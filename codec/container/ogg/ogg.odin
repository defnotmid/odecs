// Ogg (RFC 3533) demuxing of one logical stream: every page header is
// indexed at open (through a window, the payloads not read), packets are
// reassembled from their lacing, and each packet that ends a page carries
// the page's granule position. The chosen stream is the first whose first
// packet starts with `prefer` (say "OpusHead"), else the first stream.
// Chained streams after the chosen one ends are ignored.
package ogg

import "core:io"
import "core:os"

Error :: enum {
	None,
	Invalid_Argument,
	Invalid_Data,
	IO_Error,
	Out_Of_Memory,
	Closed,
	End_Of_Stream,
}

// A packet's bytes are spans[span ..< span + spans]: one per page it lies on.
Packet_Entry :: struct {
	span:    u32,
	spans:   u16,
	lead:    [2]u8, // its first bytes (an Opus TOC and frame count)
	granule: i64, // the page's granule position when the packet ends it, else -1
}

Span :: struct {
	offset: i64,
	size:   u32,
}

Reader :: struct {
	stream:    io.Stream,
	file:      ^os.File, // owned when opened from a path
	size:      i64,
	serial:    u32,
	packets:   #soa[dynamic]Packet_Entry,
	spans:     [dynamic]Span,
	buffer:    [dynamic]u8,
	window:    [dynamic]u8,
	window_at: i64,
}

@(private)
WINDOW :: 64 << 10

open :: proc(r: ^Reader, path: string, prefer: string = "") -> Error {
	f, err := os.open(path)
	if err != nil do return .IO_Error
	if e := open_stream(r, os.to_stream(f), prefer); e != .None {
		os.close(f)
		return e
	}
	r.file = f
	return .None
}

// Reads a stream with Read_At and Size; the reader borrows it until close.
open_stream :: proc(r: ^Reader, stream: io.Stream, prefer: string = "") -> Error {
	if r == nil do return .Invalid_Argument
	modes := io.query(stream)
	if .Read_At not_in modes || .Size not_in modes do return .Invalid_Argument
	size, size_err := io.size(stream)
	if size_err != .None do return .IO_Error
	r^ = {
		stream    = stream,
		size      = size,
		window_at = -1,
	}
	if e := index(r, prefer); e != .None {close(r); return e}
	return .None
}

close :: proc(r: ^Reader) {
	if r == nil do return
	delete(r.packets)
	delete(r.spans)
	delete(r.buffer)
	delete(r.window)
	if r.file != nil do os.close(r.file)
	r^ = {}
}

// Packet i's bytes, borrowed until the next read.
read_packet :: proc(r: ^Reader, i: int) -> (data: []u8, err: Error) {
	if r == nil || r.stream.procedure == nil do return nil, .Closed
	if i < 0 || i >= len(r.packets) do return nil, .End_Of_Stream
	p := r.packets[i]
	total := 0
	for s in r.spans[p.span:][:p.spans] do total += int(s.size)
	if resize(&r.buffer, total) != nil do return nil, .Out_Of_Memory
	at := 0
	for s in r.spans[p.span:][:p.spans] {
		read_all_at(r.stream, r.buffer[at:][:s.size], s.offset) or_return
		at += int(s.size)
	}
	return r.buffer[:], .None
}

// Is `data` at an Ogg page capture pattern?
is_ogg :: proc(data: []u8) -> bool {
	return len(data) >= 4 && string(data[:4]) == "OggS"
}

@(private)
index :: proc(r: ^Reader, prefer: string) -> Error {
	// The chosen stream: by its beginning-of-stream page.
	chosen := false
	at: i64
	open_packet := -1 // a packet continued on the next page
	for at + 27 <= r.size {
		head := view(r, at, 27) or_return
		if string(head[:4]) != "OggS" || head[4] != 0 {
			if len(r.packets) == 0 && !chosen && at == 0 do return .Invalid_Data
			// Lost sync: search for the next capture pattern.
			next, found := find_capture(r, at + 1) or_return
			if !found do break
			at = next
			continue
		}
		flags := head[5]
		granule := i64(get_u64(head[6:]))
		serial := get_u32(head[14:])
		count := int(head[26])
		lacing := view(r, at + 27, count) or_return
		if len(lacing) < count do break
		lace: [255]u8
		copy(lace[:count], lacing)
		body := at + 27 + i64(count)
		body_size := 0
		for v in lace[:count] do body_size += int(v)
		if body + i64(body_size) > r.size do break // a cut-off last page
		if !chosen && flags & 2 != 0 {
			// A beginning-of-stream page: the stream to read?
			first := view(r, body, len(prefer)) or_return
			if prefer == "" || string(first) == prefer {
				r.serial = serial
				chosen = true
			}
		}
		if !chosen || serial != r.serial {
			at = body + i64(body_size)
			continue
		}
		// Packets from the lacing values: a value below 255 ends one.
		continued := flags & 1 != 0
		if !continued && open_packet >= 0 {
			// The previous packet never finished: drop it.
			resize(&r.spans, int(r.packets[open_packet].span))
			resize(&r.packets, open_packet)
			open_packet = -1
		}
		offset := body
		run := 0
		last_complete := -1
		for v, k in lace[:count] {
			run += int(v)
			if v == 255 && k < count - 1 do continue
			// A span of the current packet ends here (at a terminator, or the
			// page's last value).
			if open_packet < 0 {
				if continued && run > 0 && len(r.packets) == 0 {
					// A packet continued from before the stream's first page we keep.
					offset += i64(run)
					run = 0
					continued = false
					continue
				}
				append(&r.packets, Packet_Entry{span = u32(len(r.spans)), granule = -1})
				open_packet = len(r.packets) - 1
			}
			continued = false
			append(&r.spans, Span{offset, u32(run)})
			r.packets.spans[open_packet] += 1
			offset += i64(run)
			run = 0
			if v < 255 {
				last_complete = open_packet
				open_packet = -1
			}
		}
		if last_complete >= 0 do r.packets.granule[last_complete] = granule
		at = body + i64(body_size)
		if flags & 4 != 0 do break // end of stream
	}
	if open_packet >= 0 {
		resize(&r.spans, int(r.packets[open_packet].span))
		resize(&r.packets, open_packet)
	}
	if !chosen || len(r.packets) == 0 do return .Invalid_Data
	// Each packet's first bytes.
	for &p in r.packets {
		lead := [2]u8{}
		got := 0
		for s in r.spans[p.span:][:p.spans] {
			if got == 2 do break
			n := min(int(s.size), 2 - got)
			bytes := view(r, s.offset, n) or_return
			copy(lead[got:], bytes)
			got += len(bytes)
		}
		p.lead = lead
	}
	return .None
}

@(private)
find_capture :: proc(r: ^Reader, from: i64) -> (at: i64, found: bool, err: Error) {
	for at = from; at + 4 <= r.size; {
		chunk := view(r, at, WINDOW) or_return
		for k in 0 ..< len(chunk) - 3 {
			if string(chunk[k:][:4]) == "OggS" do return at + i64(k), true, .None
		}
		at += i64(max(len(chunk) - 3, 1))
	}
	return 0, false, .None
}

@(private)
get_u32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private)
get_u64 :: proc(b: []u8) -> u64 {
	return u64(get_u32(b)) | u64(get_u32(b[4:])) << 32
}

@(private)
view :: proc(r: ^Reader, at: i64, n: int) -> (data: []u8, err: Error) {
	end := min(at + i64(n), r.size)
	if at < 0 || at > end do return nil, .Invalid_Data
	if r.window_at < 0 || at < r.window_at || end > r.window_at + i64(len(r.window)) {
		count := int(min(i64(max(n, WINDOW)), r.size - at))
		if resize(&r.window, count) != nil do return nil, .Out_Of_Memory
		read_all_at(r.stream, r.window[:], at) or_return
		r.window_at = at
	}
	start := int(at - r.window_at)
	return r.window[start:][:int(end - at)], .None
}

@(private)
read_all_at :: proc(s: io.Stream, data: []u8, offset: i64) -> Error {
	done := 0
	for done < len(data) {
		n, err := io.read_at(s, data[done:], offset + i64(done))
		if n <= 0 do return err == .EOF ? .Invalid_Data : .IO_Error
		done += n
	}
	return .None
}

package mp3

import "core:io"
import "core:os"

// Native .mp3 files: ID3v2 tags are skipped, every frame is indexed at open
// (its header read through a window, the audio itself not), and a leading
// Xing/Info frame supplies the gapless delay and padding. The index gives
// exact sample positions and seeking without estimation. Frames must keep
// the first frame's version, layer and sample rate; anything else (ID3v1,
// APE or Lyrics tags, junk) is skipped by searching for the next frame
// that another frame follows.

Reader :: struct {
	stream:  io.Stream,
	file:    ^os.File, // owned when opened from a path
	size:    i64,
	header:  Header, // the first audio frame's
	tag:     Info_Tag, // zero when the stream has none
	frames:  #soa[dynamic]Frame_Entry,
	buffer:  [dynamic]u8,
	window:  [dynamic]u8,
	window_at: i64,
}

Frame_Entry :: struct {
	offset: i64,
	size:   u16, // bytes, at most 1441
}

@(private)
WINDOW :: 64 << 10

open :: proc(r: ^Reader, path: string) -> Error {
	f, err := os.open(path)
	if err != nil do return .IO_Error
	if e := open_stream(r, os.to_stream(f)); e != .None {
		os.close(f)
		return e
	}
	r.file = f
	return .None
}

// Reads a stream with Read_At and Size; the reader borrows it until close.
open_stream :: proc(r: ^Reader, stream: io.Stream) -> Error {
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
	if e := index_frames(r); e != .None {close(r); return e}
	return .None
}

close :: proc(r: ^Reader) {
	if r == nil do return
	delete(r.frames)
	delete(r.buffer)
	delete(r.window)
	if r.file != nil do os.close(r.file)
	r^ = {}
}

// Interchannel samples after gapless trimming.
total_samples :: proc(r: ^Reader) -> i64 {
	return max(i64(len(r.frames)) * i64(r.header.samples) - i64(r.tag.delay) - i64(r.tag.padding), 0)
}

// Frame i's bytes, borrowed until the next read.
read_frame :: proc(r: ^Reader, i: int) -> (data: []u8, err: Error) {
	if r == nil || r.stream.procedure == nil do return nil, .Closed
	if i < 0 || i >= len(r.frames) do return nil, .End_Of_Stream
	e := r.frames[i]
	if resize(&r.buffer, int(e.size)) != nil do return nil, .Out_Of_Memory
	read_all_at(r.stream, r.buffer[:], e.offset) or_return
	return r.buffer[:], .None
}

// The first sample of frame i on the trimmed timeline (negative inside the
// encoder delay).
frame_sample :: proc(r: ^Reader, i: int) -> i64 {
	return i64(i) * i64(r.header.samples) - i64(r.tag.delay)
}

@(private)
index_frames :: proc(r: ^Reader) -> Error {
	at: i64
	// ID3v2 tags, possibly more than one.
	for {
		head := view(r, at, 10) or_return
		if len(head) < 10 || string(head[:3]) != "ID3" do break
		at += 10 + (i64(head[6]) << 21 | i64(head[7]) << 14 | i64(head[8]) << 7 | i64(head[9])) + (head[5] & 0x10 != 0 ? 10 : 0)
	}
	first := true
	for at + 4 <= r.size {
		head := view(r, at, 4) or_return
		h, e := parse_header(head)
		if e == .None && !first && !same_stream(h, r.header) do e = .Invalid_Data
		if e != .None || at + i64(h.frame_bytes) > r.size {
			// Resynchronise: the next header that another header follows.
			next, found := find_frame(r, at + 1, first ? {} : r.header, !first) or_return
			if !found do break
			at = next
			continue
		}
		if first {
			// The first frame must be followed by a matching one (or end the
			// file) before the stream is taken as MP3.
			if at + i64(h.frame_bytes) + 4 <= r.size {
				following := view(r, at + i64(h.frame_bytes), 4) or_return
				if nh, ne := parse_header(following); ne != .None || !same_stream(nh, h) {
					next, found := find_frame(r, at + 1, {}, false) or_return
					if !found do return .Invalid_Data
					at = next
					continue
				}
			}
			first = false
			r.header = h
			frame := view(r, at, h.frame_bytes) or_return
			if tag, ok := parse_info_tag(frame, h); ok {
				r.tag = tag
				at += i64(h.frame_bytes)
				continue // the tag frame holds no audio
			}
		}
		append(&r.frames, Frame_Entry{at, u16(h.frame_bytes)})
		at += i64(h.frame_bytes)
	}
	if first do return .Invalid_Data
	if len(r.frames) == 0 do return .Invalid_Data
	return .None
}

// Version, layer and rate stay fixed within a stream; the channel mode may
// change.
@(private)
same_stream :: proc(a, b: Header) -> bool {
	return a.version == b.version && a.layer == b.layer && a.sample_rate == b.sample_rate
}

// The first offset at or after `from` with a valid header followed by
// another (matching `like` when `match`).
@(private)
find_frame :: proc(r: ^Reader, from: i64, like: Header, match: bool) -> (at: i64, found: bool, err: Error) {
	for pos := from; pos + 4 <= r.size; {
		buf := view(r, pos, WINDOW) or_return
		for k in 0 ..< len(buf) - 3 {
			if buf[k] != 0xFF || buf[k + 1] & 0xE0 != 0xE0 do continue
			h, e := parse_header(buf[k:])
			if e != .None || (match && !same_stream(h, like)) do continue
			candidate := pos + i64(k)
			end := candidate + i64(h.frame_bytes)
			if end == r.size do return candidate, true, .None
			if end + 4 > r.size do continue
			next := view(r, end, 4) or_return
			if nh, ne := parse_header(next); ne == .None && same_stream(nh, h) do return candidate, true, .None
			buf = view(r, pos, WINDOW) or_return // the check moved the window
		}
		if len(buf) < 4 do break
		pos += i64(len(buf) - 3)
	}
	return 0, false, .None
}

// Bytes [at, at+n) through the window, clamped to the stream; valid until
// the next view.
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

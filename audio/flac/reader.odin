package flac

import "core:bytes"
import "core:io"
import "core:os"

// Native .flac files. Open reads the metadata blocks; frames are then found
// one after another without decoding them: a frame ends where the CRC-16
// of the bytes since its start is zero and a valid frame header (sync code,
// same blocking strategy, CRC-8) follows, or at the end of the audio.
// Seeking narrows the byte range with the seek table and bisection over
// verified frames, then steps frame by frame, so neither opening nor
// seeking reads the whole file.

Reader :: struct {
	stream:      io.Stream,
	file:        ^os.File, // owned when opened from a path
	size:        i64, // end of the audio: the file size less trailing tags
	info:        Stream_Info,
	stream_info: [34]u8, // the raw streaminfo block, a decoder configuration
	seek_table:  #soa[dynamic]Seek_Point, // seeks search its sample column
	audio:       i64, // offset of the first frame
	at:          i64, // offset of the frame read_frame returns next
	variable:    bool, // blocking strategy, from the first frame
	window:      [dynamic]u8,
	window_at:   i64,
}

// A frame's coded bytes, borrowed until the next call on the reader.
Packet :: struct {
	data:         []u8,
	offset:       i64,
	first_sample: i64,
	block_size:   int,
}

@(private)
READ_CHUNK :: 256 << 10
// Larger than any frame: 65535 samples of 8 channels at 33 bits, verbatim.
@(private)
MAX_FRAME_BYTES :: 4 << 20

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
	if e := parse_file(r); e != .None {close(r); return e}
	return .None
}

close :: proc(r: ^Reader) {
	if r == nil do return
	delete(r.seek_table)
	delete(r.window)
	if r.file != nil do os.close(r.file)
	r^ = {}
}

// The frame at the read position; the position moves past it.
read_frame :: proc(r: ^Reader) -> (p: Packet, err: Error) {
	if r == nil || r.stream.procedure == nil do return p, .Closed
	if r.at >= r.size do return p, .End_Of_Stream
	end := frame_end(r, r.at) or_return
	data := view(r, r.at, int(end - r.at)) or_return
	h := parse_frame_header(data, r.info) or_return
	p = {data = data, offset = r.at, first_sample = first_sample(h, r.info), block_size = h.block_size}
	r.at = end
	return p, .None
}

// Moves the read position to the frame holding interchannel sample
// `sample` (the last frame when it is past the end).
seek :: proc(r: ^Reader, sample: i64) -> Error {
	if r == nil || r.stream.procedure == nil do return .Closed
	lo, hi := r.audio, r.size
	// The last seek point at or before the target, if it checks out.
	points := r.seek_table.sample[:len(r.seek_table)]
	best := -1
	for lo, hi := 0, len(points); lo < hi; {
		mid := (lo + hi) / 2
		if points[mid] <= sample {best, lo = mid, mid + 1} else {hi = mid}
	}
	if best >= 0 {
		point := r.seek_table[best]
		if at := r.audio + point.offset; at < hi {
			if s, ok := frame_at(r, at); ok && s == point.sample do lo = at
		}
	}
	// Bisection: lo always starts a verified frame at or before the target.
	for hi - lo > BISECT_STOP {
		mid := lo + (hi - lo) / 2
		at, s, found := next_frame(r, mid, hi)
		switch {
		case !found:
			hi = mid
		case s <= sample:
			lo = at
		case:
			hi = mid
		}
	}
	r.at = lo
	for {
		start := r.at
		p, e := read_frame(r)
		if e == .End_Of_Stream {r.at = start; return .None}
		if e != .None do return e
		if p.first_sample + i64(p.block_size) > sample {r.at = start; return .None}
	}
}

// Interchannel samples in the stream: streaminfo's count, or, when that
// is unknown, the end of the last frame.
total_samples :: proc(r: ^Reader) -> (total: i64, err: Error) {
	if r.info.total_samples > 0 do return r.info.total_samples, .None
	saved := r.at
	defer r.at = saved
	seek(r, max(i64)) or_return
	p := read_frame(r) or_return
	return p.first_sample + i64(p.block_size), .None
}

@(private)
BISECT_STOP :: 64 << 10

@(private)
parse_file :: proc(r: ^Reader) -> Error {
	at: i64
	// An ID3v2 tag some taggers put in front of the stream.
	head := exact(r, 0, 10) or_return
	if string(head[:3]) == "ID3" {
		size := i64(head[6]) << 21 | i64(head[7]) << 14 | i64(head[8]) << 7 | i64(head[9])
		at = 10 + size + (head[5] & 0x10 != 0 ? 10 : 0)
	}
	marker := exact(r, at, 4) or_return
	if string(marker) != "fLaC" do return .Invalid_Data
	at += 4
	have_info := false
	for {
		b := exact(r, at, 4) or_return
		last, kind := b[0] & 0x80 != 0, b[0] & 0x7F
		size := i64(b[1]) << 16 | i64(b[2]) << 8 | i64(b[3])
		at += 4
		if kind == 127 || at + size > r.size do return .Invalid_Data
		switch kind {
		case 0:
			if have_info || size < 34 do return .Invalid_Data
			body := exact(r, at, 34) or_return
			copy(r.stream_info[:], body)
			r.info, _ = parse_stream_info(body) or_return
			have_info = true
		case 3:
			body := exact(r, at, int(size)) or_return
			for k := 0; k + 18 <= len(body); k += 18 {
				p := body[k:]
				s, offset := be(p[:8]), be(p[8:16])
				if s == max(u64) do continue
				if s > 1 << 62 || offset > 1 << 62 do return .Invalid_Data
				append(&r.seek_table, Seek_Point{i64(s), i64(offset), int(be(p[16:18]))})
			}
		}
		if !have_info do return .Invalid_Data
		at += size
		if last do break
	}
	r.audio, r.at = at, at
	if r.audio >= r.size do return .None // no audio frames
	first := exact(r, at, 2) or_return
	r.variable = first[1] & 1 != 0
	// A trailing ID3v1 tag is not audio.
	if r.size - 128 > r.audio {
		tail := exact(r, r.size - 128, 3) or_return
		if string(tail) == "TAG" do r.size -= 128
	}
	return .None
}

// Bytes [at, at+n) of the stream (clamped to the audio end), through the
// window; valid until the next view.
@(private)
view :: proc(r: ^Reader, at: i64, n: int) -> (data: []u8, err: Error) {
	if at < 0 || n < 0 do return nil, .Invalid_Data
	end := min(at + i64(n), r.size)
	if at > end do return nil, .Invalid_Data
	if at < r.window_at || end > r.window_at + i64(len(r.window)) || r.window_at < 0 {
		count := int(min(max(i64(n), READ_CHUNK), r.size - at))
		if resize(&r.window, count) != nil do return nil, .Out_Of_Memory
		if e := read_all_at(r.stream, r.window[:], at); e != .None do return nil, e
		r.window_at = at
	}
	start := int(at - r.window_at)
	return r.window[start:][:int(end - at)], .None
}

// Exactly n bytes at `at`, or Invalid_Data when the stream is shorter.
@(private)
exact :: proc(r: ^Reader, at: i64, n: int) -> (data: []u8, err: Error) {
	data = view(r, at, n) or_return
	return data, len(data) == n ? .None : .Invalid_Data
}

// Where the frame starting at `start` ends (see Reader). Only positions
// that start with a sync code are candidates, so the CRC-16 runs once over
// the frame, continued from candidate to candidate.
@(private)
frame_end :: proc(r: ^Reader, start: i64) -> (end: i64, err: Error) {
	need := r.info.max_frame > 0 ? 2 * r.info.max_frame + 64 : READ_CHUNK
	sync := r.variable ? u8(0xF9) : 0xF8
	for {
		buf := view(r, start, need) or_return
		h := parse_frame_header(buf, r.info) or_return
		at_end := start + i64(len(buf)) >= r.size
		c, done := crc16(buf[:h.size]), h.size
		for p := h.size + 2; p < len(buf); {
			k := bytes.index_byte(buf[p:], 0xFF)
			if k < 0 do break
			p += k
			if p + 1 < len(buf) && buf[p + 1] == sync {
				c, done = crc16(buf[done:p], c), p
				if c == 0 {
					if len(buf) - p < 16 && !at_end do break // the next header may be cut: read more
					if _, e := parse_frame_header(buf[p:], r.info); e == .None do return start + i64(p), .None
				}
			}
			p += 1
		}
		if at_end {
			// The last frame: the CRC holds at the end of the audio, or, with
			// junk after it, at the last position where it is zero.
			trailing := -1
			for p in done ..< len(buf) {
				if c == 0 && p >= h.size + 2 do trailing = p
				c = crc16(buf[p:][:1], c)
			}
			if c == 0 do return start + i64(len(buf)), .None
			if trailing > 0 do return start + i64(trailing), .None
			return 0, .Invalid_Data
		}
		if need >= MAX_FRAME_BYTES do return 0, .Invalid_Data
		need *= 2
	}
}

// The first sample of the verified frame at `at`.
@(private)
frame_at :: proc(r: ^Reader, at: i64) -> (sample: i64, ok: bool) {
	buf, e := view(r, at, 16)
	if e != .None do return
	h, he := parse_frame_header(buf, r.info)
	if he != .None || h.variable != r.variable do return
	if _, fe := frame_end(r, at); fe != .None do return
	return first_sample(h, r.info), true
}

// The first verified frame starting in [from, limit).
@(private)
next_frame :: proc(r: ^Reader, from, limit: i64) -> (at, sample: i64, found: bool) {
	for pos := from; pos < limit; {
		buf, e := view(r, pos, READ_CHUNK)
		if e != .None || len(buf) < 2 do return
		for k in 0 ..< len(buf) - 1 {
			if pos + i64(k) >= limit do return
			if buf[k] != 0xFF || buf[k + 1] & 0xFE != 0xF8 do continue
			if s, ok := frame_at(r, pos + i64(k)); ok do return pos + i64(k), s, true
			buf, _ = view(r, pos, READ_CHUNK) // frame_at moved the window
		}
		pos += i64(len(buf) - 1)
	}
	return
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

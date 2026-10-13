// WAV demuxing: RIFF/WAVE, its big-endian RIFX form and RF64 (64-bit sizes
// from a ds64 chunk), with integer or IEEE float PCM in WAVE_FORMAT_PCM,
// WAVE_FORMAT_IEEE_FLOAT or WAVE_FORMAT_EXTENSIBLE, and G.711 A-law and
// mu-law (expanded by expand_g711). The reader locates the data chunk at
// open and reads frames from it on request. Depends only on Odin core.
package wav

import "core:io"
import "core:os"

Error :: enum {
	None,
	Invalid_Argument,
	Invalid_Data, // malformed
	Unsupported,  // valid, outside the implemented scope (compressed formats)
	IO_Error,
	Out_Of_Memory,
	End_Of_Stream,
	Closed,
}

Companding :: enum u8 {
	None,
	A_Law, // G.711, 8 bits per sample
	Mu_Law,
}

// Interleaved sample layout. Samples are `bits` wide in the file; integer
// samples narrower than that (valid_bits) are left-justified, so reading
// them at the container width is exact.
Format :: struct {
	sample_rate:   int,
	channels:      int,
	bits:          int, // per sample in the file: 8, 16, 24 or 32 (integer); 32 or 64 (float)
	valid_bits:    int, // significant bits, at most `bits`
	float:         bool,
	big_endian:    bool, // RIFX
	unsigned:      bool, // 8-bit integer PCM is unsigned
	companding:    Companding, // G.711 bytes rather than linear PCM
	channel_mask:  u32, // WAVE_FORMAT_EXTENSIBLE speaker positions; 0 when unstated
	block_align:   int, // bytes per frame
}

Reader :: struct {
	stream:      io.Stream,
	file:        ^os.File, // owned when opened from a path
	size:        i64,
	format:      Format,
	data_offset: i64,
	frames:      i64, // complete frames in the data chunk (as far as the file holds)
	buffer:      [dynamic]u8, // read_frames storage
}

// Upper bound on a header chunk read whole (fmt and ds64 are small).
@(private)
MAX_HEADER_CHUNK :: 1 << 16

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
	if size_err != .None || size < 12 do return .Invalid_Data
	r^ = {
		stream = stream,
		size   = size,
	}
	if e := parse(r); e != .None {close(r); return e}
	return .None
}

close :: proc(r: ^Reader) {
	if r == nil do return
	delete(r.buffer)
	if r.file != nil do os.close(r.file)
	r^ = {}
}

// Reads `count` frames from frame `first`, clamped to the data; the bytes
// are borrowed until the next read on this reader.
read_frames :: proc(r: ^Reader, first: i64, count: int) -> (data: []u8, err: Error) {
	if r == nil || r.stream.procedure == nil do return nil, .Closed
	if first < 0 || count < 0 do return nil, .Invalid_Argument
	if first >= r.frames do return nil, .End_Of_Stream
	n := int(min(i64(count), r.frames - first))
	bytes := n * r.format.block_align
	if bytes > len(r.buffer) {
		if resize(&r.buffer, bytes) != nil do return nil, .Out_Of_Memory
	}
	data = r.buffer[:bytes]
	read_all_at(r.stream, data, r.data_offset + first * i64(r.format.block_align)) or_return
	return data, .None
}

@(private)
parse :: proc(r: ^Reader) -> Error {
	head: [12]u8
	read_all_at(r.stream, head[:], 0) or_return
	id := string(head[:4])
	if string(head[8:12]) != "WAVE" do return .Invalid_Data
	big := false
	rf64 := false
	switch id {
	case "RIFF":
	case "RIFX":
		big = true
	case "RF64", "BW64":
		rf64 = true
	case:
		return .Invalid_Data
	}
	// RF64 states 64-bit sizes in ds64; the 32-bit fields hold 0xFFFFFFFF.
	ds64_data: i64 = -1
	have_format := false
	at: i64 = 12
	for at + 8 <= r.size {
		chunk: [8]u8
		read_all_at(r.stream, chunk[:], at) or_return
		size := i64(u32_at(chunk[4:], big))
		body := at + 8
		switch string(chunk[:4]) {
		case "ds64":
			if !rf64 || size < 24 do return .Invalid_Data
			b: [24]u8
			read_all_at(r.stream, b[:], body) or_return
			ds64_data = i64(u64_at(b[8:], big))
			if ds64_data < 0 do return .Invalid_Data
		case "fmt ":
			if size < 16 || size > MAX_HEADER_CHUNK do return .Invalid_Data
			b: [MAX_HEADER_CHUNK]u8
			read_all_at(r.stream, b[:size], body) or_return
			parse_format(&r.format, b[:size], big) or_return
			have_format = true
		case "data":
			if !have_format do return .Invalid_Data
			if rf64 && size == 0xFFFFFFFF {
				if ds64_data < 0 do return .Invalid_Data
				size = ds64_data
			}
			// A size of zero or all ones (a writer that never came back to
			// fill it in), or one past the end (a cut-off recording), means
			// the data runs to the end of the file.
			if size == 0 || size == 0xFFFFFFFF || size > r.size - body do size = r.size - body
			r.data_offset = body
			r.frames = size / i64(r.format.block_align)
			return .None
		}
		at = body + size + (size & 1) // chunks are padded to even sizes
	}
	return .Invalid_Data
}

@(private)
FORMAT_PCM :: 1
@(private)
FORMAT_IEEE_FLOAT :: 3
@(private)
FORMAT_ALAW :: 6
@(private)
FORMAT_MULAW :: 7
@(private)
FORMAT_EXTENSIBLE :: 0xFFFE
// The KSDATAFORMAT_SUBTYPE GUID after its leading format code.
@(private)
SUBTYPE_SUFFIX := [14]u8{0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}

@(private)
parse_format :: proc(f: ^Format, b: []u8, big: bool) -> Error {
	tag := int(u16_at(b[0:], big))
	f.channels = int(u16_at(b[2:], big))
	f.sample_rate = int(u32_at(b[4:], big))
	f.block_align = int(u16_at(b[12:], big))
	f.bits = int(u16_at(b[14:], big))
	f.valid_bits = f.bits
	f.big_endian = big
	if tag == FORMAT_EXTENSIBLE {
		if len(b) < 40 || u16_at(b[16:], big) < 22 do return .Invalid_Data
		f.valid_bits = int(u16_at(b[18:], big))
		f.channel_mask = u32_at(b[20:], big)
		tag = int(u16_at(b[24:], big))
		if string(b[26:40]) != string(SUBTYPE_SUFFIX[:]) do return .Unsupported
		if f.valid_bits == 0 || f.valid_bits > f.bits do f.valid_bits = f.bits
	}
	switch tag {
	case FORMAT_PCM:
		if f.bits != 8 && f.bits != 16 && f.bits != 24 && f.bits != 32 do return .Unsupported
		f.unsigned = f.bits == 8
	case FORMAT_IEEE_FLOAT:
		if f.bits != 32 && f.bits != 64 do return .Unsupported
		f.float = true
	case FORMAT_ALAW, FORMAT_MULAW:
		if f.bits != 8 do return .Unsupported
		f.companding = tag == FORMAT_ALAW ? .A_Law : .Mu_Law
	case:
		return .Unsupported // ADPCM and other codecs
	}
	if f.channels < 1 || f.channels > 64 || f.sample_rate < 1 || f.sample_rate > 1 << 22 do return .Invalid_Data
	if f.block_align != f.channels * f.bits / 8 do return .Invalid_Data
	return .None
}

// Expands G.711 bytes to f32 in [-1, 1) through the 16-bit linear values
// of ITU-T G.711 (A-law tables 1a/1b, mu-law tables 2a/2b).
expand_g711 :: proc(law: Companding, src: []u8, dst: []f32) {
	for b, i in src[:min(len(src), len(dst))] {
		v: i32
		if law == .A_Law {
			a := i32(b ~ 0x55)
			seg := (a >> 4) & 7
			m := (a & 15) << 1 | 1
			v = seg == 0 ? m << 3 : (m + 32) << uint(seg + 2)
			if a & 0x80 == 0 do v = -v
		} else {
			u := i32(~b)
			t := ((u & 15) << 3 + 0x84) << uint((u >> 4) & 7)
			v = u & 0x80 != 0 ? 0x84 - t : t - 0x84
		}
		dst[i] = f32(v) / 32768
	}
}

@(private)
u16_at :: proc(b: []u8, big: bool) -> u16 {
	return big ? u16(b[0]) << 8 | u16(b[1]) : u16(b[1]) << 8 | u16(b[0])
}

@(private)
u32_at :: proc(b: []u8, big: bool) -> u32 {
	v: u32
	for i in 0 ..< 4 do v |= u32(b[big ? 3 - i : i]) << uint(8 * i)
	return v
}

@(private)
u64_at :: proc(b: []u8, big: bool) -> u64 {
	v: u64
	for i in 0 ..< 8 do v |= u64(b[big ? 7 - i : i]) << uint(8 * i)
	return v
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

// WAV demuxing: RIFF/WAVE, its big-endian RIFX form and RF64 (64-bit sizes
// from a ds64 chunk), with integer or IEEE float PCM in WAVE_FORMAT_PCM,
// WAVE_FORMAT_IEEE_FLOAT or WAVE_FORMAT_EXTENSIBLE, and G.711 A-law and
// mu-law. The reader locates the data chunk and the first smpl loop at open,
// and reads frames on request: as stored, or converted to i16 or f32.
package wav

import common "../common"
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

// Interleaved sample layout. Samples are `bits` wide in the file; integer
// samples narrower than that (valid_bits) are left-justified, so reading
// them at the container width is exact.
Format :: struct {
	sample_rate:   int,
	channels:      int,
	bits:          int, // per sample in the file: 8 (also G.711), 16, 24 or 32 (integer); 32 or 64 (float)
	valid_bits:    int, // significant bits, at most `bits`
	float:         bool,
	big_endian:    bool, // RIFX
	unsigned:      bool, // 8-bit integer PCM is unsigned
	sample:        common.Sample_Format, // how each sample is stored
	channel_mask:  u32, // WAVE_FORMAT_EXTENSIBLE speaker positions; 0 when unstated
	block_align:   int, // bytes per frame
}

// A loop from the smpl chunk, in frames; `end` is the last frame played.
Loop :: struct {
	start, end: i64,
}

Reader :: struct {
	stream:      io.Stream,
	bytes:       []u8, // the whole file, borrowed, when opened from memory
	file:        ^os.File, // owned when opened from a path
	size:        i64,
	format:      Format,
	data_offset: i64,
	frames:      i64, // complete frames in the data chunk (as far as the file holds)
	loop:        Maybe(Loop), // the smpl chunk's first loop
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

// Reads a whole file held in memory; the reader borrows it until close, and
// read_frames returns slices of it.
open_bytes :: proc(r: ^Reader, data: []u8) -> Error {
	if r == nil do return .Invalid_Argument
	if len(data) < 12 do return .Invalid_Data
	r^ = {
		bytes = data,
		size  = i64(len(data)),
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
	if r == nil || (r.stream.procedure == nil && r.bytes == nil) do return nil, .Closed
	if first < 0 || count < 0 do return nil, .Invalid_Argument
	if first >= r.frames do return nil, .End_Of_Stream
	n := int(min(i64(count), r.frames - first))
	bytes := n * r.format.block_align
	at := r.data_offset + first * i64(r.format.block_align)
	if r.bytes != nil do return r.bytes[at:][:bytes], .None
	if bytes > len(r.buffer) {
		if resize(&r.buffer, bytes) != nil do return nil, .Out_Of_Memory
	}
	data = r.buffer[:bytes]
	read_at(r, data, at) or_return
	return data, .None
}

// Reads frames from frame `first` into `out` as interleaved i16 or f32
// (common.to_i16, common.to_f32), keeping the first `channels` channels of
// each frame, or all of them for 0. Returns the frames read: as many as out
// holds, clamped to the data.
read :: proc {
	read_i16,
	read_f32,
}

read_i16 :: proc(r: ^Reader, first: i64, out: []i16, channels := 0) -> (frames: int, err: Error) {
	return read_converted(r, first, out, channels)
}

read_f32 :: proc(r: ^Reader, first: i64, out: []f32, channels := 0) -> (frames: int, err: Error) {
	return read_converted(r, first, out, channels)
}

@(private)
read_converted :: proc(r: ^Reader, first: i64, out: []$D, channels: int) -> (frames: int, err: Error) {
	if r == nil || r.format.channels < 1 do return 0, .Closed
	keep := common.kept_channels(r.format.channels, channels)
	data := read_frames(r, first, len(out) / keep) or_return
	return common.convert_pcm(data, r.format.sample, r.format.channels, out, keep), .None
}

// Walks the chunks: the header ones up to data, then any smpl after it.
@(private)
parse :: proc(r: ^Reader) -> Error {
	head: [12]u8
	read_at(r, head[:], 0) or_return
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
		read_at(r, chunk[:], at) or_return
		size := i64(u32_at(chunk[4:], big))
		body := at + 8
		switch string(chunk[:4]) {
		case "smpl":
			if r.loop == nil do r.loop = parse_loop(r, body, size, big)
		case "ds64":
			if r.data_offset != 0 do break
			if !rf64 || size < 24 do return .Invalid_Data
			b: [24]u8
			read_at(r, b[:], body) or_return
			ds64_data = i64(u64_at(b[8:], big))
			if ds64_data < 0 do return .Invalid_Data
		case "fmt ":
			if r.data_offset != 0 do break
			if size < 16 || size > MAX_HEADER_CHUNK do return .Invalid_Data
			b: [MAX_HEADER_CHUNK]u8
			read_at(r, b[:size], body) or_return
			parse_format(&r.format, b[:size], big) or_return
			have_format = true
		case "data":
			if r.data_offset != 0 do break
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
		}
		at = body + size + (size & 1) // chunks are padded to even sizes
	}
	return r.data_offset != 0 ? .None : .Invalid_Data
}

// The first loop of a smpl chunk (36 bytes, then 24 per loop); none when
// the chunk states none, is cut off, or the loop runs backwards.
@(private)
parse_loop :: proc(r: ^Reader, body, size: i64, big: bool) -> Maybe(Loop) {
	b: [60]u8
	if size < 60 || read_at(r, b[:], body) != .None || u32_at(b[28:], big) == 0 do return nil
	start, end := i64(u32_at(b[44:], big)), i64(u32_at(b[48:], big))
	if start > end do return nil
	return Loop{start, end}
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
	case FORMAT_PCM, FORMAT_IEEE_FLOAT:
		f.float = tag == FORMAT_IEEE_FLOAT
		f.unsigned = !f.float && f.bits == 8
		ok: bool
		if f.sample, ok = common.sample_format(f.bits, f.float, f.unsigned, big); !ok do return .Unsupported
	case FORMAT_ALAW, FORMAT_MULAW:
		if f.bits != 8 do return .Unsupported
		f.sample = tag == FORMAT_ALAW ? .A_Law : .Mu_Law
	case:
		return .Unsupported // ADPCM and other codecs
	}
	if f.channels < 1 || f.channels > 64 || f.sample_rate < 1 || f.sample_rate > 1 << 22 do return .Invalid_Data
	if f.block_align != f.channels * f.bits / 8 do return .Invalid_Data
	return .None
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
read_at :: proc(r: ^Reader, data: []u8, offset: i64) -> Error {
	if r.bytes != nil {
		if offset > r.size - i64(len(data)) do return .Invalid_Data
		copy(data, r.bytes[offset:])
		return .None
	}
	done := 0
	for done < len(data) {
		n, err := io.read_at(r.stream, data[done:], offset + i64(done))
		if n <= 0 do return err == .EOF ? .Invalid_Data : .IO_Error
		done += n
	}
	return .None
}

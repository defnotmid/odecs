package wav

import "core:math"
import "core:os"

// Sample formats a WAV file is written in.
Write_Format :: enum {
	S16, // WAVE_FORMAT_PCM, 16-bit: round(clamp(s, -1, 1) * 32767)
	F32, // WAVE_FORMAT_IEEE_FLOAT, 32-bit: the samples as they are
}

// The size in bytes of a WAV file of `samples` interleaved samples.
encoded_size :: proc(samples: int, format: Write_Format) -> int {
	return 44 + samples * (format == .S16 ? 2 : 4)
}

// Writes a canonical RIFF/WAVE file (a 16-byte fmt chunk, then data) of
// interleaved f32 samples into dst, which holds encoded_size bytes. Returns
// the bytes written.
encode_into :: proc(dst: []u8, samples: []f32, sample_rate, channels: int, format: Write_Format) -> (n: int, err: Error) {
	if sample_rate <= 0 || channels <= 0 || channels > 0xFFFF || len(samples) % channels != 0 do return 0, .Invalid_Argument
	width := format == .S16 ? 2 : 4
	data_bytes := len(samples) * width
	if 36 + data_bytes > int(max(u32)) do return 0, .Invalid_Argument
	n = 44 + data_bytes
	if len(dst) < n do return 0, .Invalid_Argument
	put16 :: #force_inline proc(b: []u8, at: int, v: int) {b[at], b[at + 1] = u8(v), u8(v >> 8)}
	put32 :: #force_inline proc(b: []u8, at: int, v: int) {put16(b, at, v); put16(b, at + 2, v >> 16)}
	copy(dst[0:], "RIFF")
	put32(dst, 4, 36 + data_bytes)
	copy(dst[8:], "WAVEfmt ")
	put32(dst, 16, 16)
	put16(dst, 20, format == .S16 ? FORMAT_PCM : FORMAT_IEEE_FLOAT)
	put16(dst, 22, channels)
	put32(dst, 24, sample_rate)
	put32(dst, 28, sample_rate * channels * width)
	put16(dst, 32, channels * width)
	put16(dst, 34, width * 8)
	copy(dst[36:], "data")
	put32(dst, 40, data_bytes)
	body := dst[44:n]
	switch format {
	case .S16:
		for s, i in samples do put16(body, i * 2, int(math.round(clamp(s, -1, 1) * 32767)))
	case .F32:
		for s, i in samples do put32(body, i * 4, int(transmute(u32)s))
	}
	return n, .None
}

// A WAV file of interleaved f32 samples, allocated with `allocator`.
encode :: proc(samples: []f32, sample_rate, channels: int, format: Write_Format, allocator := context.allocator) -> (data: []u8, err: Error) {
	if channels <= 0 do return nil, .Invalid_Argument
	data = make([]u8, encoded_size(len(samples), format), allocator)
	if data == nil do return nil, .Out_Of_Memory
	if _, e := encode_into(data, samples, sample_rate, channels, format); e != .None {
		delete(data, allocator)
		return nil, e
	}
	return data, .None
}

// Writes a WAV file of interleaved f32 samples to path.
write_file :: proc(path: string, samples: []f32, sample_rate, channels: int, format: Write_Format) -> Error {
	data := encode(samples, sample_rate, channels, format, context.temp_allocator) or_return
	if os.write_entire_file(path, data) != nil do return .IO_Error
	return .None
}

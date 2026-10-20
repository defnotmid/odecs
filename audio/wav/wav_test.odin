package wav

import common "../../common"
import "core:io"
import "core:math"
import "core:testing"

@(private = "file")
bytes_stream :: proc(b: ^[]u8) -> io.Stream {
	proc_ :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
		b := (^[]u8)(data)^
		#partial switch mode {
		case .Read_At:
			if offset >= i64(len(b)) do return 0, .EOF
			return i64(copy(p, b[offset:])), .None
		case .Size:
			return i64(len(b)), .None
		case .Query:
			return io.query_utility({.Read_At, .Size, .Query})
		}
		return 0, .Unsupported
	}
	return {proc_, b}
}

@(private = "file")
put :: proc(out: ^[dynamic]u8, v: u64, n: int, big: bool) {
	for i in 0 ..< n do append(out, u8(v >> uint(8 * (big ? n - 1 - i : i))))
}

@(private = "file")
chunk :: proc(out: ^[dynamic]u8, id: string, body: []u8, big: bool) {
	append(out, id)
	put(out, u64(len(body)), 4, big)
	append(out, ..body)
	if len(body) & 1 == 1 do append(out, 0)
}

// A file with a format chunk, an odd-sized chunk before the data (padded),
// the given sample bytes and, when given, a smpl chunk after them.
@(private = "file")
build :: proc(riff: string, format: []u8, samples: []u8, big := false, smpl: []u8 = nil) -> [dynamic]u8 {
	body: [dynamic]u8
	defer delete(body)
	append(&body, "WAVE")
	chunk(&body, "fmt ", format, big)
	chunk(&body, "junk", {1, 2, 3}, big)
	chunk(&body, "data", samples, big)
	if smpl != nil do chunk(&body, "smpl", smpl, big)
	out: [dynamic]u8
	append(&out, riff)
	put(&out, u64(len(body)), 4, big)
	append(&out, ..body[:])
	return out
}

@(private = "file")
pcm_format :: proc(tag, channels, rate, bits: int, big := false) -> [dynamic]u8 {
	f: [dynamic]u8
	put(&f, u64(tag), 2, big)
	put(&f, u64(channels), 2, big)
	put(&f, u64(rate), 4, big)
	put(&f, u64(rate * channels * bits / 8), 4, big)
	put(&f, u64(channels * bits / 8), 2, big)
	put(&f, u64(bits), 2, big)
	return f
}

@(test)
rifx_big_endian_and_padding :: proc(t: ^testing.T) {
	f := pcm_format(1, 2, 44100, 16, true)
	defer delete(f)
	doc := build("RIFX", f[:], {0x12, 0x34, 0xFF, 0xFE, 0x00, 0x01, 0x80, 0x00}, true)
	defer delete(doc)
	data := doc[:]
	r: Reader
	testing.expect_value(t, open_stream(&r, bytes_stream(&data)), Error.None)
	defer close(&r)
	testing.expect(t, r.format.big_endian && r.format.channels == 2 && r.format.sample_rate == 44100)
	testing.expect_value(t, r.frames, 2)
	b, e := read_frames(&r, 1, 10)
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, string(b), "\x00\x01\x80\x00")
	_, e = read_frames(&r, 2, 1)
	testing.expect_value(t, e, Error.End_Of_Stream)
}

@(test)
extensible_float_and_refusals :: proc(t: ^testing.T) {
	f := pcm_format(0xFFFE, 1, 48000, 32)
	defer delete(f)
	put(&f, 22, 2, false) // cbSize
	put(&f, 32, 2, false) // valid bits
	put(&f, 4, 4, false) // channel mask: front centre
	put(&f, 3, 2, false) // IEEE float subtype
	append(&f, ..SUBTYPE_SUFFIX[:])
	doc := build("RIFF", f[:], {0, 0, 0x80, 0x3F})
	defer delete(doc)
	data := doc[:]
	r: Reader
	testing.expect_value(t, open_stream(&r, bytes_stream(&data)), Error.None)
	testing.expect(t, r.format.float && r.format.bits == 32 && r.format.channel_mask == 4 && r.frames == 1)
	close(&r)
	// ADPCM is a valid file outside the scope.
	adpcm := pcm_format(2, 1, 8000, 4)
	defer delete(adpcm)
	doc2 := build("RIFF", adpcm[:], {1, 2})
	defer delete(doc2)
	data = doc2[:]
	testing.expect_value(t, open_stream(&r, bytes_stream(&data)), Error.Unsupported)
	// A block alignment that does not match channels and depth.
	bad := pcm_format(1, 2, 8000, 16)
	defer delete(bad)
	bad[12] = 3
	doc3 := build("RIFF", bad[:], {1, 2, 3})
	defer delete(doc3)
	data = doc3[:]
	testing.expect_value(t, open_stream(&r, bytes_stream(&data)), Error.Invalid_Data)
}

// Every prefix of a valid file opens (data clamped to what is there) or
// fails with an error.
@(test)
truncations_fail_cleanly :: proc(t: ^testing.T) {
	f := pcm_format(1, 2, 48000, 24)
	defer delete(f)
	samples: [60]u8
	doc := build("RIFF", f[:], samples[:])
	defer delete(doc)
	for n in 0 ..< len(doc) {
		data := doc[:n]
		r: Reader
		if open_stream(&r, bytes_stream(&data)) == .None {
			testing.expect(t, r.data_offset + r.frames * 6 <= i64(n))
			read_frames(&r, 0, 100)
			close(&r)
		}
	}
}

// A smpl chunk with one loop.
@(private = "file")
smpl_chunk :: proc(start, end: u32, big := false) -> [dynamic]u8 {
	b: [dynamic]u8
	for v in ([9]u32{7 = 1}) do put(&b, u64(v), 4, big) // manufacturer .. sampler data; one loop
	for v in ([6]u32{2 = start, 3 = end}) do put(&b, u64(v), 4, big) // cue, type, start, end, fraction, count
	return b
}

@(test)
loop_after_data_and_conversion :: proc(t: ^testing.T) {
	f := pcm_format(1, 3, 44100, 24)
	defer delete(f)
	s := smpl_chunk(10, 99)
	defer delete(s)
	// Two frames of three 24-bit channels.
	samples := [?]u8 {
		0x00, 0x00, 0x80, 0xFF, 0xFF, 0x7F, 0x80, 0x00, 0x00, // -2^23, 2^23 - 1, 128
		0x7F, 0x00, 0x00, 0x80, 0xFF, 0xFF, 0x7F, 0xFF, 0xFF, // 127, -128, -129
	}
	doc := build("RIFF", f[:], samples[:], smpl = s[:])
	defer delete(doc)
	r: Reader
	testing.expect_value(t, open_bytes(&r, doc[:]), Error.None)
	defer close(&r)
	testing.expect_value(t, r.frames, 2)
	testing.expect_value(t, r.loop, Maybe(Loop)(Loop{10, 99}))
	// The first two channels: 24-bit rounds off its low byte half away
	// from zero and saturates.
	pcm: [4]i16
	n, e := read(&r, 0, pcm[:], 2)
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, pcm, [4]i16{-32768, 32767, 0, -1})
	all: [6]i16
	n, _ = read(&r, 1, all[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, all, [6]i16{0, -1, -1, 0, 0, 0})
	x: [6]f32
	n, _ = read(&r, 0, x[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, x, [6]f32{-1, 8388607.0 / 8388608, 128.0 / 8388608, 127.0 / 8388608, -128.0 / 8388608, -129.0 / 8388608})
	_, e = read(&r, 2, x[:])
	testing.expect_value(t, e, Error.End_Of_Stream)
}

@(test)
rifx_loop_and_g711 :: proc(t: ^testing.T) {
	f := pcm_format(7, 1, 8000, 8, true) // mu-law
	defer delete(f)
	s := smpl_chunk(1, 2, true)
	defer delete(s)
	// An odd-sized data chunk, padded before the smpl chunk.
	doc := build("RIFX", f[:], {0x00, 0x80, 0xFF}, true, s[:])
	defer delete(doc)
	data := doc[:]
	r: Reader
	testing.expect_value(t, open_stream(&r, bytes_stream(&data)), Error.None)
	defer close(&r)
	testing.expect_value(t, r.format.sample, common.Sample_Format.Mu_Law)
	testing.expect_value(t, r.loop, Maybe(Loop)(Loop{1, 2}))
	pcm: [3]i16
	n, _ := read(&r, 0, pcm[:])
	testing.expect_value(t, n, 3)
	testing.expect_value(t, pcm, [3]i16{-32124, 32124, 0})
	// A loop running backwards is no loop.
	back := smpl_chunk(5, 4)
	defer delete(back)
	le := pcm_format(7, 1, 8000, 8)
	defer delete(le)
	doc2 := build("RIFF", le[:], {0x00}, smpl = back[:])
	defer delete(doc2)
	close(&r)
	testing.expect_value(t, open_bytes(&r, doc2[:]), Error.None)
	testing.expect(t, r.loop == nil)
}

@(test)
writer_round_trips :: proc(t: ^testing.T) {
	samples := [8]f32{0, 0.5, -0.5, 1, -1, 1.5, -2, 0.25}
	for format in Write_Format {
		for channels in ([3]int{1, 2, 4}) {
			data, err := encode(samples[:], 44100, channels, format)
			defer delete(data)
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, len(data), encoded_size(len(samples), format))
			r: Reader
			testing.expect_value(t, open_bytes(&r, data), Error.None)
			testing.expect_value(t, r.format.channels, channels)
			testing.expect_value(t, r.format.sample_rate, 44100)
			testing.expect_value(t, int(r.frames), len(samples) / channels)
			out: [8]f32
			frames, re := read(&r, 0, out[:])
			testing.expect_value(t, re, Error.None)
			testing.expect_value(t, frames * channels, len(samples))
			for s, i in samples {
				// read clamps float samples to [-1, 1].
				want := format == .F32 ? clamp(s, -1, 1) : f32(math.round(clamp(s, -1, 1) * 32767)) / 32768
				testing.expectf(t, out[i] == want, "%v x%d sample %d: %v, want %v", format, channels, i, out[i], want)
			}
			close(&r)
		}
	}
	_, e := encode(samples[:3], 44100, 2, .S16)
	testing.expect_value(t, e, Error.Invalid_Argument)
}

@(test)
header_matches_encode :: proc(t: ^testing.T) {
	samples := [8]f32{0, 0.5, -0.5, 1, -1, 1.5, -2, 0.25}
	for format in Write_Format {
		for channels in ([3]int{1, 2, 4}) {
			data, err := encode(samples[:], 48000, channels, format)
			defer delete(data)
			testing.expect_value(t, err, Error.None)
			h: [HEADER_SIZE]u8
			testing.expect_value(t, header_into(h[:], len(samples) / channels, 48000, channels, format), Error.None)
			testing.expectf(t, h == ([^][HEADER_SIZE]u8)(raw_data(data))[0], "%v x%d: the header differs from encode's", format, channels)
		}
	}
	h: [HEADER_SIZE]u8
	testing.expect_value(t, header_into(h[:HEADER_SIZE - 1], 1, 44100, 2, .S16), Error.Invalid_Argument)
	testing.expect_value(t, header_into(h[:], -1, 44100, 2, .S16), Error.Invalid_Argument)
	testing.expect_value(t, header_into(h[:], 1 << 30, 44100, 2, .S16), Error.Invalid_Argument) // 4 GiB of data: past a u32
	testing.expect_value(t, header_into(h[:], (int(max(u32)) - 36) / 4, 44100, 2, .S16), Error.None)
}

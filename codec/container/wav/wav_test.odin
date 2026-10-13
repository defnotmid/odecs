package wav

import "core:io"
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

// A file with a format chunk, an odd-sized chunk before the data (padded)
// and the given sample bytes.
@(private = "file")
build :: proc(riff: string, format: []u8, samples: []u8, big := false) -> [dynamic]u8 {
	body: [dynamic]u8
	defer delete(body)
	append(&body, "WAVE")
	chunk(&body, "fmt ", format, big)
	chunk(&body, "junk", {1, 2, 3}, big)
	chunk(&body, "data", samples, big)
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

@(test)
g711_expansion :: proc(t: ^testing.T) {
	// G.711 tables: mu-law 0x00 and 0x80 are the extremes, 0xFF and 0x7F
	// zero; A-law 0xD5 and 0x55 are the smallest steps.
	src := [?]u8{0x00, 0x80, 0xFF, 0x7F}
	out: [4]f32
	expand_g711(.Mu_Law, src[:], out[:])
	testing.expect_value(t, out, [4]f32{-32124.0 / 32768, 32124.0 / 32768, 0, 0})
	a := [?]u8{0xD5, 0x55, 0xAA, 0x2A}
	expand_g711(.A_Law, a[:], out[:])
	testing.expect_value(t, out, [4]f32{8.0 / 32768, -8.0 / 32768, 32256.0 / 32768, -32256.0 / 32768})
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

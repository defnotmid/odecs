package hdr

import "core:math"
import "core:testing"

// A file: the header with `format` and `size` lines, then `body`.
@(private = "file")
file :: proc(format, size: string, body: []u8) -> [dynamic]u8 {
	b: [dynamic]u8
	append(&b, "#?RADIANCE\n# made by hdr_test\n")
	append(&b, format)
	append(&b, "\n\n")
	append(&b, size)
	append(&b, "\n")
	append(&b, ..body)
	return b
}

@(test)
flat_scanlines :: proc(t: ^testing.T) {
	// 2x2, stored flat (narrower than 8): exponent 0 is black, 136 is the
	// mantissa itself, 1 the smallest (subnormal) scale, 255 the largest.
	body := []u8{1, 2, 3, 136, 9, 9, 9, 0, 128, 64, 1, 1, 255, 0, 1, 255}
	data := file("FORMAT=32-bit_rle_rgbe", "-Y 2 +X 2", body)
	defer delete(data)
	i, err := info(data[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, i, Info{2, 2})
	pixels: [16]f32
	testing.expect_value(t, decode_into(data[:], pixels[:]), Error.None)
	small, large := math.ldexp_f32(1, -135), math.ldexp_f32(1, 119)
	want := [16]f32{1, 2, 3, 1, 0, 0, 0, 1, 128 * small, 64 * small, small, 1, 255 * large, 0, large, 1}
	testing.expect_value(t, pixels, want)
}

@(test)
rle_scanlines :: proc(t: ^testing.T) {
	// 8x2: each row starts 2, 2, 0, 8 and holds four channels of runs (count
	// above 128) and literal dumps.
	row := []u8{
		2, 2, 0, 8,
		128 + 8, 10, // R: eight 10s
		3, 1, 2, 3, 128 + 5, 7, // G: 1, 2, 3, then five 7s
		8, 0, 1, 2, 3, 4, 5, 6, 7, // B: 0..7
		128 + 4, 136, 128 + 4, 137, // E: scale 1 then 2
	}
	body: [dynamic]u8
	defer delete(body)
	append(&body, ..row)
	append(&body, ..row)
	data := file("FORMAT=32-bit_rle_rgbe", "-Y 2 +X 8", body[:])
	defer delete(data)
	pixels: [8 * 2][4]f32
	testing.expect_value(t, decode_into(data[:], ([^]f32)(&pixels)[:8 * 2 * 4]), Error.None)
	g := [8]f32{1, 2, 3, 7, 7, 7, 7, 7}
	for y in 0 ..< 2 do for x in 0 ..< 8 {
		s: f32 = x < 4 ? 1 : 2
		testing.expect_value(t, pixels[y * 8 + x], [4]f32{10 * s, g[x] * s, f32(x) * s, 1})
	}
}

@(test)
scales_are_powers_of_two :: proc(t: ^testing.T) {
	// Every exponent through decode_into against ldexp.
	body: [dynamic]u8
	defer delete(body)
	for e in 0 ..< 256 do append(&body, 255, 1, 0, u8(e))
	data := file("FORMAT=32-bit_rle_rgbe", "-Y 256 +X 1", body[:])
	defer delete(data)
	pixels: [256][4]f32
	testing.expect_value(t, decode_into(data[:], ([^]f32)(&pixels)[:256 * 4]), Error.None)
	for e in 0 ..< 256 {
		f := e == 0 ? 0 : math.ldexp_f32(1, e - 136)
		testing.expect_value(t, pixels[e], [4]f32{255 * f, f, 0, 1})
	}
}

@(test)
refusals :: proc(t: ^testing.T) {
	pixel := []u8{1, 1, 1, 128}
	cases := []struct {
		format, size: string,
		body:         []u8,
		want:         Error,
	}{
		{"FORMAT=32-bit_rle_xyze", "-Y 1 +X 1", pixel, .Unsupported},
		{"EXPOSURE=1", "-Y 1 +X 1", pixel, .Unsupported},
		{"FORMAT=32-bit_rle_rgbe", "+Y 1 +X 1", pixel, .Unsupported},
		{"FORMAT=32-bit_rle_rgbe", "-Y 1 -X 1", pixel, .Unsupported},
		{"FORMAT=32-bit_rle_rgbe", "-Y 0 +X 1", pixel, .Invalid},
		{"FORMAT=32-bit_rle_rgbe", "-Y 1 +X x", pixel, .Invalid},
		{"FORMAT=32-bit_rle_rgbe", "-Y 2 +X 1", pixel, .Invalid}, // truncated
		{"FORMAT=32-bit_rle_rgbe", "-Y 1 +X 8", {2, 2, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0}, .Invalid}, // RLE width
		{"FORMAT=32-bit_rle_rgbe", "-Y 1 +X 8", {2, 2, 0, 8, 128 + 9, 0, 0, 0, 0, 0, 0, 0}, .Invalid}, // run past the row
		{"FORMAT=32-bit_rle_rgbe", "-Y 1 +X 8", {2, 2, 0, 8, 128 + 8, 0, 128 + 8, 0, 128 + 8, 0, 128 + 8}, .Invalid}, // truncated run
	}
	pixels: [8 * 4]f32
	for c in cases {
		data := file(c.format, c.size, c.body)
		testing.expect_value(t, decode_into(data[:], pixels[:]), c.want)
		delete(data)
	}
	testing.expect_value(t, decode_into(transmute([]u8)string("#?RADIANCE"), pixels[:]), Error.Invalid)
	data := file("FORMAT=32-bit_rle_rgbe", "-Y 1 +X 1", pixel)
	defer delete(data)
	testing.expect_value(t, decode_into(data[:], pixels[:3]), Error.Invalid) // short output
}

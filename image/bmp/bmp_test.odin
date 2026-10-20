package bmp

import "core:slice"
import "core:testing"

// A 2x2 24-bit bitmap: the 14-byte file header, a header of `header_size`
// bytes, and two rows of two BGR pixels padded to four bytes.
@(private = "file")
tiny :: proc(header_size: int, top_down: bool) -> [dynamic]u8 {
	b: [dynamic]u8
	put16 :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v), u8(v >> 8))}
	put32 :: proc(b: ^[dynamic]u8, v: int) {put16(b, v); put16(b, v >> 16)}
	append(&b, 'B', 'M')
	put32(&b, 14 + header_size + 16)
	put32(&b, 0)
	put32(&b, 14 + header_size)
	put32(&b, header_size)
	if header_size == 12 {
		put16(&b, 2)
		put16(&b, top_down ? -2 : 2)
	} else {
		put32(&b, 2)
		put32(&b, top_down ? -2 : 2)
	}
	put16(&b, 1)
	put16(&b, 24)
	if header_size == 40 do for _ in 0 ..< 6 do put32(&b, 0)
	// Stored rows: first red, green; then blue, white.
	append(&b, 0, 0, 255, 0, 255, 0, 0, 0)
	append(&b, 255, 0, 0, 255, 255, 255, 0, 0)
	return b
}

@(test)
rows_bottom_up_top_down_and_os2_header :: proc(t: ^testing.T) {
	first := [8]u8{255, 0, 0, 255, 0, 255, 0, 255} // red, green
	second := [8]u8{0, 0, 255, 255, 255, 255, 255, 255} // blue, white
	for header_size in ([2]int{12, 40}) {
		for top_down in ([2]bool{false, true}) {
			if header_size == 12 && top_down do continue // OS/2 heights are unsigned
			data := tiny(header_size, top_down)
			defer delete(data)
			pixels, w, h, err := decode(data[:])
			defer delete(pixels)
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, w, 2)
			testing.expect_value(t, h, 2)
			if err != .None do continue
			top, bottom := top_down ? first : second, top_down ? second : first
			testing.expectf(t, slice.equal(pixels[:8], top[:]) && slice.equal(pixels[8:16], bottom[:]), "header %d top_down %v: %v", header_size, top_down, pixels)
		}
	}
}

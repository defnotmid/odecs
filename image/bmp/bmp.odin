// Windows bitmaps to RGBA8, decoded by stb_image's rules (the suite's
// reference): the OS/2 12-byte header and the 40, 56, 108 and 124-byte
// Windows headers; 1, 4 and 8-bit palettes; 24-bit; 16 and 32-bit with the
// default or BI_BITFIELDS masks, each channel scaled to 8 bits by bit
// replication. RLE and embedded JPEG/PNG are refused, as stb refuses them. An
// alpha channel that is zero everywhere is taken as opaque. core:image's BMP
// loader returns three channels whatever the file holds, so it is not used.
package bmp

import "core:math/bits"

Error :: enum {
	None,
	Unsupported, // RLE, embedded JPEG/PNG, an unknown header
	Invalid,     // malformed or truncated
	Out_Of_Memory,
}

Info :: struct {
	width, height: int,
	has_alpha:     bool,
}

// The header's facts, and where the pixels and palette are.
@(private)
Header :: struct {
	using info:     Info,
	bpp, offset:    int,
	header_size:    int,
	top_down:       bool,
	masks:          [4]u32, // r, g, b, a
	read:           int, // bytes up to the end of the header and masks
	masks_follow:   bool, // three BI_BITFIELDS masks after a 40 or 56-byte header
}

// Reads past the end as zeros, as stb's reader does; parse checks the sizes
// that matter.
@(private)
Cursor :: struct {
	data: []u8,
	pos:  int,
}

@(private)
u8_at :: #force_inline proc(c: ^Cursor) -> u32 {
	v := c.pos < len(c.data) ? u32(c.data[c.pos]) : 0
	c.pos += 1
	return v
}
@(private)
u16_at :: #force_inline proc(c: ^Cursor) -> u32 {return u8_at(c) | u8_at(c) << 8}
@(private)
u32_at :: #force_inline proc(c: ^Cursor) -> u32 {return u16_at(c) | u16_at(c) << 16}

info :: proc(data: []u8) -> (i: Info, err: Error) {
	h := parse(data) or_return
	return h.info, .None
}

@(private)
parse :: proc(data: []u8) -> (h: Header, err: Error) {
	c := Cursor{data = data}
	if len(data) < 18 || data[0] != 'B' || data[1] != 'M' do return h, .Invalid
	c.pos = 10
	h.offset = int(u32_at(&c))
	h.header_size = int(u32_at(&c))
	switch h.header_size {
	case 12, 40, 56, 108, 124:
	case:
		return h, .Unsupported
	}
	width, height: i32
	if h.header_size == 12 {
		width, height = i32(u16_at(&c)), i32(i16(u16_at(&c)))
	} else {
		width, height = i32(u32_at(&c)), i32(u32_at(&c))
	}
	if u16_at(&c) != 1 do return h, .Invalid
	h.bpp = int(u16_at(&c))
	if h.header_size != 12 {
		compression := u32_at(&c)
		switch {
		case compression == 1 || compression == 2 || compression >= 4:
			return h, .Unsupported
		case compression == 3 && h.bpp != 16 && h.bpp != 32:
			return h, .Invalid
		}
		c.pos += 20 // image size, resolutions, colours used and important
		if h.header_size == 40 || h.header_size == 56 {
			if h.header_size == 56 do c.pos += 16
			if h.bpp == 16 || h.bpp == 32 {
				if compression == 0 {
					h.masks = default_masks(h.bpp)
				} else {
					h.masks.rgb = {u32_at(&c), u32_at(&c), u32_at(&c)}
					h.masks_follow = true
					// Photoshop writes this; mspaint and stb refuse it.
					if h.masks.r == h.masks.g && h.masks.g == h.masks.b do return h, .Invalid
				}
			}
		} else {
			h.masks = {u32_at(&c), u32_at(&c), u32_at(&c), u32_at(&c)}
			if compression != 3 do h.masks = default_masks(h.bpp)
			c.pos += 4 + 48 // colour space and its parameters
			if h.header_size == 124 do c.pos += 16
		}
	}
	// Where stb stands after the header: 14 file bytes, the header, and the
	// three masks a 40/56-byte BI_BITFIELDS header is followed by.
	h.read = 14 + h.header_size
	if h.masks_follow do h.read += 12
	if width <= 0 || height == 0 || int(width) > 1 << 24 || abs(int(height)) > 1 << 24 do return h, .Invalid
	h.width, h.height, h.top_down = int(width), abs(int(height)), height < 0
	switch {
	case h.bpp == 24 && h.masks.a == 0xff000000:
		h.has_alpha = false
	case:
		h.has_alpha = h.masks.a != 0
	}
	return h, .None
}

@(private)
default_masks :: proc(bpp: int) -> [4]u32 {
	switch bpp {
	case 16:
		return {31 << 10, 31 << 5, 31, 0}
	case 32:
		return {0xff << 16, 0xff << 8, 0xff, 0xff << 24}
	}
	return {}
}

// Decodes to tightly packed RGBA8, top-down rows, allocated with `allocator`.
decode :: proc(data: []u8, allocator := context.allocator) -> (pixels: []u8, width, height: int, err: Error) {
	h := parse(data) or_return
	pixels = make([]u8, h.width * h.height * 4, allocator) or_else nil
	if pixels == nil do return nil, 0, 0, .Out_Of_Memory
	if err = decode_into(data, pixels); err != .None {
		delete(pixels, allocator)
		return nil, 0, 0, err
	}
	return pixels, h.width, h.height, .None
}

// Decodes into `pixels`, width * height * 4 bytes (from info); every pixel
// is written.
decode_into :: proc(data: []u8, pixels: []u8) -> Error {
	h := parse(data) or_return
	width, height := h.width, h.height
	if len(pixels) < width * height * 4 do return .Invalid
	palette_size: int
	if h.header_size == 12 {
		if h.bpp < 24 do palette_size = (h.offset - 14 - 24) / 3
	} else if h.bpp < 16 {
		palette_size = (h.offset - h.read) >> 2
	}
	if palette_size == 0 && h.offset != h.read do return .Invalid
	c := Cursor{data = data, pos = h.read}
	// Rows are stored bottom-up unless the height is negative.
	row_of :: #force_inline proc(h: ^Header, j: int) -> int {return h.top_down ? j : h.height - 1 - j}
	all_alpha: u32
	if h.bpp < 16 {
		if palette_size <= 0 || palette_size > 256 do return .Invalid
		palette: [256][4]u8
		for i in 0 ..< palette_size {
			b, g, r := u8(u8_at(&c)), u8(u8_at(&c)), u8(u8_at(&c))
			if h.header_size != 12 do c.pos += 1
			palette[i] = {r, g, b, 255}
		}
		c.pos = h.offset
		row_bytes: int
		switch h.bpp {
		case 1:
			row_bytes = (width + 7) >> 3
		case 4:
			row_bytes = (width + 1) >> 1
		case 8:
			row_bytes = width
		case:
			return .Invalid
		}
		pad := -row_bytes & 3
		for j in 0 ..< height {
			out := pixels[row_of(&h, j) * width * 4:][:width * 4]
			start := c.pos
			for i in 0 ..< width {
				v: u32
				switch h.bpp {
				case 1:
					at := start + i >> 3
					v = (at < len(data) ? u32(data[at]) : 0) >> uint(7 - i & 7) & 1
				case 4:
					at := start + i >> 1
					b := at < len(data) ? u32(data[at]) : 0
					v = i & 1 == 0 ? b >> 4 : b & 15
				case:
					at := start + i
					v = at < len(data) ? u32(data[at]) : 0
				}
				p := palette[v]
				out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = p[0], p[1], p[2], 255
			}
			c.pos = start + row_bytes + pad
		}
		all_alpha = 255
	} else {
		c.pos = h.offset
		row_bytes := h.bpp == 24 ? 3 * width : h.bpp == 16 ? 2 * width : 0
		pad := -row_bytes & 3
		easy := h.bpp == 24 || h.bpp == 32 && h.masks == default_masks(32)
		shifts, counts: [4]int
		if !easy {
			if h.masks.r == 0 || h.masks.g == 0 || h.masks.b == 0 do return .Invalid
			for m, k in h.masks {
				shifts[k], counts[k] = high_bit(m) - 7, bit_count(m)
				if counts[k] > 8 do return .Invalid
			}
		}
		for j in 0 ..< height {
			out := pixels[row_of(&h, j) * width * 4:][:width * 4]
			for i in 0 ..< width {
				r, g, b, a: u32
				if easy {
					b, g, r = u8_at(&c), u8_at(&c), u8_at(&c)
					a = h.bpp == 32 ? u8_at(&c) : 255
				} else {
					v := h.bpp == 16 ? u16_at(&c) : u32_at(&c)
					r = scale(v & h.masks.r, shifts.r, counts.r)
					g = scale(v & h.masks.g, shifts.g, counts.g)
					b = scale(v & h.masks.b, shifts.b, counts.b)
					a = h.masks.a != 0 ? scale(v & h.masks.a, shifts.a, counts.a) : 255
				}
				all_alpha |= a
				out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = u8(r), u8(g), u8(b), u8(a)
			}
			c.pos += pad
		}
	}
	// An alpha channel that is zero everywhere was never meant: opaque.
	if all_alpha == 0 do for i := 3; i < len(pixels); i += 4 do pixels[i] = 255
	return .None
}

// The value under a mask moved to 8 bits, its top bits replicated below it.
@(private)
scale :: proc(masked: u32, shift, bits: int) -> u32 {
	@(static, rodata) multiply := [9]u32{0, 0xff, 0x55, 0x49, 0x11, 0x21, 0x41, 0x81, 0x01}
	@(static, rodata) down := [9]u32{0, 0, 0, 1, 0, 2, 4, 6, 0}
	v := shift < 0 ? masked << uint(-shift) : masked >> uint(shift)
	v >>= uint(8 - bits)
	return (v * multiply[bits]) >> down[bits]
}

@(private)
high_bit :: proc(m: u32) -> int {return m == 0 ? -1 : 31 - int(bits.count_leading_zeros(m))}

@(private)
bit_count :: proc(m: u32) -> int {return int(bits.count_ones(m))}

// Radiance RGBE (.hdr) to linear RGBA f32, alpha 1, rows top-down, as
// stb_image's stbi_loadf reads it (the suite's reference): the "#?RADIANCE"
// or "#?RGBE" signature, FORMAT=32-bit_rle_rgbe, the standard
// "-Y height +X width" orientation, and flat or RLE scanlines. A sample is
// its mantissa times 2^(exponent - 136), which f32 holds exactly. XYZE and
// the other orientations are refused, as stb refuses them.
package hdr

Error :: enum {
	None,
	Unsupported, // XYZE, no FORMAT line, an orientation other than -Y +X
	Invalid,     // malformed or truncated
}

Info :: struct {
	width, height: int,
}

// The image's size and where its scanlines start.
@(private)
Header :: struct {
	using info: Info,
	offset:     int,
}

info :: proc(data: []u8) -> (i: Info, err: Error) {
	h := parse(data) or_return
	return h.info, .None
}

// Decodes into `pixels`, width * height * 4 floats the caller owns (sized
// from info).
decode_into :: proc(data: []u8, pixels: []f32) -> Error {
	h := parse(data) or_return
	w := h.width
	if len(pixels) < w * h.height * 4 do return .Invalid
	// 2^(e - 136) from its bits: normal from 2^-126 (e = 10) up, subnormal
	// below; exponent 0 is black.
	scale: [256]f32
	for e in 1 ..< 256 do scale[e] = transmute(f32)(e >= 10 ? u32(e - 9) << 23 : u32(1) << u32(e + 13))
	src := data[h.offset:]
	at := 0
	for y in 0 ..< h.height {
		row := ([^][4]f32)(raw_data(pixels))[y * w:][:w]
		// A scanline is RLE when it starts 2, 2 and its width (only widths
		// 8 to 32767 can be); otherwise its RGBE pixels are stored as they are.
		if w >= 8 && w < 32768 && at + 4 <= len(src) && src[at] == 2 && src[at + 1] == 2 && src[at + 2] & 0x80 == 0 {
			if int(src[at + 2]) << 8 | int(src[at + 3]) != w do return .Invalid
			at += 4
			// The four channels one after another, expanded into the last
			// quarter of the row's own floats; convert's front-to-back writes
			// stay behind its reads.
			rgbe := ([^][4]u8)(raw_data(row))[w * 3:][:w]
			for k in 0 ..< 4 {
				for i := 0; i < w; {
					if at >= len(src) do return .Invalid
					count := int(src[at])
					at += 1
					if count > 128 {
						count -= 128
						if count > w - i || at >= len(src) do return .Invalid
						for &p in rgbe[i:][:count] do p[k] = src[at]
						at += 1
					} else {
						if count > w - i || count > len(src) - at do return .Invalid
						for &p, c in rgbe[i:][:count] do p[k] = src[at + c]
						at += count
					}
					i += count
				}
			}
			convert(row, rgbe, &scale)
		} else {
			if w * 4 > len(src) - at do return .Invalid
			convert(row, ([^][4]u8)(raw_data(src[at:]))[:w], &scale)
			at += w * 4
		}
	}
	return .None
}

// RGBE to RGBA: each mantissa times its pixel's scale, alpha 1. The RGBE
// may lie in `row`'s memory past the pixel being written.
@(private)
convert :: proc "contextless" (row: [][4]f32, rgbe: [][4]u8, scale: ^[256]f32) #no_bounds_check {
	for &p, i in row {
		c := rgbe[i]
		f := scale[c[3]]
		p = {f32(c[0]) * f, f32(c[1]) * f, f32(c[2]) * f, 1}
	}
}

@(private)
parse :: proc(data: []u8) -> (h: Header, err: Error) {
	pos := 0
	// The next line without its '\n'; ok is false at the end of the data.
	line :: proc(data: []u8, pos: ^int) -> (s: string, ok: bool) {
		start := pos^
		for pos^ < len(data) && data[pos^] != '\n' do pos^ += 1
		if pos^ == len(data) do return "", false
		pos^ += 1
		return string(data[start:pos^ - 1]), true
	}
	// Decimal digits at s[at^:], or -1 when there are none or too many.
	number :: proc(s: string, at: ^int) -> int {
		n, start := 0, at^
		for at^ < len(s) && s[at^] >= '0' && s[at^] <= '9' && at^ - start < 9 {
			n = n * 10 + int(s[at^] - '0')
			at^ += 1
		}
		return at^ > start && (at^ == len(s) || s[at^] < '0' || s[at^] > '9') ? n : -1
	}
	signature, ok := line(data, &pos)
	if !ok || signature != "#?RADIANCE" && signature != "#?RGBE" do return h, .Invalid
	rgbe := false
	for {
		s, more := line(data, &pos)
		if !more do return h, .Invalid
		if s == "" do break
		if s == "FORMAT=32-bit_rle_rgbe" do rgbe = true
	}
	if !rgbe do return h, .Unsupported
	size, more := line(data, &pos)
	if !more do return h, .Invalid
	at := 3
	if len(size) < 3 || size[:3] != "-Y " do return h, .Unsupported
	h.height = number(size, &at)
	for at < len(size) && size[at] == ' ' do at += 1
	if len(size) - at < 3 || size[at:][:3] != "+X " do return h, .Unsupported
	at += 3
	h.width = number(size, &at)
	if h.width <= 0 || h.height <= 0 || h.width > 1 << 24 || h.height > 1 << 24 do return h, .Invalid
	h.offset = pos
	// The fewest bytes a row can take: two per run of up to 127 in each
	// channel after the 4-byte start, or its pixels stored flat. A file too
	// short for its size is refused before anything is sized from it.
	min_row := h.width >= 8 && h.width < 32768 ? 4 + 8 * ((h.width + 126) / 127) : 4 * h.width
	if (len(data) - pos) / min_row < h.height do return h, .Invalid
	return h, .None
}

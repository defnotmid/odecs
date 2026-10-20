// GIF87a/89a to RGBA8. The stream is parsed once into frame records (the
// rectangle, the colour table, the graphic control extension, where the
// LZW data starts), so decoding a frame is: LZW codes to colour indices in
// display rows (interlace undone), then indices to pixels on a canvas.
//
// decode returns the first frame as stb_image gives it, the suite's
// reference: on a transparent canvas, with the logical screen's background
// colour (opaque) where the first frame does not reach when the background
// index is above zero, and a pixel drawn only where its colour is opaque.
// The animation (animation.odin) is composited as browsers show it.
package gif

import "core:slice"

Error :: enum {
	None,
	Unsupported, // not a GIF
	Invalid,     // malformed or truncated
	Out_Of_Memory,
}

Features :: struct {
	width, height: int, // the logical screen
	has_alpha:     bool, // some frame has a transparent colour
	animated:      bool,
	frame_count:   int,
	loop_count:    int, // NETSCAPE2.0 repetitions, 0: forever (and when absent)
}

Image :: struct {
	width, height: int,
	pixels:        []u8, // RGBA8, straight alpha, top-down
}

Disposal :: enum u8 {
	Keep, // 0 and 1: leave the frame in place
	Background, // 2: clear its rectangle
	Previous, // 3: restore what was under it
}

// One image of the stream, found by the parse.
@(private)
Frame_Record :: struct {
	x, y, width, height: int,
	interlaced:          bool,
	palette:             []u8, // the colour table, 3 bytes per entry, inside the file data
	transparent:         int, // colour index, -1: none
	disposal:            Disposal,
	delay:               int, // milliseconds
	raster:              int, // offset of the LZW minimum code size byte
}

@(private)
Parse :: struct {
	using features: Features,
	global:         []u8, // the global colour table, 3 bytes per entry
	background:     int, // the logical screen's background colour index
	frames:         [dynamic]Frame_Record,
}

get_features :: proc(data: []u8) -> (ft: Features, err: Error) {
	p := parse(data, context.temp_allocator) or_return
	defer delete(p.frames)
	return p.features, .None
}

@(private)
parse :: proc(data: []u8, allocator := context.allocator) -> (p: Parse, err: Error) {
	if len(data) < 13 || string(data[:4]) != "GIF8" || data[4] != '7' && data[4] != '9' || data[5] != 'a' do return p, .Unsupported
	p.frames.allocator = allocator
	defer if err != .None do delete(p.frames)
	u16_at :: #force_inline proc(d: []u8, at: int) -> int {return int(d[at]) | int(d[at + 1]) << 8}
	p.width, p.height = u16_at(data, 6), u16_at(data, 8)
	flags := data[10]
	p.background = int(data[11])
	at := 13
	if flags & 0x80 != 0 {
		n := 3 << (flags & 7 + 1)
		if at + n > len(data) do return p, .Invalid
		p.global = data[at:][:n]
		at += n
	}
	if p.width == 0 || p.height == 0 || p.width > 1 << 14 || p.height > 1 << 14 do return p, .Invalid
	gce := Frame_Record{transparent = -1}
	for {
		if at >= len(data) do return p, .Invalid
		tag := data[at]
		at += 1
		switch tag {
		case 0x2C: // image descriptor
			if at + 9 > len(data) do return p, .Invalid
			f := gce
			f.x, f.y, f.width, f.height = u16_at(data, at), u16_at(data, at + 2), u16_at(data, at + 4), u16_at(data, at + 6)
			local := data[at + 8]
			at += 9
			if f.x + f.width > p.width || f.y + f.height > p.height do return p, .Invalid
			f.interlaced = local & 0x40 != 0
			if local & 0x80 != 0 {
				n := 3 << (local & 7 + 1)
				if at + n > len(data) do return p, .Invalid
				f.palette = data[at:][:n]
				at += n
			} else if p.global != nil {
				f.palette = p.global
			} else {
				return p, .Invalid
			}
			if f.transparent >= 0 do p.has_alpha = true
			f.raster = at
			at += 1 // minimum code size
			at = skip_sub_blocks(data, at) or_return
			append(&p.frames, f)
			gce = {transparent = -1}
		case 0x21: // extension
			if at >= len(data) do return p, .Invalid
			label := data[at]
			at += 1
			if label == 0xF9 && at + 6 <= len(data) && data[at] == 4 {
				packed := data[at + 1]
				gce.delay = 10 * u16_at(data, at + 2)
				gce.transparent = packed & 1 != 0 ? int(data[at + 4]) : -1
				switch packed >> 2 & 7 {
				case 2:
					gce.disposal = .Background
				case 3:
					gce.disposal = .Previous
				case:
					gce.disposal = .Keep
				}
			} else if label == 0xFF && at + 16 <= len(data) && data[at] == 11 && string(data[at + 1:][:11]) == "NETSCAPE2.0" && data[at + 12] == 3 && data[at + 13] == 1 {
				p.loop_count = u16_at(data, at + 14)
			}
			at = skip_sub_blocks(data, at) or_return
		case 0x3B: // trailer
			if len(p.frames) == 0 do return p, .Invalid
			p.frame_count = len(p.frames)
			p.animated = p.frame_count > 1
			return p, .None
		case:
			// Data after the last image that is not a block ends the stream.
			if len(p.frames) == 0 do return p, .Invalid
			p.frame_count = len(p.frames)
			p.animated = p.frame_count > 1
			return p, .None
		}
	}
}

@(private)
skip_sub_blocks :: proc(data: []u8, start: int) -> (at: int, err: Error) {
	at = start
	for {
		if at >= len(data) do return at, .Invalid
		n := int(data[at])
		at += 1 + n
		if n == 0 do return at, .None
	}
}

// The first frame, as stb_image decodes it.
decode :: proc(data: []u8, allocator := context.allocator) -> (img: Image, err: Error) {
	p := parse(data, context.temp_allocator) or_return
	defer delete(p.frames)
	f := &p.frames[0]
	indices, ierr := make([]u8, f.width * f.height, context.temp_allocator)
	if ierr != nil do return img, .Out_Of_Memory
	defer delete(indices, context.temp_allocator)
	decode_raster(data, f, indices) or_return
	pixels, perr := make([]u8, p.width * p.height * 4, allocator)
	if perr != nil do return img, .Out_Of_Memory
	img = {p.width, p.height, pixels}
	// As stb: where the first frame does not reach, the background colour (black
	// without a global table), opaque. stb swaps its red and blue there; this
	// writes the colour as the table gives it.
	if p.background > 0 && (f.width < p.width || f.height < p.height) {
		c := [4]u8{0, 0, 0, 255}
		if p.background * 3 + 3 <= len(p.global) do c.rgb = {p.global[p.background * 3], p.global[p.background * 3 + 1], p.global[p.background * 3 + 2]}
		canvas := slice.reinterpret([][4]u8, pixels)
		for y in 0 ..< p.height {
			row := canvas[y * p.width:][:p.width]
			if y < f.y || y >= f.y + f.height {
				slice.fill(row, c)
			} else {
				slice.fill(row[:f.x], c)
				slice.fill(row[f.x + f.width:], c)
			}
		}
	}
	draw(pixels, p.width, f, indices)
	return img, .None
}

destroy_image :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.pixels, allocator)
	img^ = {}
}

// Draws a frame's indices onto an RGBA canvas `canvas_width` wide, a pixel
// only where its colour is opaque.
@(private)
draw :: proc(canvas: []u8, canvas_width: int, f: ^Frame_Record, indices: []u8) #no_bounds_check {
	// The frame's colours as RGBA, alpha 0 where nothing is drawn: the
	// transparent index and indices past the table.
	colours: [256][4]u8
	for i in 0 ..< len(f.palette) / 3 do colours[i] = {f.palette[i * 3], f.palette[i * 3 + 1], f.palette[i * 3 + 2], 255}
	if f.transparent >= 0 do colours[f.transparent].a = 0
	pixels := slice.reinterpret([][4]u8, canvas)
	for y in 0 ..< f.height {
		dst := pixels[(f.y + y) * canvas_width + f.x:][:f.width]
		for v, i in indices[y * f.width:][:f.width] {
			c := colours[v]
			if c.a != 0 do dst[i] = c
		}
	}
}

// The frame's colour indices, in display row order: an interlaced frame's
// rows come in four passes, decoded in that order and then put in place.
@(private)
decode_raster :: proc(data: []u8, f: ^Frame_Record, indices: []u8) -> Error {
	if !f.interlaced do return decode_lzw(data, f.raster, indices[:f.width * f.height])
	stream, err := make([]u8, f.width * f.height, context.temp_allocator)
	if err != nil do return .Out_Of_Memory
	defer delete(stream, context.temp_allocator)
	decode_lzw(data, f.raster, stream) or_return
	@(static, rodata) starts := [4]int{0, 4, 2, 1}
	@(static, rodata) steps := [4]int{8, 8, 4, 2}
	y := 0
	for pass in 0 ..< 4 do for row := starts[pass]; row < f.height; row += steps[pass] {
		copy(indices[row * f.width:][:f.width], stream[y * f.width:][:f.width])
		y += 1
	}
	return .None
}

// LZW codes (variable width, LSB first, in sub-blocks) to `out`, in stream
// order. A table entry is the previous code's string plus the first byte of
// the next, and those bytes already lie together in the output: so an entry
// is where they start and how many there are, and decoding a code copies
// from earlier output, as LZ77 does. What runs past `out` is dropped.
@(private)
decode_lzw :: proc(data: []u8, raster: int, out: []u8) -> Error #no_bounds_check {
	if raster >= len(data) do return .Invalid
	min_size := int(data[raster])
	if min_size < 1 || min_size > 11 do return .Invalid
	MAX :: 4096
	start: [MAX]int
	length: [MAX]int
	clear := 1 << uint(min_size)
	size := min_size + 1
	next := clear + 2
	old := -1
	old_start := 0 // where the previous code's string was written
	started := false
	written := 0
	bits, count: u32
	at := raster + 1
	block := 0
	for {
		for count < u32(size) {
			if block == 0 {
				if at >= len(data) do return .Invalid
				block = int(data[at])
				at += 1
				if block == 0 do return .None // the data ended without an end code
			}
			if at >= len(data) do return .Invalid
			bits |= u32(data[at]) << count
			count += 8
			at += 1
			block -= 1
		}
		code := int(bits & (1 << uint(size) - 1))
		bits >>= uint(size)
		count -= u32(size)
		switch {
		case code == clear:
			size, next, old, started = min_size + 1, clear + 2, -1, true
			continue
		case code == clear + 1:
			return .None
		case !started:
			return .Invalid // stb requires a clear code first
		case code > next:
			return .Invalid
		}
		if old >= 0 && next < MAX {
			start[next] = old_start
			length[next] = (old < clear ? 1 : length[old]) + 1
			next += 1
		} else if code == next {
			return .Invalid
		}
		n := 1
		room := len(out) - written
		if code < clear {
			if room > 0 do out[written] = u8(code)
		} else {
			n = length[code]
			// Forward, byte by byte: a code made just now (code == next - 1)
			// overlaps the bytes it writes.
			from := start[code]
			for k in 0 ..< min(n, room) do out[written + k] = out[from + k]
		}
		old, old_start = code, written
		written += n
		if next & (1 << uint(size) - 1) == 0 && next < MAX do size += 1
	}
}

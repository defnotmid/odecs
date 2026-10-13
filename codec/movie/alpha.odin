package movie

// How colour is stored beside an alpha channel in the video.
Transparency :: enum u8 {
	// No alpha in the video: pixels are composited over the background.
	None,
	// Colour premultiplied by alpha (HEVC alpha_channel_use_idc 1, what
	// Apple's encoder writes): the picture composited over black.
	Premultiplied,
	// Straight colour (alpha_channel_use_idc 0; the only form VP9 alpha in
	// WebM has). Colour where alpha is low is smoothed toward its
	// surroundings without changing the visible picture (see
	// straighten), so 4:2:0 chroma and lossy coding leave no fringes and
	// hidden colour costs few bits.
	Straight,
}

// Premultiplied RGBA in 0..255, the shape every stage of the straight-alpha
// conversion works on.
@(private)
Pixel :: [4]f32

// Images of the straight-alpha conversion, kept between frames, tight rows.
Alpha_Scratch :: struct {
	straight: []u8, // straight colour and alpha, for chroma weighted by alpha
	levels:   [FILL_LEVELS][]Pixel, // level 0 is the frame, each next half the previous
	work:     []Pixel, // full size: pulled levels, then the guide
}

// Levels of the smoothing pyramid: colour spreads about 2^FILL_LEVELS
// pixels from visible content and is black beyond, so content moving over
// a still background changes only the colour near it.
FILL_LEVELS :: 5

destroy_alpha_scratch :: proc(s: ^Alpha_Scratch) {
	delete(s.straight)
	delete(s.work)
	for l in s.levels do delete(l)
	s^ = {}
}

// Converts width x height RGBA8 (even sizes) to 8-bit 4:2:0 colour planes
// and a full-range alpha plane, storing colour as `stored` says. `input`
// says how the RGBA colour relates to its alpha (Straight or
// Premultiplied).
rgba_to_i420a :: proc(
	src: []u8,
	src_stride: int,
	width, height: int,
	planes: [3][]u8,
	strides: [3]int,
	alpha: []u8,
	alpha_stride: int,
	c: ^Rgb_To_Yuv,
	input: Alpha,
	stored: Transparency,
	scratch: ^Alpha_Scratch,
) {
	assert(input != .Opaque && stored != .None)
	for y in 0 ..< height {
		s := src[y * src_stride:][:width * 4]
		for &v, x in alpha[y * alpha_stride:][:width] do v = s[x * 4 + 3]
	}
	if stored == .Premultiplied {
		rgba_to_i420(src, src_stride, width, height, planes, strides, c, input, {})
		return
	}
	straighten(src, src_stride, width, height, input, scratch)
	rgba_to_i420_rows(scratch.straight, width * 4, width, height, planes, strides, c, {}, .Opaque, true)
}

// Straight colour for coding, in scratch.straight. A pixel with alpha a and
// premultiplied value p shows the same for any straight value c with
// c * a / 255 within half a step of p: an interval about 255 / a wide, the
// whole range at a = 0. Each pixel takes the value in its interval nearest
// a guide colour from its surroundings, so opaque pixels stay exact,
// transparent ones take the guide, and faint ones lose the noise of
// dividing small premultiplied values. The guide is a push-pull pyramid:
// each level averages 2x2 pixels of the one below (premultiplied, so alpha
// weights colour), then from the top down each level is laid over the one
// above it, upsampled, filling what it does not cover.
@(private)
straighten :: proc(src: []u8, src_stride: int, width, height: int, input: Alpha, scratch: ^Alpha_Scratch) {
	size: [FILL_LEVELS][2]int
	for &s, k in size do s = k == 0 ? {width, height} : (size[k - 1] + 1) / 2
	for &l, k in scratch.levels do resize_image(&l, size[k])
	resize_image(&scratch.work, size[0])
	resize_image(&scratch.straight, size[0] * {4, 1})

	frame := scratch.levels[0]
	for y in 0 ..< height {
		s := src[y * src_stride:][:width * 4]
		for &p, x in frame[y * width:][:width] {
			p = {f32(s[x * 4]), f32(s[x * 4 + 1]), f32(s[x * 4 + 2]), f32(s[x * 4 + 3])}
			if input == .Straight do p.rgb *= p.a / 255
		}
	}
	for k in 1 ..< FILL_LEVELS do downsample(scratch.levels[k - 1], size[k - 1], scratch.levels[k])
	for k := FILL_LEVELS - 2; k >= 1; k -= 1 {
		upsample(scratch.levels[k + 1], size[k], scratch.work)
		lay_over(scratch.levels[k], scratch.work)
	}
	upsample(scratch.levels[1], size[0], scratch.work)

	for y in 0 ..< height {
		s := src[y * src_stride:][:width * 4]
		out := scratch.straight[y * width * 4:][:width * 4]
		for guide, x in scratch.work[y * width:][:width] {
			a := u32(s[x * 4 + 3])
			for ch in 0 ..< 3 {
				p := u32(s[x * 4 + ch])
				if input == .Straight do p = div255(p * a)
				out[x * 4 + ch] = u8(nearest_straight(p, a, u32(clamp(guide[ch] + 0.5, 0, 255))))
			}
			out[x * 4 + 3] = u8(a)
		}
	}
}

@(private)
resize_image :: proc(img: ^[]$T, size: [2]int) {
	if len(img) == size.x * size.y do return
	delete(img^)
	img^ = make([]T, size.x * size.y)
}

// The straight value nearest `target` that a shows as premultiplied p.
@(private)
nearest_straight :: #force_inline proc "contextless" (p, a, target: u32) -> u32 {
	if a == 255 do return p
	if a == 0 do return target
	lo := p == 0 ? 0 : min(((2 * p - 1) * 255 + 2 * a - 1) / (2 * a), 255)
	hi := clamp(((2 * p + 1) * 255 + 2 * a - 1) / (2 * a) - 1, lo, 255)
	return clamp(target, lo, hi)
}

// Halves an image: each pixel is the alpha-weighted mean colour of up to 2x2
// pixels with their summed coverage, capped at opaque, so one visible pixel
// covers its parent and colour stays local.
@(private)
downsample :: proc(src: []Pixel, size: [2]int, dst: []Pixel) #no_bounds_check {
	half := (size + 1) / 2
	for y in 0 ..< half.y {
		r0, r1 := 2 * y * size.x, min(2 * y + 1, size.y - 1) * size.x
		for x in 0 ..< half.x {
			c0, c1 := 2 * x, min(2 * x + 1, size.x - 1)
			sum := src[r0 + c0] + src[r0 + c1] + src[r1 + c0] + src[r1 + c1]
			dst[y * half.x + x] = sum * min(1, 255 / max(sum.a, 1e-6))
		}
	}
}

// Doubles an image to `size` bilinearly into dst: each pixel weighs the
// four nearest source pixels 9, 3, 3 and 1 of 16.
@(private)
upsample :: proc(src: []Pixel, size: [2]int, dst: []Pixel) #no_bounds_check {
	half := (size + 1) / 2
	// Along an axis: the source pixel under n and its neighbour toward n.
	near :: #force_inline proc "contextless" (n, count: int) -> [2]int {
		return {n / 2, clamp(n / 2 + (n % 2 == 0 ? -1 : 1), 0, count - 1)}
	}
	for y in 0 ..< size.y {
		rows := near(y, half.y) * half.x
		for x in 0 ..< size.x {
			cols := near(x, half.x)
			dst[y * size.x + x] =
				(9 * src[rows[0] + cols[0]] + 3 * src[rows[0] + cols[1]] + 3 * src[rows[1] + cols[0]] + src[rows[1] + cols[1]]) / 16
		}
	}
}

// Lays img over `under` (at least img's size), in place in img: under shows
// through what img leaves uncovered.
@(private)
lay_over :: proc(img, under: []Pixel) #no_bounds_check {
	for &p, i in img do p += under[i] * (1 - p.a / 255)
}

@(private)
unpremultiply :: #force_inline proc "contextless" (c, a: u32) -> u32 {
	return a == 0 ? 0 : min((c * 255 + a / 2) / a, 255)
}

// Straight colour from premultiplied RGBA8 rows, in place. Transparent
// pixels keep zero colour.
unpremultiply_rgba :: proc(rgba: []u8) #no_bounds_check {
	for i := 0; i < len(rgba); i += 4 {
		a := u32(rgba[i + 3])
		if a == 255 do continue
		for ch in 0 ..< 3 do rgba[i + ch] = u8(unpremultiply(u32(rgba[i + ch]), a))
	}
}

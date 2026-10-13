package movie

import "base:intrinsics"
import "core:math"
import "core:simd"

// RGB <-> Y'CbCr with the BT.601/709/2020 non-constant-luminance matrices, in
// Q16 fixed point. Conversion happens on gamma-encoded (sRGB/BT.709 transfer)
// values, as players do; there is no transfer-function conversion.
Matrix :: enum u8 {
	BT601,
	BT709,
	BT2020,
}

// How the alpha channel of RGBA input is folded into opaque video.
Alpha :: enum u8 {
	Straight,      // non-premultiplied: composite over the background
	Premultiplied, // premultiplied: add the background under the remaining coverage
	Opaque,        // ignore alpha
}

Rgb_To_Yuv :: struct {
	y, u, v:       [3]i32, // R, G, B weights
	y_bias:        i32, // luma offset and rounding, Q16
	c_bias:        i32, // chroma offset and rounding for a 2x2 sum, Q18
	c_max:         i32,
}

Yuv_To_Rgb :: struct {
	y, rv, gu, gv, bu: i32, // Q16 weights in sample units
	y_offset:          i32,
	c_offset:          i32,
}

@(private)
matrix_weights :: proc(m: Matrix) -> (kr, kb: f64) {
	switch m {
	case .BT601:
		return 0.299, 0.114
	case .BT709:
		return 0.2126, 0.0722
	case .BT2020:
		return 0.2627, 0.0593
	}
	return 0.2126, 0.0722
}

@(private)
q16 :: proc(v: f64) -> i32 {return i32(math.round(v * 65536))}

// Weights for 8-bit 4:2:0 output. Each row of weights is balanced so that
// white maps exactly to peak luma and greys to neutral chroma.
rgb_to_yuv_coefficients :: proc(m: Matrix, full_range: bool) -> (c: Rgb_To_Yuv) {
	kr, kb := matrix_weights(m)
	ys := (full_range ? 255.0 : 219.0) / 255
	cs := (full_range ? 255.0 : 224.0) / 255
	total := q16(ys)
	c.y = {q16(kr * ys), 0, q16(kb * ys)}
	c.y[1] = total - c.y[0] - c.y[2]
	cb := cs / (2 * (1 - kb))
	cr := cs / (2 * (1 - kr))
	c.u = {q16(-kr * cb), 0, q16((1 - kb) * cb)}
	c.u[1] = -c.u[0] - c.u[2]
	c.v = {q16((1 - kr) * cr), 0, q16(-kb * cr)}
	c.v[1] = -c.v[0] - c.v[2]
	c.y_bias = (full_range ? 0 : 16 << 16) + (1 << 15)
	c.c_bias = (128 << 18) + (1 << 17)
	c.c_max = 255
	return
}

// Weights for samples of the given bit depth into 8-bit RGB.
yuv_to_rgb_coefficients :: proc(m: Matrix, full_range: bool, bit_depth: int) -> (c: Yuv_To_Rgb) {
	kr, kb := matrix_weights(m)
	kg := 1 - kr - kb
	scale := f64(int(1) << uint(bit_depth - 8))
	ys := (full_range ? 255.0 : 219.0) * scale
	cs := (full_range ? 255.0 : 224.0) * scale
	c.y = q16(255 / ys)
	c.rv = q16(255 * 2 * (1 - kr) / cs)
	c.bu = q16(255 * 2 * (1 - kb) / cs)
	c.gu = q16(-255 * 2 * kb * (1 - kb) / kg / cs)
	c.gv = q16(-255 * 2 * kr * (1 - kr) / kg / cs)
	c.y_offset = full_range ? 0 : i32(16 * scale)
	c.c_offset = i32(128 * scale)
	return
}

@(private)
div255 :: #force_inline proc "contextless" (x: u32) -> u32 {
	return (x + 128 + ((x + 128) >> 8)) >> 8
}

// Converts width x height RGBA8 (even sizes) to 8-bit 4:2:0 planes. Chroma is
// the average of each 2x2 block, centred between its luma samples.
rgba_to_i420 :: proc(
	src: []u8,
	src_stride: int,
	width, height: int,
	planes: [3][]u8,
	strides: [3]int,
	c: ^Rgb_To_Yuv,
	alpha: Alpha,
	background: [3]u8,
) {
	switch alpha {
	case .Straight:
		rgba_to_i420_rows(src, src_stride, width, height, planes, strides, c, background, .Straight, false)
	case .Premultiplied:
		rgba_to_i420_rows(src, src_stride, width, height, planes, strides, c, background, .Premultiplied, false)
	case .Opaque:
		rgba_to_i420_rows(src, src_stride, width, height, planes, strides, c, background, .Opaque, false)
	}
}

@(private)
composite :: #force_inline proc "contextless" (v, a, bg: u32, $alpha: Alpha) -> u32 {
	when alpha == .Straight {
		return div255(v * a + bg * (255 - a))
	} else when alpha == .Premultiplied {
		return min(v + div255(bg * (255 - a)), 255)
	} else {
		return v
	}
}

// Columns per pass. Each pass first converts both rows to luma plus planar
// composited R, G and B (unit-stride loops over pixels), then forms chroma
// from the planar 2x2 sums; both loops vectorize. `weighted` keeps colour
// uncomposited and weights each pixel's share of chroma by 4 * alpha + 1:
// the alpha-weighted mean for video that keeps its alpha, and the plain mean
// where all four pixels are transparent.
@(private)
CHUNK :: 256

@(private)
rgba_to_i420_rows :: proc(
	src: []u8,
	src_stride: int,
	width, height: int,
	planes: [3][]u8,
	strides: [3]int,
	c: ^Rgb_To_Yuv,
	background: [3]u8,
	$alpha: Alpha,
	$weighted: bool,
) #no_bounds_check {
	yr, yg, yb := c.y[0], c.y[1], c.y[2]
	ur, ug, ub := c.u[0], c.u[1], c.u[2]
	vr, vg, vb := c.v[0], c.v[1], c.v[2]
	y_bias, c_bias, c_max := c.y_bias, c.c_bias, c.c_max
	bgr, bgg, bgb := u32(background[0]), u32(background[1]), u32(background[2])
	assert(width % 2 == 0 && height % 2 == 0)
	assert(len(src) >= (height - 1) * src_stride + width * 4)
	assert(len(planes[0]) >= (height - 1) * strides[0] + width)
	assert(len(planes[1]) >= (height / 2 - 1) * strides[1] + width / 2)
	assert(len(planes[2]) >= (height / 2 - 1) * strides[2] + width / 2)
	rgbw: [2][4][CHUNK]i32 // R, G, B and the chroma weight, planar
	for row := 0; row < height; row += 2 {
		for x0 := 0; x0 < width; x0 += CHUNK {
			n := min(CHUNK, width - x0)
			for k in 0 ..< 2 {
				s := ([^]u8)(raw_data(src[(row + k) * src_stride + x0 * 4:]))
				l := ([^]u8)(raw_data(planes[0][(row + k) * strides[0] + x0:]))
				pr, pg, pb := &rgbw[k][0], &rgbw[k][1], &rgbw[k][2]
				for i in 0 ..< n {
					a := u32(s[i * 4 + 3])
					r := i32(composite(u32(s[i * 4]), a, bgr, alpha))
					g := i32(composite(u32(s[i * 4 + 1]), a, bgg, alpha))
					b := i32(composite(u32(s[i * 4 + 2]), a, bgb, alpha))
					l[i] = u8((yr * r + yg * g + yb * b + y_bias) >> 16)
					when weighted {
						w := 4 * i32(a) + 1
						pr[i], pg[i], pb[i], rgbw[k][3][i] = r * w, g * w, b * w, w
					} else {
						pr[i], pg[i], pb[i] = r, g, b
					}
				}
			}
			cu := ([^]u8)(raw_data(planes[1][(row / 2) * strides[1] + x0 / 2:]))
			cv := ([^]u8)(raw_data(planes[2][(row / 2) * strides[2] + x0 / 2:]))
			for j in 0 ..< n / 2 {
				sum :: #force_inline proc(p: ^[2][4][CHUNK]i32, ch, j: int) -> i32 {
					return p[0][ch][2 * j] + p[0][ch][2 * j + 1] + p[1][ch][2 * j] + p[1][ch][2 * j + 1]
				}
				rs, gs, bs := sum(&rgbw, 0, j), sum(&rgbw, 1, j), sum(&rgbw, 2, j)
				when weighted {
					// Back to a sum of four samples, as the unweighted path forms.
					ws := sum(&rgbw, 3, j)
					rs, gs, bs = (4 * rs + ws / 2) / ws, (4 * gs + ws / 2) / ws, (4 * bs + ws / 2) / ws
				}
				cu[j] = u8(clamp((ur * rs + ug * gs + ub * bs + c_bias) >> 18, 0, c_max))
				cv[j] = u8(clamp((vr * rs + vg * gs + vb * bs + c_bias) >> 18, 0, c_max))
			}
		}
	}
}

// Converts planar Y'CbCr (8- or 16-bit storage, any subsampling given as
// shifts; monochrome when chroma planes are empty) to RGBA8 with alpha 255.
// Chroma is replicated over the luma samples it covers.
yuv_to_rgba :: proc(
	planes: [3][]u8,
	strides: [3]int, // bytes
	width, height: int,
	storage_bits: int,
	shift_x, shift_y: uint,
	c: ^Yuv_To_Rgb,
	dst: []u8,
	dst_stride: int,
	alpha := Alpha_Plane{},
	bit_depth := 8, // of the alpha samples
) {
	mono := len(planes[1]) == 0
	a := alpha_scale(alpha, bit_depth)
	if !mono && shift_x == 0 && shift_y == 0 {
		if storage_bits == 8 {
			yuv444_to_rgba(planes, strides, width, height, c, dst, dst_stride, &a, u8)
		} else {
			yuv444_to_rgba(planes, strides, width, height, c, dst, dst_stride, &a, u16)
		}
		return
	}
	if storage_bits == 8 {
		if !mono && shift_x == 1 {
			yuv_to_rgba_rows(planes, strides, width, height, shift_y, c, dst, dst_stride, a, u8)
		} else {
			yuv_to_rgba_generic(planes, strides, width, height, shift_x, shift_y, mono, c, dst, dst_stride, a, u8)
		}
	} else {
		if !mono && shift_x == 1 {
			yuv_to_rgba_rows(planes, strides, width, height, shift_y, c, dst, dst_stride, a, u16)
		} else {
			yuv_to_rgba_generic(planes, strides, width, height, shift_x, shift_y, mono, c, dst, dst_stride, a, u16)
		}
	}
}

// Alpha for the conversion: a plane with the luma plane's size, storage and
// depth (empty for opaque video), and whether RGB is premultiplied by it.
Alpha_Plane :: struct {
	data:        []u8,
	stride:      int, // bytes
	premultiply: bool,
}

// An alpha plane with its Q16 scale from the sample depth to 8 bits, exact
// at 0 and full scale.
@(private)
Alpha_Scale :: struct {
	plane: Alpha_Plane,
	mul:         u32,
}

@(private)
alpha_scale :: proc(a: Alpha_Plane, bit_depth: int) -> Alpha_Scale {
	return {a, u32(math.round(255 * 65536 / f64(int(1) << uint(bit_depth) - 1)))}
}

// Writes alpha (and premultiplies) one converted row.
@(private)
alpha_row :: #force_inline proc(a: ^Alpha_Scale, row: int, out: [^]u32, width: int, $T: typeid, column := 0) #no_bounds_check {
	if len(a.plane.data) == 0 do return
	src := ([^]T)(raw_data(a.plane.data[row * a.plane.stride + column * size_of(T):]))
	for x in 0 ..< width {
		alpha := (u32(src[x]) * a.mul + 1 << 15) >> 16
		px := out[x]
		if a.plane.premultiply {
			r := div255((px & 0xFF) * alpha)
			g := div255((px >> 8 & 0xFF) * alpha)
			b := div255((px >> 16 & 0xFF) * alpha)
			px = r | g << 8 | b << 16
		}
		out[x] = px & 0xFFFFFF | alpha << 24
	}
}

// Full-resolution chroma, eight pixels per step: each lane converts one
// pixel, writes alpha and premultiplies with the scalar path's arithmetic.
@(private)
yuv444_to_rgba :: proc(planes: [3][]u8, strides: [3]int, width, height: int, c: ^Yuv_To_Rgb, dst: []u8, dst_stride: int, a: ^Alpha_Scale, $T: typeid) #no_bounds_check {
	V :: #simd[8]i32
	U :: #simd[8]u32
	load :: #force_inline proc(p: [^]T) -> V {return V(intrinsics.unaligned_load((^#simd[8]T)(p)))}
	channel :: #force_inline proc(y, w: V) -> U {return U(simd.clamp(simd.shr(y + w, U(16)), V(0), V(255)))}
	div :: #force_inline proc(x: U) -> U {return simd.shr(x + 128 + simd.shr(x + 128, U(8)), U(8))} // div255
	ky, krv, kgu, kgv, kbu := V(c.y), V(c.rv), V(c.gu), V(c.gv), V(c.bu)
	yo, co := V(c.y_offset), V(c.c_offset)
	has_alpha := len(a.plane.data) > 0
	for row in 0 ..< height {
		ys := ([^]T)(raw_data(planes[0][row * strides[0]:]))
		us := ([^]T)(raw_data(planes[1][row * strides[1]:]))
		vs := ([^]T)(raw_data(planes[2][row * strides[2]:]))
		as: [^]T
		if has_alpha do as = ([^]T)(raw_data(a.plane.data[row * a.plane.stride:]))
		out := ([^]u32)(raw_data(dst[row * dst_stride:]))
		x := 0
		for ; x + 8 <= width; x += 8 {
			u, v := load(us[x:]) - co, load(vs[x:]) - co
			y := (load(ys[x:]) - yo) * ky + (1 << 15)
			r, g, b := channel(y, krv * v), channel(y, kgu * u + kgv * v), channel(y, kbu * u)
			alpha := U(255)
			if has_alpha {
				alpha = simd.shr(U(load(as[x:])) * U(a.mul) + (1 << 15), U(16))
				if a.plane.premultiply do r, g, b = div(r * alpha), div(g * alpha), div(b * alpha)
			}
			px := r | simd.shl(g, U(8)) | simd.shl(b, U(16)) | simd.shl(alpha, U(24))
			intrinsics.unaligned_store((^U)(&out[x]), px)
		}
		for ; x < width; x += 1 {
			u, v := i32(us[x]) - c.c_offset, i32(vs[x]) - c.c_offset
			y := (i32(ys[x]) - c.y_offset) * c.y + (1 << 15)
			out[x] = pack_rgb(y, c.rv * v, c.gu * u + c.gv * v, c.bu * u)
		}
		// Alpha for the scalar tail only; the vector lanes already have it.
		if tail := width &~ 7; has_alpha && tail < width do alpha_row(a, row, out[tail:], width - tail, T, tail)
	}
}

// RGB stored as G, B, R planes (H.273 matrix 0, VP9 sRGB) to RGBA8.
gbr_to_rgba :: proc(planes: [3][]u8, strides: [3]int, width, height, storage_bits, bit_depth: int, alpha: Alpha_Plane, dst: []u8, dst_stride: int) {
	a := alpha_scale(alpha, bit_depth)
	if storage_bits == 8 {
		gbr_rows(planes, strides, width, height, &a, dst, dst_stride, u8)
	} else {
		gbr_rows(planes, strides, width, height, &a, dst, dst_stride, u16)
	}
}

@(private)
gbr_rows :: proc(planes: [3][]u8, strides: [3]int, width, height: int, a: ^Alpha_Scale, dst: []u8, dst_stride: int, $T: typeid) #no_bounds_check {
	for row in 0 ..< height {
		g := ([^]T)(raw_data(planes[0][row * strides[0]:]))
		b := ([^]T)(raw_data(planes[1][row * strides[1]:]))
		r := ([^]T)(raw_data(planes[2][row * strides[2]:]))
		out := ([^]u32)(raw_data(dst[row * dst_stride:]))
		scale :: #force_inline proc(v: T, mul: u32) -> u32 {return (u32(v) * mul + 1 << 15) >> 16}
		for x in 0 ..< width do out[x] = scale(r[x], a.mul) | scale(g[x], a.mul) << 8 | scale(b[x], a.mul) << 16 | 0xFF000000
		alpha_row(a, row, out, width, T)
	}
}

@(private)
pack_rgb :: #force_inline proc "contextless" (y, r, g, b: i32) -> u32 {
	return(
		u32(clamp((y + r) >> 16, 0, 255)) |
		u32(clamp((y + g) >> 16, 0, 255)) << 8 |
		u32(clamp((y + b) >> 16, 0, 255)) << 16 |
		0xFF000000 \
	)
}

// Horizontally subsampled chroma: one chroma sample per two output pixels.
@(private)
yuv_to_rgba_rows :: proc(
	planes: [3][]u8,
	strides: [3]int,
	width, height: int,
	shift_y: uint,
	c: ^Yuv_To_Rgb,
	dst: []u8,
	dst_stride: int,
	a: Alpha_Scale,
	$T: typeid,
) #no_bounds_check {
	a := a
	size := size_of(T)
	cw := (width + 1) / 2
	assert(len(planes[0]) >= (height - 1) * strides[0] + width * size)
	assert(len(planes[1]) >= ((height - 1) >> shift_y) * strides[1] + cw * size)
	assert(len(planes[2]) >= ((height - 1) >> shift_y) * strides[2] + cw * size)
	assert(len(dst) >= (height - 1) * dst_stride + width * 4)
	ky, krv, kgu, kgv, kbu := c.y, c.rv, c.gu, c.gv, c.bu
	yo, co := c.y_offset, c.c_offset
	for row in 0 ..< height {
		ys := ([^]T)(raw_data(planes[0][row * strides[0]:]))
		crow := row >> shift_y
		us := ([^]T)(raw_data(planes[1][crow * strides[1]:]))
		vs := ([^]T)(raw_data(planes[2][crow * strides[2]:]))
		out := ([^]u32)(raw_data(dst[row * dst_stride:]))
		pairs := width / 2
		for i in 0 ..< pairs {
			u := i32(us[i]) - co
			v := i32(vs[i]) - co
			r := krv * v
			g := kgu * u + kgv * v
			b := kbu * u
			y0 := (i32(ys[2 * i]) - yo) * ky + (1 << 15)
			y1 := (i32(ys[2 * i + 1]) - yo) * ky + (1 << 15)
			out[2 * i] = pack_rgb(y0, r, g, b)
			out[2 * i + 1] = pack_rgb(y1, r, g, b)
		}
		if width & 1 == 1 {
			u := i32(us[pairs]) - co
			v := i32(vs[pairs]) - co
			y0 := (i32(ys[width - 1]) - yo) * ky + (1 << 15)
			out[width - 1] = pack_rgb(y0, krv * v, kgu * u + kgv * v, kbu * u)
		}
		alpha_row(&a, row, out, width, T)
	}
}

@(private)
yuv_to_rgba_generic :: proc(
	planes: [3][]u8,
	strides: [3]int,
	width, height: int,
	shift_x, shift_y: uint,
	mono: bool,
	c: ^Yuv_To_Rgb,
	dst: []u8,
	dst_stride: int,
	a: Alpha_Scale,
	$T: typeid,
) {
	a := a
	size := size_of(T)
	assert(len(planes[0]) >= (height - 1) * strides[0] + width * size)
	if !mono {
		cw, ch := ((width - 1) >> shift_x) + 1, ((height - 1) >> shift_y) + 1
		assert(len(planes[1]) >= (ch - 1) * strides[1] + cw * size)
		assert(len(planes[2]) >= (ch - 1) * strides[2] + cw * size)
	}
	assert(len(dst) >= (height - 1) * dst_stride + width * 4)
	ky, krv, kgu, kgv, kbu := c.y, c.rv, c.gu, c.gv, c.bu
	yo, co := c.y_offset, c.c_offset
	for row in 0 ..< height {
		ys := ([^]T)(raw_data(planes[0][row * strides[0]:]))
		us, vs: [^]T
		if !mono {
			crow := row >> shift_y
			us = ([^]T)(raw_data(planes[1][crow * strides[1]:]))
			vs = ([^]T)(raw_data(planes[2][crow * strides[2]:]))
		}
		out := ([^]u32)(raw_data(dst[row * dst_stride:]))
		for x in 0 ..< width {
			u, v: i32
			if !mono {
				u = i32(us[x >> shift_x]) - co
				v = i32(vs[x >> shift_x]) - co
			}
			y := (i32(ys[x]) - yo) * ky + (1 << 15)
			out[x] = pack_rgb(y, krv * v, kgu * u + kgv * v, kbu * u)
		}
		alpha_row(&a, row, out, width, T)
	}
}

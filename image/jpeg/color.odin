package jpeg

import "base:intrinsics"
import "core:slice"
import "core:simd"

#assert(ODIN_ENDIAN == .Little)

// Output rows, by libjpeg-turbo's rules: each component's samples for the
// row, upsampled to the image width, then converted to RGBA8. 2x ratios are
// "fancy" (a triangle filter, rounding alternately up and down); other whole
// ratios repeat samples. The resampling of each component and the colour
// conversion are chosen once for the image; each row is then flat loops.

@(private)
Resample :: enum {
	None, // full resolution
	H2_Fancy, // half width
	V2_Fancy, // half height
	HV2_Fancy, // half both
	Box, // any whole ratio, samples repeated (2x when two samples or fewer across)
}

@(private)
Colour :: enum {
	Gray,
	RGB,
	YCbCr,
	CMYK,
	YCCK,
}

// The colour space as libjpeg guesses it: from JFIF, then the Adobe
// transform, then the component IDs.
@(private)
colour_of :: proc(d: ^Decoder) -> Colour {
	switch d.features.components {
	case 1:
		return .Gray
	case 3:
		switch {
		case d.jfif:
			return .YCbCr
		case d.transform >= 0:
			return d.transform == 0 ? .RGB : .YCbCr
		case d.comps[0].id == 'R' && d.comps[1].id == 'G' && d.comps[2].id == 'B':
			return .RGB
		}
		return .YCbCr
	}
	return d.transform < 0 || d.transform == 0 ? .CMYK : .YCCK
}

@(private)
resample_of :: proc(d: ^Decoder, c: Component) -> Resample {
	hs, vs := d.h_max / c.h, d.v_max / c.v
	switch {
	case hs == 1 && vs == 1:
		return .None
	case hs == 2 && vs == 1 && c.width > 2:
		return .H2_Fancy
	case hs == 1 && vs == 2:
		return .V2_Fancy
	case hs == 2 && vs == 2 && c.width > 2:
		return .HV2_Fancy
	}
	return .Box
}

// The image rows of band m (one MCU row) to RGBA8.
@(private)
output_band :: proc(d: ^Decoder, m: int, pixels: []u8) #no_bounds_check {
	n, width := d.features.components, d.features.width
	line := width + 3
	for y in m * d.v_max * 8 ..< min((m + 1) * d.v_max * 8, d.features.height) {
		rows: [4][]u8
		for &c, k in d.comps[:n] do rows[k] = component_row(d, &c, d.resample[k], y, d.lines[k * line:][:line])[:width]
		out := slice.reinterpret([][4]u8, pixels[y * width * 4:][:width * 4])
		switch d.colour {
		case .Gray:
			for v, i in rows[0] do out[i] = {v, v, v, 255}
		case .RGB:
			for i in 0 ..< width do out[i] = {rows[0][i], rows[1][i], rows[2][i], 255}
		case .YCbCr:
			ycbcr_row(rows[0], rows[1], rows[2], out)
		case .CMYK:
			for i in 0 ..< width {
				k := rows[3][i]
				out[i] = {blinn(rows[0][i], k), blinn(rows[1][i], k), blinn(rows[2][i], k), 255}
			}
		case .YCCK:
			// YCC to the inverted CMY libjpeg gives, then as CMYK.
			ycbcr_row(rows[0], rows[1], rows[2], out)
			for &p, i in out {
				k := rows[3][i]
				p = {blinn(255 - p[0], k), blinn(255 - p[1], k), blinn(255 - p[2], k), 255}
			}
		}
	}
}

// A component's samples for output row y, at the image's resolution: its
// plane row, or `line` made from the plane rows nearest y. A fancy 2x row y
// lies between plane row y / 2 and the one above (even y) or below (odd y),
// the image's edge rows repeated. Sixteen samples at a time in 16-bit lanes,
// the first and last columns (their own rules) and the remainder one by one.
@(private)
component_row :: proc(d: ^Decoder, c: ^Component, resample: Resample, y: int, line: []u8) -> []u8 #no_bounds_check {
	vs := d.v_max / c.v
	near := y / vs
	far := near
	if resample == .V2_Fancy || resample == .HV2_Fancy do far = y & 1 == 0 ? max(near - 1, 0) : min(near + 1, c.height - 1)
	n, f := d.planes[plane_row(c, near):][:c.stride], d.planes[plane_row(c, far):][:c.stride]
	U :: #simd[16]u16
	load :: #force_inline proc "contextless" (s: []u8, at: int) -> U {
		return cast(U)intrinsics.unaligned_load((^#simd[16]u8)(&s[at]))
	}
	// Output samples 2i and 2i + 1 side by side.
	store_pairs :: #force_inline proc "contextless" (line: []u8, i: int, even, odd: U) {
		e, o := cast(#simd[16]u8)even, cast(#simd[16]u8)odd
		both := simd.shuffle(e, o, 0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23, 8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31)
		intrinsics.unaligned_store((^#simd[32]u8)(&line[2 * i]), both)
	}
	w := c.width
	switch resample {
	case .None:
		return n
	case .H2_Fancy:
		line[0] = n[0]
		line[1] = u8((3 * u32(n[0]) + u32(n[1]) + 2) >> 2)
		i := 1
		for ; i + 16 < w; i += 16 {
			this := load(n, i) * 3
			store_pairs(line, i, simd.shr(this + load(n, i - 1) + 1, 2), simd.shr(this + load(n, i + 1) + 2, 2))
		}
		for ; i < w - 1; i += 1 {
			v := 3 * u32(n[i])
			line[i * 2] = u8((v + u32(n[i - 1]) + 1) >> 2)
			line[i * 2 + 1] = u8((v + u32(n[i + 1]) + 2) >> 2)
		}
		line[w * 2 - 2] = u8((3 * u32(n[w - 1]) + u32(n[w - 2]) + 1) >> 2)
		line[w * 2 - 1] = n[w - 1]
	case .V2_Fancy:
		bias: u16 = y & 1 == 0 ? 1 : 2
		i := 0
		for ; i + 16 <= w; i += 16 {
			intrinsics.unaligned_store((^#simd[16]u8)(&line[i]), cast(#simd[16]u8)simd.shr(load(n, i) * 3 + load(f, i) + bias, 2))
		}
		for ; i < w; i += 1 do line[i] = u8((3 * u16(n[i]) + u16(f[i]) + bias) >> 2)
	case .HV2_Fancy:
		// Columns of 3 near + 1 far, then 3:1 between columns.
		column :: #force_inline proc "contextless" (n, f: []u8, i: int) -> u32 {return 3 * u32(n[i]) + u32(f[i])}
		this, next := column(n, f, 0), column(n, f, 1)
		line[0] = u8((this * 4 + 8) >> 4)
		line[1] = u8((this * 3 + next + 7) >> 4)
		i := 1
		for ; i + 16 < w; i += 16 {
			last := load(n, i - 1) * 3 + load(f, i - 1)
			mid := load(n, i) * 3 + load(f, i)
			after := load(n, i + 1) * 3 + load(f, i + 1)
			store_pairs(line, i, simd.shr(mid * 3 + last + 8, 4), simd.shr(mid * 3 + after + 7, 4))
		}
		for ; i < w - 1; i += 1 {
			mid := column(n, f, i)
			line[i * 2] = u8((mid * 3 + column(n, f, i - 1) + 8) >> 4)
			line[i * 2 + 1] = u8((mid * 3 + column(n, f, i + 1) + 7) >> 4)
		}
		this = column(n, f, w - 1)
		line[w * 2 - 2] = u8((this * 3 + column(n, f, w - 2) + 8) >> 4)
		line[w * 2 - 1] = u8((this * 4 + 7) >> 4)
	case .Box:
		hs := d.h_max / c.h
		for i in 0 ..< (d.features.width + hs - 1) / hs do for j in 0 ..< hs do line[i * hs + j] = n[i]
	}
	return line
}

// libjpeg's YCbCr to RGB: the scaled constants (16 fractional bits) with
// the rounding half added once, sixteen pixels at a time in 32-bit lanes.
@(private)
ycbcr_row :: proc(y, cb, cr: []u8, out: [][4]u8) #no_bounds_check {
	W :: #simd[16]i32
	load :: #force_inline proc "contextless" (s: []u8, at: int) -> W {
		return cast(W)intrinsics.unaligned_load((^#simd[16]u8)(&s[at]))
	}
	channel :: #force_inline proc "contextless" (v: W) -> #simd[16]u32 {return cast(#simd[16]u32)simd.clamp(v, 0, 255)}
	by16 :: (#simd[16]u32)(16)
	n := len(y)
	i := 0
	for ; i + 16 <= n; i += 16 {
		yy := load(y, i)
		b, r := load(cb, i) - 128, load(cr, i) - 128
		red := yy + simd.shr(r * 91881 + 32768, by16)
		green := yy + simd.shr(b * -22554 + 32768 - r * 46802, by16)
		blue := yy + simd.shr(b * 116130 + 32768, by16)
		v := channel(red) | simd.shl(channel(green), 8) | simd.shl(channel(blue), 16) | 0xFF00_0000
		intrinsics.unaligned_store((^#simd[16]u32)(&out[i]), v)
	}
	for ; i < n; i += 1 {
		yy := i32(y[i])
		b, r := i32(cb[i]) - 128, i32(cr[i]) - 128
		red := yy + (91881 * r + 32768) >> 16
		green := yy + (-22554 * b + 32768 - 46802 * r) >> 16
		blue := yy + (116130 * b + 32768) >> 16
		out[i] = {u8(clamp(red, 0, 255)), u8(clamp(green, 0, 255)), u8(clamp(blue, 0, 255)), 255}
	}
}

// x * y / 255, rounded, for 8-bit values.
@(private)
blinn :: #force_inline proc "contextless" (x, y: u8) -> u8 {
	t := u32(x) * u32(y) + 128
	return u8((t + t >> 8) >> 8)
}

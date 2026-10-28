package h264

import "base:intrinsics"

import "core:simd"

// ---------------------------------------------------------------------------
// Intra prediction (8.3) of u8 samples, or u16 samples of `bit_depth` bits:
// the mid-level 1 << (bit_depth - 1) stands in for missing neighbours and
// interpolated samples clip to (1 << bit_depth) - 1.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Intra 4x4 Prediction Modes
// ---------------------------------------------------------------------------

// A block's edge samples and their two interpolation filters are shared by
// every directional candidate. The encoder scores these register values before
// publishing a winner; the decoder uses the same predictor and stores directly.
Intra_4x4_Predictors :: struct {
	edge_samples:      #simd[16]i16,
	pair_averages:     #simd[16]i16,
	weighted_averages: #simd[16]i16,
	dc_value:          i16,
}

load_intra_4x4_predictors :: proc(
	pixels: [^]$T,
	stride: int,
	have_top, have_left, have_top_right: bool,
	bit_depth := 8,
) -> (
	predictors: Intra_4x4_Predictors,
) #no_bounds_check {
	top: [8]i16
	left: [4]i16
	if have_top do for column in 0 ..< 4 do top[column] = i16(pixels[-stride + column])
	if have_left do for row in 0 ..< 4 do left[row] = i16(pixels[row * stride - 1])
	for column in 4 ..< 8 do top[column] = have_top && have_top_right ? i16(pixels[-stride + column]) : top[3]
	corner := have_top && have_left ? i16(pixels[-stride - 1]) : i16(0)
	// Follow the edge from bottom-left through the corner to top-right.
	edges := #simd[16]i16 {
		left[3],
		left[2],
		left[1],
		left[0],
		corner,
		top[0],
		top[1],
		top[2],
		top[3],
		top[4],
		top[5],
		top[6],
		top[7],
		top[7],
		top[7],
		top[7],
	}
	predictors.edge_samples = edges
	predictors.pair_averages = shr_lanes(
		simd.add(
			simd.add(
				edges,
				simd.swizzle(edges, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 12, 12, 12, 12),
			),
			1,
		),
		1,
	)
	first := simd.swizzle(edges, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 0, 0, 0)
	centre := simd.swizzle(edges, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0, 0, 0, 0)
	last := simd.swizzle(edges, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 12, 0, 0, 0, 0)
	predictors.weighted_averages = shr_lanes(
		simd.add(simd.add(simd.add(first, last), simd.mul(centre, 2)), 2),
		2,
	)
	top_sum := top[0] + top[1] + top[2] + top[3]
	left_sum := left[0] + left[1] + left[2] + left[3]
	switch {
	case have_top && have_left:
		predictors.dc_value = (top_sum + left_sum + 4) >> 3
	case have_top:
		predictors.dc_value = (top_sum + 2) >> 2
	case have_left:
		predictors.dc_value = (left_sum + 2) >> 2
	case:
		predictors.dc_value = i16(1) << uint(bit_depth - 1)
	}
	return
}

intra_4x4_prediction_samples :: #force_inline proc(
	predictors: ^Intra_4x4_Predictors,
	mode: Intra_4x4_Mode,
) -> #simd[16]i16 {
	pairs := predictors.pair_averages
	weighted := predictors.weighted_averages
	switch mode {
	case .Vertical:
		return simd.swizzle(
			predictors.edge_samples,
			5,
			6,
			7,
			8,
			5,
			6,
			7,
			8,
			5,
			6,
			7,
			8,
			5,
			6,
			7,
			8,
		)
	case .Horizontal:
		return simd.swizzle(
			predictors.edge_samples,
			3,
			3,
			3,
			3,
			2,
			2,
			2,
			2,
			1,
			1,
			1,
			1,
			0,
			0,
			0,
			0,
		)
	case .DC:
		return (#simd[16]i16)(predictors.dc_value)
	case .Diagonal_Down_Left:
		return simd.swizzle(weighted, 5, 6, 7, 8, 6, 7, 8, 9, 7, 8, 9, 10, 8, 9, 10, 11)
	case .Diagonal_Down_Right:
		return simd.swizzle(weighted, 3, 4, 5, 6, 2, 3, 4, 5, 1, 2, 3, 4, 0, 1, 2, 3)
	case .Vertical_Right:
		return simd.shuffle(
			pairs,
			weighted,
			4,
			5,
			6,
			7,
			19,
			20,
			21,
			22,
			18,
			4,
			5,
			6,
			17,
			19,
			20,
			21,
		)
	case .Horizontal_Down:
		return simd.shuffle(
			pairs,
			weighted,
			3,
			19,
			20,
			21,
			2,
			18,
			3,
			19,
			1,
			17,
			2,
			18,
			0,
			16,
			1,
			17,
		)
	case .Vertical_Left:
		return simd.shuffle(
			pairs,
			weighted,
			5,
			6,
			7,
			8,
			21,
			22,
			23,
			24,
			6,
			7,
			8,
			9,
			22,
			23,
			24,
			25,
		)
	case .Horizontal_Up:
		return simd.shuffle(
			pairs,
			weighted,
			2,
			17,
			1,
			16,
			1,
			16,
			0,
			28,
			0,
			28,
			29,
			29,
			29,
			29,
			29,
			29,
		)
	}
	return {}
}

load_luma_block_4x4 :: #force_inline proc(
	pixels: [^]u8,
	stride: int,
) -> #simd[16]i16 #no_bounds_check {
	Row :: #simd[4]u8
	rows := [4]Row {
		intrinsics.unaligned_load((^Row)(pixels)),
		intrinsics.unaligned_load((^Row)(&pixels[stride])),
		intrinsics.unaligned_load((^Row)(&pixels[2 * stride])),
		intrinsics.unaligned_load((^Row)(&pixels[3 * stride])),
	}
	return (#simd[16]i16)(transmute(#simd[16]u8)rows)
}

store_luma_block_4x4 :: #force_inline proc(
	pixels: [^]$T,
	stride: int,
	samples: #simd[16]i16,
) #no_bounds_check {
	rows := transmute([4]#simd[4]T)(#simd[16]T)(samples)
	for row in 0 ..< 4 do intrinsics.unaligned_store((^#simd[4]T)(&pixels[row * stride]), rows[row])
}

predict_intra_4x4 :: proc(
	destination: [^]$T,
	stride: int,
	mode: Intra_4x4_Mode,
	have_top, have_left, have_top_right: bool,
	bit_depth := 8,
) {
	predictors := load_intra_4x4_predictors(
		destination,
		stride,
		have_top,
		have_left,
		have_top_right,
		bit_depth,
	)
	store_luma_block_4x4(destination, stride, intra_4x4_prediction_samples(&predictors, mode))
}

// ---------------------------------------------------------------------------
// Intra 16x16 and chroma prediction (8.3.3, 8.3.4): whole rows as lanes
// ---------------------------------------------------------------------------

// Plane prediction rows: (a + b * (x - centre_x) + c * (y - centre_y) + 16) >> 5
// over N columns and `rows` rows.
plane_rows :: #force_inline proc(
	$N: int,
	dst: [^]$T,
	stride, rows: int,
	a, b, c: i32,
	pixel_max: i32,
) #no_bounds_check {
	W :: #simd[N]i32
	xs: [N]i32
	for x in 0 ..< N do xs[x] = i32(x) - i32(N / 2 - 1)
	base := simd.add(simd.mul((W)(b), transmute(W)xs), (W)(a + 16))
	for y in 0 ..< rows {
		v := simd.shr(simd.add(base, (W)(c * (i32(y) - i32(rows / 2 - 1)))), (#simd[N]u32)(5))
		intrinsics.unaligned_store((^#simd[N]T)(&dst[y * stride]), (#simd[N]T)(simd.clamp(v, 0, W(pixel_max))))
	}
}

// Copy the N samples above the block into every row
fill_from_top :: #force_inline proc($N: int, dst: [^]$T, stride, rows: int) #no_bounds_check {
	top := intrinsics.unaligned_load((^#simd[N]T)(&dst[-stride]))
	for y in 0 ..< rows do intrinsics.unaligned_store((^#simd[N]T)(&dst[y * stride]), top)
}

fill_value :: #force_inline proc($N: int, dst: [^]$T, stride, rows: int, value: T) #no_bounds_check {
	v := (#simd[N]T)(value)
	for y in 0 ..< rows do intrinsics.unaligned_store((^#simd[N]T)(&dst[y * stride]), v)
}

fill_from_left :: #force_inline proc($N: int, dst: [^]$T, stride, rows: int) #no_bounds_check {
	for y in 0 ..< rows do intrinsics.unaligned_store((^#simd[N]T)(&dst[y * stride]), (#simd[N]T)(dst[y * stride - 1]))
}

predict_intra_16x16 :: proc(
	dst: [^]$T,
	stride: int,
	mode: Intra_16x16_Mode,
	top_avail, left_avail: bool,
	bit_depth := 8,
) #no_bounds_check {
	switch mode {
	case .Vertical:
		fill_from_top(16, dst, stride, 16)
	case .Horizontal:
		fill_from_left(16, dst, stride, 16)
	case .DC:
		sum: i32
		v := i32(1) << uint(bit_depth - 1)
		switch {
		case top_avail && left_avail:
			for i in 0 ..< 16 do sum += i32(dst[-stride + i]) + i32(dst[i * stride - 1])
			v = (sum + 16) >> 5
		case top_avail:
			for i in 0 ..< 16 do sum += i32(dst[-stride + i])
			v = (sum + 8) >> 4
		case left_avail:
			for i in 0 ..< 16 do sum += i32(dst[i * stride - 1])
			v = (sum + 8) >> 4
		}
		fill_value(16, dst, stride, 16, T(v))
	case .Plane:
		top: [^]T = &dst[-stride]
		left: [^]T = &dst[-1]
		h, v: i32
		for i in 0 ..< 8 {
			h += i32(i + 1) * (i32(top[8 + i]) - i32(top[6 - i]))
			v += i32(i + 1) * (i32(left[(8 + i) * stride]) - i32(left[(6 - i) * stride]))
		}
		plane_rows(
			16,
			dst,
			stride,
			16,
			(i32(left[15 * stride]) + i32(top[15])) << 4,
			(5 * h + 32) >> 6,
			(5 * v + 32) >> 6,
			i32(1) << uint(bit_depth) - 1,
		)
	}
}

// ---------------------------------------------------------------------------
// Intra chroma prediction (8.3.4): 8x8 blocks, or 8x16 for 4:2:2
// ---------------------------------------------------------------------------

predict_intra_chroma :: proc(
	dst: [^]$T,
	stride: int,
	mode: Intra_Chroma_Mode,
	top_avail: bool,
	left_avail: bool,
	chroma_422 := false,
	bit_depth := 8,
) #no_bounds_check {
	rows := chroma_422 ? 16 : 8
	switch mode {
	case .DC:
		// DC per 4x4 block from the macroblock's top row and left column
		// (8.3.4.1-3): blocks on the top row away from the left edge prefer
		// the top samples, blocks on the left column below the top prefer
		// the left samples, the others use both.
		sum_top :: #force_inline proc(dst: [^]$T, stride, x: int) -> i32 {
			return i32(dst[-stride + x]) + i32(dst[-stride + x + 1]) + i32(dst[-stride + x + 2]) + i32(dst[-stride + x + 3])
		}
		sum_left :: #force_inline proc(dst: [^]$T, stride, y: int) -> i32 {
			return i32(dst[y * stride - 1]) + i32(dst[(y + 1) * stride - 1]) + i32(dst[(y + 2) * stride - 1]) + i32(dst[(y + 3) * stride - 1])
		}
		for y := 0; y < rows; y += 4 {
			for x := 0; x < 8; x += 4 {
				v := i32(1) << uint(bit_depth - 1)
				prefer_top := x > 0 && y == 0
				prefer_left := x == 0 && y > 0
				switch {
				case prefer_top && top_avail, prefer_left && !left_avail && top_avail:
					v = (sum_top(dst, stride, x) + 2) >> 2
				case prefer_left && left_avail, prefer_top && !top_avail && left_avail:
					v = (sum_left(dst, stride, y) + 2) >> 2
				case top_avail && left_avail:
					v = (sum_top(dst, stride, x) + sum_left(dst, stride, y) + 4) >> 3
				case top_avail:
					v = (sum_top(dst, stride, x) + 2) >> 2
				case left_avail:
					v = (sum_left(dst, stride, y) + 2) >> 2
				}
				fill_value(4, &dst[y * stride + x], stride, 4, T(v))
			}
		}
	case .Horizontal:
		fill_from_left(8, dst, stride, rows)
	case .Vertical:
		fill_from_top(8, dst, stride, rows)
	case .Plane:
		top: [^]T = &dst[-stride]
		left: [^]T = &dst[-1]
		h, v: i32
		for i in 0 ..< 4 do h += i32(i + 1) * (i32(top[4 + i]) - i32(top[2 - i]))
		// The vertical gradient spans 4 rows each side of the centre, 8 for 4:2:2.
		half := rows / 2
		for i in 0 ..< half do v += i32(i + 1) * (i32(left[(half + i) * stride]) - i32(left[(half - 2 - i) * stride]))
		c := chroma_422 ? (5 * v + 32) >> 6 : (17 * v + 16) >> 5
		plane_rows(
			8,
			dst,
			stride,
			rows,
			(i32(left[(rows - 1) * stride]) + i32(top[7])) << 4,
			(17 * h + 16) >> 5,
			c,
			i32(1) << uint(bit_depth) - 1,
		)
	}
}

// ---------------------------------------------------------------------------
// Intra 8x8 Prediction (8.3.2.2) with reference sample filtering
// ---------------------------------------------------------------------------

predict_intra_8x8 :: proc(
	dst: [^]$T,
	stride: int,
	mode: Intra_4x4_Mode,
	top_avail, left_avail, top_right_avail, top_left_avail: bool,
	bit_depth := 8,
) #no_bounds_check {
	// Unfiltered neighbours: t[0..15] above, l[0..7] left, corner
	t, ft: [16]i32
	l, fl: [8]i32
	corner, fcorner: i32
	if top_avail {
		for i in 0 ..< 8 do t[i] = i32(dst[-stride + i])
		for i in 8 ..< 16 do t[i] = top_right_avail ? i32(dst[-stride + i]) : t[7]
	}
	if left_avail do for i in 0 ..< 8 do l[i] = i32(dst[i * stride - 1])
	if top_left_avail do corner = i32(dst[-stride - 1])

	// 8.3.2.2.1 filtering
	if top_avail {
		ft[0] = top_left_avail ? (corner + 2 * t[0] + t[1] + 2) >> 2 : (3 * t[0] + t[1] + 2) >> 2
		for i in 1 ..< 15 do ft[i] = (t[i - 1] + 2 * t[i] + t[i + 1] + 2) >> 2
		ft[15] = (t[14] + 3 * t[15] + 2) >> 2
	}
	if top_left_avail {
		switch {
		case top_avail && left_avail:
			fcorner = (t[0] + 2 * corner + l[0] + 2) >> 2
		case top_avail:
			fcorner = (3 * corner + t[0] + 2) >> 2
		case left_avail:
			fcorner = (3 * corner + l[0] + 2) >> 2
		case:
			fcorner = corner
		}
	}
	if left_avail {
		fl[0] = top_left_avail ? (corner + 2 * l[0] + l[1] + 2) >> 2 : (3 * l[0] + l[1] + 2) >> 2
		for i in 1 ..< 7 do fl[i] = (l[i - 1] + 2 * l[i] + l[i + 1] + 2) >> 2
		fl[7] = (l[6] + 3 * l[7] + 2) >> 2
	}

	// Filtered neighbour sample at index i, where -1 is the corner sample
	at :: #force_inline proc(samples: []i32, corner: i32, i: int) -> i32 {
		return i < 0 ? corner : samples[i]
	}
	put :: #force_inline proc(dst: [^]$T, stride, x, y: int, v: i32) {dst[y * stride + x] = T(v)}

	switch mode {
	case .Vertical:
		for y in 0 ..< 8 do for x in 0 ..< 8 do put(dst, stride, x, y, ft[x])
	case .Horizontal:
		for y in 0 ..< 8 do for x in 0 ..< 8 do put(dst, stride, x, y, fl[y])
	case .DC:
		sum: i32 = 0
		v := i32(1) << uint(bit_depth - 1)
		switch {
		case top_avail && left_avail:
			for i in 0 ..< 8 do sum += ft[i] + fl[i]
			v = (sum + 8) >> 4
		case top_avail:
			for i in 0 ..< 8 do sum += ft[i]
			v = (sum + 4) >> 3
		case left_avail:
			for i in 0 ..< 8 do sum += fl[i]
			v = (sum + 4) >> 3
		}
		for y in 0 ..< 8 do for x in 0 ..< 8 do put(dst, stride, x, y, v)
	case .Diagonal_Down_Left:
		for y in 0 ..< 8 do for x in 0 ..< 8 {
			v := x == 7 && y == 7 ? (ft[14] + 3 * ft[15] + 2) >> 2 : (ft[x + y] + 2 * ft[x + y + 1] + ft[x + y + 2] + 2) >> 2
			put(dst, stride, x, y, v)
		}
	case .Diagonal_Down_Right:
		for y in 0 ..< 8 do for x in 0 ..< 8 {
			v: i32
			switch {
			case x > y:
				v = (at(ft[:], fcorner, x - y - 2) + 2 * at(ft[:], fcorner, x - y - 1) + ft[x - y] + 2) >> 2
			case x < y:
				v = (at(fl[:], fcorner, y - x - 2) + 2 * at(fl[:], fcorner, y - x - 1) + fl[y - x] + 2) >> 2
			case:
				v = (ft[0] + 2 * fcorner + fl[0] + 2) >> 2
			}
			put(dst, stride, x, y, v)
		}
	case .Vertical_Right:
		for y in 0 ..< 8 do for x in 0 ..< 8 {
			z := 2 * x - y
			v: i32
			switch {
			case z >= 0 && z & 1 == 0:
				v = (at(ft[:], fcorner, x - (y >> 1) - 1) + ft[x - (y >> 1)] + 1) >> 1
			case z >= 0:
				v = (at(ft[:], fcorner, x - (y >> 1) - 2) + 2 * at(ft[:], fcorner, x - (y >> 1) - 1) + ft[x - (y >> 1)] + 2) >> 2
			case z == -1:
				v = (fl[0] + 2 * fcorner + ft[0] + 2) >> 2
			case:
				v = (fl[y - 2 * x - 1] + 2 * fl[y - 2 * x - 2] + at(fl[:], fcorner, y - 2 * x - 3) + 2) >> 2
			}
			put(dst, stride, x, y, v)
		}
	case .Horizontal_Down:
		for y in 0 ..< 8 do for x in 0 ..< 8 {
			z := 2 * y - x
			v: i32
			switch {
			case z >= 0 && z & 1 == 0:
				v = (at(fl[:], fcorner, y - (x >> 1) - 1) + fl[y - (x >> 1)] + 1) >> 1
			case z >= 0:
				v = (at(fl[:], fcorner, y - (x >> 1) - 2) + 2 * at(fl[:], fcorner, y - (x >> 1) - 1) + fl[y - (x >> 1)] + 2) >> 2
			case z == -1:
				v = (fl[0] + 2 * fcorner + ft[0] + 2) >> 2
			case:
				v = (ft[x - 2 * y - 1] + 2 * ft[x - 2 * y - 2] + at(ft[:], fcorner, x - 2 * y - 3) + 2) >> 2
			}
			put(dst, stride, x, y, v)
		}
	case .Vertical_Left:
		for y in 0 ..< 8 do for x in 0 ..< 8 {
			i := x + (y >> 1)
			v := y & 1 == 0 ? (ft[i] + ft[i + 1] + 1) >> 1 : (ft[i] + 2 * ft[i + 1] + ft[i + 2] + 2) >> 2
			put(dst, stride, x, y, v)
		}
	case .Horizontal_Up:
		for y in 0 ..< 8 do for x in 0 ..< 8 {
			z := x + 2 * y
			i := y + (x >> 1)
			v: i32
			switch {
			case z > 13:
				v = fl[7]
			case z == 13:
				v = (fl[6] + 3 * fl[7] + 2) >> 2
			case z & 1 == 0:
				v = (fl[i] + fl[i + 1] + 1) >> 1
			case:
				v = (fl[i] + 2 * fl[i + 1] + fl[i + 2] + 2) >> 2
			}
			put(dst, stride, x, y, v)
		}
	}
}

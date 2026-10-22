package vp9

import "base:intrinsics"
import "core:simd"

_ :: intrinsics
_ :: simd

// Intra prediction of one transform block (section 8.5.1), for 8-bit (u8)
// or high bit depth (u16) planes.
Intra_Edges :: struct {
	have_left, have_above, not_on_right: bool,
	max_x, max_y:                       int, // last column/row of decoded samples in this plane
}

@(private)
r2 :: #force_inline proc "contextless" (x: i32, n: uint) -> i32 {return (x + (1 << (n - 1))) >> n}

predict_intra :: proc(plane: []$T, stride, x, y: int, tx_size, mode: int, e: Intra_Edges, bit_depth: int) #no_bounds_check {
	V4 :: #simd[4]i32
	VT :: #simd[4]T
	size := 4 << uint(tx_size)
	log2 := uint(tx_size + 2)
	base := i32(1) << uint(bit_depth - 1)
	max_value := i32(1) << uint(bit_depth) - 1
	above_storage: [65]i32 = --- // above[-1] at index 0
	above := above_storage[1:]
	left: [32]i32 = ---
	if !e.have_above {
		v: V4 = base - 1
		for i := 0; i < size; i += 4 do intrinsics.unaligned_store((^V4)(&above[i]), v)
	} else {
		row := plane[(y - 1) * stride:]
		if x + size - 1 <= e.max_x {
			for i := 0; i < size; i += 4 {
				intrinsics.unaligned_store((^V4)(&above[i]), V4(intrinsics.unaligned_load((^VT)(&row[x + i]))))
			}
		} else {
			for i in 0 ..< size do above[i] = i32(row[min(e.max_x, x + i)])
		}
	}
	if e.have_left {
		for i in 0 ..< size do left[i] = i32(plane[min(e.max_y, y + i) * stride + x - 1])
	} else {
		v: V4 = base + 1
		for i := 0; i < size; i += 4 do intrinsics.unaligned_store((^V4)(&left[i]), v)
	}

	switch mode {
	case DC_PRED:
		v := base
		sum: i32
		switch {
		case e.have_left && e.have_above:
			for k in 0 ..< size do sum += left[k] + above[k]
			v = (sum + i32(size)) >> (log2 + 1)
		case e.have_left:
			for k in 0 ..< size do sum += left[k]
			v = (sum + (1 << (log2 - 1))) >> log2
		case e.have_above:
			for k in 0 ..< size do sum += above[k]
			v = (sum + (1 << (log2 - 1))) >> log2
		}
		vv: VT = T(v)
		for i in 0 ..< size {
			row := plane[(y + i) * stride + x:]
			for j := 0; j < size; j += 4 do intrinsics.unaligned_store((^VT)(&row[j]), vv)
		}
		return
	case V_PRED:
		for i in 0 ..< size {
			row := plane[(y + i) * stride + x:]
			for j := 0; j < size; j += 4 {
				av := intrinsics.unaligned_load((^V4)(&above[j]))
				intrinsics.unaligned_store((^VT)(&row[j]), VT(av))
			}
		}
		return
	case H_PRED:
		for i in 0 ..< size {
			row := plane[(y + i) * stride + x:]
			lv: VT = T(left[i])
			for j := 0; j < size; j += 4 do intrinsics.unaligned_store((^VT)(&row[j]), lv)
		}
		return
	case TM_PRED:
		corner := e.have_above && e.have_left ? i32(plane[(y - 1) * stride + min(e.max_x, x - 1)]) : e.have_above ? base + 1 : base - 1
		zero_v: V4 = 0
		max_v: V4 = max_value
		for i in 0 ..< size {
			row := plane[(y + i) * stride + x:]
			diff: V4 = left[i] - corner
			for j := 0; j < size; j += 4 {
				av := intrinsics.unaligned_load((^V4)(&above[j]))
				out := simd.clamp(av + diff, zero_v, max_v)
				intrinsics.unaligned_store((^VT)(&row[j]), VT(out))
			}
		}
		return
	}

	if !e.have_above {
		for i in size ..< 2 * size do above[i] = base - 1
	} else if e.not_on_right && tx_size == TX_4X4 {
		row := plane[(y - 1) * stride:]
		for i in size ..< 2 * size do above[i] = i32(row[min(e.max_x, x + i)])
	} else {
		last := above[size - 1]
		for i in size ..< 2 * size do above[i] = last
	}
	corner := e.have_above && e.have_left ? i32(plane[(y - 1) * stride + min(e.max_x, x - 1)]) : e.have_above ? base + 1 : base - 1
	above_storage[0] = corner

	pred: [32][32]i32 = ---
	switch mode {
	case D207_PRED:
		for j in 0 ..< size do pred[size - 1][j] = left[size - 1]
		for i in 0 ..< size - 1 do pred[i][0] = r2(left[i] + left[i + 1], 1)
		for i in 0 ..< size - 2 do pred[i][1] = r2(left[i] + 2 * left[i + 1] + left[i + 2], 2)
		pred[size - 2][1] = r2(left[size - 2] + 3 * left[size - 1], 2)
		for i := size - 2; i >= 0; i -= 1 do for j in 2 ..< size do pred[i][j] = pred[i + 1][j - 2]
	case D45_PRED:
		for i in 0 ..< size do for j in 0 ..< size {
			pred[i][j] = i + j + 2 < 2 * size ? r2(above[i + j] + above[i + j + 1] * 2 + above[i + j + 2], 2) : above[2 * size - 1]
		}
	case D63_PRED:
		for i in 0 ..< size do for j in 0 ..< size {
			k := i / 2 + j
			pred[i][j] = i & 1 != 0 ? r2(above[k] + above[k + 1] * 2 + above[k + 2], 2) : r2(above[k] + above[k + 1], 1)
		}
	case D117_PRED:
		for j in 0 ..< size do pred[0][j] = r2((j == 0 ? corner : above[j - 1]) + above[j], 1)
		pred[1][0] = r2(left[0] + 2 * corner + above[0], 2)
		for j in 1 ..< size do pred[1][j] = r2((j == 1 ? corner : above[j - 2]) + 2 * above[j - 1] + above[j], 2)
		pred[2][0] = r2(corner + 2 * left[0] + left[1], 2)
		for i in 3 ..< size do pred[i][0] = r2(left[i - 3] + 2 * left[i - 2] + left[i - 1], 2)
		for i in 2 ..< size do for j in 1 ..< size do pred[i][j] = pred[i - 2][j - 1]
	case D135_PRED:
		pred[0][0] = r2(left[0] + 2 * corner + above[0], 2)
		for j in 1 ..< size do pred[0][j] = r2((j == 1 ? corner : above[j - 2]) + 2 * above[j - 1] + above[j], 2)
		pred[1][0] = r2(corner + 2 * left[0] + left[1], 2)
		for i in 2 ..< size do pred[i][0] = r2(left[i - 2] + 2 * left[i - 1] + left[i], 2)
		for i in 1 ..< size do for j in 1 ..< size do pred[i][j] = pred[i - 1][j - 1]
	case D153_PRED:
		pred[0][0] = r2(left[0] + corner, 1)
		for i in 1 ..< size do pred[i][0] = r2(left[i - 1] + left[i], 1)
		pred[0][1] = r2(left[0] + 2 * corner + above[0], 2)
		pred[1][1] = r2(corner + 2 * left[0] + left[1], 2)
		for i in 2 ..< size do pred[i][1] = r2(left[i - 2] + 2 * left[i - 1] + left[i], 2)
		for j in 2 ..< size do pred[0][j] = r2((j == 2 ? corner : above[j - 3]) + 2 * above[j - 2] + above[j - 1], 2)
		for i in 1 ..< size do for j in 2 ..< size do pred[i][j] = pred[i - 1][j - 2]
	}
	for i in 0 ..< size {
		row := plane[(y + i) * stride + x:]
		for j := 0; j < size; j += 4 {
			pv := intrinsics.unaligned_load((^V4)(&pred[i][j]))
			intrinsics.unaligned_store((^VT)(&row[j]), VT(pv))
		}
	}
}

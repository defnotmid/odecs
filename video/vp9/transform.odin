package vp9

import common "../../common"
import "base:intrinsics"
import "core:simd"

// Inverse transforms (section 8.7). The 1-D transforms are the butterfly
// sequences of the specification applied to lanes: lane l of T[k] is sample
// k of line l, so one call transforms up to eight rows or columns of a block.
// The transform size is a constant, so the angles, permutations and loop
// bounds fold away. The specification bounds the values in T to 8 + BitDepth
// bits, so at 8 bits every product and sum fits i32 lanes; deeper blocks
// compute in i64 lanes.

@(private)
round2 :: #force_inline proc "contextless" (x: i64, n: uint) -> i32 {
	return i32((x + (i64(1) << (n - 1))) >> n)
}

@(private)
round2_lanes :: #force_inline proc "contextless" (x: $V/#simd[$L]$E, $n: uint) -> V {
	when E == i32 {
		return simd.shr(x + V(1 << (n - 1)), (#simd[L]u32)(n))
	} else {
		return simd.shr(x + V(1 << (n - 1)), (#simd[L]u64)(n))
	}
}

@(private)
cos64 :: #force_inline proc "contextless" (angle: int) -> i64 {
	a := angle & 127
	switch {
	case a <= 32:
		return i64(COS64_LOOKUP[a])
	case a <= 64:
		return -i64(COS64_LOOKUP[64 - a])
	case a <= 96:
		return -i64(COS64_LOOKUP[a - 64])
	}
	return i64(COS64_LOOKUP[128 - a])
}

@(private)
sin64 :: #force_inline proc "contextless" (angle: int) -> i64 {return cos64(angle - 32)}

@(private)
brev :: #force_inline proc "contextless" (bits: uint, x: int) -> int {
	t := 0
	for i in 0 ..< bits do t |= ((x >> i) & 1) << (bits - 1 - i)
	return t
}

// Butterfly rotation, optionally swapping the outputs.
@(private)
B :: #force_inline proc "contextless" (t: ^[$M]$V, a, b, angle: int, flip: bool) {
	E :: intrinsics.type_elem_type(V)
	c, s := V(E(cos64(angle))), V(E(sin64(angle)))
	x := t[a] * c - t[b] * s
	y := t[a] * s + t[b] * c
	t[a], t[b] = round2_lanes(x, 14), round2_lanes(y, 14)
	if flip do t[a], t[b] = t[b], t[a]
}

// Hadamard rotation; flip uses (b, a).
@(private)
H :: #force_inline proc "contextless" (t: ^[$M]$V, a, b: int, flip: bool) {
	a, b := a, b
	if flip do a, b = b, a
	x, y := t[a], t[b]
	t[a], t[b] = x + y, x - y
}

@(private)
SB :: #force_inline proc "contextless" (t: ^[$M]$V, s: ^[$K]V, a, b, angle: int, flip: bool) {
	E :: intrinsics.type_elem_type(V)
	c, n := V(E(cos64(angle))), V(E(sin64(angle)))
	s[a] = t[a] * c - t[b] * n
	s[b] = t[a] * n + t[b] * c
	if flip do s[a], s[b] = s[b], s[a]
}

@(private)
SH :: #force_inline proc "contextless" (t: ^[$M]$V, s: ^[$K]V, a, b: int) {
	t[a], t[b] = round2_lanes(s[a] + s[b], 14), round2_lanes(s[a] - s[b], 14)
}

// Inverse DCT of 1 << n samples (8.7.1.2 permutation, then 8.7.1.3).
@(private)
idct :: #force_inline proc "contextless" (t: ^[$M]$V, $n: uint) {
	c := t^
	#unroll for i in 0 ..< 1 << n do t[i] = c[brev(n, i)]
	idct_permuted(t, n)
}

@(private)
idct_permuted :: #force_inline proc "contextless" (t: ^[$M]$V, $n: uint) {
	N0 :: 1 << n
	N1 :: N0 >> 1
	N2 :: N0 >> 2
	N3 :: N0 >> 3
	N :: int(n)
	when n == 2 {
		B(t, 0, 1, 16, true)
	} else {
		idct_permuted(t, n - 1)
	}
	#unroll for i in 0 ..< N2 do B(t, N1 + i, N0 - 1 - i, 32 - brev(5, N1 + i), false)
	when n >= 3 {
		#unroll for i in 0 ..< N3 do #unroll for j in 0 ..< 2 do H(t, N1 + 4 * i + 2 * j, N1 + 1 + 4 * i + 2 * j, j == 1)
	}
	when n == 5 {
		#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do B(t, N0 - N + 3 - N2 * j - 4 * i, N1 + N - 4 + N2 * j + 4 * i, 28 - 16 * i + 56 * j, true)
		#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 4 do H(t, N1 + N3 * j + i, N1 + N2 - 5 + N3 * j - i, j & 1 == 1)
	}
	when n >= 4 {
		#unroll for i in 0 ..< N - 3 do #unroll for j in 0 ..< 2 do B(t, N0 - N + 2 - i - N2 * j, N1 + N - 3 + i + N2 * j, 24 + 48 * j, true)
		#unroll for i in 0 ..< 2 * N - 6 do #unroll for j in 0 ..< 2 do H(t, N1 + N2 * j + i, N1 + N2 - 1 + N2 * j - i, j & 1 == 1)
	}
	when n >= 3 {
		#unroll for i in 0 ..< N3 do B(t, N0 - N3 - 1 - i, N1 + N3 + i, 16, true)
	}
	#unroll for i in 0 ..< N1 do H(t, i, N0 - 1 - i, false)
}

SINPI_1_9 :: 5283
SINPI_2_9 :: 9929
SINPI_3_9 :: 13377
SINPI_4_9 :: 15212

@(private)
iadst4 :: #force_inline proc "contextless" (t: ^[$M]$V) {
	s0 := V(SINPI_1_9) * t[0]
	s1 := V(SINPI_2_9) * t[0]
	s2 := V(SINPI_3_9) * t[1]
	s3 := V(SINPI_4_9) * t[2]
	s4 := V(SINPI_1_9) * t[2]
	s5 := V(SINPI_2_9) * t[3]
	s6 := V(SINPI_4_9) * t[3]
	s7 := V(SINPI_3_9) * (t[0] - t[2] + t[3])
	x0 := s0 + s3 + s5
	x1 := s1 - s4 - s6
	x2 := s7
	x3 := s2
	t[0] = round2_lanes(x0 + x3, 14)
	t[1] = round2_lanes(x1 + x3, 14)
	t[2] = round2_lanes(x2, 14)
	t[3] = round2_lanes(x0 + x1 - x3, 14)
}

@(private)
adst_input_permute :: #force_inline proc "contextless" (t: ^[$M]$V, $n: uint) {
	N0 :: 1 << n
	c := t^
	#unroll for i in 0 ..< N0 >> 1 {
		t[2 * i] = c[N0 - 1 - 2 * i]
		t[2 * i + 1] = c[2 * i]
	}
}

@(private)
adst_output_permute :: #force_inline proc "contextless" (t: ^[$M]$V, $n: uint) {
	c := t^
	when n == 4 {
		#unroll for a in 0 ..< 2 do #unroll for b in 0 ..< 2 do #unroll for cc in 0 ..< 2 do #unroll for d in 0 ..< 2 {
			t[8 * a + 4 * b + 2 * cc + d] = c[8 * (d ~ cc) + 4 * (cc ~ b) + 2 * (b ~ a) + a]
		}
	} else {
		#unroll for a in 0 ..< 2 do #unroll for b in 0 ..< 2 do #unroll for cc in 0 ..< 2 {
			t[4 * a + 2 * b + cc] = c[4 * (cc ~ b) + 2 * (b ~ a) + a]
		}
	}
}

@(private)
iadst8 :: #force_inline proc "contextless" (t: ^[$M]$V) {
	s: [8]V = ---
	adst_input_permute(t, 3)
	#unroll for i in 0 ..< 4 do SB(t, &s, 2 * i, 1 + 2 * i, 30 - 8 * i, true)
	#unroll for i in 0 ..< 4 do SH(t, &s, i, 4 + i)
	#unroll for i in 0 ..< 2 do SB(t, &s, 4 + 3 * i, 5 + i, 24 - 16 * i, true)
	#unroll for i in 0 ..< 2 do SH(t, &s, 4 + i, 6 + i)
	#unroll for i in 0 ..< 2 do H(t, i, 2 + i, false)
	#unroll for i in 0 ..< 2 do B(t, 2 + 4 * i, 3 + 4 * i, 16, true)
	adst_output_permute(t, 3)
	#unroll for i in 0 ..< 4 do t[1 + 2 * i] = -t[1 + 2 * i]
}

@(private)
iadst16 :: #force_inline proc "contextless" (t: ^[$M]$V) {
	s: [16]V = ---
	adst_input_permute(t, 4)
	#unroll for i in 0 ..< 8 do SB(t, &s, 2 * i, 1 + 2 * i, 31 - 4 * i, true)
	#unroll for i in 0 ..< 8 do SH(t, &s, i, 8 + i)
	#unroll for i in 0 ..< 4 do SB(t, &s, 8 + 2 * i, 9 + 2 * i, 28 - 16 * i, true)
	#unroll for i in 0 ..< 4 do SH(t, &s, 8 + i, 12 + i)
	#unroll for i in 0 ..< 4 do H(t, i, 4 + i, false)
	#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do SB(t, &s, 4 + 8 * i + 3 * j, 5 + 8 * i + j, 24 - 16 * j, true)
	#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do SH(t, &s, 4 + 8 * j + i, 6 + 8 * j + i)
	#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do H(t, 8 * j + i, 2 + 8 * j + i, false)
	#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do B(t, 2 + 4 * j + 8 * i, 3 + 4 * j + 8 * i, 48 + 64 * (i ~ j), false)
	adst_output_permute(t, 4)
	#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do t[1 + 12 * j + 2 * i] = -t[1 + 12 * j + 2 * i]
}

// Inverse ADST of 1 << n samples, n = 2, 3 or 4 (8.7.1.5 to 8.7.1.9).
@(private)
iadst :: #force_inline proc "contextless" (t: ^[$M]$V, $n: uint) {
	when n == 2 {
		iadst4(t)
	} else when n == 3 {
		iadst8(t)
	} else {
		iadst16(t)
	}
}

// Constant residual produced by a DC-only DCT_DCT block of side 1 << n.
dc_residual :: #force_inline proc "contextless" (c0: i32, n: uint) -> i32 {
	dc1 := round2(i64(c0) * cos64(16), 14)
	dc2 := round2(i64(dc1) * cos64(16), 14)
	return round2(i64(dc2), min(n + 2, 6))
}

@(private)
iwht :: proc "contextless" (t: ^[4]i32, shift: uint) {
	a := t[0] >> shift
	c := t[1] >> shift
	d := t[2] >> shift
	b := t[3] >> shift
	a += c
	d -= b
	e := (a - d) >> 1
	b = e - b
	c = e - c
	a -= b
	d += c
	t[0], t[1], t[2], t[3] = a, b, c, d
}

// 2-D inverse transform of a (1 << n)-square block of dequantized
// coefficients in raster order, in place (section 8.7.2). Rows at or past
// `rows` are known to be zero. bit_depth picks the lane width.
inverse_transform :: proc(block: []i32, n: uint, tx_type: int, lossless: bool, rows: int, bit_depth := 8) {
	assert(len(block) >= 1 << (2 * n) && rows <= 1 << n)
	if lossless {
		inverse_wht(block)
		return
	}
	wide := bit_depth > 8
	switch n {
	case 2:
		if wide {transform_lanes(block, 2, i64, tx_type, rows)} else {transform_lanes(block, 2, i32, tx_type, rows)}
	case 3:
		if wide {transform_lanes(block, 3, i64, tx_type, rows)} else {transform_lanes(block, 3, i32, tx_type, rows)}
	case 4:
		if wide {transform_lanes(block, 4, i64, tx_type, rows)} else {transform_lanes(block, 4, i32, tx_type, rows)}
	case:
		if wide {transform_lanes(block, 5, i64, DCT_DCT, rows)} else {transform_lanes(block, 5, i32, DCT_DCT, rows)}
	}
}

// Rows first, L at a time: L x L tiles are transposed so that T[j] holds
// column j of those rows. Then columns, L at a time, straight from the rows.
@(private)
transform_lanes :: proc(block: []i32, $n: uint, $E: typeid, tx_type, rows: int) #no_bounds_check {
	N :: 1 << n
	L :: min(N, 8)
	V :: #simd[L]E
	W :: #simd[L]i32
	SHIFT :: min(n + 2, 6)
	// 32x32 is DCT only.
	row_dct := n == 5 || tx_type == DCT_DCT || tx_type == ADST_DCT
	col_dct := n == 5 || tx_type == DCT_DCT || tx_type == DCT_ADST
	// A DC-only DCT block reconstructs to a constant across all N x N samples.
	if rows == 1 && row_dct && col_dct {
		dc_only := true
		for j in 1 ..< N do if block[j] != 0 {dc_only = false; break}
		if dc_only {
			v := W(dc_residual(block[0], n))
			for idx := 0; idx < N * N; idx += L {
				intrinsics.unaligned_store((^W)(&block[idx]), v)
			}
			return
		}
	}
	t: [N]V = ---
	when N == L {
		tile: [L]V = ---
		#unroll for l in 0 ..< L do tile[l] = V(intrinsics.unaligned_load((^W)(&block[l * N])))
		t = common.transpose(tile)
		if row_dct {idct(&t, n)} else {iadst(&t, n)}
		t = common.transpose(t)
		if col_dct {idct(&t, n)} else {iadst(&t, n)}
		#unroll for i in 0 ..< N do intrinsics.unaligned_store((^W)(&block[i * N]), W(round2_lanes(t[i], SHIFT)))
	} else {
		for g := 0; g < rows; g += L {
			#unroll for jb in 0 ..< N / L {
				tile: [L]V = ---
				#unroll for l in 0 ..< L do tile[l] = V(intrinsics.unaligned_load((^W)(&block[(g + l) * N + jb * L])))
				tile = common.transpose(tile)
				#unroll for k in 0 ..< L do t[jb * L + k] = tile[k]
			}
			if row_dct {idct(&t, n)} else {iadst(&t, n)}
			#unroll for jb in 0 ..< N / L {
				tile: [L]V = ---
				#unroll for k in 0 ..< L do tile[k] = t[jb * L + k]
				tile = common.transpose(tile)
				#unroll for l in 0 ..< L do intrinsics.unaligned_store((^W)(&block[(g + l) * N + jb * L]), W(tile[l]))
			}
		}
		row_end := min(N, (rows + L - 1) & ~int(L - 1))
		for jb := 0; jb < N; jb += L {
			#unroll for i in 0 ..< N {
				t[i] = i < row_end ? V(intrinsics.unaligned_load((^W)(&block[i * N + jb]))) : 0
			}
			if col_dct {idct(&t, n)} else {iadst(&t, n)}
			#unroll for i in 0 ..< N do intrinsics.unaligned_store((^W)(&block[i * N + jb]), W(round2_lanes(t[i], SHIFT)))
		}
	}
}

// Lossless 4x4 Walsh-Hadamard (8.7.1.10): rows shifted by 2, columns not,
// and no final rounding.
@(private)
inverse_wht :: proc(block: []i32) {
	t: [4]i32
	for i in 0 ..< 4 {
		copy(t[:], block[i * 4:][:4])
		iwht(&t, 2)
		copy(block[i * 4:][:4], t[:])
	}
	for j in 0 ..< 4 {
		for i in 0 ..< 4 do t[i] = block[i * 4 + j]
		iwht(&t, 0)
		for i in 0 ..< 4 do block[i * 4 + j] = t[i]
	}
}

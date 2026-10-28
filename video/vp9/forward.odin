package vp9

import common "../../common"
import "base:intrinsics"

// Separable fixed-point butterfly analysis transforms paired with the
// normative synthesis transforms in transform.odin.
Forward_Transforms :: struct {}

init_forward_transforms :: proc(f: ^Forward_Transforms) {}

// Forward DCT of 1 << n samples: exact transpose of idct.
@(private)
fdct :: #force_inline proc "contextless" (t: ^[$M]$V, $n: uint) {
	fdct_permuted(t, n)
	c := t^
	#unroll for i in 0 ..< 1 << n do t[i] = c[brev(n, i)]
}

@(private)
fdct_permuted :: #force_inline proc "contextless" (t: ^[$M]$V, $n: uint) {
	N0 :: 1 << n
	N1 :: N0 >> 1
	N2 :: N0 >> 2
	N3 :: N0 >> 3
	N :: int(n)
	#unroll for i in 0 ..< N1 do H(t, i, N0 - 1 - i, false)
	when n >= 3 {
		#unroll for i in 0 ..< N3 do B(t, N0 - N3 - 1 - i, N1 + N3 + i, 16, true)
	}
	when n >= 4 {
		#unroll for i in 0 ..< 2 * N - 6 do #unroll for j in 0 ..< 2 do H(t, N1 + N2 * j + i, N1 + N2 - 1 + N2 * j - i, j & 1 == 1)
		#unroll for i in 0 ..< N - 3 do #unroll for j in 0 ..< 2 do B(t, N0 - N + 2 - i - N2 * j, N1 + N - 3 + i + N2 * j, 24 + 48 * j, true)
	}
	when n == 5 {
		#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 4 do H(t, N1 + N3 * j + i, N1 + N2 - 5 + N3 * j - i, j & 1 == 1)
		#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do B(t, N0 - N + 3 - N2 * j - 4 * i, N1 + N - 4 + N2 * j + 4 * i, 28 - 16 * i + 56 * j, true)
	}
	when n >= 3 {
		#unroll for i in 0 ..< N3 do #unroll for j in 0 ..< 2 do H(t, N1 + 4 * i + 2 * j, N1 + 1 + 4 * i + 2 * j, j == 1)
	}
	#unroll for i in 0 ..< N2 do B(t, N1 + i, N0 - 1 - i, -(32 - brev(5, N1 + i)), false)
	when n == 2 {
		B(t, 0, 1, 16, true)
	} else {
		fdct_permuted(t, n - 1)
	}
}

@(private)
adst_input_permute_t :: #force_inline proc "contextless" (t: ^[$M]$V, $n: uint) {
	N0 :: 1 << n
	c := t^
	#unroll for i in 0 ..< N0 >> 1 {
		t[N0 - 1 - 2 * i] = c[2 * i]
		t[2 * i] = c[2 * i + 1]
	}
}

@(private)
adst_output_permute_t :: #force_inline proc "contextless" (t: ^[$M]$V, $n: uint) {
	c := t^
	when n == 4 {
		#unroll for a in 0 ..< 2 do #unroll for b in 0 ..< 2 do #unroll for cc in 0 ..< 2 do #unroll for d in 0 ..< 2 {
			t[8 * (d ~ cc) + 4 * (cc ~ b) + 2 * (b ~ a) + a] = c[8 * a + 4 * b + 2 * cc + d]
		}
	} else {
		#unroll for a in 0 ..< 2 do #unroll for b in 0 ..< 2 do #unroll for cc in 0 ..< 2 {
			t[4 * (cc ~ b) + 2 * (b ~ a) + a] = c[4 * a + 2 * b + cc]
		}
	}
}

@(private)
fadst4 :: #force_inline proc "contextless" (t: ^[$M]$V) {
	s0 := V(SINPI_1_9) * t[0]
	s1 := V(SINPI_4_9) * t[0]
	s2 := V(SINPI_2_9) * t[1]
	s3 := V(SINPI_1_9) * t[1]
	s4 := V(SINPI_3_9) * t[2]
	s5 := V(SINPI_4_9) * t[3]
	s6 := V(SINPI_2_9) * t[3]
	s7 := V(SINPI_3_9) * (t[0] + t[1] - t[3])
	x0 := s0 + s2 + s5
	x1 := s7
	x2 := s1 - s3 + s6
	x3 := s4
	t[0] = round2_lanes(x0 + x3, 14)
	t[1] = round2_lanes(x1, 14)
	t[2] = round2_lanes(x2 - x3, 14)
	t[3] = round2_lanes(x2 - x0 + x3, 14)
}

@(private)
fadst8 :: #force_inline proc "contextless" (t: ^[$M]$V) {
	#unroll for i in 0 ..< 4 do t[1 + 2 * i] = -t[1 + 2 * i]
	adst_output_permute_t(t, 3)
	#unroll for i in 0 ..< 2 do B(t, 2 + 4 * i, 3 + 4 * i, 16, true)
	#unroll for i in 0 ..< 2 do H(t, i, 2 + i, false)
	#unroll for i in 0 ..< 2 do H(t, 4 + i, 6 + i, false)
	#unroll for i in 0 ..< 2 do B(t, 4 + 3 * i, 5 + i, 24 - 16 * i, true)
	#unroll for i in 0 ..< 4 do H(t, i, 4 + i, false)
	#unroll for i in 0 ..< 4 do B(t, 2 * i, 1 + 2 * i, 30 - 8 * i, true)
	adst_input_permute_t(t, 3)
}

@(private)
fadst16 :: #force_inline proc "contextless" (t: ^[$M]$V) {
	#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do t[1 + 12 * j + 2 * i] = -t[1 + 12 * j + 2 * i]
	adst_output_permute_t(t, 4)
	#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do B(t, 2 + 4 * j + 8 * i, 3 + 4 * j + 8 * i, -(48 + 64 * (i ~ j)), false)
	#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do H(t, 8 * j + i, 2 + 8 * j + i, false)
	#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do H(t, 4 + 8 * j + i, 6 + 8 * j + i, false)
	#unroll for i in 0 ..< 2 do #unroll for j in 0 ..< 2 do B(t, 4 + 8 * i + 3 * j, 5 + 8 * i + j, 24 - 16 * j, true)
	#unroll for i in 0 ..< 4 do H(t, i, 4 + i, false)
	#unroll for i in 0 ..< 4 do H(t, 8 + i, 12 + i, false)
	#unroll for i in 0 ..< 4 do B(t, 8 + 2 * i, 9 + 2 * i, 28 - 16 * i, true)
	#unroll for i in 0 ..< 8 do H(t, i, 8 + i, false)
	#unroll for i in 0 ..< 8 do B(t, 2 * i, 1 + 2 * i, 31 - 4 * i, true)
	adst_input_permute_t(t, 4)
}

@(private)
fadst :: #force_inline proc "contextless" (t: ^[$M]$V, $n: uint) {
	when n == 2 {
		fadst4(t)
	} else when n == 3 {
		fadst8(t)
	} else {
		fadst16(t)
	}
}

@(private)
forward_wht4 :: proc(v: ^[4]i32) {
	a, d := v[0] + v[1], v[3] - v[2]
	e := (a - d) >> 1
	b, c := e - v[1], e - v[2]
	v^ = {a - c, c, d + b, b}
}

// 4..32 DCT and 4..16 ADST. Lossless uses a reversible 4x4 lifting transform.
// Coefficients have the inverse's scaling (the caller applies 32x32's
// quantizer shift when writing tokens). The lossy analysis is not specified
// by VP9 and need not reproduce libvpx's encoder coefficients.
forward_transform :: proc(f: ^Forward_Transforms, block: []i32, tx_size, tx_type: int, lossless: bool, bit_depth := 8) {
	assert(tx_size >= 0 && tx_size <= TX_32X32 && tx_type >= 0 && tx_type <= ADST_ADST)
	assert(tx_size != TX_32X32 || tx_type == DCT_DCT)
	n := 4 << uint(tx_size)
	assert(len(block) >= n * n && (!lossless || tx_size == TX_4X4))
	if lossless {
		for x in 0 ..< 4 {
			v := [4]i32{block[x], block[4 + x], block[8 + x], block[12 + x]}
			forward_wht4(&v)
			for y in 0 ..< 4 do block[y * 4 + x] = v[y]
		}
		for y in 0 ..< 4 {
			v := [4]i32{block[y * 4], block[y * 4 + 1], block[y * 4 + 2], block[y * 4 + 3]}
			forward_wht4(&v)
			for x in 0 ..< 4 do block[y * 4 + x] = v[x] * 4
		}
		return
	}
	wide := bit_depth > 8
	switch tx_size {
	case 0:
		if wide {forward_lossy(block, tx_type, 2, i64)} else {forward_lossy(block, tx_type, 2, i32)}
	case 1:
		if wide {forward_lossy(block, tx_type, 3, i64)} else {forward_lossy(block, tx_type, 3, i32)}
	case 2:
		if wide {forward_lossy(block, tx_type, 4, i64)} else {forward_lossy(block, tx_type, 4, i32)}
	case 3:
		if wide {forward_lossy(block, DCT_DCT, 5, i64)} else {forward_lossy(block, DCT_DCT, 5, i32)}
	}
}

// forward_transform's length assertion bounds every index below.
@(private)
forward_lossy :: proc(block: []i32, tx_type: int, $n: uint, $E: typeid) #no_bounds_check {
	N :: 1 << n
	L :: min(N, 8)
	Vec :: #simd[L]E
	W :: #simd[L]i32
	vertical_adst := n < 5 && (tx_type == ADST_DCT || tx_type == ADST_ADST)
	horizontal_adst := n < 5 && (tx_type == DCT_ADST || tx_type == ADST_ADST)
	t: [N]Vec = ---
	when N == L {
		#unroll for i in 0 ..< N do t[i] = Vec(intrinsics.unaligned_load((^W)(&block[i * N]))) * 4
		if vertical_adst {fadst(&t, n)} else {fdct(&t, n)}
		t = common.transpose(t)
		if horizontal_adst {fadst(&t, n)} else {fdct(&t, n)}
		t = common.transpose(t)
		#unroll for i in 0 ..< N {
			out := t[i]
			when n == 3 do out = round2_lanes(out, 1)
			intrinsics.unaligned_store((^W)(&block[i * N]), W(out))
		}
	} else {
		t_cols: [N / L][N]Vec = ---
		for jb := 0; jb < N; jb += L {
			#unroll for i in 0 ..< N {
				t[i] = Vec(intrinsics.unaligned_load((^W)(&block[i * N + jb]))) * 4
			}
			if vertical_adst {fadst(&t, n)} else {fdct(&t, n)}
			#unroll for gb in 0 ..< N / L {
				tile: [L]Vec = ---
				#unroll for l in 0 ..< L {
					v := t[gb * L + l]
					when n == 5 do v = round2_lanes(v, 1)
					tile[l] = v
				}
				tile = common.transpose(tile)
				#unroll for k in 0 ..< L do t_cols[gb][jb + k] = tile[k]
			}
		}
		for gb in 0 ..< N / L {
			row_vec := &t_cols[gb]
			if horizontal_adst {fadst(row_vec, n)} else {fdct(row_vec, n)}
			#unroll for jb in 0 ..< N / L {
				tile: [L]Vec = ---
				#unroll for k in 0 ..< L {
					v := row_vec[jb * L + k]
					when n == 4 {
						v = round2_lanes(v, 2)
					} else when n == 5 {
						v = round2_lanes(v, 3)
					}
					tile[k] = v
				}
				tile = common.transpose(tile)
				#unroll for l in 0 ..< L do intrinsics.unaligned_store((^W)(&block[(gb * L + l) * N + jb * L]), W(tile[l]))
			}
		}
	}
}

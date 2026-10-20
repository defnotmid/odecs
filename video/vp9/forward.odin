package vp9

import "base:intrinsics"
import "core:simd"

// Separable fixed-point analysis bases paired with the normative synthesis
// transforms. Prepared once per encoder, not regenerated in block loops.
Forward_Transforms :: struct {
	basis: [4][2][32][32]i32, // tx size, DCT/ADST, output frequency, input sample
}

init_forward_transforms :: proc(f: ^Forward_Transforms) {
	for tx in 0 ..< 4 {
		n := 4 << uint(tx)
		for k in 0 ..< n do for x in 0 ..< n {
			f.basis[tx][0][k][x] = i32(k == 0 ? cos64(16) : cos64((2 * x + 1) * k * (32 / n)))
		}
		// forward_lossy pairs reflected samples: even DCT rows are symmetric,
		// odd rows antisymmetric.
		for k in 0 ..< n do for x in 0 ..< n / 2 {
			assert(f.basis[tx][0][k][n - 1 - x] == (k & 1 == 0 ? 1 : -1) * f.basis[tx][0][k][x])
		}
	}
	// VP9 does not define a 32-point ADST.
	adst_basis(f, TX_4X4, 2)
	adst_basis(f, TX_8X8, 3)
	adst_basis(f, TX_16X16, 4)
}

// ADST basis row k is the inverse ADST of 16384 at sample k, taken in lane k.
@(private)
adst_basis :: proc(f: ^Forward_Transforms, tx: int, $n: uint) {
	N :: 1 << n
	L :: min(N, 8)
	for kb := 0; kb < N; kb += L {
		t: [32]#simd[L]i64
		for x in 0 ..< N {
			lanes: [L]i64
			if x >= kb && x < kb + L do lanes[x - kb] = 16384
			t[x] = simd.from_array(lanes)
		}
		iadst(&t, n)
		for x in 0 ..< N {
			lanes := simd.to_array(t[x])
			for l in 0 ..< L do f.basis[tx][1][kb + l][x] = i32(lanes[l])
		}
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
forward_transform :: proc(f: ^Forward_Transforms, block: []i32, tx_size, tx_type: int, lossless: bool) {
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
	switch tx_size {
	case 0: forward_lossy(f, block, tx_type, 0)
	case 1: forward_lossy(f, block, tx_type, 1)
	case 2: forward_lossy(f, block, tx_type, 2)
	case 3: forward_lossy(f, block, tx_type, 3)
	}
}

// Residuals are within +-255, so a column sum is below 32 * 255 * 2^14 and
// four times it still fits i32. Row sums of those values need i64.
// forward_transform's length assertion bounds every index below.
@(private)
forward_lossy :: proc(f: ^Forward_Transforms, block: []i32, tx_type: int, $TX: int) #no_bounds_check {
	N :: 4 << uint(TX)
	H :: N / 2
	Row :: #simd[N]i32
	vertical := tx_type == ADST_DCT || tx_type == ADST_ADST
	horizontal := tx_type == DCT_ADST || tx_type == ADST_ADST
	cols, rows := &f.basis[TX][int(vertical)], &f.basis[TX][int(horizontal)]
	input: [N]Row = ---
	for i in 0 ..< N do input[i] = intrinsics.unaligned_load((^Row)(&block[i * N]))

	// Columns: each output row weights whole input rows. For the DCT, the even
	// outputs read sums of reflected rows and the odd outputs their differences.
	tmp: [N][N]i32 = ---
	terms, count := input[:], N
	paired: [N]Row = ---
	if !vertical {
		for i in 0 ..< H do paired[i], paired[H + i] = input[i] + input[N - 1 - i], input[i] - input[N - 1 - i]
		count = H
	}
	for y in 0 ..< N {
		if !vertical do terms = paired[(y & 1) * H:][:H]
		acc: Row
		for i in 0 ..< count do acc += Row(cols[y][i]) * terms[i]
		intrinsics.unaligned_store((^Row)(&tmp[y]), simd.shr(acc * 4 + 8192, (#simd[N]u32)(14)))
	}

	// Rows, pairing reflected samples the same way for a horizontal DCT.
	shift :: uint(2 * (TX + 2) - min(6, TX + 4))
	for y in 0 ..< N {
		samples := &tmp[y]
		out := block[y * N:][:N]
		if horizontal {
			for x in 0 ..< N {
				s: i64
				for i in 0 ..< N do s += i64(rows[x][i]) * i64(samples[i])
				out[x] = round2(s, 14 + shift)
			}
			continue
		}
		sums, differences: [H]i64 = ---, ---
		for i in 0 ..< H do sums[i], differences[i] = i64(samples[i]) + i64(samples[N - 1 - i]), i64(samples[i]) - i64(samples[N - 1 - i])
		for x in 0 ..< N {
			terms := x & 1 == 0 ? &sums : &differences
			s: i64
			for i in 0 ..< H do s += i64(rows[x][i]) * terms[i]
			out[x] = round2(s, 14 + shift)
		}
	}
}

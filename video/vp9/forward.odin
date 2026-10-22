package vp9

import common "../../common"
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
// four times it still fits i32. Row products also fit i32 in pairs before
// widening to i64 for the final sum.
// forward_transform's length assertion bounds every index below.
@(private)
forward_lossy :: proc(f: ^Forward_Transforms, block: []i32, tx_type: int, $TX: int) #no_bounds_check {
	N :: 4 << uint(TX)
	H :: N / 2
	L :: min(N, 8)
	Vec :: #simd[L]i32
	Acc :: #simd[L]i64
	vertical := tx_type == ADST_DCT || tx_type == ADST_ADST
	horizontal := tx_type == DCT_ADST || tx_type == ADST_ADST
	cols, rows := &f.basis[TX][int(vertical)], &f.basis[TX][int(horizontal)]

	// Columns: process L columns at a time and transpose L x L tiles into t_cols
	// so that t_cols[gb][x] holds sample x of rows gb * L ..< (gb + 1) * L.
	t_cols: [N / L][N]Vec = ---
	for jb := 0; jb < N; jb += L {
		col_out: [N]Vec = ---
		if vertical {
			input: [N]Vec = ---
			#unroll for i in 0 ..< N do input[i] = intrinsics.unaligned_load((^Vec)(&block[i * N + jb]))
			for y in 0 ..< N {
				acc: Vec
				for i in 0 ..< N do acc += Vec(cols[y][i]) * input[i]
				col_out[y] = simd.shr(acc * 4 + 8192, (#simd[L]u32)(14))
			}
		} else {
			sums, diffs: [H]Vec = ---, ---
			#unroll for i in 0 ..< H {
				a := intrinsics.unaligned_load((^Vec)(&block[i * N + jb]))
				b := intrinsics.unaligned_load((^Vec)(&block[(N - 1 - i) * N + jb]))
				sums[i], diffs[i] = a + b, a - b
			}
			for y := 0; y < N; y += 2 {
				acc0, acc1: Vec
				for i in 0 ..< H {
					acc0 += Vec(cols[y][i]) * sums[i]
					acc1 += Vec(cols[y + 1][i]) * diffs[i]
				}
				col_out[y] = simd.shr(acc0 * 4 + 8192, (#simd[L]u32)(14))
				col_out[y + 1] = simd.shr(acc1 * 4 + 8192, (#simd[L]u32)(14))
			}
		}
		#unroll for gb in 0 ..< N / L {
			tile: [L]Vec = ---
			#unroll for l in 0 ..< L do tile[l] = col_out[gb * L + l]
			tile = common.transpose(tile)
			#unroll for k in 0 ..< L do t_cols[gb][jb + k] = tile[k]
		}
	}

	// Rows: transform L rows at a time in parallel, pairing two i32 products
	// before widening to i64, then transpose L x L tiles back to block.
	shift :: uint(2 * (TX + 2) - min(6, TX + 4))
	for gb in 0 ..< N / L {
		src := &t_cols[gb]
		row_out: [N]Vec = ---
		if horizontal {
			for x in 0 ..< N {
				s: Acc
				for i := 0; i < N; i += 2 {
					p := Vec(rows[x][i]) * src[i] + Vec(rows[x][i + 1]) * src[i + 1]
					s += Acc(p)
				}
				row_out[x] = Vec(round2_lanes(s, 14 + shift))
			}
		} else {
			sums, diffs: [H]Vec = ---, ---
			#unroll for i in 0 ..< H do sums[i], diffs[i] = src[i] + src[N - 1 - i], src[i] - src[N - 1 - i]
			for x := 0; x < N; x += 2 {
				s0, s1: Acc
				for i := 0; i < H; i += 2 {
					p0 := Vec(rows[x][i]) * sums[i] + Vec(rows[x][i + 1]) * sums[i + 1]
					p1 := Vec(rows[x + 1][i]) * diffs[i] + Vec(rows[x + 1][i + 1]) * diffs[i + 1]
					s0 += Acc(p0)
					s1 += Acc(p1)
				}
				row_out[x] = Vec(round2_lanes(s0, 14 + shift))
				row_out[x + 1] = Vec(round2_lanes(s1, 14 + shift))
			}
		}
		#unroll for jb in 0 ..< N / L {
			tile: [L]Vec = ---
			#unroll for k in 0 ..< L do tile[k] = row_out[jb * L + k]
			tile = common.transpose(tile)
			#unroll for l in 0 ..< L do intrinsics.unaligned_store((^Vec)(&block[(gb * L + l) * N + jb * L]), tile[l])
		}
	}
}

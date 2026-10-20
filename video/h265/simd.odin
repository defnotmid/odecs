package h265

import "base:intrinsics"
import "core:simd"

// ---------------------------------------------------------------------------
// Shared SIMD kernels. The arithmetic is the same scalar integer arithmetic;
// only the order the sums are accumulated in differs, which cannot change a
// result because no intermediate overflows i32.
// ---------------------------------------------------------------------------

// inverse_transform_vec is 8.6.4.2 with the inner products in SIMD lanes.
// `basis` is the row-major inverse basis, `src` the coefficients and `dst` the
// residual, both row-major. The rounding and the two clamps match the scalar
// matrix product exactly.
@(private)
inverse_transform_vec :: proc(
	$N: int,
	basis: []i32,
	src: []i16,
	dst: []i16,
	bitdepth: int,
) #no_bounds_check {
	tmp: [N * N]i32 = ---

	shift1 := u32(7)
	round1 := i32(1) << (shift1 - 1)
	shift2 := u32(12 - (bitdepth - 8))
	round2 := i32(1) << (shift2 - 1)

	r1 := (#simd[N]i32)(round1)
	r2 := (#simd[N]i32)(round2)
	lo := (#simd[N]i32)(-32768)
	hi := (#simd[N]i32)(32767)
	sh1 := (#simd[N]u32)(shift1)
	sh2 := (#simd[N]u32)(shift2)

	// First dimension: P[j][k] = sum_i basis[i][k] * src[i][j].
	for j in 0 ..< N {
		acc := (#simd[N]i32)(0)

		for i in 0 ..< N {
			b := intrinsics.unaligned_load((^#simd[N]i32)(&basis[i * N]))
			acc = simd.add(acc, simd.mul(b, (#simd[N]i32)(i32(src[i * N + j]))))
		}

		acc = simd.shr(simd.add(acc, r1), sh1)
		intrinsics.unaligned_store((^#simd[N]i32)(&tmp[j * N]), simd.clamp(acc, lo, hi))
	}

	// Second dimension: dst[j][k] = sum_i basis[i][k] * P[i][j].
	for j in 0 ..< N {
		acc := (#simd[N]i32)(0)

		for i in 0 ..< N {
			b := intrinsics.unaligned_load((^#simd[N]i32)(&basis[i * N]))
			acc = simd.add(acc, simd.mul(b, (#simd[N]i32)(tmp[i * N + j])))
		}

		acc = simd.clamp(simd.shr(simd.add(acc, r2), sh2), lo, hi)
		intrinsics.unaligned_store((^#simd[N]i16)(&dst[j * N]), (#simd[N]i16)(acc))
	}
}

// The even-frequency half of each DCT is the next smaller DCT. Odd
// frequencies are antisymmetric, so only the first half needs a dot product.
@(private)
inverse_dct_line :: #force_inline proc(
	$N: int,
	src: []$T,
	pitch: int,
) -> #simd[N]i32 #no_bounds_check {
	when N == 2 {
		a, b := i32(src[0]) * 64, i32(src[pitch]) * 64
		return #simd[2]i32{a + b, a - b}
	} else {
		H :: N / 2
		even := inverse_dct_line(H, src, pitch * 2)
		odd := (#simd[H]i32)(0)
		basis := basis_for(N)
		for i in 0 ..< H {
			b := intrinsics.unaligned_load((^#simd[H]i32)(&basis[(2 * i + 1) * N]))
			odd += b * (#simd[H]i32)(i32(src[(2 * i + 1) * pitch]))
		}
		out: [N]i32 = ---
		intrinsics.unaligned_store((^#simd[H]i32)(&out[0]), even + odd)
		intrinsics.unaligned_store((^#simd[H]i32)(&out[H]), simd.lanes_reverse(even - odd))
		return intrinsics.unaligned_load((^#simd[N]i32)(&out[0]))
	}
}

@(private)
inverse_dct :: proc($N: int, src, dst: []i16, bitdepth: int) #no_bounds_check {
	tmp: [N * N]i32 = ---
	lo, hi := (#simd[N]i32)(-32768), (#simd[N]i32)(32767)
	for j in 0 ..< N {
		acc := inverse_dct_line(N, src[j:], N)
		acc = simd.clamp(simd.shr(acc + (#simd[N]i32)(64), (#simd[N]u32)(7)), lo, hi)
		intrinsics.unaligned_store((^#simd[N]i32)(&tmp[j * N]), acc)
	}
	shift := u32(20 - bitdepth)
	round := i32(1) << (shift - 1)
	for j in 0 ..< N {
		acc := inverse_dct_line(N, tmp[j:], N)
		acc = simd.clamp(simd.shr(acc + (#simd[N]i32)(round), (#simd[N]u32)(shift)), lo, hi)
		intrinsics.unaligned_store((^#simd[N]i16)(&dst[j * N]), (#simd[N]i16)(acc))
	}
}

// inverse_transform is 8.6.4.2 with the inner products in SIMD lanes. It is
// bit-identical to the scalar matrix-product form and is the shared inverse
// transform for both the decoder and encoder reconstruction. Sizes are 4, 8,
// 16 and 32.
inverse_transform :: proc(size: int, src: []i16, dst: []i16, bitdepth: int) #no_bounds_check {
	switch size {
	case 4:
		inverse_dct(4, src, dst, bitdepth)
	case 8:
		inverse_dct(8, src, dst, bitdepth)
	case 16:
		inverse_dct(16, src, dst, bitdepth)
	case:
		inverse_dct(32, src, dst, bitdepth)
	}
}

// inverse_transform_dst4 is the 4x4 DST-VII inverse of 8.6.4.1 for luma intra
// blocks: the same separable process with the DST basis.
inverse_transform_dst4 :: proc(src: []i16, dst: []i16, bitdepth: int) #no_bounds_check {
	inverse_transform_vec(4, DST_4[:], src, dst, bitdepth)
}

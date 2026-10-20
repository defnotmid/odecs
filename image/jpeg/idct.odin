package jpeg

import common "../../common"
import "base:intrinsics"
import "core:simd"

// The Loeffler-Ligtenberg-Moschytz IDCT in integers, rounded as
// libjpeg-turbo's default (ISLOW) rounds: constants with 13 fractional
// bits; columns first, keeping 2 extra bits; then rows, rounded, biased by
// 128 and clamped to 0..255. Coefficients are dequantized on the way in, in
// 32 bits. The eight columns go through as the
// lanes of eight row vectors, then the rows likewise after a transpose; the
// result is libjpeg-turbo's exactly (its SIMD versions are too).
@(private)
idct_block :: proc(out: []u8, stride: int, block: ^[64]i16, quant: ^[64]u16) #no_bounds_check {
	V :: #simd[8]i32
	r: [8]V
	#unroll for i in 0 ..< 8 {
		coeffs := cast(V)intrinsics.unaligned_load((^#simd[8]i16)(&block[i * 8]))
		r[i] = coeffs * cast(V)intrinsics.unaligned_load((^#simd[8]u16)(&quant[i * 8]))
	}
	// A block of only its DC coefficient comes out flat: both passes on one
	// value are a shift by 5, rounded.
	ac := simd.replace(r[0], 0, 0)
	#unroll for i in 1 ..< 8 do ac |= r[i]
	if simd.reduce_or(ac) == 0 {
		v := (simd.extract(r[0], 0) * 4 + 16) >> 5 + 128
		row := (#simd[8]u8)(u8(clamp(v, 0, 255)))
		#unroll for i in 0 ..< 8 do intrinsics.unaligned_store((^#simd[8]u8)(&out[i * stride]), row)
		return
	}
	r = common.transpose(idct_pass(r, 1 << 10, 11))
	r = common.transpose(idct_pass(r, 1 << 17 + 128 << 18, 18))
	#unroll for i in 0 ..< 8 {
		intrinsics.unaligned_store((^#simd[8]u8)(&out[i * stride]), cast(#simd[8]u8)simd.clamp(r[i], 0, 255))
	}
}

// One 1D pass over eight lines at once: s[k] holds sample k of each line.
@(private)
idct_pass :: #force_inline proc "contextless" (s: [8]#simd[8]i32, $BIAS: i32, $SHIFT: u32) -> (o: [8]#simd[8]i32) {
	// Even part.
	z1 := (s[2] + s[6]) * 4433
	t2 := z1 + s[6] * -15137
	t3 := z1 + s[2] * 6270
	t0 := simd.shl(s[0] + s[4], 13)
	t1 := simd.shl(s[0] - s[4], 13)
	by := (#simd[8]u32)(SHIFT)
	x10 := t0 + t3 + BIAS
	x13 := t0 - t3 + BIAS
	x11 := t1 + t2 + BIAS
	x12 := t1 - t2 + BIAS
	// Odd part.
	a0, a1, a2, a3 := s[7], s[5], s[3], s[1]
	q1 := a0 + a3
	q2 := a1 + a2
	q3 := a0 + a2
	q4 := a1 + a3
	z5 := (q3 + q4) * 9633
	a0 *= 2446
	a1 *= 16819
	a2 *= 25172
	a3 *= 12299
	q1 *= -7373
	q2 *= -20995
	q3 = q3 * -16069 + z5
	q4 = q4 * -3196 + z5
	a0 += q1 + q3
	a1 += q2 + q4
	a2 += q2 + q3
	a3 += q1 + q4
	o[0] = simd.shr(x10 + a3, by)
	o[7] = simd.shr(x10 - a3, by)
	o[1] = simd.shr(x11 + a2, by)
	o[6] = simd.shr(x11 - a2, by)
	o[2] = simd.shr(x12 + a1, by)
	o[5] = simd.shr(x12 - a1, by)
	o[3] = simd.shr(x13 + a0, by)
	o[4] = simd.shr(x13 - a0, by)
	return
}

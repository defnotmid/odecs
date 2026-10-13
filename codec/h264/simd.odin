package h264

import "base:intrinsics"
import "core:simd"

// ---------------------------------------------------------------------------
// Vector helpers for the pixel kernels: N unsigned 8-bit samples are widened
// to 16-bit lanes, processed, clamped and narrowed back.
// ---------------------------------------------------------------------------

load_lanes :: #force_inline proc($N: int, p: [^]u8) -> #simd[N]i16 #no_bounds_check {
	return (#simd[N]i16)(intrinsics.unaligned_load((^#simd[N]u8)(p)))
}

clamp_lanes :: #force_inline proc(v: #simd[$N]i16) -> #simd[N]i16 {
	return simd.clamp(v, 0, 255)
}

shr_lanes :: #force_inline proc(v: #simd[$N]i16, $bits: u16) -> #simd[N]i16 {
	return simd.shr(v, (#simd[N]u16)(bits))
}

// (a + b + 1) >> 1 per lane
average_lanes :: #force_inline proc(a, b: #simd[$N]i16) -> #simd[N]i16 {
	return shr_lanes(simd.add(simd.add(a, b), 1), 1)
}

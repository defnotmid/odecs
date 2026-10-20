package h264

import "base:intrinsics"
import "core:simd"

// ---------------------------------------------------------------------------
// Vector helpers for the pixel kernels: N samples (u8, or u16 of at most 12
// bits) are widened to 16-bit lanes, processed, clamped and narrowed back.
// ---------------------------------------------------------------------------

load_lanes :: #force_inline proc($N: int, p: [^]$T) -> #simd[N]i16 #no_bounds_check {
	return (#simd[N]i16)(intrinsics.unaligned_load((^#simd[N]T)(p)))
}

store_lanes :: #force_inline proc(p: [^]$T, v: #simd[$N]i16) #no_bounds_check {
	intrinsics.unaligned_store((^#simd[N]T)(p), (#simd[N]T)(v))
}

clamp_lanes :: #force_inline proc(v: #simd[$N]$E, pixel_max: E = 255) -> #simd[N]E {
	return simd.clamp(v, 0, (#simd[N]E)(pixel_max))
}

shr_lanes :: #force_inline proc(v: #simd[$N]$E, $bits: uint) -> #simd[N]E {
	return simd.shr(v, (#simd[N]intrinsics.type_integer_to_unsigned(E))(bits))
}

// (a + b + 1) >> 1 per lane
average_lanes :: #force_inline proc(a, b: #simd[$N]$E) -> #simd[N]E {
	return shr_lanes(simd.add(simd.add(a, b), 1), 1)
}

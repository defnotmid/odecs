package h265

import "core:testing"

// Independent full matrix product: no butterfly or SIMD intermediates shared
// with the production inverse. Exercise every impulse as well as dense input
// and both intermediate and final saturation.
@(test)
inverse_transform_matrix_oracle :: proc(t: ^testing.T) {
	seed := u32(73)
	for n in ([4]int{4, 8, 16, 32}) {
		for dst4 in ([2]bool{false, true}) {
			if dst4 && n != 4 do continue
			basis := dst4 ? DST_4[:] : basis_for(n)
			for depth in ([3]int{8, 10, 12}) {
				for trial in 0 ..< n * n + 32 {
					src, actual, expected: [1024]i16
					tmp: [1024]i32
					if trial < n * n {
						src[trial] = trial & 1 == 0 ? -32768 : 32767
					} else {
						for i in 0 ..< n * n {
							seed = seed * 1664525 + 1013904223
							src[i] = i16(seed >> 16)
						}
					}
					for j in 0 ..< n {
						for k in 0 ..< n {
							sum: i32
							for i in 0 ..< n do sum += basis[i * n + k] * i32(src[i * n + j])
							tmp[j * n + k] = clamp((sum + 64) >> 7, -32768, 32767)
						}
					}
					shift := uint(20 - depth)
					for j in 0 ..< n {
						for k in 0 ..< n {
							sum: i32
							for i in 0 ..< n do sum += basis[i * n + k] * tmp[i * n + j]
							expected[j * n + k] = i16(
								clamp((sum + (1 << (shift - 1))) >> shift, -32768, 32767),
							)
						}
					}
					if dst4 {
						inverse_transform_dst4(src[:n * n], actual[:n * n], depth)
					} else {
						inverse_transform(n, src[:n * n], actual[:n * n], depth)
					}
					if !testing.expect_value(t, actual, expected) do return
				}
			}
		}
	}
}

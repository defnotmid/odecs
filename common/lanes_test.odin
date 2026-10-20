package common

import "core:simd"
import "core:testing"

@(test)
transpose_swaps_rows_and_columns :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, $L: int, $E: typeid) {
		V :: #simd[L]E
		r: [L]V
		for i in 0 ..< L {
			a: [L]E
			for j in 0 ..< L do a[j] = E(i * L + j)
			r[i] = simd.from_array(a)
		}
		c := transpose(r)
		for i in 0 ..< L do for j in 0 ..< L do testing.expect_value(t, simd.to_array(c[i])[j], E(j * L + i))
		testing.expect_value(t, transpose(c), r)
	}
	check(t, 4, i32)
	check(t, 4, u16)
	check(t, 8, i16)
	check(t, 8, i32)
	check(t, 8, i64)
}

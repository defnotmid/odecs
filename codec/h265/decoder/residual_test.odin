package h265_decoder

import hevc ".."
import "core:testing"

@(test)
test_residual_scan_positions :: proc(t: ^testing.T) {
	// Cover every last-significant coefficient in every transform size/order,
	// including the plain 8x8 group scan used by 32x32 transforms.
	for order in 0 ..< 3 {
		for log2 in 2 ..= 5 {
			n := 1 << uint(log2)
			groups := group_scan(hevc.Scan_Order(order), log2)
			coeffs := scan_table_ext(hevc.Scan_Order(order), 2)
			for y in 0 ..< n {
				for x in 0 ..< n {
					g :=
						RESIDUAL_SCAN_POSITIONS.group[log2 - 2][order][(y >> 2) * (n >> 2) + (x >> 2)]
					c := RESIDUAL_SCAN_POSITIONS.coeff[order][(y & 3) * 4 + (x & 3)]
					gx, gy := int(groups[g]) % (n >> 2), int(groups[g]) / (n >> 2)
					cx, cy := int(coeffs[c] & 3), int(coeffs[c] >> 2)
					testing.expectf(
						t,
						gx * 4 + cx == x && gy * 4 + cy == y,
						"order=%d log2=%d coefficient=%d,%d",
						order,
						log2,
						x,
						y,
					)
				}
			}
		}
	}
}

@(test)
test_residual_rejects_invalid_block_bounds :: proc(t: ^testing.T) {
	// Rejection must happen before dereferencing CABAC/parameter pointers.
	coefficients: [1024]i32
	for log2 in ([5]int{-1, 0, 1, 6, 63}) {
		_, _, _, ok := decode_residual(
			nil,
			nil,
			nil,
			nil,
			coefficients[:],
			Residual_Block{log2_size = log2},
			nil,
		)
		testing.expect(t, !ok)
	}
	for component in ([2]int{-1, 3}) {
		_, _, _, ok := decode_residual(
			nil,
			nil,
			nil,
			nil,
			coefficients[:],
			Residual_Block{log2_size = 2, c_idx = component},
			nil,
		)
		testing.expect(t, !ok)
	}
	for log2 in 2 ..= 5 {
		_, _, _, ok := decode_residual(
			nil,
			nil,
			nil,
			nil,
			coefficients[:(1 << uint(2 * log2)) - 1],
			Residual_Block{log2_size = log2},
			nil,
		)
		testing.expect(t, !ok)
	}
}

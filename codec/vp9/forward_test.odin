package vp9

import "core:testing"

@(test)
forward_inverse_pair :: proc(t: ^testing.T) {
	f: Forward_Transforms
	init_forward_transforms(&f)
	for tx in 0 ..< 4 {
		end := tx == TX_32X32 ? 1 : 4
		n := 4 << uint(tx)
		for kind in 0 ..< end {
			storage, original: [1024]i32
			block := storage[:n * n]
			for &v, i in block {v = i32((i * 137 + i / n * 23) % 511 - 255); original[i] = v}
			forward_transform(&f, block, tx, kind, false)
			inverse_transform(block, uint(tx + 2), kind, false, n)
			for v, i in block do if !testing.expect(t, abs(v - original[i]) <= 2, "lossy analysis/synthesis error exceeds two samples") do return
		}
	}
	for pattern in 0 ..< 100 {
		b, original: [16]i32
		for &v, i in b {v = i32((i * 173 + pattern * 37) % 511 - 255); original[i] = v}
		forward_transform(&f, b[:], 0, 0, true)
		inverse_transform(b[:], 2, 0, true, 4)
		testing.expect_value(t, b, original)
	}
}

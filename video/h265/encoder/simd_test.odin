package h265_encoder

import "core:testing"

@(test)
test_sad_geometry_scalar_parity :: proc(t: ^testing.T) {
	// Unequal padded strides and shifted starts keep the row geometry visible.
	// Contrasting padding catches a vector/tail loop reading beyond its width.
	a: [37 * 33 + 5]Sample
	b: [43 * 33 + 7]Sample
	state: u32 = 0x75363291
	for depth in ([2]int{8, 10}) {
		limit := Sample((1 << uint(depth)) - 1)
		for w in 0 ..= 32 do for h in ([7]int{0, 1, 2, 7, 16, 17, 32}) do for pattern in 0 ..< 4 {
			for &v in a do v = 0xffff
			for &v in b do v = 0
			want: u32
			for y in 0 ..< h do for x in 0 ..< w {
				av, bv: Sample
				switch pattern {
				case 0:
					av, bv = limit, 0
				case 1:
					av, bv = limit, limit
				case 2:
					av = (x + y) % 2 == 0 ? limit : 0
					bv = limit - av
				case 3:
					state ~= state << 13
					state ~= state >> 17
					state ~= state << 5
					av = Sample(state & u32(limit))
					state ~= state << 13
					state ~= state >> 17
					state ~= state << 5
					bv = Sample(state & u32(limit))
				}
				a[5 + y * 37 + x] = av
				b[7 + y * 43 + x] = bv
				want += u32(abs(i32(av) - i32(bv)))
			}
			actual := sad_u16(a[5:], 37, b[7:], 43, w, h)
			if actual != want {
				testing.expectf(t, false, "SAD depth=%d width=%d height=%d pattern=%d actual=%d expected=%d", depth, w, h, pattern, actual, want)
				return
			}
		}
	}
}

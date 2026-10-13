package h265_encoder

import "core:testing"

@(test)
test_intra_square_transpose_scalar_oracle :: proc(t: ^testing.T) {
	input: [72 * 65 + 17]Sample
	state: u32 = 0x517D903A
	// 855 full-buffer controls cover native squares, a pure 64x64 square and
	// the scalar fallback. The 64x64 case does not admit that prediction size.
	for width in ([19]int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 13, 15, 16, 17, 31, 32, 33, 63, 64}) {
		for padding in ([3]int{0, 1, 7}) {
			stride := width + padding
			for start in ([3]int{0, 1, 9}) {
				for pattern in 0 ..< 5 {
					for &value, index in input do value = Sample((index * 73 + index * index * 11 + 0xA5A5) & 0xffff)
					for y in 0 ..< width {
						for x in 0 ..< width {
							value: Sample
							switch pattern {
							case 0:
								value = 0
							case 1:
								value = 0xffff
							case 2:
								value = Sample(y * 67 + x)
							case 3:
								value = (x + y) % 2 == 0 ? 0xffff : 0
							case 4:
								state ~= state << 13
								state ~= state >> 17
								state ~= state << 5
								value = Sample(state & 0xffff)
							}
							input[start + y * stride + x] = value
						}
					}
					got, want := input, input
					// Read an immutable source at transposed coordinates. This
					// shares neither triangular swaps nor register permutations.
					for y in 0 ..< width do for x in 0 ..< width do want[start + y * stride + x] = input[start + x * stride + y]
					transpose_intra_square(got[start:], width, stride)
					for value, index in got {
						if value != want[index] {
							testing.expectf(
								t,
								false,
								"intra transpose width=%d stride=%d start=%d pattern=%d index=%d got=%d want=%d",
								width,
								stride,
								start,
								pattern,
								index,
								value,
								want[index],
							)
							return
						}
					}
				}
			}
		}
	}
}

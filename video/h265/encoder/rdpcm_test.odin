package h265_encoder

import "core:testing"

// forward_rdpcm subtracts in reverse scan order so every difference reads an
// original neighbour, and inverse_rdpcm is the matching accumulation. The
// known-value cases pin the direction: mode 10 is horizontal (difference to
// the left), mode 26 is vertical (difference above).
@(test)
test_rdpcm_round_trip :: proc(t: ^testing.T) {
	hor := [16]i16{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	hor_want := [16]i16{1, 1, 1, 1, 5, 1, 1, 1, 9, 1, 1, 1, 13, 1, 1, 1}
	forward_rdpcm(hor[:], 4, false)
	testing.expectf(t, hor == hor_want, "horizontal forward: %v", hor)
	inverse_rdpcm(hor[:], 4, false)
	testing.expect(t, hor == [16]i16{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16})

	ver := [16]i16{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	ver_want := [16]i16{1, 2, 3, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4}
	forward_rdpcm(ver[:], 4, true)
	testing.expectf(t, ver == ver_want, "vertical forward: %v", ver)
	inverse_rdpcm(ver[:], 4, true)
	testing.expect(t, ver == [16]i16{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16})

	// A round trip over several sizes and both directions.
	for size in ([]int{4, 8, 16}) {
		for vertical in ([]bool{false, true}) {
			src: [256]i16
			for i in 0 ..< size * size do src[i] = i16(i * 71 % 997 - 498)
			got := src
			forward_rdpcm(got[:size * size], size, vertical)
			inverse_rdpcm(got[:size * size], size, vertical)
			match := true
			for i in 0 ..< size * size {
				if got[i] != src[i] {
					match = false
					break
				}
			}
			testing.expectf(t, match, "round trip size %d vertical %v", size, vertical)
		}
	}
}

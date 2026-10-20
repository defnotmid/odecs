package h265_decoder

import enc "../encoder"
import "core:testing"

// Compare all chroma modes against the independently implemented decoder,
// including the 4:4:4-only reference smoothing and the unfiltered boundaries.
@(test)
test_chroma_intra_prediction :: proc(t: ^testing.T) {
	for layout in ([]enc.Chroma_Layout{.YUV_420, .YUV_422, .YUV_444}) {
		for depth in ([]int{8, 10}) {
			for log2 in 2 ..= 5 {
				n := 1 << uint(log2)
				for mode in 0 ..< 35 {
					refs: enc.Intra_Refs
					r := Ref_Samples {
						n = n,
					}
					for i in 0 ..= 2 * n {
						refs.top[i] = enc.Sample((i * 71 + i * i * 13) & ((1 << uint(depth)) - 1))
						refs.left[i] = enc.Sample((i * 37 + i * i * 19) & ((1 << uint(depth)) - 1))
						r.s[2 * n + i] = i32(refs.top[i])
						r.s[2 * n - i] = i32(refs.left[i])
					}
					s := SPS {
						chroma_format_idc = enc.layout_idc(layout),
					}
					filter_ref(&r, mode, 1, depth, &s)
					got, want: [32 * 32]enc.Sample
					enc.intra_predict(&refs, log2, u8(mode), .U, got[:], n, depth, layout)
					intra_predict(want[:], 0, n, &r, mode, 1, depth, false)
					testing.expectf(
						t,
						got == want,
						"layout %v depth %d size %d mode %d",
						layout,
						depth,
						n,
						mode,
					)
				}
			}
		}
	}
}

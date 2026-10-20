package common

import "core:simd"

// Swaps the rows and columns of an L x L tile held as L vectors of L lanes:
// lane j of the result's vector i is lane i of r[j]. Eight lanes: Odin's
// simd.interleave zips the rows into column order in one operation (register
// shuffles; a matrix transpose would go through memory). Four lanes: two
// rounds of pairwise shuffles stay within 128-bit lanes, where a single
// interleave crosses them and measured slower in H.264's 4x4 transform.
transpose :: #force_inline proc "contextless" (r: [$L]$V/#simd[L]$E) -> [L]V {
	when L == 4 {
		lo01, hi01 := simd.shuffle(r[0], r[1], 0, 4, 1, 5), simd.shuffle(r[0], r[1], 2, 6, 3, 7)
		lo23, hi23 := simd.shuffle(r[2], r[3], 0, 4, 1, 5), simd.shuffle(r[2], r[3], 2, 6, 3, 7)
		return {simd.shuffle(lo01, lo23, 0, 1, 4, 5), simd.shuffle(lo01, lo23, 2, 3, 6, 7), simd.shuffle(hi01, hi23, 0, 1, 4, 5), simd.shuffle(hi01, hi23, 2, 3, 6, 7)}
	} else when L == 8 {
		return transmute([8]V)simd.interleave(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7])
	} else {
		#panic("transpose takes 4 or 8 lanes (one interleave holds at most 64)")
	}
}

package vp9

import "core:testing"

@(test)
scans_are_permutations :: proc(t: ^testing.T) {
	scans := [?][]u16 {
		DEFAULT_SCAN_4X4[:], ROW_SCAN_4X4[:], COL_SCAN_4X4[:],
		DEFAULT_SCAN_8X8[:], ROW_SCAN_8X8[:], COL_SCAN_8X8[:],
		DEFAULT_SCAN_16X16[:], ROW_SCAN_16X16[:], COL_SCAN_16X16[:],
		DEFAULT_SCAN_32X32[:],
	}
	for scan in scans {
		seen: [1024]bool
		for p in scan {
			testing.expect(t, int(p) < len(scan) && !seen[p])
			seen[p] = true
		}
	}
}

@(test)
default_probabilities_are_valid :: proc(t: ^testing.T) {
	p: Probabilities
	default_probabilities(&p)
	for tx in 0 ..< TX_SIZES do for i in 0 ..< 2 do for j in 0 ..< 2 do for band in 0 ..< COEF_BANDS {
		for ctx in 0 ..< (band == 0 ? 3 : 6) do for node in 0 ..< 3 do testing.expect(t, p.coef[tx][i][j][band][ctx][node] > 0)
	}
	for row in KF_Y_MODE_PROBS do for probs in row do for v in probs do testing.expect(t, v > 0)
}

// A DC-only block reconstructs to a constant for every DCT size.
@(test)
dc_only_dct_is_flat :: proc(t: ^testing.T) {
	block: [32 * 32]i32
	for n in uint(2) ..= 5 {
		size := 1 << n
		coefs := block[:size * size]
		for &c in coefs do c = 0
		coefs[0] = 1000
		inverse_transform(coefs, n, DCT_DCT, false, 1)
		for v in coefs do testing.expect_value(t, v, coefs[0])
		testing.expect(t, coefs[0] != 0)
	}
}

@(test)
adaptation_without_counts_keeps_probabilities :: proc(t: ^testing.T) {
	p: Probabilities
	default_probabilities(&p)
	before := p
	counts: Counts
	adapt_coef_probs(&p, &counts, false, false)
	adapt_noncoef_probs(&p, &counts, true, true, true)
	testing.expect(t, p == before)
}

// Loop filter waves cover every superblock once, each after its left and
// upper-right neighbours.
@(test)
filter_waves_cover_each_superblock_once :: proc(t: ^testing.T) {
	for rows in 1 ..= 6 do for cols in 1 ..= 9 {
		wave_of: [6][9]int
		seen: [6][9]int
		for wave in 0 ..< 2 * (rows - 1) + cols {
			first, count := wave_range(wave, rows, cols)
			for r in first ..< first + count {
				c := wave - 2 * r
				testing.expect(t, c >= 0 && c < cols)
				seen[r][c] += 1
				wave_of[r][c] = wave
			}
		}
		for r in 0 ..< rows do for c in 0 ..< cols {
			testing.expect_value(t, seen[r][c], 1)
			if c > 0 do testing.expect(t, wave_of[r][c - 1] < wave_of[r][c])
			if r > 0 && c + 1 < cols do testing.expect(t, wave_of[r - 1][c + 1] < wave_of[r][c])
		}
	}
}

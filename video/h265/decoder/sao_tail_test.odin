package h265_decoder

import "core:testing"

// A scalar oracle for one sample of 8.7.3: band index, or Table 8-13's edge
// category from comparisons, then the clipped offset.
@(private)
sao_sample_oracle :: proc(v, va, vb: i32, p: ^Sao_Params, shift: int, maximum: i32) -> i32 {
	index := -1
	if p.type_idx == SAO_BAND {
		if band := (int(v >> uint(shift)) - p.band) & 31; band < 4 do index = band
	} else {
		category := 0
		if v < va do category -= 1
		if v > va do category += 1
		if v < vb do category -= 1
		if v > vb do category += 1
		by_category := [5]int{0, 1, -1, 2, 3}
		index = by_category[category + 2]
	}
	if index < 0 do return v
	return clamp(v + p.offset[index], 0, maximum)
}

// Runs of every length cover each vector width and tail; samples outside the
// run keep their guard values.
@(private = "file")
check_runs :: proc(t: ^testing.T, $Sample: typeid, depth: int) -> bool {
	maximum := i32(1 << uint(depth)) - 1
	scale := uint(max(depth - 10, 0))
	limit := (i32(1 << uint(min(depth, 10) - 5)) - 1) << scale
	offset_sets := [][4]i32 {
		{0, 0, 0, 0},
		{7, 3, -5, -7},
		{-7, -3, 5, 7},
		{limit, limit, -limit, -limit},
	}
	// Band, then the four edge classes as index offsets in rows of 96.
	for kind in 0 ..< 5 {
		type_idx := kind == 0 ? SAO_BAND : SAO_EDGE
		neighbours := [5]int{0, 1, 96, 97, 95}
		a, b := -neighbours[kind], neighbours[kind]
		for n in 0 ..= 80 {
			for pattern in 0 ..< 7 {
				for offsets in offset_sets {
					p := Sao_Params {
						type_idx = type_idx,
						band     = pattern * 5,
						offset   = offsets,
					}
					// Three rows: every comparison sign, equal samples and both
					// clipping limits appear inside a short run and its tail.
					source, actual: [3 * 96]Sample
					for i in 0 ..< len(source) {
						value := i32((i * 47 + pattern * 31) & int(maximum))
						if pattern == 1 do value = 0
						if pattern == 2 do value = maximum
						if pattern >= 3 do value = maximum / 2 + i32(i % 3) - 1
						source[i] = Sample(value)
						actual[i] = Sample(0xa5 + i)
					}
					expected := actual
					start := 96 + 5
					sao_run(actual[:], source[:], start, n, a, b, &p, depth - 5, maximum)
					for i in start ..< start + n {
						v := i32(source[i])
						expected[i] = Sample(
							sao_sample_oracle(
								v,
								i32(source[i + a]),
								i32(source[i + b]),
								&p,
								depth - 5,
								maximum,
							),
						)
					}
					if actual != expected {
						testing.expectf(
							t,
							false,
							"SAO %v kind=%d depth=%d n=%d pattern=%d offsets=%v",
							typeid_of(Sample),
							kind,
							depth,
							n,
							pattern,
							offsets,
						)
						return false
					}
				}
			}
		}
	}
	return true
}

@(test)
test_sao_run_all_lengths_categories_and_clipping :: proc(t: ^testing.T) {
	_ =
		check_runs(t, u8, 8) &&
		check_runs(t, u16, 8) &&
		check_runs(t, u16, 10) &&
		check_runs(t, u16, 12)
}

@(test)
test_sao_offset_scales_follow_bit_depth :: proc(t: ^testing.T) {
	for depth in 8 ..= 12 {
		s := SPS {
			bit_depth_luma   = u8(depth),
			bit_depth_chroma = u8(depth),
		}
		bound := u32(max(0, depth - 10))
		for scale in u32(0) ..= 4 {
			luma := PPS {
				log2_sao_offset_scale_luma = scale,
			}
			chroma := PPS {
				log2_sao_offset_scale_chroma = scale,
			}
			testing.expect_value(t, sao_offset_scales_valid(&luma, &s), scale <= bound)
			testing.expect_value(t, sao_offset_scales_valid(&chroma, &s), scale <= bound)
		}
	}
}

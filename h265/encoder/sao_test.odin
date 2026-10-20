package h265_encoder

import "core:testing"

// Retain the removed pixel-scan definition independently of the statistics
// algebra. In particular, costs are unclipped and band selection never wraps.
sao_test_pixel_cost :: proc(
	orig, rec: Plane(Sample),
	x0, y0, w, h, shift: int,
	info: ^Sao_Info,
	component: int,
) -> i64 {
	if info.type == .None do return 0
	dist: i64
	obase := component * 5
	if info.type == .Band {
		for y in 0 ..< h {
			for x in 0 ..< w {
				r := i64(rec.data[rec.offset + (y0 + y) * rec.stride + x0 + x])
				o := i64(orig.data[orig.offset + (y0 + y) * orig.stride + x0 + x])
				band := (r >> uint(shift)) - i64(info.band_position[component])
				if band < 0 || band > 3 do continue
				offset := i64(info.offsets[obase + 1 + int(band)])
				diff := o - r
				delta := diff - offset
				dist += delta * delta - diff * diff
			}
		}
		return dist
	}

	// Direction vectors are local to the oracle; only the category numbering
	// table is shared with the syntax owner's normative ordering.
	directions := [4][2][2]int {
		{{-1, 0}, {1, 0}},
		{{0, -1}, {0, 1}},
		{{-1, -1}, {1, 1}},
		{{1, -1}, {-1, 1}},
	}
	direction := directions[int(info.eo_class)]
	for y in 1 ..< h - 1 {
		for x in 1 ..< w - 1 {
			px, py := x0 + x, y0 + y
			c := i64(rec.data[rec.offset + py * rec.stride + px])
			a := i64(
				rec.data[rec.offset + (py + direction[0][1]) * rec.stride + px + direction[0][0]],
			)
			b := i64(
				rec.data[rec.offset + (py + direction[1][1]) * rec.stride + px + direction[1][0]],
			)
			sa := c > a ? 1 : (c < a ? -1 : 0)
			sb := c > b ? 1 : (c < b ? -1 : 0)
			cat := int(SAO_EO_IDX_TO_CAT[2 + sa + sb])
			offset := i64(info.offsets[obase + cat])
			o := i64(orig.data[orig.offset + py * orig.stride + px])
			diff := o - c
			delta := diff - offset
			dist += delta * delta - diff * diff
		}
	}
	return dist
}

sao_test_collect_stats :: proc(orig, rec: Plane(Sample), x0, y0, w, h, shift: int) -> Sao_Stats {
	stats: Sao_Stats
	sao_calc_bands(orig, rec, x0, y0, w, h, shift, &stats.bands)
	sao_calc_edges(orig, rec, x0, y0, w, h, &stats)
	return stats
}

// Walk each direction independently, with local address/category definitions.
// Comparing every bin catches errors hidden by zero or cancelling offsets.
sao_test_accumulate_edges :: proc(orig, rec: Plane(Sample), x0, y0, w, h: int, stats: ^Sao_Stats) {
	directions := [4][2][2]int {
		{{-1, 0}, {1, 0}},
		{{0, -1}, {0, 1}},
		{{-1, -1}, {1, 1}},
		{{1, -1}, {-1, 1}},
	}
	categories := [5]int{1, 2, 0, 3, 4}
	for direction, eo in directions {
		for y in 1 ..< h - 1 {
			for x in 1 ..< w - 1 {
				px, py := x0 + x, y0 + y
				c := i32(rec.data[rec.offset + py * rec.stride + px])
				a := i32(
					rec.data[rec.offset + (py + direction[0][1]) * rec.stride + px + direction[0][0]],
				)
				b := i32(
					rec.data[rec.offset + (py + direction[1][1]) * rec.stride + px + direction[1][0]],
				)
				sa := c > a ? 1 : (c < a ? -1 : 0)
				sb := c > b ? 1 : (c < b ? -1 : 0)
				cat := categories[2 + sa + sb]
				o := i32(orig.data[orig.offset + py * orig.stride + px])
				stats.edge_sum[eo][cat] += o - c
				stats.edge_count[eo][cat] += 1
			}
		}
	}
}

@(test)
test_sao_fused_edge_histograms :: proc(t: ^testing.T) {
	orig_data: [89 * 75 + 17]Sample
	rec_data: [83 * 75 + 9]Sample
	orig := Plane(Sample) {
		data   = orig_data[:],
		stride = 89,
		offset = 17,
	}
	rec := Plane(Sample) {
		data   = rec_data[:],
		stride = 83,
		offset = 9,
	}
	// Independent strides/offsets, empty/tiny interiors, chroma rectangles and
	// full CTUs: 768 histogram comparisons, each covering all 40 edge bins.
	for depth in ([2]int{8, 10}) {
		maximum := (1 << uint(depth)) - 1
		for pattern in 0 ..< 8 {
			for y in 0 ..< 75 {
				for x in 0 ..< 83 {
					o := (x * x * 17 + y * 73 + (x + 3) * (y + 5) * 11 + depth) & maximum
					r := (x * 53 + y * 197 + x * y * 31 + depth * 17) & maximum
					switch pattern {
					case 0:
						o, r = 0, 0
					case 1:
						o, r = maximum, 0
					case 2:
						o, r = 0, maximum
					case 3:
						r = (x + y) % 2 == 0 ? 0 : maximum
					case 4:
						r = (x * 17) & maximum
					case 5:
						r = (y * 29) & maximum
					case 6:
						r = (x + y) % 13 < 6 ? 0 : maximum
					case 7:
					}
					orig.data[orig.offset + y * orig.stride + x] = Sample(o)
					rec.data[rec.offset + y * rec.stride + x] = Sample(r)
				}
			}
			for shape in ([16][2]int{{0, 0}, {1, 1}, {1, 64}, {64, 1}, {2, 2}, {2, 63}, {63, 2}, {3, 3}, {4, 4}, {8, 8}, {13, 7}, {32, 32}, {32, 64}, {64, 32}, {63, 61}, {64, 64}}) {
				for origin in ([3][2]int{{0, 0}, {3, 7}, {7, 5}}) {
					got: Sao_Stats
					// Nonzero seeds verify accumulation rather than replacement;
					// band sentinels pin the separate band's ownership.
					for eo in 0 ..< 4 {
						for cat in 0 ..< 5 {
							got.edge_sum[eo][cat] = i32(eo * 17 - cat * 11)
							got.edge_count[eo][cat] = i32(eo * 5 + cat)
						}
					}
					for row in 0 ..< 2 do for band in 0 ..< 32 do got.bands[row][band] = i32(row * 37 + band + 1)
					want := got
					sao_test_accumulate_edges(
						orig,
						rec,
						origin[0],
						origin[1],
						shape[0],
						shape[1],
						&want,
					)
					sao_calc_edges(orig, rec, origin[0], origin[1], shape[0], shape[1], &got)
					for eo in 0 ..< 4 {
						for cat in 0 ..< 5 {
							if got.edge_sum[eo][cat] != want.edge_sum[eo][cat] ||
							   got.edge_count[eo][cat] != want.edge_count[eo][cat] {
								testing.expectf(
									t,
									false,
									"edge histogram depth=%d pattern=%d shape=%v origin=%v direction=%d category=%d sum=%d/%d count=%d/%d",
									depth,
									pattern,
									shape,
									origin,
									eo,
									cat,
									got.edge_sum[eo][cat],
									want.edge_sum[eo][cat],
									got.edge_count[eo][cat],
									want.edge_count[eo][cat],
								)
								return
							}
						}
					}
					testing.expect_value(t, got.bands, want.bands)
				}
			}
		}
	}
}

// The packed sum/count carry proof is stronger than native 8/10-bit
// admission. Stress its full Sample domain, negative totals, zero totals
// with positive counts, mixed signs and every chunk/tail width. The oracle
// remains the independent original four-pass pixel/bin accumulation.
@(test)
test_sao_packed_histogram_signed_sum_and_count_bounds :: proc(t: ^testing.T) {
	orig_data: [73 * 67 + 13]Sample
	rec_data: [71 * 67 + 17]Sample
	orig := Plane(Sample) {
		data   = orig_data[:],
		stride = 73,
		offset = 7,
	}
	rec := Plane(Sample) {
		data   = rec_data[:],
		stride = 71,
		offset = 11,
	}
	shapes := [6][2]int{{3, 3}, {9, 13}, {17, 19}, {63, 64}, {64, 63}, {64, 64}}
	for shape in shapes do for pattern in 0 ..< 4 {
		for &value, index in orig_data do value = Sample((index * 31 + 0x9517) & 0xffff)
		for &value, index in rec_data do value = Sample((index * 47 + 0xCA39) & 0xffff)
		w, h := shape[0], shape[1]
		for y in 0 ..< h do for x in 0 ..< w {
			o, r: Sample
			switch pattern {
			case 0:
				o, r = 65535, 0
			case 1:
				o, r = 0, 65535
			case 2:
				o, r = 32767, 32767
			case:
				o, r = (x + y) & 1 == 0 ? 65534 : 0, 32767
			}
			orig_data[orig.offset + (y + 2) * orig.stride + x + 3] = o
			rec_data[rec.offset + (y + 2) * rec.stride + x + 3] = r
		}
		orig_before, rec_before := orig_data, rec_data
		seed: Sao_Stats
		for eo in 0 ..< 4 do for cat in 0 ..< 5 {
			seed.edge_sum[eo][cat] = i32(eo * 13 - cat * 5 - 52)
			seed.edge_count[eo][cat] = i32(eo * 5 + cat + 75)
		}
		for &bands, row in seed.bands do for &value, band in bands do value = i32(0x291 + row * 113 + band * 17)
		got, want := seed, seed
		sao_test_accumulate_edges(orig, rec, 3, 2, w, h, &want)
		sao_calc_edges(orig, rec, 3, 2, w, h, &got)
		testing.expect_value(t, got, want)
		testing.expect_value(t, got.bands, seed.bands)
		count := i32((w - 2) * (h - 2))
		for eo in 0 ..< 4 {
			testing.expect_value(t, got.edge_count[eo][0], seed.edge_count[eo][0] + count)
			if pattern < 3 {
				diff := pattern == 0 ? i32(65535) : pattern == 1 ? i32(-65535) : i32(0)
				testing.expect_value(t, got.edge_sum[eo][0], seed.edge_sum[eo][0] + count * diff)
			}
		}
		for value, index in orig_data do testing.expect_value(t, value, orig_before[index])
		for value, index in rec_data do testing.expect_value(t, value, rec_before[index])
	}
}

@(test)
test_sao_statistics_pixel_oracle :: proc(t: ^testing.T) {
	// Different strides and offsets expose accidental use of a plane's sibling
	// descriptor. Rectangles also cover the CTU shapes of all chroma layouts.
	orig_data: [2][89 * 75 + 17]Sample
	rec_data: [2][83 * 75 + 9]Sample
	orig := [2]Plane(Sample) {
		{data = orig_data[0][:], stride = 89, offset = 17},
		{data = orig_data[1][:], stride = 89, offset = 17},
	}
	rec := [2]Plane(Sample) {
		{data = rec_data[0][:], stride = 83, offset = 9},
		{data = rec_data[1][:], stride = 83, offset = 9},
	}
	patterns := [6][5]i32 {
		{0, 0, 0, 0, 0},
		{0, 7, -7, 1, -1},
		{0, -7, 7, -3, 3},
		{7, -7, 7, -7, 7},
		{-7, 7, -7, 7, -7},
		{1, 2, -3, 4, -5},
	}
	positions := [12]i32{-4, -3, -1, 0, 1, 15, 27, 28, 29, 30, 31, 32}
	for depth in ([2]int{8, 10}) {
		mask := (1 << uint(depth)) - 1
		for b in 0 ..< 2 {
			for y in 0 ..< 75 {
				for x in 0 ..< 83 {
					orig[b].data[orig[b].offset + y * orig[b].stride + x] = Sample(
						(x * x * 17 + y * 73 + (x + 3) * (y + 5) * 11 + b * 37 + depth) & mask,
					)
					rec[b].data[rec[b].offset + y * rec[b].stride + x] = Sample(
						(x * 53 + y * 197 + x * y * 31 + b * 109 + depth * 17) & mask,
					)
				}
			}
		}
		for shape in ([16][2]int{{0, 0}, {1, 1}, {1, 64}, {64, 1}, {2, 2}, {2, 63}, {63, 2}, {3, 3}, {4, 4}, {8, 8}, {13, 7}, {32, 32}, {32, 64}, {64, 32}, {63, 61}, {64, 64}}) {
			w, h := shape[0], shape[1]
			for origin in ([3][2]int{{0, 0}, {3, 7}, {7, 5}}) {
				x0, y0 := origin[0], origin[1]
				stats: [2]Sao_Stats
				for b in 0 ..< 2 {
					stats[b] = sao_test_collect_stats(orig[b], rec[b], x0, y0, w, h, depth - 5)
					band_count: i32
					for count in stats[b].bands[1] do band_count += count
					testing.expect_value(t, band_count, i32(w * h))
					for eo in 0 ..< 4 {
						edge_count: i32
						for count in stats[b].edge_count[eo] do edge_count += count
						testing.expect_value(t, edge_count, i32(max(w - 2, 0) * max(h - 2, 0)))
					}
				}
				for p in 0 ..< len(patterns) {
					info: Sao_Info
					for cat in 0 ..< 5 {
						info.offsets[cat] = patterns[p][cat]
						info.offsets[5 + cat] = patterns[(p + 1) % len(patterns)][4 - cat]
					}
					for eo in 0 ..< 4 {
						info.type, info.eo_class = .Edge, u8(eo)
						for b in 0 ..< 2 {
							want := sao_test_pixel_cost(
								orig[b],
								rec[b],
								x0,
								y0,
								w,
								h,
								depth - 5,
								&info,
								b,
							)
							got := sao_stats_distortion(&stats[b], &info, b)
							if i64(got) != want {
								testing.expectf(
									t,
									false,
									"edge depth=%d shape=%v origin=%v component=%d direction=%d pattern=%d: got %d want %d",
									depth,
									shape,
									origin,
									b,
									eo,
									p,
									got,
									want,
								)
								return
							}
						}
					}
					info.type = .Band
					for pos, i in positions {
						info.band_position = {pos, positions[(i + 5) % len(positions)]}
						for b in 0 ..< 2 {
							want := sao_test_pixel_cost(
								orig[b],
								rec[b],
								x0,
								y0,
								w,
								h,
								depth - 5,
								&info,
								b,
							)
							got := sao_stats_distortion(&stats[b], &info, b)
							if i64(got) != want {
								testing.expectf(
									t,
									false,
									"band depth=%d shape=%v origin=%v component=%d position=%d pattern=%d: got %d want %d",
									depth,
									shape,
									origin,
									b,
									info.band_position[b],
									p,
									got,
									want,
								)
								return
							}
						}
					}
					// None must ignore even artificial offsets and edge metadata.
					info.type, info.eo_class = .None, 255
					for b in 0 ..< 2 do testing.expect_value(t, sao_stats_distortion(&stats[b], &info, b), i32(0))
				}
			}
		}
	}
}

@(test)
test_sao_unclipped_extreme_distortion :: proc(t: ^testing.T) {
	orig_data, rec_data: [64 * 64]Sample
	orig := Plane(Sample) {
		data   = orig_data[:],
		stride = 64,
	}
	rec := Plane(Sample) {
		data   = rec_data[:],
		stride = 64,
	}
	for depth in ([2]int{8, 10}) {
		maximum := (1 << uint(depth)) - 1
		for b in 0 ..< 2 {
			for &v in orig_data do v = Sample(b == 0 ? maximum : 0)
			for &v in rec_data do v = Sample(b == 0 ? 0 : maximum)
			stats := sao_test_collect_stats(orig, rec, 0, 0, 64, 64, depth - 5)
			for outward in ([2]bool{false, true}) {
				// Outward offsets push zero down or maximum up: clamping
				// would erase their cost. Inward offsets pin negative costs.
				offset := b == 0 ? i32(7) : i32(-7)
				if outward do offset = -offset
				per_sample := 49 + (outward ? 14 : -14) * i64(maximum)
				info := Sao_Info {
					type = .Band,
				}
				info.band_position[b] = b == 0 ? 0 : 28
				info.offsets[b * 5 + (b == 0 ? 1 : 4)] = offset
				want := i64(64 * 64) * per_sample
				testing.expect_value(t, i64(sao_stats_distortion(&stats, &info, b)), want)
				testing.expect_value(
					t,
					sao_test_pixel_cost(orig, rec, 0, 0, 64, 64, depth - 5, &info, b),
					want,
				)

				// Constant reconstruction classifies every interior sample as
				// category0. A nonzero artificial offset checks its retention.
				info = Sao_Info {
					type = .Edge,
				}
				info.offsets[b * 5] = offset
				want = i64(62 * 62) * per_sample
				for eo in 0 ..< 4 {
					info.eo_class = u8(eo)
					testing.expect_value(t, stats.edge_count[eo][0], i32(62 * 62))
					testing.expect_value(t, i64(sao_stats_distortion(&stats, &info, b)), want)
					testing.expect_value(
						t,
						sao_test_pixel_cost(orig, rec, 0, 0, 64, 64, depth - 5, &info, b),
						want,
					)
				}
			}
		}
	}
}

@(test)
test_sao_nonwrapping_band_positions :: proc(t: ^testing.T) {
	data: [4 * 4]Sample
	plane := Plane(Sample) {
		data   = data[:],
		stride = 4,
	}
	for depth in ([2]int{8, 10}) {
		for b in 0 ..< 2 {
			for sample in ([2]int{0, (1 << uint(depth)) - 1}) {
				for &v in data do v = Sample(sample)
				stats := sao_test_collect_stats(plane, plane, 0, 0, 4, 4, depth - 5)
				for pos in ([9]i32{-4, -3, -1, 0, 27, 28, 30, 31, 32}) {
					info := Sao_Info {
						type = .Band,
					}
					info.band_position[b] = pos
					for k in 0 ..< 4 do info.offsets[b * 5 + 1 + k] = i32(k + 1)
					// No source error: an admitted offset contributes its square.
					relative := i32(sample >> uint(depth - 5)) - pos
					want: i64
					if relative >= 0 && relative < 4 do want = 16 * i64(relative + 1) * i64(relative + 1)
					testing.expect_value(t, i64(sao_stats_distortion(&stats, &info, b)), want)
					testing.expect_value(
						t,
						sao_test_pixel_cost(plane, plane, 0, 0, 4, 4, depth - 5, &info, b),
						want,
					)
				}
			}
		}
	}
}

// Reconstruct integer sample errors with exactly this sum/count, then use
// the old pixel-cost definition rather than the production statistics formula.
sao_test_band_pixel_delta :: proc(sum, count, offset: i32) -> i64 {
	if count == 0 do return 0
	base := i64(sum) / i64(count)
	remainder := i64(sum) % i64(count)
	cost: i64
	for sample in 0 ..< int(count) {
		diff := base
		if i64(sample) < abs(remainder) do diff += remainder > 0 ? 1 : -1
		delta := diff - i64(offset)
		cost += delta * delta - diff * diff
	}
	return cost
}

sao_test_band_offsets_oracle :: proc(
	bands: [2][32]i32,
) -> (
	offsets: [4]i32,
	position: i32,
	dist: i64,
) {
	costs: [32]i64
	choices: [32]i32
	for band in 0 ..< 32 {
		sum, count := bands[0][band], bands[1][band]
		seed: i32
		if count != 0 do seed = clamp((sum + (count >> 1)) / count, -7, 7)
		costs[band] = max(i64)
		// Enumerate in a different order from production. Preserve its rounded
		// seed and nonzero, toward-zero candidate domain. A tie retains the
		// largest magnitude, which production encounters first.
		for candidate := i32(-7); candidate <= 7; candidate += 1 {
			admitted :=
				seed == 0 ? candidate == 0 : (seed > 0 ? candidate > 0 && candidate <= seed : candidate < 0 && candidate >= seed)
			if !admitted do continue
			cost := sao_test_band_pixel_delta(sum, count, candidate)
			if cost < costs[band] || (cost == costs[band] && abs(candidate) > abs(choices[band])) {
				costs[band], choices[band] = cost, candidate
			}
		}
	}

	dist = max(i64)
	// The existing search considers starts 0..27; it excludes start 28 and
	// never wraps. Equal window costs retain the earliest start.
	for start in 0 ..< 28 {
		cost: i64
		for band in start ..< start + 4 do cost += costs[band]
		if cost < dist do dist, position = cost, i32(start)
	}
	for k in 0 ..< 4 do offsets[k] = choices[int(position) + k]
	return
}

sao_test_expect_band_offsets :: proc(t: ^testing.T, bands: [2][32]i32) -> bool {
	want_offsets, want_position, want_dist := sao_test_band_offsets_oracle(bands)
	got_offsets, got_position, got_dist := sao_calc_band_offsets(bands)
	if got_offsets != want_offsets || got_position != want_position || i64(got_dist) != want_dist {
		testing.expectf(
			t,
			false,
			"band optimization sum/count=%v: offsets=%v/%v position=%d/%d distortion=%d/%d",
			bands,
			got_offsets,
			want_offsets,
			got_position,
			want_position,
			got_dist,
			want_dist,
		)
		return false
	}
	return true
}

@(test)
test_sao_band_offsets_bounded_oracle :: proc(t: ^testing.T) {
	// Exhaust every sum in [-12*count,12*count], counts 0..8, at all 32 bands:
	// 27,936 complete optimizer comparisons, including empty bands, fractional
	// means, signed/clamped seeds, ties and every four-band window boundary.
	for count := i32(0); count <= 8; count += 1 {
		for sum := -12 * count; sum <= 12 * count; sum += 1 {
			for band in 0 ..< 32 {
				bands: [2][32]i32
				bands[0][band], bands[1][band] = sum, count
				if !sao_test_expect_band_offsets(t, bands) do return
			}
		}
	}

	// Pin the lost magnitudes, strict cost ties and the unchanged rounding
	// policy: count 3, sum -8 starts at -2, even though unrestricted -3 costs less.
	for control in ([8][4]i32{{16, 80, 5, -400}, {1, -5, -5, -25}, {2, 5, 3, -12}, {3, -8, -2, -20}, {1, 100, 7, -1351}, {1, -100, -7, -1351}, {0, 0, 0, 0}, {8, 0, 0, 0}}) {
		bands: [2][32]i32
		bands[0][3], bands[1][3] = control[1], control[0]
		if !sao_test_expect_band_offsets(t, bands) do return
		offsets, position, dist := sao_calc_band_offsets(bands)
		testing.expect_value(t, offsets, [4]i32{0, 0, 0, control[2]})
		testing.expect_value(t, position, i32(0))
		testing.expect_value(t, dist, control[3])
	}
	for band in ([2]int{30, 31}) {
		bands: [2][32]i32
		bands[0][band], bands[1][band] = 5, 1
		if !sao_test_expect_band_offsets(t, bands) do return
		offsets, position, dist := sao_calc_band_offsets(bands)
		testing.expect_value(t, offsets, band == 30 ? [4]i32{0, 0, 0, 5} : [4]i32{})
		testing.expect_value(t, position, i32(band == 30 ? 27 : 0))
		testing.expect_value(t, dist, i32(band == 30 ? -25 : 0))
	}

	for depth in ([2]int{8, 10}) {
		maximum, shift := (1 << uint(depth)) - 1, depth - 5
		// A dense CTU: every band contains 128 valid errors (4096 total).
		for pattern in 0 ..< 3 {
			bands: [2][32]i32
			for band in 0 ..< 32 {
				rec := band << uint(shift)
				orig :=
					pattern == 0 ? maximum : (pattern == 1 ? 0 : clamp(rec + band % 15 - 7, 0, maximum))
				bands[0][band], bands[1][band] = i32(128 * (orig - rec)), 128
			}
			if !sao_test_expect_band_offsets(t, bands) do return
		}
		// Concentrate all 4096 errors in one band to exercise the largest valid
		// sums/costs; both signs have real in-range source/reconstruction pairs.
		for negative in ([2]bool{false, true}) {
			bands: [2][32]i32
			band := negative ? 30 : 0
			diff := negative ? -(band << uint(shift)) : maximum
			bands[0][band], bands[1][band] = i32(4096 * diff), 4096
			if !sao_test_expect_band_offsets(t, bands) do return
		}
	}
}

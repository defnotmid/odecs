package h265_encoder

import "base:intrinsics"
import "core:simd"

// ---------------------------------------------------------------------------
// Sample Adaptive Offset (H.265 8.7.3).
//
// The encoder decision is ported from kvazaar's sao.c. Reconstruction follows
// the reference decoder: SAO is applied to the deblocked picture and edge
// classifications read pre-SAO neighbours. The whole deblocked picture is
// kept in `enc.sao_src`, so applying SAO to `enc.rec` does not depend on the
// order in which coding tree units are processed.
// ---------------------------------------------------------------------------

Sao_Type :: enum u8 {
	None = 0,
	Band = 1,
	Edge = 2,
}

// One CTU of SAO parameters. Chroma keeps Cb in `offsets[0..4]` /
// `band_position[0]` and Cr in `offsets[5..9]` / `band_position[1]`; both
// components share `type` and `eo_class`, exactly like the bitstream syntax.
Sao_Info :: struct {
	type:          Sao_Type,
	eo_class:      u8,
	band_position: [2]i32,
	offsets:       [10]i32,
	merge_left:    bool,
	merge_up:      bool,
}

// 7.4.9.3: sao_offset_abs runs to (1 << (Min(bitDepth, 10) - 5)) - 1.
SAO_MAX_ABS :: 7

sao_c_max :: #force_inline proc(bit_depth: int) -> i32 {
	return i32(1) << uint(min(bit_depth, 10) - 5) - 1
}

SAO_EO_HORIZ :: 0
SAO_EO_VERT :: 1
SAO_EO_45 :: 2
SAO_EO_135 :: 3

SAO_EO_IDX_TO_CAT := [5]u8{1, 2, 0, 3, 4}

SAO_EO_OFFSETS := [4][2][2]i32 {
	{{-1, 0}, {1, 0}},
	{{0, -1}, {0, 1}},
	{{-1, -1}, {1, 1}},
	{{1, -1}, {-1, 1}},
}

@(private)
sao_sign3 :: #force_inline proc(v: i32) -> i32 {
	return v > 0 ? 1 : (v < 0 ? -1 : 0)
}

@(private)
sao_eo_cat :: #force_inline proc(a, b, c: i32) -> int {
	return int(SAO_EO_IDX_TO_CAT[2 + sao_sign3(c - a) + sao_sign3(c - b)])
}

@(private)
sao_offset_abs_bits :: #force_inline proc(v, c_max: i32) -> f64 {
	return f64(v == c_max ? c_max : v + 1)
}

@(private)
sao_rate :: #force_inline proc(enc: ^Encoder, bits: f64) -> i32 {
	return i32(bits * enc.lambda + 0.5)
}

// ---------------------------------------------------------------------------
// Distortion and offset estimation (kvazaar sao.c / sao_shared_generics.h).
// ---------------------------------------------------------------------------

@(private)
sao_calc_bands :: proc(orig, rec: Plane(Sample), x0, y0, w, h, shift: int, bands: ^[2][32]i32) {
	for y in 0 ..< h {
		for x in 0 ..< w {
			idx := int(at(rec, x0 + x, y0 + y)) >> uint(shift)
			bands[0][idx] += i32(at(orig, x0 + x, y0 + y)) - i32(at(rec, x0 + x, y0 + y))
			bands[1][idx] += 1
		}
	}
}

@(private)
Sao_Edge_Bins :: struct {
	// Each lane adds diff*2^32+1. A CTU has at most 62*62 interior
	// samples, so count cannot carry into the signed high-word sum.
	// Even full-u16 differences keep the combined total inside i64.
	packed: [4][5]#simd[8]i64,
}

@(private)
sao_bin_lanes :: #force_inline proc(v: #simd[$LANES]i64) -> #simd[8]i64 {
	when LANES == 8 {
		return v
	} else when LANES == 4 {
		return simd.shuffle(v, (#simd[4]i64)(0), 0, 1, 2, 3, 4, 5, 6, 7)
	} else {
		lanes := [8]i64{simd.extract(v, 0), 0, 0, 0, 0, 0, 0, 0}
		return transmute(#simd[8]i64)lanes
	}
}

@(private)
sao_edge_histogram :: #force_inline proc(
	c, a, b: #simd[$LANES]i32,
	increment: #simd[LANES]i64,
	bins: ^[5]#simd[8]i64,
) {
	V :: #simd[LANES]i32
	one, zero := V(1), V(0)
	sign_a := simd.sub(
		simd.select(simd.lanes_gt(c, a), one, zero),
		simd.select(simd.lanes_lt(c, a), one, zero),
	)
	sign_b := simd.sub(
		simd.select(simd.lanes_gt(c, b), one, zero),
		simd.select(simd.lanes_lt(c, b), one, zero),
	)
	index := simd.add(simd.add(sign_a, sign_b), V(2))
	#unroll for k in 0 ..< 5 {
		selected := simd.lanes_eq(index, V(i32(k)))
		cat := int(SAO_EO_IDX_TO_CAT[k])
		bins[cat] = simd.add(
			bins[cat],
			sao_bin_lanes(simd.select(selected, increment, (#simd[LANES]i64)(0))),
		)
	}
}

@(private)
sao_edges_chunk :: #force_inline proc(
	$LANES: int,
	orig, rec: [^]Sample,
	stride: int,
	bins: ^Sao_Edge_Bins,
) {
	load :: #force_inline proc(p: [^]Sample) -> #simd[LANES]i32 {
		return (#simd[LANES]i32)(intrinsics.unaligned_load((^#simd[LANES]Sample)(p)))
	}
	c := load(rec)
	diff := simd.sub(load(orig), c)
	increment := simd.add(
		simd.mul((#simd[LANES]i64)(diff), (#simd[LANES]i64)(0x100000000)),
		(#simd[LANES]i64)(1),
	)
	sao_edge_histogram(c, load(&rec[-1]), load(&rec[1]), increment, &bins.packed[0])
	sao_edge_histogram(c, load(&rec[-stride]), load(&rec[stride]), increment, &bins.packed[1])
	sao_edge_histogram(
		c,
		load(&rec[-stride - 1]),
		load(&rec[stride + 1]),
		increment,
		&bins.packed[2],
	)
	sao_edge_histogram(
		c,
		load(&rec[-stride + 1]),
		load(&rec[stride - 1]),
		increment,
		&bins.packed[3],
	)
}

@(private)
sao_calc_edges :: proc(
	orig, rec: Plane(Sample),
	x0, y0, w, h: int,
	stats: ^Sao_Stats,
) #no_bounds_check {
	// Keep the five histogram bins laned through the whole CTU. Each pixel
	// contributes to one lane; reduce each bin once, after all contiguous rows.
	bins: Sao_Edge_Bins
	for y in 1 ..< h - 1 {
		rp: [^]Sample = &rec.data[rec.offset + (y0 + y) * rec.stride + x0]
		op: [^]Sample = &orig.data[orig.offset + (y0 + y) * orig.stride + x0]
		x := 1
		for ; x + 8 <= w - 1; x += 8 do sao_edges_chunk(8, &op[x], &rp[x], rec.stride, &bins)
		if x + 4 <= w - 1 {sao_edges_chunk(4, &op[x], &rp[x], rec.stride, &bins); x += 4}
		for ; x < w - 1; x += 1 do sao_edges_chunk(1, &op[x], &rp[x], rec.stride, &bins)
	}
	for eo in 0 ..< 4 do for cat in 0 ..< 5 {
		total := simd.reduce_add_ordered(bins.packed[eo][cat])
		stats.edge_sum[eo][cat] += i32(total >> 32)
		stats.edge_count[eo][cat] += i32(u32(total))
	}
}

@(private)
sao_calc_band_offsets :: proc(
	bands: [2][32]i32,
) -> (
	offsets: [4]i32,
	band_position: i32,
	dist: i32,
) {
	band_dist: [32]i32
	temp_offsets: [32]i32
	for band in 0 ..< 32 {
		best := max(i32)
		offset: i32
		if bands[1][band] != 0 {
			offset = (bands[0][band] + (bands[1][band] >> 1)) / bands[1][band]
			offset = clamp(offset, -SAO_MAX_ABS, SAO_MAX_ABS)
		}
		band_dist[band] = offset == 0 ? 0 : max(i32)
		for offset != 0 {
			temp_dist := bands[1][band] * offset * offset - 2 * offset * bands[0][band]
			if temp_dist < best {
				best = temp_dist
				band_dist[band] = temp_dist
				temp_offsets[band] = offset
			}
			offset += offset > 0 ? -1 : 1
		}
	}
	best := max(i32)
	for band in 0 ..< 28 {
		temp_dist :=
			band_dist[band] + band_dist[band + 1] + band_dist[band + 2] + band_dist[band + 3]
		if temp_dist < best {
			best = temp_dist
			band_position = i32(band)
		}
	}
	for i in 0 ..< 4 do offsets[i] = temp_offsets[int(band_position) + i]
	return offsets, band_position, best
}

@(private)
Sao_Stats :: struct {
	edge_sum:   [4][5]i32,
	edge_count: [4][5]i32,
	bands:      [2][32]i32,
}

// The search already classifies every sample for offset estimation. Reuse
// those same statistics for selected and merge costs: the pixel sum of
// (diff - offset)^2 - diff^2 is count*offset^2 - 2*sum(diff)*offset.
// These are the search's unclipped costs, not the later filter's pixels.
@(private)
sao_stats_distortion :: proc(stats: ^Sao_Stats, info: ^Sao_Info, component: int) -> i32 {
	dist: i32
	obase := component * 5
	switch info.type {
	case .None:
		return 0
	case .Band:
		for k in 0 ..< 4 {
			band := int(info.band_position[component]) + k
			// The existing distortion scan does not wrap bands at 32.
			if band < 0 || band >= 32 do continue
			offset := info.offsets[obase + 1 + k]
			dist += stats.bands[1][band] * offset * offset - 2 * stats.bands[0][band] * offset
		}
	case .Edge:
		eo := int(info.eo_class)
		for cat in 0 ..< 5 {
			offset := info.offsets[obase + cat]
			dist +=
				stats.edge_count[eo][cat] * offset * offset - 2 * stats.edge_sum[eo][cat] * offset
		}
	}
	return dist
}

// ---------------------------------------------------------------------------
// Mode search (kvazaar sao_search_best_mode + sao_search_lcu).
// ---------------------------------------------------------------------------

@(private)
sao_search_best :: proc(
	enc: ^Encoder,
	orig0, rec0: Plane(Sample),
	orig1, rec1: Plane(Sample),
	x0, y0, w, h, buf_cnt, shift: int,
	has_left, has_top: bool,
	top, left: ^Sao_Info,
) -> (
	best: Sao_Info,
	merge_cost: [3]i32,
) {
	prefix_bits := (has_left ? 1.0 : 0.0) + (has_top ? 1.0 : 0.0)
	c_max := sao_c_max(shift + 5)
	// Only the active components are accumulated or read. Keep their counts
	// initialized, and retain them until all candidate/merge costs are scored.
	stats: [2]Sao_Stats = ---
	for b in 0 ..< buf_cnt do stats[b] = {}

	// --- Edge ---------------------------------------------------------------
	for b in 0 ..< buf_cnt {
		orig := b == 0 ? orig0 : orig1
		rec := b == 0 ? rec0 : rec1
		sao_calc_edges(orig, rec, x0, y0, w, h, &stats[b])
	}
	best_eo: int
	best_edge_offsets: [10]i32
	best_edge_score := max(i32)
	for eo in 0 ..< 4 {
		offset_tmp: [10]i32
		score: i32
		for b in 0 ..< buf_cnt {
			sum := &stats[b].edge_sum[eo]
			cnt := &stats[b].edge_count[eo]
			for cat in 1 ..= 4 {
				offset: i32
				if cnt[cat] != 0 {
					offset = (sum[cat] + (cnt[cat] >> 1)) / cnt[cat]
					offset = clamp(offset, -SAO_MAX_ABS, SAO_MAX_ABS)
				}
				if cat <= 2 && offset < 0 do offset = 0
				if cat >= 3 && offset > 0 do offset = 0
				offset_tmp[b * 5 + cat] = offset
				score += cnt[cat] * offset * offset - 2 * offset * sum[cat]
			}
		}
		bits := prefix_bits + 4
		for b in 0 ..< buf_cnt do for cat in 1 ..= 4 do bits += sao_offset_abs_bits(abs(offset_tmp[b * 5 + cat]), c_max)
		score += sao_rate(enc, bits)
		if score < best_edge_score {
			best_edge_score = score
			best_eo = eo
			best_edge_offsets = offset_tmp
		}
	}

	edge_sao := Sao_Info {
		type     = .Edge,
		eo_class = u8(best_eo),
		offsets  = best_edge_offsets,
	}
	edge_cost: i32
	for b in 0 ..< buf_cnt {
		edge_cost += sao_stats_distortion(&stats[b], &edge_sao, b)
	}
	{
		bits := prefix_bits + 4
		for b in 0 ..< buf_cnt do for cat in 1 ..= 4 do bits += sao_offset_abs_bits(abs(edge_sao.offsets[b * 5 + cat]), c_max)
		edge_cost += sao_rate(enc, bits)
	}

	// --- Band ---------------------------------------------------------------
	band_sao := Sao_Info {
		type = .Band,
	}
	for b in 0 ..< buf_cnt {
		orig := b == 0 ? orig0 : orig1
		rec := b == 0 ? rec0 : rec1
		sao_calc_bands(orig, rec, x0, y0, w, h, shift, &stats[b].bands)
		offsets, pos, _ := sao_calc_band_offsets(stats[b].bands)
		for i in 0 ..< 4 do band_sao.offsets[b * 5 + 1 + i] = offsets[i]
		band_sao.band_position[b] = pos
	}
	band_cost: i32
	for b in 0 ..< buf_cnt {
		band_cost += sao_stats_distortion(&stats[b], &band_sao, b)
	}
	{
		bits := prefix_bits + 2 + 5 * f64(buf_cnt)
		for b in 0 ..< buf_cnt {
			for cat in 1 ..= 4 {
				v := abs(band_sao.offsets[b * 5 + cat])
				bits += sao_offset_abs_bits(v, c_max)
				if v != 0 do bits += 1
			}
		}
		band_cost += sao_rate(enc, bits)
	}

	// --- Choose between edge, band and none ---------------------------------
	if edge_cost <= band_cost {
		best = edge_sao
		merge_cost[0] = edge_cost
	} else {
		best = band_sao
		merge_cost[0] = band_cost
	}
	none_cost := sao_rate(enc, prefix_bits + 1)
	if merge_cost[0] >= none_cost {
		best = Sao_Info {
			type = .None,
		}
		merge_cost[0] = none_cost
	}

	// --- Merge costs --------------------------------------------------------
	if left != nil {
		d := sao_stats_distortion(&stats[0], left, 0)
		if buf_cnt == 2 do d += sao_stats_distortion(&stats[1], left, 1)
		merge_cost[1] = d + sao_rate(enc, 1)
	}
	if top != nil {
		d := sao_stats_distortion(&stats[0], top, 0)
		if buf_cnt == 2 do d += sao_stats_distortion(&stats[1], top, 1)
		merge_cost[2] = d + sao_rate(enc, 2)
	}
	return
}

// Decide luma and chroma SAO parameters for every CTU in raster order.
sao_decide_frame :: proc(enc: ^Encoder) {
	for cty in 0 ..< enc.ctu_rows {
		for ctx in 0 ..< enc.ctu_cols {
			idx := cty * enc.ctu_cols + ctx
			x0 := ctx * CTU_WIDTH
			y0 := cty * CTU_WIDTH
			w := min(CTU_WIDTH, enc.coded_width - x0)
			h := min(CTU_WIDTH, enc.coded_height - y0)
			// 8.7.3: a merge may not reach across a tile boundary.
			has_left := ctx > 0 && same_tile(enc, x0, y0, x0 - CTU_WIDTH, y0)
			has_top := cty > 0 && same_tile(enc, x0, y0, x0, y0 - CTU_WIDTH)

			top_l: ^Sao_Info
			left_l: ^Sao_Info
			if has_top do top_l = &enc.sao_luma[idx - enc.ctu_cols]
			if has_left do left_l = &enc.sao_luma[idx - 1]
			luma, lcost := sao_search_best(
				enc,
				enc.source.y,
				enc.sao_src.y,
				enc.source.y,
				enc.sao_src.y,
				x0,
				y0,
				w,
				h,
				1,
				enc.bit_depth - 5,
				has_left,
				has_top,
				top_l,
				left_l,
			)

			sw, sh := chroma_sub(enc.config.chroma_format)
			x0c, y0c := x0 / sw, y0 / sh
			wc, hc := w / sw, h / sh
			top_c: ^Sao_Info
			left_c: ^Sao_Info
			if has_top do top_c = &enc.sao_chroma[idx - enc.ctu_cols]
			if has_left do left_c = &enc.sao_chroma[idx - 1]
			chroma: Sao_Info
			ccost: [3]i32
			if has_chroma(enc) {
				chroma, ccost = sao_search_best(
					enc,
					enc.source.u,
					enc.sao_src.u,
					enc.source.v,
					enc.sao_src.v,
					x0c,
					y0c,
					wc,
					hc,
					2,
					enc.bit_depth - 5,
					has_left,
					has_top,
					top_c,
					left_c,
				)
			}

			luma.merge_left = false
			luma.merge_up = false
			if has_top {
				if lcost[2] + ccost[2] <= lcost[0] + ccost[0] {
					luma = top_l^
					chroma = top_c^
					luma.merge_up = true
					luma.merge_left = false
				}
			}
			if has_left {
				if lcost[1] + ccost[1] <= lcost[0] + ccost[0] {
					if !luma.merge_up || lcost[1] + ccost[1] < lcost[2] + ccost[2] {
						luma = left_l^
						chroma = left_c^
						luma.merge_left = true
						luma.merge_up = false
					}
				}
			}
			enc.sao_luma[idx] = luma
			enc.sao_chroma[idx] = chroma
		}
	}
}

// ---------------------------------------------------------------------------
// Bitstream syntax (ff_hevc_sao_*_decode).
// ---------------------------------------------------------------------------

@(private)
sao_write_color :: proc(cabac: ^Cabac, info: Sao_Info, color: int, write_type: bool, c_max: i32) {
	obase := color == 2 ? 5 : 0
	if write_type {
		cabac_bin(cabac, &cabac.ctx.sao_type_idx_model, info.type != .None ? 1 : 0)
		if info.type != .None {
			cabac_bin_ep(cabac, info.type == .Band ? 0 : 1)
		}
	}
	if info.type == .None do return

	for cat in 1 ..= 4 {
		v := abs(info.offsets[obase + cat])
		for _ in 0 ..< v do cabac_bin_ep(cabac, 1)
		if v < c_max do cabac_bin_ep(cabac, 0)
	}
	if info.type == .Band {
		for cat in 1 ..= 4 {
			offset := info.offsets[obase + cat]
			if offset != 0 do cabac_bin_ep(cabac, offset < 0 ? 1 : 0)
		}
		cabac_bins_ep(cabac, u32(info.band_position[color == 2 ? 1 : 0]), 5)
	} else if color != 2 {
		cabac_bins_ep(cabac, u32(info.eo_class), 2)
	}
}

// Write the SAO syntax at the start of one CTU, before the coding quadtree.
write_sao :: proc(enc: ^Encoder, x_ctb, y_ctb: int, cabac: ^Cabac) {
	idx := y_ctb * enc.ctu_cols + x_ctb
	luma := enc.sao_luma[idx]
	x0 := x_ctb * CTU_WIDTH
	y0 := y_ctb * CTU_WIDTH
	if x_ctb > 0 && same_tile(enc, x0, y0, x0 - CTU_WIDTH, y0) {
		cabac_bin(cabac, &cabac.ctx.sao_merge_flag_model, luma.merge_left ? 1 : 0)
	}
	if y_ctb > 0 && same_tile(enc, x0, y0, x0, y0 - CTU_WIDTH) && !luma.merge_left {
		cabac_bin(cabac, &cabac.ctx.sao_merge_flag_model, luma.merge_up ? 1 : 0)
	}
	if luma.merge_left || luma.merge_up do return

	c_max := sao_c_max(enc.bit_depth)

	sao_write_color(cabac, luma, 0, true, c_max)
	if has_chroma(enc) do sao_write_color(cabac, enc.sao_chroma[idx], 1, true, c_max)
	sao_write_color(cabac, enc.sao_chroma[idx], 2, false, c_max)
}

// ---------------------------------------------------------------------------
// Reconstruction (ff_hevc_hls_filter / sao_filter_CTB).
// ---------------------------------------------------------------------------

@(private)
sao_apply_plane :: proc(
	dst, src: Plane(Sample),
	plane_w, plane_h: int,
	info: Sao_Info,
	obase: int,
	x0, y0, w, h, bit_depth: int,
) {
	shift := bit_depth - 5
	max_v := i32(1) << uint(bit_depth) - 1

	switch info.type {
	case .None:
		return
	case .Band:
		band_position := info.band_position[obase == 5 ? 1 : 0]
		table: [32]i32
		for k in 0 ..< 4 {
			table[int((i32(k) + band_position) & 31)] = info.offsets[obase + 1 + k]
		}
		for y in 0 ..< h {
			for x in 0 ..< w {
				v := i32(at(src, x0 + x, y0 + y))
				set_at(
					dst,
					x0 + x,
					y0 + y,
					Sample(clamp(v + table[int(v >> uint(shift))], 0, max_v)),
				)
			}
		}
	case .Edge:
		eo := int(info.eo_class)
		oa := SAO_EO_OFFSETS[eo][0]
		ob := SAO_EO_OFFSETS[eo][1]
		for y in 0 ..< h {
			for x in 0 ..< w {
				gx := x0 + x
				gy := y0 + y
				c := i32(at(src, gx, gy))
				a := i32(at(src, gx + int(oa[0]), gy + int(oa[1])))
				b := i32(at(src, gx + int(ob[0]), gy + int(ob[1])))
				v := c + info.offsets[obase + sao_eo_cat(a, b, c)]
				if eo != SAO_EO_VERT && (gx == 0 || gx == plane_w - 1) do v = c
				if eo != SAO_EO_HORIZ && (gy == 0 || gy == plane_h - 1) do v = c
				set_at(dst, gx, gy, Sample(clamp(v, 0, max_v)))
			}
		}
	}
}

// Apply SAO to the reconstructed picture in coding tree unit raster order.
// The source snapshot is refreshed here from the final reconstruction: the
// decode applies SAO to exactly what it decoded, so the encoder must filter
// the same samples (the decision's earlier snapshot comes from the search
// pass and can differ from the bitstream pass's replay).
sao_apply_frame :: proc(enc: ^Encoder) {
	copy(enc.sao_src.y.data, enc.rec.y.data)
	copy(enc.sao_src.u.data, enc.rec.u.data)
	copy(enc.sao_src.v.data, enc.rec.v.data)
	for cty in 0 ..< enc.ctu_rows {
		for ctx in 0 ..< enc.ctu_cols {
			idx := cty * enc.ctu_cols + ctx
			x0 := ctx * CTU_WIDTH
			y0 := cty * CTU_WIDTH
			w := min(CTU_WIDTH, enc.coded_width - x0)
			h := min(CTU_WIDTH, enc.coded_height - y0)
			sao_apply_plane(
				enc.rec.y,
				enc.sao_src.y,
				enc.coded_width,
				enc.coded_height,
				enc.sao_luma[idx],
				0,
				x0,
				y0,
				w,
				h,
				enc.bit_depth,
			)

			sw, sh := chroma_sub(enc.config.chroma_format)
			x0c, y0c := x0 / sw, y0 / sh
			wc, hc := w / sw, h / sh
			if has_chroma(enc) {
				sao_apply_plane(
					enc.rec.u,
					enc.sao_src.u,
					enc.coded_width / sw,
					enc.coded_height / sh,
					enc.sao_chroma[idx],
					0,
					x0c,
					y0c,
					wc,
					hc,
					enc.bit_depth,
				)
				sao_apply_plane(
					enc.rec.v,
					enc.sao_src.v,
					enc.coded_width / sw,
					enc.coded_height / sh,
					enc.sao_chroma[idx],
					5,
					x0c,
					y0c,
					wc,
					hc,
					enc.bit_depth,
				)
			}
		}
	}
}

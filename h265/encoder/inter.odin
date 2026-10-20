package h265_encoder

// ---------------------------------------------------------------------------
// Inter prediction: quarter-pel luma and eighth-pel chroma motion
// compensation (filters from kvazaar's filter.c) plus an exhaustive motion
// search. Reference samples outside the picture are edge-replicated.
// ---------------------------------------------------------------------------

LUMA_FILTER := [4][8]i32 {
	{0, 0, 0, 64, 0, 0, 0, 0},
	{-1, 4, -10, 58, 17, -5, 1, 0},
	{-1, 4, -11, 40, 40, -11, 4, -1},
	{0, 1, -5, 17, 58, -10, 4, -1},
}

CHROMA_FILTER := [8][4]i32 {
	{0, 64, 0, 0},
	{-2, 58, 10, -2},
	{-4, 54, 16, -2},
	{-6, 46, 28, -4},
	{-4, 36, 36, -4},
	{-4, 28, 46, -6},
	{-2, 16, 54, -4},
	{-2, 10, 58, -2},
}

@(private)
clamp_index :: #force_inline proc(v, hi: int) -> int {
	return v < 0 ? 0 : (v > hi ? hi : v)
}

// SAD between the source block and a motion-compensated reference block.
@(private)
sad_mc_luma :: proc(
	enc: ^Encoder,
	ref: ^Frame,
	x, y, w, h: int,
	mv_x, mv_y: i16,
	wp: Wp_Plane,
) -> u32 {
	pred: [32 * 32]Sample = ---
	mc_luma_uni_w(pred[:], w, ref, x, y, w, h, {mv_x, mv_y}, wp, enc.bit_depth)
	return sad_u16(
		enc.source.y.data[enc.source.y.offset + y * enc.source.y.stride + x:],
		enc.source.y.stride,
		pred[:],
		w,
		w,
		h,
	)
}

// SSE between the source block and a motion-compensated reference block.
// The AMVP candidate's prediction is scored with it before its residual RDO
// path runs: a prediction that is already more expensive than the best
// committed candidate rarely pays for a coded residual.
@(private)
mc_luma_sse :: proc(
	enc: ^Encoder,
	ref: ^Frame,
	x, y, w, h: int,
	mv_x, mv_y: i16,
	wp: Wp_Plane,
) -> u64 {
	pred: [32 * 32]Sample = ---
	mc_luma_uni_w(pred[:], w, ref, x, y, w, h, {mv_x, mv_y}, wp, enc.bit_depth)
	src := enc.source.y
	return ssd_u16(src.data[src.offset + y * src.stride + x:], src.stride, pred[:], w, w, h)
}

// SAD between the source block and an integer-pel reference block. The
// integer stage of the search needs no interpolation, so this is a plain
// unit-stride absolute-difference loop (ffmpeg/kvazaar `reg_sad`). A block
// whose reference window lies inside the picture needs no clamping and takes
// the unit-stride path; only blocks at the picture edge fall back to it.
@(private)
sad_int_luma :: proc(enc: ^Encoder, ref: ^Frame, x, y, w, h, mx, my: int) -> u32 #no_bounds_check {
	rx := x + mx
	ry := y + my
	if rx >= 0 && rx + w <= ref.coded_width && ry >= 0 && ry + h <= ref.coded_height {
		src := enc.source.y
		return sad_u16(
			src.data[src.offset + y * src.stride + x:],
			src.stride,
			ref.y.data[ref.y.offset + ry * ref.y.stride + rx:],
			ref.y.stride,
			w,
			h,
		)
	}

	ref_w, ref_h := ref.coded_width - 1, ref.coded_height - 1
	sum: u32
	for j in 0 ..< h {
		sy := clamp_index(ry + j, ref_h)
		for i in 0 ..< w {
			sx := clamp_index(rx + i, ref_w)
			d := i32(at(enc.source.y, x + i, y + j)) - i32(at(ref.y, sx, sy))
			sum += u32(d < 0 ? -d : d)
		}
	}
	return sum
}

// Exhaustive integer search followed by half- and quarter-pel refinement.
// The integer stage uses integer SAD (no interpolation) and stops early on an
// exact match; only the 8 half-pel and 8 quarter-pel neighbours around the
// best integer vector are interpolated. This mirrors kvazaar's
// `search_mv_full` + `search_frac`.
motion_estimate :: proc(
	enc: ^Encoder,
	ref: ^Frame,
	x, y, w, h: int,
	pred_x, pred_y: i16,
	wp: Wp_Plane,
) -> (
	best: [2]i16,
	cost: u32,
) {
	// Integer-pixel search at unit step around the prediction.
	ix := i32(pred_x) >> 2
	iy := i32(pred_y) >> 2
	best = {i16(clamp(ix * 4, -2048, 2047)), i16(clamp(iy * 4, -2048, 2047))}
	cost = max(u32)
	range := enc.motion_range
	integer_exact := false
	for dy := -range; dy <= range && !integer_exact; dy += 1 {
		for dx := -range; dx <= range; dx += 1 {
			s := sad_int_luma(enc, ref, x, y, w, h, int(ix + dx), int(iy + dy))
			if s < cost {
				cost = s
				best = {
					i16(clamp((ix + dx) * 4, -2048, 2047)),
					i16(clamp((iy + dy) * 4, -2048, 2047)),
				}
				if s == 0 {
					integer_exact = true
					break
				}
			}
		}
	}
	// Half-pel (d = 2) then quarter-pel (d = 1) refinement: the 3x3
	// neighbourhood minus the centre, whose cost is already known.
	if !integer_exact {
		cache: Luma_Search_Interpolation = ---
		cache.ready = {}
		cache.ix = x + int(i32(best[0]) >> 2) - 1
		cache.iy = y + int(i32(best[1]) >> 2) - 1
		use_cache := wp_is_default(wp)
		for step in 1 ..= 2 {
			base := best
			d := i16(step == 1 ? 2 : 1)
			for oy := i32(-1); oy <= 1; oy += 1 {
				for ox := i32(-1); ox <= 1; ox += 1 {
					if ox == 0 && oy == 0 do continue
					mvx := base[0] + i16(ox) * d
					mvy := base[1] + i16(oy) * d
					s: u32
					if use_cache {
						src := enc.source.y
						s = mc_luma_search(
							true,
							&cache,
							nil,
							ref,
							x,
							y,
							w,
							h,
							mvx,
							mvy,
							enc.bit_depth,
							src.data[src.offset + y * src.stride + x:],
							src.stride,
						)
					} else {
						s = sad_mc_luma(enc, ref, x, y, w, h, mvx, mvy, wp)
					}
					if s < cost {
						cost = s
						best = {mvx, mvy}
					}
				}
			}
		}
	}
	return
}

// ---------------------------------------------------------------------------
// Candidate derivation helpers: z-scan availability, the shared AMVP sweeps
// and the merge list of a P slice. The AMVP candidates are the same 8.5.3.2.7
// process the B lists use, so a P slice with several active references gets
// the reference scaling the single-reference path never needed.
// ---------------------------------------------------------------------------

// Z-scan order address of the 4x4 block containing (x, y), following the
// decoder's min_tb_addr_zs table (6.4.1). With tiles the coding tree unit
// number is its 6.5.1 tile-scan index; without them it is the raster number.
@(private)
min_tb_addr_zs :: proc(enc: ^Encoder, x, y: int) -> int {
	ctb := (y >> 6) * enc.ctu_cols + (x >> 6)
	if enc.tiles_on do ctb = int(enc.ts_of[ctb])
	tx := (x >> 2) & 15
	ty := (y >> 2) & 15
	within: int
	for i in 0 ..< 4 {
		m := 1 << uint(i)
		if tx & m != 0 do within += m * m
		if ty & m != 0 do within += 2 * m * m
	}
	return ctb << 8 | within
}

// 6.4.1 derivation process for z-scan order block availability. The coding
// tree unit tile-scan number is part of the address, so any block belonging to
// a later coding tree unit (including one in a row below) is unavailable even
// when it lies to the left of the current block, and a block in another tile
// is never available.
@(private)
z_scan_available :: proc(enc: ^Encoder, x_curr, y_curr, x_n, y_n: int) -> bool {
	if !same_tile(enc, x_curr, y_curr, x_n, y_n) do return false
	return min_tb_addr_zs(enc, x_n, y_n) <= min_tb_addr_zs(enc, x_curr, y_curr)
}

// Pick the candidate that yields the cheapest MVD for the chosen motion
// vector. The decoder derives the same two candidates.
pick_mvp :: proc(cands: [2][2]i16, mv: [2]i16) -> int {
	d0 := abs(i32(mv[0]) - i32(cands[0][0])) + abs(i32(mv[1]) - i32(cands[0][1]))
	d1 := abs(i32(mv[0]) - i32(cands[1][0])) + abs(i32(mv[1]) - i32(cands[1][1]))
	return d0 <= d1 ? 0 : 1
}

// ---------------------------------------------------------------------------
// Merge candidates for a P slice (8.5.3.2.2/8.5.3.2.3). The list is the five
// spatial candidates A1, B1, B0, A0, B2, then the temporal candidate of
// 8.5.3.2.8 when `--tmvp` is on, followed by the zero-motion fill. Eligibility,
// pruning and the per-reference fill follow the decoder's
// merge_candidates/temporal_merge/zero_candidates exactly, or a decoded merge
// index would select a different vector.
// ---------------------------------------------------------------------------

MERGE_MAX_CAND :: 5

merge_candidates_p :: proc(
	enc: ^Encoder,
	x, y, size: int,
	c: Pu_Context,
	out: ^[8]Mv_Info,
) -> int {
	n := 0

	a1, ok_a1 := merge_get_enc(enc, x, y, x - 1, y + size - 1, 2, c)
	if ok_a1 {
		out[n] = a1
		n += 1
	}

	b1, ok_b1 := merge_get_enc(enc, x, y, x + size - 1, y - 1, 2, c)
	if ok_b1 && !(ok_a1 && same_motion_enc(&a1, &b1)) {
		out[n] = b1
		n += 1
	}

	if b0, ok := merge_get_enc(enc, x, y, x + size, y - 1, 2, c);
	   ok && !(ok_b1 && same_motion_enc(&b1, &b0)) {
		out[n] = b0
		n += 1
	}

	if a0, ok := merge_get_enc(enc, x, y, x - 1, y + size, 2, c);
	   ok && !(ok_a1 && same_motion_enc(&a1, &a0)) {
		out[n] = a0
		n += 1
	}

	if n < 4 {
		if b2, ok := merge_get_enc(enc, x, y, x - 1, y - 1, 2, c);
		   ok && !(ok_a1 && same_motion_enc(&a1, &b2)) && !(ok_b1 && same_motion_enc(&b1, &b2)) {
			out[n] = b2
			n += 1
		}
	}

	if n < MERGE_MAX_CAND {
		if t, ok := temporal_merge_enc(enc, x, y, size, size); ok {
			out[n] = t
			n += 1
		}
	}

	n = zero_enc(out, n, MERGE_MAX_CAND, false, enc.refs_active[0])
	return n
}

// ---------------------------------------------------------------------------
// B slices: per-list motion, decoder-faithful AMVP and merge derivation.
// ---------------------------------------------------------------------------

// Mv_Info mirrors the decoder's per-prediction-unit motion, including the
// per-list reference index so merge pruning and combined bi candidates agree.
Mv_Info :: struct {
	mv:      [2][2]i16,
	ref_idx: [2]i8,
	pred:    [2]bool,
}

same_motion_enc :: #force_inline proc(a, b: ^Mv_Info) -> bool {
	return a.pred == b.pred && a.mv == b.mv && a.ref_idx == b.ref_idx
}

// mc_luma_i16 writes the 14-bit intermediate the decoder's weighted combine
// consumes (8.5.3.3.3.1). The final uni sample equals the existing `mc_luma`,
// but bi-prediction needs both intermediates before the shift of 8.5.3.3.4.2.
mc_luma_i16 :: proc(
	dst: []i16,
	dst_stride: int,
	ref: ^Frame,
	x, y, w, h: int,
	mv_x, mv_y: i16,
	bit_depth: int,
) {
	ix := x + int(i32(mv_x) >> 2)
	iy := y + int(i32(mv_y) >> 2)
	xf := int(mv_x) & 3
	yf := int(mv_y) & 3
	ref_w, ref_h := ref.coded_width - 1, ref.coded_height - 1

	// The intermediate the decoder's combine consumes: the first pass shifted
	// by shift1, the second by 6, and the integer case scaled by shift3.
	shift1 := min(4, bit_depth - 8)
	shift3 := max(2, 14 - bit_depth)

	if xf == 0 && yf == 0 {
		for oy in 0 ..< h {
			for ox in 0 ..< w {
				dst[oy * dst_stride + ox] = i16(
					i32(at(ref.y, clamp_index(ix + ox, ref_w), clamp_index(iy + oy, ref_h))) <<
					uint(shift3),
				)
			}
		}
		return
	}
	if yf == 0 {
		f := LUMA_FILTER[xf]
		for oy in 0 ..< h {
			sy := clamp_index(iy + oy, ref_h)
			for ox in 0 ..< w {
				acc: i32
				for k in 0 ..< 8 do acc += f[k] * i32(at(ref.y, clamp_index(ix + ox + k - 3, ref_w), sy))
				dst[oy * dst_stride + ox] = i16(acc >> uint(shift1))
			}
		}
		return
	}
	if xf == 0 {
		f := LUMA_FILTER[yf]
		for oy in 0 ..< h {
			for ox in 0 ..< w {
				sx := clamp_index(ix + ox, ref_w)
				acc: i32
				for k in 0 ..< 8 do acc += f[k] * i32(at(ref.y, sx, clamp_index(iy + oy + k - 3, ref_h)))
				dst[oy * dst_stride + ox] = i16(acc >> uint(shift1))
			}
		}
		return
	}
	fx, fy := LUMA_FILTER[xf], LUMA_FILTER[yf]
	tmp: [64 + 7][64]i32 = ---
	for ry in 0 ..< h + 7 {
		sy := clamp_index(iy + ry - 3, ref_h)
		for rx in 0 ..< w {
			acc: i32
			for k in 0 ..< 8 do acc += fx[k] * i32(at(ref.y, clamp_index(ix + rx + k - 3, ref_w), sy))
			tmp[ry][rx] = acc >> uint(shift1)
		}
	}
	for oy in 0 ..< h {
		for ox in 0 ..< w {
			acc: i32
			for k in 0 ..< 8 do acc += fy[k] * tmp[oy + k][ox]
			dst[oy * dst_stride + ox] = i16(acc >> 6)
		}
	}
}

// Eighth-pel chroma intermediate (8.5.3.3.3.2).
mc_chroma_i16 :: proc(
	dst: []i16,
	dst_stride: int,
	plane: Plane(Sample),
	x, y, w, h: int,
	mv_x, mv_y: i16,
	frame_w, frame_h, bit_depth: int,
) {
	ix := x + int(i32(mv_x) >> 3)
	iy := y + int(i32(mv_y) >> 3)
	xf := int(mv_x) & 7
	yf := int(mv_y) & 7
	ref_w, ref_h := frame_w - 1, frame_h - 1

	shift1 := min(4, bit_depth - 8)
	shift3 := max(2, 14 - bit_depth)

	if xf == 0 && yf == 0 {
		for oy in 0 ..< h {
			for ox in 0 ..< w {
				dst[oy * dst_stride + ox] = i16(
					i32(at(plane, clamp_index(ix + ox, ref_w), clamp_index(iy + oy, ref_h))) <<
					uint(shift3),
				)
			}
		}
		return
	}
	if yf == 0 {
		f := CHROMA_FILTER[xf]
		for oy in 0 ..< h {
			sy := clamp_index(iy + oy, ref_h)
			for ox in 0 ..< w {
				acc: i32
				for k in 0 ..< 4 do acc += f[k] * i32(at(plane, clamp_index(ix + ox + k - 1, ref_w), sy))
				dst[oy * dst_stride + ox] = i16(acc >> uint(shift1))
			}
		}
		return
	}
	if xf == 0 {
		f := CHROMA_FILTER[yf]
		for oy in 0 ..< h {
			for ox in 0 ..< w {
				sx := clamp_index(ix + ox, ref_w)
				acc: i32
				for k in 0 ..< 4 do acc += f[k] * i32(at(plane, sx, clamp_index(iy + oy + k - 1, ref_h)))
				dst[oy * dst_stride + ox] = i16(acc >> uint(shift1))
			}
		}
		return
	}
	fx, fy := CHROMA_FILTER[xf], CHROMA_FILTER[yf]
	tmp: [64 + 3][64]i32 = ---
	for ry in 0 ..< h + 3 {
		sy := clamp_index(iy + ry - 1, ref_h)
		for rx in 0 ..< w {
			acc: i32
			for k in 0 ..< 4 do acc += fx[k] * i32(at(plane, clamp_index(ix + rx + k - 1, ref_w), sy))
			tmp[ry][rx] = acc >> uint(shift1)
		}
	}
	for oy in 0 ..< h {
		for ox in 0 ..< w {
			acc: i32
			for k in 0 ..< 4 do acc += fy[k] * tmp[oy + k][ox]
			dst[oy * dst_stride + ox] = i16(acc >> 6)
		}
	}
}

// Weighted uni-prediction of 8.5.3.3.4.3 over the 14-bit intermediate. The
// inferred weights reduce to the default process of 8.5.3.3.4.2 exactly, so
// the unweighted loop is kept as the fast path.
pred_uni_w :: proc(
	dst: []Sample,
	dst_stride: int,
	src: []i16,
	src_stride, w, h: int,
	wp: Wp_Plane,
) {
	if wp_is_default(wp) {
		off := i32(1) << uint(wp.shift1 - 1)
		for j in 0 ..< h {
			for i in 0 ..< w {
				v := (i32(src[j * src_stride + i]) + off) >> uint(wp.shift1)
				dst[j * dst_stride + i] = Sample(clamp(v, 0, wp.max_v))
			}
		}
		return
	}

	round := i32(1) << uint(wp.log2_wd - 1)
	for j in 0 ..< h {
		for i in 0 ..< w {
			v :=
				((i32(src[j * src_stride + i]) * wp.weight + round) >> uint(wp.log2_wd)) +
				wp.offset
			dst[j * dst_stride + i] = Sample(clamp(v, 0, wp.max_v))
		}
	}
}

// Weighted bi-prediction of 8.5.3.3.4.3. Both lists share the slice's
// denominator, so one log2Wd drives the pair.
pred_bi_w :: proc(
	dst: []Sample,
	dst_stride: int,
	a, b: []i16,
	src_stride, w, h: int,
	wp0, wp1: Wp_Plane,
) {
	if wp_is_default(wp0) && wp_is_default(wp1) {
		off := i32(1) << uint(wp0.shift1)
		for j in 0 ..< h {
			for i in 0 ..< w {
				v :=
					(i32(a[j * src_stride + i]) + i32(b[j * src_stride + i]) + off) >>
					uint(wp0.shift1 + 1)
				dst[j * dst_stride + i] = Sample(clamp(v, 0, wp0.max_v))
			}
		}
		return
	}

	round := (wp0.offset + wp1.offset + 1) << uint(wp0.log2_wd)
	for j in 0 ..< h {
		for i in 0 ..< w {
			v :=
				(i32(a[j * src_stride + i]) * wp0.weight +
					i32(b[j * src_stride + i]) * wp1.weight +
					round) >>
				uint(wp0.log2_wd + 1)
			dst[j * dst_stride + i] = Sample(clamp(v, 0, wp0.max_v))
		}
	}
}

// mc_luma_uni_w is the P-list luma prediction: interpolation into the 14-bit
// intermediate followed by the weighted uni combine. With inferred weights it
// is sample-for-sample `mc_luma`, so that is the fast path.
mc_luma_uni_w :: proc(
	dst: []Sample,
	dst_stride: int,
	ref: ^Frame,
	x, y, w, h: int,
	mv: [2]i16,
	wp: Wp_Plane,
	bit_depth: int,
) {
	if wp_is_default(wp) {
		mc_luma(dst, dst_stride, ref, x, y, w, h, mv[0], mv[1], bit_depth)
		return
	}

	tmp: [32 * 32]i16 = ---
	mc_luma_i16(tmp[:], w, ref, x, y, w, h, mv[0], mv[1], bit_depth)
	pred_uni_w(dst, dst_stride, tmp[:], w, w, h, wp)
}

mc_chroma_uni_w :: proc(
	dst: []Sample,
	dst_stride: int,
	plane: Plane(Sample),
	x, y, w, h: int,
	mv: [2]i16,
	frame_w, frame_h: int,
	wp: Wp_Plane,
	bit_depth: int,
) {
	if wp_is_default(wp) {
		mc_chroma(dst, dst_stride, plane, x, y, w, h, mv[0], mv[1], frame_w, frame_h, bit_depth)
		return
	}

	tmp: [16 * 16]i16 = ---
	mc_chroma_i16(tmp[:], w, plane, x, y, w, h, mv[0], mv[1], frame_w, frame_h, bit_depth)
	pred_uni_w(dst, dst_stride, tmp[:], w, w, h, wp)
}

@(private)
clip3_i32 :: #force_inline proc(v, lo, hi: i32) -> i32 {
	return v < lo ? lo : (v > hi ? hi : v)
}

@(private)
sign_i32 :: #force_inline proc(v: i32) -> i32 {
	switch {
	case v < 0:
		return -1
	case v > 0:
		return 1
	}
	return 0
}

// scale_mv is the temporal distance scaling of 8.5.3.2.8, ported from the
// decoder. The encoder's references are all short term.
scale_mv_enc :: proc(v: [2]i16, curr_poc, ref_poc, col_poc, col_ref_poc: i32) -> [2]i16 {
	td := clip3_i32(col_poc - col_ref_poc, -128, 127)
	tb := clip3_i32(curr_poc - ref_poc, -128, 127)
	if td == 0 do return v

	tx := (16384 + abs(td) / 2) / td
	scale := clip3_i32((tb * tx + 32) >> 6, -4096, 4095)

	sx := scale * i32(v[0])
	sy := scale * i32(v[1])
	return {
		i16(clip3_i32(sign_i32(sx) * ((abs(sx) + 127) >> 8), -32768, 32767)),
		i16(clip3_i32(sign_i32(sy) * ((abs(sy) + 127) >> 8), -32768, 32767)),
	}
}

// ---------------------------------------------------------------------------
// Temporal MVP (8.5.3.2.8/8.5.3.2.9). The collocated picture is list 0's
// nearest reference (`collocated_from_l0` is always signalled true and
// `collocated_ref_idx` is always 0), and its 16x16 motion field was captured
// when it was coded. Both the search and the bitstream replay call this
// derivation, so the signalled merge index and mvp flag always select the
// vector the search costed.
// ---------------------------------------------------------------------------

// resolve_temporal selects the collocated picture's motion field for the
// picture about to be coded. `slice_temporal_mvp_enabled_flag` is written
// whenever the SPS enables the tool; a missing field simply yields no temporal
// candidate (which cannot happen for the encoder's own reference histories).
resolve_temporal :: proc(enc: ^Encoder) {
	enc.col = nil
	enc.tmvp = false
	if !enc.config.tmvp || enc.slice_type == .I do return

	enc.tmvp = true
	enc.col_from_l0 = true

	// 8.5.3.2.9: with no future reference the collocated block's list follows
	// the current list rather than the collocated_from_l0 field.
	enc.no_backward_pred = true
	for l in 0 ..< 2 {
		for r in 0 ..< enc.refs_active[l] {
			if enc.ref_poc[l][r] > enc.cur_poc do enc.no_backward_pred = false
		}
	}

	if enc.refs_active[0] == 0 do return

	col_poc := enc.ref_poc[0][0]
	for i in 0 ..< MAX_COL_PICS {
		if enc.col_ring_valid[i] && enc.col_ring_poc[i] == col_poc {
			enc.col = enc.col_buf[i]
			enc.col_poc = col_poc
			return
		}
	}
}

// capture_col_motion files the finished picture's motion field for the
// temporal predictor of later pictures. The 16x16 subsampling, the intra flag
// and the reference POCs are exactly what the decoder stores in a Picture's
// col_motion and reads back in temporal_mv.
capture_col_motion :: proc(enc: ^Encoder, poc: i32) {
	if !enc.config.tmvp do return

	slot := enc.col_next
	enc.col_next = (enc.col_next + 1) % MAX_COL_PICS
	grid := enc.col_buf[slot]
	rows := (enc.coded_height + 15) / 16

	for ry in 0 ..< rows {
		for rx in 0 ..< enc.col_cols {
			c := &grid[ry * enc.col_cols + rx]
			cu := cu_at(enc.cu, rx * 16, ry * 16)

			c^ = {}
			if cu.type != .Inter {
				c.intra = true
				continue
			}

			c.info = Mv_Info {
				mv      = cu.mv,
				ref_idx = cu.ref_idx,
				pred    = cu.pred,
			}
			for l in 0 ..< 2 {
				r := int(cu.ref_idx[l])
				if cu.pred[l] && r >= 0 && r < enc.refs_active[l] {
					c.ref_poc[l] = enc.ref_poc[l][r]
				}
			}
		}
	}

	enc.col_ring_poc[slot] = poc
	enc.col_ring_valid[slot] = true
}

// temporal_mv is the encoder's 8.5.3.2.8 and 8.5.3.2.9: the collocated block
// at the bottom-right of the prediction unit, falling back to its centre. It
// mirrors the decoder's temporal_mv including the long-term status test and
// the current-picture POC rejection; the encoder has no long-term references,
// so `ref_long` is always false.
temporal_mv_enc :: proc(enc: ^Encoder, x, y, w, h, list: int, ref_poc: i32) -> ([2]i16, bool) {
	if !enc.tmvp || enc.col == nil do return {}, false

	derive :: proc(enc: ^Encoder, c: ^Col_Motion_Enc, list: int, ref_poc: i32) -> ([2]i16, bool) {
		l := 0
		switch {
		case !c.info.pred[0]:
			l = 1
		case !c.info.pred[1]:
			l = 0
		case enc.no_backward_pred:
			l = list
		case enc.col_from_l0:
			l = 1
		case:
			l = 0
		}

		if !c.info.pred[l] do return {}, false
		if c.ref_long[l] do return {}, false
		if c.ref_poc[l] == enc.cur_poc || ref_poc == enc.cur_poc do return {}, false

		if enc.col_poc - c.ref_poc[l] == enc.cur_poc - ref_poc {
			return c.info.mv[l], true
		}

		return scale_mv_enc(c.info.mv[l], enc.cur_poc, ref_poc, enc.col_poc, c.ref_poc[l]), true
	}

	try :: proc(enc: ^Encoder, x, y: int) -> (^Col_Motion_Enc, bool) {
		if x < 0 || y < 0 || x >= enc.coded_width || y >= enc.coded_height do return nil, false

		c := &enc.col[(y >> 4) * enc.col_cols + (x >> 4)]
		if c.intra do return nil, false

		return c, true
	}

	// The bottom-right candidate is unavailable outside the picture or past the
	// coding tree row, and the centre takes over whenever it yields nothing.
	if c, ok := try(enc, x + w, y + h); ok && y >> 6 == (y + h) >> 6 {
		if v, ok2 := derive(enc, c, list, ref_poc); ok2 do return v, true
	}

	c, ok := try(enc, x + w / 2, y + h / 2)
	if !ok do return {}, false

	return derive(enc, c, list, ref_poc)
}

// temporal_merge is 8.5.3.2.8's merge candidate: reference index zero in each
// list the slice uses, taken through temporal_mv.
temporal_merge_enc :: proc(enc: ^Encoder, x, y, w, h: int) -> (Mv_Info, bool) {
	m: Mv_Info
	m.ref_idx = {-1, -1}

	for l in 0 ..< 2 {
		if l == 1 && enc.slice_type != .B do continue
		if enc.refs_active[l] == 0 do continue

		v, ok := temporal_mv_enc(enc, x, y, w, h, l, enc.ref_poc[l][0])
		if !ok do continue

		m.mv[l] = v
		m.ref_idx[l] = 0
		m.pred[l] = true
	}

	return m, m.pred[0] || m.pred[1]
}

// Pu_Context is the current prediction unit and its coding block, which
// 6.4.2's available_pb needs to decide neighbour availability.
Pu_Context :: struct {
	cu_x, cu_y: int,
	cu_size:    int,
	pu_w, pu_h: int,
	part_idx:   int,
}

// available_pb_enc is the decoder's available_pb: a neighbour inside the
// current coding block is available without the z-scan order test, apart from
// the NxN partition exclusion of 6.4.2.
available_pb_enc :: proc(enc: ^Encoder, x_curr, y_curr, x_n, y_n: int, c: Pu_Context) -> bool {
	if x_n < 0 || y_n < 0 || x_n >= enc.coded_width || y_n >= enc.coded_height do return false

	same_cb :=
		x_n >= c.cu_x && x_n < c.cu_x + c.cu_size && y_n >= c.cu_y && y_n < c.cu_y + c.cu_size
	if !same_cb do return z_scan_available(enc, x_curr, y_curr, x_n, y_n)

	return(
		!(c.pu_w * 2 == c.cu_size &&
			c.pu_h * 2 == c.cu_size &&
			c.part_idx == 1 &&
			c.cu_y + c.pu_h <= y_n &&
			c.cu_x + c.pu_w > x_n) \
	)
}

// neighbour_mv_enc reads a decoded block's per-list motion, or reports it
// unavailable, matching the decoder's neighbour_mv.
@(private)
neighbour_mv_enc :: proc(
	enc: ^Encoder,
	x_curr, y_curr, x, y: int,
	c: Pu_Context,
) -> (
	Mv_Info,
	bool,
) {
	if !available_pb_enc(enc, x_curr, y_curr, x, y, c) do return {}, false
	cu := cu_at(enc.cu, x, y)
	if cu.type != .Inter do return {}, false
	return Mv_Info{mv = cu.mv, ref_idx = cu.ref_idx, pred = cu.pred}, true
}

// merge_get_enc is the `get` of 8.5.3.2.2: a neighbour inside the parallel
// merge region is unavailable. The PPS uses log2_parallel_merge_level 2.
@(private)
merge_get_enc :: proc(
	enc: ^Encoder,
	x_pb, y_pb, x_n, y_n, level: int,
	c: Pu_Context,
) -> (
	Mv_Info,
	bool,
) {
	if x_pb >> uint(level) == x_n >> uint(level) && y_pb >> uint(level) == y_n >> uint(level) {
		return {}, false
	}
	return neighbour_mv_enc(enc, x_pb, y_pb, x_n, y_n, c)
}

// amvp_direct_enc and amvp_scaled_enc are the two halves of 8.5.3.2.7. The
// neighbour's reference POC is looked up through its stored per-list reference
// index, exactly as the decoder's amvp_direct/amvp_scaled do.
@(private)
amvp_direct_enc :: proc(enc: ^Encoder, m: ^Mv_Info, list: int, ref_poc: i32) -> ([2]i16, bool) {
	for k in 0 ..< 2 {
		l := list ~ k
		r := int(m.ref_idx[l])
		if m.pred[l] && r >= 0 && r < enc.refs_active[l] && enc.ref_poc[l][r] == ref_poc {
			return m.mv[l], true
		}
	}
	return {}, false
}

@(private)
amvp_scaled_enc :: proc(
	enc: ^Encoder,
	m: ^Mv_Info,
	list: int,
	ref_poc, curr_poc: i32,
) -> (
	[2]i16,
	bool,
) {
	for k in 0 ..< 2 {
		l := list ~ k
		r := int(m.ref_idx[l])
		if !m.pred[l] || r < 0 || r >= enc.refs_active[l] do continue
		return scale_mv_enc(m.mv[l], curr_poc, ref_poc, curr_poc, enc.ref_poc[l][r]), true
	}
	return {}, false
}

@(private)
amvp_sweep_enc :: proc(
	enc: ^Encoder,
	x_curr, y_curr: int,
	pos: [][2]int,
	c: Pu_Context,
	list: int,
	ref_poc, curr_poc: i32,
	scale: bool,
) -> (
	[2]i16,
	bool,
) {
	for p in pos {
		m, ok := neighbour_mv_enc(enc, x_curr, y_curr, p[0], p[1], c)
		if !ok do continue
		v: [2]i16
		found: bool
		if scale {
			v, found = amvp_scaled_enc(enc, &m, list, ref_poc, curr_poc)
		} else {
			v, found = amvp_direct_enc(enc, &m, list, ref_poc)
		}
		if found do return v, true
	}
	return {}, false
}

// amvp_candidates_b is 8.5.3.2.7 for one reference list of a B slice,
// including the scaled sweep the P path does not need.
amvp_candidates_b :: proc(
	enc: ^Encoder,
	x, y, w, h, list: int,
	c: Pu_Context,
	ref_poc, curr_poc: i32,
) -> (
	out: [2][2]i16,
	avail: [2]bool,
) {
	left := [2][2]int{{x - 1, y + h}, {x - 1, y + h - 1}}
	above := [3][2]int{{x + w, y - 1}, {x + w - 1, y - 1}, {x - 1, y - 1}}

	is_scaled := false
	for p in left {
		if _, ok := neighbour_mv_enc(enc, x, y, p[0], p[1], c); ok do is_scaled = true
	}

	out[0], avail[0] = amvp_sweep_enc(enc, x, y, left[:], c, list, ref_poc, curr_poc, false)
	if !avail[0] {
		out[0], avail[0] = amvp_sweep_enc(enc, x, y, left[:], c, list, ref_poc, curr_poc, true)
	}
	out[1], avail[1] = amvp_sweep_enc(enc, x, y, above[:], c, list, ref_poc, curr_poc, false)

	if !is_scaled {
		out[0], avail[0] = out[1], avail[1]
		out[1], avail[1] = amvp_sweep_enc(enc, x, y, above[:], c, list, ref_poc, curr_poc, true)
	}
	return
}

// amvp_build_list assembles the two predictors the decoder's prediction_unit
// signals with mvp_lX_flag: the pruned spatial pair, then the temporal
// candidate of 8.5.3.2.8 when the tool is on and a slot is still free. A
// missing second candidate stays the zero vector.
amvp_build_list :: proc(
	enc: ^Encoder,
	x, y, w, h, list: int,
	ref_poc: i32,
	out: [2][2]i16,
	avail: [2]bool,
) -> [2][2]i16 {
	c: [2][2]i16
	n := 0
	if avail[0] {
		c[n] = out[0]
		n += 1
	}
	if avail[1] && !(avail[0] && out[0] == out[1]) {
		c[n] = out[1]
		n += 1
	}
	if n < 2 {
		if t, ok := temporal_mv_enc(enc, x, y, w, h, list, ref_poc); ok {
			c[n] = t
			n += 1
		}
	}
	return c
}

// merge_candidates_b is the B-slice merge list of 8.5.3.2.2, 8.5.3.2.4 and
// 8.5.3.2.5: the spatial candidates, the combined bi pairs and the bi zero
// fill, matching the decoder's list exactly.
merge_candidates_b :: proc(enc: ^Encoder, x, y, size: int, out: ^[8]Mv_Info) -> int {
	n := 0
	c := Pu_Context {
		cu_x    = x,
		cu_y    = y,
		cu_size = size,
		pu_w    = size,
		pu_h    = size,
	}

	a1, ok_a1 := merge_get_enc(enc, x, y, x - 1, y + size - 1, 2, c)
	if ok_a1 {
		out[n] = a1
		n += 1
	}

	b1, ok_b1 := merge_get_enc(enc, x, y, x + size - 1, y - 1, 2, c)
	if ok_b1 && !(ok_a1 && same_motion_enc(&a1, &b1)) {
		out[n] = b1
		n += 1
	}

	if b0, ok := merge_get_enc(enc, x, y, x + size, y - 1, 2, c);
	   ok && !(ok_b1 && same_motion_enc(&b1, &b0)) {
		out[n] = b0
		n += 1
	}

	if a0, ok := merge_get_enc(enc, x, y, x - 1, y + size, 2, c);
	   ok && !(ok_a1 && same_motion_enc(&a1, &a0)) {
		out[n] = a0
		n += 1
	}

	if n < 4 {
		if b2, ok := merge_get_enc(enc, x, y, x - 1, y - 1, 2, c);
		   ok && !(ok_a1 && same_motion_enc(&a1, &b2)) && !(ok_b1 && same_motion_enc(&b1, &b2)) {
			out[n] = b2
			n += 1
		}
	}

	if n < MERGE_MAX_CAND {
		if t, ok := temporal_merge_enc(enc, x, y, size, size); ok {
			out[n] = t
			n += 1
		}
	}

	n = combine_bi_enc(enc, out, n, MERGE_MAX_CAND)
	num_ref := min(enc.refs_active[0], enc.refs_active[1])
	n = zero_enc(out, n, MERGE_MAX_CAND, true, num_ref)
	return n
}

// combine_bi_enc is 8.5.3.2.4: pair the L0 of one candidate with the L1 of
// another in the order of Table 8-6.
@(private)
combine_bi_enc :: proc(enc: ^Encoder, out: ^[8]Mv_Info, n, max_cand: int) -> int {
	l0_idx := [12]int{0, 1, 0, 2, 1, 2, 0, 3, 1, 3, 2, 3}
	l1_idx := [12]int{1, 0, 2, 0, 2, 1, 3, 0, 3, 1, 3, 2}

	orig := n
	count := n
	if orig < 2 do return n

	for k := 0; k < orig * (orig - 1) && count < max_cand; k += 1 {
		if k >= len(l0_idx) do break

		a, b := &out[l0_idx[k]], &out[l1_idx[k]]
		ar, br := int(a.ref_idx[0]), int(b.ref_idx[1])
		if !a.pred[0] || !b.pred[1] do continue
		if ar < 0 || ar >= enc.refs_active[0] || br < 0 || br >= enc.refs_active[1] do continue
		if enc.ref_poc[0][ar] == enc.ref_poc[1][br] && a.mv[0] == b.mv[1] do continue

		out[count] = Mv_Info {
			mv      = {a.mv[0], b.mv[1]},
			ref_idx = {a.ref_idx[0], b.ref_idx[1]},
			pred    = {true, true},
		}
		count += 1
	}
	return count
}

// zero_enc is 8.5.3.2.5. B slices fill with bi-predicted zero motion; P slices
// with a single list. The fill walks the active reference indices and clamps
// to 0 once it runs past `num_ref`, exactly like the decoder's zero_candidates;
// with one active reference every fill lands on 0 as before.
@(private)
zero_enc :: proc(out: ^[8]Mv_Info, n, max_cand: int, bi: bool, num_ref: int) -> int {
	count := n
	for i := 0; count < max_cand; i += 1 {
		r := i8(0)
		if i < num_ref do r = i8(i)
		c: Mv_Info
		c.ref_idx = {r, r}
		c.pred = {true, bi}
		if !bi do c.ref_idx[1] = -1
		out[count] = c
		count += 1
	}
	return count
}

PRED_L0 :: 0
PRED_L1 :: 1
PRED_BI :: 2

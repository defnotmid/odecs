package h265_encoder

// ---------------------------------------------------------------------------
// Rectangular (2NxN, Nx2N) and asymmetric (AMP) inter partitions. The
// search evaluates each available partition mode for a CU and keeps the best
// by RD; the chosen plan lives in the 4x4 CU grid, one motion record per
// prediction unit, exactly like the decoder's picture-wide motion field, so
// merge/AMVP derivation and deblocking read it back the same way.
//
// Every derivation here mirrors codec/h265/decoder/{inter,mvpred,ctu}.odin:
// the candidate lists, the partition pruning of 8.5.3.2.2, the L1 drop for
// 8x4/4x8 merge units and the luma/chroma reconstruction all have to agree or
// a decoded merge index would select a different vector.
// ---------------------------------------------------------------------------

// Prediction unit shapes in quarter-CU units, indexed by part mode. This is
// the decoder's PART_SHAPE (Table 7-10 geometry).
PART_SHAPE := [8][4][4]int {
	{{0, 0, 4, 4}, {0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 4, 2}, {0, 2, 4, 2}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 2, 4}, {2, 0, 2, 4}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 2, 2}, {2, 0, 2, 2}, {0, 2, 2, 2}, {2, 2, 2, 2}},
	{{0, 0, 4, 1}, {0, 1, 4, 3}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 4, 3}, {0, 3, 4, 1}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 1, 4}, {1, 0, 3, 4}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 3, 4}, {3, 0, 1, 4}, {0, 0, 0, 0}, {0, 0, 0, 0}},
}

PART_COUNT := [8]int{1, 2, 2, 4, 2, 2, 2, 2}

// Partition modes the search may pick. Inter NxN is only codable when the
// minimum coding block is larger than 8x8 (decode_part_mode reads the third
// bin only then; ffmpeg's ff_hevc_part_mode_decode does the same), and this
// encoder's minimum CU is 8. The AMP modes need amp_enabled and a CU above
// the minimum. Table 7-10, matching decode_part_mode.
part_available :: #force_inline proc(part: Part_Mode, size: int) -> bool {
	if part == .P_2Nx2N do return true
	if part == .P_NxN do return false
	if size == 8 do return part == .P_2NxN || part == .P_Nx2N
	return true
}

// pu_context gives one prediction unit's coding-block context from its part
// shape (the values 6.4.2's available_pb needs).
pu_context :: #force_inline proc(x, y, size: int, part: Part_Mode, q, i: int) -> Pu_Context {
	s := PART_SHAPE[int(part)][i]
	return Pu_Context {
		cu_x = x,
		cu_y = y,
		cu_size = size,
		pu_w = s[2] * q,
		pu_h = s[3] * q,
		part_idx = i,
	}
}

// Number of partition candidates evaluated in full per CU. The rest are
// ranked by their all-merge prediction cost.
PART_TRY :: 1

// Approximate extra rate of AMVP over merge, in bits, used to bias the
// per-PU choice before the whole-CU RD pass measures the real syntax.
PART_AMVP_BIAS_BITS :: 12

// A PU whose best merge prediction is this accurate skips its motion search.
// The bound is the 2Nx2N skip-first trade applied per prediction unit, with a
// wider per-pixel budget because a partition PU is searched for every part.
PART_SEARCH_LAMBDA_SCALE :: 0.5
PART_SEARCH_SSE_CAP :: 48

@(private)
part_search_limit :: #force_inline proc(enc: ^Encoder, w, h: int) -> u64 {
	per_pixel := u64(enc.lambda * PART_SEARCH_LAMBDA_SCALE + 0.5)
	if per_pixel == 0 do per_pixel = 1
	if per_pixel > PART_SEARCH_SSE_CAP do per_pixel = PART_SEARCH_SSE_CAP
	return u64(w * h) * per_pixel
}

// ---------------------------------------------------------------------------
// CU grid helpers
// ---------------------------------------------------------------------------

// fill_pu_info writes one prediction unit's record into the cells it covers.
// The decoder's set_mv does the same for its motion field, so later PUs of the
// same CU read it back during candidate derivation.
fill_pu_info :: proc(enc: ^Encoder, x, y, width, height: int, info_in: Cu_Info) {
	info := info_in
	if !info.pred[0] do info.ref_idx[0] = -1
	if !info.pred[1] do info.ref_idx[1] = -1
	for cy in y ..< y + height {
		for cx in x ..< x + width {
			if cx & 3 != 0 || cy & 3 != 0 do continue
			cu_at(enc.cu, cx, cy)^ = info
		}
	}
}

// mark_pu_enc is the decoder's mark_pu (8.7.2.2): the first row and first
// column of a prediction unit carry its deblocking edge flags.
mark_pu_enc :: proc(enc: ^Encoder, x, y, width, height: int) #no_bounds_check {
	span_w := width >> 2
	span_h := height >> 2
	base := (y >> 2) * enc.cu.cols + (x >> 2)
	for j in 0 ..< span_h {
		row := base + j * enc.cu.cols
		for i in 0 ..< span_w {
			c := &enc.cu.cells[row + i]
			if j == 0 do c.pu_h = true
			if i == 0 do c.pu_v = true
		}
	}
}

// set_part_skip records the no-residual decision of a partitioned CU so the
// bitstream pass replays the candidate the search actually costed.
set_part_skip :: proc(enc: ^Encoder, x, y, size: int, v: bool) #no_bounds_check {
	span := size >> 2
	base := (y >> 2) * enc.cu.cols + (x >> 2)
	for j in 0 ..< span {
		row := base + j * enc.cu.cols
		for i in 0 ..< span do enc.cu.cells[row + i].part_skip = v
	}
}

// set_tu_cbf records one transform unit's coded block flags on its cells so
// deblocking reads the same cbf the decoder marks with mark_tu.
set_tu_cbf :: proc(enc: ^Encoder, x, y, size: int, cbf_y, cbf_u, cbf_v: bool) #no_bounds_check {
	span := size >> 2
	base := (y >> 2) * enc.cu.cols + (x >> 2)
	for j in 0 ..< span {
		row := base + j * enc.cu.cols
		for i in 0 ..< span {
			c := &enc.cu.cells[row + i]
			c.cbf_y = cbf_y
			c.cbf_u = cbf_u
			c.cbf_v = cbf_v
		}
	}
}

// ---------------------------------------------------------------------------
// Merge candidates for one prediction unit. This is the decoder's
// merge_candidates including its partition-dependent pruning: a partition
// rule that excludes A1 or B1 removes it from the pruning comparisons too.
// ---------------------------------------------------------------------------

merge_candidates_pu :: proc(
	enc: ^Encoder,
	x_pb, y_pb, w, h, part_idx: int,
	part: Part_Mode,
	c: Pu_Context,
	out: ^[8]Mv_Info,
	bi: bool,
) -> int {
	n := 0

	// A1 = (x-1, y+h-1), excluded for the second PU of a horizontal split.
	a1, ok_a1 := merge_get_enc(enc, x_pb, y_pb, x_pb - 1, y_pb + h - 1, 2, c)
	if part_idx == 1 && (part == .P_Nx2N || part == .P_nLx2N || part == .P_nRx2N) do ok_a1 = false
	if ok_a1 {
		out[n] = a1
		n += 1
	}

	// B1 = (x+w-1, y-1), excluded for the second PU of a vertical split.
	b1, ok_b1 := merge_get_enc(enc, x_pb, y_pb, x_pb + w - 1, y_pb - 1, 2, c)
	if part_idx == 1 && (part == .P_2NxN || part == .P_2NxnU || part == .P_2NxnD) do ok_b1 = false
	if ok_b1 && !(ok_a1 && same_motion_enc(&a1, &b1)) {
		out[n] = b1
		n += 1
	}

	if b0, ok := merge_get_enc(enc, x_pb, y_pb, x_pb + w, y_pb - 1, 2, c);
	   ok && !(ok_b1 && same_motion_enc(&b1, &b0)) {
		out[n] = b0
		n += 1
	}

	if a0, ok := merge_get_enc(enc, x_pb, y_pb, x_pb - 1, y_pb + h, 2, c);
	   ok && !(ok_a1 && same_motion_enc(&a1, &a0)) {
		out[n] = a0
		n += 1
	}

	if n < 4 {
		if b2, ok := merge_get_enc(enc, x_pb, y_pb, x_pb - 1, y_pb - 1, 2, c);
		   ok && !(ok_a1 && same_motion_enc(&a1, &b2)) && !(ok_b1 && same_motion_enc(&b1, &b2)) {
			out[n] = b2
			n += 1
		}
	}

	if n < MERGE_MAX_CAND {
		if t, ok := temporal_merge_enc(enc, x_pb, y_pb, w, h); ok {
			out[n] = t
			n += 1
		}
	}

	if bi do n = combine_bi_enc(enc, out, n, MERGE_MAX_CAND)
	num_ref := enc.refs_active[0]
	if bi do num_ref = min(num_ref, enc.refs_active[1])
	n = zero_enc(out, n, MERGE_MAX_CAND, bi, num_ref)
	return n
}

// merge_candidate_drop_l1 is the decoder's 8.5.3.2.1 restriction: an 8x4 or
// 4x8 merge unit may not be bi-predicted, so a bi candidate falls to list 0.
merge_candidate_drop_l1 :: #force_inline proc(m: Mv_Info, w, h: int) -> Mv_Info {
	v := m
	if w + h == 12 && v.pred[0] && v.pred[1] {
		v.pred[1] = false
		v.mv[1] = {}
		v.ref_idx[1] = -1
	}
	return v
}

// ---------------------------------------------------------------------------
// Prediction. The CU's prediction planes are materialised once per candidate
// with every PU writing its own region, which is also what the transform tree
// reads when a TU spans two PUs (an AMP split).
// ---------------------------------------------------------------------------

Cu_Pred :: struct {
	y:        []Sample,
	u:        []Sample,
	v:        []Sample,
	y_stride: int,
	c_stride: int,
	cu_x:     int,
	cu_y:     int,
}

part_mc_luma_p :: #force_inline proc(
	enc: ^Encoder,
	x, y, w, h: int,
	mv: [2]i16,
	ref: int,
	dst: []Sample,
	dst_stride: int,
) {
	mc_luma_uni_w(
		dst,
		dst_stride,
		&enc.refs[0][ref],
		x,
		y,
		w,
		h,
		mv,
		wp_luma(enc, 0, ref),
		enc.bit_depth,
	)
}

part_mc_chroma_p :: #force_inline proc(
	enc: ^Encoder,
	x, y, w, h: int,
	mv: [2]i16,
	ref: int,
	plane_idx: int,
	plane: Plane(Sample),
	dst: []Sample,
	dst_stride: int,
) {
	sw, sh := chroma_sub(enc.config.chroma_format)
	mc_chroma_uni_w(
		dst,
		dst_stride,
		plane,
		x / sw,
		y / sh,
		w / sw,
		h / sh,
		chroma_mv(enc.config.chroma_format, mv),
		enc.coded_width / sw,
		enc.coded_height / sh,
		wp_chroma(enc, 0, ref, plane_idx),
		enc.bit_depth,
	)
}

// part_mc_luma_b materialises one PU's luma prediction of a B slice at the
// given stride, averaging both lists with the decoder's default bi-prediction
// when they are used.
part_mc_luma_b :: proc(
	enc: ^Encoder,
	pux, puy, w, h: int,
	pred: [2]bool,
	mv: [2][2]i16,
	ref_idx: [2]i8,
	dst: []Sample,
	dst_stride: int,
) {
	if pred[0] && pred[1] {
		a, b: [32 * 32]i16
		mc_luma_i16(
			a[:],
			w,
			&enc.refs[0][ref_idx[0]],
			pux,
			puy,
			w,
			h,
			mv[0][0],
			mv[0][1],
			enc.bit_depth,
		)
		mc_luma_i16(
			b[:],
			w,
			&enc.refs[1][ref_idx[1]],
			pux,
			puy,
			w,
			h,
			mv[1][0],
			mv[1][1],
			enc.bit_depth,
		)
		pred_bi_w(
			dst,
			dst_stride,
			a[:],
			b[:],
			w,
			w,
			h,
			wp_luma(enc, 0, int(ref_idx[0])),
			wp_luma(enc, 1, int(ref_idx[1])),
		)
		return
	}

	l := pred[0] ? 0 : 1
	t: [32 * 32]i16
	mc_luma_i16(
		t[:],
		w,
		&enc.refs[l][ref_idx[l]],
		pux,
		puy,
		w,
		h,
		mv[l][0],
		mv[l][1],
		enc.bit_depth,
	)
	pred_uni_w(dst, dst_stride, t[:], w, w, h, wp_luma(enc, l, int(ref_idx[l])))
}

part_mc_chroma_b :: proc(
	enc: ^Encoder,
	pux, puy, w, h: int,
	pred: [2]bool,
	mv: [2][2]i16,
	ref_idx: [2]i8,
	u, v: []Sample,
	dst_stride: int,
) {
	sw, sh := chroma_sub(enc.config.chroma_format)
	mvc := [2][2]i16 {
		chroma_mv(enc.config.chroma_format, mv[0]),
		chroma_mv(enc.config.chroma_format, mv[1]),
	}
	cw, ch := w / sw, h / sh
	fw, fh := enc.coded_width / sw, enc.coded_height / sh
	x, y := pux / sw, puy / sh

	if pred[0] && pred[1] {
		a, b: [32 * 32]i16
		mc_chroma_i16(
			a[:],
			cw,
			enc.refs[0][ref_idx[0]].u,
			x,
			y,
			cw,
			ch,
			mvc[0][0],
			mvc[0][1],
			fw,
			fh,
			enc.bit_depth,
		)
		mc_chroma_i16(
			b[:],
			cw,
			enc.refs[1][ref_idx[1]].u,
			x,
			y,
			cw,
			ch,
			mvc[1][0],
			mvc[1][1],
			fw,
			fh,
			enc.bit_depth,
		)
		pred_bi_w(
			u,
			dst_stride,
			a[:],
			b[:],
			cw,
			cw,
			ch,
			wp_chroma(enc, 0, int(ref_idx[0]), 0),
			wp_chroma(enc, 1, int(ref_idx[1]), 0),
		)

		mc_chroma_i16(
			a[:],
			cw,
			enc.refs[0][ref_idx[0]].v,
			x,
			y,
			cw,
			ch,
			mvc[0][0],
			mvc[0][1],
			fw,
			fh,
			enc.bit_depth,
		)
		mc_chroma_i16(
			b[:],
			cw,
			enc.refs[1][ref_idx[1]].v,
			x,
			y,
			cw,
			ch,
			mvc[1][0],
			mvc[1][1],
			fw,
			fh,
			enc.bit_depth,
		)
		pred_bi_w(
			v,
			dst_stride,
			a[:],
			b[:],
			cw,
			cw,
			ch,
			wp_chroma(enc, 0, int(ref_idx[0]), 1),
			wp_chroma(enc, 1, int(ref_idx[1]), 1),
		)
		return
	}

	l := pred[0] ? 0 : 1
	t: [32 * 32]i16
	mc_chroma_i16(
		t[:],
		cw,
		enc.refs[l][ref_idx[l]].u,
		x,
		y,
		cw,
		ch,
		mvc[l][0],
		mvc[l][1],
		fw,
		fh,
		enc.bit_depth,
	)
	pred_uni_w(u, dst_stride, t[:], cw, cw, ch, wp_chroma(enc, l, int(ref_idx[l]), 0))
	mc_chroma_i16(
		t[:],
		cw,
		enc.refs[l][ref_idx[l]].v,
		x,
		y,
		cw,
		ch,
		mvc[l][0],
		mvc[l][1],
		fw,
		fh,
		enc.bit_depth,
	)
	pred_uni_w(v, dst_stride, t[:], cw, cw, ch, wp_chroma(enc, l, int(ref_idx[l]), 1))
}

// part_predict_pu_p writes one PU of a P slice into the CU's planes.
part_predict_pu_p :: proc(enc: ^Encoder, pux, puy, w, h: int, mv: [2]i16, ref: int, p: Cu_Pred) {
	sw, sh := chroma_sub(enc.config.chroma_format)
	yoff := (puy - p.cu_y) * p.y_stride + (pux - p.cu_x)
	part_mc_luma_p(enc, pux, puy, w, h, mv, ref, p.y[yoff:], p.y_stride)

	if !has_chroma(enc) do return
	coff := (puy - p.cu_y) / sh * p.c_stride + (pux - p.cu_x) / sw
	part_mc_chroma_p(enc, pux, puy, w, h, mv, ref, 0, enc.refs[0][ref].u, p.u[coff:], p.c_stride)
	part_mc_chroma_p(enc, pux, puy, w, h, mv, ref, 1, enc.refs[0][ref].v, p.v[coff:], p.c_stride)
}

// part_predict_pu_b writes one PU of a B slice into the CU's planes.
part_predict_pu_b :: proc(
	enc: ^Encoder,
	pux, puy, w, h: int,
	pred: [2]bool,
	mv: [2][2]i16,
	ref_idx: [2]i8,
	p: Cu_Pred,
) {
	sw, sh := chroma_sub(enc.config.chroma_format)
	yoff := (puy - p.cu_y) * p.y_stride + (pux - p.cu_x)
	part_mc_luma_b(enc, pux, puy, w, h, pred, mv, ref_idx, p.y[yoff:], p.y_stride)

	if !has_chroma(enc) do return
	coff := (puy - p.cu_y) / sh * p.c_stride + (pux - p.cu_x) / sw
	part_mc_chroma_b(enc, pux, puy, w, h, pred, mv, ref_idx, p.u[coff:], p.v[coff:], p.c_stride)
}

// part_predict_cu materialises the predictions of every PU of the plan stored
// in the grid.
part_predict_cu :: proc(enc: ^Encoder, x, y, size: int, part: Part_Mode, p: Cu_Pred) {
	q := size / 4
	for i in 0 ..< PART_COUNT[int(part)] {
		s := PART_SHAPE[int(part)][i]
		pux, puy := x + s[0] * q, y + s[1] * q
		puw, puh := s[2] * q, s[3] * q
		pu := cu_at(enc.cu, pux, puy)
		if enc.slice_type == .B {
			part_predict_pu_b(enc, pux, puy, puw, puh, pu.pred, pu.mv, pu.ref_idx, p)
		} else {
			part_predict_pu_p(enc, pux, puy, puw, puh, pu.mv[0], int(pu.ref_idx[0]), p)
		}
	}
}

// ---------------------------------------------------------------------------
// Fast per-PU prediction scores for candidate selection.
// ---------------------------------------------------------------------------

@(private)
part_pu_sse_p :: proc(enc: ^Encoder, pux, puy, w, h: int, mv: [2]i16, ref: int) -> u64 {
	tmp: [32 * 32]Sample = ---
	part_mc_luma_p(enc, pux, puy, w, h, mv, ref, tmp[:], w)
	src := enc.source.y
	return ssd_u16(src.data[src.offset + puy * src.stride + pux:], src.stride, tmp[:], w, w, h)
}

@(private)
part_pu_sse_b :: proc(
	enc: ^Encoder,
	pux, puy, w, h: int,
	pred: [2]bool,
	mv: [2][2]i16,
	ref_idx: [2]i8,
) -> u64 {
	tmp: [32 * 32]Sample = ---
	part_mc_luma_b(enc, pux, puy, w, h, pred, mv, ref_idx, tmp[:], w)
	src := enc.source.y
	return ssd_u16(src.data[src.offset + puy * src.stride + pux:], src.stride, tmp[:], w, w, h)
}

// part_rank_sad_* score a merge candidate without interpolation for the
// ranking pass only: the partition order is all this decides.
@(private)
part_rank_sad_b :: #force_inline proc(
	enc: ^Encoder,
	pux, puy, w, h: int,
	pred: [2]bool,
	mv: [2][2]i16,
	ref_idx: [2]i8,
) -> u64 {
	if pred[0] && pred[1] {
		// Bi candidates are ranked by their luma reference alone; only the
		// order of the partition modes depends on this score.
	}
	l := pred[0] ? 0 : 1
	mx := int(i32(mv[l][0]) >> 2)
	my := int(i32(mv[l][1]) >> 2)
	return u64(sad_int_luma(enc, &enc.refs[l][ref_idx[l]], pux, puy, w, h, mx, my))
}

@(private)
pu_info :: #force_inline proc(
	enc: ^Encoder,
	depth: u8,
	part: Part_Mode,
	pred: [2]bool,
	mv: [2][2]i16,
	ref_idx: [2]i8,
	merge: bool,
	merge_idx: u8,
	idc: u8,
	mvp_flag: [2]u8,
	mv_cand: u8,
) -> Cu_Info {
	return Cu_Info {
		type = .Inter,
		depth = depth,
		part = part,
		pred = pred,
		mv = mv,
		ref_idx = ref_idx,
		merge = merge,
		merge_idx = merge_idx,
		idc = idc,
		mvp_flag = mvp_flag,
		mv_cand = mv_cand,
		qp = enc.qp,
	}
}

// ---------------------------------------------------------------------------
// Plan building. Merge candidates are always derived in PU order with the
// earlier PUs already in the grid, because that is the state the decoder sees.
// ---------------------------------------------------------------------------

// part_plan_merge_p builds the all-merge plan of a P slice and returns the
// summed luma prediction cost, used to rank the partition modes.
part_plan_merge_p :: proc(enc: ^Encoder, x, y, size: int, part: Part_Mode, depth: u8) -> u64 {
	q := size / 4
	sse_sum: u64
	for i in 0 ..< PART_COUNT[int(part)] {
		s := PART_SHAPE[int(part)][i]
		pux, puy := x + s[0] * q, y + s[1] * q
		puw, puh := s[2] * q, s[3] * q

		ctx := pu_context(x, y, size, part, q, i)
		list: [8]Mv_Info
		n := merge_candidates_pu(enc, pux, puy, puw, puh, i, part, ctx, &list, false)
		best_k := 0
		best_sse := max(u64)
		for k in 0 ..< n {
			dup := false
			for j in 0 ..< k {
				if same_motion_enc(&list[j], &list[k]) {
					dup = true
					break
				}
			}
			if dup do continue
			v := part_pu_sse_p(enc, pux, puy, puw, puh, list[k].mv[0], int(list[k].ref_idx[0]))
			if v < best_sse {
				best_sse = v
				best_k = k
			}
		}
		sse_sum += best_sse
		sel := list[best_k]
		fill_pu_info(
			enc,
			pux,
			puy,
			puw,
			puh,
			pu_info(enc, depth, part, sel.pred, sel.mv, sel.ref_idx, true, u8(best_k), 0, {}, 0),
		)
	}
	return sse_sum
}

// part_plan_merge_b is the B-slice all-merge plan for ranking.
part_plan_merge_b :: proc(enc: ^Encoder, x, y, size: int, part: Part_Mode, depth: u8) -> u64 {
	q := size / 4
	sse_sum: u64
	for i in 0 ..< PART_COUNT[int(part)] {
		s := PART_SHAPE[int(part)][i]
		pux, puy := x + s[0] * q, y + s[1] * q
		puw, puh := s[2] * q, s[3] * q

		c := pu_context(x, y, size, part, q, i)
		list: [8]Mv_Info
		n := merge_candidates_pu(enc, pux, puy, puw, puh, i, part, c, &list, true)
		best_k := 0
		best_sad := max(u64)
		for k in 0 ..< n {
			dup := false
			for j in 0 ..< k {
				if same_motion_enc(&list[j], &list[k]) {
					dup = true
					break
				}
			}
			if dup do continue
			v := merge_candidate_drop_l1(list[k], puw, puh)
			s := part_rank_sad_b(enc, pux, puy, puw, puh, v.pred, v.mv, v.ref_idx)
			if s < best_sad {
				best_sad = s
				best_k = k
			}
		}
		sel := merge_candidate_drop_l1(list[best_k], puw, puh)
		sse_sum += best_sad
		fill_pu_info(
			enc,
			pux,
			puy,
			puw,
			puh,
			pu_info(enc, depth, part, sel.pred, sel.mv, sel.ref_idx, true, u8(best_k), 0, {}, 0),
		)
	}
	return sse_sum
}

// part_plan_mixed_p chooses, per PU, the better of the best merge candidate
// and an AMVP vector found by the motion search. Returns true when every PU
// ended up merging, which is when the no-residual form is also evaluated.
part_plan_mixed_p :: proc(enc: ^Encoder, x, y, size: int, part: Part_Mode, depth: u8) -> bool {
	q := size / 4
	all_merge := true
	for i in 0 ..< PART_COUNT[int(part)] {
		s := PART_SHAPE[int(part)][i]
		pux, puy := x + s[0] * q, y + s[1] * q
		puw, puh := s[2] * q, s[3] * q

		ctx := pu_context(x, y, size, part, q, i)
		list: [8]Mv_Info
		n := merge_candidates_pu(enc, pux, puy, puw, puh, i, part, ctx, &list, false)
		best_k := 0
		best_sse := max(u64)
		for k in 0 ..< n {
			dup := false
			for j in 0 ..< k {
				if same_motion_enc(&list[j], &list[k]) {
					dup = true
					break
				}
			}
			if dup do continue
			v := part_pu_sse_p(enc, pux, puy, puw, puh, list[k].mv[0], int(list[k].ref_idx[0]))
			if v < best_sse {
				best_sse = v
				best_k = k
			}
		}

		// A merged prediction this accurate is cheaper to keep than to beat
		// with a signalled MVD, the same trade the 2Nx2N path makes before its
		// motion search.
		use_amvp := false
		if best_sse > part_search_limit(enc, puw, puh) {
			cands, avail := amvp_candidates_b(
				enc,
				pux,
				puy,
				puw,
				puh,
				0,
				ctx,
				enc.ref_poc[0][0],
				enc.cur_poc,
			)
			c := amvp_build_list(enc, pux, puy, puw, puh, 0, enc.ref_poc[0][0], cands, avail)
			mv, _ := motion_estimate(
				enc,
				&enc.refs[0][0],
				pux,
				puy,
				puw,
				puh,
				c[0][0],
				c[0][1],
				wp_luma(enc, 0, 0),
			)
			sse_a := part_pu_sse_p(enc, pux, puy, puw, puh, mv, 0)
			if f64(sse_a) + enc.lambda * PART_AMVP_BIAS_BITS < f64(best_sse) {
				idx := pick_mvp(c, mv)
				fill_pu_info(
					enc,
					pux,
					puy,
					puw,
					puh,
					pu_info(
						enc,
						depth,
						part,
						{true, false},
						{mv, {}},
						{0, -1},
						false,
						0,
						0,
						{},
						u8(idx),
					),
				)
				all_merge = false
				use_amvp = true
			}
		}
		if !use_amvp {
			sel := list[best_k]
			fill_pu_info(
				enc,
				pux,
				puy,
				puw,
				puh,
				pu_info(
					enc,
					depth,
					part,
					sel.pred,
					sel.mv,
					sel.ref_idx,
					true,
					u8(best_k),
					0,
					{},
					0,
				),
			)
		}
	}
	return all_merge
}

// part_plan_mixed_b is the B-slice counterpart: per PU it compares the best
// merge candidate against uni-L0, uni-L1 and bi AMVP.
part_plan_mixed_b :: proc(enc: ^Encoder, x, y, size: int, part: Part_Mode, depth: u8) -> bool {
	q := size / 4
	all_merge := true
	for i in 0 ..< PART_COUNT[int(part)] {
		s := PART_SHAPE[int(part)][i]
		pux, puy := x + s[0] * q, y + s[1] * q
		puw, puh := s[2] * q, s[3] * q

		ctx := pu_context(x, y, size, part, q, i)
		list: [8]Mv_Info
		n := merge_candidates_pu(enc, pux, puy, puw, puh, i, part, ctx, &list, true)
		best_k := 0
		best_sad := max(u64)
		for k in 0 ..< n {
			dup := false
			for j in 0 ..< k {
				if same_motion_enc(&list[j], &list[k]) {
					dup = true
					break
				}
			}
			if dup do continue
			v := merge_candidate_drop_l1(list[k], puw, puh)
			s := part_rank_sad_b(enc, pux, puy, puw, puh, v.pred, v.mv, v.ref_idx)
			if s < best_sad {
				best_sad = s
				best_k = k
			}
		}
		sel0 := merge_candidate_drop_l1(list[best_k], puw, puh)
		best_sse := part_pu_sse_b(enc, pux, puy, puw, puh, sel0.pred, sel0.mv, sel0.ref_idx)

		// The same merge-first trade as the P path: an accurate merged
		// prediction does not pay for two motion searches.
		if best_sse <= part_search_limit(enc, puw, puh) {
			sel := merge_candidate_drop_l1(list[best_k], puw, puh)
			fill_pu_info(
				enc,
				pux,
				puy,
				puw,
				puh,
				pu_info(
					enc,
					depth,
					part,
					sel.pred,
					sel.mv,
					sel.ref_idx,
					true,
					u8(best_k),
					0,
					{},
					0,
				),
			)
			continue
		}

		// AMVP motion search per list, then the uni and bi options.
		r0, r1 := enc.search_ref[0], enc.search_ref[1]
		cands0, avail0 := amvp_candidates_b(
			enc,
			pux,
			puy,
			puw,
			puh,
			0,
			ctx,
			enc.ref_poc[0][r0],
			enc.cur_poc,
		)
		cands1, avail1 := amvp_candidates_b(
			enc,
			pux,
			puy,
			puw,
			puh,
			1,
			ctx,
			enc.ref_poc[1][r1],
			enc.cur_poc,
		)
		c0 := amvp_build_list(enc, pux, puy, puw, puh, 0, enc.ref_poc[0][r0], cands0, avail0)
		c1 := amvp_build_list(enc, pux, puy, puw, puh, 1, enc.ref_poc[1][r1], cands1, avail1)
		mv0, _ := motion_estimate(
			enc,
			&enc.refs[0][r0],
			pux,
			puy,
			puw,
			puh,
			c0[0][0],
			c0[0][1],
			wp_luma(enc, 0, r0),
		)
		mv1, _ := motion_estimate(
			enc,
			&enc.refs[1][r1],
			pux,
			puy,
			puw,
			puh,
			c1[0][0],
			c1[0][1],
			wp_luma(enc, 1, r1),
		)

		sse0 := part_pu_sse_b(enc, pux, puy, puw, puh, {true, false}, {mv0, {}}, {i8(r0), -1})
		sse1 := part_pu_sse_b(enc, pux, puy, puw, puh, {false, true}, {{}, mv1}, {-1, i8(r1)})
		sse_bi := max(u64)
		if puw + puh != 12 {
			sse_bi = part_pu_sse_b(
				enc,
				pux,
				puy,
				puw,
				puh,
				{true, true},
				{mv0, mv1},
				{i8(r0), i8(r1)},
			)
		}

		bias := enc.lambda * PART_AMVP_BIAS_BITS
		choice := 0
		best_score := f64(best_sse)
		if f64(sse0) + bias < best_score {
			best_score = f64(sse0) + bias
			choice = 1
		}
		if f64(sse1) + bias < best_score {
			best_score = f64(sse1) + bias
			choice = 2
		}
		if sse_bi != max(u64) && f64(sse_bi) + bias < best_score {
			choice = 3
		}

		switch choice {
		case 1:
			fill_pu_info(
				enc,
				pux,
				puy,
				puw,
				puh,
				pu_info(
					enc,
					depth,
					part,
					{true, false},
					{mv0, {}},
					{i8(r0), -1},
					false,
					0,
					PRED_L0,
					{u8(pick_mvp(c0, mv0)), 0},
					0,
				),
			)
			all_merge = false
		case 2:
			fill_pu_info(
				enc,
				pux,
				puy,
				puw,
				puh,
				pu_info(
					enc,
					depth,
					part,
					{false, true},
					{{}, mv1},
					{-1, i8(r1)},
					false,
					0,
					PRED_L1,
					{0, u8(pick_mvp(c1, mv1))},
					0,
				),
			)
			all_merge = false
		case 3:
			flags: [2]u8
			flags[0] = u8(pick_mvp(c0, mv0))
			flags[1] = u8(pick_mvp(c1, mv1))
			fill_pu_info(
				enc,
				pux,
				puy,
				puw,
				puh,
				pu_info(
					enc,
					depth,
					part,
					{true, true},
					{mv0, mv1},
					{i8(r0), i8(r1)},
					false,
					0,
					PRED_BI,
					flags,
					0,
				),
			)
			all_merge = false
		case:
			sel := merge_candidate_drop_l1(list[best_k], puw, puh)
			fill_pu_info(
				enc,
				pux,
				puy,
				puw,
				puh,
				pu_info(
					enc,
					depth,
					part,
					sel.pred,
					sel.mv,
					sel.ref_idx,
					true,
					u8(best_k),
					0,
					{},
					0,
				),
			)
		}
	}
	return all_merge
}

// ---------------------------------------------------------------------------
// RD search
// ---------------------------------------------------------------------------

// part_consider_p evaluates one partition mode end to end: the mixed plan
// with a coded residual, plus the all-merge zero-residual form when every PU
// merges.
@(private)
part_consider_p :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	part: Part_Mode,
	trial: ^Cabac,
	base: int,
	pre: Trial_State,
	best: ^Maybe(^Inter_Best),
	best_store: ^Inter_Best,
) {
	size := CTU_WIDTH >> depth
	restore_trial(enc, pre)
	all_merge := part_plan_mixed_p(enc, x, y, size, part, depth)
	set_part_skip(enc, x, y, size, false)
	sse := write_inter_part(RQT, enc, x, y, depth, trial, true, false)
	inter_consider(
		RQT,
		best,
		best_store,
		enc,
		x,
		y,
		size,
		f64(sse) + enc.lambda * f64(bits_since(enc, base)),
	)
	if !all_merge do return

	restore_trial(enc, pre)
	set_part_skip(enc, x, y, size, true)
	sse_nr := write_inter_part(RQT, enc, x, y, depth, trial, true, true)
	inter_consider(
		RQT,
		best,
		best_store,
		enc,
		x,
		y,
		size,
		f64(sse_nr) + enc.lambda * f64(bits_since(enc, base)),
	)
}

@(private)
part_consider_b :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	part: Part_Mode,
	trial: ^Cabac,
	base: int,
	pre: Trial_State,
	best: ^Maybe(^Inter_Best),
	best_store: ^Inter_Best,
) {
	size := CTU_WIDTH >> depth
	restore_trial(enc, pre)
	all_merge := part_plan_mixed_b(enc, x, y, size, part, depth)
	set_part_skip(enc, x, y, size, false)
	sse := write_inter_part_b(RQT, enc, x, y, depth, trial, true, false)
	inter_consider(
		RQT,
		best,
		best_store,
		enc,
		x,
		y,
		size,
		f64(sse) + enc.lambda * f64(bits_since(enc, base)),
	)
	if !all_merge do return

	restore_trial(enc, pre)
	set_part_skip(enc, x, y, size, true)
	sse_nr := write_inter_part_b(RQT, enc, x, y, depth, trial, true, true)
	inter_consider(
		RQT,
		best,
		best_store,
		enc,
		x,
		y,
		size,
		f64(sse_nr) + enc.lambda * f64(bits_since(enc, base)),
	)
}

@(private)
partition_rank :: proc(
	enc: ^Encoder,
	x, y, size: int,
	part: Part_Mode,
	depth: u8,
	bi: bool,
) -> u64 {
	if bi do return part_plan_merge_b(enc, x, y, size, part, depth)
	return part_plan_merge_p(enc, x, y, size, part, depth)
}

// consider_parts ranks the available partition modes by their all-merge
// prediction cost and runs the full RD evaluation on the best few.
consider_parts :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	trial: ^Cabac,
	base: int,
	pre: Trial_State,
	best: ^Maybe(^Inter_Best),
	best_store: ^Inter_Best,
	bi: bool,
) {
	size := CTU_WIDTH >> depth
	parts: [8]Part_Mode
	rank: [8]u64
	n := 0

	for p in ([7]Part_Mode{.P_2NxN, .P_Nx2N, .P_NxN, .P_2NxnU, .P_2NxnD, .P_nLx2N, .P_nRx2N}) {
		if !part_available(p, size) do continue
		restore_trial(enc, pre)
		rank[n] = partition_rank(enc, x, y, size, p, depth, bi)
		parts[n] = p
		n += 1
	}

	for _ in 0 ..< min(n, PART_TRY) {
		k := 0
		for i in 1 ..< n do if rank[i] < rank[k] do k = i
		if rank[k] == max(u64) do break
		part := parts[k]
		rank[k] = max(u64)
		if bi {
			part_consider_b(RQT, enc, x, y, depth, part, trial, base, pre, best, best_store)
		} else {
			part_consider_p(RQT, enc, x, y, depth, part, trial, base, pre, best, best_store)
		}
	}
}

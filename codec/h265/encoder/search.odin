package h265_encoder

import common "../../common"

// ---------------------------------------------------------------------------
// Coding structure search and bitstream pass. Each node evaluates an intra
// leaf, an inter leaf (P/B slices) and a split candidate. Rejected
// candidates roll back the reconstruction, coder state and CU records.
// ---------------------------------------------------------------------------

MAX_NODE_CELLS :: 16 * 16

Trial_State :: struct {
	cabac:  Cabac,
	writer: common.Bit_Writer,
	len:    int,
}

save_trial :: proc(enc: ^Encoder) -> Trial_State {
	return {cabac = enc.trial_cabac, writer = enc.trial_writer, len = len(enc.trial_buf)}
}

restore_trial :: proc(enc: ^Encoder, s: Trial_State) {
	enc.trial_cabac = s.cabac
	// The PCM candidate writes raw bits through the trial bit writer, whose
	// pending part-byte state the arithmetic coder does not carry.
	enc.trial_writer = s.writer
	resize(&enc.trial_buf, s.len)
}

Node_State :: struct {
	trial: Trial_State,
	rec:   Region,
	cells: [MAX_NODE_CELLS]Cu_Info,
}

@(private)
cell_span :: #force_inline proc(size: int) -> int {
	return size >> 2
}

// The inter transform tree records each leaf's size (log2) in Cu_Info.tr_depth,
// so the CU grid's existing save/restore rolls it back with the rest of the CU
// state and the non-RQT path carries no extra grid.

// save_node_size fills `state` in place; only the first span x span cells are
// written, so the caller must declare the store `= ---` to avoid zeroing the
// whole 12 KiB struct.
save_node_size :: proc(enc: ^Encoder, x, y, size: int, state: ^Node_State) {
	state.trial = save_trial(enc)
	save_region(&enc.rec, x, y, size, &state.rec, enc.config.chroma_format)
	span := cell_span(size)
	for cy in 0 ..< span {
		for cx in 0 ..< span {
			state.cells[cy * span + cx] = cu_at(enc.cu, x + cx * 4, y + cy * 4)^
		}
	}
}

restore_node_size :: proc(enc: ^Encoder, x, y, size: int, state: ^Node_State) {
	restore_trial(enc, state.trial)
	restore_region(&enc.rec, x, y, size, &state.rec, enc.config.chroma_format)
	span := cell_span(size)
	for cy in 0 ..< span {
		for cx in 0 ..< span {
			cu_at(enc.cu, x + cx * 4, y + cy * 4)^ = state.cells[cy * span + cx]
		}
	}
}

save_node :: proc(enc: ^Encoder, x, y: int, depth: u8, state: ^Node_State) {
	save_node_size(enc, x, y, CTU_WIDTH >> depth, state)
}

restore_node :: proc(enc: ^Encoder, x, y: int, depth: u8, state: ^Node_State) {
	restore_node_size(enc, x, y, CTU_WIDTH >> depth, state)
}

child_inside :: #force_inline proc(enc: ^Encoder, cx, cy: int) -> bool {
	return cx < enc.coded_width && cy < enc.coded_height
}

bits_since :: #force_inline proc(enc: ^Encoder, base: int) -> int {
	return common.bits_written(enc.trial_cabac.stream) - base
}

// Intra leaf candidate: choose a mode, encode and reconstruct.
eval_intra_leaf :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	trial: ^Cabac,
	bound: f64,
) -> f64 {
	size := CTU_WIDTH >> depth
	base := common.bits_written(trial.stream)
	inputs: Intra_Search_Inputs = ---
	m := choose_intra_mode(enc, x, y, size, &inputs)
	// Every intra leaf spends at least this many bits of mode syntax on top of
	// its prediction, so one whose best prediction is already far more
	// expensive than the committed candidate is not worth a residual RDO.
	if m.sse != 0 && enc.config.forced_mode < 0 {
		if f64(m.sse) + enc.lambda * INTRA_MIN_BITS >= bound do return max(f64)
	}
	info := Cu_Info {
		type        = .Intra,
		depth       = depth,
		part        = .P_2Nx2N,
		mode        = m.mode,
		chroma_mode = m.mode,
		qp          = enc.qp,
	}
	fill_cu_info(enc, x, y, size, info)
	sse := write_leaf(RQT, enc, x, y, depth, trial, true, &inputs.refs)
	return f64(sse) + enc.lambda * f64(common.bits_written(trial.stream) - base)
}

// Raw PCM sample bits in the signalled chroma layout.
pcm_raw_bits :: #force_inline proc(size, bit_depth: int, layout: Chroma_Layout) -> int {
	sw, sh := chroma_sub(layout)
	chroma := layout == .Monochrome ? 0 : 2 * (size / sw) * (size / sh)
	return (size * size + chroma) * bit_depth
}

// PCM leaf candidate: raw samples instead of prediction and residual. The
// reconstruction is an exact copy of the source, so the distortion is zero and
// the RD cost is the raw bit count alone.
eval_intra_pcm :: proc($RQT: bool, enc: ^Encoder, x, y: int, depth: u8, trial: ^Cabac) -> f64 {
	size := CTU_WIDTH >> depth
	base := common.bits_written(trial.stream)
	info := Cu_Info {
		type  = .Intra,
		depth = depth,
		part  = .P_2Nx2N,
		mode  = 1, // INTRA_DC, the decoder's PCM mode
		pcm   = true,
		qp    = enc.qp,
	}
	fill_cu_info(enc, x, y, size, info)
	write_leaf(RQT, enc, x, y, depth, trial, true)
	return enc.lambda * f64(common.bits_written(trial.stream) - base)
}

// Result of an inter leaf evaluation. `early_skip` is set when the best
// skip/merge candidate is good enough that a residual, intra or split
// candidate cannot plausibly beat it; decide_cu then stops the node.
Inter_Leaf_Result :: struct {
	cost:       f64,
	early_skip: bool,
}

// Minimum bit overhead of an intra leaf over signalling nothing: part mode,
// intra mode, chroma mode and the coded-block flags.
INTRA_MIN_BITS :: 4

// Minimum bit overhead of an AMVP leaf over a skip: part mode, merge flag,
// MVD, mvp flag and at least one coded coefficient.
AMVP_MIN_BITS :: 16

// A skip prediction this accurate is committed without running the AMVP
// motion search, the residual RDO paths, intra or split. The bound is
// per-pixel because the distortion and the bits a residual would spend both
// scale with the block area, and it scales with lambda because at low QP a
// residual buys back more distortion for the same rate.
SKIP_EARLY_LAMBDA_SCALE :: 0.25

// Above roughly QP 34 the lambda-scaled bound would commit almost every
// block to skip, which loses more quality than the saved rate is worth at
// those bitrates.
SKIP_EARLY_SSE_CAP :: 24

@(private)
skip_early_limit :: #force_inline proc(enc: ^Encoder, size: int) -> u64 {
	per_pixel := u64(enc.lambda * SKIP_EARLY_LAMBDA_SCALE + 0.5)
	if per_pixel == 0 do per_pixel = 1
	cap := u64(f64(SKIP_EARLY_SSE_CAP) * enc.dist_scale)
	if per_pixel > cap do per_pixel = cap
	return u64(size * size) * per_pixel
}

// One reference's AMVP motion search result, ranked by prediction SSE for the
// residual RDO of a multi-reference P leaf.
@(private)
Ref_Cand :: struct {
	ref:   int,
	mv:    [2]i16,
	cands: [2][2]i16,
	sse:   u64,
}

// Best scored inter candidate, kept with the reconstruction it produced so
// the search can roll back to it after trying the remaining candidates.
// `info`/`cbf` restore a whole uniform CU; the per-cell grid is only written
// by the transform tree and only copied when RQT is on.
Inter_Best :: struct {
	cost:  f64,
	info:  Cu_Info,
	cbf:   [3]bool,
	rec:   Region,
	cells: [MAX_NODE_CELLS]Cu_Info,
}

// Save the 4x4 Cu_Info grid of a region. The transform tree writes per-cell
// edges and leaf sizes, so they cannot be rebuilt from one Cu_Info.
@(private)
save_cells :: proc(enc: ^Encoder, x, y, size: int, cells: ^[MAX_NODE_CELLS]Cu_Info) {
	span := cell_span(size)
	for cy in 0 ..< span {
		for cx in 0 ..< span {
			cells[cy * span + cx] = cu_at(enc.cu, x + cx * 4, y + cy * 4)^
		}
	}
}

@(private)
restore_cells :: proc(enc: ^Encoder, x, y, size: int, cells: ^[MAX_NODE_CELLS]Cu_Info) {
	span := cell_span(size)
	for cy in 0 ..< span {
		for cx in 0 ..< span {
			cu_at(enc.cu, x + cx * 4, y + cy * 4)^ = cells[cy * span + cx]
		}
	}
}

// inter_consider keeps the new best in the caller-provided `store`; `best`
// holds only a pointer so the per-cell grids are never copied. `RQT` is a
// compile-time flag: with it off the non-RQT path carries no extra state.
@(private)
inter_consider :: proc(
	$RQT: bool,
	best: ^Maybe(^Inter_Best),
	store: ^Inter_Best,
	enc: ^Encoder,
	x, y, size: int,
	cost: f64,
) {
	if b, ok := best.?; ok && cost >= b.cost do return
	cu := cu_at(enc.cu, x, y)
	store.cost = cost
	store.info = cu^
	store.cbf = {cu.cbf_y, cu.cbf_u, cu.cbf_v}
	save_region(&enc.rec, x, y, size, &store.rec, enc.config.chroma_format)
	when RQT {
		save_cells(enc, x, y, size, &store.cells)
	} else {
		// A partitioned CU's per-PU motion and edge records cannot be rebuilt
		// from one Cu_Info, so the whole cell grid is carried.
		if enc.config.amp do save_cells(enc, x, y, size, &store.cells)
	}
	best^ = store
}

// restore_inter_best rolls back to the state of a winning inter candidate.
@(private)
restore_inter_best :: #force_inline proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y, size: int,
	b: ^Inter_Best,
) {
	restore_region(&enc.rec, x, y, size, &b.rec, enc.config.chroma_format)
	when RQT {
		restore_cells(enc, x, y, size, &b.cells)
	} else {
		if enc.config.amp {
			restore_cells(enc, x, y, size, &b.cells)
		} else {
			// The uniform restore rebuilds the CU from one record, so the
			// origin cell's transform edge marks must not be replicated; the
			// CU boundary is re-marked for the deblocking grid.
			info := b.info
			info.tu_v = false
			info.tu_h = false
			fill_cu_info(enc, x, y, size, info)
			set_cbf_flags(enc, x, y, size, b.cbf[0], b.cbf[1], b.cbf[2])
			if enc.config.intra_rqt do mark_tu_enc(enc, x, y, size)
		}
	}
}

// Inter leaf candidate: the merge and skip forms are evaluated first because
// they need only motion compensation; a good enough skip commits the CU before
// the AMVP motion search and the residual RDO paths run. Otherwise the best of
// {AMVP, merge, skip} by RD cost wins.
eval_inter_leaf :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	trial: ^Cabac,
) -> Inter_Leaf_Result {
	if enc.slice_type == .B do return eval_inter_leaf_b(RQT, enc, x, y, depth, trial)

	size := CTU_WIDTH >> depth
	base := common.bits_written(trial.stream)
	c := Pu_Context {
		cu_x    = x,
		cu_y    = y,
		cu_size = size,
		pu_w    = size,
		pu_h    = size,
	}

	merge_mv: [8]Mv_Info
	n_merge := merge_candidates_p(enc, x, y, size, c, &merge_mv)

	pre := save_trial(enc)
	best_store: Inter_Best = ---
	best: Maybe(^Inter_Best)

	// Deduplicate the merge list on reference and vector: the zero-motion fill
	// repeats a vector and a spatial candidate may already be zero. The first
	// index for a candidate is always the cheapest to signal, so only it is
	// evaluated.
	uniq_mv: [8]Mv_Info
	uniq_idx: [8]u8
	n_uniq := 0
	for i in 0 ..< n_merge {
		dup := false
		for k in 0 ..< n_uniq {
			if same_motion_enc(&merge_mv[i], &uniq_mv[k]) {
				dup = true
				break
			}
		}
		if !dup {
			uniq_mv[n_uniq] = merge_mv[i]
			uniq_idx[n_uniq] = u8(i)
			n_uniq += 1
		}
	}

	// Skip: merge vector with no residual signalled. This only needs motion
	// compensation, so it is cheap and also identifies the best predictor for
	// the merge-with-residual candidate below.
	best_merge_sse := max(u64)
	best_merge_k: Maybe(int)
	for k in 0 ..< n_uniq {
		restore_trial(enc, pre)
		fill_cu_info(
			enc,
			x,
			y,
			size,
			Cu_Info {
				type = .Inter,
				depth = depth,
				part = .P_2Nx2N,
				pred = uniq_mv[k].pred,
				mv = uniq_mv[k].mv,
				ref_idx = uniq_mv[k].ref_idx,
				merge = true,
				merge_idx = uniq_idx[k],
				skipped = true,
				qp = enc.qp,
			},
		)
		sse := write_leaf(RQT, enc, x, y, depth, trial, true)
		inter_consider(
			RQT,
			&best,
			&best_store,
			enc,
			x,
			y,
			size,
			f64(sse) + enc.lambda * f64(bits_since(enc, base)),
		)
		if sse < best_merge_sse {
			best_merge_sse = sse
			best_merge_k = k
		}
	}

	if best_merge_sse <= skip_early_limit(enc, size) {
		restore_trial(enc, pre)
		if b, ok := best.?; ok {
			restore_inter_best(RQT, enc, x, y, size, b)
			return {cost = b.cost, early_skip = true}
		}
	}

	// AMVP: one motion search per active reference. The two references with
	// the cheapest predictions get the residual RDO, because prediction SAD is
	// not a reliable reference choice on its own: a distant reference can win
	// the SAD and still cost more residual than the one behind it.
	top := [2]Ref_Cand{{sse = max(u64)}, {sse = max(u64)}}
	for r in 0 ..< enc.refs_active[0] {
		cands_r, avail_r := amvp_candidates_b(
			enc,
			x,
			y,
			size,
			size,
			0,
			c,
			enc.ref_poc[0][r],
			enc.cur_poc,
		)
		c_r := amvp_build_list(enc, x, y, size, size, 0, enc.ref_poc[0][r], cands_r, avail_r)
		mv_r, _ := motion_estimate(
			enc,
			&enc.refs[0][r],
			x,
			y,
			size,
			size,
			c_r[0][0],
			c_r[0][1],
			wp_luma(enc, 0, r),
		)
		sse_r := mc_luma_sse(
			enc,
			&enc.refs[0][r],
			x,
			y,
			size,
			size,
			mv_r[0],
			mv_r[1],
			wp_luma(enc, 0, r),
		)
		v := Ref_Cand {
			ref   = r,
			mv    = mv_r,
			cands = c_r,
			sse   = sse_r,
		}
		if v.sse < top[0].sse {
			top[1] = top[0]
			top[0] = v
		} else if v.sse < top[1].sse {
			top[1] = v
		}
	}
	n_try := 1
	if enc.refs_active[0] > 1 && top[1].sse < max(u64) do n_try = 2
	for t in 0 ..< n_try {
		s := top[t]
		amvp_run := true
		if b, ok := best.?; ok {
			// The coded residual can only lower the prediction SSE, but the
			// residual syntax itself has a rate floor; a prediction that is
			// far above the committed cost cannot buy that back.
			if f64(s.sse) + enc.lambda * AMVP_MIN_BITS >= b.cost do amvp_run = false
		}
		if !amvp_run do continue

		idx := pick_mvp(s.cands, s.mv)
		restore_trial(enc, pre)
		fill_cu_info(
			enc,
			x,
			y,
			size,
			Cu_Info {
				type = .Inter,
				depth = depth,
				part = .P_2Nx2N,
				pred = {true, false},
				mv = {s.mv, {}},
				ref_idx = {i8(s.ref), -1},
				mv_cand = u8(idx),
				qp = enc.qp,
			},
		)
		sse := write_leaf(RQT, enc, x, y, depth, trial, true)
		inter_consider(
			RQT,
			&best,
			&best_store,
			enc,
			x,
			y,
			size,
			f64(sse) + enc.lambda * f64(bits_since(enc, base)),
		)
	}

	// Merge with residual, for the best-predicting candidate only.
	// rqt_root_cbf is inferred to one, so an all-zero residual has no valid
	// signalling.
	if k, ok := best_merge_k.?; ok {
		restore_trial(enc, pre)
		fill_cu_info(
			enc,
			x,
			y,
			size,
			Cu_Info {
				type = .Inter,
				depth = depth,
				part = .P_2Nx2N,
				pred = uniq_mv[k].pred,
				mv = uniq_mv[k].mv,
				ref_idx = uniq_mv[k].ref_idx,
				merge = true,
				merge_idx = uniq_idx[k],
				qp = enc.qp,
			},
		)
		sse_m := write_leaf(RQT, enc, x, y, depth, trial, true)
		c := cu_at(enc.cu, x, y)
		if c.cbf_y || c.cbf_u || c.cbf_v {
			inter_consider(
				RQT,
				&best,
				&best_store,
				enc,
				x,
				y,
				size,
				f64(sse_m) + enc.lambda * f64(bits_since(enc, base)),
			)
		}
	}

	if enc.config.amp {
		consider_parts(RQT, enc, x, y, depth, trial, base, pre, &best, &best_store, false)
	}

	restore_trial(enc, pre)
	if b, ok := best.?; ok {
		restore_inter_best(RQT, enc, x, y, size, b)
		return {cost = b.cost, early_skip = false}
	}
	return {cost = max(f64), early_skip = false}
}

// Evaluate one AMVP form of a B CU (uni L0, uni L1 or BI): pick the mvp flag
// for each used list, signal and reconstruct, then keep the RD cost.
@(private)
consider_amvp_b :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y, size: int,
	depth: u8,
	base: int,
	pre: Trial_State,
	trial: ^Cabac,
	best: ^Maybe(^Inter_Best),
	best_store: ^Inter_Best,
	pred: [2]bool,
	mv: [2][2]i16,
	ref_idx: [2]i8,
	idc: u8,
	c0, c1: [2][2]i16,
) {
	restore_trial(enc, pre)
	flags: [2]u8
	if pred[0] do flags[0] = u8(pick_mvp(c0, mv[0]))
	if pred[1] do flags[1] = u8(pick_mvp(c1, mv[1]))
	fill_cu_info(
		enc,
		x,
		y,
		size,
		Cu_Info {
			type = .Inter,
			depth = depth,
			part = .P_2Nx2N,
			pred = pred,
			mv = mv,
			ref_idx = ref_idx,
			idc = idc,
			mvp_flag = flags,
			qp = enc.qp,
		},
	)
	sse := write_leaf(RQT, enc, x, y, depth, trial, true)
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
}

// B inter leaf candidate: the merge/skip list is evaluated first for the same
// early termination as the P path; uni and bi AMVP and merge with residual
// follow only when no skip is good enough.
eval_inter_leaf_b :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	trial: ^Cabac,
) -> Inter_Leaf_Result {
	size := CTU_WIDTH >> depth
	base := common.bits_written(trial.stream)

	merge_mv: [8]Mv_Info
	n_merge := merge_candidates_b(enc, x, y, size, &merge_mv)

	pre := save_trial(enc)
	best_store: Inter_Best = ---
	best: Maybe(^Inter_Best)

	// Deduplicate the merge list on (prediction flags, vectors, reference
	// indices): the first index for a candidate is the cheapest to signal.
	uniq_mv: [8]Mv_Info
	uniq_idx: [8]u8
	n_uniq := 0
	for i in 0 ..< n_merge {
		dup := false
		for k in 0 ..< n_uniq {
			if same_motion_enc(&uniq_mv[k], &merge_mv[i]) {
				dup = true
				break
			}
		}
		if !dup {
			uniq_mv[n_uniq] = merge_mv[i]
			uniq_idx[n_uniq] = u8(i)
			n_uniq += 1
		}
	}

	best_merge_sse := max(u64)
	best_merge_k: Maybe(int)
	for k in 0 ..< n_uniq {
		restore_trial(enc, pre)
		fill_cu_info(
			enc,
			x,
			y,
			size,
			Cu_Info {
				type = .Inter,
				depth = depth,
				part = .P_2Nx2N,
				pred = uniq_mv[k].pred,
				mv = uniq_mv[k].mv,
				ref_idx = uniq_mv[k].ref_idx,
				merge = true,
				merge_idx = uniq_idx[k],
				skipped = true,
				qp = enc.qp,
			},
		)
		sse := write_leaf(RQT, enc, x, y, depth, trial, true)
		inter_consider(
			RQT,
			&best,
			&best_store,
			enc,
			x,
			y,
			size,
			f64(sse) + enc.lambda * f64(bits_since(enc, base)),
		)
		if sse < best_merge_sse {
			best_merge_sse = sse
			best_merge_k = k
		}
	}

	if best_merge_sse <= skip_early_limit(enc, size) {
		restore_trial(enc, pre)
		if b, ok := best.?; ok {
			restore_inter_best(RQT, enc, x, y, size, b)
			return {cost = b.cost, early_skip = true}
		}
	}

	bc := Pu_Context {
		cu_x    = x,
		cu_y    = y,
		cu_size = size,
		pu_w    = size,
		pu_h    = size,
	}
	r0, r1 := enc.search_ref[0], enc.search_ref[1]
	cands0, avail0 := amvp_candidates_b(
		enc,
		x,
		y,
		size,
		size,
		0,
		bc,
		enc.ref_poc[0][r0],
		enc.cur_poc,
	)
	cands1, avail1 := amvp_candidates_b(
		enc,
		x,
		y,
		size,
		size,
		1,
		bc,
		enc.ref_poc[1][r1],
		enc.cur_poc,
	)
	c0 := amvp_build_list(enc, x, y, size, size, 0, enc.ref_poc[0][r0], cands0, avail0)
	c1 := amvp_build_list(enc, x, y, size, size, 1, enc.ref_poc[1][r1], cands1, avail1)

	mv0, _ := motion_estimate(
		enc,
		&enc.refs[0][r0],
		x,
		y,
		size,
		size,
		c0[0][0],
		c0[0][1],
		wp_luma(enc, 0, r0),
	)
	mv1, _ := motion_estimate(
		enc,
		&enc.refs[1][r1],
		x,
		y,
		size,
		size,
		c1[0][0],
		c1[0][1],
		wp_luma(enc, 1, r1),
	)

	consider_amvp_b(
		RQT,
		enc,
		x,
		y,
		size,
		depth,
		base,
		pre,
		trial,
		&best,
		&best_store,
		{true, false},
		{mv0, {}},
		{i8(r0), -1},
		PRED_L0,
		c0,
		c1,
	)
	consider_amvp_b(
		RQT,
		enc,
		x,
		y,
		size,
		depth,
		base,
		pre,
		trial,
		&best,
		&best_store,
		{false, true},
		{{}, mv1},
		{-1, i8(r1)},
		PRED_L1,
		c0,
		c1,
	)
	consider_amvp_b(
		RQT,
		enc,
		x,
		y,
		size,
		depth,
		base,
		pre,
		trial,
		&best,
		&best_store,
		{true, true},
		{mv0, mv1},
		{i8(r0), i8(r1)},
		PRED_BI,
		c0,
		c1,
	)

	// Merge with residual for the best-predicting vector only; rqt_root_cbf
	// is inferred to one, so an all-zero residual has no valid signalling.
	if k, ok := best_merge_k.?; ok {
		restore_trial(enc, pre)
		fill_cu_info(
			enc,
			x,
			y,
			size,
			Cu_Info {
				type = .Inter,
				depth = depth,
				part = .P_2Nx2N,
				pred = uniq_mv[k].pred,
				mv = uniq_mv[k].mv,
				ref_idx = uniq_mv[k].ref_idx,
				merge = true,
				merge_idx = uniq_idx[k],
				qp = enc.qp,
			},
		)
		sse := write_leaf(RQT, enc, x, y, depth, trial, true)
		c := cu_at(enc.cu, x, y)
		if c.cbf_y || c.cbf_u || c.cbf_v {
			inter_consider(
				RQT,
				&best,
				&best_store,
				enc,
				x,
				y,
				size,
				f64(sse) + enc.lambda * f64(bits_since(enc, base)),
			)
		}
	}

	if enc.config.amp {
		consider_parts(RQT, enc, x, y, depth, trial, base, pre, &best, &best_store, true)
	}

	restore_trial(enc, pre)
	if b, ok := best.?; ok {
		restore_inter_best(RQT, enc, x, y, size, b)
		return {cost = b.cost, early_skip = false}
	}
	return {cost = max(f64), early_skip = false}
}

// Split candidate: signal the flag and recurse into the four children.
eval_split :: proc($RQT: bool, enc: ^Encoder, x, y: int, depth: u8, trial: ^Cabac) -> f64 {
	size := CTU_WIDTH >> depth
	half := size / 2
	base := common.bits_written(trial.stream)
	write_split_flag(enc, x, y, depth, trial, true)
	cost := enc.lambda * f64(common.bits_written(trial.stream) - base)
	for sub in 0 ..< 4 {
		cx := x + (sub & 1) * half
		cy := y + (sub >> 1) * half
		if child_inside(enc, cx, cy) {
			cost += decide_cu(RQT, enc, cx, cy, depth + 1, trial)
		}
	}
	return cost
}

// Decide the coding structure of one node. Returns the RD cost.
decide_cu :: proc($RQT: bool, enc: ^Encoder, x, y: int, depth: u8, trial: ^Cabac) -> f64 {
	if depth == 0 {
		// The 64x64 CTU is always split. When it lies fully inside the
		// picture the split flag is signalled; otherwise it is implied.
		if x + CTU_WIDTH <= enc.coded_width && y + CTU_WIDTH <= enc.coded_height {
			write_split_flag(enc, x, y, 0, trial, true)
		}
		half := CTU_WIDTH / 2
		cost: f64
		for sub in 0 ..< 4 {
			cx := x + (sub & 1) * half
			cy := y + (sub >> 1) * half
			if child_inside(enc, cx, cy) {
				cost += decide_cu(RQT, enc, cx, cy, 1, trial)
			}
		}
		return cost
	}

	size := CTU_WIDTH >> depth
	inside := x + size <= enc.coded_width && y + size <= enc.coded_height
	half := size / 2

	if !inside {
		// Implicit split: no flag is signalled.
		cost: f64
		for sub in 0 ..< 4 {
			cx := x + (sub & 1) * half
			cy := y + (sub >> 1) * half
			if child_inside(enc, cx, cy) {
				cost += decide_cu(RQT, enc, cx, cy, depth + 1, trial)
			}
		}
		return cost
	}

	pre: Node_State = ---
	best_state: Node_State = ---
	save_node(enc, x, y, depth, &pre)
	best_cost := max(f64)

	// Inter runs first: a skip good enough to commit stops the node before the
	// intra mode search and the split recursion.
	if enc.slice_type != .I && !enc.config.intra_only {
		// save_node only copied the initial state; no rollback is needed yet.
		r := eval_inter_leaf(RQT, enc, x, y, depth, trial)
		// The inter evaluator already restored its winning reconstruction/CU
		// records and incoming trial state. An early skip has no comparison left.
		if r.early_skip do return r.cost
		if r.cost < best_cost {
			best_cost = r.cost
			save_node(enc, x, y, depth, &best_state)
		}
	}

	restore_node(enc, x, y, depth, &pre)
	cost := eval_intra_leaf(RQT, enc, x, y, depth, trial, best_cost)
	if cost < best_cost {
		best_cost = cost
		save_node(enc, x, y, depth, &best_state)
	}

	// PCM can only win when the raw samples cost less than the best candidate;
	// the distortion is zero, so lambda * raw bits is a sound lower bound.
	if enc.config.pcm &&
	   depth > 0 &&
	   depth <= MAX_CU_DEPTH &&
	   f64(pcm_raw_bits(CTU_WIDTH >> depth, enc.bit_depth, enc.config.chroma_format)) *
			   enc.lambda <
		   best_cost {
		restore_node(enc, x, y, depth, &pre)
		cost = eval_intra_pcm(RQT, enc, x, y, depth, trial)
		if cost < best_cost {
			best_cost = cost
			save_node(enc, x, y, depth, &best_state)
		}
	}

	if depth < MAX_CU_DEPTH {
		restore_node(enc, x, y, depth, &pre)
		cost = eval_split(RQT, enc, x, y, depth, trial)
		if cost < best_cost {
			best_cost = cost
			save_node(enc, x, y, depth, &best_state)
		}
	}

	restore_node(enc, x, y, depth, &best_state)
	return best_cost
}

// Bitstream pass: follows the decisions stored in the CU grid.
write_cu :: proc($RQT: bool, enc: ^Encoder, x, y: int, depth: u8, cabac: ^Cabac) {
	if depth == 0 {
		if x + CTU_WIDTH <= enc.coded_width && y + CTU_WIDTH <= enc.coded_height {
			write_split_flag(enc, x, y, 0, cabac, true)
		}
		half := CTU_WIDTH / 2
		for sub in 0 ..< 4 {
			cx := x + (sub & 1) * half
			cy := y + (sub >> 1) * half
			if child_inside(enc, cx, cy) {
				write_cu(RQT, enc, cx, cy, 1, cabac)
			}
		}
		return
	}

	size := CTU_WIDTH >> depth
	inside := x + size <= enc.coded_width && y + size <= enc.coded_height
	half := size / 2

	split: bool
	if !inside {
		split = true
	} else if depth == MAX_CU_DEPTH {
		split = false
	} else {
		split = cu_at(enc.cu, x, y).depth > depth
		write_split_flag(enc, x, y, depth, cabac, split)
	}

	if split {
		for sub in 0 ..< 4 {
			cx := x + (sub & 1) * half
			cy := y + (sub >> 1) * half
			if child_inside(enc, cx, cy) {
				write_cu(RQT, enc, cx, cy, depth + 1, cabac)
			}
		}
		return
	}

	write_leaf(RQT, enc, x, y, depth, cabac, false)
}

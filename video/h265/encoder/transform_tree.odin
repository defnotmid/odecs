package h265_encoder

// ---------------------------------------------------------------------------
// Inter transform tree (7.3.8.8). The CU's transform block is recursively
// split into quadrant transform units, chosen by RD. The decoder's
// transform_tree/transform_unit are the reference; the syntax is emitted in
// exactly their order.
//
// Inter prediction is per PU (the whole CU), so the tree only partitions the
// residual. Leaves stop at 8x8 luma: a 4x4 luma TU would move chroma to the
// blk_idx == 3 special case and is not worth its RD here.
// ---------------------------------------------------------------------------

// Prediction for the CU the tree belongs to, with the leaf offsets resolved
// against the CU origin.
Tf_Ctx :: struct {
	cu_x:    int,
	cu_y:    int,
	cu_size: int,
	pred_y:  []Sample,
	pred_u:  []Sample,
	pred_v:  []Sample,
}

// Quantized coefficients and coded-block flags of one prepared leaf.
Tf_Leaf :: struct {
	cbf_y: bool,
	// 4:2:2 stacks two chroma transform blocks per component (7.3.8.10).
	cbf_u: [2]bool,
	cbf_v: [2]bool,
	q_y:   [32 * 32]i16,
	q_u:   [2][32 * 32]i16,
	q_v:   [2][32 * 32]i16,
	coeff: [32 * 32]i16,
	tmp:   [32 * 32]i16,
}

// The split flag is coded for an inter 2Nx2N CU when the transform block is
// larger than 4x4, at most 32x32, and the hierarchy budget is not exhausted.
@(private)
tf_split_codable :: #force_inline proc(log2_size, depth: int) -> bool {
	return log2_size <= MAX_TU_LOG2 && log2_size > 2 && depth < RQT_MAX_HIER
}

@(private)
tf_can_split :: #force_inline proc(log2_size, depth: int) -> bool {
	return log2_size > MIN_RQT_TU_LOG2 && depth < RQT_MAX_HIER
}

// region_has_any_cbf is true when any 4x4 cell of the region carries a coded
// block flag; it is the rqt_root_cbf value of 7.3.8.7.
region_has_any_cbf :: proc(enc: ^Encoder, x, y, size: int) -> bool #no_bounds_check {
	span := size >> 2
	base := (y >> 2) * enc.cu.cols + (x >> 2)
	for j in 0 ..< span {
		row := base + j * enc.cu.cols
		for i in 0 ..< span {
			c := &enc.cu.cells[row + i]
			if c.cbf_y || c.cbf_u || c.cbf_v do return true
		}
	}
	return false
}

@(private)
region_has_cbf_u :: proc(enc: ^Encoder, x, y, size: int) -> bool #no_bounds_check {
	span := size >> 2
	base := (y >> 2) * enc.cu.cols + (x >> 2)
	for j in 0 ..< span {
		row := base + j * enc.cu.cols
		for i in 0 ..< span do if enc.cu.cells[row + i].cbf_u do return true
	}
	return false
}

@(private)
region_has_cbf_v :: proc(enc: ^Encoder, x, y, size: int) -> bool #no_bounds_check {
	span := size >> 2
	base := (y >> 2) * enc.cu.cols + (x >> 2)
	for j in 0 ..< span {
		row := base + j * enc.cu.cols
		for i in 0 ..< span do if enc.cu.cells[row + i].cbf_v do return true
	}
	return false
}

// tf_recon_plane adds the reconstructed residual to the CU-sized prediction
// and writes the result, accumulating the SSE. `pred` is the CU plane, so the
// leaf reads through its own offset and stride.
@(private)
tf_recon_plane :: proc(
	enc: ^Encoder,
	dst: Plane(Sample),
	src: Plane(Sample),
	x, y, n: int,
	q: []i16,
	tmp: []i16,
	pred: []Sample,
	pred_stride, pred_ox, pred_oy: int,
	cbf: bool,
	kind: Sl_Kind,
	qp: i32,
	sse: ^u64,
) #no_bounds_check {
	if cbf {
		enc_dequantize(enc, q, tmp, n, kind, false, int(qp))
		inverse_transform(n, tmp, q, enc.bit_depth)
	}
	recon_plane_vec(
		dst,
		src,
		x,
		y,
		n,
		q,
		pred,
		pred_stride,
		pred_ox,
		pred_oy,
		cbf,
		enc.bit_depth,
		sse,
	)
}

// tf_leaf_prepare transforms and quantizes one leaf into caller-provided
// scratch. A chroma component whose parent coded block flag is zero is not
// coded and its leaf is inferred to zero residual. `leaf` must be `= ---`:
// only the entries read later are written.
@(private)
tf_leaf_prepare :: proc(
	enc: ^Encoder,
	ctx: Tf_Ctx,
	leaf: ^Tf_Leaf,
	x, y, size, depth: int,
	cbf_u_up, cbf_v_up: bool,
) #no_bounds_check {
	leaf.cbf_u = [2]bool{false, false}
	leaf.cbf_v = [2]bool{false, false}
	qp_c := chroma_qp_scaled(enc)
	csize := size / (enc.config.chroma_format == Chroma_Layout.YUV_444 ? 1 : 2)

	for j in 0 ..< size {
		for i in 0 ..< size {
			leaf.tmp[j * size + i] = i16(
				i32(at(enc.source.y, x + i, y + j)) -
				i32(ctx.pred_y[(y - ctx.cu_y + j) * ctx.cu_size + (x - ctx.cu_x + i)]),
			)
		}
	}
	forward_transform(enc, size, leaf.tmp[:], size, leaf.coeff[:], enc.bit_depth)
	leaf.cbf_y = enc_quantize(
		enc,
		leaf.coeff[:],
		leaf.q_y[:],
		size,
		.Y,
		false,
		int(luma_qp_scaled(enc)),
	)

	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	cx := x / sub_w
	cy := y / sub_h
	cw := ctx.cu_size / sub_w
	ox := cx - ctx.cu_x / sub_w
	oy := cy - ctx.cu_y / sub_h

	n_chroma := chroma_blocks(enc.config.chroma_format)
	for t in 0 ..< n_chroma {
		if depth == 0 || cbf_u_up {
			for j in 0 ..< csize {
				for i in 0 ..< csize {
					leaf.tmp[j * csize + i] = i16(
						i32(at(enc.source.u, cx + i, cy + t * csize + j)) -
						i32(ctx.pred_u[(oy + t * csize + j) * cw + ox + i]),
					)
				}
			}
			forward_transform(enc, csize, leaf.tmp[:], csize, leaf.coeff[:], enc.bit_depth)
			leaf.cbf_u[t] = enc_quantize(
				enc,
				leaf.coeff[:],
				leaf.q_u[t][:],
				csize,
				.Cb,
				false,
				int(qp_c),
			)
		}

		if depth == 0 || cbf_v_up {
			for j in 0 ..< csize {
				for i in 0 ..< csize {
					leaf.tmp[j * csize + i] = i16(
						i32(at(enc.source.v, cx + i, cy + t * csize + j)) -
						i32(ctx.pred_v[(oy + t * csize + j) * cw + ox + i]),
					)
				}
			}
			forward_transform(enc, csize, leaf.tmp[:], csize, leaf.coeff[:], enc.bit_depth)
			leaf.cbf_v[t] = enc_quantize(
				enc,
				leaf.coeff[:],
				leaf.q_v[t][:],
				csize,
				.Cr,
				false,
				int(qp_c),
			)
		}
	}
}

@(private)
tf_leaf_emit :: proc(
	cabac: ^Cabac,
	leaf: ^Tf_Leaf,
	size, depth: int,
	cbf_u_up, cbf_v_up: bool,
	n_chroma, csize: int,
) {
	if depth == 0 || cbf_u_up {
		for t in 0 ..< n_chroma {
			cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[depth], leaf.cbf_u[t] ? 1 : 0)
		}
	}
	if depth == 0 || cbf_v_up {
		for t in 0 ..< n_chroma {
			cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[depth], leaf.cbf_v[t] ? 1 : 0)
		}
	}
	if depth != 0 || leaf.cbf_u[0] || leaf.cbf_u[1] || leaf.cbf_v[0] || leaf.cbf_v[1] {
		cabac_bin(cabac, &cabac.ctx.qt_cbf_model_luma[depth == 0 ? 1 : 0], leaf.cbf_y ? 1 : 0)
	}
	if leaf.cbf_y do encode_coeff_nxn(cabac, leaf.q_y[:size * size], size, 0, .Diag)
	for t in 0 ..< n_chroma {
		if leaf.cbf_u[t] do encode_coeff_nxn(cabac, leaf.q_u[t][:csize * csize], csize, 1, .Diag)
	}
	for t in 0 ..< n_chroma {
		if leaf.cbf_v[t] do encode_coeff_nxn(cabac, leaf.q_v[t][:csize * csize], csize, 2, .Diag)
	}
}

// Reconstruct one leaf and store its coded block flags and transform edges.
@(private)
tf_leaf_recon :: proc(enc: ^Encoder, ctx: Tf_Ctx, x, y, size: int, leaf: ^Tf_Leaf) -> u64 {
	qp_c := chroma_qp_scaled(enc)
	csize := size / (enc.config.chroma_format == Chroma_Layout.YUV_444 ? 1 : 2)
	set_cbf_flags(
		enc,
		x,
		y,
		size,
		leaf.cbf_y,
		leaf.cbf_u[0] || leaf.cbf_u[1],
		leaf.cbf_v[0] || leaf.cbf_v[1],
	)
	set_tr_log2(enc, x, y, size, log2_size(size))
	mark_tu_enc(enc, x, y, size)

	sse: u64
	tf_recon_plane(
		enc,
		enc.rec.y,
		enc.source.y,
		x,
		y,
		size,
		leaf.q_y[:],
		leaf.tmp[:],
		ctx.pred_y,
		ctx.cu_size,
		x - ctx.cu_x,
		y - ctx.cu_y,
		leaf.cbf_y,
		.Y,
		luma_qp_scaled(enc),
		&sse,
	)
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	for t in 0 ..< chroma_blocks(enc.config.chroma_format) {
		tf_recon_plane(
			enc,
			enc.rec.u,
			enc.source.u,
			x / sub_w,
			y / sub_h + t * csize,
			csize,
			leaf.q_u[t][:],
			leaf.tmp[:],
			ctx.pred_u,
			ctx.cu_size / sub_w,
			x / sub_w - ctx.cu_x / sub_w,
			y / sub_h + t * csize - ctx.cu_y / sub_h,
			leaf.cbf_u[t],
			.Cb,
			qp_c,
			&sse,
		)
		tf_recon_plane(
			enc,
			enc.rec.v,
			enc.source.v,
			x / sub_w,
			y / sub_h + t * csize,
			csize,
			leaf.q_v[t][:],
			leaf.tmp[:],
			ctx.pred_v,
			ctx.cu_size / sub_w,
			x / sub_w - ctx.cu_x / sub_w,
			y / sub_h + t * csize - ctx.cu_y / sub_h,
			leaf.cbf_v[t],
			.Cr,
			qp_c,
			&sse,
		)
	}
	return sse
}

// tf_no_residual resets the tree grid and CU boundary marks of a region with
// no residual so the search pass and the replay agree on deblocking.
@(private)
tf_no_residual :: proc(enc: ^Encoder, x, y, size: int) {
	span := size >> 2
	base := (y >> 2) * enc.cu.cols + (x >> 2)
	for j in 0 ..< span {
		row := base + j * enc.cu.cols
		for i in 0 ..< span {
			enc.cu.cells[row + i].tu_v = false
			enc.cu.cells[row + i].tu_h = false
		}
	}
	set_tr_log2(enc, x, y, size, log2_size(size))
	mark_tu_enc(enc, x, y, size)
}

// ---------------------------------------------------------------------------
// RD search
// ---------------------------------------------------------------------------

Tf_Result :: struct {
	cost:  f64,
	sse:   u64,
	cbf_u: bool,
	cbf_v: bool,
}

@(private)
tf_search_leaf :: proc(
	enc: ^Encoder,
	ctx: Tf_Ctx,
	x, y, log2_size, depth: int,
	cbf_u_up, cbf_v_up, codable: bool,
	trial: ^Cabac,
) -> Tf_Result {
	size := 1 << uint(log2_size)
	start := cabac_rate(trial)
	if codable do cabac_bin(trial, &trial.ctx.trans_subdiv_model[5 - log2_size], 0)
	leaf: Tf_Leaf = ---
	tf_leaf_prepare(enc, ctx, &leaf, x, y, size, depth, cbf_u_up, cbf_v_up)
	tf_leaf_emit(
		trial,
		&leaf,
		size,
		depth,
		cbf_u_up,
		cbf_v_up,
		chroma_blocks(enc.config.chroma_format),
		size / (enc.config.chroma_format == Chroma_Layout.YUV_444 ? 1 : 2),
	)
	sse := tf_leaf_recon(enc, ctx, x, y, size, &leaf)
	bits := cabac_rate(trial) - start
	return {
		cost = f64(sse) + enc.lambda * f64(bits),
		sse = sse,
		cbf_u = leaf.cbf_u[0] || leaf.cbf_u[1],
		cbf_v = leaf.cbf_v[0] || leaf.cbf_v[1],
	}
}

@(private)
tf_search_node :: proc(
	enc: ^Encoder,
	ctx: Tf_Ctx,
	x, y, log2_size, depth: int,
	cbf_u_up, cbf_v_up: bool,
	trial: ^Cabac,
) -> Tf_Result {
	size := 1 << uint(log2_size)
	codable := tf_split_codable(log2_size, depth)
	can_split := tf_can_split(log2_size, depth)

	pre: Node_State = ---
	best: Node_State = ---
	best_res: Tf_Result
	best_cost := max(f64)

	save_node_size(enc, x, y, size, &pre)
	r := tf_search_leaf(enc, ctx, x, y, log2_size, depth, cbf_u_up, cbf_v_up, codable, trial)
	best_cost, best_res = r.cost, r
	save_node_size(enc, x, y, size, &best)

	if can_split {
		restore_node_size(enc, x, y, size, &pre)
		r2 := tf_search_split(enc, ctx, x, y, log2_size, depth, cbf_u_up, cbf_v_up, codable, trial)
		if r2.cost < best_cost {
			best_cost, best_res = r2.cost, r2
			save_node_size(enc, x, y, size, &best)
		}
	}

	restore_node_size(enc, x, y, size, &best)
	return best_res
}

@(private)
tf_search_split :: proc(
	enc: ^Encoder,
	ctx: Tf_Ctx,
	x, y, log2_size, depth: int,
	cbf_u_up, cbf_v_up, codable: bool,
	trial: ^Cabac,
) -> Tf_Result {
	size := 1 << uint(log2_size)
	half := size / 2
	start := cabac_rate(trial)
	if codable do cabac_bin(trial, &trial.ctx.trans_subdiv_model[5 - log2_size], 1)
	after_split := cabac_rate(trial)

	cost: f64
	sse: u64
	cbf_u, cbf_v: bool
	// The node's chroma flags are the OR of its children. Children are searched
	// with the parent flag assumed set; replay corrects the final bins from the
	// stored tree, which does not change any reconstruction.
	for sub in 0 ..< 4 {
		cx := x + (sub & 1) * half
		cy := y + (sub >> 1) * half
		r := tf_search_node(enc, ctx, cx, cy, log2_size - 1, depth + 1, true, true, trial)
		cost += r.cost
		sse += r.sse
		cbf_u = cbf_u || r.cbf_u
		cbf_v = cbf_v || r.cbf_v
	}

	before_cbf := cabac_rate(trial)
	if has_chroma(enc) && (depth == 0 || cbf_u_up) do cabac_bin(trial, &trial.ctx.qt_cbf_model_chroma[depth], cbf_u ? 1 : 0)
	if has_chroma(enc) && (depth == 0 || cbf_v_up) do cabac_bin(trial, &trial.ctx.qt_cbf_model_chroma[depth], cbf_v ? 1 : 0)
	after_cbf := cabac_rate(trial)

	node_bits := (after_split - start) + (after_cbf - before_cbf)
	return {cost = cost + enc.lambda * f64(node_bits), sse = sse, cbf_u = cbf_u, cbf_v = cbf_v}
}

// ---------------------------------------------------------------------------
// Bitstream replay
// ---------------------------------------------------------------------------

@(private)
tf_write_node :: proc(
	enc: ^Encoder,
	ctx: Tf_Ctx,
	x, y, log2_size, depth: int,
	cbf_u_up, cbf_v_up: bool,
	cabac: ^Cabac,
) {
	size := 1 << uint(log2_size)
	codable := tf_split_codable(log2_size, depth)
	split := int(cu_at(enc.cu, x, y).tr_depth) < log2_size

	if split {
		cbf_u := depth == 0 || cbf_u_up ? region_has_cbf_u(enc, x, y, size) : false
		cbf_v := depth == 0 || cbf_v_up ? region_has_cbf_v(enc, x, y, size) : false
		if codable do cabac_bin(cabac, &cabac.ctx.trans_subdiv_model[5 - log2_size], 1)
		if has_chroma(enc) && (depth == 0 || cbf_u_up) do cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[depth], cbf_u ? 1 : 0)
		if has_chroma(enc) && (depth == 0 || cbf_v_up) do cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[depth], cbf_v ? 1 : 0)
		half := size / 2
		for sub in 0 ..< 4 {
			cx := x + (sub & 1) * half
			cy := y + (sub >> 1) * half
			tf_write_node(enc, ctx, cx, cy, log2_size - 1, depth + 1, cbf_u, cbf_v, cabac)
		}
		return
	}

	leaf: Tf_Leaf = ---
	tf_leaf_prepare(enc, ctx, &leaf, x, y, size, depth, cbf_u_up, cbf_v_up)
	if codable do cabac_bin(cabac, &cabac.ctx.trans_subdiv_model[5 - log2_size], 0)
	// The replay codes the same chroma flags the search decided: preparing
	// the leaf again derives them identically from the same residual, pair
	// slots included.
	n_chroma := chroma_blocks(enc.config.chroma_format)
	csize := size / (enc.config.chroma_format == Chroma_Layout.YUV_444 ? 1 : 2)
	if depth == 0 || cbf_u_up {
		for t in 0 ..< n_chroma {
			cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[depth], leaf.cbf_u[t] ? 1 : 0)
		}
	}
	if depth == 0 || cbf_v_up {
		for t in 0 ..< n_chroma {
			cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[depth], leaf.cbf_v[t] ? 1 : 0)
		}
	}
	if depth != 0 || leaf.cbf_u[0] || leaf.cbf_u[1] || leaf.cbf_v[0] || leaf.cbf_v[1] {
		cabac_bin(cabac, &cabac.ctx.qt_cbf_model_luma[depth == 0 ? 1 : 0], leaf.cbf_y ? 1 : 0)
	}
	if leaf.cbf_y do encode_coeff_nxn(cabac, leaf.q_y[:size * size], size, 0, .Diag)
	for t in 0 ..< n_chroma {
		if leaf.cbf_u[t] do encode_coeff_nxn(cabac, leaf.q_u[t][:csize * csize], csize, 1, .Diag)
	}
	for t in 0 ..< n_chroma {
		if leaf.cbf_v[t] do encode_coeff_nxn(cabac, leaf.q_v[t][:csize * csize], csize, 2, .Diag)
	}
	_ = tf_leaf_recon(enc, ctx, x, y, size, &leaf)
}

// Reconstruct a CU with no residual as prediction alone.
@(private)
tf_recon_prediction :: proc(enc: ^Encoder, ctx: Tf_Ctx, x, y, size: int) -> u64 {
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	sse: u64
	csize := size / sub_w
	for j in 0 ..< size {
		for i in 0 ..< size {
			v := ctx.pred_y[(y - ctx.cu_y + j) * ctx.cu_size + (x - ctx.cu_x + i)]
			set_at(enc.rec.y, x + i, y + j, v)
			d := i32(at(enc.source.y, x + i, y + j)) - i32(v)
			sse += u64(d * d)
		}
	}
	cw := ctx.cu_size / sub_w
	ox := x / sub_w - ctx.cu_x / sub_w
	oy := y / sub_h - ctx.cu_y / sub_h
	for j in 0 ..< (has_chroma(enc) ? size / sub_h : 0) {
		for i in 0 ..< csize {
			u := ctx.pred_u[(oy + j) * cw + ox + i]
			v := ctx.pred_v[(oy + j) * cw + ox + i]
			set_at(enc.rec.u, x / sub_w + i, y / sub_h + j, u)
			set_at(enc.rec.v, x / sub_w + i, y / sub_h + j, v)
			du := i32(at(enc.source.u, x / sub_w + i, y / sub_h + j)) - i32(u)
			dv := i32(at(enc.source.v, x / sub_w + i, y / sub_h + j)) - i32(v)
			sse += u64(du * du) + u64(dv * dv)
		}
	}
	set_cbf_flags(enc, x, y, size, false, false, false)
	tf_no_residual(enc, x, y, size)
	return sse
}

// write_inter_rqt drives the inter transform tree for one CU. `merge` units
// infer rqt_root_cbf to one and always carry the tree.
write_inter_rqt :: proc(
	enc: ^Encoder,
	x, y, size: int,
	merge: bool,
	pred_y, pred_u, pred_v: []Sample,
	cabac: ^Cabac,
	search: bool,
) -> u64 {
	ctx := Tf_Ctx {
		cu_x    = x,
		cu_y    = y,
		cu_size = size,
		pred_y  = pred_y,
		pred_u  = pred_u,
		pred_v  = pred_v,
	}
	root_log2 := log2_size(size)
	// The transform root's boundary always carries the transform edge flags.
	mark_tu_enc(enc, x, y, size)

	if search {
		r := tf_search_node(enc, ctx, x, y, root_log2, 0, false, false, cabac)
		cbf_any := region_has_any_cbf(enc, x, y, size)
		if !merge {
			cabac_bin(cabac, &cabac.ctx.cu_qt_root_cbf_model, cbf_any ? 1 : 0)
		}
		if !cbf_any {
			// rqt_root_cbf 0 means no transform tree is parsed, so the deblock
			// grid must show the CU as a single transform block.
			tf_no_residual(enc, x, y, size)
		}
		return r.sse
	}

	cbf_any := region_has_any_cbf(enc, x, y, size)
	if !merge {
		cabac_bin(cabac, &cabac.ctx.cu_qt_root_cbf_model, cbf_any ? 1 : 0)
	}
	if merge || cbf_any {
		tf_write_node(enc, ctx, x, y, root_log2, 0, false, false, cabac)
		return 0
	}
	_ = tf_recon_prediction(enc, ctx, x, y, size)
	return 0
}

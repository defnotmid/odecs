package h265_encoder

// ---------------------------------------------------------------------------
// Intra transform tree (7.3.8.8/7.3.8.9). The CU's luma intra mode is
// signalled once per prediction unit, so every transform block of the CU
// predicts with that one mode; the tree only partitions the residual. Leaves
// are reconstructed in z-scan order, so a leaf predicts from the earlier
// leaves of its own CU through the current reconstruction.
//
// Chroma follows the format geometry: one full-size block for 4:4:4, one
// half-size block for 4:2:0, and two stacked half-size blocks for 4:2:2.
// Subsampled chroma at a split 8x8 node is coded with its fourth child.
// ---------------------------------------------------------------------------

// Prediction context of the CU the tree belongs to: the one luma mode of its
// prediction unit, shared by every transform block.
Ir_Ctx :: struct {
	mode: u8,
}

// Prepared chroma blocks for one transform node. Its prediction is kept so the residual can be
// applied once the leaves that precede it in coding order are reconstructed.
Ir_Chroma :: struct {
	cbf_u:  [2]bool,
	cbf_v:  [2]bool,
	q_u:    [2][32 * 32]i16,
	q_v:    [2][32 * 32]i16,
	coeff:  [32 * 32]i16,
	tmp:    [32 * 32]i16,
	pred_u: [2][32 * 32]Sample,
	pred_v: [2][32 * 32]Sample,
}

// Luma state of one leaf.
Ir_Leaf :: struct {
	cbf_y: bool,
	q_y:   [32 * 32]i16,
	coeff: [32 * 32]i16,
	tmp:   [32 * 32]i16,
	pred:  [32 * 32]Sample,
}

Ir_Result :: struct {
	cost:  f64,
	sse:   u64,
	cbf_u: bool,
	cbf_v: bool,
}

// ir_use_dst is 8.6.4.1: a 4x4 luma intra block uses DST-VII at every
// prediction mode; chroma keeps DCT-II.
@(private)
ir_use_dst :: #force_inline proc(size: int) -> bool {
	return size == 4
}

// ir_scan_order is 7.4.9.11 for an intra transform block: a 4x4 block of any
// component, or a 4x4/8x8 luma block, uses the directional scan of a near
// horizontal or near vertical mode.
@(private)
ir_scan_order :: #force_inline proc(
	mode: u8,
	size: int,
	c_idx: int,
	layout: Chroma_Layout = .YUV_420,
) -> Scan_Order {
	return intra_scan(log2_size(size), c_idx, int(mode), layout_idc(layout))
}

// ir_recon_plane is the intra residual add: dequantize, inverse transform
// (DST-VII for a 4x4 luma intra block, the transform skip scale-down when the
// block skipped, followed by the residual-DPCM accumulation) and the
// prediction clamp, accumulating the SSE.
@(private)
ir_recon_plane :: proc(
	enc: ^Encoder,
	dst: Plane(Sample),
	src: Plane(Sample),
	x, y, size: int,
	q: []i16,
	tmp: []i16,
	pred: []Sample,
	cbf: bool,
	kind: Sl_Kind,
	qp: i32,
	use_dst: bool,
	use_tskip: bool,
	use_rdpcm: bool,
	rdpcm_vertical: bool,
	sse: ^u64,
) #no_bounds_check {
	if cbf {
		enc_dequantize(enc, q, tmp, size, kind, true, int(qp))
		if use_tskip {
			inverse_transform_skip(tmp, q, size, enc.bit_depth)
			if use_rdpcm do inverse_rdpcm(q, size, rdpcm_vertical)
		} else if use_dst {
			inverse_transform_dst4(tmp, q, enc.bit_depth)
		} else {
			inverse_transform(size, tmp, q, enc.bit_depth)
		}
	}
	recon_plane_vec(dst, src, x, y, size, q, pred, size, 0, 0, cbf, enc.bit_depth, sse)
}

// ir_luma_distortion is the leaf's SSE without touching the reconstruction:
// the quantized residual is dequantized and inverse transformed into `tmp`
// and compared against the source at the prediction.
@(private)
ir_luma_distortion :: proc(
	enc: ^Encoder,
	x, y, size: int,
	q, tmp: []i16,
	pred: []Sample,
	cbf: bool,
	qp: i32,
	bit_depth: int,
	use_dst, use_tskip, use_rdpcm, rdpcm_vertical: bool,
) -> u64 #no_bounds_check {
	if cbf {
		enc_dequantize(enc, q, tmp, size, .Y, true, int(qp))
		if use_tskip {
			inverse_transform_skip(tmp, tmp, size, bit_depth)
			if use_rdpcm do inverse_rdpcm(tmp, size, rdpcm_vertical)
		} else if use_dst {
			inverse_transform_dst4(tmp, tmp, bit_depth)
		} else {
			inverse_transform(size, tmp, tmp, bit_depth)
		}
	}

	max_v := i32(1) << uint(bit_depth) - 1

	sse: u64
	for j in 0 ..< size {
		for i in 0 ..< size {
			v := i32(pred[j * size + i])
			if cbf do v = clamp(v + i32(tmp[j * size + i]), 0, max_v)
			d := i32(at(enc.source.y, x + i, y + j)) - v
			sse += u64(d * d)
		}
	}
	return sse
}

// ir_choose_tskip picks between the DST and transform-skip forms of a 4x4
// luma leaf by RD. Both candidates are trialled on the trial stream (the cbf
// bin and the transform_skip_flag included) and the cheaper is kept. The
// replay pass reads the stored decision instead.
//
// With implicit RDPCM enabled (--rdpcm) a transform-skip block whose mode is
// 10 or 26 always carries the residual DPCM accumulation, so that candidate is
// the DPCM residual; for every other mode it stays the plain skip.
@(private)
ir_choose_tskip :: proc(
	enc: ^Encoder,
	ctx: Ir_Ctx,
	x, y, depth: int,
	residual, coeff, q: []i16,
	pred: []Sample,
	cbf: ^bool,
	cabac: ^Cabac,
	measure: bool,
) -> bool #no_bounds_check {
	rdpcm := enc.config.rdpcm && (ctx.mode == 10 || ctx.mode == 26)
	rdpcm_vertical := ctx.mode == 26

	if !measure {
		tskip := cu_at(enc.cu, x, y).tskip
		if tskip {
			if rdpcm do forward_rdpcm(residual, 4, rdpcm_vertical)
			transform_skip(residual, coeff, 4, enc.bit_depth)
		} else {
			forward_transform_dst4(enc, residual, 4, coeff, enc.bit_depth)
		}
		cbf^ = enc_quantize(enc, coeff, q, 4, .Y, true, int(luma_qp_scaled(enc)))
		return tskip
	}

	scan := ir_scan_order(ctx.mode, 4, 0)
	dst_q: [16]i16
	ts_q: [16]i16

	forward_transform_dst4(enc, residual, 4, coeff, enc.bit_depth)
	dst_cbf := enc_quantize(enc, coeff, dst_q[:], 4, .Y, true, int(luma_qp_scaled(enc)))
	if rdpcm do forward_rdpcm(residual, 4, rdpcm_vertical)
	transform_skip(residual, coeff, 4, enc.bit_depth)
	ts_cbf := enc_quantize(enc, coeff, ts_q[:], 4, .Y, true, int(luma_qp_scaled(enc)))

	// `coeff` is free scratch now, so the distortion candidate shares it.
	dst_sse := ir_luma_distortion(
		enc,
		x,
		y,
		4,
		dst_q[:],
		coeff,
		pred,
		dst_cbf,
		luma_qp_scaled(enc),
		enc.bit_depth,
		true,
		false,
		false,
		false,
	)
	ts_sse := ir_luma_distortion(
		enc,
		x,
		y,
		4,
		ts_q[:],
		coeff,
		pred,
		ts_cbf,
		luma_qp_scaled(enc),
		enc.bit_depth,
		false,
		true,
		rdpcm,
		rdpcm_vertical,
	)

	pre := save_trial(enc)
	base := cabac_rate(cabac)

	restore_trial(enc, pre)
	cabac_bin(cabac, &cabac.ctx.qt_cbf_model_luma[depth == 0 ? 1 : 0], dst_cbf ? 1 : 0)
	if dst_cbf do encode_coeff_nxn(cabac, dst_q[:], 4, 0, scan, false)
	dst_bits := cabac_rate(cabac) - base

	restore_trial(enc, pre)
	cabac_bin(cabac, &cabac.ctx.qt_cbf_model_luma[depth == 0 ? 1 : 0], ts_cbf ? 1 : 0)
	if ts_cbf do encode_coeff_nxn(cabac, ts_q[:], 4, 0, scan, true)
	ts_bits := cabac_rate(cabac) - base

	restore_trial(enc, pre)
	if f64(ts_sse) + enc.lambda * f64(ts_bits) < f64(dst_sse) + enc.lambda * f64(dst_bits) {
		copy(q, ts_q[:])
		cbf^ = ts_cbf
		return true
	}
	copy(q, dst_q[:])
	cbf^ = dst_cbf
	return false
}

// ir_set_chroma_cbf records a node's chroma flags on its cells. A node whose
// 4x4 children are searched as separate leaves has already overwritten them
// with their own (empty) flags, so the split restores them once the children
// are done.
@(private)
ir_set_chroma_cbf :: proc(enc: ^Encoder, x, y, size: int, cbf_u, cbf_v: bool) #no_bounds_check {
	span := size >> 2
	base := (y >> 2) * enc.cu.cols + (x >> 2)
	for j in 0 ..< span {
		row := base + j * enc.cu.cols
		for i in 0 ..< span {
			enc.cu.cells[row + i].cbf_u = cbf_u
			enc.cu.cells[row + i].cbf_v = cbf_v
		}
	}
}

// ir_chroma_prepare predicts, transforms and quantizes one chroma block. The
// prediction is always applied; a component whose parent coded block flag is
// zero is simply left with no residual.
@(private)
ir_chroma_prepare :: proc(
	enc: ^Encoder,
	ctx: Ir_Ctx,
	ch: ^Ir_Chroma,
	x, y, size: int,
	gated_u, gated_v: bool,
) #no_bounds_check {
	sw, sh := chroma_sub(enc.config.chroma_format)
	csize := size / sw
	qp_c := chroma_qp_scaled(enc)
	mode := chroma_pred_mode(enc.config.chroma_format, ctx.mode)
	ch.cbf_u, ch.cbf_v = {}, {}
	n := chroma_blocks(enc.config.chroma_format)
	// The lower 4:2:2 block predicts from the reconstructed upper block.
	// Preparation temporarily publishes that block, then restores its pixels;
	// quantized coefficients stay intact for the syntax/reconstruction pass.
	old_u: [16 * 16]Sample = ---
	old_v: [16 * 16]Sample = ---
	if n == 2 {
		for j in 0 ..< csize do for i in 0 ..< csize {
			old_u[j * csize + i] = at(enc.rec.u, x / sw + i, y / sh + j)
			old_v[j * csize + i] = at(enc.rec.v, x / sw + i, y / sh + j)
		}
	}
	for t in 0 ..< n {
		ty := y + t * csize * sh
		refs: Intra_Refs
		build_reference(enc, &enc.rec, x, ty, log2_size(csize), .U, &refs, enc.bit_depth)
		intra_predict(
			&refs,
			log2_size(csize),
			mode,
			.U,
			ch.pred_u[t][:],
			csize,
			enc.bit_depth,
			enc.config.chroma_format,
		)
		build_reference(enc, &enc.rec, x, ty, log2_size(csize), .V, &refs, enc.bit_depth)
		intra_predict(
			&refs,
			log2_size(csize),
			mode,
			.V,
			ch.pred_v[t][:],
			csize,
			enc.bit_depth,
			enc.config.chroma_format,
		)
		if gated_u {
			for j in 0 ..< csize do for i in 0 ..< csize {
				ch.tmp[j * csize + i] = i16(i32(at(enc.source.u, x / sw + i, ty / sh + j)) - i32(ch.pred_u[t][j * csize + i]))
			}
			forward_transform(enc, csize, ch.tmp[:], csize, ch.coeff[:], enc.bit_depth)
			ch.cbf_u[t] = enc_quantize(enc, ch.coeff[:], ch.q_u[t][:], csize, .Cb, true, int(qp_c))
		}
		if gated_v {
			for j in 0 ..< csize do for i in 0 ..< csize {
				ch.tmp[j * csize + i] = i16(i32(at(enc.source.v, x / sw + i, ty / sh + j)) - i32(ch.pred_v[t][j * csize + i]))
			}
			forward_transform(enc, csize, ch.tmp[:], csize, ch.coeff[:], enc.bit_depth)
			ch.cbf_v[t] = enc_quantize(enc, ch.coeff[:], ch.q_v[t][:], csize, .Cr, true, int(qp_c))
		}
		if n == 2 && t == 0 {
			sse: u64
			q := ch.q_u[t]
			ir_recon_plane(
				enc,
				enc.rec.u,
				enc.source.u,
				x / sw,
				y / sh,
				csize,
				q[:],
				ch.tmp[:],
				ch.pred_u[t][:],
				ch.cbf_u[t],
				.Cb,
				qp_c,
				false,
				false,
				false,
				false,
				&sse,
			)
			q = ch.q_v[t]
			ir_recon_plane(
				enc,
				enc.rec.v,
				enc.source.v,
				x / sw,
				y / sh,
				csize,
				q[:],
				ch.tmp[:],
				ch.pred_v[t][:],
				ch.cbf_v[t],
				.Cr,
				qp_c,
				false,
				false,
				false,
				false,
				&sse,
			)
		}
	}
	if n == 2 {
		for j in 0 ..< csize do for i in 0 ..< csize {
			set_at(enc.rec.u, x / sw + i, y / sh + j, old_u[j * csize + i])
			set_at(enc.rec.v, x / sw + i, y / sh + j, old_v[j * csize + i])
		}
	}
}

@(private)
ir_chroma_bins :: proc(
	enc: ^Encoder,
	cabac: ^Cabac,
	ch: ^Ir_Chroma,
	depth: int,
	gated_u, gated_v: bool,
) {
	n := chroma_blocks(enc.config.chroma_format)
	if gated_u do for t in 0 ..< n do cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[depth], ch.cbf_u[t] ? 1 : 0)
	if gated_v do for t in 0 ..< n do cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[depth], ch.cbf_v[t] ? 1 : 0)
}

@(private)
ir_chroma_emit_coeffs :: proc(enc: ^Encoder, cabac: ^Cabac, ch: ^Ir_Chroma, csize: int, mode: u8) {
	scan := ir_scan_order(
		chroma_pred_mode(enc.config.chroma_format, mode),
		csize,
		1,
		enc.config.chroma_format,
	)
	for t in 0 ..< chroma_blocks(enc.config.chroma_format) do if ch.cbf_u[t] do encode_coeff_nxn(cabac, ch.q_u[t][:csize * csize], csize, 1, scan)
	for t in 0 ..< chroma_blocks(enc.config.chroma_format) do if ch.cbf_v[t] do encode_coeff_nxn(cabac, ch.q_v[t][:csize * csize], csize, 2, scan)
}

@(private)
ir_chroma_recon :: proc(enc: ^Encoder, x, y, size: int, ch: ^Ir_Chroma) -> u64 #no_bounds_check {
	sw, sh := chroma_sub(enc.config.chroma_format)
	csize := size / sw
	qp_c := chroma_qp_scaled(enc)
	sse: u64
	for t in 0 ..< chroma_blocks(enc.config.chroma_format) {
		cy := y / sh + t * csize
		ir_recon_plane(
			enc,
			enc.rec.u,
			enc.source.u,
			x / sw,
			cy,
			csize,
			ch.q_u[t][:],
			ch.tmp[:],
			ch.pred_u[t][:],
			ch.cbf_u[t],
			.Cb,
			qp_c,
			false,
			false,
			false,
			false,
			&sse,
		)
		ir_recon_plane(
			enc,
			enc.rec.v,
			enc.source.v,
			x / sw,
			cy,
			csize,
			ch.q_v[t][:],
			ch.tmp[:],
			ch.pred_v[t][:],
			ch.cbf_v[t],
			.Cr,
			qp_c,
			false,
			false,
			false,
			false,
			&sse,
		)
	}
	return sse
}

// ir_recon_leaf signals, reconstructs and records one leaf. `measure` is the
// search pass: it counts the trial stream's bits. The bitstream pass replays
// the same bins on the real stream.
@(private)
ir_recon_leaf :: proc(
	enc: ^Encoder,
	ctx: Ir_Ctx,
	x, y, size, depth: int,
	codable: bool,
	cbf_u_up, cbf_v_up: bool,
	ch_in: ^Ir_Chroma,
	cabac: ^Cabac,
	measure: bool,
) -> (
	sse: u64,
	cbf_u, cbf_v: bool,
	bits: int,
) {
	start := 0
	if measure do start = cabac_rate(cabac)
	if codable do cabac_bin(cabac, &cabac.ctx.trans_subdiv_model[5 - log2_size(size)], 0)

	// --- Luma --------------------------------------------------------------
	leaf: Ir_Leaf = ---
	refs: Intra_Refs
	build_reference(enc, &enc.rec, x, y, log2_size(size), .Y, &refs, enc.bit_depth)
	intra_predict(&refs, log2_size(size), ctx.mode, .Y, leaf.pred[:], size, enc.bit_depth)
	for j in 0 ..< size {
		for i in 0 ..< size {
			leaf.tmp[j * size + i] = i16(
				i32(at(enc.source.y, x + i, y + j)) - i32(leaf.pred[j * size + i]),
			)
		}
	}
	use_dst := ir_use_dst(size)
	use_tskip := false
	if size == 4 && enc.config.tskip {
		use_tskip = ir_choose_tskip(
			enc,
			ctx,
			x,
			y,
			depth,
			leaf.tmp[:],
			leaf.coeff[:],
			leaf.q_y[:],
			leaf.pred[:],
			&leaf.cbf_y,
			cabac,
			measure,
		)
	} else {
		if use_dst {
			forward_transform_dst4(enc, leaf.tmp[:], size, leaf.coeff[:], enc.bit_depth)
		} else {
			forward_transform(enc, size, leaf.tmp[:], size, leaf.coeff[:], enc.bit_depth)
		}
		leaf.cbf_y = enc_quantize(
			enc,
			leaf.coeff[:],
			leaf.q_y[:],
			size,
			.Y,
			true,
			int(luma_qp_scaled(enc)),
		)
	}

	// --- Chroma ------------------------------------------------------------
	// An 8x8 node's block was prepared by the caller so it can share it
	// between the leaf and split candidates; every other leaf prepares its
	// own.
	ch: Ir_Chroma = ---
	gated_u := depth == 0 || cbf_u_up
	gated_v := depth == 0 || cbf_v_up
	// 4:4:4 owns chroma even at a 4x4 leaf.
	has_chroma :=
		(size > 4 || enc.config.chroma_format == .YUV_444) &&
		enc.config.chroma_format != .Monochrome
	if has_chroma {
		if ch_in != nil {
			ch = ch_in^
		} else {
			ir_chroma_prepare(enc, ctx, &ch, x, y, size, gated_u, gated_v)
		}
		ir_chroma_bins(enc, cabac, &ch, depth, gated_u, gated_v)
		cbf_u, cbf_v = ch.cbf_u[0] || ch.cbf_u[1], ch.cbf_v[0] || ch.cbf_v[1]
	}

	// Intra always codes cbf_luma, at any depth.
	cabac_bin(cabac, &cabac.ctx.qt_cbf_model_luma[depth == 0 ? 1 : 0], leaf.cbf_y ? 1 : 0)
	if leaf.cbf_y do encode_coeff_nxn(cabac, leaf.q_y[:size * size], size, 0, ir_scan_order(ctx.mode, size, 0), use_tskip)
	if has_chroma do ir_chroma_emit_coeffs(enc, cabac, &ch, size / (enc.config.chroma_format == .YUV_444 ? 1 : 2), ctx.mode)

	// --- Record and reconstruct -------------------------------------------
	set_cbf_flags(enc, x, y, size, leaf.cbf_y, cbf_u, cbf_v)
	set_tr_log2(enc, x, y, size, log2_size(size))
	mark_tu_enc(enc, x, y, size)
	if size == 4 do cu_at(enc.cu, x, y).tskip = use_tskip

	use_rdpcm := use_tskip && enc.config.rdpcm && (ctx.mode == 10 || ctx.mode == 26)
	ir_recon_plane(
		enc,
		enc.rec.y,
		enc.source.y,
		x,
		y,
		size,
		leaf.q_y[:],
		leaf.tmp[:],
		leaf.pred[:],
		leaf.cbf_y,
		.Y,
		luma_qp_scaled(enc),
		use_dst,
		use_tskip,
		use_rdpcm,
		ctx.mode == 26,
		&sse,
	)
	if has_chroma do sse += ir_chroma_recon(enc, x, y, size, &ch)

	if measure do bits = cabac_rate(cabac) - start
	return
}

// ---------------------------------------------------------------------------
// RD search
// ---------------------------------------------------------------------------

@(private)
ir_search_split :: proc(
	enc: ^Encoder,
	ctx: Ir_Ctx,
	x, y, log2_size, depth: int,
	cbf_u_up, cbf_v_up, codable: bool,
	ch: ^Ir_Chroma,
	trial: ^Cabac,
) -> Ir_Result {
	size := 1 << uint(log2_size)
	half := size / 2

	start := cabac_rate(trial)
	if codable do cabac_bin(trial, &trial.ctx.trans_subdiv_model[5 - log2_size], 1)
	// An 8x8 node's chroma flags are read before its 4x4 children.
	if ch != nil {
		ir_chroma_bins(enc, trial, ch, depth, depth == 0 || cbf_u_up, depth == 0 || cbf_v_up)
	}
	before_children := cabac_rate(trial)

	cost: f64
	sse: u64
	cbf_u := ch != nil ? ch.cbf_u[0] || ch.cbf_u[1] : false
	cbf_v := ch != nil ? ch.cbf_v[0] || ch.cbf_v[1] : false
	for sub in 0 ..< 4 {
		cx := x + (sub & 1) * half
		cy := y + (sub >> 1) * half
		r := ir_search_node(enc, ctx, cx, cy, log2_size - 1, depth + 1, true, true, trial)
		cost += r.cost
		sse += r.sse
		if ch == nil {
			cbf_u = cbf_u || r.cbf_u
			cbf_v = cbf_v || r.cbf_v
		}
	}
	after_children := cabac_rate(trial)

	// An 8x8 node's chroma coefficients follow its fourth child. A node whose
	// children own the chroma blocks has its own (OR) flag bins after them in
	// the trial stream; the bitstream pass writes them before, so only the RD
	// estimate sees this order.
	if ch != nil {
		ir_chroma_emit_coeffs(enc, trial, ch, half, ctx.mode)
		sse += ir_chroma_recon(enc, x, y, size, ch)
		ir_set_chroma_cbf(enc, x, y, size, ch.cbf_u[0] || ch.cbf_u[1], ch.cbf_v[0] || ch.cbf_v[1])
	} else if has_chroma(enc) {
		if depth == 0 || cbf_u_up do cabac_bin(trial, &trial.ctx.qt_cbf_model_chroma[depth], cbf_u ? 1 : 0)
		if depth == 0 || cbf_v_up do cabac_bin(trial, &trial.ctx.qt_cbf_model_chroma[depth], cbf_v ? 1 : 0)
	}
	end := cabac_rate(trial)

	node_bits := (before_children - start) + (end - after_children)
	return {cost = cost + enc.lambda * f64(node_bits), sse = sse, cbf_u = cbf_u, cbf_v = cbf_v}
}

// The intra tree may split down to 4x4 luma TUs, where DST-VII applies.
@(private)
ir_can_split :: #force_inline proc(log2_size, depth: int) -> bool {
	return log2_size > 2 && depth < RQT_MAX_HIER
}

@(private)
ir_search_node :: proc(
	enc: ^Encoder,
	ctx: Ir_Ctx,
	x, y, log2_size, depth: int,
	cbf_u_up, cbf_v_up: bool,
	trial: ^Cabac,
) -> Ir_Result {
	size := 1 << uint(log2_size)
	codable := tf_split_codable(log2_size, depth)
	can_split := ir_can_split(log2_size, depth)

	// An 8x8 node owns its chroma block: it is coded once whether the node is
	// a leaf or splits into 4x4 luma TUs, so it is prepared before both.
	ch: Ir_Chroma = ---
	own_chroma := log2_size == 3 && has_chroma(enc) && enc.config.chroma_format != .YUV_444
	if own_chroma {
		ir_chroma_prepare(
			enc,
			ctx,
			&ch,
			x,
			y,
			size,
			depth == 0 || cbf_u_up,
			depth == 0 || cbf_v_up,
		)
	}

	pre: Node_State = ---
	best: Node_State = ---
	best_res: Ir_Result
	best_cost := max(f64)

	save_node_size(enc, x, y, size, &pre)
	sse, cbf_u, cbf_v, bits := ir_recon_leaf(
		enc,
		ctx,
		x,
		y,
		size,
		depth,
		codable,
		cbf_u_up,
		cbf_v_up,
		own_chroma ? &ch : nil,
		trial,
		true,
	)
	best_cost = f64(sse) + enc.lambda * f64(bits)
	best_res = {
		cost  = best_cost,
		sse   = sse,
		cbf_u = cbf_u,
		cbf_v = cbf_v,
	}
	save_node_size(enc, x, y, size, &best)

	if can_split {
		restore_node_size(enc, x, y, size, &pre)
		r2 := ir_search_split(
			enc,
			ctx,
			x,
			y,
			log2_size,
			depth,
			cbf_u_up,
			cbf_v_up,
			codable,
			own_chroma ? &ch : nil,
			trial,
		)
		if r2.cost < best_cost {
			best_cost, best_res = r2.cost, r2
			save_node_size(enc, x, y, size, &best)
		}
	}

	restore_node_size(enc, x, y, size, &best)
	return best_res
}

// ---------------------------------------------------------------------------
// Bitstream replay
// ---------------------------------------------------------------------------

@(private)
ir_write_node :: proc(
	enc: ^Encoder,
	ctx: Ir_Ctx,
	x, y, log2_size, depth: int,
	cbf_u_up, cbf_v_up: bool,
	cabac: ^Cabac,
) {
	size := 1 << uint(log2_size)
	codable := tf_split_codable(log2_size, depth)
	split := int(cu_at(enc.cu, x, y).tr_depth) < log2_size

	if !split {
		ir_recon_leaf(enc, ctx, x, y, size, depth, codable, cbf_u_up, cbf_v_up, nil, cabac, false)
		return
	}

	half := size / 2
	if codable do cabac_bin(cabac, &cabac.ctx.trans_subdiv_model[5 - log2_size], 1)

	if log2_size == 3 && has_chroma(enc) && enc.config.chroma_format != .YUV_444 {
		// The node's 4x4 chroma block is coded once, with the fourth 4x4
		// child: its flags here, its coefficients after that child's luma.
		ch: Ir_Chroma = ---
		ir_chroma_prepare(
			enc,
			ctx,
			&ch,
			x,
			y,
			size,
			depth == 0 || cbf_u_up,
			depth == 0 || cbf_v_up,
		)
		ir_chroma_bins(enc, cabac, &ch, depth, depth == 0 || cbf_u_up, depth == 0 || cbf_v_up)
		for sub in 0 ..< 4 {
			cx := x + (sub & 1) * half
			cy := y + (sub >> 1) * half
			ir_write_node(enc, ctx, cx, cy, log2_size - 1, depth + 1, true, true, cabac)
		}
		ir_chroma_emit_coeffs(enc, cabac, &ch, half, ctx.mode)
		_ = ir_chroma_recon(enc, x, y, size, &ch)
		ir_set_chroma_cbf(enc, x, y, size, ch.cbf_u[0] || ch.cbf_u[1], ch.cbf_v[0] || ch.cbf_v[1])
		return
	}

	// A taller node's chroma blocks belong to its leaves; its own flags are
	// the OR over the region the search recorded.
	cbf_u := depth == 0 || cbf_u_up ? region_has_cbf_u(enc, x, y, size) : false
	cbf_v := depth == 0 || cbf_v_up ? region_has_cbf_v(enc, x, y, size) : false
	if has_chroma(enc) && (depth == 0 || cbf_u_up) do cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[depth], cbf_u ? 1 : 0)
	if has_chroma(enc) && (depth == 0 || cbf_v_up) do cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[depth], cbf_v ? 1 : 0)
	for sub in 0 ..< 4 {
		cx := x + (sub & 1) * half
		cy := y + (sub >> 1) * half
		ir_write_node(enc, ctx, cx, cy, log2_size - 1, depth + 1, cbf_u, cbf_v, cabac)
	}
}

// write_intra_rqt drives the intra transform tree for one CU. `search` selects
// the RD pass over the replay of the stored decisions.
write_intra_rqt :: proc(enc: ^Encoder, x, y: int, depth: u8, cabac: ^Cabac, search: bool) -> u64 {
	size := CTU_WIDTH >> depth
	mode := cu_at(enc.cu, x, y).mode

	if depth == MAX_CU_DEPTH {
		cabac_bin(cabac, &cabac.ctx.part_size_model[0], 1)
	}
	// pcm_flag: every 2Nx2N intra CU in the SPS PCM size range carries it.
	if enc.config.pcm do cabac_bin_trm(cabac, 0)
	write_intra_mode(enc, x, y, mode, cabac)
	// intra_chroma_pred_mode: always "derived from luma".
	if has_chroma(enc) do cabac_bin(cabac, &cabac.ctx.chroma_pred_model[0], 0)

	ctx := Ir_Ctx {
		mode = mode,
	}
	if search {
		r := ir_search_node(enc, ctx, x, y, log2_size(size), 0, false, false, cabac)
		return r.sse
	}
	ir_write_node(enc, ctx, x, y, log2_size(size), 0, false, false, cabac)
	return 0
}

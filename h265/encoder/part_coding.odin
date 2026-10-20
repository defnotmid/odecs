package h265_encoder

// ---------------------------------------------------------------------------
// Syntax and reconstruction of a partitioned inter CU. The order is the
// decoder's: part_mode, then per prediction unit its merge or AMVP syntax,
// then rqt_root_cbf and the transform tree. With max_transform_hierarchy_
// depth_inter == 0 a non-2Nx2N unit splits once into four quadrant TUs
// (7.3.8.8 inter_split); with the optional hierarchy it signals that same
// split explicitly so the bitstream stays valid.
// ---------------------------------------------------------------------------

// write_part_mode is the inverse of the decoder's decode_part_mode (Table
// 9-34 binarization and Table 9-37 contexts).
write_part_mode :: proc(cabac: ^Cabac, part: Part_Mode, log2_size: int) {
	min_cb := log2_size == 3

	if part == .P_2Nx2N {
		cabac_bin(cabac, &cabac.ctx.part_size_model[0], 1)
		return
	}
	cabac_bin(cabac, &cabac.ctx.part_size_model[0], 0)

	vertical := part == .P_2NxN || part == .P_2NxnU || part == .P_2NxnD
	cabac_bin(cabac, &cabac.ctx.part_size_model[1], vertical ? 1 : 0)

	if min_cb {
		// At the minimum CU size the third bin only separates NxN from Nx2N,
		// and its context is part_size_model[2]. Nx2N has no bin at all.
		if part == .P_NxN do cabac_bin(cabac, &cabac.ctx.part_size_model[2], 0)
		return
	}

	if part == .P_2NxN || part == .P_Nx2N {
		cabac_bin(cabac, &cabac.ctx.part_size_model[3], 1)
		return
	}

	cabac_bin(cabac, &cabac.ctx.part_size_model[3], 0)
	if part == .P_2NxnU || part == .P_nLx2N {
		cabac_bin_ep(cabac, 0)
	} else {
		cabac_bin_ep(cabac, 1)
	}
}

@(private)
write_pu_syntax_p :: proc(
	enc: ^Encoder,
	pux, puy, puw, puh: int,
	c: Pu_Context,
	pu: ^Cu_Info,
	cabac: ^Cabac,
) {
	cabac_bin(cabac, &cabac.ctx.cu_merge_flag_ext_model, pu.merge ? 1 : 0)
	if pu.merge {
		write_merge_idx(cabac, int(pu.merge_idx))
		return
	}

	ref := int(pu.ref_idx[0])
	if enc.refs_active[0] > 1 do write_ref_idx(cabac, ref, enc.refs_active[0])
	cands, avail := amvp_candidates_b(
		enc,
		pux,
		puy,
		puw,
		puh,
		0,
		c,
		enc.ref_poc[0][ref],
		enc.cur_poc,
	)
	cl := amvp_build_list(enc, pux, puy, puw, puh, 0, enc.ref_poc[0][ref], cands, avail)
	idx := int(pu.mv_cand)
	encode_mvd(cabac, i32(pu.mv[0][0]) - i32(cl[idx][0]), i32(pu.mv[0][1]) - i32(cl[idx][1]))
	cabac_unary_max_symbol(cabac, cabac.ctx.mvp_idx_model[:], u32(idx), 1, 1)
}

// write_pu_syntax_b is 7.3.8.6 for one B-slice prediction unit. An 8x4 or
// 4x8 unit omits the bi bin and is L0/L1 only (9.3.3.9).
@(private)
write_pu_syntax_b :: proc(
	enc: ^Encoder,
	pux, puy, puw, puh: int,
	depth: u8,
	c: Pu_Context,
	pu: ^Cu_Info,
	cabac: ^Cabac,
) {
	cabac_bin(cabac, &cabac.ctx.cu_merge_flag_ext_model, pu.merge ? 1 : 0)
	if pu.merge {
		write_merge_idx(cabac, int(pu.merge_idx))
		return
	}

	idc := pu.idc
	if puw + puh != 12 do cabac_bin(cabac, &cabac.ctx.inter_dir[depth], idc == PRED_BI ? 1 : 0)
	if idc != PRED_BI do cabac_bin(cabac, &cabac.ctx.inter_dir[4], idc == PRED_L1 ? 1 : 0)

	for l in 0 ..< 2 {
		if !pu.pred[l] do continue
		if enc.refs_active[l] > 1 do write_ref_idx(cabac, int(pu.ref_idx[l]), enc.refs_active[l])
		cands, avail := amvp_candidates_b(
			enc,
			pux,
			puy,
			puw,
			puh,
			l,
			c,
			enc.ref_poc[l][pu.ref_idx[l]],
			enc.cur_poc,
		)
		c := amvp_build_list(
			enc,
			pux,
			puy,
			puw,
			puh,
			l,
			enc.ref_poc[l][pu.ref_idx[l]],
			cands,
			avail,
		)
		idx := int(pu.mvp_flag[l])
		encode_mvd(cabac, i32(pu.mv[l][0]) - i32(c[idx][0]), i32(pu.mv[l][1]) - i32(c[idx][1]))
		cabac_unary_max_symbol(cabac, cabac.ctx.mvp_idx_model[:], u32(idx), 1, 1)
	}
}

// Encode one partitioned inter CU of a P slice and reconstruct it.
write_inter_part :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	cabac: ^Cabac,
	search, force_skip: bool,
) -> u64 {
	size := CTU_WIDTH >> depth
	part := cu_at(enc.cu, x, y).part
	write_part_mode(cabac, part, log2_size(size))

	q := size / 4
	for i in 0 ..< PART_COUNT[int(part)] {
		s := PART_SHAPE[int(part)][i]
		pux, puy := x + s[0] * q, y + s[1] * q
		puw, puh := s[2] * q, s[3] * q
		pu := cu_at(enc.cu, pux, puy)
		write_pu_syntax_p(enc, pux, puy, puw, puh, pu_context(x, y, size, part, q, i), pu, cabac)
		mark_pu_enc(enc, pux, puy, puw, puh)
	}

	sub_w, _ := chroma_sub(enc.config.chroma_format)
	pred_y: [32 * 32]Sample = ---
	pred_u: [32 * 32]Sample = ---
	pred_v: [32 * 32]Sample = ---
	p := Cu_Pred {
		y        = pred_y[:],
		u        = pred_u[:],
		v        = pred_v[:],
		y_stride = size,
		c_stride = size / sub_w,
		cu_x     = x,
		cu_y     = y,
	}
	part_predict_cu(enc, x, y, size, part, p)

	return write_inter_part_residual(RQT, enc, x, y, size, p, cabac, force_skip)
}

// Encode one partitioned inter CU of a B slice and reconstruct it.
write_inter_part_b :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	cabac: ^Cabac,
	search, force_skip: bool,
) -> u64 {
	size := CTU_WIDTH >> depth
	part := cu_at(enc.cu, x, y).part
	write_part_mode(cabac, part, log2_size(size))

	q := size / 4
	for i in 0 ..< PART_COUNT[int(part)] {
		s := PART_SHAPE[int(part)][i]
		pux, puy := x + s[0] * q, y + s[1] * q
		puw, puh := s[2] * q, s[3] * q
		pu := cu_at(enc.cu, pux, puy)
		write_pu_syntax_b(
			enc,
			pux,
			puy,
			puw,
			puh,
			depth,
			pu_context(x, y, size, part, q, i),
			pu,
			cabac,
		)
		mark_pu_enc(enc, pux, puy, puw, puh)
	}

	sub_w, _ := chroma_sub(enc.config.chroma_format)
	pred_y: [32 * 32]Sample = ---
	pred_u: [32 * 32]Sample = ---
	pred_v: [32 * 32]Sample = ---
	p := Cu_Pred {
		y        = pred_y[:],
		u        = pred_u[:],
		v        = pred_v[:],
		y_stride = size,
		c_stride = size / sub_w,
		cu_x     = x,
		cu_y     = y,
	}
	part_predict_cu(enc, x, y, size, part, p)

	return write_inter_part_residual(RQT, enc, x, y, size, p, cabac, force_skip)
}

// part_prepare_chroma_cu codes the single CU-sized chroma transform block of
// an 8x8 partitioned unit, which the decoder's transform_unit handles as its
// blk_idx == 3 special case.
@(private)
part_prepare_chroma_cu :: proc(enc: ^Encoder, ctx: Tf_Ctx, x, y, size: int, leaf: ^Tf_Leaf) {
	s := size / 2
	qp_c := chroma_qp_scaled(enc)
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	cx, cy := x / sub_w, y / sub_h
	cw := ctx.cu_size / 2
	n_chroma := chroma_blocks(enc.config.chroma_format)

	for t in 0 ..< n_chroma {
		for j in 0 ..< s {
			for i in 0 ..< s {
				leaf.tmp[j * s + i] = i16(
					i32(at(enc.source.u, cx + i, cy + t * s + j)) -
					i32(ctx.pred_u[(t * s + j) * cw + i]),
				)
			}
		}
		forward_transform(enc, s, leaf.tmp[:], s, leaf.coeff[:], enc.bit_depth)
		leaf.cbf_u[t] = enc_quantize(enc, leaf.coeff[:], leaf.q_u[t][:], s, .Cb, false, int(qp_c))

		for j in 0 ..< s {
			for i in 0 ..< s {
				leaf.tmp[j * s + i] = i16(
					i32(at(enc.source.v, cx + i, cy + t * s + j)) -
					i32(ctx.pred_v[(t * s + j) * cw + i]),
				)
			}
		}
		forward_transform(enc, s, leaf.tmp[:], s, leaf.coeff[:], enc.bit_depth)
		leaf.cbf_v[t] = enc_quantize(enc, leaf.coeff[:], leaf.q_v[t][:], s, .Cr, false, int(qp_c))
	}
}

// write_inter_part_residual codes rqt_root_cbf and the forced one-level
// transform tree of a partitioned CU, then reconstructs it. `force_skip`
// writes the zero residual form the all-merge candidate was ranked with.
@(private)
write_inter_part_residual :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y, size: int,
	p: Cu_Pred,
	cabac: ^Cabac,
	force_skip: bool,
) -> u64 {
	ctx := Tf_Ctx {
		cu_x    = x,
		cu_y    = y,
		cu_size = size,
		pred_y  = p.y,
		pred_u  = p.u,
		pred_v  = p.v,
	}
	parent_chroma := has_chroma(enc) && size == 8 && enc.config.chroma_format != .YUV_444
	half := size / 2
	half_log2 := log2_size(half)

	leaves: [4]Tf_Leaf = ---
	chroma_leaf: Tf_Leaf = ---
	root_cb, root_cr: [2]bool
	cbf_any := false

	if !force_skip {
		for i in 0 ..< 4 {
			qx := x + (i & 1) * half
			qy := y + (i >> 1) * half
			if parent_chroma {
				tf_leaf_prepare(enc, ctx, &leaves[i], qx, qy, half, 1, false, false)
			} else {
				tf_leaf_prepare(enc, ctx, &leaves[i], qx, qy, half, 1, true, true)
				for t in 0 ..< 2 {
					root_cb[t] = root_cb[t] || leaves[i].cbf_u[t]
					root_cr[t] = root_cr[t] || leaves[i].cbf_v[t]
				}
			}
			cbf_any = cbf_any || leaves[i].cbf_y
		}
		if parent_chroma {
			part_prepare_chroma_cu(enc, ctx, x, y, size, &chroma_leaf)
			root_cb, root_cr = chroma_leaf.cbf_u, chroma_leaf.cbf_v
		}
		cbf_any = cbf_any || root_cb[0] || root_cb[1] || root_cr[0] || root_cr[1]
	}

	// rqt_root_cbf is present for every non-2Nx2N part mode.
	cabac_bin(cabac, &cabac.ctx.cu_qt_root_cbf_model, cbf_any ? 1 : 0)
	if !cbf_any do return tf_recon_prediction(enc, ctx, x, y, size)

	if RQT do cabac_bin(cabac, &cabac.ctx.trans_subdiv_model[5 - log2_size(size)], 1)
	n_chroma := chroma_blocks(enc.config.chroma_format)
	if parent_chroma {
		// The 8x8 node's chroma pair: both cbf of a component beside each
		// other (7.3.8.8's second at log2_size == 3).
		for t in 0 ..< n_chroma {
			cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[0], root_cb[t] ? 1 : 0)
		}
		for t in 0 ..< n_chroma {
			cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[0], root_cr[t] ? 1 : 0)
		}
	} else if has_chroma(enc) {
		cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[0], root_cb[0] || root_cb[1] ? 1 : 0)
		cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[0], root_cr[0] || root_cr[1] ? 1 : 0)
	}

	// Subsampled chroma at an 8x8 CU is coded with the last luma quadrant.
	// At 4:4:4 each 4x4 quadrant has its own chroma flags and coefficients.
	child_cb := (root_cb[0] || root_cb[1]) && !parent_chroma
	child_cr := (root_cr[0] || root_cr[1]) && !parent_chroma
	for i in 0 ..< 4 {
		if RQT && half > 4 do cabac_bin(cabac, &cabac.ctx.trans_subdiv_model[5 - half_log2], 0)
		tf_leaf_emit(
			cabac,
			&leaves[i],
			half,
			1,
			child_cb,
			child_cr,
			n_chroma,
			half / (enc.config.chroma_format == Chroma_Layout.YUV_444 ? 1 : 2),
		)
		if parent_chroma && i == 3 {
			for t in 0 ..< n_chroma {
				if chroma_leaf.cbf_u[t] do encode_coeff_nxn(cabac, chroma_leaf.q_u[t][:half * half], half, 1, .Diag)
			}
			for t in 0 ..< n_chroma {
				if chroma_leaf.cbf_v[t] do encode_coeff_nxn(cabac, chroma_leaf.q_v[t][:half * half], half, 2, .Diag)
			}
		}
	}

	sse: u64
	for i in 0 ..< 4 {
		qx := x + (i & 1) * half
		qy := y + (i >> 1) * half
		sse += tf_leaf_recon(enc, ctx, qx, qy, half, &leaves[i])
	}
	if parent_chroma {
		qp_c := chroma_qp_scaled(enc)
		cw := size / 2
		sub_w, sub_h := chroma_sub(enc.config.chroma_format)
		for t in 0 ..< n_chroma {
			tf_recon_plane(
				enc,
				enc.rec.u,
				enc.source.u,
				x / sub_w,
				y / sub_h + t * cw,
				cw,
				chroma_leaf.q_u[t][:],
				chroma_leaf.tmp[:],
				ctx.pred_u,
				ctx.cu_size / 2,
				0,
				t * cw,
				chroma_leaf.cbf_u[t],
				.Cb,
				qp_c,
				&sse,
			)
			tf_recon_plane(
				enc,
				enc.rec.v,
				enc.source.v,
				x / sub_w,
				y / sub_h + t * cw,
				cw,
				chroma_leaf.q_v[t][:],
				chroma_leaf.tmp[:],
				ctx.pred_v,
				ctx.cu_size / 2,
				0,
				t * cw,
				chroma_leaf.cbf_v[t],
				.Cr,
				qp_c,
				&sse,
			)
		}
	}

	return sse
}

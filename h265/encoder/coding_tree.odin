package h265_encoder

import "base:intrinsics"

import common "../../common"

// ---------------------------------------------------------------------------
// Leaf encoding: part mode, intra modes, chroma mode, coded block flags,
// coefficients and reconstruction.
// ---------------------------------------------------------------------------

// Record the coded block flags computed by a leaf so deblocking sees them.
@(private)
set_cbf_flags :: proc(enc: ^Encoder, x, y, width: int, cbf_y, cbf_u, cbf_v: bool) {
	// The flags belong to 4x4 cells. Traverse those cells directly instead
	// of visiting sixteen pixel positions for every record we update.
	left, right := (x + 3) >> 2, (x + width + 3) >> 2
	top, bottom := (y + 3) >> 2, (y + width + 3) >> 2
	for cy in top ..< bottom {
		row := enc.cu.cells[cy * enc.cu.cols + left:cy * enc.cu.cols + right]
		for &cell in row {
			cell.cbf_y = cbf_y
			cell.cbf_u = cbf_u
			cell.cbf_v = cbf_v
		}
	}
}

fill_cu_info :: #force_inline proc(enc: ^Encoder, x, y, width: int, info_in: Cu_Info) {
	info := info_in
	// A list the CU does not use has no reference index; the decoder normalises
	// its motion records to -1 the same way, and merge pruning compares them.
	if !info.pred[0] do info.ref_idx[0] = -1
	if !info.pred[1] do info.ref_idx[1] = -1
	left, right := (x + 3) >> 2, (x + width + 3) >> 2
	top, bottom := (y + 3) >> 2, (y + width + 3) >> 2
	for cy in top ..< bottom {
		row := enc.cu.cells[cy * enc.cu.cols + left:cy * enc.cu.cols + right]
		for &cell in row {
			cell = info
		}
	}
}

// Split flag context: count left/above neighbours split at this depth.
write_split_flag :: proc(enc: ^Encoder, x, y: int, depth: u8, cabac: ^Cabac, split: bool) {
	model := 0
	if x > 0 && same_tile(enc, x, y, x - 1, y) && cu_at(enc.cu, x - 1, y).depth > depth do model += 1
	if y > 0 && same_tile(enc, x, y, x, y - 1) && cu_at(enc.cu, x, y - 1).depth > depth do model += 1
	cabac_bin(cabac, &cabac.ctx.split_flag_model[model], split ? 1 : 0)
}

// prev_intra_luma_pred_flag / mpm_idx / rem_intra_luma_pred_mode.
write_intra_mode :: proc(enc: ^Encoder, x, y: int, mode: u8, cabac: ^Cabac) {
	preds: [3]u8
	get_mpm_predictors(enc, x, y, &preds)

	mpm := -1
	for p, i in preds {
		if p == mode {
			mpm = i
			break
		}
	}

	cabac_bin(cabac, &cabac.ctx.intra_mode_model, mpm >= 0 ? 1 : 0)
	if mpm >= 0 {
		cabac_bin_ep(cabac, mpm == 0 ? 0 : 1)
		if mpm != 0 do cabac_bin_ep(cabac, mpm == 1 ? 0 : 1)
	} else {
		// Sort the prediction list and renumber the signalled mode.
		if preds[0] > preds[1] do preds[0], preds[1] = preds[1], preds[0]
		if preds[0] > preds[2] do preds[0], preds[2] = preds[2], preds[0]
		if preds[1] > preds[2] do preds[1], preds[2] = preds[2], preds[1]
		tmp := int(mode)
		for i := 2; i >= 0; i -= 1 {
			if tmp > int(preds[i]) do tmp -= 1
		}
		cabac_bins_ep(cabac, u32(tmp), 5)
	}
}

// Evaluate one luma intra mode against the source and fold the result into
// the running best. `tried` keeps the mode from being predicted twice.
Intra_Search_Inputs :: struct {
	refs:            Intra_Refs,
	source:          []Sample,
	source_stride:   int,
	transposed:      [32 * 32]Sample,
	transpose_ready: bool,
}

@(private)
prepare_intra_search :: proc(enc: ^Encoder, x, y, size: int, inputs: ^Intra_Search_Inputs) {
	plane := enc.source.y
	start := plane.offset + y * plane.stride + x
	inputs.source = plane.data[start:start + (size - 1) * plane.stride + size]
	inputs.source_stride = plane.stride
	inputs.transpose_ready = false
	build_reference(enc, &enc.rec, x, y, log2_size(size), .Y, &inputs.refs, enc.bit_depth)
}

// Horizontal angular trials operate in the predictor's original row order.
// Prepare the corresponding source orientation once, using the same native
// register transpose as publication but distinct caller-owned destination.
@(private)
transpose_intra_source :: proc(
	source: []Sample,
	source_stride, size: int,
	dst: []Sample,
) #no_bounds_check {
	Row :: #simd[4]u16
	for row := 0; row < size; row += 4 {
		for col := 0; col < size; col += 4 {
			a := intrinsics.unaligned_load((^Row)(&source[row * source_stride + col]))
			b := intrinsics.unaligned_load((^Row)(&source[(row + 1) * source_stride + col]))
			c := intrinsics.unaligned_load((^Row)(&source[(row + 2) * source_stride + col]))
			d := intrinsics.unaligned_load((^Row)(&source[(row + 3) * source_stride + col]))
			t := common.transpose([4]Row{a, b, c, d})
			a, b, c, d = t[0], t[1], t[2], t[3]
			intrinsics.unaligned_store((^Row)(&dst[col * size + row]), a)
			intrinsics.unaligned_store((^Row)(&dst[(col + 1) * size + row]), b)
			intrinsics.unaligned_store((^Row)(&dst[(col + 2) * size + row]), c)
			intrinsics.unaligned_store((^Row)(&dst[(col + 3) * size + row]), d)
		}
	}
}

@(private)
try_intra_mode :: #force_inline proc(
	enc: ^Encoder,
	size: int,
	mode: u8,
	inputs: ^Intra_Search_Inputs,
	tried: ^[35]bool,
	best_mode: ^u8,
	best_cost: ^u64,
) #no_bounds_check {
	if tried[int(mode)] do return
	tried[int(mode)] = true
	source := inputs.source
	source_stride := inputs.source_stride
	if mode >= 2 && mode < 18 {
		if !inputs.transpose_ready {
			transpose_intra_source(
				inputs.source,
				inputs.source_stride,
				size,
				inputs.transposed[:size * size],
			)
			inputs.transpose_ready = true
		}
		source = inputs.transposed[:size * size]
		source_stride = size
	}
	cost := intra_measure(
		&inputs.refs,
		log2_size(size),
		mode,
		.Y,
		source,
		source_stride,
		enc.bit_depth,
	)
	if cost < best_cost^ {
		best_cost^ = cost
		best_mode^ = mode
	}
}

// The chosen luma mode and the SSD of its prediction against the source.
Intra_Mode :: struct {
	mode: u8,
	sse:  u64,
}

// Pick the luma intra mode with the lowest SSD against the source. MPMs,
// planar/DC and an evenly spaced angular sweep are evaluated first; the search
// then narrows around the best mode so the full 35-mode cost is only paid for
// 8x8 blocks, where a prediction is cheap.
choose_intra_mode :: #force_inline proc(
	enc: ^Encoder,
	x, y, size: int,
	inputs: ^Intra_Search_Inputs,
) -> Intra_Mode #no_bounds_check {
	prepare_intra_search(enc, x, y, size, inputs)

	if enc.config.forced_mode >= 0 do return {mode = u8(enc.config.forced_mode), sse = 0}

	best_mode: u8
	best_cost := max(u64)
	tried: [35]bool

	if size <= 8 {
		for m in 0 ..= 34 {
			try_intra_mode(enc, size, u8(m), inputs, &tried, &best_mode, &best_cost)
		}
		return {mode = best_mode, sse = best_cost}
	}

	preds: [3]u8
	get_mpm_predictors(enc, x, y, &preds)
	for p in preds {
		try_intra_mode(enc, size, p, inputs, &tried, &best_mode, &best_cost)
	}
	try_intra_mode(enc, size, 0, inputs, &tried, &best_mode, &best_cost)
	try_intra_mode(enc, size, 1, inputs, &tried, &best_mode, &best_cost)

	for m in 2 ..= 34 {
		if (m - 2) % 8 != 0 do continue
		try_intra_mode(enc, size, u8(m), inputs, &tried, &best_mode, &best_cost)
	}

	// Narrow the angular search around the best mode found so far.
	for step in ([3]u8{4, 2, 1}) {
		center := i32(best_mode)
		if center < 2 do break
		for delta in ([2]i32{-i32(step), i32(step)}) {
			m := center + delta
			if m < 2 || m > 34 do continue
			try_intra_mode(enc, size, u8(m), inputs, &tried, &best_mode, &best_cost)
		}
	}
	return {mode = best_mode, sse = best_cost}
}

// Reconstruct one plane. `pred` holds the prediction; on return `dst` holds
// prediction plus residual. `tmp` is scratch of size*size.
@(private)
recon_plane :: proc(
	enc: ^Encoder,
	dst: Plane(Sample),
	src: Plane(Sample),
	x, y, size: int,
	q: []i16,
	tmp: []i16,
	pred: []Sample,
	cbf: bool,
	kind: Sl_Kind,
	intra: bool,
	qp: i32,
	sse: ^u64,
) #no_bounds_check {
	if cbf {
		enc_dequantize(enc, q, tmp, size, kind, intra, int(qp))
		inverse_transform(size, tmp, q, enc.bit_depth)
	}
	recon_plane_vec(dst, src, x, y, size, q, pred, size, 0, 0, cbf, enc.bit_depth, sse)
}

// Write the skip flag and prediction mode of a CU (P/B slices only).
write_cu_header :: proc(enc: ^Encoder, x, y: int, cabac: ^Cabac) {
	if enc.slice_type == .I do return
	cu := cu_at(enc.cu, x, y)
	skip_model := 0
	if x > 0 && same_tile(enc, x, y, x - 1, y) && cu_at(enc.cu, x - 1, y).skipped do skip_model += 1
	if y > 0 && same_tile(enc, x, y, x, y - 1) && cu_at(enc.cu, x, y - 1).skipped do skip_model += 1
	cabac_bin(cabac, &cabac.ctx.cu_skip_flag_model[skip_model], cu.skipped ? 1 : 0)
	if !cu.skipped {
		cabac_bin(cabac, &cabac.ctx.cu_pred_mode_model, cu.type == .Inter ? 0 : 1)
	}
}

// Encode one leaf CU and reconstruct it. Returns the SSE of the CU.
// `search` selects the inter transform tree's RD pass (trial CABAC) over the
// replay of the stored decisions (bitstream pass). `RQT` is compile-time so
// the non-RQT instantiation is exactly the pre-RQT leaf code.
write_leaf :: proc(
	$RQT: bool,
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	cabac: ^Cabac,
	search: bool,
	intra_refs: ^Intra_Refs = nil,
) -> u64 {
	size := CTU_WIDTH >> depth
	write_cu_header(enc, x, y, cabac)
	cu := cu_at(enc.cu, x, y)

	if cu.pcm && enc.config.pcm {
		return write_intra_pcm(enc, x, y, depth, cabac)
	}

	if cu.type == .Inter && cu.part != .P_2Nx2N {
		if enc.slice_type == .B do return write_inter_part_b(RQT, enc, x, y, depth, cabac, search, cu.part_skip)
		return write_inter_part(RQT, enc, x, y, depth, cabac, search, cu.part_skip)
	}

	// The intra transform tree is its own opt-in path; with it off the intra
	// leaf code below is exactly the pre-RQT one.
	if cu.type == .Intra && enc.config.intra_rqt {
		return write_intra_rqt(enc, x, y, depth, cabac, search)
	}

	when RQT {
		mark_tu_enc(enc, x, y, size)
		if cu.type == .Inter {
			if enc.slice_type == .B do return write_inter_leaf_b_rqt(enc, x, y, depth, cabac, search)
			return write_inter_leaf_rqt(enc, x, y, depth, cabac, search)
		}
		return write_intra_leaf(enc, x, y, depth, cabac, intra_refs)
	} else {
		// With partitions or the intra transform tree on, every residual-less
		// CU (skip, rqt_root_cbf 0, intra) still carries the decoder's
		// CU-boundary transform marks.
		if enc.config.amp || enc.config.intra_rqt do mark_tu_enc(enc, x, y, size)
		if cu.type == .Inter {
			if enc.slice_type == .B do return write_inter_leaf_b(enc, x, y, depth, cabac)
			return write_inter_leaf(enc, x, y, depth, cabac)
		}
		return write_intra_leaf(enc, x, y, depth, cabac, intra_refs)
	}
}

// 8.7.2.2: the first column and first row of a transform block carry the edge
// flags deblocking reads; the rest of the block is interior.
mark_tu_enc :: proc(enc: ^Encoder, x, y, size: int) #no_bounds_check {
	span := size >> 2
	base := (y >> 2) * enc.cu.cols + (x >> 2)
	for i in 0 ..< span {
		enc.cu.cells[base + i].tu_h = true
	}
	for j in 0 ..< span {
		enc.cu.cells[base + j * enc.cu.cols].tu_v = true
	}
}

// Record the leaf transform size of an inter transform block on the per-4x4
// CU cells so the bitstream pass can replay the split decisions.
set_tr_log2 :: proc(enc: ^Encoder, x, y, size, log2: int) #no_bounds_check {
	span := size >> 2
	base := (y >> 2) * enc.cu.cols + (x >> 2)
	for j in 0 ..< span {
		for i in 0 ..< span do enc.cu.cells[base + j * enc.cu.cols + i].tr_depth = u8(log2)
	}
}

// Motion vector difference syntax (kvz_encode_mvd).
encode_mvd :: proc(cabac: ^Cabac, mvd_x, mvd_y: i32) {
	hor0 := mvd_x != 0
	ver0 := mvd_y != 0
	cabac_bin(cabac, &cabac.ctx.cu_mvd_model[0], hor0 ? 1 : 0)
	cabac_bin(cabac, &cabac.ctx.cu_mvd_model[0], ver0 ? 1 : 0)
	if hor0 do cabac_bin(cabac, &cabac.ctx.cu_mvd_model[1], abs(mvd_x) > 1 ? 1 : 0)
	if ver0 do cabac_bin(cabac, &cabac.ctx.cu_mvd_model[1], abs(mvd_y) > 1 ? 1 : 0)
	if hor0 {
		if abs(mvd_x) > 1 do cabac_ep_ex_golomb(cabac, u32(abs(mvd_x) - 2), 1)
		cabac_bin_ep(cabac, mvd_x > 0 ? 0 : 1)
	}
	if ver0 {
		if abs(mvd_y) > 1 do cabac_ep_ex_golomb(cabac, u32(abs(mvd_y) - 2), 1)
		cabac_bin_ep(cabac, mvd_y > 0 ? 0 : 1)
	}
}

// ref_idx_lX (9.3.3.8): truncated unary, the first two bins using the shared
// ref_idx context bank and the rest bypass. The decoder reads L0 and L1 through
// the same bank (ff_hevc_ref_idx_lx_decode), so both lists write here.
@(private)
write_ref_idx :: proc(cabac: ^Cabac, ref: int, num_active: int) {
	max := num_active - 1
	v := 0
	for v < ref {
		if v < 2 {
			cabac_bin(cabac, &cabac.ctx.cu_ref_pic_model[v], 1)
		} else {
			cabac_bin_ep(cabac, 1)
		}
		v += 1
	}
	if v < max {
		if v < 2 {
			cabac_bin(cabac, &cabac.ctx.cu_ref_pic_model[v], 0)
		} else {
			cabac_bin_ep(cabac, 0)
		}
	}
}

// Write the merge index as the truncated unary code of 7.3.8.6: the first bin
// uses its own context, the rest are bypass.
@(private)
write_merge_idx :: proc(cabac: ^Cabac, idx: int) {
	for i in 0 ..< idx {
		if i == 0 {
			cabac_bin(cabac, &cabac.ctx.cu_merge_idx_ext_model, 1)
		} else {
			cabac_bin_ep(cabac, 1)
		}
	}
	if idx < MERGE_MAX_CAND - 1 {
		if idx == 0 {
			cabac_bin(cabac, &cabac.ctx.cu_merge_idx_ext_model, 0)
		} else {
			cabac_bin_ep(cabac, 0)
		}
	}
}

// Prediction-only reconstruction shares the residual reconstruction kernel.
// The prediction is already clipped; no residual storage is needed.
@(private)
reconstruct_prediction_planes :: proc(
	enc: ^Encoder,
	x, y, size: int,
	pred_y, pred_u, pred_v: []Sample,
) -> u64 {
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	csize := size / sub_w
	sse: u64
	recon_plane_vec(
		enc.rec.y,
		enc.source.y,
		x,
		y,
		size,
		nil,
		pred_y,
		size,
		0,
		0,
		false,
		enc.bit_depth,
		&sse,
	)
	if has_chroma(enc) {
		for t in 0 ..< chroma_blocks(enc.config.chroma_format) {
			cy := y / sub_h + t * csize
			blk := t * csize * csize
			recon_plane_vec(
				enc.rec.u,
				enc.source.u,
				x / sub_w,
				cy,
				csize,
				nil,
				pred_u[blk:],
				csize,
				0,
				0,
				false,
				enc.bit_depth,
				&sse,
			)
			recon_plane_vec(
				enc.rec.v,
				enc.source.v,
				x / sub_w,
				cy,
				csize,
				nil,
				pred_v[blk:],
				csize,
				0,
				0,
				false,
				enc.bit_depth,
				&sse,
			)
		}
	}
	set_cbf_flags(enc, x, y, size, false, false, false)
	return sse
}

// Reconstruct a prediction-only (skip) CU: the merged prediction is the
// reconstruction, no residual is coded. Returns the SSE.
@(private)
reconstruct_prediction :: #force_inline proc(
	enc: ^Encoder,
	x, y, size: int,
	mv: [2]i16,
	ref: int,
) -> u64 {
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	csize := size / sub_w
	pred_y: [32 * 32]Sample = ---
	pred_u: [2 * 32 * 32]Sample = ---
	pred_v: [2 * 32 * 32]Sample = ---
	frame_cw, frame_ch := enc.coded_width / sub_w, enc.coded_height / sub_h

	mc_luma_uni_w(
		pred_y[:],
		size,
		&enc.refs[0][ref],
		x,
		y,
		size,
		size,
		mv,
		wp_luma(enc, 0, ref),
		enc.bit_depth,
	)
	if has_chroma(enc) {
		mv_c := chroma_mv(enc.config.chroma_format, mv)
		n_chroma := chroma_blocks(enc.config.chroma_format)
		for t in 0 ..< n_chroma {
			cy := y / sub_h + t * csize
			blk := t * csize * csize
			mc_chroma_uni_w(
				pred_u[blk:],
				csize,
				enc.refs[0][ref].u,
				x / sub_w,
				cy,
				csize,
				csize,
				mv_c,
				frame_cw,
				frame_ch,
				wp_chroma(enc, 0, ref, 0),
				enc.bit_depth,
			)
			mc_chroma_uni_w(
				pred_v[blk:],
				csize,
				enc.refs[0][ref].v,
				x / sub_w,
				cy,
				csize,
				csize,
				mv_c,
				frame_cw,
				frame_ch,
				wp_chroma(enc, 0, ref, 1),
				enc.bit_depth,
			)
		}
	}

	return reconstruct_prediction_planes(enc, x, y, size, pred_y[:], pred_u[:], pred_v[:])
}

// Materialise a B-slice prediction into `pred_y`/`pred_u`/`pred_v`, averaging
// the two lists with the decoder's default bi-prediction when both are used.
// Each list reads the reference named by its own reference index.
// Interpolation fills each temporary square before the weighted combine reads it.
inter_predict_b :: proc(
	enc: ^Encoder,
	x, y, size: int,
	pred: [2]bool,
	mv: [2][2]i16,
	ref_idx: [2]i8,
	pred_y, pred_u, pred_v: []Sample,
) {
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	csize := size / sub_w
	frame_cw, frame_ch := enc.coded_width / sub_w, enc.coded_height / sub_h

	if pred[0] && pred[1] {
		r0, r1 := &enc.refs[0][ref_idx[0]], &enc.refs[1][ref_idx[1]]
		wp0 := wp_luma(enc, 0, int(ref_idx[0]))
		wp1 := wp_luma(enc, 1, int(ref_idx[1]))
		a_y: [32 * 32]i16 = ---
		b_y: [32 * 32]i16 = ---
		mc_luma_i16(a_y[:], size, r0, x, y, size, size, mv[0][0], mv[0][1], enc.bit_depth)
		mc_luma_i16(b_y[:], size, r1, x, y, size, size, mv[1][0], mv[1][1], enc.bit_depth)
		pred_bi_w(pred_y, size, a_y[:], b_y[:], size, size, size, wp0, wp1)

		if has_chroma(enc) {
			mv0 := chroma_mv(enc.config.chroma_format, mv[0])
			mv1 := chroma_mv(enc.config.chroma_format, mv[1])
			n_chroma := chroma_blocks(enc.config.chroma_format)
			blk := csize * csize
			a_u: [32 * 32]i16 = ---
			b_u: [32 * 32]i16 = ---
			a_v: [32 * 32]i16 = ---
			b_v: [32 * 32]i16 = ---
			for t in 0 ..< n_chroma {
				cy := y / sub_h + t * csize
				mc_chroma_i16(
					a_u[:],
					csize,
					r0.u,
					x / sub_w,
					cy,
					csize,
					csize,
					mv0[0],
					mv0[1],
					frame_cw,
					frame_ch,
					enc.bit_depth,
				)
				mc_chroma_i16(
					b_u[:],
					csize,
					r1.u,
					x / sub_w,
					cy,
					csize,
					csize,
					mv1[0],
					mv1[1],
					frame_cw,
					frame_ch,
					enc.bit_depth,
				)
				mc_chroma_i16(
					a_v[:],
					csize,
					r0.v,
					x / sub_w,
					cy,
					csize,
					csize,
					mv0[0],
					mv0[1],
					frame_cw,
					frame_ch,
					enc.bit_depth,
				)
				mc_chroma_i16(
					b_v[:],
					csize,
					r1.v,
					x / sub_w,
					cy,
					csize,
					csize,
					mv1[0],
					mv1[1],
					frame_cw,
					frame_ch,
					enc.bit_depth,
				)
				pred_bi_w(
					pred_u[t * blk:],
					csize,
					a_u[:],
					b_u[:],
					csize,
					csize,
					csize,
					wp_chroma(enc, 0, int(ref_idx[0]), 0),
					wp_chroma(enc, 1, int(ref_idx[1]), 0),
				)
				pred_bi_w(
					pred_v[t * blk:],
					csize,
					a_v[:],
					b_v[:],
					csize,
					csize,
					csize,
					wp_chroma(enc, 0, int(ref_idx[0]), 1),
					wp_chroma(enc, 1, int(ref_idx[1]), 1),
				)
			}
		}
		return
	}

	l := pred[0] ? 0 : 1
	ref := &enc.refs[l][ref_idx[l]]
	wp := wp_luma(enc, l, int(ref_idx[l]))
	yy: [32 * 32]i16 = ---
	mc_luma_i16(yy[:], size, ref, x, y, size, size, mv[l][0], mv[l][1], enc.bit_depth)
	pred_uni_w(pred_y, size, yy[:], size, size, size, wp)

	if has_chroma(enc) {
		mvc := chroma_mv(enc.config.chroma_format, mv[l])
		n_chroma := chroma_blocks(enc.config.chroma_format)
		blk := csize * csize
		uu: [32 * 32]i16 = ---
		vv: [32 * 32]i16 = ---
		for t in 0 ..< n_chroma {
			cy := y / sub_h + t * csize
			mc_chroma_i16(
				uu[:],
				csize,
				ref.u,
				x / sub_w,
				cy,
				csize,
				csize,
				mvc[0],
				mvc[1],
				frame_cw,
				frame_ch,
				enc.bit_depth,
			)
			mc_chroma_i16(
				vv[:],
				csize,
				ref.v,
				x / sub_w,
				cy,
				csize,
				csize,
				mvc[0],
				mvc[1],
				frame_cw,
				frame_ch,
				enc.bit_depth,
			)
			pred_uni_w(
				pred_u[t * blk:],
				csize,
				uu[:],
				csize,
				csize,
				csize,
				wp_chroma(enc, l, int(ref_idx[l]), 0),
			)
			pred_uni_w(
				pred_v[t * blk:],
				csize,
				vv[:],
				csize,
				csize,
				csize,
				wp_chroma(enc, l, int(ref_idx[l]), 1),
			)
		}
	}
}

// Reconstruct a prediction-only (skip) B CU: the merged prediction is the
// reconstruction, no residual is coded. Returns the SSE.
@(private)
reconstruct_prediction_b :: #force_inline proc(
	enc: ^Encoder,
	x, y, size: int,
	pred: [2]bool,
	mv: [2][2]i16,
	ref_idx: [2]i8,
) -> u64 {
	pred_y: [32 * 32]Sample = ---
	pred_u: [2 * 32 * 32]Sample = ---
	pred_v: [2 * 32 * 32]Sample = ---
	inter_predict_b(enc, x, y, size, pred, mv, ref_idx, pred_y[:], pred_u[:], pred_v[:])

	return reconstruct_prediction_planes(enc, x, y, size, pred_y[:], pred_u[:], pred_v[:])
}

// Encode one inter leaf CU (2Nx2N, single reference list) and reconstruct it.
// `cu.skipped` selects the inferred-merge, no-residual form; `cu.merge` the
// merge form (merge index, no MVD, rqt_root_cbf inferred to one); otherwise
// AMVP with an explicit MVD.
write_inter_leaf :: proc(enc: ^Encoder, x, y: int, depth: u8, cabac: ^Cabac) -> u64 {
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	size := CTU_WIDTH >> depth
	cu := cu_at(enc.cu, x, y)
	mv := cu.mv[0]

	if cu.skipped {
		write_merge_idx(cabac, int(cu.merge_idx))
		return reconstruct_prediction(enc, x, y, size, mv, int(cu.ref_idx[0]))
	}

	ref := int(cu.ref_idx[0])

	// part_mode: 2Nx2N for inter CUs at every depth.
	cabac_bin(cabac, &cabac.ctx.part_size_model[0], 1)
	cabac_bin(cabac, &cabac.ctx.cu_merge_flag_ext_model, cu.merge ? 1 : 0)

	if cu.merge {
		write_merge_idx(cabac, int(cu.merge_idx))
	} else {
		if enc.refs_active[0] > 1 do write_ref_idx(cabac, ref, enc.refs_active[0])
		ctx := Pu_Context {
			cu_x    = x,
			cu_y    = y,
			cu_size = size,
			pu_w    = size,
			pu_h    = size,
		}
		cands, avail := amvp_candidates_b(
			enc,
			x,
			y,
			size,
			size,
			0,
			ctx,
			enc.ref_poc[0][ref],
			enc.cur_poc,
		)
		c := amvp_build_list(enc, x, y, size, size, 0, enc.ref_poc[0][ref], cands, avail)
		idx := int(cu.mv_cand)
		mvd_x := i32(mv[0]) - i32(c[idx][0])
		mvd_y := i32(mv[1]) - i32(c[idx][1])
		encode_mvd(cabac, mvd_x, mvd_y)
		cabac_unary_max_symbol(cabac, cabac.ctx.mvp_idx_model[:], u32(idx), 1, 1)
	}

	// --- Prediction --------------------------------------------------------
	csize := size / sub_w
	qp_c := chroma_qp_scaled(enc)
	// Each active block is fully written before use; omitted chroma is unread.
	q_y: [32 * 32]i16 = ---
	q_u: [2][32 * 32]i16 = ---
	q_v: [2][32 * 32]i16 = ---
	res_y: [32 * 32]i16 = ---
	res_c: [32 * 32]i16 = ---
	coeff: [32 * 32]i16 = ---
	pred_y: [32 * 32]Sample = ---
	pred_u: [2 * 32 * 32]Sample = ---
	pred_v: [2 * 32 * 32]Sample = ---

	frame_cw, frame_ch := enc.coded_width / sub_w, enc.coded_height / sub_h
	mc_luma_uni_w(
		pred_y[:],
		size,
		&enc.refs[0][ref],
		x,
		y,
		size,
		size,
		mv,
		wp_luma(enc, 0, ref),
		enc.bit_depth,
	)
	for j in 0 ..< size {
		for i in 0 ..< size {
			res_y[j * size + i] = i16(
				i32(at(enc.source.y, x + i, y + j)) - i32(pred_y[j * size + i]),
			)
		}
	}
	forward_transform(enc, size, res_y[:], size, coeff[:], enc.bit_depth)
	cbf_y := enc_quantize(enc, coeff[:], q_y[:], size, .Y, false, int(luma_qp_scaled(enc)))

	cbf_u, cbf_v: [2]bool
	if has_chroma(enc) {
		mv_c := chroma_mv(enc.config.chroma_format, mv)
		n_chroma := chroma_blocks(enc.config.chroma_format)
		for t in 0 ..< n_chroma {
			cy := y / sub_h + t * csize
			blk := t * csize * csize
			mc_chroma_uni_w(
				pred_u[blk:],
				csize,
				enc.refs[0][ref].u,
				x / sub_w,
				cy,
				csize,
				csize,
				mv_c,
				frame_cw,
				frame_ch,
				wp_chroma(enc, 0, ref, 0),
				enc.bit_depth,
			)
			for j in 0 ..< csize {
				for i in 0 ..< csize {
					res_c[j * csize + i] = i16(
						i32(at(enc.source.u, x / sub_w + i, cy + j)) -
						i32(pred_u[blk + j * csize + i]),
					)
				}
			}
			forward_transform(enc, csize, res_c[:], csize, coeff[:], enc.bit_depth)
			cbf_u[t] = enc_quantize(enc, coeff[:], q_u[t][:], csize, .Cb, false, int(qp_c))

			mc_chroma_uni_w(
				pred_v[blk:],
				csize,
				enc.refs[0][ref].v,
				x / sub_w,
				cy,
				csize,
				csize,
				mv_c,
				frame_cw,
				frame_ch,
				wp_chroma(enc, 0, ref, 1),
				enc.bit_depth,
			)
			for j in 0 ..< csize {
				for i in 0 ..< csize {
					res_c[j * csize + i] = i16(
						i32(at(enc.source.v, x / sub_w + i, cy + j)) -
						i32(pred_v[blk + j * csize + i]),
					)
				}
			}
			forward_transform(enc, csize, res_c[:], csize, coeff[:], enc.bit_depth)
			cbf_v[t] = enc_quantize(enc, coeff[:], q_v[t][:], csize, .Cr, false, int(qp_c))
		}
	}

	// --- Root coded block flag and transform tree -------------------------
	// The transform tree of a non-split inter TU signals cbf_cb and cbf_cr,
	// then cbf_luma only when a chroma component is coded. A merge unit reads
	// none of rqt_root_cbf; it is inferred to one.
	set_cbf_flags(enc, x, y, size, cbf_y, cbf_u[0] || cbf_u[1], cbf_v[0] || cbf_v[1])
	cbf_any := cbf_y || cbf_u[0] || cbf_u[1] || cbf_v[0] || cbf_v[1]
	if !cu.merge {
		cabac_bin(cabac, &cabac.ctx.cu_qt_root_cbf_model, cbf_any ? 1 : 0)
	}

	if cu.merge || cbf_any {
		// ChromaArrayType 0 codes no chroma cbf; its root luma cbf is the
		// rqt_root_cbf inference (7.3.8.8), not a bin. A 4:2:2 pair codes
		// its second cbf beside the first (7.3.8.8).
		if has_chroma(enc) {
			n_chroma := chroma_blocks(enc.config.chroma_format)
			for t in 0 ..< n_chroma {
				cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[0], cbf_u[t] ? 1 : 0)
			}
			for t in 0 ..< n_chroma {
				cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[0], cbf_v[t] ? 1 : 0)
			}
			if cbf_u[0] || cbf_u[1] || cbf_v[0] || cbf_v[1] {
				cabac_bin(cabac, &cabac.ctx.qt_cbf_model_luma[1], cbf_y ? 1 : 0)
			}
		}
		if cbf_y do encode_coeff_nxn(cabac, q_y[:size * size], size, 0, .Diag)
		if has_chroma(enc) {
			n_chroma := chroma_blocks(enc.config.chroma_format)
			for t in 0 ..< n_chroma {
				if cbf_u[t] do encode_coeff_nxn(cabac, q_u[t][:csize * csize], csize, 1, .Diag)
			}
			for t in 0 ..< n_chroma {
				if cbf_v[t] do encode_coeff_nxn(cabac, q_v[t][:csize * csize], csize, 2, .Diag)
			}
		}
	}

	sse: u64
	recon_plane(
		enc,
		enc.rec.y,
		enc.source.y,
		x,
		y,
		size,
		q_y[:],
		res_y[:],
		pred_y[:],
		cbf_y,
		.Y,
		false,
		luma_qp_scaled(enc),
		&sse,
	)
	if has_chroma(enc) {
		n_chroma := chroma_blocks(enc.config.chroma_format)
		for t in 0 ..< n_chroma {
			cy := y / sub_h + t * csize
			blk := t * csize * csize
			recon_plane(
				enc,
				enc.rec.u,
				enc.source.u,
				x / sub_w,
				cy,
				csize,
				q_u[t][:],
				res_c[:],
				pred_u[blk:],
				cbf_u[t],
				.Cb,
				false,
				qp_c,
				&sse,
			)
			recon_plane(
				enc,
				enc.rec.v,
				enc.source.v,
				x / sub_w,
				cy,
				csize,
				q_v[t][:],
				res_c[:],
				pred_v[blk:],
				cbf_v[t],
				.Cr,
				false,
				qp_c,
				&sse,
			)
		}
	}

	return sse
}

// RQT variant of write_inter_leaf. The whole CU is one PU, so the three
// predictions are materialised once and the residual is partitioned by the
// transform tree.
@(private)
write_inter_leaf_rqt :: proc(
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	cabac: ^Cabac,
	search: bool,
) -> u64 {
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	size := CTU_WIDTH >> depth
	cu := cu_at(enc.cu, x, y)
	mv := cu.mv[0]

	if cu.skipped {
		write_merge_idx(cabac, int(cu.merge_idx))
		return reconstruct_prediction(enc, x, y, size, mv, int(cu.ref_idx[0]))
	}

	ref := int(cu.ref_idx[0])

	// part_mode: 2Nx2N for inter CUs at every depth.
	cabac_bin(cabac, &cabac.ctx.part_size_model[0], 1)
	cabac_bin(cabac, &cabac.ctx.cu_merge_flag_ext_model, cu.merge ? 1 : 0)

	if cu.merge {
		write_merge_idx(cabac, int(cu.merge_idx))
	} else {
		if enc.refs_active[0] > 1 do write_ref_idx(cabac, ref, enc.refs_active[0])
		ctx := Pu_Context {
			cu_x    = x,
			cu_y    = y,
			cu_size = size,
			pu_w    = size,
			pu_h    = size,
		}
		cands, avail := amvp_candidates_b(
			enc,
			x,
			y,
			size,
			size,
			0,
			ctx,
			enc.ref_poc[0][ref],
			enc.cur_poc,
		)
		c := amvp_build_list(enc, x, y, size, size, 0, enc.ref_poc[0][ref], cands, avail)
		idx := int(cu.mv_cand)
		mvd_x := i32(mv[0]) - i32(c[idx][0])
		mvd_y := i32(mv[1]) - i32(c[idx][1])
		encode_mvd(cabac, mvd_x, mvd_y)
		cabac_unary_max_symbol(cabac, cabac.ctx.mvp_idx_model[:], u32(idx), 1, 1)
	}

	// MC fills the CU planes before the transform tree reads any subregion.
	pred_y: [32 * 32]Sample = ---
	pred_u: [2 * 32 * 32]Sample = ---
	pred_v: [2 * 32 * 32]Sample = ---
	csize := size / sub_w
	frame_cw, frame_ch := enc.coded_width / sub_w, enc.coded_height / sub_h
	mc_luma_uni_w(
		pred_y[:],
		size,
		&enc.refs[0][ref],
		x,
		y,
		size,
		size,
		mv,
		wp_luma(enc, 0, ref),
		enc.bit_depth,
	)
	if has_chroma(enc) {
		mv_c := chroma_mv(enc.config.chroma_format, mv)
		n_chroma := chroma_blocks(enc.config.chroma_format)
		for t in 0 ..< n_chroma {
			cy := y / sub_h + t * csize
			blk := t * csize * csize
			mc_chroma_uni_w(
				pred_u[blk:],
				csize,
				enc.refs[0][ref].u,
				x / sub_w,
				cy,
				csize,
				csize,
				mv_c,
				frame_cw,
				frame_ch,
				wp_chroma(enc, 0, ref, 0),
				enc.bit_depth,
			)
			mc_chroma_uni_w(
				pred_v[blk:],
				csize,
				enc.refs[0][ref].v,
				x / sub_w,
				cy,
				csize,
				csize,
				mv_c,
				frame_cw,
				frame_ch,
				wp_chroma(enc, 0, ref, 1),
				enc.bit_depth,
			)
		}
	}
	return write_inter_rqt(
		enc,
		x,
		y,
		size,
		cu.merge,
		pred_y[:],
		pred_u[:],
		pred_v[:],
		cabac,
		search,
	)
}

// Encode one inter leaf CU of a B slice (2Nx2N). Merge/skip reads the merged
// per-list motion; AMVP signals inter_pred_idc and an MVD per used list.
write_inter_leaf_b :: proc(enc: ^Encoder, x, y: int, depth: u8, cabac: ^Cabac) -> u64 {
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	size := CTU_WIDTH >> depth
	cu := cu_at(enc.cu, x, y)

	if cu.skipped {
		write_merge_idx(cabac, int(cu.merge_idx))
		return reconstruct_prediction_b(enc, x, y, size, cu.pred, cu.mv, cu.ref_idx)
	}

	// part_mode: 2Nx2N for inter CUs at every depth.
	cabac_bin(cabac, &cabac.ctx.part_size_model[0], 1)
	cabac_bin(cabac, &cabac.ctx.cu_merge_flag_ext_model, cu.merge ? 1 : 0)

	if cu.merge {
		write_merge_idx(cabac, int(cu.merge_idx))
	} else {
		// inter_pred_idc (9.3.3.9): the first bin selects BI; otherwise a
		// second bin separates L0 from L1.
		idc := cu.idc
		cabac_bin(cabac, &cabac.ctx.inter_dir[depth], idc == PRED_BI ? 1 : 0)
		if idc != PRED_BI {
			cabac_bin(cabac, &cabac.ctx.inter_dir[4], idc == PRED_L1 ? 1 : 0)
		}

		bc := Pu_Context {
			cu_x    = x,
			cu_y    = y,
			cu_size = size,
			pu_w    = size,
			pu_h    = size,
		}
		for l in 0 ..< 2 {
			if !cu.pred[l] do continue
			if enc.refs_active[l] > 1 do write_ref_idx(cabac, int(cu.ref_idx[l]), enc.refs_active[l])
			cands, avail := amvp_candidates_b(
				enc,
				x,
				y,
				size,
				size,
				l,
				bc,
				enc.ref_poc[l][cu.ref_idx[l]],
				enc.cur_poc,
			)
			c := amvp_build_list(
				enc,
				x,
				y,
				size,
				size,
				l,
				enc.ref_poc[l][cu.ref_idx[l]],
				cands,
				avail,
			)
			idx := int(cu.mvp_flag[l])
			encode_mvd(cabac, i32(cu.mv[l][0]) - i32(c[idx][0]), i32(cu.mv[l][1]) - i32(c[idx][1]))
			cabac_unary_max_symbol(cabac, cabac.ctx.mvp_idx_model[:], u32(idx), 1, 1)
		}
	}

	// --- Prediction --------------------------------------------------------
	csize := size / sub_w
	qp_c := chroma_qp_scaled(enc)
	// Each active block is fully written before use; omitted chroma is unread.
	q_y: [32 * 32]i16 = ---
	q_u: [2][32 * 32]i16 = ---
	q_v: [2][32 * 32]i16 = ---
	res_y: [32 * 32]i16 = ---
	res_c: [32 * 32]i16 = ---
	coeff: [32 * 32]i16 = ---
	pred_y: [32 * 32]Sample = ---
	pred_u: [2 * 32 * 32]Sample = ---
	pred_v: [2 * 32 * 32]Sample = ---

	inter_predict_b(enc, x, y, size, cu.pred, cu.mv, cu.ref_idx, pred_y[:], pred_u[:], pred_v[:])

	for j in 0 ..< size {
		for i in 0 ..< size {
			res_y[j * size + i] = i16(
				i32(at(enc.source.y, x + i, y + j)) - i32(pred_y[j * size + i]),
			)
		}
	}
	forward_transform(enc, size, res_y[:], size, coeff[:], enc.bit_depth)
	cbf_y := enc_quantize(enc, coeff[:], q_y[:], size, .Y, false, int(luma_qp_scaled(enc)))

	cbf_u, cbf_v: [2]bool
	n_chroma := chroma_blocks(enc.config.chroma_format)
	for t in 0 ..< n_chroma {
		cy := y / sub_h + t * csize
		blk := t * csize * csize
		for j in 0 ..< csize {
			for i in 0 ..< csize {
				res_c[j * csize + i] = i16(
					i32(at(enc.source.u, x / sub_w + i, cy + j)) -
					i32(pred_u[blk + j * csize + i]),
				)
			}
		}
		forward_transform(enc, csize, res_c[:], csize, coeff[:], enc.bit_depth)
		cbf_u[t] = enc_quantize(enc, coeff[:], q_u[t][:], csize, .Cb, false, int(qp_c))

		for j in 0 ..< csize {
			for i in 0 ..< csize {
				res_c[j * csize + i] = i16(
					i32(at(enc.source.v, x / sub_w + i, cy + j)) -
					i32(pred_v[blk + j * csize + i]),
				)
			}
		}
		forward_transform(enc, csize, res_c[:], csize, coeff[:], enc.bit_depth)
		cbf_v[t] = enc_quantize(enc, coeff[:], q_v[t][:], csize, .Cr, false, int(qp_c))
	}

	// --- Root coded block flag and transform tree -------------------------
	set_cbf_flags(enc, x, y, size, cbf_y, cbf_u[0] || cbf_u[1], cbf_v[0] || cbf_v[1])
	cbf_any := cbf_y || cbf_u[0] || cbf_u[1] || cbf_v[0] || cbf_v[1]
	if !cu.merge {
		cabac_bin(cabac, &cabac.ctx.cu_qt_root_cbf_model, cbf_any ? 1 : 0)
	}

	if cu.merge || cbf_any {
		// ChromaArrayType 0 codes no chroma cbf; its root luma cbf is the
		// rqt_root_cbf inference (7.3.8.8), not a bin. A 4:2:2 pair codes
		// its second cbf beside the first (7.3.8.8).
		if has_chroma(enc) {
			for t in 0 ..< n_chroma {
				cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[0], cbf_u[t] ? 1 : 0)
			}
			for t in 0 ..< n_chroma {
				cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[0], cbf_v[t] ? 1 : 0)
			}
			if cbf_u[0] || cbf_u[1] || cbf_v[0] || cbf_v[1] {
				cabac_bin(cabac, &cabac.ctx.qt_cbf_model_luma[1], cbf_y ? 1 : 0)
			}
		}
		if cbf_y do encode_coeff_nxn(cabac, q_y[:size * size], size, 0, .Diag)
		if has_chroma(enc) {
			for t in 0 ..< n_chroma {
				if cbf_u[t] do encode_coeff_nxn(cabac, q_u[t][:csize * csize], csize, 1, .Diag)
			}
			for t in 0 ..< n_chroma {
				if cbf_v[t] do encode_coeff_nxn(cabac, q_v[t][:csize * csize], csize, 2, .Diag)
			}
		}
	}

	sse: u64
	recon_plane(
		enc,
		enc.rec.y,
		enc.source.y,
		x,
		y,
		size,
		q_y[:],
		res_y[:],
		pred_y[:],
		cbf_y,
		.Y,
		false,
		luma_qp_scaled(enc),
		&sse,
	)
	if has_chroma(enc) {
		for t in 0 ..< n_chroma {
			cy := y / sub_h + t * csize
			blk := t * csize * csize
			recon_plane(
				enc,
				enc.rec.u,
				enc.source.u,
				x / sub_w,
				cy,
				csize,
				q_u[t][:],
				res_c[:],
				pred_u[blk:],
				cbf_u[t],
				.Cb,
				false,
				qp_c,
				&sse,
			)
			recon_plane(
				enc,
				enc.rec.v,
				enc.source.v,
				x / sub_w,
				cy,
				csize,
				q_v[t][:],
				res_c[:],
				pred_v[blk:],
				cbf_v[t],
				.Cr,
				false,
				qp_c,
				&sse,
			)
		}
	}

	return sse
}

// RQT variant of write_inter_leaf_b.
@(private)
write_inter_leaf_b_rqt :: proc(
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	cabac: ^Cabac,
	search: bool,
) -> u64 {
	size := CTU_WIDTH >> depth
	cu := cu_at(enc.cu, x, y)

	if cu.skipped {
		write_merge_idx(cabac, int(cu.merge_idx))
		return reconstruct_prediction_b(enc, x, y, size, cu.pred, cu.mv, cu.ref_idx)
	}

	// part_mode: 2Nx2N for inter CUs at every depth.
	cabac_bin(cabac, &cabac.ctx.part_size_model[0], 1)
	cabac_bin(cabac, &cabac.ctx.cu_merge_flag_ext_model, cu.merge ? 1 : 0)

	if cu.merge {
		write_merge_idx(cabac, int(cu.merge_idx))
	} else {
		// inter_pred_idc (9.3.3.9): the first bin selects BI; otherwise a
		// second bin separates L0 from L1.
		idc := cu.idc
		cabac_bin(cabac, &cabac.ctx.inter_dir[depth], idc == PRED_BI ? 1 : 0)
		if idc != PRED_BI {
			cabac_bin(cabac, &cabac.ctx.inter_dir[4], idc == PRED_L1 ? 1 : 0)
		}

		bc := Pu_Context {
			cu_x    = x,
			cu_y    = y,
			cu_size = size,
			pu_w    = size,
			pu_h    = size,
		}
		for l in 0 ..< 2 {
			if !cu.pred[l] do continue
			if enc.refs_active[l] > 1 do write_ref_idx(cabac, int(cu.ref_idx[l]), enc.refs_active[l])
			cands, avail := amvp_candidates_b(
				enc,
				x,
				y,
				size,
				size,
				l,
				bc,
				enc.ref_poc[l][cu.ref_idx[l]],
				enc.cur_poc,
			)
			c := amvp_build_list(
				enc,
				x,
				y,
				size,
				size,
				l,
				enc.ref_poc[l][cu.ref_idx[l]],
				cands,
				avail,
			)
			idx := int(cu.mvp_flag[l])
			encode_mvd(cabac, i32(cu.mv[l][0]) - i32(c[idx][0]), i32(cu.mv[l][1]) - i32(c[idx][1]))
			cabac_unary_max_symbol(cabac, cabac.ctx.mvp_idx_model[:], u32(idx), 1, 1)
		}
	}

	// Prediction fills the CU planes before the transform tree reads subregions.
	pred_y: [32 * 32]Sample = ---
	pred_u: [2 * 32 * 32]Sample = ---
	pred_v: [2 * 32 * 32]Sample = ---
	inter_predict_b(enc, x, y, size, cu.pred, cu.mv, cu.ref_idx, pred_y[:], pred_u[:], pred_v[:])
	return write_inter_rqt(
		enc,
		x,
		y,
		size,
		cu.merge,
		pred_y[:],
		pred_u[:],
		pred_v[:],
		cabac,
		search,
	)
}

// Encode one PCM coding unit (7.3.8.7) and reconstruct it by copying the
// source: the samples are lossless, so there is no prediction or residual.
// pcm_flag is a terminate bin; the raw samples begin at the next byte after the
// arithmetic coder is flushed and the alignment stop bit is written, and the
// coder restarts after them with its contexts unchanged.
write_intra_pcm :: proc(enc: ^Encoder, x, y: int, depth: u8, cabac: ^Cabac) -> u64 {
	sw, sh := chroma_sub(enc.config.chroma_format)
	size := CTU_WIDTH >> depth

	// part_mode: intra CUs at minimum size signal 2Nx2N, exactly as the
	// residual-coded leaf does; pcm_flag only exists for 2Nx2N.
	if depth == MAX_CU_DEPTH {
		cabac_bin(cabac, &cabac.ctx.part_size_model[0], 1)
	}

	cabac_bin_trm(cabac, 1) // pcm_flag
	cabac_finish(cabac)
	stream := cabac.stream
	common.write_bits(stream, 1, 1) // pcm alignment stop bit
	common.write_align_zero(stream)

	for j in 0 ..< size {
		for i in 0 ..< size {
			common.write_bits(stream, u32(at(enc.source.y, x + i, y + j)), enc.bit_depth)
		}
	}
	cw := size / sw
	ch := has_chroma(enc) ? size / sh : 0
	for j in 0 ..< ch {
		for i in 0 ..< cw {
			common.write_bits(stream, u32(at(enc.source.u, x / sw + i, y / sh + j)), enc.bit_depth)
		}
	}
	for j in 0 ..< ch {
		for i in 0 ..< cw {
			common.write_bits(stream, u32(at(enc.source.v, x / sw + i, y / sh + j)), enc.bit_depth)
		}
	}

	cabac_start(cabac)

	for j in 0 ..< size {
		for i in 0 ..< size {
			set_at(enc.rec.y, x + i, y + j, at(enc.source.y, x + i, y + j))
		}
	}
	for j in 0 ..< ch {
		for i in 0 ..< cw {
			set_at(enc.rec.u, x / sw + i, y / sh + j, at(enc.source.u, x / sw + i, y / sh + j))
			set_at(enc.rec.v, x / sw + i, y / sh + j, at(enc.source.v, x / sw + i, y / sh + j))
		}
	}

	set_cbf_flags(enc, x, y, size, false, false, false)
	mark_tu_enc(enc, x, y, size)

	return 0
}

// Encode one intra leaf CU and reconstruct it. Returns the SSE of the CU.
write_intra_leaf :: #force_inline proc(
	enc: ^Encoder,
	x, y: int,
	depth: u8,
	cabac: ^Cabac,
	prepared_refs: ^Intra_Refs = nil,
) -> u64 {
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	size := CTU_WIDTH >> depth
	mode := cu_at(enc.cu, x, y).mode

	// part_mode: intra CUs at minimum size signal 2Nx2N; larger CUs signal
	// nothing because only 2Nx2N is used for depth < MAX_CU_DEPTH.
	if depth == MAX_CU_DEPTH {
		cabac_bin(cabac, &cabac.ctx.part_size_model[0], 1)
	}
	// pcm_flag: every 2Nx2N intra CU in the SPS PCM size range carries it.
	if enc.config.pcm do cabac_bin_trm(cabac, 0)
	write_intra_mode(enc, x, y, mode, cabac)
	// intra_chroma_pred_mode: always "derived from luma" (no chroma mode at
	// all for ChromaArrayType 0).
	if has_chroma(enc) do cabac_bin(cabac, &cabac.ctx.chroma_pred_model[0], 0)

	// --- Luma --------------------------------------------------------------
	// Prediction, transform and quantization each fill their active square.
	q_y: [32 * 32]i16 = ---
	res_y: [32 * 32]i16 = ---
	coeff_y: [32 * 32]i16 = ---
	pred_y: [32 * 32]Sample = ---
	refs: Intra_Refs

	luma_refs := prepared_refs
	if luma_refs == nil {
		build_reference(enc, &enc.rec, x, y, log2_size(size), .Y, &refs, enc.bit_depth)
		luma_refs = &refs
	}
	intra_predict(luma_refs, log2_size(size), mode, .Y, pred_y[:], size, enc.bit_depth)
	for j in 0 ..< size {
		for i in 0 ..< size {
			res_y[j * size + i] = i16(
				i32(at(enc.source.y, x + i, y + j)) - i32(pred_y[j * size + i]),
			)
		}
	}
	forward_transform(enc, size, res_y[:], size, coeff_y[:], enc.bit_depth)
	cbf_y := enc_quantize(enc, coeff_y[:], q_y[:], size, .Y, true, int(luma_qp_scaled(enc)))

	// --- Chroma ------------------------------------------------------------
	csize := has_chroma(enc) ? size / sub_w : 0
	qp_c := chroma_qp_scaled(enc)
	sse_chroma: u64
	// The stacked-chroma save below copies each entire coefficient array.
	q_u: [2][32 * 32]i16
	q_v: [2][32 * 32]i16
	res_c: [32 * 32]i16 = ---
	coeff_c: [32 * 32]i16 = ---
	pred_u: [2 * 32 * 32]Sample = ---
	pred_v: [2 * 32 * 32]Sample = ---

	cbf_u, cbf_v: [2]bool
	if has_chroma(enc) {
		n_chroma := chroma_blocks(enc.config.chroma_format)
		mode_c := chroma_pred_mode(enc.config.chroma_format, mode)
		for t in 0 ..< n_chroma {
			// Each block is reconstructed as it is computed: the second
			// stacked block predicts from the first's reconstruction (8.4.2).
			ty := y + t * csize * sub_h
			build_reference(enc, &enc.rec, x, ty, log2_size(csize), .U, &refs, enc.bit_depth)
			intra_predict(
				&refs,
				log2_size(csize),
				mode_c,
				.U,
				pred_u[:],
				csize,
				enc.bit_depth,
				enc.config.chroma_format,
			)
			for j in 0 ..< csize {
				for i in 0 ..< csize {
					res_c[j * csize + i] = i16(
						i32(at(enc.source.u, x / sub_w + i, ty / sub_h + j)) -
						i32(pred_u[j * csize + i]),
					)
				}
			}
			forward_transform(enc, csize, res_c[:], csize, coeff_c[:], enc.bit_depth)
			cbf_u[t] = enc_quantize(enc, coeff_c[:], q_u[t][:], csize, .Cb, true, int(qp_c))
			if n_chroma > 1 {
				// 4:2:2: the second stacked block predicts from the
				// first's reconstruction (8.4.2), so each block
				// reconstructs as it is computed. The single-block
				// formats reconstruct at the tail below (byte-identical
				// historical order). The reconstruction's inverse
				// transform writes its spatial result back into the
				// coefficient buffer, so the quantized levels are held
				// across it — the coefficient writes come later.
				saved_u := q_u[t]
				recon_plane(
					enc,
					enc.rec.u,
					enc.source.u,
					x / sub_w,
					ty / sub_h,
					csize,
					q_u[t][:],
					res_c[:],
					pred_u[:],
					cbf_u[t],
					.Cb,
					true,
					qp_c,
					&sse_chroma,
				)
				q_u[t] = saved_u
			}

			build_reference(enc, &enc.rec, x, ty, log2_size(csize), .V, &refs, enc.bit_depth)
			intra_predict(
				&refs,
				log2_size(csize),
				mode_c,
				.V,
				pred_v[:],
				csize,
				enc.bit_depth,
				enc.config.chroma_format,
			)
			for j in 0 ..< csize {
				for i in 0 ..< csize {
					res_c[j * csize + i] = i16(
						i32(at(enc.source.v, x / sub_w + i, ty / sub_h + j)) -
						i32(pred_v[j * csize + i]),
					)
				}
			}
			forward_transform(enc, csize, res_c[:], csize, coeff_c[:], enc.bit_depth)
			cbf_v[t] = enc_quantize(enc, coeff_c[:], q_v[t][:], csize, .Cr, true, int(qp_c))
			if n_chroma > 1 {
				saved_v := q_v[t]
				recon_plane(
					enc,
					enc.rec.v,
					enc.source.v,
					x / sub_w,
					ty / sub_h,
					csize,
					q_v[t][:],
					res_c[:],
					pred_v[:],
					cbf_v[t],
					.Cr,
					true,
					qp_c,
					&sse_chroma,
				)
				q_v[t] = saved_v
			}
		}
	}

	// --- Coded block flags -------------------------------------------------
	// With the minimum CU size of 8x8 the luma transform is at least 8x8, so
	// cbf_cb and cbf_cr are always present (log2TrafoSize > 2) — except at
	// ChromaArrayType 0, which codes no chroma at all.
	set_cbf_flags(enc, x, y, size, cbf_y, cbf_u[0] || cbf_u[1], cbf_v[0] || cbf_v[1])
	if has_chroma(enc) {
		n_chroma := chroma_blocks(enc.config.chroma_format)
		for t in 0 ..< n_chroma {
			cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[0], cbf_u[t] ? 1 : 0)
		}
		for t in 0 ..< n_chroma {
			cabac_bin(cabac, &cabac.ctx.qt_cbf_model_chroma[0], cbf_v[t] ? 1 : 0)
		}
	}
	cabac_bin(cabac, &cabac.ctx.qt_cbf_model_luma[1], cbf_y ? 1 : 0)

	// --- Code the coefficients, then reconstruct ---------------------------
	sse: u64
	scan := get_scan_order(.Intra, mode, depth)

	cat := int(layout_idc(enc.config.chroma_format))
	mode_c2 := chroma_pred_mode(enc.config.chroma_format, mode)
	scan_c := intra_scan(log2_size(csize), 1, int(mode_c2), u32(cat))
	if cbf_y do encode_coeff_nxn(cabac, q_y[:size * size], size, 0, scan)
	for t in 0 ..< chroma_blocks(enc.config.chroma_format) {
		if cbf_u[t] do encode_coeff_nxn(cabac, q_u[t][:csize * csize], csize, 1, scan_c)
	}
	for t in 0 ..< chroma_blocks(enc.config.chroma_format) {
		if cbf_v[t] do encode_coeff_nxn(cabac, q_v[t][:csize * csize], csize, 2, scan_c)
	}

	recon_plane(
		enc,
		enc.rec.y,
		enc.source.y,
		x,
		y,
		size,
		q_y[:],
		res_y[:],
		pred_y[:],
		cbf_y,
		.Y,
		true,
		luma_qp_scaled(enc),
		&sse,
	)
	if has_chroma(enc) {
		n_chroma := chroma_blocks(enc.config.chroma_format)
		for t in 0 ..< n_chroma * (n_chroma == 1 ? 1 : 0) {
			ty := y + t * csize * sub_h
			blk := t * csize * csize
			recon_plane(
				enc,
				enc.rec.u,
				enc.source.u,
				x / sub_w,
				ty / sub_h,
				csize,
				q_u[t][:],
				res_c[:],
				pred_u[blk:],
				cbf_u[t],
				.Cb,
				true,
				qp_c,
				&sse,
			)
			recon_plane(
				enc,
				enc.rec.v,
				enc.source.v,
				x / sub_w,
				ty / sub_h,
				csize,
				q_v[t][:],
				res_c[:],
				pred_v[blk:],
				cbf_v[t],
				.Cr,
				true,
				qp_c,
				&sse,
			)
		}
	}
	sse += sse_chroma

	return sse
}

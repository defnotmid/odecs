package h264_encoder

import h264 ".."
import common "../../../common"

// ---------------------------------------------------------------------------
// CABAC entropy coding and exact rate-distortion bit counting (ITU-T H.264 9.3)
// ---------------------------------------------------------------------------

Cabac_State :: struct {
	using enc:        common.Cabac_Enc,
	ctx:              [h264.CABAC_TOTAL_CONTEXT_COUNT]u8,
	prev_qp_delta_nz: bool,
}

cabac_init_slice :: proc(task: ^Slice_Task) {
	common.cabac_enc_start(&task.cabac.enc, &task.writer)
	h264.cabac_init_contexts(
		&task.cabac.ctx,
		task.is_idr ? .I : .P,
		0,
		task.quantizer,
	)
	task.cabac.prev_qp_delta_nz = false
}

cabac_write_mb_skip :: proc(
	cabac: ^Cabac_State,
	grid: ^h264.Macroblock_Grid,
	macroblock_index: int,
	skip: bool,
) {
	left := h264.left_macroblock(grid, macroblock_index)
	top := h264.top_macroblock(grid, macroblock_index)
	inc := h264.cabac_mb_skip_ctx_inc(grid.macroblocks, left, top)
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[11 + inc], skip ? 1 : 0)
}

cabac_skip_bit_count :: proc(task: ^Slice_Task, macroblock_index: int, skip: bool) -> int {
	trial := task.cabac
	trial.enc.stream = nil
	before := common.cabac_enc_rate(&trial.enc)
	cabac_write_mb_skip(&trial, &task.grid, macroblock_index, skip)
	return max(common.cabac_enc_rate(&trial.enc) - before, 1)
}

@(private = "file")
write_intra_mb_type :: proc(
	cabac: ^Cabac_State,
	grid: ^h264.Macroblock_Grid,
	macroblock_index: int,
	macroblock: #soa^#soa[]h264.Macroblock,
	base: int,
	in_i_slice: bool,
) {
	is_16x16 := macroblock.type == .I_16x16
	if in_i_slice {
		left := h264.left_macroblock(grid, macroblock_index)
		top := h264.top_macroblock(grid, macroblock_index)
		inc := h264.cabac_intra_mb_type_ctx_inc(grid.macroblocks, left, top)
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[base + inc], is_16x16 ? 1 : 0)
	} else {
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[base], is_16x16 ? 1 : 0)
	}
	if !is_16x16 do return
	common.cabac_enc_terminate(&cabac.enc, 0) // not I_PCM
	offset := in_i_slice ? 3 : 1
	common.cabac_enc_decision(
		&cabac.enc,
		&cabac.ctx[base + offset],
		macroblock.luma_coded_block_mask != 0 ? 1 : 0,
	)
	chroma := u32(macroblock.chroma_residual_mode)
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[base + offset + 1], chroma != 0 ? 1 : 0)
	if chroma != 0 {
		common.cabac_enc_decision(
			&cabac.enc,
			&cabac.ctx[base + offset + (in_i_slice ? 2 : 1)],
			chroma == 2 ? 1 : 0,
		)
	}
	mode_ctx := base + offset + (in_i_slice ? 3 : 2)
	mode := u32(macroblock.intra_16x16_mode)
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[mode_ctx], (mode >> 1) & 1)
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[mode_ctx + (in_i_slice ? 1 : 0)], mode & 1)
}

cabac_write_mb_type :: proc(
	cabac: ^Cabac_State,
	grid: ^h264.Macroblock_Grid,
	macroblock_index: int,
	macroblock: #soa^#soa[]h264.Macroblock,
	is_idr: bool,
) {
	if is_idr {
		write_intra_mb_type(cabac, grid, macroblock_index, macroblock, 3, true)
		return
	}
	if macroblock.is_intra {
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[14], 1)
		write_intra_mb_type(cabac, grid, macroblock_index, macroblock, 17, false)
		return
	}
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[14], 0)
	#partial switch macroblock.type {
	case .P_L0_16x16:
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[15], 0)
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[16], 0)
	case .P_8x8, .P_8x8ref0:
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[15], 0)
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[16], 1)
	case .P_L0_L0_8x16:
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[15], 1)
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[17], 0)
	case .P_L0_L0_16x8:
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[15], 1)
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[17], 1)
	}
}

cabac_write_sub_mb_type :: #force_inline proc(cabac: ^Cabac_State) {
	// P_L0_8x8 (sub_mb_type 0) is a single bin 1 at ctxIdx 21 (Table 9-37).
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[21], 1)
}

cabac_write_transform_8x8_flag :: proc(
	cabac: ^Cabac_State,
	grid: ^h264.Macroblock_Grid,
	macroblock_index: int,
	flag: bool,
) {
	left := h264.left_macroblock(grid, macroblock_index)
	top := h264.top_macroblock(grid, macroblock_index)
	inc := h264.cabac_transform_8x8_ctx_inc(grid.macroblocks, left, top)
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[399 + inc], flag ? 1 : 0)
}

cabac_write_ref_idx :: proc(
	cabac: ^Cabac_State,
	grid: ^h264.Macroblock_Grid,
	macroblock_index, list, block: int,
	ref_idx: i32,
) {
	left := h264.left_macroblock(grid, macroblock_index)
	top := h264.top_macroblock(grid, macroblock_index)
	inc := h264.cabac_ref_idx_ctx_inc(grid.macroblocks, macroblock_index, left, top, list, block)
	ctx_idx := 54 + inc
	for i in i32(0) ..< ref_idx {
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ctx_idx], 1)
		ctx_idx = i == 0 ? 54 + 4 : 54 + 5
	}
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ctx_idx], 0)
}

cabac_write_mvd_pair :: proc(
	cabac: ^Cabac_State,
	grid: ^h264.Macroblock_Grid,
	macroblock_index, list, block: int,
	mvd: [2]i32,
) {
	left := h264.left_macroblock(grid, macroblock_index)
	top := h264.top_macroblock(grid, macroblock_index)
	inc := h264.cabac_mvd_ctx_inc(grid.macroblocks, macroblock_index, left, top, list, block)
	for comp in 0 ..< 2 {
		base := comp == 0 ? 40 : 47
		v := mvd[comp]
		if v == 0 {
			common.cabac_enc_decision(&cabac.enc, &cabac.ctx[base + inc[comp]], 0)
			continue
		}
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[base + inc[comp]], 1)
		mag := u32(abs(v))
		prefix := min(mag, 9)
		ctx_idx := base + 3
		for _ in u32(1) ..< prefix {
			common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ctx_idx], 1)
			if ctx_idx < base + 6 do ctx_idx += 1
		}
		if mag < 9 {
			common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ctx_idx], 0)
		} else {
			common.cabac_enc_exp_golomb(&cabac.enc, mag - 9, 3)
		}
		common.cabac_enc_bypass(&cabac.enc, v < 0 ? 1 : 0)
	}
}

cabac_write_intra_pred_mode :: proc(cabac: ^Cabac_State, mode, predicted: int) {
	if mode == predicted {
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[68], 1)
		return
	}
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[68], 0)
	rem := u32(mode < predicted ? mode : mode - 1)
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[69], rem & 1)
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[69], (rem >> 1) & 1)
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[69], (rem >> 2) & 1)
}

cabac_write_intra_chroma_mode :: proc(
	cabac: ^Cabac_State,
	grid: ^h264.Macroblock_Grid,
	macroblock_index: int,
	mode: h264.Intra_Chroma_Mode,
) {
	left := h264.left_macroblock(grid, macroblock_index)
	top := h264.top_macroblock(grid, macroblock_index)
	inc := h264.cabac_intra_chroma_mode_ctx_inc(grid.macroblocks, left, top)
	if mode == .DC {
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[64 + inc], 0)
		return
	}
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[64 + inc], 1)
	if mode == .Horizontal {
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[67], 0)
		return
	}
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[67], 1)
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[67], mode == .Plane ? 1 : 0)
}

cabac_write_coded_block_pattern :: proc(
	cabac: ^Cabac_State,
	grid: ^h264.Macroblock_Grid,
	macroblock_index: int,
	luma_mask: u8,
	chroma_mode: h264.Chroma_Residual_Mode,
) {
	left := h264.left_macroblock(grid, macroblock_index)
	top := h264.top_macroblock(grid, macroblock_index)
	luma: u32 = 0
	for block8 in 0 ..< 4 {
		inc := h264.cabac_cbp_luma_ctx_inc(grid.macroblocks, left, top, block8, luma)
		bit := u32((luma_mask >> uint(block8)) & 1)
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[73 + inc], bit)
		luma |= bit << uint(block8)
	}
	chroma := u32(chroma_mode)
	common.cabac_enc_decision(
		&cabac.enc,
		&cabac.ctx[77 + h264.cabac_cbp_chroma_ctx_inc(grid.macroblocks, left, top, false)],
		chroma != 0 ? 1 : 0,
	)
	if chroma != 0 {
		common.cabac_enc_decision(
			&cabac.enc,
			&cabac.ctx[77 + 4 + h264.cabac_cbp_chroma_ctx_inc(grid.macroblocks, left, top, true)],
			chroma == 2 ? 1 : 0,
		)
	}
}

cabac_write_qp_delta :: proc(cabac: ^Cabac_State, delta: i32) {
	first_ctx := 60 + (cabac.prev_qp_delta_nz ? 1 : 0)
	if delta == 0 {
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[first_ctx], 0)
		cabac.prev_qp_delta_nz = false
		return
	}
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[first_ctx], 1)
	cabac.prev_qp_delta_nz = true
	mapped := delta > 0 ? u32(2 * delta - 1) : u32(-2 * delta)
	ctx_idx := 62
	for _ in u32(1) ..< mapped {
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ctx_idx], 1)
		ctx_idx = 63
	}
	common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ctx_idx], 0)
}

cabac_write_residual_block :: proc(
	cabac: ^Cabac_State,
	grid: ^h264.Macroblock_Grid,
	macroblock_index: int,
	$cat: h264.Block_Cat,
	block: int,
	levels: []i16,
	max_coeffs: int,
) #no_bounds_check {
	positions: [64]u8 = ---
	count := 0
	for i in 0 ..< max_coeffs {
		if levels[i] != 0 {
			positions[count] = u8(i)
			count += 1
		}
	}
	when cat != .Luma_8x8 {
		left := h264.left_macroblock(grid, macroblock_index)
		top := h264.top_macroblock(grid, macroblock_index)
		ctx_idx := h264.cabac_coded_block_ctx_idx(
			grid.macroblocks,
			macroblock_index,
			left,
			top,
			cat,
			block,
		)
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ctx_idx], count > 0 ? 1 : 0)
		if count == 0 do return
	} else {
		if count == 0 do return
	}

	when cat == .Luma_8x8 {
		SIG :: 402
		LAST :: 417
		ABS :: 426
	} else {
		SIG := 105 + h264.significant_cat_offset[cat]
		LAST := 166 + h264.significant_cat_offset[cat]
		ABS := 227 + h264.abs_level_cat_offset[cat]
	}
	GT1_MAX :: 3 when cat == .Chroma_DC else 4

	last_pos := int(positions[count - 1])
	for i in 0 ..< last_pos {
		when cat == .Luma_8x8 {
			sig_ctx, last_ctx := int(h264.sig_coeff_ctx_8x8[i]), int(h264.last_coeff_ctx_8x8[i])
		} else when cat == .Chroma_DC {
			sig_ctx := min(i, 2)
			last_ctx := sig_ctx
		} else {
			sig_ctx, last_ctx := i, i
		}
		if levels[i] == 0 {
			common.cabac_enc_decision(&cabac.enc, &cabac.ctx[SIG + sig_ctx], 0)
		} else {
			common.cabac_enc_decision(&cabac.enc, &cabac.ctx[SIG + sig_ctx], 1)
			common.cabac_enc_decision(&cabac.enc, &cabac.ctx[LAST + last_ctx], 0)
		}
	}
	if last_pos < max_coeffs - 1 {
		when cat == .Luma_8x8 {
			sig_ctx, last_ctx :=
				int(h264.sig_coeff_ctx_8x8[last_pos]), int(h264.last_coeff_ctx_8x8[last_pos])
		} else when cat == .Chroma_DC {
			sig_ctx := min(last_pos, 2)
			last_ctx := sig_ctx
		} else {
			sig_ctx, last_ctx := last_pos, last_pos
		}
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[SIG + sig_ctx], 1)
		common.cabac_enc_decision(&cabac.enc, &cabac.ctx[LAST + last_ctx], 1)
	}

	num_gt1, num_eq1 := 0, 0
	for k := count - 1; k >= 0; k -= 1 {
		level := i32(levels[positions[k]])
		mag := u32(abs(level))
		inc := num_gt1 != 0 ? 0 : min(4, 1 + num_eq1)
		if mag == 1 {
			common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ABS + inc], 0)
			num_eq1 += 1
		} else {
			common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ABS + inc], 1)
			inc = 5 + min(GT1_MAX, num_gt1)
			prefix := min(mag, 15)
			for _ in u32(2) ..< prefix {
				common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ABS + inc], 1)
			}
			if mag < 15 {
				common.cabac_enc_decision(&cabac.enc, &cabac.ctx[ABS + inc], 0)
			} else {
				common.cabac_enc_exp_golomb(&cabac.enc, mag - 15, 0)
			}
			num_gt1 += 1
		}
		common.cabac_enc_bypass(&cabac.enc, level < 0 ? 1 : 0)
	}
}

write_macroblock_layer_cabac :: proc(
	task: ^Slice_Task,
	cabac: ^Cabac_State,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	macroblock_index: int,
) {
	state := task.state
	grid := &task.grid

	cabac_write_mb_type(cabac, grid, macroblock_index, macroblock, task.is_idr)
	if state.config.transform_8x8 && (macroblock.type == .I_4x4 || macroblock.type == .I_8x8) {
		cabac_write_transform_8x8_flag(cabac, grid, macroblock_index, macroblock.type == .I_8x8)
	}

	#partial switch macroblock.type {
	case .I_4x4:
		for block in 0 ..< 16 {
			bx, by := h264.subblock_to_xy(block)
			left_mode :=
				bx > 0 ? int(macroblock.intra_4x4_modes[h264.xy_to_subblock(bx - 1, by)]) : neighbour_intra_4x4_mode(grid, macroblock_index, true, by)
			top_mode :=
				by > 0 ? int(macroblock.intra_4x4_modes[h264.xy_to_subblock(bx, by - 1)]) : neighbour_intra_4x4_mode(grid, macroblock_index, false, bx)
			predicted :=
				left_mode < 0 || top_mode < 0 ? int(h264.Intra_4x4_Mode.DC) : min(left_mode, top_mode)
			cabac_write_intra_pred_mode(cabac, int(macroblock.intra_4x4_modes[block]), predicted)
		}
		cabac_write_intra_chroma_mode(
			cabac,
			grid,
			macroblock_index,
			macroblock.chroma_prediction_mode,
		)
	case .I_8x8:
		for block8 in 0 ..< 4 {
			bx, by := block8 & 1, block8 >> 1
			left_mode :=
				bx > 0 ? int(macroblock.intra_4x4_modes[(block8 - 1) * 4]) : neighbour_intra_4x4_mode(grid, macroblock_index, true, by * 2)
			top_mode :=
				by > 0 ? int(macroblock.intra_4x4_modes[(block8 - 2) * 4]) : neighbour_intra_4x4_mode(grid, macroblock_index, false, bx * 2)
			predicted :=
				left_mode < 0 || top_mode < 0 ? int(h264.Intra_4x4_Mode.DC) : min(left_mode, top_mode)
			cabac_write_intra_pred_mode(
				cabac,
				int(macroblock.intra_4x4_modes[block8 * 4]),
				predicted,
			)
		}
		cabac_write_intra_chroma_mode(
			cabac,
			grid,
			macroblock_index,
			macroblock.chroma_prediction_mode,
		)
	case .I_16x16:
		cabac_write_intra_chroma_mode(
			cabac,
			grid,
			macroblock_index,
			macroblock.chroma_prediction_mode,
		)
	case .P_L0_16x16, .P_L0_L0_16x8, .P_L0_L0_8x16:
		macroblock.motion_differences[0] = {}
		partitions := h264.macroblock_partitions(macroblock.type)
		if state.num_refs > 1 {
			for part in partitions {
				cabac_write_ref_idx(
					cabac,
					grid,
					macroblock_index,
					0,
					part.block,
					i32(macroblock.reference_indices[0][part.block / 4]),
				)
			}
		}
		for part in partitions {
			predictor := h264.predict_motion_vector(
				grid,
				macroblock_index,
				0,
				part.block,
				part.width,
				part.height,
				macroblock.reference_indices[0][part.block / 4],
			)
			mvd := [2]i32 {
				i32(macroblock.motion_vectors[0][part.block][0]) - i32(predictor[0]),
				i32(macroblock.motion_vectors[0][part.block][1]) - i32(predictor[1]),
			}
			cabac_write_mvd_pair(cabac, grid, macroblock_index, 0, part.block, mvd)
			h264.store_mvd(macroblock, 0, part, mvd)
		}
	case .P_8x8:
		macroblock.motion_differences[0] = {}
		for _ in 0 ..< 4 do cabac_write_sub_mb_type(cabac)
		if state.num_refs > 1 {
			for k in 0 ..< 4 {
				cabac_write_ref_idx(
					cabac,
					grid,
					macroblock_index,
					0,
					k * 4,
					i32(macroblock.reference_indices[0][k]),
				)
			}
		}
		for k in 0 ..< 4 {
			part := h264.Partition{k * 4, 2, 2}
			predictor := h264.predict_motion_vector(
				grid,
				macroblock_index,
				0,
				part.block,
				2,
				2,
				macroblock.reference_indices[0][k],
			)
			mvd := [2]i32 {
				i32(macroblock.motion_vectors[0][part.block][0]) - i32(predictor[0]),
				i32(macroblock.motion_vectors[0][part.block][1]) - i32(predictor[1]),
			}
			cabac_write_mvd_pair(cabac, grid, macroblock_index, 0, part.block, mvd)
			h264.store_mvd(macroblock, 0, part, mvd)
		}
	}

	if macroblock.type != .I_16x16 {
		cabac_write_coded_block_pattern(
			cabac,
			grid,
			macroblock_index,
			macroblock.luma_coded_block_mask,
			macroblock.chroma_residual_mode,
		)
		if macroblock.luma_coded_block_mask != 0 &&
		   state.config.transform_8x8 &&
		   !macroblock.is_intra {
			cabac_write_transform_8x8_flag(
				cabac,
				grid,
				macroblock_index,
				macroblock.uses_8x8_transform,
			)
		}
	}

	if macroblock.luma_coded_block_mask != 0 ||
	   macroblock.chroma_residual_mode != .None ||
	   macroblock.type == .I_16x16 {
		cabac_write_qp_delta(cabac, 0)
	} else {
		cabac.prev_qp_delta_nz = false
	}

	if macroblock.type == .I_16x16 {
		cabac_write_residual_block(
			cabac,
			grid,
			macroblock_index,
			.Luma_DC,
			0,
			choice.luma_dc_coefficients[:],
			16,
		)
		if macroblock.luma_coded_block_mask != 0 {
			for block in 0 ..< 16 {
				cabac_write_residual_block(
					cabac,
					grid,
					macroblock_index,
					.Luma_AC,
					block,
					choice.luma_coefficients[block][1:],
					15,
				)
			}
		}
	} else if macroblock.uses_8x8_transform {
		for block8 in 0 ..< 4 {
			if macroblock.luma_coded_block_mask & (1 << uint(block8)) != 0 {
				cabac_write_residual_block(
					cabac,
					grid,
					macroblock_index,
					.Luma_8x8,
					block8,
					luma_8x8_block(choice, block8)[:],
					64,
				)
			}
		}
	} else {
		for block in 0 ..< 16 {
			if macroblock.luma_coded_block_mask & (1 << uint(block / 4)) != 0 {
				cabac_write_residual_block(
					cabac,
					grid,
					macroblock_index,
					.Luma_4x4,
					block,
					choice.luma_coefficients[block][:],
					16,
				)
			}
		}
	}

	if macroblock.chroma_residual_mode != .None {
		for plane in 0 ..< 2 {
			cabac_write_residual_block(
				cabac,
				grid,
				macroblock_index,
				.Chroma_DC,
				plane,
				choice.chroma_dc_coefficients[plane][:],
				4,
			)
		}
	}
	if macroblock.chroma_residual_mode == .DC_And_AC {
		for plane in 0 ..< 2 do for block in 0 ..< 4 {
			cabac_write_residual_block(
				cabac,
				grid,
				macroblock_index,
				.Chroma_AC,
				plane * 4 + block,
				choice.chroma_ac_coefficients[plane][block][1:],
				15,
			)
		}
	}
}

cabac_macroblock_bit_count :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	macroblock_index: int,
	include_skip_flag := false,
) -> int {
	if macroblock.is_skip do return cabac_skip_bit_count(task, macroblock_index, true)
	trial := task.cabac
	trial.enc.stream = nil
	before := common.cabac_enc_rate(&trial.enc)
	if include_skip_flag do cabac_write_mb_skip(&trial, &task.grid, macroblock_index, false)
	write_macroblock_layer_cabac(task, &trial, macroblock, choice, macroblock_index)
	return max(common.cabac_enc_rate(&trial.enc) - before, 1)
}

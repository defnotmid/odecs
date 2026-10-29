package h264_encoder

import h264 ".."
import common "../../../common"

// ---------------------------------------------------------------------------
// Macroblock mode decision, coding, reconstruction and CAVLC syntax
// ---------------------------------------------------------------------------

// Everything decided about a macroblock before it is written.
Macroblock_Choice :: struct {
	type:                   h264.Macroblock_Type,
	intra_16x16_mode:       h264.Intra_16x16_Mode,
	intra_4x4_modes:        [16]h264.Intra_4x4_Mode,
	chroma_prediction_mode: h264.Intra_Chroma_Mode,
	reference_indices:      [4]i8,
	motion_vectors:         [16][2]i16,
	luma_dc_coefficients:   [16]i16, // scan order (Intra 16x16)
	luma_coefficients:      [16][16]i16, // scan order per 4x4 block in decoding order (or 4x64 for 8x8)
	chroma_dc_coefficients: [2][4]i16,
	chroma_ac_coefficients: [2][4][16]i16,
	luma_coded_block_mask:  u8,
	chroma_residual_mode:   h264.Chroma_Residual_Mode,
	motion_search_cost:     i32, // integer motion-search SAD plus syntax cost
	is_skip:                bool, // candidate is P_Skip-eligible
	uses_8x8_transform:     bool,
	has_dc_coefficients:    [3]bool,
}

luma_8x8_block :: #force_inline proc(choice: ^Macroblock_Choice, block8: int) -> ^[64]i16 {
	return (^[64]i16)(&choice.luma_coefficients[block8 * 4])
}

// A macroblock candidate evaluated by rate/distortion: residual levels in
// `choice`, staged nonzero counts, and reconstruction tiles. Task-owned
// scratch; never escapes the macroblock decision.
Macroblock_Candidate :: struct {
	choice:                     Macroblock_Choice,
	nonzero_coefficient_counts: [24]u8,
	reconstructed_luma:         [256]u8, // 16x16, stride 16
	reconstructed_cb:           [64]u8, // 8x8, stride 8
	reconstructed_cr:           [64]u8,
	distortion:                 i32,
	bit_count:                  int,
}

// Availability of the neighbouring macroblocks for intra prediction
Neighbours :: struct {
	top, left, top_right, top_left: bool,
}

encode_slice_task :: proc(task: ^Slice_Task) {
	if task.next_macroblock == task.first_macroblock + task.macroblock_count do return
	for task.next_macroblock < task.work_limit {
		encode_macroblock(task, &task.writer, task.next_macroblock, &task.skip_run)
		task.next_macroblock += 1
	}
	if task.next_macroblock != task.first_macroblock + task.macroblock_count do return
	if task.state.config.cabac {
		common.cabac_enc_finish(&task.cabac.enc, false)
	} else if !task.is_idr && task.skip_run > 0 {
		h264.write_unsigned_exp_golomb(&task.writer, u32(task.skip_run))
	}
	h264.flush_bits_rbsp(&task.writer)
	clear(&task.nal)
	h264.write_nal_annex_b(&task.nal, task.is_idr ? 3 : 2, task.is_idr ? 5 : 1, task.rbsp[:])
}

macroblock_neighbours :: proc(
	grid: ^h264.Macroblock_Grid,
	macroblock_index: int,
) -> (
	neighbours: Neighbours,
) {
	macroblock_column := macroblock_index % grid.macroblock_columns
	neighbours.top = h264.macroblock_is_available(grid, macroblock_index - grid.macroblock_columns)
	neighbours.left =
		macroblock_column > 0 && h264.macroblock_is_available(grid, macroblock_index - 1)
	neighbours.top_right =
		macroblock_column < grid.macroblock_columns - 1 &&
		h264.macroblock_is_available(grid, macroblock_index - grid.macroblock_columns + 1)
	neighbours.top_left =
		macroblock_column > 0 &&
		h264.macroblock_is_available(grid, macroblock_index - grid.macroblock_columns - 1)
	return
}

encode_macroblock :: proc(
	task: ^Slice_Task,
	writer: ^h264.Bit_Writer,
	macroblock_index: int,
	skip_run: ^int,
) {
	state := task.state
	grid := &task.grid
	macroblock := &grid.macroblocks[macroblock_index]
	macroblock^ = {}
	macroblock.slice_index = task.grid.slice_index
	macroblock.quantizer = i8(task.quantizer)
	for reference_list in 0 ..< 2 do for index in 0 ..< 4 {
		macroblock.reference_indices[reference_list][index] = -1
		macroblock.reference_picture_ids[reference_list][index] = -1
	}
	macroblock_column, macroblock_row :=
		macroblock_index % grid.macroblock_columns, macroblock_index / grid.macroblock_columns
	source := &state.source
	reconstruction := &state.curr.buf
	source_luma: [^]u8 = &source.y[(macroblock_row * 16) * source.y_stride + macroblock_column * 16]
	source_cb: [^]u8 = &source.u[(macroblock_row * 8) * source.uv_stride + macroblock_column * 8]
	source_cr: [^]u8 = &source.v[(macroblock_row * 8) * source.uv_stride + macroblock_column * 8]
	reconstructed_luma: [^]u8 = &reconstruction.y[(macroblock_row * 16) * reconstruction.y_stride + macroblock_column * 16]
	motion_lambda := task.motion_lambda
	distortion_lambda := task.distortion_lambda
	neighbours := macroblock_neighbours(grid, macroblock_index)

	candidate: Macroblock_Candidate // one task-local candidate buffer, reused per mode
	selected_candidate: Macroblock_Candidate
	selected_cost := max(f64)
	inter_candidate: Macroblock_Candidate
	inter_candidate_cost := max(f64)
	evaluate_intra := true
	if !task.is_idr {
		evaluate_skip_candidate(
			task,
			macroblock,
			&inter_candidate,
			macroblock_index,
			source_luma,
			source.y_stride,
			source_cb,
			source_cr,
			source.uv_stride,
		)
		inter_candidate_cost = rate_distortion_cost(
			inter_candidate.distortion,
			inter_candidate.bit_count,
			distortion_lambda,
		)
		// A perfect skip attains the distortion/bit lower bound. The
		// small nonzero threshold is disabled by exhaustive_intra for RD comparisons.
		if inter_candidate.distortion == 0 ||
		   (!state.config.exhaustive_intra &&
				   f64(inter_candidate.distortion) <= distortion_lambda * 4) {
			selected_candidate = inter_candidate
			evaluate_intra = false
		} else {
			motion_choice: Macroblock_Choice
			select_inter_prediction(
				task,
				macroblock,
				&motion_choice,
				macroblock_index,
				source_luma,
				source.y_stride,
				motion_lambda,
				inter_candidate.distortion > 16384,
			)
			motion_choice.chroma_prediction_mode = .DC
			evaluate_inter_candidate(
				task,
				macroblock,
				&candidate,
				&inter_candidate,
				&inter_candidate_cost,
				&motion_choice,
				macroblock_index,
				source_luma,
				source.y_stride,
				source_cb,
				source_cr,
				source.uv_stride,
				distortion_lambda,
			)
			if !state.config.exhaustive_intra &&
			   (state.config.ultrafast ?
					   motion_choice.motion_search_cost <= 4096 + 16 * motion_lambda :
					   (inter_candidate.choice.is_skip && f64(inter_candidate.distortion) <= distortion_lambda * 16)) {
				selected_candidate = inter_candidate
				evaluate_intra = false
			}
		}
	}

	if evaluate_intra {
		// Every intra luma mode shares the same chroma prediction, residual
		// and neighbours. Code it once. Predictions read outside this MB,
		// so trials can overwrite its pixels without saving/restoring scratch.
		intra_chroma: Macroblock_Candidate
		evaluate_chroma_candidate(
			task,
			macroblock,
			&intra_chroma,
			macroblock_index,
			source_cb,
			source_cr,
			source.uv_stride,
			neighbours,
			true,
			motion_lambda,
		)
		chroma_cost := rate_distortion_cost(
			intra_chroma.distortion,
			intra_chroma.bit_count,
			distortion_lambda,
		)
		selected_mode := h264.Intra_16x16_Mode.DC
		prediction_cost := max(i32)
		for mode in ([4]h264.Intra_16x16_Mode{.DC, .Vertical, .Horizontal, .Plane}) {
			if (mode == .Vertical || mode == .Plane) && !neighbours.top do continue
			if (mode == .Horizontal || mode == .Plane) && !neighbours.left do continue
			h264.predict_intra_16x16(
				reconstructed_luma,
				reconstruction.y_stride,
				mode,
				neighbours.top,
				neighbours.left,
			)
			cost :=
				block_transformed_difference_sum(
					source_luma,
					source.y_stride,
					reconstructed_luma,
					reconstruction.y_stride,
					16,
					16,
				) +
				motion_lambda * unsigned_exp_golomb_bit_count(1 + u32(mode))
			if cost < prediction_cost do selected_mode, prediction_cost = mode, cost
		}
		if chroma_cost <= inter_candidate_cost {
			mode := selected_mode
			candidate.choice = {}
			candidate.choice.type = .I_16x16
			candidate.choice.intra_16x16_mode = mode
			macroblock.is_intra = true
			macroblock.is_skip = false
			macroblock.type = .I_16x16
			macroblock.intra_16x16_mode = mode
			// Staged record for the bit estimate: matches the writer's view.
			h264.predict_intra_16x16(
				reconstructed_luma,
				reconstruction.y_stride,
				mode,
				neighbours.top,
				neighbours.left,
			)
			code_luma_16x16(
				task,
				macroblock,
				&candidate.choice,
				source_luma,
				source.y_stride,
				reconstructed_luma,
				reconstruction.y_stride,
			)
			reuse_intra_chroma_candidate(macroblock, &candidate, &intra_chroma)
			score_macroblock_candidate(
				task,
				macroblock,
				&candidate,
				macroblock_index,
				source_luma,
				source.y_stride,
				source_cb,
				source_cr,
				source.uv_stride,
				&intra_chroma,
			)
			if cost := rate_distortion_cost(
				candidate.distortion,
				candidate.bit_count,
				distortion_lambda,
			); cost < selected_cost {
				selected_cost = cost
				retain_candidate_reconstruction(task, &candidate, macroblock_index)
				selected_candidate = candidate
			}
		}
		// Search the finer blocks after the coarse modes establish a bound.
		// Intra4 keeps the original tie preference over Intra16 and inter.
		intra_luma_cost: Intra_Luma_Cost
		if chroma_cost <= inter_candidate_cost &&
		   (!state.config.ultrafast || selected_cost > distortion_lambda * 64) &&
		   evaluate_intra_4x4_candidate(
			   task,
			   macroblock,
			   &candidate,
			   macroblock_index,
			   source_luma,
			   source.y_stride,
			   reconstructed_luma,
			   reconstruction.y_stride,
			   neighbours,
			   motion_lambda,
			   min(selected_cost, inter_candidate_cost) - chroma_cost,
			   &intra_luma_cost,
		   ) {
			reuse_intra_chroma_candidate(macroblock, &candidate, &intra_chroma)
			score_macroblock_candidate(
				task,
				macroblock,
				&candidate,
				macroblock_index,
				source_luma,
				source.y_stride,
				source_cb,
				source_cr,
				source.uv_stride,
				&intra_chroma,
				&intra_luma_cost,
			)
			if cost := rate_distortion_cost(
				candidate.distortion,
				candidate.bit_count,
				distortion_lambda,
			); cost <= selected_cost {
				selected_cost = cost
				retain_candidate_reconstruction(task, &candidate, macroblock_index)
				selected_candidate = candidate
			}
		}
		if state.config.transform_8x8 &&
		   chroma_cost <= inter_candidate_cost &&
		   (!state.config.ultrafast || selected_cost > distortion_lambda * 64) {
			evaluate_intra_8x8_candidate(
				task,
				macroblock,
				&candidate,
				macroblock_index,
				source_luma,
				source.y_stride,
				reconstructed_luma,
				reconstruction.y_stride,
				neighbours,
				motion_lambda,
			)
			reuse_intra_chroma_candidate(macroblock, &candidate, &intra_chroma)
			score_macroblock_candidate(
				task,
				macroblock,
				&candidate,
				macroblock_index,
				source_luma,
				source.y_stride,
				source_cb,
				source_cr,
				source.uv_stride,
				&intra_chroma,
			)
			if cost := rate_distortion_cost(
				candidate.distortion,
				candidate.bit_count,
				distortion_lambda,
			); cost <= selected_cost {
				selected_cost = cost
				retain_candidate_reconstruction(task, &candidate, macroblock_index)
				selected_candidate = candidate
			}
		}
		if inter_candidate_cost < selected_cost do selected_candidate = inter_candidate
	}

	choice := &selected_candidate.choice
	// Publish the selected coefficients' contexts and coded-block flags.
	for index in 0 ..< 24 do macroblock.nonzero_coefficient_counts[index] = selected_candidate.nonzero_coefficient_counts[index]
	macroblock.luma_coded_block_mask = choice.luma_coded_block_mask
	macroblock.chroma_residual_mode = choice.chroma_residual_mode
	macroblock.chroma_prediction_mode = choice.chroma_prediction_mode
	macroblock.uses_8x8_transform = choice.uses_8x8_transform
	macroblock.has_dc_coefficients = choice.has_dc_coefficients
	macroblock.has_8x8_coefficients = {}
	if choice.uses_8x8_transform {
		for b8 in 0 ..< 4 do macroblock.has_8x8_coefficients[b8] = (choice.luma_coded_block_mask & (1 << uint(b8))) != 0
	}
	macroblock.is_skip = false

	// Publish the retained pixels and prediction metadata for the selected mode.
	switch choice.type {
	case .I_4x4, .I_8x8:
		macroblock.is_intra = true
		macroblock.type = choice.type
		macroblock.intra_4x4_modes = choice.intra_4x4_modes
		publish_candidate_reconstruction(task, &selected_candidate, macroblock_index)
	case .I_16x16:
		macroblock.is_intra = true
		macroblock.type = .I_16x16
		macroblock.intra_16x16_mode = choice.intra_16x16_mode
		publish_candidate_reconstruction(task, &selected_candidate, macroblock_index)
	case .P_L0_16x16, .P_L0_L0_16x8, .P_L0_L0_8x16, .P_8x8:
		macroblock.is_intra = false
		macroblock.motion_vectors[0] = choice.motion_vectors
		task.last_inter_mv = choice.motion_vectors[0]
		for index in 0 ..< 4 {
			macroblock.reference_indices[0][index] = choice.reference_indices[index]
			macroblock.reference_picture_ids[0][index] =
				state.refs[choice.reference_indices[index]].pic_id
			macroblock.prediction_directions[index] = h264.Prediction_Direction.List_0
		}
		macroblock.type = choice.type
		if choice.type == .P_8x8 do macroblock.subpartition_types = {.List_0_8x8, .List_0_8x8, .List_0_8x8, .List_0_8x8}
		// P_Skip: one motion equal to the skip predictor and nothing coded
		if choice.is_skip {
			macroblock.type = .P_Skip
			macroblock.is_skip = true
		}
		if macroblock.type == .P_Skip {
			macroblock.luma_coded_block_mask = 0
			macroblock.chroma_residual_mode = .None
			macroblock.nonzero_coefficient_counts = {}
			macroblock.uses_8x8_transform = false
			macroblock.has_8x8_coefficients = {}
			macroblock.has_dc_coefficients = {}
			macroblock.motion_differences = {}
		}
		publish_candidate_reconstruction(task, &selected_candidate, macroblock_index)
	case .I_PCM,
	     .P_8x8ref0,
	     .P_Skip,
	     .B_Direct_16x16,
	     .B_16x16,
	     .B_16x8,
	     .B_8x16,
	     .B_8x8,
	     .B_Skip:
	}
	macroblock.has_uniform_motion = h264.uniform_motion(macroblock, 0, 16)

	// Syntax
	if state.config.cabac {
		is_last := macroblock_index + 1 == task.first_macroblock + task.macroblock_count
		if macroblock.is_skip {
			cabac_write_mb_skip(&task.cabac, grid, macroblock_index, true)
			task.cabac.prev_qp_delta_nz = false
		} else {
			if !task.is_idr do cabac_write_mb_skip(&task.cabac, grid, macroblock_index, false)
			write_macroblock_layer_cabac(task, &task.cabac, macroblock, choice, macroblock_index)
		}
		common.cabac_enc_terminate(&task.cabac.enc, is_last ? 1 : 0)
		return
	}
	if macroblock.is_skip {
		skip_run^ += 1
		return
	}
	if !task.is_idr {
		h264.write_unsigned_exp_golomb(writer, u32(skip_run^))
		skip_run^ = 0
	}
	// Write directly from the selected candidate's retained coefficient levels.
	write_macroblock_layer(task, writer, macroblock, choice, macroblock_index)
}


// Intra 4x4 mode of the neighbouring macroblock's block adjacent to the left or above position.
neighbour_intra_4x4_mode :: proc(
	grid: ^h264.Macroblock_Grid,
	macroblock_index: int,
	use_left_neighbour: bool,
	block_position: int,
) -> int {
	neighbour_index :=
		use_left_neighbour ? h264.left_macroblock(grid, macroblock_index) : h264.top_macroblock(grid, macroblock_index)
	if neighbour_index < 0 do return -1
	neighbour := &grid.macroblocks[neighbour_index]
	if neighbour.type != .I_4x4 && neighbour.type != .I_8x8 do return int(h264.Intra_4x4_Mode.DC)
	return int(
		neighbour.intra_4x4_modes[use_left_neighbour ? h264.xy_to_subblock(3, block_position) : h264.xy_to_subblock(block_position, 3)],
	)
}

// Transform, quantise, and reconstruct one 4x4 block whose prediction is in reconstruction; returns non-zero count
code_residual_4x4 :: proc(
	task: ^Slice_Task,
	source: [^]u8,
	source_stride: int,
	reconstruction: [^]u8,
	reconstruction_stride: int,
	levels: ^[16]i16,
	quantizer: i32,
	intra: bool,
	first_coefficient: int,
) -> int {
	q := prepare_quantizer_4x4(quantizer, intra)
	return code_residual_4x4_samples(
		task,
		h264.load_luma_block_4x4(source, source_stride),
		h264.load_luma_block_4x4(reconstruction, reconstruction_stride),
		reconstruction,
		reconstruction_stride,
		levels,
		&q,
		intra,
		first_coefficient,
	)
}

code_residual_4x4_samples :: #force_inline proc(
	task: ^Slice_Task,
	source, prediction: #simd[16]i16,
	reconstruction: [^]u8,
	reconstruction_stride: int,
	levels: ^[16]i16,
	q: ^Quantizer_4x4,
	intra: bool,
	first_coefficient: int,
) -> int {
	coefficients := forward_dct_4x4_samples(source, prediction)
	nonzero_count := quantize_4x4_prepared(&coefficients, levels, q, first_coefficient)
	if nonzero_count > 0 do h264.reconstruct_4x4(&task.state.scales, reconstruction, reconstruction_stride, levels, true, q.qp, intra ? 0 : 3, false, 0)
	return nonzero_count
}

// Intra 16x16 luma: AC per block, DC through the Hadamard
code_luma_16x16 :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	source_luma: [^]u8,
	source_stride: int,
	reconstructed_luma: [^]u8,
	reconstruction_stride: int,
) {
	quantizer := task.quantizer
	q := &task.state.frame.quantizers[0][1]
	dc_coefficients: [16]i32
	has_ac_coefficients := false
	for block in 0 ..< 16 {
		block_column, block_row := h264.subblock_to_xy(block)
		coefficients := forward_dct_4x4_samples(
			h264.load_luma_block_4x4(
				&source_luma[block_row * 4 * source_stride + block_column * 4],
				source_stride,
			),
			h264.load_luma_block_4x4(
				&reconstructed_luma[block_row * 4 * reconstruction_stride + block_column * 4],
				reconstruction_stride,
			),
		)
		dc_coefficients[block_row * 4 + block_column] = coefficients[0]
		nonzero_count := quantize_4x4_prepared(
			&coefficients,
			&choice.luma_coefficients[block],
			q,
			1,
		)
		macroblock.nonzero_coefficient_counts[block] = u8(nonzero_count)
		if nonzero_count > 0 do has_ac_coefficients = true
	}
	choice.luma_coded_block_mask = has_ac_coefficients ? 15 : 0
	if !has_ac_coefficients do macroblock.nonzero_coefficient_counts = {}
	hadamard := forward_hadamard_4x4(&dc_coefficients)
	choice.has_dc_coefficients[0] =
		quantize_dc_prepared(hadamard[:], choice.luma_dc_coefficients[:], h264.zigzag_scan_4x4[:], q) >
		0
	macroblock.has_dc_coefficients[0] = choice.has_dc_coefficients[0]
	reconstructed_dc_coefficients := choice.luma_dc_coefficients
	h264.luma_dc_dequant_idct(&task.state.scales, &reconstructed_dc_coefficients, quantizer)
	for block in 0 ..< 16 {
		block_column, block_row := h264.subblock_to_xy(block)
		h264.reconstruct_4x4(
			&task.state.scales,
			&reconstructed_luma[block_row * 4 * reconstruction_stride + block_column * 4],
			reconstruction_stride,
			&choice.luma_coefficients[block],
			has_ac_coefficients && macroblock.nonzero_coefficient_counts[block] > 0,
			quantizer,
			0,
			true,
			i32(reconstructed_dc_coefficients[block_row * 4 + block_column]),
		)
	}
}

// Code predicted macroblock luma as sixteen 4x4 residual blocks.
code_luma_4x4 :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	source_luma: [^]u8,
	source_stride: int,
	reconstructed_luma: [^]u8,
	reconstruction_stride: int,
	intra: bool,
	macroblock_index: int = -1,
) {
	choice.luma_coded_block_mask = 0
	q := &task.state.frame.quantizers[0][intra ? 1 : 0]
	for group in 0 ..< 4 {
		only_pred: #simd[16]i16 = ---
		only_sub := 0
		group_nz_count := 0
		for sub in 0 ..< 4 {
			block := group * 4 + sub
			block_column, block_row := h264.subblock_to_xy(block)
			src_vec := h264.load_luma_block_4x4(
				&source_luma[block_row * 4 * source_stride + block_column * 4],
				source_stride,
			)
			pred_vec := h264.load_luma_block_4x4(
				&reconstructed_luma[block_row * 4 * reconstruction_stride + block_column * 4],
				reconstruction_stride,
			)
			nonzero_count := code_residual_4x4_samples(
				task,
				src_vec,
				pred_vec,
				&reconstructed_luma[block_row * 4 * reconstruction_stride + block_column * 4],
				reconstruction_stride,
				&choice.luma_coefficients[block],
				q,
				intra,
				0,
			)
			macroblock.nonzero_coefficient_counts[block] = u8(nonzero_count)
			if nonzero_count > 0 {
				only_sub = sub
				only_pred = pred_vec
				group_nz_count += nonzero_count
			}
		}
		if group_nz_count > 0 {
			if !intra && macroblock_index >= 0 && group_nz_count == 1 {
				only_block := group * 4 + only_sub
				bx, by := h264.subblock_to_xy(only_block)
				src_ptr: [^]u8 = &source_luma[by * 4 * source_stride + bx * 4]
				rec_ptr: [^]u8 = &reconstructed_luma[by * 4 * reconstruction_stride + bx * 4]
				rec_ssd := block_squared_difference_sum(src_ptr, source_stride, rec_ptr, reconstruction_stride, 4, 4)
				bits := 1
				for sub in 0 ..< 4 {
					block := group * 4 + sub
					nc := h264.cavlc_neighbour_coefficient_count(&task.grid, macroblock_index, block, false)
					bits += sub == only_sub ? cavlc_coefficient_bit_count(choice.luma_coefficients[block][:], nc) : cavlc_zero_coefficient_bit_count(nc)
				}
				h264.store_luma_block_4x4(rec_ptr, reconstruction_stride, only_pred)
				pred_ssd := block_squared_difference_sum(src_ptr, source_stride, rec_ptr, reconstruction_stride, 4, 4)
				if f64(rec_ssd) + task.distortion_lambda * f64(bits) >= f64(pred_ssd) {
					choice.luma_coefficients[only_block] = {}
					macroblock.nonzero_coefficient_counts[only_block] = 0
					continue
				}
				h264.reconstruct_4x4(&task.state.scales, rec_ptr, reconstruction_stride, &choice.luma_coefficients[only_block], true, q.qp, 3, false, 0)
			}
			choice.luma_coded_block_mask |= 1 << uint(group)
		}
	}
}

code_residual_8x8_samples :: proc(
	task: ^Slice_Task,
	source: [^]u8,
	source_stride: int,
	reconstruction: [^]u8,
	reconstruction_stride: int,
	levels: ^[64]i16,
	q: ^Quantizer_8x8,
	intra: bool,
) -> int {
	coefficients := forward_dct_8x8_samples(
		source,
		source_stride,
		reconstruction,
		reconstruction_stride,
	)
	nonzero_count := quantize_8x8_prepared(&coefficients, levels, q)
	if nonzero_count > 0 {
		h264.reconstruct_8x8(
			&task.state.scales,
			reconstruction,
			reconstruction_stride,
			levels,
			q.qp,
			intra ? 0 : 1,
		)
	}
	return nonzero_count
}

cavlc_deinterleave_8x8 :: #force_inline proc(levels: ^[64]i16, sub: int) -> (sub_levels: [16]i16, nz: u8) {
	for k in 0 ..< 16 {
		val := levels[4 * k + sub]
		sub_levels[k] = val
		if val != 0 do nz += 1
	}
	return
}

// Code predicted macroblock luma as four 8x8 residual blocks.
code_luma_8x8 :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	source_luma: [^]u8,
	source_stride: int,
	reconstructed_luma: [^]u8,
	reconstruction_stride: int,
	intra: bool,
) {
	choice.luma_coded_block_mask = 0
	choice.uses_8x8_transform = true
	q := &task.state.frame.quantizers_8x8[intra ? 1 : 0]
	for block8 in 0 ..< 4 {
		bx, by := (block8 & 1) * 8, (block8 >> 1) * 8
		levels := luma_8x8_block(choice, block8)
		nonzero_count := code_residual_8x8_samples(
			task,
			&source_luma[by * source_stride + bx],
			source_stride,
			&reconstructed_luma[by * reconstruction_stride + bx],
			reconstruction_stride,
			levels,
			q,
			intra,
		)
		has_nz := nonzero_count > 0
		macroblock.has_8x8_coefficients[block8] = has_nz
		for sub in 0 ..< 4 {
			_, sub_nz := cavlc_deinterleave_8x8(levels, sub)
			macroblock.nonzero_coefficient_counts[block8 * 4 + sub] = sub_nz
		}
		if has_nz {
			choice.luma_coded_block_mask |= 1 << uint(block8)
		}
	}
	if !intra && choice.luma_coded_block_mask == 0 {
		// ITU-T H.264 7.3.5: transform_size_8x8_flag is only present on inter MBs
		// when CodedBlockPatternLuma > 0; otherwise 4x4 transform is inferred.
		choice.uses_8x8_transform = false
	}
	macroblock.uses_8x8_transform = choice.uses_8x8_transform
}

// Chroma residual of both planes whose prediction is in reconstruction: DC through the 2x2 Hadamard
code_chroma_residual :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	macroblock_index: int,
	intra: bool,
) {
	state := task.state
	source := &state.source
	reconstruction := &state.curr.buf
	macroblock_column, macroblock_row :=
		macroblock_index %
		task.grid.macroblock_columns,
		macroblock_index /
		task.grid.macroblock_columns
	q := &state.frame.quantizers[1][intra ? 1 : 0]
	quantizer := q.qp
	has_ac_coefficients, has_dc_coefficients := false, false
	for plane in 0 ..< 2 {
		source_plane: [^]u8 =
			plane == 0 ? &source.u[(macroblock_row * 8) * source.uv_stride + macroblock_column * 8] : &source.v[(macroblock_row * 8) * source.uv_stride + macroblock_column * 8]
		reconstructed_plane: [^]u8 =
			plane == 0 ? &reconstruction.u[(macroblock_row * 8) * reconstruction.uv_stride + macroblock_column * 8] : &reconstruction.v[(macroblock_row * 8) * reconstruction.uv_stride + macroblock_column * 8]
		dc_coefficients: [4]i32
		for block in 0 ..< 4 {
			block_column, block_row := (block & 1) * 4, (block >> 1) * 4
			coefficients := forward_dct_4x4_samples(
				h264.load_luma_block_4x4(
					&source_plane[block_row * source.uv_stride + block_column],
					source.uv_stride,
				),
				h264.load_luma_block_4x4(
					&reconstructed_plane[block_row * reconstruction.uv_stride + block_column],
					reconstruction.uv_stride,
				),
			)
			dc_coefficients[block] = coefficients[0]
			nonzero_count := quantize_4x4_prepared(
				&coefficients,
				&choice.chroma_ac_coefficients[plane][block],
				q,
				1,
			)
			macroblock.nonzero_coefficient_counts[16 + plane * 4 + block] = u8(nonzero_count)
			if nonzero_count > 0 do has_ac_coefficients = true
		}
		hadamard := forward_hadamard_2x2(dc_coefficients)
		dc_nz :=
			quantize_dc_prepared(
				hadamard[:],
				choice.chroma_dc_coefficients[plane][:],
				h264.chroma_dc_scan[:],
				q,
			) >
			0
		choice.has_dc_coefficients[1 + plane] = dc_nz
		macroblock.has_dc_coefficients[1 + plane] = dc_nz
		if dc_nz do has_dc_coefficients = true
	}
	choice.chroma_residual_mode =
		has_ac_coefficients ? .DC_And_AC : has_dc_coefficients ? .DC_Only : .None
	if !has_ac_coefficients do for index in 16 ..< 24 do macroblock.nonzero_coefficient_counts[index] = 0
	list := intra ? 1 : 4
	for plane in 0 ..< 2 {
		reconstructed_plane: [^]u8 =
			plane == 0 ? &reconstruction.u[(macroblock_row * 8) * reconstruction.uv_stride + macroblock_column * 8] : &reconstruction.v[(macroblock_row * 8) * reconstruction.uv_stride + macroblock_column * 8]
		reconstructed_dc_coefficients := choice.chroma_dc_coefficients[plane]
		h264.chroma_dc_dequant_idct(
			&state.scales,
			&reconstructed_dc_coefficients,
			quantizer,
			list + plane,
		)
		for block in 0 ..< 4 {
			h264.reconstruct_4x4(
				&state.scales,
				&reconstructed_plane[(block >> 1) * 4 * reconstruction.uv_stride + (block & 1) * 4],
				reconstruction.uv_stride,
				&choice.chroma_ac_coefficients[plane][block],
				has_ac_coefficients &&
				macroblock.nonzero_coefficient_counts[16 + plane * 4 + block] > 0,
				quantizer,
				list + plane,
				true,
				i32(reconstructed_dc_coefficients[block]),
			)
		}
	}
}


// Motion compensated prediction of all partitions into the reconstruction picture
predict_inter_macroblock_encoder :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	macroblock_index: int,
) {
	state := task.state
	reconstruction := &state.curr.buf
	macroblock_column, macroblock_row :=
		macroblock_index %
		task.grid.macroblock_columns,
		macroblock_index /
		task.grid.macroblock_columns
	predict_partition :: proc(
		state: ^Encoder_State,
		reconstruction: ^h264.YUV_Buffer,
		macroblock: #soa^#soa[]h264.Macroblock,
		pixel_column, pixel_row, partition_block, partition_width, partition_height: int,
	) {
		reference := state.refs[macroblock.reference_indices[0][partition_block / 4]]
		target := h264.prediction_target(u8, reconstruction, pixel_column, pixel_row)
		h264.motion_compensate(
			&reference.buf,
			pixel_column,
			pixel_row,
			partition_width,
			partition_height,
			macroblock.motion_vectors[0][partition_block],
			&target,
		)
	}
	switch macroblock.type {
	case .P_L0_16x16:
		predict_partition(
			state,
			reconstruction,
			macroblock,
			macroblock_column * 16,
			macroblock_row * 16,
			0,
			16,
			16,
		)
	case .P_L0_L0_16x8:
		predict_partition(
			state,
			reconstruction,
			macroblock,
			macroblock_column * 16,
			macroblock_row * 16,
			0,
			16,
			8,
		)
		predict_partition(
			state,
			reconstruction,
			macroblock,
			macroblock_column * 16,
			macroblock_row * 16 + 8,
			8,
			16,
			8,
		)
	case .P_L0_L0_8x16:
		predict_partition(
			state,
			reconstruction,
			macroblock,
			macroblock_column * 16,
			macroblock_row * 16,
			0,
			8,
			16,
		)
		predict_partition(
			state,
			reconstruction,
			macroblock,
			macroblock_column * 16 + 8,
			macroblock_row * 16,
			4,
			8,
			16,
		)
	case .P_8x8:
		for index in 0 ..< 4 do predict_partition(state, reconstruction, macroblock, macroblock_column * 16 + (index & 1) * 8, macroblock_row * 16 + (index >> 1) * 8, index * 4, 8, 8)
	case .I_4x4,
	     .I_8x8,
	     .I_16x16,
	     .I_PCM,
	     .P_8x8ref0,
	     .P_Skip,
	     .B_Direct_16x16,
	     .B_16x16,
	     .B_16x8,
	     .B_8x16,
	     .B_8x8,
	     .B_Skip:
	}
}

// Motion search over 16x16, 16x8, 8x16 and 8x8 partitions and all references
select_inter_prediction :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	macroblock_index: int,
	source_luma: [^]u8,
	source_stride: int,
	motion_lambda: i32,
	wide_search := false,
) {
	state := task.state

	search_radius := state.config.search_range > 0 ? state.config.search_range : 16
	reference_index_bit_count :: proc(state: ^Encoder_State, reference_index: int) -> i32 {
		return state.num_refs > 1 ? unsigned_exp_golomb_bit_count(u32(reference_index)) : 0
	}
	// leave the record clean for the final assignment
	defer {
		macroblock.motion_vectors[0] = {}
		for index in 0 ..< 4 {
			macroblock.reference_indices[0][index] = -1
			macroblock.prediction_directions[index] = .None
		}
	}
	defer refine_inter_prediction(
		task,
		macroblock,
		choice,
		macroblock_index,
		source_luma,
		source_stride,
		motion_lambda,
	)

	// Stage each candidate so motion prediction sees earlier partitions.
	stage_partition_motion :: proc(
		macroblock: #soa^#soa[]h264.Macroblock,
		block, width, height: int,
		reference_index: i8,
		motion: [2]i16,
	) {
		block_column, block_row := h264.subblock_to_xy(block)
		for y in 0 ..< height do for x in 0 ..< width do macroblock.motion_vectors[0][h264.xy_to_subblock(block_column + x, block_row + y)] = motion
		for y in 0 ..< height / 2 do for x in 0 ..< width / 2 {
			macroblock.reference_indices[0][(block_row / 2 + y) * 2 + block_column / 2 + x] = reference_index
			macroblock.prediction_directions[(block_row / 2 + y) * 2 + block_column / 2 + x] = h264.Prediction_Direction.List_0
		}
	}
	search_partition_motion :: proc(
		task: ^Slice_Task,
		macroblock: #soa^#soa[]h264.Macroblock,
		macroblock_index, block, width, height: int,
		reference_index: int,
		source_luma: [^]u8,
		source_stride: int,
		motion_lambda: i32,
		search_radius: int,
		wide_search: bool,
	) -> (
		[2]i16,
		i32,
	) {
		grid := &task.grid
		block_column, block_row := h264.subblock_to_xy(block)
		predictor := h264.predict_motion_vector(
			grid,
			macroblock_index,
			0,
			block,
			width,
			height,
			i8(reference_index),
		)
		search_region := Motion_Search_Region {
			reference        = task.state.refs[reference_index],
			source           = &source_luma[block_row * 4 * source_stride + block_column * 4],
			source_stride    = source_stride,
			column           = (macroblock_index % grid.macroblock_columns) *
				16 + block_column * 4,
			row              = (macroblock_index / grid.macroblock_columns) * 16 + block_row * 4,
			block_width      = width * 4,
			block_height     = height * 4,
			predicted_motion = predictor,
			motion_lambda    = motion_lambda,
			search_radius    = search_radius,
		}
		left_neighbour, top_neighbour, top_right_neighbour := h264.partition_neighbours(
			grid,
			macroblock_index,
			0,
			block,
			width,
		)
		r := i16(search_radius * 4)
		candidates := [31][2]i16 {
			predictor,
			{0, 0},
			left_neighbour.mv,
			top_neighbour.mv,
			top_right_neighbour.mv,
			task.last_inter_mv,
			task.last_search_mv,
			{-r, 0},
			{r, 0},
			{0, -r},
			{0, r},
			{-r, -r},
			{r, -r},
			{-r, r},
			{r, r},
			{-2 * r, 0},
			{2 * r, 0},
			{0, -2 * r},
			{0, 2 * r},
			{-2 * r, -2 * r},
			{2 * r, -2 * r},
			{-2 * r, 2 * r},
			{2 * r, 2 * r},
			{-3 * r, 0},
			{3 * r, 0},
			{0, -3 * r},
			{0, 3 * r},
			{-3 * r, -2 * r},
			{3 * r, -2 * r},
			{-3 * r, 2 * r},
			{3 * r, 2 * r},
		}
		motion, cost := search_integer_motion(&search_region, candidates[:7])
		// A poorly predicted 16x16 also descends from the best point of a
		// grid out to three search radii (pans faster than the radius), and
		// keeps whichever descent ends cheaper.
		if width == 4 && height == 4 && wide_search {
			if wide, wide_cost := search_integer_motion(&search_region, candidates[7:]); wide_cost < cost do motion, cost = wide, wide_cost
		}
		return motion, cost
	}

	// 16x16 over all references
	selected_reference := 0
	selected_motion: [2]i16
	selected_cost := max(i32)
	max_refs := state.config.ultrafast ? min(state.num_refs, 1) : state.num_refs
	for reference_index in 0 ..< max_refs {
		motion, cost := search_partition_motion(
			task,
			macroblock,
			macroblock_index,
			0,
			4,
			4,
			reference_index,
			source_luma,
			source_stride,
			motion_lambda,
			search_radius,
			wide_search,
		)
		cost += motion_lambda * reference_index_bit_count(state, reference_index)
		if cost < selected_cost {
			selected_cost, selected_motion, selected_reference = cost, motion, reference_index
		}
	}
	choice.type = .P_L0_16x16
	choice.motion_search_cost = selected_cost + motion_lambda * 1
	task.last_search_mv = selected_motion
	for index in 0 ..< 4 do choice.reference_indices[index] = i8(selected_reference)
	for index in 0 ..< 16 do choice.motion_vectors[index] = selected_motion

	// Smaller partitions with the chosen reference. A 16x16 match already near
	// the vector-only floor is unlikely to improve enough to pay for more vectors.
	reference_index := selected_reference
	partition_cost := motion_lambda * (reference_index_bit_count(state, reference_index) * 2 + 3)
	if state.config.ultrafast || selected_cost < partition_cost + 16 * motion_lambda do return
	stage_partition_motion(macroblock, 0, 4, 4, i8(reference_index), selected_motion)
	first_motion, first_cost := search_partition_motion(
		task,
		macroblock,
		macroblock_index,
		0,
		4,
		2,
		reference_index,
		source_luma,
		source_stride,
		motion_lambda,
		search_radius,
		false,
	)
	stage_partition_motion(macroblock, 0, 4, 2, i8(reference_index), first_motion)
	second_motion, second_cost := search_partition_motion(
		task,
		macroblock,
		macroblock_index,
		8,
		4,
		2,
		reference_index,
		source_luma,
		source_stride,
		motion_lambda,
		search_radius,
		false,
	)
	if first_cost + second_cost + partition_cost < choice.motion_search_cost {
		choice.type = .P_L0_L0_16x8
		choice.motion_search_cost = first_cost + second_cost + partition_cost
		for index in 0 ..< 8 do choice.motion_vectors[index] = first_motion
		for index in 8 ..< 16 do choice.motion_vectors[index] = second_motion
	}
	stage_partition_motion(macroblock, 0, 4, 4, i8(reference_index), selected_motion)
	first_motion, first_cost = search_partition_motion(
		task,
		macroblock,
		macroblock_index,
		0,
		2,
		4,
		reference_index,
		source_luma,
		source_stride,
		motion_lambda,
		search_radius,
		false,
	)
	stage_partition_motion(macroblock, 0, 2, 4, i8(reference_index), first_motion)
	second_motion, second_cost = search_partition_motion(
		task,
		macroblock,
		macroblock_index,
		4,
		2,
		4,
		reference_index,
		source_luma,
		source_stride,
		motion_lambda,
		search_radius,
		false,
	)
	if first_cost + second_cost + partition_cost < choice.motion_search_cost {
		choice.type = .P_L0_L0_8x16
		choice.motion_search_cost = first_cost + second_cost + partition_cost
		for index in 0 ..< 16 do choice.motion_vectors[index] = subblock_coordinates(index).x < 2 ? first_motion : second_motion
	}
	// Search 8x8 only when a rectangular split already paid for itself.
	if choice.type == .P_L0_16x16 do return
	stage_partition_motion(macroblock, 0, 4, 4, i8(reference_index), selected_motion)
	eight_pixel_cost := motion_lambda * (reference_index_bit_count(state, reference_index) * 4 + 7)
	partition_motions: [4][2]i16
	for index in 0 ..< 4 {
		motion, cost := search_partition_motion(
			task,
			macroblock,
			macroblock_index,
			index * 4,
			2,
			2,
			reference_index,
			source_luma,
			source_stride,
			motion_lambda,
			search_radius,
			false,
		)
		stage_partition_motion(macroblock, index * 4, 2, 2, i8(reference_index), motion)
		partition_motions[index] = motion
		eight_pixel_cost += cost
	}
	if eight_pixel_cost < choice.motion_search_cost {
		choice.type = .P_8x8
		choice.motion_search_cost = eight_pixel_cost
		for index in 0 ..< 16 do choice.motion_vectors[index] = partition_motions[index / 4]
	}
}

refine_inter_prediction :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	candidate: ^Macroblock_Choice,
	macroblock_index: int,
	source: [^]u8,
	source_stride: int,
	motion_lambda: i32,
) {
	macroblock.motion_vectors[0] = candidate.motion_vectors
	macroblock.reference_indices[0] = candidate.reference_indices
	eight_pixel_partitions := [4]h264.Partition{{0, 2, 2}, {4, 2, 2}, {8, 2, 2}, {12, 2, 2}}
	partitions := h264.macroblock_partitions(candidate.type)
	if candidate.type == .P_8x8 do partitions = eight_pixel_partitions[:]
	for partition in partitions {
		column, row := h264.subblock_to_xy(partition.block)
		reference_index := candidate.reference_indices[partition.block / 4]
		search := Motion_Search_Region {
			reference        = task.state.refs[reference_index],
			source           = &source[row * 4 * source_stride + column * 4],
			source_stride    = source_stride,
			column           = macroblock_index % task.grid.macroblock_columns * 16 + column * 4,
			row              = macroblock_index / task.grid.macroblock_columns * 16 + row * 4,
			block_width      = partition.width * 4,
			block_height     = partition.height * 4,
			predicted_motion = h264.predict_motion_vector(
				&task.grid,
				macroblock_index,
				0,
				partition.block,
				partition.width,
				partition.height,
				reference_index,
			),
			motion_lambda    = motion_lambda,
		}
		motion, _ := refine_subpixel_motion(&search, candidate.motion_vectors[partition.block])
		for y in 0 ..< partition.height do for x in 0 ..< partition.width {
			block := h264.xy_to_subblock(column + x, row + y)
			candidate.motion_vectors[block] = motion
			macroblock.motion_vectors[0][block] = motion
		}
	}
}

subblock_coordinates :: proc(block: int) -> (coordinates: struct {
		x, y: int,
	}) {
	coordinates.x, coordinates.y = h264.subblock_to_xy(block)
	return
}

// ---------------------------------------------------------------------------
// macroblock_layer( ) in CAVLC (7.3.5)
// ---------------------------------------------------------------------------

write_macroblock_layer :: proc(
	task: ^Slice_Task,
	writer: ^h264.Bit_Writer,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	macroblock_index: int,
) {
	state := task.state
	grid := &task.grid
	intra_type: u32
	switch macroblock.type {
	case .I_4x4, .I_8x8:
		intra_type = 0
	case .I_16x16:
		intra_type =
			1 +
			u32(macroblock.intra_16x16_mode) +
			4 * u32(macroblock.chroma_residual_mode) +
			(macroblock.luma_coded_block_mask != 0 ? 12 : 0)
	case .I_PCM,
	     .P_L0_16x16,
	     .P_L0_L0_16x8,
	     .P_L0_L0_8x16,
	     .P_8x8,
	     .P_8x8ref0,
	     .P_Skip,
	     .B_Direct_16x16,
	     .B_16x16,
	     .B_16x8,
	     .B_8x16,
	     .B_8x8,
	     .B_Skip:
	}
	if task.is_idr {
		h264.write_unsigned_exp_golomb(writer, intra_type)
	} else {
		switch macroblock.type {
		case .P_L0_16x16:
			h264.write_unsigned_exp_golomb(writer, 0)
		case .P_L0_L0_16x8:
			h264.write_unsigned_exp_golomb(writer, 1)
		case .P_L0_L0_8x16:
			h264.write_unsigned_exp_golomb(writer, 2)
		case .P_8x8:
			h264.write_unsigned_exp_golomb(writer, 3)
		case .I_4x4, .I_8x8, .I_16x16:
			h264.write_unsigned_exp_golomb(writer, 5 + intra_type)
		case .I_PCM,
		     .P_8x8ref0,
		     .P_Skip,
		     .B_Direct_16x16,
		     .B_16x16,
		     .B_16x8,
		     .B_8x16,
		     .B_8x8,
		     .B_Skip:
		}
	}

	switch macroblock.type {
	case .I_4x4, .I_8x8:
		if state.config.transform_8x8 {
			h264.write_bits(writer, macroblock.type == .I_8x8 ? 1 : 0, 1)
		}
		block_count := macroblock.type == .I_8x8 ? 4 : 16
		for idx in 0 ..< block_count {
			block := macroblock.type == .I_8x8 ? idx * 4 : idx
			block_column, block_row := h264.subblock_to_xy(block)
			left_mode :=
				block_column > 0 ? int(macroblock.intra_4x4_modes[h264.xy_to_subblock(block_column - 1, block_row)]) : neighbour_intra_4x4_mode(grid, macroblock_index, true, block_row)
			top_mode :=
				block_row > 0 ? int(macroblock.intra_4x4_modes[h264.xy_to_subblock(block_column, block_row - 1)]) : neighbour_intra_4x4_mode(grid, macroblock_index, false, block_column)
			predicted :=
				left_mode < 0 || top_mode < 0 ? int(h264.Intra_4x4_Mode.DC) : min(left_mode, top_mode)
			mode := int(macroblock.intra_4x4_modes[block])
			if mode == predicted {
				h264.write_bits(writer, 1, 1)
			} else {
				h264.write_bits(writer, 0, 1)
				h264.write_bits(writer, u32(mode < predicted ? mode : mode - 1), 3)
			}
		}
		h264.write_unsigned_exp_golomb(writer, u32(macroblock.chroma_prediction_mode))
	case .I_16x16:
		h264.write_unsigned_exp_golomb(writer, u32(macroblock.chroma_prediction_mode))
	case .P_L0_16x16, .P_L0_L0_16x8, .P_L0_L0_8x16:
		partitions := h264.macroblock_partitions(macroblock.type)
		for partition in partitions do if state.num_refs > 1 do write_truncated_exp_golomb(writer, u32(macroblock.reference_indices[0][partition.block / 4]), u32(state.num_refs - 1))
		for partition in partitions {
			predictor := h264.predict_motion_vector(
				grid,
				macroblock_index,
				0,
				partition.block,
				partition.width,
				partition.height,
				macroblock.reference_indices[0][partition.block / 4],
			)
			h264.write_signed_exp_golomb(
				writer,
				i32(macroblock.motion_vectors[0][partition.block][0]) - i32(predictor[0]),
			)
			h264.write_signed_exp_golomb(
				writer,
				i32(macroblock.motion_vectors[0][partition.block][1]) - i32(predictor[1]),
			)
		}
	case .P_8x8:
		for _ in 0 ..< 4 do h264.write_unsigned_exp_golomb(writer, 0) // sub_mb_type P_L0_8x8
		if state.num_refs > 1 do for index in 0 ..< 4 do write_truncated_exp_golomb(writer, u32(macroblock.reference_indices[0][index]), u32(state.num_refs - 1))
		for index in 0 ..< 4 {
			predictor := h264.predict_motion_vector(
				grid,
				macroblock_index,
				0,
				index * 4,
				2,
				2,
				macroblock.reference_indices[0][index],
			)
			h264.write_signed_exp_golomb(
				writer,
				i32(macroblock.motion_vectors[0][index * 4][0]) - i32(predictor[0]),
			)
			h264.write_signed_exp_golomb(
				writer,
				i32(macroblock.motion_vectors[0][index * 4][1]) - i32(predictor[1]),
			)
		}
	case .I_PCM,
	     .P_8x8ref0,
	     .P_Skip,
	     .B_Direct_16x16,
	     .B_16x16,
	     .B_16x8,
	     .B_8x16,
	     .B_8x8,
	     .B_Skip:
	}

	if macroblock.type != .I_16x16 {
		h264.write_unsigned_exp_golomb(
			writer,
			coded_block_pattern_code(
				macroblock.luma_coded_block_mask | u8(macroblock.chroma_residual_mode) << 4,
				macroblock.is_intra,
			),
		)
		if state.config.transform_8x8 &&
		   macroblock.luma_coded_block_mask != 0 &&
		   !macroblock.is_intra {
			h264.write_bits(writer, macroblock.uses_8x8_transform ? 1 : 0, 1)
		}
	}
	if macroblock.luma_coded_block_mask != 0 || macroblock.chroma_residual_mode != .None || macroblock.type == .I_16x16 do h264.write_signed_exp_golomb(writer, 0) // mb_qp_delta

	if macroblock.type == .I_16x16 {
		write_cavlc_block(
			writer,
			choice.luma_dc_coefficients[:],
			h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, 0, false),
		)
		if macroblock.luma_coded_block_mask != 0 do for block in 0 ..< 16 do write_cavlc_block(writer, choice.luma_coefficients[block][1:], h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, block, false))
	} else if macroblock.uses_8x8_transform {
		for block8 in 0 ..< 4 {
			if macroblock.luma_coded_block_mask & (1 << uint(block8)) != 0 {
				levels8 := luma_8x8_block(choice, block8)
				for sub in 0 ..< 4 {
					sub_levels, _ := cavlc_deinterleave_8x8(levels8, sub)
					block := block8 * 4 + sub
					write_cavlc_block(
						writer,
						sub_levels[:],
						h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, block, false),
					)
				}
			}
		}
	} else {
		for block in 0 ..< 16 {
			if macroblock.luma_coded_block_mask & (1 << uint(block / 4)) != 0 do write_cavlc_block(writer, choice.luma_coefficients[block][:], h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, block, false))
		}
	}
	if macroblock.chroma_residual_mode != .None do for plane in 0 ..< 2 do write_cavlc_block(writer, choice.chroma_dc_coefficients[plane][:], -1)
	if macroblock.chroma_residual_mode == .DC_And_AC do for plane in 0 ..< 2 do for block in 0 ..< 4 {
		write_cavlc_block(writer, choice.chroma_ac_coefficients[plane][block][1:], h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, plane * 4 + block, true))
	}
}

// te(v) with range x: a single inverted bit when the range is 1
write_truncated_exp_golomb :: proc(writer: ^h264.Bit_Writer, value, value_range: u32) {
	if value_range == 1 {
		h264.write_bits(writer, value == 0 ? 1 : 0, 1)
	} else {
		h264.write_unsigned_exp_golomb(writer, value)
	}
}

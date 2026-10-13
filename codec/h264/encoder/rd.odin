package h264_encoder

import h264 ".."

import "base:intrinsics"
import "core:math"
import "core:simd"

// ---------------------------------------------------------------------------
// Rate-distortion decision kernels: SSD distortion after reconstruction plus
// exact CAVLC bit estimates, combined as SSD + lambda * bits.
// Motion search uses SAD for integer partitions and SATD for subpixel refinement.
// ---------------------------------------------------------------------------

// Sum of squared reconstruction differences. Macroblock geometry establishes
// the valid pixel ranges at the call sites.
block_squared_difference_sum :: proc(
	source: [^]u8,
	source_stride: int,
	prediction: [^]u8,
	prediction_stride: int,
	width, height: int,
) -> i32 #no_bounds_check {
	switch width {
	case 16:
		return squared_difference_sum(
			16,
			source,
			source_stride,
			prediction,
			prediction_stride,
			height,
		)
	case 8:
		return squared_difference_sum(
			8,
			source,
			source_stride,
			prediction,
			prediction_stride,
			height,
		)
	case 4:
		return squared_difference_sum(
			4,
			source,
			source_stride,
			prediction,
			prediction_stride,
			height,
		)
	}
	sum: i32
	for row in 0 ..< height {
		source_row: [^]u8 = &source[row * source_stride]
		prediction_row: [^]u8 = &prediction[row * prediction_stride]
		for column in 0 ..< width {
			difference := i32(source_row[column]) - i32(prediction_row[column])
			sum += difference * difference
		}
	}
	return sum
}

squared_difference_sum :: #force_inline proc(
	$Width: int,
	source: [^]u8,
	source_stride: int,
	prediction: [^]u8,
	prediction_stride: int,
	height: int,
) -> i32 {
	total: #simd[Width]i32
	for row in 0 ..< height {
		difference := (#simd[Width]i32)(
			simd.sub(
				h264.load_lanes(Width, &source[row * source_stride]),
				h264.load_lanes(Width, &prediction[row * prediction_stride]),
			),
		)
		total = simd.add(total, simd.mul(difference, difference))
	}
	return simd.reduce_add_ordered(total)
}

// SSD Lagrange multiplier for QP: 0.85 * 2^((qp - 12) / 3).
distortion_lambda_for_qp :: proc(qp: i32) -> f64 {
	return 0.85 * math.pow(2.0, f64(clamp(qp, 0, 51) - 12) / 3.0)
}

rate_distortion_cost :: #force_inline proc(
	distortion: i32,
	bit_count: int,
	distortion_lambda: f64,
) -> f64 {
	return f64(distortion) + distortion_lambda * f64(bit_count)
}

// Amortized cost of one more skipped macroblock in a skip run.
ESTIMATED_SKIP_BITS :: 1

// Exact facts accumulated while selecting all sixteen intra luma blocks.
// Chroma and macroblock headers have separate owners; no combined floating
// point RD cost is retained, so the final score keeps its original rounding.
Intra_Luma_Cost :: struct {
	distortion:      i32,
	prediction_bits: int,
	residual_bits:   int,
}

@(private)
cavlc_coefficient_token_table :: #force_inline proc(neighbour_count: i8) -> int {
	return(
		neighbour_count < 0 ? 4 : neighbour_count < 2 ? 0 : neighbour_count < 4 ? 1 : neighbour_count < 8 ? 2 : 3 \
	)
}

// Residual coding already owns an exact count for each native AC/luma block.
// Empty blocks still emit a token selected by their actual nC, but do not
// need another coefficient load/mask/reduction. General/DC callers scan below.
@(private)
cavlc_zero_coefficient_bit_count :: #force_inline proc(neighbour_count: i8) -> int {
	return int(vlc_coeff_token_enc[cavlc_coefficient_token_table(neighbour_count)][0][0][1])
}

// Exact bit count of residual_block_cavlc: mirrors write_cavlc_block
// (encoder_cavlc.odin) but accumulates lengths instead of emitting bits.
cavlc_coefficient_bit_count :: proc(levels: []i16, neighbour_count: i8) -> int {
	remaining := nonzero_coefficient_mask(levels)
	nonzero_count := int(intrinsics.count_ones(remaining))
	last_position := 31 - int(intrinsics.count_leading_zeros(remaining))
	total_zeros := last_position + 1 - nonzero_count
	trailing_ones := 0
	trailing_mask := remaining
	for trailing_ones < min(nonzero_count, 3) {
		position := 31 - int(intrinsics.count_leading_zeros(trailing_mask))
		if abs(levels[position]) != 1 do break
		trailing_ones += 1
		trailing_mask &~= u32(1) << uint(position)
	}
	table := cavlc_coefficient_token_table(neighbour_count)
	bit_count := int(vlc_coeff_token_enc[table][nonzero_count][trailing_ones][1])
	if nonzero_count == 0 do return bit_count
	bit_count += trailing_ones
	if nonzero_count < len(levels) {
		zero_code :=
			neighbour_count < 0 ? vlc_total_zeros_chroma_dc_enc[nonzero_count][total_zeros] : vlc_total_zeros_enc[nonzero_count][total_zeros]
		bit_count += int(zero_code[1])
	}

	// Counting needs no reordered coefficient/run arrays. Consume the same
	// nonzero mask directly, adding level and run lengths in one pass.
	suffix_length: uint = nonzero_count > 10 && trailing_ones < 3 ? 1 : 0
	zeros_left := total_zeros
	for index in 0 ..< nonzero_count {
		position := 31 - int(intrinsics.count_leading_zeros(remaining))
		value := i32(levels[position])
		remaining &~= u32(1) << uint(position)
		if index >= trailing_ones {
			magnitude := u32(abs(value))
			level_code := (magnitude - 1) * 2 + (value < 0 ? 1 : 0)
			if index == trailing_ones && trailing_ones < 3 do level_code -= 2
			switch {
			case suffix_length == 0 && level_code < 14:
				bit_count += int(level_code + 1)
			case suffix_length == 0 && level_code < 30:
				bit_count += 19
			case suffix_length == 0:
				bit_count += 28
			case level_code >> suffix_length < 15:
				bit_count += int(level_code >> suffix_length) + 1 + int(suffix_length)
			case:
				bit_count += 28
			}
			if suffix_length == 0 do suffix_length = 1
			if magnitude > u32(3 << (suffix_length - 1)) && suffix_length < 6 do suffix_length += 1
		}
		if index < nonzero_count - 1 && zeros_left > 0 {
			next_position := 31 - int(intrinsics.count_leading_zeros(remaining))
			run := position - next_position - 1
			bit_count += int(vlc_run_before_enc[min(zeros_left, 7)][run][1])
			zeros_left -= run
		}
	}
	return bit_count
}

truncated_exp_golomb_bit_count :: #force_inline proc(value, range: u32) -> int {
	return range == 1 ? 1 : int(unsigned_exp_golomb_bit_count(value))
}

// Intra 4x4 mode syntax bits from the candidate modes, mirroring the
// write_macroblock_layer loop (1 bit on predicted match, else 1 + 3).
intra_4x4_mode_bit_count :: proc(
	grid: ^h264.Macroblock_Grid,
	macroblock_index: int,
	modes: ^[16]h264.Intra_4x4_Mode,
) -> int {
	bits := 0
	for block in 0 ..< 16 {
		bx, by := h264.subblock_to_xy(block)
		mode_a :=
			bx > 0 ? int(modes[h264.xy_to_subblock(bx - 1, by)]) : neighbour_intra_4x4_mode(grid, macroblock_index, true, by)
		mode_b :=
			by > 0 ? int(modes[h264.xy_to_subblock(bx, by - 1)]) : neighbour_intra_4x4_mode(grid, macroblock_index, false, bx)
		predicted := mode_a < 0 || mode_b < 0 ? int(h264.Intra_4x4_Mode.DC) : min(mode_a, mode_b)
		bits += int(modes[block]) == predicted ? 1 : 4
	}
	return bits
}

// Reference indices and motion vector differences, mirroring the writer.
inter_prediction_bit_count :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	macroblock_index: int,
) -> int {
	state := task.state
	grid := &task.grid
	bits := 0
	if macroblock.type == .P_8x8 {
		for _ in 0 ..< 4 do bits += int(unsigned_exp_golomb_bit_count(0)) // sub_mb_type P_L0_8x8
		if state.num_refs > 1 do for k in 0 ..< 4 do bits += truncated_exp_golomb_bit_count(u32(macroblock.reference_indices[0][k]), u32(state.num_refs - 1))
		for k in 0 ..< 4 {
			predictor := h264.predict_motion_vector(
				grid,
				macroblock_index,
				0,
				k * 4,
				2,
				2,
				macroblock.reference_indices[0][k],
			)
			bits += int(
				signed_exp_golomb_bit_count(
					i32(macroblock.motion_vectors[0][k * 4][0]) - i32(predictor[0]),
				),
			)
			bits += int(
				signed_exp_golomb_bit_count(
					i32(macroblock.motion_vectors[0][k * 4][1]) - i32(predictor[1]),
				),
			)
		}
		return bits
	}
	parts := h264.macroblock_partitions(macroblock.type)
	if state.num_refs > 1 do for part in parts do bits += truncated_exp_golomb_bit_count(u32(macroblock.reference_indices[0][part.block / 4]), u32(state.num_refs - 1))
	for part in parts {
		predictor := h264.predict_motion_vector(
			grid,
			macroblock_index,
			0,
			part.block,
			part.width,
			part.height,
			macroblock.reference_indices[0][part.block / 4],
		)
		bits += int(
			signed_exp_golomb_bit_count(
				i32(macroblock.motion_vectors[0][part.block][0]) - i32(predictor[0]),
			),
		)
		bits += int(
			signed_exp_golomb_bit_count(
				i32(macroblock.motion_vectors[0][part.block][1]) - i32(predictor[1]),
			),
		)
	}
	return bits
}

// Luma residual syntax bits, mirroring the writer's block loop.
luma_coefficient_bit_count :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	macroblock_index: int,
) -> int {
	grid := &task.grid
	bits := 0
	if macroblock.type == .I_16x16 {
		bits += cavlc_coefficient_bit_count(
			choice.luma_dc_coefficients[:],
			h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, 0, false),
		)
		if macroblock.luma_coded_block_mask != 0 {
			for block in 0 ..< 16 {
				nc := h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, block, false)
				bits +=
					macroblock.nonzero_coefficient_counts[block] == 0 ? cavlc_zero_coefficient_bit_count(nc) : cavlc_coefficient_bit_count(choice.luma_coefficients[block][1:], nc)
			}
		}
		return bits
	}
	for block in 0 ..< 16 {
		if macroblock.luma_coded_block_mask & (1 << uint(block / 4)) != 0 {
			nc := h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, block, false)
			bits +=
				macroblock.nonzero_coefficient_counts[block] == 0 ? cavlc_zero_coefficient_bit_count(nc) : cavlc_coefficient_bit_count(choice.luma_coefficients[block][:], nc)
		}
	}
	return bits
}

// Chroma residual syntax bits, mirroring the writer's block loop.
chroma_coefficient_bit_count :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	macroblock_index: int,
) -> int {
	grid := &task.grid
	bits := 0
	if choice.chroma_residual_mode != .None do for plane in 0 ..< 2 do bits += cavlc_coefficient_bit_count(choice.chroma_dc_coefficients[plane][:], -1)
	if choice.chroma_residual_mode == .DC_And_AC do for plane in 0 ..< 2 do for block in 0 ..< 4 {
		nc := h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, plane * 4 + block, true)
		bits += macroblock.nonzero_coefficient_counts[16 + plane * 4 + block] == 0 ? cavlc_zero_coefficient_bit_count(nc) : cavlc_coefficient_bit_count(choice.chroma_ac_coefficients[plane][block][1:], nc)
	}
	return bits
}

// Exact bit count of what write_macroblock_layer would emit for this
// candidate (modes, headers, and residuals). Callers set macroblock.type,
// macroblock.is_intra, macroblock.intra_16x16_mode, macroblock.chroma_prediction_mode,
// macroblock.reference_indices, macroblock.motion_vectors, macroblock.luma_coded_block_mask,
// macroblock.chroma_residual_mode, and macroblock.nonzero_coefficient_counts before calling, exactly as the
// writer observes them at commit.
// Optional facts belong to that same completed intra trial: chroma comes from
// evaluate_chroma_candidate(true), luma from evaluate_intra_4x4_candidate.
macroblock_bit_count :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	macroblock_index: int,
	intra_chroma: ^Macroblock_Candidate = nil,
	intra_luma: ^Intra_Luma_Cost = nil,
) -> int {
	bits := 0
	intra_type: u32
	have_intra_type := false
	switch macroblock.type {
	case .I_4x4:
		intra_type, have_intra_type = 0, true
	case .I_16x16:
		// Table 7-11: intra_type = pred_mode + 4*chroma_residual_mode +
		// 12*(luma_coded_block_mask != 0). The chroma term is the residual
		// mode, not the chroma prediction mode.
		intra_type, have_intra_type =
			1 +
			u32(macroblock.intra_16x16_mode) +
			4 * u32(macroblock.chroma_residual_mode) +
			(macroblock.luma_coded_block_mask != 0 ? 12 : 0),
			true
	case .I_8x8,
	     .I_PCM,
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
	// macroblock type code: skipped blocks emit no type of their own, their
	// cost is folded into the skip run (ESTIMATED_SKIP_BITS per block).
	if macroblock.is_skip do return ESTIMATED_SKIP_BITS
	if task.is_idr {
		bits += int(unsigned_exp_golomb_bit_count(intra_type))
	} else {
		switch macroblock.type {
		case .P_L0_16x16:
			bits += int(unsigned_exp_golomb_bit_count(0))
		case .P_L0_L0_16x8:
			bits += int(unsigned_exp_golomb_bit_count(1))
		case .P_L0_L0_8x16:
			bits += int(unsigned_exp_golomb_bit_count(2))
		case .P_8x8:
			bits += int(unsigned_exp_golomb_bit_count(3))
		case .I_4x4, .I_16x16:
			bits += int(unsigned_exp_golomb_bit_count(5 + intra_type))
		case .I_8x8,
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
	_ = have_intra_type

	switch macroblock.type {
	case .I_4x4:
		bits +=
			intra_luma != nil ? intra_luma.prediction_bits : intra_4x4_mode_bit_count(&task.grid, macroblock_index, &choice.intra_4x4_modes)
		if intra_chroma == nil do bits += int(unsigned_exp_golomb_bit_count(u32(macroblock.chroma_prediction_mode)))
	case .I_16x16:
		if intra_chroma == nil do bits += int(unsigned_exp_golomb_bit_count(u32(macroblock.chroma_prediction_mode)))
	case .P_L0_16x16, .P_L0_L0_16x8, .P_L0_L0_8x16, .P_8x8:
		bits += inter_prediction_bit_count(task, macroblock, macroblock_index)
	case .I_8x8,
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

	if macroblock.type != .I_16x16 do bits += int(unsigned_exp_golomb_bit_count(coded_block_pattern_code(macroblock.luma_coded_block_mask | u8(macroblock.chroma_residual_mode) << 4, macroblock.is_intra)))
	if macroblock.luma_coded_block_mask != 0 || macroblock.chroma_residual_mode != .None || macroblock.type == .I_16x16 do bits += 1 // mb_qp_delta = 0

	bits +=
		intra_luma != nil ? intra_luma.residual_bits : luma_coefficient_bit_count(task, macroblock, choice, macroblock_index)
	bits +=
		intra_chroma != nil ? intra_chroma.bit_count : chroma_coefficient_bit_count(task, macroblock, choice, macroblock_index)
	return bits
}

// ---------------------------------------------------------------------------
// Code candidate residuals in place, then score reconstruction distortion and
// the syntax emitted by write_macroblock_layer. Retain the selected pixels;
// publishing them requires no second transform/reconstruction pass. Stage type,
// modes, motion, coded-block flags and nonzero counts as the writer sees them.
// ---------------------------------------------------------------------------

// SSD of the current picture reconstruction against the source.
macroblock_squared_error :: proc(
	source_luma: [^]u8,
	source_luma_stride: int,
	source_cb, source_cr: [^]u8,
	source_chroma_stride: int,
	reconstructed_luma: [^]u8,
	rec_y_stride: int,
	reconstructed_cb, reconstructed_cr: [^]u8,
	rec_uv_stride: int,
) -> i32 {
	ssd := block_squared_difference_sum(
		source_luma,
		source_luma_stride,
		reconstructed_luma,
		rec_y_stride,
		16,
		16,
	)
	ssd += block_squared_difference_sum(
		source_cb,
		source_chroma_stride,
		reconstructed_cb,
		rec_uv_stride,
		8,
		8,
	)
	ssd += block_squared_difference_sum(
		source_cr,
		source_chroma_stride,
		reconstructed_cr,
		rec_uv_stride,
		8,
		8,
	)
	return ssd
}


// Choose each 4x4 prediction by transformed error plus mode bits, then code
// its residual once. The reconstructed block becomes the next block's neighbour.
evaluate_intra_4x4_candidate :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	candidate: ^Macroblock_Candidate,
	macroblock_index: int,
	source: [^]u8,
	source_stride: int,
	reconstruction: [^]u8,
	reconstruction_stride: int,
	neighbours: Neighbours,
	motion_lambda: i32,
	maximum_candidate_cost: f64 = max(f64),
	completed_cost: ^Intra_Luma_Cost = nil,
) -> bool {
	grid := &task.grid
	candidate.choice = {
		type = .I_4x4,
	}
	candidate.nonzero_coefficient_counts = {}
	selected_distortion: i32
	selected_bit_count: int
	selected_prediction_bits: int
	for block in 0 ..< 16 {
		column, row := h264.subblock_to_xy(block)
		source_block: [^]u8 = &source[row * 4 * source_stride + column * 4]
		reconstructed_block: [^]u8 = &reconstruction[row * 4 * reconstruction_stride + column * 4]
		have_top := row > 0 || neighbours.top
		have_left := column > 0 || neighbours.left
		have_top_right: bool
		switch {
		case row == 0 && column < 3:
			have_top_right = neighbours.top
		case row == 0:
			have_top_right = neighbours.top_right
		case column < 3:
			have_top_right = block != 3 && block != 11
		}
		have_top_left :=
			(column > 0 && row > 0) ||
			(column == 0 && row == 0 && neighbours.top_left) ||
			(column == 0 && row > 0 && neighbours.left) ||
			(row == 0 && column > 0 && neighbours.top)
		left_mode :=
			column > 0 ? int(candidate.choice.intra_4x4_modes[h264.xy_to_subblock(column - 1, row)]) : neighbour_intra_4x4_mode(grid, macroblock_index, true, row)
		top_mode :=
			row > 0 ? int(candidate.choice.intra_4x4_modes[h264.xy_to_subblock(column, row - 1)]) : neighbour_intra_4x4_mode(grid, macroblock_index, false, column)
		predicted_mode :=
			left_mode < 0 || top_mode < 0 ? int(h264.Intra_4x4_Mode.DC) : min(left_mode, top_mode)

		selected_mode := h264.Intra_4x4_Mode.DC
		prediction_cost := max(i32)
		predictors := h264.load_intra_4x4_predictors(
			reconstructed_block,
			reconstruction_stride,
			have_top,
			have_left,
			have_top_right,
		)
		source_samples := h264.load_luma_block_4x4(source_block, source_stride)
		selected_prediction: #simd[16]i16
		for mode in h264.Intra_4x4_Mode {
			switch mode {
			case .Vertical, .Diagonal_Down_Left, .Vertical_Left:
				if !have_top do continue
			case .Horizontal, .Horizontal_Up:
				if !have_left do continue
			case .Diagonal_Down_Right, .Vertical_Right, .Horizontal_Down:
				if !have_top || !have_left || !have_top_left do continue
			case .DC:
			}
			prediction := h264.intra_4x4_prediction_samples(&predictors, mode)
			cost :=
				transformed_difference_4x4(source_samples, prediction) +
				motion_lambda * (int(mode) == predicted_mode ? 1 : 4)
			if cost < prediction_cost do selected_mode, prediction_cost, selected_prediction = mode, cost, prediction
		}
		h264.store_luma_block_4x4(reconstructed_block, reconstruction_stride, selected_prediction)
		levels := &candidate.choice.luma_coefficients[block]
		nonzero_count := code_residual_4x4_samples(
			task,
			source_samples,
			selected_prediction,
			reconstructed_block,
			reconstruction_stride,
			levels,
			&task.state.frame.quantizers[0][1],
			true,
			0,
		)
		candidate.choice.intra_4x4_modes[block] = selected_mode
		candidate.nonzero_coefficient_counts[block] = u8(nonzero_count)
		macroblock.nonzero_coefficient_counts[block] = u8(nonzero_count)
		selected_distortion += block_squared_difference_sum(
			source_block,
			source_stride,
			reconstructed_block,
			reconstruction_stride,
			4,
			4,
		)
		mode_bits := int(selected_mode) == predicted_mode ? 1 : 4
		selected_bit_count += mode_bits
		selected_prediction_bits += mode_bits
		if nonzero_count > 0 {
			candidate.choice.luma_coded_block_mask |= 1 << uint(block / 4)
			selected_bit_count += cavlc_coefficient_bit_count(
				levels[:],
				h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, block, false),
			)
		}
		// These selected pixels/mode bits and nonzero residuals cannot be
		// removed by later blocks. Omit zero-block residual bits from the
		// bound because CBP may suppress them. Remaining costs are nonnegative.
		if rate_distortion_cost(selected_distortion, selected_bit_count, task.distortion_lambda) > maximum_candidate_cost do return false
	}
	macroblock.is_intra = true
	macroblock.is_skip = false
	macroblock.type = .I_4x4
	macroblock.intra_4x4_modes = candidate.choice.intra_4x4_modes
	if completed_cost != nil {
		completed_cost^ = {
			distortion      = selected_distortion,
			prediction_bits = selected_prediction_bits,
			residual_bits   = selected_bit_count - selected_prediction_bits,
		}
		// Pruning deliberately omitted zero-block tokens before the final
		// coded-group mask was known. Add only those now actually emitted.
		// All nC neighbours precede their block in decoding order, so their
		// final counts equal the counts observed during the block's trial.
		for block in 0 ..< 16 {
			if candidate.nonzero_coefficient_counts[block] == 0 &&
			   candidate.choice.luma_coded_block_mask & (1 << uint(block / 4)) != 0 {
				completed_cost.residual_bits += cavlc_zero_coefficient_bit_count(
					h264.cavlc_neighbour_coefficient_count(grid, macroblock_index, block, false),
				)
			}
		}
	}
	return true
}

// Chroma syntax and reconstruction are shared by all intra luma candidates.
// The picture's chroma pixels remain in place while only luma is searched.
reuse_intra_chroma_candidate :: proc(
	macroblock: #soa^#soa[]h264.Macroblock,
	candidate, chroma: ^Macroblock_Candidate,
) {
	candidate.choice.chroma_prediction_mode = chroma.choice.chroma_prediction_mode
	candidate.choice.chroma_residual_mode = chroma.choice.chroma_residual_mode
	candidate.choice.chroma_dc_coefficients = chroma.choice.chroma_dc_coefficients
	candidate.choice.chroma_ac_coefficients = chroma.choice.chroma_ac_coefficients
	macroblock.chroma_prediction_mode = chroma.choice.chroma_prediction_mode
	for k in 16 ..< 24 do macroblock.nonzero_coefficient_counts[k] = chroma.nonzero_coefficient_counts[k]
}

// Chroma candidate shared by intra and inter candidates: SATD-pick the mode,
// code the residual, stage macroblock for the bit estimate.
evaluate_chroma_candidate :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	candidate: ^Macroblock_Candidate,
	macroblock_index: int,
	source_cb, source_cr: [^]u8,
	source_chroma_stride: int,
	neighbours: Neighbours,
	intra: bool,
	motion_lambda: i32,
) {
	reconstruction := &task.state.curr.buf
	source := &task.state.source
	macroblock_column, macroblock_row :=
		macroblock_index %
		task.grid.macroblock_columns,
		macroblock_index /
		task.grid.macroblock_columns
	source_planes := [2]([^]u8) {
		&source.u[(macroblock_row * 8) * source.uv_stride + macroblock_column * 8],
		&source.v[(macroblock_row * 8) * source.uv_stride + macroblock_column * 8],
	}
	reconstructed_planes := [2]([^]u8) {
		&reconstruction.u[(macroblock_row * 8) * reconstruction.uv_stride + macroblock_column * 8],
		&reconstruction.v[(macroblock_row * 8) * reconstruction.uv_stride + macroblock_column * 8],
	}
	if intra {
		selected_cost := max(i32)
		selected_mode := h264.Intra_Chroma_Mode.DC
		for mode in ([4]h264.Intra_Chroma_Mode{.DC, .Horizontal, .Vertical, .Plane}) {
			if (mode == .Vertical || mode == .Plane) && !neighbours.top do continue
			if (mode == .Horizontal || mode == .Plane) && !neighbours.left do continue
			cost := motion_lambda * i32(mode == .DC ? 1 : 3)
			for p in 0 ..< 2 {
				h264.predict_intra_chroma_8x8(
					reconstructed_planes[p],
					reconstruction.uv_stride,
					mode,
					neighbours.top,
					neighbours.left,
				)
				cost += block_transformed_difference_sum(
					source_planes[p],
					source.uv_stride,
					reconstructed_planes[p],
					reconstruction.uv_stride,
					8,
					8,
				)
			}
			if cost < selected_cost {
				selected_cost = cost
				selected_mode = mode
			}
		}
		candidate.choice.chroma_prediction_mode = selected_mode
		for p in 0 ..< 2 do h264.predict_intra_chroma_8x8(reconstructed_planes[p], reconstruction.uv_stride, candidate.choice.chroma_prediction_mode, neighbours.top, neighbours.left)
	}
	macroblock.chroma_prediction_mode = candidate.choice.chroma_prediction_mode
	code_chroma_residual(task, macroblock, &candidate.choice, macroblock_index, intra)
	for k in 16 ..< 24 do candidate.nonzero_coefficient_counts[k] = macroblock.nonzero_coefficient_counts[k]
	candidate.distortion =
		block_squared_difference_sum(
			source_cb,
			source_chroma_stride,
			reconstructed_planes[0],
			reconstruction.uv_stride,
			8,
			8,
		) +
		block_squared_difference_sum(
			source_cr,
			source_chroma_stride,
			reconstructed_planes[1],
			reconstruction.uv_stride,
			8,
			8,
		)
	candidate.bit_count =
		chroma_coefficient_bit_count(task, macroblock, &candidate.choice, macroblock_index) +
		(intra ? int(unsigned_exp_golomb_bit_count(u32(candidate.choice.chroma_prediction_mode))) : 0)
}

// Score a fully-coded candidate in place: exact bits plus SSD of the picture.
score_macroblock_candidate :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	candidate: ^Macroblock_Candidate,
	macroblock_index: int,
	source_luma: [^]u8,
	source_luma_stride: int,
	source_cb, source_cr: [^]u8,
	source_chroma_stride: int,
	intra_chroma: ^Macroblock_Candidate = nil,
	intra_luma: ^Intra_Luma_Cost = nil,
) {
	reconstruction := &task.state.curr.buf
	macroblock_column, macroblock_row :=
		macroblock_index %
		task.grid.macroblock_columns,
		macroblock_index /
		task.grid.macroblock_columns
	reconstructed_luma: [^]u8 = &reconstruction.y[(macroblock_row * 16) * reconstruction.y_stride + macroblock_column * 16]
	reconstructed_cb: [^]u8 = &reconstruction.u[(macroblock_row * 8) * reconstruction.uv_stride + macroblock_column * 8]
	reconstructed_cr: [^]u8 = &reconstruction.v[(macroblock_row * 8) * reconstruction.uv_stride + macroblock_column * 8]
	if intra_chroma != nil {
		// Intra luma trials do not change the chroma pixels or contexts.
		// A completed Intra4 trial has also visited every reconstructed luma
		// sample. Reuse exact integer facts instead of rescanning those planes.
		luma_distortion :=
			intra_luma != nil ? intra_luma.distortion : block_squared_difference_sum(source_luma, source_luma_stride, reconstructed_luma, reconstruction.y_stride, 16, 16)
		candidate.distortion = luma_distortion + intra_chroma.distortion
	} else {
		candidate.distortion = macroblock_squared_error(
			source_luma,
			source_luma_stride,
			source_cb,
			source_cr,
			source_chroma_stride,
			reconstructed_luma,
			reconstruction.y_stride,
			reconstructed_cb,
			reconstructed_cr,
			reconstruction.uv_stride,
		)
	}
	// Residual coding owns the candidate's flags in choice. Publish them
	// at this shared scoring boundary, as the final writer does at commit.
	macroblock.luma_coded_block_mask, macroblock.chroma_residual_mode =
		candidate.choice.luma_coded_block_mask, candidate.choice.chroma_residual_mode
	candidate.bit_count = macroblock_bit_count(
		task,
		macroblock,
		&candidate.choice,
		macroblock_index,
		intra_chroma,
		intra_luma,
	)
	for k in 0 ..< 24 do candidate.nonzero_coefficient_counts[k] = macroblock.nonzero_coefficient_counts[k]
}

// Snapshot a candidate's reconstruction out of the picture into the candidate.
retain_candidate_reconstruction :: proc(
	task: ^Slice_Task,
	candidate: ^Macroblock_Candidate,
	macroblock_index: int,
) {
	reconstruction := &task.state.curr.buf
	macroblock_column, macroblock_row :=
		macroblock_index %
		task.grid.macroblock_columns,
		macroblock_index /
		task.grid.macroblock_columns
	y_stride, uv_stride := reconstruction.y_stride, reconstruction.uv_stride
	reconstructed_luma: [^]u8 = &reconstruction.y[(macroblock_row * 16) * y_stride + macroblock_column * 16]
	reconstructed_cb: [^]u8 = &reconstruction.u[(macroblock_row * 8) * uv_stride + macroblock_column * 8]
	reconstructed_cr: [^]u8 = &reconstruction.v[(macroblock_row * 8) * uv_stride + macroblock_column * 8]
	// Candidate tiles are local storage, disjoint from the owned frame planes.
	for row in 0 ..< 16 {
		copy(candidate.reconstructed_luma[row * 16:row * 16 + 16], reconstructed_luma[:16])
		reconstructed_luma = &reconstructed_luma[y_stride]
	}
	for row in 0 ..< 8 {
		copy(candidate.reconstructed_cb[row * 8:row * 8 + 8], reconstructed_cb[:8])
		copy(candidate.reconstructed_cr[row * 8:row * 8 + 8], reconstructed_cr[:8])
		reconstructed_cb = &reconstructed_cb[uv_stride]
		reconstructed_cr = &reconstructed_cr[uv_stride]
	}
}

// Restore a candidate's reconstruction from the candidate into the picture.
publish_candidate_reconstruction :: proc(
	task: ^Slice_Task,
	candidate: ^Macroblock_Candidate,
	macroblock_index: int,
) {
	reconstruction := &task.state.curr.buf
	macroblock_column, macroblock_row :=
		macroblock_index %
		task.grid.macroblock_columns,
		macroblock_index /
		task.grid.macroblock_columns
	y_stride, uv_stride := reconstruction.y_stride, reconstruction.uv_stride
	reconstructed_luma: [^]u8 = &reconstruction.y[(macroblock_row * 16) * y_stride + macroblock_column * 16]
	reconstructed_cb: [^]u8 = &reconstruction.u[(macroblock_row * 8) * uv_stride + macroblock_column * 8]
	reconstructed_cr: [^]u8 = &reconstruction.v[(macroblock_row * 8) * uv_stride + macroblock_column * 8]
	for row in 0 ..< 16 {
		copy(reconstructed_luma[:16], candidate.reconstructed_luma[row * 16:row * 16 + 16])
		reconstructed_luma = &reconstructed_luma[y_stride]
	}
	for row in 0 ..< 8 {
		copy(reconstructed_cb[:8], candidate.reconstructed_cb[row * 8:row * 8 + 8])
		copy(reconstructed_cr[:8], candidate.reconstructed_cr[row * 8:row * 8 + 8])
		reconstructed_cb = &reconstructed_cb[uv_stride]
		reconstructed_cr = &reconstructed_cr[uv_stride]
	}
}


// The skip probe is already retained in selected_candidate. Code the selected motion
// candidate once and keep it only if its complete rate/distortion cost wins.
evaluate_inter_candidate :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	candidate, selected_candidate: ^Macroblock_Candidate,
	selected_cost: ^f64,
	motion_choice: ^Macroblock_Choice,
	macroblock_index: int,
	source_luma: [^]u8,
	luma_stride: int,
	source_cb, source_cr: [^]u8,
	chroma_stride: int,
	distortion_lambda: f64,
) {
	state := task.state
	reconstruction := &state.curr.buf
	column, row :=
		macroblock_index %
		task.grid.macroblock_columns,
		macroblock_index /
		task.grid.macroblock_columns
	candidate.choice = motion_choice^
	candidate.nonzero_coefficient_counts = {}
	macroblock.is_intra = false
	macroblock.is_skip = false
	macroblock.type = motion_choice.type
	macroblock.motion_vectors[0] = motion_choice.motion_vectors
	for partition in 0 ..< 4 {
		macroblock.reference_indices[0][partition] = motion_choice.reference_indices[partition]
		macroblock.reference_picture_ids[0][partition] =
			state.refs[motion_choice.reference_indices[partition]].pic_id
		macroblock.prediction_directions[partition] = h264.Prediction_Direction.List_0
	}
	macroblock.chroma_prediction_mode = motion_choice.chroma_prediction_mode
	predict_inter_macroblock_encoder(task, macroblock, macroblock_index)
	code_luma_4x4(
		task,
		macroblock,
		&candidate.choice,
		source_luma,
		luma_stride,
		&reconstruction.y[row * 16 * reconstruction.y_stride + column * 16],
		reconstruction.y_stride,
		false,
	)
	code_chroma_residual(task, macroblock, &candidate.choice, macroblock_index, false)
	score_macroblock_candidate(
		task,
		macroblock,
		candidate,
		macroblock_index,
		source_luma,
		luma_stride,
		source_cb,
		source_cr,
		chroma_stride,
	)
	if cost := rate_distortion_cost(candidate.distortion, candidate.bit_count, distortion_lambda);
	   cost <= selected_cost^ {
		selected_cost^ = cost
		retain_candidate_reconstruction(task, candidate, macroblock_index)
		selected_candidate^ = candidate^
	}
}

// Probe the spatial skip predictor before motion search or any intra trials.
// The retained tile can be committed directly when distortion is already small.
evaluate_skip_candidate :: proc(
	task: ^Slice_Task,
	macroblock: #soa^#soa[]h264.Macroblock,
	candidate: ^Macroblock_Candidate,
	macroblock_index: int,
	source_luma: [^]u8,
	source_stride: int,
	source_cb, source_cr: [^]u8,
	source_chroma_stride: int,
) {
	mv := h264.predict_skip_motion_vector(&task.grid, macroblock_index)
	candidate^ = {}
	candidate.choice.type = .P_L0_16x16
	candidate.choice.is_skip = true
	candidate.bit_count = ESTIMATED_SKIP_BITS
	macroblock.type = .P_L0_16x16
	macroblock.is_intra = false
	macroblock.is_skip = false
	for k in 0 ..< 16 {
		macroblock.motion_vectors[0][k] = mv
		candidate.choice.motion_vectors[k] = mv
	}
	for k in 0 ..< 4 {
		macroblock.reference_indices[0][k] = 0
		macroblock.reference_picture_ids[0][k] = task.state.refs[0].pic_id
		macroblock.prediction_directions[k] = h264.Prediction_Direction.List_0
	}
	predict_inter_macroblock_encoder(task, macroblock, macroblock_index)
	reconstruction := &task.state.curr.buf
	x, y :=
		macroblock_index %
		task.grid.macroblock_columns,
		macroblock_index /
		task.grid.macroblock_columns
	candidate.distortion = macroblock_squared_error(
		source_luma,
		source_stride,
		source_cb,
		source_cr,
		source_chroma_stride,
		&reconstruction.y[y * 16 * reconstruction.y_stride + x * 16],
		reconstruction.y_stride,
		&reconstruction.u[y * 8 * reconstruction.uv_stride + x * 8],
		&reconstruction.v[y * 8 * reconstruction.uv_stride + x * 8],
		reconstruction.uv_stride,
	)
	retain_candidate_reconstruction(task, candidate, macroblock_index)
}

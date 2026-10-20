package h264_encoder

import h264 ".."
import "core:testing"

@(test)
test_cavlc_zero_token_all_nc_matches_literal_lengths_and_writer :: proc(t: ^testing.T) {
	bytes: [dynamic]u8
	defer delete(bytes)
	magnitudes := [7]i16{1, 1, 2, 7, 17, 31, 63}
	for neighbour_count in -128 ..< 128 {
		nc := i8(neighbour_count)
		// Literal empty coeff_token lengths of the five syntax tables; this
		// oracle does not call the new table selector or inspect its table.
		expected := nc < 0 ? 2 : nc < 2 ? 1 : nc < 4 ? 2 : nc < 8 ? 4 : 6
		testing.expect_value(t, cavlc_zero_coefficient_bit_count(nc), expected)
		for length in ([3]int{4, 15, 16}) {
			if nc < 0 && length != 4 do continue // Chroma DC admits at most four coefficients.
			for pattern in 0 ..< 8 {
				levels: [16]i16
				for position in 0 ..< length {
					if pattern > 0 && (position + pattern) % 3 == 0 {
						magnitude := magnitudes[pattern - 1]
						levels[position] = position & 1 == 0 ? magnitude : -magnitude
					}
				}
				clear(&bytes)
				writer := h264.init_bit_writer(&bytes)
				write_cavlc_block(&writer, levels[:length], nc)
				written := len(bytes) * 8 + writer.nbits
				testing.expect_value(t, cavlc_coefficient_bit_count(levels[:length], nc), written)
				if pattern == 0 do testing.expect_value(t, cavlc_zero_coefficient_bit_count(nc), written)
			}
		}
	}
}

// Original RD block traversal: all emitted blocks inspect their actual
// coefficient span, independently of the producer's staged nonzero counts.
@(private)
rd_zero_scanned_residual_bits :: proc(
	task: ^Slice_Task,
	m: #soa^#soa[]h264.Macroblock,
	choice: ^Macroblock_Choice,
	index: int,
) -> (
	luma, chroma: int,
) {
	if m.type == .I_16x16 {
		luma += cavlc_coefficient_bit_count(
			choice.luma_dc_coefficients[:],
			h264.cavlc_neighbour_coefficient_count(&task.grid, index, 0, false),
		)
		if m.luma_coded_block_mask != 0 {
			for block in 0 ..< 16 {
				luma += cavlc_coefficient_bit_count(
					choice.luma_coefficients[block][1:],
					h264.cavlc_neighbour_coefficient_count(&task.grid, index, block, false),
				)
			}
		}
	} else {
		for block in 0 ..< 16 {
			if m.luma_coded_block_mask & (1 << uint(block / 4)) != 0 {
				luma += cavlc_coefficient_bit_count(
					choice.luma_coefficients[block][:],
					h264.cavlc_neighbour_coefficient_count(&task.grid, index, block, false),
				)
			}
		}
	}
	if choice.chroma_residual_mode != .None {
		for plane in 0 ..< 2 do chroma += cavlc_coefficient_bit_count(choice.chroma_dc_coefficients[plane][:], -1)
	}
	if choice.chroma_residual_mode == .DC_And_AC {
		for plane in 0 ..< 2 {
			for block in 0 ..< 4 {
				chroma += cavlc_coefficient_bit_count(
					choice.chroma_ac_coefficients[plane][block][1:],
					h264.cavlc_neighbour_coefficient_count(
						&task.grid,
						index,
						plane * 4 + block,
						true,
					),
				)
			}
		}
	}
	return
}

@(test)
test_native_zero_count_facts_match_scanned_blocks_and_macroblock_writer :: proc(t: ^testing.T) {
	state: Encoder_State
	testing.expect_value(
		t,
		init_encoder(&state, {width = 32, height = 32, qp = 26, slice_count = 1}),
		Error.None,
	)
	defer destroy_encoder(&state)
	y: [32 * 32]u8
	u, v: [16 * 16]u8
	testing.expect_value(
		t,
		begin_encode_frame(&state, raw_data(y[:]), raw_data(u[:]), raw_data(v[:]), 32, 16, true),
		Error.None,
	)
	task := &state.slices[0]
	bytes: [dynamic]u8
	defer delete(bytes)
	for neighbour_count in ([8]u8{0, 1, 2, 3, 4, 7, 8, 16}) {
		for kind in ([3]h264.Macroblock_Type{.P_L0_16x16, .I_4x4, .I_16x16}) {
			for mask in ([4]u8{0, 1, 5, 15}) {
				for mode in h264.Chroma_Residual_Mode {
					for pattern in 0 ..< 3 {
						for index in 0 ..< len(state.macroblocks) {
							mb := &state.macroblocks[index]
							mb^ = {
								slice_index = 0,
								is_intra    = true,
								type        = .I_4x4,
								quantizer   = 26,
							}
							for k in 0 ..< 24 do mb.nonzero_coefficient_counts[k] = neighbour_count
							for k in 0 ..< 16 do mb.intra_4x4_modes[k] = .DC
						}
						index := 3 // Both external neighbours and every internal nC dependency.
						m := &state.macroblocks[index]
						m.type, m.is_intra = kind, kind != .P_L0_16x16
						m.luma_coded_block_mask = kind == .I_16x16 && mask != 0 ? 15 : mask
						m.chroma_residual_mode = mode
						m.nonzero_coefficient_counts = {}
						choice: Macroblock_Choice
						choice.type, choice.luma_coded_block_mask, choice.chroma_residual_mode =
							kind, m.luma_coded_block_mask, mode
						choice.intra_16x16_mode, m.intra_16x16_mode = .DC, .DC
						for block in 0 ..< 16 {
							choice.intra_4x4_modes[block] = .DC
							if pattern > 0 &&
							   block % 4 == 0 &&
							   m.luma_coded_block_mask & (1 << uint(block / 4)) != 0 {
								choice.luma_coefficients[block][pattern] = block & 4 == 0 ? 1 : -7
								m.nonzero_coefficient_counts[block] = 1
								if pattern == 2 {
									choice.luma_coefficients[block][15] = -1
									m.nonzero_coefficient_counts[block] += 1
								}
							}
						}
						for plane in 0 ..< 2 {
							if pattern > 0 {
								choice.luma_dc_coefficients[plane * 3] = plane == 0 ? 1 : -2
								choice.chroma_dc_coefficients[plane][plane] = plane == 0 ? -1 : 3
								if mode == .DC_And_AC {
									choice.chroma_ac_coefficients[plane][pattern][2] =
										plane == 0 ? 1 : -7
									m.nonzero_coefficient_counts[16 + plane * 4 + pattern] = 1
								}
							}
						}
						luma, chroma := rd_zero_scanned_residual_bits(task, m, &choice, index)
						testing.expect_value(
							t,
							luma_coefficient_bit_count(task, m, &choice, index),
							luma,
						)
						testing.expect_value(
							t,
							chroma_coefficient_bit_count(task, m, &choice, index),
							chroma,
						)
						task.is_idr = kind != .P_L0_16x16
						clear(&bytes)
						writer := h264.init_bit_writer(&bytes)
						write_macroblock_layer(task, &writer, m, &choice, index)
						testing.expect_value(
							t,
							macroblock_bit_count(task, m, &choice, index),
							len(bytes) * 8 + writer.nbits,
						)
					}
				}
			}
		}
	}
}

@(test)
test_intra4_zero_facts_preserve_pruned_prefixes_and_complete_cost :: proc(t: ^testing.T) {
	state: Encoder_State
	testing.expect_value(
		t,
		init_encoder(&state, {width = 16, height = 16, qp = 26, slice_count = 1}),
		Error.None,
	)
	defer destroy_encoder(&state)
	y: [256]u8
	u, v: [64]u8
	for position in 0 ..< len(y) do y[position] = u8((position * 13 + (position / 16) * 19) & 255)
	testing.expect_value(
		t,
		begin_encode_frame(&state, raw_data(y[:]), raw_data(u[:]), raw_data(v[:]), 16, 8, true),
		Error.None,
	)
	task, source, rec := &state.slices[0], &state.source, &state.curr.buf
	m := &task.grid.macroblocks[0]
	full: Macroblock_Candidate
	full_cost: Intra_Luma_Cost
	for row in 0 ..< 16 do for column in 0 ..< 16 do rec.y[row * rec.y_stride + column] = 128
	m^ = {
		slice_index = 0,
		quantizer   = 26,
	}
	testing.expect(
		t,
		evaluate_intra_4x4_candidate(
			task,
			m,
			&full,
			0,
			source.y,
			source.y_stride,
			rec.y,
			rec.y_stride,
			{},
			task.motion_lambda,
			max(f64),
			&full_cost,
		),
	)
	cost := rate_distortion_cost(
		full_cost.distortion,
		full_cost.prediction_bits + full_cost.residual_bits,
		task.distortion_lambda,
	)
	for threshold in ([5]f64{-1, 0, cost / 4, cost, max(f64)}) {
		candidates: [2]Macroblock_Candidate
		complete: [2]bool
		prior_pixels: [256]u8
		facts := Intra_Luma_Cost {
			distortion      = -23,
			prediction_bits = -31,
			residual_bits   = -47,
		}
		for pass in 0 ..< 2 {
			for row in 0 ..< 16 do for column in 0 ..< 16 do rec.y[row * rec.y_stride + column] = 128
			m^ = {
				slice_index = 0,
				quantizer   = 26,
			}
			fact_output: ^Intra_Luma_Cost
			if pass == 1 do fact_output = &facts
			complete[pass] = evaluate_intra_4x4_candidate(
				task,
				m,
				&candidates[pass],
				0,
				source.y,
				source.y_stride,
				rec.y,
				rec.y_stride,
				{},
				task.motion_lambda,
				threshold,
				fact_output,
			)
			for row in 0 ..< 16 {
				for column in 0 ..< 16 {
					if pass == 0 {
						prior_pixels[row * 16 + column] = rec.y[row * rec.y_stride + column]
					} else {
						testing.expect_value(
							t,
							rec.y[row * rec.y_stride + column],
							prior_pixels[row * 16 + column],
						)
					}
				}
			}
		}
		testing.expect_value(t, complete[0], complete[1])
		testing.expect_value(
			t,
			candidates[0].choice.luma_coded_block_mask,
			candidates[1].choice.luma_coded_block_mask,
		)
		testing.expect_value(
			t,
			candidates[0].choice.intra_4x4_modes,
			candidates[1].choice.intra_4x4_modes,
		)
		testing.expect_value(
			t,
			candidates[0].nonzero_coefficient_counts,
			candidates[1].nonzero_coefficient_counts,
		)
		for block in 0 ..< 16 do testing.expect_value(t, candidates[0].choice.luma_coefficients[block], candidates[1].choice.luma_coefficients[block])
		if complete[1] {
			m.luma_coded_block_mask = candidates[1].choice.luma_coded_block_mask
			luma, _ := rd_zero_scanned_residual_bits(task, m, &candidates[1].choice, 0)
			testing.expect_value(t, facts.residual_bits, luma)
			testing.expect_value(
				t,
				facts.prediction_bits,
				intra_4x4_mode_bit_count(&task.grid, 0, &candidates[1].choice.intra_4x4_modes),
			)
			testing.expect_value(
				t,
				facts.distortion,
				block_squared_difference_sum(
					source.y,
					source.y_stride,
					rec.y,
					rec.y_stride,
					16,
					16,
				),
			)
		} else {
			testing.expect_value(
				t,
				facts,
				Intra_Luma_Cost{distortion = -23, prediction_bits = -31, residual_bits = -47},
			)
		}
	}
}

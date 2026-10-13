package h264_encoder

import h264 ".."
import "core:testing"

@(test)
test_cbp_inverse_matches_native_permutations_for_all_inputs :: proc(t: ^testing.T) {
	for intra in ([2]bool{false, true}) {
		source := intra ? h264.intra4x4_cbp_table[:] : h264.inter_cbp_table[:]
		seen: [48]bool
		for value in source {
			testing.expect(t, int(value) < len(seen))
			testing.expect(t, !seen[value])
			seen[value] = true
		}
		for cbp in 0 ..< 256 {
			expected: u32
			for value, code in source {
				if int(value) == cbp {expected = u32(code); break}
			}
			testing.expect_value(t, coded_block_pattern_code(u8(cbp), intra), expected)
		}
	}
}

@(private)
rd_facts_expect_score :: proc(
	t: ^testing.T,
	task: ^Slice_Task,
	index: int,
	candidate, chroma: ^Macroblock_Candidate,
	luma: ^Intra_Luma_Cost,
) {
	source, rec := &task.state.source, &task.state.curr.buf
	x, y := index % task.grid.macroblock_columns, index / task.grid.macroblock_columns
	m := &task.grid.macroblocks[index]
	full, retained := candidate^, candidate^
	score_macroblock_candidate(
		task,
		m,
		&full,
		index,
		&source.y[y * 16 * source.y_stride + x * 16],
		source.y_stride,
		&source.u[y * 8 * source.uv_stride + x * 8],
		&source.v[y * 8 * source.uv_stride + x * 8],
		source.uv_stride,
	)
	score_macroblock_candidate(
		task,
		m,
		&retained,
		index,
		&source.y[y * 16 * source.y_stride + x * 16],
		source.y_stride,
		&source.u[y * 8 * source.uv_stride + x * 8],
		&source.v[y * 8 * source.uv_stride + x * 8],
		source.uv_stride,
		chroma,
		luma,
	)
	testing.expect_value(t, retained.distortion, full.distortion)
	testing.expect_value(t, retained.bit_count, full.bit_count)
	testing.expect_value(
		t,
		rate_distortion_cost(retained.distortion, retained.bit_count, task.distortion_lambda),
		rate_distortion_cost(full.distortion, full.bit_count, task.distortion_lambda),
	)
	if luma != nil {
		testing.expect_value(
			t,
			luma.distortion,
			block_squared_difference_sum(
				&source.y[y * 16 * source.y_stride + x * 16],
				source.y_stride,
				&rec.y[y * 16 * rec.y_stride + x * 16],
				rec.y_stride,
				16,
				16,
			),
		)
	}
	// Serialization is an independent consumer of the selected mode/context
	// facts. No cached bit count is passed to the unchanged writer.
	bytes: [dynamic]u8
	defer delete(bytes)
	writer := h264.init_bit_writer(&bytes)
	write_macroblock_layer(task, &writer, m, &retained.choice, index)
	testing.expect_value(t, retained.bit_count, len(bytes) * 8 + writer.nbits)
}

@(test)
test_completed_intra_cost_facts_match_full_score_and_writer :: proc(t: ^testing.T) {
	for qp in ([5]i32{0, 9, 10, 26, 51}) {
		state: Encoder_State
		testing.expect_value(
			t,
			init_encoder(&state, {width = 32, height = 32, qp = qp, slice_count = 1}),
			Error.None,
		)
		defer destroy_encoder(&state)
		source := h264.alloc_yuv_buffer(32, 32)
		defer h264.free_yuv_buffer(&source)
		for pattern in 0 ..< 3 {
			for row in 0 ..< 32 do for col in 0 ..< 32 do source.y[row * source.y_stride + col] = pattern == 0 ? 128 : pattern == 1 ? u8((col * 19 + row * 37) & 255) : u8(col & 15 < 4 && row & 15 < 4 ? 192 : 128)
			for row in 0 ..< 16 do for col in 0 ..< 16 {
				source.u[row * source.uv_stride + col] = pattern == 0 ? 128 : u8((col * 31 + row * 9) & 255)
				source.v[row * source.uv_stride + col] = pattern == 0 ? 128 : u8((col * 7 + row * 23) & 255)
			}
			testing.expect_value(
				t,
				begin_encode_frame(
					&state,
					source.y,
					source.u,
					source.v,
					source.y_stride,
					source.uv_stride,
					true,
				),
				Error.None,
			)
			task := &state.slices[0]
			rec := &state.curr.buf
			for row in 0 ..< 32 do for col in 0 ..< 32 do rec.y[row * rec.y_stride + col] = 128
			for row in 0 ..< 16 do for col in 0 ..< 16 {
				rec.u[row * rec.uv_stride + col] = 128
				rec.v[row * rec.uv_stride + col] = 128
			}
			for idr in ([2]bool{true, false}) {
				task.is_idr = idr
				for index in ([2]int{0, 3}) {
					for i in 0 ..< len(state.macroblocks) {
						mb := &state.macroblocks[i]
						mb^ = {
							slice_index = 0,
							type        = .I_4x4,
							is_intra    = true,
							quantizer   = i8(qp),
						}
						for k in 0 ..< 24 do mb.nonzero_coefficient_counts[k] = u8((i * 3 + k * 5) % 17)
						for k in 0 ..< 16 do mb.intra_4x4_modes[k] = .DC
					}
					m := &state.macroblocks[index]
					x, y := index % 2, index / 2
					neighbours := macroblock_neighbours(&task.grid, index)
					chroma, candidate: Macroblock_Candidate
					evaluate_chroma_candidate(
						task,
						m,
						&chroma,
						index,
						&state.source.u[y * 8 * state.source.uv_stride + x * 8],
						&state.source.v[y * 8 * state.source.uv_stride + x * 8],
						state.source.uv_stride,
						neighbours,
						true,
						task.motion_lambda,
					)
					cost: Intra_Luma_Cost
					complete := evaluate_intra_4x4_candidate(
						task,
						m,
						&candidate,
						index,
						&state.source.y[y * 16 * state.source.y_stride + x * 16],
						state.source.y_stride,
						&rec.y[y * 16 * rec.y_stride + x * 16],
						rec.y_stride,
						neighbours,
						task.motion_lambda,
						max(f64),
						&cost,
					)
					testing.expect(t, complete)
					reuse_intra_chroma_candidate(m, &candidate, &chroma)
					rd_facts_expect_score(t, task, index, &candidate, &chroma, &cost)
					// Reusing chroma is also exact for coarse luma mode trials.
					candidate.choice = {
						type             = .I_16x16,
						intra_16x16_mode = .DC,
					}
					m.type, m.is_intra, m.intra_16x16_mode = .I_16x16, true, .DC
					h264.predict_intra_16x16(
						&rec.y[y * 16 * rec.y_stride + x * 16],
						rec.y_stride,
						.DC,
						neighbours.top,
						neighbours.left,
					)
					code_luma_16x16(
						task,
						m,
						&candidate.choice,
						&state.source.y[y * 16 * state.source.y_stride + x * 16],
						state.source.y_stride,
						&rec.y[y * 16 * rec.y_stride + x * 16],
						rec.y_stride,
					)
					reuse_intra_chroma_candidate(m, &candidate, &chroma)
					rd_facts_expect_score(t, task, index, &candidate, &chroma, nil)
					// An abandoned prefix must never publish complete-cost facts.
					cost = {
						distortion      = -23,
						prediction_bits = -31,
						residual_bits   = -47,
					}
					complete = evaluate_intra_4x4_candidate(
						task,
						m,
						&candidate,
						index,
						&state.source.y[y * 16 * state.source.y_stride + x * 16],
						state.source.y_stride,
						&rec.y[y * 16 * rec.y_stride + x * 16],
						rec.y_stride,
						neighbours,
						task.motion_lambda,
						-1,
						&cost,
					)
					testing.expect(t, !complete)
					testing.expect_value(
						t,
						cost,
						Intra_Luma_Cost {
							distortion = -23,
							prediction_bits = -31,
							residual_bits = -47,
						},
					)
				}
			}
			testing.expect_value(t, cancel_encode_frame(&state), Error.None)
		}
	}
}

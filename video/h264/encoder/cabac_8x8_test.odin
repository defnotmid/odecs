package h264_encoder

import h264 ".."
import common "../../../common"
import "../decoder"
import "core:testing"

@(test)
test_dct_quant_8x8_roundtrip :: proc(t: ^testing.T) {
	sps := h264.Sequence_Parameter_Set{
		profile       = .High,
		chroma_format = .YUV_420,
	}
	pps := h264.Picture_Parameter_Set{
		transform_8x8_mode_flag = true,
	}
	scales: h264.Level_Scales
	h264.compute_level_scales(&scales, &sps, &pps)

	for intra in ([2]bool{true, false}) {
		q := prepare_quantizer_8x8(4, intra)
		src, pred, rec: [64]u8
		for y in 0 ..< 8 do for x in 0 ..< 8 {
			src[y * 8 + x] = u8(40 + x * 17 + y * 13 + ((x * y) & 7) * 5)
			pred[y * 8 + x] = 100
			rec[y * 8 + x] = 100
		}
		coeffs := forward_dct_8x8_samples(&src[0], 8, &pred[0], 8)
		levels: [64]i16
		nz := quantize_8x8_prepared(&coeffs, &levels, &q)
		testing.expect(t, nz > 0)
		h264.reconstruct_8x8(&scales, &rec[0], 8, &levels, 4, intra ? 0 : 1)
		max_err := 0
		for i in 0 ..< 64 {
			err := abs(int(src[i]) - int(rec[i]))
			if err > max_err do max_err = err
		}
		testing.expectf(t, max_err <= 2, "8x8 roundtrip at QP=4 max error %d > 2", max_err)
	}
}

@(test)
test_cabac_macroblock_bit_count_matches_writer :: proc(t: ^testing.T) {
	state: Encoder_State
	testing.expect_value(
		t,
		init_encoder(
			&state,
			{width = 32, height = 32, qp = 22, slice_count = 1, cabac = true, transform_8x8 = true},
		),
		Error.None,
	)
	defer destroy_encoder(&state)

	source := h264.alloc_yuv_buffer(32, 32)
	defer h264.free_yuv_buffer(&source)
	for row in 0 ..< 32 do for col in 0 ..< 32 {
		source.y[row * source.y_stride + col] = u8((col * 23 + row * 41 + (col * row)) & 255)
	}
	for row in 0 ..< 16 do for col in 0 ..< 16 {
		source.u[row * source.uv_stride + col] = u8((col * 17 + row * 13) & 255)
		source.v[row * source.uv_stride + col] = u8((col * 29 + row * 7) & 255)
	}

	testing.expect_value(
		t,
		begin_encode_frame(&state, source.y, source.u, source.v, source.y_stride, source.uv_stride, true),
		Error.None,
	)
	task := &state.slices[0]
	cabac_init_slice(task)

	for index in 0 ..< 4 {
		m := &task.grid.macroblocks[index]
		x, y := index % 2, index / 2
		neighbours := macroblock_neighbours(&task.grid, index)
		chroma, cand4, cand8: Macroblock_Candidate
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
		ok4 := evaluate_intra_4x4_candidate(
			task,
			m,
			&cand4,
			index,
			&state.source.y[y * 16 * state.source.y_stride + x * 16],
			state.source.y_stride,
			&state.curr.buf.y[y * 16 * state.curr.buf.y_stride + x * 16],
			state.curr.buf.y_stride,
			neighbours,
			task.motion_lambda,
		)
		testing.expect(t, ok4)
		reuse_intra_chroma_candidate(m, &cand4, &chroma)
		score_macroblock_candidate(
			task,
			m,
			&cand4,
			index,
			&state.source.y[y * 16 * state.source.y_stride + x * 16],
			state.source.y_stride,
			&state.source.u[y * 8 * state.source.uv_stride + x * 8],
			&state.source.v[y * 8 * state.source.uv_stride + x * 8],
			state.source.uv_stride,
			&chroma,
		)

		ok8 := evaluate_intra_8x8_candidate(
			task,
			m,
			&cand8,
			index,
			&state.source.y[y * 16 * state.source.y_stride + x * 16],
			state.source.y_stride,
			&state.curr.buf.y[y * 16 * state.curr.buf.y_stride + x * 16],
			state.curr.buf.y_stride,
			neighbours,
			task.motion_lambda,
		)
		testing.expect(t, ok8)
		reuse_intra_chroma_candidate(m, &cand8, &chroma)
		score_macroblock_candidate(
			task,
			m,
			&cand8,
			index,
			&state.source.y[y * 16 * state.source.y_stride + x * 16],
			state.source.y_stride,
			&state.source.u[y * 8 * state.source.uv_stride + x * 8],
			&state.source.v[y * 8 * state.source.uv_stride + x * 8],
			state.source.uv_stride,
			&chroma,
		)

		chosen := index & 1 == 0 ? &cand8 : &cand4
		m.type = chosen.choice.type
		m.uses_8x8_transform = chosen.choice.uses_8x8_transform
		m.intra_4x4_modes = chosen.choice.intra_4x4_modes
		m.luma_coded_block_mask = chosen.choice.luma_coded_block_mask
		m.chroma_residual_mode = chosen.choice.chroma_residual_mode
		m.has_dc_coefficients = chosen.choice.has_dc_coefficients
		for b8 in 0 ..< 4 {
			m.has_8x8_coefficients[b8] =
				chosen.choice.uses_8x8_transform &&
				chosen.choice.luma_coded_block_mask & (1 << uint(b8)) != 0
		}
		for k in 0 ..< 24 do m.nonzero_coefficient_counts[k] = chosen.nonzero_coefficient_counts[k]

		before := common.cabac_enc_rate(&task.cabac.enc)
		write_macroblock_layer_cabac(task, &task.cabac, m, &chosen.choice, index)
		after := common.cabac_enc_rate(&task.cabac.enc)
		actual_bits := max(after - before, 1)
		testing.expect_value(t, chosen.bit_count, actual_bits)
	}
}

@(test)
test_cabac_and_8x8_encode_decode_bit_exact :: proc(t: ^testing.T) {
	Config_Case :: struct {
		cabac:         bool,
		transform_8x8: bool,
		slice_count:   int,
		qp:            i32,
	}
	cases := [4]Config_Case {
		{cabac = true, transform_8x8 = false, slice_count = 1, qp = 24},
		{cabac = true, transform_8x8 = true, slice_count = 1, qp = 20},
		{cabac = false, transform_8x8 = true, slice_count = 1, qp = 22},
		{cabac = true, transform_8x8 = true, slice_count = 2, qp = 26},
	}

	width, height :: 64, 48
	source := h264.alloc_yuv_buffer(width, height)
	defer h264.free_yuv_buffer(&source)

	for tc in cases {
		enc: Encoder_State
		testing.expect_value(
			t,
			init_encoder(
				&enc,
				{
					width          = width,
					height         = height,
					qp             = tc.qp,
					num_ref_frames = 2,
					slice_count    = tc.slice_count,
					cabac          = tc.cabac,
					transform_8x8  = tc.transform_8x8,
				},
			),
			Error.None,
		)
		defer destroy_encoder(&enc)

		dec: decoder.Decoder_State
		decoder.init_decoder(&dec)
		defer decoder.destroy_decoder(&dec)

		out_nal: [dynamic]u8
		defer delete(out_nal)

		for frame_idx in 0 ..< 5 {
			for y in 0 ..< height do for x in 0 ..< width {
				val: u8
				if y >= 32 {
					val = 96
				} else if (x + frame_idx * 3) & 16 != 0 {
					val = u8(((x + frame_idx * 2) * 19 + (y + frame_idx) * 31) & 255)
				} else {
					val = u8((x * 5 + y * 7 + frame_idx * 11) & 255)
				}
				source.y[y * source.y_stride + x] = val
			}
			for y in 0 ..< height / 2 do for x in 0 ..< width / 2 {
				source.u[y * source.uv_stride + x] = u8((80 + x * 9 + y * 5 + frame_idx * 7) & 255)
				source.v[y * source.uv_stride + x] = u8((160 - x * 7 + y * 11 - frame_idx * 5) & 255)
			}

			clear(&out_nal)
			testing.expect_value(
				t,
				encode_frame(
					&enc,
					source.y,
					source.u,
					source.v,
					source.y_stride,
					source.uv_stride,
					frame_idx == 0,
					&out_nal,
				),
				Error.None,
			)
			testing.expect(t, len(out_nal) > 0)

			nals := h264.find_nal_units(out_nal[:])
			defer delete(nals)
			frame_ready := false
			for loc in nals {
				ready, dec_err := decoder.decode_nal(&dec, out_nal[loc.offset:loc.offset + loc.length])
				testing.expect_value(t, dec_err, decoder.Error.None)
				if ready do frame_ready = true
			}
			testing.expect(t, frame_ready)
			dec_frame := dec.output
			testing.expect(t, dec_frame != nil)
			if dec_frame == nil do continue

			enc_rec := &enc.refs[0].buf
			for y in 0 ..< height {
				for x in 0 ..< width {
					got := dec_frame.buf.y[y * dec_frame.buf.y_stride + x]
					exp := enc_rec.y[y * enc_rec.y_stride + x]
					if got != exp {
						testing.expectf(
							t,
							false,
							"Luma mismatch (cabac=%v, 8x8=%v, slices=%d, frame=%d) at (%d,%d): dec=%d enc=%d",
							tc.cabac,
							tc.transform_8x8,
							tc.slice_count,
							frame_idx,
							x,
							y,
							got,
							exp,
						)
						return
					}
				}
			}
			for y in 0 ..< height / 2 {
				for x in 0 ..< width / 2 {
					got_u := dec_frame.buf.u[y * dec_frame.buf.uv_stride + x]
					exp_u := enc_rec.u[y * enc_rec.uv_stride + x]
					got_v := dec_frame.buf.v[y * dec_frame.buf.uv_stride + x]
					exp_v := enc_rec.v[y * enc_rec.uv_stride + x]
					if got_u != exp_u || got_v != exp_v {
						testing.expectf(
							t,
							false,
							"Chroma mismatch (cabac=%v, 8x8=%v, slices=%d, frame=%d) at (%d,%d): U(%d vs %d) V(%d vs %d)",
							tc.cabac,
							tc.transform_8x8,
							tc.slice_count,
							frame_idx,
							x,
							y,
							got_u,
							exp_u,
							got_v,
							exp_v,
						)
						return
					}
				}
			}
		}
	}
}

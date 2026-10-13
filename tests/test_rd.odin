package main

import h264 "../codec/h264"
import avc_enc "../codec/h264/encoder"
import "core:fmt"
import "core:os"

// Score real residual trials, then measure the production writer after the
// same publication used by encode_macroblock. Stale trial flags must not make
// residual bits disappear from the rate/distortion decision.
main :: proc() {
	failures, checked := 0, 0
	for qp in ([4]i32{22, 26, 34, 51}) {
		st: avc_enc.Encoder_State
		avc_enc.init_encoder(
			&st,
			{width = 16, height = 16, qp = qp, gop_size = 15, slice_count = 1},
		)
		defer avc_enc.destroy_encoder(&st)
		src := h264.alloc_yuv_buffer(16, 16)
		defer h264.free_yuv_buffer(&src)
		stream := make([dynamic]u8)
		defer delete(stream)
		for frame in 0 ..< 2 {
			for y in 0 ..< 16 do for x in 0 ..< 16 do src.y[y * src.y_stride + x] = u8((x * 13 + y * 7 + frame * 31) & 255)
			for y in 0 ..< 8 do for x in 0 ..< 8 {
				src.u[y * src.uv_stride + x] = u8((x * 31 + y * 9 + frame * 19) & 255)
				src.v[y * src.uv_stride + x] = u8((x * 11 + y * 27 + frame * 13) & 255)
			}
			if frame == 0 do assert(avc_enc.encode_frame(&st, src.y, src.u, src.v, src.y_stride, src.uv_stride, true, &stream) == .None)
		}
		assert(
			avc_enc.begin_encode_frame(
				&st,
				src.y,
				src.u,
				src.v,
				src.y_stride,
				src.uv_stride,
				false,
			) ==
			.None,
		)
		task := &st.slices[0]
		m := &task.grid.macroblocks[0]
		rec := &st.curr.buf
		source := &st.source
		for idr in ([2]bool{true, false}) {
			task.is_idr = idr
			for kind in ([3]h264.Macroblock_Type{.I_4x4, .I_16x16, .P_L0_16x16}) {
				if idr && kind == .P_L0_16x16 do continue
				for poison in 0 ..< 2 {
					m^ = {
						slice_index = 0,
						quantizer   = i8(qp),
						type        = kind,
						is_intra    = kind != .P_L0_16x16,
					}
					m.luma_coded_block_mask, m.chroma_residual_mode =
						poison == 0 ? 0 : 15, poison == 0 ? .None : .DC_And_AC
					trial: avc_enc.Macroblock_Candidate
					trial.choice.type = kind
					if kind == .I_4x4 {
						avc_enc.evaluate_intra_4x4_candidate(
							task,
							m,
							&trial,
							0,
							source.y,
							source.y_stride,
							rec.y,
							rec.y_stride,
							{},
							task.motion_lambda,
						)
					} else if kind == .I_16x16 {
						trial.choice.intra_16x16_mode = .DC
						m.intra_16x16_mode = .DC
						h264.predict_intra_16x16(rec.y, rec.y_stride, .DC, false, false)
						avc_enc.code_luma_16x16(
							task,
							m,
							&trial.choice,
							source.y,
							source.y_stride,
							rec.y,
							rec.y_stride,
						)
					} else {
						for k in 0 ..< 4 {
							m.reference_indices[0][k] = 0
							m.reference_picture_ids[0][k] = st.refs[0].pic_id
							m.prediction_directions[k] = h264.Prediction_Direction.List_0
						}
						avc_enc.predict_inter_macroblock_encoder(task, m, 0)
						avc_enc.code_luma_4x4(
							task,
							m,
							&trial.choice,
							source.y,
							source.y_stride,
							rec.y,
							rec.y_stride,
							false,
						)
					}
					avc_enc.evaluate_chroma_candidate(
						task,
						m,
						&trial,
						0,
						source.u,
						source.v,
						source.uv_stride,
						{},
						m.is_intra,
						task.motion_lambda,
					)
					avc_enc.score_macroblock_candidate(
						task,
						m,
						&trial,
						0,
						source.y,
						source.y_stride,
						source.u,
						source.v,
						source.uv_stride,
					)
					m.luma_coded_block_mask, m.chroma_residual_mode =
						trial.choice.luma_coded_block_mask, trial.choice.chroma_residual_mode
					bits := make([dynamic]u8)
					writer := h264.init_bit_writer(&bits)
					avc_enc.write_macroblock_layer(task, &writer, m, &trial.choice, 0)
					actual := len(bits) * 8 + writer.nbits
					if trial.bit_count != actual {
						fmt.printfln(
							"[FAIL] qp=%d idr=%v mode=%v prior_flags=%d estimate=%d writer=%d",
							qp,
							idr,
							kind,
							poison,
							trial.bit_count,
							actual,
						)
						failures += 1
					}
					delete(bits)
					checked += 1
				}
			}
		}
		// Internal CAVLC neighbours must come from earlier winning blocks,
		// independent of nonzero counts left by a previous macroblock trial.
		a, b: avc_enc.Macroblock_Candidate
		for pass in 0 ..< 2 {
			m^ = {
				slice_index = 0,
				quantizer   = i8(qp),
			}
			for k in 0 ..< 24 do m.nonzero_coefficient_counts[k] = pass == 0 ? 0 : 16
			avc_enc.evaluate_intra_4x4_candidate(
				task,
				m,
				pass == 0 ? &a : &b,
				0,
				source.y,
				source.y_stride,
				rec.y,
				rec.y_stride,
				{},
				task.motion_lambda,
			)
		}
		if a.choice != b.choice {
			fmt.printfln(
				"[FAIL] qp=%d intra4 decision depends on previous trial nonzero counts",
				qp,
			)
			failures += 1
		}
	}
	fmt.printfln("RD trial/writer checks=%d failures=%d", checked, failures)
	if failures != 0 do os.exit(1)
}

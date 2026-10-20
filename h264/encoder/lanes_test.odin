package h264_encoder

import h264 ".."
import common "../../common"
import decoder "../decoder"
import "core:slice"
import "core:testing"

@(private)
lane_test_fill :: proc(source: ^h264.YUV_Buffer, index: int) {
	for row in 0 ..< source.height do for col in 0 ..< source.width do source.y[row * source.y_stride + col] = u8((col * 7 + row * 11 + index * 19 + ((col + index) % 13) * 5) & 255)
	for row in 0 ..< source.height / 2 do for col in 0 ..< source.width / 2 {
		source.u[row * source.uv_stride + col] = u8((col * 13 + row * 3 + index * 17) & 255)
		source.v[row * source.uv_stride + col] = u8((col * 5 + row * 17 + index * 23) & 255)
	}
}

@(private)
lane_test_same_picture :: proc(t: ^testing.T, a, b: ^h264.YUV_Buffer, width, height: int) {
	for row in 0 ..< height do for col in 0 ..< width do testing.expect_value(t, a.y[row * a.y_stride + col], b.y[row * b.y_stride + col])
	for row in 0 ..< height / 2 do for col in 0 ..< width / 2 {
		testing.expect_value(t, a.u[row * a.uv_stride + col], b.u[row * b.uv_stride + col])
		testing.expect_value(t, a.v[row * a.uv_stride + col], b.v[row * b.uv_stride + col])
	}
}

@(private)
lane_test_same_history :: proc(t: ^testing.T, a, b: ^Encoder_State) {
	testing.expect_value(t, a.frames_coded, b.frames_coded)
	testing.expect_value(t, a.frame_num, b.frame_num)
	testing.expect_value(t, a.idr_pic_id, b.idr_pic_id)
	testing.expect_value(t, a.next_pic_id, b.next_pic_id)
	testing.expect_value(t, a.rate, b.rate)
	testing.expect_value(t, a.num_refs, b.num_refs)
	for r in 0 ..< a.num_refs {
		testing.expect_value(t, a.refs[r].pic_id, b.refs[r].pic_id)
		testing.expect_value(t, a.refs[r].frame_num, b.refs[r].frame_num)
		lane_test_same_picture(t, &a.refs[r].buf, &b.refs[r].buf, a.config.width, a.config.height)
	}
}

@(test)
test_borrowed_lanes_match_contiguous_stream_and_decode :: proc(t: ^testing.T) {
	// Uneven row bands and periodic IDR exercise both ordered parameter lanes
	// and references. Worker count changes scheduling, never bitstream layout.
	for workers in ([2]int{0, 3}) {
		pool: common.Static_Pool
		common.init_static_pool(&pool, workers)
		defer common.destroy_static_pool(&pool)
		work: ^common.Work_Pool
		if workers != 0 do work = &pool.work_pool
		config := Encoder_Config {
			width          = 48,
			height         = 80,
			qp             = 26,
			num_ref_frames = 2,
			slice_count    = 3,
			bitrate_kbps   = 80,
			fps            = 30,
			gop_size       = 3,
		}
		stream_encoder, lane_encoder: Encoder_State
		testing.expect_value(t, init_encoder(&stream_encoder, config), Error.None)
		testing.expect_value(t, init_encoder(&lane_encoder, config), Error.None)
		defer destroy_encoder(&stream_encoder)
		defer destroy_encoder(&lane_encoder)
		source := h264.alloc_yuv_buffer(config.width, config.height)
		defer h264.free_yuv_buffer(&source)
		stream, gathered: [dynamic]u8
		defer delete(stream)
		defer delete(gathered)
		decoded: decoder.Decoder_State
		decoder.init_decoder(&decoded)
		defer decoder.destroy_decoder(&decoded)
		for frame in 0 ..< 6 {
			lane_test_fill(&source, frame)
			idr := frame % 3 == 0
			testing.expect_value(
				t,
				encode_frame(
					&stream_encoder,
					source.y,
					source.u,
					source.v,
					source.y_stride,
					source.uv_stride,
					idr,
					&stream,
					work,
				),
				Error.None,
			)
			lanes, err := encode_frame_lanes(
				&lane_encoder,
				source.y,
				source.u,
				source.v,
				source.y_stride,
				source.uv_stride,
				idr,
				work,
			)
			testing.expect_value(t, err, Error.None)
			testing.expect(t, raw_data(lanes) == raw_data(lane_encoder.nal_lanes))
			testing.expect_value(t, len(lanes), lane_encoder.frame.num_slices + (idr ? 2 : 0))
			for nal, index in lanes {
				testing.expect(
					t,
					len(nal) >= 5 && nal[0] == 0 && nal[1] == 0 && nal[2] == 0 && nal[3] == 1,
				)
				if idr && index < 2 {
					testing.expect(
						t,
						raw_data(nal) == raw_data(lane_encoder.parameter_nals[index]),
					)
				} else {
					testing.expect(
						t,
						raw_data(nal) == raw_data(lane_encoder.slices[index - (idr ? 2 : 0)].nal),
					)
				}
				append(&gathered, ..nal)
				ready, decode_error := decoder.decode_nal(&decoded, nal[4:])
				testing.expect_value(t, decode_error, decoder.Error.None)
				if ready {
					lane_test_same_picture(
						t,
						&lane_encoder.curr.buf,
						&decoded.output.buf,
						config.width,
						config.height,
					)
					testing.expect(t, decoder.next_output_frame(&decoded) == nil)
				}
			}
			testing.expect(t, slice.equal(stream[:], gathered[:]))
			lane_test_same_history(t, &stream_encoder, &lane_encoder)
			// Flush one completed native frame before its borrowed encoder lanes
			// and decoder output storage can be reused by the next frame.
			if decoder.flush_decoder(&decoded) {
				lane_test_same_picture(
					t,
					&lane_encoder.curr.buf,
					&decoded.output.buf,
					config.width,
					config.height,
				)
				testing.expect(t, decoder.next_output_frame(&decoded) == nil)
			}
		}
	}
}

@(test)
test_lane_cancellation_and_output_ownership_refusals :: proc(t: ^testing.T) {
	config := Encoder_Config {
		width          = 32,
		height         = 48,
		qp             = 26,
		slice_count    = 2,
		num_ref_frames = 2,
	}
	state, control: Encoder_State
	testing.expect_value(t, init_encoder(&state, config), Error.None)
	testing.expect_value(t, init_encoder(&control, config), Error.None)
	defer destroy_encoder(&state)
	defer destroy_encoder(&control)
	source := h264.alloc_yuv_buffer(config.width, config.height)
	defer h264.free_yuv_buffer(&source)
	lane_test_fill(&source, 0)
	stream, gathered: [dynamic]u8
	defer delete(stream)
	defer delete(gathered)
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
	ready, err := advance_encode_frame(&state, 1)
	testing.expect_value(t, err, Error.None)
	testing.expect(t, !ready)
	testing.expect_value(t, cancel_encode_frame(&state), Error.None)
	testing.expect_value(t, state.frames_coded, 0)
	testing.expect_value(t, state.num_refs, 0)
	testing.expect_value(t, state.frame.phase, Encoder_Phase.Idle)
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
	testing.expect_value(t, complete_encode_frame_work(&state, nil), Error.None)
	lanes, commit_error := commit_frame_lanes(&state)
	testing.expect_value(t, commit_error, Error.None)
	for lane in lanes do append(&gathered, ..lane)
	testing.expect_value(
		t,
		encode_frame(
			&control,
			source.y,
			source.u,
			source.v,
			source.y_stride,
			source.uv_stride,
			true,
			&stream,
		),
		Error.None,
	)
	testing.expect(t, slice.equal(gathered[:], stream[:]))
	lane_test_same_history(t, &state, &control)
	before := state.frames_coded
	testing.expect_value(
		t,
		encode_frame(
			&state,
			source.y,
			source.u,
			source.v,
			source.y_stride,
			source.uv_stride,
			false,
			&stream,
		),
		Error.Output_Owner_Mismatch,
	)
	testing.expect_value(t, state.frames_coded, before)
	_, checkpoint_error := capture_encoder_checkpoint(&state, &stream)
	testing.expect_value(t, checkpoint_error, Error.Borrowed_Output_Checkpoints)
	_, lane_error := encode_frame_lanes(
		&control,
		source.y,
		source.u,
		source.v,
		source.y_stride,
		source.uv_stride,
		false,
	)
	testing.expect_value(t, lane_error, Error.Output_Owner_Mismatch)
	testing.expect_value(t, control.frames_coded, before)

	retained: Encoder_State
	config.checkpoint_capacity = 1
	testing.expect_value(t, init_encoder(&retained, config), Error.None)
	defer destroy_encoder(&retained)
	_, lane_error = encode_frame_lanes(
		&retained,
		source.y,
		source.u,
		source.v,
		source.y_stride,
		source.uv_stride,
		true,
	)
	testing.expect_value(t, lane_error, Error.Borrowed_Output_Checkpoints)
	testing.expect_value(t, retained.frame.phase, Encoder_Phase.Idle)
	testing.expect_value(
		t,
		begin_encode_frame(
			&retained,
			source.y,
			source.u,
			source.v,
			source.y_stride,
			source.uv_stride,
			true,
		),
		Error.None,
	)
	testing.expect_value(t, complete_encode_frame_work(&retained, nil), Error.None)
	_, lane_error = commit_frame_lanes(&retained)
	testing.expect_value(t, lane_error, Error.Borrowed_Output_Checkpoints)
	testing.expect_value(t, retained.frame.phase, Encoder_Phase.Ready)
	other_stream: [dynamic]u8
	defer delete(other_stream)
	testing.expect_value(t, commit_encode_frame(&retained, &other_stream), Error.None)
	testing.expect(t, slice.equal(other_stream[:], stream[:]))
}

@(test)
test_encoder_typed_admission_preserves_existing_state :: proc(t: ^testing.T) {
	state: Encoder_State
	for config in ([]Encoder_Config{{width = 0, height = 16}, {width = 15, height = 16}, {width = 16, height = 17}, {width = 16, height = 16, qp = -1}, {width = 16, height = 16, qp = 52}, {width = max(int) - 1, height = 16}}) {
		testing.expect_value(t, init_encoder(&state, config), Error.Invalid_Config)
		testing.expect(t, state.macroblocks == nil && state.pictures == nil)
	}
	testing.expect_value(
		t,
		begin_encode_frame(&state, nil, nil, nil, 16, 8, true),
		Error.Invalid_State,
	)
	testing.expect_value(t, init_encoder(&state, {width = 16, height = 16, qp = 26}), Error.None)
	defer destroy_encoder(&state)
	pictures := raw_data(state.pictures)
	testing.expect_value(t, init_encoder(&state, {width = 32, height = 32, qp = 26}), Error.Busy)
	testing.expect(t, raw_data(state.pictures) == pictures && state.config.width == 16)
	testing.expect_value(
		t,
		begin_encode_frame(&state, nil, nil, nil, 16, 8, false),
		Error.First_Frame_Must_Be_IDR,
	)
	testing.expect_value(
		t,
		begin_encode_frame(&state, nil, nil, nil, 16, 8, true),
		Error.Invalid_Input,
	)
	ready, err := advance_encode_frame(&state, 1)
	testing.expect(t, !ready)
	testing.expect_value(t, err, Error.Invalid_State)
	_, err = commit_frame_lanes(&state)
	testing.expect_value(t, err, Error.Invalid_State)
	testing.expect_value(t, release_encoder_checkpoint(&state, {}), Error.Invalid_Checkpoint)
	testing.expect(t, error_description(.None) == "" && error_description(.Invalid_Input) != "")
}

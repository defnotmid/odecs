package h264_encoder

import h264 ".."
import common "../../../common"
import decoder "../decoder"
import "core:mem"
import "core:testing"

@(test)
test_encoder_refuses_null_allocation_without_partial_state :: proc(t: ^testing.T) {
	state: Encoder_State
	testing.expect_value(
		t,
		init_encoder(&state, {width = 16, height = 16, qp = 26}, mem.nil_allocator()),
		Error.Allocation_Failed,
	)
	testing.expect(
		t,
		state.macroblocks == nil &&
		raw_data(state.pictures) == nil &&
		raw_data(state.slices) == nil,
	)
	// Cleanup is repeatable after failed initialization, and the state can be
	// initialized again with a functioning caller allocator.
	destroy_encoder(&state)
	testing.expect_value(t, init_encoder(&state, {width = 16, height = 16, qp = 26}), Error.None)
	destroy_encoder(&state)
}

@(test)
test_cpu_buffer_allocator_survives_foreign_caller_and_workers :: proc(t: ^testing.T) {
	for workers in ([2]int{0, 2}) {
		// Worker contexts and source/output ownership deliberately differ from
		// the allocator captured by both codec states at initialization.
		pool: common.Static_Pool
		common.init_static_pool(&pool, workers)
		defer common.destroy_static_pool(&pool)
		work: ^common.Work_Pool
		if workers != 0 do work = &pool.work_pool
		owner, ambient: mem.Tracking_Allocator
		mem.tracking_allocator_init(&owner, context.allocator)
		mem.tracking_allocator_init(&ambient, context.allocator)
		defer mem.tracking_allocator_destroy(&owner)
		defer mem.tracking_allocator_destroy(&ambient)
		owner.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		ambient.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		state: Encoder_State
		decoded: decoder.Decoder_State
		testing.expect_value(
			t,
			init_encoder(
				&state,
				{width = 32, height = 48, qp = 26, slice_count = 3, num_ref_frames = 2},
				mem.tracking_allocator(&owner),
			),
			Error.None,
		)
		decoder.init_decoder(&decoded, mem.tracking_allocator(&owner))
		source := h264.alloc_yuv_buffer(32, 48)
		defer h264.free_yuv_buffer(&source)
		lane_test_fill(&source, 0)
		{
			context.allocator = mem.tracking_allocator(&ambient)
			stream: [dynamic]u8
			defer delete(stream)
			for frame in 0 ..< 4 {
				start := len(stream)
				testing.expect_value(
					t,
					encode_frame(
						&state,
						source.y,
						source.u,
						source.v,
						source.y_stride,
						source.uv_stride,
						frame == 0,
						&stream,
						work,
					),
					Error.None,
				)
				nals := h264.find_nal_units(stream[start:])
				output_count := 0
				for nal in nals {
					ready, err := decoder.decode_nal(
						&decoded,
						stream[start + nal.offset:start + nal.offset + nal.length],
					)
					testing.expect_value(t, err, decoder.Error.None)
					if ready {
						lane_test_same_picture(t, &state.curr.buf, &decoded.output.buf, 32, 48)
						output_count += 1
						testing.expect(t, decoder.next_output_frame(&decoded) == nil)
					}
				}
				delete(nals)
				if decoder.flush_decoder(&decoded) {
					lane_test_same_picture(t, &state.curr.buf, &decoded.output.buf, 32, 48)
					output_count += 1
					testing.expect(t, decoder.next_output_frame(&decoded) == nil)
				}
				testing.expect_value(t, output_count, 1)
			}
			_, caller_owns_output := ambient.allocation_map[raw_data(stream)]
			_, codec_owns_picture := owner.allocation_map[raw_data(state.curr.buf.memory)]
			_, codec_owns_decoded_picture :=
				owner.allocation_map[raw_data(decoded.pics[0].buf.memory)]
			testing.expect(
				t,
				caller_owns_output && codec_owns_picture && codec_owns_decoded_picture,
			)
			destroy_encoder(&state)
			decoder.destroy_decoder(&decoded)
			testing.expect_value(t, owner.current_memory_allocated, i64(0))
			testing.expect_value(t, len(owner.allocation_map), 0)
			testing.expect(t, ambient.current_memory_allocated > 0)
		}
		testing.expect_value(t, ambient.current_memory_allocated, i64(0))
		testing.expect_value(t, len(ambient.allocation_map), 0)
		testing.expect_value(t, len(owner.bad_free_array), 0)
		testing.expect_value(t, len(ambient.bad_free_array), 0)
	}
}

@(test)
test_lane_storage_reuses_warmed_capacity :: proc(t: ^testing.T) {
	owner: mem.Tracking_Allocator
	mem.tracking_allocator_init(&owner, context.allocator)
	defer mem.tracking_allocator_destroy(&owner)
	owner.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	state: Encoder_State
	testing.expect_value(
		t,
		init_encoder(
			&state,
			{width = 32, height = 48, qp = 26, slice_count = 3},
			mem.tracking_allocator(&owner),
		),
		Error.None,
	)
	source := h264.alloc_yuv_buffer(32, 48)
	defer h264.free_yuv_buffer(&source)
	lane_test_fill(&source, 0)
	// Repeating exactly the same IDR image isolates lane publication capacity
	// from source complexity changes. This is a structural allocation control,
	// not a throughput claim for arbitrary streams.
	for _ in 0 ..< 4 {
		_, err := encode_frame_lanes(
			&state,
			source.y,
			source.u,
			source.v,
			source.y_stride,
			source.uv_stride,
			true,
		)
		testing.expect_value(t, err, Error.None)
	}
	allocations := owner.total_allocation_count
	descriptors := raw_data(state.nal_lanes)
	for _ in 0 ..< 4 {
		lanes, err := encode_frame_lanes(
			&state,
			source.y,
			source.u,
			source.v,
			source.y_stride,
			source.uv_stride,
			true,
		)
		testing.expect_value(t, err, Error.None)
		testing.expect(t, raw_data(lanes) == descriptors)
	}
	testing.expect_value(t, owner.total_allocation_count, allocations)
	destroy_encoder(&state)
	testing.expect_value(t, owner.current_memory_allocated, i64(0))
	testing.expect_value(t, len(owner.bad_free_array), 0)
}

@(test)
test_decoder_sps_resize_uses_initial_allocator :: proc(t: ^testing.T) {
	owner, ambient: mem.Tracking_Allocator
	mem.tracking_allocator_init(&owner, context.allocator)
	mem.tracking_allocator_init(&ambient, context.allocator)
	defer mem.tracking_allocator_destroy(&owner)
	defer mem.tracking_allocator_destroy(&ambient)
	owner.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	ambient.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	decoded: decoder.Decoder_State
	decoder.init_decoder(&decoded, mem.tracking_allocator(&owner))
	for dimensions in ([2][2]int{{16, 16}, {32, 48}}) {
		encoded: Encoder_State
		testing.expect_value(
			t,
			init_encoder(
				&encoded,
				{width = dimensions[0], height = dimensions[1], qp = 26, slice_count = 2},
			),
			Error.None,
		)
		source := h264.alloc_yuv_buffer(dimensions[0], dimensions[1])
		lane_test_fill(&source, 0)
		lanes, err := encode_frame_lanes(
			&encoded,
			source.y,
			source.u,
			source.v,
			source.y_stride,
			source.uv_stride,
			true,
		)
		testing.expect_value(t, err, Error.None)
		{
			context.allocator = mem.tracking_allocator(&ambient)
			output_count := 0
			for lane in lanes {
				ready, decode_error := decoder.decode_nal(&decoded, lane[4:])
				testing.expect_value(t, decode_error, decoder.Error.None)
				if ready {
					lane_test_same_picture(
						t,
						&encoded.curr.buf,
						&decoded.output.buf,
						dimensions[0],
						dimensions[1],
					)
					output_count += 1
					testing.expect(t, decoder.next_output_frame(&decoded) == nil)
				}
			}
			if decoder.flush_decoder(&decoded) {
				lane_test_same_picture(
					t,
					&encoded.curr.buf,
					&decoded.output.buf,
					dimensions[0],
					dimensions[1],
				)
				output_count += 1
				testing.expect(t, decoder.next_output_frame(&decoded) == nil)
			}
			testing.expect_value(t, output_count, 1)
			backed := 0
			for &picture in decoded.pics {
				if raw_data(picture.buf.memory) == nil {
					testing.expect(t, raw_data(picture.motion) == nil)
					continue
				}
				_, owns_pixels := owner.allocation_map[raw_data(picture.buf.memory)]
				_, owns_motion := owner.allocation_map[raw_data(picture.motion)]
				testing.expect(t, owns_pixels && owns_motion)
				backed += 1
			}
			testing.expect_value(t, backed, 1)
			testing.expect_value(t, ambient.current_memory_allocated, i64(0))
		}
		h264.free_yuv_buffer(&source)
		destroy_encoder(&encoded)
	}
	{
		context.allocator = mem.tracking_allocator(&ambient)
		decoder.destroy_decoder(&decoded)
	}
	testing.expect_value(t, owner.current_memory_allocated, i64(0))
	testing.expect_value(t, len(owner.allocation_map), 0)
	testing.expect_value(t, len(owner.bad_free_array), 0)
	testing.expect_value(t, len(ambient.bad_free_array), 0)
}

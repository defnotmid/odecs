package h264_decoder

import h264 ".."
import "base:runtime"
import "core:mem"
import "core:slice"
import "core:testing"

@(private)
storage_test_sps :: proc(width, height: int) -> h264.Sequence_Parameter_Set {
	return {
		profile = .Baseline,
		level = .Level_3_1,
		chroma_format = .YUV_420,
		frames_only = true,
		width = width,
		height = height,
		macroblock_columns = width / 16,
		macroblock_rows = height / 16,
		macroblock_count = (width / 16) * (height / 16),
		frame_number_bits = 4,
		picture_order_mode = .Frame_Number,
		max_reference_frames = 4,
		allow_frame_number_gaps = true,
	}
}

@(private)
storage_test_backed :: proc(state: ^Decoder_State) -> int {
	count := 0
	for pic in state.pics do if raw_data(pic.buf.memory) != nil do count += 1
	return count
}

@(test)
test_native_storage_first_use_reuse_crop_and_geometry_owner :: proc(t: ^testing.T) {
	owner, ambient: mem.Tracking_Allocator
	mem.tracking_allocator_init(&owner, context.allocator)
	mem.tracking_allocator_init(&ambient, context.allocator)
	defer mem.tracking_allocator_destroy(&owner)
	defer mem.tracking_allocator_destroy(&ambient)
	owner.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	ambient.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	state: Decoder_State
	init_decoder(&state, mem.tracking_allocator(&owner))
	sps := storage_test_sps(32, 16)
	{
		context.allocator = mem.tracking_allocator(&ambient)
		before := owner.total_allocation_count
		testing.expect_value(t, activate_sequence_parameter_set(&state, &sps), Error.None)
		testing.expect_value(t, owner.total_allocation_count, before + 1) // one shared grid
		testing.expect_value(t, storage_test_backed(&state), 0)
		for pic in state.pics do testing.expect(t, raw_data(pic.motion) == nil)
		header := h264.Slice_Header {
			is_idr = true,
		}
		pic, e := start_picture_metadata(&state, &sps, &header)
		testing.expect_value(t, e, Error.None)
		testing.expect_value(t, prepare_picture_storage(&state, &sps), Error.None)
		testing.expect_value(t, owner.total_allocation_count, before + 3)
		testing.expect_value(t, storage_test_backed(&state), 1)
		for byte in pic.buf.memory do testing.expect_value(t, byte, u8(0))
		motion_bytes := slice.from_ptr(
			([^]u8)(raw_data(pic.motion)),
			len(pic.motion) * size_of(Reference_Motion),
		)
		for byte in motion_bytes do testing.expect_value(t, byte, u8(0))
		old_memory, old_motion := raw_data(pic.buf.memory), raw_data(pic.motion)
		pic.buf.y[0] = 193
		pic.motion[0].motion_vectors[0][7] = {12, -8}
		// Crop-only SPS changes preserve held output metadata and backing.
		pic.needed_for_output = true
		sps.width, sps.crop_left = 28, 2
		warm := owner.total_allocation_count
		testing.expect_value(t, activate_sequence_parameter_set(&state, &sps), Error.None)
		testing.expect_value(t, owner.total_allocation_count, warm)
		testing.expect_value(t, pic.buf.width, 32)
		testing.expect_value(t, pic.buf.crop_x, 0)
		// A released slot keeps its stale pixels/motion for damaged-stream parity.
		state.curr = nil
		pic.needed_for_output, pic.in_use = false, false
		pic, e = start_picture_metadata(&state, &sps, &header)
		testing.expect_value(t, e, Error.None)
		testing.expect_value(t, prepare_picture_storage(&state, &sps), Error.None)
		testing.expect_value(t, owner.total_allocation_count, warm)
		testing.expect(
			t,
			raw_data(pic.buf.memory) == old_memory && raw_data(pic.motion) == old_motion,
		)
		testing.expect_value(t, pic.buf.width, 28)
		testing.expect_value(t, pic.buf.crop_x, 4)
		testing.expect_value(t, pic.buf.y[0], u8(193))
		testing.expect(t, pic.motion[0].motion_vectors[0][7] == [2]i16{12, -8})
		// Transposed geometry has the same macroblock count and still must resize.
		sps = storage_test_sps(16, 32)
		testing.expect_value(t, activate_sequence_parameter_set(&state, &sps), Error.None)
		testing.expect_value(t, storage_test_backed(&state), 0)
		testing.expect_value(t, state.storage_width, 16)
		testing.expect_value(t, state.storage_height, 32)
		testing.expect(t, state.curr == nil && state.output_count == 0)
		_, owns_old := owner.allocation_map[old_memory]
		testing.expect(t, !owns_old)
		testing.expect_value(t, ambient.current_memory_allocated, i64(0))
		destroy_decoder(&state)
	}
	testing.expect_value(t, owner.current_memory_allocated, i64(0))
	testing.expect_value(t, len(owner.bad_free_array), 0)
	testing.expect_value(t, len(ambient.bad_free_array), 0)
}

@(test)
test_native_gap_reference_backing_and_collocated_motion_consumers :: proc(t: ^testing.T) {
	state: Decoder_State
	init_decoder(&state)
	defer destroy_decoder(&state)
	sps := storage_test_sps(16, 16)
	testing.expect_value(t, activate_sequence_parameter_set(&state, &sps), Error.None)
	header := h264.Slice_Header {
		frame_num  = 3,
		slice_type = .P,
	}
	pic, e := start_picture_metadata(&state, &sps, &header)
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, prepare_picture_storage(&state, &sps), Error.None)
	testing.expect_value(t, storage_test_backed(&state), 3)
	gap := &state.pics[0]
	testing.expect(t, gap.non_existing && gap.is_short_ref && raw_data(gap.buf.memory) != nil)
	state.ref_count[0] = 1
	state.ref_list[0][0] = gap
	state.macroblocks[0].prediction_directions[0] = .List_0
	state.macroblocks[0].reference_indices[0][0] = 0
	pps: h264.Picture_Parameter_Set
	d := Slice_Decoder {
		state = &state,
		picture = pic,
		header = &header,
		sequence_parameters = &sps,
		picture_parameters = &pps,
		grid = {macroblocks = state.macroblocks, macroblock_columns = 1},
	}
	mem.set(raw_data(pic.buf.memory), 173, len(pic.buf.memory))
	predict_inter_block(&d, 0, 0, 4, 4)
	for y in 0 ..< 16 do for x in 0 ..< 16 do testing.expect_value(t, pic.buf.y[y * pic.buf.y_stride + x], u8(0))
	// A backed reference retains every motion field consumed by temporal direct.
	gap.non_existing = false
	mb := &state.macroblocks[0]
	for k in 0 ..< 16 do mb.motion_vectors[0][k] = {8, -4}
	for k in 0 ..< 4 {
		mb.prediction_directions[k] = .List_0
		mb.reference_indices[0][k] = 0
		mb.reference_picture_ids[0][k] = gap.pic_id
	}
	state.curr = gap
	save_col_motion(&state, 1)
	state.curr = pic
	state.ref_count[1], state.ref_list[1][0] = 1, gap
	header.slice_type = .B
	derive_direct(&d, 0, 15)
	for k in 0 ..< 16 {
		testing.expect(t, mb.motion_vectors[0][k] == [2]i16{8, -4})
		testing.expect(t, mb.motion_vectors[1][k] == [2]i16{0, 0})
	}
}

@(test)
test_lazy_storage_output_order_holds_and_metadata_only_path :: proc(t: ^testing.T) {
	state: Decoder_State
	init_decoder(&state)
	defer destroy_decoder(&state)
	sps := storage_test_sps(16, 16)
	testing.expect_value(t, activate_sequence_parameter_set(&state, &sps), Error.None)
	state.pics[0].in_use, state.pics[1].in_use = true, true
	testing.expect_value(t, prepare_picture_storage(&state, &sps), Error.None)
	for i in 0 ..< 2 {
		state.pics[i].needed_for_output = true
		state.pics[i].poc = i == 0 ? 8 : 2
		state.pics[i].buf.y[0] = u8(31 + i)
	}
	flush_output(&state)
	first := next_output_frame(&state)
	second := next_output_frame(&state)
	testing.expect(t, first == &state.pics[1] && second == &state.pics[0])
	second.is_short_ref = true
	release_unused_pictures(&state)
	testing.expect_value(t, first.buf.y[0], u8(32))
	testing.expect(t, !first.in_use && second.in_use && second.buf.y[0] == 31)
	testing.expect_value(t, storage_test_backed(&state), 2)
	// Hardware frontends share descriptor selection but never native storage.
	{
		context.allocator = mem.panic_allocator()
		metadata: Decoder_State
		activate_sequence_parameter_set_metadata(&metadata, &sps)
		h := h264.Slice_Header {
			is_idr = true,
		}
		selected, err := start_picture_metadata(&metadata, &sps, &h)
		testing.expect_value(t, err, Error.None)
		testing.expect(t, selected == &metadata.pics[0] && metadata.macroblocks == nil)
		for slot in metadata.pics do testing.expect(t, raw_data(slot.buf.memory) == nil && raw_data(slot.motion) == nil)
	}
}

@(private)
Storage_Failure :: struct {
	backing:   mem.Allocator,
	remaining: int,
}

@(private)
storage_failure_alloc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old: rawptr,
	old_size: int,
	loc: runtime.Source_Code_Location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	f := (^Storage_Failure)(data)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		if f.remaining == 0 do return nil, .Out_Of_Memory
		if f.remaining > 0 do f.remaining -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old, old_size, loc)
}

@(test)
test_native_storage_typed_oom_partial_cleanup_and_retry :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	f := Storage_Failure{mem.tracking_allocator(&track), -1}
	state: Decoder_State
	init_decoder(&state, {procedure = storage_failure_alloc, data = &f})
	state.sequence_parameters[0] = storage_test_sps(16, 16)
	state.active_sequence_parameter_set_id, state.active_picture_parameter_set_id = 0, 0
	sps, pps := &state.sequence_parameters[0], &state.picture_parameters[0]
	header := h264.Slice_Header {
		is_idr     = true,
		slice_type = .I,
		slice_qp   = 26,
	}
	for allowed in 0 ..< 3 {
		f.remaining = allowed == 0 ? 0 : 1
		before := track.current_memory_allocated
		testing.expect_value(t, start_picture(&state, sps, pps, &header), Error.Allocation_Failed)
		testing.expect(
			t,
			state.curr == nil && state.output_count == 0 && storage_test_backed(&state) == 0,
		)
		if allowed != 1 do testing.expect_value(t, track.current_memory_allocated, before)
		testing.expect(t, !flush_decoder(&state))
	}
	f.remaining = 2
	testing.expect_value(t, start_picture(&state, sps, pps, &header), Error.None)
	testing.expect(
		t,
		state.curr != nil && raw_data(state.curr.motion) != nil && state.curr.buf.y != nil,
	)
	testing.expect_value(t, storage_test_backed(&state), 1)
	destroy_decoder(&state)
	testing.expect_value(t, track.current_memory_allocated, i64(0))
	// The nil allocator can return no error alongside a nil allocation.
	init_decoder(&state, mem.nil_allocator())
	sps_copy := storage_test_sps(16, 16)
	testing.expect_value(
		t,
		activate_sequence_parameter_set(&state, &sps_copy),
		Error.Allocation_Failed,
	)
	destroy_decoder(&state)
}

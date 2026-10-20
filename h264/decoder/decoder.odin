package h264_decoder

import h264 ".."

import "core:mem"

// ---------------------------------------------------------------------------
// Decoder lifecycle and NAL unit handling
// ---------------------------------------------------------------------------

init_decoder :: proc(state: ^Decoder_State, allocator := context.allocator) {
	mem.zero(state, size_of(Decoder_State))
	state.allocator = allocator
	state.active_sequence_parameter_set_id = -1
	state.active_picture_parameter_set_id = -1
	state.rbsp_buffer = make([dynamic]u8, 0, 64 * 1024, allocator)
	state.max_long_term_frame_idx = -1
}

destroy_decoder :: proc(state: ^Decoder_State) {
	release_pictures(state)
	delete(state.rbsp_buffer)
}

// The next decoded frame in output order after decode_nal reported one, nil when none is left.
next_output_frame :: proc(state: ^Decoder_State) -> ^Picture {
	if state.output_count == 0 do return nil
	state.output = state.output_queue[0]
	for i in 1 ..< state.output_count do state.output_queue[i - 1] = state.output_queue[i]
	state.output_count -= 1
	return state.output
}

// Finish the picture in progress and queue every remaining frame for output (end of stream).
flush_decoder :: proc(state: ^Decoder_State) -> (frame_ready: bool) {
	if state.curr != nil do finish_picture(state)
	flush_output(state)
	return next_output_frame(state) != nil
}

// First slice of a new picture (7.4.1.2.4)
starts_new_picture :: proc(
	state: ^Decoder_State,
	header: ^h264.Slice_Header,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
) -> bool {
	if state.curr == nil || !state.have_prev_slice do return true
	prev := &state.prev_slice
	if header.frame_num != prev.frame_num || header.pps_id != prev.pps_id do return true
	if (header.nal_ref_idc == 0) != (prev.nal_ref_idc == 0) do return true
	if header.is_idr != prev.is_idr do return true
	if header.is_idr && header.idr_pic_id != prev.idr_pic_id do return true
	#partial switch sequence_parameters.picture_order_mode {
	case .Explicit_Low_Bits:
		return(
			header.pic_order_cnt_lsb != prev.pic_order_cnt_lsb ||
			header.delta_pic_order_cnt_bottom != prev.delta_pic_order_cnt_bottom \
		)
	case .Reference_Cycle:
		return header.delta_pic_order_cnt != prev.delta_pic_order_cnt
	}
	return false
}

start_picture :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	picture_parameters: ^h264.Picture_Parameter_Set,
	header: ^h264.Slice_Header,
) -> Error {
	if state.curr != nil do finish_picture(state)
	if err := activate_sequence_parameter_set(state, sequence_parameters); err != .None do return err
	state.current_sequence_parameter_set_id = state.active_sequence_parameter_set_id
	state.current_picture_parameter_set_id = state.active_picture_parameter_set_id
	h264.compute_level_scales(&state.scales, sequence_parameters, picture_parameters)
	if _, err := start_picture_metadata(state, sequence_parameters, header); err != .None do return err
	if err := prepare_picture_storage(state, sequence_parameters); err != .None {
		// A failed first-use allocation must not leave a flushable picture whose
		// sample views have never been initialized. Retained references survive.
		state.curr.in_use = false
		state.curr = nil
		state.have_prev_slice = false
		return err
	}
	for i in 0 ..< sequence_parameters.macroblock_count do state.macroblocks[i].slice_index = 0xFFFF
	state.mbs_decoded = 0
	state.slice_index = 0
	return .None
}

// Start the picture descriptor and shared POC/reference semantics without
// allocating samples. The caller has finished the previous picture and
// activated SPS metadata. Hardware frontends can reuse the same DPB rules
// while GPU images provide the sample storage.
start_picture_metadata :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	header: ^h264.Slice_Header,
) -> (
	pic: ^Picture,
	err: Error,
) {
	if header.is_idr {
		state.prev_ref_frame_num = 0
	} else {
		fill_frame_num_gap(state, sequence_parameters, header)
	}
	pic = alloc_picture(state)
	if pic == nil do return nil, .No_Picture_Buffer
	set_picture_display(pic, sequence_parameters)
	state.curr = pic
	pic.frame_num = i32(header.frame_num)
	pic.is_idr = header.is_idr
	pic.field_order_counts = compute_poc_counts(state, sequence_parameters, header)
	pic.poc = min(pic.field_order_counts[0], pic.field_order_counts[1])
	return pic, .None
}

finish_picture :: proc(state: ^Decoder_State) {
	sequence_parameters := &state.sequence_parameters[state.current_sequence_parameter_set_id]
	picture_parameters := &state.picture_parameters[state.current_picture_parameter_set_id]
	header := &state.prev_slice
	// Missing macroblocks (damaged stream): leave the buffer content as is
	h264.deblock_picture(
		state.macroblocks,
		&state.curr.buf,
		sequence_parameters.macroblock_columns,
		sequence_parameters.macroblock_rows,
		{
			picture_parameters.chroma_qp_index_offset,
			picture_parameters.second_chroma_qp_index_offset,
		},
		8 + int(sequence_parameters.luma_bit_depth_minus_8),
	)
	h264.expand_picture(&state.curr.buf)
	if header.nal_ref_idc != 0 do save_col_motion(state, sequence_parameters.macroblock_count)
	finish_picture_marking(state, sequence_parameters, header)
	state.curr = nil
	state.have_prev_slice = false
}

// Decode one NAL unit (without start code). frame_ready reports that at least
// one frame is available through state.output / next_output_frame until the
// next call. err classifies damaged or unsupported input; decoding continues.
decode_nal :: proc(state: ^Decoder_State, nal_bytes: []u8) -> (frame_ready: bool, err: Error) {
	if len(nal_bytes) < 1 do return false, .Empty_NAL
	nal_ref_idc := (nal_bytes[0] >> 5) & 3
	nal_type := h264.Nal_Unit_Type(nal_bytes[0] & 0x1F)
	rbsp := h264.unescape_rbsp_into_buffer(nal_bytes[1:], &state.rbsp_buffer)
	reader := h264.init_bit_reader(rbsp)

	#partial switch nal_type {
	case .Sequence_Parameter_Set:
		sequence_parameters, ok := parse_sequence_parameter_set(&reader)
		if !ok do return false, .Malformed_SPS
		state.sequence_parameters[sequence_parameters.sequence_parameter_set_id] =
			sequence_parameters
		state.sequence_parameter_set_valid[sequence_parameters.sequence_parameter_set_id] = true
		return false, .None

	case .Picture_Parameter_Set:
		picture_parameters, ok := parse_picture_parameter_set(&reader, state)
		if !ok do return false, .Malformed_PPS
		state.picture_parameters[picture_parameters.pic_parameter_set_id] = picture_parameters
		state.picture_parameter_set_valid[picture_parameters.pic_parameter_set_id] = true
		return false, .None

	case .End_Of_Seq, .End_Of_Stream:
		return flush_decoder(state), .None

	case .Slice_IDR, .Slice_Non_IDR:
		release_unused_pictures(state)
		header, header_ok := parse_slice_header(&reader, nal_type, nal_ref_idc, state)
		if !header_ok do return false, .Malformed_Slice_Header
		sequence_parameters := &state.sequence_parameters[state.active_sequence_parameter_set_id]
		picture_parameters := &state.picture_parameters[state.active_picture_parameter_set_id]
		if admission := sequence_parameter_set_error(sequence_parameters, high_formats = true); admission != .None do return false, admission
		if admission := picture_parameter_set_error(picture_parameters); admission != .None do return false, admission
		if header.slice_type == .SP || header.slice_type == .SI do return false, .Unsupported_Slice_Type
		if header.redundant_pic_cnt > 0 do return false, .None // redundant slices are ignored

		if starts_new_picture(state, &header, sequence_parameters) {
			if start_err := start_picture(state, sequence_parameters, picture_parameters, &header); start_err != .None do return false, start_err
		} else {
			state.slice_index += 1
		}
		state.slice = header
		state.prev_slice = header
		state.have_prev_slice = true

		if header.slice_type == .B && state.max_reorder == 0 && !state.no_reordering do state.max_reorder = state.dpb_size
		build_ref_lists(state, sequence_parameters, &header)

		engine := &state.cabac
		slice_decoder := Slice_Decoder {
			state = state,
			sequence_parameters = sequence_parameters,
			picture_parameters = picture_parameters,
			header = &state.slice,
			reader = &reader,
			cabac = picture_parameters.entropy_coding_mode_flag,
			engine = engine,
			grid = {
				macroblocks = state.macroblocks,
				macroblock_columns = sequence_parameters.macroblock_columns,
				slice_index = state.slice_index,
			},
			picture = state.curr,
			macroblock_count = sequence_parameters.macroblock_count,
			bit_depth = 8 + int(sequence_parameters.luma_bit_depth_minus_8),
			qp_bd_offset = 6 * i32(sequence_parameters.luma_bit_depth_minus_8),
			chroma_422 = sequence_parameters.chroma_format == .YUV_422,
		}
		slice_err := decode_slice_data(&slice_decoder)

		if state.mbs_decoded >= sequence_parameters.macroblock_count {
			finish_picture(state)
		}
		return next_output_frame(state) != nil, slice_err

	case .Slice_DPA, .Slice_DPB, .Slice_DPC:
		return false, .Unsupported_Data_Partitioning
	}
	return false, .None
}

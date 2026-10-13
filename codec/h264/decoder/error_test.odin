package h264_decoder

import h264 ".."
import common "../../common"
import "core:testing"

@(private)
error_test_slice_header :: proc(kind: h264.Slice_Type) -> [dynamic]u8 {
	out: [dynamic]u8
	w := common.init_bit_writer(&out)
	append(&out, u8(h264.Nal_Unit_Type.Slice_Non_IDR))
	common.write_ue(&w, 0) // first macroblock
	common.write_ue(&w, u32(kind))
	common.write_ue(&w, 0) // PPS
	common.write_bits(&w, 0, 4) // frame number
	if kind == .P || kind == .SP do common.write_bits(&w, 0, 1) // no active-list override
	if kind != .I && kind != .SI do common.write_bits(&w, 0, 1) // no list modification
	common.write_se(&w, 0) // slice QP delta
	if kind == .SP do common.write_bits(&w, 0, 1) // sp_for_switch_flag
	if kind == .SP || kind == .SI do common.write_se(&w, 0) // slice QS delta
	common.write_rbsp_trailing_bits(&w)
	return out
}

@(test)
test_typed_parameter_admission_and_refusal_order :: proc(t: ^testing.T) {
	s := h264.Sequence_Parameter_Set {
		chroma_format                      = .YUV_444,
		luma_bit_depth_minus_8             = 2,
		bypass_transform_at_zero_quantizer = true,
		frames_only                        = false,
	}
	testing.expect_value(t, sequence_parameter_set_error(&s), Error.Unsupported_Chroma_Format)
	s.chroma_format = .YUV_420
	testing.expect_value(t, sequence_parameter_set_error(&s), Error.Unsupported_Bit_Depth)
	s.luma_bit_depth_minus_8 = 0
	s.chroma_bit_depth_minus_8 = 1
	testing.expect_value(t, sequence_parameter_set_error(&s), Error.Unsupported_Bit_Depth)
	s.chroma_bit_depth_minus_8 = 0
	testing.expect_value(t, sequence_parameter_set_error(&s), Error.Unsupported_Transform_Bypass)
	s.bypass_transform_at_zero_quantizer = false
	testing.expect_value(t, sequence_parameter_set_error(&s), Error.Unsupported_Interlaced)
	s.frames_only = true
	testing.expect_value(t, sequence_parameter_set_error(&s), Error.None)
	p: h264.Picture_Parameter_Set
	testing.expect_value(t, picture_parameter_set_error(&p), Error.None)
	slice_groups := [3]u32{1, 2, 7}
	for count in slice_groups {
		p.num_slice_groups_minus1 = count
		testing.expect_value(t, picture_parameter_set_error(&p), Error.Unsupported_Slice_Groups)
	}

	unsupported := []Error {
		.Unsupported_Chroma_Format,
		.Unsupported_Bit_Depth,
		.Unsupported_Transform_Bypass,
		.Unsupported_Interlaced,
		.Unsupported_Slice_Groups,
		.Unsupported_Slice_Type,
		.Unsupported_Data_Partitioning,
	}
	for err in unsupported {
		testing.expect(t, is_unsupported(err))
		testing.expect(t, len(error_description(err)) != 0)
	}
	other := []Error {
		.None,
		.Empty_NAL,
		.Malformed_SPS,
		.Malformed_PPS,
		.Malformed_Slice_Header,
		.No_Picture_Buffer,
		.Duplicate_Macroblock,
		.Skip_Run_Out_Of_Range,
		.Invalid_Macroblock_Type,
		.Invalid_Chroma_Prediction_Mode,
		.Invalid_Coded_Block_Pattern,
		.Invalid_QP_Delta,
		.Truncated_PCM,
		.Invalid_Reference_Index,
		.Invalid_Sub_Macroblock_Type,
	}
	for err in other {
		testing.expect(t, !is_unsupported(err))
		testing.expect(t, (len(error_description(err)) == 0) == (err == .None))
	}
}

@(test)
test_typed_nal_and_resource_failures :: proc(t: ^testing.T) {
	state: Decoder_State
	init_decoder(&state)
	defer destroy_decoder(&state)
	ready, err := decode_nal(&state, nil)
	testing.expect(t, !ready)
	testing.expect_value(t, err, Error.Empty_NAL)
	partitions := [3]h264.Nal_Unit_Type{.Slice_DPA, .Slice_DPB, .Slice_DPC}
	for kind in partitions {
		data := [1]u8{u8(kind)}
		ready, err = decode_nal(&state, data[:])
		testing.expect(t, !ready)
		testing.expect_value(t, err, Error.Unsupported_Data_Partitioning)
	}
	bad_sps: [dynamic]u8
	defer delete(bad_sps)
	w := common.init_bit_writer(&bad_sps)
	append(&bad_sps, u8(h264.Nal_Unit_Type.Sequence_Parameter_Set))
	common.write_bits(&w, 66, 8)
	common.write_bits(&w, 0, 8)
	common.write_bits(&w, 30, 8)
	common.write_ue(&w, 32) // out-of-range SPS id, before any shape allocation
	common.write_rbsp_trailing_bits(&w)
	ready, err = decode_nal(&state, bad_sps[:])
	testing.expect(t, !ready)
	testing.expect_value(t, err, Error.Malformed_SPS)
	bad_pps: [dynamic]u8
	defer delete(bad_pps)
	w = common.init_bit_writer(&bad_pps)
	append(&bad_pps, u8(h264.Nal_Unit_Type.Picture_Parameter_Set))
	common.write_ue(&w, 256)
	common.write_ue(&w, 0)
	common.write_rbsp_trailing_bits(&w)
	ready, err = decode_nal(&state, bad_pps[:])
	testing.expect(t, !ready)
	testing.expect_value(t, err, Error.Malformed_PPS)
	missing_pps := error_test_slice_header(.I)
	defer delete(missing_pps)
	ready, err = decode_nal(&state, missing_pps[:])
	testing.expect(t, !ready)
	testing.expect_value(t, err, Error.Malformed_Slice_Header)

	state.sequence_parameters[0] = {
		chroma_format      = .YUV_420,
		frames_only        = true,
		macroblock_count   = 1,
		frame_number_bits  = 4,
		picture_order_mode = .Frame_Number,
	}
	state.sequence_parameter_set_valid[0] = true
	state.picture_parameters[0] = {
		pic_init_qp                   = 26,
		num_ref_idx_l0_default_active = 1,
		num_ref_idx_l1_default_active = 1,
	}
	state.picture_parameter_set_valid[0] = true
	switching_slices := [2]h264.Slice_Type{.SP, .SI}
	for kind in switching_slices {
		data := error_test_slice_header(kind)
		ready, err = decode_nal(&state, data[:])
		delete(data)
		testing.expect(t, !ready)
		testing.expect_value(t, err, Error.Unsupported_Slice_Type)
		testing.expect(t, state.curr == nil && state.macroblocks == nil)
	}
	for &pic in state.pics do pic.in_use = true
	header := h264.Slice_Header {
		is_idr = true,
	}
	pic, picture_err := start_picture_metadata(&state, &state.sequence_parameters[0], &header)
	testing.expect(t, pic == nil && state.curr == nil)
	testing.expect_value(t, picture_err, Error.No_Picture_Buffer)
}

@(private)
error_test_ue :: proc(value: u32) -> [dynamic]u8 {
	out: [dynamic]u8
	w := common.init_bit_writer(&out)
	common.write_ue(&w, value)
	common.write_rbsp_trailing_bits(&w)
	return out
}

@(test)
test_typed_slice_failure_propagation :: proc(t: ^testing.T) {
	state: Decoder_State
	sps: h264.Sequence_Parameter_Set
	pps: h264.Picture_Parameter_Set
	header := h264.Slice_Header {
		slice_type = .I,
		slice_qp   = 26,
	}
	macroblocks := make(#soa[]h264.Macroblock, 1)
	defer delete(macroblocks)
	data := error_test_ue(26) // I macroblock type 26 is beyond I_PCM
	defer delete(data)
	reader := h264.init_bit_reader(data[:])
	d := Slice_Decoder {
		state = &state,
		sequence_parameters = &sps,
		picture_parameters = &pps,
		header = &header,
		reader = &reader,
		grid = {macroblocks = macroblocks, macroblock_columns = 1, slice_index = 1},
		macroblock_count = 1,
	}
	testing.expect_value(t, decode_macroblock(&d, 0), Error.Invalid_Macroblock_Type)
	testing.expect_value(t, state.mbs_decoded, 0)
	macroblocks[0].slice_index = 1
	reader = h264.init_bit_reader(data[:])
	testing.expect_value(t, decode_slice_data(&d), Error.Duplicate_Macroblock)
	testing.expect_value(t, state.mbs_decoded, 0)

	skip := error_test_ue(2) // exceeds one remaining macroblock
	defer delete(skip)
	reader = h264.init_bit_reader(skip[:])
	header.slice_type = .P
	macroblocks[0].slice_index = 0xFFFF
	testing.expect_value(t, decode_slice_data(&d), Error.Skip_Run_Out_Of_Range)
	testing.expect_value(t, state.mbs_decoded, 0)

	sub := error_test_ue(4) // P sub-macroblock syntax admits 0..3
	defer delete(sub)
	reader = h264.init_bit_reader(sub[:])
	macroblocks[0].type = .P_8x8
	testing.expect_value(
		t,
		read_sub_macroblock_prediction(&d, 0),
		Error.Invalid_Sub_Macroblock_Type,
	)
	macroblocks[0].type = .P_L0_16x16
	macroblocks[0].prediction_directions[0] = .List_0
	header.num_ref_idx_l0_active = 0
	testing.expect_value(t, read_macroblock_prediction(&d, 0), Error.Invalid_Reference_Index)
	reader = h264.init_bit_reader(nil)
	testing.expect_value(t, decode_pcm(&d, 0), Error.Truncated_PCM)
}

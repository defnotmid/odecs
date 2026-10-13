package gpu

import avc "../h264"
@(require) import "core:os"
import "core:testing"

@(test)
h264_std_parameters :: proc(t: ^testing.T) {
	s := avc.Sequence_Parameter_Set {
		profile                            = .High,
		level                              = .Level_4,
		sequence_parameter_set_id          = 3,
		chroma_format                      = .YUV_420,
		frame_number_bits                  = 8,
		picture_order_mode                 = .Reference_Cycle,
		reference_cycle_length             = 2,
		non_reference_picture_order_offset = -2,
		top_to_bottom_field_order_offset   = 3,
		max_reference_frames               = 4,
		frames_only                        = true,
		macroblock_columns                 = 120,
		macroblock_rows                    = 68,
		macroblock_count                   = 8160,
		width                              = 1920,
		height                             = 1080,
		has_cropping                       = true,
		crop_bottom                        = 4,
		has_scaling_matrices               = true,
	}
	s.has_scaling_list[0], s.use_default_scaling_list[0] = true, true
	s.reference_frame_order_offsets[0], s.reference_frame_order_offsets[1] = 2, -1
	s.scaling_list_4x4[0][0], s.scaling_list_8x8[0][5] = 17, 29
	p := avc.Picture_Parameter_Set {
		sequence_parameter_set_id       = 3,
		pic_parameter_set_id            = 255,
		num_ref_idx_l0_default_active   = 4,
		num_ref_idx_l1_default_active   = 2,
		pic_init_qp                     = 24,
		pic_init_qs                     = 26,
		entropy_coding_mode_flag        = true,
		weighted_bipred_idc             = 2,
		transform_8x8_mode_flag         = true,
		pic_scaling_matrix_present_flag = true,
	}
	p.has_scaling_list[1] = true
	p.scaling_list_4x4[1][7] = 41
	out: H264_Parameter_Storage
	testing.expect_value(t, map_h264_parameters(&out, &s, &p), Error.None)
	testing.expect(t, int(out.sps.profile_idc) == 100 && int(out.sps.level_idc) == 10)
	testing.expect(
		t,
		out.sps.pic_width_in_mbs_minus1 == 119 && out.sps.pic_height_in_map_units_minus1 == 67,
	)
	testing.expect(
		t,
		out.sps.frame_crop_bottom_offset == 4 && out.sps.log2_max_frame_num_minus4 == 4,
	)
	testing.expect(
		t,
		out.sps.pOffsetForRefFrame == &out.order_offsets[0] && out.order_offsets[1] == -1,
	)
	testing.expect(
		t,
		out.sps.pScalingLists == &out.sps_scaling && out.pps.pScalingLists == &out.pps_scaling,
	)
	testing.expect(
		t,
		out.sps_scaling.scaling_list_present_mask == 1 &&
		out.sps_scaling.use_default_scaling_matrix_mask == 1,
	)
	testing.expect(
		t,
		out.sps_scaling.ScalingList4x4[0][0] == 17 && out.sps_scaling.ScalingList8x8[0][5] == 29,
	)
	testing.expect(
		t,
		out.pps_scaling.ScalingList4x4[1][7] == 41 && out.pps.pic_init_qp_minus26 == -2,
	)
	testing.expect(
		t,
		out.pps.pic_parameter_set_id == 255 && out.pps.num_ref_idx_l0_default_active_minus1 == 3,
	)
	s.frames_only = false
	testing.expect_value(t, map_h264_parameters(&out, &s, &p), Error.Unsupported)
	s.frames_only = true; s.luma_bit_depth_minus_8 = 2
	testing.expect_value(t, map_h264_parameters(&out, &s, &p), Error.Unsupported)
	s.luma_bit_depth_minus_8 = 0; p.num_slice_groups_minus1 = 1
	testing.expect_value(t, map_h264_parameters(&out, &s, &p), Error.Unsupported)
}

@(test)
h264_frontend_input_contract :: proc(t: ^testing.T) {
	d: H264_Decoder
	testing.expect_value(t, init_h264_decoder(&d, {bit_depth = 10}), Error.Unsupported)
	testing.expect_value(t, init_h264_decoder(&d, {device_index = -1}), Error.None)
	testing.expect_value(t, init_h264_decoder(&d, {}), Error.Invalid_Argument)
	testing.expect(t, d.syntax.macroblocks == nil && d.syntax.pics[0].buf.y == nil)
	testing.expect_value(t, flush_h264_decoder(&d, nil, nil), Error.None)
	testing.expect_value(t, flush_h264_decoder(&d, nil, nil), Error.None)
	sei := [2]u8{0x06, 0x80}
	testing.expect_value(t, decode_h264_nal(&d, sei[:], nil, nil), Error.None)
	bad := [1]u8{0x80}
	testing.expect_value(t, decode_h264_nal(&d, bad[:], nil, nil), Error.Invalid_Argument)
	testing.expect(t, d.failed)
	testing.expect_value(t, decode_h264_nal(&d, sei[:], nil, nil), Error.Invalid_Argument)
	destroy_h264_decoder(&d)
	destroy_h264_decoder(&d)
	testing.expect(t, d.syntax.rbsp_buffer == nil && !d.initialized)
}

@(test)
h264_missing_reference_refusal :: proc(t: ^testing.T) {
	d: H264_Decoder
	testing.expect_value(t, init_h264_decoder(&d, {device_index = -1}), Error.None)
	defer destroy_h264_decoder(&d)
	d.seen_picture = true
	d.syntax.sequence_parameters[0] = {
		profile                    = .Baseline,
		level                      = .Level_1,
		chroma_format              = .YUV_420,
		frame_number_bits          = 4,
		picture_order_mode         = .Frame_Number,
		max_reference_frames       = 1,
		frames_only                = true,
		width                      = 16,
		height                     = 16,
		macroblock_columns         = 1,
		macroblock_rows            = 1,
		macroblock_count           = 1,
		has_bitstream_restrictions = true,
		max_buffered_frames        = 1,
	}
	d.syntax.picture_parameters[0] = {
		num_ref_idx_l0_default_active = 1,
		num_ref_idx_l1_default_active = 1,
		pic_init_qp                   = 26,
	}
	d.syntax.sequence_parameter_set_valid[0], d.syntax.picture_parameter_set_valid[0] = true, true
	d.syntax.pics[0].in_use, d.syntax.pics[0].is_short_ref = true, true
	d.syntax.pics[0].frame_num = 0
	// Frame 2 explicitly requests missing short-term frame 1. Native damaged
	// stream reconstruction may substitute frame 0; hardware must refuse it.
	data := make([dynamic]u8)
	defer delete(data)
	w := avc.init_bit_writer(&data)
	append(&data, u8(0x61))
	avc.write_unsigned_exp_golomb(&w, 0) // first MB
	avc.write_unsigned_exp_golomb(&w, 5) // P
	avc.write_unsigned_exp_golomb(&w, 0) // PPS
	avc.write_bits(&w, 2, 4) // frame_num
	avc.write_bits(&w, 0, 1) // active defaults
	avc.write_bits(&w, 1, 1) // explicit reference modification
	avc.write_unsigned_exp_golomb(&w, 0) // subtract
	avc.write_unsigned_exp_golomb(&w, 0) // abs_diff_pic_num_minus1
	avc.write_unsigned_exp_golomb(&w, 3) // end list
	avc.write_bits(&w, 0, 1) // sliding window marking
	avc.write_signed_exp_golomb(&w, 0) // QP delta
	avc.flush_bits_rbsp(&w)
	testing.expect_value(t, decode_h264_nal(&d, data[:], nil, nil), Error.Unsupported)
	testing.expect(
		t,
		d.failed && !d.backend.initialized && d.syntax.ref_list[0][0] == &d.syntax.pics[0],
	)
}

@(test)
h264_declared_format_admission :: proc(t: ^testing.T) {
	d: H264_Decoder
	testing.expect_value(
		t,
		init_h264_decoder(&d, {device_index = -1, profile_idc = 100}),
		Error.None,
	)
	defer destroy_h264_decoder(&d)
	d.syntax.dpb_size = 1
	s := avc.Sequence_Parameter_Set {
		profile            = .Baseline,
		width              = 16,
		height             = 16,
		macroblock_columns = 1,
		macroblock_rows    = 1,
	}
	p: avc.Picture_Parameter_Set
	testing.expect_value(t, h264_ensure_backend(&d, &s, &p, true), Error.Unsupported)
	testing.expect(t, !d.backend.initialized)
	// Exported consumer resources use this VkDevice through session close.
	// A changing SPS cannot destroy/recreate it underneath those resources.
	d.config.profile_idc = 0
	d.config.output_storage = .Device
	d.backend.initialized = true
	d.backend.config = {
		width       = 16,
		height      = 16,
		profile_idc = 66,
		dpb_slots   = 2,
	}
	s.width, s.macroblock_columns = 32, 2
	testing.expect_value(t, h264_ensure_backend(&d, &s, &p, true), Error.Unsupported)
	testing.expect(t, d.backend.initialized && d.backend.config.width == 16)
	// This unit admission test allocated no device resources.
	d.backend.initialized = false
}

when #config(ODECS_GPU_AVC_TEST, false) {
	H264_Test_Output :: struct {
		bytes:  [dynamic]u8,
		frames: int,
	}
	h264_test_receive :: proc(frame: H264_Frame, user: rawptr) {
		out := cast(^H264_Test_Output)user
		append_frame_samples(&out.bytes, frame)
		out.frames += 1
	}

	// An explicitly requested hardware gate fails on missing hardware/fixtures.
	// The reference is the full planar output in display order.
	@(test)
	h264_hardware_decode :: proc(t: ^testing.T) {
		fixture :: #config(ODECS_GPU_AVC_FIXTURE, "")
		reference :: #config(ODECS_GPU_AVC_REFERENCE, "")
		testing.expect(t, fixture != "" && reference != "")
		if fixture == "" || reference == "" do return
		data, e := os.read_entire_file(fixture, context.allocator)
		testing.expect(t, e == nil)
		if e != nil do return
		defer delete(data)
		ref, ref_e := os.read_entire_file(reference, context.allocator)
		testing.expect(t, ref_e == nil)
		if ref_e != nil do return
		defer delete(ref)
		d: H264_Decoder
		testing.expect_value(t, init_h264_decoder(&d, {device_index = -1}), Error.None)
		defer destroy_h264_decoder(&d)
		out: H264_Test_Output
		defer delete(out.bytes)
		nals := avc.find_nal_units(data)
		defer delete(nals)
		for nal in nals {
			err := decode_h264_nal(
				&d,
				data[nal.offset:nal.offset + nal.length],
				h264_test_receive,
				&out,
			)
			testing.expect_value(t, err, Error.None)
			if err != .None do return
		}
		testing.expect_value(t, flush_h264_decoder(&d, h264_test_receive, &out), Error.None)
		frames := out.frames
		testing.expect_value(t, flush_h264_decoder(&d, h264_test_receive, &out), Error.None)
		testing.expect(t, out.frames == frames && frames > 0)
		testing.expect_value(t, len(out.bytes), len(ref))
		if len(out.bytes) != len(ref) do return
		for byte, i in ref do if byte != out.bytes[i] {testing.expect_value(t, out.bytes[i], byte); return}
		testing.expect(t, d.syntax.macroblocks == nil && d.syntax.pics[0].buf.y == nil)
	}
}

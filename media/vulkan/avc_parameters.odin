package media_vulkan

import avc "../../video/h264"
import vk "vendor:vulkan"

// Fill this in its final location: the Vulkan structs point into this storage.
H264_Parameter_Storage :: struct {
	sps:                      vk.VideoH264SequenceParameterSet,
	pps:                      vk.VideoH264PictureParameterSet,
	sps_scaling, pps_scaling: vk.VideoH264ScalingLists,
	order_offsets:            [256]i32,
}

@(private)
h264_map_scaling :: proc(
	out: ^vk.VideoH264ScalingLists,
	lists4: [6][16]u8,
	lists8: [2][64]u8,
	present, defaults: [8]bool,
) {
	out.ScalingList4x4 = lists4
	for list, i in lists8 do out.ScalingList8x8[i] = list
	for yes, i in present do if yes do out.scaling_list_present_mask |= u16(1) << uint(i)
	for yes, i in defaults do if yes do out.use_default_scaling_matrix_mask |= u16(1) << uint(i)
}

map_h264_parameters :: proc(
	out: ^H264_Parameter_Storage,
	s: ^avc.Sequence_Parameter_Set,
	p: ^avc.Picture_Parameter_Set,
) -> Error {
	if out == nil || s == nil || p == nil do return .Invalid_Argument
	if s.sequence_parameter_set_id != p.sequence_parameter_set_id ||
	   s.sequence_parameter_set_id > 31 ||
	   p.pic_parameter_set_id > 255 ||
	   (s.profile != .Baseline && s.profile != .Main && s.profile != .High) ||
	   s.chroma_format != .YUV_420 ||
	   s.luma_bit_depth_minus_8 != 0 ||
	   s.chroma_bit_depth_minus_8 != 0 ||
	   !s.frames_only ||
	   s.adaptive_frame_field_coding ||
	   s.frame_number_bits < 4 ||
	   s.frame_number_bits > 16 ||
	   s.max_reference_frames > 16 ||
	   s.reference_cycle_length > 255 ||
	   s.macroblock_columns < 1 ||
	   s.macroblock_rows < 1 ||
	   p.num_slice_groups_minus1 != 0 ||
	   p.pic_init_qp < 0 ||
	   p.pic_init_qp > 51 ||
	   p.pic_init_qs < 0 ||
	   p.pic_init_qs > 51 ||
	   p.weighted_bipred_idc > 2 ||
	   p.num_ref_idx_l0_default_active < 1 ||
	   p.num_ref_idx_l0_default_active > 32 ||
	   p.num_ref_idx_l1_default_active < 1 ||
	   p.num_ref_idx_l1_default_active > 32 {
		return .Unsupported
	}
	if s.picture_order_mode == .Explicit_Low_Bits && (s.picture_order_low_bits < 4 || s.picture_order_low_bits > 16) do return .Unsupported
	out^ = {}
	levels := [19]u8{10, 11, 12, 13, 20, 21, 22, 30, 31, 32, 40, 41, 42, 50, 51, 52, 60, 61, 62}
	found := false
	for level, i in levels do if level == u8(s.level) {out.sps.level_idc = vk.VideoH264LevelIdc(i); found = true; break}
	if !found do return .Unsupported
	out.sps.profile_idc = vk.VideoH264ProfileIdc(s.profile)
	out.sps.chroma_format_idc = vk.VideoH264ChromaFormatIdc(s.chroma_format)
	out.sps.seq_parameter_set_id = u8(s.sequence_parameter_set_id)
	out.sps.log2_max_frame_num_minus4 = u8(s.frame_number_bits - 4)
	out.sps.pic_order_cnt_type = vk.VideoH264PocType(s.picture_order_mode)
	out.sps.offset_for_non_ref_pic = s.non_reference_picture_order_offset
	out.sps.offset_for_top_to_bottom_field = s.top_to_bottom_field_order_offset
	if s.picture_order_mode == .Explicit_Low_Bits do out.sps.log2_max_pic_order_cnt_lsb_minus4 = u8(s.picture_order_low_bits - 4)
	out.sps.num_ref_frames_in_pic_order_cnt_cycle = u8(s.reference_cycle_length)
	out.order_offsets = s.reference_frame_order_offsets
	if s.reference_cycle_length != 0 do out.sps.pOffsetForRefFrame = &out.order_offsets[0]
	out.sps.max_num_ref_frames = u8(s.max_reference_frames)
	out.sps.pic_width_in_mbs_minus1 = u32(s.macroblock_columns - 1)
	out.sps.pic_height_in_map_units_minus1 = u32(s.macroblock_rows - 1)
	out.sps.frame_crop_left_offset, out.sps.frame_crop_right_offset = s.crop_left, s.crop_right
	out.sps.frame_crop_top_offset, out.sps.frame_crop_bottom_offset = s.crop_top, s.crop_bottom
	out.sps.flags = {.frame_mbs_only_flag}
	if s.constraint_set_0 do out.sps.flags += {.constraint_set0_flag}
	if s.constraint_set_1 do out.sps.flags += {.constraint_set1_flag}
	if s.constraint_set_2 do out.sps.flags += {.constraint_set2_flag}
	if s.constraint_set_3 do out.sps.flags += {.constraint_set3_flag}
	if s.infer_direct_8x8_motion do out.sps.flags += {.direct_8x8_inference_flag}
	if s.picture_order_delta_always_zero do out.sps.flags += {.delta_pic_order_always_zero_flag}
	if s.allow_frame_number_gaps do out.sps.flags += {.gaps_in_frame_num_value_allowed_flag}
	if s.bypass_transform_at_zero_quantizer do out.sps.flags += {.qpprime_y_zero_transform_bypass_flag}
	if s.has_cropping do out.sps.flags += {.frame_cropping_flag}
	if s.has_scaling_matrices {
		out.sps.flags += {.seq_scaling_matrix_present_flag}
		h264_map_scaling(
			&out.sps_scaling,
			s.scaling_list_4x4,
			s.scaling_list_8x8,
			s.has_scaling_list,
			s.use_default_scaling_list,
		)
		out.sps.pScalingLists = &out.sps_scaling
	}
	// VUI timing/colour metadata is outside reconstruction. DPB/reordering uses
	// the native parsed bitstream restrictions in the syntax frontend.
	out.pps = {
		seq_parameter_set_id                 = u8(p.sequence_parameter_set_id),
		pic_parameter_set_id                 = u8(p.pic_parameter_set_id),
		num_ref_idx_l0_default_active_minus1 = u8(p.num_ref_idx_l0_default_active - 1),
		num_ref_idx_l1_default_active_minus1 = u8(p.num_ref_idx_l1_default_active - 1),
		weighted_bipred_idc                  = vk.VideoH264WeightedBipredIdc(
			p.weighted_bipred_idc,
		),
		pic_init_qp_minus26                  = i8(p.pic_init_qp - 26),
		pic_init_qs_minus26                  = i8(p.pic_init_qs - 26),
		chroma_qp_index_offset               = i8(p.chroma_qp_index_offset),
		second_chroma_qp_index_offset        = i8(p.second_chroma_qp_index_offset),
	}
	if p.transform_8x8_mode_flag do out.pps.flags += {.transform_8x8_mode_flag}
	if p.redundant_pic_cnt_present_flag do out.pps.flags += {.redundant_pic_cnt_present_flag}
	if p.constrained_intra_pred_flag do out.pps.flags += {.constrained_intra_pred_flag}
	if p.deblocking_filter_control_present_flag do out.pps.flags += {.deblocking_filter_control_present_flag}
	if p.weighted_pred_flag do out.pps.flags += {.weighted_pred_flag}
	if p.bottom_field_pic_order_in_frame_present_flag do out.pps.flags += {.bottom_field_pic_order_in_frame_present_flag}
	if p.entropy_coding_mode_flag do out.pps.flags += {.entropy_coding_mode_flag}
	if p.pic_scaling_matrix_present_flag {
		out.pps.flags += {.pic_scaling_matrix_present_flag}
		h264_map_scaling(
			&out.pps_scaling,
			p.scaling_list_4x4,
			p.scaling_list_8x8,
			p.has_scaling_list,
			p.use_default_scaling_list,
		)
		out.pps.pScalingLists = &out.pps_scaling
	}
	return .None
}

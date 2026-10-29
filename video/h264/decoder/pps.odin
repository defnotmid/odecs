package h264_decoder

import h264 ".."

parse_picture_parameter_set :: proc(
	reader: ^h264.Bit_Reader,
	state: ^Decoder_State,
) -> (
	picture_parameters: h264.Picture_Parameter_Set,
	ok: bool,
) {
	picture_parameters.pic_parameter_set_id = h264.read_ue(reader)
	picture_parameters.sequence_parameter_set_id = h264.read_ue(reader)
	if picture_parameters.pic_parameter_set_id >= 256 || picture_parameters.sequence_parameter_set_id >= 32 do return picture_parameters, false
	picture_parameters.entropy_coding_mode_flag = h264.read_bit(reader) == 1
	picture_parameters.bottom_field_pic_order_in_frame_present_flag = h264.read_bit(reader) == 1
	picture_parameters.num_slice_groups_minus1 = h264.read_ue(reader)

	if picture_parameters.num_slice_groups_minus1 > 0 {
		if picture_parameters.num_slice_groups_minus1 > 7 do return picture_parameters, false
		slice_group_map_type := h264.read_ue(reader)
		switch slice_group_map_type {
		case 0:
			for _ in 0 ..= picture_parameters.num_slice_groups_minus1 do _ = h264.read_ue(reader) // run_length_minus1
		case 2:
			for _ in 0 ..< picture_parameters.num_slice_groups_minus1 {
				_ = h264.read_ue(reader) // top_left
				_ = h264.read_ue(reader) // bottom_right
			}
		case 3, 4, 5:
			_ = h264.read_bit(reader) // slice_group_change_direction_flag
			_ = h264.read_ue(reader) // slice_group_change_rate_minus1
		case 6:
			pic_size_in_map_units := h264.read_ue(reader) + 1
			bits := uint(1)
			for (u32(1) << bits) < picture_parameters.num_slice_groups_minus1 + 1 do bits += 1
			for _ in 0 ..< pic_size_in_map_units do _ = h264.read_bits(reader, bits) // slice_group_id
		}
	}

	picture_parameters.num_ref_idx_l0_default_active = h264.read_ue(reader) + 1
	picture_parameters.num_ref_idx_l1_default_active = h264.read_ue(reader) + 1
	if picture_parameters.num_ref_idx_l0_default_active > 32 || picture_parameters.num_ref_idx_l1_default_active > 32 do return picture_parameters, false
	picture_parameters.weighted_pred_flag = h264.read_bit(reader) == 1
	picture_parameters.weighted_bipred_idc = u8(h264.read_bits(reader, 2))
	picture_parameters.pic_init_qp = 26 + h264.read_se(reader)
	picture_parameters.pic_init_qs = 26 + h264.read_se(reader)
	picture_parameters.chroma_qp_index_offset = clamp(h264.read_se(reader), -12, 12)
	picture_parameters.deblocking_filter_control_present_flag = h264.read_bit(reader) == 1
	picture_parameters.constrained_intra_pred_flag = h264.read_bit(reader) == 1
	picture_parameters.redundant_pic_cnt_present_flag = h264.read_bit(reader) == 1
	picture_parameters.second_chroma_qp_index_offset = picture_parameters.chroma_qp_index_offset

	if h264.has_more_rbsp_data(reader) {
		picture_parameters.transform_8x8_mode_flag = h264.read_bit(reader) == 1
		picture_parameters.pic_scaling_matrix_present_flag = h264.read_bit(reader) == 1
		if picture_parameters.pic_scaling_matrix_present_flag {
			// A PPS matrix falls back to the SPS lists (rule B) for lists not sent
			sps_id := picture_parameters.sequence_parameter_set_id
			is_444 :=
				state != nil &&
				state.sequence_parameter_set_valid[sps_id] &&
				state.sequence_parameters[sps_id].chroma_format == .YUV_444
			limit := 6 + (picture_parameters.transform_8x8_mode_flag ? (is_444 ? 6 : 2) : 0)
			for i in 0 ..< limit {
				present := h264.read_bit(reader) == 1
				if i < 8 {
					picture_parameters.has_scaling_list[i] = present
				} else {
					picture_parameters.has_chroma_scaling_list[i - 8] = present
				}
				if !present do continue
				if i < 6 {
					picture_parameters.use_default_scaling_list[i] = parse_scaling_list(
						reader,
						picture_parameters.scaling_list_4x4[i][:],
					)
				} else if i < 8 {
					picture_parameters.use_default_scaling_list[i] = parse_scaling_list(
						reader,
						picture_parameters.scaling_list_8x8[i - 6][:],
					)
				} else {
					picture_parameters.use_default_chroma_scaling_list[i - 8] = parse_scaling_list(
						reader,
						picture_parameters.chroma_scaling_list_8x8[i - 8][:],
					)
				}
			}
		}
		picture_parameters.second_chroma_qp_index_offset = clamp(h264.read_se(reader), -12, 12)
	}
	return picture_parameters, true
}

picture_parameter_set_error :: proc(picture_parameters: ^h264.Picture_Parameter_Set) -> Error {
	if picture_parameters.num_slice_groups_minus1 > 0 do return .Unsupported_Slice_Groups
	return .None
}

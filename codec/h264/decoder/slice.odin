package h264_decoder

import h264 ".."

// slice_header() (7.3.3). Activates the referenced PPS/SPS in `dec`.
parse_slice_header :: proc(
	reader: ^h264.Bit_Reader,
	nal_type: h264.Nal_Unit_Type,
	nal_ref_idc: u8,
	dec: ^Decoder_State,
) -> (
	header: h264.Slice_Header,
	ok: bool,
) {
	header.nal_ref_idc = nal_ref_idc
	header.is_idr = nal_type == .Slice_IDR
	header.first_mb_in_slice = int(h264.read_ue(reader))
	slice_type_raw := h264.read_ue(reader)
	if slice_type_raw > 9 do return header, false
	header.slice_type = h264.Slice_Type(slice_type_raw % 5)

	header.pps_id = h264.read_ue(reader)
	if header.pps_id >= 256 || !dec.picture_parameter_set_valid[header.pps_id] do return header, false
	picture_parameters := &dec.picture_parameters[header.pps_id]
	if !dec.sequence_parameter_set_valid[picture_parameters.sequence_parameter_set_id] do return header, false
	sequence_parameters := &dec.sequence_parameters[picture_parameters.sequence_parameter_set_id]
	dec.active_picture_parameter_set_id = int(header.pps_id)
	dec.active_sequence_parameter_set_id = int(picture_parameters.sequence_parameter_set_id)
	if header.first_mb_in_slice >= sequence_parameters.macroblock_count do return header, false

	header.frame_num = h264.read_bits(reader, uint(sequence_parameters.frame_number_bits))
	if header.is_idr do header.idr_pic_id = h264.read_ue(reader)

	#partial switch sequence_parameters.picture_order_mode {
	case .Explicit_Low_Bits:
		header.pic_order_cnt_lsb = h264.read_bits(
			reader,
			uint(sequence_parameters.picture_order_low_bits),
		)
		if picture_parameters.bottom_field_pic_order_in_frame_present_flag do header.delta_pic_order_cnt_bottom = h264.read_se(reader)
	case .Reference_Cycle:
		if !sequence_parameters.picture_order_delta_always_zero {
			header.delta_pic_order_cnt[0] = h264.read_se(reader)
			if picture_parameters.bottom_field_pic_order_in_frame_present_flag do header.delta_pic_order_cnt[1] = h264.read_se(reader)
		}
	}

	if picture_parameters.redundant_pic_cnt_present_flag do header.redundant_pic_cnt = h264.read_ue(reader)
	if header.slice_type == .B do header.direct_spatial_mv_pred_flag = h264.read_bit(reader) == 1

	header.num_ref_idx_l0_active = picture_parameters.num_ref_idx_l0_default_active
	header.num_ref_idx_l1_active = picture_parameters.num_ref_idx_l1_default_active
	if header.slice_type == .P || header.slice_type == .SP || header.slice_type == .B {
		if h264.read_bit(reader) == 1 { 	// num_ref_idx_active_override_flag
			header.num_ref_idx_l0_active = h264.read_ue(reader) + 1
			if header.slice_type == .B do header.num_ref_idx_l1_active = h264.read_ue(reader) + 1
		}
	}
	if header.num_ref_idx_l0_active > 32 || header.num_ref_idx_l1_active > 32 do return header, false

	// ref_pic_list_modification()
	if header.slice_type != .I && header.slice_type != .SI {
		lists := header.slice_type == .B ? 2 : 1
		for l in 0 ..< lists {
			if h264.read_bit(reader) == 0 do continue // ref_pic_list_modification_flag_lX
			for h264.has_more_rbsp_data(reader) {
				idc := h264.read_ue(reader)
				if idc == 3 do break
				if idc > 3 do return header, false
				value := h264.read_ue(reader)
				if header.num_reorder[l] < h264.MAX_REF_COMMANDS {
					header.reorder[l][header.num_reorder[l]] = {idc, value}
					header.num_reorder[l] += 1
				}
			}
		}
	}

	// pred_weight_table()
	if (picture_parameters.weighted_pred_flag &&
		   (header.slice_type == .P || header.slice_type == .SP)) ||
	   (picture_parameters.weighted_bipred_idc == 1 && header.slice_type == .B) {
		w := &header.weights
		w.luma_log2_denom = h264.read_ue(reader)
		w.chroma_log2_denom = h264.read_ue(reader)
		if w.luma_log2_denom > 7 || w.chroma_log2_denom > 7 do return header, false
		lists := header.slice_type == .B ? 2 : 1
		for l in 0 ..< lists {
			count := l == 0 ? header.num_ref_idx_l0_active : header.num_ref_idx_l1_active
			for i in 0 ..< count {
				w.luma_weight[l][i] = 1 << w.luma_log2_denom
				if h264.read_bit(reader) == 1 { 	// luma_weight_lX_flag
					w.luma_weight[l][i] = h264.read_se(reader)
					w.luma_offset[l][i] = h264.read_se(reader)
				}
				w.chroma_weight[l][i] = {1 << w.chroma_log2_denom, 1 << w.chroma_log2_denom}
				if h264.read_bit(reader) == 1 { 	// chroma_weight_lX_flag
					for c in 0 ..< 2 {
						w.chroma_weight[l][i][c] = h264.read_se(reader)
						w.chroma_offset[l][i][c] = h264.read_se(reader)
					}
				}
			}
		}
	}

	// dec_ref_pic_marking()
	if nal_ref_idc != 0 {
		if header.is_idr {
			header.no_output_of_prior_pics_flag = h264.read_bit(reader) == 1
			header.long_term_reference_flag = h264.read_bit(reader) == 1
		} else {
			header.adaptive_ref_pic_marking_flag = h264.read_bit(reader) == 1
			if header.adaptive_ref_pic_marking_flag {
				for h264.has_more_rbsp_data(reader) {
					op := h264.read_ue(reader)
					if op == 0 do break
					if op > 6 do return header, false
					cmd := h264.MMCO_Command {
						op = op,
					}
					if op == 1 || op == 3 do cmd.arg1 = h264.read_ue(reader)
					if op == 2 do cmd.arg1 = h264.read_ue(reader)
					if op == 3 || op == 6 do cmd.arg2 = h264.read_ue(reader)
					if op == 4 do cmd.arg1 = h264.read_ue(reader)
					if op == 5 do header.mmco5 = true
					if header.num_mmco < h264.MAX_REF_COMMANDS {
						header.mmco[header.num_mmco] = cmd
						header.num_mmco += 1
					}
				}
			}
		}
	}

	if picture_parameters.entropy_coding_mode_flag &&
	   header.slice_type != .I &&
	   header.slice_type != .SI {
		header.cabac_init_idc = h264.read_ue(reader)
		if header.cabac_init_idc > 2 do return header, false
	}
	header.slice_qp_delta = h264.read_se(reader)
	header.slice_qp = picture_parameters.pic_init_qp + header.slice_qp_delta
	if header.slice_qp < 0 || header.slice_qp > 51 do return header, false
	if header.slice_type == .SP || header.slice_type == .SI {
		if header.slice_type == .SP do _ = h264.read_bit(reader) // sp_for_switch_flag
		_ = h264.read_se(reader) // slice_qs_delta
	}
	if picture_parameters.deblocking_filter_control_present_flag {
		deblocking_code := h264.read_ue(reader)
		if deblocking_code > u32(h264.Deblocking_Mode.Within_Slice) do return header, false
		header.deblocking_mode = h264.Deblocking_Mode(deblocking_code)
		if header.deblocking_mode != .Disabled {
			header.slice_alpha_c0_offset_div2 = clamp(h264.read_se(reader), -6, 6)
			header.slice_beta_offset_div2 = clamp(h264.read_se(reader), -6, 6)
		}
	}
	return header, true
}

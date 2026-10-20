package h264_decoder

import h264 ".."
import "base:intrinsics"

// Crop offsets must have a complete u32 ue(v) before the RBSP stop bit. Unlike
// the hot slice reader, this header path rejects an overflowing or truncated
// code rather than interpreting it as zero.
@(private)
read_sps_crop_offset :: proc(reader: ^h264.Bit_Reader) -> (offset: u32, ok: bool) {
	zeros := int(intrinsics.count_leading_zeros(reader.cache))
	if zeros > 31 || reader.stop_bit_pos - reader.bit_pos < 2 * zeros + 1 do return
	h264.skip_bits(reader, uint(zeros + 1))
	if zeros == 0 do return 0, true
	return (u32(1) << uint(zeros)) - 1 + h264.read_bits(reader, uint(zeros)), true
}

// 7.4.2.1.1: CropUnitY also includes the field/frame coding factor. Keep the
// sum and multiplication wide so malformed offsets cannot wrap into a valid
// visible extent.
sequence_parameter_set_cropped_dimensions :: proc(
	s: ^h264.Sequence_Parameter_Set,
) -> (
	width, height: int,
	ok: bool,
) {
	if s == nil ||
	   s.macroblock_columns <= 0 ||
	   s.macroblock_columns > 1024 ||
	   s.macroblock_rows <= 0 ||
	   s.macroblock_rows > 2048 {
		return
	}
	unit_x, unit_y: u64 = 1, 1
	switch s.chroma_format {
	case .Monochrome, .YUV_444:
	case .YUV_420:
		unit_x, unit_y = 2, 2
	case .YUV_422:
		unit_x = 2
	case:
		return
	}
	if !s.frames_only do unit_y *= 2
	coded_width := u64(s.macroblock_columns) * 16
	coded_height := u64(s.macroblock_rows) * 16
	crop_width, crop_height: u64
	if s.has_cropping {
		crop_width = (u64(s.crop_left) + u64(s.crop_right)) * unit_x
		crop_height = (u64(s.crop_top) + u64(s.crop_bottom)) * unit_y
	}
	if crop_width >= coded_width || crop_height >= coded_height do return
	return int(coded_width - crop_width), int(coded_height - crop_height), true
}

// scaling_list() (7.3.2.1.1.1). Returns whether the default matrix was requested.
parse_scaling_list :: proc(reader: ^h264.Bit_Reader, list: []u8) -> (use_default: bool) {
	last_scale := 8
	next_scale := 8
	for j in 0 ..< len(list) {
		if next_scale != 0 {
			delta := int(h264.read_se(reader))
			next_scale = ((last_scale + delta + 256) % 256 + 256) % 256
			if j == 0 && next_scale == 0 do use_default = true
		}
		list[j] = u8(next_scale == 0 ? last_scale : next_scale)
		last_scale = int(list[j])
	}
	return
}

// hrd_parameters() (E.1.2), values discarded
parse_hrd :: proc(reader: ^h264.Bit_Reader) {
	cpb_cnt := h264.read_ue(reader) + 1
	_ = h264.read_bits(reader, 4) // bit_rate_scale
	_ = h264.read_bits(reader, 4) // cpb_size_scale
	for _ in 0 ..< min(cpb_cnt, 32) {
		_ = h264.read_ue(reader) // bit_rate_value_minus1
		_ = h264.read_ue(reader) // cpb_size_value_minus1
		_ = h264.read_bit(reader) // cbr_flag
	}
	_ = h264.read_bits(reader, 5) // initial_cpb_removal_delay_length_minus1
	_ = h264.read_bits(reader, 5) // cpb_removal_delay_length_minus1
	_ = h264.read_bits(reader, 5) // dpb_output_delay_length_minus1
	_ = h264.read_bits(reader, 5) // time_offset_length
}

// vui_parameters() (E.1.1); the colour description and bitstream_restriction
// are kept
parse_vui :: proc(reader: ^h264.Bit_Reader, sequence_parameters: ^h264.Sequence_Parameter_Set) {
	if h264.read_bit(reader) == 1 { 	// aspect_ratio_info_present_flag
		if h264.read_bits(reader, 8) == 255 { 	// Extended_SAR
			_ = h264.read_bits(reader, 16)
			_ = h264.read_bits(reader, 16)
		}
	}
	if h264.read_bit(reader) == 1 do _ = h264.read_bit(reader) // overscan_info_present -> overscan_appropriate
	if h264.read_bit(reader) == 1 { 	// video_signal_type_present_flag
		_ = h264.read_bits(reader, 3) // video_format
		sequence_parameters.video_full_range = h264.read_bit(reader) == 1
		if h264.read_bit(reader) == 1 { 	// colour_description_present_flag
			sequence_parameters.colour_primaries = u8(h264.read_bits(reader, 8))
			sequence_parameters.transfer_characteristics = u8(h264.read_bits(reader, 8))
			sequence_parameters.matrix_coefficients = u8(h264.read_bits(reader, 8))
		}
	}
	if h264.read_bit(reader) == 1 { 	// chroma_loc_info_present_flag
		_ = h264.read_ue(reader)
		_ = h264.read_ue(reader)
	}
	if h264.read_bit(reader) == 1 { 	// timing_info_present_flag
		_ = h264.read_bits(reader, 32)
		_ = h264.read_bits(reader, 32)
		_ = h264.read_bit(reader) // fixed_frame_rate_flag
	}
	nal_hrd := h264.read_bit(reader) == 1
	if nal_hrd do parse_hrd(reader)
	vcl_hrd := h264.read_bit(reader) == 1
	if vcl_hrd do parse_hrd(reader)
	if nal_hrd || vcl_hrd do _ = h264.read_bit(reader) // low_delay_hrd_flag
	_ = h264.read_bit(reader) // pic_struct_present_flag
	sequence_parameters.has_bitstream_restrictions = h264.read_bit(reader) == 1
	if sequence_parameters.has_bitstream_restrictions {
		_ = h264.read_bit(reader) // motion_vectors_over_pic_boundaries_flag
		_ = h264.read_ue(reader) // max_bytes_per_pic_denom
		_ = h264.read_ue(reader) // max_bits_per_mb_denom
		_ = h264.read_ue(reader) // log2_max_mv_length_horizontal
		_ = h264.read_ue(reader) // log2_max_mv_length_vertical
		sequence_parameters.max_reordered_frames = h264.read_ue(reader)
		sequence_parameters.max_buffered_frames = h264.read_ue(reader)
	}
}

parse_sequence_parameter_set :: proc(
	reader: ^h264.Bit_Reader,
) -> (
	sequence_parameters: h264.Sequence_Parameter_Set,
	ok: bool,
) {
	sequence_parameters.colour_primaries = 2
	sequence_parameters.transfer_characteristics = 2
	sequence_parameters.matrix_coefficients = 2
	sequence_parameters.profile = h264.Sequence_Profile(h264.read_bits(reader, 8))
	sequence_parameters.constraint_set_0 = h264.read_bit(reader) == 1
	sequence_parameters.constraint_set_1 = h264.read_bit(reader) == 1
	sequence_parameters.constraint_set_2 = h264.read_bit(reader) == 1
	sequence_parameters.constraint_set_3 = h264.read_bit(reader) == 1
	_ = h264.read_bits(reader, 4) // reserved_zero_4bits
	sequence_parameters.level = h264.Sequence_Level(h264.read_bits(reader, 8))
	sequence_parameters.sequence_parameter_set_id = h264.read_ue(reader)
	if sequence_parameters.sequence_parameter_set_id >= 32 do return sequence_parameters, false

	sequence_parameters.chroma_format = .YUV_420

	#partial switch sequence_parameters.profile {
	case .High,
	     .High_10,
	     .High_422,
	     .High_444_Predictive,
	     .CAVLC_444_Intra,
	     .Scalable_Baseline,
	     .Scalable_High,
	     .Multiview_High,
	     .Stereo_High,
	     .Multiview_Depth_High,
	     .Enhanced_Multiview_Depth_High,
	     .Multiresolution_Frame_Compatible_High,
	     .Multiresolution_Frame_Compatible_Depth_High:
		sequence_parameters.chroma_format = h264.Chroma_Format(h264.read_ue(reader))
		if u32(sequence_parameters.chroma_format) > 3 do return sequence_parameters, false
		if sequence_parameters.chroma_format == .YUV_444 do _ = h264.read_bit(reader) // separate_colour_plane_flag
		sequence_parameters.luma_bit_depth_minus_8 = h264.read_ue(reader)
		sequence_parameters.chroma_bit_depth_minus_8 = h264.read_ue(reader)
		sequence_parameters.bypass_transform_at_zero_quantizer = h264.read_bit(reader) == 1
		sequence_parameters.has_scaling_matrices = h264.read_bit(reader) == 1
		if sequence_parameters.has_scaling_matrices {
			limit := sequence_parameters.chroma_format != .YUV_444 ? 8 : 12
			for i in 0 ..< limit {
				present := h264.read_bit(reader) == 1
				if i < 8 do sequence_parameters.has_scaling_list[i] = present
				if !present do continue
				if i < 6 {
					sequence_parameters.use_default_scaling_list[i] = parse_scaling_list(
						reader,
						sequence_parameters.scaling_list_4x4[i][:],
					)
				} else if i < 8 {
					sequence_parameters.use_default_scaling_list[i] = parse_scaling_list(
						reader,
						sequence_parameters.scaling_list_8x8[i - 6][:],
					)
				} else {
					dummy: [64]u8
					parse_scaling_list(reader, dummy[:])
				}
			}
		}
	}

	sequence_parameters.frame_number_bits = h264.read_ue(reader) + 4
	if sequence_parameters.frame_number_bits > 16 do return sequence_parameters, false
	sequence_parameters.picture_order_mode = h264.Picture_Order_Mode(h264.read_ue(reader))
	switch sequence_parameters.picture_order_mode {
	case .Explicit_Low_Bits:
		sequence_parameters.picture_order_low_bits = h264.read_ue(reader) + 4
		if sequence_parameters.picture_order_low_bits > 16 do return sequence_parameters, false
	case .Reference_Cycle:
		sequence_parameters.picture_order_delta_always_zero = h264.read_bit(reader) == 1
		sequence_parameters.non_reference_picture_order_offset = h264.read_se(reader)
		sequence_parameters.top_to_bottom_field_order_offset = h264.read_se(reader)
		sequence_parameters.reference_cycle_length = h264.read_ue(reader)
		if sequence_parameters.reference_cycle_length > 255 do return sequence_parameters, false
		for i in 0 ..< sequence_parameters.reference_cycle_length {
			sequence_parameters.reference_frame_order_offsets[i] = h264.read_se(reader)
		}
	case .Frame_Number:
	case:
		return sequence_parameters, false
	}

	sequence_parameters.max_reference_frames = h264.read_ue(reader)
	if sequence_parameters.max_reference_frames > 16 do return sequence_parameters, false
	sequence_parameters.allow_frame_number_gaps = h264.read_bit(reader) == 1
	pic_width_in_mbs_minus1 := h264.read_ue(reader)
	pic_height_in_map_units_minus1 := h264.read_ue(reader)
	if pic_width_in_mbs_minus1 >= 1024 || pic_height_in_map_units_minus1 >= 1024 do return sequence_parameters, false
	sequence_parameters.frames_only = h264.read_bit(reader) == 1
	if !sequence_parameters.frames_only {
		sequence_parameters.adaptive_frame_field_coding = h264.read_bit(reader) == 1
	}
	sequence_parameters.infer_direct_8x8_motion = h264.read_bit(reader) == 1
	sequence_parameters.has_cropping = h264.read_bit(reader) == 1
	if sequence_parameters.has_cropping {
		crop_ok: bool
		sequence_parameters.crop_left, crop_ok = read_sps_crop_offset(reader)
		if !crop_ok do return sequence_parameters, false
		sequence_parameters.crop_right, crop_ok = read_sps_crop_offset(reader)
		if !crop_ok do return sequence_parameters, false
		sequence_parameters.crop_top, crop_ok = read_sps_crop_offset(reader)
		if !crop_ok do return sequence_parameters, false
		sequence_parameters.crop_bottom, crop_ok = read_sps_crop_offset(reader)
		if !crop_ok do return sequence_parameters, false
	}
	sequence_parameters.has_video_usability_information = h264.read_bit(reader) == 1
	if sequence_parameters.has_video_usability_information do parse_vui(reader, &sequence_parameters)

	sequence_parameters.macroblock_columns = int(pic_width_in_mbs_minus1 + 1)
	sequence_parameters.macroblock_rows = int(
		(2 - (sequence_parameters.frames_only ? u32(1) : u32(0))) *
		(pic_height_in_map_units_minus1 + 1),
	)
	sequence_parameters.macroblock_count =
		sequence_parameters.macroblock_columns * sequence_parameters.macroblock_rows

	sequence_parameters.width, sequence_parameters.height, ok =
		sequence_parameter_set_cropped_dimensions(&sequence_parameters)
	if !ok do return sequence_parameters, false
	return sequence_parameters, true
}

// Admission is separate from syntax parsing, so unsupported headers can still
// be inspected without allocating native reconstruction storage.
// The hardware frontends take 8-bit 4:2:0; `high_formats` also admits 4:2:2
// and 9 or 10 bits (High 10, High 4:2:2), with luma and chroma at one depth,
// which the native decoder reconstructs.
sequence_parameter_set_error :: proc(
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	high_formats := false,
) -> Error {
	switch {
	case sequence_parameters.chroma_format != .YUV_420 &&
	     !(high_formats && sequence_parameters.chroma_format == .YUV_422):
		return .Unsupported_Chroma_Format
	case sequence_parameters.luma_bit_depth_minus_8 > (high_formats ? 2 : 0) ||
	     sequence_parameters.chroma_bit_depth_minus_8 != sequence_parameters.luma_bit_depth_minus_8:
		return .Unsupported_Bit_Depth
	case sequence_parameters.bypass_transform_at_zero_quantizer:
		return .Unsupported_Transform_Bypass
	case !sequence_parameters.frames_only:
		return .Unsupported_Interlaced
	}
	return .None
}

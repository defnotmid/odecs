package gpu

import vk "vendor:vulkan"

// These descriptors define the independently decodable Main/Main10 pictures
// submitted by Encoder. The driver returns the actual VPS/SPS/PPS, including
// any permitted overrides, rather than a separately maintained header writer.
@(private)
create_h265_encoder_parameters :: proc(e: ^Encoder) -> Error {
	d := &e.device
	w, h := u32(e.config.width), u32(e.config.height)
	coded_w, coded_h := align_u32(w, 8), align_u32(h, 8)
	ptl := vk.VideoH265ProfileTierLevel {
		flags               = {
			.general_progressive_source_flag,
			.general_non_packed_constraint_flag,
			.general_frame_only_constraint_flag,
		},
		general_profile_idc = vk.VideoH265ProfileIdc(i32(e.config.bit_depth == 10 ? 2 : 1)),
		general_level_idc   = e.h265_caps.maxLevelIdc,
	}
	// A P-picture GOP retains the preceding reference and the current picture.
	dpb: vk.VideoH265DecPicBufMgr
	if e.config.gop_size > 1 do dpb.max_dec_pic_buffering_minus1[0] = 1
	vps := vk.VideoH265VideoParameterSet {
		flags             = {
			.vps_temporal_id_nesting_flag,
			.vps_sub_layer_ordering_info_present_flag,
		},
		pDecPicBufMgr     = &dpb,
		pProfileTierLevel = &ptl,
	}
	sps := vk.VideoH265SequenceParameterSet {
		flags                                       = {
			.sps_temporal_id_nesting_flag,
			.sps_sub_layer_ordering_info_present_flag,
			.amp_enabled_flag,
			.sample_adaptive_offset_enabled_flag,
			.strong_intra_smoothing_enabled_flag,
		},
		chroma_format_idc                           = vk.VideoH265ChromaFormatIdc(1),
		pic_width_in_luma_samples                   = coded_w,
		pic_height_in_luma_samples                  = coded_h,
		bit_depth_luma_minus8                       = u8(e.config.bit_depth - 8),
		bit_depth_chroma_minus8                     = u8(e.config.bit_depth - 8),
		log2_max_pic_order_cnt_lsb_minus4           = 12,
		log2_min_luma_coding_block_size_minus3      = 0,
		log2_diff_max_min_luma_coding_block_size    = 3,
		log2_min_luma_transform_block_size_minus2   = 0,
		log2_diff_max_min_luma_transform_block_size = 3,
		max_transform_hierarchy_depth_inter         = 3,
		max_transform_hierarchy_depth_intra         = 3,
		pProfileTierLevel                           = &ptl,
		pDecPicBufMgr                               = &dpb,
	}
	vui: vk.VideoH265SequenceParameterSetVui
	if e.config.colour_primaries != 0 {
		vui.flags = {.video_signal_type_present_flag, .colour_description_present_flag}
		if e.config.full_range do vui.flags += {.video_full_range_flag}
		vui.video_format = 5
		vui.colour_primaries = e.config.colour_primaries
		vui.transfer_characteristics = e.config.transfer
		vui.matrix_coeffs = e.config.matrix_coefficients
		sps.flags += {.vui_parameters_present_flag}
		sps.pSequenceParameterSetVui = &vui
	}
	if coded_w != w || coded_h != h {
		sps.flags += {.conformance_window_flag}
		sps.conf_win_right_offset, sps.conf_win_bottom_offset =
			(coded_w - w) / 2, (coded_h - h) / 2
	}
	pps := vk.VideoH265PictureParameterSet {
		flags = {
			.pps_loop_filter_across_slices_enabled_flag,
			.deblocking_filter_control_present_flag,
		},
	}
	add := vk.VideoEncodeH265SessionParametersAddInfoKHR {
		sType       = .VIDEO_ENCODE_H265_SESSION_PARAMETERS_ADD_INFO_KHR,
		stdVPSCount = 1,
		pStdVPSs    = cast([^]vk.VideoH265VideoParameterSet)&vps,
		stdSPSCount = 1,
		pStdSPSs    = cast([^]vk.VideoH265SequenceParameterSet)&sps,
		stdPPSCount = 1,
		pStdPPSs    = cast([^]vk.VideoH265PictureParameterSet)&pps,
	}
	codec := vk.VideoEncodeH265SessionParametersCreateInfoKHR {
		sType              = .VIDEO_ENCODE_H265_SESSION_PARAMETERS_CREATE_INFO_KHR,
		maxStdVPSCount     = 1,
		maxStdSPSCount     = 1,
		maxStdPPSCount     = 1,
		pParametersAddInfo = &add,
	}
	info := vk.VideoSessionParametersCreateInfoKHR {
		sType        = .VIDEO_SESSION_PARAMETERS_CREATE_INFO_KHR,
		pNext        = &codec,
		videoSession = e.session,
	}
	if d.a.CreateVideoSessionParametersKHR(d.handle, &info, nil, &e.parameters) != .SUCCESS do return .Driver_Error
	get265 := vk.VideoEncodeH265SessionParametersGetInfoKHR {
		sType       = .VIDEO_ENCODE_H265_SESSION_PARAMETERS_GET_INFO_KHR,
		writeStdVPS = true,
		writeStdSPS = true,
		writeStdPPS = true,
	}
	get := vk.VideoEncodeSessionParametersGetInfoKHR {
		sType                  = .VIDEO_ENCODE_SESSION_PARAMETERS_GET_INFO_KHR,
		pNext                  = &get265,
		videoSessionParameters = e.parameters,
	}
	feedback265 := vk.VideoEncodeH265SessionParametersFeedbackInfoKHR {
		sType = .VIDEO_ENCODE_H265_SESSION_PARAMETERS_FEEDBACK_INFO_KHR,
	}
	feedback := vk.VideoEncodeSessionParametersFeedbackInfoKHR {
		sType = .VIDEO_ENCODE_SESSION_PARAMETERS_FEEDBACK_INFO_KHR,
		pNext = &feedback265,
	}
	size: int
	if d.a.GetEncodedVideoSessionParametersKHR(d.handle, &get, &feedback, &size, nil) != .SUCCESS || size <= 0 || size > 65536 do return .Driver_Error
	e.headers = make([]u8, size)
	if d.a.GetEncodedVideoSessionParametersKHR(d.handle, &get, &feedback, &size, raw_data(e.headers)) != .SUCCESS do return .Driver_Error
	if size <= 0 || size > len(e.headers) do return .Driver_Error
	e.headers = e.headers[:size]
	return .None
}

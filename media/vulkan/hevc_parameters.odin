package media_vulkan

import shared "../../video/h265"
import hevc "../../video/h265/decoder"
import vk "vendor:vulkan"

// Stable backing storage for the pointers consumed by Vulkan session creation.
// Fill this in its final location; do not copy it after map_h265_parameters.
H265_Parameter_Storage :: struct {
	vps:                      vk.VideoH265VideoParameterSet,
	sps:                      vk.VideoH265SequenceParameterSet,
	pps:                      vk.VideoH265PictureParameterSet,
	vps_ptl, sps_ptl:         vk.VideoH265ProfileTierLevel,
	vps_dpb, sps_dpb:         vk.VideoH265DecPicBufMgr,
	sps_scaling, pps_scaling: vk.VideoH265ScalingLists,
	rps:                      [hevc.MAX_SHORT_TERM_RPS]vk.VideoH265ShortTermRefPicSet,
	long_term:                vk.VideoH265LongTermRefPicsSps,
}

@(private)
h265_profile_tier_level :: proc(
	p: ^hevc.Profile_Tier_Level,
) -> (
	out: vk.VideoH265ProfileTierLevel,
	ok: bool,
) {
	out.general_profile_idc = vk.VideoH265ProfileIdc(p.profile_idc)
	levels := [13]u8{30, 60, 63, 90, 93, 120, 123, 150, 153, 156, 180, 183, 186}
	for level, i in levels {
		if level == p.level_idc {out.general_level_idc = vk.VideoH265LevelIdc(i); ok = true; break}
	}
	if p.tier_flag do out.flags += {.general_tier_flag}
	if p.progressive_source do out.flags += {.general_progressive_source_flag}
	if p.interlaced_source do out.flags += {.general_interlaced_source_flag}
	if p.non_packed_constraint do out.flags += {.general_non_packed_constraint_flag}
	if p.frame_only_constraint do out.flags += {.general_frame_only_constraint_flag}
	return
}

@(private)
h265_scaling_lists :: proc(out: ^vk.VideoH265ScalingLists, source: ^hevc.Scaling_List) {
	for mat in 0 ..< 6 {
		for position, i in shared.SCALING_SCAN_4X4 do out.ScalingList4x4[mat][i] = source.sl[0][mat][position]
		for position, i in shared.SCALING_SCAN_8X8 {
			out.ScalingList8x8[mat][i] = source.sl[1][mat][position]
			out.ScalingList16x16[mat][i] = source.sl[2][mat][position]
		}
		out.ScalingListDCCoef16x16[mat] = source.dc[0][mat]
	}
	for mat in 0 ..< 2 {
		for position, i in shared.SCALING_SCAN_8X8 do out.ScalingList32x32[mat][i] = source.sl[3][mat * 3][position]
		out.ScalingListDCCoef32x32[mat] = source.dc[1][mat * 3]
	}
}

@(private)
h265_short_term_rps :: proc(
	out: ^vk.VideoH265ShortTermRefPicSet,
	source: ^hevc.Short_Term_RPS,
) -> Error {
	if len(source.delta_poc_s0) + len(source.delta_poc_s1) > vk.VIDEO_H265_MAX_DPB_SIZE ||
	   len(source.used_s0) != len(source.delta_poc_s0) ||
	   len(source.used_s1) != len(source.delta_poc_s1) {return .Unsupported}
	out^ = {
		num_negative_pics = u8(len(source.delta_poc_s0)),
		num_positive_pics = u8(len(source.delta_poc_s1)),
	}
	// Session parameters describe the resolved RPS. Express it with direct
	// deltas so its meaning comes from the native parser's one derivation.
	previous: i32
	for poc, i in source.delta_poc_s0 {
		delta := i64(previous) - i64(poc) - 1
		if delta < 0 || delta > i64(max(u16)) {return .Unsupported}
		out.delta_poc_s0_minus1[i] = u16(delta)
		if source.used_s0[i] do out.used_by_curr_pic_s0_flag |= u16(1) << uint(i)
		previous = poc
	}
	previous = 0
	for poc, i in source.delta_poc_s1 {
		delta := i64(poc) - i64(previous) - 1
		if delta < 0 || delta > i64(max(u16)) {return .Unsupported}
		out.delta_poc_s1_minus1[i] = u16(delta)
		if source.used_s1[i] do out.used_by_curr_pic_s1_flag |= u16(1) << uint(i)
		previous = poc
	}
	return .None
}

map_h265_parameters :: proc(
	out: ^H265_Parameter_Storage,
	v: ^hevc.VPS,
	s: ^hevc.SPS,
	p: ^hevc.PPS,
) -> Error {
	if out == nil || v == nil || s == nil || p == nil do return .Invalid_Argument
	if v.id != s.vps_id ||
	   s.id != p.sps_id ||
	   v.max_layers_minus1 != 0 ||
	   (s.ptl.profile_idc != 1 && s.ptl.profile_idc != 2) ||
	   s.ptl.interlaced_source ||
	   s.chroma_format_idc != 1 ||
	   s.separate_colour_plane ||
	   (s.bit_depth_luma != 8 && s.bit_depth_luma != 10) ||
	   s.bit_depth_chroma != s.bit_depth_luma ||
	   s.transform_skip_rotation ||
	   s.transform_skip_context ||
	   s.implicit_rdpcm ||
	   s.explicit_rdpcm ||
	   s.extended_precision ||
	   s.intra_smoothing_disabled ||
	   s.high_precision_offsets ||
	   s.persistent_rice_adaptation ||
	   s.cabac_bypass_alignment ||
	   len(s.st_rps) > len(out.rps) ||
	   len(s.lt_ref_pic_poc_lsb) > vk.VIDEO_H265_MAX_LONG_TERM_REF_PICS_SPS ||
	   s.max_sub_layers_minus1 >= vk.VIDEO_H265_SUBLAYERS_LIST_SIZE ||
	   v.max_sub_layers_minus1 >= vk.VIDEO_H265_SUBLAYERS_LIST_SIZE {return .Unsupported}
	out^ = {}
	ok: bool
	out.vps_ptl, ok = h265_profile_tier_level(&v.ptl)
	if !ok {return .Unsupported}
	out.sps_ptl, ok = h265_profile_tier_level(&s.ptl)
	if !ok {return .Unsupported}
	for i in 0 ..= int(v.max_sub_layers_minus1) {
		if v.max_dec_pic_buffering[i] >= vk.VIDEO_H265_MAX_DPB_SIZE ||
		   v.max_num_reorder_pics[i] > u32(max(u8)) {return .Unsupported}
		out.vps_dpb.max_dec_pic_buffering_minus1[i] = u8(v.max_dec_pic_buffering[i])
		out.vps_dpb.max_num_reorder_pics[i] = u8(v.max_num_reorder_pics[i])
		out.vps_dpb.max_latency_increase_plus1[i] = v.max_latency_increase[i]
	}
	for i in 0 ..= int(s.max_sub_layers_minus1) {
		if s.max_dec_pic_buffering_by_layer[i] >= vk.VIDEO_H265_MAX_DPB_SIZE ||
		   s.max_num_reorder_pics_by_layer[i] > u32(max(u8)) {return .Unsupported}
		out.sps_dpb.max_dec_pic_buffering_minus1[i] = u8(s.max_dec_pic_buffering_by_layer[i])
		out.sps_dpb.max_num_reorder_pics[i] = u8(s.max_num_reorder_pics_by_layer[i])
		out.sps_dpb.max_latency_increase_plus1[i] = s.max_latency_increase_by_layer[i]
	}
	out.vps = {
		vps_video_parameter_set_id = v.id,
		vps_max_sub_layers_minus1  = v.max_sub_layers_minus1,
		pDecPicBufMgr              = &out.vps_dpb,
		pProfileTierLevel          = &out.vps_ptl,
		flags                      = {.vps_sub_layer_ordering_info_present_flag},
	}
	if v.temporal_id_nesting do out.vps.flags += {.vps_temporal_id_nesting_flag}
	out.sps = {
		chroma_format_idc                           = vk.VideoH265ChromaFormatIdc(
			s.chroma_format_idc,
		),
		pic_width_in_luma_samples                   = s.pic_width_in_luma_samples,
		pic_height_in_luma_samples                  = s.pic_height_in_luma_samples,
		sps_video_parameter_set_id                  = s.vps_id,
		sps_max_sub_layers_minus1                   = s.max_sub_layers_minus1,
		sps_seq_parameter_set_id                    = u8(s.id),
		bit_depth_luma_minus8                       = s.bit_depth_luma - 8,
		bit_depth_chroma_minus8                     = s.bit_depth_chroma - 8,
		log2_max_pic_order_cnt_lsb_minus4           = s.log2_max_poc_lsb - 4,
		log2_min_luma_coding_block_size_minus3      = s.min_cb_log2_size_y - 3,
		log2_diff_max_min_luma_coding_block_size    = s.ctb_log2_size_y - s.min_cb_log2_size_y,
		log2_min_luma_transform_block_size_minus2   = s.min_tb_log2_size_y - 2,
		log2_diff_max_min_luma_transform_block_size = s.max_tb_log2_size_y - s.min_tb_log2_size_y,
		max_transform_hierarchy_depth_inter         = u8(s.max_tr_hier_inter),
		max_transform_hierarchy_depth_intra         = u8(s.max_tr_hier_intra),
		num_short_term_ref_pic_sets                 = u8(len(s.st_rps)),
		num_long_term_ref_pics_sps                  = u8(len(s.lt_ref_pic_poc_lsb)),
		conf_win_left_offset                        = s.conf_win_left,
		conf_win_right_offset                       = s.conf_win_right,
		conf_win_top_offset                         = s.conf_win_top,
		conf_win_bottom_offset                      = s.conf_win_bottom,
		pProfileTierLevel                           = &out.sps_ptl,
		pDecPicBufMgr                               = &out.sps_dpb,
		flags                                       = {.sps_sub_layer_ordering_info_present_flag},
	}
	if s.temporal_id_nesting do out.sps.flags += {.sps_temporal_id_nesting_flag}
	if s.conf_win_left | s.conf_win_right | s.conf_win_top | s.conf_win_bottom != 0 do out.sps.flags += {.conformance_window_flag}
	if s.scaling_list_enabled {
		out.sps.flags += {.scaling_list_enabled_flag, .sps_scaling_list_data_present_flag}
		h265_scaling_lists(&out.sps_scaling, &s.scaling_list)
		out.sps.pScalingLists = &out.sps_scaling
	}
	if s.amp_enabled do out.sps.flags += {.amp_enabled_flag}
	if s.sao_enabled do out.sps.flags += {.sample_adaptive_offset_enabled_flag}
	if s.temporal_mvp_enabled do out.sps.flags += {.sps_temporal_mvp_enabled_flag}
	if s.strong_intra_smoothing do out.sps.flags += {.strong_intra_smoothing_enabled_flag}
	if s.pcm_enabled {
		out.sps.flags += {.pcm_enabled_flag}
		if s.pcm_loop_filter_disabled do out.sps.flags += {.pcm_loop_filter_disabled_flag}
		out.sps.pcm_sample_bit_depth_luma_minus1 = s.pcm_bit_depth_luma - 1
		out.sps.pcm_sample_bit_depth_chroma_minus1 = s.pcm_bit_depth_chroma - 1
		out.sps.log2_min_pcm_luma_coding_block_size_minus3 = s.log2_min_pcm_cb_size - 3
		out.sps.log2_diff_max_min_pcm_luma_coding_block_size =
			s.log2_max_pcm_cb_size - s.log2_min_pcm_cb_size
	}
	for &rps, i in s.st_rps {
		if err := h265_short_term_rps(&out.rps[i], &rps); err != .None do return err
	}
	if len(s.st_rps) != 0 do out.sps.pShortTermRefPicSet = &out.rps[0]
	if s.long_term_ref_pics_present {
		out.sps.flags += {.long_term_ref_pics_present_flag}
		for poc, i in s.lt_ref_pic_poc_lsb {
			out.long_term.lt_ref_pic_poc_lsb_sps[i] = poc
			if s.used_by_curr_pic_lt[i] do out.long_term.used_by_curr_pic_lt_sps_flag |= u32(1) << uint(i)
		}
		out.sps.pLongTermRefPicsSps = &out.long_term
	}
	if p.id > 63 ||
	   p.num_ref_idx_l0_default_active == 0 ||
	   p.num_ref_idx_l1_default_active == 0 ||
	   p.log2_max_transform_skip_size != 2 ||
	   p.cross_component_prediction ||
	   p.chroma_qp_offset_list_present ||
	   p.log2_sao_offset_scale_luma > u32(max(u8)) ||
	   p.log2_sao_offset_scale_chroma > u32(max(u8)) ||
	   p.num_tile_columns < 1 ||
	   p.num_tile_rows < 1 ||
	   p.num_tile_columns > len(out.pps.column_width_minus1) + 1 ||
	   p.num_tile_rows > len(out.pps.row_height_minus1) + 1 {return .Unsupported}
	out.pps = {
		pps_pic_parameter_set_id                  = u8(p.id),
		pps_seq_parameter_set_id                  = u8(p.sps_id),
		sps_video_parameter_set_id                = s.vps_id,
		num_extra_slice_header_bits               = p.num_extra_slice_header_bits,
		num_ref_idx_l0_default_active_minus1      = u8(p.num_ref_idx_l0_default_active - 1),
		num_ref_idx_l1_default_active_minus1      = u8(p.num_ref_idx_l1_default_active - 1),
		init_qp_minus26                           = i8(p.init_qp - 26),
		diff_cu_qp_delta_depth                    = u8(p.diff_cu_qp_delta_depth),
		pps_cb_qp_offset                          = i8(p.cb_qp_offset),
		pps_cr_qp_offset                          = i8(p.cr_qp_offset),
		pps_beta_offset_div2                      = i8(p.beta_offset_div2),
		pps_tc_offset_div2                        = i8(p.tc_offset_div2),
		log2_parallel_merge_level_minus2          = u8(p.log2_parallel_merge_level - 2),
		log2_max_transform_skip_block_size_minus2 = u8(p.log2_max_transform_skip_size - 2),
		log2_sao_offset_scale_luma                = u8(p.log2_sao_offset_scale_luma),
		log2_sao_offset_scale_chroma              = u8(p.log2_sao_offset_scale_chroma),
		num_tile_columns_minus1                   = u8(p.num_tile_columns - 1),
		num_tile_rows_minus1                      = u8(p.num_tile_rows - 1),
	}
	for width, i in p.column_width_minus1 {if width > u32(max(u16)) {return .Unsupported}; out.pps.column_width_minus1[i] = u16(width)}
	for height, i in p.row_height_minus1 {if height > u32(max(u16)) {return .Unsupported}; out.pps.row_height_minus1[i] = u16(height)}
	if p.dependent_slice_segments_enabled do out.pps.flags += {.dependent_slice_segments_enabled_flag}
	if p.output_flag_present do out.pps.flags += {.output_flag_present_flag}
	if p.sign_data_hiding_enabled do out.pps.flags += {.sign_data_hiding_enabled_flag}
	if p.cabac_init_present do out.pps.flags += {.cabac_init_present_flag}
	if p.constrained_intra_pred do out.pps.flags += {.constrained_intra_pred_flag}
	if p.transform_skip_enabled do out.pps.flags += {.transform_skip_enabled_flag}
	if p.cu_qp_delta_enabled do out.pps.flags += {.cu_qp_delta_enabled_flag}
	if p.slice_chroma_qp_offsets do out.pps.flags += {.pps_slice_chroma_qp_offsets_present_flag}
	if p.weighted_pred do out.pps.flags += {.weighted_pred_flag}
	if p.weighted_bipred do out.pps.flags += {.weighted_bipred_flag}
	if p.transquant_bypass do out.pps.flags += {.transquant_bypass_enabled_flag}
	if p.tiles_enabled do out.pps.flags += {.tiles_enabled_flag}
	if p.entropy_coding_sync do out.pps.flags += {.entropy_coding_sync_enabled_flag}
	if p.uniform_spacing do out.pps.flags += {.uniform_spacing_flag}
	if p.loop_filter_across_tiles do out.pps.flags += {.loop_filter_across_tiles_enabled_flag}
	if p.loop_filter_across_slices do out.pps.flags += {.pps_loop_filter_across_slices_enabled_flag}
	if p.deblocking_control_present do out.pps.flags += {.deblocking_filter_control_present_flag}
	if p.deblocking_override do out.pps.flags += {.deblocking_filter_override_enabled_flag}
	if p.deblocking_disabled do out.pps.flags += {.pps_deblocking_filter_disabled_flag}
	if p.lists_modification_present do out.pps.flags += {.lists_modification_present_flag}
	if p.slice_header_extension_present do out.pps.flags += {.slice_segment_header_extension_present_flag}
	if p.log2_sao_offset_scale_luma != 0 || p.log2_sao_offset_scale_chroma != 0 do out.pps.flags += {.pps_extension_present_flag, .pps_range_extension_flag}
	if p.scaling_list_present {
		out.pps.flags += {.pps_scaling_list_data_present_flag}
		h265_scaling_lists(&out.pps_scaling, &p.scaling_list)
		out.pps.pScalingLists = &out.pps_scaling
	}
	return .None
}

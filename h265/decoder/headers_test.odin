package h265_decoder

import hevc ".."
import common "../../common"
import enc "../encoder"
import "core:testing"

// ---------------------------------------------------------------------------
// Integration: parse the parameter sets our own byte-exact encoder emits.
// ---------------------------------------------------------------------------

find_nal :: proc(nals: []Nal_Unit, type: Nal_Type) -> ^Nal_Unit {
	for i in 0 ..< len(nals) {
		if nals[i].type == type do return &nals[i]
	}
	return nil
}

find_vcl_nal :: proc(nals: []Nal_Unit) -> ^Nal_Unit {
	for i in 0 ..< len(nals) {
		if nal_type_is_vcl(nals[i].type) do return &nals[i]
	}
	return nil
}

encode_test_frames :: proc(e: ^enc.Encoder, frames: int, w, h: int) -> [dynamic]u8 {
	out := make([dynamic]u8, 0, 1 << 16)
	luma := make([]enc.Sample, w * h)
	chroma := make([]enc.Sample, w * h / 4)
	defer delete(luma)
	defer delete(chroma)
	for i in 0 ..< len(luma) do luma[i] = 128
	for i in 0 ..< len(chroma) do chroma[i] = 128
	for _ in 0 ..< frames {
		enc.encode_frame(e, raw_data(luma), raw_data(chroma), raw_data(chroma), w, w / 2, &out)
	}
	return out
}

@(test)
test_parse_encoder_parameter_sets :: proc(t: ^testing.T) {
	cfg := enc.Config {
		width       = 16,
		height      = 16,
		qp          = 26,
		level_idc   = 120,
		forced_mode = -1,
		deblock     = true,
		sao         = true,
	}

	e: enc.Encoder
	enc.init_encoder(&e, cfg)
	defer enc.destroy_encoder(&e)

	out := encode_test_frames(&e, 1, 16, 16)
	defer delete(out)

	nals := split_annex_b(out[:])
	defer {
		for i in 0 ..< len(nals) do destroy_nal(&nals[i])
		delete(nals)
	}

	vps_nal := find_nal(nals[:], .VPS_NUT)
	sps_nal := find_nal(nals[:], .SPS_NUT)
	pps_nal := find_nal(nals[:], .PPS_NUT)
	testing.expect(t, vps_nal != nil && sps_nal != nil && pps_nal != nil)
	if vps_nal == nil || sps_nal == nil || pps_nal == nil do return

	vps, vok := parse_vps(vps_nal.rbsp)
	testing.expect(t, vok)
	testing.expect_value(t, vps.id, u8(0))
	testing.expect_value(t, vps.max_sub_layers_minus1, u8(1))
	testing.expect_value(t, vps.ptl.profile_idc, u8(1))
	testing.expect_value(t, vps.ptl.tier_flag, false)
	testing.expect_value(t, vps.ptl.level_idc, u8(120))
	testing.expect_value(t, vps.ptl.compat_flags, u32(0x60000000))

	sps, sok := parse_sps(sps_nal.rbsp)
	defer {
		if sok do destroy_sps(&sps)
	}
	testing.expect(t, sok)
	testing.expect_value(t, sps.id, u32(0))
	testing.expect_value(t, sps.chroma_format_idc, u32(1))
	testing.expect_value(t, sps.sub_width_c, 2)
	testing.expect_value(t, sps.sub_height_c, 2)
	testing.expect_value(t, sps.pic_width_in_luma_samples, u32(16))
	testing.expect_value(t, sps.pic_height_in_luma_samples, u32(16))
	testing.expect_value(t, sps.bit_depth_luma, u8(8))
	testing.expect_value(t, sps.bit_depth_chroma, u8(8))
	testing.expect_value(t, sps.log2_max_poc_lsb, u8(8))
	testing.expect_value(t, sps.min_cb_log2_size_y, u8(3))
	testing.expect_value(t, sps.ctb_log2_size_y, u8(6))
	testing.expect_value(t, sps.ctb_size_y, u32(64))
	testing.expect_value(t, sps.pic_width_in_ctbs, u32(1))
	testing.expect_value(t, sps.pic_height_in_ctbs, u32(1))
	testing.expect_value(t, sps.min_tb_log2_size_y, u8(2))
	testing.expect_value(t, sps.max_tb_log2_size_y, u8(5))
	testing.expect_value(t, sps.scaling_list_enabled, false)
	testing.expect_value(t, sps.amp_enabled, false)
	testing.expect_value(t, sps.sao_enabled, true)
	testing.expect_value(t, sps.pcm_enabled, false)
	testing.expect_value(t, len(sps.st_rps), 0)
	testing.expect_value(t, sps.long_term_ref_pics_present, false)
	testing.expect_value(t, sps.temporal_mvp_enabled, false)

	pps, pok := parse_pps(pps_nal.rbsp)
	defer {
		if pok do destroy_pps(&pps)
	}
	testing.expect(t, pok)
	testing.expect_value(t, pps.id, u32(0))
	testing.expect_value(t, pps.sps_id, u32(0))
	testing.expect_value(t, pps.num_ref_idx_l0_default_active, u32(1))
	testing.expect_value(t, pps.num_ref_idx_l1_default_active, u32(1))
	testing.expect_value(t, pps.init_qp, i32(26))
	testing.expect_value(t, pps.deblocking_control_present, true)
	testing.expect_value(t, pps.deblocking_override, false)
	testing.expect_value(t, pps.deblocking_disabled, false)
	testing.expect_value(t, pps.tiles_enabled, false)
	testing.expect_value(t, pps.entropy_coding_sync, false)
	testing.expect_value(t, pps.loop_filter_across_slices, false)
	testing.expect_value(t, pps.scaling_list_present, false)
	testing.expect_value(t, pps.log2_parallel_merge_level, u32(2))

	slice_nal := find_vcl_nal(nals[:])
	testing.expect(t, slice_nal != nil)
	if slice_nal == nil do return

	header, hok := parse_slice_header(slice_nal.rbsp, slice_nal.type, &sps, &pps)
	defer {
		if hok do destroy_slice_header(&header)
	}
	testing.expect(t, hok)
	testing.expect_value(t, header.slice_type, Slice_Type.I)
	testing.expect_value(t, header.first_slice_segment_in_pic, true)
	testing.expect_value(t, header.pps_id, u32(0))
	testing.expect_value(t, header.no_output_of_prior_pics, false)
	testing.expect_value(t, header.sao_luma, true)
	testing.expect_value(t, header.sao_chroma, true)
	testing.expect_value(t, header.qp_y, i32(26))
}

// ---------------------------------------------------------------------------
// short_term_ref_pic_set (7.3.7): an explicit set and an inter-predicted set.
// ---------------------------------------------------------------------------

@(test)
test_short_term_rps_explicit :: proc(t: ^testing.T) {
	rbsp: [dynamic]u8
	defer delete(rbsp)

	w := common.init_bit_writer(&rbsp)
	common.write_ue(&w, 2) // num_negative_pics
	common.write_ue(&w, 1) // num_positive_pics

	common.write_ue(&w, 0) // delta_poc_s0_minus1: -1
	common.write_bits(&w, 1, 1)
	common.write_ue(&w, 1) // delta_poc_s0_minus1: -3
	common.write_bits(&w, 1, 1)

	common.write_ue(&w, 2) // delta_poc_s1_minus1: +3
	common.write_bits(&w, 1, 1)
	common.write_rbsp_trailing_bits(&w)

	c: Get_Bits
	get_bits_init(&c, rbsp[:])

	rps, ok := parse_short_term_rps(&c, 0, 0, nil)
	defer {
		if ok do destroy_short_term_rps(&rps)
	}
	testing.expect(t, ok)
	testing.expect_value(t, len(rps.delta_poc_s0), 2)
	testing.expect_value(t, len(rps.delta_poc_s1), 1)
	testing.expect_value(t, rps.delta_poc_s0[0], i32(-1))
	testing.expect_value(t, rps.delta_poc_s0[1], i32(-3))
	testing.expect_value(t, rps.delta_poc_s1[0], i32(3))
	testing.expect_value(t, rps.used_s0[0], true)
	testing.expect_value(t, rps.used_s0[1], true)
	testing.expect_value(t, rps.used_s1[0], true)
}

@(test)
test_short_term_rps_inter_prediction :: proc(t: ^testing.T) {
	base: Short_Term_RPS
	base.delta_poc_s0 = make([]i32, 2)
	base.delta_poc_s1 = make([]i32, 1)
	base.used_s0 = make([]bool, 2)
	base.used_s1 = make([]bool, 1)
	base.delta_poc_s0[0], base.delta_poc_s0[1] = -1, -3
	base.delta_poc_s1[0] = 3
	base.used_s0[0], base.used_s0[1] = true, true
	base.used_s1[0] = true
	defer destroy_short_term_rps(&base)

	prev := []Short_Term_RPS{base}

	rbsp: [dynamic]u8
	defer delete(rbsp)

	w := common.init_bit_writer(&rbsp)
	common.write_bits(&w, 1, 1) // inter_ref_pic_set_prediction_flag
	common.write_ue(&w, 0) // delta_idx_minus1: reference set 1
	common.write_bits(&w, 1, 1) // delta_rps_sign: negative
	common.write_ue(&w, 0) // abs_delta_rps_minus1: -1
	// NumDeltaPocs[ref] + 1 == 4 used flags, all set.
	for _ in 0 ..< 4 do common.write_bits(&w, 1, 1)
	common.write_rbsp_trailing_bits(&w)

	c: Get_Bits
	get_bits_init(&c, rbsp[:])

	rps, ok := parse_short_term_rps(&c, 1, 1, prev)
	defer {
		if ok do destroy_short_term_rps(&rps)
	}
	testing.expect(t, ok)
	testing.expect_value(t, len(rps.delta_poc_s0), 3)
	testing.expect_value(t, len(rps.delta_poc_s1), 1)
	testing.expect_value(t, rps.delta_poc_s0[0], i32(-1))
	testing.expect_value(t, rps.delta_poc_s0[1], i32(-2))
	testing.expect_value(t, rps.delta_poc_s0[2], i32(-4))
	testing.expect_value(t, rps.delta_poc_s1[0], i32(2))
}

// ---------------------------------------------------------------------------
// scaling_list_data (7.3.4): a custom 4x4 list and a predicted copy.
// ---------------------------------------------------------------------------

@(test)
test_parse_scaling_list_data :: proc(t: ^testing.T) {
	rbsp: [dynamic]u8
	defer delete(rbsp)

	w := common.init_bit_writer(&rbsp)

	// sizeID 0, matrixID 0: a custom list whose coefficients are all 0.
	common.write_bits(&w, 1, 1) // scaling_list_pred_mode_flag
	for _ in 0 ..< 16 do common.write_se(&w, 0)

	// sizeID 0, matrixID 1: predicted from matrix 0 (delta 1).
	common.write_bits(&w, 0, 1)
	common.write_ue(&w, 1) // scaling_list_pred_matrix_id_delta

	// Remaining sizeID 0 matrices: keep the default.
	for _ in 0 ..< 4 {
		common.write_bits(&w, 0, 1)
		common.write_ue(&w, 0)
	}

	// sizeID 1, 2: keep every default matrix.
	for _ in 0 ..< 12 {
		common.write_bits(&w, 0, 1)
		common.write_ue(&w, 0)
	}

	// sizeID 3 (step 3): matrices 0 and 3 keep the default.
	for _ in 0 ..< 2 {
		common.write_bits(&w, 0, 1)
		common.write_ue(&w, 0)
	}

	common.write_rbsp_trailing_bits(&w)

	c: Get_Bits
	get_bits_init(&c, rbsp[:])

	sl := default_scaling_list()
	ok := parse_scaling_list_data(&c, &sl)
	testing.expect(t, ok)

	for i in 0 ..< 16 do testing.expect_value(t, sl.sl[0][0][i], u8(8))
	for i in 0 ..< 16 do testing.expect_value(t, sl.sl[0][1][i], u8(8))
	for i in 0 ..< 16 do testing.expect_value(t, sl.sl[0][2][i], u8(16))
	for i in 0 ..< 64 do testing.expect_value(t, sl.sl[1][0][i], hevc.DEFAULT_SCALING_LIST_INTRA[i])
	for i in 0 ..< 64 do testing.expect_value(t, sl.sl[1][3][i], hevc.DEFAULT_SCALING_LIST_INTER[i])
}

// ---------------------------------------------------------------------------
// HRD common-info inheritance (7.4.3.1): a second HRD entry with
// cprms_present_flag = 0 must still read its sub-layer HRD bodies using the
// previous entry's nal/vcl/sub_pic flags. The check is the exact bit position
// after both entries, which a dropped sub-layer body would fall short of.
// ---------------------------------------------------------------------------

write_hrd_common_info :: proc(w: ^common.Bit_Writer, nal_hrd, vcl_hrd: bool) {
	common.write_bits(w, nal_hrd ? 1 : 0, 1)
	common.write_bits(w, vcl_hrd ? 1 : 0, 1)

	if nal_hrd || vcl_hrd {
		common.write_bits(w, 0, 1) // sub_pic_hrd_params_present_flag
		common.write_bits(w, 0, 4) // bit_rate_scale
		common.write_bits(w, 0, 4) // cpb_size_scale
		common.write_bits(w, 0, 5) // initial_cpb_removal_delay_length_minus1
		common.write_bits(w, 0, 5) // au_cpb_removal_delay_length_minus1
		common.write_bits(w, 0, 5) // dpb_output_delay_length_minus1
	}
}

write_hrd_sublayer_body :: proc(w: ^common.Bit_Writer, nal_hrd, vcl_hrd: bool) {
	common.write_bits(w, 1, 1) // fixed_pic_rate_general_flag
	common.write_ue(w, 0) // elemental_duration_in_tc_minus1
	common.write_ue(w, 0) // cpb_cnt_minus1 -> one CPB
	if nal_hrd {
		common.write_ue(w, 0) // bit_rate_value_minus1
		common.write_ue(w, 0) // cpb_size_value_minus1
		common.write_bits(w, 0, 1) // cbr_flag
	}
	if vcl_hrd {
		common.write_ue(w, 0)
		common.write_ue(w, 0)
		common.write_bits(w, 0, 1)
	}
}

@(test)
test_hrd_common_info_inheritance :: proc(t: ^testing.T) {
	rbsp: [dynamic]u8
	defer delete(rbsp)

	w := common.init_bit_writer(&rbsp)
	write_hrd_common_info(&w, true, false)
	write_hrd_sublayer_body(&w, true, false)
	write_hrd_sublayer_body(&w, true, false)
	syntax_bits := common.bits_written(&w)
	common.write_align_zero(&w)

	c: Get_Bits
	get_bits_init(&c, rbsp[:])

	info0, ok0 := parse_hrd(&c, true, {}, 0)
	testing.expect(t, ok0)
	testing.expect_value(t, info0.nal_hrd, true)

	info1, ok1 := parse_hrd(&c, false, info0, 0)
	testing.expect(t, ok1)
	testing.expect_value(t, info1.nal_hrd, true)
	testing.expect_value(t, get_bits_pos(&c), syntax_bits)
}

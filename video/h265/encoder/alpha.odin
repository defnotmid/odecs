package h265_encoder

import common "../../../common"

// ---------------------------------------------------------------------------
// Alpha as an auxiliary picture layer (Annex F, AuxId 1 = AUX_ALPHA).
//
// Two encoders run side by side: Base_With_Alpha codes the colour as layer 0
// and Alpha codes the alpha plane, as the luma of an ordinary picture with
// flat chroma, as layer 1. The layers are independent (no inter-layer
// prediction), so each is a single-layer stream apart from its NAL headers
// and parameter set ids, and the alpha layer decodes with any HEVC decoder
// that filters on nuh_layer_id. The parameter sets and the SEI follow
// Apple's VideoToolbox encoder, the format Safari and AVFoundation play.
// ---------------------------------------------------------------------------

ALPHA_LAYER_ID :: 1

// NAL unit header (7.3.1.2) for the encoder's layer, TemporalId 0.
@(private)
nal_header :: #force_inline proc(enc: ^Encoder, type: Nal_Type) -> [2]u8 {
	layer: u8 = enc.config.layer == .Alpha ? ALPHA_LAYER_ID : 0
	return {u8(type) << 1 | layer >> 5, (layer & 31) << 3 | 1}
}

// SPS and PPS ids: parameter sets of all layers share one id space (F.7.4.3),
// so the alpha layer takes id 1.
@(private)
layer_parameter_set_id :: #force_inline proc(enc: ^Encoder) -> u32 {
	return enc.config.layer == .Alpha ? 1 : 0
}

// vps_extension() (F.7.3.2.1.1) after the alignment bits, for the base layer
// and one independent alpha layer with nuh_layer_id 1:
// - the alpha layer is an additional layer set {1} (num_add_layer_sets 1)
//   and an output layer set of its own, with the level-only profile/tier/level
//   entry 1;
// - one representation format, the base layer's, and the base layer's DPB size;
// - poc_lsb_not_present_flag: IDR slices of the alpha layer omit
//   slice_pic_order_cnt_lsb exactly as the base layer's do.
@(private)
write_vps_alpha_extension :: proc(enc: ^Encoder, w: ^common.Bit_Writer) {
	for w.nbits & 7 != 0 do common.write_bits(w, 1, 1) // vps_extension_alignment_bit_equal_to_one
	// profile_tier_level(0, vps_max_sub_layers_minus1 = 1): the level, then
	// one pair of sub-layer present flags and 7 reserved_zero_2bits.
	common.write_bits(w, u32(enc.config.level_idc), 8)
	common.write_bits(w, 0, 2)
	common.write_bits(w, 0, 14)
	common.write_bits(w, 0, 1) // splitting_flag
	common.write_bits(w, 1 << (15 - 3), 16) // scalability_mask_flag[0..15]: only AuxId (Table F.1)
	common.write_bits(w, 0, 3) // dimension_id_len_minus1[0]: one bit
	common.write_bits(w, 1, 1) // vps_nuh_layer_id_present_flag
	common.write_bits(w, ALPHA_LAYER_ID, 6) // layer_id_in_nuh[1]
	common.write_bits(w, 1, 1) // dimension_id[1][0]: AuxId 1, alpha
	common.write_bits(w, 0, 4) // view_id_len
	common.write_bits(w, 0, 1) // direct_dependency_flag[1][0]
	common.write_ue(w, 1) // num_add_layer_sets (NumIndependentLayers is 2)
	common.write_bits(w, 1, 1) // highest_layer_idx_plus1[0][1]
	common.write_bits(w, 0, 1) // vps_sub_layers_max_minus1_present_flag
	common.write_bits(w, 0, 1) // max_tid_ref_present_flag
	common.write_bits(w, 0, 1) // default_ref_layers_active_flag
	common.write_ue(w, 1) // vps_num_profile_tier_level_minus1
	common.write_ue(w, 0) // num_add_olss
	common.write_bits(w, 0, 2) // default_output_layer_idc
	common.write_bits(w, 1, 1) // output_layer_flag[1][0]
	common.write_bits(w, 1, 1) // profile_tier_level_idx[1][0]
	common.write_ue(w, 0) // vps_num_rep_formats_minus1
	// rep_format(): the SPS's coded size, format and conformance window.
	common.write_bits(w, u32(enc.coded_width), 16)
	common.write_bits(w, u32(enc.coded_height), 16)
	common.write_bits(w, 1, 1) // chroma_and_bit_depth_vps_present_flag
	common.write_bits(w, layout_idc(enc.config.chroma_format), 2)
	if enc.config.chroma_format == .YUV_444 do common.write_bits(w, 0, 1) // separate_colour_plane_vps_flag
	common.write_bits(w, u32(enc.bit_depth - 8), 4)
	common.write_bits(w, u32(enc.bit_depth - 8), 4)
	if enc.coded_width != enc.width || enc.coded_height != enc.height {
		sub_w := enc.config.chroma_format == .YUV_420 || enc.config.chroma_format == .YUV_422 ? 2 : 1
		sub_h := enc.config.chroma_format == .YUV_420 ? 2 : 1
		common.write_bits(w, 1, 1) // conformance_window_vps_flag
		common.write_ue(w, 0)
		common.write_ue(w, u32((enc.coded_width - enc.width) / sub_w))
		common.write_ue(w, 0)
		common.write_ue(w, u32((enc.coded_height - enc.height) / sub_h))
	} else {
		common.write_bits(w, 0, 1)
	}
	common.write_bits(w, 1, 1) // max_one_active_ref_layer_flag
	common.write_bits(w, 1, 1) // vps_poc_lsb_aligned_flag
	common.write_bits(w, 1, 1) // poc_lsb_not_present_flag[1]
	// dpb_size() for output layer set 1: sub-layer 0 only.
	buf, reorder := dpb_sizes(enc)
	common.write_bits(w, 0, 1) // sub_layer_flag_info_present_flag[1]
	common.write_ue(w, u32(buf)) // max_vps_dec_pic_buffering_minus1[1][0][0]
	common.write_ue(w, u32(reorder)) // max_vps_num_reorder_pics[1][0]
	common.write_ue(w, 0) // max_vps_latency_increase_plus1[1][0]
	common.write_ue(w, 0) // direct_dep_type_len_minus2
	common.write_bits(w, 0, 1) // direct_dependency_all_layers_flag
	common.write_ue(w, 0) // vps_non_vui_extension_length
	common.write_bits(w, 0, 1) // vps_vui_present_flag
}

// The alpha channel information SEI message (F.14.2.8): full-range alpha,
// 0 transparent and the largest sample value opaque, colour straight or
// premultiplied. Written in layer 0 as Apple's encoder does.
@(private)
write_alpha_info :: proc(w: ^common.Bit_Writer, premultiplied: bool, bit_depth: int) {
	value_bits := bit_depth + 1 // alpha_channel_bit_depth_minus8 + 9
	payload_bits := 1 + 3 + 3 + 2 * value_bits + 2
	sei_message(w, 165, (payload_bits + 8) / 8) // the payload's stop bit included
	common.write_bits(w, 0, 1) // alpha_channel_cancel_flag
	common.write_bits(w, premultiplied ? 1 : 0, 3) // alpha_channel_use_idc
	common.write_bits(w, u32(bit_depth - 8), 3) // alpha_channel_bit_depth_minus8
	common.write_bits(w, 0, value_bits) // alpha_transparent_value
	common.write_bits(w, u32(1) << uint(bit_depth) - 1, value_bits) // alpha_opaque_value
	common.write_bits(w, 0, 1) // alpha_channel_incr_flag
	common.write_bits(w, 0, 1) // alpha_channel_clip_flag
	common.write_bits(w, 1, 1) // payload_bit_equal_to_one
	common.write_align_zero(w)
	common.write_rbsp_trailing_bits(w)
}

@(private)
append_alpha_info :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	enc.sei_writer = common.init_bit_writer(&enc.sei)
	write_alpha_info(&enc.sei_writer, enc.config.alpha_premultiplied, enc.bit_depth)
	append_sei_nal(enc, out, .PREFIX_SEI_NUT)
}

// The alpha channel information prefix SEI NAL unit (header included, no
// start code), for a container's decoder configuration record: hvcC carries
// it beside the parameter sets, as Apple's files do.
alpha_info_sei_nal :: proc(premultiplied: bool, bit_depth: int, allocator := context.allocator) -> []u8 {
	rbsp: [dynamic]u8
	defer delete(rbsp)
	w := common.init_bit_writer(&rbsp)
	write_alpha_info(&w, premultiplied, bit_depth)
	out := make([dynamic]u8, allocator)
	common.append_nal_annex_b(&out, {u8(Nal_Type.PREFIX_SEI_NUT) << 1, 1}, rbsp[:], false)
	// Drop the three-byte start code.
	copy(out[:], out[3:])
	resize(&out, len(out) - 3)
	return out[:]
}

// Joins the base and alpha layers' output for one picture into one access
// unit (F.7.4.2.4.4) in Apple's order: the base parameter sets, the alpha
// layer's, the base layer's remaining units (SEI, slices), then the alpha
// layer's slices. Both inputs are Annex B; out receives Annex B with 4-byte
// start codes.
interleave_alpha :: proc(base, alpha: []u8, out: ^[dynamic]u8) {
	is_parameter_set :: proc(nal: []u8) -> bool {
		type := nal[0] >> 1 & 0x3F
		return type >= u8(Nal_Type.VPS_NUT) && type <= u8(Nal_Type.PPS_NUT)
	}
	emit :: proc(out: ^[dynamic]u8, data: []u8, parameter_sets: bool) {
		pos := 0
		for {
			nal, ok := next_annex_b_nal(data, &pos)
			if !ok do break
			if is_parameter_set(nal) != parameter_sets do continue
			append(out, 0, 0, 0, 1)
			append(out, ..nal)
		}
	}
	emit(out, base, true)
	emit(out, alpha, true)
	emit(out, base, false)
	emit(out, alpha, false)
}

// The next NAL unit (header and payload, without start code or trailing
// zero bytes) of Annex B data from pos.
@(private)
next_annex_b_nal :: proc(data: []u8, pos: ^int) -> (nal: []u8, ok: bool) {
	i := pos^
	for i + 3 <= len(data) && !(data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) do i += 1
	if i + 3 > len(data) {pos^ = len(data); return}
	start := i + 3
	end := start
	for end + 3 <= len(data) && !(data[end] == 0 && data[end + 1] == 0 && data[end + 2] <= 1) do end += 1
	if end + 3 > len(data) do end = len(data)
	pos^ = end
	for end > start && data[end - 1] == 0 do end -= 1
	if end - start < 2 do return next_annex_b_nal(data, pos)
	return data[start:end], true
}

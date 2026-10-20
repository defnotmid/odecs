package main

// Prints the frame headers of a raw AV1 OBU stream with FFmpeg's
// trace_headers element names, one "name value" per line and "frame" before
// each header, for tests/av1_check.sh to compare with the trace.

import av1 "../video/av1"
import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: av1_headers file.obu")
		os.exit(2)
	}
	data, rerr := os.read_entire_file(os.args[1], context.allocator)
	if rerr != nil do os.exit(1)
	p: av1.Parser
	frames: [dynamic]av1.Frame
	tiles: [dynamic]av1.Tile
	tile_bytes := 0
	// Temporal units start at temporal delimiters.
	start := 0
	for at := 0; at <= len(data); {
		o: av1.Obu
		next := len(data)
		if at < len(data) {
			err: av1.Error
			o, next, err = av1.next_obu(data, at)
			if err != .None {
				fmt.eprintln("obu:", err)
				os.exit(1)
			}
		}
		if at == len(data) || (o.type == .Temporal_Delimiter && at > start) {
			if err := av1.parse_temporal_unit(&p, data[start:at], &frames, &tiles); err != .None {
				fmt.eprintln("unit at", start, ":", err)
				os.exit(1)
			}
			for fr in frames {
				print_header(fr.header)
				fmt.printfln("tiles %d", len(fr.tiles))
				for t in fr.tiles do tile_bytes += int(t.size)
			}
			start = at
		}
		if at == len(data) do break
		at = next
	}
	fmt.eprintln("tile bytes", tile_bytes, "of", len(data))
}

print_header :: proc(h: av1.Frame_Header) {
	fmt.println("frame")
	v :: proc(name: string, x: $T) {fmt.printfln("%s %v", name, x)}
	b :: proc(name: string, x: bool) {fmt.printfln("%s %d", name, x ? 1 : 0)}
	b("show_existing_frame", h.show_existing_frame)
	if h.show_existing_frame {
		v("frame_to_show_map_idx", h.frame_to_show_map_idx)
		return
	}
	v("frame_type", int(h.frame_type))
	b("show_frame", h.show_frame)
	b("showable_frame", h.showable_frame)
	b("error_resilient_mode", h.error_resilient_mode)
	b("disable_cdf_update", h.disable_cdf_update)
	b("allow_screen_content_tools", h.allow_screen_content_tools)
	if !h.frame_is_intra do b("force_integer_mv", h.force_integer_mv) // the spec forces 1 on intra frames; the trace shows the coded value
	v("current_frame_id", h.current_frame_id)
	b("frame_size_override_flag", h.frame_size_override_flag)
	v("order_hint", h.order_hint)
	v("primary_ref_frame", h.primary_ref_frame)
	b("buffer_removal_time_present_flag", h.buffer_removal_time_present_flag)
	v("refresh_frame_flags", h.refresh_frame_flags)
	v("frame_width_minus_1", h.upscaled_width - 1)
	v("frame_height_minus_1", h.frame_height - 1)
	b("use_superres", h.use_superres)
	v("coded_denom", h.coded_denom)
	b("render_and_frame_size_different", h.render_and_frame_size_different)
	v("render_width_minus_1", h.render_width - 1)
	v("render_height_minus_1", h.render_height - 1)
	b("allow_intrabc", h.allow_intrabc)
	b("frame_refs_short_signaling", h.frame_refs_short_signaling)
	for i in 0 ..< av1.REFS_PER_FRAME do fmt.printfln("ref_frame_idx[%d] %d", i, h.ref_frame_idx[i])
	b("allow_high_precision_mv", h.allow_high_precision_mv)
	b("is_filter_switchable", h.is_filter_switchable)
	if !h.is_filter_switchable do v("interpolation_filter", h.interpolation_filter)
	b("is_motion_mode_switchable", h.is_motion_mode_switchable)
	b("use_ref_frame_mvs", h.use_ref_frame_mvs)
	b("disable_frame_end_update_cdf", h.disable_frame_end_update_cdf)
	t := h.tile_info
	b("uniform_tile_spacing_flag", t.uniform_tile_spacing_flag)
	v("tile_cols_log2", t.tile_cols_log2)
	v("tile_rows_log2", t.tile_rows_log2)
	if !t.uniform_tile_spacing_flag {
		for i in 0 ..< t.tile_cols do fmt.printfln("width_in_sbs_minus_1[%d] %d", i, t.width_in_sbs_minus_1[i])
		for i in 0 ..< t.tile_rows do fmt.printfln("height_in_sbs_minus_1[%d] %d", i, t.height_in_sbs_minus_1[i])
	}
	v("context_update_tile_id", t.context_update_tile_id)
	if t.tile_size_bytes > 0 do v("tile_size_bytes_minus_1", t.tile_size_bytes - 1)
	v("base_q_idx", h.base_q_idx)
	v("delta_q_y_dc.delta_q", h.delta_q_y_dc)
	v("delta_q_u_dc.delta_q", h.delta_q_u_dc)
	v("delta_q_u_ac.delta_q", h.delta_q_u_ac)
	v("delta_q_v_dc.delta_q", h.delta_q_v_dc)
	v("delta_q_v_ac.delta_q", h.delta_q_v_ac)
	b("diff_uv_delta", h.diff_uv_delta)
	b("using_qmatrix", h.using_qmatrix)
	v("qm_y", h.qm_y)
	v("qm_u", h.qm_u)
	v("qm_v", h.qm_v)
	b("segmentation_enabled", h.segmentation_enabled)
	b("segmentation_update_map", h.segmentation_update_map)
	b("segmentation_temporal_update", h.segmentation_temporal_update)
	b("segmentation_update_data", h.segmentation_update_data)
	if h.segmentation_enabled && h.segmentation_update_data {
		for i in 0 ..< av1.MAX_SEGMENTS do for j in 0 ..< av1.SEG_LVL_MAX {
			fmt.printfln("feature_enabled[%d][%d] %d", i, j, h.feature_enabled[i] >> uint(j) & 1)
			fmt.printfln("feature_value[%d][%d] %d", i, j, h.feature_data[i][j])
		}
	}
	b("delta_q_present", h.delta_q_present)
	v("delta_q_res", h.delta_q_res)
	b("delta_lf_present", h.delta_lf_present)
	v("delta_lf_res", h.delta_lf_res)
	b("delta_lf_multi", h.delta_lf_multi)
	for i in 0 ..< 4 do fmt.printfln("loop_filter_level[%d] %d", i, h.loop_filter_level[i])
	v("loop_filter_sharpness", h.loop_filter_sharpness)
	b("loop_filter_delta_enabled", h.loop_filter_delta_enabled)
	b("loop_filter_delta_update", h.loop_filter_delta_update)
	for i in 0 ..< av1.NUM_REF_FRAMES {
		fmt.printfln("update_ref_delta[%d] %d", i, h.update_ref_delta >> uint(i) & 1)
		fmt.printfln("loop_filter_ref_deltas[%d] %d", i, h.loop_filter_ref_deltas[i])
	}
	for i in 0 ..< 2 {
		fmt.printfln("update_mode_delta[%d] %d", i, h.update_mode_delta >> uint(i) & 1)
		fmt.printfln("loop_filter_mode_deltas[%d] %d", i, h.loop_filter_mode_deltas[i])
	}
	v("cdef_damping_minus_3", h.cdef_damping_minus_3)
	v("cdef_bits", h.cdef_bits)
	coded_sec :: proc(s: u8) -> u8 {return s == 4 ? 3 : s}
	for i in 0 ..< 8 {
		fmt.printfln("cdef_y_pri_strength[%d] %d", i, h.cdef_y_pri_strength[i])
		fmt.printfln("cdef_y_sec_strength[%d] %d", i, coded_sec(h.cdef_y_sec_strength[i]))
		fmt.printfln("cdef_uv_pri_strength[%d] %d", i, h.cdef_uv_pri_strength[i])
		fmt.printfln("cdef_uv_sec_strength[%d] %d", i, coded_sec(h.cdef_uv_sec_strength[i]))
	}
	CODED := [4]int{0, 2, 3, 1} // restoration type back to lr_type
	for i in 0 ..< 3 do fmt.printfln("lr_type[%d] %d", i, CODED[h.frame_restoration_type[i]])
	v("tx_mode", h.tx_mode)
	b("reference_select", h.reference_select)
	b("skip_mode_present", h.skip_mode_present)
	b("allow_warped_motion", h.allow_warped_motion)
	b("reduced_tx_set", h.reduced_tx_set)
	for ref in av1.LAST_FRAME ..= av1.ALTREF_FRAME {
		fmt.printfln("is_global[%d] %d", ref, h.gm_type[ref] != 0 ? 1 : 0)
	}
	g := h.film_grain
	b("apply_grain", g.apply_grain)
	if !g.apply_grain do return
	v("grain_seed", g.grain_seed)
	b("update_grain", g.update_grain)
	v("film_grain_params_ref_idx", g.film_grain_params_ref_idx)
	if !g.update_grain do return
	v("num_y_points", g.num_y_points)
	b("chroma_scaling_from_luma", g.chroma_scaling_from_luma)
	v("num_cb_points", g.num_cb_points)
	v("num_cr_points", g.num_cr_points)
	v("grain_scaling_minus_8", g.grain_scaling_minus_8)
	v("ar_coeff_lag", g.ar_coeff_lag)
	v("ar_coeff_shift_minus_6", g.ar_coeff_shift_minus_6)
	v("grain_scale_shift", g.grain_scale_shift)
	v("cb_mult", g.cb_mult)
	v("cb_luma_mult", g.cb_luma_mult)
	v("cb_offset", g.cb_offset)
	v("cr_mult", g.cr_mult)
	v("cr_luma_mult", g.cr_luma_mult)
	v("cr_offset", g.cr_offset)
	b("overlap_flag", g.overlap_flag)
	b("clip_to_restricted_range", g.clip_to_restricted_range)
}

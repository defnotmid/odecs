package h265_encoder

import common "../../../common"
import "core:math"
import "core:mem"

// ---------------------------------------------------------------------------
// Encoder top level: parameter sets, slice header, frame encode.
// ---------------------------------------------------------------------------

Encoder :: struct {
	config:           Config,
	width:            int,
	height:           int,
	coded_width:      int,
	coded_height:     int,
	ctu_cols:         int,
	ctu_rows:         int,
	qp:               i32,
	bit_depth:        int,
	lambda:           f64,
	// SSE scale of the current bit depth (16 for 10-bit): the lambda and the
	// fixed distortion thresholds scale with it so the mode decisions match
	// the 8-bit ones on the same content.
	dist_scale:       f64,
	source:           Frame,
	rec:              Frame,
	refs:             [2][MAX_ENC_REFS]Frame,
	ref_poc:          [2][MAX_ENC_REFS]i32,
	refs_active:      [2]int,
	// The reference index the inter search runs against per list. Low-delay B
	// searches the second list at index 1 (t-2); the hierarchical pyramid has
	// one reference per list and searches index 0.
	search_ref:       [2]int,
	// Temporal MVP: the collocated motion fields of coded pictures keyed by
	// POC, and the field of the picture this slice's collocated fields name.
	// `col` is nil when the tool is off or no field is available.
	tmvp:             bool,
	col_from_l0:      bool,
	no_backward_pred: bool,
	col_poc:          i32,
	col:              []Col_Motion_Enc,
	col_buf:          [MAX_COL_PICS][]Col_Motion_Enc,
	col_ring_poc:     [MAX_COL_PICS]i32,
	col_ring_valid:   [MAX_COL_PICS]bool,
	col_next:         int,
	col_cols:         int,
	// Wavefronts: the slice payload is built in its own buffer (the header
	// needs the substream sizes) and each substream boundary records its
	// escaped length plus the 9.3.1 context handoff.
	payload:          [dynamic]u8,
	payload_writer:   common.Bit_Writer,
	entry_sizes:      [MAX_WPP_SUBSTREAMS]u32,
	entry_count:      int,
	substream_start:  int,
	wpp_saved:        Cabac_Contexts,
	wpp_has_saved:    bool,
	// Tiles: the 6.5.1 geometry. `ts_of` maps a raster CTB to its tile-scan
	// index and `rs_of` back; `tcol_of`/`trow_of` map CTB columns and rows to
	// tile columns and rows; `tile_xb`/`tile_yb` are the tile boundaries in
	// CTB units. All are nil with tiles off, where the two orders coincide.
	tiles_on:         bool,
	ts_of:            []i32,
	rs_of:            []i32,
	tcol_of:          []i32,
	trow_of:          []i32,
	tile_ts0:         [dynamic]int,
	tile_tasks:       []Tile_Task,
	tile_xb:          [dynamic]int,
	tile_yb:          [dynamic]int,
	sao_src:          Frame,
	// The SEI NAL payload is built in its own buffer and emitted complete.
	sei:              [dynamic]u8,
	sei_writer:       common.Bit_Writer,
	// Rate control: the PPS anchors at qp_base and each picture takes its
	// own slice_qp_delta from the controller.
	qp_base:          i32,
	rc:               Rc_State,
	cur_poc:          i32,
	cu:               Cu_Grid,
	slice_type:       Slice_Type,
	wp:               Pred_Weights,
	// The active scaling list of this encode (see scaling.odin); off leaves
	// scaling_on false and every quantizer call flat.
	scaling:          Scaling_List,
	scaling_on:       bool,

	// Hierarchical GOP: buffered display-order input frames and the coded
	// pictures they reference, both keyed by display POC.
	// Integer motion search half-range in pixels. The hierarchical anchors
	// reference pictures a whole group away, where motion is larger than the
	// low-delay distance-1 case the fixed range 4 was chosen for.
	motion_range:     i32,
	hier_queue:       [MAX_HIER_FRAMES]Frame,
	hier_dpb:         [MAX_HIER_FRAMES]Frame,
	hier_dpb_poc:     [MAX_HIER_FRAMES]i32,
	hier_dpb_valid:   [MAX_HIER_FRAMES]bool,
	gop_size:         int,
	queue_head:       int,
	queue_poc0:       i32,
	queue_count:      int,
	hier_started:     bool,
	sao_luma:         []Sao_Info,
	sao_chroma:       []Sao_Info,

	// Transposed transform bases for the vector forward transform, built once.
	// Index 4 is the 4x4 DST-VII basis used for luma intra blocks.
	dct_t:            [5][1024]i32,
	cabac:            Cabac,
	rbsp:             [dynamic]u8,
	out:              [dynamic]u8,
	frame_index:      int,
	poc_origin:       int,
	rec_display:      [dynamic]u8,
	trial_buf:        [dynamic]u8,
	trial_writer:     common.Bit_Writer,
	trial_cabac:      Cabac,
	allocator:        mem.Allocator,
}

init_encoder :: proc(enc: ^Encoder, config: Config, allocator := context.allocator) {
	enc.allocator = allocator
	enc.config = config
	enc.width = config.width
	enc.height = config.height
	enc.coded_width = (config.width + 7) / 8 * 8
	enc.coded_height = (config.height + 7) / 8 * 8
	enc.ctu_cols = (enc.coded_width + CTU_WIDTH - 1) / CTU_WIDTH
	enc.ctu_rows = (enc.coded_height + CTU_WIDTH - 1) / CTU_WIDTH
	// Tiles take precedence over wavefronts (4:2:0 forbids combining them),
	// and a tile grid denser than the picture is clamped.
	enc.tiles_on = config.tiles_cols > 1 || config.tiles_rows > 1
	if enc.tiles_on {
		enc.config.wpp = false
		enc.config.tiles_cols = clamp(config.tiles_cols, 1, enc.ctu_cols)
		enc.config.tiles_rows = clamp(config.tiles_rows, 1, enc.ctu_rows)
		if enc.config.tiles_cols == 1 && enc.config.tiles_rows == 1 {
			enc.tiles_on = false
		} else if enc.config.tiles_cols * enc.config.tiles_rows > MAX_WPP_SUBSTREAMS {
			enc.tiles_on = false
			enc.config.tiles_cols = 1
			enc.config.tiles_rows = 1
		} else {
			build_tiles(enc)
		}
	}
	enc.bit_depth = config.bit_depth == 0 ? 8 : config.bit_depth
	if enc.bit_depth != 8 && enc.bit_depth != 10 do enc.bit_depth = 8
	// 8.6.1: the luma QP range runs from -QpBdOffset to 51.
	enc.qp = clamp(config.qp, -6 * i32(enc.bit_depth - 8), 51)
	enc.qp_base = enc.qp
	// level_idc 0 selects the lowest level that fits (Annex A).
	if enc.config.level_idc == 0 {
		enc.config.level_idc = select_level(
			enc.coded_width,
			enc.coded_height,
			config.fps_num,
			config.fps_den,
			config.refs + 2,
		)
	}
	if config.forced_mode < 0 do enc.config.forced_mode = -1
	// Residual DPCM rides on transform skip: the implicit intra form is a
	// transform-skip block whose prediction mode is 10 or 26.
	if config.rdpcm do enc.config.tskip = true
	if config.intra_only || config.intra_only_i_slices {
		enc.config.b_frames = false
		enc.config.hierarchical = false
	}
	enc.gop_size = clamp(config.gop_size, 2, MAX_GOP)
	enc.config.refs = clamp(config.refs, 1, MAX_ENC_REFS)
	enc.search_ref = {0, 1}
	enc.motion_range = config.hierarchical || config.refs > 1 ? 8 : 4
	enc.dist_scale = f64(i32(1) << uint(2 * (enc.bit_depth - 8)))
	enc.lambda = qd_lambda(enc.qp) * enc.dist_scale

	// Rate control: one record per encode; Constant_QP changes nothing.
	enc.rc = Rc_State {
		mode    = config.rc,
		base_qp = enc.qp_base,
	}
	if config.rc == .ABR || config.rc == .CBR {
		fps := 25.0
		if config.fps_num > 0 && config.fps_den > 0 {
			fps = f64(config.fps_num) / f64(config.fps_den)
		}
		enc.rc.target_bits = f64(config.bitrate) / fps
		enc.rc.buffer_size = f64(config.rc_buffer)
		if enc.rc.buffer_size <= 0 && config.rc == .CBR do enc.rc.buffer_size = f64(config.bitrate)
	}
	if config.rc == .CRF {
		enc.qp_base = clamp(i32(config.crf + 0.5), -6 * i32(enc.bit_depth - 8), 51)
		enc.qp = enc.qp_base
		enc.rc.base_qp = enc.qp_base
	}
	enc.wp = default_weights()
	init_scaling(enc, config.scaling)
	init_fwd_dct_t(enc)

	neutral := Sample(1) << uint(enc.bit_depth - 1)

	enc.source = alloc_frame(
		enc.coded_width,
		enc.coded_height,
		1,
		allocator,
		layout_format(enc.config.chroma_format),
	)
	enc.rec = alloc_frame(
		enc.coded_width,
		enc.coded_height,
		1,
		allocator,
		layout_format(enc.config.chroma_format),
	)
	for l in 0 ..< 2 {
		for r in 0 ..< MAX_ENC_REFS {
			enc.refs[l][r] = alloc_frame(
				enc.coded_width,
				enc.coded_height,
				1,
				allocator,
				layout_format(enc.config.chroma_format),
			)
			fill_frame(&enc.refs[l][r], neutral)
		}
	}
	enc.sao_src = alloc_frame(
		enc.coded_width,
		enc.coded_height,
		1,
		allocator,
		layout_format(enc.config.chroma_format),
	)
	fill_frame(&enc.source, neutral)
	fill_frame(&enc.rec, neutral)
	fill_frame(&enc.sao_src, neutral)

	if config.hierarchical {
		for i in 0 ..< MAX_HIER_FRAMES {
			enc.hier_queue[i] = alloc_frame(
				enc.coded_width,
				enc.coded_height,
				1,
				allocator,
				layout_format(enc.config.chroma_format),
			)
			enc.hier_dpb[i] = alloc_frame(
				enc.coded_width,
				enc.coded_height,
				1,
				allocator,
				layout_format(enc.config.chroma_format),
			)
			fill_frame(&enc.hier_queue[i], neutral)
			fill_frame(&enc.hier_dpb[i], neutral)
		}
	}

	enc.cu = Cu_Grid {
		cells = make([]Cu_Info, (enc.coded_width / 4) * (enc.coded_height / 4), allocator),
		cols  = enc.coded_width / 4,
	}
	if config.tmvp {
		enc.col_cols = (enc.coded_width + 15) / 16
		cells := enc.col_cols * ((enc.coded_height + 15) / 16)
		for i in 0 ..< MAX_COL_PICS do enc.col_buf[i] = make([]Col_Motion_Enc, cells, allocator)
	}
	ctu_count := enc.ctu_cols * enc.ctu_rows
	enc.sao_luma = make([]Sao_Info, ctu_count, allocator)
	enc.sao_chroma = make([]Sao_Info, ctu_count, allocator)

	enc.rbsp = make([dynamic]u8, 0, 1 << 20, allocator)
	enc.out = make([dynamic]u8, 0, 1 << 20, allocator)
	enc.rec_display = make([dynamic]u8, 0, 1 << 16, allocator)
	enc.trial_buf = make([dynamic]u8, 0, 1 << 16, allocator)
	enc.sei = make([dynamic]u8, 0, 1 << 12, allocator)
	enc.trial_writer = common.Bit_Writer {
		buf = &enc.trial_buf,
	}
	enc.trial_cabac.stream = &enc.trial_writer
	if config.wpp {
		enc.payload = make([dynamic]u8, 0, 1 << 20, allocator)
		enc.payload_writer = common.Bit_Writer {
			buf = &enc.payload,
		}
	}
}

destroy_encoder :: proc(enc: ^Encoder) {
	free_frame(&enc.source)
	free_frame(&enc.rec)
	for l in 0 ..< 2 {
		for r in 0 ..< MAX_ENC_REFS do free_frame(&enc.refs[l][r])
	}
	free_frame(&enc.sao_src)
	for i in 0 ..< MAX_HIER_FRAMES {
		free_frame(&enc.hier_queue[i])
		free_frame(&enc.hier_dpb[i])
	}
	for i in 0 ..< MAX_COL_PICS do delete(enc.col_buf[i])
	delete(enc.cu.cells)
	delete(enc.sao_luma)
	delete(enc.sao_chroma)
	delete(enc.ts_of)
	delete(enc.rs_of)
	delete(enc.tcol_of)
	delete(enc.trow_of)
	delete(enc.tile_xb)
	delete(enc.tile_yb)
	delete(enc.tile_ts0)
	for i in 0 ..< len(enc.tile_tasks) do delete(enc.tile_tasks[i].trial_buf)
	delete(enc.tile_tasks)
	delete(enc.rbsp)
	delete(enc.out)
	delete(enc.rec_display)
	delete(enc.trial_buf)
	delete(enc.sei)
	delete(enc.payload)
	enc^ = {}
}

// Copy one input frame into the padded source frame, extending the last row
// and column into the coded padding.
set_source :: proc(enc: ^Encoder, y, u, v: [^]Sample, y_stride, c_stride: int) {
	set_source_into(enc, &enc.source, y, u, v, y_stride, c_stride)
}

// ---------------------------------------------------------------------------
// Parameter sets
// ---------------------------------------------------------------------------

// select_level picks the lowest level of Table A.6 that fits the picture
// size, the luma sample rate and the decoded picture buffer (Annex A). The
// rate-dependent constraints (MaxCPB, MaxSliceSegmentRate) need the rate
// control the product surface has not landed yet.
select_level :: proc(width, height, fps_num, fps_den, refs: int) -> u8 {
	// (level_idc, MaxLumaPs, MaxLumaSr) for the Main-tier levels.
	table := [?]struct {
		level:   u8,
		luma_ps: i64,
		luma_sr: i64,
	} {
		{30, 36864, 552960}, // 1
		{60, 122880, 3686400}, // 2
		{63, 245760, 7372800}, // 2.1
		{90, 552960, 16588800}, // 3
		{93, 983040, 33177600}, // 3.1
		{120, 2228224, 66846720}, // 4
		{123, 2228224, 133693440}, // 4.1
		{150, 8912896, 267386880}, // 5
		{153, 8912896, 534773760}, // 5.1
		{156, 8912896, 1069547520}, // 5.2
		{180, 35651584, 1069547520}, // 6
		{183, 35651584, 2139095040}, // 6.1
		{186, 35651584, 4278190080}, // 6.2
	}

	luma_ps := i64(width) * i64(height)
	fps := fps_num > 0 && fps_den > 0 ? i64(fps_num) / i64(fps_den) : 30
	luma_sr := luma_ps * fps

	for e in table {
		if luma_ps <= e.luma_ps && luma_sr <= e.luma_sr {
			// The A.4.2 MaxDpbSize constraint is satisfied by the
			// SPS buffering (refs + 2 pictures stay under 16 at these
			// sizes); the rate constraints wait for rate control.
			_ = refs
			return e.level
		}
	}

	return 186
}

write_ptl :: proc(
	w: ^common.Bit_Writer,
	level_idc: u8,
	bit_depth: int,
	layout: Chroma_Layout,
	rdpcm := false,
) {
	rext := layout != .YUV_420 || rdpcm
	// general_profile_space, general_tier_flag and the profile idc: Main for
	// 8-bit 4:2:0, Main 10 above, and RExt for other formats or RDPCM.
	common.write_bits(w, 0, 2)
	common.write_bits(w, 0, 1)
	common.write_bits(w, rext ? 4 : (bit_depth > 8 ? 2 : 1), 5)
	// general_profile_compatibility_flags: Main and Main 10 for an 8-bit
	// 4:2:0 stream, only Main 10 above, and only RExt for other formats.
	common.write_bits(w, rext ? 0x08000000 : (bit_depth > 8 ? 0x20000000 : 0x60000000), 32)
	common.write_bits(w, 1, 1) // progressive_source
	common.write_bits(w, 0, 1) // interlaced_source
	common.write_bits(w, 0, 1) // non_packed_constraint
	common.write_bits(w, 0, 1) // frame_only_constraint
	if rext {
		common.write_bits(w, 1, 1) // max_12bit_constraint_flag
		common.write_bits(w, bit_depth <= 10 ? 1 : 0, 1)
		// RDPCM requires the Main 4:4:4 family (A.3.5/Table A.1), even
		// when the actual samples are 4:2:0. The 4:2:2 family starts at
		// Main 4:2:2 10, so an 8-bit 4:2:2 stream must not claim the
		// reserved max_8bit/max_422 constraint combination (Table A.2).
		max_422 := layout != .YUV_444 && !rdpcm
		common.write_bits(w, bit_depth <= 8 && (!max_422 || layout == .Monochrome) ? 1 : 0, 1)
		common.write_bits(w, max_422 ? 1 : 0, 1) // max_422chroma
		common.write_bits(w, layout == .Monochrome && !rdpcm ? 1 : 0, 1) // max_420chroma
		common.write_bits(w, layout == .Monochrome && !rdpcm ? 1 : 0, 1) // max_monochrome
		common.write_bits(w, 0, 1) // intra_constraint_flag
		common.write_bits(w, 0, 1) // one_picture_only_constraint_flag
		common.write_bits(w, 1, 1) // lower_bit_rate_constraint_flag
		common.write_bits(w, 0, 32) // reserved_zero_34bits and inbld_flag
		common.write_bits(w, 0, 3)
	} else {
		common.write_bits(w, 0, 32) // reserved constraint bits
		common.write_bits(w, 0, 12)
	}
	common.write_bits(w, u32(level_idc), 8)
	// No sub-layers: maxNumSubLayersMinus1 is 1, so one pair of present
	// flags followed by 7 reserved_zero_2bits entries.
	common.write_bits(w, 0, 1)
	common.write_bits(w, 0, 1)
	for _ in 0 ..< 7 do common.write_bits(w, 0, 2)
}

write_vps :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	w := common.init_bit_writer(&enc.rbsp)
	common.write_bits(&w, 0, 4) // vps_video_parameter_set_id
	common.write_bits(&w, 3, 2) // vps_base_layer_internal_flag, vps_base_layer_available_flag
	common.write_bits(&w, enc.config.layer == .Base_With_Alpha ? 1 : 0, 6) // vps_max_layers_minus1
	common.write_bits(&w, 1, 3) // vps_max_sub_layers_minus1
	common.write_bits(&w, 0, 1) // temporal_id_nesting
	common.write_bits(&w, 0xffff, 16)
	write_ptl(&w, enc.config.level_idc, enc.bit_depth, enc.config.chroma_format, enc.config.rdpcm)
	common.write_bits(&w, 0, 1) // sub_layer_ordering_info_present
	buf, reorder := dpb_sizes(enc)
	common.write_ue(&w, u32(buf)) // max_dec_pic_buffering_minus1
	common.write_ue(&w, u32(reorder)) // max_num_reorder_pics
	common.write_ue(&w, 0) // max_latency_increase_plus1
	common.write_bits(&w, enc.config.layer == .Base_With_Alpha ? 1 : 0, 6) // vps_max_layer_id
	common.write_ue(&w, 0) // vps_num_layer_sets_minus1
	common.write_bits(&w, 0, 1) // timing_info_present
	if enc.config.layer == .Base_With_Alpha {
		common.write_bits(&w, 1, 1) // vps_extension_flag
		write_vps_alpha_extension(enc, &w)
		common.write_bits(&w, 0, 1) // vps_extension2_flag
	} else {
		common.write_bits(&w, 0, 1) // vps_extension_flag
	}
	common.write_rbsp_trailing_bits(&w)

	header := nal_header(enc, .VPS_NUT)
	common.append_nal_annex_b(out, header[:], enc.rbsp[:])
}

write_sps :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	w := common.init_bit_writer(&enc.rbsp)
	common.write_bits(&w, 0, 4) // sps_video_parameter_set_id
	common.write_bits(&w, 1, 3) // sps_max_sub_layers_minus1 (sps_ext_or_max_sub_layers_minus1 in layer 1)
	common.write_bits(&w, 0, 1) // temporal_id_nesting
	write_ptl(&w, enc.config.level_idc, enc.bit_depth, enc.config.chroma_format, enc.config.rdpcm)

	common.write_ue(&w, layer_parameter_set_id(enc)) // sps_seq_parameter_set_id
	common.write_ue(&w, layout_idc(enc.config.chroma_format)) // chroma_format_idc
	if enc.config.chroma_format == .YUV_444 do common.write_bits(&w, 0, 1) // separate_colour_plane_flag
	common.write_ue(&w, u32(enc.coded_width))
	common.write_ue(&w, u32(enc.coded_height))
	if enc.coded_width != enc.width || enc.coded_height != enc.height {
		// The conformance window offsets count in crop units (Table 6-1):
		// chroma samples for 4:2:0 and 4:2:2, luma samples for monochrome
		// and 4:4:4. The 4:2:0 form matches the historical bitstream.
		sub_w :=
			enc.config.chroma_format == .YUV_420 || enc.config.chroma_format == .YUV_422 ? 2 : 1
		sub_h := enc.config.chroma_format == .YUV_420 ? 2 : 1
		common.write_bits(&w, 1, 1)
		common.write_ue(&w, 0)
		common.write_ue(&w, u32((enc.coded_width - enc.width) / sub_w))
		common.write_ue(&w, 0)
		common.write_ue(&w, u32((enc.coded_height - enc.height) / sub_h))
	} else {
		common.write_bits(&w, 0, 1)
	}
	common.write_ue(&w, u32(enc.bit_depth - 8)) // bit_depth_luma_minus8
	common.write_ue(&w, u32(enc.bit_depth - 8)) // bit_depth_chroma_minus8
	common.write_ue(&w, 4) // log2_max_pic_order_cnt_lsb_minus4
	common.write_bits(&w, 0, 1) // sub_layer_ordering_info_present
	buf, reorder := dpb_sizes(enc)
	common.write_ue(&w, u32(buf)) // max_dec_pic_buffering_minus1
	common.write_ue(&w, u32(reorder)) // max_num_reorder_pics
	common.write_ue(&w, 0) // max_latency_increase_plus1
	common.write_ue(&w, 0) // log2_min_coding_block_size_minus3: 8
	common.write_ue(&w, 3) // log2_diff_max_min_coding_block_size: 64
	common.write_ue(&w, 0) // log2_min_transform_block_size_minus2: 4
	common.write_ue(&w, 3) // log2_diff_max_min_transform_block_size: 32
	common.write_ue(&w, enc.config.rqt ? RQT_MAX_HIER : 0) // max_transform_hierarchy_depth_inter
	common.write_ue(&w, enc.config.intra_rqt ? RQT_MAX_HIER : 0) // max_transform_hierarchy_depth_intra
	common.write_bits(&w, enc.scaling_on ? 1 : 0, 1) // scaling_list_enabled_flag
	if enc.scaling_on {
		common.write_bits(&w, 1, 1) // sps_scaling_list_data_present_flag
		write_scaling_list_data(&w, &enc.scaling)
	}
	common.write_bits(&w, enc.config.amp ? 1 : 0, 1) // amp_enabled_flag
	common.write_bits(&w, enc.config.sao ? 1 : 0, 1) // sample_adaptive_offset_enabled_flag
	common.write_bits(&w, enc.config.pcm ? 1 : 0, 1) // pcm_enabled_flag
	if enc.config.pcm {
		common.write_bits(&w, u32(enc.bit_depth - 1), 4) // pcm_sample_bit_depth_luma_minus1
		common.write_bits(&w, u32(enc.bit_depth - 1), 4) // pcm_sample_bit_depth_chroma_minus1
		common.write_ue(&w, PCM_LOG2_MIN - 3) // log2_min_pcm_luma_coding_block_size_minus3
		common.write_ue(&w, PCM_LOG2_MAX - PCM_LOG2_MIN) // log2_diff_max_min_pcm_luma_coding_block_size
		// PCM samples are filtered like any intra block; the decoder's
		// pcm_loop_filter_disabled_flag stays zero so both sides agree.
		common.write_bits(&w, 0, 1) // pcm_loop_filter_disabled_flag
	}
	common.write_ue(&w, 0) // num_short_term_ref_pic_sets
	common.write_bits(&w, 0, 1) // long_term_ref_pics_present_flag
	common.write_bits(&w, enc.config.tmvp ? 1 : 0, 1) // sps_temporal_mvp_enabled_flag
	common.write_bits(&w, 0, 1) // strong_intra_smoothing_enabled_flag
	vui := enc.config.vui || enc.config.colour_primaries != 0
	common.write_bits(&w, vui ? 1 : 0, 1) // vui_parameters_present_flag
	if vui do write_vui(enc, &w)
	if enc.config.rdpcm {
		// sps_range_extension(): the implicit residual DPCM tool. Every other
		// range-extension flag stays off, so the weighted prediction offsets
		// keep the eight-bit domain ffmpeg decodes them in.
		common.write_bits(&w, 1, 1) // sps_extension_present_flag
		common.write_bits(&w, 1, 1) // sps_range_extension_flag
		common.write_bits(&w, 0, 1) // sps_multilayer_extension_flag
		common.write_bits(&w, 0, 1) // sps_extension_3d_flag
		common.write_bits(&w, 0, 1) // sps_scc_extension_flag
		common.write_bits(&w, 0, 4) // sps_extension_4bits
		common.write_bits(&w, 0, 1) // transform_skip_rotation_enabled_flag
		common.write_bits(&w, 0, 1) // transform_skip_context_enabled_flag
		common.write_bits(&w, 1, 1) // implicit_rdpcm_enabled_flag
		common.write_bits(&w, 0, 1) // explicit_rdpcm_enabled_flag
		common.write_bits(&w, 0, 1) // extended_precision_processing_flag
		common.write_bits(&w, 0, 1) // intra_smoothing_disabled_flag
		common.write_bits(&w, 0, 1) // high_precision_offsets_enabled_flag
		common.write_bits(&w, 0, 1) // persistent_rice_adaptation_enabled_flag
		common.write_bits(&w, 0, 1) // cabac_bypass_alignment_enabled_flag
	} else {
		common.write_bits(&w, 0, 1) // sps_extension_present_flag
	}
	common.write_rbsp_trailing_bits(&w)

	header := nal_header(enc, .SPS_NUT)
	common.append_nal_annex_b(out, header[:], enc.rbsp[:])
}

write_pps :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	w := common.init_bit_writer(&enc.rbsp)
	common.write_ue(&w, layer_parameter_set_id(enc)) // pps_pic_parameter_set_id
	common.write_ue(&w, layer_parameter_set_id(enc)) // pps_seq_parameter_set_id
	common.write_bits(&w, 0, 1) // dependent_slice_segments_enabled_flag
	common.write_bits(&w, 0, 1) // output_flag_present_flag
	common.write_bits(&w, 0, 3) // num_extra_slice_header_bits
	common.write_bits(&w, 0, 1) // sign_data_hiding_flag
	common.write_bits(&w, 0, 1) // cabac_init_present_flag
	common.write_ue(&w, 0) // num_ref_idx_l0_default_active_minus1
	common.write_ue(&w, 0) // num_ref_idx_l1_default_active_minus1
	common.write_se(&w, enc.qp_base - 26) // pic_init_qp_minus26
	common.write_bits(&w, 0, 1) // constrained_intra_pred_flag
	common.write_bits(&w, enc.config.tskip ? 1 : 0, 1) // transform_skip_enabled_flag
	common.write_bits(&w, 0, 1) // cu_qp_delta_enabled_flag
	common.write_se(&w, 0) // pps_cb_qp_offset
	common.write_se(&w, 0) // pps_cr_qp_offset
	common.write_bits(&w, 0, 1) // pps_slice_chroma_qp_offsets_present_flag
	common.write_bits(&w, enc.config.weighted ? 1 : 0, 1) // weighted_pred_flag
	common.write_bits(&w, enc.config.weighted ? 1 : 0, 1) // weighted_bipred_flag
	common.write_bits(&w, 0, 1) // transquant_bypass_enable_flag
	common.write_bits(&w, enc.tiles_on ? 1 : 0, 1) // tiles_enabled_flag
	common.write_bits(&w, enc.config.wpp ? 1 : 0, 1) // entropy_coding_sync_enabled_flag
	if enc.tiles_on {
		// 7.4.3.3: the tile widths are spelled out (uniform_spacing_flag 0)
		// so both sides read identical geometry.
		common.write_ue(&w, u32(enc.config.tiles_cols - 1)) // num_tile_columns_minus1
		common.write_ue(&w, u32(enc.config.tiles_rows - 1)) // num_tile_rows_minus1
		common.write_bits(&w, 0, 1) // uniform_spacing_flag
		for i in 0 ..< enc.config.tiles_cols - 1 {
			common.write_ue(&w, u32(enc.tile_xb[i + 1] - enc.tile_xb[i] - 1)) // column_width_minus1
		}
		for i in 0 ..< enc.config.tiles_rows - 1 {
			common.write_ue(&w, u32(enc.tile_yb[i + 1] - enc.tile_yb[i] - 1)) // row_height_minus1
		}
		common.write_bits(&w, 1, 1) // loop_filter_across_tiles_enabled_flag
	}
	common.write_bits(&w, 0, 1) // loop_filter_across_slices_enabled_flag
	common.write_bits(&w, 1, 1) // deblocking_filter_control_present_flag
	common.write_bits(&w, 0, 1) // deblocking_filter_override_enabled_flag
	common.write_bits(&w, enc.config.deblock ? 0 : 1, 1) // pps_deblocking_filter_disabled_flag
	if enc.config.deblock {
		common.write_se(&w, 0) // pps_beta_offset_div2
		common.write_se(&w, 0) // pps_tc_offset_div2
	}
	common.write_bits(&w, 0, 1) // pps_scaling_list_data_present_flag
	common.write_bits(&w, 0, 1) // lists_modification_present_flag
	common.write_ue(&w, 0) // log2_parallel_merge_level_minus2
	common.write_bits(&w, 0, 1) // slice_segment_header_extension_present_flag
	common.write_bits(&w, 0, 1) // pps_extension_present_flag
	common.write_rbsp_trailing_bits(&w)

	header := nal_header(enc, .PPS_NUT)
	common.append_nal_annex_b(out, header[:], enc.rbsp[:])
}

write_parameter_sets :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	// The VPS belongs to layer 0; the alpha layer refers to the base layer's.
	if enc.config.layer != .Alpha do write_vps(enc, out)
	write_sps(enc, out)
	write_pps(enc, out)
}

// ---------------------------------------------------------------------------
// Slice encoding
// ---------------------------------------------------------------------------

write_slice_header :: proc(enc: ^Encoder, first: bool, poc: int, slice_type: Slice_Type) {
	w := common.init_bit_writer(&enc.rbsp)
	common.write_bits(&w, first ? 1 : 0, 1) // first_slice_segment_in_pic_flag
	if slice_type == .I {
		common.write_bits(&w, 0, 1) // no_output_of_prior_pics_flag
	}
	common.write_ue(&w, layer_parameter_set_id(enc)) // slice_pic_parameter_set_id
	common.write_ue(&w, u32(slice_type)) // slice_type
	if slice_type != .I {
		common.write_bits(&w, u32(poc & 0xff), 8) // pic_order_cnt_lsb
		common.write_bits(&w, 0, 1) // short_term_ref_pic_set_sps_flag
		if enc.config.hierarchical {
			write_hier_rps(enc, &w, poc, slice_type)
		} else if slice_type == .B {
			// Low-delay B: the short-term RPS has up to two negative pictures
			// (t-1 then t-2); delta_poc_s0_minus1 accumulates, so both gaps are
			// one and both values are zero.
			n_neg := poc >= 2 ? 2 : 1
			common.write_ue(&w, u32(n_neg)) // num_negative_pics
			common.write_ue(&w, 0) // num_positive_pics
			common.write_ue(&w, 0) // delta_poc_s0_minus1
			common.write_bits(&w, 1, 1) // used_by_curr_pic_s0_flag
			if n_neg == 2 {
				common.write_ue(&w, 0) // delta_poc_s0_minus1
				common.write_bits(&w, 1, 1) // used_by_curr_pic_s0_flag
			}
		} else {
			// P: every kept past picture is a used negative reference, nearest
			// first; delta_poc_s0_minus1 accumulates down the history.
			common.write_ue(&w, u32(enc.refs_active[0])) // num_negative_pics
			common.write_ue(&w, 0) // num_positive_pics
			prev := poc
			for i in 0 ..< enc.refs_active[0] {
				p := int(enc.ref_poc[0][i])
				common.write_ue(&w, u32(prev - p - 1)) // delta_poc_s0_minus1
				common.write_bits(&w, 1, 1) // used_by_curr_pic_s0_flag
				prev = p
			}
		}
		// slice_temporal_mvp_enabled_flag (7.3.6.1): present for every non-IDR
		// slice once the SPS enables the tool.
		if enc.config.tmvp do common.write_bits(&w, 1, 1)
	}
	if enc.config.sao {
		common.write_bits(&w, 1, 1) // slice_sao_luma_flag
		// slice_sao_chroma_flag is present only when ChromaArrayType != 0.
		if has_chroma(enc) do common.write_bits(&w, 1, 1)
	}
	if slice_type != .I {
		if slice_type == .B {
			if enc.config.hierarchical {
				// One active reference per list, the PPS defaults.
				common.write_bits(&w, 0, 1) // num_ref_idx_active_override_flag
			} else {
				// L0 keeps one active reference (t-1); L1 carries two so ref_idx 1
				// selects t-2 and ref_idx 0 still names t-1.
				common.write_bits(&w, 1, 1) // num_ref_idx_active_override_flag
				common.write_ue(&w, 0) // num_ref_idx_l0_active_minus1
				common.write_ue(&w, 1) // num_ref_idx_l1_active_minus1
			}
			common.write_bits(&w, 0, 1) // mvd_l1_zero_flag
		} else if enc.refs_active[0] > 1 {
			common.write_bits(&w, 1, 1) // num_ref_idx_active_override_flag
			common.write_ue(&w, u32(enc.refs_active[0] - 1)) // num_ref_idx_l0_active_minus1
		} else {
			common.write_bits(&w, 0, 1) // num_ref_idx_active_override_flag
		}
		if enc.config.tmvp {
			// collocated_from_l0_flag is inferred true for P; every list 0 has
			// a reference, and the collocated picture is its nearest one.
			if slice_type == .B do common.write_bits(&w, 1, 1) // collocated_from_l0_flag
			if enc.refs_active[0] > 1 do common.write_ue(&w, 0) // collocated_ref_idx
		}
		if enc.config.weighted do write_pred_weight_table(enc, &w)
		common.write_ue(&w, 0) // five_minus_max_num_merge_cand
	}
	common.write_se(&w, i32(enc.qp) - i32(enc.qp_base)) // slice_qp_delta
	if enc.tiles_on || enc.config.wpp {
		// 7.3.6.1 entry points: one substream per tile (or wavefront row
		// boundary), each measured in escaped NAL bytes, so the header is
		// written after the payload pass.
		n := enc.entry_count
		common.write_ue(&w, u32(n))
		if n > 0 {
			max_size: u32 = 1
			for i in 0 ..< n do max_size = max(max_size, enc.entry_sizes[i])

			bits := 1
			for (u32(1) << uint(bits)) <= max_size - 1 do bits += 1

			common.write_ue(&w, u32(bits - 1)) // offset_len_minus1
			for i in 0 ..< n do common.write_bits(&w, enc.entry_sizes[i] - 1, bits)
		}
	}
	// The slice segment header is byte aligned before the CABAC payload.
	common.write_rbsp_trailing_bits(&w)
}

// escaped_len is the NAL length of a raw substream: its bytes plus the
// emulation prevention bytes the Annex B writer would insert. A substream ends
// on an alignment byte that carries a one bit, so no zero run crosses a
// substream boundary and counting each substream on its own is exact.
escaped_len :: proc(data: []u8) -> int {
	n := 0
	zeros := 0

	for b in data {
		if zeros == 2 && b <= 3 {
			n += 1
			zeros = 0
		}

		n += 1
		zeros = b == 0 ? zeros + 1 : 0
	}

	return n
}

// wpp_next_substream closes one wavefront substream at a row boundary: flush
// and byte-align it, record its escaped length for the slice header, and start
// the next one with the contexts 9.3.1 hands down from the second coding tree
// block of the row just finished. A tile boundary uses the same closure but
// re-initializes the context variables (9.3.2.2).
next_substream :: proc(enc: ^Encoder, wpp_handoff: bool) {
	cabac_finish(&enc.cabac)
	common.write_bits(&enc.payload_writer, 1, 1)
	common.write_align_zero(&enc.payload_writer)

	end := len(enc.payload)
	enc.entry_sizes[enc.entry_count] = u32(escaped_len(enc.payload[enc.substream_start:end]))
	enc.entry_count += 1
	enc.substream_start = end

	if wpp_handoff && enc.wpp_has_saved {
		enc.cabac.ctx = enc.wpp_saved
	} else {
		// A picture one coding tree block wide has no above-right block to
		// synchronize with, so every row initializes (9.3.1); so does every
		// tile start (9.3.2.2).
		init_contexts(&enc.cabac, u32(enc.qp), enc.slice_type)
	}

	enc.wpp_has_saved = false
	cabac_start(&enc.cabac)
}

// ---------------------------------------------------------------------------
// Tile geometry (6.5.1). The PPS spells the tile widths out
// (uniform_spacing_flag 0), so the split here is free to be the balanced one:
// tile column i covers CTB columns [i * cols / N, (i + 1) * cols / N).
// ---------------------------------------------------------------------------

build_tiles :: proc(enc: ^Encoder) {
	cols, rows := enc.config.tiles_cols, enc.config.tiles_rows
	ctus := enc.ctu_cols * enc.ctu_rows

	enc.ts_of = make([]i32, ctus)
	enc.rs_of = make([]i32, ctus)
	enc.tcol_of = make([]i32, enc.ctu_cols)
	enc.trow_of = make([]i32, enc.ctu_rows)
	clear(&enc.tile_xb)
	clear(&enc.tile_yb)

	for i in 0 ..= cols do append(&enc.tile_xb, i * enc.ctu_cols / cols)
	for i in 0 ..= rows do append(&enc.tile_yb, i * enc.ctu_rows / rows)

	for tx in 0 ..< cols {
		for cx in enc.tile_xb[tx] ..< enc.tile_xb[tx + 1] do enc.tcol_of[cx] = i32(tx)
	}
	for ty in 0 ..< rows {
		for cy in enc.tile_yb[ty] ..< enc.tile_yb[ty + 1] do enc.trow_of[cy] = i32(ty)
	}

	// 6.5.1 tile scan: tiles in raster order, coding tree blocks in raster
	// order inside each tile.
	ts := 0
	clear(&enc.tile_ts0)
	for ty in 0 ..< rows {
		for tx in 0 ..< cols {
			append(&enc.tile_ts0, ts)
			for cy in enc.tile_yb[ty] ..< enc.tile_yb[ty + 1] {
				for cx in enc.tile_xb[tx] ..< enc.tile_xb[tx + 1] {
					rs := cy * enc.ctu_cols + cx
					enc.rs_of[ts] = i32(rs)
					enc.ts_of[rs] = i32(ts)
					ts += 1
				}
			}
		}
	}
	append(&enc.tile_ts0, ts)

	// The parallel search's per-tile scratch, preallocated here once: each
	// tile's trial stream buffer holds its coding tree blocks' worst-case
	// trial bins (16 KB per block covers the PCM raw-bits case).
	enc.tile_tasks = make([]Tile_Task, cols * rows, enc.allocator)
	for tile in 0 ..< cols * rows {
		task := &enc.tile_tasks[tile]
		tx, ty := tile % cols, tile / cols
		ctbs := (enc.tile_xb[tx + 1] - enc.tile_xb[tx]) * (enc.tile_yb[ty + 1] - enc.tile_yb[ty])
		task.enc = enc
		task.ctu_total = enc.ctu_cols * enc.ctu_rows
		task.trial_buf = make([dynamic]u8, 0, ctbs << 14, enc.allocator)
	}
}

// ---------------------------------------------------------------------------
// Parallel tile search. A tile's decisions read only their own tile (6.4.1
// never reaches across tiles and the reference gathering clips at tile
// edges), so the caller's Work_Pool runs the tiles concurrently over the
// shared disjoint reconstruction and CU grid. Each tile's scratch is
// preallocated at init and each item writes only its own tile. The trial
// stream mirrors the contexts of the tile's real substream (9.3.2.2), which
// keeps every decision independent of the pool.
// ---------------------------------------------------------------------------

// Tile_Task is one tile's search request: its inputs and its preallocated
// trial stream scratch (never grown in the hot path).
Tile_Task :: struct {
	enc:       ^Encoder,
	ctu_total: int,
	trial_buf: [dynamic]u8,
}

@(private)
tile_search_range :: proc(data: rawptr, first, end: int) {
	tasks := (cast(^[]Tile_Task)data)^
	for &task, local in tasks[first:end] {
		i := first + local
		enc := task.enc

		// Each tile owns its persistent trial buffer. The stack clone carries
		// that descriptor while shared reconstruction and CU writes stay in
		// this tile's disjoint region; no range callback allocates scratch.
		e := enc^
		clear(&task.trial_buf)
		e.trial_buf = task.trial_buf
		common.init_bit_writer(&e.trial_buf)
		e.trial_writer = common.Bit_Writer {
			buf = &e.trial_buf,
		}
		init_contexts(&e.trial_cabac, u32(enc.qp), enc.slice_type)
		e.trial_cabac.transform_skip_enabled = enc.config.tskip
		e.trial_cabac.stream = &e.trial_writer
		cabac_start(&e.trial_cabac)

		for ts in int(enc.tile_ts0[i]) ..< int(enc.tile_ts0[i + 1]) {
			rs := int(e.rs_of[ts])
			x := rs % enc.ctu_cols * CTU_WIDTH
			y := rs / enc.ctu_cols * CTU_WIDTH
			if enc.config.rqt {
				decide_cu(true, &e, x, y, 0, &e.trial_cabac)
			} else {
				decide_cu(false, &e, x, y, 0, &e.trial_cabac)
			}
			cabac_bin_trm(&e.trial_cabac, ts == task.ctu_total - 1 ? 1 : 0)
		}
	}
}

@(private)
search_tiles :: proc(enc: ^Encoder) {
	tasks := enc.tile_tasks
	pool := enc.config.pool

	if pool == nil {
		tile_search_range(&tasks, 0, len(tasks))
		return
	}

	pool.run(pool, len(tasks), tile_search_range, &tasks)
}

// tile_at_ts is the tile number of the coding tree block at tile-scan index ts.
@(private)
tile_at_ts :: proc(enc: ^Encoder, ts: int) -> int {
	rs := int(enc.rs_of[ts])
	return(
		int(enc.trow_of[rs / enc.ctu_cols]) * enc.config.tiles_cols +
		int(enc.tcol_of[rs % enc.ctu_cols]) \
	)
}

// same_tile is 6.4.1's tile identity for neighbour availability: a block in a
// different tile is never available.
same_tile :: proc(enc: ^Encoder, x1, y1, x2, y2: int) -> bool {
	if !enc.tiles_on do return true
	return(
		enc.tcol_of[x1 >> 6] == enc.tcol_of[x2 >> 6] &&
		enc.trow_of[y1 >> 6] == enc.trow_of[y2 >> 6] \
	)
}

// tile_bounds is the tile of (x, y) in luma pixels: left, right, top, bottom.
tile_bounds :: proc(enc: ^Encoder, x, y: int) -> (int, int, int, int) {
	if !enc.tiles_on do return 0, enc.coded_width, 0, enc.coded_height

	tx := enc.tcol_of[x >> 6]
	ty := enc.trow_of[y >> 6]

	return enc.tile_xb[tx] * CTU_WIDTH,
		enc.tile_xb[tx + 1] * CTU_WIDTH,
		enc.tile_yb[ty] * CTU_WIDTH,
		enc.tile_yb[ty + 1] * CTU_WIDTH
}

// ---------------------------------------------------------------------------
// SEI (D.2): a recovery point on every IRAP picture (prefix) and a
// decoded-picture-hash suffix (checksum) per picture.
// ---------------------------------------------------------------------------

// sei_checksum is D.2's checksum hash (the compChecksum formula of the
// reference implementation): a position-masked sum of the sample bytes,
// accumulating the high byte too at more than 8 bits.
sei_checksum :: proc(plane: Plane(Sample), w, h: int, deep: bool) -> u32 {
	checksum: u32

	for y in 0 ..< h {
		for x in 0 ..< w {
			v := at(plane, x, y)
			mask := u32((x & 0xff) ~ (y & 0xff) ~ (x >> 8) ~ (y >> 8))

			checksum += u32(v & 0xff) ~ mask
			if deep do checksum += u32(v >> 8) ~ mask
		}
	}

	return checksum
}

// sei_message writes one D.1 message (escaped payload type and size) into
// the payload buffer.
sei_message :: proc(w: ^common.Bit_Writer, payload_type, payload_size: int) {
	t, s := payload_type, payload_size

	for t >= 255 {
		common.write_bits(w, 0xff, 8)
		t -= 255
	}
	common.write_bits(w, u32(t), 8)

	for s >= 255 {
		common.write_bits(w, 0xff, 8)
		s -= 255
	}
	common.write_bits(w, u32(s), 8)
}

// append_sei_nal writes a complete prefix or suffix SEI NAL unit.
append_sei_nal :: proc(enc: ^Encoder, out: ^[dynamic]u8, nal_type: Nal_Type) {
	header := nal_header(enc, nal_type)
	common.append_nal_annex_b(out, header[:], enc.sei[:])
	clear(&enc.sei)
}

// append_recovery_point writes the D.2.7 recovery point prefix SEI for an
// IRAP picture: decoding may start here and run forward exactly.
append_recovery_point :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	w := &enc.sei_writer
	common.init_bit_writer(&enc.sei)
	enc.sei_writer = common.Bit_Writer {
		buf = &enc.sei,
	}

	sei_message(w, 6, 1)
	common.write_se(w, 0) // recovery_poc_cnt
	common.write_bits(w, 1, 1) // exact_match_flag
	common.write_bits(w, 0, 1) // broken_link_flag
	// The payload fills its size byte with zero padding (the reference
	// framing aligns each payload without a stop bit); the message's own
	// trailing comes after.
	common.write_bits(w, 0, 5)
	common.write_rbsp_trailing_bits(w)

	append_sei_nal(enc, out, .PREFIX_SEI_NUT)
}

// append_picture_hash writes the D.2 decoded-picture-hash suffix SEI: the
// checksum of every component of the filtered reconstruction.
append_picture_hash :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	w := &enc.sei_writer
	common.init_bit_writer(&enc.sei)
	enc.sei_writer = common.Bit_Writer {
		buf = &enc.sei,
	}

	// D.2 hashes the signalled picture dimensions (the SPS size before the
	// conformance window), over the filtered reconstruction.
	deep := enc.bit_depth > 8
	sw, sh := chroma_sub(enc.config.chroma_format)
	cw, ch := enc.coded_width / sw, enc.coded_height / sh

	hashes: [3]u32
	hashes[0] = sei_checksum(enc.rec.y, enc.coded_width, enc.coded_height, deep)
	components := has_chroma(enc) ? 3 : 1
	if has_chroma(enc) {
		hashes[1] = sei_checksum(enc.rec.u, cw, ch, deep)
		hashes[2] = sei_checksum(enc.rec.v, cw, ch, deep)
	}

	sei_message(w, 132, 1 + components * 4)
	common.write_bits(w, 2, 8) // hash_type: checksum

	for h in hashes[:components] {
		common.write_bits(w, h, 32) // big-endian per D.2
	}
	common.write_rbsp_trailing_bits(w)

	append_sei_nal(enc, out, .SUFFIX_SEI_NUT)
}

// ---------------------------------------------------------------------------
// Rate control: one QP decision per picture and one update per picture.
// ---------------------------------------------------------------------------

// rc_picture_start picks the picture's slice QP. CRF is constant quality;
// ABR/CBR fold the accumulated rate error (and the CBR buffer pressure) into
// the running adjustment. The QP feeds the slice header as slice_qp_delta and
// the RD lambda of the picture.
rc_picture_start :: proc(enc: ^Encoder, slice_type: Slice_Type) {
	qp := f64(enc.rc.base_qp)

	// Constant_QP is exactly the base QP (the historical bitstream). CRF is
	// constant quality: the anchor plus the frame-type offsets. ABR/CBR are
	// pure rate — the feedback owns the picture QP.
	if enc.rc.mode == .CRF do qp += rc_type_offset(slice_type)
	if enc.rc.mode == .ABR || enc.rc.mode == .CBR {
		qp += enc.rc.qp_adjust

		// The one-pass prior: a picture at the base QP costs roughly 0.30
		// bits per pixel (scaled across the QP ladder), so the first
		// pictures start near the steady QP instead of spending the clip's
		// budget before the feedback has data.
		if enc.rc.coded < 3 && enc.rc.target_bits > 0 {
			expected := f64(enc.width) * f64(enc.height) * 0.30
			qp += 6.0 * math.log2(expected / enc.rc.target_bits)
		}
	}

	enc.qp = clamp(i32(qp + 0.5), -6 * i32(enc.bit_depth - 8), 51)
	enc.lambda = qd_lambda(enc.qp) * enc.dist_scale
	enc.rc.last_offset = f64(enc.qp) - f64(enc.qp_base)
}

// rc_picture_end feeds the controller with the picture's actual size in bits.
rc_picture_end :: proc(enc: ^Encoder, bits: int) {
	rc := &enc.rc
	rc.total_bits += i64(bits)
	rc.coded += 1

	if rc.mode != .ABR && rc.mode != .CBR do return

	target := f64(rc.coded) * rc.target_bits
	if target <= 0 do return

	// The proportional term is a Newton step on the rate curve anchored at
	// the operating point: six QP steps per rate doubling from the offset the
	// pictures actually used (anchoring at the base QP instead transients on
	// content that changes cost quickly). The integral term keeps long-drift
	// errors paid back.
	ratio := f64(rc.total_bits) / target
	dev := (f64(rc.total_bits) - target) / rc.target_bits
	adjust := rc.last_offset + 6.0 * math.log2(ratio) + 0.5 * dev

	if rc.mode == .CBR && rc.buffer_size > 0 {
		// Leaky bucket: the buffer drains at the target rate.
		rc.buffer += f64(bits) - rc.target_bits
		rc.buffer = clamp(rc.buffer, -rc.buffer_size, rc.buffer_size)
		adjust += 4.0 * rc.buffer / rc.buffer_size
	}

	// The adjustment is recomputed from the cumulative rate every picture
	// (no integrator state to wind up); the picture QP clamp bounds it. It
	// also moves at most four steps per picture: the rate curve is steep on
	// hard content and an un-slewed response limit-cycles around the target.
	// The slew is asymmetric: the response may move fast toward a higher QP
	// (the safe direction for the budget) and drifts only slowly toward a
	// lower one, so a run of easy pictures cannot walk the QP down into the
	// next hard one.
	next := clamp(adjust, -24.0, 32.0)
	rc.qp_adjust = clamp(next, rc.qp_adjust - 2.0, rc.qp_adjust + 6.0)
}

// write_hrd is E.2.2 (the field order of the decoder's parse_hrd): one NAL
// CPB describing the rate-control buffer at a constant picture rate.
write_hrd :: proc(enc: ^Encoder, w: ^common.Bit_Writer) {
	// nal_hrd_parameters_present_flag, vcl_hrd_parameters_present_flag
	common.write_bits(w, 1, 1)
	common.write_bits(w, 0, 1)

	// sub_pic_hrd_params_present_flag
	common.write_bits(w, 0, 1)

	// BitRate = (v + 1) << (6 + bit_rate_scale); CpbSize = (v + 1) <<
	// (4 + cpb_size_scale). Pick the scales that keep the values closest.
	br_scale, br_value := hrd_scale_value(enc.config.bitrate, 6)
	cpb_scale, cpb_value := hrd_scale_value(
		enc.config.rc_buffer > 0 ? enc.config.rc_buffer : enc.config.bitrate,
		4,
	)

	common.write_bits(w, u32(br_scale), 4) // bit_rate_scale
	common.write_bits(w, u32(cpb_scale), 4) // cpb_size_scale

	// initial_cpb_removal_delay_length_minus1, au_cpb_removal_delay_length_minus1,
	// dpb_output_delay_length_minus1
	common.write_bits(w, 23, 5)
	common.write_bits(w, 23, 5)
	common.write_bits(w, 23, 5)

	// One block per sub-layer (the VPS signals max_sub_layers_minus1 = 1):
	// a constant picture rate at one tick per picture sharing one CPB.
	for _ in 0 ..< 2 {
		common.write_bits(w, 1, 1) // fixed_pic_rate_general_flag
		common.write_ue(w, 0) // elemental_duration_in_tc_minus1
		common.write_ue(w, 0) // cpb_cnt_minus1

		// sub_layer_hrd: one CPB, no sub-picture parameters
		common.write_ue(w, u32(br_value)) // bit_rate_value_minus1
		common.write_ue(w, u32(cpb_value)) // cpb_size_value_minus1
		common.write_bits(w, 1, 1) // cbr_flag
	}
}

// hrd_scale_value splits a value into the HRD's (scale, value) pair:
// value = (out_value + 1) << (unit + out_scale), closest to `want`.
hrd_scale_value :: proc(want, unit: int) -> (int, int) {
	best_scale, best_value := 0, 0
	best_err := i64(1) << 62

	for s in 0 ..< 16 {
		div := i64(1) << uint(unit + s)
		v := (i64(want) + div / 2) / div - 1
		if v < 0 || v > 0x7ffffff do continue

		err := abs(i64(want) - (v + 1) * div)
		if err < best_err {
			best_scale, best_value, best_err = s, int(v), err
		}
		if err == 0 do break
	}

	return best_scale, best_value
}

// append_mastering_display writes the D.2.28 mastering display colour volume
// prefix SEI: three primaries, the white point and the luminance range.
append_mastering_display :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	w := &enc.sei_writer
	common.init_bit_writer(&enc.sei)
	enc.sei_writer = common.Bit_Writer {
		buf = &enc.sei,
	}
	m := &enc.config.mastering

	sei_message(w, 137, 24)
	for i in 0 ..< 3 {
		common.write_bits(w, u32(m.primaries_x[i]), 16)
		common.write_bits(w, u32(m.primaries_y[i]), 16)
	}
	common.write_bits(w, u32(m.white_x), 16)
	common.write_bits(w, u32(m.white_y), 16)
	common.write_bits(w, m.max_luma, 32)
	common.write_bits(w, m.min_luma, 32)
	common.write_rbsp_trailing_bits(w)

	append_sei_nal(enc, out, .PREFIX_SEI_NUT)
}

// write_vui is E.2: timing information from the configured frame rate and
// the bitstream restriction block, in the exact order parse_vui expects.
write_vui :: proc(enc: ^Encoder, w: ^common.Bit_Writer) {
	// aspect_ratio_info_present_flag
	common.write_bits(w, 0, 1)
	// overscan_info_present_flag
	common.write_bits(w, 0, 1)
	// video_signal_type_present_flag
	if enc.config.colour_primaries != 0 {
		common.write_bits(w, 1, 1)
		common.write_bits(w, 5, 3) // video_format: unspecified
		common.write_bits(w, enc.config.full_range ? 1 : 0, 1)
		common.write_bits(w, 1, 1) // colour_description_present_flag
		common.write_bits(w, u32(enc.config.colour_primaries), 8)
		common.write_bits(w, u32(enc.config.transfer), 8)
		common.write_bits(w, u32(enc.config.matrix_coeffs), 8)
	} else {
		common.write_bits(w, 0, 1)
	}
	// chroma_loc_info_present_flag
	common.write_bits(w, 0, 1)
	// neutral_chroma_indication_flag, field_seq_flag,
	// frame_field_info_present_flag
	common.write_bits(w, 0, 3)
	// default_display_window_flag
	common.write_bits(w, 0, 1)

	// vui_timing_info_present_flag
	if enc.config.fps_num > 0 && enc.config.fps_den > 0 {
		common.write_bits(w, 1, 1)
		common.write_bits(w, u32(enc.config.fps_den), 32) // num_units_in_tick
		common.write_bits(w, u32(enc.config.fps_num), 32) // time_scale
		common.write_bits(w, 0, 1) // poc_proportional_to_timing_flag
		// vui_hrd_parameters_present_flag
		if enc.config.hrd && enc.config.bitrate > 0 {
			common.write_bits(w, 1, 1)
			write_hrd(enc, w)
		} else {
			common.write_bits(w, 0, 1)
		}
	} else {
		common.write_bits(w, 0, 1)
	}

	// bitstream_restriction_flag
	common.write_bits(w, 1, 1)
	common.write_bits(w, 1, 1) // tiles_fixed_structure_flag
	common.write_bits(w, 1, 1) // motion_vectors_over_pic_boundaries_flag
	common.write_bits(w, 0, 1) // restricted_ref_pic_lists_flag
	common.write_ue(w, 0) // min_spatial_segmentation_idc
	common.write_ue(w, 2) // max_bytes_per_pic_denom
	common.write_ue(w, 1) // max_bits_per_min_cu_denom
	common.write_ue(w, 16) // log2_max_mv_length_horizontal
	common.write_ue(w, 16) // log2_max_mv_length_vertical
}

// Copy the visible part of the reconstructed picture into the display-order
// output buffer at its picture order count slot. An 8-bit picture writes its
// historical one byte per sample; a deeper one writes 16-bit little-endian
// samples, matching ffmpeg's yuv420pNle raw output.
capture_rec_frame :: proc(enc: ^Encoder, poc: int) {
	deep := enc.bit_depth > 8
	samples := enc.width * enc.height
	if has_chroma(enc) {
		fsw, fsh := chroma_sub(enc.config.chroma_format)
		samples += 2 * (enc.width / fsw) * (enc.height / fsh)
	}
	frame_size := deep ? samples * 2 : samples
	need := (poc + 1) * frame_size
	if len(enc.rec_display) < need do resize(&enc.rec_display, need)

	idx := poc * frame_size

	put :: #force_inline proc(buf: ^[dynamic]u8, idx: ^int, v: Sample, deep: bool) {
		if deep {
			buf[idx^] = u8(v & 0xff)
			buf[idx^ + 1] = u8(v >> 8)
			idx^ += 2
		} else {
			buf[idx^] = u8(v)
			idx^ += 1
		}
	}

	for row in 0 ..< enc.height {
		for col in 0 ..< enc.width do put(&enc.rec_display, &idx, at(enc.rec.y, col, row), deep)
	}
	if has_chroma(enc) {
		sw, sh := chroma_sub(enc.config.chroma_format)
		ch, cw := enc.height / sh, enc.width / sw
		for row in 0 ..< ch {
			for col in 0 ..< cw do put(&enc.rec_display, &idx, at(enc.rec.u, col, row), deep)
		}
		for row in 0 ..< ch {
			for col in 0 ..< cw do put(&enc.rec_display, &idx, at(enc.rec.v, col, row), deep)
		}
	}
}

// Copy one padded frame into another (both allocated with the same coded size).
copy_frame :: proc(dst, src: ^Frame) {
	copy(dst.y.data, src.y.data)
	copy(dst.u.data, src.u.data)
	copy(dst.v.data, src.v.data)
}

// Store the current reconstruction as reference 0 of list 0 at picture order
// count `poc` and shift the past pictures down one slot (the no-B I/P path).
// `min(config.refs, poc + 1)` slots end up holding `poc, poc-1, ...`.
promote_rec :: proc(enc: ^Encoder, poc: int) {
	avail := min(enc.config.refs, poc + 1)
	for r := avail - 1; r >= 1; r -= 1 {
		copy_frame(&enc.refs[0][r], &enc.refs[0][r - 1])
		enc.ref_poc[0][r] = enc.ref_poc[0][r - 1]
	}
	copy_frame(&enc.refs[0][0], &enc.rec)
	enc.ref_poc[0][0] = i32(poc)
}

// Advance the low-delay reference history after coding picture `poc`. The next
// picture sees list 0 = [poc] and list 1 = [poc, previous]; after the first
// picture (t=1) there is no t-2, so the decoder's list construction repeats t-1
// and both list-1 entries name it.
promote_lowdelay :: proc(enc: ^Encoder, poc: int) {
	if poc == 0 {
		copy_frame(&enc.refs[0][0], &enc.rec)
		copy_frame(&enc.refs[1][0], &enc.refs[0][0])
		copy_frame(&enc.refs[1][1], &enc.refs[0][0])
		enc.ref_poc[0][0] = 0
		enc.ref_poc[1][0] = 0
		enc.ref_poc[1][1] = 0
		return
	}
	// The old t-1 becomes t-2; the new reconstruction becomes t-1 in both lists.
	copy_frame(&enc.refs[1][1], &enc.refs[0][0])
	copy_frame(&enc.refs[0][0], &enc.rec)
	copy_frame(&enc.refs[1][0], &enc.refs[0][0])
	enc.ref_poc[1][1] = enc.ref_poc[0][0]
	enc.ref_poc[0][0] = i32(poc)
	enc.ref_poc[1][0] = i32(poc)
}

// Encode one picture. The source is already in enc.source and the reference
// picture order counts in enc.ref_poc; the caller owns parameter sets and
// reference-slot promotion.
encode_picture :: proc(enc: ^Encoder, poc: int, slice_type: Slice_Type, out: ^[dynamic]u8) {
	mem.set(raw_data(enc.cu.cells), 0, len(enc.cu.cells) * size_of(Cu_Info))
	enc.slice_type = slice_type
	enc.cur_poc = i32(poc)
	if !enc.config.hierarchical {
		l0 := 0
		if slice_type == .P {
			// Every earlier display picture is a candidate past reference.
			l0 = min(enc.config.refs, poc)
		} else if slice_type == .B {
			l0 = 1
		}
		enc.refs_active = {l0, slice_type == .B ? 2 : 0}
	}
	// Resolve the picture this slice's collocated fields name before any
	// candidate derivation runs.
	resolve_temporal(enc)
	analyze_weights(enc)

	// Rate control decides this picture's slice QP before any of its bytes
	// are written: the slice header's slice_qp_delta and the search's lambda
	// and quantizer must agree.
	rc_picture_start(enc, slice_type)
	out_bytes_start := len(out^)

	// Without substreams the slice header and payload share the RBSP buffer as
	// before. With them the payload is built first in its own buffer so the
	// header can carry the substream sizes.
	substreams := enc.tiles_on || enc.config.wpp
	if !substreams do write_slice_header(enc, true, poc, slice_type)

	buf := substreams ? &enc.payload : &enc.rbsp
	if substreams do clear(buf)

	enc.payload_writer = common.Bit_Writer {
		buf = buf,
	}
	writer := &enc.payload_writer
	enc.cabac.stream = writer
	init_contexts(&enc.cabac, u32(enc.qp), enc.slice_type)
	enc.cabac.transform_skip_enabled = enc.config.tskip
	cabac_start(&enc.cabac)
	enc.entry_count = 0
	enc.substream_start = 0
	enc.wpp_has_saved = false

	// Both passes traverse the picture in 6.5.1 tile-scan order (the identity
	// with tiles off).
	ctu_total := enc.ctu_cols * enc.ctu_rows

	// Search pass. With tiles each tile gets a trial stream mirroring its
	// substream and the tiles search in parallel when threads allow.
	if enc.tiles_on {
		search_tiles(enc)
	} else {
		common.init_bit_writer(&enc.trial_buf)
		enc.trial_writer = common.Bit_Writer {
			buf = &enc.trial_buf,
		}
		enc.trial_cabac = enc.cabac
		enc.trial_cabac.stream = &enc.trial_writer
		init_contexts(&enc.trial_cabac, u32(enc.qp), enc.slice_type)
		cabac_start(&enc.trial_cabac)

		for ts in 0 ..< ctu_total {
			x := ts % enc.ctu_cols * CTU_WIDTH
			y := ts / enc.ctu_cols * CTU_WIDTH
			if enc.config.rqt {
				decide_cu(true, enc, x, y, 0, &enc.trial_cabac)
			} else {
				decide_cu(false, enc, x, y, 0, &enc.trial_cabac)
			}
			cabac_bin_trm(&enc.trial_cabac, ts == ctu_total - 1 ? 1 : 0)
		}
	}

	// SAO is decided from the deblocked picture. The search pass has left the
	// full reconstruction in enc.rec, so snapshot it and filter the snapshot;
	// enc.rec must stay unfiltered until the bitstream pass has replayed the
	// reconstruction with unfiltered neighbours.
	if enc.config.sao {
		copy(enc.sao_src.y.data, enc.rec.y.data)
		copy(enc.sao_src.u.data, enc.rec.u.data)
		copy(enc.sao_src.v.data, enc.rec.v.data)
		if enc.config.deblock do deblock_frame_on(enc, &enc.sao_src)
		sao_decide_frame(enc)
	}

	// Bitstream pass.
	for ts in 0 ..< ctu_total {
		rs := enc.tiles_on ? int(enc.rs_of[ts]) : ts
		ctx := rs % enc.ctu_cols
		cty := rs / enc.ctu_cols
		x := ctx * CTU_WIDTH
		y := cty * CTU_WIDTH
		if enc.config.sao do write_sao(enc, ctx, cty, &enc.cabac)
		if enc.config.rqt {
			write_cu(true, enc, x, y, 0, &enc.cabac)
		} else {
			write_cu(false, enc, x, y, 0, &enc.cabac)
		}

		// 9.3.1: the row above hands its state after the second coding
		// tree block down to the next row.
		if enc.config.wpp && ctx == 1 && cty + 1 < enc.ctu_rows {
			enc.wpp_saved = enc.cabac.ctx
			enc.wpp_has_saved = true
		}

		last := ts == ctu_total - 1
		// A substream covers one tile (or one wavefront row): its last block
		// codes the end-of-slice flag as zero and then terminates the
		// substream with end_of_sub_stream_one_bit.
		end_of_tile := enc.tiles_on && !last && tile_at_ts(enc, ts) != tile_at_ts(enc, ts + 1)
		end_of_row := enc.config.wpp && ctx == enc.ctu_cols - 1 && cty + 1 < enc.ctu_rows

		if end_of_tile || end_of_row {
			cabac_bin_trm(&enc.cabac, 0)
			cabac_bin_trm(&enc.cabac, 1)
			next_substream(enc, end_of_row)
		} else {
			cabac_bin_trm(&enc.cabac, last ? 1 : 0)
		}
	}

	// The CU grid now holds the picture's final motion field; file it for the
	// temporal predictor of later pictures.
	capture_col_motion(enc, i32(poc))

	// Flush and RBSP alignment.
	cabac_finish(&enc.cabac)
	common.write_bits(writer, 1, 1)
	common.write_align_zero(writer)

	if substreams {
		// The payload is complete, so its substream sizes can now be written
		// into the header.
		write_slice_header(enc, true, poc, slice_type)

		off := len(enc.rbsp)
		resize(&enc.rbsp, off + len(enc.payload))
		copy(enc.rbsp[off:], enc.payload[:])
	}

	nal_type := slice_type == .I ? Nal_Type.IDR_W_RADL : Nal_Type.TRAIL_R

	// D.2 ordering: the recovery point prefix SEI comes before the VCL NAL
	// of its picture and the picture hash suffix after it.
	if enc.config.sei_recovery && slice_type == .I do append_recovery_point(enc, out)
	if enc.config.sei_mastering && slice_type == .I do append_mastering_display(enc, out)
	if enc.config.layer == .Base_With_Alpha && slice_type == .I do append_alpha_info(enc, out)

	header := nal_header(enc, nal_type)
	common.append_nal_annex_b(out, header[:], enc.rbsp[:])

	// In-loop deblocking runs after the whole picture is reconstructed, so
	// intra prediction saw unfiltered neighbours exactly like the decoder.
	if enc.config.deblock do deblock_frame(enc)

	// SAO is applied in place to the deblocked picture, reading the pre-SAO
	// neighbours from enc.sao_src (the decoder's one-CTB lag is irrelevant
	// because every edge read comes from pre-SAO samples).
	if enc.config.sao do sao_apply_frame(enc)

	// The suffix picture hash covers the filtered reconstruction, so it is
	// emitted once the in-loop filters have run (D.2 orders it after the
	// picture's VCL NAL, which only needs the byte order, not the timing).
	if enc.config.sei_hash do append_picture_hash(enc, out)

	rc_picture_end(enc, (len(out^) - out_bytes_start) * 8)


	if enc.config.capture_rec {
		display := poc
		if enc.config.idr_period > 0 && !enc.config.hierarchical && !enc.config.b_frames do display = enc.frame_index
		capture_rec_frame(enc, display)
	}
}

@(private)
reset_lowdelay_gop :: proc(enc: ^Encoder) {
	// Samples and motion buffers remain allocated. Only admitted reference
	// history is cleared; promotion after this IDR writes the new reference 0.
	enc.poc_origin = enc.frame_index
	enc.ref_poc = {}
	enc.refs_active = {}
	enc.col = nil
	enc.tmvp = false
	enc.col_ring_valid = {}
	enc.col_ring_poc = {}
	enc.col_next = 0
}

// Encode one input frame. With B frames the coding order is the display order:
// frame 0 is I and every later frame is B, predicting from list 0 = [t-1] and
// list 1 = [t-1, t-2]. Without B frames this is the historical I/P path
// (frame_index is the picture order count unless idr_period restarts a GOP).
encode_frame :: proc(
	enc: ^Encoder,
	y, u, v: [^]Sample,
	y_stride, c_stride: int,
	out: ^[dynamic]u8,
) {
	if enc.config.hierarchical {
		encode_frame_hier(enc, y, u, v, y_stride, c_stride, out)
		return
	}

	periodic := !enc.config.b_frames && enc.config.idr_period > 0
	idr := periodic && enc.frame_index % enc.config.idr_period == 0
	if enc.frame_index == 0 || idr do write_parameter_sets(enc, out)

	set_source(enc, y, u, v, y_stride, c_stride)

	if !enc.config.b_frames {
		if idr do reset_lowdelay_gop(enc)
		poc := periodic ? enc.frame_index - enc.poc_origin : enc.frame_index
		slice_type :=
			enc.frame_index == 0 || idr || enc.config.intra_only_i_slices ? Slice_Type.I : Slice_Type.P
		encode_picture(enc, poc, slice_type, out)
		promote_rec(enc, poc)
		enc.frame_index += 1
		return
	}

	slice_type := enc.frame_index == 0 ? Slice_Type.I : Slice_Type.B
	encode_picture(enc, enc.frame_index, slice_type, out)
	promote_lowdelay(enc, enc.frame_index)
	enc.frame_index += 1
}

// Low-delay B needs no reordering: every input frame is coded as it arrives, so
// there is never a buffered picture left to flush. The hierarchical GOP does
// buffer, so it emits its partial final group here.
flush_encoder :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	if enc.config.hierarchical do flush_hier(enc, out)
}

package h265_decoder

// ---------------------------------------------------------------------------
// Parameter sets (7.3.2) and their shared syntax structures. Ported from
// gen2brain/h265 hevc/headers.go (MIT); oxideav-h265 src/{vps,sps,pps,
// sequence,vui,hrd,scaling_list}.rs are the per-file cross-references.
//
// One deliberate deviation from the Go source: HRD common information is
// inherited by a VPS HRD entry whose cprms_present_flag is zero (7.4.3.1)
// rather than dropped, which the Go version gets wrong and which desynchronises
// the bit reader on such streams.
// ---------------------------------------------------------------------------

MAX_SUB_LAYERS :: 7
MAX_SHORT_TERM_RPS :: 64
MAX_LONG_TERM_REF_PICS :: 32
MAX_REF_PICS_PER_RPS :: 16
MAX_TILE_COLUMNS :: 22
MAX_TILE_ROWS :: 20
MAX_PIC_SIZE :: 16384
MAX_CHROMA_QP_OFFSETS :: 6
MIN_CTB_LOG2_SIZE_Y :: 4
MAX_CTB_LOG2_SIZE_Y :: 6
MAX_REFS :: 16

Profile_Tier_Level :: struct {
	profile_space:                                u8,
	tier_flag:                                    bool,
	profile_idc:                                  u8,
	level_idc:                                    u8,
	compat_flags:                                 u32,
	progressive_source, interlaced_source:        bool,
	non_packed_constraint, frame_only_constraint: bool,
}

Short_Term_RPS :: struct {
	delta_poc_s0:        []i32,
	delta_poc_s1:        []i32,
	used_s0:             []bool,
	used_s1:             []bool,
	// The predictor's NumDeltaPocs, required by hardware slice descriptors.
	ref_delta_poc_count: u8,
}

short_term_rps_num_delta_pocs :: proc(rps: ^Short_Term_RPS) -> int {
	return len(rps.delta_poc_s0) + len(rps.delta_poc_s1)
}

destroy_short_term_rps :: proc(rps: ^Short_Term_RPS) {
	delete(rps.delta_poc_s0)
	delete(rps.delta_poc_s1)
	delete(rps.used_s0)
	delete(rps.used_s1)
	rps^ = {}
}

VPS :: struct {
	id:                    u8,
	max_layers_minus1:     u8,
	max_sub_layers_minus1: u8,
	temporal_id_nesting:   bool,
	ptl:                   Profile_Tier_Level,
	max_dec_pic_buffering: [MAX_SUB_LAYERS]u32,
	max_num_reorder_pics:  [MAX_SUB_LAYERS]u32,
	max_latency_increase:  [MAX_SUB_LAYERS]u32,
	// F.7.4.3.1.1: the nuh_layer_id of an auxiliary alpha layer (AuxId 1)
	// that the VPS extension declares; 0 without one.
	alpha_layer_id:        u8,
}

SPS :: struct {
	vps_id:                         u8,
	max_sub_layers_minus1:          u8,
	temporal_id_nesting:            bool,
	ptl:                            Profile_Tier_Level,
	id:                             u32,
	chroma_format_idc:              u32,
	separate_colour_plane:          bool,
	sub_width_c:                    int,
	sub_height_c:                   int,
	pic_width_in_luma_samples:      u32,
	pic_height_in_luma_samples:     u32,
	conf_win_left:                  u32,
	conf_win_right:                 u32,
	conf_win_top:                   u32,
	conf_win_bottom:                u32,
	bit_depth_luma:                 u8,
	bit_depth_chroma:               u8,

	// E.3.1: the color description of the sequence, unspecified unless the
	// video usability information says otherwise.
	colour_primaries:               u16,
	transfer_char:                  u16,
	matrix_coeffs:                  u16,
	full_range:                     bool,
	log2_max_poc_lsb:               u8,
	max_dec_pic_buffering:          u32,
	max_num_reorder_pics:           u32,
	max_latency_increase:           u32,
	max_dec_pic_buffering_by_layer: [MAX_SUB_LAYERS]u32,
	max_num_reorder_pics_by_layer:  [MAX_SUB_LAYERS]u32,
	max_latency_increase_by_layer:  [MAX_SUB_LAYERS]u32,
	min_cb_log2_size_y:             u8,
	ctb_log2_size_y:                u8,
	ctb_size_y:                     u32,
	min_tb_log2_size_y:             u8,
	max_tb_log2_size_y:             u8,
	max_tr_hier_inter:              u32,
	max_tr_hier_intra:              u32,
	pic_width_in_ctbs:              u32,
	pic_height_in_ctbs:             u32,
	scaling_list_enabled:           bool,
	scaling_list:                   Scaling_List,
	amp_enabled:                    bool,
	sao_enabled:                    bool,
	pcm_enabled:                    bool,
	pcm_bit_depth_luma:             u8,
	pcm_bit_depth_chroma:           u8,
	log2_min_pcm_cb_size:           u8,
	log2_max_pcm_cb_size:           u8,
	pcm_loop_filter_disabled:       bool,
	st_rps:                         [dynamic]Short_Term_RPS,
	long_term_ref_pics_present:     bool,
	lt_ref_pic_poc_lsb:             []u32,
	used_by_curr_pic_lt:            []bool,
	temporal_mvp_enabled:           bool,
	strong_intra_smoothing:         bool,
	transform_skip_rotation:        bool,
	transform_skip_context:         bool,
	implicit_rdpcm:                 bool,
	explicit_rdpcm:                 bool,
	extended_precision:             bool,
	intra_smoothing_disabled:       bool,
	high_precision_offsets:         bool,
	persistent_rice_adaptation:     bool,
	cabac_bypass_alignment:         bool,
}

destroy_sps :: proc(s: ^SPS) {
	for i in 0 ..< len(s.st_rps) do destroy_short_term_rps(&s.st_rps[i])
	delete(s.st_rps)
	delete(s.lt_ref_pic_poc_lsb)
	delete(s.used_by_curr_pic_lt)
	s^ = {}
}

PPS :: struct {
	id:                               u32,
	sps_id:                           u32,
	dependent_slice_segments_enabled: bool,
	output_flag_present:              bool,
	num_extra_slice_header_bits:      u8,
	sign_data_hiding_enabled:         bool,
	cabac_init_present:               bool,
	num_ref_idx_l0_default_active:    u32,
	num_ref_idx_l1_default_active:    u32,
	init_qp:                          i32,
	constrained_intra_pred:           bool,
	transform_skip_enabled:           bool,
	cu_qp_delta_enabled:              bool,
	diff_cu_qp_delta_depth:           u32,
	cb_qp_offset:                     i32,
	cr_qp_offset:                     i32,
	slice_chroma_qp_offsets:          bool,
	weighted_pred:                    bool,
	weighted_bipred:                  bool,
	transquant_bypass:                bool,
	tiles_enabled:                    bool,
	entropy_coding_sync:              bool,
	num_tile_columns:                 int,
	num_tile_rows:                    int,
	uniform_spacing:                  bool,
	column_width_minus1:              []u32,
	row_height_minus1:                []u32,
	loop_filter_across_tiles:         bool,
	col_widths_in_ctbs:               []u32,
	row_heights_in_ctbs:              []u32,
	loop_filter_across_slices:        bool,
	deblocking_control_present:       bool,
	deblocking_override:              bool,
	deblocking_disabled:              bool,
	beta_offset_div2:                 i32,
	tc_offset_div2:                   i32,
	scaling_list_present:             bool,
	scaling_list:                     Scaling_List,
	lists_modification_present:       bool,
	log2_parallel_merge_level:        u32,
	slice_header_extension_present:   bool,
	log2_max_transform_skip_size:     u32,
	cross_component_prediction:       bool,
	chroma_qp_offset_list_present:    bool,
	diff_cu_chroma_qp_offset_depth:   u32,
	chroma_qp_offset_list_len:        u32,
	cb_qp_offset_list:                [MAX_CHROMA_QP_OFFSETS]i32,
	cr_qp_offset_list:                [MAX_CHROMA_QP_OFFSETS]i32,
	log2_sao_offset_scale_luma:       u32,
	log2_sao_offset_scale_chroma:     u32,
}

destroy_pps :: proc(p: ^PPS) {
	delete(p.column_width_minus1)
	delete(p.row_height_minus1)
	delete(p.col_widths_in_ctbs)
	delete(p.row_heights_in_ctbs)
	p^ = {}
}

Hrd_Common_Info :: struct {
	nal_hrd:         bool,
	vcl_hrd:         bool,
	sub_pic_present: bool,
}

parse_profile_tier_level :: proc(
	c: ^Get_Bits,
	profile_present: bool,
	max_sub_layers_minus1: u8,
) -> Profile_Tier_Level {
	p: Profile_Tier_Level

	if profile_present {
		p.profile_space = u8(get_bits_bits(c, 2))
		p.tier_flag = get_bits_bit(c) != 0
		p.profile_idc = u8(get_bits_bits(c, 5))
		p.compat_flags = get_bits_bits(c, 32)
		p.progressive_source = get_bits_bit(c) != 0
		p.interlaced_source = get_bits_bit(c) != 0
		p.non_packed_constraint = get_bits_bit(c) != 0
		p.frame_only_constraint = get_bits_bit(c) != 0
		get_bits_skip(c, 44)
	}

	p.level_idc = u8(get_bits_bits(c, 8))

	if max_sub_layers_minus1 == 0 do return p

	profile_present_sub, level_present_sub: [MAX_SUB_LAYERS]bool

	for i in 0 ..< int(max_sub_layers_minus1) {
		profile_present_sub[i] = get_bits_bit(c) != 0
		level_present_sub[i] = get_bits_bit(c) != 0
	}

	for _ in 0 ..< 8 - int(max_sub_layers_minus1) {
		get_bits_bits(c, 2)
	}

	for i in 0 ..< int(max_sub_layers_minus1) {
		if profile_present_sub[i] do get_bits_skip(c, 88)
		if level_present_sub[i] do get_bits_bits(c, 8)
	}

	return p
}

parse_sub_layer_hrd :: proc(c: ^Get_Bits, cpb_cnt: int, sub_pic_present: bool) {
	for _ in 0 ..< cpb_cnt {
		get_bits_ue(c)
		get_bits_ue(c)

		if sub_pic_present {
			get_bits_ue(c)
			get_bits_ue(c)
		}

		get_bits_bit(c)
	}
}

parse_hrd :: proc(
	c: ^Get_Bits,
	common_inf_present: bool,
	prev: Hrd_Common_Info,
	max_sub_layers_minus1: u8,
) -> (
	info: Hrd_Common_Info,
	ok: bool,
) {
	if common_inf_present {
		info.nal_hrd = get_bits_bit(c) != 0
		info.vcl_hrd = get_bits_bit(c) != 0

		if info.nal_hrd || info.vcl_hrd {
			info.sub_pic_present = get_bits_bit(c) != 0

			if info.sub_pic_present {
				get_bits_bits(c, 8)
				get_bits_bits(c, 5)
				get_bits_bit(c)
				get_bits_bits(c, 5)
			}

			get_bits_bits(c, 4)
			get_bits_bits(c, 4)

			if info.sub_pic_present do get_bits_bits(c, 4)

			get_bits_bits(c, 5)
			get_bits_bits(c, 5)
			get_bits_bits(c, 5)
		}
	} else {
		info = prev
	}

	for _ in 0 ..< int(max_sub_layers_minus1) + 1 {
		fixed_rate := get_bits_bit(c) != 0
		if !fixed_rate do fixed_rate = get_bits_bit(c) != 0

		low_delay := false

		if fixed_rate {
			get_bits_ue(c)
		} else {
			low_delay = get_bits_bit(c) != 0
		}

		cpb_cnt := 1
		if !low_delay {
			n := get_bits_ue(c)
			if n > 31 do return
			cpb_cnt = int(n) + 1
		}

		if info.nal_hrd do parse_sub_layer_hrd(c, cpb_cnt, info.sub_pic_present)
		if info.vcl_hrd do parse_sub_layer_hrd(c, cpb_cnt, info.sub_pic_present)
	}

	return info, true
}

parse_vui :: proc(c: ^Get_Bits, s: ^SPS, max_sub_layers_minus1: u8) -> bool {
	if get_bits_bit(c) != 0 {
		if get_bits_bits(c, 8) == 255 {
			get_bits_bits(c, 16)
			get_bits_bits(c, 16)
		}
	}

	if get_bits_bit(c) != 0 do get_bits_bit(c)

	// E.2.1 video_signal_type. The color description defaults to unspecified,
	// which a consumer can fall back to when it has none of its own.
	if get_bits_bit(c) != 0 {
		get_bits_bits(c, 3)
		s.full_range = get_bits_bit(c) != 0

		if get_bits_bit(c) != 0 {
			s.colour_primaries = u16(get_bits_bits(c, 8))
			s.transfer_char = u16(get_bits_bits(c, 8))
			s.matrix_coeffs = u16(get_bits_bits(c, 8))
		}
	}

	if get_bits_bit(c) != 0 {
		get_bits_ue(c)
		get_bits_ue(c)
	}

	get_bits_bit(c)
	get_bits_bit(c)
	get_bits_bit(c)

	if get_bits_bit(c) != 0 {
		get_bits_ue(c)
		get_bits_ue(c)
		get_bits_ue(c)
		get_bits_ue(c)
	}

	if get_bits_bit(c) != 0 {
		get_bits_bits(c, 32)
		get_bits_bits(c, 32)

		if get_bits_bit(c) != 0 do get_bits_ue(c)

		if get_bits_bit(c) != 0 {
			_, ok := parse_hrd(c, true, {}, max_sub_layers_minus1)
			if !ok do return false
		}
	}

	if get_bits_bit(c) != 0 {
		get_bits_bit(c)
		get_bits_bit(c)
		get_bits_bit(c)
		get_bits_ue(c)
		get_bits_ue(c)
		get_bits_ue(c)
		get_bits_ue(c)
		get_bits_ue(c)
	}

	return true
}

check_trailing :: proc(c: ^Get_Bits, extension: bool) -> bool {
	if c.err do return false

	if !extension && get_bits_more_rbsp_data(c) do return false

	return true
}

// 7.4.3.1/7.4.3.2.1 require reorder <= buffering-minus-one and
// nondecreasing sublayer bounds. A.4.2 limits MaxDpbSize to at most 16.
@(private)
parameter_set_ordering_valid :: proc(buffering, reorder: []u32) -> bool {
	if len(buffering) == 0 || len(buffering) != len(reorder) do return false
	for i in 0 ..< len(buffering) {
		if buffering[i] >= MAX_REFS || reorder[i] > buffering[i] do return false
		if i > 0 && (buffering[i] < buffering[i - 1] || reorder[i] < reorder[i - 1]) do return false
	}
	return true
}

parse_vps :: proc(rbsp: []u8) -> (v: VPS, ok: bool) {
	c: Get_Bits
	get_bits_init(&c, rbsp)

	v.id = u8(get_bits_bits(&c, 4))
	base_layer_internal := get_bits_bit(&c) != 0
	get_bits_bit(&c) // vps_base_layer_available_flag
	v.max_layers_minus1 = u8(get_bits_bits(&c, 6))
	v.max_sub_layers_minus1 = u8(get_bits_bits(&c, 3))

	if v.max_sub_layers_minus1 > MAX_SUB_LAYERS - 1 do return

	v.temporal_id_nesting = get_bits_bit(&c) != 0

	if get_bits_bits(&c, 16) != 0xffff do return

	v.ptl = parse_profile_tier_level(&c, true, v.max_sub_layers_minus1)

	start := int(v.max_sub_layers_minus1)
	if get_bits_bit(&c) != 0 do start = 0

	for i in start ..= int(v.max_sub_layers_minus1) {
		v.max_dec_pic_buffering[i] = get_bits_ue(&c)
		v.max_num_reorder_pics[i] = get_bits_ue(&c)
		v.max_latency_increase[i] = get_bits_ue(&c)
	}
	for i in 0 ..< start {
		v.max_dec_pic_buffering[i] = v.max_dec_pic_buffering[start]
		v.max_num_reorder_pics[i] = v.max_num_reorder_pics[start]
		v.max_latency_increase[i] = v.max_latency_increase[start]
	}
	if c.err ||
	   !parameter_set_ordering_valid(
			   v.max_dec_pic_buffering[:int(v.max_sub_layers_minus1) + 1],
			   v.max_num_reorder_pics[:int(v.max_sub_layers_minus1) + 1],
		   ) {
		return
	}

	max_layer_id := int(get_bits_bits(&c, 6))

	num_layer_sets_minus1 := get_bits_ue(&c)
	if num_layer_sets_minus1 > 1023 do return

	for _ in 0 ..< int(num_layer_sets_minus1) {
		get_bits_skip(&c, max_layer_id + 1)
	}

	if get_bits_bit(&c) != 0 {
		get_bits_bits(&c, 32)
		get_bits_bits(&c, 32)

		if get_bits_bit(&c) != 0 do get_bits_ue(&c)

		num_hrd := get_bits_ue(&c)
		if num_hrd > 1024 do return

		common: Hrd_Common_Info

		for i in 0 ..< int(num_hrd) {
			get_bits_ue(&c)

			common_inf_present := true
			if i > 0 do common_inf_present = get_bits_bit(&c) != 0

			next_common, hrd_ok := parse_hrd(
				&c,
				common_inf_present,
				common,
				v.max_sub_layers_minus1,
			)
			if !hrd_ok do return
			common = next_common
		}
	}

	extension := get_bits_bit(&c) != 0
	if extension && v.max_layers_minus1 > 0 {
		e := c
		v.alpha_layer_id = vps_alpha_layer(&e, &v, base_layer_internal)
	}

	if !check_trailing(&c, extension) do return

	return v, true
}

// The start of vps_extension (F.7.3.2.1.1) up to the layers' dimension
// ids: which layer, if any, is auxiliary with AuxId 1 (alpha). Anything
// unreadable leaves 0, so the stream decodes as a single layer.
@(private)
vps_alpha_layer :: proc(c: ^Get_Bits, v: ^VPS, base_layer_internal: bool) -> u8 {
	AUX_ID :: 3 // scalability_mask_flag index of AuxId (table F.1)
	for get_bits_pos(c) & 7 != 0 do get_bits_bit(c) // vps_extension_alignment_bit_equal_to_one
	if base_layer_internal do parse_profile_tier_level(c, false, v.max_sub_layers_minus1)
	splitting := get_bits_bit(c) != 0
	types, aux_dimension := 0, -1
	for i in 0 ..< 16 {
		if get_bits_bit(c) == 0 do continue
		if i == AUX_ID do aux_dimension = types
		types += 1
	}
	if aux_dimension < 0 || types > 16 do return 0
	lengths: [16]int
	for j in 0 ..< types - (splitting ? 1 : 0) do lengths[j] = int(get_bits_bits(c, 3)) + 1
	if splitting {
		// The last dimension takes the remaining bits of the 6-bit layer id.
		used := 0
		for j in 0 ..< types - 1 do used += lengths[j]
		lengths[types - 1] = 6 - used
	}
	id_present := get_bits_bit(c) != 0
	for i in 1 ..= int(v.max_layers_minus1) {
		layer_id := u32(i)
		if id_present do layer_id = get_bits_bits(c, 6)
		aux: u32
		if splitting {
			offset := 0
			for j in 0 ..< aux_dimension do offset += lengths[j]
			aux = layer_id >> uint(offset) & (1 << uint(lengths[aux_dimension]) - 1)
		} else {
			for j in 0 ..< types {
				d := get_bits_bits(c, lengths[j])
				if j == aux_dimension do aux = d
			}
		}
		if c.err do return 0
		if aux == 1 do return u8(layer_id)
	}
	return 0
}

parse_sps :: proc(rbsp: []u8) -> (s: SPS, ok: bool) {
	c: Get_Bits
	get_bits_init(&c, rbsp)

	defer {
		if !ok do destroy_sps(&s)
	}

	// E.3.1 infers all three as unspecified when the sequence does not say.
	s.colour_primaries = 2
	s.transfer_char = 2
	s.matrix_coeffs = 2

	s.vps_id = u8(get_bits_bits(&c, 4))
	s.max_sub_layers_minus1 = u8(get_bits_bits(&c, 3))

	if s.max_sub_layers_minus1 > MAX_SUB_LAYERS - 1 do return

	s.temporal_id_nesting = get_bits_bit(&c) != 0
	s.ptl = parse_profile_tier_level(&c, true, s.max_sub_layers_minus1)

	s.id = get_bits_ue(&c)
	if s.id > 15 do return

	s.chroma_format_idc = get_bits_ue(&c)
	if s.chroma_format_idc > 3 do return

	if s.chroma_format_idc == 3 {
		s.separate_colour_plane = get_bits_bit(&c) != 0
	}

	s.sub_width_c, s.sub_height_c = 1, 1

	switch s.chroma_format_idc {
	case 1:
		s.sub_width_c, s.sub_height_c = 2, 2
	case 2:
		s.sub_width_c = 2
	}

	s.pic_width_in_luma_samples = get_bits_ue(&c)
	s.pic_height_in_luma_samples = get_bits_ue(&c)

	if s.pic_width_in_luma_samples == 0 ||
	   s.pic_height_in_luma_samples == 0 ||
	   s.pic_width_in_luma_samples > MAX_PIC_SIZE ||
	   s.pic_height_in_luma_samples > MAX_PIC_SIZE {
		return
	}

	if get_bits_bit(&c) != 0 {
		s.conf_win_left = get_bits_ue(&c)
		s.conf_win_right = get_bits_ue(&c)
		s.conf_win_top = get_bits_ue(&c)
		s.conf_win_bottom = get_bits_ue(&c)
	}
	_, _, crop_ok := sps_cropped_dimensions(&s)
	if c.err || !crop_ok do return

	bit_depth_luma_minus8 := get_bits_ue(&c)
	bit_depth_chroma_minus8 := get_bits_ue(&c)

	if bit_depth_luma_minus8 > 8 || bit_depth_chroma_minus8 > 8 do return

	s.bit_depth_luma = 8 + u8(bit_depth_luma_minus8)
	s.bit_depth_chroma = 8 + u8(bit_depth_chroma_minus8)

	log2_max_poc_lsb_minus4 := get_bits_ue(&c)
	if log2_max_poc_lsb_minus4 > 12 do return

	s.log2_max_poc_lsb = 4 + u8(log2_max_poc_lsb_minus4)

	start := int(s.max_sub_layers_minus1)
	if get_bits_bit(&c) != 0 do start = 0

	for i in start ..= int(s.max_sub_layers_minus1) {
		s.max_dec_pic_buffering = get_bits_ue(&c)
		s.max_num_reorder_pics = get_bits_ue(&c)
		s.max_latency_increase = get_bits_ue(&c)
		s.max_dec_pic_buffering_by_layer[i] = s.max_dec_pic_buffering
		s.max_num_reorder_pics_by_layer[i] = s.max_num_reorder_pics
		s.max_latency_increase_by_layer[i] = s.max_latency_increase
	}
	for i in 0 ..< start {
		s.max_dec_pic_buffering_by_layer[i] = s.max_dec_pic_buffering_by_layer[start]
		s.max_num_reorder_pics_by_layer[i] = s.max_num_reorder_pics_by_layer[start]
		s.max_latency_increase_by_layer[i] = s.max_latency_increase_by_layer[start]
	}
	if c.err ||
	   !parameter_set_ordering_valid(
			   s.max_dec_pic_buffering_by_layer[:int(s.max_sub_layers_minus1) + 1],
			   s.max_num_reorder_pics_by_layer[:int(s.max_sub_layers_minus1) + 1],
		   ) {
		return
	}

	log2_min_cb_size_minus3 := get_bits_ue(&c)
	log2_diff_max_min_cb_size := get_bits_ue(&c)

	if log2_min_cb_size_minus3 > 3 || log2_diff_max_min_cb_size > 3 do return

	s.min_cb_log2_size_y = 3 + u8(log2_min_cb_size_minus3)
	s.ctb_log2_size_y = s.min_cb_log2_size_y + u8(log2_diff_max_min_cb_size)

	if s.ctb_log2_size_y < MIN_CTB_LOG2_SIZE_Y || s.ctb_log2_size_y > MAX_CTB_LOG2_SIZE_Y do return

	// 7.4.3.2: both dimensions are an integer multiple of MinCbSizeY. Without
	// it a coding unit at the edge extends past the picture, and the block
	// bookkeeping is sized for what the picture holds.
	if mask := u32(1) << s.min_cb_log2_size_y - 1;
	   s.pic_width_in_luma_samples & mask != 0 || s.pic_height_in_luma_samples & mask != 0 {
		return
	}

	s.ctb_size_y = 1 << s.ctb_log2_size_y
	s.pic_width_in_ctbs = ceil_div(s.pic_width_in_luma_samples, s.ctb_size_y)
	s.pic_height_in_ctbs = ceil_div(s.pic_height_in_luma_samples, s.ctb_size_y)

	log2_min_tb_size_minus2 := get_bits_ue(&c)
	log2_diff_max_min_tb_size := get_bits_ue(&c)

	if log2_min_tb_size_minus2 > 3 || log2_diff_max_min_tb_size > 3 do return

	s.min_tb_log2_size_y = 2 + u8(log2_min_tb_size_minus2)
	s.max_tb_log2_size_y = s.min_tb_log2_size_y + u8(log2_diff_max_min_tb_size)

	// 7.4.3.2.1 holds MaxTbLog2SizeY to Min(CtbLog2SizeY, 5), which is 32.
	if s.min_tb_log2_size_y >= s.min_cb_log2_size_y ||
	   s.max_tb_log2_size_y > min(s.ctb_log2_size_y, 5) {
		return
	}

	s.max_tr_hier_inter = get_bits_ue(&c)
	s.max_tr_hier_intra = get_bits_ue(&c)

	s.scaling_list = default_scaling_list()

	s.scaling_list_enabled = get_bits_bit(&c) != 0
	if s.scaling_list_enabled && get_bits_bit(&c) != 0 {
		if !parse_scaling_list_data(&c, &s.scaling_list) do return
	}

	s.amp_enabled = get_bits_bit(&c) != 0
	s.sao_enabled = get_bits_bit(&c) != 0

	s.log2_min_pcm_cb_size, s.log2_max_pcm_cb_size = 8, 0
	s.pcm_bit_depth_luma, s.pcm_bit_depth_chroma = s.bit_depth_luma, s.bit_depth_chroma

	s.pcm_enabled = get_bits_bit(&c) != 0
	if s.pcm_enabled {
		s.pcm_bit_depth_luma = 1 + u8(get_bits_bits(&c, 4))
		s.pcm_bit_depth_chroma = 1 + u8(get_bits_bits(&c, 4))

		if s.pcm_bit_depth_luma > s.bit_depth_luma || s.pcm_bit_depth_chroma > s.bit_depth_chroma do return

		log2_min_pcm_cb_size_minus3 := get_bits_ue(&c)
		log2_diff_max_min_pcm_cb_size := get_bits_ue(&c)

		if log2_min_pcm_cb_size_minus3 > 2 || log2_diff_max_min_pcm_cb_size > 2 do return

		s.log2_min_pcm_cb_size = 3 + u8(log2_min_pcm_cb_size_minus3)
		s.log2_max_pcm_cb_size = s.log2_min_pcm_cb_size + u8(log2_diff_max_min_pcm_cb_size)
		s.pcm_loop_filter_disabled = get_bits_bit(&c) != 0
	}

	num_st_rps := get_bits_ue(&c)
	if num_st_rps > MAX_SHORT_TERM_RPS do return

	s.st_rps = make([dynamic]Short_Term_RPS, 0, num_st_rps)

	for i in 0 ..< int(num_st_rps) {
		rps, good := parse_short_term_rps(&c, i, int(num_st_rps), s.st_rps[:])
		if !good do return

		append(&s.st_rps, rps)
	}

	s.long_term_ref_pics_present = get_bits_bit(&c) != 0
	if s.long_term_ref_pics_present {
		n := get_bits_ue(&c)
		if n > MAX_LONG_TERM_REF_PICS do return

		s.lt_ref_pic_poc_lsb = make([]u32, n)
		s.used_by_curr_pic_lt = make([]bool, n)

		for i in 0 ..< int(n) {
			s.lt_ref_pic_poc_lsb[i] = get_bits_bits(&c, int(s.log2_max_poc_lsb))
			s.used_by_curr_pic_lt[i] = get_bits_bit(&c) != 0
		}
	}

	s.temporal_mvp_enabled = get_bits_bit(&c) != 0
	s.strong_intra_smoothing = get_bits_bit(&c) != 0

	if get_bits_bit(&c) != 0 {
		if !parse_vui(&c, &s, s.max_sub_layers_minus1) do return
	}

	unparsed := false

	if get_bits_bit(&c) != 0 {
		range_extension := get_bits_bit(&c) != 0
		multilayer_extension := get_bits_bit(&c) != 0
		extension_3d := get_bits_bit(&c) != 0
		scc_extension := get_bits_bit(&c) != 0
		unparsed = get_bits_bits(&c, 4) != 0

		if range_extension {
			s.transform_skip_rotation = get_bits_bit(&c) != 0
			s.transform_skip_context = get_bits_bit(&c) != 0
			s.implicit_rdpcm = get_bits_bit(&c) != 0
			s.explicit_rdpcm = get_bits_bit(&c) != 0
			s.extended_precision = get_bits_bit(&c) != 0
			s.intra_smoothing_disabled = get_bits_bit(&c) != 0
			s.high_precision_offsets = get_bits_bit(&c) != 0
			s.persistent_rice_adaptation = get_bits_bit(&c) != 0
			s.cabac_bypass_alignment = get_bits_bit(&c) != 0
		}

		// cabac_bypass_alignment is parsed so the extension stays in step, but
		// is not applied. A stream that uses it is refused rather than decoded
		// into something that merely looks plausible.
		if s.cabac_bypass_alignment do return

		if multilayer_extension || extension_3d || scc_extension do return
	}

	if !check_trailing(&c, unparsed) do return

	return s, true
}

parse_pps :: proc(rbsp: []u8) -> (p: PPS, ok: bool) {
	c: Get_Bits
	get_bits_init(&c, rbsp)

	defer {
		if !ok do destroy_pps(&p)
	}

	p.id = get_bits_ue(&c)
	p.sps_id = get_bits_ue(&c)

	if p.id > 63 || p.sps_id > 15 do return

	p.dependent_slice_segments_enabled = get_bits_bit(&c) != 0
	p.output_flag_present = get_bits_bit(&c) != 0
	p.num_extra_slice_header_bits = u8(get_bits_bits(&c, 3))
	p.sign_data_hiding_enabled = get_bits_bit(&c) != 0
	p.cabac_init_present = get_bits_bit(&c) != 0
	p.num_ref_idx_l0_default_active = get_bits_ue(&c) + 1
	p.num_ref_idx_l1_default_active = get_bits_ue(&c) + 1

	if p.num_ref_idx_l0_default_active > 16 || p.num_ref_idx_l1_default_active > 16 do return

	p.init_qp = get_bits_se(&c) + 26
	p.constrained_intra_pred = get_bits_bit(&c) != 0
	p.transform_skip_enabled = get_bits_bit(&c) != 0

	p.cu_qp_delta_enabled = get_bits_bit(&c) != 0
	if p.cu_qp_delta_enabled do p.diff_cu_qp_delta_depth = get_bits_ue(&c)

	p.cb_qp_offset = get_bits_se(&c)
	p.cr_qp_offset = get_bits_se(&c)

	if p.cb_qp_offset < -12 || p.cb_qp_offset > 12 || p.cr_qp_offset < -12 || p.cr_qp_offset > 12 do return

	p.slice_chroma_qp_offsets = get_bits_bit(&c) != 0
	p.weighted_pred = get_bits_bit(&c) != 0
	p.weighted_bipred = get_bits_bit(&c) != 0
	p.transquant_bypass = get_bits_bit(&c) != 0
	p.tiles_enabled = get_bits_bit(&c) != 0
	p.entropy_coding_sync = get_bits_bit(&c) != 0

	p.log2_max_transform_skip_size = 2
	p.num_tile_columns, p.num_tile_rows = 1, 1
	p.uniform_spacing = true
	p.loop_filter_across_tiles = true

	if p.tiles_enabled {
		p.num_tile_columns = int(get_bits_ue(&c)) + 1
		p.num_tile_rows = int(get_bits_ue(&c)) + 1

		if p.num_tile_columns > MAX_TILE_COLUMNS || p.num_tile_rows > MAX_TILE_ROWS do return

		p.uniform_spacing = get_bits_bit(&c) != 0
		if !p.uniform_spacing {
			p.column_width_minus1 = make([]u32, p.num_tile_columns - 1)
			for i in 0 ..< len(p.column_width_minus1) {
				p.column_width_minus1[i] = get_bits_ue(&c)
			}

			p.row_height_minus1 = make([]u32, p.num_tile_rows - 1)
			for i in 0 ..< len(p.row_height_minus1) {
				p.row_height_minus1[i] = get_bits_ue(&c)
			}
		}

		p.loop_filter_across_tiles = get_bits_bit(&c) != 0
	}

	p.loop_filter_across_slices = get_bits_bit(&c) != 0

	p.deblocking_control_present = get_bits_bit(&c) != 0
	if p.deblocking_control_present {
		p.deblocking_override = get_bits_bit(&c) != 0
		p.deblocking_disabled = get_bits_bit(&c) != 0

		if !p.deblocking_disabled {
			p.beta_offset_div2 = get_bits_se(&c)
			p.tc_offset_div2 = get_bits_se(&c)

			if p.beta_offset_div2 < -6 ||
			   p.beta_offset_div2 > 6 ||
			   p.tc_offset_div2 < -6 ||
			   p.tc_offset_div2 > 6 {
				return
			}
		}
	}

	p.scaling_list = default_scaling_list()

	p.scaling_list_present = get_bits_bit(&c) != 0
	if p.scaling_list_present {
		if !parse_scaling_list_data(&c, &p.scaling_list) do return
	}

	p.lists_modification_present = get_bits_bit(&c) != 0
	p.log2_parallel_merge_level = get_bits_ue(&c) + 2
	p.slice_header_extension_present = get_bits_bit(&c) != 0

	unparsed := false

	if get_bits_bit(&c) != 0 {
		range_extension := get_bits_bit(&c) != 0
		multilayer_extension := get_bits_bit(&c) != 0
		extension_3d := get_bits_bit(&c) != 0
		scc_extension := get_bits_bit(&c) != 0
		unparsed = get_bits_bits(&c, 4) != 0

		if range_extension {
			if p.transform_skip_enabled do p.log2_max_transform_skip_size = get_bits_ue(&c) + 2

			p.cross_component_prediction = get_bits_bit(&c) != 0

			p.chroma_qp_offset_list_present = get_bits_bit(&c) != 0
			if p.chroma_qp_offset_list_present {
				p.diff_cu_chroma_qp_offset_depth = get_bits_ue(&c)
				p.chroma_qp_offset_list_len = get_bits_ue(&c) + 1

				if p.chroma_qp_offset_list_len > MAX_CHROMA_QP_OFFSETS do return

				for i in 0 ..< int(p.chroma_qp_offset_list_len) {
					p.cb_qp_offset_list[i] = get_bits_se(&c)
					p.cr_qp_offset_list[i] = get_bits_se(&c)
				}
			}

			p.log2_sao_offset_scale_luma = get_bits_ue(&c)
			p.log2_sao_offset_scale_chroma = get_bits_ue(&c)
		}

		// Parsed to keep the extension in step, but not applied.
		if p.cross_component_prediction do return

		if multilayer_extension || extension_3d || scc_extension do return
	}

	if !check_trailing(&c, unparsed) do return

	return p, true
}

pps_resolve_tile_geometry :: proc(p: ^PPS, s: ^SPS) -> bool {
	w, h := int(s.pic_width_in_ctbs), int(s.pic_height_in_ctbs)

	if !p.tiles_enabled {
		delete(p.col_widths_in_ctbs)
		delete(p.row_heights_in_ctbs)

		p.col_widths_in_ctbs = make([]u32, 1)
		p.col_widths_in_ctbs[0] = u32(w)
		p.row_heights_in_ctbs = make([]u32, 1)
		p.row_heights_in_ctbs[0] = u32(h)

		return true
	}

	if p.num_tile_columns > w || p.num_tile_rows > h do return false

	cols := make([]u32, p.num_tile_columns)
	rows := make([]u32, p.num_tile_rows)

	if p.uniform_spacing {
		for i in 0 ..< len(cols) {
			cols[i] = u32((i + 1) * w / p.num_tile_columns - i * w / p.num_tile_columns)
		}

		for i in 0 ..< len(rows) {
			rows[i] = u32((i + 1) * h / p.num_tile_rows - i * h / p.num_tile_rows)
		}
	} else {
		sum: u32

		for i in 0 ..< len(p.column_width_minus1) {
			cols[i] = p.column_width_minus1[i] + 1
			sum += cols[i]
		}

		if sum >= u32(w) {
			delete(cols)
			delete(rows)
			return false
		}

		cols[len(cols) - 1] = u32(w) - sum

		sum = 0

		for i in 0 ..< len(p.row_height_minus1) {
			rows[i] = p.row_height_minus1[i] + 1
			sum += rows[i]
		}

		if sum >= u32(h) {
			delete(cols)
			delete(rows)
			return false
		}

		rows[len(rows) - 1] = u32(h) - sum
	}

	// Geometry is resolved again for later slices and after an SPS change.
	// Publish only a valid replacement, retiring the previous owned arrays.
	delete(p.col_widths_in_ctbs)
	delete(p.row_heights_in_ctbs)
	p.col_widths_in_ctbs = cols
	p.row_heights_in_ctbs = rows

	return true
}

// 7.4.3.2.1 conformance-window units follow ChromaArrayType, including the
// inferred monochrome type for separate colour planes. Wide arithmetic keeps
// an overflowing crop sum or product from admitting an out-of-bounds view.
sps_cropped_dimensions :: proc(s: ^SPS) -> (width, height: u32, ok: bool) {
	if s == nil ||
	   s.chroma_format_idc > 3 ||
	   s.pic_width_in_luma_samples == 0 ||
	   s.pic_width_in_luma_samples > MAX_PIC_SIZE ||
	   s.pic_height_in_luma_samples == 0 ||
	   s.pic_height_in_luma_samples > MAX_PIC_SIZE {
		return
	}
	unit_x, unit_y: u64 = 1, 1
	switch sps_chroma_array_type(s) {
	case 1:
		unit_x, unit_y = 2, 2
	case 2:
		unit_x = 2
	}
	crop_width := (u64(s.conf_win_left) + u64(s.conf_win_right)) * unit_x
	crop_height := (u64(s.conf_win_top) + u64(s.conf_win_bottom)) * unit_y
	if crop_width >= u64(s.pic_width_in_luma_samples) || crop_height >= u64(s.pic_height_in_luma_samples) do return
	return s.pic_width_in_luma_samples - u32(crop_width),
		s.pic_height_in_luma_samples - u32(crop_height),
		true
}

sps_cropped_width :: proc(s: ^SPS) -> u32 {
	width, _, _ := sps_cropped_dimensions(s)
	return width
}

sps_cropped_height :: proc(s: ^SPS) -> u32 {
	_, height, _ := sps_cropped_dimensions(s)
	return height
}

// parse_short_term_rps is 7.3.7. In the inter-prediction branch `idx` is the
// index the set is being derived for and `num_st_rps` the number of sets that
// precede it; when they are equal the set is signalled in a slice header, so
// delta_idx_minus1 is present (7.4.7.1).
parse_short_term_rps :: proc(
	c: ^Get_Bits,
	idx, num_st_rps: int,
	prev: []Short_Term_RPS,
) -> (
	rps: Short_Term_RPS,
	ok: bool,
) {
	defer {
		if !ok do destroy_short_term_rps(&rps)
	}

	inter_pred := false
	if idx != 0 do inter_pred = get_bits_bit(c) != 0

	if inter_pred {
		delta_idx := 1
		if idx == num_st_rps do delta_idx = int(get_bits_ue(c)) + 1

		if delta_idx > idx do return

		ref := &prev[idx - delta_idx]

		sign := get_bits_bit(c) != 0

		abs_delta_rps_minus1 := get_bits_ue(c)
		if abs_delta_rps_minus1 >= 32768 do return

		delta_rps := i32(abs_delta_rps_minus1) + 1
		if sign do delta_rps = -delta_rps

		n := short_term_rps_num_delta_pocs(ref)
		rps.ref_delta_poc_count = u8(n)
		used := make([]bool, n + 1)
		use_delta := make([]bool, n + 1)

		defer {
			delete(used)
			delete(use_delta)
		}

		for j in 0 ..< n + 1 {
			used[j] = get_bits_bit(c) != 0

			use_delta[j] = true
			if !used[j] do use_delta[j] = get_bits_bit(c) != 0
		}

		num_neg, num_pos := len(ref.delta_poc_s0), len(ref.delta_poc_s1)

		d0: [dynamic]i32
		u0: [dynamic]bool
		d1: [dynamic]i32
		u1: [dynamic]bool

		for j := num_pos - 1; j >= 0; j -= 1 {
			if d := ref.delta_poc_s1[j] + delta_rps; d < 0 && use_delta[num_neg + j] {
				append(&d0, d)
				append(&u0, used[num_neg + j])
			}
		}

		if delta_rps < 0 && use_delta[n] {
			append(&d0, delta_rps)
			append(&u0, used[n])
		}

		for j in 0 ..< num_neg {
			if d := ref.delta_poc_s0[j] + delta_rps; d < 0 && use_delta[j] {
				append(&d0, d)
				append(&u0, used[j])
			}
		}

		for j := num_neg - 1; j >= 0; j -= 1 {
			if d := ref.delta_poc_s0[j] + delta_rps; d > 0 && use_delta[j] {
				append(&d1, d)
				append(&u1, used[j])
			}
		}

		if delta_rps > 0 && use_delta[n] {
			append(&d1, delta_rps)
			append(&u1, used[n])
		}

		for j in 0 ..< num_pos {
			if d := ref.delta_poc_s1[j] + delta_rps; d > 0 && use_delta[num_neg + j] {
				append(&d1, d)
				append(&u1, used[num_neg + j])
			}
		}

		rps.delta_poc_s0 = d0[:]
		rps.used_s0 = u0[:]
		rps.delta_poc_s1 = d1[:]
		rps.used_s1 = u1[:]

		return rps, true
	}

	num_neg := get_bits_ue(c)
	num_pos := get_bits_ue(c)

	if num_neg > MAX_REF_PICS_PER_RPS || num_pos > MAX_REF_PICS_PER_RPS do return

	rps.delta_poc_s0 = make([]i32, num_neg)
	rps.used_s0 = make([]bool, num_neg)

	poc: i32

	for i in 0 ..< int(num_neg) {
		d := get_bits_ue(c)
		if d >= 32768 do return

		poc -= i32(d) + 1
		rps.delta_poc_s0[i] = poc
		rps.used_s0[i] = get_bits_bit(c) != 0
	}

	rps.delta_poc_s1 = make([]i32, num_pos)
	rps.used_s1 = make([]bool, num_pos)

	poc = 0

	for i in 0 ..< int(num_pos) {
		d := get_bits_ue(c)
		if d >= 32768 do return

		poc += i32(d) + 1
		rps.delta_poc_s1[i] = poc
		rps.used_s1[i] = get_bits_bit(c) != 0
	}

	return rps, true
}

ceil_div :: proc(a, b: u32) -> u32 {
	return (a + b - 1) / b
}

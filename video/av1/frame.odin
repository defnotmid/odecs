package av1

// Frame headers (5.9, 6.8) and tile groups (5.11.1), with the reference
// state the headers depend on. Field names follow the specification (and
// so Vulkan's StdVideoDecodeAV1PictureInfo).

Frame_Type :: enum u8 {
	Key,
	Inter,
	Intra_Only,
	Switch,
}

Film_Grain :: struct {
	apply_grain:               bool,
	update_grain:              bool,
	grain_seed:                u16,
	film_grain_params_ref_idx: u8,
	num_y_points:              u8,
	point_y_value:             [14]u8,
	point_y_scaling:           [14]u8,
	chroma_scaling_from_luma:  bool,
	num_cb_points:             u8,
	point_cb_value:            [10]u8,
	point_cb_scaling:          [10]u8,
	num_cr_points:             u8,
	point_cr_value:            [10]u8,
	point_cr_scaling:          [10]u8,
	grain_scaling_minus_8:     u8,
	ar_coeff_lag:              u8,
	ar_coeffs_y_plus_128:      [24]u8,
	ar_coeffs_cb_plus_128:     [25]u8,
	ar_coeffs_cr_plus_128:     [25]u8,
	ar_coeff_shift_minus_6:    u8,
	grain_scale_shift:         u8,
	cb_mult, cb_luma_mult:     u8,
	cb_offset:                 u16,
	cr_mult, cr_luma_mult:     u8,
	cr_offset:                 u16,
	overlap_flag:              bool,
	clip_to_restricted_range:  bool,
}

Tile_Info :: struct {
	uniform_tile_spacing_flag: bool,
	tile_cols, tile_rows:      int,
	tile_cols_log2, tile_rows_log2: int,
	mi_col_starts:             [MAX_TILE_COLS + 1]u16,
	mi_row_starts:             [MAX_TILE_ROWS + 1]u16,
	width_in_sbs_minus_1:      [MAX_TILE_COLS]u16,
	height_in_sbs_minus_1:     [MAX_TILE_ROWS]u16,
	context_update_tile_id:    u16,
	tile_size_bytes:           int, // 1..4
}

Frame_Header :: struct {
	show_existing_frame:             bool,
	frame_to_show_map_idx:           u8,
	frame_type:                      Frame_Type,
	frame_is_intra:                  bool,
	show_frame, showable_frame:      bool,
	error_resilient_mode:            bool,
	disable_cdf_update:              bool,
	allow_screen_content_tools:      bool,
	force_integer_mv:                bool,
	current_frame_id:                u32,
	frame_size_override_flag:        bool,
	order_hint:                      u8,
	primary_ref_frame:               u8,
	buffer_removal_time_present_flag: bool,
	refresh_frame_flags:             u8,
	// Size (5.9.5-5.9.9).
	frame_width, frame_height:       int,
	upscaled_width:                  int,
	render_width, render_height:     int,
	render_and_frame_size_different: bool,
	use_superres:                    bool,
	coded_denom:                     u8,
	mi_cols, mi_rows:                int,
	allow_intrabc:                   bool,
	frame_refs_short_signaling:      bool,
	ref_frame_idx:                   [REFS_PER_FRAME]u8,
	expected_frame_id:               [REFS_PER_FRAME]u32,
	allow_high_precision_mv:         bool,
	is_filter_switchable:            bool,
	interpolation_filter:            u8, // 0..3, 4 when switchable
	is_motion_mode_switchable:       bool,
	use_ref_frame_mvs:               bool,
	order_hints:                     [NUM_REF_FRAMES]u8, // by reference name
	ref_frame_sign_bias:             [NUM_REF_FRAMES]bool,
	disable_frame_end_update_cdf:    bool,
	tile_info:                       Tile_Info,
	// Quantization (5.9.12).
	base_q_idx:                      u8,
	delta_q_y_dc:                    i8,
	delta_q_u_dc, delta_q_u_ac:      i8,
	delta_q_v_dc, delta_q_v_ac:      i8,
	diff_uv_delta:                   bool,
	using_qmatrix:                   bool,
	qm_y, qm_u, qm_v:                u8,
	// Segmentation (5.9.14).
	segmentation_enabled:            bool,
	segmentation_update_map:         bool,
	segmentation_temporal_update:    bool,
	segmentation_update_data:        bool,
	feature_enabled:                 [MAX_SEGMENTS]u8, // bit j: feature j
	feature_data:                    [MAX_SEGMENTS][SEG_LVL_MAX]i16,
	delta_q_present:                 bool,
	delta_q_res:                     u8,
	delta_lf_present:                bool,
	delta_lf_res:                    u8,
	delta_lf_multi:                  bool,
	coded_lossless, all_lossless:    bool,
	// Loop filter (5.9.11).
	loop_filter_level:               [4]u8,
	loop_filter_sharpness:           u8,
	loop_filter_delta_enabled:       bool,
	loop_filter_delta_update:        bool,
	update_ref_delta:                u8, // bit i: ref delta i was coded
	loop_filter_ref_deltas:          [NUM_REF_FRAMES]i8,
	update_mode_delta:               u8,
	loop_filter_mode_deltas:         [2]i8,
	// CDEF (5.9.19).
	cdef_damping_minus_3:            u8,
	cdef_bits:                       u8,
	cdef_y_pri_strength:             [8]u8,
	cdef_y_sec_strength:             [8]u8,
	cdef_uv_pri_strength:            [8]u8,
	cdef_uv_sec_strength:            [8]u8,
	// Loop restoration (5.9.20): 0 none, 1 Wiener, 2 self-guided, 3 switchable.
	frame_restoration_type:          [3]u8,
	loop_restoration_size:           [3]u16,
	uses_lr, uses_chroma_lr:         bool,
	tx_mode:                         u8, // 0 ONLY_4X4, 1 LARGEST, 2 SELECT
	reference_select:                bool,
	skip_mode_present:               bool,
	skip_mode_frame:                 [2]u8,
	allow_warped_motion:             bool,
	reduced_tx_set:                  bool,
	gm_type:                         [NUM_REF_FRAMES]u8,
	gm_params:                       [NUM_REF_FRAMES][6]i32,
	film_grain:                      Film_Grain,
}

// What a reference slot keeps for later headers (7.20).
Ref_State :: struct {
	valid:                         bool,
	frame_id:                      u32,
	frame_type:                    Frame_Type,
	upscaled_width:                int,
	frame_width, frame_height:     int,
	render_width, render_height:   int,
	order_hint:                    u8,
	saved_order_hints:             [NUM_REF_FRAMES]u8,
	gm_params:                     [NUM_REF_FRAMES][6]i32,
	loop_filter_ref_deltas:        [NUM_REF_FRAMES]i8,
	loop_filter_mode_deltas:       [2]i8,
	feature_enabled:               [MAX_SEGMENTS]u8,
	feature_data:                  [MAX_SEGMENTS][SEG_LVL_MAX]i16,
	film_grain:                    Film_Grain,
}

// The decoder's view of a stream: its sequence header and reference slots.
Parser :: struct {
	sequence:      Sequence_Header,
	have_sequence: bool,
	refs:          [NUM_REF_FRAMES]Ref_State,
}

// One frame of a temporal unit: its header and where it lies in the data.
Frame :: struct {
	header:        Frame_Header,
	header_offset: int, // the frame header (or frame) OBU
	tiles:         []Tile, // a window into the caller's tile array
}

Tile :: struct {
	offset, size: u32,
}

WARPEDMODEL_PREC_BITS :: 16

// Parses one temporal unit: its frames in decode order (shown, hidden, or
// shown again with show_existing_frame), each frame's tiles appended to
// `tiles`, the reference state updated after each frame as decoding it
// would.
parse_temporal_unit :: proc(p: ^Parser, data: []u8, frames: ^[dynamic]Frame, tiles: ^[dynamic]Tile) -> Error {
	clear(frames)
	clear(tiles)
	pending := -1 // index in frames of a header awaiting its tile groups
	first_tile := 0
	for at := 0; at < len(data); {
		o, next := next_obu(data, at) or_return
		at = next
		#partial switch o.type {
		case .Sequence_Header:
			s := parse_sequence_header(o.payload) or_return
			if s.operating_point_idc[0] != 0 do return .Unsupported // scalable streams
			p.sequence, p.have_sequence = s, true
		case .Frame_Header, .Frame:
			if !p.have_sequence do return .Invalid_Data
			if pending >= 0 do continue // a redundant copy of the header
			b := Bits{data = o.payload}
			h := parse_frame_header(p, &b, o.temporal_id, o.spatial_id) or_return
			append(frames, Frame{header = h, header_offset = o.offset})
			if h.show_existing_frame {
				show_existing(p, &frames[len(frames) - 1].header)
				continue
			}
			pending = len(frames) - 1
			first_tile = len(tiles)
			if o.type == .Frame {
				// The tile group follows the header's byte alignment.
				header_bytes := (b.pos + 7) / 8
				done := parse_tile_group(&frames[pending].header, o.payload[header_bytes:], o.payload_offset + header_bytes, tiles) or_return
				if done {
					frames[pending].tiles = tiles[first_tile:]
					update_references(p, &frames[pending].header)
					pending = -1
				}
			}
		case .Tile_Group:
			if pending < 0 do return .Invalid_Data
			done := parse_tile_group(&frames[pending].header, o.payload, o.payload_offset, tiles) or_return
			if done {
				frames[pending].tiles = tiles[first_tile:]
				update_references(p, &frames[pending].header)
				pending = -1
			}
		case .Tile_List:
			return .Unsupported
		}
	}
	if pending >= 0 do return .Invalid_Data // a frame without all its tiles
	// tiles may have grown: re-slice every frame's window.
	at := 0
	for &fr in frames {
		n := len(fr.tiles)
		fr.tiles = tiles[at:][:n]
		at += n
	}
	return .None
}

// 7.21 for a shown existing key frame, then the refresh of all slots.
@(private)
show_existing :: proc(p: ^Parser, h: ^Frame_Header) {
	slot := p.refs[h.frame_to_show_map_idx]
	h.frame_type = slot.frame_type
	h.order_hint = slot.order_hint
	h.frame_width, h.frame_height, h.upscaled_width = slot.frame_width, slot.frame_height, slot.upscaled_width
	h.render_width, h.render_height = slot.render_width, slot.render_height
	h.film_grain = slot.film_grain
	if h.frame_type == .Key {
		h.refresh_frame_flags = 0xFF
		h.order_hints = slot.saved_order_hints
		h.gm_params = slot.gm_params
		h.loop_filter_ref_deltas = slot.loop_filter_ref_deltas
		h.loop_filter_mode_deltas = slot.loop_filter_mode_deltas
		h.feature_enabled, h.feature_data = slot.feature_enabled, slot.feature_data
		h.current_frame_id = slot.frame_id
		for &r in p.refs do r = slot
	}
}

// The reference frame update process (7.20) for the header's refresh.
update_references :: proc(p: ^Parser, h: ^Frame_Header) {
	for i in 0 ..< NUM_REF_FRAMES {
		if h.refresh_frame_flags >> uint(i) & 1 == 0 do continue
		p.refs[i] = {
			valid                   = true,
			frame_id                = h.current_frame_id,
			frame_type              = h.frame_type,
			upscaled_width          = h.upscaled_width,
			frame_width             = h.frame_width,
			frame_height            = h.frame_height,
			render_width            = h.render_width,
			render_height           = h.render_height,
			order_hint              = h.order_hint,
			saved_order_hints       = h.order_hints,
			gm_params               = h.gm_params,
			loop_filter_ref_deltas  = h.loop_filter_ref_deltas,
			loop_filter_mode_deltas = h.loop_filter_mode_deltas,
			feature_enabled         = h.feature_enabled,
			feature_data            = h.feature_data,
			film_grain              = h.film_grain,
		}
	}
}

@(private)
relative_dist :: proc(s: ^Sequence_Header, a, b: int) -> int {
	if !s.enable_order_hint do return 0
	diff := a - b
	m := 1 << uint(s.order_hint_bits - 1)
	return (diff & (m - 1)) - (diff & m)
}

// The uncompressed header (5.9.2).
@(private)
parse_frame_header :: proc(p: ^Parser, b: ^Bits, temporal_id, spatial_id: u8) -> (h: Frame_Header, err: Error) {
	s := &p.sequence
	id_len := 0
	if s.frame_id_numbers_present_flag do id_len = int(s.additional_frame_id_length_minus_1) + int(s.delta_frame_id_length_minus_2) + 3
	ALL_FRAMES :: 0xFF
	if s.reduced_still_picture_header {
		h.frame_type = .Key
		h.frame_is_intra = true
		h.show_frame = true
	} else {
		h.show_existing_frame = flag(b)
		if h.show_existing_frame {
			h.frame_to_show_map_idx = u8(f(b, 3))
			if s.decoder_model_info_present_flag && !s.equal_picture_interval do f(b, int(s.frame_presentation_time_length_minus_1) + 1)
			if s.frame_id_numbers_present_flag do f(b, id_len) // display_frame_id
			h.show_frame = true
			if !p.refs[h.frame_to_show_map_idx].valid do return h, .Invalid_Data
			return h, b.overrun ? .Invalid_Data : .None
		}
		h.frame_type = Frame_Type(f(b, 2))
		h.frame_is_intra = h.frame_type == .Intra_Only || h.frame_type == .Key
		h.show_frame = flag(b)
		if h.show_frame && s.decoder_model_info_present_flag && !s.equal_picture_interval do f(b, int(s.frame_presentation_time_length_minus_1) + 1)
		h.showable_frame = h.show_frame ? h.frame_type != .Key : flag(b)
		h.error_resilient_mode = h.frame_type == .Switch || (h.frame_type == .Key && h.show_frame) ? true : flag(b)
	}
	if h.frame_type == .Key && h.show_frame {
		for &r in p.refs {r.valid = false; r.order_hint = 0}
	}
	h.disable_cdf_update = flag(b)
	h.allow_screen_content_tools = s.seq_force_screen_content_tools == SELECT_SCREEN_CONTENT_TOOLS ? flag(b) : s.seq_force_screen_content_tools != 0
	if h.allow_screen_content_tools {
		h.force_integer_mv = s.seq_force_integer_mv == SELECT_INTEGER_MV ? flag(b) : s.seq_force_integer_mv != 0
	}
	if h.frame_is_intra do h.force_integer_mv = true
	if s.frame_id_numbers_present_flag {
		h.current_frame_id = f(b, id_len)
		mark_ref_frames(p, &h, id_len)
	}
	switch {
	case h.frame_type == .Switch:
		h.frame_size_override_flag = true
	case s.reduced_still_picture_header:
	case:
		h.frame_size_override_flag = flag(b)
	}
	h.order_hint = u8(f(b, s.order_hint_bits))
	h.primary_ref_frame = h.frame_is_intra || h.error_resilient_mode ? PRIMARY_REF_NONE : u8(f(b, 3))
	if s.decoder_model_info_present_flag {
		h.buffer_removal_time_present_flag = flag(b)
		if h.buffer_removal_time_present_flag {
			for op in 0 ..= int(s.operating_points_cnt_minus_1) {
				if !s.decoder_model_present_for_this_op[op] do continue
				idc := s.operating_point_idc[op]
				if idc == 0 || (idc >> temporal_id & 1 != 0 && idc >> (spatial_id + 8) & 1 != 0) do f(b, int(s.buffer_removal_time_length_minus_1) + 1)
			}
		}
	}
	h.refresh_frame_flags = h.frame_type == .Switch || (h.frame_type == .Key && h.show_frame) ? ALL_FRAMES : u8(f(b, 8))
	if (!h.frame_is_intra || h.refresh_frame_flags != ALL_FRAMES) && h.error_resilient_mode && s.enable_order_hint {
		for i in 0 ..< NUM_REF_FRAMES {
			hint := u8(f(b, s.order_hint_bits))
			if hint != p.refs[i].order_hint do p.refs[i] = {order_hint = hint} // invalid, with that hint
		}
	}
	if h.frame_is_intra {
		frame_size(s, &h, b)
		render_size(&h, b)
		if h.allow_screen_content_tools && h.upscaled_width == h.frame_width do h.allow_intrabc = flag(b)
	} else {
		if s.enable_order_hint {
			h.frame_refs_short_signaling = flag(b)
			if h.frame_refs_short_signaling {
				last, gold := u8(f(b, 3)), u8(f(b, 3))
				set_frame_refs(p, &h, last, gold)
			}
		}
		for i in 0 ..< REFS_PER_FRAME {
			if !h.frame_refs_short_signaling do h.ref_frame_idx[i] = u8(f(b, 3))
			if s.frame_id_numbers_present_flag {
				delta := f(b, int(s.delta_frame_id_length_minus_2) + 2) + 1
				h.expected_frame_id[i] = (h.current_frame_id + (u32(1) << uint(id_len)) - delta) % (u32(1) << uint(id_len))
			}
		}
		for i in 0 ..< REFS_PER_FRAME do if !p.refs[h.ref_frame_idx[i]].valid do return h, .Invalid_Data
		if h.frame_size_override_flag && !h.error_resilient_mode {
			found := false
			for i in 0 ..< REFS_PER_FRAME {
				if flag(b) {
					r := &p.refs[h.ref_frame_idx[i]]
					h.upscaled_width = r.upscaled_width
					h.frame_width = h.upscaled_width
					h.frame_height = r.frame_height
					h.render_width, h.render_height = r.render_width, r.render_height
					found = true
					break
				}
			}
			if !found {
				frame_size(s, &h, b)
				render_size(&h, b)
			} else {
				superres_params(s, &h, b)
				compute_image_size(&h)
			}
		} else {
			frame_size(s, &h, b)
			render_size(&h, b)
		}
		h.allow_high_precision_mv = h.force_integer_mv ? false : flag(b)
		h.is_filter_switchable = flag(b)
		h.interpolation_filter = h.is_filter_switchable ? 4 : u8(f(b, 2))
		h.is_motion_mode_switchable = flag(b)
		h.use_ref_frame_mvs = h.error_resilient_mode || !s.enable_ref_frame_mvs ? false : flag(b)
		for i in 0 ..< REFS_PER_FRAME {
			hint := p.refs[h.ref_frame_idx[i]].order_hint
			h.order_hints[LAST_FRAME + i] = hint
			h.ref_frame_sign_bias[LAST_FRAME + i] = s.enable_order_hint && relative_dist(s, int(hint), int(h.order_hint)) > 0
		}
	}
	h.disable_frame_end_update_cdf = s.reduced_still_picture_header || h.disable_cdf_update ? true : flag(b)
	// setup_past_independence or load_previous (6.8.2): the values that
	// later syntax predicts from.
	prev_gm: [NUM_REF_FRAMES][6]i32
	if h.primary_ref_frame == PRIMARY_REF_NONE {
		for ref in LAST_FRAME ..= ALTREF_FRAME do prev_gm[ref] = {0, 0, 1 << WARPEDMODEL_PREC_BITS, 0, 0, 1 << WARPEDMODEL_PREC_BITS}
		h.loop_filter_ref_deltas = {1, 0, 0, 0, -1, 0, -1, -1}
		h.loop_filter_mode_deltas = {}
	} else {
		prev := &p.refs[h.ref_frame_idx[h.primary_ref_frame]]
		prev_gm = prev.gm_params
		h.loop_filter_ref_deltas = prev.loop_filter_ref_deltas
		h.loop_filter_mode_deltas = prev.loop_filter_mode_deltas
		h.feature_enabled = prev.feature_enabled
		h.feature_data = prev.feature_data
	}
	tile_info(s, &h, b) or_return
	quantization_params(s, &h, b)
	segmentation_params(&h, b)
	if h.base_q_idx > 0 do h.delta_q_present = flag(b)
	if h.delta_q_present do h.delta_q_res = u8(f(b, 2))
	if h.delta_q_present {
		if !h.allow_intrabc do h.delta_lf_present = flag(b)
		if h.delta_lf_present {
			h.delta_lf_res = u8(f(b, 2))
			h.delta_lf_multi = flag(b)
		}
	}
	h.coded_lossless = true
	for seg in 0 ..< MAX_SEGMENTS {
		q := int(h.base_q_idx)
		if h.segmentation_enabled && h.feature_enabled[seg] & 1 != 0 do q = clamp(q + int(h.feature_data[seg][0]), 0, 255)
		lossless := q == 0 && h.delta_q_y_dc == 0 && h.delta_q_u_ac == 0 && h.delta_q_u_dc == 0 && h.delta_q_v_ac == 0 && h.delta_q_v_dc == 0
		if !lossless do h.coded_lossless = false
	}
	h.all_lossless = h.coded_lossless && h.frame_width == h.upscaled_width
	loop_filter_params(s, &h, b)
	cdef_params(s, &h, b)
	lr_params(s, &h, b)
	h.tx_mode = h.coded_lossless ? 0 : (flag(b) ? 2 : 1)
	h.reference_select = h.frame_is_intra ? false : flag(b)
	skip_mode_params(p, &h, b)
	h.allow_warped_motion = h.frame_is_intra || h.error_resilient_mode || !s.enable_warped_motion ? false : flag(b)
	h.reduced_tx_set = flag(b)
	global_motion_params(&h, &prev_gm, b)
	film_grain_params(p, &h, b) or_return
	return h, b.overrun ? .Invalid_Data : .None
}

@(private)
mark_ref_frames :: proc(p: ^Parser, h: ^Frame_Header, id_len: int) {
	diff_len := uint(p.sequence.delta_frame_id_length_minus_2) + 2
	cur := h.current_frame_id
	for &r in p.refs {
		if cur > 1 << diff_len {
			if r.frame_id > cur || r.frame_id < cur - 1 << diff_len do r.valid = false
		} else if r.frame_id > cur && r.frame_id < (1 << uint(id_len)) + cur - 1 << diff_len {
			r.valid = false
		}
	}
}

// 7.8: the references implied by LAST and GOLDEN and the order hints.
@(private)
set_frame_refs :: proc(p: ^Parser, h: ^Frame_Header, last, gold: u8) {
	s := &p.sequence
	idx: [REFS_PER_FRAME]int
	for &x in idx do x = -1
	idx[0], idx[GOLDEN_FRAME - LAST_FRAME] = int(last), int(gold)
	used: [NUM_REF_FRAMES]bool
	used[last], used[gold] = true, true
	cur := 1 << uint(s.order_hint_bits - 1)
	shifted: [NUM_REF_FRAMES]int
	for i in 0 ..< NUM_REF_FRAMES do shifted[i] = cur + relative_dist(s, int(p.refs[i].order_hint), int(h.order_hint))
	// Backward references: the latest for ALTREF, then the earliest twice.
	find :: proc(used: ^[NUM_REF_FRAMES]bool, shifted: ^[NUM_REF_FRAMES]int, cur: int, backward, latest: bool) -> int {
		ref, best := -1, 0
		for i in 0 ..< NUM_REF_FRAMES {
			hint := shifted[i]
			if used[i] || (backward ? hint < cur : hint >= cur) do continue
			if ref < 0 || (latest ? hint >= best : hint < best) {ref, best = i, hint}
		}
		return ref
	}
	if r := find(&used, &shifted, cur, true, true); r >= 0 {idx[ALTREF_FRAME - LAST_FRAME] = r; used[r] = true}
	if r := find(&used, &shifted, cur, true, false); r >= 0 {idx[BWDREF_FRAME - LAST_FRAME] = r; used[r] = true}
	if r := find(&used, &shifted, cur, true, false); r >= 0 {idx[ALTREF2_FRAME - LAST_FRAME] = r; used[r] = true}
	for ref in ([5]int{LAST2_FRAME, LAST3_FRAME, BWDREF_FRAME, ALTREF2_FRAME, ALTREF_FRAME}) {
		if idx[ref - LAST_FRAME] >= 0 do continue
		if r := find(&used, &shifted, cur, false, true); r >= 0 {idx[ref - LAST_FRAME] = r; used[r] = true}
	}
	// Anything left: the earliest of all.
	earliest, best := -1, 0
	for i in 0 ..< NUM_REF_FRAMES {
		if earliest < 0 || shifted[i] < best {earliest, best = i, shifted[i]}
	}
	for i in 0 ..< REFS_PER_FRAME {
		if idx[i] < 0 do idx[i] = earliest
		h.ref_frame_idx[i] = u8(idx[i])
	}
}

@(private)
frame_size :: proc(s: ^Sequence_Header, h: ^Frame_Header, b: ^Bits) {
	if h.frame_size_override_flag {
		h.frame_width = int(f(b, int(s.frame_width_bits_minus_1) + 1)) + 1
		h.frame_height = int(f(b, int(s.frame_height_bits_minus_1) + 1)) + 1
	} else {
		h.frame_width = int(s.max_frame_width_minus_1) + 1
		h.frame_height = int(s.max_frame_height_minus_1) + 1
	}
	superres_params(s, h, b)
	compute_image_size(h)
}

@(private)
superres_params :: proc(s: ^Sequence_Header, h: ^Frame_Header, b: ^Bits) {
	SUPERRES_NUM :: 8
	if s.enable_superres do h.use_superres = flag(b)
	denom := SUPERRES_NUM
	if h.use_superres {
		h.coded_denom = u8(f(b, 3))
		denom = int(h.coded_denom) + 9
	}
	h.upscaled_width = h.frame_width
	h.frame_width = (h.upscaled_width * SUPERRES_NUM + denom / 2) / denom
}

@(private)
compute_image_size :: proc(h: ^Frame_Header) {
	h.mi_cols = 2 * ((h.frame_width + 7) >> 3)
	h.mi_rows = 2 * ((h.frame_height + 7) >> 3)
}

@(private)
render_size :: proc(h: ^Frame_Header, b: ^Bits) {
	h.render_and_frame_size_different = flag(b)
	if h.render_and_frame_size_different {
		h.render_width = int(f(b, 16)) + 1
		h.render_height = int(f(b, 16)) + 1
	} else {
		h.render_width, h.render_height = h.upscaled_width, h.frame_height
	}
}

@(private)
tile_log2 :: proc(block, target: int) -> int {
	k := 0
	for block << uint(k) < target do k += 1
	return k
}

// 5.9.15
@(private)
tile_info :: proc(s: ^Sequence_Header, h: ^Frame_Header, b: ^Bits) -> Error {
	MAX_TILE_WIDTH :: 4096
	MAX_TILE_AREA :: 4096 * 2304
	t := &h.tile_info
	sb128 := s.use_128x128_superblock
	sb_cols := sb128 ? (h.mi_cols + 31) >> 5 : (h.mi_cols + 15) >> 4
	sb_rows := sb128 ? (h.mi_rows + 31) >> 5 : (h.mi_rows + 15) >> 4
	sb_shift := uint(sb128 ? 5 : 4)
	sb_size := sb_shift + 2
	max_tile_width_sb := MAX_TILE_WIDTH >> sb_size
	max_tile_area_sb := MAX_TILE_AREA >> (2 * sb_size)
	min_log2_cols := tile_log2(max_tile_width_sb, sb_cols)
	max_log2_cols := tile_log2(1, min(sb_cols, MAX_TILE_COLS))
	max_log2_rows := tile_log2(1, min(sb_rows, MAX_TILE_ROWS))
	min_log2_tiles := max(min_log2_cols, tile_log2(max_tile_area_sb, sb_rows * sb_cols))
	t.uniform_tile_spacing_flag = flag(b)
	if t.uniform_tile_spacing_flag {
		t.tile_cols_log2 = min_log2_cols
		for t.tile_cols_log2 < max_log2_cols && flag(b) do t.tile_cols_log2 += 1
		width_sb := (sb_cols + (1 << uint(t.tile_cols_log2)) - 1) >> uint(t.tile_cols_log2)
		i := 0
		for start := 0; start < sb_cols; start += width_sb {
			if i >= MAX_TILE_COLS do return .Invalid_Data
			t.mi_col_starts[i] = u16(start << sb_shift)
			t.width_in_sbs_minus_1[i] = u16(min(width_sb, sb_cols - start) - 1)
			i += 1
		}
		t.mi_col_starts[i] = u16(h.mi_cols)
		t.tile_cols = i
		t.tile_rows_log2 = max(min_log2_tiles - t.tile_cols_log2, 0)
		for t.tile_rows_log2 < max_log2_rows && flag(b) do t.tile_rows_log2 += 1
		height_sb := (sb_rows + (1 << uint(t.tile_rows_log2)) - 1) >> uint(t.tile_rows_log2)
		i = 0
		for start := 0; start < sb_rows; start += height_sb {
			if i >= MAX_TILE_ROWS do return .Invalid_Data
			t.mi_row_starts[i] = u16(start << sb_shift)
			t.height_in_sbs_minus_1[i] = u16(min(height_sb, sb_rows - start) - 1)
			i += 1
		}
		t.mi_row_starts[i] = u16(h.mi_rows)
		t.tile_rows = i
	} else {
		widest := 0
		i := 0
		for start := 0; start < sb_cols; i += 1 {
			if i >= MAX_TILE_COLS do return .Invalid_Data
			t.mi_col_starts[i] = u16(start << sb_shift)
			size := int(ns(b, u32(min(sb_cols - start, max_tile_width_sb)))) + 1
			t.width_in_sbs_minus_1[i] = u16(size - 1)
			widest = max(size, widest)
			start += size
		}
		t.mi_col_starts[i] = u16(h.mi_cols)
		t.tile_cols = i
		t.tile_cols_log2 = tile_log2(1, t.tile_cols)
		area := min_log2_tiles > 0 ? (sb_rows * sb_cols) >> uint(min_log2_tiles + 1) : sb_rows * sb_cols
		max_height := max(area / widest, 1)
		i = 0
		for start := 0; start < sb_rows; i += 1 {
			if i >= MAX_TILE_ROWS do return .Invalid_Data
			t.mi_row_starts[i] = u16(start << sb_shift)
			size := int(ns(b, u32(min(sb_rows - start, max_height)))) + 1
			t.height_in_sbs_minus_1[i] = u16(size - 1)
			start += size
		}
		t.mi_row_starts[i] = u16(h.mi_rows)
		t.tile_rows = i
		t.tile_rows_log2 = tile_log2(1, t.tile_rows)
	}
	if t.tile_cols_log2 > 0 || t.tile_rows_log2 > 0 {
		t.context_update_tile_id = u16(f(b, t.tile_rows_log2 + t.tile_cols_log2))
		t.tile_size_bytes = int(f(b, 2)) + 1
	}
	return .None
}

@(private)
read_delta_q :: proc(b: ^Bits) -> i8 {
	return flag(b) ? i8(su(b, 7)) : 0
}

@(private)
quantization_params :: proc(s: ^Sequence_Header, h: ^Frame_Header, b: ^Bits) {
	h.base_q_idx = u8(f(b, 8))
	h.delta_q_y_dc = read_delta_q(b)
	if !s.color.mono_chrome {
		if s.color.separate_uv_delta_q do h.diff_uv_delta = flag(b)
		h.delta_q_u_dc = read_delta_q(b)
		h.delta_q_u_ac = read_delta_q(b)
		if h.diff_uv_delta {
			h.delta_q_v_dc = read_delta_q(b)
			h.delta_q_v_ac = read_delta_q(b)
		} else {
			h.delta_q_v_dc, h.delta_q_v_ac = h.delta_q_u_dc, h.delta_q_u_ac
		}
	}
	h.using_qmatrix = flag(b)
	if h.using_qmatrix {
		h.qm_y = u8(f(b, 4))
		h.qm_u = u8(f(b, 4))
		h.qm_v = s.color.separate_uv_delta_q ? u8(f(b, 4)) : h.qm_u
	}
}

@(private)
segmentation_params :: proc(h: ^Frame_Header, b: ^Bits) {
	BITS := [SEG_LVL_MAX]int{8, 6, 6, 6, 6, 3, 0, 0}
	SIGNED := [SEG_LVL_MAX]bool{true, true, true, true, true, false, false, false}
	LIMIT := [SEG_LVL_MAX]i32{255, 63, 63, 63, 63, 7, 0, 0}
	h.segmentation_enabled = flag(b)
	if !h.segmentation_enabled {
		h.feature_enabled, h.feature_data = {}, {}
		return
	}
	if h.primary_ref_frame == PRIMARY_REF_NONE {
		h.segmentation_update_map, h.segmentation_update_data = true, true
	} else {
		h.segmentation_update_map = flag(b)
		if h.segmentation_update_map do h.segmentation_temporal_update = flag(b)
		h.segmentation_update_data = flag(b)
	}
	if !h.segmentation_update_data do return
	for i in 0 ..< MAX_SEGMENTS {
		h.feature_enabled[i] = 0
		for j in 0 ..< SEG_LVL_MAX {
			value: i32
			if flag(b) {
				h.feature_enabled[i] |= 1 << uint(j)
				if SIGNED[j] {
					value = clamp(su(b, 1 + BITS[j]), -LIMIT[j], LIMIT[j])
				} else {
					value = clamp(i32(f(b, BITS[j])), 0, LIMIT[j])
				}
			}
			h.feature_data[i][j] = i16(value)
		}
	}
}

@(private)
loop_filter_params :: proc(s: ^Sequence_Header, h: ^Frame_Header, b: ^Bits) {
	if h.coded_lossless || h.allow_intrabc {
		h.loop_filter_ref_deltas = {1, 0, 0, 0, -1, 0, -1, -1}
		h.loop_filter_mode_deltas = {}
		return
	}
	h.loop_filter_level[0] = u8(f(b, 6))
	h.loop_filter_level[1] = u8(f(b, 6))
	if !s.color.mono_chrome && (h.loop_filter_level[0] != 0 || h.loop_filter_level[1] != 0) {
		h.loop_filter_level[2] = u8(f(b, 6))
		h.loop_filter_level[3] = u8(f(b, 6))
	}
	h.loop_filter_sharpness = u8(f(b, 3))
	h.loop_filter_delta_enabled = flag(b)
	if !h.loop_filter_delta_enabled do return
	h.loop_filter_delta_update = flag(b)
	if !h.loop_filter_delta_update do return
	for i in 0 ..< NUM_REF_FRAMES {
		if flag(b) {
			h.update_ref_delta |= 1 << uint(i)
			h.loop_filter_ref_deltas[i] = i8(su(b, 7))
		}
	}
	for i in 0 ..< 2 {
		if flag(b) {
			h.update_mode_delta |= 1 << uint(i)
			h.loop_filter_mode_deltas[i] = i8(su(b, 7))
		}
	}
}

@(private)
cdef_params :: proc(s: ^Sequence_Header, h: ^Frame_Header, b: ^Bits) {
	if h.coded_lossless || h.allow_intrabc || !s.enable_cdef do return // damping 3, bits 0, strengths 0
	h.cdef_damping_minus_3 = u8(f(b, 2))
	h.cdef_bits = u8(f(b, 2))
	for i in 0 ..< 1 << h.cdef_bits {
		h.cdef_y_pri_strength[i] = u8(f(b, 4))
		h.cdef_y_sec_strength[i] = u8(f(b, 2))
		if h.cdef_y_sec_strength[i] == 3 do h.cdef_y_sec_strength[i] += 1
		if !s.color.mono_chrome {
			h.cdef_uv_pri_strength[i] = u8(f(b, 4))
			h.cdef_uv_sec_strength[i] = u8(f(b, 2))
			if h.cdef_uv_sec_strength[i] == 3 do h.cdef_uv_sec_strength[i] += 1
		}
	}
}

@(private)
lr_params :: proc(s: ^Sequence_Header, h: ^Frame_Header, b: ^Bits) {
	if h.all_lossless || h.allow_intrabc || !s.enable_restoration do return
	REMAP := [4]u8{0, 3, 1, 2} // none, switchable, Wiener, self-guided
	planes := s.color.mono_chrome ? 1 : 3
	for i in 0 ..< planes {
		h.frame_restoration_type[i] = REMAP[f(b, 2)]
		if h.frame_restoration_type[i] != 0 {
			h.uses_lr = true
			if i > 0 do h.uses_chroma_lr = true
		}
	}
	if !h.uses_lr do return
	shift: uint
	if s.use_128x128_superblock {
		shift = uint(f(b, 1)) + 1
	} else {
		shift = uint(f(b, 1))
		if shift != 0 do shift += uint(f(b, 1))
	}
	h.loop_restoration_size[0] = 256 >> (2 - shift)
	uv_shift: uint
	if s.color.subsampling_x == 1 && s.color.subsampling_y == 1 && h.uses_chroma_lr do uv_shift = uint(f(b, 1))
	h.loop_restoration_size[1] = h.loop_restoration_size[0] >> uv_shift
	h.loop_restoration_size[2] = h.loop_restoration_size[0] >> uv_shift
}

@(private)
skip_mode_params :: proc(p: ^Parser, h: ^Frame_Header, b: ^Bits) {
	s := &p.sequence
	if h.frame_is_intra || !h.reference_select || !s.enable_order_hint do return
	forward, backward := -1, -1
	forward_hint, backward_hint: int
	for i in 0 ..< REFS_PER_FRAME {
		hint := int(p.refs[h.ref_frame_idx[i]].order_hint)
		d := relative_dist(s, hint, int(h.order_hint))
		if d < 0 {
			if forward < 0 || relative_dist(s, hint, forward_hint) > 0 {forward, forward_hint = i, hint}
		} else if d > 0 {
			if backward < 0 || relative_dist(s, hint, backward_hint) < 0 {backward, backward_hint = i, hint}
		}
	}
	allowed := false
	switch {
	case forward < 0:
	case backward >= 0:
		allowed = true
		h.skip_mode_frame = {u8(LAST_FRAME + min(forward, backward)), u8(LAST_FRAME + max(forward, backward))}
	case:
		second, second_hint := -1, 0
		for i in 0 ..< REFS_PER_FRAME {
			hint := int(p.refs[h.ref_frame_idx[i]].order_hint)
			if relative_dist(s, hint, forward_hint) < 0 {
				if second < 0 || relative_dist(s, hint, second_hint) > 0 {second, second_hint = i, hint}
			}
		}
		if second >= 0 {
			allowed = true
			h.skip_mode_frame = {u8(LAST_FRAME + min(forward, second)), u8(LAST_FRAME + max(forward, second))}
		}
	}
	if allowed do h.skip_mode_present = flag(b)
}

// 5.9.24-5.9.29
@(private)
global_motion_params :: proc(h: ^Frame_Header, prev: ^[NUM_REF_FRAMES][6]i32, b: ^Bits) {
	IDENTITY, TRANSLATION, ROTZOOM, AFFINE :: 0, 1, 2, 3
	for ref in LAST_FRAME ..= ALTREF_FRAME {
		h.gm_type[ref] = IDENTITY
		h.gm_params[ref] = {0, 0, 1 << WARPEDMODEL_PREC_BITS, 0, 0, 1 << WARPEDMODEL_PREC_BITS}
	}
	if h.frame_is_intra do return
	for ref in LAST_FRAME ..= ALTREF_FRAME {
		type := IDENTITY
		if flag(b) {
			if flag(b) {
				type = ROTZOOM
			} else {
				type = flag(b) ? TRANSLATION : AFFINE
			}
		}
		h.gm_type[ref] = u8(type)
		if type >= ROTZOOM {
			read_global_param(h, prev, b, type, ref, 2)
			read_global_param(h, prev, b, type, ref, 3)
			if type == AFFINE {
				read_global_param(h, prev, b, type, ref, 4)
				read_global_param(h, prev, b, type, ref, 5)
			} else {
				h.gm_params[ref][4] = -h.gm_params[ref][3]
				h.gm_params[ref][5] = h.gm_params[ref][2]
			}
		}
		if type >= TRANSLATION {
			read_global_param(h, prev, b, type, ref, 0)
			read_global_param(h, prev, b, type, ref, 1)
		}
	}
}

@(private)
read_global_param :: proc(h: ^Frame_Header, prev: ^[NUM_REF_FRAMES][6]i32, b: ^Bits, type, ref, idx: int) {
	abs_bits, prec_bits := 12, 15 // GM_ABS_ALPHA_BITS, GM_ALPHA_PREC_BITS
	if idx < 2 {
		if type == 1 {
			hp := h.allow_high_precision_mv ? 0 : 1
			abs_bits, prec_bits = 9 - hp, 3 - hp
		} else {
			abs_bits, prec_bits = 12, 6
		}
	}
	prec_diff := uint(WARPEDMODEL_PREC_BITS - prec_bits)
	round := idx % 3 == 2 ? i32(1) << WARPEDMODEL_PREC_BITS : 0
	sub := idx % 3 == 2 ? i32(1) << uint(prec_bits) : 0
	mx := i32(1) << uint(abs_bits)
	r := (prev[ref][idx] >> prec_diff) - sub
	h.gm_params[ref][idx] = (decode_signed_subexp_with_ref(b, -mx, mx + 1, r) << prec_diff) + round
}

@(private)
decode_signed_subexp_with_ref :: proc(b: ^Bits, low, high, r: i32) -> i32 {
	return decode_unsigned_subexp_with_ref(b, high - low, r - low) + low
}

@(private)
decode_unsigned_subexp_with_ref :: proc(b: ^Bits, mx, r: i32) -> i32 {
	v := decode_subexp(b, mx)
	return (r << 1) <= mx ? inverse_recenter(r, v) : mx - 1 - inverse_recenter(mx - 1 - r, v)
}

@(private)
decode_subexp :: proc(b: ^Bits, num_syms: i32) -> i32 {
	i, mk, k: i32 = 0, 0, 3
	for {
		b2 := i != 0 ? k + i - 1 : k
		a := i32(1) << uint(b2)
		if num_syms <= mk + 3 * a {
			return i32(ns(b, u32(num_syms - mk))) + mk
		}
		if !flag(b) do return i32(f(b, int(b2))) + mk
		i += 1
		mk += a
		if b.overrun do return 0
	}
}

@(private)
inverse_recenter :: proc(r, v: i32) -> i32 {
	switch {
	case v > 2 * r:
		return v
	case v & 1 != 0:
		return r - ((v + 1) >> 1)
	}
	return r + (v >> 1)
}

// 5.9.30
@(private)
film_grain_params :: proc(p: ^Parser, h: ^Frame_Header, b: ^Bits) -> Error {
	s := &p.sequence
	g := &h.film_grain
	g^ = {}
	if !s.film_grain_params_present || (!h.show_frame && !h.showable_frame) do return .None
	g.apply_grain = flag(b)
	if !g.apply_grain do return .None
	g.grain_seed = u16(f(b, 16))
	g.update_grain = h.frame_type == .Inter ? flag(b) : true
	if !g.update_grain {
		g.film_grain_params_ref_idx = u8(f(b, 3))
		seed := g.grain_seed
		ref := g.film_grain_params_ref_idx
		g^ = p.refs[ref].film_grain
		g.grain_seed, g.film_grain_params_ref_idx, g.update_grain = seed, ref, false
		return .None
	}
	g.num_y_points = u8(f(b, 4))
	if g.num_y_points > 14 do return .Invalid_Data
	for i in 0 ..< g.num_y_points {
		g.point_y_value[i] = u8(f(b, 8))
		g.point_y_scaling[i] = u8(f(b, 8))
	}
	c := &s.color
	g.chroma_scaling_from_luma = c.mono_chrome ? false : flag(b)
	if !(c.mono_chrome || g.chroma_scaling_from_luma || (c.subsampling_x == 1 && c.subsampling_y == 1 && g.num_y_points == 0)) {
		g.num_cb_points = u8(f(b, 4))
		if g.num_cb_points > 10 do return .Invalid_Data
		for i in 0 ..< g.num_cb_points {
			g.point_cb_value[i] = u8(f(b, 8))
			g.point_cb_scaling[i] = u8(f(b, 8))
		}
		g.num_cr_points = u8(f(b, 4))
		if g.num_cr_points > 10 do return .Invalid_Data
		for i in 0 ..< g.num_cr_points {
			g.point_cr_value[i] = u8(f(b, 8))
			g.point_cr_scaling[i] = u8(f(b, 8))
		}
	}
	g.grain_scaling_minus_8 = u8(f(b, 2))
	g.ar_coeff_lag = u8(f(b, 2))
	luma := 2 * int(g.ar_coeff_lag) * (int(g.ar_coeff_lag) + 1)
	chroma := luma
	if g.num_y_points != 0 {
		chroma = luma + 1
		for i in 0 ..< luma do g.ar_coeffs_y_plus_128[i] = u8(f(b, 8))
	}
	if g.chroma_scaling_from_luma || g.num_cb_points != 0 do for i in 0 ..< chroma do g.ar_coeffs_cb_plus_128[i] = u8(f(b, 8))
	if g.chroma_scaling_from_luma || g.num_cr_points != 0 do for i in 0 ..< chroma do g.ar_coeffs_cr_plus_128[i] = u8(f(b, 8))
	g.ar_coeff_shift_minus_6 = u8(f(b, 2))
	g.grain_scale_shift = u8(f(b, 2))
	if g.num_cb_points != 0 {
		g.cb_mult = u8(f(b, 8))
		g.cb_luma_mult = u8(f(b, 8))
		g.cb_offset = u16(f(b, 9))
	}
	if g.num_cr_points != 0 {
		g.cr_mult = u8(f(b, 8))
		g.cr_luma_mult = u8(f(b, 8))
		g.cr_offset = u16(f(b, 9))
	}
	g.overlap_flag = flag(b)
	g.clip_to_restricted_range = flag(b)
	return .None
}

// 5.11.1: the tiles of one tile group, their payload offsets given relative
// to the start of the caller's data (`base` is the group's offset there).
// Returns whether this group ends the frame.
@(private)
parse_tile_group :: proc(h: ^Frame_Header, payload: []u8, base: int, tiles: ^[dynamic]Tile) -> (done: bool, err: Error) {
	t := &h.tile_info
	num_tiles := t.tile_cols * t.tile_rows
	b := Bits{data = payload}
	start, end := 0, num_tiles - 1
	if num_tiles > 1 && flag(&b) {
		bits := t.tile_cols_log2 + t.tile_rows_log2
		start = int(f(&b, bits))
		end = int(f(&b, bits))
	}
	if b.overrun || start > end || end >= num_tiles do return false, .Invalid_Data
	at := (b.pos + 7) / 8
	for n in start ..= end {
		size := len(payload) - at
		if n != end {
			if at + t.tile_size_bytes > len(payload) do return false, .Invalid_Data
			v := 0
			for k in 0 ..< t.tile_size_bytes do v |= int(payload[at + k]) << uint(8 * k)
			at += t.tile_size_bytes
			size = v + 1
		}
		if size <= 0 || size > len(payload) - at do return false, .Invalid_Data
		append(tiles, Tile{u32(base + at), u32(size)})
		at += size
	}
	return end == num_tiles - 1, .None
}

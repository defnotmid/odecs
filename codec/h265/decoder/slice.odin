package h265_decoder

import hevc ".."
import "core:math/bits"

// ---------------------------------------------------------------------------
// Slice segment header (7.3.6.1). Ported from gen2brain/h265 hevc/slice.go
// (MIT); oxideav-h265 src/slice.rs and src/slice_data.rs are the per-file
// cross-references.
// ---------------------------------------------------------------------------

Slice_Type :: hevc.Slice_Type

Long_Term_RPS :: struct {
	num_sps:               int,
	poc_lsb_lt:            []u32,
	used_by_curr_pic_lt:   []bool,
	delta_poc_msb_present: []bool,
	delta_poc_msb_cycle:   []u32,
}

destroy_long_term_rps :: proc(lt: ^Long_Term_RPS) {
	delete(lt.poc_lsb_lt)
	delete(lt.used_by_curr_pic_lt)
	delete(lt.delta_poc_msb_present)
	delete(lt.delta_poc_msb_cycle)
	lt^ = {}
}

Ref_Pic_List_Modification :: struct {
	flag_l0:       bool,
	list_entry_l0: []u32,
	flag_l1:       bool,
	list_entry_l1: []u32,
}

Pred_Weight_Table :: struct {
	luma_log2_denom:   u8,
	chroma_log2_denom: u8,
	luma_weight:       [2][MAX_REFS]i16,
	luma_offset:       [2][MAX_REFS]i16,
	chroma_weight:     [2][MAX_REFS][2]i16,
	chroma_offset:     [2][MAX_REFS][2]i16,
}

Slice_Header :: struct {
	nal_type:                   Nal_Type,
	first_slice_segment_in_pic: bool,
	no_output_of_prior_pics:    bool,
	pps_id:                     u32,
	dependent_slice_segment:    bool,
	slice_segment_address:      u32,
	slice_type:                 Slice_Type,
	pic_output_flag:            bool,
	colour_plane_id:            u8,
	pic_order_cnt_lsb:          u32,
	st_rps_from_sps:            bool,
	st_rps_idx:                 u32,
	st_rps:                     Short_Term_RPS,
	st_rps_num_bits:            int, // exact short_term_ref_pic_set syntax length in this slice
	lt_rps:                     Long_Term_RPS,
	temporal_mvp:               bool,
	num_poc_total_curr:         u32,
	sao_luma:                   bool,
	sao_chroma:                 bool,
	num_ref_idx_l0_active:      u32,
	num_ref_idx_l1_active:      u32,
	list_modification:          Ref_Pic_List_Modification,
	mvd_l1_zero:                bool,
	cabac_init:                 bool,
	collocated_from_l0:         bool,
	collocated_ref_idx:         u32,
	max_num_merge_cand:         u32,
	weights:                    Pred_Weight_Table,
	qp_delta:                   i32,
	qp_y:                       i32,
	cb_qp_offset:               i32,
	cr_qp_offset:               i32,
	cu_chroma_qp_offset:        bool,
	deblocking_disabled:        bool,
	beta_offset_div2:           i32,
	tc_offset_div2:             i32,
	loop_filter_across:         bool,
	entry_point_offsets:        []u32,
	data_offset:                int,
}

// destroy_slice_header frees the slice's own variable syntax. A slice header
// that took its short-term RPS from the SPS only aliases it; a dependent slice
// that inherited another header's lists must not be destroyed independently.
destroy_slice_header :: proc(h: ^Slice_Header) {
	if !h.st_rps_from_sps do destroy_short_term_rps(&h.st_rps)
	destroy_long_term_rps(&h.lt_rps)
	delete(h.list_modification.list_entry_l0)
	delete(h.list_modification.list_entry_l1)
	delete(h.entry_point_offsets)
	h^ = {}
}

ceil_log2 :: proc(n: u32) -> int {
	if n <= 1 do return 0

	return bits.len_u32(n - 1)
}

sps_chroma_array_type :: proc(s: ^SPS) -> u32 {
	if s.separate_colour_plane do return 0

	return s.chroma_format_idc
}

// slice_header_clone copies the variable syntax so the copy owns its own
// memory and destroy_slice_header is safe on every header.
slice_header_clone :: proc(h: ^Slice_Header, src: ^Slice_Header) {
	h^ = src^

	if !h.st_rps_from_sps {
		h.st_rps.delta_poc_s0 = clone_slice(src.st_rps.delta_poc_s0)
		h.st_rps.delta_poc_s1 = clone_slice(src.st_rps.delta_poc_s1)
		h.st_rps.used_s0 = clone_slice(src.st_rps.used_s0)
		h.st_rps.used_s1 = clone_slice(src.st_rps.used_s1)
	}

	h.lt_rps.poc_lsb_lt = clone_slice(src.lt_rps.poc_lsb_lt)
	h.lt_rps.used_by_curr_pic_lt = clone_slice(src.lt_rps.used_by_curr_pic_lt)
	h.lt_rps.delta_poc_msb_present = clone_slice(src.lt_rps.delta_poc_msb_present)
	h.lt_rps.delta_poc_msb_cycle = clone_slice(src.lt_rps.delta_poc_msb_cycle)
	h.list_modification.list_entry_l0 = clone_slice(src.list_modification.list_entry_l0)
	h.list_modification.list_entry_l1 = clone_slice(src.list_modification.list_entry_l1)
	h.entry_point_offsets = clone_slice(src.entry_point_offsets)
}

@(private)
clone_slice :: proc(src: $T) -> T {
	if len(src) == 0 do return nil
	dst := make(T, len(src))
	copy(dst, src)
	return dst
}

// slice_header_inherit is the 7.4.7.1 inheritance of a dependent slice
// segment. The address, entry points, payload offset and the identifying NAL
// fields stay the dependent slice's own; the rest is copied from the retained
// independent slice header, with its own copies of the variable syntax so
// every header owns its memory.
slice_header_inherit :: proc(h: ^Slice_Header, prev: ^Slice_Header) {
	addr := h.slice_segment_address
	entry := h.entry_point_offsets
	off := h.data_offset
	first := h.first_slice_segment_in_pic
	dep := h.dependent_slice_segment
	nal := h.nal_type
	pps_id := h.pps_id
	no_output := h.no_output_of_prior_pics

	slice_header_clone(h, prev)

	h.slice_segment_address = addr
	delete(h.entry_point_offsets)
	h.entry_point_offsets = entry
	h.data_offset = off
	h.first_slice_segment_in_pic = first
	h.dependent_slice_segment = dep
	h.nal_type = nal
	h.pps_id = pps_id
	h.no_output_of_prior_pics = no_output
}

parse_slice_header :: proc(
	rbsp: []u8,
	nal_type: Nal_Type,
	s: ^SPS,
	p: ^PPS,
) -> (
	h: Slice_Header,
	ok: bool,
) {
	c: Get_Bits
	get_bits_init(&c, rbsp)

	defer {
		if !ok do destroy_slice_header(&h)
	}

	h.nal_type = nal_type
	h.first_slice_segment_in_pic = get_bits_bit(&c) != 0

	if nal_type >= .BLA_W_LP && nal_type <= .RSV_IRAP_VCL23 {
		h.no_output_of_prior_pics = get_bits_bit(&c) != 0
	}

	h.pps_id = get_bits_ue(&c)
	if h.pps_id != p.id do return

	num_ctbs := s.pic_width_in_ctbs * s.pic_height_in_ctbs

	if !h.first_slice_segment_in_pic {
		if p.dependent_slice_segments_enabled {
			h.dependent_slice_segment = get_bits_bit(&c) != 0
		}

		h.slice_segment_address = get_bits_bits(&c, ceil_log2(num_ctbs))
		if h.slice_segment_address >= num_ctbs do return
	}

	h.pic_output_flag = true
	h.collocated_from_l0 = true
	h.max_num_merge_cand = 5
	h.num_ref_idx_l0_active = p.num_ref_idx_l0_default_active
	h.num_ref_idx_l1_active = p.num_ref_idx_l1_default_active
	h.deblocking_disabled = p.deblocking_disabled
	h.beta_offset_div2 = p.beta_offset_div2
	h.tc_offset_div2 = p.tc_offset_div2
	h.loop_filter_across = p.loop_filter_across_slices

	if !h.dependent_slice_segment {
		get_bits_skip(&c, int(p.num_extra_slice_header_bits))

		t := get_bits_ue(&c)
		if t > 2 do return

		h.slice_type = Slice_Type(t)

		if p.output_flag_present do h.pic_output_flag = get_bits_bit(&c) != 0

		if s.separate_colour_plane do h.colour_plane_id = u8(get_bits_bits(&c, 2))

		if !nal_type_is_idr(nal_type) {
			h.pic_order_cnt_lsb = get_bits_bits(&c, int(s.log2_max_poc_lsb))

			h.st_rps_from_sps = get_bits_bit(&c) != 0
			if !h.st_rps_from_sps {
				start := get_bits_pos(&c)
				rps, good := parse_short_term_rps(&c, len(s.st_rps), len(s.st_rps), s.st_rps[:])
				if !good do return

				h.st_rps = rps
				h.st_rps_num_bits = get_bits_pos(&c) - start
			} else {
				if len(s.st_rps) == 0 do return

				if len(s.st_rps) > 1 {
					h.st_rps_idx = get_bits_bits(&c, ceil_log2(u32(len(s.st_rps))))
				}

				if int(h.st_rps_idx) >= len(s.st_rps) do return

				h.st_rps = s.st_rps[h.st_rps_idx]
			}

			if s.long_term_ref_pics_present {
				lt, good := parse_long_term_rps(&c, s)
				if !good do return

				h.lt_rps = lt
			}

			if s.temporal_mvp_enabled do h.temporal_mvp = get_bits_bit(&c) != 0
		}

		h.num_poc_total_curr = num_poc_total_curr(&h.st_rps, &h.lt_rps)

		if s.sao_enabled {
			h.sao_luma = get_bits_bit(&c) != 0

			if sps_chroma_array_type(s) != 0 {
				h.sao_chroma = get_bits_bit(&c) != 0
			}
		}

		if h.slice_type != .I {
			if get_bits_bit(&c) != 0 {
				h.num_ref_idx_l0_active = get_bits_ue(&c) + 1

				if h.slice_type == .B {
					h.num_ref_idx_l1_active = get_bits_ue(&c) + 1
				}
			}

			if h.num_ref_idx_l0_active > MAX_REFS || h.num_ref_idx_l1_active > MAX_REFS do return

			if p.lists_modification_present && h.num_poc_total_curr > 1 {
				if !parse_ref_pic_list_modification(&c, &h) do return
			}

			if h.slice_type == .B do h.mvd_l1_zero = get_bits_bit(&c) != 0

			if p.cabac_init_present do h.cabac_init = get_bits_bit(&c) != 0

			if h.temporal_mvp {
				if h.slice_type == .B do h.collocated_from_l0 = get_bits_bit(&c) != 0

				active := h.num_ref_idx_l1_active
				if h.collocated_from_l0 do active = h.num_ref_idx_l0_active

				if active > 1 {
					h.collocated_ref_idx = get_bits_ue(&c)
					if h.collocated_ref_idx >= active do return
				}
			}

			if (p.weighted_pred && h.slice_type == .P) ||
			   (p.weighted_bipred && h.slice_type == .B) {
				if !parse_pred_weight_table(&c, &h, s) do return
			}

			n := get_bits_ue(&c)
			if n > 4 do return

			h.max_num_merge_cand = 5 - n
		}

		h.qp_delta = get_bits_se(&c)
		h.qp_y = p.init_qp + h.qp_delta

		if h.qp_y < -(6 * i32(s.bit_depth_luma) - 48) || h.qp_y > 51 do return

		if p.slice_chroma_qp_offsets {
			h.cb_qp_offset = get_bits_se(&c)
			h.cr_qp_offset = get_bits_se(&c)

			if h.cb_qp_offset < -12 ||
			   h.cb_qp_offset > 12 ||
			   h.cr_qp_offset < -12 ||
			   h.cr_qp_offset > 12 {
				return
			}
		}

		if p.chroma_qp_offset_list_present do h.cu_chroma_qp_offset = get_bits_bit(&c) != 0

		if p.deblocking_override && get_bits_bit(&c) != 0 {
			h.deblocking_disabled = get_bits_bit(&c) != 0

			if !h.deblocking_disabled {
				h.beta_offset_div2 = get_bits_se(&c)
				h.tc_offset_div2 = get_bits_se(&c)

				if h.beta_offset_div2 < -6 ||
				   h.beta_offset_div2 > 6 ||
				   h.tc_offset_div2 < -6 ||
				   h.tc_offset_div2 > 6 {
					return
				}
			}
		}

		if p.loop_filter_across_slices && (h.sao_luma || h.sao_chroma || !h.deblocking_disabled) {
			h.loop_filter_across = get_bits_bit(&c) != 0
		}
	}

	if p.tiles_enabled || p.entropy_coding_sync {
		n := get_bits_ue(&c)
		if n > num_ctbs do return

		if n > 0 {
			len_minus1 := get_bits_ue(&c)
			if len_minus1 > 31 do return

			h.entry_point_offsets = make([]u32, n)

			cum: u32

			for i in 0 ..< len(h.entry_point_offsets) {
				v := get_bits_bits(&c, int(len_minus1) + 1)

				if cum + v + 1 < cum do return

				cum += v + 1
				h.entry_point_offsets[i] = cum
			}
		}
	}

	if p.slice_header_extension_present {
		n := get_bits_ue(&c)
		if n > u32(len(rbsp)) do return

		get_bits_skip(&c, int(n) * 8)
	}

	if get_bits_bit(&c) != 1 do return

	get_bits_byte_align(&c)

	if c.err do return

	h.data_offset = get_bits_pos(&c) / 8

	return h, true
}

num_poc_total_curr :: proc(st: ^Short_Term_RPS, lt: ^Long_Term_RPS) -> u32 {
	n: u32

	for u in st.used_s0 do if u do n += 1
	for u in st.used_s1 do if u do n += 1
	for u in lt.used_by_curr_pic_lt do if u do n += 1

	return n
}

parse_ref_pic_list_modification :: proc(c: ^Get_Bits, h: ^Slice_Header) -> bool {
	n := ceil_log2(h.num_poc_total_curr)

	h.list_modification.flag_l0 = get_bits_bit(c) != 0
	if h.list_modification.flag_l0 {
		h.list_modification.list_entry_l0 = make([]u32, int(h.num_ref_idx_l0_active))

		for i in 0 ..< len(h.list_modification.list_entry_l0) {
			v := get_bits_bits(c, n)
			if v >= h.num_poc_total_curr do return false

			h.list_modification.list_entry_l0[i] = v
		}
	}

	if h.slice_type != .B do return true

	h.list_modification.flag_l1 = get_bits_bit(c) != 0
	if h.list_modification.flag_l1 {
		h.list_modification.list_entry_l1 = make([]u32, int(h.num_ref_idx_l1_active))

		for i in 0 ..< len(h.list_modification.list_entry_l1) {
			v := get_bits_bits(c, n)
			if v >= h.num_poc_total_curr do return false

			h.list_modification.list_entry_l1[i] = v
		}
	}

	return true
}

parse_long_term_rps :: proc(c: ^Get_Bits, s: ^SPS) -> (lt: Long_Term_RPS, ok: bool) {
	defer {
		if !ok do destroy_long_term_rps(&lt)
	}

	num_sps: u32
	if len(s.lt_ref_pic_poc_lsb) > 0 do num_sps = get_bits_ue(c)

	num_pics := get_bits_ue(c)

	if num_sps > u32(len(s.lt_ref_pic_poc_lsb)) || num_sps + num_pics > MAX_LONG_TERM_REF_PICS do return

	total := int(num_sps + num_pics)
	lt.num_sps = int(num_sps)
	lt.poc_lsb_lt = make([]u32, total)
	lt.used_by_curr_pic_lt = make([]bool, total)
	lt.delta_poc_msb_present = make([]bool, total)
	lt.delta_poc_msb_cycle = make([]u32, total)

	for i in 0 ..< total {
		if u32(i) < num_sps {
			idx: u32
			if len(s.lt_ref_pic_poc_lsb) > 1 {
				idx = get_bits_bits(c, ceil_log2(u32(len(s.lt_ref_pic_poc_lsb))))
			}

			if int(idx) >= len(s.lt_ref_pic_poc_lsb) do return

			lt.poc_lsb_lt[i] = s.lt_ref_pic_poc_lsb[idx]
			lt.used_by_curr_pic_lt[i] = s.used_by_curr_pic_lt[idx]
		} else {
			lt.poc_lsb_lt[i] = get_bits_bits(c, int(s.log2_max_poc_lsb))
			lt.used_by_curr_pic_lt[i] = get_bits_bit(c) != 0
		}

		lt.delta_poc_msb_present[i] = get_bits_bit(c) != 0
		if lt.delta_poc_msb_present[i] do lt.delta_poc_msb_cycle[i] = get_bits_ue(c)
	}

	return lt, true
}

parse_pred_weight_table :: proc(c: ^Get_Bits, h: ^Slice_Header, s: ^SPS) -> bool {
	w := &h.weights

	denom := get_bits_ue(c)
	if denom > 7 do return false

	w.luma_log2_denom = u8(denom)

	chroma_denom := i32(denom)
	if sps_chroma_array_type(s) != 0 {
		chroma_denom += get_bits_se(c)

		if chroma_denom < 0 || chroma_denom > 7 do return false
	}

	w.chroma_log2_denom = u8(chroma_denom)

	// 7.4.7.3, WpOffsetHalfRangeC: the sample depth under high precision
	// offsets, eight bits otherwise.
	half := i32(128)
	if s.high_precision_offsets do half = 1 << uint(s.bit_depth_chroma - 1)

	lists := 1
	if h.slice_type == .B do lists = 2

	counts := [2]u32{h.num_ref_idx_l0_active, h.num_ref_idx_l1_active}

	for l in 0 ..< lists {
		n := int(counts[l])

		luma_flag, chroma_flag: [MAX_REFS]bool

		for i in 0 ..< n do luma_flag[i] = get_bits_bit(c) != 0

		if sps_chroma_array_type(s) != 0 {
			for i in 0 ..< n do chroma_flag[i] = get_bits_bit(c) != 0
		}

		for i in 0 ..< n {
			if luma_flag[i] {
				w.luma_weight[l][i] = i16(1 << w.luma_log2_denom) + i16(get_bits_se(c))
				w.luma_offset[l][i] = i16(get_bits_se(c))
			} else {
				w.luma_weight[l][i] = i16(1 << w.luma_log2_denom)
			}

			if !chroma_flag[i] {
				w.chroma_weight[l][i] = [2]i16 {
					i16(1 << w.chroma_log2_denom),
					i16(1 << w.chroma_log2_denom),
				}

				continue
			}

			for j in 0 ..< 2 {
				dw := get_bits_se(c)
				d_off := get_bits_se(c)

				weight := i16(1 << w.chroma_log2_denom) + i16(dw)
				w.chroma_weight[l][i][j] = weight

				off := half + d_off - ((half * i32(weight)) >> w.chroma_log2_denom)
				w.chroma_offset[l][i][j] = i16(clip3(off, -half, half - 1))
			}
		}
	}

	return true
}

clip3 :: proc(v, lo, hi: i32) -> i32 {
	if v < lo do return lo
	if v > hi do return hi

	return v
}

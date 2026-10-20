package vp9_decoder

import vp9 ".."

// Per-frame syntax from the uncompressed and compressed headers.
@(private)
Header :: struct {
	profile:                   int,
	show_existing_frame:       bool,
	frame_to_show:             int,
	frame_type:                int, // 0 key frame, 1 non-key
	show_frame:                bool,
	error_resilient:           bool,
	intra_only:                bool,
	frame_is_intra:            bool,
	reset_frame_context:       int,
	refresh_frame_flags:       int,
	ref_frame_idx:             [3]int,
	sign_bias:                 [4]bool, // by reference frame
	width, height:             int,
	render_width, render_height: int,
	mi_cols, mi_rows:          int,
	sb64_cols, sb64_rows:      int,
	allow_high_precision_mv:   bool,
	interp_filter:             int,
	refresh_frame_context:     bool,
	frame_parallel:            bool,
	frame_context_idx:         int,
	base_q_idx:                int,
	delta_q_y_dc, delta_q_uv_dc, delta_q_uv_ac: int,
	lossless:                  bool,
	tile_cols_log2, tile_rows_log2: int,
	compressed_size:           int,
	uncompressed_size:         int, // bytes
	use_prev_mvs:              bool,
	// Compressed header.
	tx_mode:                   int,
	reference_mode:            int,
	comp_fixed_ref:            int,
	comp_var_ref:              [2]int,
}

@(private)
Bit_Reader :: struct {
	data: []u8,
	pos:  int, // bits
}

@(private)
f :: proc(r: ^Bit_Reader, n: int) -> int {
	x := 0
	for _ in 0 ..< n {
		bit := 0
		if r.pos < len(r.data) * 8 do bit = int(r.data[r.pos >> 3] >> uint(7 - r.pos & 7)) & 1
		r.pos += 1
		x = x << 1 | bit
	}
	return x
}

@(private)
s :: proc(r: ^Bit_Reader, n: int) -> int {
	v := f(r, n)
	return f(r, 1) == 1 ? -v : v
}

@(private)
uncompressed_header :: proc(d: ^Decoder, data: []u8) -> Error {
	r := Bit_Reader{data = data}
	h := &d.h
	h^ = {}
	if f(&r, 2) != 2 do return .Invalid_Data
	low := f(&r, 1)
	h.profile = f(&r, 1) << 1 | low
	if h.profile == 3 && f(&r, 1) != 0 do return .Invalid_Data
	h.show_existing_frame = f(&r, 1) == 1
	if h.show_existing_frame {
		h.frame_to_show = f(&r, 3)
		h.uncompressed_size = (r.pos + 7) / 8
		return .None
	}
	d.last_frame_type = d.frame_type
	h.frame_type = f(&r, 1)
	d.frame_type = h.frame_type
	h.show_frame = f(&r, 1) == 1
	h.error_resilient = f(&r, 1) == 1
	if h.frame_type == 0 {
		frame_sync_code(&r) or_return
		color_config(d, &r, h.profile) or_return
		frame_size(d, &r)
		render_size(&r, h)
		h.refresh_frame_flags = 0xFF
		h.frame_is_intra = true
	} else {
		h.intra_only = h.show_frame ? false : f(&r, 1) == 1
		h.frame_is_intra = h.intra_only
		h.reset_frame_context = h.error_resilient ? 0 : f(&r, 2)
		if h.intra_only {
			frame_sync_code(&r) or_return
			if h.profile > 0 {
				color_config(d, &r, h.profile) or_return
			} else {
				d.color_space, d.ss_x, d.ss_y, d.bit_depth, d.full_range = 1, 1, 1, 8, false
			}
			h.refresh_frame_flags = f(&r, 8)
			frame_size(d, &r)
			render_size(&r, h)
		} else {
			h.refresh_frame_flags = f(&r, 8)
			for i in 0 ..< 3 {
				h.ref_frame_idx[i] = f(&r, 3)
				h.sign_bias[vp9.LAST_FRAME + i] = f(&r, 1) == 1
			}
			found := false
			for i in 0 ..< 3 {
				if f(&r, 1) == 1 {
					ref := d.refs[h.ref_frame_idx[i]]
					if ref == nil do return .Invalid_Data
					h.width, h.height = ref.width, ref.height
					found = true
					break
				}
			}
			if !found {
				frame_size(d, &r)
			} else {
				compute_image_size(d)
			}
			render_size(&r, h)
			h.allow_high_precision_mv = f(&r, 1) == 1
			if f(&r, 1) == 1 {
				h.interp_filter = vp9.SWITCHABLE
			} else {
				h.interp_filter = int(vp9.LITERAL_TO_TYPE[f(&r, 2)])
			}
			// Every reference must exist, match the frame's format and be
			// within the 2x-down / 16x-up scaling range.
			for i in 0 ..< 3 {
				ref := d.refs[h.ref_frame_idx[i]]
				if ref == nil || ref.bit_depth != d.bit_depth || ref.ss_x != d.ss_x || ref.ss_y != d.ss_y do return .Invalid_Data
				if 2 * h.width < ref.width || 2 * h.height < ref.height || h.width > 16 * ref.width || h.height > 16 * ref.height do return .Unsupported
			}
		}
	}
	if !h.error_resilient {
		h.refresh_frame_context = f(&r, 1) == 1
		h.frame_parallel = f(&r, 1) == 1
	} else {
		h.frame_parallel = true
	}
	h.frame_context_idx = f(&r, 2)
	if h.frame_is_intra || h.error_resilient {
		setup_past_independence(d)
		if h.frame_type == 0 || h.error_resilient || h.reset_frame_context == 3 {
			for i in 0 ..< 4 do d.contexts[i] = d.probs
		} else if h.reset_frame_context == 2 {
			d.contexts[h.frame_context_idx] = d.probs
		}
		h.frame_context_idx = 0
	}
	// Loop filter.
	lf := &d.loop_filter
	lf.level = f(&r, 6)
	lf.sharpness = f(&r, 3)
	lf.delta_enabled = f(&r, 1) == 1
	if lf.delta_enabled && f(&r, 1) == 1 {
		for i in 0 ..< 4 do if f(&r, 1) == 1 do lf.ref_deltas[i] = i8(s(&r, 6))
		for i in 0 ..< 2 do if f(&r, 1) == 1 do lf.mode_deltas[i] = i8(s(&r, 6))
	}
	// Quantization.
	h.base_q_idx = f(&r, 8)
	delta_q :: proc(r: ^Bit_Reader) -> int {return f(r, 1) == 1 ? s(r, 4) : 0}
	h.delta_q_y_dc, h.delta_q_uv_dc, h.delta_q_uv_ac = delta_q(&r), delta_q(&r), delta_q(&r)
	h.lossless = h.base_q_idx == 0 && h.delta_q_y_dc == 0 && h.delta_q_uv_dc == 0 && h.delta_q_uv_ac == 0
	// Segmentation.
	seg := &d.segmentation
	seg.enabled = f(&r, 1) == 1
	seg.update_map, seg.temporal_update = false, false
	if seg.enabled {
		read_prob :: proc(r: ^Bit_Reader) -> u8 {return f(r, 1) == 1 ? u8(f(r, 8)) : 255}
		seg.update_map = f(&r, 1) == 1
		if seg.update_map {
			for i in 0 ..< 7 do seg.tree_probs[i] = read_prob(&r)
			seg.temporal_update = f(&r, 1) == 1
			for i in 0 ..< 3 do seg.pred_probs[i] = seg.temporal_update ? read_prob(&r) : 255
		}
		if f(&r, 1) == 1 {
			seg.abs_or_delta_update = f(&r, 1) == 1
			for i in 0 ..< vp9.MAX_SEGMENTS do for j in 0 ..< 4 {
				value := 0
				enabled := f(&r, 1) == 1
				seg.feature_enabled[i][j] = enabled
				if enabled {
					value = f(&r, int(vp9.SEGMENTATION_FEATURE_BITS[j]))
					if vp9.SEGMENTATION_FEATURE_SIGNED[j] == 1 && f(&r, 1) == 1 do value = -value
				}
				seg.feature_data[i][j] = i16(value)
			}
		}
	}
	// Tiles.
	min_log2 := 0
	for (vp9.MAX_TILE_WIDTH_B64 << uint(min_log2)) < h.sb64_cols do min_log2 += 1
	max_log2 := 1
	for (h.sb64_cols >> uint(max_log2)) >= vp9.MIN_TILE_WIDTH_B64 do max_log2 += 1
	max_log2 -= 1
	h.tile_cols_log2 = min_log2
	for h.tile_cols_log2 < max_log2 && f(&r, 1) == 1 do h.tile_cols_log2 += 1
	h.tile_rows_log2 = f(&r, 1)
	if h.tile_rows_log2 == 1 do h.tile_rows_log2 += f(&r, 1)
	h.compressed_size = f(&r, 16)
	h.uncompressed_size = (r.pos + 7) / 8
	if r.pos > len(data) * 8 do return .Invalid_Data
	return .None
}

@(private)
frame_sync_code :: proc(r: ^Bit_Reader) -> Error {
	return f(r, 8) == 0x49 && f(r, 8) == 0x83 && f(r, 8) == 0x42 ? .None : .Invalid_Data
}

@(private)
color_config :: proc(d: ^Decoder, r: ^Bit_Reader, profile: int) -> Error {
	d.bit_depth = 8
	if profile >= 2 do d.bit_depth = f(r, 1) == 1 ? 12 : 10
	d.color_space = f(r, 3)
	if d.color_space != vp9.CS_RGB {
		d.full_range = f(r, 1) == 1
		d.ss_x, d.ss_y = 1, 1
		if profile == 1 || profile == 3 {
			d.ss_x, d.ss_y = f(r, 1), f(r, 1)
			if f(r, 1) != 0 do return .Invalid_Data
		}
	} else {
		d.full_range = true
		if profile == 1 || profile == 3 {
			d.ss_x, d.ss_y = 0, 0
			if f(r, 1) != 0 do return .Invalid_Data
		}
	}
	return .None
}

@(private)
frame_size :: proc(d: ^Decoder, r: ^Bit_Reader) {
	d.h.width, d.h.height = f(r, 16) + 1, f(r, 16) + 1
	compute_image_size(d)
}

@(private)
render_size :: proc(r: ^Bit_Reader, h: ^Header) {
	if f(r, 1) == 1 {
		h.render_width, h.render_height = f(r, 16) + 1, f(r, 16) + 1
	} else {
		h.render_width, h.render_height = h.width, h.height
	}
}

// Section 7.2.6: a size change clears the segmentation map and stops
// motion vector prediction from the previous frame.
@(private)
compute_image_size :: proc(d: ^Decoder) {
	h := &d.h
	h.mi_cols, h.mi_rows = (h.width + 7) >> 3, (h.height + 7) >> 3
	h.sb64_cols, h.sb64_rows = (h.mi_cols + 7) >> 3, (h.mi_rows + 7) >> 3
	same := d.sized && h.width == d.last_width && h.height == d.last_height
	if !same do d.clear_segment_map = true
	h.use_prev_mvs = same && d.last_show_frame && !h.error_resilient && !h.intra_only && h.frame_type != 0
	d.sized = true
	d.last_width, d.last_height = h.width, h.height
}

@(private)
setup_past_independence :: proc(d: ^Decoder) {
	seg := &d.segmentation
	seg.feature_data, seg.feature_enabled = {}, {}
	seg.abs_or_delta_update = false
	d.clear_segment_map = true
	lf := &d.loop_filter
	lf.delta_enabled = true
	lf.ref_deltas = {1, 0, -1, -1}
	lf.mode_deltas = {0, 0}
	vp9.default_probabilities(&d.probs)
}

// ---- Compressed header (section 6.3) --------------------------------------------

@(private)
compressed_header :: proc(d: ^Decoder, b: ^Bool_Decoder) {
	h := &d.h
	p := &d.probs
	if h.lossless {
		h.tx_mode = vp9.ONLY_4X4
	} else {
		h.tx_mode = read_literal(b, 2)
		if h.tx_mode == vp9.ALLOW_32X32 do h.tx_mode += read_literal(b, 1)
	}
	if h.tx_mode == vp9.TX_MODE_SELECT {
		for i in 0 ..< vp9.TX_SIZE_CONTEXTS do for j in 0 ..< 1 do diff_update(b, &p.tx[vp9.TX_8X8][i][j])
		for i in 0 ..< vp9.TX_SIZE_CONTEXTS do for j in 0 ..< 2 do diff_update(b, &p.tx[vp9.TX_16X16][i][j])
		for i in 0 ..< vp9.TX_SIZE_CONTEXTS do for j in 0 ..< 3 do diff_update(b, &p.tx[vp9.TX_32X32][i][j])
	}
	max_tx := int(vp9.TX_MODE_TO_BIGGEST_TX_SIZE[h.tx_mode])
	for tx in 0 ..= max_tx {
		if read_literal(b, 1) == 0 do continue
		for i in 0 ..< 2 do for j in 0 ..< 2 do for k in 0 ..< 6 {
			for l in 0 ..< (k == 0 ? 3 : 6) do for m in 0 ..< 3 do diff_update(b, &p.coef[tx][i][j][k][l][m])
		}
	}
	for i in 0 ..< vp9.SKIP_CONTEXTS do diff_update(b, &p.skip[i])
	if h.frame_is_intra do return
	for i in 0 ..< vp9.INTER_MODE_CONTEXTS do for j in 0 ..< vp9.INTER_MODES - 1 do diff_update(b, &p.inter_mode[i][j])
	if h.interp_filter == vp9.SWITCHABLE {
		for j in 0 ..< vp9.INTERP_FILTER_CONTEXTS do for i in 0 ..< vp9.SWITCHABLE_FILTERS - 1 do diff_update(b, &p.interp_filter[j][i])
	}
	for i in 0 ..< vp9.IS_INTER_CONTEXTS do diff_update(b, &p.is_inter[i])
	// Frame reference mode.
	compound_allowed := false
	for i in 1 ..< 3 do if h.sign_bias[i + 1] != h.sign_bias[1] do compound_allowed = true
	h.reference_mode = vp9.SINGLE_REFERENCE
	if compound_allowed {
		if read_literal(b, 1) == 1 {
			h.reference_mode = read_literal(b, 1) == 1 ? vp9.REFERENCE_MODE_SELECT : vp9.COMPOUND_REFERENCE
		}
		switch {
		case h.sign_bias[vp9.LAST_FRAME] == h.sign_bias[vp9.GOLDEN_FRAME]:
			h.comp_fixed_ref, h.comp_var_ref = vp9.ALTREF_FRAME, {vp9.LAST_FRAME, vp9.GOLDEN_FRAME}
		case h.sign_bias[vp9.LAST_FRAME] == h.sign_bias[vp9.ALTREF_FRAME]:
			h.comp_fixed_ref, h.comp_var_ref = vp9.GOLDEN_FRAME, {vp9.LAST_FRAME, vp9.ALTREF_FRAME}
		case:
			h.comp_fixed_ref, h.comp_var_ref = vp9.LAST_FRAME, {vp9.GOLDEN_FRAME, vp9.ALTREF_FRAME}
		}
	}
	if h.reference_mode == vp9.REFERENCE_MODE_SELECT {
		for i in 0 ..< vp9.COMP_MODE_CONTEXTS do diff_update(b, &p.comp_mode[i])
	}
	if h.reference_mode != vp9.COMPOUND_REFERENCE {
		for i in 0 ..< vp9.REF_CONTEXTS do for j in 0 ..< 2 do diff_update(b, &p.single_ref[i][j])
	}
	if h.reference_mode != vp9.SINGLE_REFERENCE {
		for i in 0 ..< vp9.REF_CONTEXTS do diff_update(b, &p.comp_ref[i])
	}
	for i in 0 ..< vp9.BLOCK_SIZE_GROUPS do for j in 0 ..< vp9.INTRA_MODES - 1 do diff_update(b, &p.y_mode[i][j])
	for i in 0 ..< vp9.PARTITION_CONTEXTS do for j in 0 ..< vp9.PARTITION_TYPES - 1 do diff_update(b, &p.partition[i][j])
	// Motion vector probabilities.
	for j in 0 ..< vp9.MV_JOINTS - 1 do mv_update(b, &p.mv_joint[j])
	for i in 0 ..< 2 {
		mv_update(b, &p.mv_sign[i])
		for j in 0 ..< vp9.MV_CLASSES - 1 do mv_update(b, &p.mv_class[i][j])
		mv_update(b, &p.mv_class0_bit[i])
		for j in 0 ..< vp9.MV_OFFSET_BITS do mv_update(b, &p.mv_bits[i][j])
	}
	for i in 0 ..< 2 {
		for j in 0 ..< vp9.CLASS0_SIZE do for k in 0 ..< vp9.MV_FR_SIZE - 1 do mv_update(b, &p.mv_class0_fr[i][j][k])
		for k in 0 ..< vp9.MV_FR_SIZE - 1 do mv_update(b, &p.mv_fr[i][k])
	}
	if h.allow_high_precision_mv {
		for i in 0 ..< 2 {
			mv_update(b, &p.mv_class0_hp[i])
			mv_update(b, &p.mv_hp[i])
		}
	}
}

@(private)
diff_update :: proc(b: ^Bool_Decoder, prob: ^u8) {
	if read_bool(b, 252) == 0 do return
	delta := decode_term_subexp(b)
	m := int(prob^)
	v := int(vp9.INV_MAP_TABLE[min(delta, 254)])
	m -= 1
	if (m << 1) <= 255 {
		m = 1 + inv_recenter_nonneg(v, m)
	} else {
		m = 255 - inv_recenter_nonneg(v, 255 - 1 - m)
	}
	prob^ = u8(clamp(m, 1, 255))
}

@(private)
decode_term_subexp :: proc(b: ^Bool_Decoder) -> int {
	if read_literal(b, 1) == 0 do return read_literal(b, 4)
	if read_literal(b, 1) == 0 do return read_literal(b, 4) + 16
	if read_literal(b, 1) == 0 do return read_literal(b, 5) + 32
	v := read_literal(b, 7)
	if v < 65 do return v + 64
	return (v << 1) - 1 + read_literal(b, 1)
}

@(private)
inv_recenter_nonneg :: proc(v, m: int) -> int {
	if v > 2 * m do return v
	if v & 1 != 0 do return m - ((v + 1) >> 1)
	return m + (v >> 1)
}

@(private)
mv_update :: proc(b: ^Bool_Decoder, prob: ^u8) {
	if read_bool(b, 252) == 1 do prob^ = u8(read_literal(b, 7) << 1 | 1)
}

package vp9_decoder

import vp9 ".."
import "base:intrinsics"

// One tile's decoding state: its bool decoder, left contexts, symbol counts
// and block scratch. Tiles of a row run concurrently and touch only their
// own columns of the frame-wide above contexts, mode info and samples.
@(private)
Tile :: struct {
	d:              ^Decoder,
	data:           []u8,
	mi_row_start:   int,
	mi_row_end:     int,
	mi_col_start:   int,
	mi_col_end:     int,
	b:              Bool_Decoder,
	err:            Error,
	counts:         vp9.Counts,
	left_partition: [8]u8,
	left_nonzero:   [3][16]u8,
	left_seg_pred:  [8]u8,
	blk:            Block,
	coefs:          [32 * 32]i32,
	token_cache:    [32 * 32]u8,
	scratch:        [64 * 64 * 2]u8, // second compound prediction
}

// The block being decoded (the spec's MiRow, MiSize, y_mode, ...).
@(private)
Block :: struct {
	mi_row, mi_col, mi_size: int,
	avail_u, avail_l:        bool,
	segment_id:              int,
	skip:                    bool,
	tx_size:                 int,
	is_inter:                bool,
	y_mode:                  int,
	sub_modes:               [4]int,
	uv_mode:                 int,
	ref_frame:               [2]int,
	interp_filter:           int,
	block_mvs:               [2][4]vp9.Mv,
	left_ref, above_ref:     [2]int,
	left_intra, above_intra: bool,
	left_single, above_single: bool,
	mode_context:            [4]int,
	ref_list_mv:             [2]vp9.Mv,
	ref_mv_count:            int,
	candidate_mv:            [2]vp9.Mv,
	candidate_frame:         [2]int,
	nearest_mv, near_mv:     [2]vp9.Mv,
	best_mv:                 [2]vp9.Mv,
	mv:                      [2]vp9.Mv,
	eob_total:               int,
}

@(private)
decode_tile :: proc(t: ^Tile, $T: typeid) {
	d := t.d
	if !init_bool(&t.b, t.data) {t.err = .Invalid_Data; return}
	t.counts = {}
	for r := t.mi_row_start; r < t.mi_row_end; r += 8 {
		t.left_partition, t.left_nonzero, t.left_seg_pred = {}, {}, {}
		for c := t.mi_col_start; c < t.mi_col_end; c += 8 {
			decode_partition(t, r, c, vp9.BLOCK_64X64, T)
			if overrun(&t.b) {t.err = .Invalid_Data; return}
		}
	}
	_ = d
}

@(private)
mi_at :: #force_inline proc(d: ^Decoder, r, c: int) -> ^vp9.Mode_Info {
	return &d.mi[r * d.h.mi_cols + c]
}

@(private)
decode_partition :: proc(t: ^Tile, r, c, bsize: int, $T: typeid) {
	d := t.d
	h := &d.h
	if r >= h.mi_rows || c >= h.mi_cols do return
	num8x8 := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[bsize])
	half := num8x8 >> 1
	has_rows := r + half < h.mi_rows
	has_cols := c + half < h.mi_cols
	bsl := uint(vp9.MI_WIDTH_LOG2_LOOKUP[bsize])
	offset := 3 - bsl
	above, left: u8
	for i in 0 ..< num8x8 {
		above |= d.above_partition[c + i]
		left |= t.left_partition[(r + i) & 7]
	}
	ctx := int(bsl) * 4 + int(left >> offset & 1) * 2 + int(above >> offset & 1)
	probs := h.frame_is_intra ? vp9.KF_PARTITION_PROBS[ctx] : d.probs.partition[ctx]
	partition: int
	switch {
	case has_rows && has_cols:
		tree := vp9.PARTITION_TREE
		partition = read_tree(&t.b, tree[:], probs[:])
	case has_cols:
		partition = read_bool(&t.b, probs[1]) == 1 ? vp9.PARTITION_SPLIT : vp9.PARTITION_HORZ
	case has_rows:
		partition = read_bool(&t.b, probs[2]) == 1 ? vp9.PARTITION_SPLIT : vp9.PARTITION_VERT
	case:
		partition = vp9.PARTITION_SPLIT
	}
	t.counts.partition[ctx][partition] += 1
	subsize := int(vp9.SUBSIZE_LOOKUP[partition][bsize])
	switch {
	case subsize < vp9.BLOCK_8X8 || partition == vp9.PARTITION_NONE:
		decode_block(t, r, c, subsize, T)
	case partition == vp9.PARTITION_HORZ:
		decode_block(t, r, c, subsize, T)
		if has_rows do decode_block(t, r + half, c, subsize, T)
	case partition == vp9.PARTITION_VERT:
		decode_block(t, r, c, subsize, T)
		if has_cols do decode_block(t, r, c + half, subsize, T)
	case:
		decode_partition(t, r, c, subsize, T)
		decode_partition(t, r, c + half, subsize, T)
		decode_partition(t, r + half, c, subsize, T)
		decode_partition(t, r + half, c + half, subsize, T)
	}
	if bsize == vp9.BLOCK_8X8 || partition != vp9.PARTITION_SPLIT {
		a := u8(15) >> vp9.B_WIDTH_LOG2_LOOKUP[subsize]
		l := u8(15) >> vp9.B_HEIGHT_LOG2_LOOKUP[subsize]
		for i in 0 ..< num8x8 {
			d.above_partition[c + i] = a
			t.left_partition[(r + i) & 7] = l
		}
	}
}

@(private)
decode_block :: proc(t: ^Tile, r, c, subsize: int, $T: typeid) {
	d := t.d
	h := &d.h
	b := &t.blk
	b^ = {
		mi_row  = r,
		mi_col  = c,
		mi_size = subsize,
		avail_u = r > 0,
		avail_l = c > t.mi_col_start,
	}
	if h.frame_is_intra {
		intra_frame_mode_info(t)
	} else {
		inter_frame_mode_info(t)
	}
	residual(t, T)
	if b.is_inter && subsize >= vp9.BLOCK_8X8 && b.eob_total == 0 do b.skip = true
	m := vp9.Mode_Info {
		ref_frame     = {i8(b.ref_frame[0]), i8(b.ref_frame[1])},
		mi_size       = u8(subsize),
		tx_size       = u8(b.tx_size),
		y_mode        = u8(b.y_mode),
		interp_filter = u8(b.interp_filter),
		segment_id    = u8(b.segment_id),
		skip          = b.skip,
		sub_mvs       = b.block_mvs,
	}
	for i in 0 ..< 4 do m.sub_modes[i] = u8(b.sub_modes[i])
	rows := min(int(vp9.NUM_8X8_BLOCKS_HIGH_LOOKUP[subsize]), h.mi_rows - r)
	cols := min(int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[subsize]), h.mi_cols - c)
	for y in 0 ..< rows do for x in 0 ..< cols do mi_at(d, r + y, c + x)^ = m
}

// ---- Mode info -----------------------------------------------------------------------

@(private)
intra_frame_mode_info :: proc(t: ^Tile) {
	d := t.d
	b := &t.blk
	seg := &d.segmentation
	tree := vp9.INTRA_MODE_TREE
	if seg.enabled && seg.update_map {
		segment_tree := vp9.SEGMENT_TREE
		b.segment_id = read_tree(&t.b, segment_tree[:], seg.tree_probs[:])
	}
	read_skip(t)
	read_tx_size(t, true)
	b.ref_frame = {vp9.INTRA_FRAME, vp9.NONE}
	above_cell := b.avail_u ? mi_at(d, b.mi_row - 1, b.mi_col) : nil
	left_cell := b.avail_l ? mi_at(d, b.mi_row, b.mi_col - 1) : nil
	if b.mi_size >= vp9.BLOCK_8X8 {
		above := above_cell != nil ? int(above_cell.sub_modes[2]) : vp9.DC_PRED
		left := left_cell != nil ? int(left_cell.sub_modes[1]) : vp9.DC_PRED
		b.y_mode = read_tree(&t.b, tree[:], vp9.KF_Y_MODE_PROBS[above][left][:])
		b.sub_modes = b.y_mode
	} else {
		w4, h4 := int(vp9.NUM_4X4_BLOCKS_WIDE_LOOKUP[b.mi_size]), int(vp9.NUM_4X4_BLOCKS_HIGH_LOOKUP[b.mi_size])
		mode: int
		for idy := 0; idy < 2; idy += h4 {
			for idx := 0; idx < 2; idx += w4 {
				above := idy > 0 ? b.sub_modes[idx] : above_cell != nil ? int(above_cell.sub_modes[2 + idx]) : vp9.DC_PRED
				left := idx > 0 ? b.sub_modes[idy * 2] : left_cell != nil ? int(left_cell.sub_modes[1 + idy * 2]) : vp9.DC_PRED
				mode = read_tree(&t.b, tree[:], vp9.KF_Y_MODE_PROBS[above][left][:])
				for y2 in 0 ..< h4 do for x2 in 0 ..< w4 do b.sub_modes[(idy + y2) * 2 + idx + x2] = mode
			}
		}
		b.y_mode = mode
	}
	b.uv_mode = read_tree(&t.b, tree[:], vp9.KF_UV_MODE_PROBS[b.y_mode][:])
}

@(private)
read_skip :: proc(t: ^Tile) {
	d := t.d
	b := &t.blk
	if vp9.seg_feature_active(&d.segmentation, b.segment_id, vp9.SEG_LVL_SKIP) {
		b.skip = true
		return
	}
	ctx := 0
	if b.avail_u && mi_at(d, b.mi_row - 1, b.mi_col).skip do ctx += 1
	if b.avail_l && mi_at(d, b.mi_row, b.mi_col - 1).skip do ctx += 1
	v := read_bool(&t.b, d.probs.skip[ctx])
	t.counts.skip[ctx][v] += 1
	b.skip = v == 1
}

@(private)
read_tx_size :: proc(t: ^Tile, allow_select: bool) {
	d := t.d
	b := &t.blk
	max_tx := int(vp9.MAX_TXSIZE_LOOKUP[b.mi_size])
	if !allow_select || d.h.tx_mode != vp9.TX_MODE_SELECT || b.mi_size < vp9.BLOCK_8X8 {
		b.tx_size = min(max_tx, int(vp9.TX_MODE_TO_BIGGEST_TX_SIZE[d.h.tx_mode]))
		return
	}
	above, left := max_tx, max_tx
	if b.avail_u {
		m := mi_at(d, b.mi_row - 1, b.mi_col)
		if !m.skip do above = int(m.tx_size)
	}
	if b.avail_l {
		m := mi_at(d, b.mi_row, b.mi_col - 1)
		if !m.skip do left = int(m.tx_size)
	}
	if !b.avail_l do left = above
	if !b.avail_u do above = left
	ctx := above + left > max_tx ? 1 : 0
	probs := d.probs.tx[max_tx][ctx][:]
	switch max_tx {
	case vp9.TX_32X32:
		tree := vp9.TX_SIZE_32_TREE
		b.tx_size = read_tree(&t.b, tree[:], probs)
	case vp9.TX_16X16:
		tree := vp9.TX_SIZE_16_TREE
		b.tx_size = read_tree(&t.b, tree[:], probs)
	case:
		tree := vp9.TX_SIZE_8_TREE
		b.tx_size = read_tree(&t.b, tree[:], probs)
	}
	t.counts.tx_size[max_tx][ctx][b.tx_size] += 1
}

@(private)
inter_frame_mode_info :: proc(t: ^Tile) {
	d := t.d
	b := &t.blk
	b.left_ref, b.above_ref = {vp9.INTRA_FRAME, vp9.NONE}, {vp9.INTRA_FRAME, vp9.NONE}
	if b.avail_l {
		m := mi_at(d, b.mi_row, b.mi_col - 1)
		b.left_ref = {int(m.ref_frame[0]), int(m.ref_frame[1])}
	}
	if b.avail_u {
		m := mi_at(d, b.mi_row - 1, b.mi_col)
		b.above_ref = {int(m.ref_frame[0]), int(m.ref_frame[1])}
	}
	b.left_intra, b.above_intra = b.left_ref[0] <= vp9.INTRA_FRAME, b.above_ref[0] <= vp9.INTRA_FRAME
	b.left_single, b.above_single = b.left_ref[1] <= vp9.NONE, b.above_ref[1] <= vp9.NONE
	inter_segment_id(t)
	read_skip(t)
	read_is_inter(t)
	read_tx_size(t, !b.skip || !b.is_inter)
	if b.is_inter {
		inter_block_mode_info(t)
	} else {
		intra_block_mode_info(t)
	}
}

@(private)
inter_segment_id :: proc(t: ^Tile) {
	d := t.d
	b := &t.blk
	seg := &d.segmentation
	if !seg.enabled do return
	h := &d.h
	bw, bh := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[b.mi_size]), int(vp9.NUM_8X8_BLOCKS_HIGH_LOOKUP[b.mi_size])
	predicted := 7
	for y in 0 ..< min(h.mi_rows - b.mi_row, bh) {
		for x in 0 ..< min(h.mi_cols - b.mi_col, bw) do predicted = min(predicted, int(d.prev_segment_ids[(b.mi_row + y) * h.mi_cols + b.mi_col + x]))
	}
	if !seg.update_map {
		b.segment_id = predicted
		return
	}
	segment_tree := vp9.SEGMENT_TREE
	if !seg.temporal_update {
		b.segment_id = read_tree(&t.b, segment_tree[:], seg.tree_probs[:])
		return
	}
	ctx := int(t.left_seg_pred[b.mi_row & 7]) + int(d.above_seg_pred[b.mi_col])
	pred := read_bool(&t.b, seg.pred_probs[ctx])
	b.segment_id = pred == 1 ? predicted : read_tree(&t.b, segment_tree[:], seg.tree_probs[:])
	for i in 0 ..< bw do d.above_seg_pred[b.mi_col + i] = u8(pred)
	for i in 0 ..< bh do t.left_seg_pred[(b.mi_row + i) & 7] = u8(pred)
}

@(private)
read_is_inter :: proc(t: ^Tile) {
	d := t.d
	b := &t.blk
	seg := &d.segmentation
	if vp9.seg_feature_active(seg, b.segment_id, vp9.SEG_LVL_REF_FRAME) {
		b.is_inter = seg.feature_data[b.segment_id][vp9.SEG_LVL_REF_FRAME] != vp9.INTRA_FRAME
		return
	}
	ctx := 0
	switch {
	case b.avail_u && b.avail_l:
		ctx = b.left_intra && b.above_intra ? 3 : b.left_intra || b.above_intra ? 1 : 0
	case b.avail_u || b.avail_l:
		ctx = 2 * int(b.avail_u ? b.above_intra : b.left_intra)
	}
	v := read_bool(&t.b, d.probs.is_inter[ctx])
	t.counts.is_inter[ctx][v] += 1
	b.is_inter = v == 1
}

@(private)
intra_block_mode_info :: proc(t: ^Tile) {
	d := t.d
	b := &t.blk
	tree := vp9.INTRA_MODE_TREE
	b.ref_frame = {vp9.INTRA_FRAME, vp9.NONE}
	if b.mi_size >= vp9.BLOCK_8X8 {
		ctx := int(vp9.SIZE_GROUP_LOOKUP[b.mi_size])
		b.y_mode = read_tree(&t.b, tree[:], d.probs.y_mode[ctx][:])
		t.counts.intra_mode[ctx][b.y_mode] += 1
		b.sub_modes = b.y_mode
	} else {
		w4, h4 := int(vp9.NUM_4X4_BLOCKS_WIDE_LOOKUP[b.mi_size]), int(vp9.NUM_4X4_BLOCKS_HIGH_LOOKUP[b.mi_size])
		mode: int
		for idy := 0; idy < 2; idy += h4 {
			for idx := 0; idx < 2; idx += w4 {
				mode = read_tree(&t.b, tree[:], d.probs.y_mode[0][:])
				t.counts.intra_mode[0][mode] += 1
				for y2 in 0 ..< h4 do for x2 in 0 ..< w4 do b.sub_modes[(idy + y2) * 2 + idx + x2] = mode
			}
		}
		b.y_mode = mode
	}
	b.uv_mode = read_tree(&t.b, tree[:], d.probs.uv_mode[b.y_mode][:])
	t.counts.uv_mode[b.y_mode][b.uv_mode] += 1
}

@(private)
inter_block_mode_info :: proc(t: ^Tile) {
	d := t.d
	h := &d.h
	b := &t.blk
	read_ref_frames(t)
	for j in 0 ..< 2 {
		if b.ref_frame[j] > vp9.INTRA_FRAME {
			find_mv_refs(t, b.ref_frame[j], -1)
			find_best_ref_mvs(t, j)
		}
	}
	compound := b.ref_frame[1] > vp9.INTRA_FRAME
	inter_mode_tree := vp9.INTER_MODE_TREE
	if vp9.seg_feature_active(&d.segmentation, b.segment_id, vp9.SEG_LVL_SKIP) {
		b.y_mode = vp9.ZEROMV
	} else if b.mi_size >= vp9.BLOCK_8X8 {
		ctx := b.mode_context[b.ref_frame[0]]
		mode := read_tree(&t.b, inter_mode_tree[:], d.probs.inter_mode[ctx][:])
		t.counts.inter_mode[ctx][mode] += 1
		b.y_mode = vp9.NEARESTMV + mode
	}
	if h.interp_filter == vp9.SWITCHABLE {
		left := b.avail_l && b.left_ref[0] > vp9.INTRA_FRAME ? int(mi_at(d, b.mi_row, b.mi_col - 1).interp_filter) : 3
		above := b.avail_u && b.above_ref[0] > vp9.INTRA_FRAME ? int(mi_at(d, b.mi_row - 1, b.mi_col).interp_filter) : 3
		ctx := 3
		switch {
		case left == above:
			ctx = left
		case left == 3 && above != 3:
			ctx = above
		case left != 3 && above == 3:
			ctx = left
		}
		tree := vp9.INTERP_FILTER_TREE
		b.interp_filter = read_tree(&t.b, tree[:], d.probs.interp_filter[ctx][:])
		t.counts.interp_filter[ctx][b.interp_filter] += 1
	} else {
		b.interp_filter = h.interp_filter
	}
	if b.mi_size < vp9.BLOCK_8X8 {
		w4, h4 := int(vp9.NUM_4X4_BLOCKS_WIDE_LOOKUP[b.mi_size]), int(vp9.NUM_4X4_BLOCKS_HIGH_LOOKUP[b.mi_size])
		for idy := 0; idy < 2; idy += h4 {
			for idx := 0; idx < 2; idx += w4 {
				ctx := b.mode_context[b.ref_frame[0]]
				mode := read_tree(&t.b, inter_mode_tree[:], d.probs.inter_mode[ctx][:])
				t.counts.inter_mode[ctx][mode] += 1
				b.y_mode = vp9.NEARESTMV + mode
				if b.y_mode == vp9.NEARESTMV || b.y_mode == vp9.NEARMV {
					for j in 0 ..< 1 + int(compound) do append_sub8x8_mvs(t, idy * 2 + idx, j)
				}
				assign_mv(t, compound)
				for y2 in 0 ..< h4 do for x2 in 0 ..< w4 {
					block := (idy + y2) * 2 + idx + x2
					for l in 0 ..< 1 + int(compound) do b.block_mvs[l][block] = b.mv[l]
				}
			}
		}
	} else {
		assign_mv(t, compound)
		for l in 0 ..< 1 + int(compound) do for block in 0 ..< 4 do b.block_mvs[l][block] = b.mv[l]
	}
}

@(private)
read_ref_frames :: proc(t: ^Tile) {
	d := t.d
	h := &d.h
	b := &t.blk
	seg := &d.segmentation
	if vp9.seg_feature_active(seg, b.segment_id, vp9.SEG_LVL_REF_FRAME) {
		b.ref_frame = {int(seg.feature_data[b.segment_id][vp9.SEG_LVL_REF_FRAME]), vp9.NONE}
		return
	}
	comp_mode := h.reference_mode
	if h.reference_mode == vp9.REFERENCE_MODE_SELECT {
		ctx := comp_mode_ctx(t)
		comp_mode = read_bool(&t.b, d.probs.comp_mode[ctx])
		t.counts.comp_mode[ctx][comp_mode] += 1
	}
	if comp_mode == vp9.COMPOUND_REFERENCE {
		idx := int(h.sign_bias[h.comp_fixed_ref])
		ctx := comp_ref_ctx(t)
		comp_ref := read_bool(&t.b, d.probs.comp_ref[ctx])
		t.counts.comp_ref[ctx][comp_ref] += 1
		b.ref_frame[idx] = h.comp_fixed_ref
		b.ref_frame[1 - idx] = h.comp_var_ref[comp_ref]
	} else {
		ctx := single_ref_p1_ctx(t)
		p1 := read_bool(&t.b, d.probs.single_ref[ctx][0])
		t.counts.single_ref[ctx][0][p1] += 1
		if p1 == 1 {
			ctx2 := single_ref_p2_ctx(t)
			p2 := read_bool(&t.b, d.probs.single_ref[ctx2][1])
			t.counts.single_ref[ctx2][1][p2] += 1
			b.ref_frame[0] = p2 == 1 ? vp9.ALTREF_FRAME : vp9.GOLDEN_FRAME
		} else {
			b.ref_frame[0] = vp9.LAST_FRAME
		}
		b.ref_frame[1] = vp9.NONE
	}
}

@(private)
comp_mode_ctx :: proc(t: ^Tile) -> int {
	b := &t.blk
	fixed := t.d.h.comp_fixed_ref
	switch {
	case b.avail_u && b.avail_l:
		switch {
		case b.above_single && b.left_single:
			return int(b.above_ref[0] == fixed) ~ int(b.left_ref[0] == fixed)
		case b.above_single:
			return 2 + int(b.above_ref[0] == fixed || b.above_intra)
		case b.left_single:
			return 2 + int(b.left_ref[0] == fixed || b.left_intra)
		}
		return 4
	case b.avail_u:
		return b.above_single ? int(b.above_ref[0] == fixed) : 3
	case b.avail_l:
		return b.left_single ? int(b.left_ref[0] == fixed) : 3
	}
	return 1
}

@(private)
comp_ref_ctx :: proc(t: ^Tile) -> int {
	b := &t.blk
	h := &t.d.h
	var_idx := 1 - int(h.sign_bias[h.comp_fixed_ref])
	var1 := h.comp_var_ref[1]
	switch {
	case b.avail_u && b.avail_l:
		switch {
		case b.above_intra && b.left_intra:
			return 2
		case b.left_intra:
			return 1 + 2 * int((b.above_single ? b.above_ref[0] : b.above_ref[var_idx]) != var1)
		case b.above_intra:
			return 1 + 2 * int((b.left_single ? b.left_ref[0] : b.left_ref[var_idx]) != var1)
		}
		vrfa := b.above_single ? b.above_ref[0] : b.above_ref[var_idx]
		vrfl := b.left_single ? b.left_ref[0] : b.left_ref[var_idx]
		switch {
		case vrfa == vrfl && var1 == vrfa:
			return 0
		case b.left_single && b.above_single:
			if vrfa == h.comp_fixed_ref && vrfl == h.comp_var_ref[0] || vrfl == h.comp_fixed_ref && vrfa == h.comp_var_ref[0] do return 4
			return vrfa == vrfl ? 3 : 1
		case b.left_single || b.above_single:
			vrfc := b.left_single ? vrfa : vrfl
			rfs := b.above_single ? vrfa : vrfl
			if vrfc == var1 && rfs != var1 do return 1
			if rfs == var1 && vrfc != var1 do return 2
			return 4
		case vrfa == vrfl:
			return 4
		}
		return 2
	case b.avail_u:
		if b.above_intra do return 2
		return b.above_single ? 3 * int(b.above_ref[0] != var1) : 4 * int(b.above_ref[var_idx] != var1)
	case b.avail_l:
		if b.left_intra do return 2
		return b.left_single ? 3 * int(b.left_ref[0] != var1) : 4 * int(b.left_ref[var_idx] != var1)
	}
	return 2
}

@(private)
single_ref_p1_ctx :: proc(t: ^Tile) -> int {
	b := &t.blk
	LAST :: vp9.LAST_FRAME
	switch {
	case b.avail_u && b.avail_l:
		switch {
		case b.above_intra && b.left_intra:
			return 2
		case b.left_intra:
			return b.above_single ? 4 * int(b.above_ref[0] == LAST) : 1 + int(b.above_ref[0] == LAST || b.above_ref[1] == LAST)
		case b.above_intra:
			return b.left_single ? 4 * int(b.left_ref[0] == LAST) : 1 + int(b.left_ref[0] == LAST || b.left_ref[1] == LAST)
		case b.above_single && b.left_single:
			return 2 * int(b.above_ref[0] == LAST) + 2 * int(b.left_ref[0] == LAST)
		case !b.above_single && !b.left_single:
			return 1 + int(b.above_ref[0] == LAST || b.above_ref[1] == LAST || b.left_ref[0] == LAST || b.left_ref[1] == LAST)
		}
		rfs := b.above_single ? b.above_ref[0] : b.left_ref[0]
		crf1 := b.above_single ? b.left_ref[0] : b.above_ref[0]
		crf2 := b.above_single ? b.left_ref[1] : b.above_ref[1]
		if rfs == LAST do return 3 + int(crf1 == LAST || crf2 == LAST)
		return int(crf1 == LAST || crf2 == LAST)
	case b.avail_u:
		if b.above_intra do return 2
		return b.above_single ? 4 * int(b.above_ref[0] == LAST) : 1 + int(b.above_ref[0] == LAST || b.above_ref[1] == LAST)
	case b.avail_l:
		if b.left_intra do return 2
		return b.left_single ? 4 * int(b.left_ref[0] == LAST) : 1 + int(b.left_ref[0] == LAST || b.left_ref[1] == LAST)
	}
	return 2
}

@(private)
single_ref_p2_ctx :: proc(t: ^Tile) -> int {
	b := &t.blk
	LAST :: vp9.LAST_FRAME
	GOLDEN :: vp9.GOLDEN_FRAME
	ALTREF :: vp9.ALTREF_FRAME
	switch {
	case b.avail_u && b.avail_l:
		switch {
		case b.above_intra && b.left_intra:
			return 2
		case b.left_intra:
			if b.above_single {
				if b.above_ref[0] == LAST do return 3
				return 4 * int(b.above_ref[0] == GOLDEN)
			}
			return 1 + 2 * int(b.above_ref[0] == GOLDEN || b.above_ref[1] == GOLDEN)
		case b.above_intra:
			if b.left_single {
				if b.left_ref[0] == LAST do return 3
				return 4 * int(b.left_ref[0] == GOLDEN)
			}
			return 1 + 2 * int(b.left_ref[0] == GOLDEN || b.left_ref[1] == GOLDEN)
		case b.above_single && b.left_single:
			a, l := b.above_ref[0], b.left_ref[0]
			switch {
			case a == LAST && l == LAST:
				return 3
			case a == LAST:
				return 4 * int(l == GOLDEN)
			case l == LAST:
				return 4 * int(a == GOLDEN)
			}
			return 2 * int(a == GOLDEN) + 2 * int(l == GOLDEN)
		case !b.above_single && !b.left_single:
			if b.above_ref[0] == b.left_ref[0] && b.above_ref[1] == b.left_ref[1] {
				return 3 * int(b.above_ref[0] == GOLDEN || b.above_ref[1] == GOLDEN)
			}
			return 2
		}
		rfs := b.above_single ? b.above_ref[0] : b.left_ref[0]
		crf1 := b.above_single ? b.left_ref[0] : b.above_ref[0]
		crf2 := b.above_single ? b.left_ref[1] : b.above_ref[1]
		if rfs == GOLDEN do return 3 + int(crf1 == GOLDEN || crf2 == GOLDEN)
		if rfs == ALTREF do return int(crf1 == GOLDEN || crf2 == GOLDEN)
		return 1 + 2 * int(crf1 == GOLDEN || crf2 == GOLDEN)
	case b.avail_u:
		if b.above_intra || b.above_ref[0] == LAST && b.above_single do return 2
		if b.above_single do return 4 * int(b.above_ref[0] == GOLDEN)
		return 3 * int(b.above_ref[0] == GOLDEN || b.above_ref[1] == GOLDEN)
	case b.avail_l:
		if b.left_intra || b.left_ref[0] == LAST && b.left_single do return 2
		if b.left_single do return 4 * int(b.left_ref[0] == GOLDEN)
		return 3 * int(b.left_ref[0] == GOLDEN || b.left_ref[1] == GOLDEN)
	}
	return 2
}

// ---- Motion vectors ----------------------------------------------------------------

@(private)
assign_mv :: proc(t: ^Tile, compound: bool) {
	b := &t.blk
	b.mv[1] = {}
	for i in 0 ..< 1 + int(compound) {
		switch b.y_mode {
		case vp9.NEWMV:
			read_mv(t, i)
		case vp9.NEARESTMV:
			b.mv[i] = b.nearest_mv[i]
		case vp9.NEARMV:
			b.mv[i] = b.near_mv[i]
		case:
			b.mv[i] = {}
		}
	}
}

@(private)
use_mv_hp :: #force_inline proc(mv: vp9.Mv) -> bool {
	return abs(int(mv[0])) >> 3 < vp9.COMPANDED_MVREF_THRESH && abs(int(mv[1])) >> 3 < vp9.COMPANDED_MVREF_THRESH
}

@(private)
read_mv :: proc(t: ^Tile, ref: int) {
	d := t.d
	b := &t.blk
	use_hp := d.h.allow_high_precision_mv && use_mv_hp(b.best_mv[ref])
	tree := vp9.MV_JOINT_TREE
	joint := read_tree(&t.b, tree[:], d.probs.mv_joint[:])
	t.counts.mv_joint[joint] += 1
	diff: [2]int
	if joint == vp9.MV_JOINT_HZVNZ || joint == vp9.MV_JOINT_HNZVNZ do diff[0] = read_mv_component(t, 0, use_hp)
	if joint == vp9.MV_JOINT_HNZVZ || joint == vp9.MV_JOINT_HNZVNZ do diff[1] = read_mv_component(t, 1, use_hp)
	b.mv[ref] = {i16(int(b.best_mv[ref][0]) + diff[0]), i16(int(b.best_mv[ref][1]) + diff[1])}
}

@(private)
read_mv_component :: proc(t: ^Tile, comp: int, use_hp: bool) -> int {
	p := &t.d.probs
	c := &t.counts
	sign := read_bool(&t.b, p.mv_sign[comp])
	c.mv_sign[comp][sign] += 1
	class_tree, fr_tree := vp9.MV_CLASS_TREE, vp9.MV_FR_TREE
	class := read_tree(&t.b, class_tree[:], p.mv_class[comp][:])
	c.mv_class[comp][class] += 1
	mag: int
	if class == 0 {
		bit := read_bool(&t.b, p.mv_class0_bit[comp])
		c.mv_class0_bit[comp][bit] += 1
		fr := read_tree(&t.b, fr_tree[:], p.mv_class0_fr[comp][bit][:])
		c.mv_class0_fr[comp][bit][fr] += 1
		hp := use_hp ? read_bool(&t.b, p.mv_class0_hp[comp]) : 1
		c.mv_class0_hp[comp][hp] += 1
		mag = (bit << 3 | fr << 1 | hp) + 1
	} else {
		bits := 0
		for i in 0 ..< class {
			bit := read_bool(&t.b, p.mv_bits[comp][i])
			c.mv_bits[comp][i][bit] += 1
			bits |= bit << uint(i)
		}
		mag = vp9.CLASS0_SIZE << uint(class + 2)
		fr := read_tree(&t.b, fr_tree[:], p.mv_fr[comp][:])
		c.mv_fr[comp][fr] += 1
		hp := use_hp ? read_bool(&t.b, p.mv_hp[comp]) : 1
		c.mv_hp[comp][hp] += 1
		mag += (bits << 3 | fr << 1 | hp) + 1
	}
	return sign == 1 ? -mag : mag
}

@(private)
is_inside :: #force_inline proc(t: ^Tile, r, c: int) -> bool {
	return r >= 0 && r < t.d.h.mi_rows && c >= t.mi_col_start && c < t.mi_col_end
}

@(private)
clamp_mv_row :: #force_inline proc(t: ^Tile, v, border: int) -> int {
	b := &t.blk
	bh := int(vp9.NUM_8X8_BLOCKS_HIGH_LOOKUP[b.mi_size])
	to_top := -(b.mi_row * 8 * 8)
	to_bottom := (t.d.h.mi_rows - bh - b.mi_row) * 8 * 8
	return clamp(v, to_top - border, to_bottom + border)
}

@(private)
clamp_mv_col :: #force_inline proc(t: ^Tile, v, border: int) -> int {
	b := &t.blk
	bw := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[b.mi_size])
	to_left := -(b.mi_col * 8 * 8)
	to_right := (t.d.h.mi_cols - bw - b.mi_col) * 8 * 8
	return clamp(v, to_left - border, to_right + border)
}

@(private)
add_mv_ref_list :: #force_inline proc(b: ^Block, list: int) {
	if b.ref_mv_count >= 2 do return
	if b.ref_mv_count > 0 && b.candidate_mv[list] == b.ref_list_mv[0] do return
	b.ref_list_mv[b.ref_mv_count] = b.candidate_mv[list]
	b.ref_mv_count += 1
}

@(private)
get_block_mv :: #force_inline proc(t: ^Tile, r, c, list: int, use_prev: bool) {
	b := &t.blk
	grid := use_prev ? &t.d.prev_mi : &t.d.mi
	m := &grid[r * t.d.h.mi_cols + c]
	b.candidate_mv[list] = m.sub_mvs[list][3]
	b.candidate_frame[list] = int(m.ref_frame[list])
}

@(private)
if_same_ref_frame_add :: proc(t: ^Tile, r, c, ref_frame: int, use_prev: bool) {
	b := &t.blk
	for j in 0 ..< 2 {
		get_block_mv(t, r, c, j, use_prev)
		if b.candidate_frame[j] == ref_frame {
			add_mv_ref_list(b, j)
			return
		}
	}
}

@(private)
if_diff_ref_frame_add :: proc(t: ^Tile, r, c, ref_frame: int, use_prev: bool) {
	b := &t.blk
	h := &t.d.h
	for j in 0 ..< 2 do get_block_mv(t, r, c, j, use_prev)
	same := b.candidate_mv[0] == b.candidate_mv[1]
	scale :: proc(b: ^Block, h: ^Header, list, ref_frame: int) {
		if h.sign_bias[b.candidate_frame[list]] != h.sign_bias[ref_frame] do b.candidate_mv[list] = -b.candidate_mv[list]
	}
	if b.candidate_frame[0] > vp9.INTRA_FRAME && b.candidate_frame[0] != ref_frame {
		scale(b, h, 0, ref_frame)
		add_mv_ref_list(b, 0)
	}
	if b.candidate_frame[1] > vp9.INTRA_FRAME && b.candidate_frame[1] != ref_frame && !same {
		scale(b, h, 1, ref_frame)
		add_mv_ref_list(b, 1)
	}
}

// Section 6.5.1: up to two candidate vectors from the neighbourhood (and
// the previous frame), and the inter mode context.
@(private)
find_mv_refs :: proc(t: ^Tile, ref_frame, block: int) {
	d := t.d
	b := &t.blk
	b.ref_mv_count = 0
	b.ref_list_mv = {}
	different_ref_found := false
	context_counter := 0
	search := &vp9.MV_REF_BLOCKS[b.mi_size]
	for i in 0 ..< 2 {
		r, c := b.mi_row + int(search[i][0]), b.mi_col + int(search[i][1])
		if !is_inside(t, r, c) do continue
		m := mi_at(d, r, c)
		different_ref_found = true
		context_counter += int(vp9.MODE_2_COUNTER[m.y_mode])
		for j in 0 ..< 2 {
			if int(m.ref_frame[j]) == ref_frame {
				idx := block >= 0 ? int(vp9.IDX_N_COLUMN_TO_SUBBLOCK[block][search[i][1] == 0 ? 1 : 0]) : 3
				b.candidate_mv[j] = m.sub_mvs[j][idx]
				add_mv_ref_list(b, j)
				break
			}
		}
	}
	for i in 2 ..< 8 {
		r, c := b.mi_row + int(search[i][0]), b.mi_col + int(search[i][1])
		if !is_inside(t, r, c) do continue
		different_ref_found = true
		if_same_ref_frame_add(t, r, c, ref_frame, false)
	}
	if d.h.use_prev_mvs do if_same_ref_frame_add(t, b.mi_row, b.mi_col, ref_frame, true)
	if different_ref_found {
		for i in 0 ..< 8 {
			r, c := b.mi_row + int(search[i][0]), b.mi_col + int(search[i][1])
			if is_inside(t, r, c) do if_diff_ref_frame_add(t, r, c, ref_frame, false)
		}
	}
	if d.h.use_prev_mvs do if_diff_ref_frame_add(t, b.mi_row, b.mi_col, ref_frame, true)
	b.mode_context[ref_frame] = int(vp9.COUNTER_TO_CONTEXT[context_counter])
	for i in 0 ..< 2 {
		b.ref_list_mv[i] = {i16(clamp_mv_row(t, int(b.ref_list_mv[i][0]), vp9.MV_BORDER)), i16(clamp_mv_col(t, int(b.ref_list_mv[i][1]), vp9.MV_BORDER))}
	}
}

@(private)
find_best_ref_mvs :: proc(t: ^Tile, list: int) {
	b := &t.blk
	allow_hp := t.d.h.allow_high_precision_mv
	border := (vp9.BORDERINPIXELS - vp9.INTERP_EXTEND) << 3
	for i in 0 ..< 2 {
		row, col := int(b.ref_list_mv[i][0]), int(b.ref_list_mv[i][1])
		if !allow_hp || !use_mv_hp(b.ref_list_mv[i]) {
			if row & 1 != 0 do row += row > 0 ? -1 : 1
			if col & 1 != 0 do col += col > 0 ? -1 : 1
		}
		b.ref_list_mv[i] = {i16(clamp_mv_row(t, row, border)), i16(clamp_mv_col(t, col, border))}
	}
	b.nearest_mv[list] = b.ref_list_mv[0]
	b.near_mv[list] = b.ref_list_mv[1]
	b.best_mv[list] = b.ref_list_mv[0]
}

@(private)
append_sub8x8_mvs :: proc(t: ^Tile, block, list: int) {
	b := &t.blk
	find_mv_refs(t, b.ref_frame[list], block)
	candidates: [2]vp9.Mv
	n := 0
	switch {
	case block == 0:
		candidates = b.ref_list_mv
		n = 2
	case block <= 2:
		candidates[0] = b.block_mvs[list][0]
		n = 1
	case:
		candidates[0] = b.block_mvs[list][2]
		n = 1
		for idx := 1; idx >= 0 && n < 2; idx -= 1 {
			if b.block_mvs[list][idx] != candidates[0] {candidates[n] = b.block_mvs[list][idx]; n += 1}
		}
	}
	for k in 0 ..< 2 {
		if n >= 2 do break
		if b.ref_list_mv[k] != candidates[0] {candidates[n] = b.ref_list_mv[k]; n += 1}
	}
	if n < 2 do candidates[n] = {}
	b.nearest_mv[list] = candidates[0]
	b.near_mv[list] = candidates[1]
}

// ---- Residual and reconstruction ------------------------------------------------------

@(private)
residual :: proc(t: ^Tile, $T: typeid) {
	d := t.d
	h := &d.h
	b := &t.blk
	bsize := max(b.mi_size, vp9.BLOCK_8X8)
	for p in 0 ..< 3 {
		sub_x, sub_y := p > 0 ? d.ss_x : 0, p > 0 ? d.ss_y : 0
		tx := p > 0 ? vp9.uv_tx_size(b.mi_size, b.tx_size, d.ss_x, d.ss_y) : b.tx_size
		step := 1 << uint(tx)
		plane_size := int(vp9.SS_SIZE_LOOKUP[bsize][sub_x][sub_y])
		w4, h4 := int(vp9.NUM_4X4_BLOCKS_WIDE_LOOKUP[plane_size]), int(vp9.NUM_4X4_BLOCKS_HIGH_LOOKUP[plane_size])
		base_x, base_y := (b.mi_col * 8) >> uint(sub_x), (b.mi_row * 8) >> uint(sub_y)
		if b.is_inter {
			if b.mi_size < vp9.BLOCK_8X8 {
				for y in 0 ..< h4 do for x in 0 ..< w4 do predict_inter(t, p, base_x + 4 * x, base_y + 4 * y, 4, 4, y * w4 + x, T)
			} else {
				predict_inter(t, p, base_x, base_y, w4 * 4, h4 * 4, 0, T)
			}
		}
		max_x, max_y := (h.mi_cols * 8) >> uint(sub_x), (h.mi_rows * 8) >> uint(sub_y)
		frame := plane(d.cur, p, T)
		stride := d.cur.strides[p]
		above := d.above_nonzero[p][:]
		left := &t.left_nonzero[p]
		block_idx := 0
		for y := 0; y < h4; y += step {
			for x := 0; x < w4; x += step {
				start_x, start_y := base_x + 4 * x, base_y + 4 * y
				nonzero := false
				if start_x < max_x && start_y < max_y {
					if !b.is_inter {
						mode := p > 0 ? b.uv_mode : b.mi_size >= vp9.BLOCK_8X8 ? b.y_mode : b.sub_modes[block_idx]
						edges := vp9.Intra_Edges {
							have_left    = b.avail_l || x > 0,
							have_above   = b.avail_u || y > 0,
							not_on_right = x + step < w4,
							max_x        = max_x - 1,
							max_y        = max_y - 1,
						}
						vp9.predict_intra(frame, stride, start_x, start_y, tx, mode, edges, d.bit_depth)
					}
					if !b.skip {
						eob, rows, tx_type := tokens(t, p, start_x, start_y, tx, block_idx, max_x, max_y)
						nonzero = eob > 0
						b.eob_total += int(nonzero)
						if nonzero do reconstruct(t, frame[start_y * stride + start_x:], stride, tx, tx_type, rows)
					}
				}
				for i in 0 ..< step {
					above[(start_x >> 2) + i] = u8(nonzero)
					left[((start_y >> 2) + i) & 15] = u8(nonzero)
				}
				block_idx += 1
			}
		}
	}
}

// Reads one transform block's coefficients (section 6.4.24) into t.coefs,
// dequantized, in raster order. Returns the end of block, the number of
// leading rows holding coefficients, and the transform type.
@(private)
tokens :: proc(t: ^Tile, p, start_x, start_y, tx, block_idx, max_x, max_y: int) -> (eob, rows, tx_type: int) {
	d := t.d
	h := &d.h
	b := &t.blk
	n := 4 << uint(tx)
	seg_eob := 16 << uint(tx << 1)
	// Transform type and scan.
	tx_type = vp9.DCT_DCT
	if p == 0 && tx != vp9.TX_32X32 {
		if tx == vp9.TX_4X4 {
			if !h.lossless && !b.is_inter do tx_type = int(vp9.MODE2TXFM_MAP[b.mi_size < vp9.BLOCK_8X8 ? b.sub_modes[block_idx] : b.y_mode])
		} else {
			tx_type = int(vp9.MODE2TXFM_MAP[b.y_mode])
		}
	}
	scan := scan_for(tx, tx_type)
	coefs := t.coefs[:n * n]
	intrinsics.mem_zero(raw_data(coefs), len(coefs) * size_of(i32))
	probs := &d.probs.coef[tx][min(p, 1)][int(b.is_inter)]
	counts_token := &t.counts.token[tx][min(p, 1)][int(b.is_inter)]
	counts_more := &t.counts.more_coefs[tx][min(p, 1)][int(b.is_inter)]
	// Dequantizers of this block's segment.
	q := vp9.segment_qindex(&d.segmentation, h.base_q_idx, b.segment_id)
	dc, ac: i32
	if p == 0 {
		dc, ac = vp9.dc_q(d.bit_depth, q + h.delta_q_y_dc), vp9.ac_q(d.bit_depth, q)
	} else {
		dc, ac = vp9.dc_q(d.bit_depth, q + h.delta_q_uv_dc), vp9.ac_q(d.bit_depth, q + h.delta_q_uv_ac)
	}
	shift: uint = tx == vp9.TX_32X32 ? 1 : 0
	// First coefficient context from the neighbouring blocks.
	sub_x, sub_y := p > 0 ? d.ss_x : 0, p > 0 ? d.ss_y : 0
	ctx_max_x, ctx_max_y := (2 * h.mi_cols) >> uint(sub_x), (2 * h.mi_rows) >> uint(sub_y)
	x4, y4 := start_x >> 2, start_y >> 2
	above, left: u8
	for i in 0 ..< 1 << uint(tx) {
		if x4 + i < ctx_max_x do above |= d.above_nonzero[p][x4 + i]
		if y4 + i < ctx_max_y do left |= t.left_nonzero[p][(y4 + i) & 15]
	}
	ctx := int(above) + int(left)
	cache := t.token_cache[:]
	check_eob := true
	bit_depth := d.bit_depth
	max_row := 0
	c := 0
	for ; c < seg_eob; c += 1 {
		pos := int(scan[c])
		band := tx == vp9.TX_4X4 ? int(vp9.COEFBAND_4X4[c]) : int(vp9.COEFBAND_8X8PLUS[c])
		if c > 0 {
			// Neighbours above and to the left in the transform block.
			i, j := pos / n, pos % n
			a, l: int
			switch {
			case i > 0 && j > 0:
				a, l = (i - 1) * n + j, i * n + j - 1
				if tx_type == vp9.DCT_ADST do l = a
				if tx_type == vp9.ADST_DCT do a = l
			case i > 0:
				a, l = (i - 1) * n + j, (i - 1) * n + j
			case:
				a, l = i * n + j - 1, i * n + j - 1
			}
			ctx = (1 + int(cache[a]) + int(cache[l])) >> 1
		}
		pr := &probs[band][ctx]
		if check_eob {
			more := read_bool(&t.b, pr[0])
			counts_more[band][ctx][more] += 1
			if more == 0 do break
		}
		token: int
		if read_bool(&t.b, pr[1]) == 0 {
			token = vp9.ZERO_TOKEN
		} else if read_bool(&t.b, pr[2]) == 0 {
			token = vp9.ONE_TOKEN
		} else {
			token = read_large_token(&t.b, pr[2])
		}
		counts_token[band][ctx][min(2, token)] += 1
		cache[pos] = vp9.ENERGY_CLASS[token]
		if token == vp9.ZERO_TOKEN {
			check_eob = false
			continue
		}
		coef := read_coef(&t.b, token, bit_depth)
		value := (i32(coef) * (c == 0 ? dc : ac)) >> shift
		coefs[pos] = read_bool(&t.b, 128) == 1 ? -value : value
		max_row = max(max_row, pos / n + 1)
		check_eob = true
	}
	return c, max_row, tx_type
}

// Tokens TWO_TOKEN and up: the tree below node 2, with Pareto-derived
// probabilities from the band's third coefficient probability.
@(private)
read_large_token :: proc(b: ^Bool_Decoder, prob: u8) -> int {
	x := int(prob - 1) / 2
	pareto: [8]u8
	if prob & 1 != 0 {
		pareto = vp9.PARETO_TABLE[x]
	} else {
		for k in 0 ..< 8 do pareto[k] = u8((int(vp9.PARETO_TABLE[x][k]) + int(vp9.PARETO_TABLE[x + 1][k])) >> 1)
	}
	tree := vp9.TOKEN_TREE
	n := 4 // node 2 of the token tree
	for {
		n = int(tree[n + read_bool(b, pareto[(n >> 1) - 2])])
		if n <= 0 do return -n
	}
}

@(private)
read_coef :: #force_inline proc(b: ^Bool_Decoder, token, bit_depth: int) -> int {
	extra := &vp9.EXTRA_BITS[token]
	cat, count := int(extra[0]), int(extra[1])
	coef := int(extra[2])
	if token == vp9.DCT_VAL_CAT6 {
		for e in 0 ..< bit_depth - 8 do coef += read_bool(b, 255) << uint(5 + bit_depth - e)
	}
	for e in 0 ..< count do coef += read_bool(b, vp9.CAT_PROBS[cat][e]) << uint(count - 1 - e)
	return coef
}

@(private)
scan_for :: proc(tx, tx_type: int) -> []u16 {
	row := tx_type == vp9.ADST_DCT // ADST columns: rows scanned first
	col := tx_type == vp9.DCT_ADST
	switch tx {
	case vp9.TX_4X4:
		return row ? vp9.ROW_SCAN_4X4[:] : col ? vp9.COL_SCAN_4X4[:] : vp9.DEFAULT_SCAN_4X4[:]
	case vp9.TX_8X8:
		return row ? vp9.ROW_SCAN_8X8[:] : col ? vp9.COL_SCAN_8X8[:] : vp9.DEFAULT_SCAN_8X8[:]
	case vp9.TX_16X16:
		return row ? vp9.ROW_SCAN_16X16[:] : col ? vp9.COL_SCAN_16X16[:] : vp9.DEFAULT_SCAN_16X16[:]
	}
	return vp9.DEFAULT_SCAN_32X32[:]
}

@(private)
reconstruct :: proc(t: ^Tile, dst: []$T, stride, tx, tx_type, rows: int) {
	d := t.d
	n := 4 << uint(tx)
	coefs := t.coefs[:n * n]
	vp9.inverse_transform(coefs, uint(tx + 2), tx_type, d.h.lossless, rows)
	max_value := i32(1) << uint(d.bit_depth) - 1
	for i in 0 ..< n {
		row := dst[i * stride:][:n]
		res := coefs[i * n:][:n]
		for j in 0 ..< n do row[j] = T(clamp(i32(row[j]) + res[j], 0, max_value))
	}
}

// Inter prediction of one region of the block for one plane (8.5.2).
@(private)
predict_inter :: proc(t: ^Tile, p, x, y, w, h, block_idx: int, $T: typeid) {
	d := t.d
	b := &t.blk
	sub_x, sub_y := p > 0 ? d.ss_x : 0, p > 0 ? d.ss_y : 0
	frame := plane(d.cur, p, T)
	stride := d.cur.strides[p]
	compound := b.ref_frame[1] > vp9.INTRA_FRAME
	for list in 0 ..< 1 + int(compound) {
		// Motion vector of this region (8.5.2.1).
		mvs := &b.block_mvs[list]
		mv: [2]i32
		switch {
		case p == 0 || b.mi_size >= vp9.BLOCK_8X8 || sub_x == 0 && sub_y == 0:
			mv = {i32(mvs[block_idx][0]), i32(mvs[block_idx][1])}
		case sub_x == 0 && sub_y == 1:
			for k in 0 ..< 2 do mv[k] = vp9.round_mv_q2(i32(mvs[block_idx][k]) + i32(mvs[block_idx + 2][k]))
		case sub_x == 1 && sub_y == 0:
			for k in 0 ..< 2 do mv[k] = vp9.round_mv_q2(i32(mvs[block_idx][k]) + i32(mvs[block_idx + 1][k]))
		case:
			for k in 0 ..< 2 do mv[k] = vp9.round_mv_q4(i32(mvs[0][k]) + i32(mvs[1][k]) + i32(mvs[2][k]) + i32(mvs[3][k]))
		}
		// Clamp to the frame plus a margin (8.5.2.2), in 1/16 plane samples.
		bh, bw := int(vp9.NUM_8X8_BLOCKS_HIGH_LOOKUP[b.mi_size]), int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[b.mi_size])
		to_top := -((b.mi_row * 8) * 16) >> uint(sub_y)
		to_bottom := (((d.h.mi_rows - bh - b.mi_row) * 8) * 16) >> uint(sub_y)
		to_left := -((b.mi_col * 8) * 16) >> uint(sub_x)
		to_right := (((d.h.mi_cols - bw - b.mi_col) * 8) * 16) >> uint(sub_x)
		spel_left := (vp9.INTERP_EXTEND + ((bw * 8) >> uint(sub_x))) << 4
		spel_top := (vp9.INTERP_EXTEND + ((bh * 8) >> uint(sub_y))) << 4
		row := clamp((2 * int(mv[0])) >> uint(sub_y), to_top - spel_top, to_bottom + spel_top - 16)
		col := clamp((2 * int(mv[1])) >> uint(sub_x), to_left - spel_left, to_right + spel_left - 16)
		// Reference position and step (8.5.2.3).
		ref := d.refs[d.h.ref_frame_idx[b.ref_frame[list] - vp9.LAST_FRAME]]
		x_scale := (ref.width << 14) / d.h.width
		y_scale := (ref.height << 14) / d.h.height
		luma_x, luma_y := x << uint(sub_x), y << uint(sub_y)
		frac_x := ((16 * luma_x * x_scale) >> 14) & 15
		frac_y := ((16 * luma_y * y_scale) >> 14) & 15
		start_x := ((x * x_scale) >> 14) << 4 + ((col * x_scale) >> 14) + frac_x
		start_y := ((y * y_scale) >> 14) << 4 + ((row * y_scale) >> 14) + frac_y
		step_x, step_y := (16 * x_scale) >> 14, (16 * y_scale) >> 14
		source := vp9.Ref_Plane(T) {
			data   = plane(ref, p, T),
			stride = ref.strides[p],
			last_x = ((ref.width + sub_x) >> uint(sub_x)) - 1,
			last_y = ((ref.height + sub_y) >> uint(sub_y)) - 1,
		}
		if list == 0 {
			vp9.predict_inter_block(source, start_x, start_y, step_x, step_y, w, h, b.interp_filter, d.bit_depth, frame[y * stride + x:], stride)
		} else {
			second := ([^]T)(&t.scratch)[:64 * 64]
			vp9.predict_inter_block(source, start_x, start_y, step_x, step_y, w, h, b.interp_filter, d.bit_depth, second, 64)
			vp9.average_into(frame[y * stride + x:], stride, second, 64, w, h)
		}
	}
}

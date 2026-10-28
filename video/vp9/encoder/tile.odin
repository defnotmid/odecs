package vp9_encoder

import vp9 ".."
import "base:intrinsics"
import "core:simd"

@(private)
Context_Snapshot :: struct {
	last_mv:        vp9.Mv,
	left_part:      [8]u8,
	left_seg_pred:  [8]u8,
	left_ctx:       [8]Edge_Context,
	left_nz:        [3][16]u8,
	above_part:     [8]u8,
	above_seg_pred: [8]u8,
	above_ctx:      [8]Edge_Context,
	above_nz0:      [16]u8,
	above_nz1:      [16]u8,
	above_nz2:      [16]u8,
	seg_id:         [4][4]u8,
}

COUNT_WORDS :: size_of(Encoder_Counts) / size_of(u32)

@(private)
Saved_Leaf :: struct {
	sym_len:   int,
	count_len: int,
	ctx_after: Context_Snapshot,
	motion:    [4][4]Motion,
	cell:      [4][4]vp9.Filter_Cell,
	seg_id:    [4][4]u8,
	recon_y:   [32 * 32]u16,
	recon_uv:  [2][32 * 32]u16,
	syms:      [65536]u16,
	counts:    [8192]u16,
}

@(private)
Tile :: struct {
	e: ^Encoder,
	first_col, end_col: int,
	b: Bool_Writer,
	syms: [dynamic]u16,
	counts: Encoder_Counts,
	last_mv: vp9.Mv,
	above_partition: []u8,
	above_seg_pred: []u8,
	above_context: []Edge_Context,
	above_nonzero: [3][]u8,
	left_partition: [8]u8,
	left_seg_pred: [8]u8,
	left_context: [8]Edge_Context,
	left_nonzero: [3][16]u8,
	pred: [64 * 64]u16,
	qbuf: [3][4096]i32,
	nzbuf: [3][256]u16,
	block_storage: [1024]i32,
	token_cache: [1024]u8,
	trial_depth: int,
	undo_len: int,
	count_undo: [16384]u16,
	saved: [3]Saved_Leaf,
}

// Tiles stage their symbols, coded once the compressed header has settled
// this frame's probabilities. A symbol is its bit (bit 15) and where its
// probability is: below 256 the probability itself, below 4096 a byte of
// Probabilities (offset + 256) or segmentation tree/pred probs (4080..4089),
// above that a Pareto row entry of a coefficient probability (4096 + offset * 8 + entry).
@(private)
SEG_TREE_PROB_BASE :: 4080
@(private)
SEG_PRED_PROB_BASE :: 4087
@(private)
SYM_PROB_SIZE :: 4096 + (offset_of(vp9.Probabilities, coef) + size_of(vp9.Probabilities{}.coef)) * 8
#assert(256 + size_of(vp9.Probabilities) <= SEG_TREE_PROB_BASE)
#assert(SYM_PROB_SIZE <= 1 << 15)

@(private)
emit_sym :: #force_inline proc(t: ^Tile, sym: u16) {
	if _, err := append(&t.syms, sym); err != nil do t.b.failed = true
}

@(private)
count_inc :: #force_inline proc(t: ^Tile, c: ^u32) #no_bounds_check {
	c^ += 1
	if t.trial_depth > 0 {
		t.count_undo[t.undo_len] = u16((uintptr(c) - uintptr(&t.counts)) >> 2)
		t.undo_len += 1
	}
}

@(private)
syms_bit_cost :: proc(e: ^Encoder, syms: []u16) -> i64 #no_bounds_check {
	bits: i64
	sym_probs := &e.sym_probs
	for s in syms do bits += i64(BIT_COSTS[s >> 15][sym_probs[s & 0x7FFF]])
	return bits
}

@(private)
save_context :: #force_inline proc(t: ^Tile, r, c, n: int) -> (s: Context_Snapshot) #no_bounds_check {
	e := t.e
	sb_c := c & ~int(7)
	uv_nz := 16 >> uint(e.ss_x)
	s.last_mv = t.last_mv
	s.left_part = t.left_partition
	s.left_seg_pred = t.left_seg_pred
	s.left_ctx = t.left_context
	s.left_nz = t.left_nonzero
	copy(s.above_part[:], t.above_partition[sb_c:][:8])
	copy(s.above_seg_pred[:], t.above_seg_pred[sb_c:][:8])
	copy(s.above_ctx[:], t.above_context[sb_c:][:8])
	copy(s.above_nz0[:], t.above_nonzero[0][sb_c * 2:][:16])
	copy(s.above_nz1[:uv_nz], t.above_nonzero[1][(sb_c * 2) >> uint(e.ss_x):][:uv_nz])
	copy(s.above_nz2[:uv_nz], t.above_nonzero[2][(sb_c * 2) >> uint(e.ss_x):][:uv_nz])
	rows, cols := min(n, e.mi_rows - r), min(n, e.mi_cols - c)
	for y in 0 ..< rows do for x in 0 ..< cols {
		s.seg_id[y][x] = e.segment_ids[(r + y) * e.mi_cols + c + x]
	}
	return
}

@(private)
restore_context :: #force_inline proc(t: ^Tile, r, c, n: int, s: ^Context_Snapshot) #no_bounds_check {
	e := t.e
	sb_c := c & ~int(7)
	uv_nz := 16 >> uint(e.ss_x)
	t.last_mv = s.last_mv
	t.left_partition = s.left_part
	t.left_seg_pred = s.left_seg_pred
	t.left_context = s.left_ctx
	t.left_nonzero = s.left_nz
	copy(t.above_partition[sb_c:][:8], s.above_part[:])
	copy(t.above_seg_pred[sb_c:][:8], s.above_seg_pred[:])
	copy(t.above_context[sb_c:][:8], s.above_ctx[:])
	copy(t.above_nonzero[0][sb_c * 2:][:16], s.above_nz0[:])
	copy(t.above_nonzero[1][(sb_c * 2) >> uint(e.ss_x):][:uv_nz], s.above_nz1[:uv_nz])
	copy(t.above_nonzero[2][(sb_c * 2) >> uint(e.ss_x):][:uv_nz], s.above_nz2[:uv_nz])
	rows, cols := min(n, e.mi_rows - r), min(n, e.mi_cols - c)
	for y in 0 ..< rows do for x in 0 ..< cols {
		e.segment_ids[(r + y) * e.mi_cols + c + x] = s.seg_id[y][x]
	}
}

@(private)
put_seg_pred :: #force_inline proc(t: ^Tile, bit, ctx: int) {
	emit_sym(t, u16((bit << 15) | (SEG_PRED_PROB_BASE + ctx)))
}

@(private)
put_seg_tree :: #force_inline proc(t: ^Tile, seg_id: int) #no_bounds_check {
	code := SEG_CODES[seg_id]
	for i in 0 ..< int(code.count) {
		bit := int(code.bits >> uint(i) & 1)
		emit_sym(t, u16((bit << 15) | (SEG_TREE_PROB_BASE + int(code.nodes[i]))))
	}
}

@(private)
put_fixed :: #force_inline proc(t: ^Tile, bit: int, prob: u8) {
	emit_sym(t, u16((bit << 15) | int(prob)))
}

@(private)
put_prob :: #force_inline proc(t: ^Tile, bit: int, prob: ^u8) {
	emit_sym(t, u16((bit << 15) | (256 + int(uintptr(prob) - uintptr(&t.e.probs)))))
}

@(private)
put_tree_fixed :: #force_inline proc(t: ^Tile, code: Tree_Code, probs: []u8) #no_bounds_check {
	for i in 0 ..< int(code.count) {
		put_fixed(t, int(code.bits >> uint(i) & 1), probs[code.nodes[i]])
	}
}

@(private)
put_tree_prob :: #force_inline proc(t: ^Tile, code: Tree_Code, probs: []u8) #no_bounds_check {
	for i in 0 ..< int(code.count) {
		put_prob(t, int(code.bits >> uint(i) & 1), &probs[code.nodes[i]])
	}
}

@(private)
put_tree_pareto :: #force_inline proc(t: ^Tile, pr2: ^u8, token: int) #no_bounds_check {
	base := 4096 + (int(uintptr(pr2) - uintptr(&t.e.probs)) << 3)
	code := TOKEN_PARETO_CODES[token]
	for i in 0 ..< int(code.count) {
		bit := int(code.bits >> uint(i) & 1)
		emit_sym(t, u16((bit << 15) | (base + int(code.nodes[i]))))
	}
}

@(private)
encode_tile :: proc(t: ^Tile) {
	if t.e.bit_depth > 8 {
		encode_tile_typed(t, u16)
	} else {
		encode_tile_typed(t, u8)
	}
}

@(private)
encode_tile_typed :: proc(t: ^Tile, $T: typeid) {
	stage_source(t, T)
	clear(&t.syms)
	t.b.failed = false
	t.last_mv = {}
	t.trial_depth = 0
	t.undo_len = 0
	for r := 0; r < t.e.mi_rows; r += 8 {
		t.left_partition, t.left_seg_pred, t.left_context, t.left_nonzero = {}, {}, {}, {}
		for c := t.first_col; c < t.end_col; c += 8 do encode_partition(t, r, c, vp9.BLOCK_64X64, T)
	}
}

@(private)
build_sym_probs :: proc(e: ^Encoder) #no_bounds_check {
	probs_bytes := ([^]u8)(&e.probs)
	copy(e.sym_probs[256:][:size_of(vp9.Probabilities)], probs_bytes[:size_of(vp9.Probabilities)])
	copy(e.sym_probs[SEG_TREE_PROB_BASE:][:7], e.segmentation.tree_probs[:])
	copy(e.sym_probs[SEG_PRED_PROB_BASE:][:3], e.segmentation.pred_probs[:])
	count := e.lossless ? 1 : 4
	for tx in 0 ..< count do for i in 0 ..< 2 do for j in 0 ..< 2 do for k in 0 ..< 6 {
		for l in 0 ..< (k == 0 ? 3 : 6) {
			pr2 := &e.probs.coef[tx][i][j][k][l][2]
			base := 4096 + (int(uintptr(pr2) - uintptr(&e.probs)) << 3)
			row := vp9.pareto_row(pr2^)
			intrinsics.unaligned_store((^u64)(&e.sym_probs[base]), intrinsics.unaligned_load((^u64)(row)))
		}
	}
}

@(private)
flush_tile :: proc(t: ^Tile) #no_bounds_check {
	if t.b.failed do return
	sym_probs := &t.e.sym_probs
	b := t.b
	start_bool(&b)
	for s in t.syms {
		put_bool(&b, int(s >> 15), sym_probs[s & 0x7FFF])
	}
	finish_bool(&b)
	t.b = b
}

// Copies this tile's columns of the input into the aligned source, replicating
// the right and bottom edges, so block loops index it without clamping.
@(private)
stage_source :: proc(t: ^Tile, $T: typeid) #no_bounds_check {
	e := t.e
	for p in 0 ..< 3 {
		sx := p > 0 ? uint(e.ss_x) : 0
		sy := p > 0 ? uint(e.ss_y) : 0
		w, h := (e.config.width + int(sx)) >> sx, (e.config.height + int(sy)) >> sy
		stride := e.source_strides[p]
		source := plane_t(e.source[p], T)
		input := plane_t(e.input[p], T)
		rows := len(source) / stride
		x0 := t.first_col * 8 >> sx
		x1 := t.end_col == e.mi_cols ? stride : t.end_col * 8 >> sx
		visible := max(0, min(x1, w) - x0)
		for y in 0 ..< rows {
			dst := source[y * stride + x0:][:x1 - x0]
			src := input[min(y, h - 1) * e.input_strides[p]:]
			copy(dst[:visible], src[x0:][:visible])
			for &v in dst[visible:] do v = src[w - 1]
		}
	}
}

@(private)
emit_partition :: proc(t: ^Tile, ctx, part: int, has_rows, has_cols: bool) #no_bounds_check {
	e := t.e
	if e.keyframe {
		probs := &vp9.KF_PARTITION_PROBS[ctx]
		switch {
		case has_rows && has_cols: put_tree_fixed(t, PARTITION_CODES[part], probs[:])
		case has_cols: put_fixed(t, int(part == vp9.PARTITION_SPLIT), probs[1])
		case has_rows: put_fixed(t, int(part == vp9.PARTITION_SPLIT), probs[2])
		}
	} else {
		probs := &e.probs.partition[ctx]
		switch {
		case has_rows && has_cols: put_tree_prob(t, PARTITION_CODES[part], probs[:])
		case has_cols: put_prob(t, int(part == vp9.PARTITION_SPLIT), &probs[1])
		case has_rows: put_prob(t, int(part == vp9.PARTITION_SPLIT), &probs[2])
		}
	}
	count_inc(t, &t.counts.partition[ctx][part])
}

@(private)
encode_leaf_partition :: proc(t: ^Tile, r, c, size, ctx, part: int, has_rows, has_cols: bool, $T: typeid) -> (dist: i64) #no_bounds_check {
	n := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size])
	half := n >> 1
	emit_partition(t, ctx, part, has_rows, has_cols)
	subsize := int(vp9.SUBSIZE_LOOKUP[part][size])
	switch {
	case subsize < vp9.BLOCK_8X8 || part == vp9.PARTITION_NONE:
		dist = encode_block(t, r, c, subsize, T)
	case part == vp9.PARTITION_HORZ:
		dist = encode_block(t, r, c, subsize, T)
		if has_rows do dist += encode_block(t, r + half, c, subsize, T)
	case part == vp9.PARTITION_VERT:
		dist = encode_block(t, r, c, subsize, T)
		if has_cols do dist += encode_block(t, r, c + half, subsize, T)
	}
	a := u8(15) >> vp9.B_WIDTH_LOG2_LOOKUP[subsize]
	l := u8(15) >> vp9.B_HEIGHT_LOG2_LOOKUP[subsize]
	for i in 0 ..< n {
		t.above_partition[c + i] = a
		t.left_partition[(r + i) & 7] = l
	}
	return dist
}

@(private)
save_leaf :: proc(t: ^Tile, slot, r, c, n, sym_start, undo_start: int, $T: typeid) #no_bounds_check {
	e := t.e
	saved := &t.saved[slot]
	saved.ctx_after = save_context(t, r, c, n)
	rows, cols := min(n, e.mi_rows - r), min(n, e.mi_cols - c)
	for y in 0 ..< rows do for x in 0 ..< cols {
		idx := (r + y) * e.mi_cols + c + x
		saved.motion[y][x] = e.motion[idx]
		saved.cell[y][x] = e.filter_cells[idx]
		saved.seg_id[y][x] = e.segment_ids[idx]
	}
	saved.sym_len = len(t.syms) - sym_start
	copy(saved.syms[:saved.sym_len], t.syms[sym_start:])
	saved.count_len = t.undo_len - undo_start
	copy(saved.counts[:saved.count_len], t.count_undo[undo_start:t.undo_len])
	px := n * 8
	recon_y := ([^]T)(&saved.recon_y)[:32 * 32]
	plane_y := plane_t(e.planes[0], T)
	for yy in 0 ..< px do copy(recon_y[yy * px:][:px], plane_y[(r * 8 + yy) * e.strides[0] + c * 8:][:px])
	uv_w, uv_h := px >> uint(e.ss_x), px >> uint(e.ss_y)
	uv_x, uv_y := (c * 8) >> uint(e.ss_x), (r * 8) >> uint(e.ss_y)
	for p in 0 ..< 2 {
		stride := e.strides[p + 1]
		recon_uv := ([^]T)(&saved.recon_uv[p])[:32 * 32]
		plane_uv := plane_t(e.planes[p + 1], T)
		for yy in 0 ..< uv_h do copy(recon_uv[yy * uv_w:][:uv_w], plane_uv[(uv_y + yy) * stride + uv_x:][:uv_w])
	}
}

@(private)
undo_trial :: #force_inline proc(t: ^Tile, r, c, n, sym_start, undo_start: int, ctx_before: ^Context_Snapshot) #no_bounds_check {
	counts := (^[COUNT_WORDS]u32)(&t.counts)
	for i := t.undo_len - 1; i >= undo_start; i -= 1 do counts[t.count_undo[i]] -= 1
	t.undo_len = undo_start
	resize(&t.syms, sym_start)
	restore_context(t, r, c, n, ctx_before)
}

@(private)
restore_leaf :: proc(t: ^Tile, slot, r, c, n, sym_start, undo_start: int, $T: typeid) #no_bounds_check {
	e := t.e
	saved := &t.saved[slot]
	counts := (^[COUNT_WORDS]u32)(&t.counts)
	for i := t.undo_len - 1; i >= undo_start; i -= 1 do counts[t.count_undo[i]] -= 1
	t.undo_len = undo_start
	resize(&t.syms, sym_start)
	for s in saved.syms[:saved.sym_len] do emit_sym(t, s)
	for idx in saved.counts[:saved.count_len] {
		counts[idx] += 1
		if t.trial_depth > 1 {
			t.count_undo[t.undo_len] = idx
			t.undo_len += 1
		}
	}
	restore_context(t, r, c, n, &saved.ctx_after)
	px := n * 8
	recon_y := ([^]T)(&saved.recon_y)[:32 * 32]
	plane_y := plane_t(e.planes[0], T)
	for yy in 0 ..< px do copy(plane_y[(r * 8 + yy) * e.strides[0] + c * 8:][:px], recon_y[yy * px:][:px])
	uv_w, uv_h := px >> uint(e.ss_x), px >> uint(e.ss_y)
	uv_x, uv_y := (c * 8) >> uint(e.ss_x), (r * 8) >> uint(e.ss_y)
	for p in 0 ..< 2 {
		stride := e.strides[p + 1]
		recon_uv := ([^]T)(&saved.recon_uv[p])[:32 * 32]
		plane_uv := plane_t(e.planes[p + 1], T)
		for yy in 0 ..< uv_h do copy(plane_uv[(uv_y + yy) * stride + uv_x:][:uv_w], recon_uv[yy * uv_w:][:uv_w])
	}
	rows, cols := min(n, e.mi_rows - r), min(n, e.mi_cols - c)
	for y in 0 ..< rows do for x in 0 ..< cols {
		idx := (r + y) * e.mi_cols + c + x
		e.motion[idx] = saved.motion[y][x]
		e.filter_cells[idx] = saved.cell[y][x]
		e.segment_ids[idx] = saved.seg_id[y][x]
	}
}

@(private)
encode_partition :: proc(t: ^Tile, r, c, size: int, $T: typeid) -> i64 #no_bounds_check {
	e := t.e
	if r >= e.mi_rows || c >= e.mi_cols do return 0
	n := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size])
	half := n / 2
	has_rows, has_cols := r + half < e.mi_rows, c + half < e.mi_cols
	bsl := uint(vp9.MI_WIDTH_LOG2_LOOKUP[size])
	a, l: u8
	for i in 0 ..< n {a |= t.above_partition[c + i]; l |= t.left_partition[(r + i) & 7]}
	ctx := int(bsl) * 4 + int(l >> (3 - bsl) & 1) * 2 + int(a >> (3 - bsl) & 1)
	can_none := size == vp9.BLOCK_8X8 || (int(bsl) <= e.config.block_log2 - 3 && has_rows && has_cols)
	split, rect_part := false, -1
	if !can_none {
		split = true
	} else if size > vp9.BLOCK_8X8 || (!e.keyframe && !e.config.ultrafast && !e.lossless) {
		split, rect_part = should_split(t, r, c, size, T)
	}
	if can_none && split && !e.config.ultrafast && !e.lossless && size <= vp9.BLOCK_32X32 {
		slot := int(bsl)
		t.trial_depth += 1
		sym_start := len(t.syms)
		undo_start := t.undo_len
		ctx_before := save_context(t, r, c, n)
		dist_best := encode_leaf_partition(t, r, c, size, ctx, vp9.PARTITION_NONE, has_rows, has_cols, T)
		q := i64(e.dequant[e.segment_ids[r * e.mi_cols + c]][0][1])
		if (t.above_context[c].skip && dist_best * 8 <= (i64(n * n * 64) * q) << uint(e.bit_depth - 8)) || (size == vp9.BLOCK_8X8 && dist_best <= i64(n * n) * q * q * 16) {
			t.trial_depth -= 1
			if t.trial_depth == 0 do t.undo_len = 0
			return dist_best
		}
		bits_none := syms_bit_cost(e, t.syms[sym_start:])
		rd_best := dist_best + ((bits_none * q * q * 14) >> 16)
		save_leaf(t, slot, r, c, n, sym_start, undo_start, T)
		undo_trial(t, r, c, n, sym_start, undo_start, &ctx_before)
		if rect_part >= vp9.PARTITION_HORZ {
			rect_sub := max(int(vp9.SUBSIZE_LOOKUP[rect_part][size]), vp9.BLOCK_8X8)
			if vp9.SS_SIZE_LOOKUP[rect_sub][e.ss_x][e.ss_y] != vp9.BLOCK_INVALID {
				dist_rect := encode_leaf_partition(t, r, c, size, ctx, rect_part, has_rows, has_cols, T)
				bits_rect := syms_bit_cost(e, t.syms[sym_start:])
				rd_rect := dist_rect + ((bits_rect * q * q * 14) >> 16)
				if rd_rect < rd_best {
					rd_best, dist_best = rd_rect, dist_rect
					save_leaf(t, slot, r, c, n, sym_start, undo_start, T)
				}
				undo_trial(t, r, c, n, sym_start, undo_start, &ctx_before)
			}
		}
		dist_split: i64
		if size == vp9.BLOCK_8X8 {
			dist_split = encode_leaf_partition(t, r, c, size, ctx, vp9.PARTITION_SPLIT, has_rows, has_cols, T)
		} else {
			emit_partition(t, ctx, vp9.PARTITION_SPLIT, has_rows, has_cols)
			subsize := int(vp9.SUBSIZE_LOOKUP[vp9.PARTITION_SPLIT][size])
			dist_split = encode_partition(t, r, c, subsize, T) + encode_partition(t, r, c + half, subsize, T) + encode_partition(t, r + half, c, subsize, T) + encode_partition(t, r + half, c + half, subsize, T)
		}
		bits_split := syms_bit_cost(e, t.syms[sym_start:])
		rd_split := dist_split + ((bits_split * q * q * 14) >> 16)
		if rd_best <= rd_split {
			restore_leaf(t, slot, r, c, n, sym_start, undo_start, T)
			t.trial_depth -= 1
			if t.trial_depth == 0 do t.undo_len = 0
			return dist_best
		}
		t.trial_depth -= 1
		if t.trial_depth == 0 do t.undo_len = 0
		return dist_split
	}
	if !split {
		return encode_leaf_partition(t, r, c, size, ctx, vp9.PARTITION_NONE, has_rows, has_cols, T)
	}
	emit_partition(t, ctx, vp9.PARTITION_SPLIT, has_rows, has_cols)
	subsize := int(vp9.SUBSIZE_LOOKUP[vp9.PARTITION_SPLIT][size])
	return encode_partition(t, r, c, subsize, T) + encode_partition(t, r, c + half, subsize, T) + encode_partition(t, r + half, c, subsize, T) + encode_partition(t, r + half, c + half, subsize, T)
}

@(private)
should_split :: proc(t: ^Tile, r, c, size: int, $T: typeid) -> (split: bool, rect_part: int) #no_bounds_check {
	e := t.e
	half_px := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size]) * 4
	x, y := c * 8, r * 8
	s_stride := e.source_strides[0]
	area := u32(half_px * half_px)
	source := plane_t(e.source[0], T)
	src := source[y * s_stride + x:]
	if e.keyframe {
		p0 := src
		p1 := source[(y + half_px - 2) * s_stride + x + half_px - 2:]
		v_diff := block_sad(half_px, p0, s_stride, source[(y + 2) * s_stride + x:], s_stride) + block_sad(half_px, p1, s_stride, source[(y + half_px) * s_stride + x + half_px - 2:], s_stride)
		h_diff := block_sad(half_px, p0, s_stride, source[y * s_stride + x + 2:], s_stride) + block_sad(half_px, p1, s_stride, source[(y + half_px - 2) * s_stride + x + half_px:], s_stride)
		if size > vp9.BLOCK_16X16 {
			p2 := source[y * s_stride + x + half_px - 2:]
			p3 := source[(y + half_px - 2) * s_stride + x:]
			v_diff += block_sad(half_px, p2, s_stride, source[(y + 2) * s_stride + x + half_px - 2:], s_stride) + block_sad(half_px, p3, s_stride, source[(y + half_px) * s_stride + x:], s_stride)
			h_diff += block_sad(half_px, p2, s_stride, source[y * s_stride + x + half_px:], s_stride) + block_sad(half_px, p3, s_stride, source[(y + half_px - 2) * s_stride + x + 2:], s_stride)
			return min(v_diff, h_diff) > 0, -1
		}
		return min(v_diff, h_diff) > (area << uint(e.bit_depth - 8)) / 2, -1
	}
	r_stride := e.strides[0]
	rx, ry := BORDER + x, BORDER + y
	ref_store := plane_t(e.reference_storage[0], T)
	ref := ref_store[ry * r_stride + rx:]
	s00 := block_sad(half_px, src, s_stride, ref, r_stride)
	s01 := block_sad(half_px, source[y * s_stride + x + half_px:], s_stride, ref_store[ry * r_stride + rx + half_px:], r_stride)
	s10 := block_sad(half_px, source[(y + half_px) * s_stride + x:], s_stride, ref_store[(ry + half_px) * r_stride + rx:], r_stride)
	s11 := block_sad(half_px, source[(y + half_px) * s_stride + x + half_px:], s_stride, ref_store[(ry + half_px) * r_stride + rx + half_px:], r_stride)
	total := s00 + s01 + s10 + s11
	min_s := min(min(s00, s01), min(s10, s11))
	max_s := max(max(s00, s01), max(s10, s11))
	h_imb := abs(int(s00 + s01) - int(s10 + s11))
	v_imb := abs(int(s00 + s10) - int(s01 + s11))
	rect_part = max(h_imb, v_imb) * 5 >= int(total) ? (h_imb >= v_imb ? vp9.PARTITION_HORZ : vp9.PARTITION_VERT) : -1
	if e.lossless do return total > 0, rect_part
	q := u32(e.dequant[e.segment_ids[r * e.mi_cols + c]][0][1])
	noise := (area * q) >> 5
	if size == vp9.BLOCK_8X8 do return max_s > min_s * 2 + noise * 2 && max_s > noise * 6, rect_part
	if size > vp9.BLOCK_16X16 do return max_s > min_s + (noise >> 2) || max_s > noise, rect_part
	return max_s > min_s + noise || max_s > noise * 3, rect_part
}

@(private)
has_nz :: #force_inline proc(p: []u8) -> int #no_bounds_check {
	switch len(p) {
	case 1: return int(p[0] != 0)
	case 2: return int(intrinsics.unaligned_load((^u16)(&p[0])) != 0)
	case 4: return int(intrinsics.unaligned_load((^u32)(&p[0])) != 0)
	case 8: return int(intrinsics.unaligned_load((^u64)(&p[0])) != 0)
	}
	v: u8
	for b in p do v |= b
	return int(v != 0)
}

@(private)
fill_nz :: #force_inline proc(p: []u8, val: u8) #no_bounds_check {
	m := u64(val) * 0x0101010101010101
	switch len(p) {
	case 1: p[0] = val
	case 2: intrinsics.unaligned_store((^u16)(&p[0]), u16(m))
	case 4: intrinsics.unaligned_store((^u32)(&p[0]), u32(m))
	case 8: intrinsics.unaligned_store((^u64)(&p[0]), m)
	}
}

@(private)
encode_block :: proc(t: ^Tile, r, c, size: int, $T: typeid) -> i64 #no_bounds_check {
	e := t.e
	sub8x8 := size < vp9.BLOCK_8X8
	bw8 := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size])
	bh8 := int(vp9.NUM_8X8_BLOCKS_HIGH_LOOKUP[size])
	w4 := int(vp9.NUM_4X4_BLOCKS_WIDE_LOOKUP[size])
	h4 := int(vp9.NUM_4X4_BLOCKS_HIGH_LOOKUP[size])
	lossless := e.lossless
	max_tx := int(vp9.MAX_TXSIZE_LOOKUP[size])
	seg_id, predicted_seg := 0, 7
	if e.segmentation.enabled {
		if !e.keyframe {
			for y in 0 ..< min(e.mi_rows - r, bh8) {
				for x in 0 ..< min(e.mi_cols - c, bw8) {
					predicted_seg = min(predicted_seg, int(e.prev_segment_ids[(r + y) * e.mi_cols + c + x]))
				}
			}
		}
		seg_id = e.segmentation.update_map ? int(e.segment_ids[r * e.mi_cols + c]) : (!e.keyframe ? predicted_seg : 0)
	}
	seg_skip := vp9.seg_feature_active(&e.segmentation, seg_id, vp9.SEG_LVL_SKIP)
	seg_ref_active := !e.keyframe && vp9.seg_feature_active(&e.segmentation, seg_id, vp9.SEG_LVL_REF_FRAME)
	seg_ref := seg_ref_active ? int(e.segmentation.feature_data[seg_id][vp9.SEG_LVL_REF_FRAME]) : vp9.NONE
	dc, ac := e.dequant[seg_id][0][0], e.dequant[seg_id][0][1]
	dc_uv, ac_uv := e.dequant[seg_id][1][0], e.dequant[seg_id][1][1]
	tx := lossless ? vp9.TX_4X4 : e.keyframe ? (size <= vp9.BLOCK_8X8 ? vp9.TX_4X4 : max_tx) : min(max_tx, vp9.TX_16X16)
	nearest, near, mv: [2]vp9.Mv
	block_mvs: [2][4]vp9.Mv
	sub_modes: [4]int
	inter_ctx := 0
	is_inter_ctx := 0
	comp_ctx, comp_ref_ctx := 1, 2
	ref_ctx1, ref_ctx2 := 2, 2
	ref_frame := [2]i8{vp9.INTRA_FRAME, vp9.NONE}
	mode := vp9.DC_PRED
	uv_mode := vp9.DC_PRED
	interp_filter := vp9.EIGHTTAP
	filter_ctx := 3
	luma_sad := max(u32)
	avail_u, avail_l := r > 0, c > t.first_col
	above_edge, left_edge := t.above_context[c], t.left_context[r & 7]
	if e.keyframe {
		if !sub8x8 {
			above := avail_u ? int(above_edge.modes[0]) : vp9.DC_PRED
			left := avail_l ? int(left_edge.modes[0]) : vp9.DC_PRED
			mode, _ = choose_intra(t, r, c, size, tx, vp9.KF_Y_MODE_PROBS[above][left][:], T)
			sub_modes = mode
		} else {
			for idy := 0; idy < 2; idy += h4 {
				for idx := 0; idx < 2; idx += w4 {
					above := idy > 0 ? sub_modes[idx] : avail_u ? int(above_edge.modes[idx]) : vp9.DC_PRED
					left := idx > 0 ? sub_modes[idy * 2] : avail_l ? int(left_edge.modes[idy]) : vp9.DC_PRED
					mode, _ = choose_intra(t, r, c, size, vp9.TX_4X4, vp9.KF_Y_MODE_PROBS[above][left][:], T, idx * 4, idy * 4)
					for y2 in 0 ..< h4 do for x2 in 0 ..< w4 do sub_modes[(idy + y2) * 2 + idx + x2] = mode
				}
			}
		}
		uv_mode = choose_intra_uv(t, r, c, size, vp9.uv_tx_size(size, tx, e.ss_x, e.ss_y), vp9.KF_UV_MODE_PROBS[mode][:], T)
	} else if seg_ref_active && seg_ref == vp9.INTRA_FRAME {
		ref_frame = {vp9.INTRA_FRAME, vp9.NONE}
		tx = lossless ? vp9.TX_4X4 : max_tx
		if !sub8x8 {
			sg := int(vp9.SIZE_GROUP_LOOKUP[size])
			mode, _ = choose_intra(t, r, c, size, tx, e.probs.y_mode[sg][:], T)
			sub_modes = mode
		} else {
			for idy := 0; idy < 2; idy += h4 {
				for idx := 0; idx < 2; idx += w4 {
					mode, _ = choose_intra(t, r, c, size, vp9.TX_4X4, e.probs.y_mode[0][:], T, idx * 4, idy * 4)
					for y2 in 0 ..< h4 do for x2 in 0 ..< w4 do sub_modes[(idy + y2) * 2 + idx + x2] = mode
				}
			}
		}
		uv_mode = choose_intra_uv(t, r, c, size, vp9.uv_tx_size(size, tx, e.ss_x, e.ss_y), e.probs.uv_mode[mode][:], T)
	} else {
		base_ref := seg_ref_active ? u8(seg_ref) : vp9.LAST_FRAME
		ref_frame = {i8(base_ref), vp9.NONE}
		a_ref := avail_u ? above_edge.ref_frame : [2]i8{vp9.INTRA_FRAME, vp9.NONE}
		l_ref := avail_l ? left_edge.ref_frame : [2]i8{vp9.INTRA_FRAME, vp9.NONE}
		a_intra, l_intra := a_ref[0] <= vp9.INTRA_FRAME, l_ref[0] <= vp9.INTRA_FRAME
		if avail_u && avail_l {
			is_inter_ctx = l_intra && a_intra ? 3 : l_intra || a_intra ? 1 : 0
		} else if avail_u {
			is_inter_ctx = 2 * int(a_intra)
		} else if avail_l {
			is_inter_ctx = 2 * int(l_intra)
		}
		comp_ctx = comp_mode_ctx(avail_u, avail_l, a_ref, l_ref)
		comp_ref_ctx = calc_comp_ref_ctx(avail_u, avail_l, a_ref, l_ref)
		ref_ctx1 = single_ref_p1_ctx(avail_u, avail_l, a_ref, l_ref)
		ref_ctx2 = single_ref_p2_ctx(avail_u, avail_l, a_ref, l_ref)
		l_nearest, l_near: vp9.Mv
		l_nearest, l_near, inter_ctx = motion_predictors(t, r, c, size, base_ref)
		nearest[0], near[0] = l_nearest, l_near
		bd_shift := uint(e.bit_depth - 8)
		rate_q := i64(max(16 << bd_shift, int(ac)))
		if sub8x8 {
			luma_sad = 0
			for idy := 0; idy < 2; idy += h4 {
				for idx := 0; idx < 2; idx += w4 {
					b_i := idy * 2 + idx
					s_nearest, s_near := sub8x8_motion_predictors(t, r, c, size, base_ref, b_i, &block_mvs[0])
					s_mv, s_mode, s_sad := search_motion(t, r, c, size, s_nearest, s_near, inter_ctx, T, base_ref, idx * 4, idy * 4, l_nearest)
					luma_sad += s_sad
					mode = s_mode
					mv[0] = s_mv
					for y2 in 0 ..< h4 do for x2 in 0 ..< w4 {
						k := (idy + y2) * 2 + idx + x2
						block_mvs[0][k] = s_mv
						sub_modes[k] = s_mode
					}
				}
			}
			if !e.config.ultrafast && !lossless {
				f_left := avail_l && left_edge.ref_frame[0] > vp9.INTRA_FRAME ? int(left_edge.interp_filter) : 3
				f_above := avail_u && above_edge.ref_frame[0] > vp9.INTRA_FRAME ? int(above_edge.interp_filter) : 3
				filter_ctx = f_left == f_above ? f_left : f_left == 3 ? f_above : f_above == 3 ? f_left : 3
			}
		} else if seg_skip {
			mv = {}
			mode = vp9.ZEROMV
			sub_modes = vp9.ZEROMV
			luma_sad = motion_sad(t, r, c, size, {}, T, base_ref)
			if !e.config.ultrafast && !lossless {
				f_left := avail_l && left_edge.ref_frame[0] > vp9.INTRA_FRAME ? int(left_edge.interp_filter) : 3
				f_above := avail_u && above_edge.ref_frame[0] > vp9.INTRA_FRAME ? int(above_edge.interp_filter) : 3
				filter_ctx = f_left == f_above ? f_left : f_left == 3 ? f_above : f_above == 3 ? f_left : 3
			}
		} else {
			l_mv: vp9.Mv
			l_mv, mode, luma_sad = search_motion(t, r, c, size, l_nearest, l_near, inter_ctx, T, base_ref)
			mv[0] = l_mv
			inter_bits := bit_cost(1, e.probs.is_inter[is_inter_ctx])
			single_base_bits := inter_bits + (e.allow_comp ? bit_cost(0, e.probs.comp_mode[comp_ctx]) : 0)
			last_bits := single_base_bits + bit_cost(0, e.probs.single_ref[ref_ctx1][0]) + u32(e.inter_mode_cost[inter_ctx][mode - vp9.NEARESTMV])
			if mode == vp9.NEWMV do last_bits += mv_bit_cost(e, l_mv, l_nearest)
			best_cost := i64(luma_sad) + ((rate_q * i64(last_bits)) >> 12)
			if !seg_ref_active && ((!e.last_keyframe && (e.frames % u64(e.config.keyframe_interval) & 7) != 1) || e.has_altref) && luma_sad > 0 {
				alt_refs := [2]u8{vp9.GOLDEN_FRAME, vp9.ALTREF_FRAME}
				num_alt := 1 + int(e.has_altref && !e.config.ultrafast)
				for alt_ref, ri in alt_refs[:num_alt] {
					if ri == 0 && (e.last_keyframe || (e.frames % u64(e.config.keyframe_interval) & 7) == 1) && e.has_altref do continue
					g_ref_bits := single_base_bits + bit_cost(1, e.probs.single_ref[ref_ctx1][0]) + bit_cost(ri, e.probs.single_ref[ref_ctx2][1])
					if e.config.ultrafast {
						g_bits := g_ref_bits + u32(e.inter_mode_cost[inter_ctx][vp9.ZEROMV - vp9.NEARESTMV])
						g_rate_cost := (rate_q * i64(g_bits)) >> 12
						if best_cost > g_rate_cost {
							g_sad := motion_sad(t, r, c, size, {}, T, alt_ref)
							if i64(g_sad) + g_rate_cost < best_cost {
								best_cost = i64(g_sad) + g_rate_cost
								ref_frame = {i8(alt_ref), vp9.NONE}
								mv[0], mode, luma_sad = {}, vp9.ZEROMV, g_sad
							}
						}
					} else {
						g_nearest, g_near, _ := motion_predictors(t, r, c, size, alt_ref)
						g_best_mv := g_nearest
						g_cands := [3]struct{mv: vp9.Mv, mode: int}{{g_nearest, vp9.NEARESTMV}, {g_near, vp9.NEARMV}, {{}, vp9.ZEROMV}}
						for cand, ci in g_cands {
							if ci > 0 && cand.mv == g_cands[0].mv do continue
							if ci == 2 && cand.mv == g_cands[1].mv do continue
							g_bits := g_ref_bits + u32(e.inter_mode_cost[inter_ctx][cand.mode - vp9.NEARESTMV])
							g_rate_cost := (rate_q * i64(g_bits)) >> 12
							if best_cost > g_rate_cost {
								g_sad := motion_sad(t, r, c, size, cand.mv, T, alt_ref)
								if i64(g_sad) + g_rate_cost < best_cost {
									best_cost = i64(g_sad) + g_rate_cost
									ref_frame = {i8(alt_ref), vp9.NONE}
									nearest[0], near[0] = g_nearest, g_near
									mv[0], mode, luma_sad = cand.mv, cand.mode, g_sad
									g_best_mv = cand.mv
								}
							}
						}
						if lossless || luma_sad > (u32(bw8 * bh8 * 32) << bd_shift) {
							g_mv, g_mode, g_sad := search_motion(t, r, c, size, g_nearest, g_near, inter_ctx, T, alt_ref)
							g_best_mv = g_mv
							g_bits := g_ref_bits + u32(e.inter_mode_cost[inter_ctx][g_mode - vp9.NEARESTMV])
							if g_mode == vp9.NEWMV do g_bits += mv_bit_cost(e, g_mv, g_nearest)
							g_cost := i64(g_sad) + ((rate_q * i64(g_bits)) >> 12)
							if g_cost < best_cost {
								best_cost = g_cost
								ref_frame = {i8(alt_ref), vp9.NONE}
								nearest[0], near[0] = g_nearest, g_near
								mv[0], mode, luma_sad = g_mv, g_mode, g_sad
							}
						}
						if e.allow_comp && luma_sad > 0 {
							comp_base_bits := inter_bits + bit_cost(1, e.probs.comp_mode[comp_ctx]) + bit_cost(ri, e.probs.comp_ref[comp_ref_ctx])
							c_cands := [4]struct{mv0, mv1: vp9.Mv, mode: int}{
								{l_nearest, g_nearest, vp9.NEARESTMV},
								{l_near, g_near, vp9.NEARMV},
								{{}, {}, vp9.ZEROMV},
								{l_mv, g_best_mv, vp9.NEWMV},
							}
							for cand, ci in c_cands {
								if ci == 3 {
									if cand.mv0 == l_nearest && cand.mv1 == g_nearest do continue
									if (!e.allow_hp || !use_mv_hp(l_nearest)) && ((cand.mv0[0] - l_nearest[0]) & 1 != 0 || (cand.mv0[1] - l_nearest[1]) & 1 != 0) do continue
									if (!e.allow_hp || !use_mv_hp(g_nearest)) && ((cand.mv1[0] - g_nearest[0]) & 1 != 0 || (cand.mv1[1] - g_nearest[1]) & 1 != 0) do continue
								}
								c_bits := comp_base_bits + u32(e.inter_mode_cost[inter_ctx][cand.mode - vp9.NEARESTMV])
								if cand.mode == vp9.NEWMV do c_bits += mv_bit_cost(e, cand.mv0, l_nearest) + mv_bit_cost(e, cand.mv1, g_nearest)
								c_rate_cost := (rate_q * i64(c_bits)) >> 12
								if best_cost > c_rate_cost {
									c_sad := compound_sad(t, r, c, size, cand.mv0, cand.mv1, T, vp9.EIGHTTAP, alt_ref)
									if i64(c_sad) + c_rate_cost < best_cost {
										best_cost = i64(c_sad) + c_rate_cost
										ref_frame = {vp9.LAST_FRAME, i8(alt_ref)}
										nearest = {l_nearest, g_nearest}
										near = {l_near, g_near}
										mv = {cand.mv0, cand.mv1}
										mode, luma_sad = cand.mode, c_sad
									}
								}
							}
						}
					}
				}
			}
			if !seg_ref_active && !lossless && size <= vp9.BLOCK_32X32 && luma_sad > u32(bw8 * bh8 * 64) * u32(max(8 << bd_shift, int(ac) >> 2)) {
				sg := int(vp9.SIZE_GROUP_LOOKUP[size])
				cand, i_sad := choose_intra(t, r, c, size, max_tx, e.probs.y_mode[sg][:], T)
				i_bits := bit_cost(0, e.probs.is_inter[is_inter_ctx]) + code_bit_cost(INTRA_MODE_CODES[cand], e.probs.y_mode[sg][:]) + code_bit_cost(INTRA_MODE_CODES[vp9.DC_PRED], e.probs.uv_mode[cand][:])
				i_cost := i64(i_sad) + ((rate_q * i64(i_bits)) >> 12)
				if i_cost < best_cost {
					best_cost = i_cost
					ref_frame = {vp9.INTRA_FRAME, vp9.NONE}
					mv, mode, luma_sad = {}, cand, i_sad
					tx = max_tx
					uv_mode = choose_intra_uv(t, r, c, size, vp9.uv_tx_size(size, tx, e.ss_x, e.ss_y), e.probs.uv_mode[mode][:], T)
				}
			}
			if ref_frame[0] != vp9.INTRA_FRAME && !e.config.ultrafast && !lossless {
				f_left := avail_l && left_edge.ref_frame[0] > vp9.INTRA_FRAME ? int(left_edge.interp_filter) : 3
				f_above := avail_u && above_edge.ref_frame[0] > vp9.INTRA_FRAME ? int(above_edge.interp_filter) : 3
				filter_ctx = f_left == f_above ? f_left : f_left == 3 ? f_above : f_above == 3 ? f_left : 3
				is_comp := ref_frame[1] > vp9.INTRA_FRAME
				subpel := mv[0][0] & 7 != 0 || mv[0][1] & 7 != 0 || (is_comp && (mv[1][0] & 7 != 0 || mv[1][1] & 7 != 0))
				c_mask_y := i16((8 << uint(e.ss_y)) - 1)
				c_mask_x := i16((8 << uint(e.ss_x)) - 1)
				int_chroma := mv[0][0] & c_mask_y == 0 && mv[0][1] & c_mask_x == 0 && (!is_comp || (mv[1][0] & c_mask_y == 0 && mv[1][1] & c_mask_x == 0))
				if subpel {
					best_f_cost := i64(luma_sad) + ((rate_q * i64(code_bit_cost(INTERP_FILTER_CODES[vp9.EIGHTTAP], e.probs.interp_filter[filter_ctx][:]))) >> 12)
					for f in 1 ..< vp9.SWITCHABLE_FILTERS {
						f_bits := code_bit_cost(INTERP_FILTER_CODES[f], e.probs.interp_filter[filter_ctx][:])
						f_rate_cost := (rate_q * i64(f_bits)) >> 12
						if best_f_cost > f_rate_cost {
							f_sad := is_comp ? compound_sad(t, r, c, size, mv[0], mv[1], T, f, u8(ref_frame[1])) : motion_sad(t, r, c, size, mv[0], T, u8(ref_frame[0]), f)
							if i64(f_sad) + f_rate_cost < best_f_cost {
								best_f_cost = i64(f_sad) + f_rate_cost
								interp_filter = f
								luma_sad = f_sad
							}
						}
					}
				} else if int_chroma {
					best_f_bits := code_bit_cost(INTERP_FILTER_CODES[vp9.EIGHTTAP], e.probs.interp_filter[filter_ctx][:])
					for f in 1 ..< vp9.SWITCHABLE_FILTERS {
						f_bits := code_bit_cost(INTERP_FILTER_CODES[f], e.probs.interp_filter[filter_ctx][:])
						if f_bits < best_f_bits {
							best_f_bits = f_bits
							interp_filter = f
						}
					}
				}
			}
			sub_modes = mode
		}
	}
	is_intra := ref_frame[0] == vp9.INTRA_FRAME
	is_comp := ref_frame[1] > vp9.INTRA_FRAME
	any_nonzero := false
	pred := ([^]T)(&t.pred)[:64 * 64]
	for p in 0 ..< 3 {
		sx := p > 0 ? uint(e.ss_x) : 0
		sy := p > 0 ? uint(e.ss_y) : 0
		ptx := p > 0 ? vp9.uv_tx_size(size, tx, e.ss_x, e.ss_y) : tx
		p_dc := p > 0 ? dc_uv : dc
		p_ac := p > 0 ? ac_uv : ac
		n, step := 4 << uint(ptx), 1 << uint(ptx)
		region_w, region_h := (bw8 * 8) >> sx, (bh8 * 8) >> sy
		base_x, base_y := (c * 8) >> sx, (r * 8) >> sy
		max_x, max_y := (e.mi_cols * 8) >> sx, (e.mi_rows * 8) >> sy
		stride := e.strides[p]
		frame := plane_t(e.planes[p], T)
		source, source_stride := plane_t(e.source[p], T), e.source_strides[p]
		if !is_intra {
			if p == 0 && luma_sad == 0 {
				for yy in 0 ..< region_h {
					copy(frame[(base_y + yy) * stride + base_x:][:region_w], source[(base_y + yy) * source_stride + base_x:][:region_w])
				}
				sub_idx := 0
				for y := 0; y < region_h; y += n {for x := 0; x < region_w; x += n {
					px, py := base_x + x, base_y + y
					x4, y4 := px >> 2, py >> 2
					if px < max_x && py < max_y {
						ctx := has_nz(t.above_nonzero[0][x4:][:step]) + has_nz(t.left_nonzero[0][y4 & 15:][:step])
						t.nzbuf[0][sub_idx] = u16(ctx << 12)
						sub_idx += 1
					}
					fill_nz(t.above_nonzero[0][x4:][:step], 0)
					fill_nz(t.left_nonzero[0][y4 & 15:][:step], 0)
				}}
				continue
			}
			reference := bordered_reference(e, p, T, u8(ref_frame[0]))
			if sub8x8 {
				w4_p, h4_p := region_w >> 2, region_h >> 2
				mvs := &block_mvs[0]
				for by in 0 ..< h4_p do for bx in 0 ..< w4_p {
					block_idx := by * w4_p + bx
					smv: [2]i32
					switch {
					case p == 0 || sx == 0 && sy == 0:
						smv = {i32(mvs[block_idx][0]), i32(mvs[block_idx][1])}
					case sx == 0 && sy == 1:
						for k in 0 ..< 2 do smv[k] = vp9.round_mv_q2(i32(mvs[block_idx][k]) + i32(mvs[block_idx + 2][k]))
					case sx == 1 && sy == 0:
						for k in 0 ..< 2 do smv[k] = vp9.round_mv_q2(i32(mvs[block_idx][k]) + i32(mvs[block_idx + 1][k]))
					case:
						for k in 0 ..< 2 do smv[k] = vp9.round_mv_q4(i32(mvs[0][k]) + i32(mvs[1][k]) + i32(mvs[2][k]) + i32(mvs[3][k]))
					}
					px, py := base_x + bx * 4, base_y + by * 4
					block := vp9.Inter_Block(T){&reference, (BORDER + px) * 16 + (int(smv[1]) * 2 >> sx), (BORDER + py) * 16 + (int(smv[0]) * 2 >> sy), 16, 16, 4, 4, interp_filter, e.bit_depth, &frame[py * stride + px], stride}
					vp9.predict_inter_block(&block)
				}
			} else {
				block := vp9.Inter_Block(T){&reference, (BORDER + base_x) * 16 + (int(mv[0][1]) * 2 >> sx), (BORDER + base_y) * 16 + (int(mv[0][0]) * 2 >> sy), 16, 16, region_w, region_h, interp_filter, e.bit_depth, &frame[base_y * stride + base_x], stride}
				vp9.predict_inter_block(&block)
				if is_comp {
					ref1 := bordered_reference(e, p, T, u8(ref_frame[1]))
					b1 := vp9.Inter_Block(T){&ref1, (BORDER + base_x) * 16 + (int(mv[1][1]) * 2 >> sx), (BORDER + base_y) * 16 + (int(mv[1][0]) * 2 >> sy), 16, 16, region_w, region_h, interp_filter, e.bit_depth, &pred[0], region_w}
					vp9.predict_inter_block(&b1)
					vp9.average_into(frame[base_y * stride + base_x:], stride, pred[:], region_w, region_w, region_h)
				}
			}
			if p == 0 && !lossless && !seg_skip && !sub8x8 {
				half_px := min(bw8, bh8) * 4
				_, min_s, max_s := quadrant_sad(half_px, source[base_y * source_stride + base_x:], source_stride, frame[base_y * stride + base_x:], stride)
				switch max_tx {
				case vp9.TX_8X8:
					tx = min_s * 3 < max_s || min_s * 2 < u32(ac) ? vp9.TX_4X4 : vp9.TX_8X8
				case vp9.TX_16X16:
					tx = min_s * 4 < max_s && min_s < u32(ac) ? vp9.TX_8X8 : vp9.TX_16X16
				case:
					tx = min_s * 2 >= max_s && min_s >= u32(ac) * 4 ? vp9.TX_32X32 : vp9.TX_16X16
				}
				if !e.config.ultrafast && max_s > min_s * 3 && max_s > u32(ac) * 2 {
					tx_alt := tx == max_tx ? max_tx - 1 : max_tx
					x40 := base_x >> 2
					nw4 := region_w >> 2
					var_a, var_l: [16]u8
					copy(var_a[:nw4], t.above_nonzero[0][x40:][:nw4])
					copy(var_l[:], t.left_nonzero[0][:])
					for yy in 0 ..< region_h do copy(pred[yy * region_w:][:region_w], frame[(base_y + yy) * stride + base_x:][:region_w])
					t_ctx := tx_size_ctx(t, r, c, size)
					q := i64(ac)
					bw := min(region_w, max_x - base_x)
					bh := min(region_h, max_y - base_y)
					nz_alt, rate_alt := transform_plane(t, r, c, size, 0, tx_alt, false, false, mode, uv_mode, sub_modes, dc, ac, true, T)
					if nz_alt {
						rate_alt += i64(code_bit_cost(TX_SIZE_CODES[max_tx][tx_alt], e.probs.tx[max_tx][t_ctx][:]))
					}
					rd_alt := plane_sse(bw, bh, source[base_y * source_stride + base_x:], source_stride, frame[base_y * stride + base_x:], stride) + ((rate_alt * q * q * 14) >> 16)
					copy(t.above_nonzero[0][x40:][:nw4], var_a[:nw4])
					copy(t.left_nonzero[0][:], var_l[:])
					for yy in 0 ..< region_h do copy(frame[(base_y + yy) * stride + base_x:][:region_w], pred[yy * region_w:][:region_w])
					nz_def, rate_def := transform_plane(t, r, c, size, 0, tx, false, false, mode, uv_mode, sub_modes, dc, ac, true, T)
					if nz_def {
						rate_def += i64(code_bit_cost(TX_SIZE_CODES[max_tx][tx], e.probs.tx[max_tx][t_ctx][:]))
					}
					rd_def := plane_sse(bw, bh, source[base_y * source_stride + base_x:], source_stride, frame[base_y * stride + base_x:], stride) + ((rate_def * q * q * 14) >> 16)
					if rd_def <= rd_alt {
						if nz_def do any_nonzero = true
						continue
					}
					copy(t.above_nonzero[0][x40:][:nw4], var_a[:nw4])
					copy(t.left_nonzero[0][:], var_l[:])
					for yy in 0 ..< region_h do copy(frame[(base_y + yy) * stride + base_x:][:region_w], pred[yy * region_w:][:region_w])
					tx = tx_alt
				}
				ptx = tx
			}
		} else if p == 0 && !lossless && !seg_skip && !sub8x8 && !e.config.ultrafast && size <= vp9.BLOCK_16X16 {
			tx_alt := tx == max_tx ? max_tx - 1 : max_tx
			x40 := base_x >> 2
			nw4 := region_w >> 2
			var_a, var_l: [16]u8
			copy(var_a[:nw4], t.above_nonzero[0][x40:][:nw4])
			copy(var_l[:], t.left_nonzero[0][:])
			t_ctx := tx_size_ctx(t, r, c, size)
			q := i64(ac)
			bw := min(region_w, max_x - base_x)
			bh := min(region_h, max_y - base_y)
			_, rate_alt := transform_plane(t, r, c, size, 0, tx_alt, true, false, mode, uv_mode, sub_modes, dc, ac, true, T)
			rate_alt += i64(code_bit_cost(TX_SIZE_CODES[max_tx][tx_alt], e.probs.tx[max_tx][t_ctx][:]))
			rd_alt := plane_sse(bw, bh, source[base_y * source_stride + base_x:], source_stride, frame[base_y * stride + base_x:], stride) + ((rate_alt * q * q * 14) >> 16)
			copy(t.above_nonzero[0][x40:][:nw4], var_a[:nw4])
			copy(t.left_nonzero[0][:], var_l[:])
			nz_def, rate_def := transform_plane(t, r, c, size, 0, tx, true, false, mode, uv_mode, sub_modes, dc, ac, true, T)
			rate_def += i64(code_bit_cost(TX_SIZE_CODES[max_tx][tx], e.probs.tx[max_tx][t_ctx][:]))
			rd_def := plane_sse(bw, bh, source[base_y * source_stride + base_x:], source_stride, frame[base_y * stride + base_x:], stride) + ((rate_def * q * q * 14) >> 16)
			if rd_def <= rd_alt {
				if nz_def do any_nonzero = true
				continue
			}
			copy(t.above_nonzero[0][x40:][:nw4], var_a[:nw4])
			copy(t.left_nonzero[0][:], var_l[:])
			tx = tx_alt
			ptx = tx
		}
		nz, _ := transform_plane(t, r, c, size, p, ptx, is_intra, seg_skip, mode, uv_mode, sub_modes, p_dc, p_ac, false, T)
		if nz do any_nonzero = true
	}
	if e.segmentation.enabled && e.segmentation.update_map {
		if e.keyframe || !e.segmentation.temporal_update {
			put_seg_tree(t, seg_id)
			count_inc(t, &t.counts.seg_tree[seg_id])
		} else {
			seg_ctx := int(t.left_seg_pred[r & 7]) + int(t.above_seg_pred[c])
			pred := int(seg_id == predicted_seg)
			put_seg_pred(t, pred, seg_ctx)
			count_inc(t, &t.counts.seg_pred[seg_ctx][pred])
			if pred == 0 {
				put_seg_tree(t, seg_id)
				count_inc(t, &t.counts.seg_tree[seg_id])
			}
			for i in 0 ..< bw8 do t.above_seg_pred[c + i] = u8(pred)
			for i in 0 ..< bh8 do t.left_seg_pred[(r + i) & 7] = u8(pred)
		}
	}
	skip := seg_skip || !any_nonzero
	if !seg_skip {
		skip_ctx := int(avail_u && above_edge.skip) + int(avail_l && left_edge.skip)
		put_prob(t, int(skip), &e.probs.skip[skip_ctx])
		count_inc(t, &t.counts.skip[skip_ctx][int(skip)])
	}
	if e.keyframe {
		if !lossless && !sub8x8 do write_tx_size(t, r, c, size, tx)
		if !sub8x8 {
			above := avail_u ? int(above_edge.modes[0]) : vp9.DC_PRED
			left := avail_l ? int(left_edge.modes[0]) : vp9.DC_PRED
			put_tree_fixed(t, INTRA_MODE_CODES[mode], vp9.KF_Y_MODE_PROBS[above][left][:])
		} else {
			for idy := 0; idy < 2; idy += h4 {
				for idx := 0; idx < 2; idx += w4 {
					above := idy > 0 ? sub_modes[idx] : avail_u ? int(above_edge.modes[idx]) : vp9.DC_PRED
					left := idx > 0 ? sub_modes[idy * 2] : avail_l ? int(left_edge.modes[idy]) : vp9.DC_PRED
					put_tree_fixed(t, INTRA_MODE_CODES[sub_modes[idy * 2 + idx]], vp9.KF_Y_MODE_PROBS[above][left][:])
				}
			}
		}
		put_tree_fixed(t, INTRA_MODE_CODES[uv_mode], vp9.KF_UV_MODE_PROBS[mode][:])
	} else if is_intra {
		if !seg_ref_active {
			put_prob(t, 0, &e.probs.is_inter[is_inter_ctx])
			count_inc(t, &t.counts.is_inter[is_inter_ctx][0])
		}
		if !lossless && !sub8x8 do write_tx_size(t, r, c, size, tx)
		if !sub8x8 {
			sg := int(vp9.SIZE_GROUP_LOOKUP[size])
			put_tree_prob(t, INTRA_MODE_CODES[mode], e.probs.y_mode[sg][:])
			count_inc(t, &t.counts.intra_mode[sg][mode])
		} else {
			for idy := 0; idy < 2; idy += h4 {
				for idx := 0; idx < 2; idx += w4 {
					sm := sub_modes[idy * 2 + idx]
					put_tree_prob(t, INTRA_MODE_CODES[sm], e.probs.y_mode[0][:])
					count_inc(t, &t.counts.intra_mode[0][sm])
				}
			}
		}
		put_tree_prob(t, INTRA_MODE_CODES[uv_mode], e.probs.uv_mode[mode][:])
		count_inc(t, &t.counts.uv_mode[mode][uv_mode])
	} else {
		if !seg_ref_active {
			put_prob(t, 1, &e.probs.is_inter[is_inter_ctx])
			count_inc(t, &t.counts.is_inter[is_inter_ctx][1])
		}
		if !lossless && !skip && !sub8x8 do write_tx_size(t, r, c, size, tx)
		if !seg_ref_active {
			if e.allow_comp {
				put_prob(t, int(is_comp), &e.probs.comp_mode[comp_ctx])
				count_inc(t, &t.counts.comp_mode[comp_ctx][int(is_comp)])
			}
			if is_comp {
				comp_bit := int(ref_frame[1] == vp9.ALTREF_FRAME)
				put_prob(t, comp_bit, &e.probs.comp_ref[comp_ref_ctx])
				count_inc(t, &t.counts.comp_ref[comp_ref_ctx][comp_bit])
			} else {
				p1 := int(ref_frame[0] != vp9.LAST_FRAME)
				put_prob(t, p1, &e.probs.single_ref[ref_ctx1][0])
				count_inc(t, &t.counts.single_ref[ref_ctx1][0][p1])
				if p1 == 1 {
					p2 := int(ref_frame[0] == vp9.ALTREF_FRAME)
					put_prob(t, p2, &e.probs.single_ref[ref_ctx2][1])
					count_inc(t, &t.counts.single_ref[ref_ctx2][1][p2])
				}
			}
		}
		if !sub8x8 && !seg_skip {
			put_tree_prob(t, INTER_MODE_CODES[mode - vp9.NEARESTMV], e.probs.inter_mode[inter_ctx][:])
			count_inc(t, &t.counts.inter_mode[inter_ctx][mode - vp9.NEARESTMV])
		}
		if !e.config.ultrafast && !lossless {
			put_tree_prob(t, INTERP_FILTER_CODES[interp_filter], e.probs.interp_filter[filter_ctx][:])
			count_inc(t, &t.counts.interp_filter[filter_ctx][interp_filter])
		}
		if sub8x8 {
			for idy := 0; idy < 2; idy += h4 {
				for idx := 0; idx < 2; idx += w4 {
					b_i := idy * 2 + idx
					sm := sub_modes[b_i]
					put_tree_prob(t, INTER_MODE_CODES[sm - vp9.NEARESTMV], e.probs.inter_mode[inter_ctx][:])
					count_inc(t, &t.counts.inter_mode[inter_ctx][sm - vp9.NEARESTMV])
					if sm == vp9.NEWMV {
						put_mv(t, block_mvs[0][b_i], nearest[0])
						if is_comp do put_mv(t, block_mvs[1][b_i], nearest[1])
					}
				}
			}
		} else if mode == vp9.NEWMV {
			put_mv(t, mv[0], nearest[0])
			if is_comp do put_mv(t, mv[1], nearest[1])
		}
	}
	if !skip {
		is_inter := int(!is_intra)
		for p in 0 ..< 3 {
			sx := p > 0 ? uint(e.ss_x) : 0
			sy := p > 0 ? uint(e.ss_y) : 0
			ptx := p > 0 ? vp9.uv_tx_size(size, tx, e.ss_x, e.ss_y) : tx
			n := 4 << uint(ptx)
			region_w, region_h := (bw8 * 8) >> sx, (bh8 * 8) >> sy
			base_x, base_y := (c * 8) >> sx, (r * 8) >> sy
			max_x, max_y := (e.mi_cols * 8) >> sx, (e.mi_rows * 8) >> sy
			plane_type := min(p, 1)
			probs := &e.probs.coef[ptx][plane_type][is_inter]
			counts_more := &t.counts.more_coefs[ptx][plane_type][is_inter]
			sub_idx := 0
			for y := 0; y < region_h; y += n {for x := 0; x < region_w; x += n {
				if base_x + x < max_x && base_y + y < max_y {
					blk_mode := sub8x8 && p == 0 ? sub_modes[sub_idx] : mode
					tx_type := is_intra && p == 0 && !lossless && ptx != vp9.TX_32X32 ? int(vp9.MODE2TXFM_MAP[blk_mode]) : vp9.DCT_DCT
					entry := int(t.nzbuf[p][sub_idx])
					eob, ctx := entry & 0xFFF, entry >> 12
					if eob == 0 {
						put_prob(t, 0, &probs[0][ctx][0])
						count_inc(t, &counts_more[0][ctx][0])
					} else {
						quant := t.qbuf[p][sub_idx * n * n:][:n * n]
						put_tokens(t, p, is_inter, ctx, ptx, tx_type, quant, eob)
					}
					sub_idx += 1
				}
			}}
		}
	}
	stored_tx := !is_intra && skip && !lossless ? max_tx : tx
	edge := Edge_Context{ref_frame = ref_frame, tx_size = u8(stored_tx), interp_filter = u8(interp_filter), skip = skip}
	motion := Motion{mv = mv, sub_mvs = block_mvs, ref_frame = ref_frame, y_mode = u8(mode), sub8x8 = sub8x8}
	m := vp9.Mode_Info{skip = skip, mi_size = u8(size), tx_size = u8(stored_tx), ref_frame = ref_frame, y_mode = u8(mode), segment_id = u8(seg_id)}
	rows, cols := min(bh8, e.mi_rows - r), min(bw8, e.mi_cols - c)
	cell := vp9.filter_cell(m, &e.filter_levels, e.ss_x, e.ss_y)
	edge.modes = {u8(sub_modes[2]), u8(sub_modes[3])}
	for x in 0 ..< cols do t.above_context[c + x] = edge
	edge.modes = {u8(sub_modes[1]), u8(sub_modes[3])}
	for y in 0 ..< rows do t.left_context[(r + y) & 7] = edge
	update_seg := e.segmentation.enabled && e.segmentation.update_map
	for y in 0 ..< rows do for x in 0 ..< cols {
		idx := (r + y) * e.mi_cols + c + x
		e.motion[idx] = motion
		e.filter_cells[idx] = cell
		if update_seg do e.segment_ids[idx] = u8(seg_id)
	}
	dist: i64
	if t.trial_depth > 0 {
		for p in 0 ..< 3 {
			sx := p > 0 ? uint(e.ss_x) : 0
			sy := p > 0 ? uint(e.ss_y) : 0
			bx, by := (c * 8) >> sx, (r * 8) >> sy
			bw := min((bw8 * 8) >> sx, ((e.mi_cols * 8) >> sx) - bx)
			bh := min((bh8 * 8) >> sy, ((e.mi_rows * 8) >> sy) - by)
			if bw > 0 && bh > 0 {
				source := plane_t(e.source[p], T)
				frame := plane_t(e.planes[p], T)
				dist += plane_sse(bw, bh, source[by * e.source_strides[p] + bx:], e.source_strides[p], frame[by * e.strides[p] + bx:], e.strides[p])
			}
		}
	}
	return dist
}

@(private)
comp_mode_ctx :: proc(avail_u, avail_l: bool, above_ref, left_ref: [2]i8) -> int {
	FIXED :: i8(vp9.LAST_FRAME)
	above_intra, left_intra := above_ref[0] <= vp9.INTRA_FRAME, left_ref[0] <= vp9.INTRA_FRAME
	above_single, left_single := above_ref[1] <= vp9.NONE, left_ref[1] <= vp9.NONE
	switch {
	case avail_u && avail_l:
		switch {
		case above_single && left_single:
			return int(above_ref[0] == FIXED) ~ int(left_ref[0] == FIXED)
		case above_single:
			return 2 + int(above_ref[0] == FIXED || above_intra)
		case left_single:
			return 2 + int(left_ref[0] == FIXED || left_intra)
		}
		return 4
	case avail_u:
		return above_single ? int(above_ref[0] == FIXED) : 3
	case avail_l:
		return left_single ? int(left_ref[0] == FIXED) : 3
	}
	return 1
}

@(private)
calc_comp_ref_ctx :: proc(avail_u, avail_l: bool, above_ref, left_ref: [2]i8) -> int {
	FIXED :: i8(vp9.LAST_FRAME)
	VAR0 :: i8(vp9.GOLDEN_FRAME)
	VAR1 :: i8(vp9.ALTREF_FRAME)
	above_intra, left_intra := above_ref[0] <= vp9.INTRA_FRAME, left_ref[0] <= vp9.INTRA_FRAME
	above_single, left_single := above_ref[1] <= vp9.NONE, left_ref[1] <= vp9.NONE
	switch {
	case avail_u && avail_l:
		switch {
		case above_intra && left_intra:
			return 2
		case left_intra:
			return 1 + 2 * int((above_single ? above_ref[0] : above_ref[1]) != VAR1)
		case above_intra:
			return 1 + 2 * int((left_single ? left_ref[0] : left_ref[1]) != VAR1)
		}
		vrfa := above_single ? above_ref[0] : above_ref[1]
		vrfl := left_single ? left_ref[0] : left_ref[1]
		switch {
		case vrfa == vrfl && VAR1 == vrfa:
			return 0
		case left_single && above_single:
			if vrfa == FIXED && vrfl == VAR0 || vrfl == FIXED && vrfa == VAR0 do return 4
			return vrfa == vrfl ? 3 : 1
		case left_single || above_single:
			vrfc := left_single ? vrfa : vrfl
			rfs := above_single ? vrfa : vrfl
			if vrfc == VAR1 && rfs != VAR1 do return 1
			if rfs == VAR1 && vrfc != VAR1 do return 2
			return 4
		case vrfa == vrfl:
			return 4
		}
		return 2
	case avail_u:
		if above_intra do return 2
		return above_single ? 3 * int(above_ref[0] != VAR1) : 4 * int(above_ref[1] != VAR1)
	case avail_l:
		if left_intra do return 2
		return left_single ? 3 * int(left_ref[0] != VAR1) : 4 * int(left_ref[1] != VAR1)
	}
	return 2
}

@(private)
single_ref_p1_ctx :: proc(avail_u, avail_l: bool, above_ref, left_ref: [2]i8) -> int {
	LAST :: i8(vp9.LAST_FRAME)
	above_intra, left_intra := above_ref[0] <= vp9.INTRA_FRAME, left_ref[0] <= vp9.INTRA_FRAME
	above_single, left_single := above_ref[1] <= vp9.NONE, left_ref[1] <= vp9.NONE
	switch {
	case avail_u && avail_l:
		switch {
		case above_intra && left_intra:
			return 2
		case left_intra:
			return above_single ? 4 * int(above_ref[0] == LAST) : 1 + int(above_ref[0] == LAST || above_ref[1] == LAST)
		case above_intra:
			return left_single ? 4 * int(left_ref[0] == LAST) : 1 + int(left_ref[0] == LAST || left_ref[1] == LAST)
		case above_single && left_single:
			return 2 * int(above_ref[0] == LAST) + 2 * int(left_ref[0] == LAST)
		case !above_single && !left_single:
			return 1 + int(above_ref[0] == LAST || above_ref[1] == LAST || left_ref[0] == LAST || left_ref[1] == LAST)
		}
		rfs := above_single ? above_ref[0] : left_ref[0]
		crf1 := above_single ? left_ref[0] : above_ref[0]
		crf2 := above_single ? left_ref[1] : above_ref[1]
		if rfs == LAST do return 3 + int(crf1 == LAST || crf2 == LAST)
		return int(crf1 == LAST || crf2 == LAST)
	case avail_u:
		if above_intra do return 2
		return above_single ? 4 * int(above_ref[0] == LAST) : 1 + int(above_ref[0] == LAST || above_ref[1] == LAST)
	case avail_l:
		if left_intra do return 2
		return left_single ? 4 * int(left_ref[0] == LAST) : 1 + int(left_ref[0] == LAST || left_ref[1] == LAST)
	}
	return 2
}

@(private)
single_ref_p2_ctx :: proc(avail_u, avail_l: bool, above_ref, left_ref: [2]i8) -> int {
	LAST :: i8(vp9.LAST_FRAME)
	GOLDEN :: i8(vp9.GOLDEN_FRAME)
	ALTREF :: i8(vp9.ALTREF_FRAME)
	above_intra, left_intra := above_ref[0] <= vp9.INTRA_FRAME, left_ref[0] <= vp9.INTRA_FRAME
	above_single, left_single := above_ref[1] <= vp9.NONE, left_ref[1] <= vp9.NONE
	switch {
	case avail_u && avail_l:
		switch {
		case above_intra && left_intra:
			return 2
		case left_intra:
			if above_single {
				if above_ref[0] == LAST do return 3
				return 4 * int(above_ref[0] == GOLDEN)
			}
			return 1 + 2 * int(above_ref[0] == GOLDEN || above_ref[1] == GOLDEN)
		case above_intra:
			if left_single {
				if left_ref[0] == LAST do return 3
				return 4 * int(left_ref[0] == GOLDEN)
			}
			return 1 + 2 * int(left_ref[0] == GOLDEN || left_ref[1] == GOLDEN)
		case above_single && left_single:
			a, l := above_ref[0], left_ref[0]
			switch {
			case a == LAST && l == LAST:
				return 3
			case a == LAST:
				return 4 * int(l == GOLDEN)
			case l == LAST:
				return 4 * int(a == GOLDEN)
			}
			return 2 * int(a == GOLDEN) + 2 * int(l == GOLDEN)
		case !above_single && !left_single:
			if above_ref[0] == left_ref[0] && above_ref[1] == left_ref[1] {
				return 3 * int(above_ref[0] == GOLDEN || above_ref[1] == GOLDEN)
			}
			return 2
		}
		rfs := above_single ? above_ref[0] : left_ref[0]
		crf1 := above_single ? left_ref[0] : above_ref[0]
		crf2 := above_single ? left_ref[1] : above_ref[1]
		if rfs == GOLDEN do return 3 + int(crf1 == GOLDEN || crf2 == GOLDEN)
		if rfs == ALTREF do return int(crf1 == GOLDEN || crf2 == GOLDEN)
		return 1 + 2 * int(crf1 == GOLDEN || crf2 == GOLDEN)
	case avail_u:
		if above_intra || above_ref[0] == LAST && above_single do return 2
		if above_single do return 4 * int(above_ref[0] == GOLDEN)
		return 3 * int(above_ref[0] == GOLDEN || above_ref[1] == GOLDEN)
	case avail_l:
		if left_intra || left_ref[0] == LAST && left_single do return 2
		if left_single do return 4 * int(left_ref[0] == GOLDEN)
		return 3 * int(left_ref[0] == GOLDEN || left_ref[1] == GOLDEN)
	}
	return 2
}

@(private)
tx_size_ctx :: proc(t: ^Tile, r, c, size: int) -> int #no_bounds_check {
	max_tx := int(vp9.MAX_TXSIZE_LOOKUP[size])
	avail_u, avail_l := r > 0, c > t.first_col
	above, left := max_tx, max_tx
	if avail_u && !t.above_context[c].skip do above = int(t.above_context[c].tx_size)
	if avail_l && !t.left_context[r & 7].skip do left = int(t.left_context[r & 7].tx_size)
	if !avail_l do left = above
	if !avail_u do above = left
	return above + left > max_tx ? 1 : 0
}

@(private)
write_tx_size :: proc(t: ^Tile, r, c, size, tx: int) #no_bounds_check {
	e := t.e
	max_tx := int(vp9.MAX_TXSIZE_LOOKUP[size])
	ctx := tx_size_ctx(t, r, c, size)
	put_tree_prob(t, TX_SIZE_CODES[max_tx][tx], e.probs.tx[max_tx][ctx][:])
	count_inc(t, &t.counts.tx_size[max_tx][ctx][tx])
}

@(private)
token_block_cost :: proc(t: ^Tile, p, is_inter, ctx0, tx, tx_type: int, quant: []i32, eob: int) -> i64 #no_bounds_check {
	plane_type := min(p, 1)
	probs := &t.e.probs.coef[tx][plane_type][is_inter]
	if eob == 0 do return i64(bit_cost(0, probs[0][ctx0][0]))
	scan := vp9.scan_entries(tx, tx_type)
	cache := &t.token_cache
	cost := i64(0)
	check_eob := true
	bit_depth := t.e.bit_depth
	for e, c in scan[:eob] {
		pos := int(e.pos)
		ctx := c == 0 ? ctx0 : (1 + int(cache[e.above]) + int(cache[e.left])) >> 1
		pr := &probs[e.band][ctx]
		c_cost, cls := coeff_token_cost(abs(int(quant[pos])), check_eob, pr, bit_depth)
		cost += c_cost
		cache[pos] = cls
		check_eob = quant[pos] != 0
	}
	if eob < len(scan) {
		e := scan[eob]
		ctx := (1 + int(cache[e.above]) + int(cache[e.left])) >> 1
		cost += i64(bit_cost(0, probs[e.band][ctx][0]))
	}
	return cost
}

@(private)
transform_plane :: proc(t: ^Tile, r, c, size, p, ptx: int, is_intra, seg_skip: bool, mode, uv_mode: int, sub_modes: [4]int, dc, ac: i32, calc_rate: bool, $T: typeid) -> (any_nz: bool, rate: i64) #no_bounds_check {
	V4 :: #simd[4]i32
	UT4 :: #simd[4]T
	V8 :: #simd[8]i32
	UT8 :: #simd[8]T
	e := t.e
	sub8x8 := size < vp9.BLOCK_8X8
	bw8 := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size])
	bh8 := int(vp9.NUM_8X8_BLOCKS_HIGH_LOOKUP[size])
	sx := p > 0 ? uint(e.ss_x) : 0
	sy := p > 0 ? uint(e.ss_y) : 0
	n, step := 4 << uint(ptx), 1 << uint(ptx)
	region_w, region_h := (bw8 * 8) >> sx, (bh8 * 8) >> sy
	base_x, base_y := (c * 8) >> sx, (r * 8) >> sy
	max_x, max_y := (e.mi_cols * 8) >> sx, (e.mi_rows * 8) >> sy
	max_x4, max_y4 := max_x >> 2, max_y >> 2
	stride := e.strides[p]
	frame := plane_t(e.planes[p], T)
	source, source_stride := plane_t(e.source[p], T), e.source_strides[p]
	lossless := e.lossless
	qshift: uint = ptx == vp9.TX_32X32 ? 1 : 0
	is_inter := int(!is_intra)
	bias_num: i32 = is_intra ? (ptx == vp9.TX_32X32 ? 5 : 3) : (ptx == vp9.TX_32X32 ? 4 : 2)
	dc_bias := lossless ? 2 : (dc * bias_num) >> 3
	ac_bias := lossless ? 2 : (ac * bias_num) >> 3
	ac_thresh := max((ac - ac_bias + (1 << qshift) - 1) >> qshift, 1)
	thresh_v8: V8 = ac_thresh
	max_q := i32((1 << uint(6 + e.bit_depth)) + 66)
	max_sample := i32((1 << uint(e.bit_depth)) - 1)
	max_v4: V4 = max_sample
	max_v8: V8 = max_sample
	sub_idx := 0
	for y := 0; y < region_h; y += n {for x := 0; x < region_w; x += n {
		px, py := base_x + x, base_y + y
		x4, y4 := px >> 2, py >> 2
		if px >= max_x || py >= max_y {
			fill_nz(t.above_nonzero[p][x4:][:step], 0)
			fill_nz(t.left_nonzero[p][y4 & 15:][:step], 0)
			continue
		}
		blk_mode := p > 0 ? uv_mode : (sub8x8 ? sub_modes[sub_idx] : mode)
		if is_intra {
			edges := vp9.Intra_Edges{have_left = c > t.first_col || x > 0, have_above = r > 0 || y > 0, not_on_right = x + n < region_w, max_x = max_x - 1, max_y = max_y - 1}
			vp9.predict_intra(frame, stride, px, py, ptx, blk_mode, edges, e.bit_depth)
		}
		tx_type := is_intra && p == 0 && !lossless && ptx != vp9.TX_32X32 ? int(vp9.MODE2TXFM_MAP[blk_mode]) : vp9.DCT_DCT
		ctx := has_nz(t.above_nonzero[p][x4:][:step]) + has_nz(t.left_nonzero[p][y4 & 15:][:step])
		quant := t.qbuf[p][sub_idx * n * n:][:n * n]
		if seg_skip {
			t.nzbuf[p][sub_idx] = u16(ctx << 12)
			sub_idx += 1
			fill_nz(t.above_nonzero[p][x4:][:step], 0)
			fill_nz(t.left_nonzero[p][y4 & 15:][:step], 0)
			continue
		}
		block := t.block_storage[:n * n]
		all_zero := false
		if n == 4 {
			any_diff: V4 = 0
			for yy in 0 ..< 4 {
				s_row := source[(py + yy) * source_stride + px:]
				p_row := frame[(py + yy) * stride + px:]
				b_row := block[yy * 4:]
				sv := V4(intrinsics.unaligned_load((^UT4)(&s_row[0])))
				pv := V4(intrinsics.unaligned_load((^UT4)(&p_row[0])))
				diff := sv - pv
				any_diff |= diff
				intrinsics.unaligned_store((^V4)(&b_row[0]), diff)
			}
			all_zero = simd.reduce_or(any_diff) == 0
		} else {
			any_diff: V8 = 0
			for yy in 0 ..< n {
				s_row := source[(py + yy) * source_stride + px:]
				p_row := frame[(py + yy) * stride + px:]
				b_row := block[yy * n:]
				for xx := 0; xx < n; xx += 8 {
					sv := V8(intrinsics.unaligned_load((^UT8)(&s_row[xx])))
					pv := V8(intrinsics.unaligned_load((^UT8)(&p_row[xx])))
					diff := sv - pv
					any_diff |= diff
					intrinsics.unaligned_store((^V8)(&b_row[xx]), diff)
				}
			}
			all_zero = simd.reduce_or(any_diff) == 0
		}
		if all_zero {
			t.nzbuf[p][sub_idx] = u16(ctx << 12)
			if calc_rate do rate += token_block_cost(t, p, is_inter, ctx, ptx, tx_type, quant, 0)
			sub_idx += 1
			fill_nz(t.above_nonzero[p][x4:][:step], 0)
			fill_nz(t.left_nonzero[p][y4 & 15:][:step], 0)
			continue
		}
		vp9.forward_transform(&e.forward, block, ptx, tx_type, lossless, e.bit_depth)
		nz_count := 0
		for base := 0; base < n * n; base += 8 {
			bv := intrinsics.unaligned_load((^V8)(&block[base]))
			av := simd.abs(bv)
			if base > 0 && simd.reduce_or(simd.lanes_ge(av, thresh_v8)) == 0 {
				intrinsics.unaligned_store((^V8)(&quant[base]), V8(0))
				continue
			}
			for lane in 0 ..< 8 {
				k := base + lane
				v := block[k]
				step_q := k == 0 ? dc : ac
				bias := k == 0 ? dc_bias : ac_bias
				qv := min(((abs(v) << qshift) + bias) / step_q, max_q)
				if qv != 0 {
					quant[k] = v < 0 ? -qv : qv
					nz_count += 1
				} else {
					quant[k] = 0
				}
			}
		}
		eob, last_pos: int
		if nz_count > 0 {
			if lossless {
				scan := vp9.scan_entries(ptx, tx_type)
				rem := nz_count
				for se, i in scan {
					rc := int(se.pos)
					if qv := quant[rc]; qv != 0 {
						eob = i + 1
						if rc > last_pos do last_pos = rc
						rem -= 1
						if rem == 0 do break
					}
				}
				for &v, k in block do v = quant[k] << 2
			} else {
				eob, last_pos = optimize_quant(t, p, is_inter, ctx, ptx, tx_type, block, quant, dc, ac, qshift, nz_count)
			}
		}
		t.nzbuf[p][sub_idx] = u16(eob | (ctx << 12))
		if calc_rate do rate += token_block_cost(t, p, is_inter, ctx, ptx, tx_type, quant, eob)
		sub_idx += 1
		nz := u8(eob > 0)
		fill_nz(t.above_nonzero[p][x4:][:step], nz)
		fill_nz(t.left_nonzero[p][y4 & 15:][:step], nz)
		if eob > 0 {
			for k in max_x4 ..< x4 + step do t.above_nonzero[p][k] = 0
			for k in max_y4 ..< y4 + step do t.left_nonzero[p][k & 15] = 0
			any_nz = true
			log2_n := uint(ptx) + 2
			if last_pos == 0 && !lossless && tx_type == vp9.DCT_DCT {
				dc_res := vp9.dc_residual(block[0], log2_n)
				if n == 4 {
					rv: V4 = dc_res
					for yy in 0 ..< 4 {
						p_row := frame[(py + yy) * stride + px:]
						pv := V4(intrinsics.unaligned_load((^UT4)(&p_row[0])))
						cv := simd.clamp(pv + rv, V4(0), max_v4)
						intrinsics.unaligned_store((^UT4)(&p_row[0]), UT4(cv))
					}
				} else {
					rv: V8 = dc_res
					for yy in 0 ..< n {
						p_row := frame[(py + yy) * stride + px:]
						for xx := 0; xx < n; xx += 8 {
							pv := V8(intrinsics.unaligned_load((^UT8)(&p_row[xx])))
							cv := simd.clamp(pv + rv, V8(0), max_v8)
							intrinsics.unaligned_store((^UT8)(&p_row[xx]), UT8(cv))
						}
					}
				}
			} else {
				vp9.inverse_transform(block, log2_n, tx_type, lossless, (last_pos >> log2_n) + 1)
				for yy in 0 ..< n {
					p_row := frame[(py + yy) * stride + px:]
					b_row := block[yy * n:]
					if n == 4 {
						pv := V4(intrinsics.unaligned_load((^UT4)(&p_row[0])))
						rv := intrinsics.unaligned_load((^V4)(&b_row[0]))
						cv := simd.clamp(pv + rv, V4(0), max_v4)
						intrinsics.unaligned_store((^UT4)(&p_row[0]), UT4(cv))
					} else {
						for xx := 0; xx < n; xx += 8 {
							pv := V8(intrinsics.unaligned_load((^UT8)(&p_row[xx])))
							rv := intrinsics.unaligned_load((^V8)(&b_row[xx]))
							cv := simd.clamp(pv + rv, V8(0), max_v8)
							intrinsics.unaligned_store((^UT8)(&p_row[xx]), UT8(cv))
						}
					}
				}
			}
		}
	}}
	return any_nz, rate
}

@(private)
dequant :: #force_inline proc(qv, step: i32, qshift: uint) -> i32 {
	dq := (abs(qv) * step) >> qshift
	return qv < 0 ? -dq : dq
}

@(private)
coeff_token_cost :: #force_inline proc(aq: int, check_eob: bool, pr: ^[3]u8, bit_depth: int) -> (cost: i64, class: u8) #no_bounds_check {
	if check_eob do cost = i64(bit_cost(1, pr[0]))
	if aq == 0 do return cost + i64(bit_cost(0, pr[1])), 0
	cost += i64(bit_cost(1, pr[1])) + 256
	if aq == 1 do return cost + i64(bit_cost(0, pr[2])), 1
	token := aq <= 4 ? aq : aq < 67 ? 4 + int(31 - intrinsics.count_leading_zeros(u32(aq - 3))) : 10
	pareto := vp9.pareto_row(pr[2])
	cost += i64(bit_cost(1, pr[2])) + i64(code_bit_cost(TOKEN_PARETO_CODES[token], pareto[:]))
	if token >= 5 do cost += i64(int(vp9.EXTRA_BITS[token][1]) + (token == vp9.DCT_VAL_CAT6 ? bit_depth - 8 : 0)) * 256
	return cost, vp9.ENERGY_CLASS[token]
}

@(private)
optimize_quant :: proc(t: ^Tile, p, is_inter, ctx0, tx, tx_type: int, block, quant: []i32, dc, ac: i32, qshift: uint, nz_count: int) -> (final_eob, last_pos: int) #no_bounds_check {
	plane_type := min(p, 1)
	probs := &t.e.probs.coef[tx][plane_type][is_inter]
	scan := vp9.scan_entries(tx, tx_type)
	cache := &t.token_cache
	bit_depth := t.e.bit_depth
	eob := 0
	rem := nz_count
	for e, i in scan {
		if quant[e.pos] != 0 {
			eob = i + 1
			rem -= 1
			if rem == 0 do break
		}
	}
	if abs(quant[scan[eob - 1].pos]) > 1 {
		final_eob = eob
	} else {
		q := i64(ac)
		rdmult := q * q * (plane_type == 0 ? 15 : 10)
		rd_cost :: #force_inline proc(rdmult, rate, dist: i64) -> i64 {
			return dist + ((rate * rdmult) >> 15)
		}
		best_rd := rd_cost(rdmult, i64(bit_cost(0, probs[0][ctx0][0])), 0)
		accu_rate := i64(0)
		accu_dist := i64(0)
		check_eob := true
		for i in 0 ..< eob {
			e := scan[i]
			rc := int(e.pos)
			ctx := i == 0 ? ctx0 : (1 + int(cache[e.above]) + int(cache[e.left])) >> 1
			band := int(e.band)
			pr := &probs[band][ctx]
			q0 := quant[rc]
			if q0 == 0 {
				accu_rate += (check_eob ? i64(bit_cost(1, pr[0])) : 0) + i64(bit_cost(0, pr[1]))
				cache[rc] = 0
				check_eob = false
				continue
			}
			step := rc == 0 ? dc : ac
			av := i64(abs(block[rc]) << qshift)
			aq0 := abs(int(q0))
			dq0 := i64(aq0) * i64(step)
			d0 := dq0 * (dq0 - 2 * av)
			rate0, class0 := coeff_token_cost(aq0, check_eob, pr, bit_depth)
			accu_rate += rate0
			accu_dist += d0
			cache[rc] = class0
			check_eob = true
			next_eob := i64(0)
			if i + 1 < len(scan) {
				en := scan[i + 1]
				ctx_n := (1 + int(cache[en.above]) + int(cache[en.left])) >> 1
				next_eob = i64(bit_cost(0, probs[en.band][ctx_n][0]))
			}
			eob_rd := rd_cost(rdmult, accu_rate + next_eob, accu_dist)
			if eob_rd < best_rd {
				best_rd = eob_rd
				final_eob = i + 1
			}
		}
		for i in final_eob ..< eob do quant[scan[i].pos] = 0
		if final_eob == 0 do return 0, 0
	}
	for i in 0 ..< final_eob {
		rc := int(scan[i].pos)
		if quant[rc] != 0 && rc > last_pos do last_pos = rc
	}
	if last_pos == 0 && tx_type == vp9.DCT_DCT {
		block[0] = dequant(quant[0], dc, qshift)
		return final_eob, 0
	}
	for &v in block do v = 0
	for i in 0 ..< final_eob {
		rc := int(scan[i].pos)
		if qv := quant[rc]; qv != 0 {
			block[rc] = dequant(qv, rc == 0 ? dc : ac, qshift)
		}
	}
	return final_eob, last_pos
}

@(private)
put_tokens :: proc(t: ^Tile, p, is_inter, ctx0, tx, tx_type: int, quant: []i32, eob: int) #no_bounds_check {
	plane_type := min(p, 1)
	probs := &t.e.probs.coef[tx][plane_type][is_inter]
	counts_more := &t.counts.more_coefs[tx][plane_type][is_inter]
	counts_token := &t.counts.token[tx][plane_type][is_inter]
	scan := vp9.scan_entries(tx, tx_type)
	cache := &t.token_cache
	ctx := ctx0
	check_eob := true
	bit_depth := t.e.bit_depth
	for e, c in scan[:eob] {
		pos := int(e.pos)
		if c > 0 do ctx = (1 + int(cache[e.above]) + int(cache[e.left])) >> 1
		band := int(e.band)
		pr := &probs[band][ctx]
		if check_eob {
			put_prob(t, 1, &pr[0])
			count_inc(t, &counts_more[band][ctx][1])
		}
		qval := int(quant[pos])
		if qval == 0 {
			put_prob(t, 0, &pr[1])
			count_inc(t, &counts_token[band][ctx][0])
			cache[pos] = 0
			check_eob = false
			continue
		}
		put_prob(t, 1, &pr[1])
		value := abs(qval)
		if value == 1 {
			put_prob(t, 0, &pr[2])
			put_fixed(t, int(qval < 0), 128)
			count_inc(t, &counts_token[band][ctx][1])
			cache[pos] = 1
			check_eob = true
			continue
		}
		token := value <= 4 ? value : value < 67 ? 4 + int(31 - intrinsics.count_leading_zeros(u32(value - 3))) : 10
		put_prob(t, 1, &pr[2])
		put_tree_pareto(t, &pr[2], token)
		if token >= 5 {
			extra := &vp9.EXTRA_BITS[token]
			count := int(extra[1])
			v := value - int(extra[2])
			if token == vp9.DCT_VAL_CAT6 {
				for eb in 0 ..< bit_depth - 8 do put_fixed(t, (v >> uint(5 + bit_depth - eb)) & 1, 255)
			}
			cat_probs := &vp9.CAT_PROBS[extra[0]]
			for k in 0 ..< count do put_fixed(t, v >> uint(count - 1 - k) & 1, cat_probs[k])
		}
		put_fixed(t, int(qval < 0), 128)
		count_inc(t, &counts_token[band][ctx][2])
		cache[pos] = vp9.ENERGY_CLASS[token]
		check_eob = true
	}
	if eob < len(scan) {
		e := scan[eob]
		ctx = (1 + int(cache[e.above]) + int(cache[e.left])) >> 1
		band := int(e.band)
		put_prob(t, 0, &probs[band][ctx][0])
		count_inc(t, &counts_more[band][ctx][0])
	}
}

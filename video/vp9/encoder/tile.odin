package vp9_encoder

import vp9 ".."
import "base:intrinsics"
import "core:simd"

@(private)
Tile :: struct {
	e: ^Encoder,
	first_col, end_col: int,
	b: Bool_Writer,
	syms: [dynamic]u16,
	counts: vp9.Counts,
	prev_origin_mv: vp9.Mv,
	above_partition: []u8,
	above_nonzero: [3][]u8,
	left_partition: [8]u8,
	left_nonzero: [3][16]u8,
}

// Tiles stage their symbols, coded once the compressed header has settled
// this frame's probabilities. A symbol is its bit (bit 15) and where its
// probability is: below 256 the probability itself, below 4096 a byte of
// Probabilities (offset + 256), above that a Pareto row entry of a
// coefficient probability (4096 + offset * 8 + entry).
#assert(256 + size_of(vp9.Probabilities) <= 4096)
#assert(4096 + (offset_of(vp9.Probabilities, coef) + size_of(vp9.Probabilities{}.coef)) * 8 <= 1 << 15)

@(private)
emit_sym :: #force_inline proc(t: ^Tile, sym: u16) {
	if _, err := append(&t.syms, sym); err != nil do t.b.failed = true
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
put_tree_fixed :: proc(t: ^Tile, tree: []i8, probs: []u8, value: int) {
	path, bits, ok := tree_path(tree, 0, value)
	assert(ok)
	node := 0
	for i := bits - 1; i >= 0; i -= 1 {
		bit := path >> uint(i) & 1
		put_fixed(t, bit, probs[node >> 1])
		node = int(tree[node + bit])
	}
}

@(private)
put_tree_prob :: proc(t: ^Tile, tree: []i8, probs: []u8, value: int) {
	path, bits, ok := tree_path(tree, 0, value)
	assert(ok)
	node := 0
	for i := bits - 1; i >= 0; i -= 1 {
		bit := path >> uint(i) & 1
		put_prob(t, bit, &probs[node >> 1])
		node = int(tree[node + bit])
	}
}

@(private)
put_tree_pareto :: proc(t: ^Tile, pr2: ^u8, token: int) {
	base := 4096 + (int(uintptr(pr2) - uintptr(&t.e.probs)) << 3)
	path, bits, ok := tree_path(vp9.TOKEN_TREE[:], 4, token)
	assert(ok)
	node := 4
	for i := bits - 1; i >= 0; i -= 1 {
		bit := path >> uint(i) & 1
		emit_sym(t, u16((bit << 15) | (base + (node >> 1) - 2)))
		node = int(vp9.TOKEN_TREE[node + bit])
	}
}

@(private)
encode_tile :: proc(t: ^Tile) {
	stage_source(t)
	clear(&t.syms)
	t.b.failed = false
	for r := 0; r < t.e.mi_rows; r += 8 {
		t.left_partition, t.left_nonzero = {}, {}
		for c := t.first_col; c < t.end_col; c += 8 do encode_partition(t, r, c, vp9.BLOCK_64X64)
	}
}

@(private)
flush_tile :: proc(t: ^Tile) #no_bounds_check {
	if t.b.failed do return
	probs_bytes := ([^]u8)(&t.e.probs)
	b := t.b
	start_bool(&b)
	for s in t.syms {
		bit := int(s >> 15)
		id := int(s & 0x7FFF)
		prob: u8
		if id < 256 {
			prob = u8(id)
		} else if id < 4096 {
			prob = probs_bytes[id - 256]
		} else {
			rem := id - 4096
			pr2 := probs_bytes[rem >> 3]
			prob = vp9.pareto_row(pr2)[rem & 7]
		}
		put_bool(&b, bit, prob)
	}
	finish_bool(&b)
	t.b = b
}

// Copies this tile's columns of the input into the aligned source, replicating
// the right and bottom edges, so block loops index it without clamping.
@(private)
stage_source :: proc(t: ^Tile) #no_bounds_check {
	e := t.e
	for p in 0 ..< 3 {
		shift := p > 0 ? uint(1) : 0
		w, h := (e.config.width + int(shift)) >> shift, (e.config.height + int(shift)) >> shift
		stride := e.source_strides[p]
		rows := len(e.source[p]) / stride
		x0 := t.first_col * 8 >> shift
		x1 := t.end_col == e.mi_cols ? stride : t.end_col * 8 >> shift
		visible := max(0, min(x1, w) - x0)
		for y in 0 ..< rows {
			dst := e.source[p][y * stride + x0:][:x1 - x0]
			src := e.input[p][min(y, h - 1) * e.input_strides[p]:]
			copy(dst[:visible], src[x0:][:visible])
			for &v in dst[visible:] do v = src[w - 1]
		}
	}
}

@(private)
encode_partition :: proc(t: ^Tile, r, c, size: int) #no_bounds_check {
	e := t.e
	if r >= e.mi_rows || c >= e.mi_cols do return
	n := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size])
	half := n / 2
	has_rows, has_cols := r + half < e.mi_rows, c + half < e.mi_cols
	bsl := uint(vp9.MI_WIDTH_LOG2_LOOKUP[size])
	a, l: u8
	for i in 0 ..< n {a |= t.above_partition[c + i]; l |= t.left_partition[(r + i) & 7]}
	ctx := int(bsl) * 4 + int(l >> (3 - bsl) & 1) * 2 + int(a >> (3 - bsl) & 1)
	leaf := size == vp9.BLOCK_8X8 || int(bsl) <= e.config.block_log2 - 3 && has_rows && has_cols && !should_split(t, r, c, size)
	part := leaf ? vp9.PARTITION_NONE : vp9.PARTITION_SPLIT
	if e.keyframe {
		probs := &vp9.KF_PARTITION_PROBS[ctx]
		switch {
		case has_rows && has_cols: put_tree_fixed(t, vp9.PARTITION_TREE[:], probs[:], part)
		case has_cols: put_fixed(t, 1, probs[1])
		case has_rows: put_fixed(t, 1, probs[2])
		}
	} else {
		probs := &e.probs.partition[ctx]
		switch {
		case has_rows && has_cols: put_tree_prob(t, vp9.PARTITION_TREE[:], probs[:], part)
		case has_cols: put_prob(t, 1, &probs[1])
		case has_rows: put_prob(t, 1, &probs[2])
		}
	}
	t.counts.partition[ctx][part] += 1
	if leaf {
		encode_block(t, r, c, size)
		for i in 0 ..< n {
			t.above_partition[c + i] = u8(15) >> vp9.B_WIDTH_LOG2_LOOKUP[size]
			t.left_partition[(r + i) & 7] = u8(15) >> vp9.B_HEIGHT_LOG2_LOOKUP[size]
		}
	} else {
		subsize := int(vp9.SUBSIZE_LOOKUP[vp9.PARTITION_SPLIT][size])
		encode_partition(t, r, c, subsize)
		encode_partition(t, r, c + half, subsize)
		encode_partition(t, r + half, c, subsize)
		encode_partition(t, r + half, c + half, subsize)
	}
}

@(private)
should_split :: proc(t: ^Tile, r, c, size: int) -> bool #no_bounds_check {
	e := t.e
	half_px := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size]) * 4
	x, y := c * 8, r * 8
	s_stride := e.source_strides[0]
	area := u32(half_px * half_px)
	q0 := &e.source[0][y * s_stride + x]
	q1 := &e.source[0][y * s_stride + x + half_px]
	q2 := &e.source[0][(y + half_px) * s_stride + x]
	q3 := &e.source[0][(y + half_px) * s_stride + x + half_px]
	if e.keyframe {
		p0 := &e.source[0][y * s_stride + x]
		p1 := &e.source[0][(y + half_px - 2) * s_stride + x + half_px - 2]
		v_diff := block_sad(half_px, p0, s_stride, &e.source[0][(y + 2) * s_stride + x], s_stride) + block_sad(half_px, p1, s_stride, &e.source[0][(y + half_px) * s_stride + x + half_px - 2], s_stride)
		h_diff := block_sad(half_px, p0, s_stride, &e.source[0][y * s_stride + x + 2], s_stride) + block_sad(half_px, p1, s_stride, &e.source[0][(y + half_px - 2) * s_stride + x + half_px], s_stride)
		return min(v_diff, h_diff) > area / 2
	}
	r_stride := e.strides[0]
	rx, ry := BORDER + x, BORDER + y
	r0 := &e.reference_storage[0][ry * r_stride + rx]
	r1 := &e.reference_storage[0][ry * r_stride + rx + half_px]
	r2 := &e.reference_storage[0][(ry + half_px) * r_stride + rx]
	r3 := &e.reference_storage[0][(ry + half_px) * r_stride + rx + half_px]
	s0 := block_sad(half_px, q0, s_stride, r0, r_stride)
	s1 := block_sad(half_px, q1, s_stride, r1, r_stride)
	s2 := block_sad(half_px, q2, s_stride, r2, r_stride)
	s3 := block_sad(half_px, q3, s_stride, r3, r_stride)
	if e.config.base_q_idx == 0 do return s0 + s1 + s2 + s3 > 0
	min_s := min(min(s0, s1), min(s2, s3))
	max_s := max(max(s0, s1), max(s2, s3))
	q := u32(vp9.ac_q(8, e.config.base_q_idx))
	noise := (area * q) >> 5
	return max_s > min_s + noise || max_s > noise * 3
}

@(private)
encode_block :: proc(t: ^Tile, r, c, size: int) #no_bounds_check {
	V4 :: #simd[4]i32
	U4 :: #simd[4]u8
	e := t.e
	n8 := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size])
	lossless := e.config.base_q_idx == 0
	max_tx := int(vp9.MAX_TXSIZE_LOOKUP[size])
	tx := lossless || size == vp9.BLOCK_8X8 ? vp9.TX_4X4 : max_tx
	mv := vp9.Mv{}
	predictor := vp9.Mv{}
	inter_ctx := 0
	mode := vp9.DC_PRED
	if e.keyframe {
		mode = choose_intra(t, r, c, size, tx)
	} else {
		predictor, inter_ctx = motion_predictor(t, r, c, size)
		mv = search_motion(t, r, c, size, predictor)
		mode = mv == predictor ? vp9.NEARESTMV : mv == vp9.Mv{} ? vp9.ZEROMV : vp9.NEWMV
	}
	any_nonzero := false
	dc, ac := vp9.dc_q(8, e.config.base_q_idx), vp9.ac_q(8, e.config.base_q_idx)
	dc_bias := e.keyframe ? dc * 2 / 5 : dc / 4
	ac_bias := e.keyframe ? ac * 2 / 5 : ac / 4
	ac_thresh := ac - ac_bias
	zero_v: V4 = 0
	max_v: V4 = 255
	qbuf: [3][4096]i32 = ---
	nzbuf: [3][256]u16 = ---
	for p in 0 ..< 3 {
		shift := p > 0 ? uint(1) : 0
		ptx := p > 0 ? vp9.uv_tx_size(size, tx, 1, 1) : tx
		n := 4 << uint(ptx)
		region := n8 * 8 >> shift
		base_x, base_y := c * 8 >> shift, r * 8 >> shift
		max_x, max_y := e.mi_cols * 8 >> shift, e.mi_rows * 8 >> shift
		stride := e.strides[p]
		frame := e.planes[p]
		source, source_stride := e.source[p], e.source_strides[p]
		if !e.keyframe {
			reference := bordered_reference(e, p)
			block := vp9.Inter_Block(u8){&reference, (BORDER + base_x) * 16 + (int(mv[1]) * 2 >> shift), (BORDER + base_y) * 16 + (int(mv[0]) * 2 >> shift), 16, 16, region, region, vp9.EIGHTTAP, 8, &frame[base_y * stride + base_x], stride}
			vp9.predict_inter_block(&block)
		}
		qshift := ptx == vp9.TX_32X32 ? uint(1) : 0
		qshift_v: #simd[4]u32 = u32(qshift)
		sub_idx := 0
		for y := 0; y < region; y += n {for x := 0; x < region; x += n {
			sx, sy := base_x + x, base_y + y
			if sx >= max_x || sy >= max_y do continue
			if e.keyframe do vp9.predict_intra(frame, stride, sx, sy, ptx, p > 0 ? vp9.DC_PRED : mode, {have_left = c > t.first_col || x > 0, have_above = r > 0 || y > 0, not_on_right = x + n < region, max_x = max_x - 1, max_y = max_y - 1}, 8)
			storage: [1024]i32 = ---
			block := storage[:n * n]
			max_diff: V4 = 0
			for yy in 0 ..< n {
				src := source[(sy + yy) * source_stride + sx:]
				pred := frame[(sy + yy) * stride + sx:]
				dst := block[yy * n:]
				for xx := 0; xx < n; xx += 4 {
					s_v := V4(intrinsics.unaligned_load((^U4)(&src[xx])))
					p_v := V4(intrinsics.unaligned_load((^U4)(&pred[xx])))
					diff := s_v - p_v
					max_diff = simd.max(max_diff, V4(simd.abs(diff)))
					intrinsics.unaligned_store((^V4)(&dst[xx]), diff)
				}
			}
			if simd.reduce_max(max_diff) == 0 {
				nzbuf[p][sub_idx] = 0
				sub_idx += 1
				continue
			}
			tx_type := e.keyframe && p == 0 && !lossless && ptx != vp9.TX_32X32 ? int(vp9.MODE2TXFM_MAP[mode]) : vp9.DCT_DCT
			vp9.forward_transform(&e.forward, block, ptx, tx_type, lossless)
			quant := qbuf[p][sub_idx * n * n:][:n * n]
			nz_count := 0
			last_pos := 0
			if lossless {
				nz_vec: #simd[4]u32 = 0
				for i := 0; i < n * n; i += 4 {
					v := intrinsics.unaligned_load((^V4)(&block[i]))
					av := V4(simd.abs(v))
					aq := simd.shr(av + 2, 2)
					q_vec := simd.select(simd.lanes_lt(v, zero_v), -aq, aq)
					intrinsics.unaligned_store((^V4)(&quant[i]), q_vec)
					intrinsics.unaligned_store((^V4)(&block[i]), simd.shl(q_vec, 2))
					mask := simd.lanes_ne(q_vec, zero_v)
					if simd.reduce_or(mask) != 0 {
						nz_vec -= mask
						last_pos = i + 3
					}
				}
				nz_count = int(simd.reduce_add_ordered(nz_vec))
			} else {
				v0 := block[0]
				for i := 0; i < n * n; i += 4 {
					v := intrinsics.unaligned_load((^V4)(&block[i]))
					av := simd.shl(V4(simd.abs(v)), qshift_v)
					if simd.reduce_max(av) < ac_thresh {
						intrinsics.unaligned_store((^V4)(&quant[i]), zero_v)
						intrinsics.unaligned_store((^V4)(&block[i]), zero_v)
					} else {
						for k in 0 ..< 4 {
							vk := block[i + k]
							qk := ((abs(vk) << qshift) + ac_bias) / ac * (vk < 0 ? -1 : 1)
							quant[i + k] = qk
							block[i + k] = (abs(qk) * ac >> qshift) * (qk < 0 ? -1 : 1)
							if qk != 0 {
								nz_count += 1
								last_pos = i + k
							}
						}
					}
				}
				if dc != ac {
					nz_count -= int(quant[0] != 0)
					q0 := ((abs(v0) << qshift) + dc_bias) / dc * (v0 < 0 ? -1 : 1)
					quant[0] = q0
					block[0] = (abs(q0) * dc >> qshift) * (q0 < 0 ? -1 : 1)
					nz_count += int(q0 != 0)
				}
			}
			nzbuf[p][sub_idx] = u16(nz_count)
			sub_idx += 1
			if nz_count > 0 {
				any_nonzero = true
				rows := (last_pos >> uint(ptx + 2)) + 1
				vp9.inverse_transform(block, uint(ptx + 2), tx_type, lossless, rows)
				for yy in 0 ..< n {
					row := frame[(sy + yy) * stride + sx:]
					res := block[yy * n:]
					for xx := 0; xx < n; xx += 4 {
						rv := intrinsics.unaligned_load((^V4)(&res[xx]))
						px := V4(intrinsics.unaligned_load((^U4)(&row[xx])))
						out := simd.clamp(px + rv, zero_v, max_v)
						intrinsics.unaligned_store((^U4)(&row[xx]), U4(out))
					}
				}
			}
		}}
	}
	skip := !any_nonzero
	skip_ctx := 0
	if r > 0 && e.mi[(r - 1) * e.mi_cols + c].skip do skip_ctx += 1
	if c > t.first_col && e.mi[r * e.mi_cols + c - 1].skip do skip_ctx += 1
	put_prob(t, int(skip), &e.probs.skip[skip_ctx])
	t.counts.skip[skip_ctx][int(skip)] += 1
	if e.keyframe {
		if !lossless do write_tx_size(t, r, c, size, tx)
		above := r > 0 ? int(e.mi[(r - 1) * e.mi_cols + c].sub_modes[2]) : vp9.DC_PRED
		left := c > t.first_col ? int(e.mi[r * e.mi_cols + c - 1].sub_modes[1]) : vp9.DC_PRED
		put_tree_fixed(t, vp9.INTRA_MODE_TREE[:], vp9.KF_Y_MODE_PROBS[above][left][:], mode)
		put_tree_fixed(t, vp9.INTRA_MODE_TREE[:], vp9.KF_UV_MODE_PROBS[mode][:], vp9.DC_PRED)
	} else {
		put_prob(t, 1, &e.probs.is_inter[0])
		t.counts.is_inter[0][1] += 1
		if !lossless && !skip do write_tx_size(t, r, c, size, tx)
		ref_ctx := r > 0 || c > t.first_col ? 4 : 2
		put_prob(t, 0, &e.probs.single_ref[ref_ctx][0])
		t.counts.single_ref[ref_ctx][0][0] += 1
		put_tree_prob(t, vp9.INTER_MODE_TREE[:], e.probs.inter_mode[inter_ctx][:], mode - vp9.NEARESTMV)
		t.counts.inter_mode[inter_ctx][mode - vp9.NEARESTMV] += 1
		if mode == vp9.NEWMV do put_mv(t, mv, predictor)
	}
	for p in 0 ..< 3 {
		shift := p > 0 ? uint(1) : 0
		ptx := p > 0 ? vp9.uv_tx_size(size, tx, 1, 1) : tx
		n, step := 4 << uint(ptx), 1 << uint(ptx)
		region := n8 * 8 >> shift
		base_x, base_y := c * 8 >> shift, r * 8 >> shift
		max_x, max_y := e.mi_cols * 8 >> shift, e.mi_rows * 8 >> shift
		tx_type := e.keyframe && p == 0 && !lossless && ptx != vp9.TX_32X32 ? int(vp9.MODE2TXFM_MAP[mode]) : vp9.DCT_DCT
		sub_idx := 0
		for y := 0; y < region; y += n {for x := 0; x < region; x += n {
			sx, sy := base_x + x, base_y + y
			nonzero := false
			if sx < max_x && sy < max_y {
				nz_count := int(nzbuf[p][sub_idx])
				if !skip {
					quant := qbuf[p][sub_idx * n * n:][:n * n]
					put_tokens(t, p, sx, sy, ptx, tx_type, quant, nz_count, max_x, max_y)
					nonzero = nz_count > 0
				}
				sub_idx += 1
			}
			for i in 0 ..< step {
				t.above_nonzero[p][(sx >> 2) + i] = u8(nonzero)
				t.left_nonzero[p][((sy >> 2) + i) & 15] = u8(nonzero)
			}
		}}
	}
	stored_tx := !e.keyframe && skip && !lossless ? max_tx : tx
	m := vp9.Mode_Info{skip = skip, mi_size = u8(size), tx_size = u8(stored_tx), ref_frame = {e.keyframe ? vp9.INTRA_FRAME : vp9.LAST_FRAME, vp9.NONE}, y_mode = u8(mode), sub_modes = {u8(mode),u8(mode),u8(mode),u8(mode)}, sub_mvs = {{mv,mv,mv,mv}, {}}}
	rows, cols := min(n8, e.mi_rows - r), min(n8, e.mi_cols - c)
	cell := vp9.filter_cell(m, &e.filter_levels, 1, 1)
	for y in 0 ..< rows do for x in 0 ..< cols {
		e.mi[(r + y) * e.mi_cols + c + x] = m
		e.filter_cells[(r + y) * e.mi_cols + c + x] = cell
	}
}

@(private)
write_tx_size :: proc(t: ^Tile, r, c, size, tx: int) #no_bounds_check {
	e := t.e
	max_tx := int(vp9.MAX_TXSIZE_LOOKUP[size])
	avail_u, avail_l := r > 0, c > t.first_col
	above, left := max_tx, max_tx
	if avail_u {
		m := &e.mi[(r - 1) * e.mi_cols + c]
		if !m.skip do above = int(m.tx_size)
	}
	if avail_l {
		m := &e.mi[r * e.mi_cols + c - 1]
		if !m.skip do left = int(m.tx_size)
	}
	if !avail_l do left = above
	if !avail_u do above = left
	ctx := above + left > max_tx ? 1 : 0
	probs := e.probs.tx[max_tx][ctx][:]
	switch max_tx {
	case vp9.TX_32X32: put_tree_prob(t, vp9.TX_SIZE_32_TREE[:], probs, tx)
	case vp9.TX_16X16: put_tree_prob(t, vp9.TX_SIZE_16_TREE[:], probs, tx)
	case: put_tree_prob(t, vp9.TX_SIZE_8_TREE[:], probs, tx)
	}
	t.counts.tx_size[max_tx][ctx][tx] += 1
}

@(private)
put_tokens :: proc(t: ^Tile, p, x, y, tx, tx_type: int, quant: []i32, nz_count, max_x, max_y: int) #no_bounds_check {
	plane_type := min(p, 1)
	is_inter := int(!t.e.keyframe)
	probs := &t.e.probs.coef[tx][plane_type][is_inter]
	counts_more := &t.counts.more_coefs[tx][plane_type][is_inter]
	above, left: u8
	step := 1 << uint(tx)
	x4, y4 := x >> 2, y >> 2
	max_x4, max_y4 := max_x >> 2, max_y >> 2
	for i in 0 ..< step {
		if x4 + i < max_x4 do above |= t.above_nonzero[p][x4 + i]
		if y4 + i < max_y4 do left |= t.left_nonzero[p][(y4 + i) & 15]
	}
	ctx := int(above) + int(left)
	if nz_count == 0 {
		put_prob(t, 0, &probs[0][ctx][0])
		counts_more[0][ctx][0] += 1
		return
	}
	counts_token := &t.counts.token[tx][plane_type][is_inter]
	scan := vp9.scan_entries(tx, tx_type)
	eob := 0
	rem := nz_count
	for e, i in scan {
		if quant[e.pos] != 0 {
			eob = i + 1
			rem -= 1
			if rem == 0 do break
		}
	}
	cache: [1024]u8 = ---
	check_eob := true
	for e, c in scan {
		pos := int(e.pos)
		if c > 0 do ctx = (1 + int(cache[e.above]) + int(cache[e.left])) >> 1
		band := int(e.band)
		pr := &probs[band][ctx]
		if check_eob {
			more := int(c < eob)
			put_prob(t, more, &pr[0])
			counts_more[band][ctx][more] += 1
			if more == 0 do break
		}
		qval := int(quant[pos])
		value := abs(qval)
		token := value <= 4 ? value : value < 67 ? 4 + int(31 - intrinsics.count_leading_zeros(u32(value - 3))) : 10
		put_prob(t, int(token != 0), &pr[1])
		if token != 0 {
			put_prob(t, int(token != 1), &pr[2])
			if token >= 2 do put_tree_pareto(t, &pr[2], token)
			extra := &vp9.EXTRA_BITS[token]
			count := int(extra[1])
			v := value - int(extra[2])
			cat_probs := &vp9.CAT_PROBS[extra[0]]
			for k in 0 ..< count do put_fixed(t, v >> uint(count - 1 - k) & 1, cat_probs[k])
			put_fixed(t, int(qval < 0), 128)
		}
		counts_token[band][ctx][min(2, token)] += 1
		cache[pos] = vp9.ENERGY_CLASS[token]
		check_eob = token != 0
	}
}

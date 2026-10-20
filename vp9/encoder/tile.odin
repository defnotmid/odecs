package vp9_encoder

import vp9 ".."

@(private)
Tile :: struct {
	e: ^Encoder,
	first_col, end_col: int,
	b: Bool_Writer,
	above_partition: []u8,
	above_nonzero: [3][]u8,
	left_partition: [8]u8,
	left_nonzero: [3][16]u8,
}

@(private)
encode_tile :: proc(t: ^Tile) {
	stage_source(t)
	start_bool(&t.b)
	for r := 0; r < t.e.mi_rows; r += 8 {
		t.left_partition, t.left_nonzero = {}, {}
		for c := t.first_col; c < t.end_col; c += 8 do encode_partition(t, r, c, vp9.BLOCK_64X64)
	}
	finish_bool(&t.b)
}

// Copies this tile's columns of the input into the aligned source, replicating
// the right and bottom edges, so block loops index it without clamping.
@(private)
stage_source :: proc(t: ^Tile) {
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
encode_partition :: proc(t: ^Tile, r, c, size: int) {
	e := t.e
	if r >= e.mi_rows || c >= e.mi_cols do return
	n := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size])
	half := n / 2
	has_rows, has_cols := r + half < e.mi_rows, c + half < e.mi_cols
	bsl := uint(vp9.MI_WIDTH_LOG2_LOOKUP[size])
	a, l: u8
	for i in 0 ..< n {a |= t.above_partition[c + i]; l |= t.left_partition[(r + i) & 7]}
	ctx := int(bsl) * 4 + int(l >> (3 - bsl) & 1) * 2 + int(a >> (3 - bsl) & 1)
	probs := e.keyframe ? vp9.KF_PARTITION_PROBS[ctx] : e.probs.partition[ctx]
	leaf := size == vp9.BLOCK_8X8 || int(bsl) <= e.config.block_log2 - 3 && has_rows && has_cols
	part := leaf ? vp9.PARTITION_NONE : vp9.PARTITION_SPLIT
	switch {
	case has_rows && has_cols: put_tree(&t.b, vp9.PARTITION_TREE[:], probs[:], part)
	case has_cols: put_bool(&t.b, 1, probs[1])
	case has_rows: put_bool(&t.b, 1, probs[2])
	}
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
encode_block :: proc(t: ^Tile, r, c, size: int) {
	e := t.e
	b := &t.b
	n8 := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size])
	lossless := e.config.base_q_idx == 0
	tx := lossless ? vp9.TX_4X4 : int(vp9.MAX_TXSIZE_LOOKUP[size])
	skip_ctx := 0
	if r > 0 && e.mi[(r - 1) * e.mi_cols + c].skip do skip_ctx += 1
	if c > t.first_col && e.mi[r * e.mi_cols + c - 1].skip do skip_ctx += 1
	put_bool(b, 0, e.probs.skip[skip_ctx])
	mv := vp9.Mv{}
	mode := vp9.DC_PRED
	if e.keyframe {
		mode = choose_intra(t, r, c, size)
		above := r > 0 ? int(e.mi[(r - 1) * e.mi_cols + c].sub_modes[2]) : vp9.DC_PRED
		left := c > t.first_col ? int(e.mi[r * e.mi_cols + c - 1].sub_modes[1]) : vp9.DC_PRED
		put_tree(b, vp9.INTRA_MODE_TREE[:], vp9.KF_Y_MODE_PROBS[above][left][:], mode)
		put_tree(b, vp9.INTRA_MODE_TREE[:], vp9.KF_UV_MODE_PROBS[mode][:], vp9.DC_PRED)
	} else {
		put_bool(b, 1, e.probs.is_inter[0])
		ref_ctx := r > 0 || c > t.first_col ? 4 : 2
		put_bool(b, 0, e.probs.single_ref[ref_ctx][0])
		predictor, ctx := motion_predictor(t, r, c, size)
		mv = search_motion(t, r, c, size, predictor)
		mode = mv == vp9.Mv{} ? vp9.ZEROMV : mv == predictor ? vp9.NEARESTMV : vp9.NEWMV
		put_tree(b, vp9.INTER_MODE_TREE[:], e.probs.inter_mode[ctx][:], mode - vp9.NEARESTMV)
		if mode == vp9.NEWMV do put_mv(t, mv, predictor)
	}
	any_nonzero := false
	for p in 0 ..< 3 {
		shift := p > 0 ? uint(1) : 0
		ptx := p > 0 ? vp9.uv_tx_size(size, tx, 1, 1) : tx
		n, step := 4 << uint(ptx), 1 << uint(ptx)
		region := n8 * 8 >> shift
		base_x, base_y := c * 8 >> shift, r * 8 >> shift
		max_x, max_y := e.mi_cols * 8 >> shift, e.mi_rows * 8 >> shift
		stride := e.strides[p]
		frame := e.planes[p]
		source, source_stride := e.source[p], e.source_strides[p]
		if !e.keyframe {
			vp9.predict_inter_block(bordered_reference(e, p), (BORDER + base_x) * 16 + (int(mv[1]) * 2 >> shift), (BORDER + base_y) * 16 + (int(mv[0]) * 2 >> shift), 16, 16, region, region, vp9.EIGHTTAP, 8, frame[base_y * stride + base_x:], stride)
		}
		for y := 0; y < region; y += n {for x := 0; x < region; x += n {
			sx, sy := base_x + x, base_y + y
			if sx >= max_x || sy >= max_y do continue
			if e.keyframe do vp9.predict_intra(frame, stride, sx, sy, ptx, p > 0 ? vp9.DC_PRED : mode, {have_left = c > t.first_col || x > 0, have_above = r > 0 || y > 0, not_on_right = x + n < region, max_x = max_x - 1, max_y = max_y - 1}, 8)
			storage: [1024]i32
			block := storage[:n * n]
			for yy in 0 ..< n {
				src := source[(sy + yy) * source_stride + sx:][:n]
				pred := frame[(sy + yy) * stride + sx:][:n]
				dst := block[yy * n:][:n]
				for xx in 0 ..< n do dst[xx] = i32(src[xx]) - i32(pred[xx])
			}
			tx_type := e.keyframe && p == 0 && !lossless && ptx != vp9.TX_32X32 ? int(vp9.MODE2TXFM_MAP[mode]) : vp9.DCT_DCT
			vp9.forward_transform(&e.forward, block, ptx, tx_type, lossless)
			qstorage: [1024]i32
			quant := qstorage[:n * n]
			dc, ac := vp9.dc_q(8, e.config.base_q_idx), vp9.ac_q(8, e.config.base_q_idx)
			qshift := ptx == vp9.TX_32X32 ? uint(1) : 0
			for v, i in block {
				q := i == 0 ? dc : ac
				quant[i] = ((abs(v) << qshift) + q / 2) / q * (v < 0 ? -1 : 1)
				block[i] = (abs(quant[i]) * q >> qshift) * (quant[i] < 0 ? -1 : 1)
			}
			nonzero := put_tokens(t, p, sx, sy, ptx, tx_type, quant)
			any_nonzero ||= nonzero
			if nonzero {
				vp9.inverse_transform(block, uint(ptx + 2), tx_type, lossless, n)
				for yy in 0 ..< n do for xx in 0 ..< n {
					at := (sy + yy) * stride + sx + xx
					frame[at] = u8(clamp(i32(frame[at]) + block[yy * n + xx], 0, 255))
				}
			}
			// Like the decoder, contexts beyond the 8-aligned frame edge are zero.
			for i in 0 ..< step {
				t.above_nonzero[p][(sx >> 2) + i] = u8(nonzero && sx + i * 4 < max_x)
				t.left_nonzero[p][((sy >> 2) + i) & 15] = u8(nonzero && sy + i * 4 < max_y)
			}
		}}
	}
	m := vp9.Mode_Info{skip = !e.keyframe && !any_nonzero, mi_size = u8(size), tx_size = u8(tx), ref_frame = {e.keyframe ? vp9.INTRA_FRAME : vp9.LAST_FRAME, vp9.NONE}, y_mode = u8(mode), sub_modes = {u8(mode),u8(mode),u8(mode),u8(mode)}, sub_mvs = {{mv,mv,mv,mv}, {}}}
	rows, cols := min(n8, e.mi_rows - r), min(n8, e.mi_cols - c)
	for y in 0 ..< rows do for x in 0 ..< cols do e.mi[(r + y) * e.mi_cols + c + x] = m
}

@(private)
put_tokens :: proc(t: ^Tile, p, x, y, tx, tx_type: int, quant: []i32) -> bool {
	probs := &t.e.probs.coef[tx][min(p, 1)][int(!t.e.keyframe)]
	above, left: u8
	step := 1 << uint(tx)
	for i in 0 ..< step {above |= t.above_nonzero[p][(x >> 2) + i]; left |= t.left_nonzero[p][((y >> 2) + i) & 15]}
	ctx := int(above) + int(left)
	scan := vp9.scan_entries(tx, tx_type)
	eob := 0
	for e, i in scan do if quant[e.pos] != 0 do eob = i + 1
	cache: [1024]u8
	check_eob := true
	for e, c in scan {
		pos := int(e.pos)
		if c > 0 do ctx = (1 + int(cache[e.above]) + int(cache[e.left])) >> 1
		pr := probs[e.band][ctx]
		if check_eob {
			put_bool(&t.b, int(c < eob), pr[0])
			if c >= eob do break
		}
		value := abs(int(quant[pos]))
		token := 0
		if value > 0 do for i in 1 ..< 11 do if value >= int(vp9.EXTRA_BITS[i][2]) do token = i
		put_bool(&t.b, int(token != 0), pr[1])
		if token != 0 {
			put_bool(&t.b, int(token != 1), pr[2])
			if token >= 2 {
				index := int(pr[2] - 1) / 2
				pareto := vp9.PARETO_TABLE[index]
				if pr[2] & 1 == 0 do for k in 0 ..< 8 do pareto[k] = u8((int(pareto[k]) + int(vp9.PARETO_TABLE[index + 1][k])) >> 1)
				put_tree(&t.b, vp9.TOKEN_TREE[:], pareto[:], token, 4, 2)
			}
			extra := vp9.EXTRA_BITS[token]
			count := int(extra[1])
			v := value - int(extra[2])
			for k in 0 ..< count do put_bool(&t.b, v >> uint(count - 1 - k) & 1, vp9.CAT_PROBS[extra[0]][k])
			put_bool(&t.b, int(quant[pos] < 0), 128)
		}
		cache[pos] = vp9.ENERGY_CLASS[token]
		check_eob = token != 0
	}
	return eob > 0
}

package vp9_encoder

import vp9 ".."
import "base:intrinsics"
import "core:simd"

MAX_MV :: 64 * 8 // 64 pixels in 1/8-sample units (inside BORDER = 80)

@(private)
mv_bounds :: #force_inline proc(e: ^Encoder, r, c, size: int) -> (min_y, max_y, min_x, max_x: int) #no_bounds_check {
	bh := int(vp9.NUM_8X8_BLOCKS_HIGH_LOOKUP[size])
	bw := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size])
	return max(-MAX_MV, -r * 64 - vp9.MV_BORDER),
		min(MAX_MV, (e.mi_rows - bh - r) * 64 + vp9.MV_BORDER),
		max(-MAX_MV, -c * 64 - vp9.MV_BORDER),
		min(MAX_MV, (e.mi_cols - bw - c) * 64 + vp9.MV_BORDER)
}

// Converts 1/256-bit syntax cost to SAD units at the frame's AC quantizer.
@(private)
sad_rate_cost :: #force_inline proc(e: ^Encoder, bits_256: u32) -> i64 {
	q := i64(max(16, int(vp9.ac_q(8, e.config.base_q_idx))))
	return (q * i64(bits_256)) >> 12
}

@(private)
motion_predictors :: proc(t: ^Tile, r, c, size: int) -> (nearest, near: vp9.Mv, mode_ctx: int) #no_bounds_check {
	e := t.e
	cands: [2]vp9.Mv
	count := 0
	add :: #force_inline proc(cands: ^[2]vp9.Mv, count: ^int, mv: vp9.Mv) {
		if count^ < 2 && (count^ == 0 || mv != cands[0]) {
			cands[count^] = mv
			count^ += 1
		}
	}
	counter := 0
	offsets := &vp9.MV_REF_BLOCKS[size]
	for i in 0 ..< 2 {
		y, x := r + int(offsets[i][0]), c + int(offsets[i][1])
		if y < 0 || y >= e.mi_rows || x < t.first_col || x >= t.end_col do continue
		m := &e.motion[y * e.mi_cols + x]
		counter += int(vp9.MODE_2_COUNTER[m.y_mode])
		if m.is_inter do add(&cands, &count, m.mv)
	}
	if count < 2 {
		for i in 2 ..< 8 {
			y, x := r + int(offsets[i][0]), c + int(offsets[i][1])
			if y < 0 || y >= e.mi_rows || x < t.first_col || x >= t.end_col do continue
			m := &e.motion[y * e.mi_cols + x]
			if m.is_inter do add(&cands, &count, m.mv)
		}
	}
	if count < 2 && !e.last_keyframe {
		m := &e.prev_motion[r * e.mi_cols + c]
		if m.is_inter do add(&cands, &count, m.mv)
	}
	min_r, max_r, min_c, max_c := mv_bounds(e, r, c, size)
	for i in 0 ..< 2 {
		row := clamp(int(cands[i][0]), min_r, max_r)
		col := clamp(int(cands[i][1]), min_c, max_c)
		if row & 1 != 0 do row += row > 0 ? -1 : 1
		if col & 1 != 0 do col += col > 0 ? -1 : 1
		cands[i] = {i16(row), i16(col)}
	}
	return cands[0], cands[1], int(vp9.COUNTER_TO_CONTEXT[counter])
}

// The whole bordered reference, addressed BORDER samples in: every vector the
// search admits keeps the filter footprint inside, so nothing is clamped.
@(private)
bordered_reference :: proc(e: ^Encoder, p: int) -> vp9.Ref_Plane(u8) {
	stride := e.strides[p]
	return {data = e.reference_storage[p], stride = stride, last_x = stride - 1, last_y = len(e.reference_storage[p]) / stride - 1}
}

// Sum of absolute differences of an n x n block, n = 4, 8, 16, 32 or 64.
@(private)
block_sad :: proc(n: int, a: [^]u8, a_stride: int, b: [^]u8, b_stride: int) -> u32 {
	switch n {
	case 4: return sad_rows(4, a, a_stride, b, b_stride)
	case 8: return sad_rows(8, a, a_stride, b, b_stride)
	case 16: return sad_rows(16, a, a_stride, b, b_stride)
	case 32: return sad_rows(32, a, a_stride, b, b_stride)
	}
	return sad_rows(64, a, a_stride, b, b_stride)
}

@(private)
sad_rows :: #force_inline proc($N: int, a: [^]u8, a_stride: int, b: [^]u8, b_stride: int) -> u32 #no_bounds_check {
	// N rows of differences up to 255 fit each u16 lane: 64 * 255 < 65536.
	total: #simd[N]u16
	for row in 0 ..< N {
		x := intrinsics.unaligned_load((^#simd[N]u8)(&a[row * a_stride]))
		y := intrinsics.unaligned_load((^#simd[N]u8)(&b[row * b_stride]))
		total += (#simd[N]u16)(simd.max(x, y) - simd.min(x, y))
	}
	return simd.reduce_add_ordered((#simd[N]u32)(total))
}

// Sum, minimum and maximum of the four half_px x half_px quadrant SADs of a block.
@(private)
quadrant_sad :: proc(half_px: int, a: [^]u8, a_stride: int, b: [^]u8, b_stride: int) -> (total, min_s, max_s: u32) #no_bounds_check {
	s0 := block_sad(half_px, a, a_stride, b, b_stride)
	s1 := block_sad(half_px, &a[half_px], a_stride, &b[half_px], b_stride)
	s2 := block_sad(half_px, &a[half_px * a_stride], a_stride, &b[half_px * b_stride], b_stride)
	s3 := block_sad(half_px, &a[half_px * a_stride + half_px], a_stride, &b[half_px * b_stride + half_px], b_stride)
	return s0 + s1 + s2 + s3, min(min(s0, s1), min(s2, s3)), max(max(s0, s1), max(s2, s3))
}

// Precomputes the frame's motion-vector component and joint bit costs once
// from e.probs before tiles run, so motion search reads flat tables.
@(private)
build_mv_costs :: proc(e: ^Encoder) #no_bounds_check {
	p := &e.probs
	for j in 0 ..< vp9.MV_JOINTS {
		e.mv_joint_cost[j] = u16(code_bit_cost(MV_JOINT_CODES[j], &p.mv_joint[0]))
	}
	for comp in 0 ..< 2 {
		s0 := bit_cost(0, p.mv_sign[comp])
		s1 := bit_cost(1, p.mv_sign[comp])
		e.mv_comp_cost[comp][0][0] = 0
		e.mv_comp_cost[comp][1][0] = 0
		for half in 1 ..= MAX_MV {
			mag := (half << 1) - 1
			class := mag < 16 ? 0 : int(28 - intrinsics.count_leading_zeros(u32(mag)))
			base := code_bit_cost(MV_CLASS_CODES[class], &p.mv_class[comp][0])
			fr := mag >> 1 & 3
			if class == 0 {
				bit := mag >> 3
				base += bit_cost(bit, p.mv_class0_bit[comp])
				base += code_bit_cost(MV_FR_CODES[fr], &p.mv_class0_fr[comp][bit][0])
			} else {
				offset := mag - (vp9.CLASS0_SIZE << uint(class + 2))
				for i in 0 ..< class do base += bit_cost(offset >> uint(i + 3) & 1, p.mv_bits[comp][i])
				base += code_bit_cost(MV_FR_CODES[fr], &p.mv_fr[comp][0])
			}
			e.mv_comp_cost[comp][0][half] = u16(s0 + base)
			e.mv_comp_cost[comp][1][half] = u16(s1 + base)
		}
	}
}

@(private)
mv_bit_cost :: #force_inline proc(e: ^Encoder, mv, predictor: vp9.Mv) -> u32 #no_bounds_check {
	d0, d1 := int(mv[0]) - int(predictor[0]), int(mv[1]) - int(predictor[1])
	joint := int(d1 != 0) + 2 * int(d0 != 0)
	return u32(e.mv_joint_cost[joint]) + u32(e.mv_comp_cost[0][int(d0 < 0)][abs(d0) >> 1]) + u32(e.mv_comp_cost[1][int(d1 < 0)][abs(d1) >> 1])
}

@(private)
best_inter_mode :: proc(e: ^Encoder, mv, nearest, near: vp9.Mv, mode_ctx: int) -> (mode: int, bits_256: u32) #no_bounds_check {
	pr := &e.probs.inter_mode[mode_ctx][0]
	mode = vp9.NEWMV
	bits_256 = max(u32)
	if mv == nearest {
		mode = vp9.NEARESTMV
		bits_256 = code_bit_cost(INTER_MODE_CODES[vp9.NEARESTMV - vp9.NEARESTMV], pr)
	}
	if mv == near {
		c := code_bit_cost(INTER_MODE_CODES[vp9.NEARMV - vp9.NEARESTMV], pr)
		if c < bits_256 {mode, bits_256 = vp9.NEARMV, c}
	}
	if mv == (vp9.Mv{}) {
		c := code_bit_cost(INTER_MODE_CODES[vp9.ZEROMV - vp9.NEARESTMV], pr)
		if c < bits_256 {mode, bits_256 = vp9.ZEROMV, c}
	}
	if bits_256 == max(u32) {
		bits_256 = code_bit_cost(INTER_MODE_CODES[vp9.NEWMV - vp9.NEARESTMV], pr) + mv_bit_cost(e, mv, nearest)
	}
	return
}

@(private)
motion_sad :: proc(t: ^Tile, r, c, size: int, mv: vp9.Mv) -> u32 #no_bounds_check {
	e := t.e
	n := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size]) * 8
	x, y := c * 8, r * 8
	source := &e.source[0][y * e.source_strides[0] + x]
	if mv[0] & 7 == 0 && mv[1] & 7 == 0 {
		at := (BORDER + y + int(mv[0]) / 8) * e.strides[0] + BORDER + x + int(mv[1]) / 8
		return block_sad(n, source, e.source_strides[0], &e.reference_storage[0][at], e.strides[0])
	}
	pred: [64 * 64]u8 = ---
	reference := bordered_reference(e, 0)
	block := vp9.Inter_Block(u8){&reference, (BORDER + x) * 16 + int(mv[1]) * 2, (BORDER + y) * 16 + int(mv[0]) * 2, 16, 16, n, n, vp9.EIGHTTAP, 8, &pred[0], n}
	vp9.predict_inter_block(&block)
	return block_sad(n, source, e.source_strides[0], &pred[0], n)
}

@(private)
Motion_Search :: struct {
	t: ^Tile,
	r, c, size, n, x0, y0: int,
	source: [^]u8,
	s_stride, r_stride: int,
	min_y, max_y, min_x, max_x: int,
	nearest, near: vp9.Mv,
	mode_ctx: int,
	best: vp9.Mv,
	best_mode: int,
	best_sad: u32,
	best_cost: i64,
}

@(private)
eval_motion_int :: #force_inline proc(s: ^Motion_Search, mv: vp9.Mv) #no_bounds_check {
	e := s.t.e
	at := (BORDER + s.y0 + int(mv[0]) / 8) * s.r_stride + BORDER + s.x0 + int(mv[1]) / 8
	sad := block_sad(s.n, s.source, s.s_stride, &e.reference_storage[0][at], s.r_stride)
	mode, bits := best_inter_mode(e, mv, s.nearest, s.near, s.mode_ctx)
	cost := i64(sad) + sad_rate_cost(e, bits)
	if cost < s.best_cost {
		s.best, s.best_mode, s.best_sad, s.best_cost = mv, mode, sad, cost
	}
}

@(private)
eval_motion_subpel :: #force_inline proc(s: ^Motion_Search, mv: vp9.Mv) -> i64 #no_bounds_check {
	e := s.t.e
	sad := motion_sad(s.t, s.r, s.c, s.size, mv)
	mode, bits := best_inter_mode(e, mv, s.nearest, s.near, s.mode_ctx)
	cost := i64(sad) + sad_rate_cost(e, bits)
	if cost < s.best_cost {
		s.best, s.best_mode, s.best_sad, s.best_cost = mv, mode, sad, cost
	}
	return cost
}

@(private)
search_motion :: proc(t: ^Tile, r, c, size: int, nearest, near: vp9.Mv, mode_ctx: int) -> (best: vp9.Mv, best_mode: int) #no_bounds_check {
	e := t.e
	radius := e.config.search_range * 8
	n := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size]) * 8
	x0, y0 := c * 8, r * 8
	min_y, max_y, min_x, max_x := mv_bounds(e, r, c, size)
	s := Motion_Search{
		t = t, r = r, c = c, size = size, n = n, x0 = x0, y0 = y0,
		source = &e.source[0][y0 * e.source_strides[0] + x0],
		s_stride = e.source_strides[0], r_stride = e.strides[0],
		min_y = min_y, max_y = max_y, min_x = min_x, max_x = max_x,
		nearest = nearest, near = near, mode_ctx = mode_ctx,
		best_mode = vp9.ZEROMV, best_sad = max(u32), best_cost = max(i64),
	}

	prev_mv := !e.last_keyframe ? e.prev_motion[r * e.mi_cols + c].mv : vp9.Mv{}
	raw_seeds := [5]vp9.Mv{nearest, {}, near, prev_mv, t.last_mv}
	seeds: [5]vp9.Mv = ---
	num_seeds := 0
	for raw in raw_seeds {
		mv := vp9.Mv{
			i16(clamp(int(raw[0]) & ~int(7), min_y, max_y)),
			i16(clamp(int(raw[1]) & ~int(7), min_x, max_x)),
		}
		dup := false
		for prev in seeds[:num_seeds] do if prev == mv {dup = true; break}
		if !dup {
			seeds[num_seeds] = mv
			num_seeds += 1
		}
	}
	for mv in seeds[:num_seeds] {
		eval_motion_int(&s, mv)
		if s.best_sad == 0 {
			t.last_mv = s.best
			return s.best, s.best_mode
		}
	}

	step := 8
	for step * 2 <= radius do step *= 2
	for ; step >= 8; step /= 2 {
		for _ in 0 ..< 4 {
			before := s.best
			for offset in ([4][2]int{{-1,0},{1,0},{0,-1},{0,1}}) {
				y, x := int(before[0]) + offset[0] * step, int(before[1]) + offset[1] * step
				if y < min_y || y > max_y || x < min_x || x > max_x do continue
				eval_motion_int(&s, {i16(y), i16(x)})
			}
			if s.best == before do break
		}
	}
	t.last_mv = s.best
	if s.best_sad == 0 do return s.best, s.best_mode

	if (nearest[0] & 7 != 0 || nearest[1] & 7 != 0) && int(nearest[0]) >= min_y && int(nearest[0]) <= max_y && int(nearest[1]) >= min_x && int(nearest[1]) <= max_x {
		eval_motion_subpel(&s, nearest)
		if s.best_sad == 0 {
			t.last_mv = s.best
			return s.best, s.best_mode
		}
	}
	if (near[0] & 7 != 0 || near[1] & 7 != 0) && near != nearest && int(near[0]) >= min_y && int(near[0]) <= max_y && int(near[1]) >= min_x && int(near[1]) <= max_x {
		eval_motion_subpel(&s, near)
		if s.best_sad == 0 {
			t.last_mv = s.best
			return s.best, s.best_mode
		}
	}
	if e.config.base_q_idx == 0 do return s.best, s.best_mode

	for sub_step in ([2]int{4, 2}) {
		before := s.best
		cy, cx := int(before[0]), int(before[1])
		c_up := cy - sub_step >= min_y ? eval_motion_subpel(&s, {i16(cy - sub_step), i16(cx)}) : max(i64)
		c_dn := cy + sub_step <= max_y ? eval_motion_subpel(&s, {i16(cy + sub_step), i16(cx)}) : max(i64)
		c_lt := cx - sub_step >= min_x ? eval_motion_subpel(&s, {i16(cy), i16(cx - sub_step)}) : max(i64)
		c_rt := cx + sub_step <= max_x ? eval_motion_subpel(&s, {i16(cy), i16(cx + sub_step)}) : max(i64)
		if s.best != before {
			dy := c_up < c_dn ? -sub_step : sub_step
			dx := c_lt < c_rt ? -sub_step : sub_step
			if cy + dy >= min_y && cy + dy <= max_y && cx + dx >= min_x && cx + dx <= max_x {
				eval_motion_subpel(&s, {i16(cy + dy), i16(cx + dx)})
			}
		}
	}
	t.last_mv = s.best
	return s.best, s.best_mode
}

@(private)
put_mv :: proc(t: ^Tile, mv, predictor: vp9.Mv) {
	p := &t.e.probs
	c := &t.counts
	diff := [2]int{int(mv[0]) - int(predictor[0]), int(mv[1]) - int(predictor[1])}
	joint := int(diff[1] != 0) + 2 * int(diff[0] != 0)
	put_tree_prob(t, MV_JOINT_CODES[joint], &p.mv_joint[0])
	c.mv_joint[joint] += 1
	for comp in 0 ..< 2 {
		v := diff[comp]
		if v == 0 do continue
		sign := int(v < 0)
		put_prob(t, sign, &p.mv_sign[comp])
		c.mv_sign[comp][sign] += 1
		mag := abs(v) - 1
		class := mag < 16 ? 0 : int(28 - intrinsics.count_leading_zeros(u32(mag)))
		put_tree_prob(t, MV_CLASS_CODES[class], &p.mv_class[comp][0])
		c.mv_class[comp][class] += 1
		fr := mag >> 1 & 3
		if class == 0 {
			bit := mag >> 3
			put_prob(t, bit, &p.mv_class0_bit[comp])
			c.mv_class0_bit[comp][bit] += 1
			put_tree_prob(t, MV_FR_CODES[fr], &p.mv_class0_fr[comp][bit][0])
			c.mv_class0_fr[comp][bit][fr] += 1
			c.mv_class0_hp[comp][1] += 1
		} else {
			offset := mag - (vp9.CLASS0_SIZE << uint(class + 2))
			for i in 0 ..< class {
				bit := offset >> uint(i + 3) & 1
				put_prob(t, bit, &p.mv_bits[comp][i])
				c.mv_bits[comp][i][bit] += 1
			}
			put_tree_prob(t, MV_FR_CODES[fr], &p.mv_fr[comp][0])
			c.mv_fr[comp][fr] += 1
			c.mv_hp[comp][1] += 1
		}
		// Quarter-pixel MVs have implicit hp=1 (magnitude's low bit is zero).
	}
}

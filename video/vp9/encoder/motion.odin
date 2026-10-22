package vp9_encoder

import vp9 ".."
import "base:intrinsics"
import "core:simd"

@(private)
motion_predictor :: proc(t: ^Tile, r, c, size: int) -> (best: vp9.Mv, mode_ctx: int) {
	e := t.e
	counter := 0
	found := false
	for offset, i in vp9.MV_REF_BLOCKS[size] {
		y, x := r + int(offset[0]), c + int(offset[1])
		if y < 0 || y >= e.mi_rows || x < t.first_col || x >= t.end_col do continue
		m := &e.mi[y * e.mi_cols + x]
		if i < 2 do counter += int(vp9.MODE_2_COUNTER[m.y_mode])
		if !found {best = m.sub_mvs[0][3]; found = true}
	}
	if !found && !e.last_keyframe do best = t.prev_origin_mv
	best[0] = i16(clamp(int(best[0]), -r * 64 - vp9.MV_BORDER, (e.mi_rows - int(vp9.NUM_8X8_BLOCKS_HIGH_LOOKUP[size]) - r) * 64 + vp9.MV_BORDER))
	best[1] = i16(clamp(int(best[1]), -c * 64 - vp9.MV_BORDER, (e.mi_cols - int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size]) - c) * 64 + vp9.MV_BORDER))
	return best, int(vp9.COUNTER_TO_CONTEXT[counter])
}

// The whole bordered reference, addressed BORDER samples in: every vector the
// search admits keeps the filter footprint inside, so nothing is clamped.
@(private)
bordered_reference :: proc(e: ^Encoder, p: int) -> vp9.Ref_Plane(u8) {
	stride := e.strides[p]
	return {data = e.reference_storage[p], stride = stride, last_x = stride - 1, last_y = len(e.reference_storage[p]) / stride - 1}
}

// Sum of absolute differences of an n x n block, n = 8, 16 or 32.
@(private)
block_sad :: proc(n: int, a: [^]u8, a_stride: int, b: [^]u8, b_stride: int) -> u32 {
	switch n {
	case 8: return sad_rows(8, a, a_stride, b, b_stride)
	case 16: return sad_rows(16, a, a_stride, b, b_stride)
	}
	return sad_rows(32, a, a_stride, b, b_stride)
}

@(private)
sad_rows :: #force_inline proc($N: int, a: [^]u8, a_stride: int, b: [^]u8, b_stride: int) -> u32 #no_bounds_check {
	// N rows of differences up to 255 fit each u16 lane: 32 * 255 < 65536.
	total: #simd[N]u16
	for row in 0 ..< N {
		x := intrinsics.unaligned_load((^#simd[N]u8)(&a[row * a_stride]))
		y := intrinsics.unaligned_load((^#simd[N]u8)(&b[row * b_stride]))
		total += (#simd[N]u16)(simd.max(x, y) - simd.min(x, y))
	}
	return simd.reduce_add_ordered((#simd[N]u32)(total))
}

@(private)
motion_cost :: proc(t: ^Tile, r, c, size: int, mv, predictor: vp9.Mv) -> i64 {
	e := t.e
	n := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size]) * 8
	x, y := c * 8, r * 8
	source := &e.source[0][y * e.source_strides[0] + x]
	if mv[0] & 7 == 0 && mv[1] & 7 == 0 {
		// Integer candidates read the reference directly.
		at := (BORDER + y + int(mv[0]) / 8) * e.strides[0] + BORDER + x + int(mv[1]) / 8
		return i64(block_sad(n, source, e.source_strides[0], &e.reference_storage[0][at], e.strides[0])) + motion_penalty(e, mv, predictor)
	}
	pred: [32 * 32]u8 = ---
	reference := bordered_reference(e, 0)
	block := vp9.Inter_Block(u8){&reference, (BORDER + x) * 16 + int(mv[1]) * 2, (BORDER + y) * 16 + int(mv[0]) * 2, 16, 16, n, n, vp9.EIGHTTAP, 8, &pred[0], n}
	vp9.predict_inter_block(&block)
	return i64(block_sad(n, source, e.source_strides[0], &pred[0], n)) + motion_penalty(e, mv, predictor)
}

@(private)
motion_penalty :: proc(e: ^Encoder, mv, predictor: vp9.Mv) -> i64 {
	if mv == (vp9.Mv{}) do return 0
	if mv == predictor do return 1
	q := i64(max(8, int(vp9.ac_q(8, e.config.base_q_idx))))
	diff := i64(abs(int(mv[0]) - int(predictor[0])) + abs(int(mv[1]) - int(predictor[1])))
	return q / 2 + (q * diff) >> 5
}

@(private)
search_motion :: proc(t: ^Tile, r, c, size: int, predictor: vp9.Mv) -> vp9.Mv {
	e := t.e
	radius := e.config.search_range * 8
	best := vp9.Mv{}
	cost := motion_cost(t, r, c, size, best, predictor)
	if cost == 0 do return best
	if abs(int(predictor[0])) <= radius && abs(int(predictor[1])) <= radius {
		candidate_cost := motion_cost(t, r, c, size, predictor, predictor)
		if candidate_cost < cost {best, cost = predictor, candidate_cost}
	}
	// Coarse-to-fine diamond search, then half- and quarter-pixel refinement.
	step := 8
	for step * 2 <= radius do step *= 2
	for ; step >= 2; step /= 2 {
		for {
			before := best
			for offset in ([4][2]int{{-1,0},{1,0},{0,-1},{0,1}}) {
				y, x := int(before[0]) + offset[0] * step, int(before[1]) + offset[1] * step
				if abs(y) > radius || abs(x) > radius do continue
				mv := vp9.Mv{i16(y), i16(x)}
				candidate_cost := motion_cost(t, r, c, size, mv, predictor)
				if candidate_cost < cost {best, cost = mv, candidate_cost}
			}
			if best == before do break
		}
	}
	return best
}

@(private)
put_mv :: proc(t: ^Tile, mv, predictor: vp9.Mv) {
	p := &t.e.probs
	c := &t.counts
	diff := [2]int{int(mv[0]) - int(predictor[0]), int(mv[1]) - int(predictor[1])}
	joint := int(diff[1] != 0) + 2 * int(diff[0] != 0)
	put_tree_prob(t, vp9.MV_JOINT_TREE[:], p.mv_joint[:], joint)
	c.mv_joint[joint] += 1
	for comp in 0 ..< 2 {
		v := diff[comp]
		if v == 0 do continue
		sign := int(v < 0)
		put_prob(t, sign, &p.mv_sign[comp])
		c.mv_sign[comp][sign] += 1
		mag := abs(v) - 1
		class := 0
		for mag >= (vp9.CLASS0_SIZE << uint(class + 3)) do class += 1
		put_tree_prob(t, vp9.MV_CLASS_TREE[:], p.mv_class[comp][:], class)
		c.mv_class[comp][class] += 1
		fr := mag >> 1 & 3
		if class == 0 {
			bit := mag >> 3
			put_prob(t, bit, &p.mv_class0_bit[comp])
			c.mv_class0_bit[comp][bit] += 1
			put_tree_prob(t, vp9.MV_FR_TREE[:], p.mv_class0_fr[comp][bit][:], fr)
			c.mv_class0_fr[comp][bit][fr] += 1
			c.mv_class0_hp[comp][1] += 1
		} else {
			offset := mag - (vp9.CLASS0_SIZE << uint(class + 2))
			for i in 0 ..< class {
				bit := offset >> uint(i + 3) & 1
				put_prob(t, bit, &p.mv_bits[comp][i])
				c.mv_bits[comp][i][bit] += 1
			}
			put_tree_prob(t, vp9.MV_FR_TREE[:], p.mv_fr[comp][:], fr)
			c.mv_fr[comp][fr] += 1
			c.mv_hp[comp][1] += 1
		}
		// Quarter-pixel MVs have implicit hp=1 (magnitude's low bit is zero).
	}
}

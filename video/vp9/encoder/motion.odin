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

@(private)
motion_predictors :: proc(t: ^Tile, r, c, size: int, ref_frame: u8, block: int = -1) -> (nearest, near: vp9.Mv, mode_ctx: int) #no_bounds_check {
	e := t.e
	cands: [2]vp9.Mv
	count := 0
	add :: #force_inline proc(cands: ^[2]vp9.Mv, count: ^int, mv: vp9.Mv) {
		if count^ < 2 && (count^ == 0 || mv != cands[0]) {
			cands[count^] = mv
			count^ += 1
		}
	}
	add_same :: #force_inline proc(cands: ^[2]vp9.Mv, count: ^int, m: ^Motion, ref: i8) {
		for j in 0 ..< 2 {
			if m.ref_frame[j] == ref {
				add(cands, count, m.mv[j])
				return
			}
		}
	}
	add_diff :: #force_inline proc(cands: ^[2]vp9.Mv, count: ^int, m: ^Motion, ref: i8, allow_comp: bool) {
		same := m.mv[0] == m.mv[1]
		for j in 0 ..< 2 {
			f := m.ref_frame[j]
			if f <= vp9.INTRA_FRAME || f == ref || j == 1 && same do continue
			mv := m.mv[j]
			if allow_comp && (f != vp9.LAST_FRAME) != (ref != vp9.LAST_FRAME) do mv = -mv
			add(cands, count, mv)
		}
	}
	ref := i8(ref_frame)
	counter := 0
	diff_found := false
	offsets := &vp9.MV_REF_BLOCKS[size]
	for i in 0 ..< 2 {
		y, x := r + int(offsets[i][0]), c + int(offsets[i][1])
		if y < 0 || y >= e.mi_rows || x < t.first_col || x >= t.end_col do continue
		m := &e.motion[y * e.mi_cols + x]
		diff_found = true
		counter += int(vp9.MODE_2_COUNTER[m.y_mode])
		for j in 0 ..< 2 {
			if m.ref_frame[j] == ref {
				mv := m.mv[j]
				if block >= 0 && m.sub8x8 {
					idx := int(vp9.IDX_N_COLUMN_TO_SUBBLOCK[block][offsets[i][1] == 0 ? 1 : 0])
					mv = m.sub_mvs[j][idx]
				}
				add(&cands, &count, mv)
				break
			}
		}
	}
	if count < 2 {
		for i in 2 ..< 8 {
			y, x := r + int(offsets[i][0]), c + int(offsets[i][1])
			if y < 0 || y >= e.mi_rows || x < t.first_col || x >= t.end_col do continue
			m := &e.motion[y * e.mi_cols + x]
			diff_found = true
			add_same(&cands, &count, m, ref)
		}
	}
	if count < 2 && e.use_prev_mvs {
		m := &e.prev_motion[r * e.mi_cols + c]
		add_same(&cands, &count, m, ref)
	}
	if count < 2 && diff_found {
		for i in 0 ..< 8 {
			y, x := r + int(offsets[i][0]), c + int(offsets[i][1])
			if y < 0 || y >= e.mi_rows || x < t.first_col || x >= t.end_col do continue
			m := &e.motion[y * e.mi_cols + x]
			add_diff(&cands, &count, m, ref, e.allow_comp)
		}
	}
	if count < 2 && e.use_prev_mvs {
		m := &e.prev_motion[r * e.mi_cols + c]
		add_diff(&cands, &count, m, ref, e.allow_comp)
	}
	min_r, max_r, min_c, max_c := mv_bounds(e, r, c, size)
	for i in 0 ..< 2 {
		row := clamp(int(cands[i][0]), min_r, max_r)
		col := clamp(int(cands[i][1]), min_c, max_c)
		if block < 0 && (!e.allow_hp || !use_mv_hp({i16(row), i16(col)})) {
			if row & 1 != 0 do row += row > 0 ? -1 : 1
			if col & 1 != 0 do col += col > 0 ? -1 : 1
		}
		cands[i] = {i16(row), i16(col)}
	}
	return cands[0], cands[1], int(vp9.COUNTER_TO_CONTEXT[counter])
}

@(private)
sub8x8_motion_predictors :: proc(t: ^Tile, r, c, size: int, ref_frame: u8, block: int, block_mvs: ^[4]vp9.Mv) -> (nearest, near: vp9.Mv) #no_bounds_check {
	ref0, ref1, _ := motion_predictors(t, r, c, size, ref_frame, block)
	ref_list := [2]vp9.Mv{ref0, ref1}
	candidates: [2]vp9.Mv
	n := 0
	switch {
	case block == 0:
		candidates = ref_list
		n = 2
	case block <= 2:
		candidates[0] = block_mvs[0]
		n = 1
	case:
		candidates[0] = block_mvs[2]
		n = 1
		for idx := 1; idx >= 0 && n < 2; idx -= 1 {
			if block_mvs[idx] != candidates[0] {candidates[n] = block_mvs[idx]; n += 1}
		}
	}
	for k in 0 ..< 2 {
		if n >= 2 do break
		if ref_list[k] != candidates[0] {candidates[n] = ref_list[k]; n += 1}
	}
	if n < 2 do candidates[n] = {}
	return candidates[0], candidates[1]
}

@(private)
use_mv_hp :: #force_inline proc(mv: vp9.Mv) -> bool {
	return abs(int(mv[0])) >> 3 < vp9.COMPANDED_MVREF_THRESH && abs(int(mv[1])) >> 3 < vp9.COMPANDED_MVREF_THRESH
}

// The whole bordered reference, addressed BORDER samples in: every vector the
// search admits keeps the filter footprint inside, so nothing is clamped.
@(private)
bordered_reference :: proc(e: ^Encoder, p: int, $T: typeid, ref_frame: u8 = vp9.LAST_FRAME) -> vp9.Ref_Plane(T) {
	stride := e.strides[p]
	raw := ref_frame == vp9.ALTREF_FRAME ? e.altref_storage[p] : ref_frame == vp9.GOLDEN_FRAME ? e.golden_storage[p] : e.reference_storage[p]
	storage := plane_t(raw, T)
	return {data = storage, stride = stride, last_x = stride - 1, last_y = len(storage) / stride - 1}
}

@(private)
rect_sad :: proc(w, h: int, a: []$T, a_stride: int, b: []T, b_stride: int) -> u32 #no_bounds_check {
	switch w {
	case 4:  return sad_rows(4, h, a, a_stride, b, b_stride)
	case 8:  return sad_rows(8, h, a, a_stride, b, b_stride)
	case 16: return sad_rows(16, h, a, a_stride, b, b_stride)
	case 32: return sad_rows(32, h, a, a_stride, b, b_stride)
	}
	return sad_rows(64, h, a, a_stride, b, b_stride)
}

// Sum of absolute differences of an n x n block, n = 4, 8, 16, 32 or 64.
@(private)
block_sad :: #force_inline proc(n: int, a: []$T, a_stride: int, b: []T, b_stride: int) -> u32 #no_bounds_check {
	return rect_sad(n, n, a, a_stride, b, b_stride)
}

@(private)
sad_rows :: #force_inline proc($W: int, h: int, a: []$T, a_stride: int, b: []T, b_stride: int) -> u32 #no_bounds_check {
	when T == u8 {
		// h rows of differences up to 255 fit each u16 lane: 64 * 255 < 65536.
		total: #simd[W]u16
		for row in 0 ..< h {
			x := intrinsics.unaligned_load((^#simd[W]u8)(&a[row * a_stride]))
			y := intrinsics.unaligned_load((^#simd[W]u8)(&b[row * b_stride]))
			total += (#simd[W]u16)(simd.max(x, y) - simd.min(x, y))
		}
		return simd.reduce_add_ordered((#simd[W]u32)(total))
	} else {
		L :: min(W, 8)
		total: #simd[L]u32
		for row in 0 ..< h {
			ra, rb := a[row * a_stride:], b[row * b_stride:]
			#unroll for i in 0 ..< W / L {
				col := i * L
				x := intrinsics.unaligned_load((^#simd[L]u16)(&ra[col]))
				y := intrinsics.unaligned_load((^#simd[L]u16)(&rb[col]))
				total += (#simd[L]u32)(simd.max(x, y) - simd.min(x, y))
			}
		}
		return simd.reduce_add_ordered(total)
	}
}

// Sum, minimum and maximum of the four half_px x half_px quadrant SADs of a block.
@(private)
quadrant_sad :: proc(half_px: int, a: []$T, a_stride: int, b: []T, b_stride: int) -> (total, min_s, max_s: u32) #no_bounds_check {
	s0 := block_sad(half_px, a, a_stride, b, b_stride)
	s1 := block_sad(half_px, a[half_px:], a_stride, b[half_px:], b_stride)
	s2 := block_sad(half_px, a[half_px * a_stride:], a_stride, b[half_px * b_stride:], b_stride)
	s3 := block_sad(half_px, a[half_px * a_stride + half_px:], a_stride, b[half_px * b_stride + half_px:], b_stride)
	return s0 + s1 + s2 + s3, min(min(s0, s1), min(s2, s3)), max(max(s0, s1), max(s2, s3))
}

// Precomputes the frame's inter-mode and motion-vector bit costs once
// from e.probs before tiles run, so motion search reads flat tables.
@(private)
build_mv_costs :: proc(e: ^Encoder) #no_bounds_check {
	p := &e.probs
	for ctx in 0 ..< vp9.INTER_MODE_CONTEXTS {
		for m in 0 ..< vp9.INTER_MODES {
			e.inter_mode_cost[ctx][m] = u16(code_bit_cost(INTER_MODE_CODES[m], p.inter_mode[ctx][:]))
		}
	}
	for j in 0 ..< vp9.MV_JOINTS {
		e.mv_joint_cost[j] = u16(code_bit_cost(MV_JOINT_CODES[j], p.mv_joint[:]))
	}
	for comp in 0 ..< 2 {
		s0 := bit_cost(0, p.mv_sign[comp])
		s1 := bit_cost(1, p.mv_sign[comp])
		for hp_mode in 0 ..< 2 {
			e.mv_comp_cost[comp][hp_mode][0][0] = 0
			e.mv_comp_cost[comp][hp_mode][1][0] = 0
		}
		for d_abs in 1 ..= 2 * MAX_MV {
			mag := d_abs - 1
			class := mag < 16 ? 0 : int(28 - intrinsics.count_leading_zeros(u32(mag)))
			base := code_bit_cost(MV_CLASS_CODES[class], p.mv_class[comp][:])
			fr := mag >> 1 & 3
			hp := mag & 1
			hp_cost: u32
			if class == 0 {
				bit := mag >> 3
				base += bit_cost(bit, p.mv_class0_bit[comp])
				base += code_bit_cost(MV_FR_CODES[fr], p.mv_class0_fr[comp][bit][:])
				hp_cost = bit_cost(hp, p.mv_class0_hp[comp])
			} else {
				offset := mag - (vp9.CLASS0_SIZE << uint(class + 2))
				for i in 0 ..< class do base += bit_cost(offset >> uint(i + 3) & 1, p.mv_bits[comp][i])
				base += code_bit_cost(MV_FR_CODES[fr], p.mv_fr[comp][:])
				hp_cost = bit_cost(hp, p.mv_hp[comp])
			}
			e.mv_comp_cost[comp][0][0][d_abs] = u16(s0 + base)
			e.mv_comp_cost[comp][0][1][d_abs] = u16(s1 + base)
			e.mv_comp_cost[comp][1][0][d_abs] = u16(s0 + base + hp_cost)
			e.mv_comp_cost[comp][1][1][d_abs] = u16(s1 + base + hp_cost)
		}
	}
}

@(private)
mv_bit_cost :: #force_inline proc(e: ^Encoder, mv, predictor: vp9.Mv) -> u32 #no_bounds_check {
	d0, d1 := int(mv[0]) - int(predictor[0]), int(mv[1]) - int(predictor[1])
	joint := int(d1 != 0) + 2 * int(d0 != 0)
	hp_mode := int(e.allow_hp && use_mv_hp(predictor))
	return u32(e.mv_joint_cost[joint]) + u32(e.mv_comp_cost[0][hp_mode][int(d0 < 0)][abs(d0)]) + u32(e.mv_comp_cost[1][hp_mode][int(d1 < 0)][abs(d1)])
}

@(private)
best_inter_mode :: #force_inline proc(s: ^Motion_Search($T), mv: vp9.Mv) -> (mode: int, bits_256: u32) #no_bounds_check {
	mode = vp9.NEWMV
	bits_256 = max(u32)
	if mv == s.nearest {
		mode = vp9.NEARESTMV
		bits_256 = s.mode_cost[vp9.NEARESTMV - vp9.NEARESTMV]
	}
	if mv == s.near {
		c := s.mode_cost[vp9.NEARMV - vp9.NEARESTMV]
		if c < bits_256 {mode, bits_256 = vp9.NEARMV, c}
	}
	if mv == (vp9.Mv{}) {
		c := s.mode_cost[vp9.ZEROMV - vp9.NEARESTMV]
		if c < bits_256 {mode, bits_256 = vp9.ZEROMV, c}
	}
	if bits_256 == max(u32) {
		bits_256 = s.mode_cost[vp9.NEWMV - vp9.NEARESTMV] + mv_bit_cost(s.t.e, mv, s.best_ref)
	}
	return
}

@(private)
motion_sad :: proc(t: ^Tile, r, c, size: int, mv: vp9.Mv, $T: typeid, ref_frame: u8 = vp9.LAST_FRAME, filter: int = vp9.EIGHTTAP, sub_x: int = 0, sub_y: int = 0) -> u32 #no_bounds_check {
	e := t.e
	bw, bh := int(vp9.NUM_4X4_BLOCKS_WIDE_LOOKUP[size]) * 4, int(vp9.NUM_4X4_BLOCKS_HIGH_LOOKUP[size]) * 4
	x, y := c * 8 + sub_x, r * 8 + sub_y
	source := plane_t(e.source[0], T)[y * e.source_strides[0] + x:]
	if mv[0] & 7 == 0 && mv[1] & 7 == 0 {
		at := (BORDER + y + int(mv[0]) / 8) * e.strides[0] + BORDER + x + int(mv[1]) / 8
		raw := ref_frame == vp9.ALTREF_FRAME ? e.altref_storage[0] : ref_frame == vp9.GOLDEN_FRAME ? e.golden_storage[0] : e.reference_storage[0]
		storage := plane_t(raw, T)
		return rect_sad(bw, bh, source, e.source_strides[0], storage[at:], e.strides[0])
	}
	reference := bordered_reference(e, 0, T, ref_frame)
	pred := ([^]T)(&t.pred)[:64 * 64]
	block := vp9.Inter_Block(T){&reference, (BORDER + x) * 16 + int(mv[1]) * 2, (BORDER + y) * 16 + int(mv[0]) * 2, 16, 16, bw, bh, filter, e.bit_depth, &pred[0], bw}
	vp9.predict_inter_block(&block)
	return rect_sad(bw, bh, source, e.source_strides[0], pred, bw)
}

@(private)
compound_sad :: proc(t: ^Tile, r, c, size: int, mv0, mv1: vp9.Mv, $T: typeid, filter: int = vp9.EIGHTTAP, ref1_frame: u8 = vp9.GOLDEN_FRAME) -> u32 #no_bounds_check {
	e := t.e
	bw, bh := int(vp9.NUM_4X4_BLOCKS_WIDE_LOOKUP[size]) * 4, int(vp9.NUM_4X4_BLOCKS_HIGH_LOOKUP[size]) * 4
	x, y := c * 8, r * 8
	stride := e.strides[0]
	dst := plane_t(e.planes[0], T)[y * stride + x:]
	ref0 := bordered_reference(e, 0, T, vp9.LAST_FRAME)
	b0 := vp9.Inter_Block(T){&ref0, (BORDER + x) * 16 + int(mv0[1]) * 2, (BORDER + y) * 16 + int(mv0[0]) * 2, 16, 16, bw, bh, filter, e.bit_depth, raw_data(dst), stride}
	vp9.predict_inter_block(&b0)
	ref1 := bordered_reference(e, 0, T, ref1_frame)
	pred := ([^]T)(&t.pred)[:64 * 64]
	b1 := vp9.Inter_Block(T){&ref1, (BORDER + x) * 16 + int(mv1[1]) * 2, (BORDER + y) * 16 + int(mv1[0]) * 2, 16, 16, bw, bh, filter, e.bit_depth, &pred[0], bw}
	vp9.predict_inter_block(&b1)
	vp9.average_into(dst, stride, pred, bw, bw, bh)
	return rect_sad(bw, bh, plane_t(e.source[0], T)[y * e.source_strides[0] + x:], e.source_strides[0], dst, stride)
}

@(private)
Motion_Search :: struct($T: typeid) {
	t: ^Tile,
	r, c, size, bw, bh, x0, y0, sub_x, sub_y: int,
	ref_frame: u8,
	source, ref_data: []T,
	s_stride, r_stride: int,
	min_y, max_y, min_x, max_x: int,
	nearest, near, best_ref: vp9.Mv,
	mode_cost: [vp9.INTER_MODES]u32,
	rate_q: i64,
	best: vp9.Mv,
	best_mode: int,
	best_sad: u32,
	best_cost: i64,
}

@(private)
eval_motion_int :: #force_inline proc(s: ^Motion_Search($T), mv: vp9.Mv) -> bool #no_bounds_check {
	at := (BORDER + s.y0 + int(mv[0]) / 8) * s.r_stride + BORDER + s.x0 + int(mv[1]) / 8
	sad := rect_sad(s.bw, s.bh, s.source, s.s_stride, s.ref_data[at:], s.r_stride)
	if i64(sad) >= s.best_cost do return false
	mode, bits := best_inter_mode(s, mv)
	cost := i64(sad) + ((s.rate_q * i64(bits)) >> 12)
	if cost < s.best_cost {
		s.best, s.best_mode, s.best_sad, s.best_cost = mv, mode, sad, cost
		return true
	}
	return false
}

@(private)
eval_motion_subpel :: #force_inline proc(s: ^Motion_Search($T), mv: vp9.Mv) -> i64 #no_bounds_check {
	sad := motion_sad(s.t, s.r, s.c, s.size, mv, T, s.ref_frame, vp9.EIGHTTAP, s.sub_x, s.sub_y)
	mode, bits := best_inter_mode(s, mv)
	cost := i64(sad) + ((s.rate_q * i64(bits)) >> 12)
	if cost < s.best_cost {
		s.best, s.best_mode, s.best_sad, s.best_cost = mv, mode, sad, cost
	}
	return cost
}

@(private)
search_motion :: proc(t: ^Tile, r, c, size: int, nearest, near: vp9.Mv, mode_ctx: int, $T: typeid, ref_frame: u8 = vp9.LAST_FRAME, sub_x: int = 0, sub_y: int = 0, best_ref: vp9.Mv = {max(i16), 0}) -> (best: vp9.Mv, best_mode: int, best_sad: u32) #no_bounds_check {
	e := t.e
	sub8x8 := size < vp9.BLOCK_8X8
	radius := sub8x8 ? 8 : e.config.search_range * 8
	bw, bh := int(vp9.NUM_4X4_BLOCKS_WIDE_LOOKUP[size]) * 4, int(vp9.NUM_4X4_BLOCKS_HIGH_LOOKUP[size]) * 4
	x0, y0 := c * 8 + sub_x, r * 8 + sub_y
	min_y, max_y, min_x, max_x := mv_bounds(e, r, c, size)
	mc := e.inter_mode_cost[mode_ctx]
	ref_pred := best_ref[0] == max(i16) ? nearest : best_ref
	raw_ref := ref_frame == vp9.ALTREF_FRAME ? e.altref_storage[0] : ref_frame == vp9.GOLDEN_FRAME ? e.golden_storage[0] : e.reference_storage[0]
	s := Motion_Search(T){
		t = t, r = r, c = c, size = size, bw = bw, bh = bh, x0 = x0, y0 = y0, sub_x = sub_x, sub_y = sub_y,
		ref_frame = ref_frame,
		source = plane_t(e.source[0], T)[y0 * e.source_strides[0] + x0:],
		ref_data = plane_t(raw_ref, T),
		s_stride = e.source_strides[0], r_stride = e.strides[0],
		min_y = min_y, max_y = max_y, min_x = min_x, max_x = max_x,
		nearest = nearest, near = near, best_ref = ref_pred,
		mode_cost = {u32(mc[0]), u32(mc[1]), u32(mc[2]), u32(mc[3])},
		rate_q = i64(max(16, int(vp9.ac_q(e.bit_depth, e.q_idx)))),
		best_mode = vp9.ZEROMV, best_sad = max(u32), best_cost = max(i64),
	}

	prev_mv := e.use_prev_mvs ? e.prev_motion[r * e.mi_cols + c].mv[0] : vp9.Mv{}
	raw_seeds := [5]vp9.Mv{{}, nearest, near, prev_mv, t.last_mv}
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
			if !sub8x8 && ref_frame == vp9.LAST_FRAME do t.last_mv = s.best
			return s.best, s.best_mode, 0
		}
	}

	step := 8
	for step * 2 <= radius do step *= 2
	for ; step >= 8; step /= 2 {
		last_dir := -1
		for _ in 0 ..< 4 {
			before := s.best
			best_dir := -1
			for offset, dir in ([4][2]int{{-1,0},{1,0},{0,-1},{0,1}}) {
				if dir == (last_dir ~ 1) do continue
				y, x := int(before[0]) + offset[0] * step, int(before[1]) + offset[1] * step
				if y < min_y || y > max_y || x < min_x || x > max_x do continue
				if eval_motion_int(&s, {i16(y), i16(x)}) do best_dir = dir
			}
			if best_dir < 0 do break
			last_dir = best_dir
		}
	}
	if !sub8x8 && ref_frame == vp9.LAST_FRAME do t.last_mv = s.best
	if s.best_sad == 0 do return s.best, s.best_mode, 0

	if (nearest[0] & 7 != 0 || nearest[1] & 7 != 0) && int(nearest[0]) >= min_y && int(nearest[0]) <= max_y && int(nearest[1]) >= min_x && int(nearest[1]) <= max_x {
		eval_motion_subpel(&s, nearest)
		if s.best_sad == 0 {
			if !sub8x8 && ref_frame == vp9.LAST_FRAME do t.last_mv = s.best
			return s.best, s.best_mode, 0
		}
	}
	if (near[0] & 7 != 0 || near[1] & 7 != 0) && near != nearest && int(near[0]) >= min_y && int(near[0]) <= max_y && int(near[1]) >= min_x && int(near[1]) <= max_x {
		eval_motion_subpel(&s, near)
		if s.best_sad == 0 {
			if !sub8x8 && ref_frame == vp9.LAST_FRAME do t.last_mv = s.best
			return s.best, s.best_mode, 0
		}
	}
	if e.lossless do return s.best, s.best_mode, s.best_sad

	use_hp := e.allow_hp && use_mv_hp(ref_pred)
	steps := [3]int{4, 2, 1}
	for sub_step in steps[:use_hp ? 3 : 2] {
		before := s.best
		if before[0] & 1 != 0 || before[1] & 1 != 0 do continue
		cy, cx := int(before[0]), int(before[1])
		if sub_step == 1 && (abs(cy) >= 63 || abs(cx) >= 63) do continue
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
	if !sub8x8 && ref_frame == vp9.LAST_FRAME do t.last_mv = s.best
	return s.best, s.best_mode, s.best_sad
}

@(private)
plane_sse :: proc(w, h: int, a: []$T, a_stride: int, b: []T, b_stride: int) -> i64 #no_bounds_check {
	UT8 :: #simd[8]T
	I8 :: #simd[8]i32
	UT4 :: #simd[4]T
	I4 :: #simd[4]i32
	if w >= 8 {
		when T == u8 {
			acc: I8 = 0
			for y in 0 ..< h {
				ra := a[y * a_stride:]
				rb := b[y * b_stride:]
				for x := 0; x < w; x += 8 {
					d := I8(intrinsics.unaligned_load((^UT8)(&ra[x]))) - I8(intrinsics.unaligned_load((^UT8)(&rb[x])))
					acc += d * d
				}
			}
			return i64(simd.reduce_add_ordered(acc))
		} else {
			total := i64(0)
			for y in 0 ..< h {
				ra := a[y * a_stride:]
				rb := b[y * b_stride:]
				row_acc: I8 = 0
				for x := 0; x < w; x += 8 {
					d := I8(intrinsics.unaligned_load((^UT8)(&ra[x]))) - I8(intrinsics.unaligned_load((^UT8)(&rb[x])))
					row_acc += d * d
				}
				total += i64(simd.reduce_add_ordered(row_acc))
			}
			return total
		}
	}
	when T == u8 {
		acc4: I4 = 0
		for y in 0 ..< h {
			d := I4(intrinsics.unaligned_load((^UT4)(&a[y * a_stride]))) - I4(intrinsics.unaligned_load((^UT4)(&b[y * b_stride])))
			acc4 += d * d
		}
		return i64(simd.reduce_add_ordered(acc4))
	} else {
		total := i64(0)
		for y in 0 ..< h {
			d := I4(intrinsics.unaligned_load((^UT4)(&a[y * a_stride]))) - I4(intrinsics.unaligned_load((^UT4)(&b[y * b_stride])))
			total += i64(simd.reduce_add_ordered(d * d))
		}
		return total
	}
}

@(private)
put_mv :: proc(t: ^Tile, mv, predictor: vp9.Mv) {
	p := &t.e.probs
	c := &t.counts
	use_hp := t.e.allow_hp && use_mv_hp(predictor)
	diff := [2]int{int(mv[0]) - int(predictor[0]), int(mv[1]) - int(predictor[1])}
	joint := int(diff[1] != 0) + 2 * int(diff[0] != 0)
	put_tree_prob(t, MV_JOINT_CODES[joint], p.mv_joint[:])
	count_inc(t, &c.mv_joint[joint])
	for comp in 0 ..< 2 {
		v := diff[comp]
		if v == 0 do continue
		sign := int(v < 0)
		put_prob(t, sign, &p.mv_sign[comp])
		count_inc(t, &c.mv_sign[comp][sign])
		mag := abs(v) - 1
		class := mag < 16 ? 0 : int(28 - intrinsics.count_leading_zeros(u32(mag)))
		put_tree_prob(t, MV_CLASS_CODES[class], p.mv_class[comp][:])
		count_inc(t, &c.mv_class[comp][class])
		fr := mag >> 1 & 3
		hp := mag & 1
		if class == 0 {
			bit := mag >> 3
			put_prob(t, bit, &p.mv_class0_bit[comp])
			count_inc(t, &c.mv_class0_bit[comp][bit])
			put_tree_prob(t, MV_FR_CODES[fr], p.mv_class0_fr[comp][bit][:])
			count_inc(t, &c.mv_class0_fr[comp][bit][fr])
			if use_hp do put_prob(t, hp, &p.mv_class0_hp[comp])
			count_inc(t, &c.mv_class0_hp[comp][hp])
		} else {
			offset := mag - (vp9.CLASS0_SIZE << uint(class + 2))
			for i in 0 ..< class {
				bit := offset >> uint(i + 3) & 1
				put_prob(t, bit, &p.mv_bits[comp][i])
				count_inc(t, &c.mv_bits[comp][i][bit])
			}
			put_tree_prob(t, MV_FR_CODES[fr], p.mv_fr[comp][:])
			count_inc(t, &c.mv_fr[comp][fr])
			if use_hp do put_prob(t, hp, &p.mv_hp[comp])
			count_inc(t, &c.mv_hp[comp][hp])
		}
	}
}

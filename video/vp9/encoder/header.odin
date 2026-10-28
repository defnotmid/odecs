package vp9_encoder

import vp9 ".."

// Bit cost of a boolean decision in 1/256-bit units (prob_bits(p) for bit 0,
// prob_bits(256 - p) for bit 1), tabulated once for all probabilities 1..255.
@(private)
BIT_COSTS: [2][256]u16

@(private, init)
init_bit_costs :: proc "contextless" () {
	for p in 1 ..< 256 {
		x := u32(p) << 8
		res := u32(0)
		for x <= 32768 {x <<= 1; res += 256}
		for b in 0 ..< 8 {
			x = u32((u64(x) * u64(x)) >> 16)
			if x <= 32768 {x <<= 1; res += 128 >> uint(b)}
		}
		BIT_COSTS[0][p] = u16(res)
		BIT_COSTS[1][256 - p] = u16(res)
	}
}

@(private)
prob_bits :: #force_inline proc "contextless" (p: u8) -> u32 #no_bounds_check {
	return u32(BIT_COSTS[0][p])
}

@(private)
bit_cost :: #force_inline proc "contextless" (bit: int, p: u8) -> u32 #no_bounds_check {
	return u32(BIT_COSTS[bit][p])
}

@(private)
code_bit_cost :: #force_inline proc "contextless" (code: Tree_Code, probs: []u8) -> u32 #no_bounds_check {
	cost: u32
	for i in 0 ..< int(code.count) {
		bit := int(code.bits >> uint(i) & 1)
		cost += u32(BIT_COSTS[bit][probs[code.nodes[i]]])
	}
	return cost
}

@(private)
branch_cost :: #force_inline proc(ct0, ct1: u32, p: u8) -> u64 {
	return u64(ct0) * u64(prob_bits(p)) + u64(ct1) * u64(prob_bits(u8(256 - int(p))))
}

@(private)
target_prob :: proc(old_p: u8, ct0, ct1: u32) -> u8 {
	den := ct0 + ct1
	if den == 0 do return old_p
	prob := clamp((ct0 * 256 + (den >> 1)) / den, 1, 255)
	count := min(den, 24)
	factor := 192 * count / 24
	return u8(clamp((u32(old_p) * (256 - factor) + prob * factor + 128) >> 8, 1, 255))
}

@(private)
recenter_nonneg :: #force_inline proc(t, m: int) -> int {
	if t > 2 * m do return t
	if t >= m do return 2 * (t - m)
	return 2 * (m - t) - 1
}

@(private)
diff_update_delta :: proc(old_p, new_p: u8) -> int {
	m, t := int(old_p) - 1, int(new_p) - 1
	v := (m << 1) <= 255 ? recenter_nonneg(t, m) : recenter_nonneg(254 - t, 254 - m)
	for d in 0 ..< 255 do if int(vp9.INV_MAP_TABLE[d]) == v do return d
	return 0
}

@(private)
term_subexp_bits :: #force_inline proc(delta: int) -> u64 {
	if delta < 16 do return 5
	if delta < 32 do return 6
	if delta < 64 do return 8
	if delta < 129 do return 10
	return 11
}

@(private)
encode_term_subexp :: proc(b: ^Bool_Writer, delta: int) {
	if delta < 16 {
		put_literal(b, 0, 1)
		put_literal(b, delta, 4)
	} else if delta < 32 {
		put_literal(b, 2, 2)
		put_literal(b, delta - 16, 4)
	} else if delta < 64 {
		put_literal(b, 6, 3)
		put_literal(b, delta - 32, 5)
	} else if delta < 129 {
		put_literal(b, 7, 3)
		put_literal(b, delta - 64, 7)
	} else {
		x := delta + 1
		put_literal(b, 7, 3)
		put_literal(b, x >> 1, 7)
		put_literal(b, x & 1, 1)
	}
}

@(private)
diff_update_savings :: proc(old_p: u8, ct: [2]u32) -> (new_p: u8, delta: int, savings: i64) {
	new_p = target_prob(old_p, ct[0], ct[1])
	if new_p == old_p do return old_p, 0, 0
	delta = diff_update_delta(old_p, new_p)
	old_cost := i64(branch_cost(ct[0], ct[1], old_p)) + 6
	new_cost := i64(branch_cost(ct[0], ct[1], new_p)) + i64(6 + term_subexp_bits(delta)) * 256
	if new_cost < old_cost do return new_p, delta, old_cost - new_cost
	return old_p, 0, 0
}

@(private)
emit_diff_update :: proc(b: ^Bool_Writer, prob: ^u8, ct: [2]u32) {
	new_p, delta, savings := diff_update_savings(prob^, ct)
	if savings > 0 {
		put_bool(b, 1, 252)
		encode_term_subexp(b, delta)
		prob^ = new_p
	} else {
		put_bool(b, 0, 252)
	}
}

@(private)
emit_mv_update :: proc(b: ^Bool_Writer, prob: ^u8, ct: [2]u32) {
	old_p := prob^
	new_p := target_prob(old_p, ct[0], ct[1]) | 1
	if new_p != old_p {
		old_cost := branch_cost(ct[0], ct[1], old_p) + 6
		new_cost := branch_cost(ct[0], ct[1], new_p) + 13 * 256
		if new_cost < old_cost {
			put_bool(b, 1, 252)
			put_literal(b, int(new_p >> 1), 7)
			prob^ = new_p
			return
		}
	}
	put_bool(b, 0, 252)
}

@(private)
tree_branch_counts :: proc(tree: []i8, i: int, counts: []u32, out: [][2]u32) -> u32 {
	s := int(tree[i])
	left := s <= 0 ? counts[-s] : tree_branch_counts(tree, s, counts, out)
	r := int(tree[i + 1])
	right := r <= 0 ? counts[-r] : tree_branch_counts(tree, r, counts, out)
	out[i >> 1] = {left, right}
	return left + right
}

@(private)
emit_tree_diff_updates :: proc(b: ^Bool_Writer, tree: []i8, probs: []u8, counts: []u32) {
	branches: [16][2]u32
	tree_branch_counts(tree, 0, counts, branches[:len(probs)])
	for j in 0 ..< len(probs) do emit_diff_update(b, &probs[j], branches[j])
}

@(private)
emit_tree_mv_updates :: proc(b: ^Bool_Writer, tree: []i8, probs: []u8, counts: []u32) {
	branches: [16][2]u32
	tree_branch_counts(tree, 0, counts, branches[:len(probs)])
	for j in 0 ..< len(probs) do emit_mv_update(b, &probs[j], branches[j])
}

@(private)
update_segmentation_probs :: proc(e: ^Encoder) {
	seg := &e.segmentation
	if !seg.enabled || !seg.update_map do return
	branches: [7][2]u32
	tree_branch_counts(vp9.SEGMENT_TREE[:], 0, e.counts.seg_tree[:], branches[:])
	for i in 0 ..< 7 {
		ct0, ct1 := branches[i][0], branches[i][1]
		den := ct0 + ct1
		p := den > 0 ? u8(clamp((ct0 * 256 + (den >> 1)) / den, 1, 255)) : 255
		seg.tree_probs[i] = p != 255 && branch_cost(ct0, ct1, p) + 8 * 256 < branch_cost(ct0, ct1, 255) ? p : 255
	}
	if !e.keyframe && seg.temporal_update {
		for i in 0 ..< 3 {
			ct0, ct1 := e.counts.seg_pred[i][0], e.counts.seg_pred[i][1]
			den := ct0 + ct1
			p := den > 0 ? u8(clamp((ct0 * 256 + (den >> 1)) / den, 1, 255)) : 255
			seg.pred_probs[i] = p != 255 && branch_cost(ct0, ct1, p) + 8 * 256 < branch_cost(ct0, ct1, 255) ? p : 255
		}
	}
}

@(private)
build_compressed_header :: proc(e: ^Encoder) {
	b := &e.header
	p := &e.probs
	c := &e.counts
	start_bool(b)
	if !e.lossless {
		put_literal(b, vp9.ALLOW_32X32, 2)
		put_literal(b, 1, 1) // TX_MODE_SELECT
		for i in 0 ..< vp9.TX_SIZE_CONTEXTS do emit_tree_diff_updates(b, vp9.TX_SIZE_8_TREE[:], p.tx[vp9.TX_8X8][i][:1], c.tx_size[vp9.TX_8X8][i][:])
		for i in 0 ..< vp9.TX_SIZE_CONTEXTS do emit_tree_diff_updates(b, vp9.TX_SIZE_16_TREE[:], p.tx[vp9.TX_16X16][i][:2], c.tx_size[vp9.TX_16X16][i][:])
		for i in 0 ..< vp9.TX_SIZE_CONTEXTS do emit_tree_diff_updates(b, vp9.TX_SIZE_32_TREE[:], p.tx[vp9.TX_32X32][i][:3], c.tx_size[vp9.TX_32X32][i][:])
	}
	count := e.lossless ? 1 : 4
	for tx in 0 ..< count {
		total_savings := i64(0)
		for i in 0 ..< 2 do for j in 0 ..< 2 do for k in 0 ..< 6 {
			for l in 0 ..< (k == 0 ? 3 : 6) {
				tok := c.token[tx][i][j][k][l]
				cts := [3][2]u32{c.more_coefs[tx][i][j][k][l], {tok[0], tok[1] + tok[2]}, {tok[1], tok[2]}}
				for m in 0 ..< 3 {
					_, _, s := diff_update_savings(p.coef[tx][i][j][k][l][m], cts[m])
					total_savings += s
				}
			}
		}
		if total_savings > 396 * 6 {
			put_literal(b, 1, 1)
			for i in 0 ..< 2 do for j in 0 ..< 2 do for k in 0 ..< 6 {
				for l in 0 ..< (k == 0 ? 3 : 6) {
					tok := c.token[tx][i][j][k][l]
					cts := [3][2]u32{c.more_coefs[tx][i][j][k][l], {tok[0], tok[1] + tok[2]}, {tok[1], tok[2]}}
					for m in 0 ..< 3 do emit_diff_update(b, &p.coef[tx][i][j][k][l][m], cts[m])
				}
			}
		} else {
			put_literal(b, 0, 1)
		}
	}
	for i in 0 ..< vp9.SKIP_CONTEXTS do emit_diff_update(b, &p.skip[i], c.skip[i])
	if !e.keyframe {
		for i in 0 ..< vp9.INTER_MODE_CONTEXTS do emit_tree_diff_updates(b, vp9.INTER_MODE_TREE[:], p.inter_mode[i][:], c.inter_mode[i][:])
		if !e.config.ultrafast && !e.lossless {
			for i in 0 ..< vp9.INTERP_FILTER_CONTEXTS do emit_tree_diff_updates(b, vp9.INTERP_FILTER_TREE[:], p.interp_filter[i][:], c.interp_filter[i][:])
		}
		for i in 0 ..< vp9.IS_INTER_CONTEXTS do emit_diff_update(b, &p.is_inter[i], c.is_inter[i])
		if e.allow_comp {
			put_literal(b, 1, 1) // not SINGLE_REFERENCE
			put_literal(b, 1, 1) // REFERENCE_MODE_SELECT
			for i in 0 ..< vp9.COMP_MODE_CONTEXTS do emit_diff_update(b, &p.comp_mode[i], c.comp_mode[i])
		}
		for i in 0 ..< vp9.REF_CONTEXTS do for j in 0 ..< 2 do emit_diff_update(b, &p.single_ref[i][j], c.single_ref[i][j])
		if e.allow_comp {
			for i in 0 ..< vp9.REF_CONTEXTS do emit_diff_update(b, &p.comp_ref[i], c.comp_ref[i])
		}
		for i in 0 ..< vp9.BLOCK_SIZE_GROUPS do emit_tree_diff_updates(b, vp9.INTRA_MODE_TREE[:], p.y_mode[i][:], c.intra_mode[i][:])
		for i in 0 ..< vp9.PARTITION_CONTEXTS do emit_tree_diff_updates(b, vp9.PARTITION_TREE[:], p.partition[i][:], c.partition[i][:])
		emit_tree_mv_updates(b, vp9.MV_JOINT_TREE[:], p.mv_joint[:], c.mv_joint[:])
		for i in 0 ..< 2 {
			emit_mv_update(b, &p.mv_sign[i], c.mv_sign[i])
			emit_tree_mv_updates(b, vp9.MV_CLASS_TREE[:], p.mv_class[i][:], c.mv_class[i][:])
			emit_mv_update(b, &p.mv_class0_bit[i], c.mv_class0_bit[i])
			for j in 0 ..< vp9.MV_OFFSET_BITS do emit_mv_update(b, &p.mv_bits[i][j], c.mv_bits[i][j])
		}
		for i in 0 ..< 2 {
			for j in 0 ..< vp9.CLASS0_SIZE do emit_tree_mv_updates(b, vp9.MV_FR_TREE[:], p.mv_class0_fr[i][j][:], c.mv_class0_fr[i][j][:])
			emit_tree_mv_updates(b, vp9.MV_FR_TREE[:], p.mv_fr[i][:], c.mv_fr[i][:])
		}
		if e.allow_hp {
			for i in 0 ..< 2 {
				emit_mv_update(b, &p.mv_class0_hp[i], c.mv_class0_hp[i])
				emit_mv_update(b, &p.mv_hp[i], c.mv_hp[i])
			}
		}
	}
	finish_bool(b)
}

@(private)
Raw_Writer :: struct {data: ^[dynamic]u8, bits: int, failed: bool}

@(private)
raw_bits :: proc(w: ^Raw_Writer, value, bits: int) {
	for i := bits - 1; i >= 0; i -= 1 {
		if w.bits & 7 == 0 {
			if _, err := append(w.data, 0); err != nil {w.failed = true; return}
		}
		w.data^[len(w.data^) - 1] |= u8(value >> uint(i) & 1) << uint(7 - (w.bits & 7))
		w.bits += 1
	}
}

@(private)
emit_delta_q :: proc(w: ^Raw_Writer, dq: int) {
	if dq == 0 {
		raw_bits(w, 0, 1)
	} else {
		raw_bits(w, 1, 1)
		raw_bits(w, abs(dq), 4)
		raw_bits(w, int(dq < 0), 1)
	}
}

@(private)
emit_seg_prob :: proc(w: ^Raw_Writer, p: u8) {
	if p != 255 {
		raw_bits(w, 1, 1)
		raw_bits(w, int(p), 8)
	} else {
		raw_bits(w, 0, 1)
	}
}

@(private)
emit_profile :: proc(w: ^Raw_Writer, profile: int) {
	raw_bits(w, profile & 1, 1)
	raw_bits(w, (profile >> 1) & 1, 1)
	if profile == 3 do raw_bits(w, 0, 1)
}

@(private)
build_uncompressed_header :: proc(e: ^Encoder) -> bool {
	w := Raw_Writer{data = &e.packet}
	raw_bits(&w, 2, 2)
	emit_profile(&w, e.profile)
	raw_bits(&w, 0, 1) // show_existing_frame
	raw_bits(&w, int(!e.keyframe), 1)
	raw_bits(&w, int(e.show_frame), 1); raw_bits(&w, 0, 1) // show_frame, error_resilient=0 (enables backward adaptation)
	if e.keyframe {
		raw_bits(&w, 0x498342, 24)
		if e.profile >= 2 do raw_bits(&w, int(e.bit_depth == 12), 1)
		raw_bits(&w, 2, 3); raw_bits(&w, 0, 1) // BT.709 limited
		if e.profile == 1 || e.profile == 3 {
			raw_bits(&w, e.ss_x, 1)
			raw_bits(&w, e.ss_y, 1)
			raw_bits(&w, 0, 1)
		}
		raw_bits(&w, e.config.width - 1, 16); raw_bits(&w, e.config.height - 1, 16)
		raw_bits(&w, 0, 1) // same render size
	} else {
		if !e.show_frame do raw_bits(&w, 0, 1) // intra_only = 0
		raw_bits(&w, 0, 2) // reset_frame_context = 0
		raw_bits(&w, e.refresh_frame_flags, 8)
		raw_bits(&w, 0, 3); raw_bits(&w, 0, 1) // LAST = slot 0
		raw_bits(&w, 1, 3); raw_bits(&w, int(e.allow_comp), 1) // GOLDEN = slot 1
		raw_bits(&w, e.has_altref ? 2 : 1, 3); raw_bits(&w, int(e.allow_comp), 1) // ALTREF = slot 2 or 1
		raw_bits(&w, 1, 1) // size from LAST
		raw_bits(&w, 0, 1) // same render size
		raw_bits(&w, int(e.allow_hp), 1)
		if !e.config.ultrafast && !e.lossless {
			raw_bits(&w, 1, 1) // SWITCHABLE
		} else {
			raw_bits(&w, 0, 1); raw_bits(&w, 1, 2) // fixed EIGHTTAP
		}
	}
	raw_bits(&w, 1, 1); raw_bits(&w, 0, 1) // refresh_frame_context=1, frame_parallel=0
	raw_bits(&w, e.frame_context_idx, 2) // context index
	raw_bits(&w, e.base_filter_level, 6); raw_bits(&w, 0, 3)
	if !e.config.ultrafast {
		raw_bits(&w, 1, 1); raw_bits(&w, 0, 1) // delta_enabled=1, delta_update=0
	} else {
		raw_bits(&w, 0, 1)
	}
	raw_bits(&w, e.q_idx, 8)
	emit_delta_q(&w, e.config.delta_q_y_dc)
	emit_delta_q(&w, e.config.delta_q_uv_dc)
	emit_delta_q(&w, e.config.delta_q_uv_ac)
	seg := &e.segmentation
	raw_bits(&w, int(seg.enabled), 1)
	if seg.enabled {
		raw_bits(&w, int(seg.update_map), 1)
		if seg.update_map {
			for i in 0 ..< 7 do emit_seg_prob(&w, seg.tree_probs[i])
			temp := !e.keyframe && seg.temporal_update
			raw_bits(&w, int(temp), 1)
			if temp {
				for i in 0 ..< 3 do emit_seg_prob(&w, seg.pred_probs[i])
			}
		}
		raw_bits(&w, int(e.seg_update_data), 1)
		if e.seg_update_data {
			raw_bits(&w, int(seg.abs_or_delta_update), 1)
			for i in 0 ..< vp9.MAX_SEGMENTS do for j in 0 ..< 4 {
				enabled := seg.feature_enabled[i][j]
				raw_bits(&w, int(enabled), 1)
				if enabled {
					val := int(seg.feature_data[i][j])
					raw_bits(&w, abs(val), int(vp9.SEGMENTATION_FEATURE_BITS[j]))
					if vp9.SEGMENTATION_FEATURE_SIGNED[j] == 1 {
						raw_bits(&w, int(val < 0), 1)
					}
				}
			}
		}
	}
	minimum, maximum := tile_limits(e.sb_cols)
	for _ in minimum ..< e.config.tile_cols_log2 do raw_bits(&w, 1, 1)
	if e.config.tile_cols_log2 < maximum do raw_bits(&w, 0, 1)
	raw_bits(&w, 0, 1) // one tile row
	raw_bits(&w, len(e.header.data), 16)
	return !w.failed
}

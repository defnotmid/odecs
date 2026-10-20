package vp9

// Backward probability adaptation (section 8.4): blends each probability of
// the frame context loaded before this frame with the frequencies observed
// while decoding it.

@(private)
merge_prob :: #force_inline proc(pre: u8, ct0, ct1, count_sat, max_update: u32) -> u8 {
	den := ct0 + ct1
	prob := den == 0 ? 128 : clamp((ct0 * 256 + den >> 1) / den, 1, 255)
	count := min(den, count_sat)
	factor := max_update * count / count_sat
	return u8((u32(pre) * (256 - factor) + prob * factor + 128) >> 8)
}

// merge_probs over a decode tree: leaves are -value, inner nodes the index
// of their children; probs[i >> 1] belongs to node i.
@(private)
merge_probs :: proc(tree: []i8, i: int, probs: []u8, counts: []u32, count_sat, max_update: u32) -> u32 {
	s := int(tree[i])
	left := s <= 0 ? counts[-s] : merge_probs(tree, s, probs, counts, count_sat, max_update)
	r := int(tree[i + 1])
	right := r <= 0 ? counts[-r] : merge_probs(tree, r, probs, counts, count_sat, max_update)
	probs[i >> 1] = merge_prob(probs[i >> 1], left, right, count_sat, max_update)
	return left + right
}

@(private)
adapt_probs :: #force_inline proc(tree: []i8, probs: []u8, counts: []u32) {
	merge_probs(tree, 0, probs, counts, COUNT_SAT, MAX_UPDATE_FACTOR)
}

@(private)
adapt_prob :: #force_inline proc(prob: ^u8, counts: [2]u32) {
	prob^ = merge_prob(prob^, counts[0], counts[1], COUNT_SAT, MAX_UPDATE_FACTOR)
}

// Section 8.4.3. update_factor is 112, or 128 for the first inter frame
// after a key frame.
adapt_coef_probs :: proc(p: ^Probabilities, c: ^Counts, frame_is_intra, last_was_key: bool) {
	update: u32 = !frame_is_intra && last_was_key ? 128 : 112
	small_token_tree := SMALL_TOKEN_TREE
	binary_tree := BINARY_TREE
	for t in 0 ..< TX_SIZES do for i in 0 ..< 2 do for j in 0 ..< 2 do for k in 0 ..< COEF_BANDS {
		for l in 0 ..< (k == 0 ? 3 : 6) {
			probs := p.coef[t][i][j][k][l][:]
			merge_probs(small_token_tree[:], 2, probs, c.token[t][i][j][k][l][:], 24, update)
			merge_probs(binary_tree[:], 0, probs, c.more_coefs[t][i][j][k][l][:], 24, update)
		}
	}
}

// Section 8.4.4.
adapt_noncoef_probs :: proc(p: ^Probabilities, c: ^Counts, interp_switchable, tx_select, allow_high_precision_mv: bool) {
	inter_mode_tree, intra_mode_tree, partition_tree := INTER_MODE_TREE, INTRA_MODE_TREE, PARTITION_TREE
	interp_filter_tree, mv_joint_tree, mv_class_tree, mv_fr_tree := INTERP_FILTER_TREE, MV_JOINT_TREE, MV_CLASS_TREE, MV_FR_TREE
	tx8, tx16, tx32 := TX_SIZE_8_TREE, TX_SIZE_16_TREE, TX_SIZE_32_TREE
	for i in 0 ..< IS_INTER_CONTEXTS do adapt_prob(&p.is_inter[i], c.is_inter[i])
	for i in 0 ..< COMP_MODE_CONTEXTS do adapt_prob(&p.comp_mode[i], c.comp_mode[i])
	for i in 0 ..< REF_CONTEXTS do adapt_prob(&p.comp_ref[i], c.comp_ref[i])
	for i in 0 ..< REF_CONTEXTS do for j in 0 ..< 2 do adapt_prob(&p.single_ref[i][j], c.single_ref[i][j])
	for i in 0 ..< INTER_MODE_CONTEXTS do adapt_probs(inter_mode_tree[:], p.inter_mode[i][:], c.inter_mode[i][:])
	for i in 0 ..< BLOCK_SIZE_GROUPS do adapt_probs(intra_mode_tree[:], p.y_mode[i][:], c.intra_mode[i][:])
	for i in 0 ..< INTRA_MODES do adapt_probs(intra_mode_tree[:], p.uv_mode[i][:], c.uv_mode[i][:])
	for i in 0 ..< PARTITION_CONTEXTS do adapt_probs(partition_tree[:], p.partition[i][:], c.partition[i][:])
	for i in 0 ..< SKIP_CONTEXTS do adapt_prob(&p.skip[i], c.skip[i])
	if interp_switchable {
		for i in 0 ..< INTERP_FILTER_CONTEXTS do adapt_probs(interp_filter_tree[:], p.interp_filter[i][:], c.interp_filter[i][:])
	}
	if tx_select {
		for i in 0 ..< TX_SIZE_CONTEXTS {
			adapt_probs(tx8[:], p.tx[TX_8X8][i][:], c.tx_size[TX_8X8][i][:])
			adapt_probs(tx16[:], p.tx[TX_16X16][i][:], c.tx_size[TX_16X16][i][:])
			adapt_probs(tx32[:], p.tx[TX_32X32][i][:], c.tx_size[TX_32X32][i][:])
		}
	}
	adapt_probs(mv_joint_tree[:], p.mv_joint[:], c.mv_joint[:])
	for i in 0 ..< 2 {
		adapt_prob(&p.mv_sign[i], c.mv_sign[i])
		adapt_probs(mv_class_tree[:], p.mv_class[i][:], c.mv_class[i][:])
		adapt_prob(&p.mv_class0_bit[i], c.mv_class0_bit[i])
		for j in 0 ..< MV_OFFSET_BITS do adapt_prob(&p.mv_bits[i][j], c.mv_bits[i][j])
		for j in 0 ..< CLASS0_SIZE do adapt_probs(mv_fr_tree[:], p.mv_class0_fr[i][j][:], c.mv_class0_fr[i][j][:])
		adapt_probs(mv_fr_tree[:], p.mv_fr[i][:], c.mv_fr[i][:])
		if allow_high_precision_mv {
			adapt_prob(&p.mv_class0_hp[i], c.mv_class0_hp[i])
			adapt_prob(&p.mv_hp[i], c.mv_hp[i])
		}
	}
}

// Adds one tile's counts into the frame's.
add_counts :: proc(dst, src: ^Counts) {
	d := ([^]u32)(dst)[:size_of(Counts) / size_of(u32)]
	s := ([^]u32)(src)[:size_of(Counts) / size_of(u32)]
	for v, i in s do d[i] += v
}

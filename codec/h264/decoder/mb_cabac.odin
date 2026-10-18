package h264_decoder

import h264 ".."

// ---------------------------------------------------------------------------
// CABAC syntax elements (9.3.2, 9.3.3.1): binarization and context selection
// ---------------------------------------------------------------------------

@(private = "file")
decision :: #force_inline proc(decoder: ^Slice_Decoder, ctx_idx: int) -> u32 {
	return cabac_decode_decision(decoder.engine, ctx_idx)
}

@(private = "file")
bypass :: #force_inline proc(decoder: ^Slice_Decoder) -> u32 {
	return cabac_decode_bypass(decoder.engine)
}

cabac_read_mb_skip :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> bool {
	inc := 0
	for idx in ([2]int{decoder.left_index, decoder.top_index}) {
		if idx >= 0 && !decoder.macroblocks[idx].is_skip do inc += 1
	}
	base := decoder.header.slice_type == .B ? 24 : 11
	return decision(decoder, base + inc) == 1
}

// Macroblock type of an I slice, or the intra suffix in P/B slices (Table 9-36); `base` is the context of bin 0
@(private = "file")
read_intra_mb_type :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index: int,
	base: int,
	in_i_slice: bool,
) -> u32 {
	if in_i_slice {
		inc := 0
		for idx in ([2]int{decoder.left_index, decoder.top_index}) {
			if idx >= 0 && decoder.macroblocks[idx].type != .I_4x4 && decoder.macroblocks[idx].type != .I_8x8 do inc += 1
		}
		if decision(decoder, base + inc) == 0 do return 0
	} else if decision(decoder, base) == 0 {
		return 0
	}
	if cabac_decode_terminate(decoder.engine, decoder.reader) == 1 do return 25 // I_PCM
	// I_16x16: bins for luma cbp, chroma cbp and prediction mode
	offset := in_i_slice ? 3 : 1
	luma := decision(decoder, base + offset)
	chroma: u32 = 0
	if decision(decoder, base + offset + 1) == 1 {
		chroma = 1 + decision(decoder, base + offset + (in_i_slice ? 2 : 1))
	}
	mode_ctx := base + offset + (in_i_slice ? 3 : 2)
	mode := decision(decoder, mode_ctx) << 1
	mode |= decision(decoder, mode_ctx + (in_i_slice ? 1 : 0))
	return 1 + mode + chroma * 4 + luma * 12
}

cabac_read_mb_type :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> u32 {
	switch decoder.header.slice_type {
	case .I, .SI:
		return read_intra_mb_type(decoder, macroblock_index, 3, true)
	case .P, .SP:
		if decision(decoder, 14) == 1 do return 5 + read_intra_mb_type(decoder, macroblock_index, 17, false)
		if decision(decoder, 15) == 0 do return decision(decoder, 16) == 0 ? 0 : 3
		return decision(decoder, 17) == 0 ? 2 : 1
	case .B:
		inc := 0
		for idx in ([2]int{decoder.left_index, decoder.top_index}) {
			if idx < 0 do continue
			neighbour := &decoder.macroblocks[idx]
			if neighbour.type != .B_Skip && neighbour.type != .B_Direct_16x16 do inc += 1
		}
		if decision(decoder, 27 + inc) == 0 do return 0
		if decision(decoder, 27 + 3) == 0 do return 1 + decision(decoder, 27 + 5)
		bits := decision(decoder, 27 + 4) << 3
		bits |= decision(decoder, 27 + 5) << 2
		bits |= decision(decoder, 27 + 5) << 1
		bits |= decision(decoder, 27 + 5)
		switch {
		case bits < 8:
			return bits + 3
		case bits == 13:
			return 23 + read_intra_mb_type(decoder, macroblock_index, 32, false)
		case bits == 14:
			return 11
		case bits == 15:
			return 22
		}
		return (bits << 1 | decision(decoder, 27 + 5)) - 4
	}
	return 0
}

cabac_read_sub_mb_type :: proc(decoder: ^Slice_Decoder) -> u32 {
	if decoder.header.slice_type != .B {
		if decision(decoder, 21) == 1 do return 0
		if decision(decoder, 22) == 0 do return 1
		return decision(decoder, 23) == 1 ? 2 : 3
	}
	if decision(decoder, 36) == 0 do return 0
	if decision(decoder, 37) == 0 do return 1 + decision(decoder, 39)
	sub: u32 = 3
	if decision(decoder, 38) == 1 {
		if decision(decoder, 39) == 1 do return 11 + decision(decoder, 39)
		sub += 4
	}
	sub += decision(decoder, 39) << 1
	return sub + decision(decoder, 39)
}

cabac_read_transform_8x8_flag :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> bool {
	inc := 0
	for idx in ([2]int{decoder.left_index, decoder.top_index}) {
		if idx >= 0 && decoder.macroblocks[idx].uses_8x8_transform do inc += 1
	}
	return decision(decoder, 399 + inc) == 1
}

// Neighbouring 4x4 block of `block` in the given direction: macroblock index and block index, or -1
@(private = "file")
neighbour_block :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index, block: int,
	left: bool,
) -> (
	idx, sub: int,
) {
	bx, by := h264.subblock_to_xy(block)
	if left {
		if bx > 0 do return macroblock_index, h264.xy_to_subblock(bx - 1, by)
		return decoder.left_index, h264.xy_to_subblock(3, by)
	}
	if by > 0 do return macroblock_index, h264.xy_to_subblock(bx, by - 1)
	return decoder.top_index, h264.xy_to_subblock(bx, 3)
}

cabac_read_ref_idx :: proc(decoder: ^Slice_Decoder, macroblock_index, list, block: int) -> i32 {
	inc := 0
	for left, i in ([2]bool{true, false}) {
		idx, sub := neighbour_block(decoder, macroblock_index, block, left)
		if idx < 0 do continue
		neighbour := &decoder.macroblocks[idx]
		if neighbour.is_intra || neighbour.is_skip do continue
		if neighbour.type == .B_Direct_16x16 || (neighbour.type == .B_8x8 && neighbour.subpartition_types[sub / 4] == .Direct_8x8) do continue
		if neighbour.reference_indices[list][sub / 4] > 0 do inc += i == 0 ? 1 : 2
	}
	value: i32 = 0
	ctx_idx := 54 + inc
	for decision(decoder, ctx_idx) == 1 {
		value += 1
		ctx_idx = value == 1 ? 54 + 4 : 54 + 5
		if value > 32 do break
	}
	return value
}

// Both components of one mvd (9.3.3.1.1.7): the neighbours' absolute mvd
// sums are gathered once, then both components decode on a local cursor.
cabac_read_mvd_pair :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index, list, block: int,
) -> (
	mvd: [2]i32,
) {
	sum: [2]int
	for left in ([2]bool{true, false}) {
		idx, sub := neighbour_block(decoder, macroblock_index, block, left)
		if idx < 0 do continue
		neighbour := &decoder.macroblocks[idx]
		if neighbour.is_intra || neighbour.is_skip || neighbour.prediction_directions[sub / 4] & (list == 0 ? h264.Prediction_Direction.List_0 : .List_1) == .None do continue
		difference := neighbour.motion_differences[list][sub]
		sum += {int(difference[0]), int(difference[1])}
	}
	c := decoder.engine.cursor
	ctx := &decoder.engine.ctx
	for comp in 0 ..< 2 {
		base := comp == 0 ? 40 : 47
		inc := sum[comp] < 3 ? 0 : sum[comp] <= 32 ? 1 : 2
		if cabac_decision(&c, &ctx[base + inc]) == 0 do continue
		// UEG3 prefix: truncated unary with cMax 9, contexts 3, 4, 5, 6, 6, ...
		value: u32 = 1
		ctx_idx := base + 3
		for value < 9 && cabac_decision(&c, &ctx[ctx_idx]) == 1 {
			value += 1
			if ctx_idx < base + 6 do ctx_idx += 1
		}
		if value == 9 do value += cabac_exp_golomb(&c, 3)
		mvd[comp] = cabac_bypass(&c) == 1 ? -i32(value) : i32(value)
	}
	decoder.engine.cursor = c
	return
}

cabac_read_intra_pred_mode :: proc(decoder: ^Slice_Decoder) -> (prev: bool, rem: int) {
	if decision(decoder, 68) == 1 do return true, 0
	rem = int(decision(decoder, 69))
	rem |= int(decision(decoder, 69)) << 1
	rem |= int(decision(decoder, 69)) << 2
	return false, rem
}

cabac_read_intra_chroma_mode :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> u32 {
	inc := 0
	for idx in ([2]int{decoder.left_index, decoder.top_index}) {
		if idx < 0 do continue
		neighbour := &decoder.macroblocks[idx]
		if neighbour.is_intra && neighbour.type != .I_PCM && neighbour.chroma_prediction_mode != .DC do inc += 1
	}
	if decision(decoder, 64 + inc) == 0 do return 0
	if decision(decoder, 67) == 0 do return 1
	return decision(decoder, 67) == 0 ? 2 : 3
}

cabac_read_coded_block_pattern :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> u32 {
	left, top := decoder.left_index, decoder.top_index
	luma: u32 = 0
	for block8 in 0 ..< 4 {
		// condTermFlag is 0 for an unavailable, I_PCM, or coded neighbouring 8x8 block
		cond :: proc(decoder: ^Slice_Decoder, idx: int, bit: uint, own: u32, inside: bool) -> int {
			if inside do return own >> bit & 1 == 0 ? 1 : 0
			if idx < 0 do return 0
			neighbour := &decoder.macroblocks[idx]
			if neighbour.type == .I_PCM do return 0
			if neighbour.is_skip do return 1
			return neighbour.luma_coded_block_mask >> bit & 1 == 0 ? 1 : 0
		}
		bx, by := block8 & 1, block8 >> 1
		a :=
			bx > 0 ? cond(decoder, 0, uint(block8 - 1), luma, true) : cond(decoder, left, uint(block8 + 1), luma, false)
		b :=
			by > 0 ? cond(decoder, 0, uint(block8 - 2), luma, true) : cond(decoder, top, uint(block8 + 2), luma, false)
		luma |= decision(decoder, 73 + a + 2 * b) << uint(block8)
	}
	chroma_cond :: proc(decoder: ^Slice_Decoder, idx: int, want_two: bool) -> int {
		if idx < 0 do return 0
		neighbour := &decoder.macroblocks[idx]
		if neighbour.type == .I_PCM do return 1
		if neighbour.is_skip do return 0
		return(
			(want_two ? neighbour.chroma_residual_mode == .DC_And_AC : neighbour.chroma_residual_mode != .None) ? 1 : 0 \
		)
	}
	chroma: u32 = 0
	if decision(
		   decoder,
		   77 + chroma_cond(decoder, left, false) + 2 * chroma_cond(decoder, top, false),
	   ) ==
	   1 {
		chroma =
			1 +
			decision(
				decoder,
				77 + 4 + chroma_cond(decoder, left, true) + 2 * chroma_cond(decoder, top, true),
			)
	}
	return luma | chroma << 4
}

cabac_read_qp_delta :: proc(decoder: ^Slice_Decoder, prev_delta_nz: bool) -> i32 {
	if decision(decoder, 60 + (prev_delta_nz ? 1 : 0)) == 0 do return 0
	value: i32 = 1
	ctx_idx := 62
	for decision(decoder, ctx_idx) == 1 {
		value += 1
		ctx_idx = 63
		if value > 52 do break
	}
	return value & 1 == 1 ? (value + 1) >> 1 : -(value >> 1)
}

// ctxBlockCatOffset per block category (Table 9-40)
@(private = "file")
coded_block_flag_cat_offset: [6]int = {0, 4, 8, 12, 16, 0}
@(private = "file")
significant_cat_offset: [6]int = {0, 15, 29, 44, 47, 0}
@(private = "file")
abs_level_cat_offset: [6]int = {0, 10, 20, 30, 39, 0}

// Significance map contexts of 8x8 blocks (Table 9-43, frame coded)
@(private)
sig_coeff_ctx_8x8: [63]u8 = {
	0,
	1,
	2,
	3,
	4,
	5,
	5,
	4,
	4,
	3,
	3,
	4,
	4,
	4,
	5,
	5,
	4,
	4,
	4,
	4,
	3,
	3,
	6,
	7,
	7,
	7,
	8,
	9,
	10,
	9,
	8,
	7,
	7,
	6,
	11,
	12,
	13,
	11,
	6,
	7,
	8,
	9,
	14,
	10,
	9,
	8,
	6,
	11,
	12,
	13,
	11,
	6,
	9,
	14,
	10,
	9,
	11,
	12,
	13,
	11,
	14,
	10,
	12,
}
@(private)
last_coeff_ctx_8x8: [63]u8 = {
	0,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	3,
	3,
	3,
	3,
	3,
	3,
	3,
	3,
	4,
	4,
	4,
	4,
	4,
	4,
	4,
	4,
	5,
	5,
	5,
	5,
	6,
	6,
	6,
	6,
	7,
	7,
	7,
	7,
	8,
	8,
	8,
}

// coded_block_flag condTermFlag of a neighbouring macroblock for a block category (9.3.3.1.1.9)
@(private = "file")
coded_block_cond :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index, idx: int,
	$cat: Block_Cat,
	sub: int,
	plane: int,
) -> int {
	if idx < 0 do return decoder.macroblocks[macroblock_index].is_intra ? 1 : 0
	neighbour := &decoder.macroblocks[idx]
	if neighbour.type == .I_PCM do return 1
	if neighbour.is_skip do return 0
	when cat == .Luma_DC {
		return neighbour.type == .I_16x16 && neighbour.has_dc_coefficients[0] ? 1 : 0
	} else when cat == .Chroma_DC {
		return(
			neighbour.chroma_residual_mode != .None && neighbour.has_dc_coefficients[1 + plane] ? 1 : 0 \
		)
	} else when cat == .Chroma_AC {
		return(
			neighbour.chroma_residual_mode == .DC_And_AC && neighbour.nonzero_coefficient_counts[h264.chroma_count_index(plane, sub)] > 0 ? 1 : 0 \
		)
	} else {
		if neighbour.luma_coded_block_mask >> uint(sub / 4) & 1 == 0 do return 0
		if neighbour.uses_8x8_transform do return 1 // inferred for 4:2:0
		return neighbour.nonzero_coefficient_counts[sub] > 0 ? 1 : 0
	}
}

// residual_block_cabac (7.3.5.3.3): levels in scan order, returns the number of non-zero levels
cabac_read_residual_block :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index: int,
	$cat: Block_Cat,
	block: int,
	levels: []$L,
	max_coeffs: int,
) -> int {
	// coded_block_flag (not sent for 8x8 blocks in 4:2:0)
	when cat != .Luma_8x8 {
		// The DC categories read only neighbours.
		when cat != .Luma_DC && cat != .Chroma_DC {macroblock := &decoder.macroblocks[macroblock_index]}
		inc: int
		when cat == .Luma_DC || cat == .Chroma_DC {
			plane := cat == .Chroma_DC ? block : 0
			left, top := decoder.left_index, decoder.top_index
			inc =
				coded_block_cond(decoder, macroblock_index, left, cat, 0, plane) +
				2 * coded_block_cond(decoder, macroblock_index, top, cat, 0, plane)
		} else when cat == .Chroma_AC {
			// Blocks in raster order, two per row: 2 rows, 4 in 4:2:2.
			blocks := decoder.chroma_422 ? 8 : 4
			plane, index := block / blocks, block % blocks
			bx, by := index & 1, index >> 1
			counts := &macroblock.nonzero_coefficient_counts
			a :=
				bx > 0 ? (counts[h264.chroma_count_index(plane, by * 2)] > 0 ? 1 : 0) : coded_block_cond(decoder, macroblock_index, decoder.left_index, cat, by * 2 + 1, plane)
			b :=
				by > 0 ? (counts[h264.chroma_count_index(plane, index - 2)] > 0 ? 1 : 0) : coded_block_cond(decoder, macroblock_index, decoder.top_index, cat, blocks - 2 + bx, plane)
			inc = a + 2 * b
		} else {
			for left, i in ([2]bool{true, false}) {
				idx, sub := neighbour_block(decoder, macroblock_index, block, left)
				cond: int
				if idx == macroblock_index {
					cond =
						macroblock.luma_coded_block_mask >> uint(sub / 4) & 1 != 0 && macroblock.nonzero_coefficient_counts[sub] > 0 ? 1 : 0
				} else {
					cond = coded_block_cond(decoder, macroblock_index, idx, cat, sub, 0)
				}
				inc += i == 0 ? cond : 2 * cond
			}
		}
		if decision(decoder, 85 + coded_block_flag_cat_offset[cat] + inc) == 0 do return 0
	}
	return cabac_residual_levels(decoder.engine, cat, levels, max_coeffs)
}

// The significance map and levels of one coded block (7.3.5.3.3, 9.3.3.1.3),
// specialized per ctxBlockCat. Significant scan positions are recorded in one
// dense list, which the level pass reads back from its highest frequency. The
// arithmetic cursor is a local value for the whole block.
@(private)
cabac_residual_levels :: proc(
	engine: ^Cabac_Engine,
	$cat: Block_Cat,
	levels: []$L,
	max_coeffs: int,
) -> int #no_bounds_check {
	when cat == .Luma_8x8 {
		SIG :: 402
		LAST :: 417
		ABS :: 426
	} else {
		SIG := 105 + significant_cat_offset[cat]
		LAST := 166 + significant_cat_offset[cat]
		ABS := 227 + abs_level_cat_offset[cat]
	}
	// coeff_abs_level_minus1's greater-than-one contexts stop one lower for
	// chroma DC (9.3.3.1.3).
	GT1_MAX :: 3 when cat == .Chroma_DC else 4

	c := engine.cursor
	ctx := &engine.ctx

	// Chroma DC contexts step every NumC8x8 levels: 1, or 2 for 4:2:2's 8 levels (9.3.3.1.3).
	when cat == .Chroma_DC {dc_step := uint(max_coeffs >> 3)}
	positions: [64]u8
	count := 0
	final := true
	for i in 0 ..< max_coeffs - 1 {
		when cat == .Luma_8x8 {
			sig_ctx, last_ctx := int(sig_coeff_ctx_8x8[i]), int(last_coeff_ctx_8x8[i])
		} else when cat == .Chroma_DC {
			sig_ctx := min(i >> dc_step, 2)
			last_ctx := sig_ctx
		} else {
			sig_ctx, last_ctx := i, i
		}
		if cabac_decision(&c, &ctx[SIG + sig_ctx]) == 0 do continue
		positions[count] = u8(i)
		count += 1
		if cabac_decision(&c, &ctx[LAST + last_ctx]) == 1 {
			final = false
			break
		}
	}
	// Without a last flag the final scan position is significant.
	if final {
		positions[count] = u8(max_coeffs - 1)
		count += 1
	}

	num_gt1, num_eq1 := 0, 0
	for k := count - 1; k >= 0; k -= 1 {
		inc := num_gt1 != 0 ? 0 : min(4, 1 + num_eq1)
		value: i32 = 1
		if cabac_decision(&c, &ctx[ABS + inc]) == 1 {
			inc = 5 + min(GT1_MAX, num_gt1)
			value = 2
			for value < 15 && cabac_decision(&c, &ctx[ABS + inc]) == 1 do value += 1
			if value == 15 do value += i32(cabac_exp_golomb(&c, 0))
			num_gt1 += 1
		} else {
			num_eq1 += 1
		}
		if cabac_bypass(&c) == 1 do value = -value
		when L == i16 {levels[positions[k]] = i16(clamp(value, -32768, 32767))} else {levels[positions[k]] = value}
	}

	engine.cursor = c
	return count
}

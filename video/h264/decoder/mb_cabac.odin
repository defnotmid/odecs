package h264_decoder

import h264 ".."
import common "../../../common"

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
	inc := h264.cabac_mb_skip_ctx_inc(decoder.macroblocks, decoder.left_index, decoder.top_index)
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
		inc := h264.cabac_intra_mb_type_ctx_inc(decoder.macroblocks, decoder.left_index, decoder.top_index)
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
		inc := h264.cabac_b_mb_type_ctx_inc(decoder.macroblocks, decoder.left_index, decoder.top_index)
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
	inc := h264.cabac_transform_8x8_ctx_inc(decoder.macroblocks, decoder.left_index, decoder.top_index)
	return decision(decoder, 399 + inc) == 1
}

cabac_read_ref_idx :: proc(decoder: ^Slice_Decoder, macroblock_index, list, block: int) -> i32 {
	inc := h264.cabac_ref_idx_ctx_inc(decoder.macroblocks, macroblock_index, decoder.left_index, decoder.top_index, list, block)
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
	inc := h264.cabac_mvd_ctx_inc(decoder.macroblocks, macroblock_index, decoder.left_index, decoder.top_index, list, block)
	c := decoder.engine.cursor
	ctx := &decoder.engine.ctx
	for comp in 0 ..< 2 {
		base := comp == 0 ? 40 : 47
		if common.cabac_decision(&c, &ctx[base + inc[comp]]) == 0 do continue
		// UEG3 prefix: truncated unary with cMax 9, contexts 3, 4, 5, 6, 6, ...
		value: u32 = 1
		ctx_idx := base + 3
		for value < 9 && common.cabac_decision(&c, &ctx[ctx_idx]) == 1 {
			value += 1
			if ctx_idx < base + 6 do ctx_idx += 1
		}
		if value == 9 do value += cabac_exp_golomb(&c, 3)
		mvd[comp] = common.cabac_bypass(&c) == 1 ? -i32(value) : i32(value)
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
	inc := h264.cabac_intra_chroma_mode_ctx_inc(decoder.macroblocks, decoder.left_index, decoder.top_index)
	if decision(decoder, 64 + inc) == 0 do return 0
	if decision(decoder, 67) == 0 do return 1
	return decision(decoder, 67) == 0 ? 2 : 3
}

cabac_read_coded_block_pattern :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> u32 {
	left, top := decoder.left_index, decoder.top_index
	luma: u32 = 0
	for block8 in 0 ..< 4 {
		inc := h264.cabac_cbp_luma_ctx_inc(decoder.macroblocks, left, top, block8, luma)
		luma |= decision(decoder, 73 + inc) << uint(block8)
	}
	chroma: u32 = 0
	if !decoder.monochrome && !decoder.chroma_444 {
		if decision(decoder, 77 + h264.cabac_cbp_chroma_ctx_inc(decoder.macroblocks, left, top, false)) == 1 {
			chroma = 1 + decision(decoder, 77 + 4 + h264.cabac_cbp_chroma_ctx_inc(decoder.macroblocks, left, top, true))
		}
	}
	return luma | chroma << 4
}

cabac_read_qp_delta :: proc(decoder: ^Slice_Decoder, prev_delta_nz: bool) -> i32 {
	if decision(decoder, 60 + (prev_delta_nz ? 1 : 0)) == 0 do return 0
	// mb_qp_delta lies in -(26 + QpBdOffsetY / 2) .. 25 + QpBdOffsetY / 2 (7.4.5),
	// so its unary code is at most 52 + QpBdOffsetY bins; the bound only stops
	// corrupt data.
	longest := i32(52 + 6 * (decoder.bit_depth - 8))
	value: i32 = 1
	ctx_idx := 62
	for decision(decoder, ctx_idx) == 1 {
		value += 1
		ctx_idx = 63
		if value > longest do break
	}
	return value & 1 == 1 ? (value + 1) >> 1 : -(value >> 1)
}

// residual_block_cabac (7.3.5.3.3): levels in scan order, returns the number of non-zero levels
cabac_read_residual_block :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index: int,
	$cat: h264.Block_Cat,
	block: int,
	levels: []$L,
	max_coeffs: int,
	plane_444 := 0,
) -> int {
	plane_offset := plane_444 * h264.CABAC_PLANE_STRIDE
	// coded_block_flag (not sent for 8x8 blocks unless ChromaArrayType == 3)
	when cat == .Luma_8x8 {
		if decoder.chroma_444 {
			ctx_idx := h264.cabac_coded_block_ctx_idx(
				decoder.macroblocks,
				macroblock_index,
				decoder.left_index,
				decoder.top_index,
				cat,
				block,
				decoder.chroma_422,
				decoder.chroma_444,
				plane_444,
			)
			if decision(decoder, ctx_idx) == 0 do return 0
		}
	} else {
		ctx_idx := h264.cabac_coded_block_ctx_idx(
			decoder.macroblocks,
			macroblock_index,
			decoder.left_index,
			decoder.top_index,
			cat,
			block,
			decoder.chroma_422,
			decoder.chroma_444,
			plane_444,
		)
		if decision(decoder, ctx_idx) == 0 do return 0
	}
	return cabac_residual_levels(decoder.engine, cat, levels, max_coeffs, plane_offset)
}

// The significance map and levels of one coded block (7.3.5.3.3, 9.3.3.1.3),
// specialized per ctxBlockCat. Significant scan positions are recorded in one
// dense list, which the level pass reads back from its highest frequency. The
// arithmetic cursor is a local value for the whole block.
@(private)
cabac_residual_levels :: proc(
	engine: ^Cabac_Engine,
	$cat: h264.Block_Cat,
	levels: []$L,
	max_coeffs: int,
	plane_offset := 0,
) -> int #no_bounds_check {
	when cat == .Luma_8x8 {
		SIG := plane_offset + 402
		LAST := plane_offset + 417
		ABS := plane_offset + 426
	} else {
		SIG := plane_offset + 105 + h264.significant_cat_offset[cat]
		LAST := plane_offset + 166 + h264.significant_cat_offset[cat]
		ABS := plane_offset + 227 + h264.abs_level_cat_offset[cat]
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
			sig_ctx, last_ctx := int(h264.sig_coeff_ctx_8x8[i]), int(h264.last_coeff_ctx_8x8[i])
		} else when cat == .Chroma_DC {
			sig_ctx := min(i >> dc_step, 2)
			last_ctx := sig_ctx
		} else {
			sig_ctx, last_ctx := i, i
		}
		if common.cabac_decision(&c, &ctx[SIG + sig_ctx]) == 0 do continue
		positions[count] = u8(i)
		count += 1
		if common.cabac_decision(&c, &ctx[LAST + last_ctx]) == 1 {
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
		if common.cabac_decision(&c, &ctx[ABS + inc]) == 1 {
			inc = 5 + min(GT1_MAX, num_gt1)
			value = 2
			for value < 15 && common.cabac_decision(&c, &ctx[ABS + inc]) == 1 do value += 1
			if value == 15 do value += i32(cabac_exp_golomb(&c, 0))
			num_gt1 += 1
		} else {
			num_eq1 += 1
		}
		if common.cabac_bypass(&c) == 1 do value = -value
		when L == i16 {levels[positions[k]] = i16(clamp(value, -32768, 32767))} else {levels[positions[k]] = value}
	}

	engine.cursor = c
	return count
}

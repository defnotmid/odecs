package h264_decoder

import h264 ".."

col_block :: proc(decoder: ^Slice_Decoder, block: int) -> int {
	if !decoder.sequence_parameters.infer_direct_8x8_motion do return block
	corner := [4]int{0, 5, 10, 15}
	return corner[block / 4]
}

derive_direct :: proc(decoder: ^Slice_Decoder, macroblock_index: int, mask: u8) {
	macroblock := &decoder.macroblocks[macroblock_index]
	state := decoder.state
	col_pic := state.ref_count[1] > 0 ? state.ref_list[1][0] : nil
	col: ^Reference_Motion
	if col_pic != nil && !col_pic.non_existing do col = &col_pic.motion[macroblock_index]

	if decoder.header.direct_spatial_mv_pred_flag {
		// 8.4.1.2.2: reference indices from the 16x16 neighbours, then per-block motion
		refs: [2]i8 = {-1, -1}
		mvp: [2][2]i16
		for list in 0 ..< 2 {
			a, b, c := h264.partition_neighbours(&decoder.grid, macroblock_index, list, 0, 4)
			min_positive :: proc(x, y: i8) -> i8 {return x >= 0 && y >= 0 ? min(x, y) : max(x, y)}
			refs[list] = min_positive(a.ref, min_positive(b.ref, c.ref))
		}
		direct_zero := refs[0] < 0 && refs[1] < 0
		if direct_zero do refs = {0, 0}
		for list in 0 ..< 2 do if refs[list] >= 0 && !direct_zero do mvp[list] = h264.predict_motion_vector(&decoder.grid, macroblock_index, list, 0, 4, 4, refs[list])
		col_short := col_pic != nil && col_pic.is_short_ref
		for block8 in 0 ..< 4 {
			if mask & (1 << uint(block8)) == 0 do continue
			macroblock.prediction_directions[block8] =
				(refs[0] >= 0 ? h264.Prediction_Direction.List_0 : h264.Prediction_Direction.None) |
				(refs[1] >= 0 ? h264.Prediction_Direction.List_1 : h264.Prediction_Direction.None)
			for list in 0 ..< 2 do macroblock.reference_indices[list][block8] = refs[list]
			for k in 0 ..< 4 {
				block := block8 * 4 + k
				col_zero := false
				if col_short && col != nil && !col.is_intra && !direct_zero {
					cb := col_block(decoder, block)
					col_list :=
						col.prediction_directions[cb / 4] & h264.Prediction_Direction.List_0 != .None ? 0 : 1
					mv := col.motion_vectors[col_list][cb]
					col_zero =
						col.reference_indices[col_list][cb / 4] == 0 &&
						mv[0] >= -1 &&
						mv[0] <= 1 &&
						mv[1] >= -1 &&
						mv[1] <= 1
				}
				for list in 0 ..< 2 {
					macroblock.motion_vectors[list][block] =
						refs[list] == 0 && col_zero ? {0, 0} : mvp[list]
					if refs[list] < 0 do macroblock.motion_vectors[list][block] = {0, 0}
				}
			}
		}
		return
	}

	// 8.4.1.2.3 temporal
	for block8 in 0 ..< 4 {
		if mask & (1 << uint(block8)) == 0 do continue
		macroblock.prediction_directions[block8] = h264.Prediction_Direction.Bidirectional
		macroblock.reference_indices[1][block8] = 0
		macroblock.reference_indices[0][block8] = 0
		for k in 0 ..< 4 {
			block := block8 * 4 + k
			cb := col_block(decoder, block)
			mv_col: [2]i16
			ref_idx0: i32 = 0
			if col != nil && !col.is_intra {
				col_list :=
					col.prediction_directions[cb / 4] & h264.Prediction_Direction.List_0 != .None ? 0 : 1
				mv_col = col.motion_vectors[col_list][cb]
				ref_pic_col := col.reference_picture_ids[col_list][cb / 4]
				ref_idx0 = 0
				for i in 0 ..< state.ref_count[0] {
					if pic := state.ref_list[0][i];
					   pic != nil && pic.pic_id == ref_pic_col {ref_idx0 = i32(i); break}
				}
			}
			if k == 0 do macroblock.reference_indices[0][block8] = i8(ref_idx0)
			mv0, mv1 := mv_col, [2]i16{0, 0}
			if pic0 := state.ref_list[0][ref_idx0];
			   pic0 != nil && col_pic != nil && !pic0.is_long_ref {
				tb := clamp(state.curr.poc - pic0.poc, -128, 127)
				td := clamp(col_pic.poc - pic0.poc, -128, 127)
				if td != 0 {
					tx := (16384 + abs(td / 2)) / td
					dist_scale := clamp((tb * tx + 32) >> 6, -1024, 1023)
					mv0 = {
						i16((dist_scale * i32(mv_col[0]) + 128) >> 8),
						i16((dist_scale * i32(mv_col[1]) + 128) >> 8),
					}
					mv1 = mv0 - mv_col
				}
			}
			macroblock.motion_vectors[0][block] = mv0
			macroblock.motion_vectors[1][block] = mv1
		}
	}
}

// ---------------------------------------------------------------------------
// Luma and chroma motion compensation interpolation (8.4.2.2)
// ---------------------------------------------------------------------------

// Six-tap half-sample filter of N samples starting at `p`, taps `step` apart

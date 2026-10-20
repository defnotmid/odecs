package h264_decoder

import h264 ".."

import "base:intrinsics"
import "core:simd"

Weight :: struct {
	w0, w1, o0, o1, log2_denom: i32,
}

// Weights of a partition per plane (0: luma, 1: Cb, 2: Cr) for explicit or implicit weighting; nil when default
partition_weights :: proc(
	decoder: ^Slice_Decoder,
	ref: [2]i8,
	dir: h264.Prediction_Direction,
) -> (
	weights: [3]Weight,
	weighted: bool,
) {
	picture_parameters := decoder.picture_parameters
	header := decoder.header
	explicit :=
		header.slice_type == .B ? picture_parameters.weighted_bipred_idc == 1 : picture_parameters.weighted_pred_flag
	implicit :=
		header.slice_type == .B &&
		picture_parameters.weighted_bipred_idc == 2 &&
		dir == h264.Prediction_Direction.Bidirectional
	if !explicit && !implicit do return weights, false
	if implicit {
		// 8.4.2.3.1 implicit: weights from POC distances
		w0, w1: i32 = 32, 32
		pic0, pic1 := decoder.state.ref_list[0][ref[0]], decoder.state.ref_list[1][ref[1]]
		if pic0 != nil && pic1 != nil && !pic0.is_long_ref && !pic1.is_long_ref {
			tb := clamp(decoder.state.curr.poc - pic0.poc, -128, 127)
			td := clamp(pic1.poc - pic0.poc, -128, 127)
			if td != 0 {
				tx := (16384 + abs(td / 2)) / td
				dist_scale := clamp((tb * tx + 32) >> 6, -1024, 1023)
				if dist_scale >> 2 >= -64 && dist_scale >> 2 <= 128 {
					w1 = dist_scale >> 2
					w0 = 64 - w1
				}
			}
		}
		for p in 0 ..< 3 do weights[p] = {w0, w1, 0, 0, 5}
		return weights, true
	}
	// Offsets are in 8-bit units, scaled to the bit depth (8-291 to 8-297).
	table := &header.weights
	r0, r1 := max(int(ref[0]), 0), max(int(ref[1]), 0)
	scale := uint(decoder.bit_depth - 8)
	weights[0] = {
		table.luma_weight[0][r0],
		table.luma_weight[1][r1],
		table.luma_offset[0][r0] << scale,
		table.luma_offset[1][r1] << scale,
		i32(table.luma_log2_denom),
	}
	for p in 0 ..< 2 {
		weights[1 + p] = {
			table.chroma_weight[0][r0][p],
			table.chroma_weight[1][r1][p],
			table.chroma_offset[0][r0][p] << scale,
			table.chroma_offset[1][r1][p] << scale,
			i32(table.chroma_log2_denom),
		}
	}
	return weights, true
}

// Combine N samples of the list predictions into the picture (8.4.2.3)
combine_lanes :: #force_inline proc(
	$N: int,
	dst, src0, src1: [^]$T,
	dir: h264.Prediction_Direction,
	weight: Weight,
	weighted: bool,
	pixel_max: i32,
) #no_bounds_check {
	W :: #simd[N]i32
	switch {
	case dir == h264.Prediction_Direction.Bidirectional && weighted:
		v := simd.add(
			simd.mul((W)(h264.load_lanes(N, src0)), (W)(weight.w0)),
			simd.mul((W)(h264.load_lanes(N, src1)), (W)(weight.w1)),
		)
		v = simd.shr(
			simd.add(v, (W)(i32(1) << uint(weight.log2_denom))),
			(#simd[N]u32)(u32(weight.log2_denom + 1)),
		)
		v = simd.add(v, (W)((weight.o0 + weight.o1 + 1) >> 1))
		intrinsics.unaligned_store((^#simd[N]T)(dst), (#simd[N]T)(simd.clamp(v, 0, W(pixel_max))))
	case dir == h264.Prediction_Direction.Bidirectional:
		h264.store_lanes(dst, h264.average_lanes(h264.load_lanes(N, src0), h264.load_lanes(N, src1)))
	case weighted:
		src := dir == h264.Prediction_Direction.List_0 ? src0 : src1
		w, o :=
			dir == h264.Prediction_Direction.List_0 ? weight.w0 : weight.w1,
			dir == h264.Prediction_Direction.List_0 ? weight.o0 : weight.o1
		v := simd.mul((W)(h264.load_lanes(N, src)), (W)(w))
		if weight.log2_denom >= 1 do v = simd.shr(simd.add(v, (W)(i32(1) << uint(weight.log2_denom - 1))), (#simd[N]u32)(u32(weight.log2_denom)))
		intrinsics.unaligned_store((^#simd[N]T)(dst), (#simd[N]T)(simd.clamp(simd.add(v, (W)(o)), 0, W(pixel_max))))
	case:
		src := dir == h264.Prediction_Direction.List_0 ? src0 : src1
		intrinsics.unaligned_store((^#simd[N]T)(dst), intrinsics.unaligned_load((^#simd[N]T)(src)))
	}
}

write_prediction :: proc(
	dst: [^]$T,
	dst_stride: int,
	src0, src1: [^]T,
	src_stride, width, height: int,
	dir: h264.Prediction_Direction,
	weight: Weight,
	weighted: bool,
	pixel_max: i32,
) #no_bounds_check {
	for y in 0 ..< height {
		d, s0, s1 := &dst[y * dst_stride], &src0[y * src_stride], &src1[y * src_stride]
		switch width {
		case 16:
			combine_lanes(16, d, s0, s1, dir, weight, weighted, pixel_max)
		case 8:
			combine_lanes(8, d, s0, s1, dir, weight, weighted, pixel_max)
		case 4:
			combine_lanes(4, d, s0, s1, dir, weight, weighted, pixel_max)
		case:
			combine_lanes(2, d, s0, s1, dir, weight, weighted, pixel_max)
		}
	}
}

// Prediction of one block (in 4x4 units) of the macroblock from its lists
predict_inter_block :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index, block, width, height: int,
	$T: typeid,
) #no_bounds_check {
	macroblock := &decoder.macroblocks[macroblock_index]
	state := decoder.state
	buf := &decoder.picture.buf
	dir := macroblock.prediction_directions[block / 4]
	if dir == .None do return
	ref := [2]i8 {
		macroblock.reference_indices[0][block / 4],
		macroblock.reference_indices[1][block / 4],
	}
	weights, weighted := partition_weights(decoder, ref, dir)
	bx, by := h264.subblock_to_xy(block)
	x_pos := (macroblock_index % decoder.macroblock_columns) * 16 + bx * 4
	y_pos := (macroblock_index / decoder.macroblock_columns) * 16 + by * 4
	target := h264.prediction_target(T, buf, x_pos, y_pos)
	pixel_max := i32(1) << uint(decoder.bit_depth) - 1

	reference :: proc(state: ^Decoder_State, list: int, ref: i8) -> ^Picture {
		if ref < 0 || int(ref) >= state.ref_count[list] do return nil
		return state.ref_list[list][ref]
	}
	// Single reference without weighting: predict straight into the picture
	if dir != h264.Prediction_Direction.Bidirectional && !weighted {
		list := dir == h264.Prediction_Direction.List_0 ? 0 : 1
		if pic := reference(state, list, ref[list]); pic != nil {
			mv := macroblock.motion_vectors[list][block]
			h264.motion_compensate(&pic.buf, x_pos, y_pos, width * 4, height * 4, mv, &target, pixel_max)
		}
		return
	}
	// Chroma blocks are half the luma width, and half its height in 4:2:0.
	chroma_height := decoder.chroma_422 ? height * 4 : height * 2
	// Uninitialized: every sample read is predicted first, or zeroed for a
	// missing reference.
	luma_pred: [2][16 * 16]T = ---
	chroma_pred: [2][2][8 * 16]T = ---
	for list in 0 ..< 2 {
		if dir & (list == 0 ? h264.Prediction_Direction.List_0 : .List_1) == .None do continue
		pic := reference(state, list, ref[list])
		if pic == nil {
			luma_pred[list], chroma_pred[list] = {}, {}
		} else {
			pred := h264.Prediction_Target(T) {
				luma          = &luma_pred[list][0],
				chroma        = {&chroma_pred[list][0][0], &chroma_pred[list][1][0]},
				luma_stride   = 16,
				chroma_stride = 8,
			}
			mv := macroblock.motion_vectors[list][block]
			h264.motion_compensate(&pic.buf, x_pos, y_pos, width * 4, height * 4, mv, &pred, pixel_max)
		}
	}
	write_prediction(
		target.luma,
		target.luma_stride,
		&luma_pred[0][0],
		&luma_pred[1][0],
		16,
		width * 4,
		height * 4,
		dir,
		weights[0],
		weighted,
		pixel_max,
	)
	for p in 0 ..< 2 {
		write_prediction(
			target.chroma[p],
			target.chroma_stride,
			&chroma_pred[0][p][0],
			&chroma_pred[1][p][0],
			8,
			width * 2,
			chroma_height,
			dir,
			weights[1 + p],
			weighted,
			pixel_max,
		)
	}
}

// Whether blocks `first`..`first + count` share direction, references and vectors
predict_inter_macroblock :: proc(decoder: ^Slice_Decoder, macroblock_index: int, $T: typeid) {
	macroblock := &decoder.macroblocks[macroblock_index]
	macroblock.has_uniform_motion = h264.uniform_motion(macroblock, 0, 16)
	if macroblock.has_uniform_motion {
		predict_inter_block(decoder, macroblock_index, 0, 4, 4, T)
		return
	}
	for block8 in 0 ..< 4 {
		if h264.uniform_motion(macroblock, block8 * 4, 4) {
			predict_inter_block(decoder, macroblock_index, block8 * 4, 2, 2, T)
		} else {
			for k in 0 ..< 4 do predict_inter_block(decoder, macroblock_index, block8 * 4 + k, 1, 1, T)
		}
	}
}

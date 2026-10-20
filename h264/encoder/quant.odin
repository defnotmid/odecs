package h264_encoder

import common "../../common"

import "base:intrinsics"
import "core:simd"

// ---------------------------------------------------------------------------
// Forward transforms and quantisation (informative in the standard; the
// inverse is the decoder's)
// ---------------------------------------------------------------------------

// Forward 4x4 integer transform of a raster residual block
forward_dct_4x4 :: proc(residual: ^[16]i32) -> (coefficients: [16]i32) {
	Row :: #simd[4]i32
	row0 := intrinsics.unaligned_load((^Row)(&residual[0]))
	row1 := intrinsics.unaligned_load((^Row)(&residual[4]))
	row2 := intrinsics.unaligned_load((^Row)(&residual[8]))
	row3 := intrinsics.unaligned_load((^Row)(&residual[12]))
	return forward_dct_4x4_rows(row0, row1, row2, row3)
}

// Both the general i32 block and native pixel/register inputs lower to these
// same four rows. Keep transform order and equations in one owner.
forward_dct_4x4_rows :: #force_inline proc(
	first_row, second_row, third_row, fourth_row: #simd[4]i32,
) -> (
	coefficients: [16]i32,
) {
	Row :: #simd[4]i32
	row0, row1, row2, row3 := first_row, second_row, third_row, fourth_row
	columns := common.transpose([4]Row{row0, row1, row2, row3})
	column0, column1, column2, column3 := columns[0], columns[1], columns[2], columns[3]
	column0, column1, column2, column3 = forward_transform_four_vectors(
		column0,
		column1,
		column2,
		column3,
	)
	rows := common.transpose([4]Row{column0, column1, column2, column3})
	row0, row1, row2, row3 = rows[0], rows[1], rows[2], rows[3]
	row0, row1, row2, row3 = forward_transform_four_vectors(row0, row1, row2, row3)
	intrinsics.unaligned_store((^Row)(&coefficients[0]), row0)
	intrinsics.unaligned_store((^Row)(&coefficients[4]), row1)
	intrinsics.unaligned_store((^Row)(&coefficients[8]), row2)
	intrinsics.unaligned_store((^Row)(&coefficients[12]), row3)
	return
}

// Native source/prediction samples are widened u8, so subtraction in i16 is
// exact. Intra4 already owns these registers; other phases load four bounded
// 4-byte rows instead of scalarizing and repacking sixteen differences.
forward_dct_4x4_samples :: #force_inline proc(source, prediction: #simd[16]i16) -> [16]i32 {
	difference := simd.sub(source, prediction)
	return forward_dct_4x4_rows(
		(#simd[4]i32)(simd.swizzle(difference, 0, 1, 2, 3)),
		(#simd[4]i32)(simd.swizzle(difference, 4, 5, 6, 7)),
		(#simd[4]i32)(simd.swizzle(difference, 8, 9, 10, 11)),
		(#simd[4]i32)(simd.swizzle(difference, 12, 13, 14, 15)),
	)
}

forward_transform_four_vectors :: #force_inline proc(
	first, second, third, fourth: #simd[4]i32,
) -> (
	#simd[4]i32,
	#simd[4]i32,
	#simd[4]i32,
	#simd[4]i32,
) {
	outer_sum, outer_difference := simd.add(first, fourth), simd.sub(first, fourth)
	inner_sum, inner_difference := simd.add(second, third), simd.sub(second, third)
	return simd.add(
		outer_sum,
		inner_sum,
	), simd.add(simd.mul(outer_difference, 2), inner_difference), simd.sub(outer_sum, inner_sum), simd.sub(outer_difference, simd.mul(inner_difference, 2))
}

// Forward 4x4 Hadamard of the 16 luma DC coefficients (raster order of 4x4 blocks)
forward_hadamard_4x4 :: proc(dc: ^[16]i32) -> (out: [16]i32) {
	tmp: [16]i32
	for i in 0 ..< 4 {
		d := dc[i * 4:]
		s0, s3 := d[0] + d[3], d[0] - d[3]
		s1, s2 := d[1] + d[2], d[1] - d[2]
		tmp[i * 4 + 0] = s0 + s1
		tmp[i * 4 + 1] = s3 + s2
		tmp[i * 4 + 2] = s0 - s1
		tmp[i * 4 + 3] = s3 - s2
	}
	for i in 0 ..< 4 {
		d0, d1, d2, d3 := tmp[i], tmp[4 + i], tmp[8 + i], tmp[12 + i]
		s0, s3 := d0 + d3, d0 - d3
		s1, s2 := d1 + d2, d1 - d2
		out[0 * 4 + i] = (s0 + s1 + 1) >> 1
		out[1 * 4 + i] = (s3 + s2 + 1) >> 1
		out[2 * 4 + i] = (s0 - s1 + 1) >> 1
		out[3 * 4 + i] = (s3 - s2 + 1) >> 1
	}
	return
}

// Forward 2x2 Hadamard of the chroma DC coefficients (raster order of the four blocks)
forward_hadamard_2x2 :: proc(dc: [4]i32) -> [4]i32 {
	return {
		dc[0] + dc[1] + dc[2] + dc[3],
		dc[0] - dc[1] + dc[2] - dc[3],
		dc[0] + dc[1] - dc[2] - dc[3],
		dc[0] - dc[1] - dc[2] + dc[3],
	}
}

// Quantisation multipliers (8-315 inverted): [qp % 6][class]
quant_multiplier: [6][3]i32 = {
	{13107, 5243, 8066},
	{11916, 4660, 7490},
	{10082, 4194, 6554},
	{9362, 3647, 5825},
	{8192, 3355, 5243},
	{7282, 2893, 4559},
}

// Immutable per-frame facts of the admitted QP and prediction kind. Slice
// workers borrow these records; coefficient tuples remain candidate-owned.
Quantizer_4x4 :: struct {
	multipliers:                    #simd[16]i32,
	shift:                          u32,
	deadzone:                       i32,
	dc_shift:                       uint,
	dc_deadzone, dc_multiplier, qp: i32,
}

prepare_quantizer_4x4 :: #force_inline proc(qp: i32, intra: bool) -> (q: Quantizer_4x4) {
	q.qp = qp
	q.shift = u32(15 + qp / 6)
	q.deadzone = (i32(1) << q.shift) / (intra ? 3 : 6)
	scales := quant_multiplier[qp % 6]
	q.multipliers = #simd[16]i32 {
		scales[0],
		scales[2],
		scales[2],
		scales[0],
		scales[1],
		scales[0],
		scales[2],
		scales[2],
		scales[2],
		scales[2],
		scales[1],
		scales[0],
		scales[1],
		scales[2],
		scales[2],
		scales[1],
	}
	q.dc_shift = uint(16 + qp / 6)
	q.dc_deadzone = (i32(1) << q.dc_shift) / (intra ? 3 : 6)
	q.dc_multiplier = scales[0]
	return
}

// Quantise raster coefficients into scan-order levels with a dead zone of 1/3
// (intra) or 1/6 (inter); `first` is 1 for AC-only blocks. Returns the count of non-zero levels.
quantize_4x4 :: proc(
	coefficients: ^[16]i32,
	levels: ^[16]i16,
	qp: i32,
	intra: bool,
	first: int,
) -> int {
	q := prepare_quantizer_4x4(qp, intra)
	return quantize_4x4_prepared(coefficients, levels, &q, first)
}

quantize_4x4_prepared :: #force_inline proc(
	coefficients: ^[16]i32,
	levels: ^[16]i16,
	q: ^Quantizer_4x4,
	first: int,
) -> int {
	Coefficients :: #simd[16]i32
	raster := intrinsics.unaligned_load((^Coefficients)(coefficients))
	scan := simd.swizzle(raster, 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15)
	magnitudes := simd.shr(
		simd.add(simd.mul(simd.abs(scan), q.multipliers), Coefficients(q.deadzone)),
		(#simd[16]u32)(q.shift),
	)
	signed_levels := simd.select(simd.lanes_lt(scan, 0), simd.neg(magnitudes), magnitudes)
	quantized := simd.clamp(signed_levels, -32767, 32767)
	if first == 1 do quantized = simd.replace(quantized, 0, 0)
	intrinsics.unaligned_store((^#simd[16]i16)(levels), (#simd[16]i16)(quantized))
	return int(
		simd.reduce_add_ordered(
			simd.select(simd.lanes_ne(quantized, 0), Coefficients(1), Coefficients(0)),
		),
	)
}

// Quantise a transformed DC block (luma 16 or chroma 4 values, raster order) into scan order
quantize_dc :: proc(
	coeff: []i32,
	levels: []i16,
	scan: []u8,
	qp: i32,
	intra: bool,
) -> (
	nonzero: int,
) {
	q := prepare_quantizer_4x4(qp, intra)
	return quantize_dc_prepared(coeff, levels, scan, &q)
}

quantize_dc_prepared :: proc(
	coeff: []i32,
	levels: []i16,
	scan: []u8,
	q: ^Quantizer_4x4,
) -> (
	nonzero: int,
) {
	for i in 0 ..< len(levels) {
		c := coeff[scan[i]]
		level := (abs(c) * q.dc_multiplier + q.dc_deadzone) >> q.dc_shift
		if c < 0 do level = -level
		levels[i] = i16(clamp(level, -32767, 32767))
		if level != 0 do nonzero += 1
	}
	// For 8-bit residuals |DC| <= 4080; the luma Hadamard's /2 bounds
	// its output by 32640 (chroma by 16320). QP >= 10 quantizes that to
	// at most 2040, below every Baseline escape limit. Lower QPs can exceed
	// the exact per-level limit; normalize before either inverse DC transform.
	if q.qp < 10 do normalize_baseline_cavlc_dc_levels(levels)
	return
}

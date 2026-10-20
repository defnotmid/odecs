package h264_encoder

import h264 ".."

import "base:intrinsics"
import "core:simd"

// ---------------------------------------------------------------------------
// Distortion kernels, motion estimation and intra mode search
// ---------------------------------------------------------------------------

// Sum absolute pixel differences, widening before each row reduction.
absolute_difference_rows :: #force_inline proc(
	$Width: int,
	source: [^]u8,
	source_stride: int,
	prediction: [^]u8,
	prediction_stride: int,
	height: int,
) -> i32 #no_bounds_check {
	total: i32
	for row in 0 ..< height {
		differences := simd.abs_diff(
			h264.load_lanes(Width, &source[row * source_stride]),
			h264.load_lanes(Width, &prediction[row * prediction_stride]),
		)
		total += simd.reduce_add_ordered((#simd[Width]i32)(differences))
	}
	return total
}

block_absolute_difference_sum :: proc(
	source: [^]u8,
	source_stride: int,
	prediction: [^]u8,
	prediction_stride: int,
	width, height: int,
) -> i32 {
	switch width {
	case 16:
		return absolute_difference_rows(
			16,
			source,
			source_stride,
			prediction,
			prediction_stride,
			height,
		)
	case 8:
		return absolute_difference_rows(
			8,
			source,
			source_stride,
			prediction,
			prediction_stride,
			height,
		)
	}
	return absolute_difference_rows(
		4,
		source,
		source_stride,
		prediction,
		prediction_stride,
		height,
	)
}

// Sum of absolute Hadamard-transformed differences of one 4x4 block. The block
// lives in one 16-lane register as four row groups; the vertical butterflies swap
// row groups and the horizontal ones swap lanes within a group. Whole-row sign
// flips are free because only magnitudes are summed.
transformed_difference_block_4x4 :: proc(
	source: [^]u8,
	source_stride: int,
	prediction: [^]u8,
	prediction_stride: int,
) -> i32 #no_bounds_check {
	return transformed_difference_4x4(
		h264.load_luma_block_4x4(source, source_stride),
		h264.load_luma_block_4x4(prediction, prediction_stride),
	)
}

transformed_difference_4x4 :: #force_inline proc(source, prediction: #simd[16]i16) -> i32 {
	difference := simd.sub(source, prediction)

	// Vertical: rows (r0, r1, r2, r3) -> (r0+r2 + r1+r3, r1+r3 - (r0+r2), -(r0-r2 + r1-r3), r0-r2 - (r1-r3))
	swapped_pairs := simd.swizzle(difference, 8, 9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7)
	pair_sum, pair_difference :=
		simd.add(difference, swapped_pairs), simd.sub(difference, swapped_pairs)
	row_pairs := simd.shuffle(
		pair_sum,
		pair_difference,
		0,
		1,
		2,
		3,
		4,
		5,
		6,
		7,
		24,
		25,
		26,
		27,
		28,
		29,
		30,
		31,
	)
	swapped_rows := simd.swizzle(row_pairs, 4, 5, 6, 7, 0, 1, 2, 3, 12, 13, 14, 15, 8, 9, 10, 11)
	plus, minus := simd.add(row_pairs, swapped_rows), simd.sub(row_pairs, swapped_rows)
	vertical_transform := simd.shuffle(
		plus,
		minus,
		0,
		1,
		2,
		3,
		20,
		21,
		22,
		23,
		8,
		9,
		10,
		11,
		28,
		29,
		30,
		31,
	)

	// Horizontal butterflies combine adjacent columns, then opposite pairs.
	swapped_lanes := simd.swizzle(
		vertical_transform,
		1,
		0,
		3,
		2,
		5,
		4,
		7,
		6,
		9,
		8,
		11,
		10,
		13,
		12,
		15,
		14,
	)
	plus, minus =
		simd.add(vertical_transform, swapped_lanes), simd.sub(vertical_transform, swapped_lanes)
	column_pairs := simd.shuffle(
		plus,
		minus,
		0,
		17,
		2,
		19,
		4,
		21,
		6,
		23,
		8,
		25,
		10,
		27,
		12,
		29,
		14,
		31,
	)
	opposite_pairs := simd.swizzle(
		column_pairs,
		2,
		3,
		0,
		1,
		6,
		7,
		4,
		5,
		10,
		11,
		8,
		9,
		14,
		15,
		12,
		13,
	)
	magnitudes := simd.add(
		simd.abs(simd.add(column_pairs, opposite_pairs)),
		simd.abs(simd.sub(column_pairs, opposite_pairs)),
	)
	// Every magnitude appears twice across the lane pairs, so the lane total is double the SATD
	return (simd.reduce_add_ordered((#simd[16]i32)(magnitudes)) / 2 + 1) >> 1
}

block_transformed_difference_sum :: proc(
	source: [^]u8,
	source_stride: int,
	prediction: [^]u8,
	prediction_stride: int,
	width, height: int,
) -> (
	sum: i32,
) {
	switch width {
	case 16:
		return transformed_difference_sum(
			16,
			source,
			source_stride,
			prediction,
			prediction_stride,
			height,
		)
	case 8:
		return transformed_difference_sum(
			8,
			source,
			source_stride,
			prediction,
			prediction_stride,
			height,
		)
	}
	for row := 0; row < height; row += 4 do sum += transformed_difference_block_4x4(&source[row * source_stride], source_stride, &prediction[row * prediction_stride], prediction_stride)
	return
}

// Transform four 4x4 blocks together across a 16-pixel row (two at width 8).
// Every group of four lanes remains an independent Hadamard block.
transformed_difference_sum :: proc(
	$Width: int,
	source: [^]u8,
	source_stride: int,
	prediction: [^]u8,
	prediction_stride: int,
	height: int,
) -> i32 #no_bounds_check {
	total: #simd[Width]i32
	for row := 0; row < height; row += 4 {
		first := simd.sub(
			h264.load_lanes(Width, &source[row * source_stride]),
			h264.load_lanes(Width, &prediction[row * prediction_stride]),
		)
		second := simd.sub(
			h264.load_lanes(Width, &source[(row + 1) * source_stride]),
			h264.load_lanes(Width, &prediction[(row + 1) * prediction_stride]),
		)
		third := simd.sub(
			h264.load_lanes(Width, &source[(row + 2) * source_stride]),
			h264.load_lanes(Width, &prediction[(row + 2) * prediction_stride]),
		)
		fourth := simd.sub(
			h264.load_lanes(Width, &source[(row + 3) * source_stride]),
			h264.load_lanes(Width, &prediction[(row + 3) * prediction_stride]),
		)
		outer_sum, outer_difference := simd.add(first, fourth), simd.sub(first, fourth)
		inner_sum, inner_difference := simd.add(second, third), simd.sub(second, third)
		rows := [4]#simd[Width]i16 {
			simd.add(outer_sum, inner_sum),
			simd.sub(outer_sum, inner_sum),
			simd.add(outer_difference, inner_difference),
			simd.sub(outer_difference, inner_difference),
		}
		for transformed_row in rows {
			adjacent: #simd[Width]i16
			when Width == 16 {adjacent = simd.swizzle(transformed_row, 1, 0, 3, 2, 5, 4, 7, 6, 9, 8, 11, 10, 13, 12, 15, 14)} else {adjacent = simd.swizzle(transformed_row, 1, 0, 3, 2, 5, 4, 7, 6)}
			pair_sum, pair_difference :=
				simd.add(transformed_row, adjacent), simd.sub(transformed_row, adjacent)
			alternating, opposite: #simd[Width]i16
			when Width == 16 {
				alternating = simd.shuffle(
					pair_sum,
					pair_difference,
					0,
					17,
					2,
					19,
					4,
					21,
					6,
					23,
					8,
					25,
					10,
					27,
					12,
					29,
					14,
					31,
				)
				opposite = simd.swizzle(
					alternating,
					2,
					3,
					0,
					1,
					6,
					7,
					4,
					5,
					10,
					11,
					8,
					9,
					14,
					15,
					12,
					13,
				)
			} else {
				alternating = simd.shuffle(pair_sum, pair_difference, 0, 9, 2, 11, 4, 13, 6, 15)
				opposite = simd.swizzle(alternating, 2, 3, 0, 1, 6, 7, 4, 5)
			}
			magnitudes := simd.add(
				simd.abs(simd.add(alternating, opposite)),
				simd.abs(simd.sub(alternating, opposite)),
			)
			total = simd.add(total, (#simd[Width]i32)(magnitudes))
		}
	}
	// The horizontal lane pairs duplicate every magnitude. Hadamard SATD
	// divides by another two; each complete 4x4 transform has an even sum.
	return simd.reduce_add_ordered(total) / 4
}

// Bits of se(value) / ue(value) codes
unsigned_exp_golomb_bit_count :: #force_inline proc(value: u32) -> i32 {
	return(
		2 * i32(intrinsics.count_leading_zeros(u32(1))) -
		2 * i32(intrinsics.count_leading_zeros(value + 1)) +
		1 \
	)
}

signed_exp_golomb_bit_count :: #force_inline proc(value: i32) -> i32 {
	return unsigned_exp_golomb_bit_count(u32(value > 0 ? 2 * value - 1 : -2 * value))
}

motion_vector_bit_count :: #force_inline proc(motion, predictor: [2]i16) -> i32 {
	return(
		signed_exp_golomb_bit_count(i32(motion[0]) - i32(predictor[0])) +
		signed_exp_golomb_bit_count(i32(motion[1]) - i32(predictor[1])) \
	)
}

// Lagrange multiplier for SAD/SATD costs: 2^((qp - 12) / 6)
motion_lambda_for_qp :: proc(qp: i32) -> i32 {
	table := [52]i32 {
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
		1,
		2,
		2,
		2,
		2,
		3,
		3,
		3,
		4,
		4,
		4,
		5,
		6,
		6,
		7,
		8,
		9,
		10,
		11,
		13,
		14,
		16,
		18,
		20,
		23,
		25,
		29,
		32,
		36,
		40,
		45,
		51,
		57,
		64,
		72,
		81,
		91,
	}
	return table[clamp(qp, 0, 51)]
}

Motion_Search_Region :: struct {
	reference:        ^Encoder_Picture,
	source:           [^]u8,
	source_stride:    int,
	column, row:      int, // block position in pixels
	block_width:      int,
	block_height:     int,
	predicted_motion: [2]i16,
	motion_lambda:    i32,
	search_radius:    int, // integer-pixel search radius
}

// Cost of an integer-pel vector: SAD plus vector bits
@(private = "file")
integer_motion_cost :: proc(
	search: ^Motion_Search_Region,
	motion_x, motion_y: int,
) -> i32 #no_bounds_check {
	buffer := &search.reference.buf
	x := search.column + motion_x
	y := search.row + motion_y
	if x < 3 - h264.PADDING_LENGTH || y < 3 - h264.PADDING_LENGTH || x > buffer.coded_width + h264.PADDING_LENGTH - search.block_width - 4 || y > buffer.coded_height + h264.PADDING_LENGTH - search.block_height - 4 do return max(i32)
	distortion := block_absolute_difference_sum(
		search.source,
		search.source_stride,
		&buffer.y[y * buffer.y_stride + x],
		buffer.y_stride,
		search.block_width,
		search.block_height,
	)
	return(
		distortion +
		search.motion_lambda *
			motion_vector_bit_count(
				{i16(motion_x * 4), i16(motion_y * 4)},
				search.predicted_motion,
			) \
	)
}

@(private = "file")
subpixel_motion_cost :: proc(
	search: ^Motion_Search_Region,
	motion: [2]i16,
	prediction: [^]u8,
) -> i32 {
	predict_reference_luma(
		search.reference,
		search.column,
		search.row,
		search.block_width,
		search.block_height,
		motion,
		prediction,
	)
	return(
		block_transformed_difference_sum(
			search.source,
			search.source_stride,
			prediction,
			16,
			search.block_width,
			search.block_height,
		) +
		search.motion_lambda * motion_vector_bit_count(motion, search.predicted_motion) \
	)
}

// Integer hexagon search from the selected_motion candidate vector. Returns the motion
// in quarter-pixel units and its SAD plus vector-bit cost.
search_integer_motion :: proc(
	search: ^Motion_Search_Region,
	candidates: [][2]i16,
) -> (
	selected_motion: [2]i16,
	cost: i32,
) {
	selected_x, selected_y := 0, 0
	selected_cost := max(i32)
	for candidate in candidates {
		motion_x, motion_y := int(candidate[0]) >> 2, int(candidate[1]) >> 2
		if value := integer_motion_cost(search, motion_x, motion_y); value < selected_cost {
			selected_cost, selected_x, selected_y = value, motion_x, motion_y
		}
	}
	centre_x, centre_y := selected_x, selected_y
	hexagon := [6][2]int{{-2, 0}, {-1, -2}, {1, -2}, {2, 0}, {1, 2}, {-1, 2}}
	for step := 0; step < search.search_radius; step += 1 {
		improved := false
		for offset in hexagon {
			motion_x, motion_y := selected_x + offset[0], selected_y + offset[1]
			if abs(motion_x - centre_x) > search.search_radius || abs(motion_y - centre_y) > search.search_radius do continue
			if value := integer_motion_cost(search, motion_x, motion_y); value < selected_cost {
				selected_cost, selected_x, selected_y = value, motion_x, motion_y
				improved = true
			}
		}
		if !improved do break
	}
	diamond := [4][2]int{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
	for offset in diamond {
		if value := integer_motion_cost(search, selected_x + offset[0], selected_y + offset[1]);
		   value < selected_cost {
			selected_cost, selected_x, selected_y =
				value, selected_x + offset[0], selected_y + offset[1]
		}
	}

	return {i16(selected_x * 4), i16(selected_y * 4)}, selected_cost
}

// Refine only the partitions selected by the integer-pixel search.
refine_subpixel_motion :: proc(
	search: ^Motion_Search_Region,
	integer_motion: [2]i16,
) -> (
	selected_motion: [2]i16,
	cost: i32,
) {
	prediction: [16 * 16]u8
	selected_motion = integer_motion
	cost = subpixel_motion_cost(search, selected_motion, &prediction[0])
	for step in ([2]i16{2, 1}) do for _ in 0 ..< 2 {
		origin := selected_motion
		for offset in ([4][2]i16{{-step, 0}, {step, 0}, {0, -step}, {0, step}}) {
			motion := origin + offset
			if value := subpixel_motion_cost(search, motion, &prediction[0]); value < cost {
				cost, selected_motion = value, motion
			}
		}
		if selected_motion == origin do break
	}
	return
}

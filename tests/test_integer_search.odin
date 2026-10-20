package main

import h264 "../video/h264"
import avc_enc "../video/h264/encoder"
import "core:fmt"

next_random :: proc(state: ^u32) -> u32 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 17
	state^ ~= state^ << 5
	return state^
}

scalar_motion_bits :: proc(motion, predictor: [2]i16) -> i32 {
	bits: i32
	for component in 0 ..< 2 {
		delta := i32(motion[component]) - i32(predictor[component])
		code := u32(delta > 0 ? 2 * delta - 1 : -2 * delta) + 1
		length: i32
		for code > 0 {
			length += 1
			code >>= 1
		}
		bits += 2 * length - 1
	}
	return bits
}

// Independent scalar SAD with the original bounds and vector-bit cost.
original_integer_cost :: proc(
	search: ^avc_enc.Motion_Search_Region,
	motion_x, motion_y: int,
) -> i32 {
	buffer := &search.reference.buf
	x, y := search.column + motion_x, search.row + motion_y
	if x < 3 - h264.PADDING_LENGTH || y < 3 - h264.PADDING_LENGTH || x > buffer.coded_width + h264.PADDING_LENGTH - search.block_width - 4 || y > buffer.coded_height + h264.PADDING_LENGTH - search.block_height - 4 do return max(i32)
	distortion: i32
	for row in 0 ..< search.block_height do for column in 0 ..< search.block_width {
		distortion += abs(i32(search.source[row * search.source_stride + column]) - i32(buffer.y[(y + row) * buffer.y_stride + x + column]))
	}
	return(
		distortion +
		search.motion_lambda *
			scalar_motion_bits({i16(motion_x * 4), i16(motion_y * 4)}, search.predicted_motion) \
	)
}

// Frozen original traversal, including its mutable center within each offset
// loop. This checks removal of repeated work without changing the search.
original_integer_search :: proc(
	search: ^avc_enc.Motion_Search_Region,
	candidates: [][2]i16,
) -> (
	selected_motion: [2]i16,
	cost: i32,
) {
	selected_x, selected_y := 0, 0
	selected_cost := max(i32)
	for candidate in candidates {
		motion_x, motion_y := int(candidate[0]) >> 2, int(candidate[1]) >> 2
		if value := original_integer_cost(search, motion_x, motion_y); value < selected_cost {
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
			if value := original_integer_cost(search, motion_x, motion_y); value < selected_cost {
				selected_cost, selected_x, selected_y = value, motion_x, motion_y
				improved = true
			}
		}
		if !improved do break
	}
	diamond := [4][2]int{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
	for offset in diamond {
		if value := original_integer_cost(search, selected_x + offset[0], selected_y + offset[1]);
		   value < selected_cost {
			selected_cost, selected_x, selected_y =
				value, selected_x + offset[0], selected_y + offset[1]
		}
	}
	return {i16(selected_x * 4), i16(selected_y * 4)}, selected_cost
}

compare_search :: proc(search: ^avc_enc.Motion_Search_Region, seeds: [][2]i16, checks: ^int) {
	expected_motion, expected_cost := original_integer_search(search, seeds)
	actual_motion, actual_cost := avc_enc.search_integer_motion(search, seeds)
	if actual_motion != expected_motion || actual_cost != expected_cost {
		fmt.printfln(
			"[FAIL] shape=%dx%d position=%v radius=%d lambda=%d predictor=%v seeds=%v actual=%v/%d expected=%v/%d",
			search.block_width,
			search.block_height,
			[2]int{search.column, search.row},
			search.search_radius,
			search.motion_lambda,
			search.predicted_motion,
			seeds,
			actual_motion,
			actual_cost,
			expected_motion,
			expected_cost,
		)
		assert(false)
	}
	checks^ += 1
}

test_motion_bit_bounds :: proc() {
	output := make([dynamic]u8, 0, 16)
	defer delete(output)
	// Every representable i16-minus-i16 delta, with both signs in the two
	// components, is checked against the actual signed Exp-Golomb writer and
	// independent scalar code-number arithmetic. This includes delta zero.
	for delta in i32(-65535) ..= 65535 {
		motion, predictor: [2]i16
		if delta >= 0 {
			motion[0] = 32767
			predictor[0] = i16(32767 - delta)
		} else {
			motion[0] = -32768
			predictor[0] = i16(-32768 - delta)
		}
		motion[1], predictor[1] = predictor[0], motion[0]
		writer := h264.init_bit_writer(&output)
		h264.write_signed_exp_golomb(&writer, delta)
		h264.write_signed_exp_golomb(&writer, -delta)
		written := i32(len(output) * 8 + writer.nbits)
		actual := avc_enc.motion_vector_bit_count(motion, predictor)
		assert(actual == written && actual == scalar_motion_bits(motion, predictor))
	}
	limits := [14]i16 {
		-32768,
		-32767,
		-16384,
		-257,
		-256,
		-1,
		0,
		1,
		255,
		256,
		257,
		16383,
		32766,
		32767,
	}
	for motion in limits {
		for predictor in limits {
			mv, pred := [2]i16{motion, predictor}, [2]i16{predictor, motion}
			assert(avc_enc.motion_vector_bit_count(mv, pred) == scalar_motion_bits(mv, pred))
		}
	}
	assert(scalar_motion_bits({32767, -32768}, {-32768, 32767}) == 66)
	assert(avc_enc.motion_lambda_for_qp(51) == 91)
	assert(avc_enc.motion_vector_bit_count({0, 0}, {0, 0}) == 2)
	fmt.println(
		"[SUCCESS] Motion-vector rate: all 131071 i16 deltas, written Exp-Golomb lengths, independent scalar code arithmetic and extreme pairs",
	)
}

test_ties_and_prefixes :: proc(reference: ^avc_enc.Encoder_Picture, checks: ^int) {
	buffer := &reference.buf
	// Flat zero-rate searches make every valid seed and offset exactly tied.
	// The first valid seed must survive the complete mutable-center traversal.
	for row in 0 ..< 48 do for column in 0 ..< 64 do buffer.y[row * buffer.y_stride + column] = 128
	h264.expand_picture(buffer)
	source: [256]u8
	for &value in source do value = 128
	for shape in ([5][2]int{{16, 16}, {16, 8}, {8, 16}, {8, 8}, {4, 4}}) {
		search := avc_enc.Motion_Search_Region {
			reference     = reference,
			source        = &source[0],
			source_stride = 16,
			column        = 16,
			row           = 16,
			block_width   = shape[0],
			block_height  = shape[1],
			motion_lambda = 0,
			search_radius = 16,
		}
		seeds := [3][2]i16{{8, 0}, {-8, 0}, {0, 0}}
		compare_search(&search, seeds[:], checks)
		motion, cost := avc_enc.search_integer_motion(&search, seeds[:])
		assert(motion == seeds[0] && cost == 0)
	}
	// The first seed establishes a full low-cost incumbent. Each second seed
	// places high error in the 4th, 8th or 12th row prefix. The complete scalar
	// traversal is the oracle, including the final diamond after losing seeds.
	for shape in ([2][2]int{{16, 16}, {8, 16}}) {
		for bad_row in ([3]int{0, 4, 8}) {
			for row in 0 ..< 48 do for column in 0 ..< 64 do buffer.y[row * buffer.y_stride + column] = 255
			for row in 0 ..< shape[1] {
				for column in 0 ..< shape[0] {
					buffer.y[(16 + row) * buffer.y_stride + column] = 10
					buffer.y[(16 + row) * buffer.y_stride + 32 + column] =
						row >= bad_row && row < bad_row + 4 ? 255 : 0
					source[row * 16 + column] = 0
				}
			}
			h264.expand_picture(buffer)
			search := avc_enc.Motion_Search_Region {
				reference     = reference,
				source        = &source[0],
				source_stride = 16,
				column        = 16,
				row           = 16,
				block_width   = shape[0],
				block_height  = shape[1],
				motion_lambda = 91,
				search_radius = 0,
			}
			seeds := [2][2]i16{{-64, 0}, {64, 0}}
			compare_search(&search, seeds[:], checks)
		}
	}
	// Full white-versus-black contrast reaches the maximum native SAD. Extreme
	// predictors also exercise the largest vector-bit contribution without wrap.
	for row in 0 ..< 48 do for column in 0 ..< 64 do buffer.y[row * buffer.y_stride + column] = 255
	h264.expand_picture(buffer)
	source = {}
	search := avc_enc.Motion_Search_Region {
		reference        = reference,
		source           = &source[0],
		source_stride    = 16,
		column           = 16,
		row              = 16,
		block_width      = 16,
		block_height     = 16,
		predicted_motion = {32767, -32768},
		motion_lambda    = 91,
		search_radius    = 16,
	}
	assert(
		original_integer_cost(&search, 0, 0) ==
		65280 + 91 * scalar_motion_bits({0, 0}, search.predicted_motion),
	)
	seeds := [3][2]i16{{0, 0}, {-32, 32}, {32767, -32768}}
	compare_search(&search, seeds[:], checks)
}

main :: proc() {
	test_motion_bit_bounds()
	reference: avc_enc.Encoder_Picture
	reference.buf = h264.alloc_yuv_buffer(64, 48)
	defer h264.free_yuv_buffer(&reference.buf)
	random: u32 = 0x541BB137
	checks := 0
	for pattern in 0 ..< 4 {
		buffer := &reference.buf
		for row in 0 ..< 48 do for column in 0 ..< 64 {
			switch pattern {
			case 0:
				buffer.y[row * buffer.y_stride + column] = 128
			case 1:
				buffer.y[row * buffer.y_stride + column] = u8((column * 7 + row * 11) & 255)
			case 2:
				buffer.y[row * buffer.y_stride + column] = u8(next_random(&random))
			case 3:
				buffer.y[row * buffer.y_stride + column] = (column < 32 ? u8(0) : u8(255))
			}
		}
		h264.expand_picture(buffer)
		for shape in ([9][2]int{{16, 16}, {16, 8}, {16, 4}, {8, 16}, {8, 8}, {8, 4}, {4, 16}, {4, 8}, {4, 4}}) {
			for position in ([5][2]int{{0, 0}, {16, 16}, {48, 32}, {3 - h264.PADDING_LENGTH, 3 - h264.PADDING_LENGTH}, {64 + h264.PADDING_LENGTH - shape[0] - 4, 48 + h264.PADDING_LENGTH - shape[1] - 4}}) {
				for radius in ([4]int{0, 1, 16, 33}) {
					for predictor in ([4][2]i16{{0, 0}, {3, -3}, {-17, 9}, {32767, -32768}}) {
						source: [256]u8
						// A shifted block exercises successful center updates; the flat
						// and split patterns also produce equal-cost and extreme SAD cases.
						x := clamp(
							position[0] - 3,
							3 - h264.PADDING_LENGTH,
							64 + h264.PADDING_LENGTH - shape[0] - 4,
						)
						y := clamp(
							position[1] + 2,
							3 - h264.PADDING_LENGTH,
							48 + h264.PADDING_LENGTH - shape[1] - 4,
						)
						for row in 0 ..< shape[1] do for column in 0 ..< shape[0] do source[row * 16 + column] = buffer.y[(y + row) * buffer.y_stride + x + column]
						search := avc_enc.Motion_Search_Region {
							reference        = &reference,
							source           = &source[0],
							source_stride    = 16,
							column           = position[0],
							row              = position[1],
							block_width      = shape[0],
							block_height     = shape[1],
							predicted_motion = predictor,
							motion_lambda    = avc_enc.motion_lambda_for_qp(i32(checks % 52)),
							search_radius    = radius,
						}
						seed_sets := [4][5][2]i16 {
							{predictor, {0, 0}, {0, 1}, {1, 0}, {3, 3}}, // Fractional seeds collapse to the same integer coordinate.
							{{0, 0}, {128, 0}, {0, 0}, {0, 128}, {128, 128}}, // Repeated seeds and distant full-cost competitors.
							{{-3, -3}, {-4, -4}, {-1, -1}, {3, 3}, {32767, -32768}}, // Negative shifts and out-of-bounds vectors.
							{
								{
									i16(int(next_random(&random) % 129) - 64),
									i16(int(next_random(&random) % 129) - 64),
								},
								predictor,
								{-12, 8},
								{-12, 8},
								{0, 0},
							},
						}
						for &seeds in seed_sets {
							compare_search(&search, seeds[:], &checks)
						}
						// Empty seeds retain the original zero center, including its
						// max-cost starting state, before the unchanged offset traversal.
						compare_search(&search, nil, &checks)
					}
				}
			}
		}
	}
	test_ties_and_prefixes(&reference, &checks)
	fmt.printfln(
		"[SUCCESS] Integer search: %d original-traversal/scalar-cost comparisons, all 4/8/16 shapes, borders, ties, 4/8/12-row prefixes and vector-bit bounds",
		checks,
	)
}

package h264_encoder

import h264 ".."
import "core:testing"

// Independent matrix definition of the existing integer transform, rather
// than the four-vector butterfly implementation or a transform round trip.
residual_shape_transform_oracle :: proc(residual: ^[16]i32) -> (coefficients: [16]i32) {
	weights := [4][4]i32{{1, 1, 1, 1}, {2, 1, -1, -2}, {1, -1, -1, 1}, {1, -2, 2, -1}}
	for row in 0 ..< 4 do for column in 0 ..< 4 {
		value: i32
		for y in 0 ..< 4 do for x in 0 ..< 4 do value += weights[row][y] * residual[y * 4 + x] * weights[column][x]
		coefficients[row * 4 + column] = value
	}
	return
}

residual_shape_next :: proc(seed: ^u32) -> u32 {
	seed^ = seed^ * 1664525 + 1013904223
	return seed^
}

@(test)
test_register_and_strided_residual_inputs_match_matrix_transform :: proc(t: ^testing.T) {
	seed: u32 = 0x7134_b2c9
	for stride in ([7]int{4, 5, 7, 8, 15, 16, 31}) {
		for pattern in 0 ..< 40 {
			source, prediction: [136]u8
			for &value in source do value = u8(residual_shape_next(&seed) >> 24)
			for &value in prediction do value = u8(residual_shape_next(&seed) >> 24)
			residual: [16]i32
			for y in 0 ..< 4 do for x in 0 ..< 4 {
				at := 1 + y * stride + x
				if pattern == 0 {source[at], prediction[at] = 0, 0}
				if pattern == 1 {source[at], prediction[at] = 255, 0}
				if pattern == 2 {source[at], prediction[at] = 0, 255}
				if pattern >= 3 && pattern < 19 {source[at] = y * 4 + x == pattern - 3 ? 255 : 0; prediction[at] = 0}
				residual[y * 4 + x] = i32(source[at]) - i32(prediction[at])
			}
			before_source, before_prediction := source, prediction
			expected := residual_shape_transform_oracle(&residual)
			actual := forward_dct_4x4_samples(
				h264.load_luma_block_4x4(&source[1], stride),
				h264.load_luma_block_4x4(&prediction[1], stride),
			)
			testing.expect_value(t, actual, expected)
			testing.expect_value(t, forward_dct_4x4(&residual), expected)
			testing.expect(
				t,
				source == before_source && prediction == before_prediction,
				"residual producer mutated input or row padding",
			)
		}
	}
}

@(test)
test_prepared_quantizer_matches_independent_equations_all_qps :: proc(t: ^testing.T) {
	seed: u32 = 0x294b_b718
	for qp in i32(0) ..< 52 {
		for intra in ([2]bool{false, true}) {
			q := prepare_quantizer_4x4(qp, intra)
			testing.expect_value(t, q.qp, qp)
			for first in 0 ..< 2 {
				for pattern in 0 ..< 64 {
					coefficients: [16]i32
					for &value, i in coefficients {
						value = i32(residual_shape_next(&seed) % 200001) - 100000
						if pattern < 4 do value = pattern == 0 ? 0 : pattern == 1 ? 1 : pattern == 2 ? -1 : (i & 1 == 0 ? 100000 : -100000)
					}
					expected: [16]i16
					count: int
					shift := uint(15 + qp / 6)
					bias := (i32(1) << shift) / (intra ? 3 : 6)
					for scan in first ..< 16 {
						position := int(h264.zigzag_scan_4x4[scan])
						row, column := position / 4, position % 4
						kind :=
							row & 1 == 0 && column & 1 == 0 ? 0 : row & 1 != 0 && column & 1 != 0 ? 1 : 2
						coefficient := coefficients[position]
						magnitude :=
							(abs(coefficient) * quant_multiplier[qp % 6][kind] + bias) >> shift
						expected[scan] = i16(
							clamp(coefficient < 0 ? -magnitude : magnitude, -32767, 32767),
						)
						if expected[scan] != 0 do count += 1
					}
					guarded: [18]i16
					guarded[0], guarded[17] = 0x3217, -0x2765
					actual := cast(^[16]i16)(&guarded[1])
					testing.expect_value(
						t,
						quantize_4x4_prepared(&coefficients, actual, &q, first),
						count,
					)
					testing.expect_value(t, actual^, expected)
					testing.expect(
						t,
						guarded[0] == 0x3217 && guarded[17] == -0x2765,
						"quantizer wrote outside sixteen levels",
					)
					generic: [16]i16
					testing.expect_value(
						t,
						quantize_4x4(&coefficients, &generic, qp, intra, first),
						count,
					)
					testing.expect_value(t, generic, expected)
				}
			}
			// DC uses an independent scalar equation. Low-QP wire
			// normalization is an unchanged semantic owner of this cut.
			for size in ([2]int{4, 16}) {
				coefficients: [16]i32
				for &value in coefficients do value = i32(residual_shape_next(&seed) % 65281) - 32640
				expected, actual: [16]i16
				count: int
				scan := size == 4 ? h264.chroma_dc_scan[:] : h264.zigzag_scan_4x4[:]
				for position, i in scan {
					c := coefficients[position]
					bits := uint(16 + qp / 6)
					bias := (i32(1) << bits) / (intra ? 3 : 6)
					v := (abs(c) * quant_multiplier[qp % 6][0] + bias) >> bits
					expected[i] = i16(clamp(c < 0 ? -v : v, -32767, 32767))
					if expected[i] != 0 do count += 1
				}
				if qp < 10 do normalize_baseline_cavlc_dc_levels(expected[:size])
				testing.expect_value(
					t,
					quantize_dc_prepared(coefficients[:], actual[:size], scan, &q),
					count,
				)
				testing.expect_value(t, actual, expected)
			}
		}
	}
}

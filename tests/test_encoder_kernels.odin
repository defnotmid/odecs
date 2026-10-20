package main

import h264 "../video/h264"
import avc_dec "../video/h264/decoder"
import avc_enc "../video/h264/encoder"
import "core:fmt"

next_random :: proc(state: ^u32) -> u32 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 17
	state^ ~= state^ << 5
	return state^
}

scalar_transform :: proc(residual: [16]i32) -> [16]i32 {
	coefficients := residual
	for vertical in ([2]bool{false, true}) {
		input := coefficients
		for line in 0 ..< 4 {
			start, step := vertical ? line : line * 4, vertical ? 4 : 1
			first, second, third, fourth :=
				input[start], input[start + step], input[start + step * 2], input[start + step * 3]
			coefficients[start] = first + second + third + fourth
			coefficients[start + step] = 2 * first + second - third - 2 * fourth
			coefficients[start + step * 2] = first - second - third + fourth
			coefficients[start + step * 3] = first - 2 * second + 2 * third - fourth
		}
	}
	return coefficients
}

test_transform_quantization :: proc() {
	random_state: u32 = 0x517D903A
	for qp in i32(0) ..< 52 do for intra in ([2]bool{false, true}) do for first_coefficient in 0 ..< 2 do for _ in 0 ..< 64 {
		residual: [16]i32
		for &value in residual do value = i32(next_random(&random_state) % 511) - 255
		coefficients := scalar_transform(residual)
		assert(avc_enc.forward_dct_4x4(&residual) == coefficients)
		expected, actual: [16]i16
		nonzero_count := 0
		shift := uint(15 + qp / 6)
		bias := (i32(1) << shift) / (intra ? 3 : 6)
		for scan in first_coefficient ..< 16 {
			position := int(h264.zigzag_scan_4x4[scan])
			column, row := position % 4, position / 4
			scaling_class := column % 2 == 0 && row % 2 == 0 ? 0 : column % 2 == 1 && row % 2 == 1 ? 1 : 2
			coefficient := coefficients[position]
			magnitude := (abs(coefficient) * avc_enc.quant_multiplier[qp % 6][scaling_class] + bias) >> shift
			expected[scan] = i16(clamp(coefficient < 0 ? -magnitude : magnitude, -32767, 32767))
			if expected[scan] != 0 do nonzero_count += 1
		}
		assert(avc_enc.quantize_4x4(&coefficients, &actual, qp, intra, first_coefficient) == nonzero_count && actual == expected)
	}
	fmt.println(
		"[SUCCESS] SIMD transform and quantization: every QP, intra/inter, AC/DC, scalar oracle",
	)
}

test_coefficient_summary :: proc() {
	random_state: u32 = 0x43152321
	for length in 0 ..= 16 do for _ in 0 ..< 256 {
		levels: [16]i16
		for &level in levels[:length] do level = i16(next_random(&random_state) % 9) - 4
		actual := avc_enc.summarize_cavlc_coefficients(levels[:length])
		expected: avc_enc.Cavlc_Coefficient_Summary
		position := length - 1
		for position >= 0 && levels[position] == 0 do position -= 1
		for position >= 0 {
			expected.levels_descending[expected.nonzero_count] = levels[position]
			position -= 1
			zero_count := 0
			for position >= 0 && levels[position] == 0 {zero_count += 1; position -= 1}
			expected.zero_runs[expected.nonzero_count] = u8(zero_count)
			expected.total_zero_count += zero_count
			expected.nonzero_count += 1
		}
		for index in 0 ..< min(3, expected.nonzero_count) {
			if abs(expected.levels_descending[index]) != 1 do break
			expected.trailing_one_count += 1
			expected.trailing_sign_bits = expected.trailing_sign_bits << 1 | (expected.levels_descending[index] < 0 ? 1 : 0)
		}
		assert(actual == expected)
		if length == 4 || length == 15 || length == 16 {
			for neighbour_count in ([5]i8{0, 2, 4, 8, 16}) {
				neighbour_count := length == 4 ? i8(-1) : neighbour_count
				output := make([dynamic]u8)
				writer := h264.init_bit_writer(&output)
				avc_enc.write_cavlc_block(&writer, levels[:length], neighbour_count)
				assert(avc_enc.cavlc_coefficient_bit_count(levels[:length], neighbour_count) == len(output) * 8 + writer.nbits)
				delete(output)
			}
		}
	}
	fmt.println(
		"[SUCCESS] SIMD coefficient masks/runs and direct bit counts: scalar scan and actual writer",
	)
}

test_reference_prediction :: proc() {
	state: avc_enc.Encoder_State
	avc_enc.init_encoder(&state, {width = 64, height = 48, qp = 26, slice_count = 3})
	defer avc_enc.destroy_encoder(&state)
	source := &state.source
	assert(
		avc_enc.begin_encode_frame(
			&state,
			source.y,
			source.u,
			source.v,
			source.y_stride,
			source.uv_stride,
			true,
		) ==
		.None,
	)
	random_state: u32 = 0x5987DDEF
	buffer := &state.curr.buf
	for row in 0 ..< 48 do for column in 0 ..< 64 do buffer.y[row * buffer.y_stride + column] = u8(next_random(&random_state))
	h264.expand_picture(buffer)
	avc_enc.prepare_reference_interpolation_range(
		raw_data(state.slices),
		0,
		state.frame.num_slices,
	)
	for width in ([3]int{4, 8, 16}) do for height in ([3]int{4, 8, 16}) {
		for position in ([5][2]int{{0, 0}, {48, 32}, {16, 16}, {-50, -50}, {100, 100}}) do for horizontal in i16(0) ..< 4 do for vertical in i16(0) ..< 4 {
			expected, actual: [256]u8
			column := clamp(position[0], 2 - h264.PADDING_LENGTH, buffer.coded_width + h264.PADDING_LENGTH - width - 3)
			row := clamp(position[1], 2 - h264.PADDING_LENGTH, buffer.coded_height + h264.PADDING_LENGTH - height - 3)
			h264.mc_luma(&buffer.y[row * buffer.y_stride + column], buffer.y_stride, &expected[0], 16, horizontal, vertical, width, height)
			avc_enc.predict_reference_luma(state.curr, position[0], position[1], width, height, {horizontal, vertical}, &actual[0])
			assert(actual == expected)
			// Batched SATD must remain the sum of the existing independent blocks.
			scalar_sum: i32
			for by := 0; by < height; by += 4 do for bx := 0; bx < width; bx += 4 {
				scalar_sum += avc_enc.transformed_difference_block_4x4(&buffer.y[by * buffer.y_stride + bx], buffer.y_stride, &actual[by * 16 + bx], 16)
			}
			assert(avc_enc.block_transformed_difference_sum(buffer.y, buffer.y_stride, &actual[0], 16, width, height) == scalar_sum)
		}
	}
	fmt.println(
		"[SUCCESS] Reference half planes/quarter prediction and batched SATD: shapes, borders, all 16 fractions",
	)
}

main :: proc() {
	test_absolute_differences()
	test_intra_predictions()
	test_transform_quantization()
	test_coefficient_summary()
	test_baseline_dc_coefficients()
	test_dc_quantization_domain()
	test_baseline_low_qp_roundtrip()
	test_reference_prediction()
}

// Walk the original scan order and reduce only levels whose literal
// prefix-15 suffix would overflow. This deliberately finds the admitted value
// by testing successive magnitudes, independently of the production cap.
scalar_baseline_dc_levels :: proc(input: []i16) -> (expected: [16]i16) {
	copy(expected[:len(input)], input)
	count, trailing := 0, 0
	for value in input do if value != 0 do count += 1
	for position := len(input) - 1; position >= 0; position -= 1 {
		value := i32(input[position])
		if value == 0 do continue
		if abs(value) != 1 || trailing == 3 do break
		trailing += 1
	}
	suffix := count > 10 && trailing < 3 ? 1 : 0
	skipped, coded := 0, 0
	// The prefix-15 bases come from the decoder's suffix lengths 0..6.
	bases := [7]i32{30, 30, 60, 120, 240, 480, 960}
	for position := len(input) - 1; position >= 0; position -= 1 {
		value := i32(input[position])
		if value == 0 do continue
		if skipped < trailing {skipped += 1; continue}
		magnitude := abs(value)
		for {
			code := 2 * (magnitude - 1) + (value < 0 ? 1 : 0)
			if coded == 0 && trailing < 3 do code -= 2
			if code - bases[suffix] <= 4095 do break
			magnitude -= 1
		}
		expected[position] = i16(value < 0 ? -magnitude : magnitude)
		if suffix == 0 do suffix = 1
		if magnitude > 3 << uint(suffix - 1) && suffix < 6 do suffix += 1
		coded += 1
	}
	return
}

assert_cavlc_native_roundtrip :: proc(levels: []i16, neighbour_count: i8) {
	output := make([dynamic]u8)
	defer delete(output)
	writer := h264.init_bit_writer(&output)
	avc_enc.write_cavlc_block(&writer, levels, neighbour_count)
	written_bits := len(output) * 8 + writer.nbits
	assert(avc_enc.cavlc_coefficient_bit_count(levels, neighbour_count) == written_bits)
	h264.flush_bits_rbsp(&writer)
	reader := h264.init_bit_reader(output[:])
	total, trailing := avc_dec.cavlc_read_coeff_token(&reader, neighbour_count)
	decoded_descending: [16]i32
	avc_dec.cavlc_read_levels(&reader, int(total), int(trailing), decoded_descending[:])
	level_end := reader.bit_pos
	count := 0
	for position := len(levels) - 1; position >= 0; position -= 1 {
		if levels[position] != 0 {
			assert(decoded_descending[count] == i32(levels[position]))
			count += 1
		}
	}
	assert(count == int(total))
	zeros := 0
	if total != 0 && int(total) < len(levels) do zeros = avc_dec.cavlc_read_total_zeros(&reader, int(total), neighbour_count < 0)
	runs: [16]int
	decoded: [16]i16
	if total != 0 {
		avc_dec.cavlc_read_runs(&reader, int(total), zeros, runs[:])
		position := -1
		for index := int(total) - 1; index >= 0; index -= 1 {
			position += runs[index] + 1
			assert(position < len(levels))
			decoded[position] = i16(decoded_descending[index])
		}
	}
	for value, index in levels do assert(decoded[index] == value)
	assert(reader.bit_pos == written_bits)

	// Independently inspect each emitted prefix. Value roundtrip alone would
	// accept a wider escape even though our declared Baseline profile forbids it.
	baseline_reader := h264.init_bit_reader(output[:])
	_, trailing = avc_dec.cavlc_read_coeff_token(&baseline_reader, neighbour_count)
	h264.skip_bits(&baseline_reader, uint(trailing))
	suffix := total > 10 && trailing < 3 ? 1 : 0
	for index in int(trailing) ..< int(total) {
		prefix := 0
		for h264.read_bit(&baseline_reader) == 0 {prefix += 1; assert(prefix <= 15)}
		suffix_size := suffix
		if prefix == 14 && suffix == 0 do suffix_size = 4
		if prefix == 15 do suffix_size = 12
		if suffix_size != 0 do h264.skip_bits(&baseline_reader, uint(suffix_size))
		if suffix == 0 do suffix = 1
		if abs(decoded_descending[index]) > 3 << uint(suffix - 1) && suffix < 6 do suffix += 1
	}
	assert(baseline_reader.bit_pos == level_end)
}

test_baseline_dc_coefficients :: proc() {
	zero: [16]i16
	avc_enc.normalize_baseline_cavlc_dc_levels(zero[:])
	assert(zero == [16]i16{})
	assert_cavlc_native_roundtrip(zero[:], 0)
	ones: [4]i16 = {1, -1, 0, 1}
	avc_enc.normalize_baseline_cavlc_dc_levels(ones[:])
	assert(ones == [4]i16{1, -1, 0, 1})
	assert_cavlc_native_roundtrip(ones[:], -1)
	for sign in ([2]i32{-1, 1}) {
		for magnitude in ([9]i32{2063, 2064, 2065, 3251, 3264, 3277, 6528, 32767, 32768}) {
			if sign > 0 && magnitude == 32768 do continue
			levels: [16]i16
			levels[0] = i16(sign * magnitude)
			avc_enc.normalize_baseline_cavlc_dc_levels(levels[:])
			assert(levels[0] == i16(sign * min(magnitude, 2064)))
			assert_cavlc_native_roundtrip(levels[:], 0)
		}
		// Three trailing ones remove the first-level adjustment: limit 2063.
		trailing: [16]i16
		trailing[0], trailing[5], trailing[11], trailing[15] = i16(sign * 2064), 1, -1, 1
		avc_enc.normalize_baseline_cavlc_dc_levels(trailing[:])
		assert(trailing[0] == i16(sign * 2063))
		assert_cavlc_native_roundtrip(trailing[:], 0)
		for trailing_count in 1 ..< 3 {
			partial: [4]i16
			partial[0] = i16(sign * 2065)
			for index in 0 ..< trailing_count do partial[3 - index] = index == 0 ? i16(1) : i16(-1)
			avc_enc.normalize_baseline_cavlc_dc_levels(partial[:])
			assert(partial[0] == i16(sign * 2064))
			assert_cavlc_native_roundtrip(partial[:], -1)
		}
		// First magnitude 2 leaves suffixLength 1 for the next escape.
		second: [4]i16 = {i16(sign * 2065), 0, 0, 2}
		avc_enc.normalize_baseline_cavlc_dc_levels(second[:])
		assert(second[0] == i16(sign * 2063))
		assert_cavlc_native_roundtrip(second[:], -1)
		// More than ten coefficients start at suffixLength 1. Subsequent
		// emitted magnitudes advance through the exact limits of suffixes 2..6.
		full: [16]i16
		for &value in full do value = i16(sign * 32767)
		avc_enc.normalize_baseline_cavlc_dc_levels(full[:])
		limits := [6]i32{2064, 2078, 2108, 2168, 2288, 2528}
		for index in 0 ..< 16 do assert(full[15 - index] == i16(sign * limits[min(index, 5)]))
		assert_cavlc_native_roundtrip(full[:], 0)
	}
	random_state: u32 = 0x954EB731
	values := [22]i16 {
		-32768,
		-6528,
		-3277,
		-2065,
		-2064,
		-2063,
		-4,
		-3,
		-2,
		-1,
		0,
		1,
		2,
		3,
		4,
		2063,
		2064,
		2065,
		3251,
		3264,
		6528,
		32767,
	}
	for length in ([3]int{4, 15, 16}) do for _ in 0 ..< 96 {
		original: [16]i16
		for &value in original[:length] do value = values[next_random(&random_state) % u32(len(values))]
		expected := scalar_baseline_dc_levels(original[:length])
		actual := original
		before := avc_enc.summarize_cavlc_coefficients(original[:length])
		avc_enc.normalize_baseline_cavlc_dc_levels(actual[:length])
		after := avc_enc.summarize_cavlc_coefficients(actual[:length])
		assert(actual == expected)
		assert(before.nonzero_count == after.nonzero_count && before.trailing_one_count == after.trailing_one_count && before.trailing_sign_bits == after.trailing_sign_bits && before.zero_runs == after.zero_runs)
		for neighbour_count in ([5]i8{0, 2, 4, 8, 16}) do assert_cavlc_native_roundtrip(actual[:length], length == 4 ? i8(-1) : neighbour_count)
	}
	fmt.println(
		"[SUCCESS] Baseline DC escapes: exact conditional limits, scalar admission, native coefficients/runs, emitted prefixes and bit counts",
	)
}

test_dc_quantization_domain :: proc() {
	for qp in i32(0) ..< 52 do for intra in ([2]bool{false, true}) do for length in ([2]int{4, 16}) do for pattern in 0 ..< length do for sign in ([2]i32{-1, 1}) {
		dc: [16]i32
		for index in 0 ..< length {
			parity := 0
			for bit in 0 ..< 4 do parity += (index & pattern) >> uint(bit) & 1
			dc[index] = (parity & 1) == 0 ? sign * 4080 : -sign * 4080
		}
		transformed: [16]i32
		if length == 16 {
			transformed = avc_enc.forward_hadamard_4x4(&dc)
		} else {
			input := [4]i32{dc[0], dc[1], dc[2], dc[3]}
			result := avc_enc.forward_hadamard_2x2(input)
			copy(transformed[:4], result[:])
		}
		scan := length == 16 ? h264.zigzag_scan_4x4[:] : h264.chroma_dc_scan[:]
		raw: [16]i16
		shift := uint(16 + qp / 6)
		bias := (i32(1) << shift) / (intra ? 3 : 6)
		for index in 0 ..< length {
			coefficient := transformed[scan[index]]
			magnitude := (abs(coefficient) * avc_enc.quant_multiplier[qp % 6][0] + bias) >> shift
			raw[index] = i16(coefficient < 0 ? -magnitude : magnitude)
			if qp >= 10 do assert(magnitude <= 2040)
		}
		expected := scalar_baseline_dc_levels(raw[:length])
		actual: [16]i16
		nonzero := avc_enc.quantize_dc(transformed[:length], actual[:length], scan, qp, intra)
		assert(actual == expected)
		count := 0
		for value in expected[:length] do if value != 0 do count += 1
		assert(nonzero == count)
		assert_cavlc_native_roundtrip(actual[:length], length == 4 ? i8(-1) : i8(0))
	}
	fmt.println(
		"[SUCCESS] DC quantization: all 52 QPs, luma/chroma Hadamard extremes, intra/inter, native coefficient parity and QP10 bound",
	)
}

assert_same_reconstruction :: proc(expected, actual: ^h264.YUV_Buffer, width, height: int) {
	for row in 0 ..< height do for column in 0 ..< width do assert(expected.y[row * expected.y_stride + column] == actual.y[row * actual.y_stride + column])
	for row in 0 ..< height / 2 do for column in 0 ..< width / 2 {
		assert(expected.u[row * expected.uv_stride + column] == actual.u[row * actual.uv_stride + column])
		assert(expected.v[row * expected.uv_stride + column] == actual.v[row * actual.uv_stride + column])
	}
}

test_baseline_low_qp_roundtrip :: proc() {
	for qp in ([3]i32{0, 1, 5}) do for width in ([2]int{16, 32}) {
		encoder: avc_enc.Encoder_State
		avc_enc.init_encoder(&encoder, {width = width, height = width, qp = qp, slice_count = 1, disable_deblocking = true, exhaustive_intra = true})
		defer avc_enc.destroy_encoder(&encoder)
		decoder: avc_dec.Decoder_State
		avc_dec.init_decoder(&decoder)
		defer avc_dec.destroy_decoder(&decoder)
		source := h264.alloc_yuv_buffer(width, width)
		defer h264.free_yuv_buffer(&source)
		stream := make([dynamic]u8)
		defer delete(stream)
		for frame in 0 ..< 4 {
			for row in 0 ..< width do for column in 0 ..< width {
				last_macroblock := row >= width - 16 && column >= width - 16
				white := frame < 2 ? frame == 0 : frame == 2 ? last_macroblock : !last_macroblock
				source.y[row * source.y_stride + column] = white ? 255 : 0
			}
			for row in 0 ..< width / 2 do for column in 0 ..< width / 2 {
				last_macroblock := row >= width / 2 - 8 && column >= width / 2 - 8
				white := frame < 2 ? frame == 0 : frame == 2 ? last_macroblock : !last_macroblock
				source.u[row * source.uv_stride + column] = white ? 255 : 0
				source.v[row * source.uv_stride + column] = white ? 0 : 255
			}
			start := len(stream)
			assert(avc_enc.encode_frame(&encoder, source.y, source.u, source.v, source.y_stride, source.uv_stride, frame % 2 == 0, &stream) == .None)
			nals := h264.find_nal_units(stream[start:])
			defer delete(nals)
			decoded := 0
			for nal in nals {
				ready, err := avc_dec.decode_nal(&decoder, stream[start + nal.offset:start + nal.offset + nal.length])
				assert(err == .None)
				if ready {
					assert_same_reconstruction(&encoder.curr.buf, &decoder.output.buf, width, width)
					decoded += 1
					assert(avc_dec.next_output_frame(&decoder) == nil)
				}
			}
			if avc_dec.flush_decoder(&decoder) {
				assert_same_reconstruction(&encoder.curr.buf, &decoder.output.buf, width, width)
				decoded += 1
				assert(avc_dec.next_output_frame(&decoder) == nil)
			}
			assert(decoded == 1)
		}
	}
	fmt.println(
		"[SUCCESS] Baseline QP0/1/5: black/white and macroblock contrast, IDR/P, all-plane encoder/native reconstruction parity",
	)
}

test_absolute_differences :: proc() {
	random_state: u32 = 0x75363291
	for width in ([3]int{4, 8, 16}) do for height in ([3]int{4, 8, 16}) do for sample in 0 ..< 256 {
		source, prediction: [256]u8
		for &pixel in source do pixel = sample == 0 ? 255 : u8(next_random(&random_state))
		for &pixel in prediction do pixel = sample == 0 ? 0 : u8(next_random(&random_state))
		expected, squared: i32
		for row in 0 ..< height do for column in 0 ..< width {
			difference := i32(source[row * 16 + column]) - i32(prediction[row * 16 + column])
			expected += abs(difference)
			squared += difference * difference
		}
		assert(avc_enc.block_absolute_difference_sum(&source[0], 16, &prediction[0], 16, width, height) == expected)
		assert(avc_enc.block_squared_difference_sum(&source[0], 16, &prediction[0], 16, width, height) == squared)
	}
	fmt.println("[SUCCESS] SAD/SSD scalar parity, including full 16x16 contrast (SAD=65280)")
}

test_intra_predictions :: proc() {
	random_state: u32 = 0xF012876A
	for _ in 0 ..< 64 do for have_top in ([2]bool{false, true}) do for have_left in ([2]bool{false, true}) do for have_top_right in ([2]bool{false, true}) do for mode in h264.Intra_4x4_Mode {
		switch mode {
		case .DC:
		case .Vertical, .Diagonal_Down_Left, .Vertical_Left:
			if !have_top do continue
		case .Horizontal, .Horizontal_Up:
			if !have_left do continue
		case .Diagonal_Down_Right, .Vertical_Right, .Horizontal_Down:
			if !have_top || !have_left do continue
		}
		original: [16 * 16]u8
		for &pixel in original do pixel = u8(next_random(&random_state))
		expected, actual := original, original
		scalar_intra_4x4(&expected[4 * 16 + 4], 16, mode, have_top, have_left, have_top_right)
		h264.predict_intra_4x4(&actual[4 * 16 + 4], 16, mode, have_top, have_left, have_top_right)
		assert(actual == expected)
	}
	fmt.println("[SUCCESS] Intra4 register predictions: all modes, random edges, scalar oracle")
}

scalar_intra_4x4 :: proc(
	dst: [^]u8,
	stride: int,
	mode: h264.Intra_4x4_Mode,
	top_avail: bool,
	left_avail: bool,
	tr_avail: bool,
) #no_bounds_check {
	switch mode {
	case .Vertical:
		top: [^]u8 = &dst[-stride]
		for y in 0 ..< 4 {
			dst[y * stride + 0] = top[0]
			dst[y * stride + 1] = top[1]
			dst[y * stride + 2] = top[2]
			dst[y * stride + 3] = top[3]
		}

	case .Horizontal:
		for y in 0 ..< 4 {
			val := dst[y * stride - 1]
			dst[y * stride + 0] = val
			dst[y * stride + 1] = val
			dst[y * stride + 2] = val
			dst[y * stride + 3] = val
		}

	case .DC:
		val: u8 = 128
		if top_avail && left_avail {
			sum :=
				i32(dst[-stride + 0]) +
				i32(dst[-stride + 1]) +
				i32(dst[-stride + 2]) +
				i32(dst[-stride + 3])
			sum +=
				i32(dst[0 * stride - 1]) +
				i32(dst[1 * stride - 1]) +
				i32(dst[2 * stride - 1]) +
				i32(dst[3 * stride - 1])
			val = u8((sum + 4) >> 3)
		} else if top_avail {
			sum :=
				i32(dst[-stride + 0]) +
				i32(dst[-stride + 1]) +
				i32(dst[-stride + 2]) +
				i32(dst[-stride + 3])
			val = u8((sum + 2) >> 2)
		} else if left_avail {
			sum :=
				i32(dst[0 * stride - 1]) +
				i32(dst[1 * stride - 1]) +
				i32(dst[2 * stride - 1]) +
				i32(dst[3 * stride - 1])
			val = u8((sum + 2) >> 2)
		}
		for y in 0 ..< 4 {
			dst[y * stride + 0] = val
			dst[y * stride + 1] = val
			dst[y * stride + 2] = val
			dst[y * stride + 3] = val
		}

	case .Diagonal_Down_Left:
		top: [8]i32
		top[0] = i32(dst[-stride + 0])
		top[1] = i32(dst[-stride + 1])
		top[2] = i32(dst[-stride + 2])
		top[3] = i32(dst[-stride + 3])
		if tr_avail {
			top[4] = i32(dst[-stride + 4])
			top[5] = i32(dst[-stride + 5])
			top[6] = i32(dst[-stride + 6])
			top[7] = i32(dst[-stride + 7])
		} else {
			top[4] = top[3]
			top[5] = top[3]
			top[6] = top[3]
			top[7] = top[3]
		}
		d: [7]u8
		d[0] = u8((top[0] + 2 * top[1] + top[2] + 2) >> 2)
		d[1] = u8((top[1] + 2 * top[2] + top[3] + 2) >> 2)
		d[2] = u8((top[2] + 2 * top[3] + top[4] + 2) >> 2)
		d[3] = u8((top[3] + 2 * top[4] + top[5] + 2) >> 2)
		d[4] = u8((top[4] + 2 * top[5] + top[6] + 2) >> 2)
		d[5] = u8((top[5] + 2 * top[6] + top[7] + 2) >> 2)
		d[6] = u8((top[6] + 3 * top[7] + 2) >> 2)

		dst[0 * stride + 0] =
			d[0]; dst[0 * stride + 1] = d[1]; dst[0 * stride + 2] = d[2]; dst[0 * stride + 3] = d[3]
		dst[1 * stride + 0] =
			d[1]; dst[1 * stride + 1] = d[2]; dst[1 * stride + 2] = d[3]; dst[1 * stride + 3] = d[4]
		dst[2 * stride + 0] =
			d[2]; dst[2 * stride + 1] = d[3]; dst[2 * stride + 2] = d[4]; dst[2 * stride + 3] = d[5]
		dst[3 * stride + 0] =
			d[3]; dst[3 * stride + 1] = d[4]; dst[3 * stride + 2] = d[5]; dst[3 * stride + 3] = d[6]

	case .Diagonal_Down_Right:
		lt := i32(dst[-stride - 1])
		t0 := i32(dst[-stride + 0])
		t1 := i32(dst[-stride + 1])
		t2 := i32(dst[-stride + 2])
		t3 := i32(dst[-stride + 3])
		l0 := i32(dst[0 * stride - 1])
		l1 := i32(dst[1 * stride - 1])
		l2 := i32(dst[2 * stride - 1])
		l3 := i32(dst[3 * stride - 1])

		d: [7]u8
		d[0] = u8((l3 + 2 * l2 + l1 + 2) >> 2)
		d[1] = u8((l2 + 2 * l1 + l0 + 2) >> 2)
		d[2] = u8((l1 + 2 * l0 + lt + 2) >> 2)
		d[3] = u8((l0 + 2 * lt + t0 + 2) >> 2)
		d[4] = u8((lt + 2 * t0 + t1 + 2) >> 2)
		d[5] = u8((t0 + 2 * t1 + t2 + 2) >> 2)
		d[6] = u8((t1 + 2 * t2 + t3 + 2) >> 2)

		dst[0 * stride + 0] =
			d[3]; dst[0 * stride + 1] = d[4]; dst[0 * stride + 2] = d[5]; dst[0 * stride + 3] = d[6]
		dst[1 * stride + 0] =
			d[2]; dst[1 * stride + 1] = d[3]; dst[1 * stride + 2] = d[4]; dst[1 * stride + 3] = d[5]
		dst[2 * stride + 0] =
			d[1]; dst[2 * stride + 1] = d[2]; dst[2 * stride + 2] = d[3]; dst[2 * stride + 3] = d[4]
		dst[3 * stride + 0] =
			d[0]; dst[3 * stride + 1] = d[1]; dst[3 * stride + 2] = d[2]; dst[3 * stride + 3] = d[3]

	case .Vertical_Right:
		lt := i32(dst[-stride - 1])
		t0 := i32(dst[-stride + 0])
		t1 := i32(dst[-stride + 1])
		t2 := i32(dst[-stride + 2])
		t3 := i32(dst[-stride + 3])
		l0 := i32(dst[0 * stride - 1])
		l1 := i32(dst[1 * stride - 1])
		l2 := i32(dst[2 * stride - 1])

		vr0 := u8((1 + lt + t0) >> 1)
		vr1 := u8((1 + t0 + t1) >> 1)
		vr2 := u8((1 + t1 + t2) >> 1)
		vr3 := u8((1 + t2 + t3) >> 1)
		vr4 := u8((2 + l0 + 2 * lt + t0) >> 2)
		vr5 := u8((2 + lt + 2 * t0 + t1) >> 2)
		vr6 := u8((2 + t0 + 2 * t1 + t2) >> 2)
		vr7 := u8((2 + t1 + 2 * t2 + t3) >> 2)
		vr8 := u8((2 + lt + 2 * l0 + l1) >> 2)
		vr9 := u8((2 + l0 + 2 * l1 + l2) >> 2)

		dst[0 * stride + 0] =
			vr0; dst[0 * stride + 1] = vr1; dst[0 * stride + 2] = vr2; dst[0 * stride + 3] = vr3
		dst[1 * stride + 0] =
			vr4; dst[1 * stride + 1] = vr5; dst[1 * stride + 2] = vr6; dst[1 * stride + 3] = vr7
		dst[2 * stride + 0] =
			vr8; dst[2 * stride + 1] = vr0; dst[2 * stride + 2] = vr1; dst[2 * stride + 3] = vr2
		dst[3 * stride + 0] =
			vr9; dst[3 * stride + 1] = vr4; dst[3 * stride + 2] = vr5; dst[3 * stride + 3] = vr6

	case .Horizontal_Down:
		lt := i32(dst[-stride - 1])
		t0 := i32(dst[-stride + 0])
		t1 := i32(dst[-stride + 1])
		t2 := i32(dst[-stride + 2])
		l0 := i32(dst[0 * stride - 1])
		l1 := i32(dst[1 * stride - 1])
		l2 := i32(dst[2 * stride - 1])
		l3 := i32(dst[3 * stride - 1])

		tl0 := 1 + lt + l0
		lt0 := 1 + lt + t0
		t01 := 1 + t0 + t1
		t12 := 1 + t1 + t2
		l01 := 1 + l0 + l1
		l12 := 1 + l1 + l2
		l23 := 1 + l2 + l3

		hd0 := u8(tl0 >> 1)
		hd1 := u8((tl0 + lt0) >> 2)
		hd2 := u8((lt0 + t01) >> 2)
		hd3 := u8((t01 + t12) >> 2)
		hd4 := u8(l01 >> 1)
		hd5 := u8((tl0 + l01) >> 2)
		hd6 := u8(l12 >> 1)
		hd7 := u8((l01 + l12) >> 2)
		hd8 := u8(l23 >> 1)
		hd9 := u8((l12 + l23) >> 2)

		dst[0 * stride + 0] =
			hd0; dst[0 * stride + 1] = hd1; dst[0 * stride + 2] = hd2; dst[0 * stride + 3] = hd3
		dst[1 * stride + 0] =
			hd4; dst[1 * stride + 1] = hd5; dst[1 * stride + 2] = hd0; dst[1 * stride + 3] = hd1
		dst[2 * stride + 0] =
			hd6; dst[2 * stride + 1] = hd7; dst[2 * stride + 2] = hd4; dst[2 * stride + 3] = hd5
		dst[3 * stride + 0] =
			hd8; dst[3 * stride + 1] = hd9; dst[3 * stride + 2] = hd6; dst[3 * stride + 3] = hd7

	case .Vertical_Left:
		top: [8]i32
		top[0] = i32(dst[-stride + 0])
		top[1] = i32(dst[-stride + 1])
		top[2] = i32(dst[-stride + 2])
		top[3] = i32(dst[-stride + 3])
		if tr_avail {
			top[4] = i32(dst[-stride + 4])
			top[5] = i32(dst[-stride + 5])
			top[6] = i32(dst[-stride + 6])
			top[7] = i32(dst[-stride + 7])
		} else {
			top[4] = top[3]
			top[5] = top[3]
			top[6] = top[3]
			top[7] = top[3]
		}
		vl0 := u8((1 + top[0] + top[1]) >> 1)
		vl1 := u8((1 + top[1] + top[2]) >> 1)
		vl2 := u8((1 + top[2] + top[3]) >> 1)
		vl3 := u8((1 + top[3] + top[4]) >> 1)
		vl4 := u8((1 + top[4] + top[5]) >> 1)
		vl5 := u8((2 + top[0] + 2 * top[1] + top[2]) >> 2)
		vl6 := u8((2 + top[1] + 2 * top[2] + top[3]) >> 2)
		vl7 := u8((2 + top[2] + 2 * top[3] + top[4]) >> 2)
		vl8 := u8((2 + top[3] + 2 * top[4] + top[5]) >> 2)
		vl9 := u8((2 + top[4] + 2 * top[5] + top[6]) >> 2)

		dst[0 * stride + 0] =
			vl0; dst[0 * stride + 1] = vl1; dst[0 * stride + 2] = vl2; dst[0 * stride + 3] = vl3
		dst[1 * stride + 0] =
			vl5; dst[1 * stride + 1] = vl6; dst[1 * stride + 2] = vl7; dst[1 * stride + 3] = vl8
		dst[2 * stride + 0] =
			vl1; dst[2 * stride + 1] = vl2; dst[2 * stride + 2] = vl3; dst[2 * stride + 3] = vl4
		dst[3 * stride + 0] =
			vl6; dst[3 * stride + 1] = vl7; dst[3 * stride + 2] = vl8; dst[3 * stride + 3] = vl9

	case .Horizontal_Up:
		l0 := i32(dst[0 * stride - 1])
		l1 := i32(dst[1 * stride - 1])
		l2 := i32(dst[2 * stride - 1])
		l3 := i32(dst[3 * stride - 1])

		l01 := 1 + l0 + l1
		l12 := 1 + l1 + l2
		l23 := 1 + l2 + l3

		hu0 := u8(l01 >> 1)
		hu1 := u8((l01 + l12) >> 2)
		hu2 := u8(l12 >> 1)
		hu3 := u8((l12 + l23) >> 2)
		hu4 := u8(l23 >> 1)
		hu5 := u8((1 + l23 + 2 * l3) >> 2)
		l3_u8 := u8(l3)

		dst[0 * stride + 0] =
			hu0; dst[0 * stride + 1] = hu1; dst[0 * stride + 2] = hu2; dst[0 * stride + 3] = hu3
		dst[1 * stride + 0] =
			hu2; dst[1 * stride + 1] = hu3; dst[1 * stride + 2] = hu4; dst[1 * stride + 3] = hu5
		dst[2 * stride + 0] =
			hu4; dst[2 * stride + 1] = hu5; dst[2 * stride + 2] = l3_u8; dst[2 * stride + 3] = l3_u8
		dst[3 * stride + 0] =
			l3_u8; dst[3 * stride + 1] = l3_u8; dst[3 * stride + 2] = l3_u8; dst[3 * stride + 3] = l3_u8
	}
}

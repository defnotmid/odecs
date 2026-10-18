package common

import "core:math"
import "core:testing"

@(private)
pcm_test_oracle :: proc(value: f32) -> u16 {
	// This is the original CLI/harness expression. It does not use the
	// production clamp-before-round, signed-half bias or SIMD conversion.
	return u16(i16(clamp(math.round(f64(value) * 32768), -32768, 32767)))
}

@(private)
pcm_test_adjacent :: proc(value: f32, upper: bool) -> f32 {
	bits := transmute(u32)value
	if value == 0 {
		bits = upper ? 1 : 0x80000001
	} else if (value > 0) == upper {
		bits += 1
	} else {
		bits -= 1
	}
	return transmute(f32)bits
}

@(private)
pcm_test_matches :: proc(t: ^testing.T, input: []f32, output: []u8, label: string) {
	for value, index in input {
		want := pcm_test_oracle(value)
		got := u16(output[2 * index]) | u16(output[2 * index + 1]) << 8
		if got != want {
			testing.expectf(
				t,
				false,
				"%s sample %d bits=%08x: got %d wanted %d",
				label,
				index,
				transmute(u32)value,
				i16(got),
				i16(want),
			)
			return
		}
	}
}

@(test)
test_pcm_s16le_all_rounding_boundaries :: proc(t: ^testing.T) {
	// Every signed-16 half boundary and its immediately adjacent input f32
	// values. All these ties are exactly representable after scaling by 2^15.
	input := make([]f32, 65536 * 3)
	defer delete(input)
	output := make([]u8, 2 * len(input))
	defer delete(output)
	for level in -32768 ..< 32768 {
		tie := f32((f64(level) + 0.5) / 32768)
		index := 3 * (level + 32768)
		input[index] = pcm_test_adjacent(tie, false)
		input[index + 1] = tie
		input[index + 2] = pcm_test_adjacent(tie, true)
	}
	samples, err := pack_s16le(input, output)
	testing.expect_value(t, err, PCM_Error.None)
	testing.expect_value(t, samples, len(input))
	pcm_test_matches(t, input, output, "all half boundaries")
}

@(test)
test_pcm_s16le_finite_extremes_and_bit_patterns :: proc(t: ^testing.T) {
	SPECIAL_BITS := [?]u32 {
		0,
		0x80000000,
		1,
		0x80000001,
		0x007fffff,
		0x807fffff,
		0x00800000,
		0x80800000,
		0x7f7fffff,
		0xff7fffff,
		0x3f800000,
		0xbf800000,
		0x3f7fffff,
		0xbf7fffff,
		0x37800000,
		0xb7800000,
		0x377fffff,
		0xb77fffff,
	}
	input := make([]f32, 4096 + len(SPECIAL_BITS))
	defer delete(input)
	output := make([]u8, 2 * len(input))
	defer delete(output)
	for bits, i in SPECIAL_BITS do input[i] = transmute(f32)bits
	state: u32 = 0x947f2a63
	for &value in input[len(SPECIAL_BITS):] {
		state ~= state << 13; state ~= state >> 17; state ~= state << 5
		bits := state
		if bits & 0x7f800000 == 0x7f800000 do bits &~= 0x00800000
		value = transmute(f32)bits
	}
	samples, err := pack_s16le(input, output)
	testing.expect_value(t, err, PCM_Error.None)
	testing.expect_value(t, samples, len(input))
	pcm_test_matches(t, input, output, "finite bit patterns")
}

@(test)
test_pcm_s16le_lengths_alignment_and_capacity :: proc(t: ^testing.T) {
	GUARD :: u8(0xa7)
	input: [40]f32
	for &value, i in input do value = f32((i * 8191) % 98305 - 49152) / 32768
	output: [96]u8
	for count in 0 ..= 33 do for input_offset in 0 ..< 4 do for output_offset in 0 ..< 8 {
		for &byte in output do byte = GUARD
		source := input[input_offset:input_offset + count]
		// One extra byte checks that odd trailing capacity remains untouched.
		samples, err := pack_s16le(source, output[output_offset:output_offset + 2 * count + 1])
		testing.expect_value(t, err, PCM_Error.None)
		testing.expect_value(t, samples, count)
		pcm_test_matches(t, source, output[output_offset:], "length/alignment")
		for byte, i in output do if i < output_offset || i >= output_offset + 2 * count {
			testing.expectf(t, byte == GUARD, "PCM wrote outside active output: count=%d input_offset=%d output_offset=%d byte=%d", count, input_offset, output_offset, i)
		}
		if count == 0 do continue
		for &byte in output do byte = GUARD
		samples, err = pack_s16le(source, output[output_offset:output_offset + 2 * count - 1])
		testing.expect_value(t, err, PCM_Error.Output_Too_Small)
		testing.expect_value(t, samples, 0)
		for byte in output do testing.expect_value(t, byte, GUARD)
	}
	samples, err := pack_s16le(nil, nil)
	testing.expect_value(t, err, PCM_Error.None)
	testing.expect_value(t, samples, 0)
}

@(test)
test_pcm_s16le_first_nonfinite_preserves_prefix :: proc(t: ^testing.T) {
	GUARD :: u8(0x6d)
	BAD_BITS := [?]u32 {
		0x7f800000,
		0xff800000,
		0x7fc00000,
		0xffc00000,
		0x7f800001,
		0xff800001,
		0x7fffffff,
		0xffffffff,
	}
	input: [33]f32
	output: [70]u8
	for bad_bits in BAD_BITS do for first_bad in 0 ..< len(input) {
		for &value, i in input do value = f32(i - 17) / 19
		input[first_bad] = transmute(f32)bad_bits
		// A later bad sample must not replace the first rejection position.
		if first_bad + 1 < len(input) do input[first_bad + 1] = transmute(f32)u32(0x7f800000)
		for &byte in output do byte = GUARD
		samples, err := pack_s16le(input[:], output[1:67])
		testing.expect_value(t, err, PCM_Error.Non_Finite)
		testing.expect_value(t, samples, first_bad)
		pcm_test_matches(t, input[:first_bad], output[1:], "nonfinite prefix")
		for byte, index in output do if index == 0 || index >= 1 + 2 * first_bad {
			testing.expectf(t, byte == GUARD, "PCM changed rejected sample/tail: bad_bits=%08x first_bad=%d byte=%d", bad_bits, first_bad, index)
		}
		// Capacity admission takes precedence and leaves even the prefix alone.
		for &byte in output do byte = GUARD
		samples, err = pack_s16le(input[:], output[1:66])
		testing.expect_value(t, err, PCM_Error.Output_Too_Small)
		testing.expect_value(t, samples, 0)
		for byte in output do testing.expect_value(t, byte, GUARD)
	}
}

@(test)
test_to_i16_and_to_f32_per_stored_type :: proc(t: ^testing.T) {
	testing.expect_value(t, [3]i16{to_i16(u8(0)), to_i16(u8(128)), to_i16(u8(255))}, [3]i16{-32768, 0, 32512})
	testing.expect_value(t, [2]i16{to_i16(i8(-128)), to_i16(i8(127))}, [2]i16{-32768, 32512})
	testing.expect_value(t, [2]i16{to_i16(i16be(-2)), to_i16(i16le(7))}, [2]i16{-2, 7})
	// Wider integers round their dropped bits half away from zero and saturate.
	testing.expect_value(t, [4]i16{to_i16(I24{0x80, 0, 0}), to_i16(I24{0x80, 0xFF, 0xFF}), to_i16(I24{0x7F, 0, 0}), to_i16(I24be{0x7F, 0xFF, 0xFF})}, [4]i16{1, -1, 0, 32767})
	testing.expect_value(t, [3]i16{to_i16(i32be(min(i32))), to_i16(i32(0x7FFF_7FFF)), to_i16(i32(-0x8000))}, [3]i16{-32768, 32767, -1})
	// Floats: exact ties, the value just below a tie (where adding a half
	// rounds up in f64), saturation and NaN.
	below := 0.49999999999999994 / 32768
	testing.expect_value(t, [4]i16{to_i16(f32(0.5 / 32768)), to_i16(f64(-1.5 / 32768)), to_i16(below), to_i16(f64be(2))}, [4]i16{1, -2, 0, 32767})
	nan := transmute(f32)u32(0x7FC00000)
	testing.expect_value(t, [2]i16{to_i16(nan), to_i16(f32(-4))}, [2]i16{0, -32768})
	testing.expect_value(t, [4]f32{to_f32(u8(0)), to_f32(i16be(-16384)), to_f32(I24be{0x80, 0, 0}), to_f32(i32(min(i32)))}, [4]f32{-1, -0.5, -1, -1})
	testing.expect_value(t, [3]f32{to_f32(nan), to_f32(f64(3)), to_f32(f32be(-0.25))}, [3]f32{0, 1, -0.25})
}

@(test)
test_g711_expansion :: proc(t: ^testing.T) {
	// G.711 tables: mu-law 0x00 and 0x80 are the extremes, 0xFF and 0x7F
	// zero; A-law 0xD5 and 0x55 are the smallest steps.
	mu := [4]Mu_Law{0x00, 0x80, 0xFF, 0x7F}
	a := [4]A_Law{0xD5, 0x55, 0xAA, 0x2A}
	got_mu, got_a: [4]i16
	for v, i in mu do got_mu[i] = to_i16(v)
	for v, i in a do got_a[i] = to_i16(v)
	testing.expect_value(t, got_mu, [4]i16{-32124, 32124, 0, 0})
	testing.expect_value(t, got_a, [4]i16{8, -8, 32256, -32256})
	testing.expect_value(t, to_f32(Mu_Law(0x80)), 32124.0 / 32768)
}

@(test)
test_convert_pcm_keeps_leading_channels :: proc(t: ^testing.T) {
	// Three big-endian 16-bit channels; keep two; the output holds two frames
	// of the three in the data.
	data := [?]u8{0, 1, 0, 2, 0, 3, 0xFF, 0xFF, 0xFF, 0xFE, 0, 9, 0, 4, 0, 5, 0, 6}
	out: [4]i16
	testing.expect_value(t, convert_pcm(data[:], .I16be, 3, out[:], 2), 2)
	testing.expect_value(t, out, [4]i16{1, 2, -1, -2})
	x: [9]f32
	testing.expect_value(t, convert_pcm(data[:17], .I16be, 3, x[:], 3), 2) // the cut-off frame is left out
	testing.expect_value(t, x[3], -1.0 / 32768)
	testing.expect_value(t, convert_pcm(data[:], .I16, 3, out[:], 4), 0) // more channels than stored
}

@(test)
test_interleave_i32_i16 :: proc(t: ^testing.T) {
	l := []i32{-8388608, 128, 127}
	r := []i32{8388607, -128, -129}
	planes := [][]i32{l, r}
	out: [6]i16
	interleave_i32_i16(planes, 3, 24, out[:])
	testing.expect_value(t, out, [6]i16{-32768, 32767, 1, -1, 0, -1})
	narrow := []i32{-128, 127}
	interleave_i32_i16({narrow}, 2, 8, out[:2])
	testing.expect_value(t, [2]i16{out[0], out[1]}, [2]i16{-32768, 32512})
}

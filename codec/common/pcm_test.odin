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

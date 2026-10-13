package aac_encoder

import "core:math"
import "core:mem"
import "core:testing"

@(private)
band_test_scalar_statistics :: proc(values: []f64, initial: Band_Statistics) -> Band_Statistics {
	result := initial
	for sample in values {
		value := abs(sample)
		square := value * value
		result.energy += square
		result.fourth += square * square
		result.root += math.sqrt(value)
		result.peak = max(result.peak, value)
	}
	return result
}

@(test)
test_band_simd_statistics_preserves_order_and_guards :: proc(t: ^testing.T) {
	counts := [18]int{0, 1, 2, 3, 4, 5, 7, 8, 9, 12, 16, 20, 60, 120, 128, 256, 960, 1024}
	input: [1027]f64
	seed: u32 = 0x352cb93f
	for &value, i in input {
		seed = seed * 1664525 + 1013904223
		value = f64(i32(seed)) / 65536
		if i % 17 == 0 do value = i & 1 == 0 ? 0.0 : -0.0
		if i % 23 == 0 do value *= 1e-15
	}
	before := input
	initial := Band_Statistics {
		energy = 0.125,
		fourth = 0.25,
		root   = 0.5,
		peak   = 0.0625,
	}
	for count in counts {
		output: [1027]f64
		negative: [1027]bool
		for &value in output do value = -937.25
		for &value in negative do value = true
		stats := initial
		band_statistics_into(
			input[1:1 + count],
			output[2:2 + count],
			negative[2:2 + count],
			&stats,
		)
		want := band_test_scalar_statistics(input[1:1 + count], initial)
		testing.expect(t, stats == want)
		for i in 0 ..< count {
			power := math.pow(abs(input[1 + i]), 0.75)
			testing.expectf(
				t,
				abs(output[2 + i] - power) <= max(1.0, abs(power)) * 1e-12,
				"count%d sample%d power",
				count,
				i,
			)
			testing.expect_value(t, negative[2 + i], input[1 + i] < 0)
		}
		for value in output[:2] do testing.expect_value(t, value, f64(-937.25))
		for value in output[2 + count:] do testing.expect_value(t, value, f64(-937.25))
		for value in negative[:2] do testing.expect(t, value)
		for value in negative[2 + count:] do testing.expect(t, value)
		testing.expect(t, input == before)
	}
	// Split portions of one grouped band retain the exact cross-window sum.
	stats := initial
	output: [24]f64
	negative: [24]bool
	band_statistics_into(input[1:13], output[:12], negative[:12], &stats)
	band_statistics_into(input[13:25], output[12:], negative[12:], &stats)
	testing.expect(t, stats == band_test_scalar_statistics(input[1:25], initial))
}

@(test)
test_band_compander_matches_independent_power_domain :: proc(t: ^testing.T) {
	values: [2048]f64
	for &value, i in values {
		exponent := -1000 + i % 2000
		value = math.ldexp(1 + f64(i % 31) / 32, exponent)
	}
	values[0], values[1] = 0, 0h0000000000000001
	powers: [2048]f64
	negative: [2048]bool
	stats: Band_Statistics
	band_statistics_into(values[:], powers[:], negative[:], &stats)
	for value, i in values {
		want := math.pow(value, 0.75)
		testing.expectf(
			t,
			!math.is_nan(powers[i]) &&
			!math.is_inf(powers[i]) &&
			abs(powers[i] - want) <= abs(want) * 1e-12,
			"compander value%g got%g want%g",
			value,
			powers[i],
			want,
		)
	}
}

@(test)
test_band_simd_quantizer_exact_scalar_and_capacity :: proc(t: ^testing.T) {
	counts := [14]int{0, 1, 3, 4, 7, 8, 9, 12, 20, 60, 120, 128, 960, 1024}
	input: [1027]f64
	negative: [1027]bool
	seed: u32 = 0x91ce5a73
	for &value, i in input {
		seed = seed * 1664525 + 1013904223
		value = f64(seed & 0xfffff) / 37
		negative[i] = seed & 1 != 0
	}
	// Neighbors of integer boundaries and saturation distinguish a misplaced
	// bias, incorrect rounding, unsigned signs, and conversion before the clamp.
	for i in 0 ..< 24 {
		boundary := f64(i * 347) - 0.4054
		input[i + 1] = max(0.0, boundary + f64(i % 3 - 1) * 1e-9)
	}
	input[25], input[26], input[27] = 0, 8191 - 0.4054, 1e300
	before_input, before_negative := input, negative
	for sf in 0 ..< 256 {
		scale := math.pow(2.0, -3 * f64(sf - 100) / 16)
		for count in counts {
			output: [1027]i32
			for &value in output do value = -93917
			maximum := quantize_band_into(
				input[1:1 + count],
				negative[1:1 + count],
				output[2:2 + count],
				scale,
			)
			want_max := 0
			for i in 0 ..< count {
				q := i32(min(8191.0, math.floor(input[1 + i] * scale + 0.4054)))
				want := negative[1 + i] ? -q : q
				testing.expect_value(t, output[2 + i], want)
				want_max = max(want_max, int(q))
			}
			testing.expect_value(t, maximum, want_max)
			for value in output[:2] do testing.expect_value(t, value, i32(-93917))
			for value in output[2 + count:] do testing.expect_value(t, value, i32(-93917))
		}
	}
	testing.expect(t, input == before_input && negative == before_negative)
}

@(test)
test_band_simd_helpers_use_only_caller_storage :: proc(t: ^testing.T) {
	input := [12]f64{-35, 0, 7, -22, 17, 9, -13, 3, 4, -8, 1, 2}
	companded: [12]f64
	negative: [12]bool
	output: [12]i32
	stats: Band_Statistics
	allocator := context.allocator
	context.allocator = mem.nil_allocator()
	band_statistics_into(input[:], companded[:], negative[:], &stats)
	maximum := quantize_band_into(companded[:], negative[:], output[:], 1)
	context.allocator = allocator
	testing.expect(t, maximum > 0 && stats.energy > 0)
}

package aac_encoder

import "base:intrinsics"
import "core:simd"

@(private)
Band_Statistics :: struct {
	energy, fourth, root, peak: f64,
}

// The derivative and the compander share sqrt(abs(x)). The second square
// root and product evaluate abs(x)^(3/4) without a per-sample libm call.
// This order also avoids an intermediate x*sqrt(x) overflow or underflow.
@(private)
compand_magnitude :: #force_inline proc(value: $T) -> (root, companded: T) {
	root = intrinsics.sqrt(value)
	companded = root * intrinsics.sqrt(root)
	return
}

@(private)
band_statistics_lanes :: #force_inline proc(
	$Lanes: int,
	spectrum, companded: ^f64,
	negative: [^]bool,
	stats: ^Band_Statistics,
) {
	#assert(Lanes == 4 || Lanes == 8)
	V :: #simd[Lanes]f64
	values := intrinsics.unaligned_load((^V)(spectrum))
	magnitude := simd.abs(values)
	roots, powers := compand_magnitude(magnitude)
	squares := simd.mul(magnitude, magnitude)
	fourths := simd.mul(squares, squares)
	minus := simd.lanes_lt(values, V{})
	intrinsics.unaligned_store((^V)(companded), powers)
	#unroll for lane in 0 ..< Lanes {
		stats.energy += simd.extract(squares, lane)
		stats.fourth += simd.extract(fourths, lane)
		stats.root += simd.extract(roots, lane)
		stats.peak = max(stats.peak, simd.extract(magnitude, lane))
		negative[lane] = simd.extract(minus, lane) != 0
	}
}

// Each call owns one contiguous window portion of a grouped band. The caller
// retains its packed output and accumulates the same stats over all windows.
// Reductions keep the original scalar sample order, including a seeded sum.
@(private)
band_statistics_into :: proc(
	spectrum, companded: []f64,
	negative: []bool,
	stats: ^Band_Statistics,
) #no_bounds_check {
	assert(len(spectrum) == len(companded) && len(spectrum) == len(negative))
	vector_end := len(spectrum) &~ 7
	for i := 0; i < vector_end; i += 8 {
		band_statistics_lanes(8, &spectrum[i], &companded[i], ([^]bool)(&negative[i]), stats)
	}
	tail := vector_end
	if len(spectrum) - tail >= 4 {
		band_statistics_lanes(
			4,
			&spectrum[tail],
			&companded[tail],
			([^]bool)(&negative[tail]),
			stats,
		)
		tail += 4
	}
	for i in tail ..< len(spectrum) {
		value := abs(spectrum[i])
		root, power := compand_magnitude(value)
		square := value * value
		stats.energy += square
		stats.fourth += square * square
		stats.root += root
		stats.peak = max(stats.peak, value)
		companded[i], negative[i] = power, spectrum[i] < 0
	}
}

@(private)
quantize_band_lanes :: #force_inline proc(
	$Lanes: int,
	companded: ^f64,
	negative: [^]bool,
	output: ^i32,
	scale: f64,
) -> int {
	#assert(Lanes == 4 || Lanes == 8)
	V :: #simd[Lanes]f64
	I :: #simd[Lanes]i32
	values := intrinsics.unaligned_load((^V)(companded))
	magnitudes := I(simd.min(simd.add(simd.mul(values, V(scale)), V(0.4054)), V(8191)))
	minus: #simd[Lanes]bool
	#unroll for lane in 0 ..< Lanes do minus = simd.replace(minus, lane, negative[lane])
	result := simd.select(minus, simd.neg(magnitudes), magnitudes)
	intrinsics.unaligned_store((^I)(output), result)
	return int(simd.reduce_max(magnitudes))
}

// The magnitude and positive band scale make every converted value
// nonnegative. Truncation therefore equals floor; clamping before conversion
// keeps the admitted integer domain 0..8191. No floor/modf call is needed.
@(private)
quantize_band_into :: proc(
	companded: []f64,
	negative: []bool,
	output: []i32,
	scale: f64,
) -> int #no_bounds_check {
	assert(len(companded) == len(negative) && len(companded) == len(output))
	assert(scale > 0)
	vector_end := len(companded) &~ 7
	max_value := 0
	for i := 0; i < vector_end; i += 8 {
		max_value = max(
			max_value,
			quantize_band_lanes(8, &companded[i], ([^]bool)(&negative[i]), &output[i], scale),
		)
	}
	tail := vector_end
	if len(companded) - tail >= 4 {
		max_value = max(
			max_value,
			quantize_band_lanes(
				4,
				&companded[tail],
				([^]bool)(&negative[tail]),
				&output[tail],
				scale,
			),
		)
		tail += 4
	}
	for i in tail ..< len(companded) {
		q := i32(min(8191.0, companded[i] * scale + 0.4054))
		output[i] = negative[i] ? -q : q
		max_value = max(max_value, int(q))
	}
	return max_value
}

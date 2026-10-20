package aac

import "core:math"
import "core:slice"
import "core:testing"

// These oracles use the cosine definition, not transform scratch, twiddles,
// folding, or a forward/inverse round trip. Analysis and synthesis have
// independently generated inputs and the package's explicit normalization:
// X[k] = 2 sum_i x[i] cos(pi/N (i+(N+1)/2) (k+1/2))
// z[i] = (1/N) sum_k X[k] cos(pi/N (i+(N+1)/2) (k+1/2)).
@(private)
Transform_Test_Vector :: enum {
	Zero,
	DC,
	Impulse_Start,
	Impulse_Before_Middle,
	Impulse_Middle,
	Impulse_End,
	Alternating,
	Random,
	Cancellation,
}

@(private)
transform_test_add :: proc(sum, correction: ^f64, value: f64) {
	adjusted := value - correction^
	next := sum^ + adjusted
	correction^ = (next - sum^) - adjusted
	sum^ = next
}

@(private)
transform_test_random :: proc(state: ^u32) -> u32 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 17
	state^ ~= state^ << 5
	return state^
}

@(private)
transform_test_analysis_input :: proc(input: []f64, kind: Transform_Test_Vector) {
	n := len(input) / 2
	for &v in input do v = 0
	switch kind {
	case .Zero:
	case .DC:
		for &v in input do v = 32768
	case .Impulse_Start:
		input[0] = 65536
	case .Impulse_Before_Middle:
		input[n - 1] = -65536
	case .Impulse_Middle:
		input[n] = 49152
	case .Impulse_End:
		input[2 * n - 1] = -49152
	case .Alternating:
		for &v, i in input do v = i & 1 == 0 ? 65536 : -65536
	case .Random:
		state: u32 = 0x958731d5
		for &v in input do v = f64(i32(transform_test_random(&state) % 131073) - 65536)
	case .Cancellation:
		// On the first N samples the paired cosines have opposite signs;
		// on the second N they are equal. These pairs lie in the MDCT nullspace.
		for i in 0 ..< n / 2 {
			a := f64((i * 7919) % 131073 - 65536)
			b := f64((i * 6151 + 32768) % 131073 - 65536)
			input[i], input[n - 1 - i] = a, a
			input[n + i], input[2 * n - 1 - i] = b, -b
		}
	}
}

@(private)
transform_test_synthesis_input :: proc(spectrum: []f64, kind: Transform_Test_Vector) {
	n := len(spectrum)
	for &v in spectrum do v = 0
	switch kind {
	case .Zero:
	case .DC:
		for &v in spectrum do v = -7.5e6
	case .Impulse_Start:
		spectrum[0] = -1e7
	case .Impulse_Before_Middle:
		spectrum[n / 2 - 1] = 1e7
	case .Impulse_Middle:
		spectrum[n / 2] = -6.25e6
	case .Impulse_End:
		spectrum[n - 1] = 8.75e6
	case .Alternating:
		for &v, k in spectrum do v = k & 1 == 0 ? -1e7 : 1e7
	case .Random:
		state: u32 = 0x3159cae7
		for &v in spectrum do v = f64(i32(transform_test_random(&state) % 20000001) - 10000000)
	case .Cancellation:
		// Opposing adjacent coefficients exercise cancellation with a different
		// vector and scale from the analysis nullspace input.
		for k in 0 ..< n / 2 {
			v := f64((k * 13007 + 65537) % 10000001)
			spectrum[2 * k], spectrum[2 * k + 1] = v, -v
		}
	}
}

@(private)
transform_test_analysis_bin :: proc(input: []f64, k: int) -> f64 {
	n := len(input) / 2
	sum, correction: f64
	for v, i in input {
		if v == 0 do continue
		angle := math.PI / f64(n) * (f64(i) + f64(n + 1) / 2) * (f64(k) + 0.5)
		transform_test_add(&sum, &correction, v * math.cos(angle))
	}
	return 2 * sum
}

@(private)
transform_test_synthesis_sample :: proc(spectrum: []f64, i: int) -> f64 {
	n := len(spectrum)
	sum, correction: f64
	for v, k in spectrum {
		if v == 0 do continue
		angle := math.PI / f64(n) * (f64(i) + f64(n + 1) / 2) * (f64(k) + 0.5)
		transform_test_add(&sum, &correction, v * math.cos(angle))
	}
	return sum / f64(n)
}

@(private)
transform_test_norm :: proc(values: []f64) -> f64 {
	norm: f64
	for v in values do norm += abs(v)
	return norm
}

@(private)
transform_test_close :: proc(
	t: ^testing.T,
	got, want, scale: f64,
	operation: string,
	n, index: int,
	kind: Transform_Test_Vector,
) {
	// The direct cosine grid forms large arguments independently of the FFT.
	// Bound its rounding allowance by the input L1 norm, including the stated
	// transform normalization; cancellation does not get a relative-only test.
	tolerance := max(1e-9, 5e-12 * scale)
	testing.expectf(
		t,
		!math.is_nan(got) && !math.is_inf(got) && abs(got - want) <= tolerance,
		"%s N=%d %v index=%d: got %.17g expected %.17g tolerance %.3g",
		operation,
		n,
		kind,
		index,
		got,
		want,
		tolerance,
	)
}

@(test)
test_mdct_independent_cosine_grid :: proc(t: ^testing.T) {
	plan: Transform
	init_transform(&plan)
	input: [2048]f64
	actual: [1024]f64
	for n in ([2]int{128, 1024}) {
		for kind in ([9]Transform_Test_Vector{.Zero, .DC, .Impulse_Start, .Impulse_Before_Middle, .Impulse_Middle, .Impulse_End, .Alternating, .Random, .Cancellation}) {
			transform_test_analysis_input(input[:2 * n], kind)
			mdct(&plan, input[:2 * n], actual[:n])
			scale := 2 * transform_test_norm(input[:2 * n])
			all_bins :=
				n == 128 || kind == .Zero || (kind >= .Impulse_Start && kind <= .Impulse_End)
			if all_bins {
				for k in 0 ..< n do transform_test_close(t, actual[k], transform_test_analysis_bin(input[:2 * n], k), scale, "MDCT", n, k, kind)
			} else {
				for k in ([14]int{0, 1, 2, 7, n / 8 - 1, n / 8, n / 4 - 1, n / 4, n / 2 - 1, n / 2, 3 * n / 4 - 1, 3 * n / 4, n - 2, n - 1}) {
					transform_test_close(
						t,
						actual[k],
						transform_test_analysis_bin(input[:2 * n], k),
						scale,
						"MDCT",
						n,
						k,
						kind,
					)
				}
			}
			if kind == .Cancellation {
				for k in 0 ..< n do transform_test_close(t, actual[k], 0, scale, "MDCT nullspace", n, k, kind)
			}
		}
	}
}

@(test)
test_imdct_independent_cosine_grid :: proc(t: ^testing.T) {
	plan: Transform
	init_transform(&plan)
	spectrum: [1024]f64
	actual: [2048]f64
	for n in ([2]int{128, 1024}) {
		for kind in ([9]Transform_Test_Vector{.Zero, .DC, .Impulse_Start, .Impulse_Before_Middle, .Impulse_Middle, .Impulse_End, .Alternating, .Random, .Cancellation}) {
			transform_test_synthesis_input(spectrum[:n], kind)
			imdct(&plan, spectrum[:n], actual[:2 * n])
			scale := transform_test_norm(spectrum[:n]) / f64(n)
			all_samples :=
				n == 128 ||
				kind == .Zero ||
				kind == .Random ||
				(kind >= .Impulse_Start && kind <= .Impulse_End)
			if all_samples {
				for i in 0 ..< 2 * n do transform_test_close(t, actual[i], transform_test_synthesis_sample(spectrum[:n], i), scale, "IMDCT", n, i, kind)
			} else {
				for i in ([14]int{0, 1, 2, 7, n / 4 - 1, n / 4, n / 2 - 1, n / 2, n - 1, n, 3 * n / 2 - 1, 3 * n / 2, 2 * n - 2, 2 * n - 1}) {
					transform_test_close(
						t,
						actual[i],
						transform_test_synthesis_sample(spectrum[:n], i),
						scale,
						"IMDCT",
						n,
						i,
						kind,
					)
				}
			}
		}
	}
}

// Keep the former scalar scatter order as an exact post-rotation oracle. Its
// two index domains are independent of the paired contiguous region mapping.
@(private)
transform_test_scalar_unfold :: proc(plan: ^Transform, n: int, output: []f64) {
	m := n / 2
	wr := n == 128 ? plan.short_rotate[0][:] : plan.long_rotate[0][:]
	wi := n == 128 ? plan.short_rotate[1][:] : plan.long_rotate[1][:]
	scale := 1 / f64(n)
	for j in 0 ..< m / 2 {
		a, b := plan.scratch[0][j], plan.scratch[1][j]
		even := (a * wr[j] - b * wi[j]) * scale
		odd := -(a * wi[j] + b * wr[j]) * scale
		output[3 * m - 1 - 2 * j], output[3 * m + 2 * j] = -even, -even
		output[m - 1 - 2 * j], output[m + 2 * j] = odd, -odd
	}
	for j in m / 2 ..< m {
		a, b := plan.scratch[0][j], plan.scratch[1][j]
		even := (a * wr[j] - b * wi[j]) * scale
		odd := -(a * wi[j] + b * wr[j]) * scale
		output[2 * j - m], output[3 * m - 1 - 2 * j] = even, -even
		output[m + 2 * j], output[5 * m - 1 - 2 * j] = -odd, -odd
	}
}

@(private)
transform_test_unfold_plan :: proc(plan: ^Transform, n, kind: int) {
	wr := n == 128 ? plan.short_rotate[0][:] : plan.long_rotate[0][:]
	wi := n == 128 ? plan.short_rotate[1][:] : plan.long_rotate[1][:]
	negative_zero := transmute(f64)u64(0x8000_0000_0000_0000)
	rotation := [8]f64{0, negative_zero, 1, -1, 0.5, -0.5, 1e-20, -1e-20}
	for j in 0 ..< n / 2 {
		wr[j], wi[j] = rotation[j % 8], rotation[(3 * j + 1) % 8]
		if kind == 0 {
			plan.scratch[0][j] = j % 2 == 0 ? 0 : negative_zero
			plan.scratch[1][j] = j % 4 < 2 ? negative_zero : 0
		} else if kind == 1 {
			plan.scratch[0][j] = f64((j * 127 + 17) % 509 - 254) / 8
			plan.scratch[1][j] = f64((j * 73 + 3) % 257 - 128) / 16
		} else {
			wr[j], wi[j] = 0.5, 0.5
			plan.scratch[0][j] = f64(j - n / 4)
			plan.scratch[1][j] = plan.scratch[0][j]
		}
	}
}

@(test)
test_unfold_paired_regions_exact_scalar_and_guards :: proc(t: ^testing.T) {
	for n in ([2]int{128, 1024}) {
		for kind in 0 ..< 3 {
			plan: Transform
			transform_test_unfold_plan(&plan, n, kind)
			actual, expected: [2064]f64
			for i in 0 ..< len(actual) {
				actual[i] = f64(i * 19 + 7) / 16
				expected[i] = actual[i]
			}
			transform_test_scalar_unfold(&plan, n, expected[7:7 + 2 * n])
			unfold_dct(&plan, n, actual[7:7 + 2 * n])
			for i in 0 ..< len(actual) {
				testing.expectf(
					t,
					transmute(u64)actual[i] == transmute(u64)expected[i],
					"unfold N=%d kind=%d padded index=%d got=%016x expected=%016x",
					n,
					kind,
					i,
					transmute(u64)actual[i],
					transmute(u64)expected[i],
				)
			}
		}
	}
}

@(test)
test_unfold_transform_overlap_preserves_scalar_order :: proc(t: ^testing.T) {
	for n in ([2]int{128, 1024}) {
		actual_plan: Transform
		transform_test_unfold_plan(&actual_plan, n, 1)
		expected_plan := actual_plan
		// The full output fits in Transform's scratch + window storage. This
		// deliberately aliases live scratch so a reordered SIMD path would fail.
		actual := slice.from_ptr(&actual_plan.scratch[0][0], 2 * n)
		expected := slice.from_ptr(&expected_plan.scratch[0][0], 2 * n)
		transform_test_scalar_unfold(&expected_plan, n, expected)
		unfold_dct(&actual_plan, n, actual)
		actual_bits := slice.from_ptr(cast(^u64)(&actual_plan), size_of(Transform) / size_of(u64))
		expected_bits := slice.from_ptr(
			cast(^u64)(&expected_plan),
			size_of(Transform) / size_of(u64),
		)
		for i in 0 ..< len(actual_bits) {
			testing.expectf(
				t,
				actual_bits[i] == expected_bits[i],
				"aliased unfold N=%d transform word=%d got=%016x expected=%016x",
				n,
				i,
				actual_bits[i],
				expected_bits[i],
			)
		}
	}
}

// Isolate Long publication from the separately checked IMDCT. This is the
// former scalar equation and exact load/output/history write order, including
// the observable effect of aliases on later window or overlap reads.
@(private)
transform_test_scalar_long :: proc(
	$Stride: int,
	plan: ^Transform,
	bank: ^Filterbank,
	shape: u8,
	spectrum: []f64,
	output: []f32,
) {
	block: [2048]f64 = ---
	imdct(plan, spectrum, block[:])
	for i in 0 ..< 1024 {
		left := plan.long_window[bank.previous_shape][i]
		right := plan.long_window[shape][1023 - i]
		output[i * Stride] = f32((block[i] * left + bank.overlap[i]) / 32768)
		bank.overlap[i] = block[1024 + i] * right
	}
	bank.previous_shape = shape
}

@(private)
Transform_Test_Alias_Plan :: struct {
	prefix: [8]u64,
	plan:   Transform,
	suffix: [8]u64,
}
@(private)
Transform_Test_Alias_Bank :: struct {
	prefix: [8]u64,
	bank:   Filterbank,
	suffix: [8]u64,
}

@(private)
transform_test_alias_words :: proc(storage: rawptr, bytes: int) -> []u64 {
	return slice.from_ptr(cast(^u64)storage, bytes / size_of(u64))
}

@(private)
transform_test_compare_alias_words :: proc(
	t: ^testing.T,
	actual, expected: []u64,
	stride, family, placement: int,
	previous, shape: u8,
	storage: string,
) {
	for value, i in expected {
		testing.expectf(
			t,
			actual[i] == value,
			"Long alias stride=%d family=%d placement=%d previous=%d shape=%d %s word=%d got=%016x expected=%016x",
			stride,
			family,
			placement,
			previous,
			shape,
			storage,
			i,
			actual[i],
			value,
		)
	}
}

@(private)
transform_test_long_alias_cases :: proc($Stride: int, t: ^testing.T) {
	#assert(size_of(Transform_Test_Alias_Plan) % size_of(u64) == 0)
	#assert(size_of(Transform_Test_Alias_Bank) % size_of(u64) == 0)
	actual_plan, expected_plan := new(Transform_Test_Alias_Plan), new(Transform_Test_Alias_Plan)
	actual_bank, expected_bank := new(Transform_Test_Alias_Bank), new(Transform_Test_Alias_Bank)
	defer free(actual_plan)
	defer free(expected_plan)
	defer free(actual_bank)
	defer free(expected_bank)
	actual_plan_words := transform_test_alias_words(
		actual_plan,
		size_of(Transform_Test_Alias_Plan),
	)
	expected_plan_words := transform_test_alias_words(
		expected_plan,
		size_of(Transform_Test_Alias_Plan),
	)
	actual_bank_words := transform_test_alias_words(
		actual_bank,
		size_of(Transform_Test_Alias_Bank),
	)
	expected_bank_words := transform_test_alias_words(
		expected_bank,
		size_of(Transform_Test_Alias_Bank),
	)
	spectrum: [1024]f64
	transform_test_synthesis_input(spectrum[:], .Random)
	actual_output, expected_output: [2064]f32
	count :: 1023 * Stride + 1
	for family in 0 ..< 3 {
		for placement in 0 ..< 2 {
			for previous in u8(0) ..< 2 {
				for shape in u8(0) ..< 2 {
					// Initialize padding/guards as well as fields before cloning.
					for &word, i in actual_plan_words do word = 0x3ff0_0000_0000_0000 | u64(i * 37 + 11)
					for &word, i in actual_bank_words do word = 0x3ff0_0000_0000_0000 | u64(i * 19 + 7)
					init_transform(&actual_plan.plan)
					got_bank := &actual_bank.bank
					if family == 2 {
						// A shifted bank also changes the next left-window value when
						// history is published, discriminating an eight-row preload.
						got_bank = cast(^Filterbank)(&actual_plan.plan.long_window[0][placement])
					}
					got_bank.previous_shape = previous
					for &v, i in got_bank.overlap do v = f64((i * 73 + 17) % 257 - 128) / 8
					copy(expected_plan_words, actual_plan_words)
					copy(expected_bank_words, actual_bank_words)
					want_bank := &expected_bank.bank
					if family == 2 do want_bank = cast(^Filterbank)(&expected_plan.plan.long_window[0][placement])
					for &v, i in actual_output do v = f32(4096 + f64(i) / 8)
					expected_output = actual_output
					got, want := actual_output[3:3 + count], expected_output[3:3 + count]
					switch family {
					case 0:
						// Output overlaps bank, on either side of its start.
						if placement == 0 {
							got = slice.from_ptr(cast(^f32)(&actual_bank.prefix[7]), count + 1)[1:]
							want = slice.from_ptr(
								cast(^f32)(&expected_bank.prefix[7]),
								count + 1,
							)[1:]
						} else {
							got = slice.from_ptr(cast(^f32)(&got_bank.overlap[1]), count)
							want = slice.from_ptr(cast(^f32)(&want_bank.overlap[1]), count)
						}
					case 1:
						// Output overlaps live Long windows and their preceding word.
						if placement == 0 {
							got = slice.from_ptr(
								cast(^f32)(&actual_plan.plan.scratch[1][511]),
								count + 1,
							)[1:]
							want = slice.from_ptr(
								cast(^f32)(&expected_plan.plan.scratch[1][511]),
								count + 1,
							)[1:]
						} else {
							got = slice.from_ptr(
								cast(^f32)(&actual_plan.plan.long_window[0][1]),
								count,
							)
							want = slice.from_ptr(
								cast(^f32)(&expected_plan.plan.long_window[0][1]),
								count,
							)
						}
					case 2: // Bank overlaps Transform; output remains disjoint.
					}
					transform_test_scalar_long(
						Stride,
						&expected_plan.plan,
						want_bank,
						shape,
						spectrum[:],
						want,
					)
					synthesize_to(
						Stride,
						&actual_plan.plan,
						got_bank,
						.Long,
						shape,
						spectrum[:],
						got,
					)
					transform_test_compare_alias_words(
						t,
						actual_plan_words,
						expected_plan_words,
						Stride,
						family,
						placement,
						previous,
						shape,
						"Transform",
					)
					transform_test_compare_alias_words(
						t,
						actual_bank_words,
						expected_bank_words,
						Stride,
						family,
						placement,
						previous,
						shape,
						"bank",
					)
					for value, i in expected_output {
						testing.expectf(
							t,
							transmute(u32)actual_output[i] == transmute(u32)value,
							"Long alias stride=%d family=%d placement=%d previous=%d shape=%d output slot=%d",
							Stride,
							family,
							placement,
							previous,
							shape,
							i,
						)
					}
				}
			}
		}
	}
}

@(test)
test_synthesis_long_aliases_preserve_scalar_publication_order :: proc(t: ^testing.T) {
	transform_test_long_alias_cases(1, t)
	transform_test_long_alias_cases(2, t)
}

// I0(v) = (1/pi) integral_0^pi exp(v cos(theta)) dtheta. A 128-point
// midpoint quadrature evaluates this independent definition; production uses
// a power series. The largest argument here is 6*pi, safely finite in f64.
@(private)
transform_test_bessel_i0 :: proc(v: f64) -> f64 {
	sum, correction: f64
	for i in 0 ..< 128 {
		angle := math.PI * (f64(i) + 0.5) / 128
		transform_test_add(&sum, &correction, math.exp(v * math.cos(angle)))
	}
	return sum / 128
}

@(private)
Transform_Test_Windows :: struct {
	long:  [2][1024]f64,
	short: [2][128]f64,
}

@(private)
transform_test_window_definitions :: proc(windows: ^Transform_Test_Windows) {
	for n in ([2]int{128, 1024}) {
		sine := n == 128 ? windows.short[0][:] : windows.long[0][:]
		kbd := n == 128 ? windows.short[1][:] : windows.long[1][:]
		alpha := n == 128 ? 6.0 : 4.0
		kernel: [1025]f64
		total, total_correction: f64
		for i in 0 ..= n {
			x := 2 * f64(i) / f64(n) - 1
			kernel[i] = transform_test_bessel_i0(math.PI * alpha * math.sqrt(max(0, 1 - x * x)))
			transform_test_add(&total, &total_correction, kernel[i])
		}
		cumulative, correction: f64
		for i in 0 ..< n {
			sine[i] = math.sin(math.PI * (f64(i) + 0.5) / f64(2 * n))
			transform_test_add(&cumulative, &correction, kernel[i])
			kbd[i] = math.sqrt(cumulative / total)
		}
	}
}

@(test)
test_transform_independent_window_definitions :: proc(t: ^testing.T) {
	plan: Transform
	init_transform(&plan)
	windows: Transform_Test_Windows
	transform_test_window_definitions(&windows)
	for shape in 0 ..< 2 {
		for i in 0 ..< 1024 {
			testing.expectf(
				t,
				abs(plan.long_window[shape][i] - windows.long[shape][i]) <= 3e-13,
				"long window shape=%d sample=%d",
				shape,
				i,
			)
		}
		for i in 0 ..< 128 {
			testing.expectf(
				t,
				abs(plan.short_window[shape][i] - windows.short[shape][i]) <= 3e-13,
				"short window shape=%d sample=%d",
				shape,
				i,
			)
		}
	}
}

@(private)
transform_test_long_envelope :: proc(
	w: ^Transform_Test_Windows,
	sequence: Window_Sequence,
	previous, current: u8,
	sample: int,
) -> f64 {
	// Global support of the long/start/stop windows in the 2048-sample block.
	if sample < 1024 {
		if sequence != .Stop do return w.long[previous][sample]
		if sample < 448 do return 0
		if sample < 576 do return w.short[previous][sample - 448]
		return 1
	}
	if sequence != .Start do return w.long[current][2047 - sample]
	if sample < 1472 do return 1
	if sample < 1600 do return w.short[current][1599 - sample]
	return 0
}

@(private)
transform_test_windowed_sample :: proc(
	w: ^Transform_Test_Windows,
	sequence: Window_Sequence,
	previous, current: u8,
	spectrum: []f64,
	sample: int,
) -> f64 {
	if sequence != .Short {
		return(
			transform_test_synthesis_sample(spectrum, sample) *
			transform_test_long_envelope(w, sequence, previous, current, sample) \
		)
	}
	// Short blocks are independent 256-sample functions with global origins
	// 448+128*b. Sum the functions covering this sample, rather than creating
	// and writing eight intermediate blocks as the production filterbank does.
	value: f64
	for b in 0 ..< 8 {
		local := sample - (448 + 128 * b)
		if local < 0 || local >= 256 do continue
		left_shape := b == 0 ? previous : current
		envelope := local < 128 ? w.short[left_shape][local] : w.short[current][255 - local]
		value += transform_test_synthesis_sample(spectrum[b * 128:(b + 1) * 128], local) * envelope
	}
	return value
}

@(private)
transform_test_filterbank_spectrum :: proc(
	spectrum: []f64,
	sequence: Window_Sequence,
	frame: int,
) {
	for &v in spectrum do v = 0
	if frame >= 12 do return // Two zero blocks test the overlap drain.
	if sequence == .Short {
		for b in 0 ..< 8 {
			spectrum[b * 128] = f64((b + frame) % 3 - 1) * 1e7
			spectrum[b * 128 + 1 + (b * 17 + frame * 7) % 126] = f64((b * 3 + frame) % 7 - 3) * 2e6
			spectrum[b * 128 + 127] = f64((b * 5 + frame) % 5 - 2) * 3e6
		}
	} else {
		for k, i in ([12]int{0, 1, 3, 17, 127, 255, 511, 512, 767, 1000, 1022, 1023}) {
			spectrum[k] = f64((i * 17 + frame * 13) % 23 - 11) * (1e7 / 11)
		}
	}
}

@(test)
test_filterbank_direct_equations_and_overlap_transitions :: proc(t: ^testing.T) {
	plan: Transform
	init_transform(&plan)
	windows: Transform_Test_Windows
	transform_test_window_definitions(&windows)
	sequences := [14]Window_Sequence {
		.Long,
		.Long,
		.Start,
		.Short,
		.Short,
		.Stop,
		.Long,
		.Start,
		.Short,
		.Stop,
		.Long,
		.Long,
		.Long,
		.Long,
	}
	shapes := [14]u8{0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 1}
	for initial in u8(0) ..< 2 {
		bank := Filterbank {
			previous_shape = initial,
		}
		history: [1024]f64
		// A nonzero initial tail proves that history is consumed exactly once.
		for &v, i in history do v = f64((i * 997) % 16385 - 8192)
		bank.overlap = history
		strided_banks: [2]Filterbank
		strided_history: [2][1024]f64
		for ch in 0 ..< 2 {
			strided_banks[ch].previous_shape = initial
			for &v, i in strided_history[ch] do v = history[i] + f64((ch + 1) * (i % 17) * 31 - ch * 1024)
			strided_banks[ch].overlap = strided_history[ch]
		}
		previous := initial
		for sequence, frame in sequences {
			shape := shapes[frame] ~ initial
			spectrum: [1024]f64
			transform_test_filterbank_spectrum(spectrum[:], sequence, frame)
			block: [2048]f64
			for &v, sample in block do v = transform_test_windowed_sample(&windows, sequence, previous, shape, spectrum[:], sample)
			actual: [1032]f32
			for &v in actual do v = 123.5
			synthesize(&plan, &bank, sequence, shape, spectrum[:], actual[:])
			scale := transform_test_norm(spectrum[:]) / 128
			for i in 0 ..< 1024 {
				want := f32((block[i] + history[i]) / 32768)
				tolerance := 8e-7 * max(1, abs(f64(want)))
				testing.expectf(
					t,
					!math.is_nan(actual[i]) &&
					!math.is_inf(actual[i]) &&
					abs(f64(actual[i]) - f64(want)) <= tolerance,
					"filterbank initial=%d frame=%d %v shape=%d output=%d got %.9g expected %.9g",
					initial,
					frame,
					sequence,
					shape,
					i,
					actual[i],
					want,
				)
				transform_test_close(
					t,
					bank.overlap[i],
					block[1024 + i],
					scale,
					"filterbank history",
					1024,
					i,
					.Random,
				)
				history[i] = block[1024 + i]
			}
			for v in actual[1024:] do testing.expect_value(t, v, f32(123.5))
			testing.expect_value(t, bank.previous_shape, shape)
			// Both interleaved channel offsets are compared to the independent
			// cosine/window block and their own seeded overlap, not mono output.
			// Exact minimum-length slices and nonuniform guards detect writes to
			// the other channel, the leading guard, and the trailing allocation.
			prefix :: 5
			strided: [2064]f32
			for &v, i in strided do v = f32(512 + f64(i) / 4)
			for slot in 0 ..< 2 {
				ch := (frame + slot) & 1 // Alternate which channel writes first.
				before := strided
				synthesize_to(
					2,
					&plan,
					&strided_banks[ch],
					sequence,
					shape,
					spectrum[:],
					strided[prefix + ch:prefix + ch + 2047],
				)
				for i in 0 ..< 1024 {
					index := prefix + ch + 2 * i
					want := f32((block[i] + strided_history[ch][i]) / 32768)
					tolerance := 8e-7 * max(1, abs(f64(want)))
					testing.expectf(
						t,
						!math.is_nan(strided[index]) &&
						!math.is_inf(strided[index]) &&
						abs(f64(strided[index]) - f64(want)) <= tolerance,
						"stride2 initial=%d frame=%d %v shape=%d channel=%d output=%d got %.9g expected %.9g",
						initial,
						frame,
						sequence,
						shape,
						ch,
						i,
						strided[index],
						want,
					)
					transform_test_close(
						t,
						strided_banks[ch].overlap[i],
						block[1024 + i],
						scale,
						"stride2 history",
						1024,
						i,
						.Random,
					)
					strided_history[ch][i] = block[1024 + i]
					if frame == 13 do testing.expect_value(t, strided[index], f32(0))
				}
				for value, index in strided {
					owned :=
						index >= prefix + ch &&
						index <= prefix + ch + 2046 &&
						(index - prefix - ch) & 1 == 0
					if !owned do testing.expect_value(t, transmute(u32)value, transmute(u32)before[index])
				}
				testing.expect_value(t, strided_banks[ch].previous_shape, shape)
				if frame == 13 do for value in strided_banks[ch].overlap do testing.expect_value(t, value, f64(0))
			}
			previous = shape
			if frame == 13 {
				for v in actual[:1024] do testing.expect_value(t, v, f32(0))
				for v in bank.overlap do testing.expect_value(t, v, f64(0))
			}
		}
	}
}

package aac

import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"

// Reuse the independent cosine definitions, input generators and quadrature
// Bessel oracle in transform_test. None reads a production twiddle or fold.
@(test)
test_960_120_transform_direct_cosines_and_guards :: proc(t: ^testing.T) {
	plan: Transform
	init_transform(&plan, 960)
	input: [2064]f64
	actual: [2064]f64
	for n in ([2]int{120, 960}) {
		for kind in ([6]Transform_Test_Vector{.DC, .Impulse_Start, .Impulse_Middle, .Impulse_End, .Random, .Cancellation}) {
			for &v in input do v = 331.25
			for &v in actual do v = -799.5
			transform_test_analysis_input(input[7:7 + 2 * n], kind)
			before := input
			mdct(&plan, input[7:7 + 2 * n], actual[5:5 + n])
			testing.expect(t, slice.equal(input[:], before[:]))
			scale := 2 * transform_test_norm(input[7:7 + 2 * n])
			for k in 0 ..< n {
				if n == 120 ||
				   kind >= .Impulse_Start && kind <= .Impulse_End ||
				   k % 37 == 0 ||
				   k == n - 1 {
					transform_test_close(
						t,
						actual[5 + k],
						transform_test_analysis_bin(input[7:7 + 2 * n], k),
						scale,
						"960 MDCT",
						n,
						k,
						kind,
					)
				}
			}
			for value, i in actual do if i < 5 || i >= 5 + n do testing.expect_value(t, value, f64(-799.5))
			for &v in actual do v = -799.5
			transform_test_synthesis_input(input[7:7 + n], kind)
			before = input
			imdct(&plan, input[7:7 + n], actual[5:5 + 2 * n])
			testing.expect(t, slice.equal(input[:], before[:]))
			scale = transform_test_norm(input[7:7 + n]) / f64(n)
			for i in 0 ..< 2 * n {
				if n == 120 ||
				   kind >= .Impulse_Start && kind <= .Impulse_End ||
				   i % 37 == 0 ||
				   i == 2 * n - 1 {
					transform_test_close(
						t,
						actual[5 + i],
						transform_test_synthesis_sample(input[7:7 + n], i),
						scale,
						"960 IMDCT",
						n,
						i,
						kind,
					)
				}
			}
			for value, i in actual do if i < 5 || i >= 5 + 2 * n do testing.expect_value(t, value, f64(-799.5))
		}
	}
}

@(private)
length_test_windows :: proc(w: ^Transform_Test_Windows, n: int) {
	for size in ([2]int{n / 8, n}) {
		short := size < n
		sine := short ? w.short[0][:] : w.long[0][:]
		kbd := short ? w.short[1][:] : w.long[1][:]
		alpha := short ? 6.0 : 4.0
		kernel: [1025]f64
		total, correction: f64
		for i in 0 ..= size {
			x := 2 * f64(i) / f64(size) - 1
			kernel[i] = transform_test_bessel_i0(math.PI * alpha * math.sqrt(max(0, 1 - x * x)))
			transform_test_add(&total, &correction, kernel[i])
		}
		sum: f64
		correction = 0
		for i in 0 ..< size {
			sine[i] = math.sin(math.PI * (f64(i) + 0.5) / f64(2 * size))
			transform_test_add(&sum, &correction, kernel[i])
			kbd[i] = math.sqrt(sum / total)
		}
	}
}

@(private)
length_test_envelope :: proc(
	w: ^Transform_Test_Windows,
	n: int,
	sequence: Window_Sequence,
	previous, shape: u8,
	sample: int,
) -> f64 {
	short := n / 8
	flat := (n - short) / 2
	if sample < n {
		if sequence != .Stop do return w.long[previous][sample]
		if sample < flat do return 0
		if sample < flat + short do return w.short[previous][sample - flat]
		return 1
	}
	if sequence != .Start do return w.long[shape][2 * n - 1 - sample]
	if sample < n + flat do return 1
	if sample < n + flat + short do return w.short[shape][n + flat + short - 1 - sample]
	return 0
}

@(test)
test_analysis_all_window_sequences_direct_cosines :: proc(t: ^testing.T) {
	plan: Transform
	windows: Transform_Test_Windows
	input, windowed: [2048]f64
	output: [1032]f64
	for n in ([2]int{1024, 960}) {
		init_transform(&plan, n)
		length_test_windows(&windows, n)
		for shape in u8(0) ..< 2 {
			for i in 0 ..< n do testing.expect(t, abs(plan.long_window[shape][i] - windows.long[shape][i]) <= 3e-13)
			for i in 0 ..< n / 8 do testing.expect(t, abs(plan.short_window[shape][i] - windows.short[shape][i]) <= 3e-13)
		}
		transform_test_analysis_input(input[:2 * n], .Random)
		for sequence in ([4]Window_Sequence{.Long, .Start, .Short, .Stop}) {
			for previous in u8(0) ..< 2 {
				for shape in u8(0) ..< 2 {
					for &v in output do v = 812.75
					analysis(&plan, sequence, previous, shape, input[:2 * n], output[3:3 + n])
					windows_count := sequence == .Short ? 8 : 1
					size := n / windows_count
					for b in 0 ..< windows_count {
						for i in 0 ..< 2 * size {
							if sequence == .Short {
								left := b == 0 ? previous : shape
								envelope :=
									i < size ? windows.short[left][i] : windows.short[shape][2 * size - 1 - i]
								windowed[i] = input[(n - size) / 2 + b * size + i] * envelope
							} else {
								windowed[i] =
									input[i] *
									length_test_envelope(&windows, n, sequence, previous, shape, i)
							}
						}
						scale := 2 * transform_test_norm(windowed[:2 * size])
						for k := 0; k < size; k += 17 {
							transform_test_close(
								t,
								output[3 + b * size + k],
								transform_test_analysis_bin(windowed[:2 * size], k),
								scale,
								"windowed analysis",
								size,
								k,
								.Random,
							)
						}
						transform_test_close(
							t,
							output[3 + (b + 1) * size - 1],
							transform_test_analysis_bin(windowed[:2 * size], size - 1),
							scale,
							"windowed analysis",
							size,
							size - 1,
							.Random,
						)
					}
					for value, i in output do if i < 3 || i >= 3 + n do testing.expect_value(t, value, f64(812.75))
				}
			}
		}
		// Publication can overlap the captured caller input, including windows
		// still needed by later short blocks; the plan itself is a separate owner.
		expected: [1024]f64
		analysis(&plan, .Short, 1, 0, input[:2 * n], expected[:n])
		alias := input
		analysis(&plan, .Short, 1, 0, alias[:2 * n], alias[n / 2:n / 2 + n])
		testing.expect(t, slice.equal(alias[n / 2:n / 2 + n], expected[:n]))
	}
}

@(private)
length_test_windowed_sample :: proc(
	w: ^Transform_Test_Windows,
	n: int,
	sequence: Window_Sequence,
	previous, shape: u8,
	spectrum: []f64,
	sample: int,
) -> f64 {
	if sequence != .Short do return transform_test_synthesis_sample(spectrum, sample) * length_test_envelope(w, n, sequence, previous, shape, sample)
	short := n / 8
	value: f64
	for b in 0 ..< 8 {
		local := sample - ((n - short) / 2 + b * short)
		if local < 0 || local >= 2 * short do continue
		left := b == 0 ? previous : shape
		envelope := local < short ? w.short[left][local] : w.short[shape][2 * short - 1 - local]
		value +=
			transform_test_synthesis_sample(spectrum[b * short:(b + 1) * short], local) * envelope
	}
	return value
}

@(private)
length_test_strided :: proc(
	$Stride: int,
	t: ^testing.T,
	plan: ^Transform,
	windows: ^Transform_Test_Windows,
) {
	n := plan.frame_length
	banks: [Stride]Filterbank
	history: [Stride][1024]f64
	for ch in 0 ..< Stride {
		banks[ch].previous_shape = 1
		for i in 0 ..< 1024 do history[ch][i] = f64((i * 17 + ch * 991) % 8193 - 4096)
		banks[ch].overlap = history[ch]
	}
	sequences := [8]Window_Sequence{.Long, .Start, .Short, .Short, .Stop, .Long, .Long, .Long}
	previous: u8 = 1
	for sequence, frame in sequences {
		shape := u8(frame & 1)
		spectrum: [1024]f64
		if frame < 6 {
			count := sequence == .Short ? 8 : 1
			size := n / count
			for b in 0 ..< count {
				spectrum[b * size] = f64((frame + b) % 3 - 1) * 1e7
				spectrum[b * size + 1 + (frame * 13 + b * 7) % (size - 2)] = 3e6
				spectrum[(b + 1) * size - 1] = -2e6
			}
		}
		block: [2048]f64
		for sample in 0 ..< 2 * n do block[sample] = length_test_windowed_sample(windows, n, sequence, previous, shape, spectrum[:n], sample)
		actual: [8200]f32
		for &v, i in actual do v = f32(512 + f64(i) / 8)
		for ch in 0 ..< Stride {
			before := actual
			synthesize_to(
				Stride,
				plan,
				&banks[ch],
				sequence,
				shape,
				spectrum[:n],
				actual[3 + ch:3 + ch + (n - 1) * Stride + 1],
			)
			for value, slot in actual {
				index := slot - (3 + ch)
				if index < 0 || index >= n * Stride || index % Stride != 0 {
					testing.expect_value(t, value, before[slot])
					continue
				}
				i := index / Stride
				want := f32((block[i] + history[ch][i]) / 32768)
				testing.expectf(
					t,
					abs(f64(value) - f64(want)) <= 8e-7 * max(1, abs(f64(want))),
					"N=%d stride=%d frame=%d ch=%d sample=%d",
					n,
					Stride,
					frame,
					ch,
					i,
				)
				transform_test_close(
					t,
					banks[ch].overlap[i],
					block[n + i],
					transform_test_norm(spectrum[:n]) / f64(n / 8),
					"variable window history",
					n,
					i,
					.Random,
				)
				history[ch][i] = block[n + i]
			}
			for i in n ..< 1024 do testing.expect_value(t, banks[ch].overlap[i], history[ch][i])
			testing.expect_value(t, banks[ch].previous_shape, shape)
		}
		previous = shape
	}
}

@(test)
test_filterbank_both_lengths_all_output_strides_transitions_and_drains :: proc(t: ^testing.T) {
	plan: Transform
	windows: Transform_Test_Windows
	for n in ([2]int{1024, 960}) {
		init_transform(&plan, n)
		length_test_windows(&windows, n)
		length_test_strided(1, t, &plan, &windows)
		length_test_strided(2, t, &plan, &windows)
		length_test_strided(3, t, &plan, &windows)
		length_test_strided(4, t, &plan, &windows)
		length_test_strided(5, t, &plan, &windows)
		length_test_strided(6, t, &plan, &windows)
		length_test_strided(7, t, &plan, &windows)
		length_test_strided(8, t, &plan, &windows)
	}
}

@(test)
test_transform_tables_and_calls_have_no_frame_allocations :: proc(t: ^testing.T) {
	long_counts := [13]int{40, 40, 46, 49, 49, 49, 46, 46, 42, 42, 42, 40, 40}
	short_counts := [13]int{12, 12, 12, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15}
	for rate in 0 ..< 13 {
		long, short := long_offsets(rate, 960), short_offsets(rate, 960)
		testing.expect_value(t, len(long) - 1, long_counts[rate])
		testing.expect_value(t, len(short) - 1, short_counts[rate])
		testing.expect_value(t, long[len(long) - 1], 960)
		testing.expect_value(t, short[len(short) - 1], 120)
		for offsets in ([2][]int{long, short}) {
			testing.expect_value(t, offsets[0], 0)
			for i in 1 ..< len(offsets) do testing.expect(t, offsets[i] > offsets[i - 1] && offsets[i] % 4 == 0)
		}
	}
	for n in ([2]int{1024, 960}) {
		testing.expect(t, slice.equal(long_offsets(12, n), long_offsets(11, n)))
		testing.expect(t, slice.equal(short_offsets(12, n), short_offsets(11, n)))
	}
	testing.expect_value(t, tns_max_bands(12, false), 39)
	testing.expect_value(t, tns_max_bands(12, true), 14)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	plan: Transform
	bank: Filterbank
	input: [2048]f64
	spectrum: [1024]f64
	output: [1024]f32
	{
		context.allocator = mem.tracking_allocator(&track)
		for n in ([2]int{1024, 960}) {
			init_transform(&plan, n)
			for sequence in ([4]Window_Sequence{.Long, .Start, .Short, .Stop}) {
				analysis(&plan, sequence, 0, 1, input[:2 * n], spectrum[:n])
				synthesize(&plan, &bank, sequence, 1, spectrum[:n], output[:n])
			}
		}
	}
	testing.expect_value(t, track.total_allocation_count, i64(0))
}

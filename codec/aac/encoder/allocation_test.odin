package aac_encoder

import aac ".."
import "core:math"
import "core:testing"

@(private)
allocation_short_groups :: proc(e: ^Encoder, windows_per_group, bands: int) {
	assert(windows_per_group > 0 && 8 % windows_per_group == 0)
	e.groups = 8 / windows_per_group
	e.group_length = {}; e.group_start = {}
	for g in 0 ..< e.groups {
		e.group_start[g] = g * windows_per_group
		e.group_length[g] = windows_per_group
	}
	e.stride = e.frame_samples / 8; e.max_sfb = bands
	e.tool = {}; e.ms = {}; e.tns = {}
	e.work_stats = {
		sequence = .Short,
	}
}

// Measure the actual quantized band using the inverse equation, independently
// of the encoder's masking threshold, derivative and scale-factor estimate.
@(private)
allocation_band_result :: proc(
	e: ^Encoder,
	g, b: int,
) -> (
	power, error: f64,
	magnitude, bits: int,
) {
	offsets := aac.short_offsets(e.rate_index, e.frame_samples)
	width := offsets[b + 1] - offsets[b]
	first, _ := band_range(e, 0, g, b)
	scale := math.pow(2.0, f64(e.sf[0][g][b] - 100) / 4)
	for w in 0 ..< e.group_length[g] do for i in 0 ..< width {
		original := e.spectrum[0][(e.group_start[g] + w) * e.stride + offsets[b] + i]
		q := e.quant[0][first + w * width + i]
		value := math.pow(f64(abs(q)), 4.0 / 3) * scale
		if q < 0 do value = -value
		difference := original - value
		power += original * original; error += difference * difference
		magnitude = max(magnitude, int(abs(q)))
	}
	bits = e.spectral_bits[0][g][b]
	return
}

@(test)
test_sparse_audible_peak_takes_priority_over_distant_quiet_leakage :: proc(t: ^testing.T) {
	for n in ([2]int{960, 1024}) {
		e := new(Encoder); defer free(e)
		testing.expect_value(
			t,
			init_encoder(
				e,
				{sample_rate = 48000, channels = 1, bit_rate = 64000, frame_samples = n},
				.Raw,
				{
					disable_pns = true,
					disable_ms = true,
					disable_intensity = true,
					disable_tns = true,
				},
			),
			Error.None,
		)
		defer destroy_encoder(e)
		offsets := aac.short_offsets(e.rate_index, n)
		strong_band, quiet_band := 0, 4
		testing.expect_value(t, offsets[strong_band + 1] - offsets[strong_band], 4)
		testing.expect_value(t, offsets[quiet_band + 1] - offsets[quiet_band], 4)
		for quiet in ([2]f64{128, 1024}) {
			e.spectrum = {}
			allocation_short_groups(e, 1, quiet_band + 1)
			for w in 0 ..< 8 do e.spectrum[0][w * e.stride + offsets[quiet_band] + 1] = quiet
			prepare_bands(e, offsets, true); quantize(e, 0)
			isolated_power, isolated_error, isolated_magnitude, isolated_bits :=
				allocation_band_result(e, 0, quiet_band)
			testing.expect(t, isolated_power > 0 && isolated_magnitude > 0 && isolated_bits > 0)

			// The same weak shape remains present; only a distant audible
			// peak is added. Per-band amplitude-invariant allocation used to
			// give leakage almost the same coding cost as the strong tone.
			for w in 0 ..< 8 do e.spectrum[0][w * e.stride + offsets[strong_band] + 1] = 1234567
			prepare_bands(e, offsets, true); quantize(e, 0)
			strong_power, strong_error, strong_magnitude, strong_bits := allocation_band_result(
				e,
				0,
				strong_band,
			)
			quiet_power, quiet_error, quiet_magnitude, quiet_bits := allocation_band_result(
				e,
				0,
				quiet_band,
			)
			testing.expect_value(t, quiet_power, isolated_power)
			testing.expectf(
				t,
				strong_bits > quiet_bits && quiet_bits < isolated_bits,
				"N%d quiet%g: spectral bits strong%d quiet%d isolated%d",
				n,
				quiet,
				strong_bits,
				quiet_bits,
				isolated_bits,
			)
			testing.expectf(
				t,
				strong_magnitude > 8 * quiet_magnitude,
				"N%d quiet%g: quantized magnitude strong%d quiet%d",
				n,
				quiet,
				strong_magnitude,
				quiet_magnitude,
			)
			testing.expectf(
				t,
				strong_error / strong_power < 0.001,
				"N%d quiet%g: audible peak relative error%g",
				n,
				quiet,
				strong_error / strong_power,
			)
			testing.expectf(
				t,
				quiet_error / quiet_power > isolated_error / isolated_power,
				"N%d quiet%g: leakage relative error%g isolated%g",
				n,
				quiet,
				quiet_error / quiet_power,
				isolated_error / isolated_power,
			)
		}
	}
}

@(test)
test_grouping_identical_short_tones_preserves_per_window_precision :: proc(t: ^testing.T) {
	for n in ([2]int{960, 1024}) {
		e := new(Encoder); defer free(e)
		testing.expect_value(
			t,
			init_encoder(
				e,
				{sample_rate = 48000, channels = 1, bit_rate = 64000, frame_samples = n},
				.Raw,
				{
					disable_pns = true,
					disable_ms = true,
					disable_intensity = true,
					disable_tns = true,
				},
			),
			Error.None,
		)
		defer destroy_encoder(e)
		offsets := aac.short_offsets(e.rate_index, n)
		for width in ([3]int{4, 8, 16}) {
			band := -1
			for b in 0 ..< len(offsets) - 1 do if offsets[b + 1] - offsets[b] == width {band = b; break}
			testing.expect(t, band >= 0)
			if band < 0 do continue
			e.spectrum = {}
			allocation_short_groups(e, 1, band + 1)
			for w in 0 ..< 8 do e.spectrum[0][w * e.stride + offsets[band] + 1] = 1234567
			prepare_bands(e, offsets, true); quantize(e, 0)
			first, end := band_range(e, 0, 0, band)
			reference: [16]i32
			copy(reference[:width], e.quant[0][first:end])
			power, error, magnitude, _ := allocation_band_result(e, 0, band)
			testing.expect(t, power > 0 && magnitude > 0)
			reference_error := error / power

			// These are four valid partitions of eight short windows. Their
			// repeated spectra have the same audible energy in each window.
			// Grouping must not coarsen the tone merely because a packed band
			// contains more coefficients from additional time windows.
			for windows_per_group in ([3]int{2, 4, 8}) {
				allocation_short_groups(e, windows_per_group, band + 1)
				prepare_bands(e, offsets, true); quantize(e, 0)
				for g in 0 ..< e.groups {
					start, _ := band_range(e, 0, g, band)
					for w in 0 ..< windows_per_group do for i in 0 ..< width {
						testing.expectf(t, e.quant[0][start + w * width + i] == reference[i], "N%d width%d group%d window%d coefficient%d", n, width, windows_per_group, w, i)
					}
					grouped_power, grouped_error, _, _ := allocation_band_result(e, g, band)
					relative := grouped_error / grouped_power
					testing.expectf(
						t,
						abs(relative - reference_error) <= max(1.0, reference_error) * 1e-12,
						"N%d width%d group%d: relative error%g reference%g",
						n,
						width,
						windows_per_group,
						relative,
						reference_error,
					)
				}
			}
		}
	}
}

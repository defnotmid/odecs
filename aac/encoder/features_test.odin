package aac_encoder

import aac ".."
import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"

@(test)
test_quantizer_factorization_and_exact_coding_cost :: proc(t: ^testing.T) {
	e := new(Encoder); defer free(e)
	testing.expect_value(t, init_encoder(e, {sample_rate = 48000, channels = 2}), Error.None)
	defer destroy_encoder(e)
	for sf in 0 ..< 256 do for value in ([8]f64{0, 0.0001, 0.2, 1, 37, 1290, 32768, 1000000}) {
		direct := math.pow(value * math.pow(2.0, -f64(sf - 100) / 4), 0.75)
		factored := math.pow(value, 0.75) * e.quant_factor[sf]
		testing.expectf(t, abs(direct - factored) <= max(1.0, abs(direct)) * 1e-12, "sf%d value%g direct%g factored%g", sf, value, direct, factored)
	}
	seed: u32 = 19
	for sequence in ([4]aac.Window_Sequence{.Long, .Start, .Short, .Stop}) {
		for ch in 0 ..< 2 do for i in 0 ..< 1024 {
			seed = seed * 1664525 + 1013904223
			e.previous[ch][i] = f64(i32(seed)) / 65536
			e.pending[ch][i] = f64(i32(seed ~ 0x31415926)) / 65536
		}
		analyze_block(e, sequence)
		for adjustment in ([6]int{0, 3, 17, 39, 100, 192}) {
			quantize(e, adjustment)
			cost := raw_bits(e); write_payload(e)
			testing.expect_value(t, len(e.payload) * 8, cost)
		}
	}
}

@(test)
test_tns_transmitted_filter_has_independent_inverse :: proc(t: ^testing.T) {
	e := new(Encoder); defer free(e)
	testing.expect_value(t, init_encoder(e, {sample_rate = 48000, channels = 1}), Error.None)
	defer destroy_encoder(e)
	e.max_sfb = e.long_max_sfb; e.stride = 1024
	offsets := aac.long_offsets(e.rate_index, 1024)
	for &value, i in e.spectrum[0] do value = 80000 * math.exp(-f64(i) / 70) * math.cos(f64(i) * 0.023)
	original := e.spectrum[0]
	prepare_tns(e, 0, offsets, false)
	filter := &e.tns[0][0]
	testing.expect(t, filter.order > 0)
	if filter.order == 0 do return
	// Build LPC coefficients independently from the transmitted sine values,
	// then evaluate the inverse recurrence with an indexed output history.
	polynomial: [5]f64; polynomial[0] = 1
	for m in 1 ..= filter.order {
		q := f64(filter.coefficient[m - 1])
		reflection := math.sin(q * (math.PI / 2) / (q < 0 ? 8.5 : 7.5))
		previous := polynomial
		for j in 1 ..< m do polynomial[j] = previous[j] + reflection * previous[m - j]
		polynomial[m] = reflection
	}
	reconstructed: [1024]f64
	start := offsets[filter.start_band]
	end := offsets[min(e.max_sfb, aac.tns_max_bands(e.rate_index, false))]
	for i in start ..< end {
		value := e.spectrum[0][i]
		for lag in 1 ..= min(filter.order, i - start) do value -= polynomial[lag] * reconstructed[i - lag]
		reconstructed[i] = value
		testing.expectf(
			t,
			abs(value - original[i]) < max(1.0, abs(original[i])) * 1e-10,
			"TNS inverse bin%d",
			i,
		)
	}
	for i in 0 ..< start do testing.expect_value(t, e.spectrum[0][i], original[i])
	for i in end ..< 1024 do testing.expect_value(t, e.spectrum[0][i], original[i])
}

@(test)
test_mid_side_and_intensity_selection_reconstructs_channels :: proc(t: ^testing.T) {
	e := new(Encoder); defer free(e)
	testing.expect_value(
		t,
		init_encoder(e, {sample_rate = 48000, channels = 2, bit_rate = 64000}),
		Error.None,
	)
	defer destroy_encoder(e)
	select_groups(e, .Long)
	offsets := aac.long_offsets(e.rate_index, 1024)
	for i in 0 ..< 1024 {e.spectrum[0][i] = f64(i + 1); e.spectrum[1][i] = f64(i + 1)}
	prepare_stereo(e, offsets)
	testing.expect(t, e.work_stats.ms_bands > 0 && e.work_stats.intensity_bands > 0)
	for b in 0 ..< e.max_sfb {
		if e.ms[0][0][b] {
			for k in offsets[b] ..< offsets[b + 1] {
				testing.expect_value(t, e.spectrum[0][k], f64(k + 1))
				testing.expect_value(t, e.spectrum[1][k], f64(0))
			}
		} else if e.tool[1][0][b] >= 14 {
			testing.expect_value(t, e.tool[1][0][b], u8(15))
			testing.expect_value(t, e.base_sf[1][0][b], 0)
		}
	}
	e.ms = {}; e.tool = {}; e.work_stats = {}; e.options.disable_ms = true
	for i in 0 ..< 1024 {e.spectrum[0][i] = f64(i + 1); e.spectrum[1][i] = -f64(i + 1) * 0.5}
	prepare_stereo(e, offsets)
	testing.expect(t, e.work_stats.intensity_bands > 0)
	for b in 0 ..< e.max_sfb do if e.tool[1][0][b] >= 14 {
		testing.expect_value(t, e.tool[1][0][b], u8(14))
		testing.expect_value(t, e.base_sf[1][0][b], 4)
	}
}

@(test)
test_noise_substitution_admits_flat_bands_and_rejects_tones :: proc(t: ^testing.T) {
	e := new(Encoder); defer free(e)
	testing.expect_value(
		t,
		init_encoder(e, {sample_rate = 48000, channels = 1, bit_rate = 32000}),
		Error.None,
	)
	defer destroy_encoder(e)
	select_groups(e, .Long)
	offsets := aac.long_offsets(e.rate_index, 1024)
	for &value, i in e.spectrum[0] do value = i & 1 == 0 ? 5000 : -5000
	prepare_bands(e, offsets, false)
	testing.expect(t, e.work_stats.pns_bands > 0)
	for b in 0 ..< e.max_sfb do if e.tool[0][0][b] == 13 {
		represented := math.pow(2.0, f64(e.base_sf[0][0][b]) / 2)
		testing.expect(t, represented / e.energy[0][0][b] > 0.84 && represented / e.energy[0][0][b] < 1.19)
	}
	e.tool = {}; e.work_stats = {}; e.spectrum = {}
	for b in 0 ..< e.max_sfb do e.spectrum[0][offsets[b]] = 50000
	prepare_bands(e, offsets, false)
	testing.expect_value(t, e.work_stats.pns_bands, 0)
}

@(test)
test_lookahead_transitions_output_guards_and_retry :: proc(t: ^testing.T) {
	e := new(Encoder); defer free(e)
	testing.expect_value(t, init_encoder(e, {sample_rate = 48000, channels = 2}), Error.None)
	defer destroy_encoder(e)
	pcm: [2048]f32; out: [8194]u8
	for &value in out do value = 0xcd
	bytes, error := encode_frame_to(e, pcm[:], out[:])
	testing.expect_value(t, error, Error.None); testing.expect_value(t, bytes, 0)
	for value in out do testing.expect_value(t, value, u8(0xcd))
	for i in 1024 ..< 1280 do pcm[i] = i & 1 == 0 ? 0.8 : -0.8
	before_energy, before_tail := e.input_energy, e.input_tail
	_, error = encode_frame_to(e, pcm[:], out[:0])
	testing.expect_value(t, error, Error.Output_Too_Small)
	testing.expect_value(t, e.frames, 0); testing.expect_value(t, e.input_frames, 1)
	testing.expect_value(t, e.sequence, aac.Window_Sequence.Long)
	testing.expect(t, e.input_energy == before_energy && e.input_tail == before_tail)
	bytes, error = encode_frame_to(e, pcm[:], out[:])
	testing.expect_value(t, error, Error.None); testing.expect(t, bytes > 0)
	testing.expect_value(t, e.stats.sequence, aac.Window_Sequence.Start)
	for value in out[bytes:] do testing.expect_value(t, value, u8(0xcd))
	pcm = {}
	_, error = encode_frame_to(e, pcm[:], out[:])
	testing.expect_value(
		t,
		error,
		Error.None,
	); testing.expect_value(t, e.stats.sequence, aac.Window_Sequence.Short)
	_, error = encode_frame_to(e, pcm[:], out[:])
	testing.expect_value(
		t,
		error,
		Error.None,
	); testing.expect_value(t, e.stats.sequence, aac.Window_Sequence.Stop)
	_, error = encode_frame_to(e, pcm[:], out[:])
	testing.expect_value(
		t,
		error,
		Error.None,
	); testing.expect_value(t, e.stats.sequence, aac.Window_Sequence.Long)
	for {
		bytes, error = flush_encoder_next_to(e, out[:])
		testing.expect_value(t, error, Error.None)
		if bytes == 0 do break
	}
	testing.expect_value(t, e.frames, e.input_frames + 1)
	_, error = encode_frame_to(
		e,
		pcm[:],
		out[:],
	); testing.expect_value(t, error, Error.Invalid_State)
}

@(test)
test_preallocated_encode_and_flush_do_not_allocate :: proc(t: ^testing.T) {
	for n in ([2]int{960, 1024}) do for channels in ([3]int{1, 2, 8}) {
		e := new(Encoder); defer free(e)
		testing.expect_value(t, init_encoder(e, {sample_rate = 48000, channels = channels, frame_samples = n}, n == 960 ? .LOAS : .ADTS), Error.None)
		defer destroy_encoder(e)
		pcm: [8192]f32; out: [8194]u8
		for &value, i in pcm[:n * channels] do value = f32(0.2 * math.sin(f64(i / channels) / 17))
		payload_pointer, packet_pointer := raw_data(e.payload), raw_data(e.packet)
		allocator := context.allocator
		context.allocator = mem.nil_allocator()
		for _ in 0 ..< 5 {
			_, error := encode_frame_to(e, pcm[:n * channels], out[:])
			testing.expect_value(t, error, Error.None)
		}
		for {
			bytes, error := flush_encoder_next_to(e, out[:]); testing.expect_value(t, error, Error.None)
			if bytes == 0 do break
		}
		context.allocator = allocator
		testing.expect_value(t, raw_data(e.payload), payload_pointer)
		testing.expect_value(t, raw_data(e.packet), packet_pointer)
		testing.expect_value(t, e.frames, 6)
		reset_encoder(e)
		testing.expect_value(t, e.frames, 0); testing.expect_value(t, e.input_frames, 0)
		testing.expect(t, !e.pending_valid && !e.finished)
	}
}

@(test)
test_reservoir_tracks_actual_bytes_and_cbr_fills :: proc(t: ^testing.T) {
	for constant in ([2]bool{false, true}) {
		e := new(Encoder); defer free(e)
		testing.expect_value(
			t,
			init_encoder(
				e,
				{sample_rate = 48000, channels = 1, bit_rate = 64000},
				.ADTS,
				{constant_bit_rate = constant},
			),
			Error.None,
		)
		defer destroy_encoder(e)
		pcm: [1024]f32; out: [8194]u8
		for frame in 0 ..< 12 {
			for &value, i in pcm do value = frame < 4 ? 0 : f32(0.25 * math.sin(f64(i + frame * 1024) / 13))
			previous, remainder := e.reservoir_bits, e.rate_remainder
			bytes, error := encode_frame_to(
				e,
				pcm[:],
				out[:],
			); testing.expect_value(t, error, Error.None)
			if bytes == 0 do continue
			numerator := e.config.bit_rate * 1024 + remainder
			expected := clamp(previous + numerator / 48000 - bytes * 8, 0, e.reservoir_limit)
			testing.expect_value(t, e.reservoir_bits, expected)
			testing.expect_value(t, e.rate_remainder, numerator % 48000)
			testing.expect(t, bytes * 8 <= e.stats.target_bits)
			if constant do testing.expect(t, e.stats.target_bits - bytes * 8 < 24)
			if frame == 3 && !constant do testing.expect(t, e.reservoir_bits > 0)
		}
	}
}

@(test)
test_all_transports_reset_replays_complete_bytes :: proc(t: ^testing.T) {
	for transport in ([3]Transport{.ADTS, .Raw, .LOAS}) {
		e := new(Encoder); defer free(e)
		testing.expect_value(
			t,
			init_encoder(e, {sample_rate = 7350, channels = 7, bit_rate = 224000}, transport),
			Error.None,
		)
		defer destroy_encoder(e)
		pcm: [7168]f32
		for &value, i in pcm do value = f32(0.1 * math.sin(f64(i / 7) / 7))
		first, second: [dynamic]u8; defer delete(first); defer delete(second)
		for output in ([2]^[dynamic]u8{&first, &second}) {
			for _ in 0 ..< 3 do testing.expect_value(t, encode_frame(e, pcm[:], output), Error.None)
			testing.expect_value(t, flush_encoder(e, output), Error.None)
			reset_encoder(e)
		}
		testing.expect(t, slice.equal(first[:], second[:]))
	}
}

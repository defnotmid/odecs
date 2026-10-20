package aac_decoder

import aac ".."
import common "../../../common"
@(require) import "core:fmt"
import "core:math"
@(require) import "core:os"
import "core:slice"
import "core:testing"

FEATURE_EXPORT :: #config(ODECS_AAC_FEATURE_EXPORT, false)

@(private)
feature_banks_equal :: #force_no_inline proc(actual, expected: []aac.Filterbank) -> bool {
	if len(actual) != len(expected) do return false
	for channel in 0 ..< len(actual) {
		if actual[channel].previous_shape != expected[channel].previous_shape || !slice.equal(actual[channel].overlap[:], expected[channel].overlap[:]) do return false
	}
	return true
}

@(private)
feature_banks_zero :: #force_no_inline proc(banks: []aac.Filterbank) -> bool {
	for channel in 0 ..< len(banks) {
		if banks[channel].previous_shape != 0 do return false
		for value in banks[channel].overlap do if value != 0 do return false
	}
	return true
}

@(private)
feature_export :: proc(
	t: ^testing.T,
	name: string,
	config: Config,
	unit: []u8,
	drain: []u8 = nil,
) {
	when FEATURE_EXPORT {
		stream: [dynamic]u8; defer delete(stream)
		for _ in 0 ..< 4 {
			e :=
				aac.resolved_frame_samples(config) == 1024 ? aac.append_adts(&stream, config, unit) : aac.append_loas(&stream, config, unit)
			testing.expect_value(t, e, Error.None)
		}
		if len(drain) > 0 {
			e :=
				aac.resolved_frame_samples(config) == 1024 ? aac.append_adts(&stream, config, drain) : aac.append_loas(&stream, config, drain)
			testing.expect_value(t, e, Error.None)
		}
		extension := aac.resolved_frame_samples(config) == 1024 ? "aac" : "loas"
		path := fmt.tprintf(".work/aac-lc-complete/features/%s.%s", name, extension)
		testing.expectf(t, os.write_entire_file(path, stream[:]) == nil, "export %s", path)
	}
}

@(private)
feature_code :: proc(w: ^common.Bit_Writer, symbol: int) {
	code := aac.CODEBOOKS[0][symbol]
	common.write_bits(w, code.bits, int(code.length))
}

@(private)
feature_info :: proc(rate, n: int, sequence: aac.Window_Sequence = .Long, shape: u8 = 0) -> Ics {
	info := Ics {
		sequence = sequence,
		shape    = shape,
		max_sfb  = 1,
		groups   = 1,
	}
	info.group_length[0] = sequence == .Short ? 8 : 1
	info.offsets = sequence == .Short ? aac.short_offsets(rate, n) : aac.long_offsets(rate, n)
	return info
}

// Direct syntax generator: one coded band, no prediction/gain control,
// optionally a first-order TNS filter. It uses public codeword facts only.
@(private)
feature_channel :: proc(
	w: ^common.Bit_Writer,
	info: Ics,
	amplitude: bool,
	gain: int = 100,
	tns: bool = false,
) {
	common.write_bits(w, u32(gain), 8)
	flow_test_write_ics(w, info)
	for _ in 0 ..< info.groups {
		common.write_bits(w, amplitude ? 1 : 0, 4)
		common.write_bits(w, u32(info.max_sfb), info.sequence == .Short ? 3 : 5)
	}
	if amplitude do for _ in 0 ..< info.groups do for _ in 0 ..< info.max_sfb do feature_code(w, 60)
	common.write_bits(w, 0, 1) // no pulses
	common.write_bits(w, tns ? 1 : 0, 1)
	if tns {
		for _ in 0 ..< (info.sequence == .Short ? 8 : 1) {
			common.write_bits(w, 1, info.sequence == .Short ? 1 : 2)
			common.write_bits(w, 0, 1) // resolution3
			common.write_bits(w, u32(len(info.offsets) - 1), info.sequence == .Short ? 4 : 6)
			common.write_bits(w, 1, info.sequence == .Short ? 3 : 5)
			common.write_bits(w, 0, 1) // ascending
			common.write_bits(w, 0, 1) // no compression
			common.write_bits(w, 1, 3) // sin(pi/7) reflection
		}
	}
	common.write_bits(w, 0, 1)
	if amplitude {
		for g in 0 ..< info.groups do for band in 0 ..< info.max_sfb do for _ in 0 ..< info.group_length[g] {
			for k := 0; k < info.offsets[band + 1] - info.offsets[band]; k += 4 {
				// Base-three symbol67 is {1,0,0,0}; remaining tuples are zero.
				tuple_test_write(w, 1, k == 0 ? 67 : 40, k == 0 ? [4]i32{1, 0, 0, 0} : [4]i32{}, 4)
			}
		}
	}
}

@(private)
feature_audio :: proc(
	w: ^common.Bit_Writer,
	e: aac.Channel_Element,
	rate, n: int,
	amplitude: bool = true,
	tns: bool = false,
	sequence: aac.Window_Sequence = .Long,
	shape: u8 = 0,
	gain_base: int = 100,
) {
	common.write_bits(w, e.kind == .CPE ? 1 : (e.kind == .LFE ? 3 : 0), 3)
	common.write_bits(w, u32(e.tag), 4)
	if e.kind == .CPE do common.write_bits(w, 0, 1)
	info := feature_info(rate, n, sequence, shape)
	for side in 0 ..< e.channels do feature_channel(w, info, amplitude, gain_base + 4 * (e.first_channel + side), tns)
}

@(private)
feature_end :: proc(w: ^common.Bit_Writer) {
	common.write_bits(w, 7, 3)
	common.write_align_zero(w)
}

// Independent first-frame synthesis equation for a single coefficient per
// transform. No production transform/window/coupling helper is called here.
@(private)
feature_cosine_sample :: proc(n, sample: int, amplitude: f64, short: bool = false) -> f64 {
	if !short {
		angle := math.PI / f64(n) * (f64(sample) + 0.5 + f64(n) / 2) * 0.5
		window := math.sin(math.PI * (f64(sample) + 0.5) / f64(2 * n))
		return amplitude * math.cos(angle) / f64(n) * window / 32768
	}
	small := n / 8
	flat := (n - small) / 2
	value: f64
	for w in 0 ..< 8 {
		local := sample - flat - w * small
		if local < 0 || local >= 2 * small do continue
		angle := math.PI / f64(small) * (f64(local) + 0.5 + f64(small) / 2) * 0.5
		value +=
			amplitude *
			math.cos(angle) /
			f64(small) *
			math.sin(math.PI * (f64(local) + 0.5) / f64(2 * small))
	}
	return value / 32768
}

@(test)
test_pulse_restores_zero_codebook_before_inverse_quantization :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [1026]f32
	for n in ([2]int{960, 1024}) do for amplitude in ([4]int{0, 1, 3, 15}) {
		testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 1, frame_samples = n}), Error.None)
		w := common.init_bit_writer(&buf)
		feature_zero_pulse(&w, .SCE, n, 1, 0, amplitude)
		feature_end(&w)
		for &value in pcm do value = -77
		_, err := decode_frame(d, buf[:], pcm[1:n + 1]); testing.expect_value(t, err, Error.None)
		// No scale-factor bits were sent: ZERO_HCB owns sf0 even though
		// global_gain255 would give an unrelated large gain for a coded band.
		coefficient := -math.pow(f64(amplitude), 4.0 / 3) * math.pow(2.0, -25)
		testing.expect_value(t, d.channel[0].sf[0][0], 0)
		testing.expect_value(t, d.channel[0].spectrum[0], coefficient)
		energy: f64
		for sample in 0 ..< n {
			want := feature_cosine_sample(n, sample, coefficient)
			testing.expect(t, abs(f64(pcm[1 + sample]) - want) <= abs(want) * 1e-6 + 1e-17)
			energy += f64(pcm[1 + sample]) * f64(pcm[1 + sample])
		}
		testing.expect(t, amplitude == 0 ? energy == 0 : energy > 0)
		testing.expect_value(t, pcm[0], f32(-77))
		for value in pcm[n + 1:] do testing.expect_value(t, value, f32(-77))
	}
}

// Direct ZERO_HCB syntax with one pulse and no transmitted scalefactors or
// spectral tuples. The decoder must restore its zero coefficient first.
@(private)
feature_zero_pulse :: proc(
	w: ^common.Bit_Writer,
	kind: aac.Element_Kind,
	n, max_sfb, offset, amplitude: int,
) {
	common.write_bits(w, kind == .LFE ? 3 : 0, 3)
	common.write_bits(w, 0, 4)
	common.write_bits(w, 255, 8)
	info := feature_info(3, n); info.max_sfb = max_sfb
	flow_test_write_ics(w, info)
	common.write_bits(w, 0, 4); common.write_bits(w, u32(max_sfb), 5)
	common.write_bits(w, 1, 1); common.write_bits(w, 0, 2)
	common.write_bits(w, 0, 6); common.write_bits(w, u32(offset), 5)
	common.write_bits(w, u32(amplitude), 4)
	common.write_bits(w, 0, 2) // TNS and gain control absent
}

@(test)
test_lfe_pulse_first_twelve_lines_and_late_refusal :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	config := Config {
		sample_rate = 48000,
		channels    = 6,
	}
	testing.expect_value(t, init_decoder(d, config), Error.None)
	layout, layout_err := aac.resolve_channel_layout(
		config,
	); testing.expect_value(t, layout_err, Error.None)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [6144]f32
	for offset in ([2]int{11, 12}) {
		w := common.init_bit_writer(&buf)
		for element in layout.elements[:layout.element_count] {
			if element.kind == .LFE {feature_zero_pulse(&w, .LFE, 1024, 4, offset, 3)} else {
				feature_audio(&w, element, 3, 1024, false)
			}
		}
		feature_end(&w)
		banks, seed := d.bank, d.noise_seed
		for &value in pcm do value = -77
		_, err := decode_frame(d, buf[:], pcm[:])
		if offset == 11 {
			testing.expect_value(t, err, Error.None)
			testing.expect_value(
				t,
				d.channel[5].spectrum[11],
				-math.pow(3.0, 4.0 / 3) * math.pow(2.0, -25),
			)
		} else {
			testing.expect_value(t, err, Error.Invalid_Data)
			testing.expect(t, feature_banks_equal(d.bank[:], banks[:]) && d.noise_seed == seed)
			for value in pcm do testing.expect_value(t, value, f32(-77))
		}
	}
}

@(test)
test_multichannel_standard_layouts_and_active_frame_sizes :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	buf: [dynamic]u8; defer delete(buf)
	output: [8 * 1024 + 2]f32
	for rate in ([2]int{3, 12}) do for n in ([2]int{960, 1024}) do for channels in 1 ..= 8 {
		config := Config {
			sample_rate   = aac.SAMPLE_RATES[rate],
			channels      = channels,
			frame_samples = n,
		}
		if channels == 7 {config.use_pce = true; config.program_config, _ = aac.default_program_config(config)}
		testing.expect_value(t, init_decoder(d, config), Error.None)
		layout, _ := aac.resolve_channel_layout(config)
		w := common.init_bit_writer(&buf)
		if config.use_pce {common.write_bits(&w, 5, 3); testing.expect_value(t, aac.write_program_config_element(&w, &config.program_config), Error.None)}
		for element in layout.elements[:layout.element_count] do feature_audio(&w, element, rate, n)
		feature_end(&w)
		when FEATURE_EXPORT {
			if rate == 3 {
				export: [dynamic]u8
				ew := common.init_bit_writer(&export)
				if config.use_pce {common.write_bits(&ew, 5, 3); testing.expect_value(t, aac.write_program_config_element(&ew, &config.program_config), Error.None)}
				for element in layout.elements[:layout.element_count] do feature_audio(&ew, element, rate, n, gain_base = 164)
				feature_end(&ew)
				feature_export(t, fmt.tprintf("standard_%dch_%d", channels, n), config, export[:])
				delete(export)
			}
		}
		for &v in output do v = -123
		count, err := decode_frame(d, buf[:], output[1:1 + n * channels])
		testing.expect_value(t, err, Error.None); testing.expect_value(t, count, n)
		testing.expect_value(t, output[0], f32(-123))
		for value in output[1 + n * channels:] do testing.expect_value(t, value, f32(-123))
		for sample in 0 ..< n do for channel in 0 ..< channels {
			want := feature_cosine_sample(n, sample, f64(int(1) << uint(channel)))
			testing.expectf(t, abs(f64(output[1 + sample * channels + channel]) - want) < 2e-12, "rate%d N%d channels%d sample%d channel%d", rate, n, channels, sample, channel)
		}
	}
}

@(test)
test_in_band_pce_tag_mapping_and_configured_layout_ownership :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	buf: [dynamic]u8; defer delete(buf)
	p := aac.Program_Config {
		object_type = 2,
		sample_rate = 48000,
		front_count = 2,
	}
	p.front[0], p.front[1] = {false, 7}, {true, 9}
	w := common.init_bit_writer(&buf)
	common.write_bits(&w, 5, 3)
	testing.expect_value(t, aac.write_program_config_element(&w, &p), Error.None)
	// Encounter order deliberately differs from explicit program order.
	feature_audio(&w, {.CPE, 9, 1, 2}, 3, 1024)
	feature_audio(&w, {.SCE, 7, 0, 1}, 3, 1024)
	feature_end(&w)
	when FEATURE_EXPORT {
		export: [dynamic]u8
		for with_drc in ([2]bool{false, true}) {
			ew := common.init_bit_writer(&export)
			common.write_bits(
				&ew,
				5,
				3,
			); testing.expect_value(t, aac.write_program_config_element(&ew, &p), Error.None)
			feature_audio(&ew, {.CPE, 9, 1, 2}, 3, 1024, gain_base = 164)
			feature_audio(&ew, {.SCE, 7, 0, 1}, 3, 1024, gain_base = 164)
			if with_drc do feature_fill_drc(&ew, 1, 2, true, 8)
			feature_end(&ew)
			feature_export(
				t,
				with_drc ? "pce_tag_order_drc_3ch" : "pce_tag_order_no_drc_3ch",
				{sample_rate = 48000, channels = 3, use_pce = true},
				export[:],
			)
		}
		delete(export)
	}
	testing.expect_value(
		t,
		init_decoder(d, {sample_rate = 48000, channels = 3, use_pce = true}),
		Error.None,
	)
	pcm: [3 * 1024]f32
	count, err := decode_frame(d, buf[:], pcm[:])
	testing.expect_value(t, err, Error.None); testing.expect_value(t, count, 1024)
	testing.expect(t, d.explicit_layout && d.program == p)
	for sample in 0 ..< 1024 do for channel in 0 ..< 3 {
		testing.expect(t, abs(f64(pcm[sample * 3 + channel]) - feature_cosine_sample(1024, sample, f64(int(1) << uint(channel)))) < 2e-12)
	}
	// An outside standard layout consumes a PCE but retains its configuration.
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 3}), Error.None)
	_, err = decode_frame(d, buf[:], pcm[:])
	testing.expect_value(t, err, Error.None)
	testing.expect(t, !d.explicit_layout && d.program == aac.Program_Config{})
}

@(test)
test_program_order_change_retains_element_owned_overlap :: proc(t: ^testing.T) {
	actual, oracle := new(Decoder), new(Decoder); defer free(actual); defer free(oracle)
	p := aac.Program_Config {
		object_type = 2,
		sample_rate = 48000,
		front_count = 2,
	}
	p.front[0], p.front[1] = {false, 1}, {false, 2}
	testing.expect_value(
		t,
		init_decoder(actual, {sample_rate = 48000, channels = 2, use_pce = true}),
		Error.None,
	)
	testing.expect_value(
		t,
		init_decoder(
			oracle,
			{sample_rate = 48000, channels = 2, use_pce = true, program_config = p},
		),
		Error.None,
	)
	buf: [dynamic]u8; defer delete(buf)
	got, expected: [2048]f32
	for frame in 0 ..< 2 {
		if frame == 1 do p.front[0], p.front[1] = p.front[1], p.front[0]
		w := common.init_bit_writer(&buf)
		// Exclusions refer to this frame's program order, while excluded
		// values retain the history owned by the corresponding element tag.
		common.write_bits(
			&w,
			5,
			3,
		); testing.expect_value(t, aac.write_program_config_element(&w, &p), Error.None)
		if frame == 1 do feature_fill_drc(&w, 0, 1, false, 3)
		feature_audio(&w, {.SCE, 1, 0, 1}, 3, 1024)
		feature_audio(&w, {.SCE, 2, 1, 1}, 3, 1024)
		if frame == 0 do feature_fill_drc(&w, 1, 1, true, 7)
		feature_end(&w)
		_, e := decode_frame(actual, buf[:], got[:]); testing.expect_value(t, e, Error.None)
		_, e = decode_frame(oracle, buf[:], expected[:]); testing.expect_value(t, e, Error.None)
		for sample in 0 ..< 1024 do for channel in 0 ..< 2 {
			other := frame == 0 ? channel : 1 - channel
			testing.expect_value(t, got[sample * 2 + channel], expected[sample * 2 + other])
			testing.expect(t, feature_banks_equal(actual.bank[channel:channel + 1], oracle.bank[other:other + 1]))
		}
		testing.expect_value(t, actual.dynamic_range.reference_level, u8(85))
		if frame == 0 {
			testing.expect_value(t, actual.dynamic_range.channel[0].control[0], u8(7))
			testing.expect(t, !actual.dynamic_range.channel[1].present)
		} else {
			testing.expect(t, !actual.dynamic_range.channel[0].present)
			testing.expect_value(t, actual.dynamic_range.channel[1].control[0], u8(3))
		}
	}
}

@(private)
feature_coupling_program :: proc(
	t: ^testing.T,
	w: ^common.Bit_Writer,
	n: int,
	independent: bool,
) -> Config {
	config := Config {
		sample_rate   = 48000,
		channels      = 2,
		frame_samples = n,
		use_pce       = true,
	}
	p, err := aac.default_program_config(config)
	testing.expect_value(t, err, Error.None)
	p.coupling_count = 1
	p.coupling[0] = {independent, 4}
	config.program_config = p
	// MPEG-4's predefined stereo configuration does not declare a CCE.
	// Use explicit PCE mapping and repeat the identical declaration before
	// payload elements; LATM also carries it in the outside ASC.
	common.write_bits(w, 5, 3)
	testing.expect_value(t, aac.write_program_config_element(w, &p), Error.None)
	return config
}

@(private)
feature_cce :: proc(
	w: ^common.Bit_Writer,
	rate, n: int,
	independent, domain: bool,
	selection: int,
	common_gain: bool,
	signed_gain: bool,
	exponent: int,
	source_tns: bool = false,
	sequence: aac.Window_Sequence = .Long,
	shape: u8 = 0,
	amplitude: bool = true,
	gain_base: int = 100,
	tag: u8 = 4,
) {
	common.write_bits(w, 2, 3); common.write_bits(w, u32(tag), 4)
	common.write_bits(w, independent ? 1 : 0, 1)
	common.write_bits(w, 0, 3) // one CPE target
	common.write_bits(w, 1, 1); common.write_bits(w, 0, 4)
	common.write_bits(w, u32(selection), 2)
	common.write_bits(w, domain ? 1 : 0, 1)
	common.write_bits(w, signed_gain ? 1 : 0, 1)
	common.write_bits(w, 3, 2) // cc_scale=2
	feature_channel(w, feature_info(rate, n, sequence, shape), amplitude, gain_base, source_tns)
	if selection == 3 {
		if !independent do common.write_bits(w, common_gain ? 1 : 0, 1)
		feature_code(w, exponent + 60)
	}
}

@(test)
test_cce_gain_lists_and_target_tns_domains :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [2048]f32
	for selection in 0 ..< 4 do for domain in ([2]bool{false, true}) do for common_gain in ([2]bool{false, true}) {
		testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 2}), Error.None)
		w := common.init_bit_writer(&buf)
		feature_audio(&w, {.CPE, 0, 0, 2}, 3, 1024, false, true)
		feature_cce(&w, 3, 1024, false, domain, selection, common_gain, !common_gain, -1, true)
		feature_end(&w)
		when FEATURE_EXPORT {
			if selection == 3 {
				export: [dynamic]u8
				ew := common.init_bit_writer(&export)
				export_config := feature_coupling_program(t, &ew, 1024, false)
				feature_audio(&ew, {.CPE, 0, 0, 2}, 3, 1024, false, true)
				feature_cce(&ew, 3, 1024, false, domain, selection, common_gain, !common_gain, -1, true, gain_base = 164)
				feature_end(&ew)
				feature_export(t, fmt.tprintf("cce_target_tns_domain%t_common%t", domain, common_gain), export_config, export[:])
				delete(export)
			}
		}
		_, err := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.None)
		reflection := math.sin(math.PI / 7)
		for channel in 0 ..< 2 {
			gain := f64(1)
			if (selection == 1 && channel == 0) || (selection == 2 && channel == 1) do gain = 0
			if selection == 3 && channel == 1 do gain = common_gain ? 2 : -2
			for bin in 0 ..< 1024 {
				// Source TNS has first-order impulse h[k]=(-r)^k. Pre-target
				// coupling filters it a second time: (h*h)[k]=(k+1)*(-r)^k.
				want := bin < 4 ? gain * math.pow(-reflection, f64(bin)) * (domain ? 1 : f64(bin + 1)) : 0
				testing.expect(t, abs(d.channel[channel].spectrum[bin] - want) < 2e-14)
			}
		}
		// The embedded source SCE is filtered independently of cc_domain.
		for bin in 0 ..< 1024 {
			want := bin < 4 ? math.pow(-reflection, f64(bin)) : 0
			testing.expect(t, abs(d.coupling[0].channel.spectrum[bin] - want) < 2e-14)
		}
	}
}

@(test)
test_independent_cce_and_grouped_short_120_cosine_oracles :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [2048]f32
	for n in ([2]int{960, 1024}) do for independent in ([2]bool{false, true}) {
		testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 2, frame_samples = n}), Error.None)
		w := common.init_bit_writer(&buf)
		feature_audio(&w, {.CPE, 0, 0, 2}, 3, n, false, false, independent ? aac.Window_Sequence.Long : .Short)
		feature_cce(&w, 3, n, independent, true, 3, true, false, 1, false, .Short)
		feature_end(&w)
		when FEATURE_EXPORT {
			export, drain: [dynamic]u8
			ew := common.init_bit_writer(&export)
			export_config := feature_coupling_program(t, &ew, n, independent)
			feature_audio(&ew, {.CPE, 0, 0, 2}, 3, n, false, false, independent ? aac.Window_Sequence.Long : .Short)
			feature_cce(&ew, 3, n, independent, true, 3, true, false, 1, false, .Short, gain_base = 164)
			feature_end(&ew)
			dw := common.init_bit_writer(&drain)
			_ = feature_coupling_program(t, &dw, n, independent)
			feature_audio(&dw, {.CPE, 0, 0, 2}, 3, n, false, false, independent ? aac.Window_Sequence.Long : .Stop)
			feature_cce(&dw, 3, n, independent, true, 3, true, false, 1, false, .Stop, 0, false)
			feature_end(&dw)
			feature_export(t, fmt.tprintf("cce_independent%t_short%d", independent, n / 8), export_config, export[:], drain[:])
			delete(export); delete(drain)
		}
		count, err := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.None); testing.expect_value(t, count, n)
		for sample in 0 ..< n do for channel in 0 ..< 2 {
			want := feature_cosine_sample(n, sample, channel == 0 ? 1 : 0.5, true)
			testing.expect(t, abs(f64(pcm[sample * 2 + channel]) - want) < 3e-12)
		}
		if independent {
			testing.expect(t, !feature_banks_zero(d.coupling_bank[4:5]))
		} else {
			testing.expect_value(t, d.coupling_bank[4].previous_shape, u8(0))
			testing.expect(t, feature_banks_zero(d.coupling_bank[4:5]))
		}
	}
}

@(test)
test_signed_differential_coupling_accumulates_across_short_groups :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [2048]f32
	for n in ([2]int{960, 1024}) {
		testing.expect_value(
			t,
			init_decoder(d, {sample_rate = 48000, channels = 2, frame_samples = n}),
			Error.None,
		)
		w := common.init_bit_writer(&buf)
		feature_audio(&w, {.CPE, 0, 0, 2}, 3, n, false, false, .Short)
		common.write_bits(&w, 2, 3); common.write_bits(&w, 4, 4)
		common.write_bits(&w, 0, 1); common.write_bits(&w, 0, 3)
		common.write_bits(&w, 1, 1); common.write_bits(&w, 0, 4); common.write_bits(&w, 3, 2)
		common.write_bits(&w, 1, 1); common.write_bits(&w, 1, 1); common.write_bits(&w, 0, 2)
		info := feature_info(3, n, .Short)
		info.groups, info.group_length = 4, {2, 3, 1, 2, 0, 0, 0, 0}
		feature_channel(&w, info, true)
		common.write_bits(&w, 0, 1)
		for delta in ([4]int{-3, 1, -2, 4}) do feature_code(&w, 60 + delta)
		feature_end(&w)
		_, e := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, e, Error.None)
		// Raw cumulative gains are {-3,-2,-4,0}; their arithmetic halves
		// are {-2,-1,-2,0}. Phase belongs to those totals, across all groups.
		exponents := [4]f64{2, 1, 2, 0}
		phases := [4]f64{-1, 1, 1, 1}
		window := 0
		for length, group in info.group_length[:info.groups] {
			want := phases[group] * math.pow(2.0, exponents[group] / 8)
			for _ in 0 ..< length {
				testing.expect_value(t, d.channel[0].spectrum[window * (n / 8)], f64(1))
				testing.expect(t, abs(d.channel[1].spectrum[window * (n / 8)] - want) < 2e-14)
				window += 1
			}
		}
	}
}

@(test)
test_literal_signed_coupling_two_band_codewords :: proc(t: ^testing.T) {
	// Literal codewords are ISO14496-3 Table4.A.1 facts, not values obtained
	// through production Huffman encoding. The expected gains distinguish
	// the 2009 cumulative split from per-delta arithmetic half (13818-7:2004).
	Case :: struct {
		name:  string,
		code:  [2]aac.Huffman_Code,
		delta: [2]int,
		gain:  [2]f64,
	}
	cases := [4]Case {
		{"minus1_minus1", {{3, 0x4}, {3, 0x4}}, {-1, -1}, {-2, 2}},
		{"plus1_plus1", {{4, 0xa}, {4, 0xa}}, {1, 1}, {-1, 0.5}},
		{"minus3_plus1", {{5, 0x1a}, {4, 0xa}}, {-3, 1}, {-4, 2}},
		{"plus3_minus1", {{5, 0x1b}, {3, 0x4}}, {3, -1}, {-0.5, 0.5}},
	}
	d := new(Decoder); defer free(d)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [2048]f32
	for item in cases {
		for code, band in item.code do testing.expect_value(t, aac.CODEBOOKS[0][60 + item.delta[band]], code)
		testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 2}), Error.None)
		w := common.init_bit_writer(&buf)
		feature_signed_two_band_cce(&w, item.code, 100)
		feature_end(&w)
		_, err := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.None)
		for channel in 0 ..< 2 do for bin in 0 ..< 1024 {
			want: f64
			if bin == 0 || bin == 4 do want = channel == 0 ? 1 : item.gain[bin / 4]
			testing.expect_value(t, d.channel[channel].spectrum[bin], want)
		}
		when FEATURE_EXPORT {
			export: [dynamic]u8; defer delete(export)
			ew := common.init_bit_writer(&export)
			config := feature_coupling_program(t, &ew, 1024, false)
			feature_signed_two_band_cce(&ew, item.code, 164)
			feature_end(&ew)
			feature_export(t, fmt.tprintf("cce_signed_delta_%s", item.name), config, export[:])
		}
	}
}

@(private)
feature_signed_two_band_cce :: proc(
	w: ^common.Bit_Writer,
	code: [2]aac.Huffman_Code,
	gain_base: int,
) {
	info := feature_info(3, 1024)
	info.max_sfb = 2
	common.write_bits(w, 1, 3); common.write_bits(w, 0, 4); common.write_bits(w, 0, 1)
	for _ in 0 ..< 2 do feature_channel(w, info, false)
	common.write_bits(w, 2, 3); common.write_bits(w, 4, 4)
	common.write_bits(w, 0, 1); common.write_bits(w, 0, 3)
	common.write_bits(w, 1, 1); common.write_bits(w, 0, 4); common.write_bits(w, 3, 2)
	common.write_bits(w, 1, 1); common.write_bits(w, 1, 1); common.write_bits(w, 3, 2)
	feature_channel(w, info, true, gain_base)
	common.write_bits(w, 0, 1) // differential gain list
	for word in code do common.write_bits(w, word.bits, int(word.length))
}

@(test)
test_lfe_restrictions_and_coupling_refusals_preserve_histories :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [6 * 1024]f32
	config := Config {
		sample_rate = 48000,
		channels    = 6,
	}
	layout, _ := aac.resolve_channel_layout(config)
	testing.expect_value(t, init_decoder(d, config), Error.None)
	for mode in 0 ..< 3 {
		w := common.init_bit_writer(&buf)
		for element in layout.elements[:layout.element_count] {
			feature_audio(
				&w,
				element,
				3,
				1024,
				true,
				element.kind == .LFE && mode == 2,
				element.kind == .LFE && mode == 0 ? aac.Window_Sequence.Short : .Long,
				element.kind == .LFE && mode == 1 ? 1 : 0,
			)
		}
		feature_end(&w)
		for &v in pcm do v = -99
		_, err := decode_frame(d, buf[:], pcm[:])
		testing.expect_value(t, err, Error.Invalid_Data)
		testing.expect(t, feature_banks_zero(d.bank[:]) && d.noise_seed == 1)
		for value in pcm do testing.expect_value(t, value, f32(-99))
	}
	// A dependent CCE must share the target's complete window state.
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 2}), Error.None)
	w := common.init_bit_writer(&buf)
	feature_audio(&w, {.CPE, 0, 0, 2}, 3, 1024, false)
	feature_cce(&w, 3, 1024, false, false, 0, true, false, 0, false, .Short)
	feature_end(&w)
	_, mismatch := decode_frame(
		d,
		buf[:],
		pcm[:],
	); testing.expect_value(t, mismatch, Error.Invalid_Data)
	for value in pcm do testing.expect_value(t, value, f32(-99))
	// Every physical byte truncation rejects before coupling history publication.
	w = common.init_bit_writer(&buf)
	feature_audio(&w, {.CPE, 0, 0, 2}, 3, 1024, false)
	feature_cce(&w, 3, 1024, true, true, 3, true, false, 2)
	feature_end(&w)
	for cut in 0 ..< len(buf) {
		_, err := decode_frame(d, buf[:cut], pcm[:])
		testing.expect(t, err != .None)
		testing.expect(
			t,
			feature_banks_zero(d.bank[:]) &&
			feature_banks_zero(d.coupling_bank[:]) &&
			d.noise_seed == 1,
		)
	}
	_, err := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.None)
}

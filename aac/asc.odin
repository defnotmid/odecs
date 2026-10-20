package aac

import common "../common"

// The compact two-byte ASC supports predefined layouts and both LC frame
// lengths. PCE layouts use the general writer below.
audio_specific_config :: proc(c: Config) -> (out: [2]u8, err: Error) {
	if e := validate_config(c); e != .None do return {}, e
	i, configuration := sample_rate_index(c.sample_rate), channel_configuration(c)
	if configuration == 0 do return {}, .Unsupported_Transport
	return {
			u8(2 << 3 | i >> 1),
			u8((i & 1) << 7 | configuration << 3 | (resolved_frame_samples(c) == 960 ? 4 : 0)),
		},
		.None
}

write_audio_specific_config :: proc(w: ^common.Bit_Writer, c: Config) -> Error {
	if e := validate_config(c); e != .None do return e
	if e := reserve_writer_bits(w, 16 + 2400); e != .None do return e
	start := common.bits_written(w)
	common.write_bits(w, 2, 5); common.write_bits(w, u32(sample_rate_index(c.sample_rate)), 4)
	configuration := channel_configuration(c)
	common.write_bits(w, u32(configuration), 4)
	common.write_bits(w, resolved_frame_samples(c) == 960 ? 1 : 0, 1)
	common.write_bits(w, 0, 2) // dependsOnCoreCoder, extensionFlag
	if configuration == 0 {
		p, err := default_program_config(c)
		if err != .None do return err
		return write_program_config_element(w, &p, start)
	}
	return .None
}

append_audio_specific_config :: proc(out: ^[dynamic]u8, c: Config) -> Error {
	if e := validate_config(c); e != .None do return e
	w := common.Bit_Writer {
		buf = out,
	}
	if e := write_audio_specific_config(&w, c); e != .None do return e
	common.write_align_zero(&w)
	return .None
}

// Read one base LC configuration at the current bit position. Embedded LATM
// version0 has no ASC length and therefore must not probe payload bits for an
// optional sync extension. Length-delimited standalone parsing checks those.
read_audio_specific_config :: proc(r: ^Bit_Reader) -> (config: Config, err: Error) {
	if r == nil do return {}, .Invalid_Config
	start := r.pos
	object_type := read_bits(r, 5)
	if object_type == 31 do object_type = 32 + read_bits(r, 6)
	i := int(read_bits(r, 4))
	rate := i < len(SAMPLE_RATES) ? SAMPLE_RATES[i] : 0
	if i == 15 do rate = int(read_bits(r, 24))
	configuration := int(read_bits(r, 4))
	if r.err != .None do return {}, r.err
	if object_type != 2 do return {}, .Unsupported_Profile
	if configuration > 7 do return {}, .Unsupported_Channels
	config = {
		sample_rate = rate,
		channels    = channels_for_configuration(configuration),
		use_pce     = configuration == 0,
	}
	if read_flag(r) do config.frame_samples = 960
	dependency := read_flag(r)
	if dependency do _ = read_bits(r, 14)
	extension := read_flag(r)
	if r.err != .None do return {}, r.err
	// ISO/IEC 14496-3:2009 4.5.1 requires extensionFlag zero for LC
	// (AOT2), even though Table4.1 describes its syntax for other profiles.
	if dependency || extension do return {}, .Unsupported_Tool
	if configuration == 0 {
		p, e := read_program_config_element(r, start)
		if e != .None do return {}, e
		layout, le := program_channel_layout(&p)
		if le != .None do return {}, le
		config.program_config, config.channels = p, layout.channels
	}
	return config, validate_config(config)
}

parse_audio_specific_config :: proc(data: []u8) -> (config: Config, err: Error) {
	r := Bit_Reader {
		data = data,
	}
	config, err = read_audio_specific_config(&r)
	if err != .None do return {}, err
	// A backward-compatible sync extension (1.6.5.4) that explicitly signals
	// SBR absent (extension object type 5, sbrPresentFlag 0) describes plain
	// LC; FFmpeg writes it by default. Present SBR/PS is outside the LC-only
	// contract. Zero padding is harmless; arbitrary trailing configuration is
	// not accepted.
	if len(data) > max(int) / 8 do return {}, .Invalid_Data
	remaining := len(data) * 8 - r.pos
	if remaining >= 11 {
		probe := r
		if read_bits(&probe, 11) == 0x2b7 {
			if read_bits(&probe, 5) != 5 || read_flag(&probe) || probe.err != .None do return {}, .Unsupported_Profile
			r = probe
		}
	}
	for r.pos < len(data) * 8 {
		if read_flag(&r) do return {}, .Invalid_Data
	}
	return config, .None
}

package aac_decoder

import aac ".."

@(private)
decode_mux_access_units :: proc(
	d: ^Decoder,
	mux: aac.LATM_State,
	frame: ^aac.LATM_Frame,
	output: []f32,
) -> (
	samples: int,
	err: Error,
) {
	if frame.config.sample_rate != d.config.sample_rate || frame.config.channels != d.config.channels || aac.resolved_frame_samples(frame.config) != d.frame_samples do return 0, .Invalid_Config
	n := d.config.channels * d.frame_samples
	if len(output) < frame.access_unit_count * n do return 0, .Output_Too_Small
	// The mux's current ASC owns the mapping on every access unit, including
	// a new configuration returning from an explicit PCE to a predefined map.
	layout, e := aac.resolve_channel_layout(frame.config)
	if e != .None do return 0, e
	program := frame.config.program_config
	explicit_layout := frame.config.use_pce && aac.program_config_present(&program)
	if frame.access_unit_count == 1 {
		unit := frame.access_units[0]
		bytes: int
		bytes, e = parse_raw_block(
			d,
			unit,
			layout,
			program,
			explicit_layout,
			false,
			&d.dynamic_range,
			false,
			0,
		)
		if e != .None do return 0, e
		if bytes != len(unit) do return 0, .Invalid_Data
		if e = render_single_block(d, output); e != .None do return 0, e
		commit_frame_metadata(d)
		d.latm = mux
		return d.frame_samples, .None
	}
	copy(d.pending_bank[:d.config.channels], d.bank[:d.config.channels])
	staged_coupling: [16]bool
	seed := d.noise_seed
	history_layout, history_program := d.layout, d.program
	drc := d.dynamic_range
	for unit, index in frame.access_units[:frame.access_unit_count] {
		bytes: int
		bytes, e = parse_raw_block(
			d,
			unit,
			layout,
			program,
			explicit_layout,
			false,
			&drc,
			false,
			0,
		)
		if e != .None do return 0, e
		if bytes != len(unit) do return 0, .Invalid_Data
		stage_coupling_banks(d, &staged_coupling)
		if e = render_raw_block(d, d.pending_bank[:], d.pending_coupling_bank[:], &seed, d.pending_pcm[index * n:(index + 1) * n], history_layout); e != .None do return 0, e
		drc = resolve_frame_dynamic_range(d, &history_layout, &history_program)
		layout, program, explicit_layout = d.frame.layout, d.frame.program, d.frame.explicit_layout
		history_layout, history_program = layout, program
	}
	commit_staged_banks(d, &staged_coupling)
	d.noise_seed = seed
	d.layout, d.program, d.explicit_layout, d.dynamic_range, d.latm =
		layout, program, explicit_layout, drc, mux
	copy(output[:n * frame.access_unit_count], d.pending_pcm[:n * frame.access_unit_count])
	return d.frame_samples * frame.access_unit_count, .None
}

// One complete LOAS/LATM mux unit commits all its raw access units together.
// The transport config and retained PCM/history staging survive failed retries.
decode_loas_frame :: proc(
	d: ^Decoder,
	data: []u8,
	output: []f32,
) -> (
	consumed, samples: int,
	err: Error,
) {
	if d == nil || !d.initialized do return 0, 0, .Invalid_State
	mux := d.latm
	frame, bytes, e := aac.parse_loas(&mux, data, d.latm_scratch[:])
	if e != .None do return 0, 0, e
	n, de := decode_mux_access_units(d, mux, &frame, output)
	if de != .None do return 0, 0, de
	return bytes, n, .None
}

decode_latm_frame :: proc(d: ^Decoder, data: []u8, output: []f32) -> (samples: int, err: Error) {
	if d == nil || !d.initialized do return 0, .Invalid_State
	mux := d.latm
	frame, e := aac.parse_latm(&mux, data, d.latm_scratch[:])
	if e != .None do return 0, e
	return decode_mux_access_units(d, mux, &frame, output)
}

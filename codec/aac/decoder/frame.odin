package aac_decoder

import aac ".."
import "core:math"

@(private)
Frame_Element :: struct {
	kind:                    aac.Element_Kind,
	tag:                     u8,
	first_channel, channels: int,
	common:                  bool,
	ms:                      [8][64]bool,
}
@(private)
Frame_Info :: struct {
	element:                                      [aac.MAX_CHANNELS]Frame_Element,
	element_count, channel_count, coupling_count: int,
	output_channel:                               [aac.MAX_CHANNELS]int,
	layout:                                       aac.Channel_Layout,
	program:                                      aac.Program_Config,
	explicit_layout:                              bool,
	tagged_drc_present:                           [16]bool,
	base_drc:                                     ^Dynamic_Range,
	crc:                                          u16,
}

@(private)
add_crc_range :: proc(r: ^aac.Bit_Reader, crc: ^u16, first, end, padded_bits: int) {
	if r.err != .None do return
	value, err := aac.crc16_update_range(r.data, crc^, {first, end, padded_bits})
	if err != .None {r.err = err; return}
	crc^ = value
}

@(private)
read_audio_element :: proc(
	d: ^Decoder,
	r: ^aac.Bit_Reader,
	kind: aac.Element_Kind,
	protected: bool,
) {
	f := &d.frame
	first := r.pos
	tag := u8(read(r, 4))
	if r.err != .None do return
	channels := kind == .CPE ? 2 : 1
	if f.element_count >= len(f.element) ||
	   channels > d.config.channels - f.channel_count {r.err = .Invalid_Data; return}
	for old in f.element[:f.element_count] {
		if old.kind == kind && old.tag == tag {r.err = .Invalid_Data; return}
	}
	element := &f.element[f.element_count]
	element^ = {
		kind          = kind,
		tag           = tag,
		first_channel = f.channel_count,
		channels      = channels,
	}
	first_channel := f.channel_count
	f.element_count += 1; f.channel_count += channels
	for &channel in d.channel[first_channel:first_channel + channels] {
		channel.spectrum = {}; channel.tns_count = {}
	}
	if kind == .CPE {
		element.common = flag(r)
		if element.common {
			d.channel[first_channel].ics = ics_info(r, d.rate_index, d.frame_samples)
			d.channel[first_channel + 1].ics = d.channel[first_channel].ics
			if r.err != .None do return
			mask := read(r, 2)
			if mask == 3 {r.err = .Invalid_Data; return}
			for g in 0 ..< d.channel[first_channel].ics.groups do for b in 0 ..< d.channel[first_channel].ics.max_sfb {
				element.ms[g][b] = mask == 2 || (mask == 1 && flag(r))
			}
		}
	}
	read_channel(d, r, &d.channel[first_channel], element.common)
	second := r.pos
	if channels == 2 && r.err == .None do read_channel(d, r, &d.channel[first_channel + 1], element.common)
	if r.err != .None do return
	for side in 0 ..< channels {
		c := &d.channel[first_channel + side]
		for g in 0 ..< c.ics.groups do for b in 0 ..< c.ics.max_sfb {
			if c.codebook[g][b] >= 14 && (!element.common || side == 0) {r.err = .Invalid_Data; return}
		}
		if kind == .LFE {
			if c.ics.sequence != .Long ||
			   c.ics.shape != 0 ||
			   c.tns_present {r.err = .Invalid_Data; return}
			for coefficient in c.spectrum[12:d.frame_samples] {
				if coefficient != 0 {r.err = .Invalid_Data; return}
			}
			// PNS cannot reconstruct out-of-band LFE lines after this check.
			for b in 0 ..< c.ics.max_sfb {
				if c.codebook[0][b] == 13 &&
				   c.ics.offsets[b + 1] > 12 {r.err = .Invalid_Data; return}
			}
		}
	}
	if protected {
		add_crc_range(r, &f.crc, first, r.pos, 192)
		if channels == 2 do add_crc_range(r, &f.crc, second, r.pos, 128)
	}
}

@(private)
resolve_output_channels :: proc(d: ^Decoder) -> Error {
	f := &d.frame
	if f.channel_count != d.config.channels do return .Invalid_Data
	used: [aac.MAX_CHANNELS]bool
	for &wanted in f.layout.elements[:f.layout.element_count] {
		found := false
		for element, index in f.element[:f.element_count] {
			if used[index] || element.kind != wanted.kind || (f.explicit_layout && element.tag != wanted.tag) do continue
			if element.channels != wanted.channels do return .Invalid_Data
			used[index] = true; found = true
			if !f.explicit_layout do wanted.tag = element.tag
			for side in 0 ..< element.channels do f.output_channel[element.first_channel + side] = wanted.first_channel + side
			break
		}
		if !found do return .Invalid_Data
	}
	for value in used[:f.element_count] do if !value do return .Invalid_Data
	return .None
}

// Parse one ID_END-terminated block without publishing overlap, noise,
// program, metadata or output. Encounter-order scratch is mapped only after
// all tags and the optional program configuration have been validated.
@(private)
parse_raw_block :: proc(
	d: ^Decoder,
	data: []u8,
	layout: aac.Channel_Layout,
	program: aac.Program_Config,
	explicit_layout: bool,
	allow_program: bool,
	drc: ^Dynamic_Range,
	protected: bool,
	crc: u16,
) -> (
	consumed: int,
	err: Error,
) {
	f := &d.frame
	f.element_count, f.channel_count, f.coupling_count = 0, 0, 0
	f.layout, f.program, f.explicit_layout, f.crc = layout, program, explicit_layout, crc
	f.tagged_drc_present = {}
	f.base_drc = drc
	r := aac.Bit_Reader {
		data = data,
	}
	ended := false
	other_element_seen := false
	for r.err == .None && !ended {
		id := read(&r, 3)
		// ISO13818-7 §8.5.2.2 requires all PCEs before other syntactic
		// elements, including metadata; MPEG-4 retains this restriction.
		if id == 5 && other_element_seen {r.err = .Invalid_Data; break}
		if id != 5 do other_element_seen = true
		switch id {
		case 0:
			read_audio_element(d, &r, .SCE, protected)
		case 1:
			read_audio_element(d, &r, .CPE, protected)
		case 2:
			first := r.pos
			if f.coupling_count >= len(d.coupling) {r.err = .Invalid_Data; break}
			cc := &d.coupling[f.coupling_count]
			read_coupling(d, &r, cc)
			if r.err == .None do for old in d.coupling[:f.coupling_count] do if old.tag == cc.tag do r.err = .Invalid_Data
			f.coupling_count += 1
			if protected do add_crc_range(&r, &f.crc, first, r.pos, 192)
		case 3:
			read_audio_element(d, &r, .LFE, protected)
		case 4:
			first := r.pos
			_ = read(&r, 4)
			aligned := flag(&r)
			n := int(read(&r, 8)); if n == 255 do n += int(read(&r, 8))
			if aligned do aac.align_reader(&r)
			if r.err == .None do aac.skip_bits(&r, n * 8)
			if protected do add_crc_range(&r, &f.crc, first, r.pos, 0)
		case 5:
			first := r.pos
			p, e := aac.read_program_config_element(&r)
			if e != .None {r.err = e; break}
			l, le := aac.program_channel_layout(&p)
			if le != .None {r.err = le; break}
			if p.mono_mixdown_present || p.stereo_mixdown_present {r.err = .Invalid_Data; break}
			if allow_program {
				if p.sample_rate != d.config.sample_rate ||
				   l.channels != d.config.channels {r.err = .Invalid_Config; break}
				f.program, f.layout, f.explicit_layout = p, l, true
			}
			if protected do add_crc_range(&r, &f.crc, first, r.pos, 0)
		case 6:
			read_fill(d, &r)
		case 7:
			ended = true
		}
	}
	if r.err != .None do return 0, r.err
	if !ended do return 0, .Invalid_Data
	aac.align_reader(&r)
	if r.err != .None do return 0, r.err
	if e := resolve_output_channels(d); e != .None do return 0, e
	if e := resolve_coupling(d); e != .None do return 0, e
	return r.pos / 8, .None
}

@(private)
synthesize_channel :: proc(d: ^Decoder, bank: ^aac.Filterbank, c: ^Channel, output: []f32) {
	n := d.frame_samples
	switch d.config.channels {
	case 1:
		aac.synthesize_to(
			1,
			&d.transform,
			bank,
			c.ics.sequence,
			c.ics.shape,
			c.spectrum[:n],
			output,
		)
	case 2:
		aac.synthesize_to(
			2,
			&d.transform,
			bank,
			c.ics.sequence,
			c.ics.shape,
			c.spectrum[:n],
			output,
		)
	case 3:
		aac.synthesize_to(
			3,
			&d.transform,
			bank,
			c.ics.sequence,
			c.ics.shape,
			c.spectrum[:n],
			output,
		)
	case 4:
		aac.synthesize_to(
			4,
			&d.transform,
			bank,
			c.ics.sequence,
			c.ics.shape,
			c.spectrum[:n],
			output,
		)
	case 5:
		aac.synthesize_to(
			5,
			&d.transform,
			bank,
			c.ics.sequence,
			c.ics.shape,
			c.spectrum[:n],
			output,
		)
	case 6:
		aac.synthesize_to(
			6,
			&d.transform,
			bank,
			c.ics.sequence,
			c.ics.shape,
			c.spectrum[:n],
			output,
		)
	case 7:
		aac.synthesize_to(
			7,
			&d.transform,
			bank,
			c.ics.sequence,
			c.ics.shape,
			c.spectrum[:n],
			output,
		)
	case 8:
		aac.synthesize_to(
			8,
			&d.transform,
			bank,
			c.ics.sequence,
			c.ics.shape,
			c.spectrum[:n],
			output,
		)
	}
}

// All potentially failing syntax/CRC/target validation precedes this owner.
// Math touches only scratch until coupling values have been checked; noise
// becomes committed together with completed filterbank histories.
@(private)
render_raw_block :: proc(
	d: ^Decoder,
	banks: []aac.Filterbank,
	coupling_banks: []aac.Filterbank,
	seed: ^u32,
	output: []f32,
	old_layout: aac.Channel_Layout,
) -> Error {
	f := &d.frame
	next_seed := seed^
	for &element in f.element[:f.element_count] {
		element_stereo_and_noise(
			d.channel[element.first_channel:element.first_channel + element.channels],
			&next_seed,
			element.common,
			&element.ms,
			d.frame_samples,
		)
	}
	no_ms: [8][64]bool
	for &cc in d.coupling[:f.coupling_count] {
		element_stereo_and_noise(
			(([^]Channel)(&cc.channel))[:1],
			&next_seed,
			false,
			&no_ms,
			d.frame_samples,
		)
		// The embedded SCE completes its own spectral tools for either mode.
		// cc_domain selects the target's TNS boundary; dependent coupling
		// stops before synthesis, while independent coupling also runs IMDCT.
		apply_tns(&cc.channel, d.rate_index, d.frame_samples)
	}
	couple_before_or_after_tns(d, false)
	for &channel in d.channel[:f.channel_count] do apply_tns(&channel, d.rate_index, d.frame_samples)
	couple_before_or_after_tns(d, true)
	if f.coupling_count > 0 {
		for &channel in d.channel[:f.channel_count] do for value in channel.spectrum[:d.frame_samples] {
			if math.is_inf(value) || math.is_nan(value) do return .Invalid_Data
		}
	}
	if f.layout != old_layout {
		// A selected program or outside ASC can change canonical output order.
		// Filterbank history belongs to element kind/tag and channel side;
		// unmatched new elements start fresh after every possible refusal.
		d.remapped_bank = {}
		previous_layout := old_layout
		for wanted in f.layout.elements[:f.layout.element_count] {
			for previous in previous_layout.elements[:previous_layout.element_count] {
				if previous.kind != wanted.kind || previous.tag != wanted.tag || previous.channels != wanted.channels do continue
				for side in 0 ..< wanted.channels do d.remapped_bank[wanted.first_channel + side] = banks[previous.first_channel + side]
				break
			}
		}
		copy(banks, d.remapped_bank[:d.config.channels])
	}
	for &channel, encounter in d.channel[:f.channel_count] {
		out_channel := f.output_channel[encounter]
		synthesize_channel(d, &banks[out_channel], &channel, output[out_channel:])
	}
	for &cc in d.coupling[:f.coupling_count] {
		if !cc.independent do continue
		aac.synthesize_to(
			1,
			&d.transform,
			&coupling_banks[cc.tag],
			cc.channel.ics.sequence,
			cc.channel.ics.shape,
			cc.channel.spectrum[:d.frame_samples],
			d.coupling_pcm[:d.frame_samples],
		)
		for target in cc.target[:cc.target_count] {
			for side in 0 ..< (target.kind == .CPE ? 2 : 1) {
				list := side == 0 ? target.left_list : target.right_list
				if list < 0 do continue
				out_channel := f.output_channel[target.channel + side]
				gain := cc.gain[list].value
				for value, sample in d.coupling_pcm[:d.frame_samples] {
					i := sample * d.config.channels + out_channel
					output[i] = f32(f64(output[i]) + f64(value) * gain)
				}
			}
		}
	}
	if f.coupling_count > 0 {
		for value in output[:d.frame_samples * d.config.channels] {
			if math.is_inf(value) || math.is_nan(value) do return .Invalid_Data
		}
	}
	seed^ = next_seed
	return .None
}

@(private)
render_single_block :: proc(d: ^Decoder, output: []f32) -> Error {
	if d.frame.coupling_count == 0 do return render_raw_block(d, d.bank[:], d.coupling_bank[:], &d.noise_seed, output, d.layout)
	// Extreme coupling gains can overflow the caller's f32 representation.
	// Render CCE access units into retained transaction storage so even that
	// late math refusal preserves all committed histories and caller samples.
	copy(d.pending_bank[:d.config.channels], d.bank[:d.config.channels])
	staged_coupling: [16]bool
	stage_coupling_banks(d, &staged_coupling)
	seed := d.noise_seed
	n := d.frame_samples * d.config.channels
	e := render_raw_block(
		d,
		d.pending_bank[:],
		d.pending_coupling_bank[:],
		&seed,
		d.pending_pcm[:n],
		d.layout,
	)
	if e != .None do return e
	commit_staged_banks(d, &staged_coupling)
	d.noise_seed = seed
	copy(output[:n], d.pending_pcm[:n])
	return .None
}

@(private)
stage_coupling_banks :: proc(d: ^Decoder, staged: ^[16]bool) {
	for cc in d.coupling[:d.frame.coupling_count] {
		if !cc.independent || staged[cc.tag] do continue
		d.pending_coupling_bank[cc.tag] = d.coupling_bank[cc.tag]
		staged[cc.tag] = true
	}
}

@(private)
commit_staged_banks :: proc(d: ^Decoder, staged: ^[16]bool) {
	copy(d.bank[:d.config.channels], d.pending_bank[:d.config.channels])
	for present, tag in staged^ do if present do d.coupling_bank[tag] = d.pending_coupling_bank[tag]
}

@(private)
commit_frame_metadata :: proc(d: ^Decoder) {
	f := &d.frame
	d.dynamic_range = resolve_frame_dynamic_range(d, &d.layout, &d.program)
	d.layout, d.program, d.explicit_layout = f.layout, f.program, f.explicit_layout
}

// Decode one raw AAC-LC access unit into caller-owned interleaved PCM.
// The prefix entry also reports the byte-aligned ID_END boundary, allowing
// an enclosing transport to advance through multiple raw data blocks.
@(private)
decode_raw_unit :: proc(
	d: ^Decoder,
	data: []u8,
	output: []f32,
	exact: bool,
) -> (
	consumed, samples: int,
	err: Error,
) {
	if d == nil || !d.initialized do return 0, 0, .Invalid_State
	if len(output) < d.frame_samples * d.config.channels do return 0, 0, .Output_Too_Small
	bytes, e := parse_raw_block(
		d,
		data,
		d.layout,
		d.program,
		d.explicit_layout,
		d.allow_in_band_program,
		&d.dynamic_range,
		false,
		0,
	)
	if e != .None do return 0, 0, e
	if exact && bytes != len(data) do return 0, 0, .Invalid_Data
	if e = render_single_block(d, output); e != .None do return 0, 0, e
	commit_frame_metadata(d)
	return bytes, d.frame_samples, .None
}

decode_frame_prefix :: proc(
	d: ^Decoder,
	data: []u8,
	output: []f32,
) -> (
	consumed, samples: int,
	err: Error,
) {
	return decode_raw_unit(d, data, output, false)
}

decode_frame :: proc(d: ^Decoder, data: []u8, output: []f32) -> (samples: int, err: Error) {
	_, samples, err = decode_raw_unit(d, data, output, true)
	return
}

decode_adts_frame :: proc(
	d: ^Decoder,
	data: []u8,
	output: []f32,
) -> (
	consumed, samples: int,
	err: Error,
) {
	h, payload, e := aac.parse_adts(data)
	if e != .None do return 0, 0, e
	if d == nil || !d.initialized do return 0, 0, .Invalid_State
	if h.config.sample_rate != d.config.sample_rate || (h.config.channels != 0 && h.config.channels != d.config.channels) || d.frame_samples != 1024 do return 0, 0, .Invalid_Config
	n := d.frame_samples * d.config.channels
	if len(output) < n * h.raw_block_count do return 0, 0, .Output_Too_Small
	outside_program := d.config.use_pce && aac.program_config_present(&d.config.program_config)
	allow_program := h.channel_configuration == 0 && !outside_program
	layout, program, explicit_layout := d.layout, d.program, d.explicit_layout
	if h.channel_configuration != 0 {
		// Each nonzero ADTS header owns its default mapping. A previous
		// in-band PCE cannot authorize extra elements after that transition.
		layout, e = aac.resolve_channel_layout(h.config)
		if e != .None do return 0, 0, e
		program, explicit_layout = {}, false
	} else if outside_program {
		// An explicit outside ASC remains authoritative even after an ADTS
		// header temporarily selected a predefined channel configuration.
		layout, e = aac.resolve_channel_layout(d.config)
		if e != .None do return 0, 0, e
		program, explicit_layout = d.config.program_config, true
	}
	if h.raw_block_count == 1 {
		crc: u16
		if h.protected {
			value, ce := aac.adts_block_crc_seed(h, data, 0)
			if ce != .None do return 0, 0, ce
			crc = value
		}
		bytes, pe := parse_raw_block(
			d,
			payload,
			layout,
			program,
			explicit_layout,
			allow_program,
			&d.dynamic_range,
			h.protected,
			crc,
		)
		if pe != .None do return 0, 0, pe
		if bytes != len(payload) do return 0, 0, .Invalid_Data
		if h.protected {
			if ce := aac.validate_adts_block_crc(h, 0, d.frame.crc); ce != .None do return 0, 0, ce
		}
		if pe = render_single_block(d, output); pe != .None do return 0, 0, pe
		commit_frame_metadata(d)
		return h.frame_bytes, d.frame_samples, .None
	}
	// A late block or CRC refusal must preserve both prior histories and the
	// caller's entire PCM destination. Durable staging is charged only here.
	copy(d.pending_bank[:d.config.channels], d.bank[:d.config.channels])
	staged_coupling: [16]bool
	seed := d.noise_seed
	drc := d.dynamic_range
	position := h.header_bytes
	for block in 0 ..< h.raw_block_count {
		end := h.frame_bytes
		if h.protected {position = h.block_offsets[block]; end = h.block_ends[block]}
		crc: u16
		if h.protected {
			value, ce := aac.adts_block_crc_seed(h, data, block)
			if ce != .None do return 0, 0, ce
			crc = value
		}
		bytes, pe := parse_raw_block(
			d,
			data[position:end],
			layout,
			program,
			explicit_layout,
			allow_program,
			&drc,
			h.protected,
			crc,
		)
		if pe != .None do return 0, 0, pe
		if h.protected && bytes != end - position do return 0, 0, .Invalid_Data
		if h.protected {
			if ce := aac.validate_adts_block_crc(h, block, d.frame.crc); ce != .None do return 0, 0, ce
		}
		stage_coupling_banks(d, &staged_coupling)
		if pe = render_raw_block(d, d.pending_bank[:], d.pending_coupling_bank[:], &seed, d.pending_pcm[block * n:(block + 1) * n], layout); pe != .None do return 0, 0, pe
		drc = resolve_frame_dynamic_range(d, &layout, &program)
		layout, program, explicit_layout = d.frame.layout, d.frame.program, d.frame.explicit_layout
		position += bytes
	}
	if !h.protected && position != h.frame_bytes do return 0, 0, .Invalid_Data
	commit_staged_banks(d, &staged_coupling)
	d.noise_seed = seed
	d.layout, d.program, d.explicit_layout, d.dynamic_range = layout, program, explicit_layout, drc
	copy(output[:n * h.raw_block_count], d.pending_pcm[:n * h.raw_block_count])
	return h.frame_bytes, d.frame_samples * h.raw_block_count, .None
}

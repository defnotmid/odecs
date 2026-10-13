package aac_decoder

import aac ".."

// DRC is exposed as durable metadata. PCM keeps its full dynamic range;
// interpreting exclusions, interpolation and a user target level is a
// separate playback decision rather than an implicit decoding gain.
Dynamic_Range_Bands :: struct {
	present:              bool,
	band_count:           int,
	interpolation_scheme: u8, // MPEG-4 QMF interpolation; reserved in MPEG-2
	band_top:             [16]u8,
	negative:             [16]bool,
	control:              [16]u8, // magnitude in quarter-decibel units
}
Dynamic_Range_Info :: struct {
	present, program_tag_present: bool,
	program_tag:                  u8,
	excluded:                     [70]bool,
	excluded_count:               int,
	reference_level_present:      bool,
	reference_level:              u8,
	bands:                        Dynamic_Range_Bands,
}
Dynamic_Range :: struct {
	reference_level_present: bool,
	reference_level:         u8,
	// Canonical audio channels occupy [0:Config.channels]. Independent CCE
	// metadata occupies Config.channels + element tag (all 16 tag values).
	// FIL exclusion ordinals are lowered into these stable owners at commit.
	channel:                 [aac.MAX_CHANNELS + 16]Dynamic_Range_Bands,
	last:                    Dynamic_Range_Info,
}

@(private)
fill_read :: proc(r: ^aac.Bit_Reader, end, bits: int) -> u32 {
	if r.err != .None do return 0
	if bits > end - r.pos {r.err = .Invalid_Data; return 0}
	return read(r, bits)
}

@(private)
read_dynamic_range :: proc(r: ^aac.Bit_Reader, end, frame_samples: int) -> Dynamic_Range_Info {
	info: Dynamic_Range_Info
	info.present = true
	info.program_tag_present = fill_read(r, end, 1) != 0
	if info.program_tag_present {
		info.program_tag = u8(fill_read(r, end, 4))
		_ = fill_read(r, end, 4) // reserved
	}
	if fill_read(r, end, 1) != 0 {
		for {
			if info.excluded_count >= len(info.excluded) {r.err = .Invalid_Data; return info}
			for _ in 0 ..< 7 {
				info.excluded[info.excluded_count] = fill_read(r, end, 1) != 0
				info.excluded_count += 1
			}
			more := fill_read(r, end, 1) != 0
			if r.err != .None || !more do break
		}
	}
	info.bands.present, info.bands.band_count = true, 1
	if fill_read(r, end, 1) != 0 {
		info.bands.band_count += int(fill_read(r, end, 4))
		// The same four bits were reserved in MPEG-2. Retain their value;
		// MPEG-4 Table4.102 defines the QMF interpolation scheme here.
		info.bands.interpolation_scheme = u8(fill_read(r, end, 4))
		for i in 0 ..< info.bands.band_count {
			info.bands.band_top[i] = u8(fill_read(r, end, 8))
			if i > 0 &&
			   info.bands.band_top[i] <=
				   info.bands.band_top[i - 1] {r.err = .Invalid_Data; return info}
		}
	} else {
		info.bands.band_top[0] = u8(frame_samples / 4 - 1)
	}
	info.reference_level_present = fill_read(r, end, 1) != 0
	if info.reference_level_present {
		info.reference_level = u8(fill_read(r, end, 7))
		_ = fill_read(r, end, 1)
	}
	for i in 0 ..< info.bands.band_count {
		info.bands.negative[i] = fill_read(r, end, 1) != 0
		info.bands.control[i] = u8(fill_read(r, end, 7))
	}
	return info
}

@(private)
publish_dynamic_range :: proc(state: ^Dynamic_Range, info: Dynamic_Range_Info) {
	state.last = info
	if info.reference_level_present {
		state.reference_level_present = true; state.reference_level = info.reference_level
	}
	for &channel, index in state.channel {
		if index < info.excluded_count && info.excluded[index] do continue
		channel = info.bands
	}
}

@(private)
read_fill :: proc(d: ^Decoder, r: ^aac.Bit_Reader) {
	count := int(read(r, 4))
	if count == 15 do count += int(read(r, 8)) - 1
	if r.err != .None do return
	if count * 8 > len(r.data) * 8 - r.pos {r.err = .Truncated; return}
	end := r.pos + count * 8
	for r.pos < end && r.err == .None {
		extension := fill_read(r, end, 4)
		switch extension {
		case 11:
			info := read_dynamic_range(r, end, d.frame_samples)
			if r.err != .None do return
			// Retain separate tag slots so only the selected program owns
			// this access unit's committed metadata updates.
			if info.program_tag_present {
				if !d.frame.tagged_drc_present[info.program_tag] do d.drc_scratch[info.program_tag] = {}
				publish_dynamic_range(&d.drc_scratch[info.program_tag], info)
				d.frame.tagged_drc_present[info.program_tag] = true
			} else {
				for &state, tag in d.drc_scratch {
					if !d.frame.tagged_drc_present[tag] do state = {}
					publish_dynamic_range(&state, info)
					d.frame.tagged_drc_present[tag] = true
				}
			}
		case 13, 14:
			r.err = .Unsupported_Profile; return
		case 2:
			// MPEG-4 Table4.57 ANC_DATA has its own byte count, so a
			// following DRC extension remains visible in the same FIL element.
			version := fill_read(r, end, 4)
			if version != 0 {aac.skip_bits(r, end - r.pos); continue}
			bytes := 0
			for r.err == .None {
				part := int(fill_read(r, end, 8))
				bytes += part
				if bytes > (end - r.pos) / 8 {r.err = .Invalid_Data; return}
				if part != 255 do break
			}
			if r.err == .None do aac.skip_bits(r, bytes * 8)
		case 1:
			if fill_read(r, end, 4) != 0 {r.err = .Invalid_Data; return}
			for r.pos < end && r.err == .None {
				if fill_read(r, end, 8) != 0xa5 {r.err = .Invalid_Data; return}
			}
		case:
			// Reserved extensions and EXT_FILL have explicitly opaque remaining
			// payload. They consume this extension's remaining byte count.
			aac.skip_bits(r, end - r.pos)
		}
	}
}

// FIL scratch records only updates, not a copied channel history. This lets
// this frame's program establish the actual output order before retained
// per-channel values are remapped and exclusions are interpreted.
@(private)
resolve_frame_dynamic_range :: proc(
	d: ^Decoder,
	old_layout: ^aac.Channel_Layout,
	old_program: ^aac.Program_Config,
) -> Dynamic_Range {
	f := &d.frame
	state := f.base_drc^
	if f.layout != old_layout^ {
		previous := state
		for wanted in f.layout.elements[:f.layout.element_count] {
			for side in 0 ..< wanted.channels do state.channel[wanted.first_channel + side] = {}
			for old in old_layout.elements[:old_layout.element_count] {
				if old.kind != wanted.kind || old.tag != wanted.tag || old.channels != wanted.channels do continue
				for side in 0 ..< wanted.channels do state.channel[wanted.first_channel + side] = previous.channel[old.first_channel + side]
				break
			}
		}
	}
	tag := f.explicit_layout ? f.program.tag : u8(0)
	if f.tagged_drc_present[tag] {
		updates := &d.drc_scratch[tag]
		if updates.reference_level_present {
			state.reference_level_present, state.reference_level = true, updates.reference_level
		}
		// PCE masks follow canonical program order. Without a PCE, audio
		// masks follow raw element encounter order, before independent CCEs.
		for encounter in 0 ..< f.channel_count {
			output := f.output_channel[encounter]
			ordinal := f.explicit_layout ? output : encounter
			update := updates.channel[ordinal]
			if update.present do state.channel[output] = update
		}
		ordinal := d.config.channels
		if f.explicit_layout {
			for entry in f.program.coupling[:f.program.coupling_count] {
				if !entry.independent do continue
				update := updates.channel[ordinal]
				if update.present do state.channel[d.config.channels + int(entry.tag)] = update
				ordinal += 1
			}
		} else {
			for cc in d.coupling[:f.coupling_count] {
				if !cc.independent do continue
				update := updates.channel[ordinal]
				if update.present do state.channel[d.config.channels + int(cc.tag)] = update
				ordinal += 1
			}
		}
		state.last = updates.last
	}
	return state
}

package main

import aac "../codec/aac"
import dec "../codec/aac/decoder"
import common "../codec/common"
import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) !=
	   3 {fmt.eprintln("usage: decode_aac input.aac|input.loas output.s16le"); os.exit(2)}
	data, error := os.read_entire_file(os.args[1], context.allocator)
	if error != nil {fmt.eprintln(error); os.exit(1)}
	defer delete(data)
	loas := len(data) >= 2 && data[0] == 0x56 && data[1] & 0xe0 == 0xe0
	config: aac.Config
	if loas {
		mux: aac.LATM_State
		scratch: [8191]u8
		frame, _, e := aac.parse_loas(&mux, data, scratch[:])
		if e != .None {fmt.eprintln(e); os.exit(1)}
		config = frame.config
	} else {
		header, payload, e := aac.parse_adts(data)
		if e != .None {fmt.eprintln(e); os.exit(1)}
		config, e = aac.adts_config(header, payload)
		if e != .None {fmt.eprintln(e); os.exit(1)}
	}
	d := new(dec.Decoder)
	if d == nil {fmt.eprintln(aac.Error.Allocation_Failed); os.exit(1)}
	defer free(d)
	if e := dec.init_decoder(d, config); e != .None {fmt.eprintln(e); os.exit(1)}
	// Retained transport output spans at most64 complete access units. Large
	// caller storage lives on the heap and is reused for every input frame.
	pcm := make([]f32, 64 * 8 * 1024)
	if raw_data(pcm) == nil {fmt.eprintln(aac.Error.Allocation_Failed); os.exit(1)}
	defer delete(pcm)
	out: [dynamic]u8
	defer delete(out)
	pos, frames, transport_frames, short, tns, pns, intensity := 0, 0, 0, 0, 0, 0, 0
	for pos < len(data) {
		consumed, samples: int
		e: aac.Error
		if loas {consumed, samples, e = dec.decode_loas_frame(d, data[pos:], pcm)} else {
			consumed, samples, e = dec.decode_adts_frame(d, data[pos:], pcm)
		}
		if e !=
		   .None {fmt.eprintfln("AAC decode frame %d at byte %d: %v", frames, pos, e); os.exit(1)}
		if consumed <= 0 ||
		   consumed > len(data) - pos ||
		   samples < 0 ||
		   samples > len(pcm) / config.channels {
			fmt.eprintln("invalid decoder output boundary"); os.exit(1)
		}
		first_frame, first_byte := frames, pos
		pos +=
			consumed; frames += samples / aac.resolved_frame_samples(config); transport_frames += 1
		// Decoder scratch describes the last AU of a transport frame. Keep the
		// existing counters, and report that scope explicitly for multi-AU muxes.
		for ch in 0 ..< config.channels {
			c := &d.channel[ch]
			if c.ics.sequence == .Short do short += 1
			for n in c.tns_count do tns += n
			for g in 0 ..< c.ics.groups do for b in 0 ..< c.ics.max_sfb {
				if c.codebook[g][b] == 13 do pns += 1
				if c.codebook[g][b] >= 14 do intensity += 1
			}
		}
		count := samples * config.channels
		first := len(out)
		if count > max(int) / 2 ||
		   first > max(int) - count * 2 {fmt.eprintln("PCM output size overflow"); os.exit(1)}
		end := first + count * 2
		if end > cap(out) {
			capacity := max(end, cap(out) <= max(int) / 2 ? cap(out) * 2 : end)
			if e := reserve(&out, capacity);
			   e != nil {fmt.eprintln("cannot reserve PCM output:", e); os.exit(1)}
		}
		if e := non_zero_resize(&out, end);
		   e != nil {fmt.eprintln("cannot extend PCM output:", e); os.exit(1)}
		packed, packing_error := common.pack_s16le(pcm[:count], out[first:])
		pcm_error: aac.Error
		switch packing_error {
		case .None:
		case .Non_Finite:
			pcm_error = .Invalid_Data
		case .Output_Too_Small:
			pcm_error = .Output_Too_Small
		}
		if pcm_error != .None {
			_ = non_zero_resize(&out, first + packed * 2)
			fmt.eprintfln("AAC PCM frame %d at byte %d: %v", first_frame, first_byte, pcm_error)
			os.exit(1)
		}
	}
	if os.write_entire_file(os.args[2], out[:]) != nil do os.exit(1)
	fmt.printfln(
		"AAC-LC: rate=%d channels=%d frame_samples=%d frames=%d transport_frames=%d short=%d tns=%d pns=%d intensity=%d bytes=%d transport=%s stats_scope=last_au_per_transport",
		config.sample_rate,
		config.channels,
		aac.resolved_frame_samples(config),
		frames,
		transport_frames,
		short,
		tns,
		pns,
		intensity,
		len(out),
		loas ? "loas" : "adts",
	)
}

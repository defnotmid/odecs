package aac_encoder

import aac ".."
import common "../../common"

@(private)
channel_offsets :: proc(e: ^Encoder, ch: int) -> []int {return(
		!e.lfe[ch] && e.work_stats.sequence == .Short ? aac.short_offsets(e.rate_index, e.frame_samples) : aac.long_offsets(e.rate_index, e.frame_samples) \
	)}
@(private)
channel_groups :: proc(e: ^Encoder, ch: int) -> int {return e.lfe[ch] ? 1 : e.groups}
@(private)
channel_bands :: proc(e: ^Encoder, ch: int) -> int {return e.coded_max_sfb[ch]}
@(private)
band_range :: proc(e: ^Encoder, ch, g, b: int) -> (first, end: int) {
	offsets := channel_offsets(e, ch)
	first = e.lfe[ch] ? offsets[b] : e.band_start[g][b]
	end = first + (offsets[b + 1] - offsets[b]) * (e.lfe[ch] ? 1 : e.group_length[g])
	return
}

@(private)
quantize :: proc(e: ^Encoder, adjustment: int) {
	for ch in 0 ..< e.config.channels {
		groups := channel_groups(e, ch)
		bands := e.lfe[ch] ? e.lfe_max_sfb : e.max_sfb
		gain := 100
		found := false
		for g in 0 ..< groups do for b in 0 ..< bands {
			if !found && e.tool[ch][g][b] == 0 && e.energy[ch][g][b] > 0 {gain = clamp(e.base_sf[ch][g][b] + adjustment, 0, 255); found = true}
		}
		e.global_gain[ch] = gain
		previous, noise, intensity := gain, gain - 90, 0
		first_noise := true
		for g in 0 ..< groups do for b in 0 ..< bands {
			tool := e.tool[ch][g][b]
			e.spectral_bits[ch][g][b] = 0
			if tool >= 13 {
				sf := e.base_sf[ch][g][b]
				if tool == 13 {
					sf = clamp(sf, noise - (first_noise ? 256 : 60), noise + (first_noise ? 255 : 60))
					first_noise = false; noise = sf
				} else {sf = clamp(sf, intensity - 60, intensity + 60); intensity = sf}
				e.sf[ch][g][b] = sf; e.codebook[ch][g][b] = tool
				continue
			}
			sf := clamp(e.base_sf[ch][g][b] + adjustment, max(0, previous - 60), min(255, previous + 60))
			e.sf[ch][g][b] = sf
			first, end := band_range(e, ch, g, b)
			scale := e.quant_factor[sf]
			maximum := quantize_band_into(e.companded[ch][first:end], e.negative[ch][first:end], e.quant[ch][first:end], scale)
			book: u8
			bits := 0
			if maximum > 0 {book, bits = choose_codebook_and_cost(e.quant[ch][first:end], maximum); previous = sf}
			e.codebook[ch][g][b] = book; e.spectral_bits[ch][g][b] = bits
		}
		e.coded_max_sfb[ch] = 0
		for g in 0 ..< groups do for b in 0 ..< bands do if e.codebook[ch][g][b] != 0 do e.coded_max_sfb[ch] = max(e.coded_max_sfb[ch], b + 1)
	}
	for element in e.layout.elements[:e.layout.element_count] do if element.kind == .CPE {
		left := element.first_channel; bands := max(e.coded_max_sfb[left], e.coded_max_sfb[left + 1])
		e.coded_max_sfb[left], e.coded_max_sfb[left + 1] = bands, bands
	}
}

@(private)
ics_bits :: proc(e: ^Encoder, ch: int) -> int {return(
		!e.lfe[ch] && e.work_stats.sequence == .Short ? 15 : 11 \
	)}
@(private)
write_ics_info :: proc(e: ^Encoder, w: ^common.Bit_Writer, ch: int) {
	sequence := e.lfe[ch] ? aac.Window_Sequence.Long : e.work_stats.sequence
	common.write_bits(w, 0, 1); common.write_bits(w, u32(sequence), 2)
	common.write_bits(w, e.lfe[ch] ? 0 : u32(e.options.window_shape), 1)
	common.write_bits(w, u32(channel_bands(e, ch)), sequence == .Short ? 4 : 6)
	if sequence == .Short {
		mask: u32
		for g in 0 ..< e.groups do for w in 1 ..< e.group_length[g] do mask |= 1 << uint(6 - (e.group_start[g] + w - 1))
		common.write_bits(w, mask, 7)
	} else {common.write_bits(w, 0, 1)}
}

@(private)
ms_mode :: proc(e: ^Encoder, left: int) -> u32 {
	any, all := false, true
	for g in 0 ..< e.groups do for b in 0 ..< channel_bands(e, left) {any = any || e.ms[left][g][b]; all = all && e.ms[left][g][b]}
	return !any ? 0 : (all ? 2 : 1)
}

@(private)
tns_present :: proc(e: ^Encoder, ch: int) -> bool {
	for filter in e.tns[ch] do if filter.order > 0 && channel_bands(e, ch) > filter.start_band do return true
	return false
}

@(private)
channel_bits :: proc(e: ^Encoder, ch: int, common_window: bool) -> int {
	short := !e.lfe[ch] && e.work_stats.sequence == .Short
	groups, bands := channel_groups(e, ch), channel_bands(e, ch)
	length_bits := short ? 3 : 5; escape := (1 << uint(length_bits)) - 1
	bits := 8 + 3 + (common_window ? 0 : ics_bits(e, ch))
	previous, noise, intensity := e.global_gain[ch], e.global_gain[ch] - 90, 0
	first_noise := true
	for g in 0 ..< groups {
		start := 0
		for start < bands {
			end := start + 1
			for end < bands && e.codebook[ch][g][end] == e.codebook[ch][g][start] do end += 1
			bits += 4 + ((end - start) / escape + 1) * length_bits; start = end
		}
		for b in 0 ..< bands {
			book := e.codebook[ch][g][b]; sf := e.sf[ch][g][b]
			if book == 0 do continue
			switch book {
			case 13:
				if first_noise {bits += 9; first_noise = false} else {bits += int(aac.CODEBOOKS[0][sf - noise + 60].length)}
				noise = sf
			case 14, 15:
				bits += int(aac.CODEBOOKS[0][sf - intensity + 60].length); intensity = sf
			case:
				bits += int(aac.CODEBOOKS[0][sf - previous + 60].length); previous = sf
			}
			bits += e.spectral_bits[ch][g][b]
		}
	}
	if tns_present(e, ch) {
		for w in 0 ..< (short ? 8 : 1) {
			bits += short ? 1 : 2
			if filter := &e.tns[ch][w]; filter.order > 0 && bands > filter.start_band do bits += 1 + (short ? 4 + 3 : 6 + 5) + 2 + filter.order * 4
		}
	}
	return bits
}

@(private)
raw_bits :: proc(e: ^Encoder) -> int {
	bits := e.pce_bytes * 8 + 3 //ID_END and zero alignment follow all elements.
	for element in e.layout.elements[:e.layout.element_count] {
		bits += 7
		pair := element.kind == .CPE
		if pair {
			bits += 1 + ics_bits(e, element.first_channel) + 2
			if ms_mode(e, element.first_channel) == 1 do bits += e.groups * channel_bands(e, element.first_channel)
		}
		for ch in element.first_channel ..< element.first_channel + element.channels do bits += channel_bits(e, ch, pair)
	}
	return (bits + 7) &~ 7
}

@(private)
write_channel :: proc(e: ^Encoder, w: ^common.Bit_Writer, ch: int, common_window: bool) {
	short := !e.lfe[ch] && e.work_stats.sequence == .Short
	groups, bands := channel_groups(e, ch), channel_bands(e, ch)
	length_bits := short ? 3 : 5; escape := (1 << uint(length_bits)) - 1
	common.write_bits(w, u32(e.global_gain[ch]), 8)
	if !common_window do write_ics_info(e, w, ch)
	for g in 0 ..< groups {
		b := 0
		for b < bands {
			book := e.codebook[ch][g][b]; end := b + 1
			for end < bands && e.codebook[ch][g][end] == book do end += 1
			common.write_bits(w, u32(book), 4)
			length := end - b
			for length >= escape {common.write_bits(w, u32(escape), length_bits); length -= escape}
			common.write_bits(w, u32(length), length_bits); b = end
		}
	}
	previous, noise, intensity := e.global_gain[ch], e.global_gain[ch] - 90, 0
	first_noise := true
	for g in 0 ..< groups do for b in 0 ..< bands {
		book := e.codebook[ch][g][b]; sf := e.sf[ch][g][b]
		if book == 0 do continue
		switch book {
		case 13:
			if first_noise {common.write_bits(w, u32(sf - noise + 256), 9); first_noise = false} else {write_huffman(w, 0, sf - noise + 60)}
			noise = sf
		case 14, 15:
			write_huffman(w, 0, sf - intensity + 60); intensity = sf
		case:
			write_huffman(w, 0, sf - previous + 60); previous = sf
		}
	}
	common.write_bits(w, 0, 1) //pulse_data_present
	present := tns_present(e, ch)
	common.write_bits(w, u32(present), 1)
	if present {
		offsets := channel_offsets(e, ch)
		for window in 0 ..< (short ? 8 : 1) {
			filter := &e.tns[ch][window]
			active := filter.order > 0 && bands > filter.start_band
			common.write_bits(w, active ? 1 : 0, short ? 1 : 2)
			if !active do continue
			common.write_bits(w, 1, 1) //four-bit reflection resolution
			common.write_bits(w, u32(len(offsets) - 1 - filter.start_band), short ? 4 : 6)
			common.write_bits(w, u32(filter.order), short ? 3 : 5)
			common.write_bits(w, 0, 2) //forward, uncompressed coefficients
			for coefficient in filter.coefficient[:filter.order] do common.write_bits(w, u32(u8(coefficient)) & 15, 4)
		}
	}
	common.write_bits(w, 0, 1) //gain_control_data_present
	for g in 0 ..< groups do for b in 0 ..< bands {
		book := int(e.codebook[ch][g][b]); if book == 0 || book >= 13 do continue
		first, end := band_range(e, ch, g, b); count := book <= 4 ? 4 : 2
		for k := first; k < end; k += count do write_tuple(w, book, e.quant[ch][k:k + count])
	}
}

@(private)
write_payload :: proc(e: ^Encoder, padded_bits: int = 0) {
	writer := common.init_bit_writer(&e.payload)
	append(&e.payload, ..e.pce_prefix[:e.pce_bytes])
	for element in e.layout.elements[:e.layout.element_count] {
		id := element.kind == .CPE ? 1 : (element.kind == .LFE ? 3 : 0)
		common.write_bits(&writer, u32(id), 3); common.write_bits(&writer, u32(element.tag), 4)
		pair := element.kind == .CPE
		if pair {
			common.write_bits(&writer, 1, 1); write_ics_info(e, &writer, element.first_channel)
			mode := ms_mode(e, element.first_channel); common.write_bits(&writer, mode, 2)
			if mode == 1 do for g in 0 ..< e.groups do for b in 0 ..< channel_bands(e, element.first_channel) do common.write_bits(&writer, u32(e.ms[element.first_channel][g][b]), 1)
		}
		for ch in element.first_channel ..< element.first_channel + element.channels do write_channel(e, &writer, ch, pair)
	}
	// CBR padding is an ordinary fill element; payload starts EXT_FILL
	// and carries zero bytes. Every candidate's coding cost excludes padding.
	for remaining := padded_bits - common.bits_written(&writer) - 3;
	    remaining >= 15;
	    remaining = padded_bits - common.bits_written(&writer) - 3 {
		bytes := min(269, (remaining - 7) / 8)
		if bytes >= 15 {bytes = min(bytes, (remaining - 15) / 8); if bytes < 15 do bytes = 14}
		if bytes <= 0 do break
		common.write_bits(&writer, 6, 3)
		common.write_bits(&writer, u32(min(bytes, 15)), 4)
		if bytes >= 15 do common.write_bits(&writer, u32(bytes - 14), 8)
		for _ in 0 ..< bytes do common.write_bits(&writer, 0, 8)
	}
	common.write_bits(&writer, 7, 3); common.write_align_zero(&writer)
}

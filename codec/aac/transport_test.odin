package aac

import common "../common"
import "core:mem"
import "core:testing"

@(private)
transport_test_crc16 :: proc(data: []u8, initial: u16, first, end, padded: int) -> u16 {
	// Explicit x^16 polynomial division, with input XORed before shifting.
	// The known external check value below also pins polynomial/init/final xor.
	count := padded == 0 ? end - first : padded
	crc := u32(initial)
	for i in 0 ..< count {
		bit: u32
		if first + i < end do bit = u32(data[(first + i) / 8] >> uint(7 - (first + i) % 8) & 1)
		if bit != 0 do crc ~= 0x8000
		crc <<= 1
		if crc & 0x10000 != 0 do crc ~= 0x18005
	}
	return u16(crc)
}

@(private)
transport_test_bytes_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) do return false
	for v, i in a do if v != b[i] do return false
	return true
}

@(test)
transport_crc_regions_and_known_vectors :: proc(t: ^testing.T) {
	text := [9]u8{'1', '2', '3', '4', '5', '6', '7', '8', '9'}
	crc, e := crc16_update_range(text[:], 0xffff, {0, 72, 0})
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, crc, u16(0xaee7))
	crc8, e8 := latm_config_crc(text[:], 0, 72)
	testing.expect_value(t, e8, Error.None)
	testing.expect_value(t, crc8, u8(0x0b))
	data: [64]u8
	for &b, i in data do b = u8(i * 37 + 19)
	for first in 0 ..< 16 do for n in ([8]int{0, 1, 7, 8, 127, 128, 192, 253}) do for padded in ([4]int{0, 128, 192, 256}) {
		got, err := crc16_update_range(data[:], 0x73ab, {first, first + n, padded})
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, got, transport_test_crc16(data[:], 0x73ab, first, first + n, padded))
	}
	for range in ([5]CRC_Range{{-1, 0, 0}, {0, -1, 0}, {8, 7, 0}, {0, 513, 0}, {0, 0, -1}}) {
		_, err := crc16_update_range(data[:], 0xffff, range)
		testing.expect_value(t, err, Error.Invalid_Config)
	}
}

@(test)
transport_asc_layout_and_pce_boundaries :: proc(t: ^testing.T) {
	for rate in SAMPLE_RATES do for channels in 1 ..= 8 do for samples in ([2]int{1024, 960}) {
		c := Config {
			sample_rate   = rate,
			channels      = channels,
			frame_samples = samples,
		}
		layout, le := resolve_channel_layout(c)
		testing.expect_value(t, le, Error.None)
		testing.expect_value(t, layout.channels, channels)
		next := 0
		for item in layout.elements[:layout.element_count] {
			testing.expect_value(t, item.first_channel, next)
			next += item.channels
		}
		data: [dynamic]u8
		defer delete(data)
		testing.expect_value(t, append_audio_specific_config(&data, c), Error.None)
		parsed, err := parse_audio_specific_config(data[:])
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, parsed.sample_rate, rate)
		testing.expect_value(t, parsed.channels, channels)
		testing.expect_value(t, resolved_frame_samples(parsed), samples)
		if channels == 7 {
			testing.expect(t, parsed.use_pce)
			testing.expect_value(t, parsed.program_config.front_count, 2)
			testing.expect_value(t, parsed.program_config.side_count, 1)
		}
	}
	for samples in ([2]int{0, 960}) {
		c := Config {
			sample_rate   = 44100,
			channels      = 2,
			frame_samples = samples,
		}
		asc, e := audio_specific_config(c)
		testing.expect_value(t, e, Error.None)
		testing.expect_value(t, asc, [2]u8{0x12, samples == 960 ? u8(0x14) : u8(0x10)})
	}
	p, pe := default_program_config({sample_rate = 7350, channels = 8, use_pce = true})
	testing.expect_value(t, pe, Error.None)
	testing.expect_value(t, p.front_count, 3) // predefined7+1 is wide front
	testing.expect_value(t, p.side_count, 0)
	p.tag = 9
	p.matrix_mixdown_present = true; p.matrix_mixdown_index = 2; p.pseudo_surround = true
	p.associated_count = 2; p.associated[0], p.associated[1] = 3, 14
	p.coupling_count = 2; p.coupling[0], p.coupling[1] = {true, 5}, {false, 11}
	p.comment_bytes = 255
	for &b, i in p.comment do b = u8(i)
	for prefix in 0 ..< 8 {
		buf: [dynamic]u8
		defer delete(buf)
		w := common.init_bit_writer(&buf)
		common.write_bits(&w, 0, prefix)
		testing.expect_value(t, write_program_config_element(&w, &p), Error.None)
		common.write_align_zero(&w)
		r := Bit_Reader {
			data = buf[:],
			pos  = prefix,
		}
		parsed, err := read_program_config_element(&r)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, parsed, p)
		for n in 0 ..< len(buf) {
			r = Bit_Reader {
				data = buf[:n],
				pos  = prefix,
			}
			_, e := read_program_config_element(&r)
			testing.expect(t, e != .None)
		}
	}
	bad := p
	bad.front[2] = bad.front[1]
	_, e := program_channel_layout(&bad)
	testing.expect_value(t, e, Error.Invalid_Config)
	bad = p; bad.object_type = 1
	_, e = program_channel_layout(&bad)
	testing.expect_value(t, e, Error.Unsupported_Profile)
	for mono in ([2]bool{true, false}) {
		bad = p
		bad.mono_mixdown_present = mono; bad.stereo_mixdown_present = !mono
		_, e = program_channel_layout(&bad)
		testing.expect_value(t, e, Error.Invalid_Config)
		buf: [dynamic]u8
		defer delete(buf)
		w := common.init_bit_writer(&buf)
		testing.expect_value(t, write_program_config_element(&w, &bad), Error.Invalid_Config)
		testing.expect_value(t, common.bits_written(&w), 0)
		testing.expect_value(
			t,
			validate_config(
				{sample_rate = p.sample_rate, channels = 8, use_pce = true, program_config = bad},
			),
			Error.Invalid_Config,
		)
		// Independent minimal mono PCE wire syntax with one forbidden
		// mixdown flag, rather than using the refusing production writer.
		common.write_bits(&w, 0, 4); common.write_bits(&w, 1, 2); common.write_bits(&w, 3, 4)
		common.write_bits(&w, 1, 4); common.write_bits(&w, 0, 4); common.write_bits(&w, 0, 4)
		common.write_bits(&w, 0, 2); common.write_bits(&w, 0, 3); common.write_bits(&w, 0, 4)
		common.write_bits(&w, u32(mono), 1)
		if mono do common.write_bits(&w, 0, 4)
		common.write_bits(&w, u32(!mono), 1)
		if !mono do common.write_bits(&w, 0, 4)
		common.write_bits(&w, 0, 1); common.write_bits(&w, 0, 5)
		common.write_align_zero(&w); common.write_bits(&w, 0, 8); common.write_align_zero(&w)
		r := Bit_Reader {
			data = buf[:],
		}
		_, e = read_program_config_element(&r)
		testing.expect_value(t, e, Error.Invalid_Config)
	}
	bootstrap := Config {
		sample_rate = 48000,
		channels    = 6,
		use_pce     = true,
	}
	testing.expect_value(t, validate_config(bootstrap), Error.None)
	_, e = resolve_channel_layout(bootstrap)
	testing.expect_value(t, e, Error.None)
	// PCE alignment in a length-delimited ASC is relative to ASC start,
	// including when LATM starts it at an arbitrary physical bit position.
	for prefix in 0 ..< 8 {
		buf: [dynamic]u8
		defer delete(buf)
		w := common.init_bit_writer(&buf)
		common.write_bits(&w, 0, prefix)
		testing.expect_value(t, write_audio_specific_config(&w, bootstrap), Error.None)
		common.write_bits(&w, 0x15, 5); common.write_align_zero(&w)
		r := Bit_Reader {
			data = buf[:],
			pos  = prefix,
		}
		parsed, err := read_audio_specific_config(&r)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, parsed.channels, 6)
		testing.expect_value(t, read_bits(&r, 5), u32(0x15))
	}
}

@(test)
transport_pce_associated_and_lfe_wire_domains :: proc(t: ^testing.T) {
	p, pe := default_program_config({sample_rate = 48000, channels = 1, use_pce = true})
	testing.expect_value(t, pe, Error.None)
	p.lfe_count = 3; p.lfe[0], p.lfe[1], p.lfe[2] = 0, 7, 15
	p.associated_count = 7
	for &tag, i in p.associated[:7] do tag = u8(i)
	p.associated[6] = 15
	buf: [dynamic]u8
	defer delete(buf)
	w := common.init_bit_writer(&buf)
	testing.expect_value(t, write_program_config_element(&w, &p), Error.None)
	common.write_align_zero(&w)
	// Independent grammar fixture pins the 2-bit LFE and 3-bit associated
	// counts and every 4-bit tag at their largest representable values.
	b: Transport_Bits
	put := transport_test_bits
	put(&b, 0, 4); put(&b, 1, 2); put(&b, 3, 4)
	put(&b, 1, 4); put(&b, 0, 4); put(&b, 0, 4)
	put(&b, 3, 2); put(&b, 7, 3); put(&b, 0, 4)
	put(&b, 0, 3); put(&b, 0, 5)
	put(&b, 0, 4); put(&b, 7, 4); put(&b, 15, 4)
	for value in 0 ..< 6 do put(&b, u32(value), 4)
	put(&b, 15, 4); put(&b, 0, -b.pos & 7); put(&b, 0, 8)
	testing.expect(t, transport_test_bytes_equal(buf[:], b.data[:b.pos / 8]))
	r := Bit_Reader {
		data = b.data[:b.pos / 8],
	}
	parsed, e := read_program_config_element(&r)
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, parsed, p)
	for count in -1 ..= 16 {
		bad := p; bad.associated_count = count
		_, le := program_channel_layout(&bad)
		want := count >= 0 && count <= 7 ? Error.None : Error.Invalid_Config
		testing.expect_value(t, le, want)
		clear(&buf); w = common.init_bit_writer(&buf)
		testing.expect_value(t, write_program_config_element(&w, &bad), want)
		if want != .None do testing.expect_value(t, common.bits_written(&w), 0)
	}
	for count in -1 ..= 9 {
		bad := p; bad.lfe_count = count
		_, le := program_channel_layout(&bad)
		want := count >= 0 && count <= 3 ? Error.None : Error.Invalid_Config
		testing.expect_value(t, le, want)
		clear(&buf); w = common.init_bit_writer(&buf)
		testing.expect_value(t, write_program_config_element(&w, &bad), want)
		if want != .None do testing.expect_value(t, common.bits_written(&w), 0)
	}
	// A u8 caller tag can hold values wider than the syntax. Every such
	// value is refused instead of being truncated by the bit writer.
	for tag in 0 ..= 255 {
		bad := p; bad.associated_count = 1; bad.associated[0] = u8(tag)
		_, le := program_channel_layout(&bad)
		want := tag <= 15 ? Error.None : Error.Invalid_Config
		testing.expect_value(t, le, want)
		clear(&buf); w = common.init_bit_writer(&buf)
		testing.expect_value(t, write_program_config_element(&w, &bad), want)
		if want != .None do testing.expect_value(t, common.bits_written(&w), 0)
	}
}

@(test)
transport_asc_lc_extension_flag_refusal :: proc(t: ^testing.T) {
	standalone := [2]u8{0x12, 0x10}
	config, e := parse_audio_specific_config(standalone[:])
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, config.sample_rate, 44100)
	testing.expect_value(t, config.channels, 2)
	_, e = parse_audio_specific_config(standalone[:1])
	testing.expect_value(t, e, Error.Truncated)
	standalone[1] = 0x11
	_, e = parse_audio_specific_config(standalone[:])
	testing.expect_value(t, e, Error.Unsupported_Tool)
	// LC requires extensionFlag zero, regardless of any later syntax bits.
	for tail in ([2]u8{0x00, 0x80}) {
		data := [3]u8{0x12, 0x11, tail}
		r := Bit_Reader {
			data = data[:],
		}
		_, e = read_audio_specific_config(&r)
		testing.expect_value(t, e, Error.Unsupported_Tool)
		testing.expect_value(t, r.pos, 16)
		testing.expect_value(t, r.err, Error.None)
	}
	// Independently frame GASpecificConfig at every bit offset, for each
	// frame length and with/without a PCE. Refusal consumes only the base
	// configuration. Flag-zero controls still pin PCE alignment and the
	// sentinel directly after the valid configuration.
	for prefix in 0 ..< 8 do for pce in ([2]bool{false, true}) do for short_frame in ([2]bool{false, true}) do for extension in ([2]bool{false, true}) {
		b: Transport_Bits
		put := transport_test_bits
		put(&b, 0, prefix)
		put(&b, 2, 5); put(&b, 3, 4); put(&b, pce ? 0 : 2, 4)
		put(&b, short_frame ? 1 : 0, 1); put(&b, 0, 1); put(&b, extension ? 1 : 0, 1)
		base_end := b.pos
		if pce {
			put(&b, 5, 4); put(&b, 1, 2); put(&b, 3, 4)
			put(&b, 1, 4); put(&b, 0, 4); put(&b, 0, 4)
			put(&b, 0, 2); put(&b, 0, 3); put(&b, 0, 4)
			put(&b, 0, 3); put(&b, 0, 1); put(&b, 7, 4)
			put(&b, 0, -(b.pos - prefix) & 7)
			put(&b, 2, 8); put(&b, 0xa5, 8); put(&b, 0x39, 8)
		}
		end := b.pos
		put(&b, 0x15, 5)
		put(&b, 0, -b.pos & 7)
		r := Bit_Reader {
			data = b.data[:b.pos / 8],
			pos  = prefix,
		}
		parsed, parse_error := read_audio_specific_config(&r)
		testing.expect_value(t, parse_error, extension ? Error.Unsupported_Tool : Error.None)
		testing.expect_value(t, r.pos, extension ? base_end : end)
		testing.expect_value(t, r.err, Error.None)
		if extension {
			testing.expect_value(t, parsed, Config{})
		} else {
			testing.expect_value(t, read_bits(&r, 5), u32(0x15))
			testing.expect_value(t, parsed.sample_rate, 48000)
			testing.expect_value(t, parsed.channels, pce ? 1 : 2)
			testing.expect_value(t, resolved_frame_samples(parsed), short_frame ? 960 : 1024)
			if pce {
				testing.expect_value(t, parsed.program_config.tag, u8(5))
				testing.expect_value(t, parsed.program_config.front[0].tag, u8(7))
				testing.expect_value(t, parsed.program_config.comment_bytes, 2)
			}
		}
		// Missing extensionFlag is truncated before either typed admission
		// or PCE parsing, without a padding zero satisfying the field.
		if (base_end - 1) & 7 == 0 {
			r = Bit_Reader {
				data = b.data[:(base_end - 1) / 8],
				pos  = prefix,
			}
			_, e = read_audio_specific_config(&r)
			testing.expect_value(t, e, Error.Truncated)
		}
		// A forbidden flag must not inspect a missing PCE. Its flag-zero
		// counterpart discriminates this early refusal from PCE truncation.
		if pce && base_end & 7 == 0 {
			r = Bit_Reader {
				data = b.data[:base_end / 8],
				pos  = prefix,
			}
			_, e = read_audio_specific_config(&r)
			testing.expect_value(t, e, extension ? Error.Unsupported_Tool : Error.Truncated)
			testing.expect_value(t, r.pos, base_end)
		}
	}
}

@(test)
transport_adts_mpeg_id_and_profile_admission :: proc(t: ^testing.T) {
	// Independent eight-byte LC, 44.1kHz stereo, one unprotected raw block.
	base := [8]u8{0xff, 0xf1, 0x50, 0x80, 0x01, 0x1f, 0xfc, 0xe0}
	initial, _, ie := parse_adts(base[:])
	testing.expect_value(t, ie, Error.None)
	testing.expect(t, !initial.mpeg2)
	for mpeg2 in ([2]bool{false, true}) {
		frame := base
		if mpeg2 do frame[1] |= 8
		before := frame
		h, payload, e := parse_adts(frame[:])
		testing.expect_value(t, e, Error.None)
		testing.expect_value(t, h.mpeg2, mpeg2)
		testing.expect_value(t, frame, before)
		testing.expect_value(t, len(payload), 1)
		testing.expect(t, raw_data(payload) == raw_data(frame[7:]))
		testing.expect_value(t, payload[0], u8(0xe0))
		h.mpeg2 = false
		testing.expect_value(t, h, initial)
		// Sampling-frequency index12 is MPEG-4-only; changing ID never
		// relaxes the LC profile admission or rewrites caller bytes.
		frame[2] = 0x70
		h, _, e = parse_adts(frame[:])
		testing.expect_value(t, e, mpeg2 ? Error.Invalid_Config : Error.None)
		if !mpeg2 do testing.expect_value(t, h.config.sample_rate, 7350)
		frame[2] = 0x10
		_, _, e = parse_adts(frame[:])
		testing.expect_value(t, e, Error.Unsupported_Profile)
	}
}

@(test)
transport_adts_multiblock_crc_and_failures :: proc(t: ^testing.T) {
	payload: [4][31]u8
	for &block, i in payload do for &b, j in block do b = u8(i * 41 + j * 13)
	ranges := [2]CRC_Range{{3, 31 * 8, 192}, {70, 31 * 8, 128}}
	blocks: [4]ADTS_Block
	for &block, i in blocks do block = {payload[i][:i * 7 + 3], ranges[:1]}
	for count in 1 ..= 4 do for protected in ([2]bool{false, true}) {
		buf: [dynamic]u8
		defer delete(buf)
		config := Config {
			sample_rate = 7350,
			channels    = 8,
		}
		// Ranges are clipped to the element's actual end before zero padding.
		local: [4][2]CRC_Range
		for &block, i in blocks[:count] {
			local[i] = ranges
			local[i][0].end = len(block.data) * 8
			block.crc_ranges = local[i][:1]
		}
		testing.expect_value(t, append_adts_blocks(&buf, config, blocks[:count], protected), Error.None)
		h, raw, e := parse_adts(buf[:])
		testing.expect_value(t, e, Error.None)
		testing.expect_value(t, h.raw_block_count, count)
		testing.expect_value(t, h.config.channels, 8)
		testing.expect_value(t, h.config.sample_rate, 7350)
		testing.expect_value(t, h.frame_bytes, len(buf))
		testing.expect_value(t, len(raw), len(buf) - h.header_bytes)
		if protected {
			if count > 1 {
				want := transport_test_crc16(buf[:], 0xffff, 0, (h.header_bytes - 2) * 8, 0)
				testing.expect_value(t, h.header_crc, want)
			}
			for block, i in blocks[:count] {
				crc, ce := adts_block_crc_seed(h, buf[:], i)
				testing.expect_value(t, ce, Error.None)
				for range in block.crc_ranges do crc = transport_test_crc16(block.data, crc, range.first, range.end, range.padded_bits)
				testing.expect_value(t, validate_adts_block_crc(h, i, crc), Error.None)
				if count > 1 do testing.expect(t, transport_test_bytes_equal(buf[h.block_offsets[i]:h.block_ends[i]], block.data))
			}
			if count > 1 {
				buf[7] ~= 1
				_, _, bad := parse_adts(buf[:])
				testing.expect_value(t, bad, Error.Crc_Mismatch)
				buf[7] ~= 1
				// Make an invalid block position with a valid header CRC.
				buf[7], buf[8] = 0, 0
				crc := transport_test_crc16(buf[:], 0xffff, 0, (h.header_bytes - 2) * 8, 0)
				buf[h.header_bytes - 2], buf[h.header_bytes - 1] = u8(crc >> 8), u8(crc)
				_, _, bad = parse_adts(buf[:])
				testing.expect_value(t, bad, Error.Invalid_Data)
			}
		}
	}
	buf: [dynamic]u8
	defer delete(buf)
	boundary: [8185]u8
	testing.expect_value(
		t,
		append_adts(&buf, {sample_rate = 44100, channels = 1}, boundary[:8184]),
		Error.None,
	)
	testing.expect_value(t, len(buf), 8191)
	n := len(buf)
	testing.expect_value(
		t,
		append_adts(&buf, {sample_rate = 44100, channels = 1}, boundary[:]),
		Error.Invalid_Data,
	)
	testing.expect_value(t, len(buf), n)
	testing.expect_value(
		t,
		append_adts(&buf, {sample_rate = 44100, channels = 1, frame_samples = 960}, boundary[:1]),
		Error.Unsupported_Transport,
	)
	clear(&buf)
	testing.expect_value(
		t,
		append_adts(&buf, {sample_rate = 44100, channels = 7}, boundary[:1]),
		Error.None,
	)
	h, _, err := parse_adts(buf[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, h.channel_configuration, 0)
	testing.expect(t, h.config.use_pce && h.config.channels == 0)
}

@(test)
transport_output_allocation_failures_are_typed :: proc(t: ^testing.T) {
	buf := make([dynamic]u8, mem.nil_allocator())
	c := Config {
		sample_rate = 44100,
		channels    = 2,
	}
	payload := [1]u8{0xe0}
	testing.expect_value(t, append_adts(&buf, c, payload[:]), Error.Allocation_Failed)
	testing.expect_value(t, len(buf), 0)
	testing.expect_value(t, append_loas(&buf, c, payload[:]), Error.Allocation_Failed)
	testing.expect_value(t, len(buf), 0)
	testing.expect_value(t, append_audio_specific_config(&buf, c), Error.Allocation_Failed)
	testing.expect_value(t, len(buf), 0)
}

@(test)
transport_adts_leading_pce_initialization :: proc(t: ^testing.T) {
	c := Config {
		sample_rate = 48000,
		channels    = 7,
	}
	p, pe := default_program_config(c)
	testing.expect_value(t, pe, Error.None)
	raw, frame: [dynamic]u8
	defer delete(raw); defer delete(frame)
	w := common.init_bit_writer(&raw)
	common.write_bits(&w, 5, 3)
	testing.expect_value(t, write_program_config_element(&w, &p), Error.None)
	common.write_bits(&w, 7, 3); common.write_align_zero(&w)
	testing.expect_value(t, append_adts(&frame, c, raw[:]), Error.None)
	h, payload, he := parse_adts(frame[:])
	testing.expect_value(t, he, Error.None)
	resolved, err := adts_config(h, payload)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, resolved.channels, 7)
	testing.expect_value(t, resolved.program_config, p)
	for n in 0 ..< len(payload) - 1 {
		_, e := adts_config(h, payload[:n])
		testing.expect(t, e != .None)
	}
	bad := [1]u8{0xe0}
	_, err = adts_config(h, bad[:])
	testing.expect_value(t, err, Error.Invalid_Config)
}

@(test)
asc_sync_extension_signalling_sbr_absent_is_plain_lc :: proc(t: ^testing.T) {
	// LC 48 kHz stereo, then sync extension 0x2b7, extension AOT 5, sbrPresentFlag 0.
	config, e := parse_audio_specific_config({0x11, 0x90, 0x56, 0xE5, 0x00})
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, config.sample_rate, 48000)
	testing.expect_value(t, config.channels, 2)
	// sbrPresentFlag 1 (HE-AAC) remains outside the LC contract.
	_, e = parse_audio_specific_config({0x11, 0x90, 0x56, 0xE5, 0x80, 0x00})
	testing.expect_value(t, e, Error.Unsupported_Profile)
	// Bits after the explicit-absent extension must still be zero padding.
	_, e = parse_audio_specific_config({0x11, 0x90, 0x56, 0xE5, 0x01})
	testing.expect_value(t, e, Error.Invalid_Data)
}

package aac_decoder

import aac ".."
import common "../../../common"
import "core:testing"

@(test)
test_coupling_program_and_default_transport_transitions_preserve_samples :: proc(t: ^testing.T) {
	for n in ([2]int{960, 1024}) do for independent in ([2]bool{false, true}) {
		config := Config {
			sample_rate   = 48000,
			channels      = 2,
			frame_samples = n,
		}
		d, oracle := new(Decoder), new(Decoder)
		defer free(d); defer free(oracle)
		testing.expect_value(t, init_decoder(d, config), Error.None)
		testing.expect_value(t, init_decoder(oracle, config), Error.None)
		plain, declared, invalid, packet: [dynamic]u8
		defer delete(plain); defer delete(declared); defer delete(invalid); defer delete(packet)
		w := common.init_bit_writer(&plain)
		feature_audio(&w, {.CPE, 0, 0, 2}, 3, n, false)
		feature_cce(&w, 3, n, independent, true, 3, true, false, 1)
		feature_end(&w)
		w = common.init_bit_writer(&declared)
		declared_config := feature_coupling_program(t, &w, n, independent)
		feature_audio(&w, {.CPE, 0, 0, 2}, 3, n, false)
		feature_cce(&w, 3, n, independent, true, 3, true, false, 1)
		feature_end(&w)
		invalid_config := declared_config
		invalid_config.program_config.coupling[0].independent = !independent
		w = common.init_bit_writer(&invalid)
		common.write_bits(&w, 5, 3)
		testing.expect_value(t, aac.write_program_config_element(&w, &invalid_config.program_config), Error.None)
		feature_audio(&w, {.CPE, 0, 0, 2}, 3, n, false)
		feature_cce(&w, 3, n, independent, true, 3, true, false, 1)
		feature_end(&w)
		pcm, want: [2048]f32
		// Generic raw decoding preserves MPEG-2's implicit CCE syntax.
		_, e := decode_frame(d, plain[:], pcm[:]); testing.expect_value(t, e, Error.None)
		_, e = decode_frame(oracle, plain[:], want[:]); testing.expect_value(t, e, Error.None)
		for value, index in pcm[:2 * n] do testing.expect_value(t, value, want[index])
		for _ in 0 ..< 2 {
			// A PCE's declaration must agree with the actual CCE. Refuse before
			// publication both initially and after a successful declared frame.
			clear(&packet)
			if n == 1024 {
				testing.expect_value(t, aac.append_adts(&packet, invalid_config, invalid[:]), Error.None)
			} else {
				testing.expect_value(t, aac.append_loas(&packet, invalid_config, invalid[:]), Error.None)
			}
			banks, coupling_banks := d.bank, d.coupling_bank
			seed, layout, program, drc, mux := d.noise_seed, d.layout, d.program, d.dynamic_range, d.latm
			for &value in pcm do value = -19
			if n == 1024 {
				_, _, e = decode_adts_frame(d, packet[:], pcm[:])
			} else {
				_, _, e = decode_loas_frame(d, packet[:], pcm[:])
			}
			testing.expect_value(t, e, Error.Invalid_Data)
			testing.expect(t, feature_banks_equal(d.bank[:], banks[:]) && feature_banks_equal(d.coupling_bank[:], coupling_banks[:]))
			testing.expect(t, d.noise_seed == seed && d.layout == layout && d.program == program && d.dynamic_range == drc && d.latm == mux)
			for value in pcm do testing.expect_value(t, value, f32(-19))
			// A non-output CCE does not require implicit output mapping. The
			// default-configured transport preserves generic raw sample results,
			// replacing any earlier PCE mapping without imposing new refusals.
			clear(&packet)
			if n == 1024 {
				testing.expect_value(t, aac.append_adts(&packet, config, plain[:]), Error.None)
				_, _, e = decode_adts_frame(d, packet[:], pcm[:]); testing.expect_value(t, e, Error.None)
			} else {
				testing.expect_value(t, aac.append_loas(&packet, config, plain[:]), Error.None)
				_, _, e = decode_loas_frame(d, packet[:], pcm[:]); testing.expect_value(t, e, Error.None)
			}
			_, e = decode_frame(oracle, plain[:], want[:]); testing.expect_value(t, e, Error.None)
			for value, index in pcm[:2 * n] do testing.expect_value(t, value, want[index])
			testing.expect(t, !d.explicit_layout && !aac.program_config_present(&d.program))
			clear(&packet)
			if n == 1024 {
				testing.expect_value(t, aac.append_adts(&packet, declared_config, declared[:]), Error.None)
				_, _, e = decode_adts_frame(d, packet[:], pcm[:]); testing.expect_value(t, e, Error.None)
				_, _, e = decode_adts_frame(oracle, packet[:], want[:]); testing.expect_value(t, e, Error.None)
			} else {
				testing.expect_value(t, aac.append_loas(&packet, declared_config, declared[:]), Error.None)
				_, _, e = decode_loas_frame(d, packet[:], pcm[:]); testing.expect_value(t, e, Error.None)
				_, _, e = decode_loas_frame(oracle, packet[:], want[:]); testing.expect_value(t, e, Error.None)
			}
			for value, index in pcm[:2 * n] do testing.expect_value(t, value, want[index])
			testing.expect(t, feature_banks_equal(d.bank[:], oracle.bank[:]) && feature_banks_equal(d.coupling_bank[:], oracle.coupling_bank[:]))
		}
		if n == 1024 {
			clear(&packet)
			testing.expect_value(t, aac.append_adts(&packet, config, plain[:]), Error.None)
			packet[1] |= 0x08 // MPEG-2 ID, unprotected frame: no CRC changes.
			_, _, e = decode_adts_frame(d, packet[:], pcm[:]); testing.expect_value(t, e, Error.None)
			_, e = decode_frame(oracle, plain[:], want[:]); testing.expect_value(t, e, Error.None)
			for value, index in pcm do testing.expect_value(t, value, want[index])
			testing.expect(t, !d.explicit_layout && !aac.program_config_present(&d.program))
		}
	}
}

@(private)
feature_fill_drc :: proc(
	w: ^common.Bit_Writer,
	excluded_channel: int,
	bands: int,
	reference: bool,
	control: u32,
	interpolation: u32 = 0,
	frame_samples: int = 1024,
) {
	common.write_bits(w, 6, 3)
	common.write_bits(w, u32(1 + 1 + (bands > 1 ? 1 + bands : 0) + (reference ? 1 : 0) + bands), 4)
	common.write_bits(w, 11, 4)
	common.write_bits(w, 0, 1) // applies to this program
	common.write_bits(w, 1, 1)
	for channel in 0 ..< 7 do common.write_bits(w, channel == excluded_channel ? 1 : 0, 1)
	common.write_bits(w, 0, 1) // no more exclusion groups
	common.write_bits(w, bands > 1 ? 1 : 0, 1)
	if bands > 1 {
		common.write_bits(w, u32(bands - 1), 4); common.write_bits(w, interpolation, 4)
		for band in 0 ..< bands do common.write_bits(w, band + 1 == bands ? u32(frame_samples / 4 - 1) : 3, 8)
	}
	common.write_bits(w, reference ? 1 : 0, 1)
	if reference {common.write_bits(w, 85, 7); common.write_bits(w, 0, 1)}
	for band in 0 ..< bands {
		common.write_bits(w, u32(band & 1), 1)
		common.write_bits(w, control + u32(band), 7)
	}
}

@(test)
test_dynamic_range_interpolation_and_960_band_extent :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	testing.expect_value(
		t,
		init_decoder(d, {sample_rate = 48000, channels = 1, frame_samples = 960}),
		Error.None,
	)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [960]f32
	for bands in 1 ..= 2 {
		w := common.init_bit_writer(&buf)
		feature_audio(&w, {.SCE, 0, 0, 1}, 3, 960, false)
		feature_fill_drc(&w, -1, bands, false, 7, interpolation = 8, frame_samples = 960)
		feature_end(&w)
		_, err := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.None)
		metadata := &d.dynamic_range.channel[0]
		testing.expect_value(t, metadata.band_count, bands)
		testing.expect_value(t, metadata.band_top[bands - 1], u8(239))
		testing.expect_value(t, metadata.interpolation_scheme, bands == 1 ? u8(0) : u8(8))
		for value in pcm do testing.expect_value(t, value, f32(0))
	}
}

@(test)
test_implicit_dynamic_range_exclusions_follow_encounter_order :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 3}), Error.None)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [3072]f32
	// Canonical center is output0, but payload presents front left/right first.
	// Exclusion0 therefore protects front left, not the canonical center.
	w := common.init_bit_writer(&buf)
	feature_audio(&w, {.CPE, 9, 1, 2}, 3, 1024, false)
	feature_audio(&w, {.SCE, 7, 0, 1}, 3, 1024, false)
	feature_fill_drc(&w, 0, 1, false, 11)
	feature_end(&w)
	_, err := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.None)
	testing.expect_value(t, d.dynamic_range.channel[0].control[0], u8(11))
	testing.expect(t, !d.dynamic_range.channel[1].present)
	testing.expect_value(t, d.dynamic_range.channel[2].control[0], u8(11))
	// No metadata replaces the prior element-owned values on the next frame.
	w = common.init_bit_writer(&buf)
	feature_audio(&w, {.SCE, 7, 0, 1}, 3, 1024, false)
	feature_audio(&w, {.CPE, 9, 1, 2}, 3, 1024, false)
	feature_end(&w)
	_, err = decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.None)
	testing.expect_value(t, d.dynamic_range.channel[0].control[0], u8(11))
	testing.expect(t, !d.dynamic_range.channel[1].present)
	testing.expect_value(t, d.dynamic_range.channel[2].control[0], u8(11))
}

@(test)
test_independent_cce_dynamic_range_has_stable_tag_ownership :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	testing.expect_value(
		t,
		init_decoder(d, {sample_rate = 48000, channels = 2, use_pce = true}),
		Error.None,
	)
	p := aac.Program_Config {
		object_type    = 2,
		sample_rate    = 48000,
		front_count    = 1,
		coupling_count = 2,
	}
	p.front[0] = {true, 0}
	p.coupling[0], p.coupling[1] = {true, 4}, {true, 5}
	buf: [dynamic]u8; defer delete(buf)
	pcm: [2048]f32
	for frame in 0 ..< 4 {
		if frame == 1 || frame == 3 do p.coupling[0], p.coupling[1] = p.coupling[1], p.coupling[0]
		w := common.init_bit_writer(&buf)
		common.write_bits(
			&w,
			5,
			3,
		); testing.expect_value(t, aac.write_program_config_element(&w, &p), Error.None)
		feature_audio(&w, {.CPE, 0, 0, 2}, 3, 1024, false)
		feature_cce(&w, 3, 1024, true, false, 0, true, false, 0, amplitude = false, tag = 4)
		if frame != 2 do feature_cce(&w, 3, 1024, true, false, 0, true, false, 0, amplitude = false, tag = 5)
		// Audio order is unchanged. PCE coupling order alone changes which
		// tag the exclusion2 protects; the absent tag5 then retains its value.
		if frame < 2 do feature_fill_drc(&w, 2, 1, false, frame == 0 ? 7 : 3)
		feature_end(&w)
		_, err := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.None)
		left, right := &d.dynamic_range.channel[2 + 4], &d.dynamic_range.channel[2 + 5]
		if frame ==
		   0 {testing.expect(t, !left.present)} else {testing.expect_value(t, left.control[0], u8(3))}
		testing.expect_value(t, right.control[0], u8(7))
		for value in pcm do testing.expect_value(t, value, f32(0))
	}
}

@(test)
test_implicit_cce_exclusions_lower_encounter_order_to_tags :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 2}), Error.None)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [2048]f32
	for frame in 0 ..< 2 {
		w := common.init_bit_writer(&buf)
		feature_audio(&w, {.CPE, 0, 0, 2}, 3, 1024, false)
		for element in 0 ..< 2 {
			tag := u8(frame == 0 ? 4 + element : 5 - element)
			feature_cce(&w, 3, 1024, true, false, 0, true, false, 0, amplitude = false, tag = tag)
		}
		feature_fill_drc(&w, 2, 1, false, frame == 0 ? 7 : 3)
		feature_end(&w)
		_, err := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.None)
		if frame == 0 {testing.expect(t, !d.dynamic_range.channel[6].present)} else {
			testing.expect_value(t, d.dynamic_range.channel[6].control[0], u8(3))
		}
		testing.expect_value(t, d.dynamic_range.channel[7].control[0], u8(7))
	}
}

@(test)
test_dynamic_range_metadata_persistence_exclusion_and_retry :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 2}), Error.None)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [2048]f32
	for frame in 0 ..< 3 {
		w := common.init_bit_writer(&buf)
		feature_audio(&w, {.CPE, 0, 0, 2}, 3, 1024, false)
		if frame == 0 do feature_fill_drc(&w, 1, 2, true, 8)
		if frame == 2 do feature_fill_drc(&w, 0, 1, false, 3)
		feature_end(&w)
		_, err := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.None)
		for value in pcm do testing.expect_value(t, value, f32(0))
		testing.expect(t, d.dynamic_range.reference_level_present)
		testing.expect_value(t, d.dynamic_range.reference_level, u8(85))
		testing.expect_value(t, d.dynamic_range.channel[0].band_count, 2)
		testing.expect_value(t, d.dynamic_range.channel[0].control[0], u8(8))
		if frame < 2 {
			testing.expect(t, !d.dynamic_range.channel[1].present)
		} else {
			testing.expect_value(t, d.dynamic_range.channel[1].band_count, 1)
			testing.expect_value(t, d.dynamic_range.channel[1].control[0], u8(3))
		}
	}
	banks, coupling_banks, seed, drc, program :=
		d.bank, d.coupling_bank, d.noise_seed, d.dynamic_range, d.program
	w := common.init_bit_writer(&buf)
	feature_audio(&w, {.CPE, 0, 0, 2}, 3, 1024, false)
	common.write_bits(&w, 6, 3); common.write_bits(&w, 1, 4)
	common.write_bits(&w, 11, 4); common.write_bits(&w, 0, 4) // omits required gain byte
	feature_end(&w)
	for &value in pcm do value = -77
	_, err := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, err, Error.Invalid_Data)
	testing.expect(
		t,
		feature_banks_equal(d.bank[:], banks[:]) &&
		feature_banks_equal(d.coupling_bank[:], coupling_banks[:]) &&
		d.noise_seed == seed &&
		d.dynamic_range == drc &&
		d.program == program,
	)
	for value in pcm do testing.expect_value(t, value, f32(-77))
}

@(test)
test_ancillary_extension_preserves_following_dynamic_range :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 1}), Error.None)
	buf: [dynamic]u8; defer delete(buf)
	pcm: [1024]f32
	w := common.init_bit_writer(&buf)
	feature_audio(&w, {.SCE, 0, 0, 1}, 3, 1024, false)
	common.write_bits(&w, 6, 3); common.write_bits(&w, 5, 4)
	common.write_bits(&w, 2, 4); common.write_bits(&w, 0, 4)
	common.write_bits(&w, 1, 8); common.write_bits(&w, 0xac, 8)
	common.write_bits(&w, 11, 4); common.write_bits(&w, 0, 4)
	common.write_bits(&w, 9, 8)
	feature_end(&w)
	_, e := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, e, Error.None)
	testing.expect_value(t, d.dynamic_range.channel[0].control[0], u8(9))
	for value in pcm do testing.expect_value(t, value, f32(0))
}

@(test)
test_exact_raw_access_unit_refuses_trailing_bytes_before_publication :: proc(t: ^testing.T) {
	d, oracle := new(Decoder), new(Decoder); defer free(d); defer free(oracle)
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 1}), Error.None)
	testing.expect_value(t, init_decoder(oracle, d.config), Error.None)
	valid, junk, concatenated: [dynamic]u8; defer delete(valid); defer delete(junk); defer delete(concatenated)
	_, _ = feature_crc_block(&valid, false, true)
	pcm, want: [1024]f32
	_, e := decode_frame(d, valid[:], pcm[:]); testing.expect_value(t, e, Error.None)
	_, e = decode_frame(oracle, valid[:], want[:]); testing.expect_value(t, e, Error.None)
	append(&junk, ..valid[:]); append(&junk, 0x39)
	append(&concatenated, ..valid[:]); append(&concatenated, ..valid[:])
	banks, seed, drc, layout, program := d.bank, d.noise_seed, d.dynamic_range, d.layout, d.program
	for payload in ([2][]u8{junk[:], concatenated[:]}) {
		for &v in pcm do v = -27
		_, refused := decode_frame(
			d,
			payload,
			pcm[:],
		); testing.expect_value(t, refused, Error.Invalid_Data)
		testing.expect(
			t,
			feature_banks_equal(d.bank[:], banks[:]) &&
			d.noise_seed == seed &&
			d.dynamic_range == drc &&
			d.layout == layout &&
			d.program == program,
		)
		for value in pcm do testing.expect_value(t, value, f32(-27))
	}
	_, e = decode_frame(oracle, valid[:], want[:]); testing.expect_value(t, e, Error.None)
	bytes, samples, prefix_error := decode_frame_prefix(d, concatenated[:], pcm[:])
	testing.expect_value(
		t,
		prefix_error,
		Error.None,
	); testing.expect_value(t, bytes, len(valid)); testing.expect_value(t, samples, 1024)
	for value, index in pcm do testing.expect_value(t, value, want[index])
	testing.expect(
		t,
		feature_banks_equal(d.bank[:], oracle.bank[:]) && d.noise_seed == oracle.noise_seed,
	)
}

@(test)
test_late_program_configuration_is_rejected_before_commit :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	testing.expect_value(
		t,
		init_decoder(d, {sample_rate = 48000, channels = 1, use_pce = true}),
		Error.None,
	)
	p := aac.Program_Config {
		object_type = 2,
		sample_rate = 48000,
		front_count = 1,
	}
	p.front[0] = {false, 0}
	buf: [dynamic]u8; defer delete(buf)
	pcm: [1024]f32
	for metadata_first in ([2]bool{false, true}) {
		w := common.init_bit_writer(&buf)
		if metadata_first {
			feature_fill_drc(&w, 1, 1, true, 7)
		} else {
			feature_audio(&w, {.SCE, 0, 0, 1}, 3, 1024)
		}
		common.write_bits(
			&w,
			5,
			3,
		); testing.expect_value(t, aac.write_program_config_element(&w, &p), Error.None)
		if metadata_first do feature_audio(&w, {.SCE, 0, 0, 1}, 3, 1024)
		feature_end(&w)
		for &value in pcm do value = -55
		_, e := decode_frame(d, buf[:], pcm[:]); testing.expect_value(t, e, Error.Invalid_Data)
		testing.expect(
			t,
			feature_banks_zero(d.bank[:]) &&
			d.noise_seed == 1 &&
			!d.explicit_layout &&
			!d.dynamic_range.last.present,
		)
		for value in pcm do testing.expect_value(t, value, f32(-55))
	}
}

@(private)
feature_crc_block :: proc(
	buf: ^[dynamic]u8,
	pair: bool,
	noise: bool,
	invalid: bool = false,
) -> (
	ranges: [2]aac.CRC_Range,
	count: int,
) {
	w := common.init_bit_writer(buf)
	common.write_bits(&w, pair ? 1 : 0, 3)
	first := common.bits_written(&w)
	common.write_bits(&w, 0, 4)
	if pair do common.write_bits(&w, 0, 1)
	second: int
	for side in 0 ..< (pair ? 2 : 1) {
		if side == 1 do second = common.bits_written(&w)
		if !noise {
			feature_channel(&w, feature_info(3, 1024), true, 100 + 4 * side)
		} else {
			syntax := Flow_Test_Syntax {
				sequence = .Long,
				max_sfb  = 1,
				books    = {13, 0, 0},
			}
			flow_test_write_channel(&w, syntax, false)
		}
	}
	end := common.bits_written(&w)
	ranges[0] = {first, end, 192}; count = 1
	if pair {ranges[1] = {second, end, 128}; count = 2}
	common.write_bits(&w, invalid ? 3 : 7, 3)
	common.write_align_zero(&w)
	return
}

@(test)
test_adts_crc_and_multiple_block_atomicity :: proc(t: ^testing.T) {
	d, oracle := new(Decoder), new(Decoder); defer free(d); defer free(oracle)
	one, two, bad, packet: [dynamic]u8; defer delete(one); defer delete(two); defer delete(bad); defer delete(packet)
	for channels in ([2]int{1, 2}) do for protected in ([2]bool{false, true}) do for blocks in ([2]int{1, 4}) {
		config := Config {
			sample_rate = 48000,
			channels    = channels,
		}
		testing.expect_value(t, init_decoder(d, config), Error.None)
		testing.expect_value(t, init_decoder(oracle, config), Error.None)
		first_ranges, first_count := feature_crc_block(&one, channels == 2, true)
		second_ranges, second_count := feature_crc_block(&two, channels == 2, false)
		entries: [4]aac.ADTS_Block
		for &entry, index in entries {
			entry = index & 1 == 0 ? aac.ADTS_Block{one[:], first_ranges[:first_count]} : aac.ADTS_Block{two[:], second_ranges[:second_count]}
		}
		testing.expect_value(t, aac.append_adts_blocks(&packet, config, entries[:blocks], protected), Error.None)
		actual, expected: [4 * 2048 + 2]f32
		for &v in actual do v = -333
		for block in 0 ..< blocks {
			_, e := decode_frame(oracle, entries[block].data, expected[block * 1024 * channels:(block + 1) * 1024 * channels])
			testing.expect_value(t, e, Error.None)
		}
		bytes, samples, err := decode_adts_frame(d, packet[:], actual[1:1 + blocks * 1024 * channels])
		testing.expect_value(t, err, Error.None); testing.expect_value(t, bytes, len(packet)); testing.expect_value(t, samples, blocks * 1024)
		for value, index in actual[1:1 + blocks * 1024 * channels] do testing.expect_value(t, value, expected[index])
		testing.expect_value(t, actual[0], f32(-333)); testing.expect_value(t, actual[1 + blocks * 1024 * channels], f32(-333))
		testing.expect(t, feature_banks_equal(d.bank[:], oracle.bank[:]) && d.noise_seed == oracle.noise_seed)
		// A late syntax error, or CRC error in the last protected block,
		// cannot publish an earlier block's PCM, noise or overlap history.
		bad_ranges, bad_count := feature_crc_block(&bad, channels == 2, true, true)
		entries[blocks - 1] = {bad[:], bad_ranges[:bad_count]}
		clear(&packet)
		testing.expect_value(t, aac.append_adts_blocks(&packet, config, entries[:blocks], protected), Error.None)
		banks, seed, drc := d.bank, d.noise_seed, d.dynamic_range
		for &v in actual do v = -333
		_, _, refused := decode_adts_frame(d, packet[:], actual[:])
		testing.expect(t, refused != .None)
		testing.expect(t, feature_banks_equal(d.bank[:], banks[:]) && d.noise_seed == seed && d.dynamic_range == drc)
		for value in actual do testing.expect_value(t, value, f32(-333))
		if protected {
			entries[blocks - 1] = {two[:], second_ranges[:second_count]}
			clear(&packet)
			testing.expect_value(t, aac.append_adts_blocks(&packet, config, entries[:blocks], true), Error.None)
			h, _, _ := aac.parse_adts(packet[:])
			// Modify protected global_gain syntax, leaving framing intact.
			at := blocks == 1 ? h.header_bytes : h.block_offsets[blocks - 1]
			packet[at + 1] ~= 0x80
			_, _, crc_error := decode_adts_frame(d, packet[:], actual[:])
			testing.expect_value(t, crc_error, Error.Crc_Mismatch)
			testing.expect(t, feature_banks_equal(d.bank[:], banks[:]) && d.noise_seed == seed && d.dynamic_range == drc)
			for value in actual do testing.expect_value(t, value, f32(-333))
		}
		clear(&packet)
	}
}

@(test)
test_crc_covers_program_data_and_coupling_but_excludes_fill :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	payload, packet: [dynamic]u8; defer delete(payload); defer delete(packet)
	p := aac.Program_Config {
		object_type    = 2,
		sample_rate    = 48000,
		front_count    = 1,
		coupling_count = 1,
	}
	p.front[0] = {true, 0}; p.coupling[0] = {true, 4}
	config := Config {
		sample_rate    = 48000,
		channels       = 2,
		use_pce        = true,
		program_config = p,
	}
	ranges: [6]aac.CRC_Range
	w := common.init_bit_writer(&payload)
	common.write_bits(&w, 5, 3); first := common.bits_written(&w)
	testing.expect_value(t, aac.write_program_config_element(&w, &p), Error.None)
	ranges[0] = {first, common.bits_written(&w), 0}
	// DSE owns alignment and all of its opaque payload bytes.
	common.write_bits(&w, 4, 3); first = common.bits_written(&w)
	common.write_bits(&w, 2, 4); common.write_bits(&w, 1, 1); common.write_bits(&w, 2, 8)
	common.write_align_zero(&w); common.write_bits(&w, 0x39a7, 16)
	ranges[1] = {first, common.bits_written(&w), 0}
	common.write_bits(&w, 1, 3); first = common.bits_written(&w)
	common.write_bits(&w, 0, 4); common.write_bits(&w, 0, 1)
	feature_channel(&w, feature_info(3, 1024), false)
	second := common.bits_written(&w)
	feature_channel(&w, feature_info(3, 1024), false)
	last := common.bits_written(&w)
	ranges[2], ranges[3] = {first, last, 192}, {second, last, 128}
	first = last + 3 // feature_cce writes ID before its protected tag
	feature_cce(&w, 3, 1024, true, true, 0, true, false, 0)
	ranges[4] = {first, common.bits_written(&w), 192}
	feature_fill_drc(&w, 1, 1, true, 7)
	feature_end(&w)
	block := [1]aac.ADTS_Block{{payload[:], ranges[:5]}}
	testing.expect_value(t, aac.append_adts_blocks(&packet, config, block[:], true), Error.None)
	testing.expect_value(t, init_decoder(d, config), Error.None)
	pcm: [2048]f32
	_, _, err := decode_adts_frame(d, packet[:], pcm[:]); testing.expect_value(t, err, Error.None)
	testing.expect_value(t, d.dynamic_range.reference_level, u8(85))
}

@(test)
test_adts_zero_channel_configuration_preserves_outside_program :: proc(t: ^testing.T) {
	d := new(Decoder); defer free(d)
	p := aac.Program_Config {
		object_type = 2,
		sample_rate = 48000,
		front_count = 2,
	}
	p.front[0], p.front[1] = {false, 7}, {true, 9}
	config := Config {
		sample_rate    = 48000,
		channels       = 3,
		use_pce        = true,
		program_config = p,
	}
	other := p; other.front[0].tag, other.front[1].tag = 8, 10
	payload, packet: [dynamic]u8; defer delete(payload); defer delete(packet)
	w := common.init_bit_writer(&payload)
	common.write_bits(
		&w,
		5,
		3,
	); testing.expect_value(t, aac.write_program_config_element(&w, &other), Error.None)
	feature_audio(&w, {.CPE, 9, 1, 2}, 3, 1024)
	feature_audio(&w, {.SCE, 7, 0, 1}, 3, 1024)
	feature_end(&w)
	testing.expect_value(t, aac.append_adts(&packet, config, payload[:]), Error.None)
	testing.expect_value(t, init_decoder(d, config), Error.None)
	pcm: [3 * 1024]f32
	_, _, e := decode_adts_frame(d, packet[:], pcm[:]); testing.expect_value(t, e, Error.None)
	testing.expect(t, d.program == p)
	for sample in 0 ..< 1024 do for channel in 0 ..< 3 {
		testing.expect(t, abs(f64(pcm[sample * 3 + channel]) - feature_cosine_sample(1024, sample, f64(int(1) << uint(channel)))) < 2e-12)
	}
	// Without an outside program, ADTS cc0 delegates layout to its PCE;
	// these old-tag audio elements then fail the new program's mapping.
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 3}), Error.None)
	for &value in pcm do value = -49
	_, _, e = decode_adts_frame(
		d,
		packet[:],
		pcm[:],
	); testing.expect_value(t, e, Error.Invalid_Data)
	testing.expect(t, !d.explicit_layout && feature_banks_zero(d.bank[:]) && d.noise_seed == 1)
	for value in pcm do testing.expect_value(t, value, f32(-49))
}

@(test)
test_loas_pce_to_predefined_mapping_and_reuse_is_transactional :: proc(t: ^testing.T) {
	d, oracle := new(Decoder), new(Decoder); defer free(d); defer free(oracle)
	config := Config {
		sample_rate = 48000,
		channels    = 3,
	}
	testing.expect_value(t, init_decoder(d, config), Error.None)
	testing.expect_value(t, init_decoder(oracle, config), Error.None)
	p := aac.Program_Config {
		object_type = 2,
		sample_rate = 48000,
		front_count = 2,
	}
	p.front[0], p.front[1] = {false, 7}, {true, 9}
	program_config := config; program_config.use_pce = true; program_config.program_config = p
	unit, stream: [dynamic]u8; defer delete(unit); defer delete(stream)
	w := common.init_bit_writer(&unit)
	feature_audio(&w, {.CPE, 9, 1, 2}, 3, 1024)
	feature_audio(&w, {.SCE, 7, 0, 1}, 3, 1024)
	feature_end(&w)
	testing.expect_value(t, aac.append_loas(&stream, program_config, unit[:]), Error.None)
	pcm, expected: [3072]f32
	_, _, err := decode_loas_frame(d, stream[:], pcm[:]); testing.expect_value(t, err, Error.None)
	testing.expect(t, d.explicit_layout && d.program == p)
	banks, seed, layout, program, mux, drc :=
		d.bank, d.noise_seed, d.layout, d.program, d.latm, d.dynamic_range
	// New ASC selects standard center/front pair tags0, unlike prior tags7/9.
	w = common.init_bit_writer(&unit)
	feature_audio(&w, {.SCE, 0, 0, 1}, 3, 1024)
	feature_audio(&w, {.CPE, 0, 1, 2}, 3, 1024)
	feature_end(&w)
	append(&unit, u8(0)) // syntax-valid first AU followed by forbidden junk
	clear(&stream)
	testing.expect_value(t, aac.append_loas(&stream, config, unit[:]), Error.None)
	for &value in pcm do value = -77
	_, _, err = decode_loas_frame(
		d,
		stream[:],
		pcm[:],
	); testing.expect_value(t, err, Error.Invalid_Data)
	testing.expect(
		t,
		feature_banks_equal(d.bank[:], banks[:]) &&
		d.noise_seed == seed &&
		d.layout == layout &&
		d.program == program &&
		d.latm == mux &&
		d.dynamic_range == drc,
	)
	for value in pcm do testing.expect_value(t, value, f32(-77))
	resize(&unit, len(unit) - 1)
	for frame in 0 ..< 2 {
		clear(&stream)
		testing.expect_value(t, aac.append_loas(&stream, config, unit[:], frame == 1), Error.None)
		_, _, err = decode_loas_frame(
			d,
			stream[:],
			pcm[:],
		); testing.expect_value(t, err, Error.None)
		_, err = decode_frame(
			oracle,
			unit[:],
			expected[:],
		); testing.expect_value(t, err, Error.None)
		for sample in 0 ..< len(pcm) do testing.expect_value(t, pcm[sample], expected[sample])
		testing.expect(
			t,
			feature_banks_equal(d.bank[:], oracle.bank[:]) &&
			!d.explicit_layout &&
			d.program == aac.Program_Config{} &&
			!d.latm.config.use_pce,
		)
	}
}

@(test)
test_loas_subframe_and_mux_config_transaction :: proc(t: ^testing.T) {
	d, oracle := new(Decoder), new(Decoder); defer free(d); defer free(oracle)
	one, two, bad, packet: [dynamic]u8; defer delete(one); defer delete(two); defer delete(bad); defer delete(packet)
	config := Config {
		sample_rate   = 48000,
		channels      = 1,
		frame_samples = 960,
	}
	w := common.init_bit_writer(&one); feature_audio(&w, {.SCE, 0, 0, 1}, 3, 960); feature_end(&w)
	w = common.init_bit_writer(
		&two,
	); feature_audio(&w, {.SCE, 0, 0, 1}, 3, 960, false); feature_end(&w)
	w = common.init_bit_writer(
		&bad,
	); feature_audio(&w, {.SCE, 0, 0, 1}, 3, 960, false); common.write_bits(&w, 3, 3); common.write_align_zero(&w)
	units := [2][]u8{one[:], two[:]}
	testing.expect_value(t, init_decoder(d, config), Error.None)
	testing.expect_value(t, init_decoder(oracle, config), Error.None)
	actual, expected: [2 * 960]f32
	for same in ([2]bool{false, true}) {
		clear(&packet)
		testing.expect_value(
			t,
			aac.append_loas_blocks(&packet, config, units[:], same, !same),
			Error.None,
		)
		for unit, index in units {
			_, e := decode_frame(
				oracle,
				unit,
				expected[index * 960:(index + 1) * 960],
			); testing.expect_value(t, e, Error.None)
		}
		bytes, samples, err := decode_loas_frame(d, packet[:], actual[:])
		testing.expect_value(
			t,
			err,
			Error.None,
		); testing.expect_value(t, samples, 1920); testing.expect_value(t, bytes, len(packet))
		for value, index in actual do testing.expect_value(t, value, expected[index])
		testing.expect(
			t,
			feature_banks_equal(d.bank[:], oracle.bank[:]) && d.noise_seed == oracle.noise_seed,
		)
	}
	banks, coupling_banks, seed, mux, drc :=
		d.bank, d.coupling_bank, d.noise_seed, d.latm, d.dynamic_range
	units[1] = bad[:]
	clear(
		&packet,
	); testing.expect_value(t, aac.append_loas_blocks(&packet, config, units[:], true), Error.None)
	for &v in actual do v = -83
	_, _, error := decode_loas_frame(d, packet[:], actual[:]); testing.expect(t, error != .None)
	testing.expect(
		t,
		feature_banks_equal(d.bank[:], banks[:]) &&
		feature_banks_equal(d.coupling_bank[:], coupling_banks[:]) &&
		d.noise_seed == seed &&
		d.latm == mux &&
		d.dynamic_range == drc,
	)
	for value in actual do testing.expect_value(t, value, f32(-83))
	// A failing new StreamMuxConfig cannot replace a successful prior config.
	units[1] = two[:]
	wrong := config; wrong.sample_rate = 44100
	clear(
		&packet,
	); testing.expect_value(t, aac.append_loas_blocks(&packet, wrong, units[:]), Error.None)
	_, _, error = decode_loas_frame(
		d,
		packet[:],
		actual[:],
	); testing.expect_value(t, error, Error.Invalid_Config)
	testing.expect(t, d.latm == mux && feature_banks_equal(d.bank[:], banks[:]))
	clear(
		&packet,
	); testing.expect_value(t, aac.append_loas_blocks(&packet, config, units[:], true), Error.None)
	_, _, error = decode_loas_frame(
		d,
		packet[:],
		actual[:],
	); testing.expect_value(t, error, Error.None)
}

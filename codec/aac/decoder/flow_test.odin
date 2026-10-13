package aac_decoder

import aac ".."
import common "../../common"
import "core:math"
import "core:testing"

// Retain the old two-stage PNS/stereo equations independently of the new
// per-band classification. Expected paths do not call production helpers.
@(private)
flow_test_original_noise :: proc(seed: ^u32, out: []f64, sf: int) {
	energy: f64
	for &v in out {
		seed^ = seed^ * 1664525 + 1013904223
		v = f64(i32(seed^)); energy += v * v
	}
	scale := math.pow(2.0, f64(sf) / 4) / math.sqrt(max(energy, 1))
	for &v in out do v *= scale
}

@(private)
flow_test_original_stereo_noise :: proc(d: ^Decoder, common_window: bool, ms: ^[8][64]bool) {
	left, right := &d.channel[0], &d.channel[1]
	for ch in 0 ..< d.config.channels {
		c := &d.channel[ch]
		window := 0
		stride := c.ics.sequence == .Short ? 128 : 1024
		for g in 0 ..< c.ics.groups {
			for b in 0 ..< c.ics.max_sfb {
				if c.codebook[g][b] != 13 do continue
				for w in 0 ..< c.ics.group_length[g] {
					start := (window + w) * stride + c.ics.offsets[b]
					end := (window + w) * stride + c.ics.offsets[b + 1]
					if ch == 1 && common_window && ms[g][b] && left.codebook[g][b] == 13 {
						scale := math.pow(2.0, f64(c.sf[g][b] - left.sf[g][b]) / 4)
						for k in start ..< end do c.spectrum[k] = left.spectrum[k] * scale
					} else {
						flow_test_original_noise(&d.noise_seed, c.spectrum[start:end], c.sf[g][b])
					}
				}
			}
			window += c.ics.group_length[g]
		}
	}
	if !common_window || d.config.channels != 2 do return
	window := 0
	stride := left.ics.sequence == .Short ? 128 : 1024
	for g in 0 ..< left.ics.groups {
		for b in 0 ..< left.ics.max_sfb {
			for w in 0 ..< left.ics.group_length[g] {
				cb := right.codebook[g][b]
				scale := math.pow(2.0, -f64(right.sf[g][b]) / 4)
				if cb == 14 do scale = -scale
				if ms[g][b] do scale = -scale
				for k in left.ics.offsets[b] ..< left.ics.offsets[b + 1] {
					i := (window + w) * stride + k
					if cb == 14 || cb == 15 {
						right.spectrum[i] = left.spectrum[i] * scale
					} else if ms[g][b] && cb != 13 && left.codebook[g][b] != 13 {
						l, r := left.spectrum[i], right.spectrum[i]
						left.spectrum[i], right.spectrum[i] = l + r, l - r
					}
				}
			}
		}
		window += left.ics.group_length[g]
	}
}

@(private)
flow_test_ics :: proc(layout: int) -> Ics {
	info := Ics {
		sequence = .Long,
		max_sfb  = 6,
		groups   = 1,
		offsets  = aac.SWB_LONG[3],
	}
	info.group_length[0] = 1
	switch layout {
	case 1:
		info.sequence = .Short; info.group_length = {8, 0, 0, 0, 0, 0, 0, 0}
	case 2:
		info.sequence = .Short; info.groups = 4; info.group_length = {2, 3, 1, 2, 0, 0, 0, 0}
	case 3:
		info.sequence = .Short; info.groups = 8; info.group_length = {1, 1, 1, 1, 1, 1, 1, 1}
	}
	if info.sequence == .Short do info.offsets = aac.SWB_SHORT[3]
	return info
}

@(private)
flow_test_fill_channel :: proc(c: ^Channel, info: Ics, book: u8, sf_pattern, ch: int) {
	c^ = {}
	c.ics = info
	// Distinct nonzero tail values prove that band tools do not touch uncoded
	// windows/bins. Codebook-zero active bands use their actual zero spectrum.
	for &v, i in c.spectrum do v = f64((i * 71 + ch * 13) % 257 - 128) / 32
	window := 0
	stride := info.sequence == .Short ? 128 : 1024
	for g in 0 ..< info.groups {
		for b in 0 ..< info.max_sfb {
			c.codebook[g][b] = book
			if book == 0 {
				c.sf[g][b] = 0
			} else if book == 1 {
				c.sf[g][b] = ((sf_pattern + ch + g + b) & 1) == 0 ? 0 : 255
			} else {
				c.sf[g][b] =
					sf_pattern == 0 ? 0 : (((ch + g + b + sf_pattern) & 1) == 0 ? -512 : 512)
			}
			if book == 0 || book >= 14 {
				for w in 0 ..< info.group_length[g] {
					start := (window + w) * stride + info.offsets[b]
					end := (window + w) * stride + info.offsets[b + 1]
					for &v in c.spectrum[start:end] do v = 0
				}
			}
		}
		window += info.group_length[g]
	}
}

@(private)
flow_test_spectra_and_seed :: proc(t: ^testing.T, got, want: ^Decoder, case_index: int) {
	testing.expect_value(t, got.noise_seed, want.noise_seed)
	for ch in 0 ..< 2 {
		for v, i in want.channel[ch].spectrum {
			testing.expectf(
				t,
				transmute(u64)got.channel[ch].spectrum[i] == transmute(u64)v,
				"stereo/PNS case=%d channel=%d sample=%d",
				case_index,
				ch,
				i,
			)
		}
	}
}

@(test)
test_stereo_noise_old_equations_all_bands_and_groupings :: proc(t: ^testing.T) {
	actual, expected := new(Decoder), new(Decoder)
	defer free(actual)
	defer free(expected)
	actual.config.channels, expected.config.channels = 2, 2
	case_index := 0
	for layout in 0 ..< 4 {
		info := flow_test_ics(layout)
		windows := 0
		for n in info.group_length[:info.groups] do windows += n
		testing.expect_value(t, windows, layout == 0 ? 1 : 8)
		for left_book in ([5]u8{0, 1, 13, 14, 15}) {
			for right_book in ([5]u8{0, 1, 13, 14, 15}) {
				for use_ms in ([2]bool{false, true}) {
					for sf_pattern in 0 ..< 3 {
						flow_test_fill_channel(&actual.channel[0], info, left_book, sf_pattern, 0)
						flow_test_fill_channel(&actual.channel[1], info, right_book, sf_pattern, 1)
						actual.noise_seed = u32(case_index * 7919) ~ 0x936571ab
						expected.channel, expected.noise_seed = actual.channel, actual.noise_seed
						ms: [8][64]bool
						for g in 0 ..< info.groups do for b in 0 ..< info.max_sfb do ms[g][b] = use_ms
						// This local helper matrix includes every cb pair. Left
						// intensity is rejected earlier by complete-frame validation;
						// its inclusion here checks the helper's old local semantics.
						stereo_and_noise(actual, true, &ms)
						flow_test_original_stereo_noise(expected, true, &ms)
						flow_test_spectra_and_seed(t, actual, expected, case_index)
						case_index += 1
					}
				}
			}
		}
	}
	// The matrix includes cb0+MS with one nonzero partner, and intensity on
	// the right with PNS on the left: neither may be skipped by MS classification.
	testing.expect_value(t, case_index, 600)
}

@(test)
test_stereo_noise_independent_grouping_and_mono_seed_order :: proc(t: ^testing.T) {
	actual, expected := new(Decoder), new(Decoder)
	defer free(actual)
	defer free(expected)
	for channels in 1 ..= 2 {
		actual.config.channels, expected.config.channels = channels, channels
		for left_layout in 0 ..< 4 {
			for right_layout in 0 ..< 4 {
				flow_test_fill_channel(&actual.channel[0], flow_test_ics(left_layout), 13, 1, 0)
				flow_test_fill_channel(&actual.channel[1], flow_test_ics(right_layout), 13, 2, 1)
				actual.noise_seed = 0x85731bdf
				expected.channel, expected.noise_seed = actual.channel, actual.noise_seed
				ms: [8][64]bool
				for &row in ms do for &v in row do v = true
				stereo_and_noise(actual, false, &ms)
				flow_test_original_stereo_noise(expected, false, &ms)
				flow_test_spectra_and_seed(
					t,
					actual,
					expected,
					channels * 100 + left_layout * 4 + right_layout,
				)
			}
		}
	}
}

// A small direct syntax writer supplies a successful PNS frame, a pulse-free
// escaped spectral frame, and late syntax errors after their channel is read.
// It uses public codewords plus the independent existing tuple test writer.
@(private)
flow_test_frame :: proc(buf: ^[dynamic]u8, noise, invalid_end: bool) {
	w := common.init_bit_writer(buf)
	common.write_bits(&w, 0, 3) // Single-channel element.
	common.write_bits(&w, 0, 4)
	common.write_bits(&w, 100, 8)
	common.write_bits(&w, 0, 1) // Reserved.
	common.write_bits(&w, 0, 2) // Long.
	common.write_bits(&w, 0, 1) // Sine.
	common.write_bits(&w, 1, 6) // First four-coefficient band.
	common.write_bits(&w, 0, 1) // Predictor absent.
	common.write_bits(&w, noise ? 13 : 11, 4)
	common.write_bits(&w, 1, 5)
	if noise {
		common.write_bits(&w, 326, 9) // (100-90)+(326-256)=80 noise scalefactor.
	} else {
		code := aac.CODEBOOKS[0][60]
		common.write_bits(&w, code.bits, int(code.length))
	}
	common.write_bits(&w, 0, 3) // Pulse, TNS, gain control absent.
	if !noise {
		tuple_test_write(&w, 11, 16 * 17, {-129, 0, 0, 0}, 2)
		tuple_test_write(&w, 11, 0, {}, 2)
	}
	common.write_bits(&w, invalid_end ? 3 : 7, 3) // Truncated late LFE or END.
	common.write_align_zero(&w)
}

@(private)
flow_test_committed_state :: proc(
	t: ^testing.T,
	d: ^Decoder,
	banks: ^[aac.MAX_CHANNELS]aac.Filterbank,
	seed: u32,
) {
	testing.expect_value(t, d.noise_seed, seed)
	for ch in 0 ..< 2 {
		testing.expect_value(t, d.bank[ch].previous_shape, banks[ch].previous_shape)
		for v, i in banks[ch].overlap do tuple_test_exact_f64(t, d.bank[ch].overlap[i], v)
	}
}

@(test)
test_rejected_after_success_retries_normal_pulse_and_noise_exact :: proc(t: ^testing.T) {
	actual, baseline := new(Decoder), new(Decoder)
	defer free(actual)
	defer free(baseline)
	testing.expect_value(t, init_decoder(actual, {sample_rate = 48000, channels = 1}), Error.None)
	testing.expect_value(
		t,
		init_decoder(baseline, {sample_rate = 48000, channels = 1}),
		Error.None,
	)
	first, normal, pulse, late_noise, late_normal: [dynamic]u8
	defer delete(first)
	defer delete(normal)
	defer delete(pulse)
	defer delete(late_noise)
	defer delete(late_normal)
	flow_test_frame(&first, true, false)
	flow_test_frame(&normal, false, false)
	tuple_test_pulse_frame(&pulse, -68)
	flow_test_frame(&late_noise, true, true)
	flow_test_frame(&late_normal, false, true)
	output, expected: [1024]f32
	for d in ([2]^Decoder{actual, baseline}) {
		count, err := decode_frame(d, first[:], output[:])
		testing.expect_value(t, count, 1024)
		testing.expect_value(t, err, Error.None)
	}
	committed_banks, committed_seed := actual.bank, actual.noise_seed
	testing.expect(t, committed_seed != 1)
	nonzero_history := false
	for v in committed_banks[0].overlap do if v != 0 do nonzero_history = true
	testing.expect(t, nonzero_history)
	end_only := [1]u8{0xe0}
	for next, kind in ([3][]u8{normal[:], pulse[:], first[:]}) {
		baseline.bank, baseline.noise_seed = committed_banks, committed_seed
		count, err := decode_frame(baseline, next, expected[:])
		testing.expect_value(t, count, 1024)
		testing.expect_value(t, err, Error.None)
		if kind == 0 {
			want := math.pow(129.0, 4.0 / 3) * 1 * -1
			tuple_test_exact_f64(t, baseline.channel[0].spectrum[0], want)
			for v in baseline.channel[0].spectrum[1:] do tuple_test_exact_f64(t, v, 0)
		}
		// All byte truncations exclude at least one actual syntax bit: alignment
		// adds at most seven bits, never a separate padding byte.
		for case_index in 0 ..< (len(next) + 3) {
			actual.bank, actual.noise_seed = committed_banks, committed_seed
			flow_test_poison_channel(&actual.channel[0], case_index + kind * 100)
			flow_test_poison_channel(&actual.channel[1], case_index + kind * 100 + 1)
			for &v in output do v = -123.5
			bad := next[:min(case_index, len(next))]
			switch case_index - len(next) {
			case 0:
				bad = late_noise[:]
			case 1:
				bad = late_normal[:]
			case 2:
				bad = end_only[:]
			}
			samples, rejected := decode_frame(actual, bad, output[:])
			testing.expect_value(t, samples, 0)
			testing.expectf(t, rejected != .None, "kind=%d rejection=%d", kind, case_index)
			flow_test_committed_state(t, actual, &committed_banks, committed_seed)
			for v in output do testing.expect_value(t, v, f32(-123.5))
			replay_samples, replay_err := decode_frame(actual, next, output[:])
			testing.expect_value(t, replay_samples, 1024)
			testing.expect_value(t, replay_err, Error.None)
			for v, i in expected do testing.expect_value(t, transmute(u32)output[i], transmute(u32)v)
			flow_test_committed_state(t, actual, &baseline.bank, baseline.noise_seed)
		}
	}
}

// Test syntax owns its declared active fields. Invalid prior values make an
// omitted write visible without prescribing the unused pulse-free quant plane.
@(private)
flow_test_poison_channel :: proc(c: ^Channel, variant: int) {
	c.ics = {
		sequence     = .Short,
		shape        = 2,
		groups       = 8,
		max_sfb      = 64,
		group_length = {1, 1, 1, 1, 1, 1, 1, 1},
		offsets      = nil,
	}
	for &row in c.codebook do for &v in row do v = 12
	for &row in c.sf do for &v in row do v = 700 + variant
	for &v, i in c.spectrum do v = f64(i + variant + 1) / 8
	for &v, i in c.quant do v = i32(((i + variant) & 1) == 0 ? 7000 + i : -7000 - i)
	for &v in c.tns_count do v = 3
	for &window in c.tns do for &f in window {
		f.length, f.order, f.reverse = 7, 3, true
		for &v, j in f.reflection do v = f64(j + variant + 1) / 16
	}
}

@(private)
Flow_Test_Syntax :: struct {
	sequence:                  aac.Window_Sequence,
	shape:                     u8,
	layout, max_sfb, tns_kind: int,
	books:                     [3]u8,
	pulses:                    bool,
}

@(private)
flow_test_syntax_ics :: proc(s: Flow_Test_Syntax) -> Ics {
	info := flow_test_ics(s.sequence == .Short ? s.layout : 0)
	info.sequence, info.shape, info.max_sfb = s.sequence, s.shape, s.max_sfb
	return info
}

@(private)
flow_test_write_ics :: proc(w: ^common.Bit_Writer, info: Ics) {
	common.write_bits(w, 0, 1)
	common.write_bits(w, u32(info.sequence), 2)
	common.write_bits(w, u32(info.shape), 1)
	if info.sequence == .Short {
		common.write_bits(w, u32(info.max_sfb), 4)
		group, end := 0, info.group_length[0]
		for window in 1 ..< 8 {
			common.write_bits(w, window < end ? 1 : 0, 1)
			if window == end {group += 1; end += info.group_length[group]}
		}
	} else {
		common.write_bits(w, u32(info.max_sfb), 6)
		common.write_bits(w, 0, 1)
	}
}

@(private)
flow_test_write_channel :: proc(w: ^common.Bit_Writer, s: Flow_Test_Syntax, common_window: bool) {
	info := flow_test_syntax_ics(s)
	short := info.sequence == .Short
	common.write_bits(w, 100, 8)
	if !common_window do flow_test_write_ics(w, info)
	for _ in 0 ..< info.groups do for b in 0 ..< info.max_sfb {
		common.write_bits(w, u32(s.books[b]), 4)
		common.write_bits(w, 1, short ? 3 : 5)
	}
	first_noise := true
	for _ in 0 ..< info.groups do for b in 0 ..< info.max_sfb {
		book := s.books[b]
		if book == 0 do continue
		if book == 13 && first_noise {
			common.write_bits(w, 326, 9) // Noise SF 80, with later deltas zero.
			first_noise = false
		} else {
			code := aac.CODEBOOKS[0][60]
			common.write_bits(w, code.bits, int(code.length))
		}
	}
	common.write_bits(w, s.pulses ? 1 : 0, 1)
	if s.pulses {
		common.write_bits(w, 3, 2)
		common.write_bits(w, 0, 6)
		for i in 0 ..< 4 {
			common.write_bits(w, i == 0 ? 0 : 4, 5)
			common.write_bits(w, u32(i + 1), 4)
		}
	}
	common.write_bits(w, s.tns_kind == 0 ? 0 : 1, 1)
	if s.tns_kind != 0 {
		for window in 0 ..< (short ? 8 : 1) {
			common.write_bits(w, 1, short ? 1 : 2) // One filter per window.
			common.write_bits(w, 0, 1) // Three-bit coefficient resolution.
			common.write_bits(w, u32(len(info.offsets) - 1), short ? 4 : 6)
			order := s.tns_kind == 1 ? 0 : 2
			common.write_bits(w, u32(order), short ? 3 : 5)
			if order == 0 do continue
			common.write_bits(w, u32(window & 1), 1)
			common.write_bits(w, 0, 1)
			common.write_bits(w, 1, 3)
			common.write_bits(w, 7, 3)
		}
	}
	common.write_bits(w, 0, 1) // Gain control absent.
	for g in 0 ..< info.groups do for b in 0 ..< info.max_sfb {
		if s.books[b] != 1 do continue
		for _ in 0 ..< info.group_length[g] {
			for k := info.offsets[b]; k < info.offsets[b + 1]; k += 4 {
				// Base-three digits {2,0,1,2} encode {1,-1,0,1}.
				tuple_test_write(w, 1, 59, {1, -1, 0, 1}, 4)
			}
		}
	}
}

@(private)
flow_test_transition_frame :: proc(
	buf: ^[dynamic]u8,
	left, right: Flow_Test_Syntax,
	channels: int,
) {
	w := common.init_bit_writer(buf)
	common.write_bits(&w, channels == 1 ? 0 : 1, 3)
	common.write_bits(&w, 0, 4)
	if channels == 2 {
		common.write_bits(&w, 1, 1) // Shared fresh ICS owns both channels.
		flow_test_write_ics(&w, flow_test_syntax_ics(left))
		common.write_bits(&w, 0, 2) // No MS, intensity still applies.
	}
	flow_test_write_channel(&w, left, channels == 2)
	if channels == 2 do flow_test_write_channel(&w, right, true)
	common.write_bits(&w, 7, 3)
	common.write_align_zero(&w)
}

@(private)
flow_test_active_syntax :: proc(t: ^testing.T, c: ^Channel, s: Flow_Test_Syntax) {
	info := flow_test_syntax_ics(s)
	testing.expect_value(t, c.ics.sequence, info.sequence)
	testing.expect_value(t, c.ics.shape, info.shape)
	testing.expect_value(t, c.ics.max_sfb, info.max_sfb)
	testing.expect_value(t, c.ics.groups, info.groups)
	for n, g in info.group_length do testing.expect_value(t, c.ics.group_length[g], n)
	testing.expect_value(t, len(c.ics.offsets), len(info.offsets))
	for g in 0 ..< info.groups do for b in 0 ..< info.max_sfb {
		book := s.books[b]
		sf := book == 1 ? 100 : (book == 13 ? 80 : 0)
		testing.expect_value(t, c.codebook[g][b], book)
		testing.expect_value(t, c.sf[g][b], sf)
	}
	for n, window in c.tns_count {
		active := s.tns_kind != 0 && (info.sequence == .Short || window == 0)
		testing.expect_value(t, n, active ? 1 : 0)
	}
}

@(test)
test_poisoned_scratch_long_short_and_channel_transition_owners :: proc(t: ^testing.T) {
	actual, baseline := new(Decoder), new(Decoder)
	defer free(actual)
	defer free(baseline)
	buf: [dynamic]u8
	defer delete(buf)
	frames := [?]Flow_Test_Syntax {
		{sequence = .Long, max_sfb = 3, books = {1, 13, 0}, tns_kind = 2},
		{sequence = .Start, shape = 1, max_sfb = 3, books = {0, 1, 13}, tns_kind = 1},
		{sequence = .Short, layout = 2, max_sfb = 3, books = {13, 0, 1}, tns_kind = 2},
		{sequence = .Short, shape = 1, layout = 3, max_sfb = 1, books = {0, 1, 13}},
		{sequence = .Short, layout = 1, max_sfb = 0},
		{sequence = .Stop, shape = 1, max_sfb = 2, books = {0, 13, 1}, tns_kind = 1},
		{sequence = .Long, max_sfb = 3, books = {1, 0, 13}},
		{sequence = .Long, max_sfb = 0},
		{sequence = .Long, shape = 1, max_sfb = 1, books = {0, 1, 13}},
	}
	got, want: [2050]f32
	for channels in 1 ..= 2 {
		testing.expect_value(
			t,
			init_decoder(actual, {sample_rate = 48000, channels = channels}),
			Error.None,
		)
		testing.expect_value(
			t,
			init_decoder(baseline, {sample_rate = 48000, channels = channels}),
			Error.None,
		)
		for left, frame in frames {
			right := left
			right.books = {0, 13, (frame & 1) == 0 ? u8(14) : u8(15)}
			flow_test_transition_frame(&buf, left, right, channels)
			for ch in 0 ..< 2 do flow_test_poison_channel(&actual.channel[ch], frame * 2 + ch)
			inactive := actual.channel[1]
			// Independent comparison has the old whole-channel-zero defaults;
			// both controls retain their own committed bank/seed across frames.
			baseline.channel = {}
			for &v in got do v = -123.5
			n, e := decode_frame(baseline, buf[:], want[1:1 + 1024 * channels])
			testing.expect_value(t, n, 1024)
			testing.expect_value(t, e, Error.None)
			n, e = decode_frame(actual, buf[:], got[1:1 + 1024 * channels])
			testing.expect_value(t, n, 1024)
			testing.expect_value(t, e, Error.None)
			if e != .None do continue
			for i in 0 ..< 1024 * channels do testing.expect_value(t, transmute(u32)got[i + 1], transmute(u32)want[i + 1])
			testing.expect_value(t, got[0], f32(-123.5))
			testing.expect_value(t, got[1 + 1024 * channels], f32(-123.5))
			flow_test_active_syntax(t, &actual.channel[0], left)
			if channels == 2 do flow_test_active_syntax(t, &actual.channel[1], right)
			for ch in 0 ..< channels do for v, i in baseline.channel[ch].spectrum {
				tuple_test_exact_f64(t, actual.channel[ch].spectrum[i], v)
			}
			flow_test_committed_state(t, actual, &baseline.bank, baseline.noise_seed)
			if channels == 1 {
				// The inactive mono channel is deliberately invalid and nonzero,
				// so reading or clearing it would violate this ownership boundary.
				testing.expect_value(t, actual.channel[1].ics.max_sfb, inactive.ics.max_sfb)
				testing.expect(t, actual.channel[1].ics.offsets == nil)
				for v, i in inactive.spectrum do tuple_test_exact_f64(t, actual.channel[1].spectrum[i], v)
				for v, i in inactive.tns_count do testing.expect_value(t, actual.channel[1].tns_count[i], v)
			}
		}
	}
}

@(test)
test_poisoned_pulse_quant_clears_tool_and_uncoded_positions :: proc(t: ^testing.T) {
	actual, baseline := new(Decoder), new(Decoder)
	defer free(actual)
	defer free(baseline)
	testing.expect_value(t, init_decoder(actual, {sample_rate = 48000, channels = 2}), Error.None)
	testing.expect_value(
		t,
		init_decoder(baseline, {sample_rate = 48000, channels = 2}),
		Error.None,
	)
	buf: [dynamic]u8
	defer delete(buf)
	got, want: [2048]f32
	for intensity in ([2]u8{14, 15}) {
		left := Flow_Test_Syntax {
			sequence = .Long,
			max_sfb  = 3,
			books    = {1, 13, 0},
			pulses   = true,
		}
		right := left
		right.books = {0, 13, intensity}
		for b in 0 ..= 3 do testing.expect_value(t, aac.SWB_LONG[3][b], b * 4)
		flow_test_transition_frame(&buf, left, right, 2)
		for ch in 0 ..< 2 do flow_test_poison_channel(&actual.channel[ch], ch + int(intensity))
		baseline.channel = {}
		n, e := decode_frame(baseline, buf[:], want[:])
		testing.expect_value(t, n, 1024)
		testing.expect_value(t, e, Error.None)
		n, e = decode_frame(actual, buf[:], got[:])
		testing.expect_value(t, n, 1024)
		testing.expect_value(t, e, Error.None)
		if e != .None do continue
		for v, i in want do testing.expect_value(t, transmute(u32)got[i], transmute(u32)v)
		flow_test_committed_state(t, actual, &baseline.bank, baseline.noise_seed)
		for ch in 0 ..< 2 {
			flow_test_active_syntax(t, &actual.channel[ch], ch == 0 ? left : right)
			for v, i in baseline.channel[ch].quant do testing.expect_value(t, actual.channel[ch].quant[i], v)
			for v, i in baseline.channel[ch].spectrum do tuple_test_exact_f64(t, actual.channel[ch].spectrum[i], v)
		}
		// The right channel's pulses start from zero in cb0, PNS, intensity,
		// and above max_sfb; none may inherit the poisoned prior integer plane.
		for i in 0 ..< 4 do testing.expect_value(t, actual.channel[1].quant[i * 4], -i32(i + 1))
		// ZERO_HCB owns sf0, so restored pulses pass through the independent
		// inverse-quantization equation before the later PNS/intensity tools.
		zero_scale := math.pow(2.0, -25)
		right_zero := -math.pow(1.0, 4.0 / 3) * zero_scale
		left_zero := -math.pow(3.0, 4.0 / 3) * zero_scale
		tuple_test_exact_f64(t, actual.channel[1].spectrum[0], right_zero)
		tuple_test_exact_f64(t, actual.channel[0].spectrum[8], left_zero)
		tuple_test_exact_f64(
			t,
			actual.channel[1].spectrum[8],
			intensity == 14 ? -left_zero : left_zero,
		)
		for value in actual.channel[1].spectrum[1:4] do tuple_test_exact_f64(t, value, 0)
		for ch in 0 ..< 2 {
			// Intensity phase can represent a zero coefficient as negative zero.
			for value in actual.channel[ch].spectrum[9:12] do testing.expect_value(t, value, f64(0))
			// The pulse at line12 remains outside max_sfb and has no consumer.
			for value in actual.channel[ch].spectrum[12:] do tuple_test_exact_f64(t, value, 0)
			// PNS replaces its integer pulse with normalized noise at SF80.
			energy: f64
			for value in actual.channel[ch].spectrum[4:8] do energy += value * value
			expected_energy := math.pow(2.0, 40)
			testing.expect(t, abs(energy - expected_energy) <= expected_energy * 1e-12)
		}
	}
}

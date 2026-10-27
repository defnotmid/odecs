package aac_encoder

import aac ".."
import "core:math"

@(private)
framed_bits :: proc(e: ^Encoder, bits: int) -> int {
	overhead := e.latm_config_sent ? e.next_transport_bits : e.first_transport_bits
	if e.transport == .LOAS do overhead += (bits / 8 / 255) * 8
	return bits + overhead
}

@(private)
prepare_packet :: proc(e: ^Encoder, ahead_attack: bool) -> Error {
	sequence := select_sequence(e, ahead_attack)
	analyze_block(e, sequence)
	numerator := e.config.bit_rate * e.frame_samples + e.rate_remainder
	nominal := numerator / e.config.sample_rate
	e.prepared_rate_remainder = numerator % e.config.sample_rate
	extra := 0
	if !e.options.disable_reservoir && !e.options.constant_bit_rate {
		// The final overlap carries the release to silence. Spend retained
		// credit on that boundary just as on an input attack; otherwise the
		// last audible samples pay for leakage from the abrupt release.
		target_reservoir := min(e.reservoir_limit / 4, nominal / 2)
		extra =
			e.pending_attack || sequence == .Short || e.flush_stage > 0 ? min(e.reservoir_bits / 2, nominal) : (e.reservoir_bits - target_reservoir) / 8
	}
	maximum_packet := min(6144 * e.independent_channels, 65528)
	budget := min(nominal + extra, maximum_packet)
	maximum_raw := maximum_packet
	if e.transport == .ADTS do maximum_raw -= 56
	adjustment := 0
	quantize(e, 0)
	cost := raw_bits(e)
	if cost > maximum_raw || framed_bits(e, cost) > budget {
		quantize(e, 192)
		minimum := raw_bits(e)
		if minimum > maximum_raw || framed_bits(e, minimum) > budget {
			// At extreme low rates, optional tool side information can exceed
			// the budget. Re-analyze from the retained unfiltered PCM rather
			// than dropping a TNS flag from already-filtered coefficients.
			options := e.options
			e.options.disable_tns =
				true; e.options.disable_ms = true; e.options.disable_pns = true; e.options.disable_intensity = true
			analyze_block(e, sequence)
			e.options = options
			quantize(e, 192); minimum = raw_bits(e)
			if minimum > maximum_raw do return .Invalid_Config
			// Tiny transport-only blocks have a minimum representable size.
			// The reservoir records actual emitted bytes, never estimated bits.
			budget = max(budget, framed_bits(e, minimum))
			if budget > maximum_packet do return .Invalid_Config
		}
		low, high := 0, 192
		for low < high {
			mid := low + (high - low) / 2
			quantize(e, mid); bits := raw_bits(e)
			if bits > maximum_raw ||
			   framed_bits(e, bits) > budget {low = mid + 1} else {high = mid}
		}
		adjustment = high; quantize(e, high); cost = raw_bits(e)
	}
	padding := 0
	if e.options.constant_bit_rate {
		overhead := e.latm_config_sent ? e.next_transport_bits : e.first_transport_bits
		padding = min(maximum_raw, max(0, budget - overhead)) &~ 7
		for padding > cost && framed_bits(e, padding) > budget do padding -= 8
	}
	write_payload(e, padding)
	assert(
		len(e.payload) * 8 >= cost && (padding == 0 || len(e.payload) * 8 <= max(cost, padding)),
	)
	if len(e.payload) * 8 > maximum_raw do return .Invalid_Data
	clear(&e.packet)
	err: Error
	switch e.transport {
	case .ADTS:
		err = aac.append_adts(&e.packet, e.config, e.payload[:])
	case .Raw:
		append(&e.packet, ..e.payload[:])
	case .LOAS:
		err = aac.append_loas(&e.packet, e.config, e.payload[:], e.latm_config_sent)
	}
	if err != .None do return err
	e.prepared_reservoir_bits =
		e.options.disable_reservoir ? 0 : clamp(e.reservoir_bits + nominal - len(e.packet) * 8, 0, e.reservoir_limit)
	e.work_stats.bytes = len(
		e.packet,
	); e.work_stats.target_bits = budget; e.work_stats.adjustment = adjustment
	e.work_stats.reservoir_bits = e.prepared_reservoir_bits
	return .None
}

@(private)
commit_packet :: proc(e: ^Encoder) {
	for ch in 0 ..< e.config.channels do copy(e.previous[ch][:e.frame_samples], e.pending[ch][:e.frame_samples])
	e.sequence = e.work_stats.sequence; e.previous_shape = e.options.window_shape
	e.reservoir_bits = e.prepared_reservoir_bits; e.rate_remainder = e.prepared_rate_remainder
	e.frames += 1; e.stats = e.work_stats
	if e.transport == .LOAS do e.latm_config_sent = true
}

@(private)
validate_input :: proc(e: ^Encoder, pcm: []f32) -> Error {
	if e == nil do return .Invalid_State
	if !e.initialized || e.finished || e.flush_stage != 0 do return .Invalid_State
	if len(pcm) != e.frame_samples * e.config.channels do return .Invalid_Config
	for value in pcm do if math.is_nan(value) || math.is_inf(value) || abs(value) > 1 do return .Invalid_Data
	return .None
}

@(private)
retain_input :: proc(e: ^Encoder, pcm: []f32, early_attack, late_attack: bool, energy, tail: [aac.MAX_CHANNELS]f64) {
	for ch in 0 ..< e.config.channels do for i in 0 ..< e.frame_samples do e.pending[ch][i] = f64(pcm[i * e.config.channels + ch]) * 32768
	e.pending_valid = true
	e.pending_attack = e.pending_late_attack || early_attack
	e.pending_late_attack = late_attack
	e.input_energy = energy; e.input_tail = tail; e.input_frames += 1
}

@(private)
append_packet :: proc(output: ^[dynamic]u8, packet: []u8) -> Error {
	if output == nil || len(output) > max(int) - len(packet) do return .Invalid_Config
	needed := len(output) + len(packet)
	if needed > cap(output) {
		capacity := max(needed, cap(output) <= max(int) / 2 ? cap(output) * 2 : needed)
		if error := reserve(output, capacity); error != nil do return .Allocation_Failed
	}
	if needed > 0 && (raw_data(output^) == nil || cap(output) < needed) do return .Allocation_Failed
	append(output, ..packet)
	return .None
}

// Accept exactly frame_samples interleaved samples/channel. One frame of
// lookahead selects the preceding start window; the first call emits no AU.
// Transport is chosen at init; Raw callers retain each emitted AU boundary.
encode_frame :: proc(e: ^Encoder, pcm: []f32, output: ^[dynamic]u8) -> Error {
	if output == nil do return .Invalid_Config
	if err := validate_input(e, pcm); err != .None do return err
	early_attack, late_attack, energy, tail := detect_attack(e, pcm)
	if e.pending_valid {
		if err := prepare_packet(e, e.pending_late_attack || early_attack); err != .None do return err
		if err := append_packet(output, e.packet[:]); err != .None do return err
		commit_packet(e)
	}
	retain_input(e, pcm, early_attack, late_attack, energy, tail)
	return .None
}

// Caller-owned output; rejected input/capacity preserves stream histories.
// bytes==0 on the first accepted input. No frame allocation or output merge.
encode_frame_to :: proc(e: ^Encoder, pcm: []f32, output: []u8) -> (bytes: int, err: Error) {
	if error := validate_input(e, pcm); error != .None do return 0, error
	early_attack, late_attack, energy, tail := detect_attack(e, pcm)
	if e.pending_valid {
		if error := prepare_packet(e, e.pending_late_attack || early_attack); error != .None do return 0, error
		if len(output) < len(e.packet) do return 0, .Output_Too_Small
		bytes = copy(output, e.packet[:]); commit_packet(e)
	}
	retain_input(e, pcm, early_attack, late_attack, energy, tail)
	return bytes, .None
}

// The returned AU/frame borrows retained storage until the next codec call.
encode_frame_borrowed :: proc(e: ^Encoder, pcm: []f32) -> (packet: []u8, err: Error) {
	if error := validate_input(e, pcm); error != .None do return nil, error
	early_attack, late_attack, energy, tail := detect_attack(e, pcm)
	if e.pending_valid {
		if error := prepare_packet(e, e.pending_late_attack || early_attack); error != .None do return nil, error
		packet = e.packet[:]; commit_packet(e)
	}
	retain_input(e, pcm, early_attack, late_attack, energy, tail)
	return packet, .None
}

@(private)
prepare_flush :: proc(e: ^Encoder) -> (have_packet: bool, err: Error) {
	if e == nil do return false, .Invalid_State
	if !e.initialized do return false, .Invalid_State
	if e.finished do return false, .None
	if !e.pending_valid {e.finished = true; return false, .None}
	if error := prepare_packet(e, e.pending_late_attack); error != .None do return false, error
	return true, .None
}

@(private)
commit_flush :: proc(e: ^Encoder) {
	commit_packet(e)
	if e.flush_stage == 0 {
		for ch in 0 ..< e.config.channels do for &value in e.pending[ch][:e.frame_samples] do value = 0
		e.pending_attack = e.pending_late_attack; e.pending_late_attack = false; e.flush_stage = 1
	} else {e.pending_valid = false; e.finished = true; e.flush_stage = 2}
}

// Each call returns at most one borrowed packet. Drain until packet is empty.
flush_encoder_next_borrowed :: proc(e: ^Encoder) -> (packet: []u8, err: Error) {
	have, error := prepare_flush(e)
	if error != .None || !have do return nil, error
	packet = e.packet[:]; commit_flush(e)
	return packet, .None
}

flush_encoder_next_to :: proc(e: ^Encoder, output: []u8) -> (bytes: int, err: Error) {
	have, error := prepare_flush(e)
	if error != .None || !have do return 0, error
	if len(output) < len(e.packet) do return 0, .Output_Too_Small
	bytes = copy(output, e.packet[:]); commit_flush(e)
	return bytes, .None
}

// Append pending input and final overlap. Retry resumes an interrupted drain;
// repeated completed flushes are harmless. Original unpadded length is external.
flush_encoder :: proc(e: ^Encoder, output: ^[dynamic]u8) -> Error {
	if output == nil do return .Invalid_Config
	for {
		have, err := prepare_flush(e)
		if err != .None || !have do return err
		if error := append_packet(output, e.packet[:]); error != .None do return error
		commit_flush(e)
	}
}

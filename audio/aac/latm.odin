package aac

import common "../../common"

LATM_State :: struct {
	initialized:                         bool,
	config:                              Config,
	num_subframes:                       int, // syntax value 0..63: one more access unit than this
	frame_length_type, fixed_frame_bits: int,
	other_data_bits:                     int,
}
LATM_Frame :: struct {
	config:            Config,
	access_units:      [64][]u8,
	access_unit_count: int,
}

@(private)
latm_get_value :: proc(r: ^Bit_Reader) -> u32 {
	bytes := 1 + int(read_bits(r, 2))
	value: u32
	for _ in 0 ..< bytes do value = value << 8 | read_bits(r, 8)
	return value
}

// ISO/IEC14496-3 1.7.3.2.3/1.8.4.3: StreamMuxConfig CRC covers the
// audioMuxVersion bit through otherData syntax, excluding crcCheckPresent.
// Polynomial x^8+x^2+x+1, zero initial remainder, inverted transmitted bits.
latm_config_crc :: proc(data: []u8, first, end: int) -> (u8, Error) {
	if first < 0 || end < first || end / 8 > len(data) || (end / 8 == len(data) && end & 7 != 0) do return 0, .Invalid_Config
	crc: u8
	for bit in first ..< end {
		feedback := (crc >> 7) ~ ((data[bit >> 3] >> uint(7 - (bit & 7))) & 1)
		crc <<= 1
		if feedback != 0 do crc ~= 0x07
	}
	return crc ~ 0xff, .None
}

@(private)
read_stream_mux_config :: proc(r: ^Bit_Reader) -> (state: LATM_State, err: Error) {
	first := r.pos
	version := read_flag(r)
	if version && read_flag(r) do return {}, .Unsupported_Transport
	if version do _ = latm_get_value(r) // taraBufferFullness
	if !read_flag(r) do return {}, r.err == .None ? Error.Unsupported_Transport : r.err
	state.num_subframes = int(read_bits(r, 6))
	programs, layers := read_bits(r, 4), read_bits(r, 3)
	if r.err != .None do return {}, r.err
	if programs != 0 || layers != 0 do return {}, .Unsupported_Transport
	asc_bits := 0
	if version {
		value := latm_get_value(r)
		if r.err != .None do return {}, r.err
		if value > u32(len(r.data) * 8 - r.pos) do return {}, .Truncated
		asc_bits = int(value)
	}
	asc_start := r.pos
	state.config, err = read_audio_specific_config(r)
	if err != .None do return {}, err
	if version {
		consumed := r.pos - asc_start
		if consumed > asc_bits do return {}, .Invalid_Data
		// The ASC length owns optional extensions, not subsequent LATM bits.
		if asc_bits - consumed >= 11 {
			probe := r^
			if read_bits(&probe, 11) == 0x2b7 do return {}, .Unsupported_Profile
		}
		skip_bits(r, asc_bits - consumed)
	}
	state.frame_length_type = int(read_bits(r, 3))
	switch state.frame_length_type {
	case 0:
		_ = read_bits(r, 8) // latmBufferFullness
	case 1:
		state.fixed_frame_bits = 8 * (20 + int(read_bits(r, 9)))
	case:
		return {}, r.err == .None ? Error.Unsupported_Transport : r.err
	}
	if read_flag(r) {
		length: u32
		if version {length = latm_get_value(r)} else {
			for {
				more := read_flag(r)
				value := read_bits(r, 8)
				if r.err != .None do return {}, r.err
				if length > max(u32) >> 8 do return {}, .Invalid_Data
				length = length << 8 | value
				if !more do break
			}
		}
		if u64(length) > u64(len(r.data)) * 8 do return {}, .Truncated
		state.other_data_bits = int(length)
	}
	crc_end := r.pos
	if read_flag(r) {
		expected := u8(read_bits(r, 8))
		if r.err != .None do return {}, r.err
		actual, e := latm_config_crc(r.data, first, crc_end)
		if e != .None do return {}, e
		if actual != expected do return {}, .Crc_Mismatch
	}
	if r.err != .None do return {}, r.err
	state.initialized = true
	return state, .None
}

// One AAC-LC program/layer, common-time complete access units; version0 or1,
// variable or fixed byte lengths. The reader first validates every boundary
// and capacity, then copies unaligned payload bytes into caller scratch and
// publishes the new mux state. On failure both scratch and state are untouched.
parse_latm :: proc(
	state: ^LATM_State,
	data: []u8,
	scratch: []u8,
) -> (
	frame: LATM_Frame,
	err: Error,
) {
	if state == nil do return {}, .Invalid_Config
	if len(data) == 0 do return {}, .Truncated
	if len(data) > 8191 do return {}, .Invalid_Data
	r := Bit_Reader {
		data = data,
	}
	next := state^
	if read_flag(&r) {
		if !next.initialized do return {}, .Invalid_State
		if e := validate_config(next.config); e != .None do return {}, e
		if next.num_subframes < 0 ||
		   next.num_subframes > 63 ||
		   next.other_data_bits < 0 ||
		   (next.frame_length_type != 0 && next.frame_length_type != 1) ||
		   (next.frame_length_type == 1 &&
				   (next.fixed_frame_bits < 160 ||
						   next.fixed_frame_bits > 4248 ||
						   next.fixed_frame_bits & 7 != 0)) {return {}, .Invalid_Config}
	} else {
		e: Error
		next, e = read_stream_mux_config(&r)
		if e != .None do return {}, e
	}
	starts, lengths: [64]int
	total := 0
	for i in 0 ..= next.num_subframes {
		bytes := next.fixed_frame_bits / 8
		if next.frame_length_type == 0 {
			bytes = 0
			for {
				v := int(read_bits(&r, 8))
				if r.err != .None do return {}, r.err
				if bytes > 8191 - v do return {}, .Invalid_Data
				bytes += v
				if v != 255 do break
			}
		}
		if bytes == 0 do return {}, .Invalid_Data
		if bytes > (len(data) * 8 - r.pos) / 8 do return {}, .Truncated
		starts[i], lengths[i] = r.pos, bytes
		total += bytes
		skip_bits(&r, 8 * bytes)
	}
	skip_bits(&r, next.other_data_bits)
	align_reader(&r)
	if r.err != .None do return {}, r.err
	if r.pos != len(data) * 8 do return {}, .Invalid_Data
	if len(scratch) < total do return {}, .Output_Too_Small
	// The borrowed input and caller output must be separate: otherwise an
	// early copy could corrupt a later unaligned access unit.
	if total > 0 {
		a, b := uintptr(raw_data(data)), uintptr(raw_data(scratch))
		if (a <= b && b - a < uintptr(len(data))) || (b < a && a - b < uintptr(total)) do return {}, .Invalid_Config
	}
	frame.config, frame.access_unit_count = next.config, next.num_subframes + 1
	offset := 0
	for i in 0 ..< frame.access_unit_count {
		r.pos, r.err = starts[i], .None
		for j in 0 ..< lengths[i] do scratch[offset + j] = u8(read_bits(&r, 8))
		frame.access_units[i] = scratch[offset:offset + lengths[i]]
		offset += lengths[i]
	}
	state^ = next
	return frame, .None
}

parse_loas :: proc(
	state: ^LATM_State,
	data: []u8,
	scratch: []u8,
) -> (
	frame: LATM_Frame,
	consumed: int,
	err: Error,
) {
	if len(data) < 3 do return {}, 0, .Truncated
	if data[0] != 0x56 || data[1] & 0xe0 != 0xe0 do return {}, 0, .Invalid_Data
	n := int(data[1] & 31) << 8 | int(data[2])
	if n == 0 do return {}, 0, .Invalid_Data
	if n > len(data) - 3 do return {}, 0, .Truncated
	frame, err = parse_latm(state, data[3:3 + n], scratch)
	if err != .None do return {}, 0, err
	return frame, n + 3, .None
}

append_loas :: proc(
	out: ^[dynamic]u8,
	config: Config,
	payload: []u8,
	use_same_stream_mux := false,
) -> Error {
	blocks := [1][]u8{payload}
	return append_loas_blocks(out, config, blocks[:], use_same_stream_mux)
}

// A reused StreamMuxConfig must have the same config and access-unit count
// as the preceding emitted frame. The caller owns that stream relationship.
append_loas_blocks :: proc(
	out: ^[dynamic]u8,
	config: Config,
	payloads: [][]u8,
	use_same_stream_mux := false,
	crc := false,
) -> Error {
	if e := validate_config(config); e != .None do return e
	if len(payloads) < 1 || len(payloads) > 64 do return .Invalid_Config
	bytes, length_bytes := 0, 0
	for payload in payloads {
		if len(payload) == 0 || len(payload) > 8191 - bytes do return .Invalid_Data
		bytes += len(payload); length_bytes += 1 + len(payload) / 255
	}
	if e := reserve_bytes(out, bytes + length_bytes + 324); e != .None do return e
	start := len(out)
	append(out, 0, 0, 0)
	w := common.Bit_Writer {
		buf = out,
	}
	common.write_bits(&w, use_same_stream_mux ? 1 : 0, 1)
	if !use_same_stream_mux {
		first := common.bits_written(&w)
		common.write_bits(&w, 0, 1) // audioMuxVersion
		common.write_bits(&w, 1, 1) // allStreamsSameTimeFraming
		common.write_bits(&w, u32(len(payloads) - 1), 6)
		common.write_bits(&w, 0, 7) // numProgram, numLayer
		if e := write_audio_specific_config(&w, config); e != .None {resize(out, start); return e}
		common.write_bits(&w, 0, 3); common.write_bits(&w, 255, 8) // type0/fullness
		common.write_bits(&w, 0, 1) // otherDataPresent
		last := common.bits_written(&w)
		common.write_bits(&w, crc ? 1 : 0, 1)
		if crc {
			// Flush a snapshot of pending bits for the CRC, preserving writer
			// state and excluding the just-written crcCheckPresent bit.
			whole_bytes := len(out)
			pending := w
			common.write_align_zero(&pending)
			checksum, e := latm_config_crc(out^[:], first, last)
			resize(out, whole_bytes)
			if e != .None {resize(out, start); return e}
			common.write_bits(&w, u32(checksum), 8)
		}
	}
	for payload in payloads {
		remaining := len(payload)
		for remaining >= 255 {common.write_bits(&w, 255, 8); remaining -= 255}
		common.write_bits(&w, u32(remaining), 8)
		for b in payload do common.write_bits(&w, u32(b), 8)
	}
	common.write_align_zero(&w)
	n := len(out) - start - 3
	if n > 8191 {resize(out, start); return .Invalid_Data}
	out[start], out[start + 1], out[start + 2] = 0x56, u8(0xe0 | n >> 8), u8(n)
	return .None
}

package aac

import "core:testing"

@(private)
Transport_Bits :: struct {
	data: [8192]u8,
	pos:  int,
}
@(private)
transport_test_bits :: proc(b: ^Transport_Bits, value: u32, count: int) {
	for bit := count - 1; bit >= 0; bit -= 1 {
		if value >> uint(bit) & 1 != 0 do b.data[b.pos / 8] |= 1 << uint(7 - b.pos % 8)
		b.pos += 1
	}
}
@(private)
transport_test_crc8 :: proc(data: []u8, first, end: int) -> u8 {
	remainder: u32
	for i in first ..< end {
		if data[i / 8] >> uint(7 - i % 8) & 1 != 0 do remainder ~= 128
		remainder *= 2
		if remainder & 256 != 0 do remainder ~= 0x107
	}
	return u8(remainder) ~ 0xff
}

@(test)
transport_loas_payload_boundaries_and_state :: proc(t: ^testing.T) {
	data: [600]u8
	for &b, i in data do b = u8(i * 23 + 7)
	for channels in ([3]int{1, 7, 8}) do for samples in ([2]int{1024, 960}) do for count in ([3]int{1, 2, 64}) do for protected in ([2]bool{false, true}) {
		payloads: [64][]u8
		for &payload, i in payloads[:count] do payload = data[:count == 64 ? 1 : (i == 0 ? 255 : 511)]
		c := Config {
			sample_rate   = 7350,
			channels      = channels,
			frame_samples = samples,
		}
		buf: [dynamic]u8
		defer delete(buf)
		testing.expect_value(t, append_loas_blocks(&buf, c, payloads[:count], false, protected), Error.None)
		state: LATM_State
		scratch: [8191]u8
		frame, consumed, err := parse_loas(&state, buf[:], scratch[:])
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, consumed, len(buf))
		testing.expect_value(t, frame.access_unit_count, count)
		testing.expect_value(t, frame.config.channels, channels)
		testing.expect_value(t, resolved_frame_samples(frame.config), samples)
		for payload, i in payloads[:count] do testing.expect(t, transport_test_bytes_equal(payload, frame.access_units[i]))
		committed := state
		for n in 0 ..< len(buf) {
			guarded := [8191]u8{}
			for &b in guarded do b = 0x5a
			trial := committed
			_, _, e := parse_loas(&trial, buf[:n], guarded[:])
			testing.expect(t, e != .None)
			testing.expect_value(t, trial, committed)
			for v in guarded do testing.expect_value(t, v, u8(0x5a))
		}
		guarded: [8191]u8
		for &v in guarded do v = 0x67
		trial := committed
		_, _, e := parse_loas(&trial, buf[:], guarded[:0])
		testing.expect_value(t, e, Error.Output_Too_Small)
		testing.expect_value(t, trial, committed)
		for v in guarded do testing.expect_value(t, v, u8(0x67))
		clear(&buf)
		testing.expect_value(t, append_loas_blocks(&buf, c, payloads[:count], true), Error.None)
		frame, consumed, err = parse_loas(&state, buf[:], scratch[:])
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, state, committed)
		for payload, i in payloads[:count] do testing.expect(t, transport_test_bytes_equal(payload, frame.access_units[i]))
		uninitialized: LATM_State
		_, _, e = parse_loas(&uninitialized, buf[:], scratch[:])
		testing.expect_value(t, e, Error.Invalid_State)
	}
}

@(test)
transport_latm_independent_version_and_crc_fixtures :: proc(t: ^testing.T) {
	// Build the normative field sequence without the transport writer. Pin
	// version1 ASC length, fixed frame semantics, nonbyte CRC, otherData and
	// payload extraction from every resulting unaligned start.
	for version in ([2]bool{false, true}) do for fixed in ([2]bool{false, true}) do for other in ([2]bool{false, true}) {
		b: Transport_Bits
		put := transport_test_bits
		put(&b, 0, 1) // useSameStreamMux
		first := b.pos
		put(&b, version ? 1 : 0, 1)
		if version {put(&b, 0, 1); put(&b, 0, 2); put(&b, 255, 8)} 	// versionA0,taraValue
		put(&b, 1, 1); put(&b, 0, 6); put(&b, 0, 4); put(&b, 0, 3)
		if version {put(&b, 0, 2); put(&b, 16, 8)}
		put(&b, 0x1210, 16) // AAC-LC44100 stereo1024
		put(&b, fixed ? 1 : 0, 3)
		if fixed {put(&b, 0, 9)} else {put(&b, 255, 8)} 	// fixed length=8*(0+20)
		put(&b, other ? 1 : 0, 1)
		if other {
			if version {put(&b, 0, 2); put(&b, 5, 8)} else {put(&b, 0, 1); put(&b, 5, 8)}
		}
		last := b.pos
		put(&b, 1, 1)
		checksum_bit := b.pos
		put(&b, u32(transport_test_crc8(b.data[:], first, last)), 8)
		if !fixed do put(&b, 20, 8)
		for i in 0 ..< 20 do put(&b, u32(i * 7 + 3), 8)
		if other do put(&b, 0x1b, 5)
		put(&b, 0, -b.pos & 7)
		state: LATM_State
		scratch: [32]u8
		frame, err := parse_latm(&state, b.data[:b.pos / 8], scratch[:])
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, frame.access_unit_count, 1)
		testing.expect_value(t, len(frame.access_units[0]), 20)
		for v, i in frame.access_units[0] do testing.expect_value(t, v, u8(i * 7 + 3))
		testing.expect_value(t, state.frame_length_type, fixed ? 1 : 0)
		testing.expect_value(t, state.other_data_bits, other ? 5 : 0)
		before := state
		b.data[checksum_bit / 8] ~= 1 << uint(7 - checksum_bit % 8)
		_, err = parse_latm(&state, b.data[:b.pos / 8], scratch[:])
		testing.expect_value(t, err, Error.Crc_Mismatch)
		testing.expect_value(t, state, before)
	}
}

@(test)
transport_latm_malformed_admission_and_capacity :: proc(t: ^testing.T) {
	scratch: [32]u8
	for marker in ([2]u32{0, 1}) {
		b: Transport_Bits
		transport_test_bits(&b, 0, 1)
		transport_test_bits(&b, 0, 1)
		transport_test_bits(&b, marker, 1) // allStreamsSameTimeFraming
		transport_test_bits(&b, 0, 6)
		transport_test_bits(&b, 1, 4) // two programs
		transport_test_bits(&b, 0, 3)
		transport_test_bits(&b, 0, -b.pos & 7)
		state: LATM_State
		_, err := parse_latm(&state, b.data[:b.pos / 8], scratch[:])
		testing.expect_value(t, err, Error.Unsupported_Transport)
		testing.expect(t, !state.initialized)
	}
	state: LATM_State
	empty := [3]u8{0x56, 0xe0, 0}
	_, _, e := parse_loas(&state, empty[:], scratch[:])
	testing.expect_value(t, e, Error.Invalid_Data)
	bad_sync := [4]u8{0x55, 0xe0, 1, 0}
	_, _, e = parse_loas(&state, bad_sync[:], scratch[:])
	testing.expect_value(t, e, Error.Invalid_Data)
	buf: [dynamic]u8
	defer delete(buf)
	payload := [1]u8{0xe0}
	testing.expect_value(
		t,
		append_loas(&buf, {sample_rate = 48000, channels = 1}, payload[:]),
		Error.None,
	)
	before := state
	// The payload destination overlaps LATM input (not just the already
	// consumed three-byte LOAS header), so publication must refuse it.
	_, _, e = parse_loas(&state, buf[:], buf[3:])
	testing.expect_value(t, e, Error.Invalid_Config)
	testing.expect_value(t, state, before)
	// Length escape255 without its terminating byte cannot consume payload.
	truncated := [2]u8{0xff, 0x80}
	known := LATM_State {
		initialized = true,
		config = {sample_rate = 48000, channels = 1},
	}
	_, e2 := parse_latm(&known, truncated[:], scratch[:])
	testing.expect(t, e2 != .None)
}

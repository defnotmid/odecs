package vp9_decoder

import "core:testing"

@(test)
malformed_headers_fail_cleanly :: proc(t: ^testing.T) {
	d: Decoder
	init_decoder(&d)
	defer destroy_decoder(&d)
	_, _, err := decode_packet(&d, nil)
	testing.expect_value(t, err, Error.Invalid_Data)
	// Frame marker 0b00 instead of 0b10.
	_, _, err = decode_packet(&d, {0x00, 0x00})
	testing.expect_value(t, err, Error.Invalid_Data)
	// A key frame whose sync code is wrong, and one cut short.
	key := [?]u8{0x82, 0x49, 0x83, 0x43, 0x00, 0x00, 0x00, 0x00}
	_, _, err = decode_packet(&d, key[:])
	testing.expect(t, err != .None)
	for n in 1 ..< len(key) {
		_, _, err = decode_packet(&d, key[:n])
		testing.expect(t, err != .None)
	}
	// An inter frame before any reference exists.
	_, _, err = decode_packet(&d, {0x86, 0x00, 0x00, 0x00})
	testing.expect(t, err != .None)
}

@(test)
superframe_index_bounds :: proc(t: ^testing.T) {
	d: Decoder
	init_decoder(&d)
	defer destroy_decoder(&d)
	// Two frames of 1-byte sizes claiming more bytes than the packet has.
	packet := [?]u8{0x00, 0xC1, 0x40, 0x40, 0xC1}
	_, _, err := decode_packet(&d, packet[:])
	testing.expect_value(t, err, Error.Invalid_Data)
}

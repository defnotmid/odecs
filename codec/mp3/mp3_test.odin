package mp3

import "core:testing"

@(test)
headers :: proc(t: ^testing.T) {
	Case :: struct {
		bytes:                         [4]u8,
		version:                       Version,
		rate, bitrate, channels, size: int,
		samples:                       int,
	}
	cases := [?]Case {
		{{0xFF, 0xFB, 0x90, 0x44}, .MPEG1, 44100, 128, 2, 417, 1152}, // the common case
		{{0xFF, 0xFB, 0x92, 0xC4}, .MPEG1, 44100, 128, 1, 418, 1152}, // padded, mono
		{{0xFF, 0xFB, 0xE4, 0x00}, .MPEG1, 48000, 320, 2, 960, 1152},
		{{0xFF, 0xF3, 0x80, 0xC4}, .MPEG2, 22050, 64, 1, 208, 576},
		{{0xFF, 0xF3, 0x88, 0xC4}, .MPEG2, 16000, 64, 1, 288, 576},
		{{0xFF, 0xE3, 0x18, 0xC4}, .MPEG25, 8000, 8, 1, 72, 576},
	}
	for c in cases {
		b := c.bytes
		h, e := parse_header(b[:])
		testing.expect_value(t, e, Error.None)
		testing.expect_value(t, h.version, c.version)
		testing.expect_value(t, h.sample_rate, c.rate)
		testing.expect_value(t, h.bitrate, c.bitrate)
		testing.expect_value(t, h.channels, c.channels)
		testing.expect_value(t, h.frame_bytes, c.size)
		testing.expect_value(t, h.samples, c.samples)
	}
	refused := [?][4]u8 {
		{0xFF, 0xFD, 0x90, 0x44}, // Layer II
		{0xFF, 0xFB, 0x00, 0x44}, // free format
	}
	for r in refused {
		b := r
		_, e := parse_header(b[:])
		testing.expect_value(t, e, Error.Unsupported)
	}
	invalid := [?][4]u8 {
		{0xFF, 0xEB, 0x90, 0x44}, // reserved version
		{0xFF, 0xFB, 0xF0, 0x44}, // bitrate index 15
		{0xFF, 0xFB, 0x9C, 0x44}, // rate index 3
		{0xFE, 0xFB, 0x90, 0x44}, // no sync
	}
	for r in invalid {
		b := r
		_, e := parse_header(b[:])
		testing.expect_value(t, e, Error.Invalid_Data)
	}
}

// A frame whose side information and main data are all zero: no
// scalefactors, no big values, no count1 bits. It decodes completely, to
// silence.
@(private = "file")
silent_frame :: proc(bytes: [4]u8) -> [dynamic]u8 {
	header := bytes
	h, _ := parse_header(header[:])
	frame := make([dynamic]u8, h.frame_bytes)
	copy(frame[:], header[:])
	return frame
}

@(test)
silent_frames_decode :: proc(t: ^testing.T) {
	for header in ([?][4]u8{{0xFF, 0xFB, 0x90, 0x44}, {0xFF, 0xF3, 0x88, 0xC4}, {0xFF, 0xE3, 0x18, 0xC4}}) {
		frame := silent_frame(header)
		defer delete(frame)
		d := new(Decoder)
		defer free(d)
		for _ in 0 ..< 3 {
			f, e := decode_frame(d, frame[:])
			testing.expect_value(t, e, Error.None)
			testing.expect(t, f.complete)
			for c in 0 ..< f.header.channels do for x in f.pcm[c] do testing.expect_value(t, x, 0)
		}
	}
}

// Every truncation fails cleanly, and every one-bit change decodes or fails
// without touching memory outside the frame (checked by the bounds checks
// and, in the fuzz gate, AddressSanitizer).
@(test)
corruption_is_contained :: proc(t: ^testing.T) {
	frame := silent_frame({0xFF, 0xFB, 0x90, 0x44})
	defer delete(frame)
	for i in 4 ..< len(frame) do frame[i] = u8(i * 37)
	d := new(Decoder)
	defer free(d)
	for n in 0 ..< len(frame) {
		_, e := decode_frame(d, frame[:n])
		testing.expect(t, e != .None)
	}
	for i in 32 ..< 64 * 8 {
		frame[i / 8] ~= 1 << uint(i % 8)
		decode_frame(d, frame[:])
		frame[i / 8] ~= 1 << uint(i % 8)
	}
}

@(test)
info_tag :: proc(t: ^testing.T) {
	frame := silent_frame({0xFF, 0xFB, 0x90, 0x64}) // MPEG-1 joint stereo: tag after 32 bytes of side info
	defer delete(frame)
	at := 4 + 32
	copy(frame[at:], "Info")
	frame[at + 7] = 1 | 2 // frames, bytes
	frame[at + 11] = 200 // 200 frames
	frame[at + 15] = 100
	lame := at + 16
	copy(frame[lame:], "LAME3.100")
	// Encoder delay 576, padding 1000: 0x240 and 0x3E8 as 12-bit fields.
	frame[lame + 21], frame[lame + 22], frame[lame + 23] = 0x24, 0x03, 0xE8
	h, _ := parse_header(frame[:])
	tag, ok := parse_info_tag(frame[:], h)
	testing.expect(t, ok)
	testing.expect_value(t, tag.frames, 200)
	testing.expect_value(t, tag.delay, 576 + DECODER_DELAY)
	testing.expect_value(t, tag.padding, 1000 - DECODER_DELAY)
}

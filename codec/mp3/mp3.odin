// MPEG-1, MPEG-2 and MPEG-2.5 Audio Layer III ("MP3"): frame headers, the
// Xing/Info/LAME tag that carries a stream's length and gapless trimming,
// and the bit reader shared by the decoder (decoder.odin) and the file
// reader (reader.odin). Depends only on Odin core.
package mp3

Error :: enum {
	None,
	Invalid_Argument,
	Invalid_Data,  // malformed
	Unsupported,   // valid, outside the implemented scope (Layers I and II, free format)
	IO_Error,
	Out_Of_Memory,
	End_Of_Stream,
	Closed,
}

Version :: enum u8 {
	MPEG25,
	Reserved,
	MPEG2,
	MPEG1,
}

Mode :: enum u8 {
	Stereo,
	Joint_Stereo,
	Dual_Channel,
	Mono,
}

Header :: struct {
	version:        Version,
	layer:          int, // 1..3
	crc:            bool,
	bitrate:        int, // kbps
	sample_rate:    int,
	rate_index:     int, // 0..8: MPEG-2.5, MPEG-2, MPEG-1, three rates each
	mode:           Mode,
	mode_extension: u8, // joint stereo: bit 1 mid/side, bit 0 intensity
	channels:       int,
	frame_bytes:    int, // the whole frame, header and padding included
	samples:        int, // per channel: 1152, or 576 for MPEG-2 and 2.5
}

@(private, rodata)
BITRATES := [2][15]u16 {
	{0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160}, // MPEG-2 and 2.5
	{0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320}, // MPEG-1
}
@(private, rodata)
SAMPLE_RATES := [3]int{44100, 48000, 32000}

// Parses the 4-byte frame header at the start of b. Only Layer III frames
// with a stated bitrate are accepted; other layers and free format return
// Unsupported, anything else that is not a header Invalid_Data.
parse_header :: proc(b: []u8) -> (h: Header, err: Error) {
	if len(b) < 4 || b[0] != 0xFF || b[1] & 0xE0 != 0xE0 do return h, .Invalid_Data
	h.version = Version(b[1] >> 3 & 3)
	layer_code := b[1] >> 1 & 3
	bitrate_index, rate_code := int(b[2] >> 4), int(b[2] >> 2 & 3)
	if h.version == .Reserved || layer_code == 0 || bitrate_index == 15 || rate_code == 3 do return h, .Invalid_Data
	h.layer = 4 - int(layer_code)
	if h.layer != 3 || bitrate_index == 0 do return h, .Unsupported
	mpeg1 := h.version == .MPEG1
	h.crc = b[1] & 1 == 0
	h.bitrate = int(BITRATES[1 if mpeg1 else 0][bitrate_index])
	h.sample_rate = SAMPLE_RATES[rate_code] / (mpeg1 ? 1 : h.version == .MPEG2 ? 2 : 4)
	h.rate_index = rate_code + 3 * (mpeg1 ? 2 : h.version == .MPEG2 ? 1 : 0)
	h.mode = Mode(b[3] >> 6)
	h.mode_extension = b[3] >> 4 & 3
	h.channels = h.mode == .Mono ? 1 : 2
	h.samples = mpeg1 ? 1152 : 576
	h.frame_bytes = (mpeg1 ? 144000 : 72000) * h.bitrate / h.sample_rate + int(b[2] >> 1 & 1)
	return h, .None
}

// Bytes of side information after the header (and its CRC).
side_info_bytes :: proc(h: Header) -> int {
	if h.version == .MPEG1 do return h.channels == 1 ? 17 : 32
	return h.channels == 1 ? 9 : 17
}

// A Xing/Info tag in a stream's first frame: the frame is metadata, not
// audio. With a LAME (or compatible) extension it also states the encoder
// delay and padding; with the decoder's own 529-sample delay these give the
// samples to trim from the start and end for gapless playback.
Info_Tag :: struct {
	frames:  int, // audio frames after the tag frame; 0 when not stated
	bytes:   int,
	toc:     [100]u8,
	has_toc: bool,
	delay:   int, // samples to drop at the start (0 without a LAME extension)
	padding: int, // samples to drop at the end
}

// The decoder's delay that the LAME convention adds to the encoder delay.
DECODER_DELAY :: 529

parse_info_tag :: proc(frame: []u8, h: Header) -> (tag: Info_Tag, ok: bool) {
	at := 4 + (h.crc ? 2 : 0) + side_info_bytes(h)
	if at + 8 > len(frame) do return
	id := string(frame[at:][:4])
	if id != "Xing" && id != "Info" do return
	flags := frame[at + 7]
	at += 8
	be32 :: proc(b: []u8) -> int {return int(b[0]) << 24 | int(b[1]) << 16 | int(b[2]) << 8 | int(b[3])}
	if flags & 1 != 0 {
		if at + 4 > len(frame) do return
		tag.frames = be32(frame[at:])
		at += 4
	}
	if flags & 2 != 0 {
		if at + 4 > len(frame) do return
		tag.bytes = be32(frame[at:])
		at += 4
	}
	if flags & 4 != 0 {
		if at + 100 > len(frame) do return
		copy(tag.toc[:], frame[at:][:100])
		tag.has_toc = true
		at += 100
	}
	if flags & 8 != 0 do at += 4
	ok = true
	// The LAME extension: 9-byte encoder version, then (at offset 21) the
	// 12-bit encoder delay and 12-bit padding.
	if at + 24 <= len(frame) && frame[at] != 0 {
		d := frame[at + 21:]
		encoder_delay := int(d[0]) << 4 | int(d[1]) >> 4
		encoder_padding := int(d[1] & 15) << 8 | int(d[2])
		tag.delay = encoder_delay + DECODER_DELAY
		tag.padding = max(encoder_padding - DECODER_DELAY, 0)
	}
	return
}

// ---- Bit reader -------------------------------------------------------------

// MSB-first reads within [pos, limit) bits; reads past the limit return 0
// and leave pos past it, which callers check.
@(private)
Bits :: struct {
	data:       []u8,
	pos, limit: int,
}

@(private)
get_bits :: proc(b: ^Bits, n: int) -> u32 {
	if n == 0 do return 0
	start := b.pos
	b.pos += n
	if b.pos > b.limit do return 0
	v: u32
	for k in 0 ..< n {
		bit := start + k
		v = v << 1 | u32(b.data[bit >> 3] >> uint(7 - bit & 7) & 1)
	}
	return v
}

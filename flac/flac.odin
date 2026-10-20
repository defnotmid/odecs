// FLAC (RFC 9639): stream metadata, frame headers, CRCs and the bit reader
// shared by the decoder (decoder.odin) and the native-file reader
// (reader.odin). Depends only on Odin core and common.
package flac

import "base:intrinsics"
import common "../common"

Error :: enum {
	None,
	Invalid_Argument,
	Invalid_Data,  // malformed, forbidden pattern, or a CRC that does not match
	Unsupported,   // valid, outside the implemented scope
	IO_Error,
	Out_Of_Memory,
	End_Of_Stream,
	Closed,
}

MAX_CHANNELS :: 8
MAX_BLOCK :: 65535

// The streaminfo metadata block (section 8.2).
Stream_Info :: struct {
	min_block, max_block: int,
	min_frame, max_frame: int, // bytes; 0 when unknown
	sample_rate:          int,
	channels:             int,
	bits:                 int, // 4..32
	total_samples:        i64, // interchannel samples; 0 when unknown
	md5:                  [16]u8,
}

// A seek table entry (section 8.5.1); placeholders are dropped.
Seek_Point :: struct {
	sample: i64,
	offset: i64, // from the first frame header
	count:  int,
}

Channel_Assignment :: enum u8 {
	Independent,
	Left_Side,
	Side_Right,
	Mid_Side,
}

Frame_Header :: struct {
	block_size:  int,
	sample_rate: int, // from streaminfo when the header refers to it
	channels:    int,
	assignment:  Channel_Assignment,
	bits:        int, // from streaminfo when the header refers to it
	variable:    bool, // blocking strategy: number is a sample number
	number:      i64, // frame number (fixed blocking) or first sample (variable)
	size:        int, // header bytes, CRC-8 included
}

// The first sample of a frame. Fixed-blocking streams number frames, and
// every frame but the last has the stream's block size.
first_sample :: proc(h: Frame_Header, info: Stream_Info) -> i64 {
	if h.variable do return h.number
	block := info.min_block == info.max_block && info.max_block > 0 ? info.max_block : h.block_size
	return h.number * i64(block)
}

// Streaminfo and the seek table from FLAC metadata: either the bytes after
// the fLaC marker (a native file, Matroska CodecPrivate, MP4 dfLa) with or
// without the marker, or a bare 34-byte streaminfo. `audio` is where the
// frames start. The seek table is allocated only when asked for.
parse_metadata :: proc(data: []u8, seek_table: ^#soa[dynamic]Seek_Point = nil) -> (info: Stream_Info, audio: int, err: Error) {
	if len(data) == 34 do return parse_stream_info(data)
	at := len(data) >= 4 && string(data[:4]) == "fLaC" ? 4 : 0
	have_info := false
	for {
		if at + 4 > len(data) do return info, at, .Invalid_Data
		last := data[at] & 0x80 != 0
		kind := data[at] & 0x7F
		size := int(data[at + 1]) << 16 | int(data[at + 2]) << 8 | int(data[at + 3])
		at += 4
		if kind == 127 || size > len(data) - at do return info, at, .Invalid_Data
		body := data[at:][:size]
		switch kind {
		case 0:
			if have_info || size < 34 do return info, at, .Invalid_Data
			info, _ = parse_stream_info(body[:34]) or_return
			have_info = true
		case 3:
			if seek_table == nil do break
			for k := 0; k + 18 <= size; k += 18 {
				p := body[k:]
				sample := be(p[:8])
				if sample == max(u64) do continue
				if sample > 1 << 62 || be(p[8:16]) > 1 << 62 do return info, at, .Invalid_Data
				append(seek_table, Seek_Point{i64(sample), i64(be(p[8:16])), int(be(p[16:18]))})
			}
		}
		if !have_info do return info, at, .Invalid_Data // streaminfo comes first
		at += size
		if last do return info, at, .None
	}
}

@(private)
parse_stream_info :: proc(b: []u8) -> (info: Stream_Info, audio: int, err: Error) {
	info = {
		min_block     = int(be(b[0:2])),
		max_block     = int(be(b[2:4])),
		min_frame     = int(be(b[4:7])),
		max_frame     = int(be(b[7:10])),
		sample_rate   = int(be(b[10:13]) >> 4),
		channels      = int(b[12] >> 1 & 7) + 1,
		bits          = int(be(b[12:14]) >> 4 & 31) + 1,
		total_samples = i64(be(b[13:18]) & (1 << 36 - 1)),
	}
	copy(info.md5[:], b[18:34])
	if info.min_block < 16 || info.max_block < info.min_block || info.bits < 4 do return info, 0, .Invalid_Data
	return info, 34, .None
}

// Big-endian unsigned value of up to 8 bytes.
@(private)
be :: proc(b: []u8) -> (v: u64) {
	for x in b do v = v << 8 | u64(x)
	return
}

@(private, rodata)
BLOCK_SIZES := [16]int{0, 192, 576, 1152, 2304, 4608, -1, -2, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768}
@(private, rodata)
SAMPLE_RATES := [12]int{0, 88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000}
@(private, rodata)
BIT_DEPTHS := [8]int{0, 8, 12, -1, 16, 20, 24, 32}

// Parses and checks the frame header at the start of data (section 9.1),
// filling fields the header defers to streaminfo from `info`.
parse_frame_header :: proc(data: []u8, info: Stream_Info) -> (h: Frame_Header, err: Error) {
	if len(data) < 6 || data[0] != 0xFF || data[1] & 0xFE != 0xF8 do return h, .Invalid_Data
	h.variable = data[1] & 1 != 0
	block_code, rate_code := int(data[2] >> 4), int(data[2] & 15)
	channel_code, depth_code := int(data[3] >> 4), int(data[3] >> 1 & 7)
	if block_code == 0 || rate_code == 15 || channel_code > 10 || depth_code == 3 || data[3] & 1 != 0 do return h, .Invalid_Data
	// The coded number: UTF-8's layout extended to 7 bytes / 36 bits.
	at := 4
	lead := data[at]
	ones := int(intrinsics.count_leading_zeros(~lead)) // 0: one byte; 2..7: that many bytes
	if ones == 1 || ones == 8 do return h, .Invalid_Data
	extra := max(ones - 1, 0)
	if at + 1 + extra >= len(data) do return h, .Invalid_Data
	number := u64(ones == 0 ? lead : lead & (0xFF >> uint(ones + 1)))
	for k in 1 ..= extra {
		c := data[at + k]
		if c & 0xC0 != 0x80 do return h, .Invalid_Data
		number = number << 6 | u64(c & 0x3F)
	}
	if !h.variable && number >= 1 << 31 do return h, .Invalid_Data
	h.number = i64(number)
	at += 1 + extra
	h.block_size = BLOCK_SIZES[block_code]
	if h.block_size < 0 {
		n := h.block_size == -1 ? 1 : 2
		if at + n >= len(data) do return h, .Invalid_Data
		h.block_size = int(be(data[at:][:n])) + 1
		if h.block_size > MAX_BLOCK do return h, .Invalid_Data
		at += n
	}
	switch rate_code {
	case 0:
		h.sample_rate = info.sample_rate
	case 12, 13, 14:
		n := rate_code == 12 ? 1 : 2
		if at + n >= len(data) do return h, .Invalid_Data
		v := int(be(data[at:][:n]))
		h.sample_rate = rate_code == 12 ? v * 1000 : rate_code == 13 ? v : v * 10
		at += n
	case:
		h.sample_rate = SAMPLE_RATES[rate_code]
	}
	h.bits = depth_code == 0 ? info.bits : BIT_DEPTHS[depth_code]
	if h.bits < 4 || h.bits > 32 do return h, .Invalid_Data
	if channel_code <= 7 {
		h.channels = channel_code + 1
	} else {
		h.channels = 2
		h.assignment = Channel_Assignment(channel_code - 7)
	}
	if at >= len(data) || crc8(data[:at]) != data[at] do return h, .Invalid_Data
	h.size = at + 1
	return h, .None
}

// ---- CRCs (sections 9.1.8 and 9.3): MSB first, initial value 0 ------------

@(private)
crc8_table: [256]u8
// crc16_tables[k][x]: the CRC-16 of byte x followed by k zero bytes, so
// eight bytes fold into the CRC with eight independent lookups.
@(private)
crc16_tables: [8][256]u16

@(private, init)
init_crc_tables :: proc "contextless" () {
	for i in 0 ..< 256 {
		c8 := u8(i)
		for _ in 0 ..< 8 do c8 = c8 << 1 ~ (c8 & 0x80 != 0 ? 0x07 : 0)
		crc8_table[i] = c8
		c16 := u16(i) << 8
		for _ in 0 ..< 8 do c16 = c16 << 1 ~ (c16 & 0x8000 != 0 ? 0x8005 : 0)
		crc16_tables[0][i] = c16
	}
	for k in 1 ..< 8 do for i in 0 ..< 256 {
		prev := crc16_tables[k - 1][i]
		crc16_tables[k][i] = prev << 8 ~ crc16_tables[0][prev >> 8]
	}
}

crc8 :: proc(data: []u8) -> (c: u8) {
	for b in data do c = crc8_table[c ~ b]
	return
}

// CRC-16 continued from `c`. Over a whole frame, footer included, it is 0.
crc16 :: proc(data: []u8, c: u16 = 0) -> u16 #no_bounds_check {
	c := c
	t := &crc16_tables
	data := data
	for len(data) >= 8 {
		c = t[7][u8(c >> 8) ~ data[0]] ~ t[6][u8(c) ~ data[1]] ~ t[5][data[2]] ~ t[4][data[3]] ~ t[3][data[4]] ~ t[2][data[5]] ~ t[1][data[6]] ~ t[0][data[7]]
		data = data[8:]
	}
	for b in data do c = c << 8 ~ t[0][u8(c >> 8) ~ b]
	return c
}

// ---- Bit reader (shared in common) ------------------------------------

Bit_Reader :: common.Bit_Reader
refill :: common.refill_bits
skip :: common.skip_bits
read :: common.read_bits
read_signed :: common.read_signed_bits
read_unary :: common.read_unary
byte_position :: common.byte_position

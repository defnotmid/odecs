package aac

import common "../../common"

FRAME_SAMPLES :: 1024
SAMPLE_RATES := [13]int {
	96000,
	88200,
	64000,
	48000,
	44100,
	32000,
	24000,
	22050,
	16000,
	12000,
	11025,
	8000,
	7350,
}

Config :: struct {
	sample_rate, channels, bit_rate: int,
	frame_samples:                   int, // 0 preserves the 1024-sample default; otherwise 960 or 1024
	use_pce:                         bool,
	program_config:                  Program_Config,
}
resolved_frame_samples :: proc(c: Config) -> int {return(
		c.frame_samples == 0 ? 1024 : c.frame_samples \
	)}
sample_rate_index :: proc(rate: int) -> int {
	for v, i in SAMPLE_RATES do if v == rate do return i
	return -1
}
validate_config :: proc(c: Config) -> Error {
	if sample_rate_index(c.sample_rate) < 0 do return .Invalid_Config
	if c.channels < 1 || c.channels > MAX_CHANNELS do return .Unsupported_Channels
	if n := resolved_frame_samples(c); n != 960 && n != 1024 do return .Invalid_Config
	program := c.program_config
	if c.use_pce && program_config_present(&program) {
		layout, err := program_channel_layout(&program)
		if err != .None do return err
		if layout.channels != c.channels || c.program_config.sample_rate != c.sample_rate do return .Invalid_Config
	}
	return .None
}

@(private)
reserve_bytes :: proc(out: ^[dynamic]u8, extra: int) -> Error {
	if out == nil || extra < 0 || len(out) > max(int) - extra do return .Invalid_Config
	n := len(out) + extra
	if e := reserve(out, n); e != nil do return .Allocation_Failed
	if n > 0 && (raw_data(out^) == nil || cap(out) < n) do return .Allocation_Failed
	return .None
}
@(private)
reserve_writer_bits :: proc(w: ^common.Bit_Writer, bits: int) -> Error {
	if w == nil || w.buf == nil || w.nbits < 0 || w.nbits > 7 || bits < 0 || bits > max(int) - 14 do return .Invalid_Config
	return reserve_bytes(w.buf, (w.nbits + bits + 7) / 8)
}

ADTS_Header :: struct {
	config:                    Config,
	frame_bytes, header_bytes: int,
	channel_configuration:     int,
	mpeg2:                     bool, // ADTS ID: true for MPEG-2, false for MPEG-4.
	protected:                 bool,
	raw_block_count:           int,
	// Protected multi-block positions exclude the per-block trailing CRCs.
	// Unprotected multi-block boundaries are found by decoding ID_END.
	block_offsets, block_ends: [4]int,
	block_crc:                 [4]u16,
	header_crc:                u16,
}
CRC_Range :: struct {
	first, end, padded_bits: int,
}
ADTS_Block :: struct {
	data:       []u8,
	crc_ranges: []CRC_Range,
}

// ISO/IEC 11172-3 2.4.3.1 and 13818-7 6.1.3: MSB-first polynomial
// x^16+x^15+x^2+1, initial register FFFF, no final inversion.
crc16_update_range :: proc(data: []u8, seed: u16, range: CRC_Range) -> (u16, Error) {
	crc := seed
	if range.first < 0 ||
	   range.end < range.first ||
	   range.padded_bits < 0 ||
	   range.end / 8 > len(data) ||
	   (range.end / 8 == len(data) && range.end & 7 != 0) {return crc, .Invalid_Config}
	n := range.end - range.first
	if range.padded_bits > 0 do n = min(n, range.padded_bits)
	for bit in range.first ..< range.first + n {
		value := u16((data[bit >> 3] >> uint(7 - (bit & 7))) & 1)
		feedback := (crc >> 15) ~ value
		crc <<= 1
		if feedback != 0 do crc ~= 0x8005
	}
	for _ in n ..< range.padded_bits {
		feedback := crc >> 15; crc <<= 1
		if feedback != 0 do crc ~= 0x8005
	}
	return crc, .None
}
adts_block_crc_seed :: proc(header: ADTS_Header, frame: []u8, index: int) -> (u16, Error) {
	if !header.protected || header.raw_block_count < 1 || header.raw_block_count > 4 || index < 0 || index >= header.raw_block_count || header.frame_bytes < 7 || header.frame_bytes > len(frame) do return 0, .Invalid_Config
	if header.raw_block_count == 1 do return crc16_update_range(frame, 0xffff, {0, 56, 0})
	return 0xffff, .None
}
validate_adts_block_crc :: proc(header: ADTS_Header, index: int, computed: u16) -> Error {
	if !header.protected || header.raw_block_count < 1 || header.raw_block_count > 4 || index < 0 || index >= header.raw_block_count do return .Invalid_Config
	expected := header.raw_block_count == 1 ? header.header_crc : header.block_crc[index]
	return computed == expected ? .None : .Crc_Mismatch
}

// Validate the whole frame and protected multi-block header before borrowing
// payload. A single-block CRC also needs decoded element ranges; its syntax
// owner feeds those ranges and calls validate_adts_block_crc.
parse_adts :: proc(data: []u8) -> (header: ADTS_Header, payload: []u8, err: Error) {
	if len(data) < 7 do return {}, nil, .Truncated
	if data[0] != 0xff || data[1] & 0xf6 != 0xf0 do return {}, nil, .Invalid_Data
	if data[2] >> 6 != 1 do return {}, nil, .Unsupported_Profile
	header.mpeg2 = data[1] & 8 != 0
	i := int((data[2] >> 2) & 15)
	if i >= len(SAMPLE_RATES) || (header.mpeg2 && i == 12) do return {}, nil, .Invalid_Config
	header.channel_configuration = int(data[2] & 1) * 4 + int(data[3] >> 6)
	header.config = {
		sample_rate = SAMPLE_RATES[i],
		channels    = channels_for_configuration(header.channel_configuration),
		use_pce     = header.channel_configuration == 0,
	}
	header.protected = data[1] & 1 == 0
	header.raw_block_count = 1 + int(data[6] & 3)
	header.frame_bytes = int(data[3] & 3) << 11 | int(data[4]) << 3 | int(data[5] >> 5)
	header.header_bytes = 7
	if header.protected do header.header_bytes += 2 * header.raw_block_count
	if header.frame_bytes <= header.header_bytes do return {}, nil, .Invalid_Data
	if header.frame_bytes > len(data) do return {}, nil, .Truncated
	frame := data[:header.frame_bytes]
	if !header.protected {
		header.block_offsets[0] = 7
		if header.raw_block_count == 1 do header.block_ends[0] = header.frame_bytes
		return header, frame[7:], .None
	}
	crc_index := header.header_bytes - 2
	header.header_crc = u16(frame[crc_index]) << 8 | u16(frame[crc_index + 1])
	if header.raw_block_count == 1 {
		header.block_offsets[0], header.block_ends[0] = 9, header.frame_bytes
		return header, frame[9:], .None
	}
	crc, e := crc16_update_range(frame, 0xffff, {0, crc_index * 8, 0})
	if e != .None do return {}, nil, e
	if crc != header.header_crc do return {}, nil, .Crc_Mismatch
	header.block_offsets[0] = header.header_bytes
	for block in 1 ..< header.raw_block_count {
		pos := 7 + 2 * (block - 1)
		offset := int(frame[pos]) << 8 | int(frame[pos + 1])
		if offset > header.frame_bytes - header.header_bytes do return {}, nil, .Invalid_Data
		header.block_offsets[block] = header.header_bytes + offset
	}
	for block in 0 ..< header.raw_block_count {
		end :=
			block + 1 < header.raw_block_count ? header.block_offsets[block + 1] : header.frame_bytes
		if end - header.block_offsets[block] < 3 do return {}, nil, .Invalid_Data
		header.block_ends[block] = end - 2
		header.block_crc[block] = u16(frame[end - 2]) << 8 | u16(frame[end - 1])
	}
	return header, frame[header.header_bytes:], .None
}

// Resolve initialization metadata without decoding audio syntax. A stream
// with channel_configuration0 must put its PCE first, or the caller must
// already know its program configuration through the enclosing application.
adts_config :: proc(header: ADTS_Header, payload: []u8) -> (config: Config, err: Error) {
	config = header.config
	if header.channel_configuration < 0 || header.channel_configuration > 7 do return {}, .Invalid_Config
	if header.channel_configuration != 0 {
		config.channels = channels_for_configuration(header.channel_configuration)
		return config, validate_config(config)
	}
	r := Bit_Reader {
		data = payload,
	}
	if read_bits(&r, 3) != 5 {
		if r.err != .None do return {}, r.err
		return {}, .Invalid_Config
	}
	p, e := read_program_config_element(&r)
	if e != .None do return {}, e
	if p.sample_rate != config.sample_rate do return {}, .Invalid_Config
	layout, le := program_channel_layout(&p)
	if le != .None do return {}, le
	config.channels, config.use_pce, config.program_config = layout.channels, true, p
	return config, validate_config(config)
}

append_adts :: proc(out: ^[dynamic]u8, config: Config, payload: []u8) -> Error {
	block := [1]ADTS_Block{{data = payload}}
	return append_adts_blocks(out, config, block[:])
}

// CRC ranges are supplied in appearance order by the raw syntax owner.
// Regions start after ID3: first192 padded for SCE/CPE/CCE/LFE, plus second
// ICS128 for CPE; whole PCE/DSE; no FIL/END (13818-7 6.1.3).
append_adts_blocks :: proc(
	out: ^[dynamic]u8,
	config: Config,
	blocks: []ADTS_Block,
	protected := false,
) -> Error {
	if e := validate_config(config); e != .None do return e
	if resolved_frame_samples(config) != 1024 do return .Unsupported_Transport
	if len(blocks) < 1 || len(blocks) > 4 do return .Invalid_Config
	header_bytes := 7 + (protected ? 2 * len(blocks) : 0)
	n := header_bytes
	for block in blocks {
		if len(block.data) == 0 || len(block.data) > 8191 - n do return .Invalid_Data
		n += len(block.data)
		if protected && len(blocks) > 1 do n += 2
		if n > 8191 do return .Invalid_Data
		if protected do for range in block.crc_ranges {
			if _, e := crc16_update_range(block.data, 0xffff, range); e != .None do return e
		}
	}
	i, c := sample_rate_index(config.sample_rate), channel_configuration(config)
	header: [15]u8
	header[0], header[1] = 0xff, protected ? 0xf0 : 0xf1
	header[2] = u8(1 << 6 | i << 2 | c >> 2)
	header[3], header[4] = u8((c & 3) << 6 | n >> 11), u8(n >> 3)
	header[5], header[6] = u8((n & 7) << 5 | 0x1f), u8(0xfc | len(blocks) - 1)
	if protected && len(blocks) > 1 {
		pos := 0
		for block, index in blocks[:len(blocks) - 1] {
			pos += len(block.data) + 2
			header[7 + 2 * index], header[8 + 2 * index] = u8(pos >> 8), u8(pos)
		}
	}
	header_crc: u16
	if protected {
		header_crc, _ = crc16_update_range(
			header[:header_bytes - 2],
			0xffff,
			{0, (header_bytes - 2) * 8, 0},
		)
		if len(blocks) == 1 do for range in blocks[0].crc_ranges do header_crc, _ = crc16_update_range(blocks[0].data, header_crc, range)
		header[header_bytes - 2], header[header_bytes - 1] = u8(header_crc >> 8), u8(header_crc)
	}
	if e := reserve_bytes(out, n); e != .None do return e
	append(out, ..header[:header_bytes])
	for block in blocks {
		append(out, ..block.data)
		if protected && len(blocks) > 1 {
			crc: u16 = 0xffff
			for range in block.crc_ranges do crc, _ = crc16_update_range(block.data, crc, range)
			append(out, u8(crc >> 8), u8(crc))
		}
	}
	return .None
}

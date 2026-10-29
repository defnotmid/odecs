package h264_decoder

import h264 ".."

import "base:intrinsics"

// ---------------------------------------------------------------------------
// CAVLC residual block parsing (9.2)
// ---------------------------------------------------------------------------

// A variable-length code of at most 16 bits and the value it stands for.
@(private = "file")
Short_Code :: struct {
	code, length: u8,
	value:        u8,
}

// Codes of a prefix-free table matched against the next 16 bits.
@(private = "file")
read_short_code :: proc(reader: ^h264.Bit_Reader, codes: []Short_Code) -> (value: u8, ok: bool) #no_bounds_check {
	next := h264.peek_bits(reader, 16)
	for c in codes {
		if next >> (16 - u32(c.length)) == u32(c.code) {
			h264.skip_bits(reader, uint(c.length))
			return c.value, true
		}
	}
	return 0, false
}

// coeff_token for the 4:2:2 chroma DC (Table 9-5, nC == -2), as
// trailing_ones << 4 | total_coeff. Codes longer than 8 bits start with
// zeros, so their values fit a byte.
@(private = "file", rodata)
coeff_token_chroma_dc_422 := [?]Short_Code {
	{0b1, 1, 0x00},
	{0b01, 2, 0x11},
	{0b001, 3, 0x22},
	{0b00001, 5, 0x33},
	{0b000001, 6, 0x34},
	{0b0001111, 7, 0x01},
	{0b0001110, 7, 0x02},
	{0b0001101, 7, 0x12},
	{0b0001100, 7, 0x13},
	{0b0001011, 7, 0x23},
	{0b0001010, 7, 0x24},
	{0b0001001, 7, 0x35},
	{0b0001000, 7, 0x36},
	{0b00000111, 9, 0x03}, // 0000 0011 1
	{0b00000110, 9, 0x04}, // 0000 0011 0
	{0b00000101, 9, 0x14}, // 0000 0010 1
	{0b00000100, 9, 0x25}, // 0000 0010 0
	{0b00000111, 10, 0x05}, // 0000 0001 11
	{0b00000110, 10, 0x15}, // 0000 0001 10
	{0b00000101, 10, 0x26}, // 0000 0001 01
	{0b00000100, 10, 0x37}, // 0000 0001 00
	{0b00000111, 11, 0x06}, // 0000 0000 111
	{0b00000110, 11, 0x16}, // 0000 0000 110
	{0b00000101, 11, 0x27}, // 0000 0000 101
	{0b00000100, 11, 0x38}, // 0000 0000 100
	{0b00000111, 12, 0x07}, // 0000 0000 0111
	{0b00000110, 12, 0x17}, // 0000 0000 0110
	{0b00000101, 12, 0x18}, // 0000 0000 0101
	{0b00000100, 12, 0x28}, // 0000 0000 0100
	{0b00000111, 13, 0x08}, // 0000 0000 0011 1
}

// total_zeros of a 4:2:2 chroma DC block (Table 9-9 (b)) per TotalCoeff 1..7.
@(private = "file", rodata)
total_zeros_chroma_dc_422 := [7][]Short_Code {
	{{0b1, 1, 0}, {0b010, 3, 1}, {0b011, 3, 2}, {0b0010, 4, 3}, {0b0011, 4, 4}, {0b0001, 4, 5}, {0b00001, 5, 6}, {0b00000, 5, 7}},
	{{0b000, 3, 0}, {0b01, 2, 1}, {0b001, 3, 2}, {0b100, 3, 3}, {0b101, 3, 4}, {0b110, 3, 5}, {0b111, 3, 6}},
	{{0b000, 3, 0}, {0b001, 3, 1}, {0b01, 2, 2}, {0b10, 2, 3}, {0b110, 3, 4}, {0b111, 3, 5}},
	{{0b110, 3, 0}, {0b00, 2, 1}, {0b01, 2, 2}, {0b10, 2, 3}, {0b111, 3, 4}},
	{{0b00, 2, 0}, {0b01, 2, 1}, {0b10, 2, 2}, {0b11, 2, 3}},
	{{0b00, 2, 0}, {0b01, 2, 1}, {0b1, 1, 2}},
	{{0b0, 1, 0}, {0b1, 1, 1}},
}

// coeff_token: (total_coeff, trailing_ones)
cavlc_read_coeff_token :: proc(
	reader: ^h264.Bit_Reader,
	nc: i8,
) -> (
	total_coeff, trailing_ones: u8,
) #no_bounds_check {
	index, length: u8
	if nc == -2 {
		token, _ := read_short_code(reader, coeff_token_chroma_dc_422[:])
		return token & 15, token >> 4
	} else if nc < 0 {
		entry := coeff_token_chroma_dc_table[h264.peek_bits(reader, 8)]
		index, length = entry[0], entry[1]
	} else if class := int(h264.nc_map_table[min(int(nc), 16)]); class == 3 {
		entry := coeff_token_table[3][h264.peek_bits(reader, 6)]
		index, length = entry[0], 6
	} else {
		first := h264.peek_bits(reader, 8)
		entry := coeff_token_table[class][first]
		index, length = entry[0], entry[1]
		if u8(first) < coeff_token_long_threshold[class] {
			h264.skip_bits(reader, 8)
			entry =
				coeff_token_long_table[class][first][h264.peek_bits(reader, uint(coeff_token_long_bits[class][first]))]
			index, length = entry[0], entry[1]
		}
	}
	h264.skip_bits(reader, uint(length))
	trailing_ones = h264.vlc_trailing_ones_total_coeff[index][0]
	total_coeff = h264.vlc_trailing_ones_total_coeff[index][1]
	return
}

// Level values, highest frequency first (9.2.2)
cavlc_read_levels :: proc(
	reader: ^h264.Bit_Reader,
	total_coeff, trailing_ones: int,
	levels: []i32,
) #no_bounds_check {
	for i in 0 ..< trailing_ones do levels[i] = h264.read_bit(reader) == 1 ? -1 : 1
	suffix_length: u32 = total_coeff > 10 && trailing_ones < 3 ? 1 : 0
	for i in trailing_ones ..< total_coeff {
		level_prefix := min(u32(intrinsics.count_leading_zeros(reader.cache)), 31)
		h264.skip_bits(reader, uint(level_prefix + 1))
		level_code := min(level_prefix, 15) << suffix_length
		suffix_size := suffix_length
		if level_prefix == 14 && suffix_length == 0 do suffix_size = 4
		if level_prefix >= 15 {
			suffix_size = level_prefix - 3
			if suffix_length == 0 do level_code += 15
			if level_prefix >= 16 do level_code += (1 << (level_prefix - 3)) - 4096
		}
		if suffix_size > 0 do level_code += h264.read_bits(reader, uint(min(suffix_size, 28)))
		if i == trailing_ones && trailing_ones < 3 do level_code += 2
		level := level_code & 1 == 0 ? i32(level_code + 2) >> 1 : -(i32(level_code + 1) >> 1)
		levels[i] = level
		if suffix_length == 0 do suffix_length = 1
		if abs(level) > 3 << (suffix_length - 1) && suffix_length < 6 do suffix_length += 1
	}
}

// total_zeros (9.2.3) of a block of max_coeffs levels: chroma DC has 4, or 8
// in 4:2:2.
cavlc_read_total_zeros :: proc(
	reader: ^h264.Bit_Reader,
	total_coeff: int,
	chroma_dc_coefficients: bool,
	max_coeffs := 4,
) -> int #no_bounds_check {
	if chroma_dc_coefficients && max_coeffs == 8 {
		zeros, _ := read_short_code(reader, total_zeros_chroma_dc_422[total_coeff - 1])
		return int(zeros)
	}
	if chroma_dc_coefficients {
		entry :=
			total_zeros_chroma_table[total_coeff - 1][h264.peek_bits(reader, uint(total_zeros_chroma_bits[total_coeff - 1]))]
		h264.skip_bits(reader, uint(entry[1]))
		return int(entry[0])
	}
	entry :=
		total_zeros_table[total_coeff - 1][h264.peek_bits(reader, uint(total_zeros_bits[total_coeff - 1]))]
	h264.skip_bits(reader, uint(entry[1]))
	return int(entry[0])
}

// One run_before while zeros remain. Both the public run-array reader and
// the residual scatter consume this same syntax owner.
@(private = "file")
cavlc_read_run_before :: #force_inline proc(
	reader: ^h264.Bit_Reader,
	zeros_left: int,
) -> int #no_bounds_check {
	bits := uint(run_before_bits[min(zeros_left, 15)])
	entry := run_before_table[min(zeros_left, 7) - 1][h264.peek_bits(reader, bits)]
	h264.skip_bits(reader, uint(entry[1]))
	run := int(entry[0])
	if zeros_left > 6 && run == 7 {
		extra := min(int(intrinsics.count_leading_zeros(reader.cache)), 31)
		h264.skip_bits(reader, uint(extra + 1))
		run += extra
	}
	return min(run, zeros_left)
}

// run_before of every level but the last (9.2.3); runs[i] zeros precede level i
cavlc_read_runs :: proc(
	reader: ^h264.Bit_Reader,
	total_coeff, total_zeros: int,
	runs: []int,
) #no_bounds_check {
	zeros_left := total_zeros
	for i in 0 ..< total_coeff - 1 {
		if zeros_left == 0 do break
		run := cavlc_read_run_before(reader, zeros_left)
		runs[i] = run
		zeros_left -= run
	}
	runs[total_coeff - 1] = zeros_left
}

// residual_block_cavlc (7.3.5.3.2): levels in scan order, returns total_coeff
cavlc_read_residual_block :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index: int,
	$cat: h264.Block_Cat,
	block: int,
	levels: []$L,
	max_coeffs: int,
	plane_444 := 0,
) -> int #no_bounds_check {
	when cat == .Chroma_DC {
		nc := i8(decoder.chroma_422 ? -2 : -1)
	} else {
		nc := h264.cavlc_neighbour_coefficient_count(
			&decoder.grid,
			macroblock_index,
			decoder.left_index,
			decoder.top_index,
			0 when cat == .Luma_DC else block,
			cat == .Chroma_AC,
			decoder.chroma_422 ? 8 : 4,
			plane_444,
		)
	}
	// The block parses on a local reader, kept in registers, stored back once.
	local := decoder.reader^
	reader := &local
	defer decoder.reader^ = local

	total_coeff, trailing_ones := #force_inline cavlc_read_coeff_token(reader, nc)
	total := min(int(total_coeff), max_coeffs)
	if total == 0 do return 0

	level_values: [16]i32
	#force_inline cavlc_read_levels(reader, total, int(trailing_ones), level_values[:])
	total_zeros := 0
	if total < max_coeffs {
		zeros := #force_inline cavlc_read_total_zeros(reader, total, cat == .Chroma_DC, max_coeffs)
		total_zeros = min(zeros, max_coeffs - total)
	}
	// The highest nonzero scan position is total + total_zeros - 1.
	// Runs arrive from that end, so place each level as its run is read.
	// Clamped total/zeros establish 0 <= position < max_coeffs throughout,
	// including the existing padded-zero behavior of a short RBSP reader.
	position := total + total_zeros - 1
	zeros_left := total_zeros
	for i in 0 ..< total {
		when L == i16 {levels[position] = i16(clamp(level_values[i], -32768, 32767))} else {levels[position] = level_values[i]}
		if i + 1 == total do break
		run := 0
		if zeros_left > 0 {
			run = cavlc_read_run_before(reader, zeros_left)
			zeros_left -= run
		}
		position -= run + 1
	}
	return total
}

package h264_decoder

import h264 ".."

import "base:intrinsics"

// ---------------------------------------------------------------------------
// CAVLC residual block parsing (9.2)
// ---------------------------------------------------------------------------

// coeff_token: (total_coeff, trailing_ones)
cavlc_read_coeff_token :: proc(
	reader: ^h264.Bit_Reader,
	nc: i8,
) -> (
	total_coeff, trailing_ones: u8,
) #no_bounds_check {
	index, length: u8
	if nc < 0 {
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

cavlc_read_total_zeros :: proc(
	reader: ^h264.Bit_Reader,
	total_coeff: int,
	chroma_dc_coefficients: bool,
) -> int #no_bounds_check {
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
	$cat: Block_Cat,
	block: int,
	levels: []i16,
	max_coeffs: int,
) -> int #no_bounds_check {
	when cat == .Chroma_DC {
		nc := i8(-1)
	} else {
		nc := h264.cavlc_neighbour_coefficient_count(
			&decoder.grid,
			macroblock_index,
			decoder.left_index,
			decoder.top_index,
			0 when cat == .Luma_DC else block,
			cat == .Chroma_AC,
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
		zeros := #force_inline cavlc_read_total_zeros(reader, total, cat == .Chroma_DC)
		total_zeros = min(zeros, max_coeffs - total)
	}
	// The highest nonzero scan position is total + total_zeros - 1.
	// Runs arrive from that end, so place each level as its run is read.
	// Clamped total/zeros establish 0 <= position < max_coeffs throughout,
	// including the existing padded-zero behavior of a short RBSP reader.
	position := total + total_zeros - 1
	zeros_left := total_zeros
	for i in 0 ..< total {
		levels[position] = i16(clamp(level_values[i], -32768, 32767))
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

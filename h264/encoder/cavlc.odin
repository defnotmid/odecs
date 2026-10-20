package h264_encoder

import h264 ".."

import "base:intrinsics"
import "core:simd"

// ---------------------------------------------------------------------------
// CAVLC writing of residual blocks (9.2) and coded_block_pattern codes
// ---------------------------------------------------------------------------

Cavlc_Coefficient_Summary :: struct {
	levels_descending:  [16]i16, // highest frequency first
	zero_runs:          [16]u8,
	nonzero_count:      int,
	trailing_one_count: int,
	total_zero_count:   int,
	trailing_sign_bits: u32,
}

// Runs and levels of scan-order levels
summarize_cavlc_coefficients :: proc(levels: []i16) -> (summary: Cavlc_Coefficient_Summary) {
	remaining := nonzero_coefficient_mask(levels)
	summary.nonzero_count = int(intrinsics.count_ones(remaining))
	position := 31 - int(intrinsics.count_leading_zeros(remaining))
	summary.total_zero_count = position + 1 - summary.nonzero_count
	for index in 0 ..< summary.nonzero_count {
		summary.levels_descending[index] = levels[position]
		remaining &~= u32(1) << uint(position)
		next_position := 31 - int(intrinsics.count_leading_zeros(remaining))
		summary.zero_runs[index] = u8(position - next_position - 1)
		position = next_position
	}
	for i in 0 ..< min(summary.nonzero_count, 3) {
		if abs(summary.levels_descending[i]) != 1 do break
		summary.trailing_one_count += 1
		summary.trailing_sign_bits =
			summary.trailing_sign_bits << 1 | (summary.levels_descending[i] < 0 ? 1 : 0)
	}
	return
}

nonzero_coefficient_mask :: proc(levels: []i16) -> u32 {
	switch len(levels) {
	case 16:
		coefficients := intrinsics.unaligned_load((^#simd[16]i16)(raw_data(levels)))
		return u32(transmute(u16)simd.extract_msbs(simd.lanes_ne(coefficients, 0)))
	case 15:
		// AC-only blocks have no sixteenth element. Overlap two safe loads
		// and ignore the duplicated lane, without reading past the block.
		first := intrinsics.unaligned_load((^#simd[8]i16)(&levels[0]))
		last := intrinsics.unaligned_load((^#simd[8]i16)(&levels[7]))
		coefficients := simd.shuffle(
			first,
			last,
			0,
			1,
			2,
			3,
			4,
			5,
			6,
			7,
			9,
			10,
			11,
			12,
			13,
			14,
			15,
			8,
		)
		return u32(transmute(u16)simd.extract_msbs(simd.lanes_ne(coefficients, 0))) & 0x7FFF
	case 4:
		coefficients := intrinsics.unaligned_load((^#simd[4]i16)(raw_data(levels)))
		return u32(transmute(u8)simd.extract_msbs(simd.lanes_ne(coefficients, 0)))
	}
	mask: u32
	for coefficient, position in levels do if coefficient != 0 do mask |= u32(1) << uint(position)
	return mask
}

// Baseline limits level_prefix to 15 (A.2.1). Its largest escape has a
// 12-bit suffix: levelCode <= (suffixLength == 0 ? 30 : 15 << suffixLength)
// + 4095, before the first non-trailing level's +2 decoding adjustment.
// Keep DC quantization and reconstruction in that exact emitted domain.
normalize_baseline_cavlc_dc_levels :: proc(levels: []i16) {
	nonzero_count := int(intrinsics.count_ones(nonzero_coefficient_mask(levels)))
	if nonzero_count == 0 do return
	position := len(levels) - 1
	trailing_ones := 0
	for position >= 0 && trailing_ones < 3 {
		value := i32(levels[position])
		if value == 0 {position -= 1; continue}
		if abs(value) != 1 do break
		trailing_ones += 1
		position -= 1
	}
	suffix_length: uint = nonzero_count > 10 && trailing_ones < 3 ? 1 : 0
	first_nontrailing := true
	for position >= 0 {
		value := i32(levels[position])
		if value != 0 {
			code_limit := (suffix_length == 0 ? i32(30) : i32(15 << suffix_length)) + 4095
			if first_nontrailing && trailing_ones < 3 do code_limit += 2
			magnitude_limit := (code_limit - (value < 0 ? 1 : 0)) / 2 + 1
			magnitude := min(abs(value), magnitude_limit)
			levels[position] = i16(value < 0 ? -magnitude : magnitude)
			// The emitted magnitude owns the next suffix state. Clipping these
			// large values preserves the zero mask and all trailing-one signs.
			if suffix_length == 0 do suffix_length = 1
			if magnitude > 3 << (suffix_length - 1) && suffix_length < 6 do suffix_length += 1
			first_nontrailing = false
		}
		position -= 1
	}
}

write_cavlc_block :: proc(writer: ^h264.Bit_Writer, levels: []i16, nc: i8) {
	summary := summarize_cavlc_coefficients(levels)
	max_coeffs := len(levels)
	table := nc < 0 ? 4 : nc < 2 ? 0 : nc < 4 ? 1 : nc < 8 ? 2 : 3
	token := vlc_coeff_token_enc[table][summary.nonzero_count][summary.trailing_one_count]
	h264.write_bits(writer, u32(token[0]), int(token[1]))
	if summary.nonzero_count == 0 do return
	if summary.trailing_one_count > 0 do h264.write_bits(writer, summary.trailing_sign_bits, summary.trailing_one_count)

	suffix_length: uint = summary.nonzero_count > 10 && summary.trailing_one_count < 3 ? 1 : 0
	for i in summary.trailing_one_count ..< summary.nonzero_count {
		value := i32(summary.levels_descending[i])
		magnitude := u32(abs(value))
		level_code := (magnitude - 1) * 2 + (value < 0 ? 1 : 0)
		if i == summary.trailing_one_count && summary.trailing_one_count < 3 do level_code -= 2
		switch {
		case suffix_length == 0 && level_code < 14:
			h264.write_bits(writer, 1, int(level_code + 1))
		case suffix_length == 0 && level_code < 30:
			h264.write_bits(writer, 1, 15)
			h264.write_bits(writer, level_code - 14, 4)
		case suffix_length == 0:
			h264.write_bits(writer, 1, 16)
			h264.write_bits(writer, level_code - 30, 12)
		case level_code >> suffix_length < 15:
			h264.write_bits(writer, 1, int(level_code >> suffix_length) + 1)
			h264.write_bits(writer, level_code & ((1 << suffix_length) - 1), int(suffix_length))
		case:
			h264.write_bits(writer, 1, 16)
			h264.write_bits(writer, level_code - (15 << suffix_length), 12)
		}
		if suffix_length == 0 do suffix_length = 1
		if magnitude > u32(3 << (suffix_length - 1)) && suffix_length < 6 do suffix_length += 1
	}

	if summary.nonzero_count < max_coeffs {
		zeros :=
			nc < 0 ? vlc_total_zeros_chroma_dc_enc[summary.nonzero_count][summary.total_zero_count] : vlc_total_zeros_enc[summary.nonzero_count][summary.total_zero_count]
		h264.write_bits(writer, u32(zeros[0]), int(zeros[1]))
	}
	zeros_left := summary.total_zero_count
	for i := 0; i < summary.nonzero_count - 1 && zeros_left > 0; i += 1 {
		run := vlc_run_before_enc[min(zeros_left, 7)][summary.zero_runs[i]]
		h264.write_bits(writer, u32(run[0]), int(run[1]))
		zeros_left -= int(summary.zero_runs[i])
	}
}

// Inverses derived from this repository's two decoder CBP permutations.
// The exhaustive oracle checks all256 public inputs against those source tables.
@(private = "file")
cbp_inverse: [2][48]u8 = {
	{
		3,
		29,
		30,
		17,
		31,
		18,
		37,
		8,
		32,
		38,
		19,
		9,
		20,
		10,
		11,
		2,
		16,
		33,
		34,
		21,
		35,
		22,
		39,
		4,
		36,
		40,
		23,
		5,
		24,
		6,
		7,
		1,
		41,
		42,
		43,
		25,
		44,
		26,
		46,
		12,
		45,
		47,
		27,
		13,
		28,
		14,
		15,
		0,
	},
	{
		0,
		2,
		3,
		7,
		4,
		8,
		17,
		13,
		5,
		18,
		9,
		14,
		10,
		15,
		16,
		11,
		1,
		32,
		33,
		36,
		34,
		37,
		44,
		40,
		35,
		45,
		38,
		41,
		39,
		42,
		43,
		19,
		6,
		24,
		25,
		20,
		26,
		21,
		46,
		28,
		27,
		47,
		22,
		29,
		23,
		30,
		31,
		12,
	},
}

// coded_block_pattern to its me(v) code (Table 9-4), inverse of the decoder tables
coded_block_pattern_code :: proc(cbp: u8, intra: bool) -> u32 {
	if cbp >= 48 do return 0
	return u32(cbp_inverse[intra ? 0 : 1][cbp])
}

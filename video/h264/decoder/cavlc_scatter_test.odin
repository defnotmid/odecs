package h264_decoder

import h264 ".."
import "base:intrinsics"
import "core:testing"

// Original staged algorithm, kept only as a differential oracle. The token,
// level and total-zero readers are unchanged by this cut; run parsing and
// ascending placement below are independent of the new scatter/run helper.
@(private)
cavlc_staged_oracle :: proc(
	reader: ^h264.Bit_Reader,
	nc: i8,
	chroma_dc: bool,
	levels: []i16,
	max_coeffs: int,
) -> int {
	total_coeff, trailing_ones := cavlc_read_coeff_token(reader, nc)
	total := min(int(total_coeff), max_coeffs)
	if total == 0 do return 0
	values: [16]i32
	cavlc_read_levels(reader, total, int(trailing_ones), values[:])
	zeros := 0
	if total < max_coeffs do zeros = min(cavlc_read_total_zeros(reader, total, chroma_dc), max_coeffs - total)
	runs: [16]int
	zeros_left := zeros
	for i in 0 ..< total - 1 {
		if zeros_left == 0 do break
		bits := uint(run_before_bits[min(zeros_left, 15)])
		entry := run_before_table[min(zeros_left, 7) - 1][h264.peek_bits(reader, bits)]
		h264.skip_bits(reader, uint(entry[1]))
		run := int(entry[0])
		if zeros_left > 6 && run == 7 {
			extra := min(int(intrinsics.count_leading_zeros(reader.cache)), 31)
			h264.skip_bits(reader, uint(extra + 1))
			run += extra
		}
		runs[i] = min(run, zeros_left)
		zeros_left -= runs[i]
	}
	runs[total - 1] = zeros_left
	position := -1
	for i := total - 1; i >= 0; i -= 1 {
		position += runs[i] + 1
		if position >= max_coeffs do break
		levels[position] = i16(clamp(values[i], -32768, 32767))
	}
	return total
}

@(private)
cavlc_expect_reader :: proc(t: ^testing.T, actual, expected: ^h264.Bit_Reader) {
	testing.expect_value(t, actual.pos, expected.pos)
	testing.expect_value(t, actual.cache, expected.cache)
	testing.expect_value(t, actual.bits_left, expected.bits_left)
	testing.expect_value(t, actual.bit_pos, expected.bit_pos)
	testing.expect_value(t, actual.stop_bit_pos, expected.stop_bit_pos)
}

// Checks one category, then the next as a compile-time constant.
@(private = "file")
check_category :: proc(
	t: ^testing.T,
	macroblocks: #soa[]h264.Macroblock,
	bytes: []u8,
	offset: int,
	nc: i8,
	$cat: h264.Block_Cat,
) {
	max_coeffs := cat == .Chroma_DC ? 4 : cat == .Chroma_AC || cat == .Luma_AC ? 15 : 16
	actual, expected: [18]i16
	for &value in actual do value = 12345
	for &value in expected do value = 12345
	for i in 1 ..= max_coeffs {actual[i], expected[i] = 0, 0}
	new_reader := h264.init_bit_reader(bytes)
	h264.skip_bits(&new_reader, uint(offset))
	old_reader := new_reader
	decoder := Slice_Decoder {
		bit_depth = 8,
		reader = &new_reader,
		grid = {macroblocks = macroblocks, macroblock_columns = 2, slice_index = 0},
	}
	new_count := cavlc_read_residual_block(
		&decoder,
		1,
		cat,
		0,
		actual[1:1 + max_coeffs],
		max_coeffs,
	)
	old_count := cavlc_staged_oracle(
		&old_reader,
		cat == .Chroma_DC ? -1 : nc,
		cat == .Chroma_DC,
		expected[1:1 + max_coeffs],
		max_coeffs,
	)
	testing.expect_value(t, new_count, old_count)
	testing.expect_value(t, actual, expected)
	cavlc_expect_reader(t, &new_reader, &old_reader)
	// CAVLC codes 8x8 transform blocks as four 4x4 blocks.
	when cat < .Chroma_AC do check_category(t, macroblocks, bytes, offset, nc, h264.Block_Cat(int(cat) + 1))
}

@(test)
test_fused_cavlc_scatter_matches_staging_at_every_tail_and_nc_class :: proc(t: ^testing.T) {
	macroblocks := make(#soa[]h264.Macroblock, 2)
	defer delete(macroblocks)
	for index in 0 ..< 2 do macroblocks[index].slice_index = 0
	for pattern in 0 ..< 8 {
		bytes: [64]u8
		seed := u32(0x3b79d421) + u32(pattern) * 17
		for &byte, i in bytes {
			seed = seed * 1664525 + 1013904223
			byte =
				pattern == 0 ? 0 : pattern == 1 ? 255 : pattern == 2 ? u8(i & 1 == 0 ? 0x55 : 0xaa) : u8(seed >> 24)
		}
		for length in ([13]int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 24, 64}) {
			for offset in 0 ..< 8 {
				for nc in ([8]i8{0, 1, 2, 3, 4, 7, 8, 16}) {
					for &count in macroblocks[0].nonzero_coefficient_counts do count = u8(nc)
					check_category(t, macroblocks, bytes[:length], offset, nc, .Luma_DC)
				}
			}
		}
	}
}

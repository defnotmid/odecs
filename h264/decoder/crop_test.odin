package h264_decoder

import h264 ".."
import common "../../common"
import "core:testing"

@(private)
write_crop_test_ue :: proc(w: ^common.Bit_Writer, value: u32) {
	if value == max(u32) {
		// codeNum+1 needs 33 bits: the u32 syntax reader must reject it.
		common.write_bits(w, 0, 32)
		common.write_bits(w, 1, 1)
		common.write_bits(w, 0, 32)
	} else {
		common.write_ue(w, value)
	}
}

@(private)
crop_test_sps :: proc(chroma: h264.Chroma_Format, frames_only: bool, crop: [4]u32) -> [dynamic]u8 {
	out: [dynamic]u8
	w := common.init_bit_writer(&out)
	common.write_bits(&w, 100, 8) // High profile
	common.write_bits(&w, 0, 8) // constraints and reserved bits
	common.write_bits(&w, 30, 8)
	common.write_ue(&w, 0) // SPS id
	common.write_ue(&w, u32(chroma))
	if chroma == .YUV_444 do common.write_bits(&w, 0, 1)
	common.write_ue(&w, 0) // luma depth minus 8
	common.write_ue(&w, 0) // chroma depth minus 8
	common.write_bits(&w, 0, 2) // bypass, scaling matrices
	common.write_ue(&w, 0) // frame number bits minus 4
	common.write_ue(&w, 0) // POC type
	common.write_ue(&w, 0) // POC bits minus 4
	common.write_ue(&w, 1) // max references
	common.write_bits(&w, 0, 1) // frame number gaps
	common.write_ue(&w, 3) // 64 coded luma columns
	common.write_ue(&w, 3) // four map-unit rows
	common.write_bits(&w, frames_only ? 1 : 0, 1)
	if !frames_only do common.write_bits(&w, 0, 1)
	common.write_bits(&w, 1, 1) // direct 8x8 inference
	common.write_bits(&w, 1, 1) // frame cropping flag
	for offset in crop do write_crop_test_ue(&w, offset)
	common.write_bits(&w, 0, 1) // VUI absent
	common.write_rbsp_trailing_bits(&w)
	return out
}

@(test)
test_sps_crop_units_and_positive_extent :: proc(t: ^testing.T) {
	cases := []struct {
		chroma:        h264.Chroma_Format,
		frames_only:   bool,
		width, height: int,
	} {
		{.Monochrome, true, 61, 57},
		{.YUV_420, true, 58, 50},
		{.YUV_422, true, 58, 57},
		{.YUV_444, true, 61, 57},
		{.Monochrome, false, 61, 114},
		{.YUV_420, false, 58, 100},
		{.YUV_422, false, 58, 114},
		{.YUV_444, false, 61, 114},
	}
	for c in cases {
		rbsp := crop_test_sps(c.chroma, c.frames_only, {1, 2, 3, 4})
		defer delete(rbsp)
		reader := h264.init_bit_reader(rbsp[:])
		s, ok := parse_sequence_parameter_set(&reader)
		testing.expect(t, ok)
		testing.expect_value(t, s.width, c.width)
		testing.expect_value(t, s.height, c.height)
	}
	rbsp := crop_test_sps(.YUV_420, true, {31, 0, 31, 0})
	defer delete(rbsp)
	reader := h264.init_bit_reader(rbsp[:])
	s, ok := parse_sequence_parameter_set(&reader)
	testing.expect(t, ok)
	testing.expect_value(t, s.width, 2)
	testing.expect_value(t, s.height, 2)
}

@(test)
test_sps_rejects_overflowing_and_empty_crops :: proc(t: ^testing.T) {
	cases := [][4]u32 {
		{max(u32), 0, 0, 0},
		{0, 0, max(u32), 0},
		{max(u32) - 1, 0, 0, 0},
		{0, 0, max(u32) - 1, 0},
		{0x80000000, 0, 0, 0},
		{0, 0, 0x80000000, 0},
		{0x80000000, 0x80000000, 0, 0},
		{0, 0, 0x80000000, 0x80000000},
		{32, 0, 0, 0},
		{0, 0, 32, 0},
		{17, 15, 0, 0},
		{0, 0, 17, 15},
	}
	for crop in cases {
		rbsp := crop_test_sps(.YUV_420, true, crop)
		defer delete(rbsp)
		reader := h264.init_bit_reader(rbsp[:])
		_, ok := parse_sequence_parameter_set(&reader)
		testing.expect(t, !ok)
	}
	s := h264.Sequence_Parameter_Set {
		chroma_format = .YUV_420,
		frames_only   = true,
	}
	_, _, ok := sequence_parameter_set_cropped_dimensions(&s)
	testing.expect(t, !ok)
	s.macroblock_columns, s.macroblock_rows = 4, 4
	s.chroma_format = h264.Chroma_Format(4)
	_, _, ok = sequence_parameter_set_cropped_dimensions(&s)
	testing.expect(t, !ok)
}

package h265_decoder

import common "../../common"
import encoder "../encoder"
import "core:testing"

@(private)
write_crop_test_ue :: proc(w: ^common.Bit_Writer, value: u32) {
	if value == max(u32) {
		common.write_bits(w, 0, 32)
		common.write_bits(w, 1, 1)
		common.write_bits(w, 0, 32)
	} else {
		common.write_ue(w, value)
	}
}

@(private)
crop_test_sps :: proc(
	chroma, width, height: u32,
	crop: [4]u32,
	separate_colour_plane := false,
	ordering: [][2]u32 = nil,
) -> [dynamic]u8 {
	out: [dynamic]u8
	w := common.init_bit_writer(&out)
	common.write_bits(&w, 0, 4) // VPS id
	common.write_bits(&w, 1, 3) // two temporal sublayers
	common.write_bits(&w, 0, 1)
	encoder.write_ptl(&w, 60, 8, .YUV_420)
	common.write_ue(&w, 0) // SPS id
	common.write_ue(&w, chroma)
	if chroma == 3 do common.write_bits(&w, separate_colour_plane ? 1 : 0, 1)
	common.write_ue(&w, width)
	common.write_ue(&w, height)
	common.write_bits(&w, 1, 1) // conformance window
	for offset in crop do write_crop_test_ue(&w, offset)
	common.write_ue(&w, 0) // luma depth minus 8
	common.write_ue(&w, 0) // chroma depth minus 8
	common.write_ue(&w, 4) // POC bits minus 4
	common.write_bits(&w, len(ordering) > 1 ? 1 : 0, 1)
	if len(ordering) == 0 {
		common.write_ue(&w, 1) // max DPB minus 1
		common.write_ue(&w, 0) // max reorder
		common.write_ue(&w, 0) // max latency plus 1
	} else {
		for pair in ordering {
			write_crop_test_ue(&w, pair[0])
			write_crop_test_ue(&w, pair[1])
			common.write_ue(&w, 0)
		}
	}
	common.write_ue(&w, 0) // min CB log2 minus 3
	common.write_ue(&w, 3) // CB size difference
	common.write_ue(&w, 0) // min transform log2 minus 2
	common.write_ue(&w, 3) // transform size difference
	common.write_ue(&w, 0) // inter transform hierarchy
	common.write_ue(&w, 0) // intra transform hierarchy
	common.write_bits(&w, 0, 4) // scaling, AMP, SAO, PCM
	common.write_ue(&w, 0) // short term RPS count
	common.write_bits(&w, 0, 5) // long term, TMVP, smoothing, VUI, extensions
	common.write_rbsp_trailing_bits(&w)
	return out
}

@(test)
test_sps_crop_units_and_positive_extent :: proc(t: ^testing.T) {
	cases := []struct {
		chroma:        u32,
		separate:      bool,
		width, height: u32,
	} {
		{0, false, 61, 57},
		{1, false, 58, 50},
		{2, false, 58, 57},
		{3, false, 61, 57},
		{3, true, 61, 57},
	}
	for c in cases {
		rbsp := crop_test_sps(c.chroma, 64, 64, {1, 2, 3, 4}, c.separate)
		defer delete(rbsp)
		s, parsed := parse_sps(rbsp[:])
		defer destroy_sps(&s)
		testing.expect(t, parsed)
		width, height, ok := sps_cropped_dimensions(&s)
		testing.expect(t, ok)
		testing.expect_value(t, width, c.width)
		testing.expect_value(t, height, c.height)
		testing.expect_value(t, sps_cropped_width(&s), c.width)
		testing.expect_value(t, sps_cropped_height(&s), c.height)
	}
	rbsp := crop_test_sps(1, 64, 64, {31, 0, 31, 0})
	defer delete(rbsp)
	s, ok := parse_sps(rbsp[:])
	defer destroy_sps(&s)
	testing.expect(t, ok)
	testing.expect_value(t, sps_cropped_width(&s), u32(2))
	testing.expect_value(t, sps_cropped_height(&s), u32(2))
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
		rbsp := crop_test_sps(1, 64, 64, crop)
		defer delete(rbsp)
		s, ok := parse_sps(rbsp[:])
		defer destroy_sps(&s)
		testing.expect(t, !ok)
	}
	zero_extents := [][2]u32{{0, 64}, {64, 0}, {0, 0}}
	for dims in zero_extents {
		rbsp := crop_test_sps(1, dims[0], dims[1], {})
		defer delete(rbsp)
		s, ok := parse_sps(rbsp[:])
		defer destroy_sps(&s)
		testing.expect(t, !ok)
	}
	s := SPS {
		chroma_format_idc          = 1,
		pic_width_in_luma_samples  = 64,
		pic_height_in_luma_samples = 64,
		conf_win_left              = max(u32),
		conf_win_right             = 1,
	}
	_, _, ok := sps_cropped_dimensions(&s)
	testing.expect(t, !ok)
	testing.expect_value(t, sps_cropped_width(&s), u32(0))
	testing.expect_value(t, sps_cropped_height(&s), u32(0))
}

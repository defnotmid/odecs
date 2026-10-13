package h265_decoder

import common "../../common"
import encoder "../encoder"
import "core:testing"

@(private)
ordering_test_vps :: proc(ordering: [][2]u32) -> [dynamic]u8 {
	out: [dynamic]u8
	w := common.init_bit_writer(&out)
	common.write_bits(&w, 0, 4) // VPS id
	common.write_bits(&w, 3, 2) // base layer internal/available
	common.write_bits(&w, 0, 6) // max layers minus 1
	common.write_bits(&w, 1, 3) // two temporal sublayers
	common.write_bits(&w, 0, 1) // temporal id nesting
	common.write_bits(&w, 0xffff, 16)
	encoder.write_ptl(&w, 60, 8, .YUV_420)
	common.write_bits(&w, len(ordering) > 1 ? 1 : 0, 1)
	for pair in ordering {
		write_crop_test_ue(&w, pair[0])
		write_crop_test_ue(&w, pair[1])
		common.write_ue(&w, 0)
	}
	common.write_bits(&w, 0, 6) // max layer id
	common.write_ue(&w, 0) // additional layer sets
	common.write_bits(&w, 0, 2) // timing info and extensions absent
	common.write_rbsp_trailing_bits(&w)
	return out
}

@(test)
test_parameter_set_ordering_bounds :: proc(t: ^testing.T) {
	cases := []struct {
		ordering: [][2]u32,
		ok:       bool,
	} {
		{{{0, 0}}, true},
		{{{15, 15}}, true},
		{{{0, 0}, {15, 15}}, true},
		{{{1, 0}, {4, 3}}, true},
		{{{16, 0}}, false},
		{{{1, 2}}, false},
		{{{1, max(u32)}}, false},
		{{{1, max(u32) - 1}}, false},
		{{{max(u32) - 1, 0}}, false},
		{{{2, 0}, {1, 0}}, false},
		{{{2, 1}, {3, 0}}, false},
		{{{1, 2}, {4, 2}}, false},
		{{{16, 0}, {16, 0}}, false},
	}
	for c in cases {
		sps_rbsp := crop_test_sps(1, 64, 64, {}, ordering = c.ordering)
		defer delete(sps_rbsp)
		s, s_ok := parse_sps(sps_rbsp[:])
		defer destroy_sps(&s)
		testing.expect_value(t, s_ok, c.ok)
		vps_rbsp := ordering_test_vps(c.ordering)
		defer delete(vps_rbsp)
		v, v_ok := parse_vps(vps_rbsp[:])
		testing.expect_value(t, v_ok, c.ok)
		if !c.ok do continue
		for i in 0 ..< 2 {
			pair := c.ordering[min(i, len(c.ordering) - 1)]
			testing.expect_value(t, s.max_dec_pic_buffering_by_layer[i], pair[0])
			testing.expect_value(t, s.max_num_reorder_pics_by_layer[i], pair[1])
			testing.expect_value(t, v.max_dec_pic_buffering[i], pair[0])
			testing.expect_value(t, v.max_num_reorder_pics[i], pair[1])
		}
	}
}

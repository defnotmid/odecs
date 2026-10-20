package h265_decoder

import common "../../../common"
import encoder "../encoder"
import "core:testing"

// Check the emitted syntax, including inferred lower sublayers. Low-delay
// output still needs room for the retained references and the current picture.
@(test)
test_parameter_sets_signal_reference_capacity :: proc(t: ^testing.T) {
	cases := []struct {
		config:             encoder.Config,
		buffering, reorder: u32,
		profile:            u8,
	} {
		{{width = 64, height = 64, refs = 1}, 1, 0, 1},
		{{width = 64, height = 64, refs = 4}, 4, 0, 1},
		{{width = 64, height = 64, intra_only = true}, 1, 0, 1},
		{{width = 64, height = 64, b_frames = true}, 2, 1, 1},
		{{width = 64, height = 64, hierarchical = true, gop_size = 8}, 8, 7, 1},
		{{width = 64, height = 64, rdpcm = true}, 1, 0, 4},
		{{width = 64, height = 64, rdpcm = true, bit_depth = 10}, 1, 0, 4},
	}
	for c in cases {
		enc: encoder.Encoder
		encoder.init_encoder(&enc, c.config)
		defer encoder.destroy_encoder(&enc)
		out: [dynamic]u8
		defer delete(out)
		encoder.write_vps(&enc, &out)
		encoder.write_sps(&enc, &out)
		nals := split_annex_b(out[:])
		defer {
			for &n in nals do destroy_nal(&n)
			delete(nals)
		}
		testing.expect_value(t, len(nals), 2)
		if len(nals) != 2 do continue
		v, v_ok := parse_vps(nals[0].rbsp)
		s, s_ok := parse_sps(nals[1].rbsp)
		defer destroy_sps(&s)
		testing.expect(t, v_ok && s_ok)
		if !v_ok || !s_ok do continue
		testing.expect_value(t, s.ptl.profile_idc, c.profile)
		testing.expect_value(t, v.ptl.profile_idc, c.profile)
		testing.expect_value(t, s.implicit_rdpcm, c.config.rdpcm)
		for i in 0 ..= int(s.max_sub_layers_minus1) {
			testing.expect_value(t, s.max_dec_pic_buffering_by_layer[i], c.buffering)
			testing.expect_value(t, s.max_num_reorder_pics_by_layer[i], c.reorder)
			testing.expect_value(t, v.max_dec_pic_buffering[i], c.buffering)
			testing.expect_value(t, v.max_num_reorder_pics[i], c.reorder)
		}
	}
}

// Annex A Table A.2 fixes these nine RExt constraint bits. In particular,
// max_8bit=1 with max_422chroma=1 is reserved for a non-intra colour stream,
// and Table A.1 permits RDPCM in the Main 4:4:4 family only.
@(test)
test_encoder_rext_profile_constraints :: proc(t: ^testing.T) {
	cases := []struct {
		layout:      encoder.Chroma_Layout,
		depth:       int,
		rdpcm:       bool,
		constraints: u32,
	} {
		{.YUV_420, 8, true, 0b111000001},
		{.YUV_420, 10, true, 0b110000001},
		{.YUV_422, 8, false, 0b110100001},
		{.YUV_422, 10, false, 0b110100001},
		{.YUV_422, 8, true, 0b111000001},
		{.YUV_444, 8, false, 0b111000001},
		{.Monochrome, 8, false, 0b111111001},
		{.Monochrome, 10, false, 0b110111001},
		{.Monochrome, 8, true, 0b111000001},
	}
	for c in cases {
		out: [dynamic]u8
		defer delete(out)
		writer := common.init_bit_writer(&out)
		encoder.write_ptl(&writer, 60, c.depth, c.layout, c.rdpcm)
		bits: Get_Bits
		get_bits_init(&bits, out[:])
		get_bits_skip(&bits, 3)
		testing.expect_value(t, get_bits_bits(&bits, 5), u32(4))
		testing.expect_value(t, get_bits_bits(&bits, 32), u32(0x08000000))
		get_bits_skip(&bits, 4)
		testing.expect_value(t, get_bits_bits(&bits, 9), c.constraints)
		testing.expect(t, !bits.err)
	}
}

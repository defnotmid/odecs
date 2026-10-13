package h265_decoder

import "core:encoding/hex"
import "core:testing"

// The VPS x265 writes for an alpha stream (--alpha): two layers, the
// extension's scalability mask with AuxId, and layer 1 as AuxId 1 (alpha).
@(private = "file")
ALPHA_VPS :: "40010c11ffff01600000030090000003000003003c959815bf3c1800010704383808000004fc400000030001e4680a00078500514acd48"

@(test)
vps_declares_alpha_layer :: proc(t: ^testing.T) {
	bytes, ok := hex.decode(transmute([]u8)string(ALPHA_VPS))
	defer delete(bytes)
	testing.expect(t, ok)
	nal, nal_ok := parse_nal(bytes)
	testing.expect(t, nal_ok)
	defer destroy_nal(&nal)
	v, vps_ok := parse_vps(nal.rbsp)
	testing.expect(t, vps_ok)
	testing.expect_value(t, v.max_layers_minus1, 1)
	testing.expect_value(t, v.alpha_layer_id, 1)
}

// A decoder for layer 0 skips another layer's NAL units, and one for the
// alpha layer skips layer 0's (VPSs aside).
@(test)
decoders_keep_to_their_layer :: proc(t: ^testing.T) {
	d: Decoder
	init_decoder(&d)
	defer destroy_decoder(&d)
	out: [dynamic]^Picture
	defer delete(out)
	// A slice NAL of layer 1 is accepted (skipped) by a layer-0 decoder
	// without a picture or an error, even with no parameter sets.
	slice := Nal_Unit{type = .IDR_W_RADL, layer_id = 1, rbsp = {0x80}}
	testing.expect(t, decode_nal(&d, slice, &out))
	testing.expect_value(t, len(out), 0)
	d.layer = 1
	slice.layer_id = 0
	testing.expect(t, decode_nal(&d, slice, &out))
	testing.expect_value(t, len(out), 0)
}

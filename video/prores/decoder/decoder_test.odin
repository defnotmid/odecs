package prores_decoder

import prores ".."
import common "../../../common"
import "core:testing"

// A 16x16 frame of one slice, written field by field. Every block has only
// a DC coefficient: luma DC +1 at quantizer index 16 is the coefficient
// 1 * 4 * 16 = 64, 8 in 12-bit units, so 10-bit luma is 512 + 2. Chroma DC 0
// stays at mid-grey.
@(private)
build_frame :: proc(chroma444: bool, alpha_bits: int) -> [dynamic]u8 {
	bits: [dynamic]u8
	defer delete(bits)
	// One component: the first DC with codebook 0xB8 (Rice order 5), then
	// zero differences: 0x70 after the initial state, 0x04 after a zero.
	component :: proc(bits: ^[dynamic]u8, first_dc: u32, blocks: int) -> []u8 {
		w := common.init_bit_writer(bits)
		common.write_bits(&w, 1, 1)
		common.write_bits(&w, first_dc, 5)
		for b in 1 ..< blocks {
			common.write_bits(&w, 1, 1)
			if b == 1 do common.write_bits(&w, 0, 3)
		}
		common.write_align_zero(&w)
		out := make([]u8, len(bits))
		copy(out, bits[:])
		return out
	}
	luma := component(&bits, 2, 4) // value 2 is DC +1
	chroma := component(&bits, 0, chroma444 ? 4 : 2)
	defer delete(luma)
	defer delete(chroma)
	alpha: []u8
	if alpha_bits == 8 {
		// Opaque: a full-width difference of 0 from the initial 255, then
		// a run of the remaining 255 values (4 zero bits, then 11 bits).
		w := common.init_bit_writer(&bits)
		common.write_bits(&w, 1, 1)
		common.write_bits(&w, 0, 8)
		common.write_bits(&w, 0, 1)
		common.write_bits(&w, 0, 4)
		common.write_bits(&w, 255, 11)
		common.write_align_zero(&w)
		alpha = make([]u8, len(bits))
		copy(alpha, bits[:])
	}
	defer delete(alpha)
	put16 :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v >> 8), u8(v))}
	put32 :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}
	slice: [dynamic]u8
	defer delete(slice)
	append(&slice, 8 << 3, 16) // header size, quantizer index
	put16(&slice, len(luma))
	put16(&slice, len(chroma))
	put16(&slice, len(chroma))
	append(&slice, ..luma)
	append(&slice, ..chroma)
	append(&slice, ..chroma)
	append(&slice, ..alpha)
	frame: [dynamic]u8
	header_size := 20
	picture_size := 8 + 2 + len(slice)
	put32(&frame, 8 + header_size + picture_size)
	append(&frame, 'i', 'c', 'p', 'f')
	put16(&frame, header_size)
	append(&frame, 0, chroma444 ? 1 : 0, 't', 'e', 's', 't')
	put16(&frame, 16)
	put16(&frame, 16)
	append(&frame, (chroma444 ? 3 : 2) << 6, 0, 1, 1, 1, u8(alpha_bits == 8 ? 1 : 0), 0, 0)
	append(&frame, 8 << 3)
	put32(&frame, picture_size)
	put16(&frame, 1)
	append(&frame, 0) // one-macroblock slices
	put16(&frame, len(slice))
	append(&frame, ..slice[:])
	return frame
}

@(test)
flat_422_frame_decodes_to_dc_values :: proc(t: ^testing.T) {
	frame := build_frame(false, 0)
	defer delete(frame)
	d: Decoder
	init_decoder(&d)
	defer destroy_decoder(&d)
	f, err := decode_frame(&d, frame[:])
	testing.expect_value(t, err, prores.Error.None)
	if err != .None do return
	testing.expect_value(t, f.bit_depth, 10)
	testing.expect_value(t, f.chroma, prores.Chroma.YUV422)
	testing.expect(t, f.alpha == nil)
	for y in 0 ..< 16 do for x in 0 ..< 16 {
		testing.expect_value(t, f.planes[0][y * f.strides[0] + x], 514)
		if x < 8 do testing.expect_value(t, f.planes[1][y * f.strides[1] + x], 512)
	}
}

@(test)
alpha_4444_frame_is_opaque :: proc(t: ^testing.T) {
	frame := build_frame(true, 8)
	defer delete(frame)
	d: Decoder
	init_decoder(&d)
	defer destroy_decoder(&d)
	f, err := decode_frame(&d, frame[:])
	testing.expect_value(t, err, prores.Error.None)
	if err != .None do return
	testing.expect_value(t, f.bit_depth, 12)
	testing.expect(t, f.alpha != nil)
	for y in 0 ..< 16 do for x in 0 ..< 16 {
		testing.expect_value(t, f.planes[0][y * f.strides[0] + x], 2048 + 8)
		testing.expect_value(t, f.alpha[y * f.alpha_stride + x], 4095)
	}
}

// Every truncation of a valid frame is refused, never read past its end.
@(test)
truncated_frames_fail_cleanly :: proc(t: ^testing.T) {
	frame := build_frame(true, 8)
	defer delete(frame)
	d: Decoder
	init_decoder(&d)
	defer destroy_decoder(&d)
	for n in 0 ..< len(frame) {
		_, err := decode_frame(&d, frame[:n])
		testing.expect(t, err != .None)
	}
}

@(test)
slice_layout :: proc(t: ^testing.T) {
	// 20 macroblocks at 8 per slice: 8, 8, 4.
	testing.expect_value(t, prores.slices_per_row(20, 3), 3)
	testing.expect_value(t, prores.slice_mb_count(20, 16, 3), 4)
	// 23 at 8: 8, 8, 4, 2, 1.
	testing.expect_value(t, prores.slices_per_row(23, 3), 5)
	testing.expect_value(t, prores.slice_mb_count(23, 22, 3), 1)
	testing.expect_value(t, prores.qscale(128), 128)
	testing.expect_value(t, prores.qscale(129), 132)
	testing.expect_value(t, prores.qscale(224), 512)
}

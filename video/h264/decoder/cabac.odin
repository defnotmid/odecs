package h264_decoder

import h264 ".."
import common "../../../common"


// ---------------------------------------------------------------------------
// CABAC arithmetic decoding engine (9.3.1.2, 9.3.3.2)
// ---------------------------------------------------------------------------

// Initialise all context variables for a slice (9.3.1.1).
cabac_init_contexts :: #force_inline proc(
	engine: ^Cabac_Engine,
	slice_type: h264.Slice_Type,
	cabac_init_idc: u32,
	slice_qp: i32,
) {
	h264.cabac_init_contexts(&engine.ctx, slice_type, cabac_init_idc, slice_qp)
}

// Initialise the decoding engine (common's, shared with HEVC) at the reader's
// position: at the start of slice data or after PCM samples (9.3.1.2).
cabac_init_engine :: proc(engine: ^Cabac_Engine, reader: ^h264.Bit_Reader) {
	common.cabac_start(&engine.cursor, reader.data, reader.bit_pos)
}

// Return the bit reader to the position the arithmetic decoder has consumed
// (after a terminating bin: before pcm_alignment_zero_bit or rbsp_trailing_bits).
cabac_release_reader :: proc(engine: ^Cabac_Engine, reader: ^h264.Bit_Reader) {
	h264.seek_bits(reader, common.cabac_consumed_bits(&engine.cursor))
}

cabac_decode_decision :: #force_inline proc(
	engine: ^Cabac_Engine,
	ctx_idx: int,
) -> u32 #no_bounds_check {
	return common.cabac_decision(&engine.cursor, &engine.ctx[ctx_idx])
}

cabac_decode_bypass :: #force_inline proc(engine: ^Cabac_Engine) -> u32 {
	return common.cabac_bypass(&engine.cursor)
}

// DecodeTerminate (9.3.3.2.2.3). A terminating bin returns the reader to the
// consumed position.
cabac_decode_terminate :: proc(engine: ^Cabac_Engine, reader: ^h264.Bit_Reader) -> u32 {
	if common.cabac_terminate(&engine.cursor) == 0 do return 0
	cabac_release_reader(engine, reader)
	return 1
}

// Exp-Golomb suffix of order k in bypass mode (9.3.3.2.3, UEGk with unary
// prefix already consumed), on a local cursor.
cabac_exp_golomb :: #force_inline proc "contextless" (c: ^common.Cabac_Cursor, k: uint) -> u32 {
	k := k
	value: u32 = 0
	for common.cabac_bypass(c) == 1 {
		value += 1 << k
		k += 1
		if k > 30 do break
	}
	for k > 0 {
		k -= 1
		value += common.cabac_bypass(c) << k
	}
	return value
}

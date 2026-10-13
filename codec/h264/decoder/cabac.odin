package h264_decoder

import h264 ".."

import "base:intrinsics"
import "core:math/bits"

// ---------------------------------------------------------------------------
// CABAC arithmetic decoding engine (9.3.1.2, 9.3.3.2)
// ---------------------------------------------------------------------------

// Initialise all context variables for a slice (9.3.1.1).
cabac_init_contexts :: proc(
	engine: ^Cabac_Engine,
	slice_type: h264.Slice_Type,
	cabac_init_idc: u32,
	slice_qp: i32,
) {
	kind := slice_type == .I || slice_type == .SI ? 0 : int(cabac_init_idc) + 1
	qp := clamp(slice_qp, 0, 51)
	for ctx in 0 ..< CABAC_CONTEXT_COUNT {
		m := i32(cabac_context_init[ctx][kind][0])
		n := i32(cabac_context_init[ctx][kind][1])
		pre := clamp(((m * qp) >> 4) + n, 1, 126)
		if pre <= 63 {
			engine.ctx[ctx] = u8((63 - pre) << 1)
		} else {
			engine.ctx[ctx] = u8((pre - 64) << 1 | 1)
		}
	}
}

// Context bytes index these tables directly: the LPS range per
// codIRange quantization, and the next byte after an MPS or an LPS bin
// (Tables 9-44 and 9-45, with valMPS flipping on an LPS at pStateIdx 0).
cabac_lps_range: [128][4]u8
cabac_next: [128][2]u8 // [byte][bin was LPS]

@(init, private = "file")
build_cabac_byte_tables :: proc "contextless" () {
	for st in 0 ..< 128 {
		state, mps := st >> 1, u8(st & 1)
		cabac_lps_range[st] = cabac_range_lps[state]
		cabac_next[st][0] = cabac_state_trans[state][1] << 1 | mps
		cabac_next[st][1] = cabac_state_trans[state][0] << 1 | (state == 0 ? mps ~ 1 : mps)
	}
}

// Window refills load 32 stream bits once fewer than 16 remain; a
// renormalization shifts at most 6 bits, so the window never runs dry.
CABAC_REFILL_BELOW :: 16

// Initialise the decoding engine at the reader's position: at the start of
// slice data or after PCM samples (9.3.1.2). codIOffset takes the next nine
// bits; the rest of the loaded window stays as look-ahead.
cabac_init_engine :: proc(engine: ^Cabac_Engine, reader: ^h264.Bit_Reader) {
	c := &engine.cursor
	c^ = {
		range = 510,
		data  = reader.data,
		pos   = reader.bit_pos >> 3,
	}
	cabac_refill(c)
	// Bits before the reader position leave the window.
	skip := u32(reader.bit_pos & 7)
	c.value = (c.value << skip) & (1 << 48 - 1)
	c.buffered -= skip
	cabac_shift(c, 9)
}

// Return the bit reader to the position the arithmetic decoder has consumed
// (after a terminating bin: before pcm_alignment_zero_bit or rbsp_trailing_bits).
cabac_release_reader :: proc(engine: ^Cabac_Engine, reader: ^h264.Bit_Reader) {
	h264.seek_bits(reader, engine.cursor.pos * 8 - int(engine.cursor.buffered))
}

// The four stream bytes at pos, big-endian, with zeros past the end.
@(private = "file")
cabac_tail_word :: proc "contextless" (data: []u8, pos: int) -> (word: u64) #no_bounds_check {
	for i in 0 ..< 4 {
		word <<= 8
		if at := pos + i; at >= 0 && at < len(data) do word |= u64(data[at])
	}
	return
}

cabac_refill :: #force_inline proc "contextless" (c: ^Cabac_Cursor) #no_bounds_check {
	word: u64
	if c.pos >= 0 && c.pos + 4 <= len(c.data) {
		word = u64(bits.from_be_u32(intrinsics.unaligned_load((^u32)(&c.data[c.pos]))))
	} else {
		word = cabac_tail_word(c.data, c.pos)
	}
	c.value |= word << (CABAC_REFILL_BELOW - c.buffered)
	c.buffered += 32
	c.pos += 4
}

// Move `shift` look-ahead bits into codIOffset.
cabac_shift :: #force_inline proc "contextless" (c: ^Cabac_Cursor, shift: u32) {
	c.value <<= shift
	c.buffered -= shift
	if c.buffered < CABAC_REFILL_BELOW do cabac_refill(c)
}

// DecodeDecision (9.3.3.2.1) with RenormD; the context byte is updated in
// place. The MPS/LPS outcome is data dependent, so it selects values rather
// than branching; RenormD's shift is zero while codIRange stays >= 256.
cabac_decision :: #force_inline proc "contextless" (
	c: ^Cabac_Cursor,
	ctx: ^u8,
) -> u32 #no_bounds_check {
	st := ctx^
	lps := u32(cabac_lps_range[st][(c.range >> 6) & 3])
	mps_range := c.range - lps
	scaled := u64(mps_range) << 48
	is_lps := c.value >= scaled
	c.value -= is_lps ? scaled : 0
	c.range = is_lps ? lps : mps_range
	ctx^ = cabac_next[st][int(is_lps)]
	shift := u32(intrinsics.count_leading_zeros(c.range)) - 23
	c.range <<= shift
	cabac_shift(c, shift)
	return u32(st & 1) ~ u32(is_lps)
}

// DecodeBypass (9.3.3.2.3): one look-ahead bit joins codIOffset.
cabac_bypass :: #force_inline proc "contextless" (c: ^Cabac_Cursor) -> u32 {
	cabac_shift(c, 1)
	scaled := u64(c.range) << 48
	if c.value >= scaled {
		c.value -= scaled
		return 1
	}
	return 0
}

cabac_decode_decision :: #force_inline proc(
	engine: ^Cabac_Engine,
	ctx_idx: int,
) -> u32 #no_bounds_check {
	return cabac_decision(&engine.cursor, &engine.ctx[ctx_idx])
}

cabac_decode_bypass :: #force_inline proc(engine: ^Cabac_Engine) -> u32 {
	return cabac_bypass(&engine.cursor)
}

// DecodeTerminate (9.3.3.2.2.3). A terminating bin returns the reader to the
// consumed position.
cabac_decode_terminate :: proc(engine: ^Cabac_Engine, reader: ^h264.Bit_Reader) -> u32 {
	c := &engine.cursor
	c.range -= 2
	if c.value >= u64(c.range) << 48 {
		cabac_release_reader(engine, reader)
		return 1
	}
	if c.range < 256 {
		shift := u32(intrinsics.count_leading_zeros(c.range)) - 23
		c.range <<= shift
		cabac_shift(c, shift)
	}
	return 0
}

// Exp-Golomb suffix of order k in bypass mode (9.3.3.2.3, UEGk with unary
// prefix already consumed), on a local cursor.
cabac_exp_golomb :: #force_inline proc "contextless" (c: ^Cabac_Cursor, k: uint) -> u32 {
	k := k
	value: u32 = 0
	for cabac_bypass(c) == 1 {
		value += 1 << k
		k += 1
		if k > 30 do break
	}
	for k > 0 {
		k -= 1
		value += cabac_bypass(c) << k
	}
	return value
}

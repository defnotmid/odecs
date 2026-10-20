package h264_decoder

import common "../../../common"
import h264 ".."
import "core:testing"

// A literal 9.3.3.2 arithmetic decoder: a 9-bit codIOffset that takes one
// stream bit per renormalization step, the normative LPS range and state
// transition tables, and an independent bit counter. It shares no window,
// refill or byte-indexed table with the production cursor.
@(private = "file")
Spec_Engine :: struct {
	range, offset: u32,
	data:          []u8,
	bit:           int, // stream bits consumed
	ctx:           [CABAC_CONTEXT_COUNT]u8,
}

@(private = "file")
spec_read_bit :: proc(e: ^Spec_Engine) -> u32 {
	byte_index := e.bit >> 3
	b: u32
	if byte_index < len(e.data) do b = u32(e.data[byte_index] >> uint(7 - e.bit & 7)) & 1
	e.bit += 1
	return b
}

@(private = "file")
spec_init :: proc(e: ^Spec_Engine, data: []u8, start: int) {
	e.data, e.bit, e.range, e.offset = data, start, 510, 0
	for _ in 0 ..< 9 do e.offset = e.offset << 1 | spec_read_bit(e)
}

@(private = "file")
spec_decision :: proc(e: ^Spec_Engine, ctx_idx: int) -> u32 {
	state, mps := e.ctx[ctx_idx] >> 1, u32(e.ctx[ctx_idx] & 1)
	lps := u32(common.RANGE_TAB_LPS[state][(e.range >> 6) & 3])
	e.range -= lps
	bin: u32
	if e.offset >= e.range {
		bin = 1 - mps
		e.offset -= e.range
		e.range = lps
		if state == 0 do mps = 1 - mps
		state = common.TRANS_IDX[state][0]
	} else {
		bin = mps
		state = common.TRANS_IDX[state][1]
	}
	e.ctx[ctx_idx] = state << 1 | u8(mps)
	for e.range < 256 {
		e.range <<= 1
		e.offset = e.offset << 1 | spec_read_bit(e)
	}
	return bin
}

@(private = "file")
spec_bypass :: proc(e: ^Spec_Engine) -> u32 {
	e.offset = e.offset << 1 | spec_read_bit(e)
	if e.offset >= e.range {
		e.offset -= e.range
		return 1
	}
	return 0
}

@(private = "file")
spec_terminate :: proc(e: ^Spec_Engine) -> u32 {
	e.range -= 2
	if e.offset >= e.range do return 1
	for e.range < 256 {
		e.range <<= 1
		e.offset = e.offset << 1 | spec_read_bit(e)
	}
	return 0
}

@(private = "file")
same_state :: proc(a: ^Cabac_Engine, b: ^Spec_Engine) -> bool {
	c := &a.cursor
	return(
		c.range == b.range &&
		u32(c.value >> 48) == b.offset &&
		c.value & (1 << (48 - u64(c.buffered)) - 1) == 0 &&
		c.pos * 8 - int(c.buffered) == b.bit &&
		a.ctx == b.ctx \
	)
}

@(test)
test_cabac_cursor_matches_specification_engine :: proc(t: ^testing.T) {
	data: [131]u8
	seed: u32 = 0x9274_0651
	for &value in data {seed = seed * 1664525 + 1013904223; value = u8(seed >> 24)}
	for length in ([12]int{0, 1, 2, 3, 4, 5, 7, 8, 9, 33, 64, len(data)}) {
		for start in ([10]int{0, 1, 3, 7, 8, 9, 15, 16, 31, 40}) {
			for init_kind in 0 ..< 4 {
				reader := h264.init_bit_reader(data[:length])
				h264.skip_bits(&reader, uint(start))
				a: Cabac_Engine
				cabac_init_contexts(
					&a,
					init_kind == 0 ? .I : .B,
					u32(init_kind % 3),
					i32(start * 7 % 52),
				)
				cabac_init_engine(&a, &reader)
				b := Spec_Engine {
					ctx = a.ctx,
				}
				spec_init(&b, data[:length], start)
				// 9.3.1.2: a bitstream never initializes codIOffset to 510 or
				// 511. Beyond it the engines' unbounded widths differ.
				if b.offset >= 510 do continue
				if !same_state(&a, &b) {
					testing.expectf(t, false, "init length %d start %d", length, start)
					return
				}
				steps: for step in 0 ..< 1500 {
					seed = seed * 1664525 + 1013904223
					index := int(seed >> 8) % CABAC_CONTEXT_COUNT
					actual, expected: u32
					switch (seed >> 28) % 7 {
					case 0, 1:
						actual, expected = cabac_decode_bypass(&a), spec_bypass(&b)
					case 2:
						if b.range < 258 do continue
						actual, expected = cabac_decode_terminate(&a, &reader), spec_terminate(&b)
						if expected == 1 {
							// The terminating bin ends arithmetic decoding here.
							testing.expect_value(t, actual, expected)
							testing.expect_value(t, reader.bit_pos, b.bit)
							break steps
						}
					case:
						actual, expected =
							cabac_decode_decision(&a, index), spec_decision(&b, index)
					}
					if actual != expected || !same_state(&a, &b) {
						testing.expectf(
							t,
							false,
							"length %d start %d step %d diverged",
							length,
							start,
							step,
						)
						return
					}
				}
			}
		}
	}
}

// Residual levels decoded through the local cursor match the same syntax
// read one bin at a time from a specification engine.
@(test)
test_cabac_residual_levels_match_specification_engine :: proc(t: ^testing.T) {
	seed: u32 = 0x5eed_1234
	for trial in 0 ..< 70 {
		if !check_levels(t, min(Block_Cat), trial, &seed) do return
	}
}

// Checks one category, then the next as a compile-time constant.
@(private = "file")
check_levels :: proc(t: ^testing.T, $cat: Block_Cat, trial: int, seed: ^u32) -> bool {
	max_coeffs := ([6]int{16, 15, 16, 4, 15, 64})[cat]
	data: [512]u8
	for &value in data {seed^ = seed^ * 1664525 + 1013904223; value = u8(seed^ >> 24)}
	// A coded slice starts with codIOffset below codIRange (510).
	data[0] &= 0x7f
	reader := h264.init_bit_reader(data[:])
	a: Cabac_Engine
	cabac_init_contexts(&a, .P, u32(trial % 3), i32(trial % 52))
	for &ctx, i in a.ctx do ctx = u8((int(ctx) + i * trial) % 128)
	cabac_init_engine(&a, &reader)
	b := Spec_Engine {
		ctx = a.ctx,
	}
	spec_init(&b, data[:], 0)

	actual: [64]i16
	cabac_residual_levels(&a, cat, actual[:max_coeffs], max_coeffs)

	// 7.3.5.3.3 and 9.3.3.1.3 read bin by bin, with ctxIdxOffset and
	// ctxBlockCatOffset from Tables 9-34 and 9-40.
	sig_offset := [6]int{0, 15, 29, 44, 47, 0}
	abs_offset := [6]int{0, 10, 20, 30, 39, 0}
	sig_base, last_base, abs_base := 402, 417, 426
	if cat != .Luma_8x8 {
		sig_base = 105 + sig_offset[cat]
		last_base = 166 + sig_offset[cat]
		abs_base = 227 + abs_offset[cat]
	}
	expected: [64]i16
	significant: [64]bool
	num_last := max_coeffs - 1
	for i in 0 ..< max_coeffs - 1 {
		sig, last := i, i
		if cat == .Luma_8x8 do sig, last = int(sig_coeff_ctx_8x8[i]), int(last_coeff_ctx_8x8[i])
		if cat == .Chroma_DC do sig, last = min(i, 2), min(i, 2)
		if spec_decision(&b, sig_base + sig) == 0 do continue
		significant[i] = true
		if spec_decision(&b, last_base + last) == 1 {
			num_last = i
			break
		}
	}
	significant[num_last] = true
	gt1, eq1 := 0, 0
	for i := num_last; i >= 0; i -= 1 {
		if !significant[i] do continue
		value: i32 = 1
		if spec_decision(&b, abs_base + (gt1 != 0 ? 0 : min(4, 1 + eq1))) == 1 {
			ctx := abs_base + 5 + min(cat == .Chroma_DC ? 3 : 4, gt1)
			value = 2
			for value < 15 && spec_decision(&b, ctx) == 1 do value += 1
			if value == 15 {
				k: uint = 0
				for k <= 30 && spec_bypass(&b) == 1 {value += 1 << k; k += 1}
				for k > 0 {k -= 1; value += i32(spec_bypass(&b)) << k}
			}
			gt1 += 1
		} else {
			eq1 += 1
		}
		if spec_bypass(&b) == 1 do value = -value
		expected[i] = i16(value)
	}
	if actual != expected || !same_state(&a, &b) {
		testing.expectf(t, false, "trial %d cat %v diverged", trial, cat)
		return false
	}
	when cat < max(Block_Cat) do return check_levels(t, Block_Cat(int(cat) + 1), trial, seed)
	return true
}

package h265_decoder

import common "../../../common"
import "core:testing"

// ---------------------------------------------------------------------------
// The arithmetic encoder of 9.3.4.4, longhand. Ported from the reference
// decoder's cabac_test.go (MIT) so the engine can be round-tripped against an
// implementation that shares no state representation with it.
// ---------------------------------------------------------------------------

Cabac_Ref_Encoder :: struct {
	low:         u32,
	rng:         u32,
	outstanding: int,
	first_bit:   bool,
	out:         [dynamic]u8,
	nbits:       int,
	p_state:     [CABAC_N_CONTEXTS]u8,
	val_mps:     [CABAC_N_CONTEXTS]u8,
}

ref_encoder_init :: proc(e: ^Cabac_Ref_Encoder, qp: i32, st: Slice_Type, cabac_init: bool) {
	e.low = 0
	e.rng = 510
	e.first_bit = true

	row := &CABAC_INIT_VALUES[cabac_init_type(st, cabac_init)]

	for i in 0 ..< CABAC_N_CONTEXTS {
		s := cabac_init_state(row[i], qp)
		e.p_state[i] = s >> 1
		e.val_mps[i] = s & 1
	}
}

ref_encoder_destroy :: proc(e: ^Cabac_Ref_Encoder) {
	delete(e.out)
	e^ = {}
}

@(private)
ref_write_bit :: proc(e: ^Cabac_Ref_Encoder, b: u32) {
	if e.nbits % 8 == 0 do append(&e.out, 0)

	if b != 0 do e.out[len(e.out) - 1] |= 1 << uint(7 - e.nbits % 8)

	e.nbits += 1
}

@(private)
ref_put_bit :: proc(e: ^Cabac_Ref_Encoder, b: u32) {
	if e.first_bit {
		e.first_bit = false
	} else {
		ref_write_bit(e, b)
	}

	for e.outstanding > 0 {
		ref_write_bit(e, 1 - b)
		e.outstanding -= 1
	}
}

@(private)
ref_renorm :: proc(e: ^Cabac_Ref_Encoder) {
	for e.rng < 256 {
		switch {
		case e.low < 256:
			ref_put_bit(e, 0)
		case e.low >= 512:
			e.low -= 512
			ref_put_bit(e, 1)
		case:
			e.low -= 256
			e.outstanding += 1
		}

		e.rng <<= 1
		e.low <<= 1
	}
}

ref_encode_bin :: proc(e: ^Cabac_Ref_Encoder, ctx: int, bin: u32) {
	lps := u32(common.RANGE_TAB_LPS[e.p_state[ctx]][(e.rng >> 6) & 3])
	e.rng -= lps

	if bin != u32(e.val_mps[ctx]) {
		e.low += e.rng
		e.rng = lps

		if e.p_state[ctx] == 0 do e.val_mps[ctx] = 1 - e.val_mps[ctx]

		e.p_state[ctx] = common.TRANS_IDX[e.p_state[ctx]][0]
	} else {
		mps := int(e.p_state[ctx])
		if mps < 62 do mps += 1

		e.p_state[ctx] = u8(mps)
	}

	ref_renorm(e)
}

ref_encode_bypass :: proc(e: ^Cabac_Ref_Encoder, bin: u32) {
	e.low <<= 1
	if bin != 0 do e.low += e.rng

	switch {
	case e.low >= 1024:
		e.low -= 1024
		ref_put_bit(e, 1)
	case e.low < 512:
		ref_put_bit(e, 0)
	case:
		e.low -= 512
		e.outstanding += 1
	}
}

ref_encode_terminate :: proc(e: ^Cabac_Ref_Encoder, bin: u32) {
	e.rng -= 2

	if bin == 0 {
		ref_renorm(e)
		return
	}

	e.low += e.rng
	e.rng = 2
	ref_renorm(e)

	ref_put_bit(e, e.low >> 9 & 1)
	ref_write_bit(e, e.low >> 8 & 1)
	ref_write_bit(e, 1)
}

// ref_encoder_finish pads to eight bytes the way the reference test does.
ref_encoder_finish :: proc(e: ^Cabac_Ref_Encoder) -> []u8 {
	for len(e.out) < 8 do append(&e.out, 0)

	return e.out[:]
}

// ---------------------------------------------------------------------------

@(test)
test_cabac_init_type :: proc(t: ^testing.T) {
	testing.expect_value(t, cabac_init_type(.I, false), 0)
	testing.expect_value(t, cabac_init_type(.I, true), 0)
	testing.expect_value(t, cabac_init_type(.P, false), 1)
	testing.expect_value(t, cabac_init_type(.P, true), 2)
	testing.expect_value(t, cabac_init_type(.B, false), 2)
	testing.expect_value(t, cabac_init_type(.B, true), 1)
}

@(test)
test_cabac_init_state_matches_spec :: proc(t: ^testing.T) {
	for v in 0 ..< 256 {
		for qp_in in i32(-10) ..= 60 {
			iv := u8(v)
			m := i32(iv >> 4) * 5 - 45
			n := i32(iv & 0x0f) << 3 - 16

			qp := clamp(qp_in, 0, 51)
			pre := clamp((m * qp >> 4) + n, 1, 126)

			val_mps: i32
			p_state_idx := 63 - pre

			if pre > 63 {
				val_mps = 1
				p_state_idx = pre - 64
			}

			want := u8(2 * p_state_idx + val_mps)
			got := cabac_init_state(iv, qp_in)
			testing.expectf(
				t,
				got == want,
				"init_state(%d, %d) = %d, want %d",
				iv,
				qp_in,
				got,
				want,
			)
		}
	}
}

@(test)
test_cabac_context_state_range :: proc(t: ^testing.T) {
	c: Cabac

	for st in ([]Slice_Type{.I, .P, .B}) {
		for qp in i32(0) ..= 51 {
			cabac_init_contexts(&c, qp, st, false)

			for i in 0 ..< CABAC_N_CONTEXTS {
				testing.expectf(
					t,
					c.state[i] <= 125,
					"slice %v qp %d ctx %d state %d",
					st,
					qp,
					i,
					c.state[i],
				)
			}
		}
	}
}

@(test)
test_cabac_init_bounds :: proc(t: ^testing.T) {
	c: Cabac

	testing.expect(t, !cabac_init(&c, []u8{0x01}, 0))
	testing.expect(t, !cabac_init(&c, []u8{0x01, 0x02}, 1))
	testing.expect(t, !cabac_init(&c, []u8{0x01, 0x02}, -1))
	testing.expect(t, cabac_init(&c, []u8{0x01, 0x02}, 0))
	testing.expect_value(t, c.cursor.range, u32(0x1fe))
}

@(test)
test_cabac_round_trip :: proc(t: ^testing.T) {
	for st in ([]Slice_Type{.I, .P, .B}) {
		for qp in ([]i32{0, 26, 51}) {
			e: Cabac_Ref_Encoder
			ref_encoder_init(&e, qp, st, false)
			defer ref_encoder_destroy(&e)

			for i in 0 ..< 512 {
				ref_encode_bin(&e, i % CABAC_N_CONTEXTS, u32((i * 17 + i / 7) & 1))
				ref_encode_bypass(&e, u32((i * 31) & 1))

				if i % 29 == 0 do ref_encode_terminate(&e, 0)
			}

			ref_encode_terminate(&e, 1)

			c: Cabac
			testing.expect(t, cabac_init(&c, ref_encoder_finish(&e), 0))
			cabac_init_contexts(&c, qp, st, false)

			for i in 0 ..< 512 {
				want := u32((i * 17 + i / 7) & 1)
				got := cabac_decode_bin(&c, i % CABAC_N_CONTEXTS)
				testing.expectf(
					t,
					got == want,
					"slice %v qp %d bin %d = %d, want %d",
					st,
					qp,
					i,
					got,
					want,
				)

				want = u32((i * 31) & 1)
				got = cabac_decode_bypass(&c)
				testing.expectf(
					t,
					got == want,
					"slice %v qp %d bypass %d = %d, want %d",
					st,
					qp,
					i,
					got,
					want,
				)

				if i % 29 == 0 {
					testing.expectf(
						t,
						cabac_decode_terminate(&c) == 0,
						"slice %v qp %d terminate %d",
						st,
						qp,
						i,
					)
				}
			}

			testing.expectf(
				t,
				cabac_decode_terminate(&c) == 1,
				"slice %v qp %d final terminator",
				st,
				qp,
			)
		}
	}
}

@(test)
test_cabac_all_initial_states :: proc(t: ^testing.T) {
	// Exercise both MPS polarities and every reachable probability state,
	// including long MPS runs, state-zero flips, and refill boundaries.
	for state in 0 ..< 126 {
		e: Cabac_Ref_Encoder
		ref_encoder_init(&e, 26, .I, false)
		e.p_state[0], e.val_mps[0] = u8(state >> 1), u8(state & 1)
		bins: [512]u32
		seed := u32(1 + state)
		for i in 0 ..< len(bins) {
			seed = seed * 1664525 + 1013904223
			bins[i] = i < 128 ? u32(state & 1) : seed >> 31
			ref_encode_bin(&e, 0, bins[i])
		}
		ref_encode_terminate(&e, 1)
		c: Cabac
		testing.expect(t, cabac_init(&c, ref_encoder_finish(&e), 0))
		c.state[0] = u8(state)
		for bin, i in bins {
			if !testing.expectf(
				t,
				cabac_decode_bin(&c, 0) == bin,
				"initial state %d, bin %d",
				state,
				i,
			) {
				ref_encoder_destroy(&e)
				return
			}
		}
		testing.expect(t, cabac_decode_terminate(&c) == 1)
		ref_encoder_destroy(&e)
	}
}

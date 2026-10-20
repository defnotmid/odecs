package h265_decoder

import "core:math/bits"

// ---------------------------------------------------------------------------
// CABAC arithmetic decoding engine (9.3.4.3), ported from gen2brain/h265
// hevc/cabac.go (MIT); oxideav-h265 src/cabac.rs and src/ctx_init.rs are the
// per-file cross-references.
//
// The context state is one byte per context, `2 * pStateIdx + valMps`, the
// representation the reference decoder uses. Initialization is Table 9-5.
// ---------------------------------------------------------------------------

CABAC_BITS :: 16
CABAC_MASK :: u32(1 << CABAC_BITS - 1)

// Offsets of each syntax element's first context, 9.3.2.2.
ctxSAOMergeFlag :: 0
ctxSAOTypeIDX :: 1
ctxSplitCodingUnitFlag :: 2
ctxCUTransquantBypassFlag :: 5
ctxSkipFlag :: 6
ctxCUQPDelta :: 9
ctxPredModeFlag :: 12
ctxPartMode :: 13
ctxPrevIntraLumaPredFlag :: 17
ctxIntraChromaPredMode :: 18
ctxMergeFlag :: 20
ctxMergeIDX :: 21
ctxInterPredIDC :: 22
ctxRefIDXL0 :: 27
ctxRefIDXL1 :: 29
ctxAbsMVDGreater0Flag :: 31
ctxAbsMVDGreater1Flag :: 33
ctxMVPLXFlag :: 35
ctxNoResidualDataFlag :: 36
ctxSplitTransformFlag :: 37
ctxCBFLuma :: 40
ctxCBFCBCR :: 42
ctxTransformSkipFlag :: 47
ctxExplicitRDPCMFlag :: 49
ctxExplicitRDPCMDirFlag :: 51
ctxLastSignificantCoeffXPrefix :: 53
ctxLastSignificantCoeffYPrefix :: 71
ctxSignificantCoeffGroupFlag :: 89
ctxSignificantCoeffFlag :: 93
ctxCoeffAbsLevelGreater1Flag :: 137
ctxCoeffAbsLevelGreater2Flag :: 161
ctxLog2ResScaleAbs :: 167
ctxResScaleSignFlag :: 175
ctxCUChromaQPOffsetFlag :: 177
ctxCUChromaQPOffsetIDX :: 178

Cabac :: struct {
	low:   u32,
	rng:   u32,
	data:  []u8,
	pos:   int,
	state: [CABAC_N_CONTEXTS]u8,
}

// cabac_init positions the engine at the first byte of slice_segment_data.
cabac_init :: proc(c: ^Cabac, data: []u8, off: int) -> bool {
	if off < 0 || off + 2 > len(data) do return false

	c.data = data
	c.low = u32(data[off]) << 18 + u32(data[off + 1]) << 10 + 1 << 9
	c.rng = 0x1fe
	c.pos = off + 2

	return true
}

cabac_init_type :: proc(slice: Slice_Type, cabac_init: bool) -> int {
	n := 2 - int(slice)
	if cabac_init && slice != .I do n ~= 3

	return n
}

// cabac_init_state is 9.3.2.2 Table 9-5: the probability state for one
// initValue at the slice QP.
cabac_init_state :: proc(v: u8, qp_in: i32) -> u8 {
	m := i32(v >> 4) * 5 - 45
	n := i32(v & 0x0f) << 3 - 16

	qp := qp_in
	if qp < 0 {
		qp = 0
	} else if qp > 51 {
		qp = 51
	}

	s := 2 * (((m * qp) >> 4) + n) - 127
	s = s ~ (s >> 31)

	if s > 124 do s = 124 + (s & 1)

	return u8(s)
}

cabac_init_contexts :: proc(c: ^Cabac, qp: i32, slice: Slice_Type, cabac_init: bool) {
	row := &CABAC_INIT_VALUES[cabac_init_type(slice, cabac_init)]

	for i in 0 ..< CABAC_N_CONTEXTS {
		c.state[i] = cabac_init_state(row[i], qp)
	}
}

@(private)
cabac_byte_at :: #force_inline proc(c: ^Cabac, i: int) -> u32 #no_bounds_check {
	if i < len(c.data) do return u32(c.data[i])

	return 0
}

@(private)
cabac_refill :: proc(c: ^Cabac) #no_bounds_check {
	c.low += cabac_byte_at(c, c.pos) << 9 + cabac_byte_at(c, c.pos + 1) << 1 - CABAC_MASK
	c.pos += 2
}

// cabac_refill_shifted refills with the incoming bytes aligned to the first
// clear bit of `low`, which is how the reference keeps its 16-bit window.
@(private)
cabac_refill_shifted :: proc(c: ^Cabac) #no_bounds_check {
	i := uint(bits.trailing_zeros(c.low) - CABAC_BITS)
	x := cabac_byte_at(c, c.pos) << 9 + cabac_byte_at(c, c.pos + 1) << 1 - CABAC_MASK
	c.low += x << i
	c.pos += 2
}

@(private)
// cabac_norm_shift is how far the range must shift back into [256, 512). It is
// 9 - bit_length(r), which count_leading_zeros answers in one branchless
// instruction: bit_length(r) is 32 - clz(r), so the shift is clz(r) - 23 (and
// for r == 0 both forms give 9).
cabac_norm_shift :: #force_inline proc(r: u32) -> uint #no_bounds_check {
	return uint(bits.leading_zeros(r) - 23)
}

// Pack the range and both next states into one table load per decision.
@(private)
CABAC_DECISIONS: [4][128]u32

@(private, init)
cabac_decisions_init :: proc "contextless" () {
	for range in 0 ..< 4 {
		for state in 0 ..< 128 {
			index, mps := state >> 1, state & 1
			next_mps := 2 * (index + (index < 62 ? 1 : 0)) + mps
			next_lps := 2 * int(TRANS_IDX_LPS[index]) + (mps ~ (index == 0 ? 1 : 0))
			CABAC_DECISIONS[range][state] =
				u32(RANGE_TAB_LPS[index][range]) | u32(next_mps) << 8 | u32(next_lps) << 16
		}
	}
}

// cabac_decode_bin is DecodeDecision (9.3.4.3.2) against context `ctx`.
//
// The LPS/MPS split is the one genuinely unpredictable branch in the engine, so
// following ffmpeg's branchless get_cabac (x86/cabac.h, BRANCHLESS_GET_CABAC)
// both outcomes are computed and a mask selects the winner. The engine front end
// then runs straight-line; only the (rare, predictable) refill stays a branch.
cabac_decode_bin :: #force_inline proc(c: ^Cabac, ctx: int) -> u32 #no_bounds_check {
	s := c.state[ctx]
	decision := CABAC_DECISIONS[(c.rng >> 6) & 3][s]
	lps := decision & 255

	r_mps := c.rng - lps
	low_lps := r_mps << 17

	mask := c.low > low_lps ? ~u32(0) : u32(0)

	c.rng = (lps & mask) | (r_mps & ~mask)
	c.low -= low_lps & mask

	lps_bin := mask & 1
	c.state[ctx] = u8(decision >> (8 + lps_bin * 8))
	bin := u32(s & 1) ~ lps_bin

	shift := cabac_norm_shift(c.rng)
	c.rng <<= shift
	c.low <<= shift

	if c.low & CABAC_MASK == 0 do cabac_refill_shifted(c)

	return bin
}

// cabac_decode_bypass is DecodeBypass (9.3.4.3.4). The comparison is random, so
// it is a mask select rather than a branch.
cabac_decode_bypass :: proc(c: ^Cabac) -> u32 #no_bounds_check {
	c.low += c.low
	if c.low & CABAC_MASK == 0 do cabac_refill(c)

	r := c.rng << 17
	ge := c.low >= r

	c.low -= r & (ge ? ~u32(0) : u32(0))

	return ge ? 1 : 0
}

// cabac_decode_bypass_bits accumulates `n` bypass bins MSB-first.
cabac_decode_bypass_bits :: proc(c: ^Cabac, n: int) -> u32 #no_bounds_check {
	v: u32

	for _ in 0 ..< n {
		v = v << 1 | cabac_decode_bypass(c)
	}

	return v
}

// cabac_decode_terminate is DecodeTerminate (9.3.4.3.5). Non-zero means the
// arithmetic coding is finished.
cabac_decode_terminate :: proc(c: ^Cabac) -> u32 #no_bounds_check {
	c.rng -= 2

	if c.low >= c.rng << 17 do return 1

	if c.rng < 256 {
		c.rng <<= 1
		c.low <<= 1

		if c.low & CABAC_MASK == 0 do cabac_refill(c)
	}

	return 0
}

// cabac_align_bypass is the alignment process before aligned bypass decoding
// (9.3.4.3.6): after it every bypass bin consumes one stream bit.
cabac_align_bypass :: proc(c: ^Cabac) {
	c.rng = 256
}

// cabac_pcm_offset is the byte position that pcm_sample_luma starts at,
// accounting for the bits still buffered in `low` (7.3.8.7).
cabac_pcm_offset :: proc(c: ^Cabac) -> int {
	n := c.pos

	if c.low & 1 != 0 do n -= 1
	if c.low & 0x1ff != 0 do n -= 1

	return n
}

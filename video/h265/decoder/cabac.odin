package h265_decoder

import common "../../../common"

// ---------------------------------------------------------------------------
// CABAC arithmetic decoding engine (9.3.4.3), ported from gen2brain/h265
// hevc/cabac.go (MIT); oxideav-h265 src/cabac.rs and src/ctx_init.rs are the
// per-file cross-references.
//
// The context state is one byte per context, `2 * pStateIdx + valMps`, the
// representation the reference decoder uses. Initialization is Table 9-5.
// ---------------------------------------------------------------------------

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

// The arithmetic decoding engine is common's, shared with H.264, which
// defines the same engine and tables.
Cabac :: struct {
	cursor: common.Cabac_Cursor,
	state:  [CABAC_N_CONTEXTS]u8,
}

// cabac_init positions the engine at the first byte of slice_segment_data.
cabac_init :: proc(c: ^Cabac, data: []u8, off: int) -> bool {
	if off < 0 || off + 2 > len(data) do return false
	common.cabac_start(&c.cursor, data, off * 8)
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

// A transform block's view of the engine: the cursor copied into a local for
// the block, kept in registers across its bins as H.264's residual loops keep
// theirs, and the slice's contexts. decode_residual writes the cursor back.
Cabac_Bins :: struct {
	cursor: common.Cabac_Cursor,
	state:  ^[CABAC_N_CONTEXTS]u8,
}

// cabac_decode_bin is DecodeDecision (9.3.4.3.2) against context `ctx`.
cabac_decode_bin :: proc {
	cabac_decode_bin_slice,
	cabac_decode_bin_block,
}

cabac_decode_bin_slice :: #force_inline proc(c: ^Cabac, ctx: int) -> u32 #no_bounds_check {
	return common.cabac_decision(&c.cursor, &c.state[ctx])
}

cabac_decode_bin_block :: #force_inline proc(c: ^Cabac_Bins, ctx: int) -> u32 #no_bounds_check {
	return common.cabac_decision(&c.cursor, &c.state[ctx])
}

// cabac_decode_bypass is DecodeBypass (9.3.4.3.4).
cabac_decode_bypass :: proc {
	cabac_decode_bypass_slice,
	cabac_decode_bypass_block,
}

cabac_decode_bypass_slice :: #force_inline proc(c: ^Cabac) -> u32 {return common.cabac_bypass(&c.cursor)}
cabac_decode_bypass_block :: #force_inline proc(c: ^Cabac_Bins) -> u32 {return common.cabac_bypass(&c.cursor)}

// cabac_decode_bypass_bits accumulates `n` bypass bins MSB-first.
cabac_decode_bypass_bits :: proc {
	cabac_decode_bypass_bits_slice,
	cabac_decode_bypass_bits_block,
}

cabac_decode_bypass_bits_slice :: proc(c: ^Cabac, n: int) -> u32 {return bypass_bits(&c.cursor, n)}
cabac_decode_bypass_bits_block :: #force_inline proc(c: ^Cabac_Bins, n: int) -> u32 {return bypass_bits(&c.cursor, n)}

@(private = "file")
bypass_bits :: #force_inline proc "contextless" (c: ^common.Cabac_Cursor, n: int) -> u32 {
	v: u32
	for _ in 0 ..< n do v = v << 1 | common.cabac_bypass(c)
	return v
}

// cabac_decode_terminate is DecodeTerminate (9.3.4.3.5). Non-zero means the
// arithmetic coding is finished.
cabac_decode_terminate :: proc(c: ^Cabac) -> u32 {
	return common.cabac_terminate(&c.cursor)
}

// cabac_align_bypass is the alignment process before aligned bypass decoding
// (9.3.4.3.6): after it every bypass bin consumes one stream bit.
cabac_align_bypass :: proc(c: ^Cabac) {
	c.cursor.range = 256
}

// cabac_pcm_offset is the byte position that pcm_sample_luma starts at: the
// first byte boundary after the bits the engine consumed (7.3.8.7).
cabac_pcm_offset :: proc(c: ^Cabac) -> int {
	return (common.cabac_consumed_bits(&c.cursor) + 7) >> 3
}

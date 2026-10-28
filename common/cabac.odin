package common

import "base:intrinsics"

// CABAC arithmetic decoding engine. H.264 (9.3.1.2, 9.3.3.2) and HEVC
// (9.3.2.5, 9.3.4.3) define the same engine with the same range and state
// transition tables; only how the contexts start differs, which stays with
// each codec. A context is one byte, pStateIdx << 1 | valMPS.
Cabac_Cursor :: struct {
	range:    u32, // codIRange, 9 bits
	buffered: u32, // look-ahead stream bits held below codIOffset in value
	value:    u64, // codIOffset in bits 48..56, then `buffered` look-ahead bits
	data:     []u8,
	pos:      int, // next byte of data to load; reads past the end are zero
}

// Window refills load 32 stream bits once fewer than 16 remain; a
// renormalization shifts at most 6 bits, so the window never runs dry.
CABAC_REFILL_BELOW :: 16

// Starts the engine at bit `bit_pos` of data (H.264 9.3.1.2, HEVC 9.3.2.5):
// codIOffset takes the next nine bits, the rest of the loaded window stays as
// look-ahead.
cabac_start :: proc "contextless" (c: ^Cabac_Cursor, data: []u8, bit_pos: int) {
	c^ = {
		range = 510,
		data  = data,
		pos   = bit_pos >> 3,
	}
	cabac_refill(c)
	// Bits before the start position leave the window.
	skip := u32(bit_pos & 7)
	c.value = (c.value << skip) & (1 << 48 - 1)
	c.buffered -= skip
	cabac_shift(c, 9)
}

// The stream bits the engine has consumed: where the bitstream continues
// after a terminating bin (before pcm_alignment_zero_bit or the trailing bits).
cabac_consumed_bits :: #force_inline proc "contextless" (c: ^Cabac_Cursor) -> int {
	return c.pos * 8 - int(c.buffered)
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
		word = u64(u32(intrinsics.unaligned_load((^u32be)(&c.data[c.pos]))))
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

// DecodeDecision with RenormD; the context byte is updated in place. The
// MPS/LPS outcome is data dependent, so it selects values rather than
// branching; RenormD's shift is zero while codIRange stays >= 256.
cabac_decision :: #force_inline proc "contextless" (c: ^Cabac_Cursor, ctx: ^u8) -> u32 #no_bounds_check {
	st := ctx^
	lps := u32(CABAC_LPS_RANGE[st][(c.range >> 6) & 3])
	mps_range := c.range - lps
	scaled := u64(mps_range) << 48
	is_lps := c.value >= scaled
	c.value -= is_lps ? scaled : 0
	c.range = is_lps ? lps : mps_range
	ctx^ = CABAC_NEXT[st][int(is_lps)]
	shift := u32(intrinsics.count_leading_zeros(c.range)) - 23
	c.range <<= shift
	cabac_shift(c, shift)
	return u32(st & 1) ~ u32(is_lps)
}

// DecodeBypass: one look-ahead bit joins codIOffset. The outcome is data
// dependent, so it selects rather than branches, as cabac_decision does.
cabac_bypass :: #force_inline proc "contextless" (c: ^Cabac_Cursor) -> u32 {
	cabac_shift(c, 1)
	scaled := u64(c.range) << 48
	one := c.value >= scaled
	c.value -= one ? scaled : 0
	return u32(one)
}

// DecodeTerminate: 1 ends the arithmetic coded data (no renormalization; the
// bitstream continues at cabac_consumed_bits).
cabac_terminate :: proc "contextless" (c: ^Cabac_Cursor) -> u32 {
	c.range -= 2
	if c.value >= u64(c.range) << 48 do return 1
	if c.range < 256 {
		shift := u32(intrinsics.count_leading_zeros(c.range)) - 23
		c.range <<= shift
		cabac_shift(c, shift)
	}
	return 0
}

// Context bytes index these directly: the LPS range per codIRange
// quantization, and the next byte after an MPS or an LPS bin (valMPS flips
// on an LPS at pStateIdx 0).
CABAC_LPS_RANGE: [128][4]u8
CABAC_NEXT: [128][2]u8 // [byte][bin was LPS]

@(init, private = "file")
build_cabac_tables :: proc "contextless" () {
	for st in 0 ..< 128 {
		state, mps := st >> 1, u8(st & 1)
		CABAC_LPS_RANGE[st] = RANGE_TAB_LPS[state]
		CABAC_NEXT[st][0] = TRANS_IDX[state][1] << 1 | mps
		CABAC_NEXT[st][1] = TRANS_IDX[state][0] << 1 | (state == 0 ? mps ~ 1 : mps)
	}
}

// rangeTabLPS[pStateIdx][qCodIRangeIdx] (H.264 Table 9-44, HEVC Table 9-52)
@(rodata)
RANGE_TAB_LPS := [64][4]u8 {
	{128, 176, 208, 240},
	{128, 167, 197, 227},
	{128, 158, 187, 216},
	{123, 150, 178, 205},
	{116, 142, 169, 195},
	{111, 135, 160, 185},
	{105, 128, 152, 175},
	{100, 122, 144, 166},
	{95, 116, 137, 158},
	{90, 110, 130, 150},
	{85, 104, 123, 142},
	{81, 99, 117, 135},
	{77, 94, 111, 128},
	{73, 89, 105, 122},
	{69, 85, 100, 116},
	{66, 80, 95, 110},
	{62, 76, 90, 104},
	{59, 72, 86, 99},
	{56, 69, 81, 94},
	{53, 65, 77, 89},
	{51, 62, 73, 85},
	{48, 59, 69, 80},
	{46, 56, 66, 76},
	{43, 53, 63, 72},
	{41, 50, 59, 69},
	{39, 48, 56, 65},
	{37, 45, 54, 62},
	{35, 43, 51, 59},
	{33, 41, 48, 56},
	{32, 39, 46, 53},
	{30, 37, 43, 50},
	{29, 35, 41, 48},
	{27, 33, 39, 45},
	{26, 31, 37, 43},
	{24, 30, 35, 41},
	{23, 28, 33, 39},
	{22, 27, 32, 37},
	{21, 26, 30, 35},
	{20, 24, 29, 33},
	{19, 23, 27, 31},
	{18, 22, 26, 30},
	{17, 21, 25, 28},
	{16, 20, 23, 27},
	{15, 19, 22, 25},
	{14, 18, 21, 24},
	{14, 17, 20, 23},
	{13, 16, 19, 22},
	{12, 15, 18, 21},
	{12, 14, 17, 20},
	{11, 14, 16, 19},
	{11, 13, 15, 18},
	{10, 12, 15, 17},
	{10, 12, 14, 16},
	{9, 11, 13, 15},
	{9, 11, 12, 14},
	{8, 10, 12, 14},
	{8, 9, 11, 13},
	{7, 9, 11, 12},
	{7, 9, 10, 12},
	{7, 8, 10, 11},
	{6, 8, 9, 11},
	{6, 7, 9, 10},
	{6, 7, 8, 9},
	{2, 2, 2, 2},
}

// {transIdxLPS, transIdxMPS}[pStateIdx] (H.264 Table 9-45, HEVC Table 9-53)
@(rodata)
TRANS_IDX := [64][2]u8 {
	{0, 1},
	{0, 2},
	{1, 3},
	{2, 4},
	{2, 5},
	{4, 6},
	{4, 7},
	{5, 8},
	{6, 9},
	{7, 10},
	{8, 11},
	{9, 12},
	{9, 13},
	{11, 14},
	{11, 15},
	{12, 16},
	{13, 17},
	{13, 18},
	{15, 19},
	{15, 20},
	{16, 21},
	{16, 22},
	{18, 23},
	{18, 24},
	{19, 25},
	{19, 26},
	{21, 27},
	{21, 28},
	{22, 29},
	{22, 30},
	{23, 31},
	{24, 32},
	{24, 33},
	{25, 34},
	{26, 35},
	{26, 36},
	{27, 37},
	{27, 38},
	{28, 39},
	{29, 40},
	{29, 41},
	{30, 42},
	{30, 43},
	{30, 44},
	{31, 45},
	{32, 46},
	{32, 47},
	{33, 48},
	{33, 49},
	{33, 50},
	{34, 51},
	{34, 52},
	{35, 53},
	{35, 54},
	{35, 55},
	{36, 56},
	{36, 57},
	{36, 58},
	{37, 59},
	{37, 60},
	{37, 61},
	{38, 62},
	{38, 62},
	{63, 63},
}

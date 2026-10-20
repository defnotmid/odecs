package vp9_decoder

import "base:intrinsics"
import "core:math/bits"

// Boolean (arithmetic) decoder, section 9.2. `value` holds the decoder's
// 8-bit window in its top byte followed by look-ahead bits; bytes past the
// end of the data read as zero.
@(private)
Bool_Decoder :: struct {
	data:  []u8,
	pos:   int,
	value: u64,
	bits:  int, // valid bits in value
	range: u32,
}

@(private)
init_bool :: proc(b: ^Bool_Decoder, data: []u8) -> bool {
	b^ = {data = data, range = 255}
	if len(data) < 1 do return false
	fill(b)
	return read_bool(b, 128) == 0 // the marker bit
}

// Refills load 32 stream bits once fewer than 16 remain, as the H.264 CABAC
// window does; a decision consumes at most 7, so the window never runs dry.
@(private)
fill :: #force_inline proc(b: ^Bool_Decoder) #no_bounds_check {
	word: u64
	if b.pos + 4 <= len(b.data) {
		word = u64(bits.from_be_u32(intrinsics.unaligned_load((^u32)(&b.data[b.pos]))))
	} else {
		for i in 0 ..< 4 {
			word <<= 8
			if b.pos + i < len(b.data) do word |= u64(b.data[b.pos + i])
		}
	}
	b.value |= word << uint(32 - b.bits)
	b.pos += 4
	b.bits += 32
}

@(private)
read_bool :: #force_inline proc(b: ^Bool_Decoder, prob: u8) -> int {
	if b.bits < 16 do fill(b)
	split := 1 + (((b.range - 1) * u32(prob)) >> 8)
	big := u64(split) << 56
	// The outcome is data dependent, so it selects values rather than branching.
	one := b.value >= big
	bit := int(one)
	b.range = one ? b.range - split : split
	b.value -= one ? big : 0
	shift := uint(intrinsics.count_leading_zeros(b.range) - 24)
	b.range <<= shift
	b.value <<= shift
	b.bits -= int(shift)
	return bit
}

@(private)
read_literal :: #force_inline proc(b: ^Bool_Decoder, n: int) -> int {
	x := 0
	for _ in 0 ..< n do x = x << 1 | read_bool(b, 128)
	return x
}

// Decodes a tree value with probs[node >> 1] for each node (section 9.3.3).
@(private)
read_tree :: #force_inline proc(b: ^Bool_Decoder, tree: []i8, probs: []u8) -> int {
	n := 0
	for {
		n = int(tree[n + read_bool(b, probs[n >> 1])])
		if n <= 0 do return -n
	}
}

// Whether the decoder read past its data (corrupt or truncated input).
@(private)
overrun :: #force_inline proc(b: ^Bool_Decoder) -> bool {
	return b.pos - b.bits / 8 > len(b.data) + 8
}

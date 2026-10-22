package vp9_encoder

import "base:intrinsics"

// The inverse of section 9.2's range subdivision. Bytes are emitted with
// carry propagation; the marker bit guarantees a preceding byte for carry.
@(private)
Bool_Writer :: struct {
	data: [dynamic]u8,
	low, range: u32,
	count: int,
	failed: bool, // an append failed; the data is incomplete
}

@(private)
start_bool :: proc(b: ^Bool_Writer) {
	clear(&b.data)
	b.low, b.range, b.count, b.failed = 0, 255, -24, false
	put_bool(b, 0, 128)
}

@(private)
put_bool_byte :: #force_no_inline proc(b: ^Bool_Writer, shift: int) #no_bounds_check {
	offset := shift - b.count
	if (b.low << uint(offset - 1)) & 0x80000000 != 0 {
		at := len(b.data) - 1
		for at >= 0 && b.data[at] == 255 {b.data[at] = 0; at -= 1}
		assert(at >= 0 || b.failed)
		if at >= 0 do b.data[at] += 1
	}
	if _, err := append(&b.data, u8(b.low >> uint(24 - offset))); err != nil do b.failed = true
	b.low <<= uint(offset)
	rem := b.count
	b.low &= 0xFFFFFF
	b.count -= 8
	b.low <<= uint(rem)
}

@(private)
put_bool :: #force_inline proc(b: ^Bool_Writer, bit: int, prob: u8) {
	split := 1 + ((b.range - 1) * u32(prob) >> 8)
	if bit == 0 {b.range = split} else {b.low += split; b.range -= split}
	shift := int(intrinsics.count_leading_zeros(b.range) - 24)
	b.range <<= uint(shift)
	b.count += shift
	if b.count >= 0 {
		put_bool_byte(b, shift)
		return
	}
	b.low <<= uint(shift)
}

@(private)
put_literal :: proc(b: ^Bool_Writer, value, bits: int) {
	for i := bits - 1; i >= 0; i -= 1 do put_bool(b, value >> uint(i) & 1, 128)
}

@(private)
finish_bool :: proc(b: ^Bool_Writer) {
	for _ in 0 ..< 32 do put_bool(b, 0, 128)
	// A frame whose last byte looks like a superframe index needs padding.
	if len(b.data) > 0 && b.data[len(b.data) - 1] & 0xE0 == 0xC0 {
		if _, err := append(&b.data, 0); err != nil do b.failed = true
	}
}

@(private)
tree_path :: proc(tree: []i8, node, symbol: int) -> (bits, count: int, found: bool) {
	for bit in 0 ..< 2 {
		child := int(tree[node + bit])
		if child <= 0 {
			if -child == symbol do return bit, 1, true
		} else {
			path, n, ok := tree_path(tree, child, symbol)
			if ok do return bit << uint(n) | path, n + 1, true
		}
	}
	return 0, 0, false
}

@(private)
put_tree :: proc(b: ^Bool_Writer, tree: []i8, probs: []u8, symbol: int, start: int = 0, prob_offset: int = 0) {
	path, n, ok := tree_path(tree, start, symbol)
	assert(ok)
	node := start
	for i := n - 1; i >= 0; i -= 1 {
		bit := path >> uint(i) & 1
		put_bool(b, bit, probs[(node >> 1) - prob_offset])
		node = int(tree[node + bit])
	}
}

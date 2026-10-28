package vp9_encoder

import vp9 ".."
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
	b.low += bit != 0 ? split : 0
	b.range = bit != 0 ? b.range - split : split
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

// One symbol's path from the root of a VP9 binary tree: the bits and the
// probability indices (node >> 1) visited along the way. Built once at init
// so coding and rate estimation walk flat steps without searching the tree.
@(private)
Tree_Code :: struct {
	bits:  u16,
	count: u8,
	nodes: [9]u8,
}

@(private)
PARTITION_CODES: [vp9.PARTITION_TYPES]Tree_Code
@(private)
INTRA_MODE_CODES: [vp9.INTRA_MODES]Tree_Code
@(private)
INTER_MODE_CODES: [vp9.INTER_MODES]Tree_Code
@(private)
INTERP_FILTER_CODES: [vp9.SWITCHABLE_FILTERS]Tree_Code
@(private)
TX_SIZE_CODES: [vp9.TX_SIZES][vp9.TX_SIZES]Tree_Code
@(private)
MV_JOINT_CODES: [vp9.MV_JOINTS]Tree_Code
@(private)
MV_CLASS_CODES: [vp9.MV_CLASSES]Tree_Code
@(private)
MV_FR_CODES: [vp9.MV_FR_SIZE]Tree_Code
@(private)
TOKEN_PARETO_CODES: [11]Tree_Code
@(private)
SEG_CODES: [vp9.MAX_SEGMENTS]Tree_Code

@(private, init)
init_tree_codes :: proc "contextless" () {
	build_tree_codes(PARTITION_CODES[:], vp9.PARTITION_TREE[:], 0, {}, 0)
	build_tree_codes(INTRA_MODE_CODES[:], vp9.INTRA_MODE_TREE[:], 0, {}, 0)
	build_tree_codes(INTER_MODE_CODES[:], vp9.INTER_MODE_TREE[:], 0, {}, 0)
	build_tree_codes(INTERP_FILTER_CODES[:], vp9.INTERP_FILTER_TREE[:], 0, {}, 0)
	build_tree_codes(TX_SIZE_CODES[vp9.TX_8X8][:], vp9.TX_SIZE_8_TREE[:], 0, {}, 0)
	build_tree_codes(TX_SIZE_CODES[vp9.TX_16X16][:], vp9.TX_SIZE_16_TREE[:], 0, {}, 0)
	build_tree_codes(TX_SIZE_CODES[vp9.TX_32X32][:], vp9.TX_SIZE_32_TREE[:], 0, {}, 0)
	build_tree_codes(MV_JOINT_CODES[:], vp9.MV_JOINT_TREE[:], 0, {}, 0)
	build_tree_codes(MV_CLASS_CODES[:], vp9.MV_CLASS_TREE[:], 0, {}, 0)
	build_tree_codes(MV_FR_CODES[:], vp9.MV_FR_TREE[:], 0, {}, 0)
	build_tree_codes(TOKEN_PARETO_CODES[:], vp9.TOKEN_TREE[:], 4, {}, 2)
	build_tree_codes(SEG_CODES[:], vp9.SEGMENT_TREE[:], 0, {}, 0)
}

@(private)
build_tree_codes :: proc "contextless" (out: []Tree_Code, tree: []i8, node: int, code: Tree_Code, base_node: int) {
	for bit in 0 ..< 2 {
		next := code
		next.bits |= u16(bit) << uint(next.count)
		next.nodes[next.count] = u8((node >> 1) - base_node)
		next.count += 1
		child := int(tree[node + bit])
		if child <= 0 {
			out[-child] = next
		} else {
			build_tree_codes(out, tree, child, next, base_node)
		}
	}
}

package h264

macroblock_is_available :: #force_inline proc(grid: ^Macroblock_Grid, idx: int) -> bool {
	// The band is immutable while slices run. Reject it before touching the
	// mutable tag; the tag still excludes not-yet-coded records inside a band.
	if idx < 0 ||
	   idx < grid.first_macroblock ||
	   (grid.end_macroblock != 0 && idx >= grid.end_macroblock) ||
	   idx >= len(grid.macroblocks) {
		return false
	}
	return grid.macroblocks[idx].slice_index == grid.slice_index
}

left_macroblock :: #force_inline proc(grid: ^Macroblock_Grid, macroblock_index: int) -> int {
	return(
		macroblock_index % grid.macroblock_columns > 0 && macroblock_is_available(grid, macroblock_index - 1) ? macroblock_index - 1 : -1 \
	)
}

top_macroblock :: #force_inline proc(grid: ^Macroblock_Grid, macroblock_index: int) -> int {
	return(
		macroblock_is_available(grid, macroblock_index - grid.macroblock_columns) ? macroblock_index - grid.macroblock_columns : -1 \
	)
}


// Partition layout of a macroblock type in 4x4 units: first block index, width, height
Partition :: struct {
	block:  int,
	width:  int,
	height: int,
}

macroblock_partitions :: proc(type: Macroblock_Type) -> []Partition {
	@(static) p16x16 := []Partition{{0, 4, 4}}
	@(static) p16x8 := []Partition{{0, 4, 2}, {8, 4, 2}}
	@(static) p8x16 := []Partition{{0, 2, 4}, {4, 2, 4}}
	#partial switch type {
	case .P_L0_L0_16x8, .B_16x8:
		return p16x8
	case .P_L0_L0_8x16, .B_8x16:
		return p8x16
	}
	return p16x16
}

// Sub-partitions of an 8x8 block by sub_mb_type shape (0: 8x8, 1: 8x4, 2: 4x8, 3: 4x4), relative block offsets
sub_partitions :: proc(shape: Subpartition_Shape) -> []Partition {
	@(static) s8x8 := []Partition{{0, 2, 2}}
	@(static) s8x4 := []Partition{{0, 2, 1}, {2, 2, 1}}
	@(static) s4x8 := []Partition{{0, 1, 2}, {1, 1, 2}}
	@(static) s4x4 := []Partition{{0, 1, 1}, {1, 1, 1}, {2, 1, 1}, {3, 1, 1}}
	switch shape {
	case .Block_8x8:
		return s8x8
	case .Block_8x4:
		return s8x4
	case .Block_4x8:
		return s4x8
	case .Block_4x4:
		return s4x4
	}
	return s8x8
}

// Store |mvd| per 4x4 block of a partition for CABAC mvd context derivation (9.3.3.1.1.7).
store_mvd :: proc(
	macroblock: #soa^#soa[]Macroblock,
	list: int,
	part: Partition,
	motion_differences: [2]$I,
) {
	bx, by := subblock_to_xy(part.block)
	value := [2]u8 {
		u8(min(abs(int(motion_differences[0])), 255)),
		u8(min(abs(int(motion_differences[1])), 255)),
	}
	for y in 0 ..< part.height do for x in 0 ..< part.width {
		macroblock.motion_differences[list][xy_to_subblock(bx + x, by + y)] = value
	}
}

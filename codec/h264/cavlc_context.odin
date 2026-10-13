package h264

// nC for a luma or chroma AC block from the neighbouring blocks' coefficient
// counts (9.2.1). `block` is the 4x4 index in decoding order (luma) or
// plane * 4 + raster index (chroma, with `chroma` set). A caller that has
// already resolved the macroblock's left and top neighbours (-1 when
// unavailable) passes them; otherwise they are resolved here.
cavlc_neighbour_coefficient_count :: proc {
	cavlc_neighbour_coefficient_count_resolving,
	cavlc_neighbour_coefficient_count_resolved,
}

cavlc_neighbour_coefficient_count_resolving :: proc(
	grid: ^Macroblock_Grid,
	macroblock_index: int,
	block: int,
	chroma: bool,
) -> i8 {
	return cavlc_neighbour_coefficient_count_resolved(
		grid,
		macroblock_index,
		left_macroblock(grid, macroblock_index),
		top_macroblock(grid, macroblock_index),
		block,
		chroma,
	)
}

cavlc_neighbour_coefficient_count_resolved :: proc(
	grid: ^Macroblock_Grid,
	macroblock_index, left, top: int,
	block: int,
	chroma: bool,
) -> i8 #no_bounds_check {
	macroblock := &grid.macroblocks[macroblock_index]
	// Coefficient count of a 4x4 block of a neighbouring macroblock, -1 if unusable
	neighbour_count :: #force_inline proc(
		grid: ^Macroblock_Grid,
		idx: int,
		nzc_index: int,
	) -> int #no_bounds_check {
		if idx < 0 do return -1
		neighbour := &grid.macroblocks[idx]
		if neighbour.type == .I_PCM do return 16
		return int(neighbour.nonzero_coefficient_counts[nzc_index])
	}
	na, nb: int
	if chroma {
		plane, index := block / 4, block % 4
		bx, by := index & 1, index >> 1
		base := 16 + plane * 4
		na =
			bx > 0 ? int(macroblock.nonzero_coefficient_counts[base + by * 2]) : neighbour_count(grid, left, base + by * 2 + 1)
		nb =
			by > 0 ? int(macroblock.nonzero_coefficient_counts[base + bx]) : neighbour_count(grid, top, base + 2 + bx)
	} else {
		bx, by := subblock_to_xy(block)
		na =
			bx > 0 ? int(macroblock.nonzero_coefficient_counts[xy_to_subblock(bx - 1, by)]) : neighbour_count(grid, left, xy_to_subblock(3, by))
		nb =
			by > 0 ? int(macroblock.nonzero_coefficient_counts[xy_to_subblock(bx, by - 1)]) : neighbour_count(grid, top, xy_to_subblock(bx, 3))
	}
	switch {
	case na >= 0 && nb >= 0:
		return i8((na + nb + 1) >> 1)
	case na >= 0:
		return i8(na)
	case nb >= 0:
		return i8(nb)
	}
	return 0
}

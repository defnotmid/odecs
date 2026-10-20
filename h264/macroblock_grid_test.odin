package h264

import "core:testing"

@(test)
test_macroblock_band_precedes_mutable_slice_tags :: proc(t: ^testing.T) {
	macroblocks := make(#soa[]Macroblock, 12)
	defer delete(macroblocks)
	// Matching outside tags must never grant availability across either edge.
	for i in 0 ..< len(macroblocks) do macroblocks[i].slice_index = 7
	grid := Macroblock_Grid {
		macroblocks        = macroblocks,
		macroblock_columns = 4,
		slice_index        = 7,
		first_macroblock   = 4,
		end_macroblock     = 8,
	}
	for i in 0 ..< 4 do testing.expect(t, !macroblock_is_available(&grid, i))
	for i in 4 ..< 8 do testing.expect(t, macroblock_is_available(&grid, i))
	for i in 8 ..< 12 do testing.expect(t, !macroblock_is_available(&grid, i))
	testing.expect(t, !macroblock_is_available(&grid, -1))
	testing.expect(t, !macroblock_is_available(&grid, max(int)))
	// A band is only an ownership bound, not evidence that its records are coded.
	macroblocks[6].slice_index = 0xffff
	testing.expect(t, !macroblock_is_available(&grid, 6))
	macroblocks[6].slice_index = 8
	testing.expect(t, !macroblock_is_available(&grid, 6))
	macroblocks[6].slice_index = 7
	testing.expect(t, macroblock_is_available(&grid, 6))
	// Zero bounds retain the decoder's full-grid, per-record tag behavior.
	full := Macroblock_Grid {
		macroblocks        = macroblocks,
		macroblock_columns = 4,
		slice_index        = 7,
	}
	for i in 0 ..< len(macroblocks) do testing.expect(t, macroblock_is_available(&full, i))
	macroblocks[1].slice_index = 0xffff
	testing.expect(t, !macroblock_is_available(&full, 1))
	testing.expect_value(t, left_macroblock(&full, 4), -1) // picture row boundary
	testing.expect_value(t, top_macroblock(&full, 0), -1)
	testing.expect_value(t, left_macroblock(&full, 5), 4)
	testing.expect_value(t, top_macroblock(&full, 4), 0)
	testing.expect(t, !macroblock_is_available(&full, len(macroblocks)))
}

@(test)
test_macroblock_band_queries_require_no_metadata_storage :: proc(t: ^testing.T) {
	// No fake length or pointer: the grid has empty backing storage. These
	// queries are rejected by the immutable band before any tag can be read.
	grid := Macroblock_Grid {
		macroblock_columns = 4,
		slice_index        = 7,
		first_macroblock   = 4,
		end_macroblock     = 8,
	}
	for i in ([8]int{-1, 0, 1, 3, 8, 9, 12, max(int)}) {
		testing.expect(t, !macroblock_is_available(&grid, i))
	}
	testing.expect_value(t, left_macroblock(&grid, 4), -1)
	testing.expect_value(t, top_macroblock(&grid, 4), -1)
	// A first partition has no internal neighbours to read; all external
	// candidates are outside this band. nC requires a real current record,
	// so its storage/read behavior is covered by the populated-grid test below.
	a, b, c := partition_neighbours(&grid, 4, 0, 0, 4)
	testing.expect(t, !a.avail && !b.avail && !c.avail)
	testing.expect_value(t, predict_motion_vector(&grid, 4, 0, 0, 4, 4, 0), ([2]i16{0, 0}))
	testing.expect_value(t, predict_skip_motion_vector(&grid, 4), ([2]i16{0, 0}))
	// The full-grid default also safely rejects missing storage.
	full := Macroblock_Grid {
		macroblock_columns = 4,
		slice_index        = 7,
	}
	testing.expect(t, !macroblock_is_available(&full, 0))
}

@(private)
set_grid_test_motion :: proc(macroblocks: #soa[]Macroblock, index: int, motion: [2]i16) {
	for list in 0 ..< 2 {
		for block in 0 ..< 16 do macroblocks[index].motion_vectors[list][block] = motion
		for partition in 0 ..< 4 do macroblocks[index].reference_indices[list][partition] = i8(list)
	}
}

@(test)
test_macroblock_band_nC_and_motion_prediction :: proc(t: ^testing.T) {
	macroblocks := make(#soa[]Macroblock, 12)
	defer delete(macroblocks)
	for i in 0 ..< len(macroblocks) {
		macroblocks[i].slice_index = 7
		macroblocks[i].type = .P_L0_16x16
		for block in 0 ..< 24 do macroblocks[i].nonzero_coefficient_counts[block] = 15
	}
	for block in 0 ..< 24 {
		macroblocks[4].nonzero_coefficient_counts[block] = 3
		macroblocks[5].nonzero_coefficient_counts[block] = 7
	}
	set_grid_test_motion(macroblocks, 0, {4, -12})
	set_grid_test_motion(macroblocks, 1, {40, 16})
	set_grid_test_motion(macroblocks, 2, {80, 32})
	set_grid_test_motion(macroblocks, 4, {12, -8})
	grid := Macroblock_Grid {
		macroblocks        = macroblocks,
		macroblock_columns = 4,
		slice_index        = 7,
		first_macroblock   = 4,
		end_macroblock     = 8,
	}
	// Index 5 has an in-band left neighbour but top/top-right/top-left
	// matching records in another band. Luma and both chroma planes use left
	// alone, while internal already-coded subblocks remain available.
	testing.expect_value(t, left_macroblock(&grid, 5), 4)
	testing.expect_value(t, top_macroblock(&grid, 5), -1)
	testing.expect_value(t, cavlc_neighbour_coefficient_count(&grid, 5, 0, false), i8(3))
	testing.expect_value(t, cavlc_neighbour_coefficient_count(&grid, 5, 1, false), i8(7))
	testing.expect_value(t, cavlc_neighbour_coefficient_count(&grid, 5, 2, false), i8(5))
	for plane in 0 ..< 2 {
		testing.expect_value(
			t,
			cavlc_neighbour_coefficient_count(&grid, 5, plane * 4, true),
			i8(3),
		)
		testing.expect_value(
			t,
			cavlc_neighbour_coefficient_count(&grid, 5, plane * 4 + 1, true),
			i8(7),
		)
		testing.expect_value(
			t,
			cavlc_neighbour_coefficient_count(&grid, 5, plane * 4 + 2, true),
			i8(5),
		)
	}
	for list in 0 ..< 2 {
		a, b, c := partition_neighbours(&grid, 5, list, 0, 4)
		testing.expect(t, a.avail && !b.avail && !c.avail)
		testing.expect_value(t, a.mv, ([2]i16{12, -8}))
		testing.expect_value(
			t,
			predict_motion_vector(&grid, 5, list, 0, 4, 4, i8(list)),
			([2]i16{12, -8}),
		)
	}
	testing.expect_value(t, predict_skip_motion_vector(&grid, 5), ([2]i16{0, 0}))
	// The same records in a full decoder grid still participate in nC and
	// motion prediction. A missing C must continue to fall back to D.
	full := Macroblock_Grid {
		macroblocks        = macroblocks,
		macroblock_columns = 4,
		slice_index        = 7,
	}
	testing.expect_value(t, cavlc_neighbour_coefficient_count(&full, 5, 0, false), i8(9))
	for list in 0 ..< 2 {
		testing.expect_value(
			t,
			predict_motion_vector(&full, 5, list, 0, 4, 4, i8(list)),
			([2]i16{40, 16}),
		)
	}
	macroblocks[2].slice_index = 0xffff
	a, b, c := partition_neighbours(&full, 5, 0, 0, 4)
	testing.expect(t, a.avail && b.avail && c.avail)
	testing.expect_value(t, c.mv, ([2]i16{4, -12}))
	testing.expect_value(t, predict_motion_vector(&full, 5, 0, 0, 4, 4, 0), ([2]i16{12, -8}))
	macroblocks[1].type = .I_PCM
	testing.expect_value(t, cavlc_neighbour_coefficient_count(&full, 5, 0, false), i8(10))
	testing.expect_value(t, cavlc_neighbour_coefficient_count(&grid, 5, 0, false), i8(3))
	// Not-yet-coded records inside the band remain unavailable to consumers.
	macroblocks[4].slice_index = 0xffff
	testing.expect_value(t, cavlc_neighbour_coefficient_count(&grid, 5, 0, false), i8(0))
	a, b, c = partition_neighbours(&grid, 5, 0, 0, 4)
	testing.expect(t, !a.avail && !b.avail && !c.avail)
	testing.expect_value(t, predict_motion_vector(&grid, 5, 0, 0, 4, 4, 0), ([2]i16{0, 0}))
}

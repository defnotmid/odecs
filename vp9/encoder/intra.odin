package vp9_encoder

import vp9 ".."

@(private)
choose_intra :: proc(t: ^Tile, r, c, size: int) -> int {
	e := t.e
	n := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size]) * 8
	tx := int(vp9.MAX_TXSIZE_LOOKUP[size])
	mode := vp9.DC_PRED
	best := max(i64)
	x, y := c * 8, r * 8
	edges := vp9.Intra_Edges{have_left = c > t.first_col, have_above = r > 0, max_x = e.mi_cols * 8 - 1, max_y = e.mi_rows * 8 - 1}
	for candidate in ([4]int{vp9.DC_PRED, vp9.V_PRED, vp9.H_PRED, vp9.TM_PRED}) {
		vp9.predict_intra(e.planes[0], e.strides[0], x, y, tx, candidate, edges, 8)
		cost := i64(block_sad(n, &e.source[0][y * e.source_strides[0] + x], e.source_strides[0], &e.planes[0][y * e.strides[0] + x], e.strides[0]))
		if cost < best {best, mode = cost, candidate}
	}
	return mode
}

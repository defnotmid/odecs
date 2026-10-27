package vp9_encoder

import vp9 ".."
import "base:intrinsics"
import "core:simd"

@(private)
choose_intra :: proc(t: ^Tile, r, c, size, tx: int) -> int #no_bounds_check {
	U4 :: #simd[4]u8
	U16 :: #simd[4]u16
	e := t.e
	n := int(vp9.NUM_8X8_BLOCKS_WIDE_LOOKUP[size]) * 8
	mode := vp9.DC_PRED
	best := max(i64)
	x, y := c * 8, r * 8
	max_x, max_y := e.mi_cols * 8, e.mi_rows * 8
	above := r > 0 ? int(t.above_context[c].y_mode) : vp9.DC_PRED
	left := c > t.first_col ? int(t.left_context[r & 7].y_mode) : vp9.DC_PRED
	q := i64(max(4, int(vp9.ac_q(8, e.config.base_q_idx))))
	frame, stride := e.planes[0], e.strides[0]
	source, s_stride := e.source[0], e.source_strides[0]
	for candidate in ([4]int{vp9.DC_PRED, vp9.V_PRED, vp9.H_PRED, vp9.TM_PRED}) {
		cost := (candidate == above || candidate == left) ? i64(0) : q / 4
		if tx == vp9.TX_4X4 {
			total: U16 = 0
			for dy := 0; dy < n; dy += 4 {
				for dx := 0; dx < n; dx += 4 {
					sx, sy := x + dx, y + dy
					if sx >= max_x || sy >= max_y do continue
					edges := vp9.Intra_Edges{have_left = c > t.first_col || dx > 0, have_above = r > 0 || dy > 0, not_on_right = dx + 4 < n, max_x = max_x - 1, max_y = max_y - 1}
					vp9.predict_intra(frame, stride, sx, sy, vp9.TX_4X4, candidate, edges, 8)
					for yy in 0 ..< 4 {
						sv := intrinsics.unaligned_load((^U4)(&source[(sy + yy) * s_stride + sx]))
						pv := intrinsics.unaligned_load((^U4)(&frame[(sy + yy) * stride + sx]))
						total += U16(simd.max(sv, pv) - simd.min(sv, pv))
						intrinsics.unaligned_store((^U4)(&frame[(sy + yy) * stride + sx]), sv)
					}
				}
			}
			cost += i64(simd.reduce_add_ordered((#simd[4]u32)(total)))
		} else {
			edges := vp9.Intra_Edges{have_left = c > t.first_col, have_above = r > 0, max_x = max_x - 1, max_y = max_y - 1}
			vp9.predict_intra(frame, stride, x, y, tx, candidate, edges, 8)
			cost += i64(block_sad(n, &source[y * s_stride + x], s_stride, &frame[y * stride + x], stride))
		}
		if cost < best {best, mode = cost, candidate}
	}
	return mode
}

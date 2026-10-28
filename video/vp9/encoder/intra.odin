package vp9_encoder

import vp9 ".."
import "base:intrinsics"
import "core:simd"

@(private)
choose_intra :: proc(t: ^Tile, r, c, size, tx: int, probs: []u8, $T: typeid, sub_x: int = 0, sub_y: int = 0) -> (mode: int, best_sad: u32) #no_bounds_check {
	UT :: #simd[4]T
	U32 :: #simd[4]u32
	e := t.e
	bw, bh := int(vp9.NUM_4X4_BLOCKS_WIDE_LOOKUP[size]) * 4, int(vp9.NUM_4X4_BLOCKS_HIGH_LOOKUP[size]) * 4
	tn := 4 << uint(tx)
	mode = vp9.DC_PRED
	best_sad = max(u32)
	best := max(i64)
	x, y := c * 8 + sub_x, r * 8 + sub_y
	max_x, max_y := e.mi_cols * 8, e.mi_rows * 8
	q := i64(max(4, int(vp9.ac_q(e.bit_depth, e.q_idx))))
	frame, stride := plane_t(e.planes[0], T), e.strides[0]
	source, s_stride := plane_t(e.source[0], T), e.source_strides[0]
	fast_modes := [4]int{vp9.DC_PRED, vp9.V_PRED, vp9.H_PRED, vp9.TM_PRED}
	num_modes := e.config.ultrafast ? 4 : vp9.INTRA_MODES
	for idx in 0 ..< num_modes {
		candidate := e.config.ultrafast ? fast_modes[idx] : idx
		bits := code_bit_cost(INTRA_MODE_CODES[candidate], probs)
		cost := (q * i64(bits)) >> 11
		sad: u32
		if tx == vp9.TX_4X4 {
			total: U32 = 0
			for dy := 0; dy < bh; dy += 4 {
				for dx := 0; dx < bw; dx += 4 {
					sx, sy := x + dx, y + dy
					if sx >= max_x || sy >= max_y do continue
					edges := vp9.Intra_Edges{have_left = c > t.first_col || sub_x + dx > 0, have_above = r > 0 || sub_y + dy > 0, not_on_right = sub_x + dx + 4 < max(bw, 8), max_x = max_x - 1, max_y = max_y - 1}
					vp9.predict_intra(frame, stride, sx, sy, vp9.TX_4X4, candidate, edges, e.bit_depth)
					for yy in 0 ..< 4 {
						sv := intrinsics.unaligned_load((^UT)(&source[(sy + yy) * s_stride + sx]))
						pv := intrinsics.unaligned_load((^UT)(&frame[(sy + yy) * stride + sx]))
						total += U32(simd.max(sv, pv) - simd.min(sv, pv))
						intrinsics.unaligned_store((^UT)(&frame[(sy + yy) * stride + sx]), sv)
					}
				}
			}
			sad = simd.reduce_add_ordered(total)
		} else if tn < bw || tn < bh {
			for dy := 0; dy < bh; dy += tn {
				for dx := 0; dx < bw; dx += tn {
					sx, sy := x + dx, y + dy
					if sx >= max_x || sy >= max_y do continue
					edges := vp9.Intra_Edges{have_left = c > t.first_col || dx > 0, have_above = r > 0 || dy > 0, not_on_right = dx + tn < bw, max_x = max_x - 1, max_y = max_y - 1}
					vp9.predict_intra(frame, stride, sx, sy, tx, candidate, edges, e.bit_depth)
					sad += block_sad(tn, source[sy * s_stride + sx:], s_stride, frame[sy * stride + sx:], stride)
					for yy in 0 ..< tn do copy(frame[(sy + yy) * stride + sx:][:tn], source[(sy + yy) * s_stride + sx:][:tn])
				}
			}
		} else {
			edges := vp9.Intra_Edges{have_left = c > t.first_col, have_above = r > 0, max_x = max_x - 1, max_y = max_y - 1}
			vp9.predict_intra(frame, stride, x, y, tx, candidate, edges, e.bit_depth)
			sad = block_sad(tn, source[y * s_stride + x:], s_stride, frame[y * stride + x:], stride)
		}
		cost += i64(sad)
		if cost < best {best, mode, best_sad = cost, candidate, sad}
	}
	return
}

@(private)
choose_intra_uv :: proc(t: ^Tile, r, c, size, uv_tx: int, probs: []u8, $T: typeid) -> int #no_bounds_check {
	e := t.e
	if e.config.ultrafast || e.lossless do return vp9.DC_PRED
	bsize := max(size, vp9.BLOCK_8X8)
	plane_size := int(vp9.SS_SIZE_LOOKUP[bsize][e.ss_x][e.ss_y])
	bw, bh := int(vp9.NUM_4X4_BLOCKS_WIDE_LOOKUP[plane_size]) * 4, int(vp9.NUM_4X4_BLOCKS_HIGH_LOOKUP[plane_size]) * 4
	tn := 4 << uint(uv_tx)
	x, y := (c * 8) >> uint(e.ss_x), (r * 8) >> uint(e.ss_y)
	max_x, max_y := (e.mi_cols * 8) >> uint(e.ss_x), (e.mi_rows * 8) >> uint(e.ss_y)
	if x >= max_x || y >= max_y do return vp9.DC_PRED
	q := i64(max(4, int(vp9.ac_q(e.bit_depth, e.q_idx))))
	mode := vp9.DC_PRED
	best := max(i64)
	for candidate in 0 ..< vp9.INTRA_MODES {
		bits := code_bit_cost(INTRA_MODE_CODES[candidate], probs)
		cost := (q * i64(bits)) >> 11
		for p in 1 ..= 2 {
			frame, stride := plane_t(e.planes[p], T), e.strides[p]
			source, s_stride := plane_t(e.source[p], T), e.source_strides[p]
			if tn < bw || tn < bh {
				for dy := 0; dy < bh; dy += tn {
					for dx := 0; dx < bw; dx += tn {
						sx, sy := x + dx, y + dy
						if sx >= max_x || sy >= max_y do continue
						edges := vp9.Intra_Edges{have_left = c > t.first_col || dx > 0, have_above = r > 0 || dy > 0, not_on_right = dx + tn < bw, max_x = max_x - 1, max_y = max_y - 1}
						vp9.predict_intra(frame, stride, sx, sy, uv_tx, candidate, edges, e.bit_depth)
						cost += i64(block_sad(tn, source[sy * s_stride + sx:], s_stride, frame[sy * stride + sx:], stride))
						for yy in 0 ..< tn do copy(frame[(sy + yy) * stride + sx:][:tn], source[(sy + yy) * s_stride + sx:][:tn])
					}
				}
			} else {
				edges := vp9.Intra_Edges{have_left = c > t.first_col, have_above = r > 0, max_x = max_x - 1, max_y = max_y - 1}
				vp9.predict_intra(frame, stride, x, y, uv_tx, candidate, edges, e.bit_depth)
				cost += i64(block_sad(tn, source[y * s_stride + x:], s_stride, frame[y * stride + x:], stride))
			}
		}
		if cost < best {best, mode = cost, candidate}
	}
	return mode
}

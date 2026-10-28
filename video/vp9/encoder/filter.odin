package vp9_encoder

import vp9 ".."

// The loop filter level follows the quantizer; the encoder signals no deltas
// or segments, so one level covers every block.
@(private)
encoder_filter_levels :: proc(e: ^Encoder) -> vp9.Filter_Levels {
	if e.lossless || e.config.disable_loop_filter {
		e.base_filter_level = 0
		return {}
	}
	q := int(vp9.ac_q(8, e.q_idx))
	level := (q * 20723 + 1015158 + (1 << 17)) >> 18
	if e.keyframe do level -= 4
	e.base_filter_level = clamp(level, 0, 63)
	lf := vp9.Loop_Filter{
		level         = e.base_filter_level,
		delta_enabled = !e.config.ultrafast,
		ref_deltas    = {1, 0, -1, -1},
		mode_deltas   = {0, 0},
	}
	return vp9.filter_levels(&lf, &e.segmentation)
}

@(private)
Filter_Wave :: struct($T: typeid) {
	f:         ^vp9.Loop_Filter_Frame(T),
	first_row: int,
	wave:      int,
}

@(private)
filter_frame :: proc(e: ^Encoder) {
	if e.lossless || e.config.disable_loop_filter do return
	if e.bit_depth == 8 {
		filter_frame_typed(e, u8)
	} else {
		filter_frame_typed(e, u16)
	}
}

@(private)
filter_frame_typed :: proc(e: ^Encoder, $T: typeid) {
	planes := [3][]T{plane_t(e.planes[0], T), plane_t(e.planes[1], T), plane_t(e.planes[2], T)}
	f := vp9.Loop_Filter_Frame(T){planes = planes, strides = e.strides, cells = e.filter_cells, mi_cols = e.mi_cols, mi_rows = e.mi_rows, ss_x = e.ss_x, ss_y = e.ss_y, bit_depth = e.bit_depth, limits = vp9.filter_limits(0)}
	if e.config.pool == nil || e.config.pool.run == nil {
		for r in 0 ..< e.sb_rows do for c in 0 ..< e.sb_cols do vp9.loop_filter_superblock(&f, r, c)
		return
	}
	run :: proc(data: rawptr, first, end: int) {
		w := (^Filter_Wave(T))(data)
		for i in first ..< end {
			r := w.first_row + i
			vp9.loop_filter_superblock(w.f, r, w.wave - 2 * r)
		}
	}
	for wave in 0 ..< 2 * (e.sb_rows - 1) + e.sb_cols {
		first_row, rows := vp9.wave_range(wave, e.sb_rows, e.sb_cols)
		job := Filter_Wave(T){&f, first_row, wave}
		e.config.pool.run(e.config.pool, rows, run, &job)
	}
}

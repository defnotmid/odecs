package vp9_encoder

import vp9 ".."

// The loop filter level follows the quantizer; the encoder signals no deltas
// or segments, so one level covers every block.
@(private)
encoder_filter_levels :: proc(e: ^Encoder) -> vp9.Filter_Levels {
	lf := vp9.Loop_Filter{level = min(63, (e.config.base_q_idx + 4) / 8)}
	seg := vp9.Segmentation{}
	return vp9.filter_levels(&lf, &seg)
}

@(private)
Filter_Wave :: struct {
	f:         ^vp9.Loop_Filter_Frame(u8),
	first_row: int,
	wave:      int,
}

@(private)
filter_frame :: proc(e: ^Encoder) {
	if e.config.base_q_idx == 0 || e.config.disable_loop_filter do return
	f := vp9.Loop_Filter_Frame(u8){planes = e.planes, strides = e.strides, cells = e.filter_cells, mi_cols = e.mi_cols, mi_rows = e.mi_rows, ss_x = 1, ss_y = 1, bit_depth = 8, limits = vp9.filter_limits(0)}
	if e.config.pool == nil || e.config.pool.run == nil {
		for r in 0 ..< e.sb_rows do for c in 0 ..< e.sb_cols do vp9.loop_filter_superblock(&f, r, c)
		return
	}
	run :: proc(data: rawptr, first, end: int) {
		w := (^Filter_Wave)(data)
		for i in first ..< end {
			r := w.first_row + i
			vp9.loop_filter_superblock(w.f, r, w.wave - 2 * r)
		}
	}
	for wave in 0 ..< 2 * (e.sb_rows - 1) + e.sb_cols {
		first_row, rows := vp9.wave_range(wave, e.sb_rows, e.sb_cols)
		job := Filter_Wave{&f, first_row, wave}
		e.config.pool.run(e.config.pool, rows, run, &job)
	}
}

package vp9_encoder

import vp9 ".."

@(private)
filter_frame :: proc(e: ^Encoder) {
	if e.config.base_q_idx == 0 || e.config.disable_loop_filter do return
	level := min(63, (e.config.base_q_idx + 4) / 8)
	lf := vp9.Loop_Filter{level = level}
	seg := vp9.Segmentation{}
	f := vp9.Loop_Filter_Frame(u8){planes = e.planes, strides = e.strides, mi = e.mi, mi_stride = e.mi_cols, mi_cols = e.mi_cols, mi_rows = e.mi_rows, ss_x = 1, ss_y = 1, bit_depth = 8, levels = vp9.filter_levels(&lf, &seg)}
	for r in 0 ..< e.sb_rows do for c in 0 ..< e.sb_cols do vp9.loop_filter_superblock(&f, r, c)
}

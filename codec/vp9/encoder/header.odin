package vp9_encoder

import vp9 ".."

@(private)
build_compressed_header :: proc(e: ^Encoder) {
	b := &e.header
	start_bool(b)
	if e.config.base_q_idx != 0 {put_literal(b, vp9.ALLOW_32X32, 2); put_literal(b, 0, 1)}
	count := e.config.base_q_idx == 0 ? 1 : 4
	for _ in 0 ..< count do put_literal(b, 0, 1) // no coefficient probability updates
	for _ in 0 ..< vp9.SKIP_CONTEXTS do put_bool(b, 0, 252)
	if !e.keyframe {
		for _ in 0 ..< vp9.INTER_MODE_CONTEXTS * (vp9.INTER_MODES - 1) do put_bool(b, 0, 252)
		for _ in 0 ..< vp9.IS_INTER_CONTEXTS do put_bool(b, 0, 252)
		// All sign biases are zero, so compound reference syntax is absent.
		for _ in 0 ..< vp9.REF_CONTEXTS * 2 do put_bool(b, 0, 252)
		for _ in 0 ..< vp9.BLOCK_SIZE_GROUPS * (vp9.INTRA_MODES - 1) do put_bool(b, 0, 252)
		for _ in 0 ..< vp9.PARTITION_CONTEXTS * (vp9.PARTITION_TYPES - 1) do put_bool(b, 0, 252)
		for _ in 0 ..< vp9.MV_JOINTS - 1 do put_bool(b, 0, 252)
		for _ in 0 ..< 2 {
			put_bool(b, 0, 252)
			for _ in 0 ..< vp9.MV_CLASSES - 1 do put_bool(b, 0, 252)
			put_bool(b, 0, 252)
			for _ in 0 ..< vp9.MV_OFFSET_BITS do put_bool(b, 0, 252)
		}
		for _ in 0 ..< 2 {
			for _ in 0 ..< vp9.CLASS0_SIZE * (vp9.MV_FR_SIZE - 1) do put_bool(b, 0, 252)
			for _ in 0 ..< vp9.MV_FR_SIZE - 1 do put_bool(b, 0, 252)
		}
	}
	finish_bool(b)
}

@(private)
Raw_Writer :: struct {data: ^[dynamic]u8, bits: int, failed: bool}

@(private)
raw_bits :: proc(w: ^Raw_Writer, value, bits: int) {
	for i := bits - 1; i >= 0; i -= 1 {
		if w.bits & 7 == 0 {
			if _, err := append(w.data, 0); err != nil {w.failed = true; return}
		}
		w.data^[len(w.data^) - 1] |= u8(value >> uint(i) & 1) << uint(7 - (w.bits & 7))
		w.bits += 1
	}
}

@(private)
build_uncompressed_header :: proc(e: ^Encoder) -> bool {
	w := Raw_Writer{data = &e.packet}
	raw_bits(&w, 2, 2); raw_bits(&w, 0, 2) // marker, profile 0
	raw_bits(&w, 0, 1) // show_existing_frame
	raw_bits(&w, int(!e.keyframe), 1)
	raw_bits(&w, 1, 1); raw_bits(&w, 1, 1) // shown, error resilient (implies frame parallel)
	if e.keyframe {
		raw_bits(&w, 0x498342, 24)
		raw_bits(&w, 2, 3); raw_bits(&w, 0, 1) // BT.709 limited
		raw_bits(&w, e.config.width - 1, 16); raw_bits(&w, e.config.height - 1, 16)
		raw_bits(&w, 0, 1) // same render size
	} else {
		raw_bits(&w, 1, 8) // refresh LAST slot zero
		for _ in 0 ..< 3 {raw_bits(&w, 0, 3); raw_bits(&w, 0, 1)}
		raw_bits(&w, 1, 1) // size from LAST
		raw_bits(&w, 0, 1) // same render size
		raw_bits(&w, 0, 1) // quarter-pixel precision
		raw_bits(&w, 0, 1); raw_bits(&w, 1, 2) // fixed EIGHTTAP
	}
	raw_bits(&w, 0, 2) // context index
	level := e.config.base_q_idx == 0 || e.config.disable_loop_filter ? 0 : min(63, (e.config.base_q_idx + 4) / 8)
	raw_bits(&w, level, 6); raw_bits(&w, 0, 3); raw_bits(&w, 0, 1) // filter level, sharpness, deltas
	raw_bits(&w, e.config.base_q_idx, 8)
	raw_bits(&w, 0, 3) // quantizer deltas absent
	raw_bits(&w, 0, 1) // no segmentation
	minimum, maximum := tile_limits(e.sb_cols)
	for _ in minimum ..< e.config.tile_cols_log2 do raw_bits(&w, 1, 1)
	if e.config.tile_cols_log2 < maximum do raw_bits(&w, 0, 1)
	raw_bits(&w, 0, 1) // one tile row
	raw_bits(&w, len(e.header.data), 16)
	return !w.failed
}

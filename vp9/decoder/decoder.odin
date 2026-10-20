// VP9 decoding (VP9 Bitstream & Decoding Process Specification v0.7):
// profiles 0-3 (8/10/12-bit, 4:2:0/4:2:2/4:4:0/4:4:4), key, intra-only and
// inter frames, compound prediction, scaled references, segmentation,
// show_existing_frame and superframes. Tile columns of a tile row decode
// in parallel on the caller's Work_Pool; each tile owns its contexts,
// counts and scratch, and tile results are combined in tile order.
package vp9_decoder

import vp9 ".."
import common "../../common"

Error :: enum {
	None,
	Invalid_Data,  // malformed, truncated, or refers to missing references
	Unsupported,   // valid but outside the implemented scope
	Out_Of_Memory,
}

// A decoded picture, valid until the next decode call. Samples are bytes
// for 8-bit streams (planes8) and u16 otherwise (planes16); strides count
// samples. Chroma planes are ((width + ss_x) >> ss_x) wide.
Picture :: struct {
	width, height:   int,
	bit_depth:       int,
	ss_x, ss_y:      int,
	color_space:     int, // VP9 color_space: 1 BT.601, 2 BT.709, ..., 7 sRGB
	full_range:      bool,
	planes8:         [3][]u8,
	planes16:        [3][]u16,
	strides:         [3]int,
}

// One decoder per stream; an alpha stream uses a second decoder.
Decoder :: struct {
	pool:              ^common.Work_Pool,
	// State carried between frames.
	contexts:          [4]vp9.Probabilities,
	probs:             vp9.Probabilities,
	loop_filter:       vp9.Loop_Filter,
	segmentation:      vp9.Segmentation,
	refs:              [vp9.NUM_REF_FRAMES]^Frame,
	frames:            [dynamic]^Frame, // buffer pool
	bit_depth:         int,
	ss_x, ss_y:        int,
	color_space:       int,
	full_range:        bool,
	sized:             bool,
	last_width:        int,
	last_height:       int,
	last_show_frame:   bool,
	frame_type:        int,
	last_frame_type:   int,
	clear_segment_map: bool,
	// Current frame.
	h:                 Header,
	cur:               ^Frame,
	// Per 8x8 cell, mi_rows x mi_cols, each grid holding what one reader needs.
	motion:            [dynamic]Motion, // for motion vector prediction
	prev_motion:       [dynamic]Motion, // the previous decoded frame's
	sub_mvs:           [dynamic][2][4]vp9.Mv, // written by blocks below 8x8 only (Motion.sub8x8)
	segment_ids:       [dynamic]u8,
	filter_cells:      [dynamic]vp9.Filter_Cell, // for the loop filter
	filter_levels:     vp9.Filter_Levels, // the current frame's, for filter_cells
	ref_scales:        [3]Ref_Scale, // LAST, GOLDEN and ALTREF against the current frame
	prev_segment_ids:  [dynamic]u8,
	above_context:     [dynamic]Edge_Context, // per 8x8 column: the block above's bottom edge
	above_partition:   [dynamic]u8,
	above_nonzero:     [3][dynamic]u8,
	above_seg_pred:    [dynamic]u8,
	counts:            vp9.Counts,
	tiles:             [dynamic]^Tile,
	shown:             ^Frame, // output of the last decode call
}

// A frame buffer: planes sized to whole superblocks so blocks can be
// predicted and reconstructed without edge checks.
@(private)
Frame :: struct {
	storage:     []u8,
	offsets:     [3]int, // bytes
	strides:     [3]int, // samples
	rows:        [3]int,
	width:       int,
	height:      int,
	ss_x, ss_y:  int,
	bit_depth:   int,
	color_space: int,
	full_range:  bool,
	refs:        int, // reference slots holding it
}

init_decoder :: proc(d: ^Decoder, pool: ^common.Work_Pool = nil) {
	d^ = {
		pool = pool,
	}
}

destroy_decoder :: proc(d: ^Decoder) {
	for f in d.frames {
		delete(f.storage)
		free(f)
	}
	for t in d.tiles do free(t)
	delete(d.frames)
	delete(d.tiles)
	delete(d.motion)
	delete(d.prev_motion)
	delete(d.sub_mvs)
	delete(d.segment_ids)
	delete(d.above_context)
	delete(d.filter_cells)
	delete(d.prev_segment_ids)
	delete(d.above_partition)
	for &a in d.above_nonzero do delete(a)
	delete(d.above_seg_pred)
	d^ = {}
}

// Decodes one container packet: a frame or a superframe. Returns the shown
// picture, if the packet shows one (hidden alt-ref frames show none).
decode_packet :: proc(d: ^Decoder, data: []u8) -> (picture: Picture, shown: bool, err: Error) {
	if len(data) == 0 do return {}, false, .Invalid_Data
	frames: [8][]u8
	count := 0
	last := data[len(data) - 1]
	if last & 0xE0 == 0xC0 {
		bytes := int(last >> 3 & 3) + 1
		n := int(last & 7) + 1
		index_size := 2 + bytes * n
		if index_size <= len(data) && data[len(data) - index_size] == last {
			at := len(data) - index_size + 1
			offset := 0
			for _ in 0 ..< n {
				size := 0
				for k in 0 ..< bytes do size |= int(data[at + k]) << uint(8 * k)
				at += bytes
				if size > len(data) - index_size - offset do return {}, false, .Invalid_Data
				frames[count] = data[offset:][:size]
				count += 1
				offset += size
			}
		}
	}
	if count == 0 {
		frames[0] = data
		count = 1
	}
	d.shown = nil
	for frame in frames[:count] {
		if len(frame) == 0 do continue
		decode_frame(d, frame) or_return
	}
	if d.shown == nil do return {}, false, .None
	return picture_of(d.shown), true, .None
}

@(private)
picture_of :: proc(f: ^Frame) -> (p: Picture) {
	p = {
		width       = f.width,
		height      = f.height,
		bit_depth   = f.bit_depth,
		ss_x        = f.ss_x,
		ss_y        = f.ss_y,
		color_space = f.color_space,
		full_range  = f.full_range,
		strides     = f.strides,
	}
	for i in 0 ..< 3 {
		if f.bit_depth == 8 {
			p.planes8[i] = plane(f, i, u8)
		} else {
			p.planes16[i] = plane(f, i, u16)
		}
	}
	return
}

@(private)
plane :: #force_inline proc(f: ^Frame, i: int, $T: typeid) -> []T {
	bytes := f.strides[i] * f.rows[i] * size_of(T)
	return ([^]T)(raw_data(f.storage[f.offsets[i]:]))[:bytes / size_of(T)]
}

@(private)
decode_frame :: proc(d: ^Decoder, data: []u8) -> Error {
	uncompressed_header(d, data) or_return
	h := &d.h
	if h.show_existing_frame {
		f := d.refs[h.frame_to_show]
		if f == nil do return .Invalid_Data
		d.shown = f
		return .None
	}
	if h.compressed_size == 0 || h.uncompressed_size + h.compressed_size > len(data) do return .Invalid_Data
	if h.width > 16384 || h.height > 16384 do return .Unsupported
	allocate_frame(d) or_return
	allocate_grids(d) or_return
	d.filter_levels = vp9.filter_levels(&d.loop_filter, &d.segmentation)
	if !h.frame_is_intra do for i in 0 ..< 3 {
		if ref := d.refs[h.ref_frame_idx[i]]; ref != nil do d.ref_scales[i] = ref_scale(ref, h)
	}

	// Probabilities: the frame context, then the compressed header's updates.
	d.probs = d.contexts[h.frame_context_idx]
	d.counts = {}
	b: common.Bool_Decoder
	if !init_bool(&b, data[h.uncompressed_size:][:h.compressed_size]) do return .Invalid_Data
	compressed_header(d, &b)
	if common.bool_overrun(&b) do return .Invalid_Data

	decode_tiles(d, data[h.uncompressed_size + h.compressed_size:]) or_return
	if d.loop_filter.level != 0 do apply_loop_filter(d)

	// Backward adaptation (6.1.2) from the context loaded before this frame.
	if !h.error_resilient && !h.frame_parallel {
		saved := &d.contexts[h.frame_context_idx]
		vp9.load_probs(&d.probs, saved)
		vp9.adapt_coef_probs(&d.probs, &d.counts, h.frame_is_intra, d.last_frame_type == 0)
		if !h.frame_is_intra {
			vp9.load_probs2(&d.probs, saved)
			vp9.adapt_noncoef_probs(&d.probs, &d.counts, h.interp_filter == vp9.SWITCHABLE, h.tx_mode == vp9.TX_MODE_SELECT, h.allow_high_precision_mv)
		}
	}
	if h.refresh_frame_context do d.contexts[h.frame_context_idx] = d.probs

	// Segmentation map, references and motion vectors for the next frame.
	seg := &d.segmentation
	if seg.enabled && seg.update_map {
		d.segment_ids, d.prev_segment_ids = d.prev_segment_ids, d.segment_ids
	}
	for i in 0 ..< vp9.NUM_REF_FRAMES {
		if h.refresh_frame_flags >> uint(i) & 1 == 0 do continue
		if d.refs[i] != nil do d.refs[i].refs -= 1
		d.refs[i] = d.cur
		d.cur.refs += 1
	}
	d.motion, d.prev_motion = d.prev_motion, d.motion
	d.last_show_frame = h.show_frame
	if h.show_frame do d.shown = d.cur
	return .None
}

// Takes a buffer no reference slot holds and that is not the picture the
// caller may still be reading, and shapes it for the current frame.
@(private)
allocate_frame :: proc(d: ^Decoder) -> Error {
	h := &d.h
	f: ^Frame
	for candidate in d.frames {
		if candidate.refs == 0 && candidate != d.shown {f = candidate; break}
	}
	if f == nil {
		f = new(Frame)
		if f == nil do return .Out_Of_Memory
		append(&d.frames, f)
	}
	luma_w, luma_h := h.sb64_cols * 64, h.sb64_rows * 64
	bytes_per := d.bit_depth == 8 ? 1 : 2
	total := 0
	for i in 0 ..< 3 {
		w := i == 0 ? luma_w : luma_w >> uint(d.ss_x)
		rows := i == 0 ? luma_h : luma_h >> uint(d.ss_y)
		f.offsets[i] = total
		f.strides[i] = w
		f.rows[i] = rows
		total += w * rows * bytes_per
	}
	if len(f.storage) < total {
		delete(f.storage)
		f.storage = make([]u8, total)
		if f.storage == nil do return .Out_Of_Memory
	}
	f.width, f.height = h.width, h.height
	f.ss_x, f.ss_y, f.bit_depth = d.ss_x, d.ss_y, d.bit_depth
	f.color_space, f.full_range = d.color_space, d.full_range
	d.cur = f
	return .None
}

@(private)
allocate_grids :: proc(d: ^Decoder) -> Error {
	h := &d.h
	cells := h.mi_rows * h.mi_cols
	if len(d.motion) != cells {
		// A new size: previous motion vectors are not used (compute_image_size).
		if resize(&d.motion, cells) != nil || resize(&d.prev_motion, cells) != nil || resize(&d.sub_mvs, cells) != nil || resize(&d.segment_ids, cells) != nil || resize(&d.filter_cells, cells) != nil || resize(&d.prev_segment_ids, cells) != nil do return .Out_Of_Memory
	}
	if d.clear_segment_map {
		for &s in d.prev_segment_ids do s = 0
		d.clear_segment_map = false
	}
	cols8 := h.sb64_cols * 8
	if resize(&d.above_context, cols8) != nil do return .Out_Of_Memory
	if resize(&d.above_partition, cols8) != nil || resize(&d.above_seg_pred, cols8) != nil do return .Out_Of_Memory
	for &a in d.above_nonzero do if resize(&a, cols8 * 2) != nil do return .Out_Of_Memory
	return .None
}

@(private)
apply_loop_filter :: proc(d: ^Decoder) {
	if d.bit_depth == 8 {
		filter_frame(d, u8)
	} else {
		filter_frame(d, u16)
	}
}

@(private)
Filter_Wave :: struct($T: typeid) {
	f:         ^vp9.Loop_Filter_Frame(T),
	first_row: int,
	wave:      int,
}

// Waves of independent superblocks run on the pool in order.
@(private)
filter_frame :: proc(d: ^Decoder, $T: typeid) {
	h := &d.h
	f := vp9.Loop_Filter_Frame(T) {
		cells     = d.filter_cells[:],
		mi_rows   = h.mi_rows,
		mi_cols   = h.mi_cols,
		ss_x      = d.ss_x,
		ss_y      = d.ss_y,
		bit_depth = d.bit_depth,
		limits    = vp9.filter_limits(d.loop_filter.sharpness),
	}
	for i in 0 ..< 3 {
		f.planes[i] = plane(d.cur, i, T)
		f.strides[i] = d.cur.strides[i]
	}
	if d.pool == nil {
		for r in 0 ..< h.sb64_rows do for c in 0 ..< h.sb64_cols do vp9.loop_filter_superblock(&f, r, c)
		return
	}
	run :: proc(data: rawptr, first, end: int) {
		w := (^Filter_Wave(T))(data)
		for i in first ..< end {
			r := w.first_row + i
			vp9.loop_filter_superblock(w.f, r, w.wave - 2 * r)
		}
	}
	for wave in 0 ..< 2 * (h.sb64_rows - 1) + h.sb64_cols {
		first_row, rows := vp9.wave_range(wave, h.sb64_rows, h.sb64_cols)
		job := Filter_Wave(T){&f, first_row, wave}
		d.pool.run(d.pool, rows, run, &job)
	}
}

// ---- Tiles --------------------------------------------------------------------------

@(private)
Tile_Job :: struct {
	d:     ^Decoder,
	tiles: []^Tile,
}

@(private)
decode_tiles :: proc(d: ^Decoder, data: []u8) -> Error {
	h := &d.h
	cols, rows := 1 << uint(h.tile_cols_log2), 1 << uint(h.tile_rows_log2)
	for &a in d.above_nonzero do for &v in a do v = 0
	for &v in d.above_partition do v = 0
	for &v in d.above_seg_pred do v = 0
	for len(d.tiles) < cols {
		t := new(Tile)
		if t == nil do return .Out_Of_Memory
		append(&d.tiles, t)
	}
	rest := data
	offset :: proc(n, mis, log2: int) -> int {
		sbs := (mis + 7) >> 3
		return min(((n * sbs) >> uint(log2)) << 3, mis)
	}
	for row in 0 ..< rows {
		for col in 0 ..< cols {
			t := d.tiles[col]
			size := len(rest)
			if row != rows - 1 || col != cols - 1 {
				if len(rest) < 4 do return .Invalid_Data
				size = int(rest[0]) << 24 | int(rest[1]) << 16 | int(rest[2]) << 8 | int(rest[3])
				rest = rest[4:]
				if size > len(rest) do return .Invalid_Data
			}
			t^ = {
				d            = d,
				data         = rest[:size],
				mi_row_start = offset(row, h.mi_rows, h.tile_rows_log2),
				mi_row_end   = offset(row + 1, h.mi_rows, h.tile_rows_log2),
				mi_col_start = offset(col, h.mi_cols, h.tile_cols_log2),
				mi_col_end   = offset(col + 1, h.mi_cols, h.tile_cols_log2),
			}
			rest = rest[size:]
		}
		job := Tile_Job{d, d.tiles[:cols]}
		if d.pool != nil && cols > 1 {
			d.pool.run(d.pool, cols, run_tiles, &job)
		} else {
			run_tiles(&job, 0, cols)
		}
		for t in d.tiles[:cols] {
			if t.err != .None do return t.err
			vp9.add_counts(&d.counts, &t.counts)
		}
	}
	return .None
}

@(private)
run_tiles :: proc(data: rawptr, first, end: int) {
	job := (^Tile_Job)(data)
	for t in job.tiles[first:end] {
		if job.d.bit_depth == 8 {
			decode_tile(t, u8)
		} else {
			decode_tile(t, u16)
		}
	}
}

// A reference's scale against the current frame in 1/16384 steps, and the
// reference samples one predicted sample advances in 1/16 samples (8.5.2.3).
// Fixed for the frame, so prediction does not divide per block.
@(private)
Ref_Scale :: struct {
	x, y:           int,
	step_x, step_y: int,
}

@(private)
ref_scale :: proc(ref: ^Frame, h: ^Header) -> (s: Ref_Scale) {
	s.x, s.y = (ref.width << 14) / h.width, (ref.height << 14) / h.height
	s.step_x, s.step_y = (16 * s.x) >> 14, (16 * s.y) >> 14
	return
}

// What motion vector prediction reads of an 8x8 cell (6.4.21, 6.5.1): the
// block's reference frames and motion vectors (its last sub-block's), and its
// mode for the inter mode context. Blocks below 8x8 also keep their four
// sub-block vectors in Decoder.sub_mvs.
@(private)
Motion :: struct {
	mv:        [2]vp9.Mv,
	ref_frame: [2]i8, // INTRA_FRAME (0) or LAST..ALTREF; [1] is NONE (-1) unless compound
	y_mode:    u8,
	sub8x8:    bool,
}

// What the next block's contexts read of the neighbouring block along one
// edge (the spec's AboveX / LeftX): kept per 8x8 column above the current row
// and per row of the tile's superblock row on the left, as the partition and
// nonzero contexts are.
@(private)
Edge_Context :: struct {
	ref_frame:     [2]i8,
	modes:         [2]u8, // the sub-block modes along the edge: bottom row above, right column on the left
	tx_size:       u8,
	interp_filter: u8,
	skip:          bool,
}

// A VP9 bool decoder starts with a marker bit that must be zero (9.2.1).
@(private)
init_bool :: proc(b: ^common.Bool_Decoder, data: []u8) -> bool {
	if len(data) < 1 do return false
	common.bool_start(b, data)
	return common.bool_decode(b, 128) == 0
}

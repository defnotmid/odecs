package vp9_encoder

import vp9 ".."
import common "../../../common"
import "core:mem"
import "core:slice"

Error :: enum {None, Invalid_Argument, Out_Of_Memory, Closed}

Chroma_Subsampling :: enum {
	YUV420, // ss_x = 1, ss_y = 1 (default)
	YUV422, // ss_x = 1, ss_y = 0
	YUV440, // ss_x = 0, ss_y = 1
	YUV444, // ss_x = 0, ss_y = 0
}

Encoder_Config :: struct {
	width, height: int,
	bit_depth: int, // 0 or 8 selects 8; 10 or 12 selects high bit depth
	subsampling: Chroma_Subsampling,
	base_q_idx: int, // 0..255; zero is exactly lossless
	delta_q_y_dc, delta_q_uv_dc, delta_q_uv_ac: int, // -15..15
	keyframe_interval: int, // zero selects 120
	block_log2: int, // 3..6: 8, 16, 32 or 64 pixel partitions; zero selects 6 (64)
	disable_loop_filter: bool,
	search_range: int, // integer pixels; zero selects 16
	tile_cols_log2: int, // clipped to the VP9 limits for the width
	ultrafast: bool, // prefer encode speed over size
	pool: ^common.Work_Pool,
}

@(private)
plane_t :: #force_inline proc(b: []u8, $T: typeid) -> []T #no_bounds_check {
	when T == u8 {
		return b
	} else {
		return slice.reinterpret([]T, b)
	}
}

@(private)
Encoder_Counts :: struct {
	using base: vp9.Counts,
	seg_tree:   [vp9.MAX_SEGMENTS]u32,
	seg_pred:   [3][2]u32,
}

// Pictures are superblock-aligned planes inside a replicated border. A motion
// vector reaches at most 64 samples (32 in chroma) beyond its block, plus the
// 8-tap filter's 3/4 samples, so no analysis or prediction read needs clamping.
BORDER :: 80

// What motion vector prediction reads of an 8x8 cell (6.4.21, 6.5.1): its
// vector, whether it was inter-coded, and its mode for the inter mode context.
@(private)
Motion :: struct {
	mv:        [2]vp9.Mv,
	sub_mvs:   [2][4]vp9.Mv,
	ref_frame: [2]i8,
	y_mode:    u8,
	sub8x8:    bool,
}

// What a block's syntax contexts read of the neighbouring 8x8 cell above or
// to the left: its modes, transform size, reference frame and skip flag.
@(private)
Edge_Context :: struct {
	ref_frame:     [2]i8,
	modes:         [2]u8,
	tx_size:       u8,
	interp_filter: u8,
	skip:          bool,
}

Encoder :: struct {
	config: Encoder_Config,
	allocator: mem.Allocator,
	planes, reference, golden, altref, last_recon: [3][]u8, // interiors: the first visible sample first
	planes_storage, reference_storage, golden_storage, altref_storage: [3][]u8, // bordered
	strides: [3]int,
	input: [3][]u8,
	input_strides: [3]int,
	// The input staged per superblock row by each tile: aligned, edges replicated.
	source: [3][]u8,
	source_strides: [3]int,
	// Per 8x8 cell, mi_rows x mi_cols, each grid holding what one reader needs.
	motion, prev_motion: []Motion,
	segment_ids, prev_segment_ids: []u8,
	segmentation: vp9.Segmentation,
	dequant: [vp9.MAX_SEGMENTS][2][2]i32,
	last_seg_enabled: [vp9.MAX_SEGMENTS][4]bool,
	last_seg_data: [vp9.MAX_SEGMENTS][4]i16,
	filter_cells: []vp9.Filter_Cell,
	filter_levels: vp9.Filter_Levels,
	mi_cols, mi_rows, sb_cols, sb_rows: int,
	contexts: [4]vp9.Probabilities,
	probs: vp9.Probabilities,
	counts: Encoder_Counts,
	mv_joint_cost: [vp9.MV_JOINTS]u16,
	mv_comp_cost: [2][2][2][2 * MAX_MV + 1]u16,
	inter_mode_cost: [vp9.INTER_MODE_CONTEXTS][vp9.INTER_MODES]u16,
	sym_probs: [SYM_PROB_SIZE]u8,
	forward: vp9.Forward_Transforms,
	tiles: []Tile,
	packet: [dynamic]u8,
	header: Bool_Writer,
	frames: u64,
	bit_depth, profile, ss_x, ss_y, q_idx, base_filter_level, frame_context_idx, refresh_frame_flags: int,
	keyframe, last_keyframe, show_frame, last_show_frame, use_prev_mvs, refresh_golden, has_altref, allow_comp, allow_hp, lossless, last_seg_abs, seg_update_data, initialized: bool,
}

// Init owns all persistent buffers with the calling allocator. The encoder
// must not move during encode_frame; no worker creates threads or publishes data.
init_encoder :: proc(e: ^Encoder, config: Encoder_Config) -> Error {
	if e == nil || config.width <= 0 || config.height <= 0 || config.width > 65536 || config.height > 65536 || (config.bit_depth != 0 && config.bit_depth != 8 && config.bit_depth != 10 && config.bit_depth != 12) || int(config.subsampling) < 0 || int(config.subsampling) > int(Chroma_Subsampling.YUV444) || config.base_q_idx < 0 || config.base_q_idx > 255 || abs(config.delta_q_y_dc) > 15 || abs(config.delta_q_uv_dc) > 15 || abs(config.delta_q_uv_ac) > 15 || config.keyframe_interval < 0 || config.tile_cols_log2 < 0 || config.search_range < 0 || config.search_range > 64 || (config.block_log2 != 0 && (config.block_log2 < 3 || config.block_log2 > 6)) do return .Invalid_Argument
	e^ = {config = config, allocator = context.allocator}
	e.bit_depth = config.bit_depth == 0 ? 8 : config.bit_depth
	switch config.subsampling {
	case .YUV420: e.ss_x, e.ss_y = 1, 1
	case .YUV422: e.ss_x, e.ss_y = 1, 0
	case .YUV440: e.ss_x, e.ss_y = 0, 1
	case .YUV444: e.ss_x, e.ss_y = 0, 0
	}
	e.profile = (e.bit_depth > 8 ? 2 : 0) + (e.ss_x != 1 || e.ss_y != 1 ? 1 : 0)
	if e.config.keyframe_interval == 0 do e.config.keyframe_interval = 120
	if e.config.search_range == 0 do e.config.search_range = 16
	if e.config.block_log2 == 0 do e.config.block_log2 = 6
	vp9.init_forward_transforms(&e.forward)
	e.mi_cols, e.mi_rows = (config.width + 7) / 8, (config.height + 7) / 8
	e.sb_cols, e.sb_rows = (e.mi_cols + 7) / 8, (e.mi_rows + 7) / 8
	if i64(e.sb_cols) * i64(e.sb_rows) * 4096 > i64(max(int)) / 16 {e^ = {}; return .Out_Of_Memory}
	minimum, maximum := tile_limits(e.sb_cols)
	e.config.tile_cols_log2 = clamp(config.tile_cols_log2, minimum, maximum)
	vp9.default_probabilities(&e.probs)
	for &ctx in e.contexts do ctx = e.probs
	for i in 0 ..< 256 do e.sym_probs[i] = u8(i)
	ok := false
	defer if !ok do destroy_encoder(e)
	err: mem.Allocator_Error
	e.motion, err = make([]Motion, e.mi_cols * e.mi_rows)
	if err != nil do return .Out_Of_Memory
	e.prev_motion, err = make([]Motion, e.mi_cols * e.mi_rows)
	if err != nil do return .Out_Of_Memory
	e.segment_ids, err = make([]u8, e.mi_cols * e.mi_rows)
	if err != nil do return .Out_Of_Memory
	e.prev_segment_ids, err = make([]u8, e.mi_cols * e.mi_rows)
	if err != nil do return .Out_Of_Memory
	e.filter_cells, err = make([]vp9.Filter_Cell, e.mi_cols * e.mi_rows)
	if err != nil do return .Out_Of_Memory
	e.filter_levels = encoder_filter_levels(e)
	sample_bytes := e.bit_depth > 8 ? 2 : 1
	for p in 0 ..< 3 {
		sx, sy := p > 0 ? uint(e.ss_x) : 0, p > 0 ? uint(e.ss_y) : 0
		aligned_w, aligned_h := e.sb_cols * 64 >> sx, e.sb_rows * 64 >> sy
		e.strides[p] = aligned_w + 2 * BORDER
		bytes := e.strides[p] * (aligned_h + 2 * BORDER) * sample_bytes
		e.planes_storage[p], err = make([]u8, bytes)
		if err != nil do return .Out_Of_Memory
		e.reference_storage[p], err = make([]u8, bytes)
		if err != nil do return .Out_Of_Memory
		e.golden_storage[p], err = make([]u8, bytes)
		if err != nil do return .Out_Of_Memory
		e.altref_storage[p], err = make([]u8, bytes)
		if err != nil do return .Out_Of_Memory
		origin := (BORDER * e.strides[p] + BORDER) * sample_bytes
		e.planes[p], e.reference[p], e.golden[p], e.altref[p] = e.planes_storage[p][origin:], e.reference_storage[p][origin:], e.golden_storage[p][origin:], e.altref_storage[p][origin:]
		e.source_strides[p] = aligned_w
		e.source[p], err = make([]u8, aligned_w * aligned_h * sample_bytes)
		if err != nil do return .Out_Of_Memory
	}
	e.last_recon = e.reference
	e.tiles, err = make([]Tile, 1 << uint(e.config.tile_cols_log2))
	if err != nil do return .Out_Of_Memory
	for &t, i in e.tiles {
		t.first_col = ((i * e.sb_cols) >> uint(e.config.tile_cols_log2)) * 8
		t.end_col = min(e.mi_cols, (((i + 1) * e.sb_cols) >> uint(e.config.tile_cols_log2)) * 8)
		t.above_partition, err = make([]u8, e.sb_cols * 8)
		if err != nil do return .Out_Of_Memory
		t.above_seg_pred, err = make([]u8, e.sb_cols * 8)
		if err != nil do return .Out_Of_Memory
		t.above_context, err = make([]Edge_Context, e.sb_cols * 8)
		if err != nil do return .Out_Of_Memory
		for p in 0 ..< 3 {
			sx := p > 0 ? uint(e.ss_x) : 0
			t.above_nonzero[p], err = make([]u8, e.sb_cols * (16 >> sx))
			if err != nil do return .Out_Of_Memory
		}
		err = reserve(&t.b.data, max(64, (t.end_col - t.first_col) * 8 * e.sb_rows * 64 * 8))
		if err != nil do return .Out_Of_Memory
		err = reserve(&t.syms, max(256, (t.end_col - t.first_col) * 8 * e.sb_rows * 64 * 16))
		if err != nil do return .Out_Of_Memory
	}
	err = reserve(&e.packet, e.sb_cols * e.sb_rows * 64 * 64 * 8)
	if err != nil do return .Out_Of_Memory
	err = reserve(&e.header.data, 1024)
	if err != nil do return .Out_Of_Memory
	e.initialized = true
	ok = true
	return .None
}

// Packet and reconstructed planes are borrowed until the next call/destroy.
// Input is planar 8-bit, with ceil(width >> ss_x), ceil(height >> ss_y) chroma.
encode_frame :: proc(e: ^Encoder, planes: [3][]u8, strides: [3]int) -> (packet: []u8, keyframe: bool, err: Error) {
	if e != nil && e.initialized && e.bit_depth != 8 do return nil, false, .Invalid_Argument
	return encode_frame_internal(e, planes, strides, false)
}

// Input is planar 10-bit or 12-bit in u16 samples; strides count samples.
encode_frame16 :: proc(e: ^Encoder, planes: [3][]u16, strides: [3]int) -> (packet: []u8, keyframe: bool, err: Error) {
	if e == nil || !e.initialized do return nil, false, .Closed
	if e.bit_depth <= 8 do return nil, false, .Invalid_Argument
	bytes := [3][]u8{slice.to_bytes(planes[0]), slice.to_bytes(planes[1]), slice.to_bytes(planes[2])}
	return encode_frame_internal(e, bytes, strides, false)
}

// Encodes an unshown alternate reference frame (show_frame = 0) into slot 2 (ALTREF_FRAME).
encode_altref_frame :: proc(e: ^Encoder, planes: [3][]u8, strides: [3]int) -> (packet: []u8, err: Error) {
	if e != nil && e.initialized && (e.frames == 0 || e.bit_depth != 8) do return nil, .Invalid_Argument
	pkt, _, er := encode_frame_internal(e, planes, strides, true)
	return pkt, er
}

encode_altref_frame16 :: proc(e: ^Encoder, planes: [3][]u16, strides: [3]int) -> (packet: []u8, err: Error) {
	if e == nil || !e.initialized do return nil, .Closed
	if e.frames == 0 || e.bit_depth <= 8 do return nil, .Invalid_Argument
	bytes := [3][]u8{slice.to_bytes(planes[0]), slice.to_bytes(planes[1]), slice.to_bytes(planes[2])}
	pkt, _, er := encode_frame_internal(e, bytes, strides, true)
	return pkt, er
}

// Emits a 1-byte show_existing_frame = 1 packet referencing slot (default slot 2 = ALTREF_FRAME).
encode_existing_frame :: proc(e: ^Encoder, slot: int = 2) -> (packet: []u8, err: Error) {
	if e == nil || !e.initialized do return nil, .Closed
	if slot < 0 || slot >= vp9.NUM_REF_FRAMES do return nil, .Invalid_Argument
	context.allocator = e.allocator
	clear(&e.packet)
	w := Raw_Writer{data = &e.packet}
	raw_bits(&w, 2, 2)
	emit_profile(&w, e.profile)
	raw_bits(&w, 1, 1) // show_existing_frame = 1
	raw_bits(&w, slot, 3)
	if w.failed do return nil, .Out_Of_Memory
	e.last_recon = slot == 2 ? e.altref : slot == 1 ? e.golden : e.reference
	e.frames += 1
	return e.packet[:], .None
}

@(private)
encode_frame_internal :: proc(e: ^Encoder, planes: [3][]u8, strides: [3]int, is_altref: bool) -> (packet: []u8, keyframe: bool, err: Error) {
	if e == nil || !e.initialized do return nil, false, .Closed
	sample_bytes := i128(e.bit_depth > 8 ? 2 : 1)
	for p in 0 ..< 3 {
		sx, sy := p > 0 ? e.ss_x : 0, p > 0 ? e.ss_y : 0
		w, h := (e.config.width + sx) >> uint(sx), (e.config.height + sy) >> uint(sy)
		if strides[p] < w || (i128(h - 1) * i128(strides[p]) + i128(w)) * sample_bytes > i128(len(planes[p])) do return nil, false, .Invalid_Argument
	}
	context.allocator = e.allocator
	e.input, e.input_strides = planes, strides
	gop_frame := e.frames % u64(e.config.keyframe_interval)
	if is_altref {
		e.keyframe = false
		e.show_frame = false
		e.refresh_golden = false
		e.refresh_frame_flags = 1 << 2
		e.allow_comp = !e.config.ultrafast && !e.last_keyframe && e.config.base_q_idx > 0
	} else {
		e.keyframe = gop_frame == 0
		e.show_frame = true
		e.refresh_golden = !e.keyframe && (gop_frame & 7) == 0 && e.config.keyframe_interval >= 8
		e.refresh_frame_flags = e.keyframe ? 0xFF : (e.refresh_golden ? 3 : 1)
		e.allow_comp = !e.config.ultrafast && !e.keyframe && ((!e.last_keyframe && (gop_frame & 7) != 1 && e.config.keyframe_interval >= 8) || e.has_altref) && e.config.base_q_idx > 0
	}
	e.use_prev_mvs = !e.keyframe && !e.last_keyframe && e.last_show_frame
	if e.config.base_q_idx > 0 && e.config.keyframe_interval > 1 {
		if e.keyframe {
			flat, total := 0, 0
			if e.bit_depth == 8 {
				for y := 1; y < e.config.height; y += 4 {
					row := planes[0][y * strides[0]:][:e.config.width]
					prev := planes[0][(y - 1) * strides[0]:][:e.config.width]
					for x := 0; x < len(row); x += 4 {
						flat += int(row[x] == prev[x])
						total += 1
					}
				}
			} else {
				p16 := plane_t(planes[0], u16)
				for y := 1; y < e.config.height; y += 4 {
					row := p16[y * strides[0]:][:e.config.width]
					prev := p16[(y - 1) * strides[0]:][:e.config.width]
					for x := 0; x < len(row); x += 4 {
						flat += int(row[x] == prev[x])
						total += 1
					}
				}
			}
			e.q_idx = flat * 3 > total * 2 ? scale_q_idx(e.bit_depth, e.config.base_q_idx, 45, 100) : max(1, (e.config.base_q_idx * 3) >> 2)
		} else if is_altref {
			e.q_idx = scale_q_idx(e.bit_depth, e.config.base_q_idx, 65, 100)
		} else {
			skip_0 := int(e.counts.skip[0][0] + e.counts.skip[1][0] + e.counts.skip[2][0])
			if (e.last_keyframe ? skip_0 * 5 : skip_0 * 16) < e.mi_cols * e.mi_rows && e.config.keyframe_interval >= 8 {
				gf_rates := [8]i32{65, 110, 95, 110, 80, 110, 95, 110}
				e.q_idx = scale_q_idx(e.bit_depth, e.config.base_q_idx, gf_rates[gop_frame & 7], 100)
			} else {
				e.q_idx = e.config.base_q_idx
			}
		}
	} else {
		e.q_idx = e.config.base_q_idx
	}
	e.lossless = e.q_idx == 0 && e.config.delta_q_y_dc == 0 && e.config.delta_q_uv_dc == 0 && e.config.delta_q_uv_ac == 0 && !e.segmentation.enabled
	for seg in 0 ..< vp9.MAX_SEGMENTS {
		q := vp9.segment_qindex(&e.segmentation, e.q_idx, seg)
		e.dequant[seg][0] = {vp9.dc_q(e.bit_depth, q + e.config.delta_q_y_dc), vp9.ac_q(e.bit_depth, q)}
		e.dequant[seg][1] = {vp9.dc_q(e.bit_depth, q + e.config.delta_q_uv_dc), vp9.ac_q(e.bit_depth, q + e.config.delta_q_uv_ac)}
	}
	if e.segmentation.enabled {
		e.seg_update_data = e.keyframe || e.segmentation.feature_enabled != e.last_seg_enabled || e.segmentation.feature_data != e.last_seg_data || e.segmentation.abs_or_delta_update != e.last_seg_abs
		if e.keyframe || e.segmentation.tree_probs[0] == 0 {
			for &p in e.segmentation.tree_probs do p = 255
			for &p in e.segmentation.pred_probs do p = 255
		}
		if e.keyframe {
			for &v in e.prev_segment_ids do v = 0
		}
	}
	e.filter_levels = encoder_filter_levels(e)
	e.allow_hp = !e.config.ultrafast && !e.keyframe && !e.lossless && e.q_idx < 128
	e.frame_context_idx = e.keyframe ? 0 : clamp(e.frame_context_idx, 0, 3)
	if e.keyframe {
		vp9.default_probabilities(&e.probs)
		for &ctx in e.contexts do ctx = e.probs
	} else {
		e.probs = e.contexts[e.frame_context_idx]
		build_mv_costs(e)
	}
	if !e.config.ultrafast do build_sym_probs(e)
	for &t in e.tiles {
		t.e = e
		t.counts = {}
		for &v in t.above_partition do v = 0
		for &v in t.above_seg_pred do v = 0
		for &v in t.above_context do v = {}
		for &a in t.above_nonzero do for &v in a do v = 0
	}
	if e.config.pool != nil && e.config.pool.run != nil {
		e.config.pool.run(e.config.pool, len(e.tiles), encode_tiles, raw_data(e.tiles))
	} else {
		encode_tiles(raw_data(e.tiles), 0, len(e.tiles))
	}
	filter_frame(e)
	extend_borders(e)
	e.counts = {}
	for &t in e.tiles {
		vp9.add_counts(&e.counts.base, &t.counts.base)
		for s in 0 ..< vp9.MAX_SEGMENTS do e.counts.seg_tree[s] += t.counts.seg_tree[s]
		for ctx in 0 ..< 3 do for b in 0 ..< 2 do e.counts.seg_pred[ctx][b] += t.counts.seg_pred[ctx][b]
	}
	saved := e.probs
	update_segmentation_probs(e)
	build_compressed_header(e)
	build_sym_probs(e)
	if e.config.pool != nil && e.config.pool.run != nil {
		e.config.pool.run(e.config.pool, len(e.tiles), flush_tiles, raw_data(e.tiles))
	} else {
		flush_tiles(raw_data(e.tiles), 0, len(e.tiles))
	}
	// A failed append leaves the reference and frame counter untouched.
	failed := e.header.failed
	for &t in e.tiles do failed ||= t.b.failed
	if failed {e.probs = saved; return nil, false, .Out_Of_Memory}
	clear(&e.packet)
	if !build_uncompressed_header(e) {e.probs = saved; return nil, false, .Out_Of_Memory}
	total := len(e.packet) + len(e.header.data)
	for &t in e.tiles do total += 4 + len(t.b.data)
	if reserve(&e.packet, total) != nil {e.probs = saved; return nil, false, .Out_Of_Memory}
	append(&e.packet, ..e.header.data[:])
	for &t, i in e.tiles {
		if i + 1 < len(e.tiles) {
			n := len(t.b.data)
			for k := 3; k >= 0; k -= 1 do append(&e.packet, u8(n >> uint(k * 8)))
		}
		append(&e.packet, ..t.b.data[:])
	}
	vp9.load_probs(&e.probs, &saved)
	vp9.adapt_coef_probs(&e.probs, &e.counts.base, e.keyframe, e.last_keyframe)
	if !e.keyframe {
		vp9.load_probs2(&e.probs, &saved)
		vp9.adapt_noncoef_probs(&e.probs, &e.counts.base, !e.config.ultrafast && !e.lossless, !e.lossless, e.allow_hp)
	}
	e.contexts[e.frame_context_idx] = e.probs
	if e.segmentation.enabled {
		e.last_seg_enabled = e.segmentation.feature_enabled
		e.last_seg_data = e.segmentation.feature_data
		e.last_seg_abs = e.segmentation.abs_or_delta_update
		if e.segmentation.update_map do copy(e.prev_segment_ids, e.segment_ids)
	}
	e.last_keyframe = e.keyframe
	e.last_show_frame = e.show_frame
	e.motion, e.prev_motion = e.prev_motion, e.motion
	if is_altref {
		for p in 0 ..< 3 {
			e.planes[p], e.altref[p] = e.altref[p], e.planes[p]
			e.planes_storage[p], e.altref_storage[p] = e.altref_storage[p], e.planes_storage[p]
		}
		e.has_altref = true
		e.last_recon = e.altref
	} else {
		for p in 0 ..< 3 {
			e.planes[p], e.reference[p] = e.reference[p], e.planes[p]
			e.planes_storage[p], e.reference_storage[p] = e.reference_storage[p], e.planes_storage[p]
			if e.keyframe || e.refresh_golden do copy(e.golden_storage[p], e.reference_storage[p])
			if e.keyframe do copy(e.altref_storage[p], e.reference_storage[p])
		}
		if e.keyframe do e.has_altref = false
		e.last_recon = e.reference
		e.frames += 1
	}
	return e.packet[:], e.keyframe, .None
}

// Latest reconstructed (post-filter) image, same lifetime as encode_frame's packet.
reconstruction :: proc(e: ^Encoder) -> (planes: [3][]u8, strides: [3]int) {
	return e.last_recon, e.strides
}

reconstruction16 :: proc(e: ^Encoder) -> (planes: [3][]u16, strides: [3]int) {
	return {plane_t(e.last_recon[0], u16), plane_t(e.last_recon[1], u16), plane_t(e.last_recon[2], u16)}, e.strides
}

destroy_encoder :: proc(e: ^Encoder) {
	if e == nil do return
	context.allocator = e.allocator
	for p in 0 ..< 3 {delete(e.planes_storage[p]); delete(e.reference_storage[p]); delete(e.golden_storage[p]); delete(e.altref_storage[p]); delete(e.source[p])}
	for &t in e.tiles {
		delete(t.b.data); delete(t.syms); delete(t.above_partition); delete(t.above_seg_pred); delete(t.above_context)
		for a in t.above_nonzero do delete(a)
	}
	delete(e.tiles); delete(e.motion); delete(e.prev_motion); delete(e.segment_ids); delete(e.prev_segment_ids); delete(e.filter_cells); delete(e.packet); delete(e.header.data)
	e^ = {}
}

// Replicates the visible picture's edges outwards, through the alignment
// padding and border, as the decoder's clamped reference reads would see them.
@(private)
extend_borders :: proc(e: ^Encoder) {
	if e.bit_depth == 8 {
		extend_borders_typed(e, u8)
	} else {
		extend_borders_typed(e, u16)
	}
}

@(private)
extend_borders_typed :: proc(e: ^Encoder, $T: typeid) {
	for p in 0 ..< 3 {
		sx, sy := p > 0 ? e.ss_x : 0, p > 0 ? e.ss_y : 0
		w, h := (e.config.width + sx) >> uint(sx), (e.config.height + sy) >> uint(sy)
		stride := e.strides[p]
		storage := plane_t(e.planes_storage[p], T)
		rows := len(storage) / stride
		for y in BORDER ..< BORDER + h {
			row := storage[y * stride:][:stride]
			for &v in row[:BORDER] do v = row[BORDER]
			for &v in row[BORDER + w:] do v = row[BORDER + w - 1]
		}
		for y in 0 ..< BORDER do copy(storage[y * stride:][:stride], storage[BORDER * stride:][:stride])
		last := (BORDER + h - 1) * stride
		for y in BORDER + h ..< rows do copy(storage[y * stride:][:stride], storage[last:][:stride])
	}
}

@(private)
scale_q_idx :: proc(bit_depth, base_q_idx: int, num, den: i32) -> int {
	target := (vp9.ac_q(bit_depth, base_q_idx) * num + (den >> 1)) / den
	q := 1
	for q < 255 && vp9.ac_q(bit_depth, q) < target do q += 1
	return q
}

@(private)
tile_limits :: proc(sb_cols: int) -> (minimum, maximum: int) {
	for vp9.MAX_TILE_WIDTH_B64 << uint(minimum) < sb_cols do minimum += 1
	maximum = 1
	for sb_cols >> uint(maximum) >= vp9.MIN_TILE_WIDTH_B64 do maximum += 1
	maximum -= 1
	return
}

@(private)
encode_tiles :: proc(data: rawptr, first, end: int) {
	tiles := (cast([^]Tile)data)[first:end]
	for &t in tiles {
		context.allocator = t.e.allocator
		encode_tile(&t)
	}
}

@(private)
flush_tiles :: proc(data: rawptr, first, end: int) {
	tiles := (cast([^]Tile)data)[first:end]
	for &t in tiles {
		context.allocator = t.e.allocator
		flush_tile(&t)
	}
}

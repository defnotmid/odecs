package vp9_encoder

import vp9 ".."
import common "../../../common"
import "core:mem"

Error :: enum {None, Invalid_Argument, Out_Of_Memory, Closed}

Encoder_Config :: struct {
	width, height: int,
	base_q_idx: int, // 0..255; zero is exactly lossless
	keyframe_interval: int, // zero selects 120
	block_log2: int, // 3..5: fixed 8, 16 or 32 pixel partitions; zero selects 8
	disable_loop_filter: bool,
	search_range: int, // integer pixels; zero selects 16
	tile_cols_log2: int, // clipped to the VP9 limits for the width
	pool: ^common.Work_Pool,
}

// Pictures are superblock-aligned planes inside a replicated border. A motion
// vector reaches at most 64 samples (32 in chroma) beyond its block, plus the
// 8-tap filter's 3/4 samples, so no analysis or prediction read needs clamping.
BORDER :: 80

Encoder :: struct {
	config: Encoder_Config,
	allocator: mem.Allocator,
	planes, reference: [3][]u8, // interiors: the first visible sample first
	planes_storage, reference_storage: [3][]u8, // bordered
	strides: [3]int,
	input: [3][]u8,
	input_strides: [3]int,
	// The input staged per superblock row by each tile: aligned, edges replicated.
	source: [3][]u8,
	source_strides: [3]int,
	mi: []vp9.Mode_Info,
	filter_cells: []vp9.Filter_Cell, // beside mi: what the loop filter reads
	filter_levels: vp9.Filter_Levels,
	mi_cols, mi_rows, sb_cols, sb_rows: int,
	probs: vp9.Probabilities,
	forward: vp9.Forward_Transforms,
	tiles: []Tile,
	packet: [dynamic]u8,
	header: Bool_Writer,
	frames: u64,
	keyframe, initialized: bool,
}

// Init owns all persistent buffers with the calling allocator. The encoder
// must not move during encode_frame; no worker creates threads or publishes data.
init_encoder :: proc(e: ^Encoder, config: Encoder_Config) -> Error {
	if e == nil || config.width <= 0 || config.height <= 0 || config.width > 65536 || config.height > 65536 || config.base_q_idx < 0 || config.base_q_idx > 255 || config.keyframe_interval < 0 || config.tile_cols_log2 < 0 || config.search_range < 0 || config.search_range > 64 || (config.block_log2 != 0 && (config.block_log2 < 3 || config.block_log2 > 5)) do return .Invalid_Argument
	e^ = {config = config, allocator = context.allocator}
	if e.config.keyframe_interval == 0 do e.config.keyframe_interval = 120
	if e.config.search_range == 0 do e.config.search_range = 16
	if e.config.block_log2 == 0 do e.config.block_log2 = 3
	vp9.init_forward_transforms(&e.forward)
	e.mi_cols, e.mi_rows = (config.width + 7) / 8, (config.height + 7) / 8
	e.sb_cols, e.sb_rows = (e.mi_cols + 7) / 8, (e.mi_rows + 7) / 8
	if i64(e.sb_cols) * i64(e.sb_rows) * 4096 > i64(max(int)) / 16 {e^ = {}; return .Out_Of_Memory}
	minimum, maximum := tile_limits(e.sb_cols)
	e.config.tile_cols_log2 = clamp(config.tile_cols_log2, minimum, maximum)
	vp9.default_probabilities(&e.probs)
	ok := false
	defer if !ok do destroy_encoder(e)
	err: mem.Allocator_Error
	e.mi, err = make([]vp9.Mode_Info, e.mi_cols * e.mi_rows)
	if err != nil do return .Out_Of_Memory
	e.filter_cells, err = make([]vp9.Filter_Cell, e.mi_cols * e.mi_rows)
	if err != nil do return .Out_Of_Memory
	e.filter_levels = encoder_filter_levels(e)
	for p in 0 ..< 3 {
		shift := p > 0 ? uint(1) : 0
		aligned_w, aligned_h := e.sb_cols * 64 >> shift, e.sb_rows * 64 >> shift
		e.strides[p] = aligned_w + 2 * BORDER
		bytes := e.strides[p] * (aligned_h + 2 * BORDER)
		e.planes_storage[p], err = make([]u8, bytes)
		if err != nil do return .Out_Of_Memory
		e.reference_storage[p], err = make([]u8, bytes)
		if err != nil do return .Out_Of_Memory
		origin := BORDER * e.strides[p] + BORDER
		e.planes[p], e.reference[p] = e.planes_storage[p][origin:], e.reference_storage[p][origin:]
		e.source_strides[p] = aligned_w
		e.source[p], err = make([]u8, aligned_w * aligned_h)
		if err != nil do return .Out_Of_Memory
	}
	e.tiles, err = make([]Tile, 1 << uint(e.config.tile_cols_log2))
	if err != nil do return .Out_Of_Memory
	for &t, i in e.tiles {
		t.first_col = ((i * e.sb_cols) >> uint(e.config.tile_cols_log2)) * 8
		t.end_col = min(e.mi_cols, (((i + 1) * e.sb_cols) >> uint(e.config.tile_cols_log2)) * 8)
		t.above_partition, err = make([]u8, e.sb_cols * 8)
		if err != nil do return .Out_Of_Memory
		for p in 0 ..< 3 {
			t.above_nonzero[p], err = make([]u8, e.sb_cols * (p > 0 ? 8 : 16))
			if err != nil do return .Out_Of_Memory
		}
		err = reserve(&t.b.data, max(64, (t.end_col - t.first_col) * 8 * e.sb_rows * 64 * 8))
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
// Input is planar 8-bit 4:2:0, with ceil(width/2), ceil(height/2) chroma.
encode_frame :: proc(e: ^Encoder, planes: [3][]u8, strides: [3]int) -> (packet: []u8, keyframe: bool, err: Error) {
	if e == nil || !e.initialized do return nil, false, .Closed
	for p in 0 ..< 3 {
		shift := p > 0 ? uint(1) : 0
		w, h := (e.config.width + int(shift)) >> shift, (e.config.height + int(shift)) >> shift
		if strides[p] < w || i128(h - 1) * i128(strides[p]) + i128(w) > i128(len(planes[p])) do return nil, false, .Invalid_Argument
	}
	context.allocator = e.allocator
	e.input, e.input_strides = planes, strides
	e.keyframe = e.frames % u64(e.config.keyframe_interval) == 0
	for &t in e.tiles {
		t.e = e
		for &v in t.above_partition do v = 0
		for &a in t.above_nonzero do for &v in a do v = 0
	}
	if e.config.pool != nil && e.config.pool.run != nil {
		e.config.pool.run(e.config.pool, len(e.tiles), encode_tiles, raw_data(e.tiles))
	} else {
		encode_tiles(raw_data(e.tiles), 0, len(e.tiles))
	}
	filter_frame(e)
	extend_borders(e)
	build_compressed_header(e)
	// A failed append leaves the reference and frame counter untouched.
	failed := e.header.failed
	for t in e.tiles do failed ||= t.b.failed
	if failed do return nil, false, .Out_Of_Memory
	clear(&e.packet)
	if !build_uncompressed_header(e) do return nil, false, .Out_Of_Memory
	total := len(e.packet) + len(e.header.data)
	for t in e.tiles do total += 4 + len(t.b.data)
	if reserve(&e.packet, total) != nil do return nil, false, .Out_Of_Memory
	append(&e.packet, ..e.header.data[:])
	for t, i in e.tiles {
		if i + 1 < len(e.tiles) {
			n := len(t.b.data)
			for k := 3; k >= 0; k -= 1 do append(&e.packet, u8(n >> uint(k * 8)))
		}
		append(&e.packet, ..t.b.data[:])
	}
	for p in 0 ..< 3 {
		e.planes[p], e.reference[p] = e.reference[p], e.planes[p]
		e.planes_storage[p], e.reference_storage[p] = e.reference_storage[p], e.planes_storage[p]
	}
	e.frames += 1
	return e.packet[:], e.keyframe, .None
}

// Latest reconstructed (post-filter) image, same lifetime as encode_frame's packet.
reconstruction :: proc(e: ^Encoder) -> (planes: [3][]u8, strides: [3]int) {
	return e.reference, e.strides
}

destroy_encoder :: proc(e: ^Encoder) {
	if e == nil do return
	context.allocator = e.allocator
	for p in 0 ..< 3 {delete(e.planes_storage[p]); delete(e.reference_storage[p]); delete(e.source[p])}
	for &t in e.tiles {
		delete(t.b.data); delete(t.above_partition)
		for a in t.above_nonzero do delete(a)
	}
	delete(e.tiles); delete(e.mi); delete(e.filter_cells); delete(e.packet); delete(e.header.data)
	e^ = {}
}

// Replicates the visible picture's edges outwards, through the alignment
// padding and border, as the decoder's clamped reference reads would see them.
@(private)
extend_borders :: proc(e: ^Encoder) {
	for p in 0 ..< 3 {
		shift := p > 0 ? uint(1) : 0
		w, h := (e.config.width + int(shift)) >> shift, (e.config.height + int(shift)) >> shift
		stride := e.strides[p]
		rows := len(e.planes_storage[p]) / stride
		storage := e.planes_storage[p]
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

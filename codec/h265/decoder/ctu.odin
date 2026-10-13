package h265_decoder


import hevc ".."
import "core:slice"

// ---------------------------------------------------------------------------
// Coding tree unit decoding for the intra path (7.3.8.2..7.3.8.11), ported from
// gen2brain/h265 hevc/ctu.go (MIT). Inter prediction and in-loop filters live
// in their own files; the pieces the tile and wavefront geometry touches are
// here with the decoding order and availability they define.
// ---------------------------------------------------------------------------

PART_2NX2N :: 0
PART_2NXN :: 1
PART_NX2N :: 2
PART_NXN :: 3
PART_2NXNU :: 4
PART_2NXND :: 5
PART_NLX2N :: 6
PART_NRX2N :: 7

// Block_Info is what boundary strength derivation reads back after decoding,
// at the granularity of a 4x4 block.
Block_Info :: struct {
	intra: bool,
	cbf:   bool,
	tu_v:  bool,
	tu_h:  bool,
	pu_v:  bool,
	pu_h:  bool,
}

// Ctu_Grids is the picture-sized storage a CTU decoder retains across
// pictures of one shape: z-scan and tile-scan tables, per-min-TB and per-4x4
// coding records, and per-CTB filter records.
Ctu_Grids :: struct {
	min_tb_log2:    int,
	min_tb_width:   int,
	min_tb_addr:    []i32,
	intra_mode:     []u8,
	intra_mode_c:   []u8,
	cu_depth:       []u8,
	qp_y:           []i8,
	skipped:        []bool,
	no_filter:      []bool,
	sao:            []Sao_Ctb,

	// The picture-wide motion field is subsampled to 4x4. `blk.intra` says
	// whether a block's record means anything.
	blk:            []Block_Info,
	motion:         []Motion,
	mv_width:       int,

	// Tiles and wavefronts: the 6.5.1 raster-to-tile-scan mapping and the tile
	// of each coding tree block.
	rs_to_ts:       []i32,
	ts_to_rs:       []i32,
	tile_id:        []i32,
	// Per-raster-CTB slice group (6.4.1's same-slice test), and each group's
	// in-loop filter controls by its address.
	ctb_slice_addr: []i32,
	slice_filters:  []Slice_Filters,

	// The geometry the grids and scan tables were built for.
	shape:          Ctu_Shape,
}

// A slice group's in-loop filter controls (7.4.7.1), which the filters read
// back once the picture is decoded: deblocking by the slice holding an
// edge's q0 sample (8.7.2), SAO by the slice holding the coding tree block.
Slice_Filters :: struct {
	beta_offset_div2, tc_offset_div2:                              i32,
	deblocking_disabled, loop_filter_across, sao_luma, sao_chroma: bool,
}

Ctu_Decoder :: struct($Sample: typeid) {
	grids:             Ctu_Grids,
	c:                 Cabac,
	s:                 ^SPS,
	p:                 ^PPS,
	sh:                ^Slice_Header,
	pic:               ^Picture,
	sao_type:          [3]int,
	eo_class:          [2]int,
	qp_y_prev:         i32,
	qp_y_cur:          i32,
	qp_y_pred:         i32,
	qp_coded:          bool,
	qp_delta:          i32,
	bypass:            bool,
	cur_intra:         bool,
	stat_coef:         [4]u8,
	coef:              [32 * 32]i32,
	cur_x:             int,
	cur_y:             int,
	cu_x:              int,
	cu_y:              int,
	cu_size:           int,
	pu_w:              int,
	pu_h:              int,
	part_idx:          int,
	last_merge:        bool,
	ref_poc:           [2][]i32,
	ref_long:          [2][]bool,
	ref_pics:          [2][]^Picture,
	// Active reference views borrow these fixed slice-owned arrays. Every
	// admitted native header has at most MAX_REFS entries; continuation slices
	// replace the views without allocating or abandoning previous lists.
	ref_poc_storage:   [2][MAX_REFS]i32,
	ref_long_storage:  [2][MAX_REFS]bool,
	ref_pic_storage:   [2][MAX_REFS]^Picture,
	poc:               i32,
	col_pic:           ^Picture,
	no_backward_pred:  bool,

	// Scratch for one prediction unit, the largest being 64x64 luma. Motion
	// compensation runs for every unit, so none of this may be allocated.
	mc_buf:            [2][64 * 64]i16,
	mc:                Mc_Scratch(Sample),
	// The deblocked samples SAO reads (8.7.3), retained across pictures.
	sao_src:           [dynamic]Sample,
	merge_cd:          [8]Mv_Info,
	ref:               Ref_Samples,
	avail:             [4 * 32 + 1]bool,
	simple_avail:      bool,
	slice_addr_rs:     int,
	dep_slice_addr_rs: int,

	// The 9.3.1 wavefront context handoff.
	saved:             [CABAC_N_CONTEXTS]u8,
	has_saved:         bool,
	// The context state a slice segment ended with, for the dependent slice
	// segment that carries on from it (9.3.1).
	dep_saved:         [CABAC_N_CONTEXTS]u8,
	has_dep_saved:     bool,
}

// Ctu_Shape is everything the grid sizes, the 6.5.1 tile scan and the 6.5.2
// z-scan addresses derive from. Pictures with an equal shape reuse them.
Ctu_Shape :: struct {
	width, height:  u32,
	ctb_log2:       u8,
	min_tb_log2:    u8,
	n_cols, n_rows: int,
	cols:           [MAX_TILE_COLUMNS]u32,
	rows:           [MAX_TILE_ROWS]u32,
}

ctu_shape :: proc(s: ^SPS, p: ^PPS) -> (k: Ctu_Shape) {
	k.width, k.height = s.pic_width_in_luma_samples, s.pic_height_in_luma_samples
	k.ctb_log2, k.min_tb_log2 = s.ctb_log2_size_y, s.min_tb_log2_size_y
	k.n_cols = copy(k.cols[:], p.col_widths_in_ctbs)
	k.n_rows = copy(k.rows[:], p.row_heights_in_ctbs)
	return
}

new_ctu_decoder :: proc(
	$Sample: typeid,
	s: ^SPS,
	p: ^PPS,
	sh: ^Slice_Header,
	pic: ^Picture,
) -> Ctu_Decoder(Sample) {
	d: Ctu_Decoder(Sample)
	reset_ctu_decoder(&d, s, p, sh, pic)
	return d
}

// reset_ctu_decoder starts a picture in a retained CTU decoder. Grids keep
// their backing across pictures of one shape. Only the grids that coding
// marks sparsely (edge, bypass, SAO and slice records) are cleared; every
// other entry is written by its coding unit before a decoded neighbour, the
// filters or the collocated store read it.
reset_ctu_decoder :: proc(
	d: ^Ctu_Decoder($Sample),
	s: ^SPS,
	p: ^PPS,
	sh: ^Slice_Header,
	pic: ^Picture,
) {
	shape := ctu_shape(s, p)
	if d.grids.min_tb_addr == nil || shape != d.grids.shape do size_ctu_grids(d, s, p, shape)

	// Per-picture state restarts from zero, as a fresh decoder would.
	grids, sao_src := d.grids, d.sao_src
	d^ = {}
	d.grids, d.sao_src = grids, sao_src
	d.s, d.p, d.sh, d.pic = s, p, sh, pic

	slice.zero(d.grids.no_filter)
	slice.zero(d.grids.sao)
	slice.zero(d.grids.blk)
	slice.zero(d.grids.ctb_slice_addr)
	slice.zero(d.grids.slice_filters)

	d.qp_y_prev = sh.qp_y
	d.qp_y_cur = sh.qp_y
}

@(private)
size_ctu_grids :: proc(d: ^Ctu_Decoder($Sample), s: ^SPS, p: ^PPS, shape: Ctu_Shape) {
	destroy_ctu_grids(&d.grids)

	g := &d.grids
	g.shape = shape
	d.s, d.p = s, p

	g.min_tb_log2 = int(s.min_tb_log2_size_y)
	g.min_tb_width =
		(int(s.pic_width_in_luma_samples) + (1 << uint(g.min_tb_log2)) - 1) >> uint(g.min_tb_log2)

	tb_w := g.min_tb_width
	tb_h :=
		(int(s.pic_height_in_luma_samples) + (1 << uint(g.min_tb_log2)) - 1) >> uint(g.min_tb_log2)

	mv_w := (int(s.pic_width_in_luma_samples) + 3) / 4
	mv_h := (int(s.pic_height_in_luma_samples) + 3) / 4
	g.mv_width = mv_w

	g.min_tb_addr = make([]i32, tb_w * tb_h)
	g.intra_mode = make([]u8, tb_w * tb_h)
	g.intra_mode_c = make([]u8, tb_w * tb_h)
	g.cu_depth = make([]u8, tb_w * tb_h)
	g.qp_y = make([]i8, tb_w * tb_h)
	g.skipped = make([]bool, tb_w * tb_h)
	g.no_filter = make([]bool, tb_w * tb_h)

	g.sao = make([]Sao_Ctb, int(s.pic_width_in_ctbs) * int(s.pic_height_in_ctbs))

	g.blk = make([]Block_Info, mv_w * mv_h)
	g.motion = make([]Motion, mv_w * mv_h)

	ctbs := int(s.pic_width_in_ctbs) * int(s.pic_height_in_ctbs)
	g.rs_to_ts = make([]i32, ctbs)
	g.ts_to_rs = make([]i32, ctbs)
	g.tile_id = make([]i32, ctbs)
	g.ctb_slice_addr = make([]i32, ctbs)
	g.slice_filters = make([]Slice_Filters, ctbs)

	build_tile_scan(d)
	build_min_tb_addr(d, tb_h)
}

// end_ctu_picture releases the picture's owned slice header and keeps the
// grids for the next picture.
end_ctu_picture :: proc(d: ^Ctu_Decoder($Sample)) {
	if d.sh != nil {
		destroy_slice_header(d.sh)
		free(d.sh)
		d.sh = nil
	}
}

@(private)
destroy_ctu_grids :: proc(g: ^Ctu_Grids) {
	delete(g.min_tb_addr)
	delete(g.intra_mode)
	delete(g.intra_mode_c)
	delete(g.cu_depth)
	delete(g.qp_y)
	delete(g.skipped)
	delete(g.no_filter)
	delete(g.sao)
	delete(g.blk)
	delete(g.motion)
	delete(g.rs_to_ts)
	delete(g.ts_to_rs)
	delete(g.tile_id)
	delete(g.ctb_slice_addr)
	delete(g.slice_filters)
	g^ = {}
}

destroy_ctu_decoder :: proc(d: ^Ctu_Decoder($Sample)) {
	destroy_ctu_grids(&d.grids)
	delete(d.sao_src)
	end_ctu_picture(d)
	d^ = {}
}

// build_tile_scan is 6.5.1: the raster-to-tile-scan conversion and the tile
// each coding tree block belongs to. With one tile (the no-tiles case) the
// mapping is the identity and every block is in tile 0.
build_tile_scan :: proc(d: ^Ctu_Decoder($Sample)) {
	w, h := int(d.s.pic_width_in_ctbs), int(d.s.pic_height_in_ctbs)
	cols, rows := d.p.col_widths_in_ctbs, d.p.row_heights_in_ctbs

	col_bd: [MAX_TILE_COLUMNS + 1]u32
	row_bd: [MAX_TILE_ROWS + 1]u32

	for i in 0 ..< len(cols) do col_bd[i + 1] = col_bd[i] + cols[i]
	for i in 0 ..< len(rows) do row_bd[i + 1] = row_bd[i] + rows[i]

	for rs in 0 ..< w * h {
		x, y := rs % w, rs / w

		tb_x, tb_y: int

		for i in 0 ..< len(cols) {
			if u32(x) >= col_bd[i] do tb_x = i
		}

		for i in 0 ..< len(rows) {
			if u32(y) >= row_bd[i] do tb_y = i
		}

		ts := 0
		for i in 0 ..< tb_x do ts += int(rows[tb_y]) * int(cols[i])
		for i in 0 ..< tb_y do ts += w * int(rows[i])
		ts += (y - int(row_bd[tb_y])) * int(cols[tb_x]) + x - int(col_bd[tb_x])

		d.grids.rs_to_ts[rs] = i32(ts)
		d.grids.ts_to_rs[ts] = i32(rs)
		d.grids.tile_id[ts] = i32(tb_y * len(cols) + tb_x)
	}
}

// build_min_tb_addr is the MinTbAddrZs derivation of 6.5.2. The value is a
// per-coding-tree-block base plus an offset that depends only on the position
// within the block, so the offset is tabulated once. The base is the block's
// 6.5.1 tile-scan index, which is the order 6.4.1 compares against.
build_min_tb_addr :: proc(d: ^Ctu_Decoder($Sample), h: int) #no_bounds_check {
	shift := int(d.s.ctb_log2_size_y) - d.grids.min_tb_log2
	side := 1 << uint(shift)
	mask := side - 1

	off: [16][16]int

	for yl in 0 ..< side {
		for xl in 0 ..< side {
			v := 0

			for i in 0 ..< shift {
				m := 1 << uint(i)

				if m & xl != 0 do v += m * m
				if m & yl != 0 do v += 2 * m * m
			}

			off[yl][xl] = v
		}
	}

	ctb_width := int(d.s.pic_width_in_ctbs)

	for y in 0 ..< h {
		yy := y >> uint(shift)
		base := y * d.grids.min_tb_width

		for x in 0 ..< d.grids.min_tb_width {
			ctb := d.grids.rs_to_ts[ctb_width * yy + (x >> uint(shift))]
			d.grids.min_tb_addr[base + x] =
				i32(ctb << uint(shift * 2)) + i32(off[y & mask][x & mask])
		}
	}
}

tb_index :: #force_inline proc(d: ^Ctu_Decoder($Sample), x, y: int) -> int #no_bounds_check {
	return (y >> uint(d.grids.min_tb_log2)) * d.grids.min_tb_width + x >> uint(d.grids.min_tb_log2)
}

// available is the z-scan availability of 6.4.1. With one tile and a slice
// starting at the first coding tree block, everything earlier in tile-scan
// order is in the same slice and the same tile, so the order test suffices;
// otherwise a neighbour in another tile is not available. (Slices still span
// a whole picture here, so the same-slice test is implied.)
// Current coordinates are a decoded block origin; neighbor coordinates are
// checked below before indexing the picture-sized min-TB and CTB grids.
available :: #force_inline proc(
	d: ^Ctu_Decoder($Sample),
	x_curr, y_curr, x_n, y_n: int,
) -> bool #no_bounds_check {
	if x_n < 0 ||
	   y_n < 0 ||
	   x_n >= int(d.s.pic_width_in_luma_samples) ||
	   y_n >= int(d.s.pic_height_in_luma_samples) {
		return false
	}

	if d.grids.min_tb_addr[tb_index(d, x_n, y_n)] >=
	   d.grids.min_tb_addr[tb_index(d, x_curr, y_curr)] {
		return false
	}

	if d.simple_avail do return true

	shift := uint(d.s.ctb_log2_size_y)
	w := int(d.s.pic_width_in_ctbs)
	cur_rs := (y_curr >> shift) * w + x_curr >> shift
	nb_rs := (y_n >> shift) * w + x_n >> shift

	if d.grids.tile_id[d.grids.rs_to_ts[cur_rs]] != d.grids.tile_id[d.grids.rs_to_ts[nb_rs]] do return false

	// 6.4.1 wants the neighbour in the same slice. Slices follow the tile
	// scan, so a raster comparison would admit one from a slice already
	// finished.
	return d.grids.ctb_slice_addr[nb_rs] == i32(d.slice_addr_rs)
}

// filter_edge is the filterEdgeFlag derivation of 8.7.2 and the availability
// part of 8.7.3: filtering may not cross a tile boundary the PPS closes off
// (or a slice boundary the slice itself closes off, which a single-slice
// picture cannot have internally).
filter_edge :: proc(d: ^Ctu_Decoder($Sample), x_p, y_p, x_q, y_q: int) -> bool {
	shift := uint(d.s.ctb_log2_size_y)
	w := int(d.s.pic_width_in_ctbs)
	p_rs := (y_p >> shift) * w + x_p >> shift
	q_rs := (y_q >> shift) * w + x_q >> shift

	if p_rs == q_rs do return true

	if d.p.tiles_enabled &&
	   !d.p.loop_filter_across_tiles &&
	   d.grids.tile_id[d.grids.rs_to_ts[p_rs]] != d.grids.tile_id[d.grids.rs_to_ts[q_rs]] {
		return false
	}

	// 8.7.2: the filter may cross a slice boundary only when the slice
	// closes its own loop filter off.
	if d.grids.ctb_slice_addr[p_rs] != d.grids.ctb_slice_addr[q_rs] {
		if !d.grids.slice_filters[d.grids.ctb_slice_addr[q_rs]].loop_filter_across do return false
	}

	return true
}

ctu_fill :: proc(d: ^Ctu_Decoder($Sample), arr: []$T, x, y, size: int, v: T) #no_bounds_check {
	// Fill the min-TB grid directly: the cell size in each direction is
	// size / min_tb, and each row of that sub-grid is one flat, unit-stride run.
	n := size >> uint(d.grids.min_tb_log2)
	ix := x >> uint(d.grids.min_tb_log2)
	iy := y >> uint(d.grids.min_tb_log2)

	for j in 0 ..< n {
		base := (iy + j) * d.grids.min_tb_width + ix
		for i in 0 ..< n do arr[base + i] = v
	}
}

blk_index :: #force_inline proc(d: ^Ctu_Decoder($Sample), x, y: int) -> int #no_bounds_check {
	return (y >> 2) * d.grids.mv_width + x >> 2
}

// blocks_in is how many blocks of a region fall inside the picture, so the
// loops that walk one need no bound on each block.
blocks_in :: proc(d: ^Ctu_Decoder($Sample), x, y, w, h, log2: int) -> (int, int) {
	last := 1 << uint(log2) - 1

	nw := min(x + w, int(d.s.pic_width_in_luma_samples)) - x
	nh := min(y + h, int(d.s.pic_height_in_luma_samples)) - y

	return max(nw + last, 0) >> uint(log2), max(nh + last, 0) >> uint(log2)
}

mark_tu :: proc(d: ^Ctu_Decoder($Sample), x, y, w, h: int, cbf: bool) #no_bounds_check {
	nw, nh := blocks_in(d, x, y, w, h, 2)

	for j in 0 ..< nh {
		base := (y >> 2 + j) * d.grids.mv_width + x >> 2

		if cbf {
			for i in 0 ..< nw do d.grids.blk[base + i].cbf = true
		}

		// The edges of 8.7.2 are the first column and the first row of the
		// block, so only those carry a flag.
		if j == 0 {
			for i in 0 ..< nw do d.grids.blk[base + i].tu_h = true
		}

		d.grids.blk[base].tu_v = true
	}
}

mark_pu :: proc(d: ^Ctu_Decoder($Sample), x, y, w, h: int, intra: bool) #no_bounds_check {
	nw, nh := blocks_in(d, x, y, w, h, 2)

	for j in 0 ..< nh {
		base := (y >> 2 + j) * d.grids.mv_width + x >> 2

		for i in 0 ..< nw do d.grids.blk[base + i].intra = intra

		if j == 0 {
			for i in 0 ..< nw do d.grids.blk[base + i].pu_h = true
		}

		d.grids.blk[base].pu_v = true
	}
}

// intra_chroma_mode is Table 8-2 (and 8-3 for 4:2:2).
intra_chroma_mode :: proc(d: ^Ctu_Decoder($Sample), luma: int) -> int {
	mode := luma

	if cabac_decode_bin(&d.c, ctxIntraChromaPredMode) != 0 {
		idx := int(cabac_decode_bypass_bits(&d.c, 2))
		modes := [4]int{INTRA_PLANAR, INTRA_VER, INTRA_HOR, INTRA_DC}
		mode = modes[idx]
		if mode == luma do mode = 34
	}

	// Table 8-3: a 4:2:2 chroma block maps the prediction mode through the
	// half-height angle table.
	if d.s.chroma_format_idc == 2 do mode = int(CHROMA_422_MAP[mode])

	return mode
}

// Table 8-3, indexed by the pre-mapping intra chroma mode.
CHROMA_422_MAP := [35]u8 {
	0,
	1,
	2,
	2,
	2,
	2,
	3,
	5,
	7,
	8,
	10,
	12,
	13,
	15,
	17,
	18,
	19,
	20,
	21,
	22,
	23,
	23,
	24,
	24,
	25,
	25,
	26,
	27,
	27,
	28,
	28,
	29,
	29,
	30,
	31,
}

coding_tree_unit :: proc(d: ^Ctu_Decoder($Sample), x, y: int) -> bool {
	if d.sh.sao_luma || d.sh.sao_chroma do parse_sao(d, x, y)

	return coding_quadtree(d, x, y, int(d.s.ctb_log2_size_y), 0)
}

coding_quadtree :: proc(d: ^Ctu_Decoder($Sample), x, y, log2_size, depth: int) -> bool {
	split := log2_size > int(d.s.min_cb_log2_size_y)

	if log2_size > int(d.s.min_cb_log2_size_y) &&
	   x + (1 << uint(log2_size)) <= int(d.s.pic_width_in_luma_samples) &&
	   y + (1 << uint(log2_size)) <= int(d.s.pic_height_in_luma_samples) {
		ctx := 0

		if available(d, x, y, x - 1, y) && int(d.grids.cu_depth[tb_index(d, x - 1, y)]) > depth do ctx += 1
		if available(d, x, y, x, y - 1) && int(d.grids.cu_depth[tb_index(d, x, y - 1)]) > depth do ctx += 1

		split = cabac_decode_bin(&d.c, ctxSplitCodingUnitFlag + ctx) != 0
	}

	if d.p.cu_qp_delta_enabled &&
	   log2_size >= int(d.s.ctb_log2_size_y) - int(d.p.diff_cu_qp_delta_depth) {
		d.qp_coded = false
		d.qp_delta = 0
		d.qp_y_pred = predict_qp(d, x, y)
		d.qp_y_cur = d.qp_y_pred
	}

	if !split do return coding_unit(d, x, y, log2_size, depth)

	half := 1 << uint(log2_size - 1)

	for i in 0 ..< 4 {
		nx := x + (i & 1) * half
		ny := y + (i >> 1) * half

		if nx >= int(d.s.pic_width_in_luma_samples) || ny >= int(d.s.pic_height_in_luma_samples) {
			continue
		}

		if !coding_quadtree(d, nx, ny, log2_size - 1, depth + 1) do return false
	}

	return true
}

// predict_qp is qPY_PRED of 8.6.1.
predict_qp :: proc(d: ^Ctu_Decoder($Sample), x, y: int) -> i32 {
	ctb_mask := ~((1 << uint(d.s.ctb_log2_size_y)) - 1)

	qp_a := d.qp_y_prev
	qp_b := d.qp_y_prev

	if available(d, x, y, x - 1, y) &&
	   (x - 1) & ctb_mask == x & ctb_mask &&
	   y & ctb_mask == y & ctb_mask {
		qp_a = i32(d.grids.qp_y[tb_index(d, x - 1, y)])
	}

	if available(d, x, y, x, y - 1) &&
	   x & ctb_mask == x & ctb_mask &&
	   (y - 1) & ctb_mask == y & ctb_mask {
		qp_b = i32(d.grids.qp_y[tb_index(d, x, y - 1)])
	}

	return (qp_a + qp_b + 1) >> 1
}

// parse_cu_qp_delta reads cu_qp_delta_abs and its sign, 9.3.3.10.
parse_cu_qp_delta :: proc(d: ^Ctu_Decoder($Sample)) {
	prefix := 0
	for prefix < 5 {
		ctx := 1
		if prefix == 0 do ctx = 0

		if cabac_decode_bin(&d.c, ctxCUQPDelta + ctx) == 0 do break

		prefix += 1
	}

	v := i32(prefix)

	if prefix > 4 {
		k := 0
		for k < 6 && cabac_decode_bypass(&d.c) != 0 do k += 1

		extra := 5 + (1 << uint(k) - 1) + int(cabac_decode_bypass_bits(&d.c, k))
		v = i32(extra)
	}

	if v != 0 && cabac_decode_bypass(&d.c) != 0 do v = -v

	d.qp_delta = v
	d.qp_coded = true

	off := 6 * (i32(d.s.bit_depth_luma) - 8)
	m := 52 + off
	d.qp_y_cur = ((d.qp_y_pred + d.qp_delta + 52 + 2 * off) % m + m) % m - off
}

coding_unit :: proc(d: ^Ctu_Decoder($Sample), x, y, log2_size, depth: int) -> bool {
	if !coding_unit_data(d, x, y, log2_size, depth) do return false

	// 8.7.2.2 marks the coding block boundary even with no transform tree.
	mark_tu(d, x, y, 1 << uint(log2_size), 1 << uint(log2_size), false)

	set_qp(d, x, y, 1 << uint(log2_size))

	return true
}

coding_unit_data :: proc(d: ^Ctu_Decoder($Sample), x, y, log2_size, depth: int) -> bool {
	size := 1 << uint(log2_size)

	ctu_fill(d, d.grids.cu_depth, x, y, size, u8(depth))

	d.bypass = d.p.transquant_bypass && cabac_decode_bin(&d.c, ctxCUTransquantBypassFlag) != 0
	if d.bypass do ctu_fill(d, d.grids.no_filter, x, y, size, true)

	skip := false

	if d.sh.slice_type != .I {
		ctx := 0

		if available(d, x, y, x - 1, y) && d.grids.skipped[tb_index(d, x - 1, y)] do ctx += 1
		if available(d, x, y, x, y - 1) && d.grids.skipped[tb_index(d, x, y - 1)] do ctx += 1

		skip = cabac_decode_bin(&d.c, ctxSkipFlag + ctx) != 0
	}

	ctu_fill(d, d.grids.skipped, x, y, size, skip)

	if skip {
		d.cur_intra = false

		return prediction_unit(d, x, y, size, size, 0, PART_2NX2N, depth, size, x, y, true)
	}

	intra := true

	if d.sh.slice_type != .I do intra = cabac_decode_bin(&d.c, ctxPredModeFlag) != 0

	part_mode := PART_2NX2N

	if !intra || log2_size == int(d.s.min_cb_log2_size_y) {
		part_mode = decode_part_mode(d, intra, log2_size)
	}

	if !intra {
		d.cur_intra = false

		return inter_cu(d, x, y, log2_size, depth, part_mode)
	}

	d.cur_intra = true

	mark_pu(d, x, y, size, size, true)

	if part_mode != PART_2NX2N && part_mode != PART_NXN do return false

	// 7.3.8.5: pcm_flag is a terminate bin, present for a 2Nx2N CU whose size
	// lies in the range the SPS PCM parameters cover.
	if d.s.pcm_enabled &&
	   part_mode == PART_2NX2N &&
	   log2_size >= int(d.s.log2_min_pcm_cb_size) &&
	   log2_size <= int(d.s.log2_max_pcm_cb_size) {
		if cabac_decode_terminate(&d.c) != 0 {
			return pcm_sample(d, x, y, log2_size)
		}
	}

	parts := 1
	if part_mode == PART_NXN do parts = 4

	pb_size := size
	if parts == 4 do pb_size = size / 2

	luma_modes: [4]int

	prev_flags: [4]bool
	for i in 0 ..< parts {
		prev_flags[i] = cabac_decode_bin(&d.c, ctxPrevIntraLumaPredFlag) != 0
	}

	for i in 0 ..< parts {
		px := x + (i & 1) * pb_size
		py := y + (i >> 1) * pb_size
		luma_modes[i] = intra_luma_mode_with_flag(d, px, py, prev_flags[i])
		ctu_fill(d, d.grids.intra_mode, px, py, pb_size, u8(luma_modes[i]))
	}

	// 7.3.8.5 codes intra_chroma_pred_mode once per prediction block when
	// ChromaArrayType is 3, and once per coding unit otherwise.
	switch {
	case sps_chroma_array_type(d.s) == 3:
		for i in 0 ..< parts {
			px := x + (i & 1) * pb_size
			py := y + (i >> 1) * pb_size
			ctu_fill(
				d,
				d.grids.intra_mode_c,
				px,
				py,
				pb_size,
				u8(intra_chroma_mode(d, luma_modes[i])),
			)
		}
	case sps_chroma_array_type(d.s) != 0:
		ctu_fill(d, d.grids.intra_mode_c, x, y, size, u8(intra_chroma_mode(d, luma_modes[0])))
	case:
		ctu_fill(d, d.grids.intra_mode_c, x, y, size, u8(luma_modes[0]))
	}

	return transform_tree(
		d,
		x,
		y,
		x,
		y,
		log2_size,
		0,
		0,
		luma_modes,
		part_mode,
		[2]bool{},
		[2]bool{},
	)
}

// decode_part_mode is 7.3.8.5's part_mode, whose binarization depends on the
// prediction mode, the coding block size and whether asymmetric splits are on.
decode_part_mode :: proc(d: ^Ctu_Decoder($Sample), intra: bool, log2_size: int) -> int {
	if intra {
		if cabac_decode_bin(&d.c, ctxPartMode) != 0 do return PART_2NX2N
		return PART_NXN
	}

	if cabac_decode_bin(&d.c, ctxPartMode) != 0 do return PART_2NX2N

	min_cb := log2_size == int(d.s.min_cb_log2_size_y)

	// Table 9-34. At the smallest coding block size the third bin separates
	// Nx2N from NxN, and the asymmetric modes are not available at all.
	if cabac_decode_bin(&d.c, ctxPartMode + 1) != 0 {
		if min_cb || !d.s.amp_enabled do return PART_2NXN

		if cabac_decode_bin(&d.c, ctxPartMode + 3) != 0 do return PART_2NXN

		if cabac_decode_bypass(&d.c) != 0 do return PART_2NXND

		return PART_2NXNU
	}

	if min_cb {
		if log2_size == 3 do return PART_NX2N

		if cabac_decode_bin(&d.c, ctxPartMode + 2) != 0 do return PART_NX2N

		return PART_NXN
	}

	if !d.s.amp_enabled do return PART_NX2N

	if cabac_decode_bin(&d.c, ctxPartMode + 3) != 0 do return PART_NX2N

	if cabac_decode_bypass(&d.c) != 0 do return PART_NRX2N

	return PART_NLX2N
}

PART_SHAPE := [8][4][4]int {
	{{0, 0, 4, 4}, {0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 4, 2}, {0, 2, 4, 2}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 2, 4}, {2, 0, 2, 4}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 2, 2}, {2, 0, 2, 2}, {0, 2, 2, 2}, {2, 2, 2, 2}},
	{{0, 0, 4, 1}, {0, 1, 4, 3}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 4, 3}, {0, 3, 4, 1}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 1, 4}, {1, 0, 3, 4}, {0, 0, 0, 0}, {0, 0, 0, 0}},
	{{0, 0, 3, 4}, {3, 0, 1, 4}, {0, 0, 0, 0}, {0, 0, 0, 0}},
}

PART_COUNT := [8]int{1, 2, 2, 4, 2, 2, 2, 2}

inter_cu :: proc(d: ^Ctu_Decoder($Sample), x, y, log2_size, depth, part_mode: int) -> bool {
	size := 1 << uint(log2_size)
	q := size / 4

	for i in 0 ..< PART_COUNT[part_mode] {
		s := PART_SHAPE[part_mode][i]

		if !prediction_unit(
			d,
			x + s[0] * q,
			y + s[1] * q,
			s[2] * q,
			s[3] * q,
			i,
			part_mode,
			depth,
			size,
			x,
			y,
			false,
		) {
			return false
		}
	}

	// The bin is rqt_root_cbf: one means residual data follows. It is inferred
	// to one for a merged 2Nx2N unit.
	if !(part_mode == PART_2NX2N && d.last_merge) {
		if cabac_decode_bin(&d.c, ctxNoResidualDataFlag) == 0 do return true
	}

	modes: [4]int

	return transform_tree(d, x, y, x, y, log2_size, 0, 0, modes, part_mode, [2]bool{}, [2]bool{})
}

// intra_luma_mode_with_flag completes 8.4.2 once prev_intra_luma_pred_flag has
// been read.
intra_luma_mode_with_flag :: proc(d: ^Ctu_Decoder($Sample), x, y: int, prev: bool) -> int {
	cand_a, cand_b := INTRA_DC, INTRA_DC

	if available(d, x, y, x - 1, y) && d.grids.blk[blk_index(d, x - 1, y)].intra {
		cand_a = int(d.grids.intra_mode[tb_index(d, x - 1, y)])
	}

	ctb_mask := ~((1 << uint(d.s.ctb_log2_size_y)) - 1)

	if available(d, x, y, x, y - 1) &&
	   y - 1 >= y & ctb_mask &&
	   d.grids.blk[blk_index(d, x, y - 1)].intra {
		cand_b = int(d.grids.intra_mode[tb_index(d, x, y - 1)])
	}

	cand: [3]int

	switch {
	case cand_a == cand_b && cand_a < 2:
		cand = [3]int{INTRA_PLANAR, INTRA_DC, INTRA_VER}
	case cand_a == cand_b:
		cand = [3]int{cand_a, 2 + (cand_a + 29) % 32, 2 + (cand_a - 2 + 1) % 32}
	case:
		cand[0], cand[1] = cand_a, cand_b

		switch {
		case cand_a != INTRA_PLANAR && cand_b != INTRA_PLANAR:
			cand[2] = INTRA_PLANAR
		case cand_a != INTRA_DC && cand_b != INTRA_DC:
			cand[2] = INTRA_DC
		case:
			cand[2] = INTRA_VER
		}
	}

	if prev {
		idx := 0
		if cabac_decode_bypass(&d.c) != 0 {
			idx = 1
			if cabac_decode_bypass(&d.c) != 0 do idx = 2
		}

		return cand[idx]
	}

	if cand[0] > cand[1] do cand[0], cand[1] = cand[1], cand[0]
	if cand[0] > cand[2] do cand[0], cand[2] = cand[2], cand[0]
	if cand[1] > cand[2] do cand[1], cand[2] = cand[2], cand[1]

	mode := int(cabac_decode_bypass_bits(&d.c, 5))
	for i in 0 ..< 3 {
		if mode >= cand[i] do mode += 1
	}

	return mode
}

transform_tree :: proc(
	d: ^Ctu_Decoder($Sample),
	x, y, x_base, y_base, log2_size, depth, blk_idx: int,
	luma_modes: [4]int,
	part_mode: int,
	cbf_cb_up, cbf_cr_up: [2]bool,
) -> bool {
	intra_split := d.cur_intra && part_mode == PART_NXN

	max_depth := int(d.s.max_tr_hier_inter)
	if d.cur_intra do max_depth = int(d.s.max_tr_hier_intra)

	if intra_split do max_depth += 1

	// 7.3.8.8: with no inter hierarchy an inter unit that is not 2Nx2N still
	// splits once.
	inter_split :=
		!d.cur_intra && d.s.max_tr_hier_inter == 0 && part_mode != PART_2NX2N && depth == 0

	split := log2_size > int(d.s.max_tb_log2_size_y) || (intra_split && depth == 0) || inter_split

	if log2_size <= int(d.s.max_tb_log2_size_y) &&
	   log2_size > int(d.s.min_tb_log2_size_y) &&
	   depth < max_depth &&
	   !(intra_split && depth == 0) &&
	   !inter_split {
		split = cabac_decode_bin(&d.c, ctxSplitTransformFlag + 5 - log2_size) != 0
	}

	cbf_cb, cbf_cr := cbf_cb_up, cbf_cr_up

	if sps_chroma_array_type(d.s) != 0 && (log2_size > 2 || sps_chroma_array_type(d.s) == 3) {
		// 7.3.8.8: 4:2:2 stacks two chroma transform blocks per luma block,
		// each with its own cbf, once the tree stops splitting them apart.
		second := sps_chroma_array_type(d.s) == 2 && (!split || log2_size == 3)

		cbf_cb = [2]bool{}
		if depth == 0 || cbf_cb_up[0] {
			cbf_cb[0] = cabac_decode_bin(&d.c, ctxCBFCBCR + depth) != 0
			if second {
				cbf_cb[1] = cabac_decode_bin(&d.c, ctxCBFCBCR + depth) != 0
			}
		}

		cbf_cr = [2]bool{}
		if depth == 0 || cbf_cr_up[0] {
			cbf_cr[0] = cabac_decode_bin(&d.c, ctxCBFCBCR + depth) != 0
			if second {
				cbf_cr[1] = cabac_decode_bin(&d.c, ctxCBFCBCR + depth) != 0
			}
		}
	}

	if split {
		half := 1 << uint(log2_size - 1)

		for i in 0 ..< 4 {
			if !transform_tree(
				d,
				x + (i & 1) * half,
				y + (i >> 1) * half,
				x,
				y,
				log2_size - 1,
				depth + 1,
				i,
				luma_modes,
				part_mode,
				cbf_cb,
				cbf_cr,
			) {
				return false
			}
		}

		return true
	}

	// 7.3.8.8 only codes cbf_luma when the block is intra, nested, or has
	// chroma coefficients.
	cbf_luma := true
	if depth != 0 || cbf_cb[0] || cbf_cb[1] || cbf_cr[0] || cbf_cr[1] || d.cur_intra {
		cbf_luma = cabac_decode_bin(&d.c, ctxCBFLuma + bool_to_int(depth == 0)) != 0
	}

	return transform_unit(
		d,
		x,
		y,
		x_base,
		y_base,
		log2_size,
		depth,
		blk_idx,
		luma_modes,
		part_mode,
		cbf_luma,
		cbf_cb,
		cbf_cr,
	)
}

set_qp :: proc(d: ^Ctu_Decoder($Sample), x, y, size: int) #no_bounds_check {
	ctu_fill(d, d.grids.qp_y, x, y, size, i8(d.qp_y_cur))
	d.qp_y_prev = d.qp_y_cur
}

transform_unit :: proc(
	d: ^Ctu_Decoder($Sample),
	x, y, x_base, y_base, log2_size, depth, blk_idx: int,
	luma_modes: [4]int,
	part_mode: int,
	cbf_luma: bool,
	cbf_cb, cbf_cr: [2]bool,
) -> bool {
	// 8.4.4.2 takes the mode from IntraPredModeY at the block's own position,
	// which is not blk_idx once the transform tree splits below the partition.
	mode := luma_modes[0]
	if d.cur_intra do mode = int(d.grids.intra_mode[tb_index(d, x, y)])

	cbf_chroma := cbf_cb[0] || cbf_cb[1] || cbf_cr[0] || cbf_cr[1]

	if (cbf_luma || cbf_chroma) && d.p.cu_qp_delta_enabled && !d.qp_coded {
		parse_cu_qp_delta(d)
	}

	mark_tu(d, x, y, 1 << uint(log2_size), 1 << uint(log2_size), cbf_luma)

	if !reconstruct(d, x, y, log2_size, 0, mode, cbf_luma) do return false

	if sps_chroma_array_type(d.s) == 0 do return true

	// 7.3.8.9/7.3.8.10: 4:4:4 chroma shares the luma block size; every other
	// array type subsamples it. 4:2:2 subsamples the width only, so its two
	// stacked chroma blocks keep the luma block height.
	sub := sps_chroma_array_type(d.s) != 3

	if log2_size > 2 || !sub {
		c := log2_size
		cx, cy := x, y

		if sub {
			c -= 1
			cx = x / d.s.sub_width_c
			cy = y / d.s.sub_height_c
		}

		return chroma_tbs(d, cx, cy, c, chroma_mode(d, x, y), cbf_cb, cbf_cr)
	}

	if blk_idx != 3 do return true

	cx := x_base / d.s.sub_width_c
	cy := y_base / d.s.sub_height_c

	return chroma_tbs(d, cx, cy, 2, chroma_mode(d, x_base, y_base), cbf_cb, cbf_cr)
}

chroma_tbs :: proc(
	d: ^Ctu_Decoder($Sample),
	cx, cy, c, mode: int,
	cbf_cb, cbf_cr: [2]bool,
) -> bool {
	// 7.3.8.10: 4:2:2 stacks two chroma transform blocks per component,
	// coded as both Cb blocks and then both Cr blocks.
	n := 1
	if sps_chroma_array_type(d.s) == 2 do n = 2

	for c_idx in 1 ..= 2 {
		cbf := cbf_cb
		if c_idx == 2 do cbf = cbf_cr

		for t in 0 ..< n {
			if !reconstruct(d, cx, cy + t << uint(c), c, c_idx, mode, cbf[t]) do return false
		}
	}

	return true
}

chroma_mode :: proc(d: ^Ctu_Decoder($Sample), x, y: int) -> int {
	if !d.cur_intra do return 0
	return int(d.grids.intra_mode_c[tb_index(d, x, y)])
}

// read_pcm_plane is 7.3.8.7's pcm_sample loop: raw samples at the SPS PCM bit
// depth, shifted up to the picture's bit depth (8.6.x reconstruction keeps the
// sample value as is otherwise).
read_pcm_plane :: proc(
	g: ^Get_Bits,
	d: ^Ctu_Decoder($Sample),
	c_idx, x, y, w, h, pcm_depth, bit_depth: int,
) #no_bounds_check {
	plane, stride := plane_at(Sample, d.pic, c_idx)
	shift := uint(bit_depth - pcm_depth)

	for j in 0 ..< h {
		for i in 0 ..< w {
			plane[(y + j) * stride + x + i] = Sample(get_bits_bits(g, pcm_depth) << shift)
		}
	}
}

// pcm_sample decodes 7.3.8.7: the raw samples follow the pcm_flag terminate bin
// at the next byte boundary, and the CABAC engine restarts after them with its
// contexts intact. The samples themselves are the reconstruction; loop filters
// may still touch them unless pcm_loop_filter_disabled_flag is set.
pcm_sample :: proc(d: ^Ctu_Decoder($Sample), x, y, log2_size: int) -> bool {
	off := cabac_pcm_offset(&d.c)
	if off < 0 || off >= len(d.c.data) do return false

	size := 1 << uint(log2_size)

	// 8.4.4.2: a PCM coding unit has the default intra prediction mode as far
	// as neighbouring mode derivation is concerned.
	ctu_fill(d, d.grids.intra_mode, x, y, size, u8(INTRA_DC))

	if d.s.pcm_loop_filter_disabled do ctu_fill(d, d.grids.no_filter, x, y, size, true)

	g: Get_Bits
	get_bits_init(&g, d.c.data[off:])

	read_pcm_plane(
		&g,
		d,
		0,
		x,
		y,
		size,
		size,
		int(d.s.pcm_bit_depth_luma),
		int(d.s.bit_depth_luma),
	)

	if sps_chroma_array_type(d.s) != 0 {
		sw, sh := d.s.sub_width_c, d.s.sub_height_c
		for c_idx in 1 ..= 2 {
			read_pcm_plane(
				&g,
				d,
				c_idx,
				x / sw,
				y / sh,
				size / sw,
				size / sh,
				int(d.s.pcm_bit_depth_chroma),
				int(d.s.bit_depth_chroma),
			)
		}
	}

	if g.err do return false

	return cabac_init(&d.c, d.c.data, off + (get_bits_pos(&g) + 7) / 8)
}

reconstruct :: proc(
	d: ^Ctu_Decoder($Sample),
	x, y, log2_size, c_idx, mode: int,
	cbf: bool,
) -> bool #no_bounds_check {
	n := 1 << uint(log2_size)
	bit_depth := int(d.s.bit_depth_luma)
	if c_idx > 0 do bit_depth = int(d.s.bit_depth_chroma)

	plane, stride := plane_at(Sample, d.pic, c_idx)

	if d.cur_intra {
		gather_ref(d, plane, stride, x, y, n, c_idx)
		filter_ref(&d.ref, mode, c_idx, bit_depth, d.s)
		// 8.4.4.2.6: disableIntraBoundaryFilter is 1 when implicit RDPCM and
		// transquant bypass both apply (the SCC flag is not parsed).
		intra_predict(
			plane,
			y * stride + x,
			stride,
			&d.ref,
			mode,
			c_idx,
			bit_depth,
			d.s.implicit_rdpcm && d.bypass,
		)
	}

	if !cbf do return true

	for i in 0 ..< n * n do d.coef[i] = 0

	rb := Residual_Block {
		log2_size         = log2_size,
		c_idx             = c_idx,
		pred_mode_intra   = mode,
		intra             = d.cur_intra,
		transquant_bypass = d.bypass,
	}

	skip, explicit_rdpcm, rdpcm_dir, ok := decode_residual(
		&d.c,
		d.s,
		d.p,
		d.sh,
		d.coef[:n * n],
		rb,
		&d.stat_coef,
	)
	if !ok do return false

	// 8.6.2 eq. 8-297 rotateCoeffs: a 4x4 intra block mirrors its
	// coefficients when the SPS signals transform_skip_rotation.
	rotate := d.s.transform_skip_rotation && n == 4 && d.cur_intra

	// 8.4.4.1 residualDpcm: the implicit form covers transform-skip and
	// transquant-bypass blocks in the horizontal/vertical intra modes;
	// the explicit form is the inter flag parsed with the residual.
	rdpcm := explicit_rdpcm
	rdpcm_vertical := rdpcm_dir
	if !rdpcm &&
	   d.s.implicit_rdpcm &&
	   (skip || d.bypass) &&
	   d.cur_intra &&
	   (mode == INTRA_HOR || mode == INTRA_VER) {
		rdpcm = true
		rdpcm_vertical = mode == INTRA_VER
	}

	// 8.6.3 scales by Qp', which carries the bit-depth offset QpY does not.
	off_y := 6 * (bit_depth - 8)
	qp_scaled := int(d.qp_y_cur) + off_y
	if c_idx > 0 {
		off := d.p.cb_qp_offset + d.sh.cb_qp_offset
		if c_idx == 2 do off = d.p.cr_qp_offset + d.sh.cr_qp_offset

		off_c := 6 * (bit_depth - 8)
		qp_scaled =
			int(
				hevc.chroma_qp(
					clamp(d.qp_y_cur + off, -i32(off_c), 57),
					int(sps_chroma_array_type(d.s)),
				),
			) +
			off_c
	}

	max_v := i32(1) << uint(bit_depth) - 1

	// 8.6.3: the scaling list scales every coefficient by its matrix entry.
	// The PPS list overrides the SPS one when present, the matrix is selected
	// by transform size, intra/inter and component, and a 16x16/32x32 DC
	// coefficient reads the DC list. A transform-skip block larger than 4x4
	// keeps the flat list (the ffmpeg gate `!(skip && log2_size > 2)`).
	scaled := d.s.scaling_list_enabled && !(skip && n > 4)

	// The i32 forms of 8.6.2 carry transquant bypass at any bit depth and
	// every block under extended precision's wider 8.6.3 coefficient range
	// (log2TransformRange grows past 15 at bit depth 10 and above); the i16
	// kernels below are the default path and keep their SIMD forms.
	if d.bypass || (d.s.extended_precision && bit_depth > 9) {
		sl: []u8
		dc_scale: u8 = 16
		if scaled && !d.bypass {
			s := &d.s.scaling_list
			if d.p.scaling_list_present do s = &d.p.scaling_list

			matrix_id := c_idx
			if !d.cur_intra do matrix_id += 3
			log2 := hevc.log2_size(n)

			if log2 >= 4 do dc_scale = s.dc[log2 - 4][matrix_id]
			sl = s.sl[log2 - 2][matrix_id][:]
		}

		res32: [32 * 32]i32 = ---

		hevc.residual_block(
			d.coef[:n * n],
			res32[:n * n],
			n,
			bit_depth,
			qp_scaled,
			sl,
			dc_scale,
			d.bypass,
			skip,
			rotate,
			c_idx == 0 && n == 4 && d.cur_intra,
		)
		if rdpcm do hevc.inverse_rdpcm(res32[:n * n], n, rdpcm_vertical)

		for j in 0 ..< n {
			for i in 0 ..< n {
				p := i32(plane[(y + j) * stride + x + i]) + res32[j * n + i]
				plane[(y + j) * stride + x + i] = Sample(clamp(p, 0, max_v))
			}
		}

		return true
	}

	// Both kernels write the full active square before it is read.
	coeffs: [32 * 32]i16 = ---
	residual: [32 * 32]i16 = ---

	if scaled {
		sl := &d.s.scaling_list
		if d.p.scaling_list_present do sl = &d.p.scaling_list

		matrix_id := c_idx
		if !d.cur_intra do matrix_id += 3
		log2 := hevc.log2_size(n)

		dc_scale := u8(16)
		if log2 >= 4 do dc_scale = sl.dc[log2 - 4][matrix_id]

		hevc.dequantize_scaled(
			d.coef[:n * n],
			coeffs[:n * n],
			n,
			bit_depth,
			qp_scaled,
			sl.sl[log2 - 2][matrix_id][:],
			dc_scale,
		)
	} else {
		hevc.dequantize(d.coef[:n * n], coeffs[:n * n], n, bit_depth, qp_scaled)
	}

	// eq. 8-297: the mirror applies to the scaled coefficients of a
	// transform-skip block as well (a raster index reversal).
	if skip && rotate {
		for i in 0 ..< n * n / 2 {
			coeffs[i], coeffs[n * n - 1 - i] = coeffs[n * n - 1 - i], coeffs[i]
		}
	}

	// 8.6.5: the residual DPCM accumulate runs after 8.6.2 and its
	// rotateCoeffs reorder.
	if skip {
		// 8.6.4.2: transform skip scales the dequantized coefficients back
		// down; there is no transform gain.
		hevc.inverse_transform_skip(coeffs[:n * n], residual[:n * n], n, bit_depth)
		if rdpcm do hevc.inverse_rdpcm(residual[:n * n], n, rdpcm_vertical)
	} else if c_idx == 0 && n == 4 && d.cur_intra {
		// 8.6.4.1: a 4x4 luma intra transform block uses DST-VII; every other
		// block uses DCT-II.
		hevc.inverse_transform_dst4(coeffs[:n * n], residual[:n * n], bit_depth)
	} else {
		hevc.inverse_transform(n, coeffs[:n * n], residual[:n * n], bit_depth)
	}

	for j in 0 ..< n {
		for i in 0 ..< n {
			p := i32(plane[(y + j) * stride + x + i]) + i32(residual[j * n + i])
			plane[(y + j) * stride + x + i] = Sample(clamp(p, 0, max_v))
		}
	}

	return true
}

gather_ref :: proc(
	d: ^Ctu_Decoder($Sample),
	plane: []Sample,
	stride, x, y, n, c_idx: int,
) #no_bounds_check {
	sw, sh := 1, 1
	if c_idx > 0 {
		sw, sh = d.s.sub_width_c, d.s.sub_height_c
	}

	w := d.pic.width / sw
	h := d.pic.height / sh

	d.ref.n = n

	last_tb, last_ok := -1, false

	for i in 0 ..< 4 * n + 1 {
		nx, ny: int

		switch {
		case i < 2 * n:
			nx, ny = x - 1, y + 2 * n - 1 - i
		case i == 2 * n:
			nx, ny = x - 1, y - 1
		case:
			nx, ny = x + i - 2 * n - 1, y - 1
		}

		ok := nx >= 0 && ny >= 0 && nx < w && ny < h

		if ok {
			tb := tb_index(d, nx * sw, ny * sh)

			if tb != last_tb {
				last_tb = tb
				last_ok = available(d, x * sw, y * sh, nx * sw, ny * sh)

				// 8.4.4.2.2: with constrained intra prediction, samples from
				// inter-coded neighbours count as unavailable.
				if last_ok &&
				   d.p.constrained_intra_pred &&
				   !d.grids.blk[blk_index(d, nx * sw, ny * sh)].intra {
					last_ok = false
				}
			}

			ok = last_ok
		}

		d.avail[i] = ok
		if ok do d.ref.s[i] = i32(plane[ny * stride + nx])
	}

	bit_depth := int(d.s.bit_depth_luma)
	if c_idx > 0 do bit_depth = int(d.s.bit_depth_chroma)

	ref_substitute(&d.ref, d.avail[:4 * n + 1], bit_depth)
}

@(private)
bool_to_int :: #force_inline proc(v: bool) -> int {
	return v ? 1 : 0
}

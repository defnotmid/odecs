package vp9

import "base:intrinsics"
import "core:simd"

// Loop filter (section 8.8): superblocks in raster order, each plane's
// vertical then horizontal edges. Edge decisions come from the mode info of
// the 8x8 cell the samples belong to and change only between cells.

// Filter levels per segment, reference frame and mode type (8.8.1).
Filter_Levels :: [MAX_SEGMENTS][4][2]u8

filter_levels :: proc(lf: ^Loop_Filter, seg: ^Segmentation) -> (levels: Filter_Levels) {
	shift := uint(lf.level >> 5)
	for segment in 0 ..< MAX_SEGMENTS {
		lvl := lf.level
		if seg_feature_active(seg, segment, SEG_LVL_ALT_L) {
			data := int(seg.feature_data[segment][SEG_LVL_ALT_L])
			lvl = clamp(seg.abs_or_delta_update ? data : data + lf.level, 0, MAX_LOOP_FILTER)
		}
		if !lf.delta_enabled {
			for ref in 0 ..< 4 do for mode in 0 ..< 2 do levels[segment][ref][mode] = u8(lvl)
			continue
		}
		intra := lvl + int(lf.ref_deltas[INTRA_FRAME]) << shift
		levels[segment][INTRA_FRAME][0] = u8(clamp(intra, 0, MAX_LOOP_FILTER))
		for ref in LAST_FRAME ..< 4 do for mode in 0 ..< 2 {
			inter := lvl + int(lf.ref_deltas[ref]) << shift + int(lf.mode_deltas[mode]) << shift
			levels[segment][ref][mode] = u8(clamp(inter, 0, MAX_LOOP_FILTER))
		}
	}
	return
}

Loop_Filter_Frame :: struct($T: typeid) {
	planes:           [3][]T,
	strides:          [3]int,
	mi:               []Mode_Info,
	mi_stride:        int,
	mi_rows, mi_cols: int,
	ss_x, ss_y:       int,
	bit_depth:        int,
	sharpness:        int,
	levels:           Filter_Levels,
}

// Filters one 64x64 superblock: each plane's vertical, then horizontal
// edges. Raster order is normative because filters overlap; superblock
// (r, c) needs (r, c - 1) and (r - 1, c + 1) done, so all superblocks with
// the same 2r + c (one "wave") are independent of each other.
loop_filter_superblock :: proc(f: ^Loop_Filter_Frame($T), sb_row, sb_col: int) {
	for plane in 0 ..< 3 do for pass in 0 ..< 2 do filter_superblock(f, plane, pass, sb_row * 8, sb_col * 8)
}

// Superblocks of wave w: rows r with column w - 2r inside the frame.
wave_range :: proc(wave, sb_rows, sb_cols: int) -> (first_row, rows: int) {
	first_row = max(0, (wave - sb_cols + 2) / 2)
	last_row := min(sb_rows - 1, wave / 2)
	return first_row, max(0, last_row - first_row + 1)
}

@(private)
Edge_Decision :: struct {
	apply:  bool,
	size:   int, // filterSize: TX_4X4, TX_8X8 or TX_16X16
	limit, blimit, thresh: i32,
}

// Each edge is filtered in runs of up to eight lines that share one 8x8
// cell's decision; a run is filtered as eight vector lanes.
@(private)
filter_superblock :: proc(f: ^Loop_Filter_Frame($T), plane, pass, row, col: int) {
	sub_x, sub_y := plane > 0 ? f.ss_x : 0, plane > 0 ? f.ss_y : 0
	sub := pass == 0 ? sub_x : sub_y
	edge_len := pass == 0 ? 64 >> uint(sub_y) : 64 >> uint(sub_x)
	stride := f.strides[plane]
	// Visible extent of the plane in samples (MiCols/MiRows * 8, subsampled).
	plane_w, plane_h := (8 * f.mi_cols) >> uint(sub_x), (8 * f.mi_rows) >> uint(sub_y)
	for edge in 0 ..< 16 >> uint(sub) {
		for i := 0; i < edge_len; i += 8 {
			x, y: int
			if pass == 0 {
				x, y = col * 8 + edge * (4 << uint(sub_x)), row * 8 + (i << uint(sub_y))
			} else {
				x, y = col * 8 + (i << uint(sub_x)), row * 8 + edge * (4 << uint(sub_y))
			}
			if x >= 8 * f.mi_cols || y >= 8 * f.mi_rows do break // past the frame along the edge
			if pass == 0 && x == 0 || pass == 1 && y == 0 do break
			loop_col := ((x >> 3) >> uint(sub_x)) << uint(sub_x)
			loop_row := ((y >> 3) >> uint(sub_y)) << uint(sub_y)
			d := edge_decision(f, &f.mi[loop_row * f.mi_stride + loop_col], plane, pass, edge, x, y, sub_x, sub_y, sub)
			if !d.apply do continue
			px, py := x >> uint(sub_x), y >> uint(sub_y)
			lines := min(8, pass == 0 ? plane_h - py : plane_w - px)
			filter_run(f.planes[plane], py * stride + px, pass == 0 ? stride : 1, pass == 0 ? 1 : stride, lines, d, f.bit_depth)
		}
	}
}

@(private)
edge_decision :: proc(f: ^Loop_Filter_Frame($T), mi: ^Mode_Info, plane, pass, edge, x, y, sub_x, sub_y, sub: int) -> (d: Edge_Decision) {
	mi_size, tx_size := int(mi.mi_size), int(mi.tx_size)
	tx := plane > 0 ? uv_tx_size(mi_size, tx_size, f.ss_x, f.ss_y) : tx_size
	sb_size := sub == 0 ? mi_size : max(BLOCK_16X16, mi_size)
	block_edge := pass == 0 ? x % (8 * int(NUM_8X8_BLOCKS_WIDE_LOOKUP[sb_size])) == 0 : y % (8 * int(NUM_8X8_BLOCKS_HIGH_LOOKUP[sb_size])) == 0
	tx_edge: bool
	if pass == 1 && sub_x == 1 && f.mi_cols & 1 == 1 && edge & 1 == 1 && x + 8 >= f.mi_cols * 8 {
		tx_edge = false // a chroma row edge crossing the right edge of the image
	} else {
		tx_edge = edge % (1 << uint(tx)) == 0
	}
	is32 := edge % 8 == 0
	intra := mi.ref_frame[0] <= INTRA_FRAME
	d.apply = block_edge || tx_edge && (intra || !mi.skip)
	// Filter size (8.8.3).
	base := tx == TX_4X4 && is32 ? TX_8X8 : min(TX_16X16, tx)
	d.size = base
	if base == TX_16X16 {
		if pass == 0 && sub_x == 1 && x >> 3 == f.mi_cols - 1 do d.size = TX_8X8
		if pass == 1 && sub_y == 1 && y >> 3 == f.mi_rows - 1 do d.size = TX_8X8
	}
	// Strength (8.8.4).
	mode := int(mi.y_mode)
	mode_type := mode == NEARESTMV || mode == NEARMV || mode == NEWMV ? 1 : 0
	lvl := i32(f.levels[mi.segment_id][max(0, int(mi.ref_frame[0]))][mode_type])
	if lvl == 0 do d.apply = false
	shift: uint = f.sharpness > 4 ? 2 : f.sharpness > 0 ? 1 : 0
	limit := f.sharpness > 0 ? clamp(lvl >> shift, 1, i32(9 - f.sharpness)) : max(1, lvl >> shift)
	d.limit, d.blimit, d.thresh = limit, 2 * (lvl + 2) + limit, lvl >> 4
	return
}

@(private)
L :: #simd[8]i32
@(private)
M :: #simd[8]u32

@(private)
shr :: #force_inline proc "contextless" (v: L, $n: u32) -> L {return simd.shr(v, M(n))}

// Samples across an edge for eight lines: p[k] is p_k (k samples before the
// edge, minus one), q[k] is q_k.
@(private)
Edge_Lanes :: struct {
	p, q: [8]L,
}

// Filters `lines` lines (up to 8) across one edge (8.8.5). `base` is q0 of
// the first line, `along` steps between lines, `across` across the edge.
// Only the samples the run's filter size can reach are read or written.
@(private)
filter_run :: proc(plane: []$T, base, along, across, lines: int, d: Edge_Decision, bit_depth: int) #no_bounds_check {
	reach := d.size == TX_16X16 ? 8 : 4
	e := load_edge(plane, base, along, across, reach)
	shift := uint(bit_depth - 8)
	limit, blimit, thresh := L(d.limit << shift), L(d.blimit << shift), L(d.thresh << shift)
	p, q := &e.p, &e.q
	ad :: #force_inline proc "contextless" (a, b: L) -> L {return simd.abs(a - b)}
	le :: #force_inline proc "contextless" (a, b: L) -> M {return simd.lanes_le(a, b)}
	both :: #force_inline proc "contextless" (a, b: M) -> M {return simd.bit_and(a, b)}
	mask := both(both(both(le(ad(p[3], p[2]), limit), le(ad(p[2], p[1]), limit)), both(le(ad(p[1], p[0]), limit), le(ad(q[1], q[0]), limit))), both(both(le(ad(q[2], q[1]), limit), le(ad(q[3], q[2]), limit)), le(ad(p[0], q[0]) * 2 + shr(ad(p[1], q[1]), 1), blimit)))
	if lines < 8 do mask = both(mask, simd.lanes_lt(simd.indices(M), M(u32(lines))))
	if simd.reduce_or(mask) == 0 do return
	hev := simd.bit_or(simd.lanes_gt(ad(p[1], p[0]), thresh), simd.lanes_gt(ad(q[1], q[0]), thresh))
	one := L(i32(1) << shift)
	flat := M(0)
	if d.size >= TX_8X8 {
		flat = both(both(both(le(ad(p[1], p[0]), one), le(ad(q[1], q[0]), one)), both(le(ad(p[2], p[0]), one), le(ad(q[2], q[0]), one))), both(le(ad(p[3], p[0]), one), le(ad(q[3], q[0]), one)))
	}
	flat2 := M(0)
	if d.size >= TX_16X16 {
		flat2 = flat
		for k in 4 ..< 8 do flat2 = both(flat2, both(le(ad(p[k], p[0]), one), le(ad(q[k], q[0]), one)))
	}
	out := e
	// Narrow filter (8.8.5.2) on lanes that are not flat.
	half := L(i32(0x80) << shift)
	lo, hi := L(-(i32(1) << uint(bit_depth - 1))), L((i32(1) << uint(bit_depth - 1)) - 1)
	c :: #force_inline proc "contextless" (v, lo, hi: L) -> L {return simd.clamp(v, lo, hi)}
	ps1, ps0, qs0, qs1 := p[1] - half, p[0] - half, q[0] - half, q[1] - half
	filter := simd.select(hev, c(ps1 - qs1, lo, hi), L(0))
	filter = c(filter + 3 * (qs0 - ps0), lo, hi)
	filter1 := shr(c(filter + 4, lo, hi), 3)
	filter2 := shr(c(filter + 3, lo, hi), 3)
	narrow := simd.bit_and(mask, simd.bit_not(flat))
	out.q[0] = simd.select(narrow, c(qs0 - filter1, lo, hi) + half, out.q[0])
	out.p[0] = simd.select(narrow, c(ps0 + filter2, lo, hi) + half, out.p[0])
	outer := simd.bit_and(narrow, simd.bit_not(hev))
	f := shr(filter1 + 1, 1)
	out.q[1] = simd.select(outer, c(qs1 - f, lo, hi) + half, out.q[1])
	out.p[1] = simd.select(outer, c(ps1 + f, lo, hi) + half, out.p[1])
	// Wide filters (8.8.5.3) on flat lanes: 8 taps, or 16 where flat2.
	if d.size >= TX_8X8 {
		wide8 := simd.bit_and(simd.bit_and(mask, flat), simd.bit_not(flat2))
		if simd.reduce_or(wide8) != 0 do wide_filter(&e, &out, 3, wide8)
		wide16 := simd.bit_and(mask, flat2)
		if simd.reduce_or(wide16) != 0 do wide_filter(&e, &out, 4, wide16)
	}
	store_edge(plane, base, along, across, reach, lines, &out)
}

// Low-pass over 2^log2 taps either side (8.8.5.3): modifies the n = 2^(log2-1)-1
// samples nearest the edge on each side, for the lanes in `lanes`.
@(private)
wide_filter :: #force_inline proc(e, out: ^Edge_Lanes, $log2: uint, lanes: M) {
	n :: (1 << (log2 - 1)) - 1
	// s[k + 8] is the sample at signed position k: p_j at -(j+1), q_j at j.
	s: [16]L
	for k in 0 ..< 8 {
		s[7 - k] = e.p[k]
		s[8 + k] = e.q[k]
	}
	// The 2n+1 tap window slides one sample per output: add the sample
	// entering on the right, drop the one leaving on the left.
	window: L
	for j in -n ..= n do window += s[clamp(-n + j, -(n + 1), n) + 8]
	for i in -n ..< n {
		v := shr(s[i + 8] + window + (1 << (log2 - 1)), u32(log2))
		if i < 0 {
			out.p[-i - 1] = simd.select(lanes, v, out.p[-i - 1])
		} else {
			out.q[i] = simd.select(lanes, v, out.q[i])
		}
		window += s[min(i + n + 1, n) + 8] - s[max(i - n, -(n + 1)) + 8]
	}
}

// Across a horizontal edge the lines are adjacent samples of one row; across
// a vertical edge each line is a row, so 8x8 blocks are transposed.
@(private)
load_edge :: proc(plane: []$T, base, along, across, reach: int) -> (e: Edge_Lanes) #no_bounds_check {
	if across != 1 {
		for k in 0 ..< reach {
			e.q[k] = L(intrinsics.unaligned_load((^#simd[8]T)(&plane[base + k * across])))
			e.p[k] = L(intrinsics.unaligned_load((^#simd[8]T)(&plane[base - (k + 1) * across])))
		}
		return
	}
	// reach 4: columns -4 .. 3 in one block; reach 8: -8 .. -1 and 0 .. 7.
	rows_p, rows_q: [8]L
	for line in 0 ..< 8 {
		at := base + line * along
		rows_p[line] = L(intrinsics.unaligned_load((^#simd[8]T)(&plane[at - reach])))
		if reach == 8 do rows_q[line] = L(intrinsics.unaligned_load((^#simd[8]T)(&plane[at])))
	}
	if reach == 4 {
		cols := transpose_8x8(rows_p)
		for k in 0 ..< 4 {
			e.p[k] = cols[3 - k]
			e.q[k] = cols[4 + k]
		}
	} else {
		cp, cq := transpose_8x8(rows_p), transpose_8x8(rows_q)
		for k in 0 ..< 8 {
			e.p[k] = cp[7 - k]
			e.q[k] = cq[k]
		}
	}
	return
}

@(private)
store_edge :: proc(plane: []$T, base, along, across, reach, lines: int, e: ^Edge_Lanes) #no_bounds_check {
	if across != 1 {
		for k in 0 ..< reach - 1 {
			store_lines(plane[base + k * across:], lines, e.q[k])
			store_lines(plane[base - (k + 1) * across:], lines, e.p[k])
		}
		return
	}
	if reach == 4 {
		cols: [8]L
		for k in 0 ..< 4 {
			cols[3 - k] = e.p[k]
			cols[4 + k] = e.q[k]
		}
		rows := transpose_8x8(cols)
		for line in 0 ..< lines {
			intrinsics.unaligned_store((^#simd[8]T)(&plane[base + line * along - 4]), (#simd[8]T)(rows[line]))
		}
		return
	}
	cp, cq: [8]L
	for k in 0 ..< 8 {
		cp[7 - k] = e.p[k]
		cq[k] = e.q[k]
	}
	rp, rq := transpose_8x8(cp), transpose_8x8(cq)
	for line in 0 ..< lines {
		at := base + line * along
		intrinsics.unaligned_store((^#simd[8]T)(&plane[at - 8]), (#simd[8]T)(rp[line]))
		intrinsics.unaligned_store((^#simd[8]T)(&plane[at]), (#simd[8]T)(rq[line]))
	}
}

@(private)
store_lines :: #force_inline proc(dst: []$T, lines: int, v: L) #no_bounds_check {
	if lines == 8 {
		intrinsics.unaligned_store((^#simd[8]T)(raw_data(dst)), (#simd[8]T)(v))
		return
	}
	a := simd.to_array(v)
	for i in 0 ..< lines do dst[i] = T(a[i])
}

// Swaps rows and columns by interleaving lanes, then pairs, then quads.
@(private)
transpose_8x8 :: proc(r: [8]L) -> (c: [8]L) {
	a, b: [8]L
	for i in 0 ..< 4 {
		a[2 * i] = simd.shuffle(r[2 * i], r[2 * i + 1], 0, 8, 1, 9, 2, 10, 3, 11)
		a[2 * i + 1] = simd.shuffle(r[2 * i], r[2 * i + 1], 4, 12, 5, 13, 6, 14, 7, 15)
	}
	for i in 0 ..< 2 do for j in 0 ..< 2 {
		b[4 * i + 2 * j] = simd.shuffle(a[4 * i + j], a[4 * i + j + 2], 0, 1, 8, 9, 2, 3, 10, 11)
		b[4 * i + 2 * j + 1] = simd.shuffle(a[4 * i + j], a[4 * i + j + 2], 4, 5, 12, 13, 6, 7, 14, 15)
	}
	for i in 0 ..< 4 {
		c[2 * i] = simd.shuffle(b[i], b[i + 4], 0, 1, 2, 3, 8, 9, 10, 11)
		c[2 * i + 1] = simd.shuffle(b[i], b[i + 4], 4, 5, 6, 7, 12, 13, 14, 15)
	}
	return
}

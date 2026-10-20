package vp9

import common "../../common"
import "base:intrinsics"
import "core:simd"

// simd and common are used only inside procedures generic over the sample
// type, which a package check does not instantiate.
_ :: simd
_ :: common

// Loop filter (section 8.8): superblocks in raster order, each plane's
// vertical then horizontal edges. Edge decisions come from the filter record of
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

// What the loop filter reads of one 8x8 cell, written beside its mode info
// when the block is coded, so filtering reads one small record per cell.
Filter_Cell :: struct {
	level:   u8, // 8.8.1 for the cell's segment, reference and mode; 0 leaves it unfiltered
	mi_size: u8,
	tx_size: [2]u8, // luma, then chroma (get_uv_tx_size)
	skip:    bool, // an inter block without coefficients: its transform edges are not filtered
}

filter_cell :: proc "contextless" (m: Mode_Info, levels: ^Filter_Levels, ss_x, ss_y: int) -> Filter_Cell {
	mode := int(m.y_mode)
	mode_type := mode == NEARESTMV || mode == NEARMV || mode == NEWMV ? 1 : 0
	return {
		level = levels[m.segment_id][max(0, int(m.ref_frame[0]))][mode_type],
		mi_size = m.mi_size,
		tx_size = {m.tx_size, u8(uv_tx_size(int(m.mi_size), int(m.tx_size), ss_x, ss_y))},
		skip = m.skip && m.ref_frame[0] > INTRA_FRAME,
	}
}

// The edge thresholds of each filter level at a frame's sharpness (8.8.4).
Filter_Limits :: [MAX_LOOP_FILTER + 1]struct {
	limit, blimit, thresh: i32,
}

filter_limits :: proc "contextless" (sharpness: int) -> (limits: Filter_Limits) {
	shift: uint = sharpness > 4 ? 2 : sharpness > 0 ? 1 : 0
	for &l, lvl in limits {
		lv := i32(lvl)
		limit := sharpness > 0 ? clamp(lv >> shift, 1, i32(9 - sharpness)) : max(1, lv >> shift)
		l = {limit, 2 * (lv + 2) + limit, lv >> 4}
	}
	return
}

Loop_Filter_Frame :: struct($T: typeid) {
	planes:           [3][]T,
	strides:          [3]int,
	cells:            []Filter_Cell, // mi_rows x mi_cols
	mi_rows, mi_cols: int,
	ss_x, ss_y:       int,
	bit_depth:        int,
	limits:           Filter_Limits,
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

// Each edge is filtered in segments of sixteen lines: two 8x8 cells along
// the edge, each with its own decision, filtered as sixteen vector lanes.
// Lines along one edge never overlap, so pairing them keeps the order the
// specification filters in.
@(private)
Edge_Pair :: struct {
	d:     [2]Edge_Decision,
	lines: [2]int, // lines of each cell to filter: 0 when it is not filtered
}

@(private)
filter_superblock :: proc(f: ^Loop_Filter_Frame($T), plane, pass, row, col: int) {
	sub_x, sub_y := plane > 0 ? f.ss_x : 0, plane > 0 ? f.ss_y : 0
	sub := pass == 0 ? sub_x : sub_y
	edge_len := pass == 0 ? 64 >> uint(sub_y) : 64 >> uint(sub_x)
	stride := f.strides[plane]
	// Visible extent of the plane in samples (MiCols/MiRows * 8, subsampled).
	plane_w, plane_h := (8 * f.mi_cols) >> uint(sub_x), (8 * f.mi_rows) >> uint(sub_y)
	for edge in 0 ..< 16 >> uint(sub) {
		segments: for i := 0; i < edge_len; i += 16 {
			pair: Edge_Pair
			start: int
			for half in 0 ..< 2 {
				x, y: int
				if pass == 0 {
					x, y = col * 8 + edge * (4 << uint(sub_x)), row * 8 + ((i + 8 * half) << uint(sub_y))
				} else {
					x, y = col * 8 + ((i + 8 * half) << uint(sub_x)), row * 8 + edge * (4 << uint(sub_y))
				}
				if x >= 8 * f.mi_cols || y >= 8 * f.mi_rows || pass == 0 && x == 0 || pass == 1 && y == 0 {
					// Past the frame along the edge, or the frame's own edge.
					if half == 0 do break segments
					break
				}
				px, py := x >> uint(sub_x), y >> uint(sub_y)
				if half == 0 do start = py * stride + px
				loop_col := ((x >> 3) >> uint(sub_x)) << uint(sub_x)
				loop_row := ((y >> 3) >> uint(sub_y)) << uint(sub_y)
				d := edge_decision(f, &f.cells[loop_row * f.mi_cols + loop_col], plane, pass, edge, x, y, sub_x, sub_y, sub)
				if !d.apply do continue
				pair.d[half] = d
				pair.lines[half] = min(8, pass == 0 ? plane_h - py : plane_w - px)
			}
			if pair.lines == {} do continue
			along, across := pass == 0 ? stride : 1, pass == 0 ? 1 : stride
			if f.bit_depth <= 10 {
				filter_pair(f.planes[plane], start, along, across, &pair, f.bit_depth, i16)
			} else {
				filter_pair(f.planes[plane], start, along, across, &pair, f.bit_depth, i32)
			}
		}
	}
}


@(private)
edge_decision :: proc(f: ^Loop_Filter_Frame($T), cell: ^Filter_Cell, plane, pass, edge, x, y, sub_x, sub_y, sub: int) -> (d: Edge_Decision) {
	lvl := int(cell.level)
	if lvl == 0 do return
	mi_size := int(cell.mi_size)
	tx := int(cell.tx_size[min(plane, 1)])
	// Block widths and transform sizes are powers of two.
	sb_size := sub == 0 ? mi_size : max(BLOCK_16X16, mi_size)
	block_edge := pass == 0 ? x & (8 * int(NUM_8X8_BLOCKS_WIDE_LOOKUP[sb_size]) - 1) == 0 : y & (8 * int(NUM_8X8_BLOCKS_HIGH_LOOKUP[sb_size]) - 1) == 0
	tx_edge: bool
	if pass == 1 && sub_x == 1 && f.mi_cols & 1 == 1 && edge & 1 == 1 && x + 8 >= f.mi_cols * 8 {
		tx_edge = false // a chroma row edge crossing the right edge of the image
	} else {
		tx_edge = edge & (1 << uint(tx) - 1) == 0
	}
	d.apply = block_edge || tx_edge && !cell.skip
	// Filter size (8.8.3).
	base := tx == TX_4X4 && edge & 7 == 0 ? TX_8X8 : min(TX_16X16, tx)
	d.size = base
	if base == TX_16X16 {
		if pass == 0 && sub_x == 1 && x >> 3 == f.mi_cols - 1 do d.size = TX_8X8
		if pass == 1 && sub_y == 1 && y >> 3 == f.mi_rows - 1 do d.size = TX_8X8
	}
	// Strength (8.8.4).
	l := &f.limits[lvl]
	d.limit, d.blimit, d.thresh = l.limit, l.blimit, l.thresh
	return
}


// Samples across an edge for sixteen lines, a lane per line: p[k] is p_k
// (k samples before the edge, minus one), q[k] is q_k.
@(private)
Edge_Lanes :: struct($V: typeid) {
	p, q: [8]V,
}

// Filters the lines of one edge pair (8.8.5) in lanes of E: i16 through 10
// bits, where no filter sum overflows them, i32 at 12. `base` is q0 of the
// pair's first line, `along` steps between lines, `across` across the edge.
// Lanes 0..7 are the first cell's lines and take its decision, lanes 8..15
// the second's. Unfiltered lanes are stored back unchanged.
@(private)
filter_pair :: proc(plane: []$T, base, along, across: int, pair: ^Edge_Pair, bit_depth: int, $E: typeid) {
	// Sixteen-tap filters reach eight samples either side, the others four.
	sixteen := pair.lines[0] > 0 && pair.d[0].size == TX_16X16 || pair.lines[1] > 0 && pair.d[1].size == TX_16X16
	if sixteen {filter_lanes(plane, base, along, across, pair, bit_depth, E, 8)} else {filter_lanes(plane, base, along, across, pair, bit_depth, E, 4)}
}

@(private)
filter_lanes :: proc(plane: []$T, base, along, across: int, pair: ^Edge_Pair, bit_depth: int, $E: typeid, $reach: int) #no_bounds_check {
	V :: #simd[16]E
	M :: type_of(simd.lanes_eq(V{}, V{}))
	halves :: #force_inline proc "contextless" (a, b: i32) -> V {
		return simd.select(simd.lanes_lt(simd.indices(V), V(8)), V(E(a)), V(E(b)))
	}
	shr :: #force_inline proc "contextless" (v: V, $n: uint) -> V {return simd.shr(v, M(n))}
	le :: #force_inline proc "contextless" (a, b: V) -> M {return simd.lanes_le(a, b)}
	both :: #force_inline proc "contextless" (a, b: M) -> M {return simd.bit_and(a, b)}
	c :: #force_inline proc "contextless" (v, lo, hi: V) -> V {return simd.clamp(v, lo, hi)}

	d0, d1 := &pair.d[0], &pair.d[1]
	size0 := pair.lines[0] > 0 ? d0.size : -1
	size1 := pair.lines[1] > 0 ? d1.size : -1
	e := load_pair(plane, base, along, across, reach, V)
	shift := uint(bit_depth - 8)
	limit := halves(d0.limit << shift, d1.limit << shift)
	blimit := halves(d0.blimit << shift, d1.blimit << shift)
	thresh := halves(d0.thresh << shift, d1.thresh << shift)
	lane := simd.indices(V)
	active := simd.lanes_lt(lane, halves(i32(pair.lines[0]), 8 + i32(pair.lines[1])))
	p, q := &e.p, &e.q
	mask := both(both(both(le(simd.abs_diff(p[3], p[2]), limit), le(simd.abs_diff(p[2], p[1]), limit)), both(le(simd.abs_diff(p[1], p[0]), limit), le(simd.abs_diff(q[1], q[0]), limit))), both(both(le(simd.abs_diff(q[2], q[1]), limit), le(simd.abs_diff(q[3], q[2]), limit)), le(simd.abs_diff(p[0], q[0]) * 2 + shr(simd.abs_diff(p[1], q[1]), 1), blimit)))
	mask = both(mask, active)
	if simd.reduce_or(mask) == 0 do return
	hev := simd.bit_or(simd.lanes_gt(simd.abs_diff(p[1], p[0]), thresh), simd.lanes_gt(simd.abs_diff(q[1], q[0]), thresh))
	one := V(E(1) << shift)
	sizes := halves(i32(size0), i32(size1))
	flat := both(both(both(le(simd.abs_diff(p[1], p[0]), one), le(simd.abs_diff(q[1], q[0]), one)), both(le(simd.abs_diff(p[2], p[0]), one), le(simd.abs_diff(q[2], q[0]), one))), both(le(simd.abs_diff(p[3], p[0]), one), le(simd.abs_diff(q[3], q[0]), one)))
	flat = both(flat, simd.lanes_ge(sizes, V(TX_8X8)))
	flat2 := M(0)
	when reach == 8 {
		flat2 = both(flat, simd.lanes_eq(sizes, V(TX_16X16)))
		#unroll for k in 4 ..< 8 do flat2 = both(flat2, both(le(simd.abs_diff(p[k], p[0]), one), le(simd.abs_diff(q[k], q[0]), one)))
	}
	out := e
	// Narrow filter (8.8.5.2) on lanes that are not flat.
	half := V(E(0x80) << shift)
	lo, hi := V(-(E(1) << uint(bit_depth - 1))), V((E(1) << uint(bit_depth - 1)) - 1)
	ps1, ps0, qs0, qs1 := p[1] - half, p[0] - half, q[0] - half, q[1] - half
	filter := simd.select(hev, c(ps1 - qs1, lo, hi), V(0))
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
	wide8 := simd.bit_and(simd.bit_and(mask, flat), simd.bit_not(flat2))
	if simd.reduce_or(wide8) != 0 do wide_filter(&e, &out, 3, wide8)
	when reach == 8 {
		wide16 := simd.bit_and(mask, flat2)
		if simd.reduce_or(wide16) != 0 do wide_filter(&e, &out, 4, wide16)
	}
	store_pair(plane, base, along, across, reach, &out)
}

// Low-pass over 2^log2 taps either side (8.8.5.3): modifies the n = 2^(log2-1)-1
// samples nearest the edge on each side, for the lanes in `lanes`.
@(private)
wide_filter :: #force_inline proc(e, out: ^Edge_Lanes($V), $log2: uint, lanes: $M) {
	n :: (1 << (log2 - 1)) - 1
	// s[k + 8] is the sample at signed position k: p_j at -(j+1), q_j at j.
	s: [16]V
	#unroll for k in 0 ..< 8 {
		s[7 - k] = e.p[k]
		s[8 + k] = e.q[k]
	}
	// The 2n+1 tap window slides one sample per output: add the sample
	// entering on the right, drop the one leaving on the left.
	window: V
	#unroll for j in -n ..= n do window += s[clamp(-n + j, -(n + 1), n) + 8]
	#unroll for i in -n ..< n {
		v := simd.shr(s[i + 8] + window + (1 << (log2 - 1)), M(log2))
		if i < 0 {
			out.p[-i - 1] = simd.select(lanes, v, out.p[-i - 1])
		} else {
			out.q[i] = simd.select(lanes, v, out.q[i])
		}
		window += s[min(i + n + 1, n) + 8] - s[max(i - n, -(n + 1)) + 8]
	}
}

// Across a horizontal edge the lines are adjacent samples of one row, so a
// sample position is a single load. Across a vertical edge each line is a
// row: a row holds reach / 4 groups of eight samples from -reach, each
// cell's groups are transposed 8 x 8 and the two cells joined into lanes.
@(private)
load_pair :: #force_inline proc(plane: []$T, base, along, across: int, $reach: int, $V: typeid/#simd[16]$E) -> (e: Edge_Lanes(V)) #no_bounds_check {
	if across != 1 {
		#unroll for k in 0 ..< reach {
			e.q[k] = V(intrinsics.unaligned_load((^#simd[16]T)(&plane[base + k * across])))
			e.p[k] = V(intrinsics.unaligned_load((^#simd[16]T)(&plane[base - (k + 1) * across])))
		}
		return
	}
	H :: #simd[8]E
	G :: reach / 4
	join :: #force_inline proc "contextless" (a, b: H) -> V {return simd.shuffle(a, b, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)}
	cols: [2][G][8]H // cell, group, sample within the group
	#unroll for cell in 0 ..< 2 do #unroll for g in 0 ..< G {
		rows: [8]H
		#unroll for line in 0 ..< 8 {
			at := base + (8 * cell + line) * along - reach + 8 * g
			rows[line] = H(intrinsics.unaligned_load((^#simd[8]T)(&plane[at])))
		}
		cols[cell][g] = common.transpose(rows)
	}
	#unroll for k in 0 ..< reach {
		p, q := reach - 1 - k, reach + k // p_k is sample -(k + 1), q_k sample k
		e.p[k] = join(cols[0][p >> 3][p & 7], cols[1][p >> 3][p & 7])
		e.q[k] = join(cols[0][q >> 3][q & 7], cols[1][q >> 3][q & 7])
	}
	return
}

@(private)
store_pair :: #force_inline proc(plane: []$T, base, along, across: int, $reach: int, e: ^Edge_Lanes($V/#simd[16]$E)) #no_bounds_check {
	if across != 1 {
		// p3 and q3 (p7 and q7 for 16 taps) never change.
		#unroll for k in 0 ..< reach - 1 {
			intrinsics.unaligned_store((^#simd[16]T)(&plane[base + k * across]), (#simd[16]T)(e.q[k]))
			intrinsics.unaligned_store((^#simd[16]T)(&plane[base - (k + 1) * across]), (#simd[16]T)(e.p[k]))
		}
		return
	}
	H :: #simd[8]E
	G :: reach / 4
	half :: #force_inline proc "contextless" (v: V, cell: int) -> H {
		return cell == 0 ? simd.shuffle(v, v, 0, 1, 2, 3, 4, 5, 6, 7) : simd.shuffle(v, v, 8, 9, 10, 11, 12, 13, 14, 15)
	}
	#unroll for cell in 0 ..< 2 {
		cols: [G][8]H
		#unroll for k in 0 ..< reach {
			p, q := reach - 1 - k, reach + k
			cols[p >> 3][p & 7] = half(e.p[k], cell)
			cols[q >> 3][q & 7] = half(e.q[k], cell)
		}
		#unroll for g in 0 ..< G {
			rows := common.transpose(cols[g])
			#unroll for line in 0 ..< 8 {
				at := base + (8 * cell + line) * along - reach + 8 * g
				intrinsics.unaligned_store((^#simd[8]T)(&plane[at]), (#simd[8]T)(rows[line]))
			}
		}
	}
}

package h265_decoder

import common "../../../common"
import "base:intrinsics"

import hevc ".."
import "core:simd"

// ---------------------------------------------------------------------------
// In-loop deblocking filter (8.7.2), ported from gen2brain/h265 hevc/deblock.go
// (MIT); oxideav-h265 src/deblock.rs is the per-file cross-reference. The
// reference processes every vertical edge in the
// picture and then every horizontal one, both on the eight-sample grid.
// ---------------------------------------------------------------------------

// Table 8-12.
DEBLOCK_BETA := [52]i32 {
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	6,
	7,
	8,
	9,
	10,
	11,
	12,
	13,
	14,
	15,
	16,
	17,
	18,
	20,
	22,
	24,
	26,
	28,
	30,
	32,
	34,
	36,
	38,
	40,
	42,
	44,
	46,
	48,
	50,
	52,
	54,
	56,
	58,
	60,
	62,
	64,
}

// Table 8-13.
DEBLOCK_TC := [54]i32 {
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	2,
	2,
	2,
	2,
	3,
	3,
	3,
	3,
	4,
	4,
	4,
	5,
	5,
	6,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	14,
	16,
	18,
	20,
	22,
	24,
}

// boundary_strength is 8.7.2.4.
boundary_strength :: proc(
	d: ^Ctu_Decoder($Sample),
	x_p, y_p, x_q, y_q: int,
	vertical: bool,
) -> int #no_bounds_check {
	qi := blk_index(d, x_q, y_q)
	q := &d.grids.blk[qi]

	tu := q.tu_v
	pu := q.pu_v

	if !vertical do tu, pu = q.tu_h, q.pu_h

	// 8.7.2 filters transform and prediction block edges only, not every edge
	// on the eight-sample grid, and most of them are neither.
	if !tu && !pu do return 0

	pi := blk_index(d, x_p, y_p)
	p := &d.grids.blk[pi]

	if p.intra || q.intra do return 2

	if tu && (p.cbf || q.cbf) do return 1


	if different_motion(&d.grids.motion[pi], &d.grids.motion[qi]) {
		return 1
	}

	return 0
}

mv_far :: #force_inline proc(a, b: Mv) -> bool {
	return abs_i32(i32(a.x) - i32(b.x)) >= 4 || abs_i32(i32(a.y) - i32(b.y)) >= 4
}

// different_motion is the motion part of 8.7.2.4, comparing the pictures each
// block recorded when it was decoded.
different_motion :: proc(p, q: ^Motion) -> bool #no_bounds_check {
	pp, qp: [2]i32
	pv, qv: [2]Mv
	np, nq: int

	for l in 0 ..< 2 {
		if p.info.pred[l] {
			pp[np], pv[np] = p.poc[l], p.info.mv[l]
			np += 1
		}

		if q.info.pred[l] {
			qp[nq], qv[nq] = q.poc[l], q.info.mv[l]
			nq += 1
		}
	}

	if np != nq do return true

	if np == 1 do return pp[0] != qp[0] || mv_far(pv[0], qv[0])

	if np == 0 do return false

	if pp[0] == qp[0] && pp[1] == qp[1] {
		if pp[0] == pp[1] {
			return(
				(mv_far(pv[0], qv[0]) || mv_far(pv[1], qv[1])) &&
				(mv_far(pv[0], qv[1]) || mv_far(pv[1], qv[0])) \
			)
		}

		return mv_far(pv[0], qv[0]) || mv_far(pv[1], qv[1])
	}

	if pp[0] == qp[1] && pp[1] == qp[0] {
		return mv_far(pv[0], qv[1]) || mv_far(pv[1], qv[0])
	}

	return true
}

// deblock is 8.7.2: every vertical edge in the picture, then every horizontal
// one, both on the eight-sample grid, in the slices that enable it.
deblock :: proc(d: ^Ctu_Decoder($Sample)) #no_bounds_check {
	enabled := false
	for addr in d.grids.ctb_slice_addr do enabled ||= !d.grids.slice_filters[addr].deblocking_disabled
	if !enabled do return

	w, h := int(d.s.pic_width_in_luma_samples), int(d.s.pic_height_in_luma_samples)
	luma, stride := plane_at(Sample, d.pic, 0)
	has_chroma := sps_chroma_array_type(d.s) != 0

	for vertical in ([2]bool{true, false}) {
		for r in 0 ..< (h + 7) / 8 {
			y := r * 8

			if !vertical && y == 0 do continue

			for x := 0; x < w; x += 8 {
				if vertical && x == 0 do continue

				deblock_edge(d, luma, stride, w, h, has_chroma, x, y, vertical)
			}
		}
	}
}

deblock_edge :: proc(
	d: ^Ctu_Decoder($Sample),
	luma: []Sample,
	stride, w, h: int,
	has_chroma: bool,
	x, y: int,
	vertical: bool,
) #no_bounds_check {
	// An edge belongs to the coding unit holding q0, and so to its slice.
	ctb := uint(d.s.ctb_log2_size_y)
	sl := &d.grids.slice_filters[d.grids.ctb_slice_addr[(y >> ctb) * int(d.s.pic_width_in_ctbs) + x >> ctb]]
	if sl.deblocking_disabled do return

	// 8.7.2 asks about tile and slice boundaries only when the edge sits on a
	// coding tree block boundary; tiles are aligned to those.
	ctb_mask := (1 << uint(d.s.ctb_log2_size_y)) - 1
	across := x & ctb_mask == 0
	if !vertical do across = y & ctb_mask == 0

	step, line := 1, stride
	if !vertical do step, line = stride, 1

	base := y * stride + x

	groups: [2]Luma_Group
	no_p, no_q: [2]bool
	on_c: [2]bool
	qp_c: [2]i32

	for k := 0; k < 8; k += 4 {
		px, py, qx, qy: int

		if vertical {
			px, py = x - 1, y + k
			qx, qy = x, y + k
		} else {
			px, py = x + k, y - 1
			qx, qy = x + k, y
		}

		if qy >= h || qx >= w {
			continue
		}

		if across && !filter_edge(d, px, py, qx, qy) do continue

		bs := boundary_strength(d, px, py, qx, qy, vertical)
		if bs == 0 do continue

		pt, qt := tb_index(d, px, py), tb_index(d, qx, qy)

		qp := (i32(d.grids.qp_y[pt]) + i32(d.grids.qp_y[qt]) + 1) >> 1

		// 8.7.2.5.3 leaves a side untouched when its coding unit bypassed the
		// transform, or is pulse code modulated with filtering turned off.
		no_p[k >> 2], no_q[k >> 2] = d.grids.no_filter[pt], d.grids.no_filter[qt]

		if beta, tc := beta_tc(qp, bs, sl, int(d.s.bit_depth_luma)); beta != 0 && tc != 0 {
			groups[k >> 2] = {beta, tc, no_p[k >> 2], no_q[k >> 2]}
		}

		if bs != 2 || !has_chroma do continue

		if (vertical && x % (8 * d.s.sub_width_c) != 0) ||
		   (!vertical && y % (8 * d.s.sub_height_c) != 0) {
			continue
		}

		on_c[k >> 2], qp_c[k >> 2] = true, qp
	}

	if on_c[0] || on_c[1] do deblock_chroma_edge(d, x, y, vertical, sl, &on_c, &qp_c, &no_p, &no_q)

	// Most grid edges filter nothing.
	if groups[0].tc != 0 || groups[1].tc != 0 {
		deblock_luma_lines(luma, base, line, step, &groups, int(d.s.bit_depth_luma))
	}
}

// deblock_chroma_edge is 8.7.2.5.5 over one edge, both groups sharing a call.
deblock_chroma_edge :: proc(
	d: ^Ctu_Decoder($Sample),
	x, y: int,
	vertical: bool,
	sl: ^Slice_Filters,
	on: ^[2]bool,
	qp: ^[2]i32,
	no_p, no_q: ^[2]bool,
) #no_bounds_check {
	if !on[0] && !on[1] do return

	sw, sh := d.s.sub_width_c, d.s.sub_height_c

	// The four-sample luma segment spans 4/subHeightC chroma rows on a
	// vertical edge, and 4/subWidthC columns on a horizontal one.
	n := 4 / sh
	if !vertical do n = 4 / sw

	both := on[0] && on[1] && qp[0] == qp[1] && no_p[0] == no_p[1] && no_q[0] == no_q[1]

	cb, cs := plane_at(Sample, d.pic, 1)
	cr, _ := plane_at(Sample, d.pic, 2)

	for g in 0 ..< 2 {
		if !on[g] do continue

		cx, cy := x, y + 4 * g
		if !vertical do cx, cy = x + 4 * g, y

		lines := n
		if both {
			if g != 0 do continue

			lines = 2 * n
		}

		cat := int(sps_chroma_array_type(d.s))
		_, tc_cb := beta_tc(
			hevc.chroma_qp(clip3(qp[g] + d.p.cb_qp_offset, 0, 57), cat),
			2,
			sl,
			int(d.s.bit_depth_chroma),
		)
		_, tc_cr := beta_tc(
			hevc.chroma_qp(clip3(qp[g] + d.p.cr_qp_offset, 0, 57), cat),
			2,
			sl,
			int(d.s.bit_depth_chroma),
		)

		if tc_cb == 0 && tc_cr == 0 do continue

		deblock_chroma_pair(
			cb,
			cr,
			cs,
			cx / sw,
			cy / sh,
			lines,
			vertical,
			tc_cb,
			tc_cr,
			int(d.s.bit_depth_chroma),
			no_p[g],
			no_q[g],
		)
	}
}

beta_tc :: proc(qp: i32, bs: int, sh: ^Slice_Filters, bit_depth: int) -> (i32, i32) {
	qb := clip3(qp + i32(sh.beta_offset_div2) * 2, 0, 51)
	beta := DEBLOCK_BETA[int(qb)] * (1 << uint(bit_depth - 8))

	qt := clip3(qp + 2 * i32(bs - 1) + i32(sh.tc_offset_div2) * 2, 0, 53)
	tc := DEBLOCK_TC[int(qt)] * (1 << uint(bit_depth - 8))

	return beta, tc
}

// The eight lines across one luma edge on the eight-sample grid, a lane per
// line and a vector per sample position: p0 and q0 are adjacent to the edge
// (8.7.2.5.7). Lines 0..3 and 4..7 are the two decision groups (8.7.2.5.3).
Edge_Lanes :: struct($T: typeid) {
	p3, p2, p1, p0, q0, q1, q2, q3: #simd[EDGE_LINES]T,
}

EDGE_LINES :: 8

// The parameters 8.7.2.5.3 decides a group with. A zero tc leaves the group
// unfiltered; a side whose coding unit bypassed the transform, or is PCM with
// filtering off, keeps its samples.
Luma_Group :: struct {
	beta, tc:   i32,
	no_p, no_q: bool,
}

// deblock_luma_lines decides and filters the eight lines of one luma edge:
// line l's sample i is plane[base + l * line + i * step], with q0 at i = 0.
// Lanes are i16 through 10-bit samples, where no sum overflows them.
deblock_luma_lines :: proc(
	plane: []$Sample,
	base, line, step: int,
	groups: ^[2]Luma_Group,
	bit_depth: int,
) {
	if bit_depth <= 10 {
		luma_lines(i16, plane, base, line, step, groups, i32(1) << uint(bit_depth) - 1)
	} else {
		luma_lines(i32, plane, base, line, step, groups, i32(1) << uint(bit_depth) - 1)
	}
}

@(private = "file")
luma_lines :: proc(
	$T: typeid,
	plane: []$Sample,
	base, line, step: int,
	groups: ^[2]Luma_Group,
	max_v: i32,
) #no_bounds_check {
	V :: #simd[EDGE_LINES]T
	U :: intrinsics.type_integer_to_unsigned(T)
	M :: #simd[EDGE_LINES]U // lane masks
	// Lanes 0..3 take group 0's value, lanes 4..7 group 1's.
	per_group :: proc(a, b: $E) -> #simd[EDGE_LINES]E {return {a, a, a, a, b, b, b, b}}
	mask :: proc(v: [2]bool) -> M {return per_group(v[0] ? max(U) : 0, v[1] ? max(U) : 0)}
	shr :: proc(v: V, $n: u64) -> V {return simd.shr(v, (#simd[EDGE_LINES]U)(n))}

	e := edge_load(T, plane, base, line, step)
	beta := per_group(T(groups[0].beta), T(groups[1].beta))
	tc := per_group(T(groups[0].tc), T(groups[1].tc))

	// 8.7.2.5.3 on every line: the curvature on each side, and dSam's flat
	// small step across the edge. Each group decides from its lines 0 and 3.
	curve_p, curve_q := simd.abs(e.p2 - 2 * e.p1 + e.p0), simd.abs(e.q2 - 2 * e.q1 + e.q0)
	flat := simd.bit_and(
		simd.lanes_lt(2 * (curve_p + curve_q), shr(beta, 2)),
		simd.bit_and(
			simd.lanes_lt(simd.abs(e.p3 - e.p0) + simd.abs(e.q0 - e.q3), shr(beta, 3)),
			simd.lanes_lt(simd.abs(e.p0 - e.q0), shr(5 * tc + 1, 1)),
		),
	)
	cp, cq := transmute([EDGE_LINES]T)curve_p, transmute([EDGE_LINES]T)curve_q
	is_flat := transmute([EDGE_LINES]U)flat
	strong, weak, wide_p, wide_q: [2]bool
	for g in 0 ..< 2 {
		first, last := 4 * g, 4 * g + 3
		dp, dq := i32(cp[first]) + i32(cp[last]), i32(cq[first]) + i32(cq[last])
		if groups[g].tc == 0 || dp + dq >= groups[g].beta do continue
		strong[g] = is_flat[first] != 0 && is_flat[last] != 0
		weak[g] = !strong[g]
		side := (groups[g].beta + groups[g].beta >> 1) >> 3
		wide_p[g], wide_q[g] = dp < side && !groups[g].no_p, dq < side && !groups[g].no_q
	}
	if !strong[0] && !strong[1] && !weak[0] && !weak[1] do return
	on_p, on_q :=
		mask({!groups[0].no_p, !groups[1].no_p}), mask({!groups[0].no_q, !groups[1].no_q})
	p3, p2, p1, p0, q0, q1, q2, q3 := e.p3, e.p2, e.p1, e.p0, e.q0, e.q1, e.q2, e.q3

	if strong[0] || strong[1] {
		// 8.7.2.5.7 with dE == 2: each sample moves at most 2 * tc, which keeps
		// the averages within the sample range.
		near :: proc(v, around, limit: V) -> V {return simd.clamp(
				v,
				around - limit,
				around + limit,
			)}
		s_p, s_q := simd.bit_and(mask(strong), on_p), simd.bit_and(mask(strong), on_q)
		c := tc * 2
		e.p0 = simd.select(s_p, near(shr(p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4, 3), p0, c), p0)
		e.p1 = simd.select(s_p, near(shr(p2 + p1 + p0 + q0 + 2, 2), p1, c), p1)
		e.p2 = simd.select(s_p, near(shr(2 * p3 + 3 * p2 + p1 + p0 + q0 + 4, 3), p2, c), p2)
		e.q0 = simd.select(s_q, near(shr(p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4, 3), q0, c), q0)
		e.q1 = simd.select(s_q, near(shr(p0 + q0 + q1 + q2 + 2, 2), q1, c), q1)
		e.q2 = simd.select(s_q, near(shr(p0 + q0 + q1 + 3 * q2 + 2 * q3 + 4, 3), q2, c), q2)
	}

	if weak[0] || weak[1] {
		// dE == 1: a line whose step is below ten times tc moves by delta, and
		// the second samples by half-clipped corrections.
		clip1 :: proc(v: V, max_v: i32) -> V {return simd.clamp(v, V(0), V(T(max_v)))}
		delta := shr(9 * (q0 - p0) - 3 * (q1 - p1) + 8, 4)
		moves := simd.bit_and(mask(weak), simd.lanes_lt(simd.abs(delta), tc * 10))
		w_p, w_q := simd.bit_and(moves, on_p), simd.bit_and(moves, on_q)
		delta = simd.clamp(delta, -tc, tc)
		half := shr(tc, 1)
		dp := simd.clamp(shr(shr(p2 + p0 + 1, 1) - p1 + delta, 1), -half, half)
		dq := simd.clamp(shr(shr(q2 + q0 + 1, 1) - q1 - delta, 1), -half, half)
		e.p0 = simd.select(w_p, clip1(p0 + delta, max_v), e.p0)
		e.q0 = simd.select(w_q, clip1(q0 - delta, max_v), e.q0)
		e.p1 = simd.select(simd.bit_and(w_p, mask(wide_p)), clip1(p1 + dp, max_v), e.p1)
		e.q1 = simd.select(simd.bit_and(w_q, mask(wide_q)), clip1(q1 + dq, max_v), e.q1)
	}
	edge_store(plane, base, line, step, &e)
}

// edge_load gathers the eight lines of an edge. Across a horizontal edge the
// lines are adjacent samples, so each sample position is one picture row;
// across a vertical edge each line is a row, so the rows are transposed.
@(private = "file")
edge_load :: proc(
	$T: typeid,
	plane: []$Sample,
	base, line, step: int,
) -> Edge_Lanes(T) #no_bounds_check {
	rows: [8]#simd[EDGE_LINES]T
	for &row, i in rows {
		at := line == 1 ? base + (i - 4) * step : base - 4 + i * line
		row = (#simd[EDGE_LINES]T)(
			intrinsics.unaligned_load((^#simd[EDGE_LINES]Sample)(&plane[at])),
		)
	}
	if line != 1 do rows = common.transpose(rows)
	return transmute(Edge_Lanes(T))rows
}

// edge_store writes the lines back; p3 and q3 never change, so a horizontal
// edge stores six rows.
@(private = "file")
edge_store :: proc(plane: []$Sample, base, line, step: int, e: ^Edge_Lanes($T)) #no_bounds_check {
	rows := transmute([8]#simd[EDGE_LINES]T)e^
	first, end := 1, 7
	if line != 1 do rows, first, end = common.transpose(rows), 0, 8
	for i in first ..< end {
		at := line == 1 ? base + (i - 4) * step : base - 4 + i * line
		intrinsics.unaligned_store(
			(^#simd[EDGE_LINES]Sample)(&plane[at]),
			(#simd[EDGE_LINES]Sample)(rows[i]),
		)
	}
}

// deblock_chroma_pair is 8.7.2.5.5 over both components at once.
deblock_chroma_pair :: proc(
	cb, cr: []$Sample,
	stride, x, y, n: int,
	vertical: bool,
	tc_cb, tc_cr: i32,
	bit_depth: int,
	no_p, no_q: bool,
) #no_bounds_check {
	step, line := 1, stride
	if !vertical do step, line = stride, 1

	base := y * stride + x
	max_v := i32(1) << uint(bit_depth) - 1

	for l in 0 ..< n {
		off := base + l * line

		if tc_cb != 0 do chroma_line(cb, off, step, tc_cb, max_v, no_p, no_q)
		if tc_cr != 0 do chroma_line(cr, off, step, tc_cr, max_v, no_p, no_q)
	}
}

chroma_line :: proc(
	plane: []$Sample,
	off, step: int,
	tc, max_v: i32,
	no_p, no_q: bool,
) #no_bounds_check {
	p0, p1 := i32(plane[off - step]), i32(plane[off - 2 * step])
	q0, q1 := i32(plane[off]), i32(plane[off + step])

	delta := clip3((((q0 - p0) << 2) + p1 - q1 + 4) >> 3, -tc, tc)

	if !no_p do plane[off - step] = Sample(clip3(p0 + delta, 0, max_v))
	if !no_q do plane[off] = Sample(clip3(q0 - delta, 0, max_v))
}

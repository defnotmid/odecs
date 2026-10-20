package h264

import common "../common"
import "base:intrinsics"

import "core:simd"

// ---------------------------------------------------------------------------
// Deblocking filter (8.7). Edges are filtered 16 (luma) or 8 (chroma) samples
// at a time: the samples along an edge form the lanes, p3..q3 the rows.
// ---------------------------------------------------------------------------

mv_differs :: #force_inline proc(a, b: [2]i16) -> bool {
	// 8.7.2.1 compares mathematical differences, not wrapping i16 differences.
	return abs(i32(a[0]) - i32(b[0])) >= 4 || abs(i32(a[1]) - i32(b[1])) >= 4
}

// One reference/motion matching owner for scalar and whole-MB classification.
// Every widened component difference is in [-65535,65535].
@(private)
inter_strength_lanes :: #force_inline proc(
	p_dir, q_dir: #simd[$N]i32,
	p_pics, q_pics: [2]#simd[N]i32,
	p_mv, q_mv: [2][2]#simd[N]i32,
) -> #simd[N]i32 {
	V :: #simd[N]i32
	equal_motion :: #force_inline proc(a, b: [2]#simd[N]i32) -> #simd[N]u32 {
		return simd.bit_and(
			simd.lanes_lt(simd.abs(simd.sub(a[0], b[0])), V(4)),
			simd.lanes_lt(simd.abs(simd.sub(a[1], b[1])), V(4)),
		)
	}
	p_list0 := simd.lanes_eq(p_dir, V(i32(Prediction_Direction.List_0)))
	q_list0 := simd.lanes_eq(q_dir, V(i32(Prediction_Direction.List_0)))
	p_pic := simd.select(p_list0, p_pics[0], p_pics[1])
	q_pic := simd.select(q_list0, q_pics[0], q_pics[1])
	p_single := [2]V {
		simd.select(p_list0, p_mv[0][0], p_mv[1][0]),
		simd.select(p_list0, p_mv[0][1], p_mv[1][1]),
	}
	q_single := [2]V {
		simd.select(q_list0, q_mv[0][0], q_mv[1][0]),
		simd.select(q_list0, q_mv[0][1], q_mv[1][1]),
	}
	single_equal := simd.bit_and(simd.lanes_eq(p_pic, q_pic), equal_motion(p_single, q_single))
	single_pair := simd.bit_and(
		simd.lanes_ne(p_dir, V(i32(Prediction_Direction.Bidirectional))),
		simd.lanes_ne(q_dir, V(i32(Prediction_Direction.Bidirectional))),
	)
	if simd.reduce_all(single_pair) do return simd.select(single_equal, V(0), V(1))
	same := simd.bit_and(simd.lanes_eq(p_pics[0], q_pics[0]), simd.lanes_eq(p_pics[1], q_pics[1]))
	swapped := simd.bit_and(
		simd.lanes_eq(p_pics[0], q_pics[1]),
		simd.lanes_eq(p_pics[1], q_pics[0]),
	)
	direct := simd.bit_and(equal_motion(p_mv[0], q_mv[0]), equal_motion(p_mv[1], q_mv[1]))
	crossed := simd.bit_and(equal_motion(p_mv[0], q_mv[1]), equal_motion(p_mv[1], q_mv[0]))
	matching := simd.select(
		simd.lanes_eq(p_pics[0], p_pics[1]),
		simd.bit_or(direct, crossed),
		simd.bit_or(simd.bit_and(same, direct), simd.bit_and(swapped, crossed)),
	)
	bidi_equal := simd.bit_and(
		simd.lanes_eq(p_dir, q_dir),
		simd.bit_and(simd.bit_or(same, swapped), matching),
	)
	return simd.select(simd.select(single_pair, single_equal, bidi_equal), V(0), V(1))
}

// Boundary strength between inter blocks p_sub of p and q_sub of q (8.7.2.1), frames only
inter_strength :: #force_inline proc(p, q: #soa^#soa[]Macroblock, p_sub, q_sub: int) -> u8 {
	V :: #simd[1]i32
	p_pics: [2]V = ---
	q_pics: [2]V = ---
	p_mv: [2][2]V = ---
	q_mv: [2][2]V = ---
	#unroll for list in 0 ..< 2 {
		p_pics[list], q_pics[list] =
			V(p.reference_picture_ids[list][p_sub / 4]),
			V(q.reference_picture_ids[list][q_sub / 4])
		#unroll for component in 0 ..< 2 {
			p_mv[list][component], q_mv[list][component] =
				V(i32(p.motion_vectors[list][p_sub][component])),
				V(i32(q.motion_vectors[list][q_sub][component]))
		}
	}
	return u8(
		simd.extract(
			inter_strength_lanes(
				V(i32(p.prediction_directions[p_sub / 4])),
				V(i32(q.prediction_directions[q_sub / 4])),
				p_pics,
				q_pics,
				p_mv,
				q_mv,
			),
			0,
		),
	)
}

// 4x4 blocks (decoding order) on the p and q side of edge `edge`, per position along the edge
edge_blocks: [2][4][4][2]u8 = {
	{ 	// vertical edges: p = column edge-1 (3 of the neighbour for edge 0), q = column edge
		{{5, 0}, {7, 2}, {13, 8}, {15, 10}},
		{{0, 1}, {2, 3}, {8, 9}, {10, 11}},
		{{1, 4}, {3, 6}, {9, 12}, {11, 14}},
		{{4, 5}, {6, 7}, {12, 13}, {14, 15}},
	},
	{ 	// horizontal edges: p = row edge-1 (3 of the neighbour for edge 0), q = row edge
		{{10, 0}, {11, 1}, {14, 4}, {15, 5}},
		{{0, 2}, {1, 3}, {4, 6}, {5, 7}},
		{{2, 8}, {3, 9}, {6, 12}, {7, 13}},
		{{8, 10}, {9, 11}, {12, 14}, {13, 15}},
	},
}

// Boundary strengths of one edge of q against p (the neighbour for edge 0, q itself otherwise)
edge_strengths :: proc(
	p, q: #soa^#soa[]Macroblock,
	edge: int,
	vertical: bool,
) -> (
	bs: [4]u8,
) #no_bounds_check {
	if p.is_intra || q.is_intra {
		v: u8 = edge == 0 ? 4 : 3
		return {v, v, v, v}
	}
	coded :: #force_inline proc(m: #soa^#soa[]Macroblock, sub: int) -> bool {
		return(
			m.uses_8x8_transform ? m.has_8x8_coefficients[sub / 4] : m.nonzero_coefficient_counts[sub] > 0 \
		)
	}
	blocks := &edge_blocks[vertical ? 0 : 1][edge]
	for k in 0 ..< 4 {
		p_sub, q_sub := int(blocks[k][0]), int(blocks[k][1])
		bs[k] = coded(p, p_sub) || coded(q, q_sub) ? 2 : inter_strength(p, q, p_sub, q_sub)
	}
	return
}

// Luma samples of one edge: lane i is sample i along the edge
Luma_Edge :: struct {
	p3, p2, p1, p0, q0, q1, q2, q3: #simd[16]i16,
}

Chroma_Edge :: struct {
	p1, p0, q0, q1: #simd[8]i16,
}

// bS and tC0 of the 4 (luma) or 8 (chroma, two samples each) lane groups expanded to lanes
expand_luma :: #force_inline proc(v: [4]u8) -> #simd[16]i16 {
	a := [16]i16 {
		i16(v[0]),
		i16(v[0]),
		i16(v[0]),
		i16(v[0]),
		i16(v[1]),
		i16(v[1]),
		i16(v[1]),
		i16(v[1]),
		i16(v[2]),
		i16(v[2]),
		i16(v[2]),
		i16(v[2]),
		i16(v[3]),
		i16(v[3]),
		i16(v[3]),
		i16(v[3]),
	}
	return transmute(#simd[16]i16)a
}

expand_chroma :: #force_inline proc(v: [4]u8) -> #simd[8]i16 {
	a := [8]i16 {
		i16(v[0]),
		i16(v[0]),
		i16(v[1]),
		i16(v[1]),
		i16(v[2]),
		i16(v[2]),
		i16(v[3]),
		i16(v[3]),
	}
	return transmute(#simd[8]i16)a
}

expand_luma_tc :: #force_inline proc(v: [4]i8) -> #simd[16]i16 {
	return expand_luma({u8(v[0]), u8(v[1]), u8(v[2]), u8(v[3])})
}

expand_chroma_tc :: #force_inline proc(v: [4]i8) -> #simd[8]i16 {
	return expand_chroma({u8(v[0]), u8(v[1]), u8(v[2]), u8(v[3])})
}

// Luma edge filtering (8.7.2.3, 8.7.2.4) of all lanes at once. Thresholds
// arrive scaled to the bit depth; filtered samples clip to pixel_max.
filter_luma_edge :: #force_inline proc(e: ^Luma_Edge, alpha, beta: i32, bs: [4]u8, tc0: [4]i8, pixel_max: i16) {
	L :: #simd[16]i16
	zero, one := L(0), L(1)
	alpha_lanes, beta_lanes := L(i16(alpha)), L(i16(beta))
	bs_lanes := expand_luma(bs)
	tc0_lanes := expand_luma_tc(tc0)
	p3, p2, p1, p0, q0, q1, q2, q3 := e.p3, e.p2, e.p1, e.p0, e.q0, e.q1, e.q2, e.q3

	d_p0q0 := simd.abs(simd.sub(p0, q0))
	active := simd.bit_and(
		simd.bit_and(simd.lanes_gt(bs_lanes, zero), simd.lanes_lt(d_p0q0, alpha_lanes)),
		simd.bit_and(
			simd.lanes_lt(simd.abs(simd.sub(p1, p0)), beta_lanes),
			simd.lanes_lt(simd.abs(simd.sub(q1, q0)), beta_lanes),
		),
	)
	ap_small := simd.lanes_lt(simd.abs(simd.sub(p2, p0)), beta_lanes)
	aq_small := simd.lanes_lt(simd.abs(simd.sub(q2, q0)), beta_lanes)

	// bS < 4: clipped delta on p0/q0, optional p1/q1
	tc := simd.add(
		tc0_lanes,
		simd.add(simd.select(ap_small, one, zero), simd.select(aq_small, one, zero)),
	)
	delta := simd.clamp(
		shr_lanes(
			simd.add(simd.add(simd.shl(simd.sub(q0, p0), (#simd[16]u16)(2)), simd.sub(p1, q1)), 4),
			3,
		),
		simd.neg(tc),
		tc,
	)
	weak_p0 := clamp_lanes(simd.add(p0, delta), pixel_max)
	weak_q0 := clamp_lanes(simd.sub(q0, delta), pixel_max)
	mid := shr_lanes(simd.add(simd.add(p0, q0), 1), 1)
	weak_p1 := simd.add(
		p1,
		simd.clamp(
			shr_lanes(simd.sub(simd.add(p2, mid), simd.shl(p1, (#simd[16]u16)(1))), 1),
			simd.neg(tc0_lanes),
			tc0_lanes,
		),
	)
	weak_q1 := simd.add(
		q1,
		simd.clamp(
			shr_lanes(simd.sub(simd.add(q2, mid), simd.shl(q1, (#simd[16]u16)(1))), 1),
			simd.neg(tc0_lanes),
			tc0_lanes,
		),
	)

	strong := simd.lanes_eq(bs_lanes, L(4))
	weak := simd.bit_and_not(active, strong)
	e.p0 = simd.select(weak, weak_p0, p0)
	e.q0 = simd.select(weak, weak_q0, q0)
	e.p1 = simd.select(simd.bit_and(weak, ap_small), weak_p1, p1)
	e.q1 = simd.select(simd.bit_and(weak, aq_small), weak_q1, q1)
	strong_active := simd.bit_and(active, strong)
	if !simd.reduce_any(strong_active) do return

	// bS == 4: strong filter when the edge is smooth, else the 3-tap.
	// Inter edges have no bS 4 lanes and keep only the weak results above.
	near := simd.lanes_lt(d_p0q0, L(i16((alpha >> 2) + 2)))
	sp := simd.bit_and(ap_small, near)
	sq := simd.bit_and(aq_small, near)
	two_p1 := simd.shl(p1, (#simd[16]u16)(1))
	two_q1 := simd.shl(q1, (#simd[16]u16)(1))
	p0_q0 := simd.add(p0, q0)
	strong_p0 := shr_lanes(
		simd.add(
			simd.add(simd.add(p2, two_p1), simd.add(simd.shl(p0_q0, (#simd[16]u16)(1)), q1)),
			4,
		),
		3,
	)
	strong_p1 := shr_lanes(simd.add(simd.add(simd.add(p2, p1), p0_q0), 2), 2)
	strong_p2 := shr_lanes(
		simd.add(
			simd.add(
				simd.add(simd.shl(p3, (#simd[16]u16)(1)), simd.mul(p2, L(3))),
				simd.add(simd.add(p1, p0), q0),
			),
			4,
		),
		3,
	)
	flat_p0 := shr_lanes(simd.add(simd.add(simd.add(two_p1, p0), q1), 2), 2)
	strong_q0 := shr_lanes(
		simd.add(
			simd.add(simd.add(q2, two_q1), simd.add(simd.shl(p0_q0, (#simd[16]u16)(1)), p1)),
			4,
		),
		3,
	)
	strong_q1 := shr_lanes(simd.add(simd.add(simd.add(q2, q1), p0_q0), 2), 2)
	strong_q2 := shr_lanes(
		simd.add(
			simd.add(
				simd.add(simd.shl(q3, (#simd[16]u16)(1)), simd.mul(q2, L(3))),
				simd.add(simd.add(q1, q0), p0),
			),
			4,
		),
		3,
	)
	flat_q0 := shr_lanes(simd.add(simd.add(simd.add(two_q1, q0), p1), 2), 2)

	e.p0 = simd.select(strong_active, simd.select(sp, strong_p0, flat_p0), e.p0)
	e.q0 = simd.select(strong_active, simd.select(sq, strong_q0, flat_q0), e.q0)
	e.p1 = simd.select(simd.bit_and(strong_active, sp), strong_p1, e.p1)
	e.q1 = simd.select(simd.bit_and(strong_active, sq), strong_q1, e.q1)
	e.p2 = simd.select(simd.bit_and(strong_active, sp), strong_p2, p2)
	e.q2 = simd.select(simd.bit_and(strong_active, sq), strong_q2, q2)
}

// Chroma edge filtering (8.7.2.3 with chromaEdgeFlag): p0/q0 only, tc already includes +1
filter_chroma_edge :: proc(e: ^Chroma_Edge, alpha, beta: i32, bs: [4]u8, tc: [4]i8, pixel_max: i16) {
	C :: #simd[8]i16
	zero := C(0)
	alpha_lanes, beta_lanes := C(i16(alpha)), C(i16(beta))
	bs_lanes := expand_chroma(bs)
	tc_lanes := expand_chroma_tc(tc)
	p1, p0, q0, q1 := e.p1, e.p0, e.q0, e.q1
	active := simd.bit_and(
		simd.bit_and(
			simd.lanes_gt(bs_lanes, zero),
			simd.lanes_lt(simd.abs(simd.sub(p0, q0)), alpha_lanes),
		),
		simd.bit_and(
			simd.lanes_lt(simd.abs(simd.sub(p1, p0)), beta_lanes),
			simd.lanes_lt(simd.abs(simd.sub(q1, q0)), beta_lanes),
		),
	)
	strong := simd.lanes_eq(bs_lanes, C(4))
	delta := simd.clamp(
		shr_lanes(
			simd.add(simd.add(simd.shl(simd.sub(q0, p0), (#simd[8]u16)(2)), simd.sub(p1, q1)), 4),
			3,
		),
		simd.neg(tc_lanes),
		tc_lanes,
	)
	weak_p0 := clamp_lanes(simd.add(p0, delta), pixel_max)
	weak_q0 := clamp_lanes(simd.sub(q0, delta), pixel_max)
	flat_p0 := shr_lanes(
		simd.add(simd.add(simd.add(simd.shl(p1, (#simd[8]u16)(1)), p0), q1), 2),
		2,
	)
	flat_q0 := shr_lanes(
		simd.add(simd.add(simd.add(simd.shl(q1, (#simd[8]u16)(1)), q0), p1), 2),
		2,
	)
	e.p0 = simd.select(active, simd.select(strong, flat_p0, weak_p0), p0)
	e.q0 = simd.select(active, simd.select(strong, flat_q0, weak_q0), q0)
}

// Horizontal edge: the rows p3..q3 are contiguous samples
deblock_luma_horizontal :: proc(
	pix: [^]$T,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc0: [4]i8,
	pixel_max: i16 = 255,
) #no_bounds_check {
	e := Luma_Edge {
		load_lanes(16, &pix[-4 * stride]),
		load_lanes(16, &pix[-3 * stride]),
		load_lanes(16, &pix[-2 * stride]),
		load_lanes(16, &pix[-stride]),
		load_lanes(16, pix),
		load_lanes(16, &pix[stride]),
		load_lanes(16, &pix[2 * stride]),
		load_lanes(16, &pix[3 * stride]),
	}
	filter_luma_edge(&e, alpha, beta, bs, tc0, pixel_max)
	store_lanes(&pix[-3 * stride], e.p2)
	store_lanes(&pix[-2 * stride], e.p1)
	store_lanes(&pix[-stride], e.p0)
	store_lanes(pix, e.q0)
	store_lanes(&pix[stride], e.q1)
	store_lanes(&pix[2 * stride], e.q2)
}

// Vertical edge: the 8 samples around the edge of each of the 16 rows are
// transposed into the p3..q3 lane vectors and back after filtering.
deblock_luma_vertical :: proc(
	pix: [^]$T,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc0: [4]i8,
	pixel_max: i16 = 255,
) #no_bounds_check {
	H :: #simd[8]i16
	upper, lower: [8]H
	for i in 0 ..< 8 {
		upper[i] = load_lanes(8, &pix[i * stride - 4])
		lower[i] = load_lanes(8, &pix[(i + 8) * stride - 4])
	}
	cu := common.transpose(upper) // cu[k] = column k of rows 0..7
	cl := common.transpose(lower)
	e: Luma_Edge
	columns := [8]^#simd[16]i16{&e.p3, &e.p2, &e.p1, &e.p0, &e.q0, &e.q1, &e.q2, &e.q3}
	#unroll for k in 0 ..< 8 do columns[k]^ = simd.shuffle(cu[k], cl[k], 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
	filter_luma_edge(&e, alpha, beta, bs, tc0, pixel_max)
	#unroll for k in 0 ..< 8 {
		cu[k] = simd.swizzle(columns[k]^, 0, 1, 2, 3, 4, 5, 6, 7)
		cl[k] = simd.swizzle(columns[k]^, 8, 9, 10, 11, 12, 13, 14, 15)
	}
	upper = common.transpose(cu)
	lower = common.transpose(cl)
	for i in 0 ..< 8 {
		store_lanes(&pix[i * stride - 4], upper[i])
		store_lanes(&pix[(i + 8) * stride - 4], lower[i])
	}
}

deblock_chroma_horizontal :: proc(
	pix: [^]$T,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc: [4]i8,
	pixel_max: i16 = 255,
) #no_bounds_check {
	e := Chroma_Edge {
		load_lanes(8, &pix[-2 * stride]),
		load_lanes(8, &pix[-stride]),
		load_lanes(8, pix),
		load_lanes(8, &pix[stride]),
	}
	filter_chroma_edge(&e, alpha, beta, bs, tc, pixel_max)
	store_lanes(&pix[-stride], e.p0)
	store_lanes(pix, e.q0)
}

// Vertical chroma edge: 8 rows of the 4 samples around the edge, transposed into the p1..q1 lanes
deblock_chroma_vertical :: proc(
	pix: [^]$T,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc: [4]i8,
	pixel_max: i16 = 255,
) #no_bounds_check {
	Q :: #simd[4]i16
	rows: [8]Q
	for i in 0 ..< 8 do rows[i] = load_lanes(4, &pix[i * stride - 2])
	pair: [4]#simd[8]i16
	#unroll for i in 0 ..< 4 do pair[i] = simd.shuffle(rows[2 * i], rows[2 * i + 1], 0, 4, 1, 5, 2, 6, 3, 7)
	quad01 := simd.shuffle(pair[0], pair[1], 0, 1, 8, 9, 2, 3, 10, 11) // k0: rows 0-3, k1: rows 0-3
	quad23 := simd.shuffle(pair[0], pair[1], 4, 5, 12, 13, 6, 7, 14, 15) // k2, k3 of rows 0-3
	quad45 := simd.shuffle(pair[2], pair[3], 0, 1, 8, 9, 2, 3, 10, 11) // rows 4-7
	quad67 := simd.shuffle(pair[2], pair[3], 4, 5, 12, 13, 6, 7, 14, 15)
	e := Chroma_Edge {
		simd.shuffle(quad01, quad45, 0, 1, 2, 3, 8, 9, 10, 11),
		simd.shuffle(quad01, quad45, 4, 5, 6, 7, 12, 13, 14, 15),
		simd.shuffle(quad23, quad67, 0, 1, 2, 3, 8, 9, 10, 11),
		simd.shuffle(quad23, quad67, 4, 5, 6, 7, 12, 13, 14, 15),
	}
	filter_chroma_edge(&e, alpha, beta, bs, tc, pixel_max)
	for i in 0 ..< 8 {
		row: [^]T = &pix[i * stride]
		row[-1] = T(simd.extract(e.p0, i))
		row[0] = T(simd.extract(e.q0, i))
	}
}

// QPC of a macroblock with QPY qp_y (8.5.8): qPI clipped to
// [-QpBdOffsetC, 51] maps through Table 8-15, which is the identity below 30.
chroma_qp :: #force_inline proc "contextless" (qp_y, offset, qp_bd_offset: i32) -> i32 {
	qpi := clamp(qp_y + offset, -qp_bd_offset, 51)
	return qpi < 0 ? qpi : i32(chroma_qp_table[qpi])
}

// What the filter depends on besides the macroblocks: the sample bit depth
// (thresholds scale by 1 << (bit_depth - 8), 8.7.2.2) and 4:2:2 chroma, whose
// full-height planes have four horizontal chroma edges per macroblock.
Deblock_Format :: struct {
	bit_depth:  int, // 0 means 8
	chroma_422: bool,
}

@(private)
Deblock_Threshold :: struct {
	alpha, beta: i32,
	tc:          [4]i8,
}

@(private)
Deblock_MB_Data :: struct {
	strengths:  [2][4][4]u8,
	// Internal edges, left boundary, top boundary; Y, Cb, Cr in each domain.
	thresholds: [3][3]Deblock_Threshold,
	// 8x8 transform: the odd internal luma edges are not filtered, though
	// 4:2:2 chroma filters the horizontal ones (their strengths are kept).
	transform8: bool,
}

@(private)
deblock_threshold :: #force_inline proc(
	qp, alpha_offset, beta_offset: i32,
	chroma: bool,
	depth_shift: uint,
) -> Deblock_Threshold {
	a, b := clamp(qp + alpha_offset, 0, 51), clamp(qp + beta_offset, 0, 51)
	tc :: #force_inline proc(t: i8, shift: uint, chroma: bool) -> i8 {return t << shift + (chroma ? 1 : 0)}
	return {
		i32(deblock_alpha_table[a + 12]) << depth_shift,
		i32(deblock_beta_table[b + 12]) << depth_shift,
		{
			0,
			tc(deblock_tc0_table[a + 12][1], depth_shift, chroma),
			tc(deblock_tc0_table[a + 12][2], depth_shift, chroma),
			tc(deblock_tc0_table[a + 12][3], depth_shift, chroma),
		},
	}
}

@(private)
deblock_previous :: #force_inline proc(v: #simd[16]i32, $Vertical: bool) -> #simd[16]i32 {
	when Vertical {
		return simd.shuffle(v, v, 5, 0, 7, 2, 1, 4, 3, 6, 13, 8, 15, 10, 9, 12, 11, 14)
	} else {
		return simd.shuffle(v, v, 10, 11, 0, 1, 14, 15, 4, 5, 2, 3, 8, 9, 6, 7, 12, 13)
	}
}

@(private)
deblock_expand_groups :: #force_inline proc(v: #simd[4]i32) -> #simd[16]i32 {
	pairs := simd.shuffle(v, v, 0, 0, 1, 1, 2, 2, 3, 3)
	return simd.shuffle(pairs, pairs, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7)
}

@(private)
deblock_internal_orientation :: #force_inline proc(
	out: ^[4][4]u8,
	dir, coded: #simd[16]i32,
	pics: [2]#simd[16]i32,
	mv: [2][2]#simd[16]i32,
	odd_edges: bool,
	$Vertical: bool,
) {
	V :: #simd[16]i32
	p_pics: [2]V = ---
	p_mv: [2][2]V = ---
	#unroll for list in 0 ..< 2 {
		p_pics[list] = deblock_previous(pics[list], Vertical)
		#unroll for component in 0 ..< 2 do p_mv[list][component] = deblock_previous(mv[list][component], Vertical)
	}
	strength := inter_strength_lanes(deblock_previous(dir, Vertical), dir, p_pics, pics, p_mv, mv)
	strength = simd.select(
		simd.lanes_ne(simd.bit_or(deblock_previous(coded, Vertical), coded), V(0)),
		V(2),
		strength,
	)
	B :: #simd[16]u8
	bytes := transmute([16]u8)B(strength)
	for edge in 1 ..< 4 {
		if !odd_edges && edge & 1 != 0 do continue
		#unroll for k in 0 ..< 4 do out[edge][k] = bytes[edge_blocks[Vertical ? 0 : 1][edge][k][1]]
	}
}

// Caller-owned scratch is reused across the picture. Metadata is immutable
// during filtering, so both orientations can be prepared before any pixels.
@(private)
prepare_deblock_mb :: proc(
	out: ^Deblock_MB_Data,
	macroblocks: #soa[]Macroblock,
	chroma_offsets: [2]i32,
	columns, mb_x, mb_y: int,
	format := Deblock_Format{},
) #no_bounds_check {
	out.strengths = {}
	index := mb_y * columns + mb_x
	cur := &macroblocks[index]
	out.transform8 = cur.uses_8x8_transform
	if cur.deblocking_mode == .Disabled do return
	// Odd internal edges of each orientation: all of them without the 8x8
	// transform, and the horizontal ones for 4:2:2 chroma regardless.
	odd_edges := [2]bool{!cur.uses_8x8_transform, !cur.uses_8x8_transform || format.chroma_422}
	uncoded :=
		!cur.is_intra &&
		cur.luma_coded_block_mask == 0 &&
		cur.chroma_residual_mode == .None &&
		cur.has_uniform_motion
	neighbours := [2]int{index - 1, index - columns}
	for orientation in 0 ..< 2 {
		if (orientation == 0 ? mb_x == 0 : mb_y == 0) do continue
		p := &macroblocks[neighbours[orientation]]
		if cur.deblocking_mode == .Within_Slice && p.slice_index != cur.slice_index do continue
		if uncoded && !p.is_intra && p.luma_coded_block_mask == 0 && p.chroma_residual_mode == .None && p.has_uniform_motion && p.prediction_directions[0] == cur.prediction_directions[0] && p.reference_picture_ids == cur.reference_picture_ids && p.motion_vectors[0][0] == cur.motion_vectors[0][0] && p.motion_vectors[1][0] == cur.motion_vectors[1][0] do continue
		out.strengths[orientation][0] = edge_strengths(p, cur, 0, orientation == 0)
	}
	if !uncoded {
		if cur.is_intra {
			for orientation in 0 ..< 2 do for edge in 1 ..< 4 {
				if odd_edges[orientation] || edge & 1 == 0 do out.strengths[orientation][edge] = {3, 3, 3, 3}
			}
		} else {
			V :: #simd[16]i32
			D :: #simd[4]i32
			directions := D(intrinsics.unaligned_load((^#simd[4]u8)(&cur.prediction_directions)))
			dir := deblock_expand_groups(directions)
			counts := intrinsics.unaligned_load((^#simd[16]u8)(&cur.nonzero_coefficient_counts))
			coded := V(counts)
			if cur.uses_8x8_transform {
				groups := D(intrinsics.unaligned_load((^#simd[4]u8)(&cur.has_8x8_coefficients)))
				coded = deblock_expand_groups(groups)
			}
			pics: [2]V = ---
			mv: [2][2]V = ---
			#unroll for list in 0 ..< 2 {
				ids := intrinsics.unaligned_load((^D)(&cur.reference_picture_ids[list]))
				pics[list] = deblock_expand_groups(ids)
				both := intrinsics.unaligned_load((^#simd[32]i16)(&cur.motion_vectors[list]))
				mv[list][0] = V(
					simd.shuffle(
						both,
						both,
						0,
						2,
						4,
						6,
						8,
						10,
						12,
						14,
						16,
						18,
						20,
						22,
						24,
						26,
						28,
						30,
					),
				)
				mv[list][1] = V(
					simd.shuffle(
						both,
						both,
						1,
						3,
						5,
						7,
						9,
						11,
						13,
						15,
						17,
						19,
						21,
						23,
						25,
						27,
						29,
						31,
					),
				)
			}
			deblock_internal_orientation(&out.strengths[0], dir, coded, pics, mv, odd_edges[0], true)
			deblock_internal_orientation(&out.strengths[1], dir, coded, pics, mv, odd_edges[1], false)
		}
	}
	qp_q := cur.type == .I_PCM ? 0 : i32(cur.quantizer)
	alpha_offset, beta_offset := i32(cur.alpha_offset) << 1, i32(cur.beta_offset) << 1
	depth_shift := uint(max(format.bit_depth, 8) - 8)
	qp_bd_offset := 6 * i32(depth_shift)
	for domain in 0 ..< 3 {
		active := false
		if domain == 0 {
			for orientation in 0 ..< 2 do for edge in 1 ..< 4 do active ||= transmute(u32)out.strengths[orientation][edge] != 0
		} else {
			active = transmute(u32)out.strengths[domain - 1][0] != 0
		}
		if !active do continue
		qp_p := qp_q
		if domain != 0 {
			p := &macroblocks[neighbours[domain - 1]]
			qp_p = p.type == .I_PCM ? 0 : i32(p.quantizer)
		}
		out.thresholds[domain][0] = deblock_threshold(
			(qp_p + qp_q + 1) >> 1,
			alpha_offset,
			beta_offset,
			false,
			depth_shift,
		)
		for plane in 0 ..< 2 {
			qpc_p := chroma_qp(qp_p, chroma_offsets[plane], qp_bd_offset)
			qpc_q := chroma_qp(qp_q, chroma_offsets[plane], qp_bd_offset)
			out.thresholds[domain][plane + 1] = deblock_threshold(
				(qpc_p + qpc_q + 1) >> 1,
				alpha_offset,
				beta_offset,
				true,
				depth_shift,
			)
		}
	}
}

// Filter the vertical or horizontal edges of a macroblock: the macroblock edge
// and the internal 4x4 edges (only the 8x8 edge for 8x8 transforms), plus the
// chroma edges that coincide with them: those of the even luma edges, and in
// 4:2:2 every horizontal one (chroma rows match luma rows).
@(private)
filter_deblock_mb_edges :: proc(
	data: ^Deblock_MB_Data,
	buf: ^YUV_Buffer,
	mb_x, mb_y: int,
	vertical: bool,
	$T: typeid,
	bit_depth: int,
) #no_bounds_check {
	// A constant clip for 8-bit samples keeps the filters' clamps immediate.
	when T == u8 {pixel_max :: i16(255)} else {pixel_max := i16(1) << uint(bit_depth) - 1}
	orientation := vertical ? 0 : 1
	active := false
	for edge in 0 ..< 4 do active ||= transmute(u32)data.strengths[orientation][edge] != 0
	if !active do return
	luma_plane, cb, cr := buffer_planes(T, buf)
	mb_pix_y: [^]T = &luma_plane[(mb_y * 16) * buf.y_stride + mb_x * 16]
	chroma_height := buf.chroma_422 ? 16 : 8
	chroma_pix := [2][^]T {
		&cb[(mb_y * chroma_height) * buf.uv_stride + mb_x * 8],
		&cr[(mb_y * chroma_height) * buf.uv_stride + mb_x * 8],
	}

	for edge in 0 ..< 4 {
		// Test the strengths in place: a copy assembled bytewise and reread as
		// a word stalls store forwarding.
		if transmute(u32)data.strengths[orientation][edge] == 0 do continue
		bs := data.strengths[orientation][edge]
		domain := edge == 0 ? orientation + 1 : 0
		luma := &data.thresholds[domain][0]
		if luma.alpha != 0 && luma.beta != 0 && !(data.transform8 && edge & 1 != 0) {
			tc0: [4]i8
			for k in 0 ..< 4 do if bs[k] > 0 && bs[k] < 4 do tc0[k] = luma.tc[bs[k]]
			if vertical {
				deblock_luma_vertical(&mb_pix_y[edge * 4], buf.y_stride, luma.alpha, luma.beta, bs, tc0, pixel_max)
			} else {
				deblock_luma_horizontal(&mb_pix_y[edge * 4 * buf.y_stride], buf.y_stride, luma.alpha, luma.beta, bs, tc0, pixel_max)
			}
		}
		chroma_row_edge := !vertical && buf.chroma_422
		if edge & 1 != 0 && !chroma_row_edge do continue
		for plane in 0 ..< 2 {
			chroma := &data.thresholds[domain][plane + 1]
			if chroma.alpha == 0 || chroma.beta == 0 do continue
			c_tc: [4]i8
			for k in 0 ..< 4 do if bs[k] > 0 && bs[k] < 4 do c_tc[k] = chroma.tc[bs[k]]
			switch {
			case vertical && buf.chroma_422:
				deblock_chroma_vertical_422(&chroma_pix[plane][edge * 2], buf.uv_stride, chroma.alpha, chroma.beta, bs, c_tc, pixel_max)
			case vertical:
				deblock_chroma_vertical(&chroma_pix[plane][edge * 2], buf.uv_stride, chroma.alpha, chroma.beta, bs, c_tc, pixel_max)
			case:
				row := chroma_row_edge ? edge * 4 : edge * 2
				deblock_chroma_horizontal(&chroma_pix[plane][row * buf.uv_stride], buf.uv_stride, chroma.alpha, chroma.beta, bs, c_tc, pixel_max)
			}
		}
	}
}

deblock_mb_edges :: proc(
	macroblocks: #soa[]Macroblock,
	buf: ^YUV_Buffer,
	chroma_offsets: [2]i32,
	macroblock_columns, mb_x, mb_y: int,
	vertical: bool,
) {
	data: Deblock_MB_Data
	prepare_deblock_mb(&data, macroblocks, chroma_offsets, macroblock_columns, mb_x, mb_y)
	filter_deblock_mb_edges(&data, buf, mb_x, mb_y, vertical, u8, 8)
}

// Deblock a picture whose samples have `bit_depth` bits (u16 storage when the
// buffer is high_depth).
deblock_picture :: proc(
	macroblocks: #soa[]Macroblock,
	buf: ^YUV_Buffer,
	macroblock_columns, macroblock_rows: int,
	chroma_offsets: [2]i32,
	bit_depth := 8,
) {
	run :: proc(
		macroblocks: #soa[]Macroblock,
		buf: ^YUV_Buffer,
		macroblock_columns, macroblock_rows: int,
		chroma_offsets: [2]i32,
		bit_depth: int,
		$T: typeid,
	) {
		data: Deblock_MB_Data
		format := Deblock_Format{bit_depth, buf != nil && buf.chroma_422}
		for mb_y in 0 ..< macroblock_rows do for mb_x in 0 ..< macroblock_columns {
			// Disabled pictures/MBs require neither scratch publication nor filters.
			if macroblocks[mb_y * macroblock_columns + mb_x].deblocking_mode == .Disabled do continue
			prepare_deblock_mb(&data, macroblocks, chroma_offsets, macroblock_columns, mb_x, mb_y, format)
			filter_deblock_mb_edges(&data, buf, mb_x, mb_y, true, T, bit_depth)
			filter_deblock_mb_edges(&data, buf, mb_x, mb_y, false, T, bit_depth)
		}
	}
	if buf != nil && buf.high_depth {
		run(macroblocks, buf, macroblock_columns, macroblock_rows, chroma_offsets, bit_depth, u16)
	} else {
		run(macroblocks, buf, macroblock_columns, macroblock_rows, chroma_offsets, bit_depth, u8)
	}
}

// A vertical 4:2:2 chroma edge: 16 rows, four per luma block row, filtered
// as two 8-row halves. Kept out of line, off the 4:2:0 path.
@(private)
deblock_chroma_vertical_422 :: #force_no_inline proc(
	pix: [^]$T,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc: [4]i8,
	pixel_max: i16,
) {
	for half in 0 ..< 2 {
		h_bs := [4]u8{bs[2 * half], bs[2 * half], bs[2 * half + 1], bs[2 * half + 1]}
		h_tc := [4]i8{tc[2 * half], tc[2 * half], tc[2 * half + 1], tc[2 * half + 1]}
		deblock_chroma_vertical(&pix[half * 8 * stride], stride, alpha, beta, h_bs, h_tc, pixel_max)
	}
}

package h264

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

// Luma edge filtering (8.7.2.3, 8.7.2.4) of all lanes at once
filter_luma_edge :: #force_inline proc(e: ^Luma_Edge, alpha, beta: i32, bs: [4]u8, tc0: [4]i8) {
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
	weak_p0 := clamp_lanes(simd.add(p0, delta))
	weak_q0 := clamp_lanes(simd.sub(q0, delta))
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
filter_chroma_edge :: proc(e: ^Chroma_Edge, alpha, beta: i32, bs: [4]u8, tc: [4]i8) {
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
	weak_p0 := clamp_lanes(simd.add(p0, delta))
	weak_q0 := clamp_lanes(simd.sub(q0, delta))
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
	pix: [^]u8,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc0: [4]i8,
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
	filter_luma_edge(&e, alpha, beta, bs, tc0)
	intrinsics.unaligned_store((^#simd[16]u8)(&pix[-3 * stride]), (#simd[16]u8)(e.p2))
	intrinsics.unaligned_store((^#simd[16]u8)(&pix[-2 * stride]), (#simd[16]u8)(e.p1))
	intrinsics.unaligned_store((^#simd[16]u8)(&pix[-stride]), (#simd[16]u8)(e.p0))
	intrinsics.unaligned_store((^#simd[16]u8)(pix), (#simd[16]u8)(e.q0))
	intrinsics.unaligned_store((^#simd[16]u8)(&pix[stride]), (#simd[16]u8)(e.q1))
	intrinsics.unaligned_store((^#simd[16]u8)(&pix[2 * stride]), (#simd[16]u8)(e.q2))
}

// 8x8 transpose of 16-bit lanes
transpose_8x8_i16 :: #force_inline proc(r: [8]#simd[8]i16) -> (t: [8]#simd[8]i16) {
	V :: #simd[8]i16
	a: [8]V
	#unroll for i in 0 ..< 4 {
		a[2 * i] = simd.shuffle(r[2 * i], r[2 * i + 1], 0, 8, 1, 9, 2, 10, 3, 11)
		a[2 * i + 1] = simd.shuffle(r[2 * i], r[2 * i + 1], 4, 12, 5, 13, 6, 14, 7, 15)
	}
	b: [8]V
	#unroll for i in 0 ..< 2 {
		b[4 * i + 0] = simd.shuffle(a[4 * i + 0], a[4 * i + 2], 0, 1, 8, 9, 2, 3, 10, 11)
		b[4 * i + 1] = simd.shuffle(a[4 * i + 0], a[4 * i + 2], 4, 5, 12, 13, 6, 7, 14, 15)
		b[4 * i + 2] = simd.shuffle(a[4 * i + 1], a[4 * i + 3], 0, 1, 8, 9, 2, 3, 10, 11)
		b[4 * i + 3] = simd.shuffle(a[4 * i + 1], a[4 * i + 3], 4, 5, 12, 13, 6, 7, 14, 15)
	}
	#unroll for i in 0 ..< 4 {
		t[2 * i] = simd.shuffle(b[i], b[i + 4], 0, 1, 2, 3, 8, 9, 10, 11)
		t[2 * i + 1] = simd.shuffle(b[i], b[i + 4], 4, 5, 6, 7, 12, 13, 14, 15)
	}
	return
}

// Vertical edge: the 8 samples around the edge of each of the 16 rows are
// transposed into the p3..q3 lane vectors and back after filtering.
deblock_luma_vertical :: proc(
	pix: [^]u8,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc0: [4]i8,
) #no_bounds_check {
	H :: #simd[8]i16
	upper, lower: [8]H
	for i in 0 ..< 8 {
		upper[i] = load_lanes(8, &pix[i * stride - 4])
		lower[i] = load_lanes(8, &pix[(i + 8) * stride - 4])
	}
	cu := transpose_8x8_i16(upper) // cu[k] = column k of rows 0..7
	cl := transpose_8x8_i16(lower)
	e: Luma_Edge
	columns := [8]^#simd[16]i16{&e.p3, &e.p2, &e.p1, &e.p0, &e.q0, &e.q1, &e.q2, &e.q3}
	#unroll for k in 0 ..< 8 do columns[k]^ = simd.shuffle(cu[k], cl[k], 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
	filter_luma_edge(&e, alpha, beta, bs, tc0)
	#unroll for k in 0 ..< 8 {
		cu[k] = simd.swizzle(columns[k]^, 0, 1, 2, 3, 4, 5, 6, 7)
		cl[k] = simd.swizzle(columns[k]^, 8, 9, 10, 11, 12, 13, 14, 15)
	}
	upper = transpose_8x8_i16(cu)
	lower = transpose_8x8_i16(cl)
	for i in 0 ..< 8 {
		intrinsics.unaligned_store((^#simd[8]u8)(&pix[i * stride - 4]), (#simd[8]u8)(upper[i]))
		intrinsics.unaligned_store(
			(^#simd[8]u8)(&pix[(i + 8) * stride - 4]),
			(#simd[8]u8)(lower[i]),
		)
	}
}

deblock_chroma_horizontal :: proc(
	pix: [^]u8,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc: [4]i8,
) #no_bounds_check {
	e := Chroma_Edge {
		load_lanes(8, &pix[-2 * stride]),
		load_lanes(8, &pix[-stride]),
		load_lanes(8, pix),
		load_lanes(8, &pix[stride]),
	}
	filter_chroma_edge(&e, alpha, beta, bs, tc)
	intrinsics.unaligned_store((^#simd[8]u8)(&pix[-stride]), (#simd[8]u8)(e.p0))
	intrinsics.unaligned_store((^#simd[8]u8)(pix), (#simd[8]u8)(e.q0))
}

// Vertical chroma edge: 8 rows of the 4 samples around the edge, transposed into the p1..q1 lanes
deblock_chroma_vertical :: proc(
	pix: [^]u8,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc: [4]i8,
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
	filter_chroma_edge(&e, alpha, beta, bs, tc)
	for i in 0 ..< 8 {
		row: [^]u8 = &pix[i * stride]
		row[-1] = u8(simd.extract(e.p0, i))
		row[0] = u8(simd.extract(e.q0, i))
	}
}

// Chroma edges use thresholds from the chroma QPs of both sides and tC0 + 1 (8.7.2.2).
chroma_edge_params :: proc(
	qp_p, qp_q, chroma_offset, alpha_offset, beta_offset: i32,
	bs: [4]u8,
) -> (
	alpha, beta: i32,
	tc: [4]i8,
) {
	qpc_p := i32(chroma_qp_table[clamp(qp_p + chroma_offset, 0, 51)])
	qpc_q := i32(chroma_qp_table[clamp(qp_q + chroma_offset, 0, 51)])
	qp_avg := (qpc_p + qpc_q + 1) >> 1
	idx_a := clamp(qp_avg + alpha_offset, 0, 51)
	idx_b := clamp(qp_avg + beta_offset, 0, 51)
	alpha = i32(deblock_alpha_table[idx_a + 12])
	beta = i32(deblock_beta_table[idx_b + 12])
	for k in 0 ..< 4 {
		if bs[k] > 0 && bs[k] < 4 do tc[k] = deblock_tc0_table[idx_a + 12][bs[k]] + 1
	}
	return
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
}

@(private)
deblock_threshold :: #force_inline proc(
	qp, alpha_offset, beta_offset: i32,
	chroma: bool,
) -> Deblock_Threshold {
	a, b := clamp(qp + alpha_offset, 0, 51), clamp(qp + beta_offset, 0, 51)
	return {
		i32(deblock_alpha_table[a + 12]),
		i32(deblock_beta_table[b + 12]),
		{
			0,
			deblock_tc0_table[a + 12][1] + (chroma ? 1 : 0),
			deblock_tc0_table[a + 12][2] + (chroma ? 1 : 0),
			deblock_tc0_table[a + 12][3] + (chroma ? 1 : 0),
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
	transform8: bool,
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
		if transform8 && edge & 1 != 0 do continue
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
) #no_bounds_check {
	out.strengths = {}
	index := mb_y * columns + mb_x
	cur := &macroblocks[index]
	if cur.deblocking_mode == .Disabled do return
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
				if !cur.uses_8x8_transform || edge & 1 == 0 do out.strengths[orientation][edge] = {3, 3, 3, 3}
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
			deblock_internal_orientation(
				&out.strengths[0],
				dir,
				coded,
				pics,
				mv,
				cur.uses_8x8_transform,
				true,
			)
			deblock_internal_orientation(
				&out.strengths[1],
				dir,
				coded,
				pics,
				mv,
				cur.uses_8x8_transform,
				false,
			)
		}
	}
	qp_q := cur.type == .I_PCM ? 0 : i32(cur.quantizer)
	alpha_offset, beta_offset := i32(cur.alpha_offset) << 1, i32(cur.beta_offset) << 1
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
		)
		for plane in 0 ..< 2 {
			qpc_p := i32(chroma_qp_table[clamp(qp_p + chroma_offsets[plane], 0, 51)])
			qpc_q := i32(chroma_qp_table[clamp(qp_q + chroma_offsets[plane], 0, 51)])
			out.thresholds[domain][plane + 1] = deblock_threshold(
				(qpc_p + qpc_q + 1) >> 1,
				alpha_offset,
				beta_offset,
				true,
			)
		}
	}
}

// Filter the vertical or horizontal edges of a macroblock: the macroblock edge
// and the internal 4x4 edges (only the 8x8 edge for 8x8 transforms), plus the
// two chroma edges that coincide with them.
@(private)
filter_deblock_mb_edges :: proc(
	data: ^Deblock_MB_Data,
	buf: ^YUV_Buffer,
	mb_x, mb_y: int,
	vertical: bool,
) #no_bounds_check {
	orientation := vertical ? 0 : 1
	active := false
	for edge in 0 ..< 4 do active ||= transmute(u32)data.strengths[orientation][edge] != 0
	if !active do return
	mb_pix_y: [^]u8 = &buf.y[(mb_y * 16) * buf.y_stride + mb_x * 16]
	chroma_pix := [2]([^]u8) {
		&buf.u[(mb_y * 8) * buf.uv_stride + mb_x * 8],
		&buf.v[(mb_y * 8) * buf.uv_stride + mb_x * 8],
	}

	for edge in 0 ..< 4 {
		bs := data.strengths[orientation][edge]
		if transmute(u32)bs == 0 do continue
		domain := edge == 0 ? orientation + 1 : 0
		luma := &data.thresholds[domain][0]
		if luma.alpha != 0 && luma.beta != 0 {
			tc0: [4]i8
			for k in 0 ..< 4 do if bs[k] > 0 && bs[k] < 4 do tc0[k] = luma.tc[bs[k]]
			if vertical {
				deblock_luma_vertical(
					&mb_pix_y[edge * 4],
					buf.y_stride,
					luma.alpha,
					luma.beta,
					bs,
					tc0,
				)
			} else {
				deblock_luma_horizontal(
					&mb_pix_y[edge * 4 * buf.y_stride],
					buf.y_stride,
					luma.alpha,
					luma.beta,
					bs,
					tc0,
				)
			}
		}
		if edge & 1 == 0 {
			for plane in 0 ..< 2 {
				chroma := &data.thresholds[domain][plane + 1]
				if chroma.alpha == 0 || chroma.beta == 0 do continue
				c_tc: [4]i8
				for k in 0 ..< 4 do if bs[k] > 0 && bs[k] < 4 do c_tc[k] = chroma.tc[bs[k]]
				if vertical {
					deblock_chroma_vertical(
						&chroma_pix[plane][edge * 2],
						buf.uv_stride,
						chroma.alpha,
						chroma.beta,
						bs,
						c_tc,
					)
				} else {
					deblock_chroma_horizontal(
						&chroma_pix[plane][edge * 2 * buf.uv_stride],
						buf.uv_stride,
						chroma.alpha,
						chroma.beta,
						bs,
						c_tc,
					)
				}
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
	filter_deblock_mb_edges(&data, buf, mb_x, mb_y, vertical)
}

deblock_picture :: proc(
	macroblocks: #soa[]Macroblock,
	buf: ^YUV_Buffer,
	macroblock_columns, macroblock_rows: int,
	chroma_offsets: [2]i32,
) {
	data: Deblock_MB_Data
	for mb_y in 0 ..< macroblock_rows do for mb_x in 0 ..< macroblock_columns {
		// Disabled pictures/MBs require neither scratch publication nor filters.
		if macroblocks[mb_y * macroblock_columns + mb_x].deblocking_mode == .Disabled do continue
		prepare_deblock_mb(&data, macroblocks, chroma_offsets, macroblock_columns, mb_x, mb_y)
		filter_deblock_mb_edges(&data, buf, mb_x, mb_y, true)
		filter_deblock_mb_edges(&data, buf, mb_x, mb_y, false)
	}
}

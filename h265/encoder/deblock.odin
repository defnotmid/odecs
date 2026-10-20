package h265_encoder

// ---------------------------------------------------------------------------
// In-loop deblocking filter (H.265 8.7.2), bit-exact with the reference
// decoder. It runs after the whole picture is reconstructed so that intra
// prediction saw unfiltered neighbours, exactly like decoding. Each coding
// tree row owns disjoint edge groups in each orientation. All vertical
// filtering finishes before the horizontal groups run. This preserves the
// former CTU raster walk: its horizontal groups already waited for every
// vertical edge in their sample support, including the next CTU's left edge.
// ---------------------------------------------------------------------------

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

@(private)
deblock_clip :: #force_inline proc(v, lo, hi: i32) -> i32 {
	return v < lo ? lo : (v > hi ? hi : v)
}

// Multi-pointers do not support negative arithmetic, so walk with an
// explicit address offset and index the returned pointer forwards only. The
// offset counts samples, so it is scaled to bytes for the pointer.
@(private)
deblock_at :: #force_inline proc(p: [^]Sample, offset: int) -> [^]Sample {
	return ([^]Sample)(uintptr(p) + uintptr(offset) * size_of(Sample))
}

// Boundary strength (8.7.2.1) at the 4x4 cell (x, y) on the q side of an
// edge. Returns 0 when the cells belong to the same coding unit, since a
// single transform block spans each CU.
@(private)
deblock_strength :: proc(enc: ^Encoder, x, y: int, vertical: bool) -> u8 {
	q := cu_at(enc.cu, x, y)

	if enc.config.amp {
		// With partitions the CU carries the decoder's per-4x4 transform and
		// prediction edge marks, so boundary strength is their union exactly
		// as in the decoder's boundary_strength.
		tu := vertical ? q.tu_v : q.tu_h
		pu := vertical ? q.pu_v : q.pu_h
		if !tu && !pu do return 0

		p := vertical ? cu_at(enc.cu, x - 1, y) : cu_at(enc.cu, x, y - 1)
		if p.type == .Intra || q.type == .Intra {
			return 2
		}
		if tu && (p.cbf_y || q.cbf_y) {
			return 1
		}
		if p.type == .Inter && q.type == .Inter {
			if different_motion_enc(enc, p, q) do return 1
		}
		return 0
	}

	if enc.config.rqt || enc.config.intra_rqt {
		// 8.7.2.4: only transform (or prediction) block edges are filtered. The
		// tree records its leaf edges per 4x4 cell; the CU boundary is recorded
		// for every coding unit, so prediction block edges are covered too.
		tu := vertical ? q.tu_v : q.tu_h
		if !tu do return 0
		p := vertical ? cu_at(enc.cu, x - 1, y) : cu_at(enc.cu, x, y - 1)
		if p.type == .Intra || q.type == .Intra do return 2
		if p.cbf_y || q.cbf_y do return 1
		if p.type == .Inter && q.type == .Inter {
			if different_motion_enc(enc, p, q) do return 1
		}
		return 0
	}

	size := CTU_WIDTH >> q.depth
	if vertical {
		if x & (size - 1) != 0 do return 0
	} else {
		if y & (size - 1) != 0 do return 0
	}

	p := vertical ? cu_at(enc.cu, x - 1, y) : cu_at(enc.cu, x, y - 1)
	if p.type == .Intra || q.type == .Intra do return 2
	if p.cbf_y || q.cbf_y do return 1
	if p.type == .Inter && q.type == .Inter {
		if different_motion_enc(enc, p, q) do return 1
	}
	return 0
}

// mv_far_enc is the motion-vector distance test of 8.7.2.4.
@(private)
mv_far_enc :: #force_inline proc(a, b: [2]i16) -> bool {
	return abs(i32(a[0]) - i32(b[0])) >= 4 || abs(i32(a[1]) - i32(b[1])) >= 4
}

// different_motion_enc is the decoder's different_motion (8.7.2.4), comparing
// the per-list reference POCs and vectors recorded for p and q.
different_motion_enc :: proc(enc: ^Encoder, p, q: ^Cu_Info) -> bool {
	pp, qp: [2]i32
	pv, qv: [2][2]i16
	np, nq: int

	for l in 0 ..< 2 {
		if p.pred[l] {
			pp[np], pv[np] = enc.ref_poc[l][p.ref_idx[l]], p.mv[l]
			np += 1
		}
		if q.pred[l] {
			qp[nq], qv[nq] = enc.ref_poc[l][q.ref_idx[l]], q.mv[l]
			nq += 1
		}
	}

	if np != nq do return true
	if np == 1 do return pp[0] != qp[0] || mv_far_enc(pv[0], qv[0])
	if np == 0 do return false

	if pp[0] == qp[0] && pp[1] == qp[1] {
		if pp[0] == pp[1] {
			return(
				(mv_far_enc(pv[0], qv[0]) || mv_far_enc(pv[1], qv[1])) &&
				(mv_far_enc(pv[0], qv[1]) || mv_far_enc(pv[1], qv[0])) \
			)
		}
		return mv_far_enc(pv[0], qv[0]) || mv_far_enc(pv[1], qv[1])
	}

	if pp[0] == qp[1] && pp[1] == qp[0] {
		return mv_far_enc(pv[0], qv[1]) || mv_far_enc(pv[1], qv[0])
	}

	return true
}

@(private)
deblock_tc_for :: proc(qp: i32, bs: u8) -> i32 {
	if bs == 0 do return 0
	table := DEBLOCK_TC[:]
	return table[clamp(qp + 2 * (i32(bs) - 1), 0, 53)]
}

@(private)
deblock_chroma_tc_for :: proc(qp_y: i32, layout: Chroma_Layout) -> i32 {
	table := DEBLOCK_TC[:]
	return table[clamp(chroma_qp(qp_y, int(layout_idc(layout))) + 2, 0, 53)]
}

// Strong luma filter (8.7.2.5.4) over the four lines of one group. `base`
// points at p3 of the first line.
@(private)
deblock_luma_strong :: proc(base: [^]Sample, xstride, ystride: int, tc, max_v: i32) {
	tc2 := tc * 2
	for d in 0 ..< 4 {
		line := deblock_at(base, d * ystride)
		p3 := i32(line[0])
		p2 := i32(line[xstride])
		p1 := i32(line[2 * xstride])
		p0 := i32(line[3 * xstride])
		q0 := i32(line[4 * xstride])
		q1 := i32(line[5 * xstride])
		q2 := i32(line[6 * xstride])
		q3 := i32(line[7 * xstride])

		line[3 * xstride] = Sample(
			deblock_clip(
				p0 + deblock_clip(((p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3) - p0, -tc2, tc2),
				0,
				max_v,
			),
		)
		line[2 * xstride] = Sample(
			deblock_clip(
				p1 + deblock_clip(((p2 + p1 + p0 + q0 + 2) >> 2) - p1, -tc2, tc2),
				0,
				max_v,
			),
		)
		line[xstride] = Sample(
			deblock_clip(
				p2 + deblock_clip(((2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3) - p2, -tc2, tc2),
				0,
				max_v,
			),
		)
		line[4 * xstride] = Sample(
			deblock_clip(
				q0 + deblock_clip(((p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3) - q0, -tc2, tc2),
				0,
				max_v,
			),
		)
		line[5 * xstride] = Sample(
			deblock_clip(
				q1 + deblock_clip(((p0 + q0 + q1 + q2 + 2) >> 2) - q1, -tc2, tc2),
				0,
				max_v,
			),
		)
		line[6 * xstride] = Sample(
			deblock_clip(
				q2 + deblock_clip(((2 * q3 + 3 * q2 + q1 + q0 + p0 + 4) >> 3) - q2, -tc2, tc2),
				0,
				max_v,
			),
		)
	}
}

// Weak luma filter (8.7.2.5.5). `dp`/`dq` are the sums used for the second
// line decisions. `base` points at p3 of the first of four lines.
@(private)
deblock_luma_weak :: proc(base: [^]Sample, xstride, ystride: int, tc, beta, dp, dq, max_v: i32) {
	tc2 := tc >> 1
	side := (beta + (beta >> 1)) >> 3
	nd_p := dp < side
	nd_q := dq < side

	for d in 0 ..< 4 {
		line := deblock_at(base, d * ystride + xstride)
		p2 := i32(line[0])
		p1 := i32(line[xstride])
		p0 := i32(line[2 * xstride])
		q0 := i32(line[3 * xstride])
		q1 := i32(line[4 * xstride])
		q2 := i32(line[5 * xstride])

		delta := (9 * (q0 - p0) - 3 * (q1 - p1) + 8) >> 4
		if abs(delta) >= 10 * tc do continue
		delta = deblock_clip(delta, -tc, tc)
		line[2 * xstride] = Sample(deblock_clip(p0 + delta, 0, max_v))
		line[3 * xstride] = Sample(deblock_clip(q0 - delta, 0, max_v))
		if nd_p {
			delta1 := deblock_clip(((((p2 + p0 + 1) >> 1) - p1 + delta) >> 1), -tc2, tc2)
			line[xstride] = Sample(deblock_clip(p1 + delta1, 0, max_v))
		}
		if nd_q {
			delta2 := deblock_clip(((((q2 + q0 + 1) >> 1) - q1 - delta) >> 1), -tc2, tc2)
			line[4 * xstride] = Sample(deblock_clip(q1 + delta2, 0, max_v))
		}
	}
}

// Luma edge filtering (8.7.2.5.3) over two 4-line groups.
@(private)
deblock_edge_luma :: proc(
	plane: Plane(Sample),
	x, y: int,
	vertical: bool,
	bs0, bs1: u8,
	qp: i32,
	bit_depth: int,
) {
	beta_table := DEBLOCK_BETA[:]
	scale := i32(1) << uint(bit_depth - 8)
	beta := beta_table[clamp(qp, 0, 51)] * scale
	tc := [2]i32{deblock_tc_for(qp, bs0) * scale, deblock_tc_for(qp, bs1) * scale}
	max_v := i32(1) << uint(bit_depth) - 1
	xstride := 1
	ystride := plane.stride
	if !vertical {
		xstride, ystride = plane.stride, 1
	}
	origin := plane.offset + y * plane.stride + x
	data := raw_data(plane.data)

	for j in 0 ..< 2 {
		if tc[j] == 0 do continue

		l0 := deblock_at(data, origin + j * 4 * ystride - 4 * xstride)
		l3 := deblock_at(data, origin + j * 4 * ystride - 4 * xstride + 3 * ystride)

		p2 := i32(l0[xstride])
		p1 := i32(l0[2 * xstride])
		p0 := i32(l0[3 * xstride])
		q0 := i32(l0[4 * xstride])
		q1 := i32(l0[5 * xstride])
		q2 := i32(l0[6 * xstride])
		tp2 := i32(l3[xstride])
		tp1 := i32(l3[2 * xstride])
		tp0 := i32(l3[3 * xstride])
		tq0 := i32(l3[4 * xstride])
		tq1 := i32(l3[5 * xstride])
		tq2 := i32(l3[6 * xstride])

		dp0 := abs(p2 - 2 * p1 + p0)
		dq0 := abs(q2 - 2 * q1 + q0)
		dp3 := abs(tp2 - 2 * tp1 + tp0)
		dq3 := abs(tq2 - 2 * tq1 + tq0)
		d0 := dp0 + dq0
		d3 := dp3 + dq3
		if d0 + d3 >= beta do continue

		p3 := i32(l0[0])
		q3 := i32(l0[7 * xstride])
		tp3 := i32(l3[0])
		tq3 := i32(l3[7 * xstride])
		beta3 := beta >> 3
		beta2 := beta >> 2
		tc25 := (tc[j] * 5 + 1) >> 1

		strong :=
			abs(p3 - p0) + abs(q3 - q0) < beta3 &&
			abs(p0 - q0) < tc25 &&
			abs(tp3 - tp0) + abs(tq3 - tq0) < beta3 &&
			abs(tp0 - tq0) < tc25 &&
			(d0 << 1) < beta2 &&
			(d3 << 1) < beta2

		if strong {
			deblock_luma_strong(l0, xstride, ystride, tc[j], max_v)
		} else {
			deblock_luma_weak(l0, xstride, ystride, tc[j], beta, dp0 + dp3, dq0 + dq3, max_v)
		}}
}

// Weak chroma filter (8.7.2.5.6). `pix` is at q0 and two groups of four lines
// are filtered with tc0 and tc1.
@(private)
deblock_edge_chroma :: proc(
	plane: Plane(Sample),
	x, y: int,
	vertical: bool,
	tc0, tc1: i32,
	max_v: i32,
) {
	if tc0 == 0 && tc1 == 0 do return
	xstride := 1
	ystride := plane.stride
	if !vertical {
		xstride, ystride = plane.stride, 1
	}
	origin := plane.offset + y * plane.stride + x
	data := raw_data(plane.data)

	for j in 0 ..< 2 {
		tc := j == 0 ? tc0 : tc1
		if tc == 0 do continue
		group := deblock_at(data, origin + j * 4 * ystride)
		for d in 0 ..< 4 {
			line := deblock_at(group, d * ystride - 2 * xstride)
			p1 := i32(line[0])
			p0 := i32(line[xstride])
			q0 := i32(line[2 * xstride])
			q1 := i32(line[3 * xstride])
			delta := deblock_clip((((q0 - p0) * 4) + p1 - q1 + 4) >> 3, -tc, tc)
			line[xstride] = Sample(deblock_clip(p0 + delta, 0, max_v))
			line[2 * xstride] = Sample(deblock_clip(q0 - delta, 0, max_v))
		}
	}
}

@(private)
deblock_luma_rows :: proc(enc: ^Encoder, plane: Plane(Sample), y0, y_end: int, $vertical: bool) {
	for y := y0; y < y_end; y += 8 {
		when !vertical {
			if y == 0 do continue
		}
		x_start := vertical ? 8 : 0
		for x := x_start; x < enc.coded_width; x += 8 {
			bs0 := deblock_strength(enc, x, y, vertical)
			bs1 :=
				vertical ? deblock_strength(enc, x, y + 4, true) : deblock_strength(enc, x + 4, y, false)
			if bs0 != 0 || bs1 != 0 do deblock_edge_luma(plane, x, y, vertical, bs0, bs1, enc.qp, enc.bit_depth)
		}
	}
}

@(private)
deblock_chroma_rows :: proc(enc: ^Encoder, plane: Plane(Sample), y0, y_end: int, $vertical: bool) {
	tc :=
		deblock_chroma_tc_for(enc.qp, enc.config.chroma_format) *
		(i32(1) << uint(enc.bit_depth - 8))
	max_v := i32(1) << uint(enc.bit_depth) - 1
	sub_w, sub_h := chroma_sub(enc.config.chroma_format)
	// 8.7.2: one four-sample luma segment spans 4/subHeightC chroma rows on
	// a vertical edge (4/subWidthC columns on a horizontal one). A 4:2:0
	// call covers two 8-luma windows (4 chroma rows each); a 4:2:2 call
	// covers one window of 8 chroma rows in its two four-row segments. The
	// framing reduces to the historical 4:2:0 walk at sub_h = 2.
	seg := 4 * sub_h
	for y := y0; y < y_end; y += 2 * seg {
		when !vertical {
			if y == 0 do continue
		}
		x_start := vertical ? 8 * sub_w : 0
		for x := x_start; x < enc.coded_width; x += 8 * sub_w {
			bs0 := deblock_strength(enc, x, y, vertical)
			bs1: u8
			when vertical {
				if y + seg < enc.coded_height do bs1 = deblock_strength(enc, x, y + seg, true)
			} else {
				if x + 4 * sub_w < enc.coded_width do bs1 = deblock_strength(enc, x + 4 * sub_w, y, false)
			}
			if bs0 == 2 || bs1 == 2 {
				deblock_edge_chroma(
					plane,
					x / sub_w,
					y / sub_h,
					vertical,
					bs0 == 2 ? tc : 0,
					bs1 == 2 ? tc : 0,
					max_v,
				)
			}
		}
	}
}

// Apply the in-loop filter to the reconstructed picture.
deblock_frame :: proc(enc: ^Encoder) {
	deblock_frame_on(enc, &enc.rec)
}

@(private)
Deblock_Rows :: struct {
	enc:   ^Encoder,
	frame: ^Frame,
}

// Same-orientation luma groups read eight samples normal to an edge and
// write at most the inner six; adjacent edges are eight samples apart.
// Chroma groups read four normal samples and write the inner two. Their
// eight-sample tangential groups are also disjoint. Consequently edge-owned
// CTU rows may run independently, including horizontal writes above y0.
@(private)
deblock_rows :: proc(rows: ^Deblock_Rows, first, end: int, $vertical: bool) {
	enc := rows.enc
	frame := rows.frame
	for cty in first ..< end {
		y0 := cty * CTU_WIDTH
		y_end := min(y0 + CTU_WIDTH, enc.coded_height)
		deblock_luma_rows(enc, frame.y, y0, y_end, vertical)
		if has_chroma(enc) {
			deblock_chroma_rows(enc, frame.u, y0, y_end, vertical)
			deblock_chroma_rows(enc, frame.v, y0, y_end, vertical)
		}
	}
}

@(private)
deblock_vertical_range :: proc(data: rawptr, first, end: int) {
	deblock_rows(cast(^Deblock_Rows)data, first, end, true)
}

@(private)
deblock_horizontal_range :: proc(data: rawptr, first, end: int) {
	deblock_rows(cast(^Deblock_Rows)data, first, end, false)
}

// Apply the in-loop deblocking filter to an arbitrary frame, including the
// pre-SAO snapshot. The immutable CU grid is shared. A synchronous pool map
// joins each orientation before the next one reads its filtered samples;
// the request lives on the caller's stack and no callback allocates.
deblock_frame_on :: proc(enc: ^Encoder, frame: ^Frame) {
	rows := Deblock_Rows {
		enc   = enc,
		frame = frame,
	}
	pool := enc.config.pool
	if pool == nil {
		deblock_rows(&rows, 0, enc.ctu_rows, true)
		deblock_rows(&rows, 0, enc.ctu_rows, false)
		return
	}
	pool.run(pool, enc.ctu_rows, deblock_vertical_range, &rows)
	pool.run(pool, enc.ctu_rows, deblock_horizontal_range, &rows)
}

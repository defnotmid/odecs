package webp

// VP8 reconstruction (RFC 6386 12, 14) and the loop filter (15).
//
// Each macroblock is predicted and reconstructed in a small workspace whose
// borders hold the pixels it predicts from: the unfiltered row above and
// column to the left (the frame is filtered only once it is complete), or
// the edge values 127 above the picture and 129 left of it.

@(private)
BPS :: 32 // workspace stride
@(private)
Y_OFF :: BPS + 8 // luma at row 1, column 8: its left border at 7, top at row 0
@(private)
U_OFF :: 18 * BPS + 8 // chroma below, its top border at row 17
@(private)
V_OFF :: 18 * BPS + 24
@(private)
WORKSPACE :: 26 * BPS

@(private)
reconstruct :: proc(d: ^Vp8, mb: ^Macroblock, mb_x, mb_y: int) {
	ws: [WORKSPACE]u8
	fill_borders(d, &ws, mb_x, mb_y)
	if mb.is_4x4 {
		for n in 0 ..< 16 {
			at := Y_OFF + (n & 3) * 4 + (n >> 2) * 4 * BPS
			predict4(&ws, at, int(mb.modes[n]))
			add_residual(&ws, at, mb.coeffs[n * 16:][:16], mb.kind[n])
		}
	} else {
		predict(&ws, Y_OFF, 16, edge_mode(mb.ymode, mb_x, mb_y))
		for n in 0 ..< 16 do add_residual(&ws, Y_OFF + (n & 3) * 4 + (n >> 2) * 4 * BPS, mb.coeffs[n * 16:][:16], mb.kind[n])
	}
	mode := edge_mode(mb.uvmode, mb_x, mb_y)
	for c in 0 ..< 2 {
		off := c == 0 ? U_OFF : V_OFF
		predict(&ws, off, 8, mode)
		for n in 0 ..< 4 {
			b := 16 + 4 * c + n
			add_residual(&ws, off + (n & 1) * 4 + (n >> 1) * 4 * BPS, mb.coeffs[b * 16:][:16], mb.kind[b])
		}
	}
	// Into the frame.
	y := d.y[mb_y * 16 * d.y_stride + mb_x * 16:]
	for j in 0 ..< 16 do copy(y[j * d.y_stride:][:16], ws[Y_OFF + j * BPS:][:16])
	uv_at := mb_y * 8 * d.uv_stride + mb_x * 8
	for j in 0 ..< 8 {
		copy(d.u[uv_at + j * d.uv_stride:][:8], ws[U_OFF + j * BPS:][:8])
		copy(d.v[uv_at + j * d.uv_stride:][:8], ws[V_OFF + j * BPS:][:8])
	}
}

// DC prediction without the missing edges.
@(private)
edge_mode :: proc(mode, mb_x, mb_y: int) -> int {
	if mode != DC_PRED do return mode
	if mb_x == 0 do return mb_y == 0 ? DC_NO_TOP_LEFT : DC_NO_LEFT
	return mb_y == 0 ? DC_NO_TOP : DC_PRED
}

@(private)
fill_borders :: proc(d: ^Vp8, ws: ^[WORKSPACE]u8, mb_x, mb_y: int) {
	x0, y0 := mb_x * 16, mb_y * 16
	top := Y_OFF - BPS
	if mb_y == 0 {
		for i in -1 ..< 20 do ws[top + i] = 127
	} else {
		above := d.y[(y0 - 1) * d.y_stride:]
		ws[top - 1] = mb_x == 0 ? 129 : above[x0 - 1]
		copy(ws[top:][:16], above[x0:][:16])
		if mb_x == d.mb_w - 1 {
			for i in 16 ..< 20 do ws[top + i] = above[x0 + 15]
		} else {
			copy(ws[top + 16:][:4], above[x0 + 16:][:4])
		}
	}
	// The right column's subblocks below the top row see the macroblock's
	// top-right pixels as their own (RFC 6386 12.3).
	for r in ([3]int{3, 7, 11}) do copy(ws[Y_OFF + r * BPS + 16:][:4], ws[top + 16:][:4])
	for j in 0 ..< 16 do ws[Y_OFF + j * BPS - 1] = mb_x == 0 ? 129 : d.y[(y0 + j) * d.y_stride + x0 - 1]
	cx0, cy0 := mb_x * 8, mb_y * 8
	for c in 0 ..< 2 {
		off := c == 0 ? U_OFF : V_OFF
		plane := c == 0 ? d.u : d.v
		if mb_y == 0 {
			for i in -1 ..< 8 do ws[off - BPS + i] = 127
		} else {
			above := plane[(cy0 - 1) * d.uv_stride:]
			ws[off - BPS - 1] = mb_x == 0 ? 129 : above[cx0 - 1]
			copy(ws[off - BPS:][:8], above[cx0:][:8])
		}
		for j in 0 ..< 8 do ws[off + j * BPS - 1] = mb_x == 0 ? 129 : plane[(cy0 + j) * d.uv_stride + cx0 - 1]
	}
}

// Whole-block prediction of a size x size block (16 luma, 8 chroma).
@(private)
predict :: proc(ws: ^[WORKSPACE]u8, at, size, mode: int) #no_bounds_check {
	shift := uint(size == 16 ? 4 : 3)
	fill :: proc(ws: ^[WORKSPACE]u8, at, size: int, v: u8) {
		for y in 0 ..< size do for x in 0 ..< size do ws[at + y * BPS + x] = v
	}
	switch mode {
	case DC_PRED:
		dc := size
		for i in 0 ..< size do dc += int(ws[at - BPS + i]) + int(ws[at + i * BPS - 1])
		fill(ws, at, size, u8(dc >> (shift + 1)))
	case DC_NO_TOP:
		dc := size >> 1
		for i in 0 ..< size do dc += int(ws[at + i * BPS - 1])
		fill(ws, at, size, u8(dc >> shift))
	case DC_NO_LEFT:
		dc := size >> 1
		for i in 0 ..< size do dc += int(ws[at - BPS + i])
		fill(ws, at, size, u8(dc >> shift))
	case DC_NO_TOP_LEFT:
		fill(ws, at, size, 128)
	case V_PRED:
		for y in 0 ..< size do copy(ws[at + y * BPS:][:size], ws[at - BPS:][:size])
	case H_PRED:
		for y in 0 ..< size do for x in 0 ..< size do ws[at + y * BPS + x] = ws[at + y * BPS - 1]
	case TM_PRED:
		true_motion(ws, at, size)
	}
}

@(private)
true_motion :: proc(ws: ^[WORKSPACE]u8, at, size: int) {
	corner := int(ws[at - BPS - 1])
	for y in 0 ..< size {
		left := int(ws[at + y * BPS - 1]) - corner
		for x in 0 ..< size do ws[at + y * BPS + x] = u8(clamp(left + int(ws[at - BPS + x]), 0, 255))
	}
}

// 4x4 subblock prediction (RFC 6386 12.3): from the 4 pixels to the left
// (I..L), the corner (X) and the 8 above and above-right (A..H).
@(private)
predict4 :: proc(ws: ^[WORKSPACE]u8, at, mode: int) #no_bounds_check {
	avg3 :: #force_inline proc(a, b, c: int) -> u8 {return u8((a + 2 * b + c + 2) >> 2)}
	avg2 :: #force_inline proc(a, b: int) -> u8 {return u8((a + b + 1) >> 1)}
	top := ws[at - BPS:][:8]
	A, B, C, D := int(top[0]), int(top[1]), int(top[2]), int(top[3])
	E, F, G, H := int(top[4]), int(top[5]), int(top[6]), int(top[7])
	X := int(ws[at - BPS - 1])
	I, J, K, L := int(ws[at - 1]), int(ws[at + BPS - 1]), int(ws[at + 2 * BPS - 1]), int(ws[at + 3 * BPS - 1])
	p: [4][4]u8 // [y][x]
	switch mode {
	case B_DC:
		dc := (A + B + C + D + I + J + K + L + 4) >> 3
		for &row in p do row = u8(dc)
	case B_TM:
		for y in 0 ..< 4 {
			left := int(ws[at + y * BPS - 1]) - X
			for x in 0 ..< 4 do p[y][x] = u8(clamp(left + int(top[x]), 0, 255))
		}
	case B_VE:
		row := [4]u8{avg3(X, A, B), avg3(A, B, C), avg3(B, C, D), avg3(C, D, E)}
		for &r in p do r = row
	case B_HE:
		p[0] = avg3(X, I, J)
		p[1] = avg3(I, J, K)
		p[2] = avg3(J, K, L)
		p[3] = avg3(K, L, L)
	case B_RD:
		p[3][0] = avg3(J, K, L)
		p[3][1], p[2][0] = avg3(I, J, K), avg3(I, J, K)
		p[3][2], p[2][1], p[1][0] = avg3(X, I, J), avg3(X, I, J), avg3(X, I, J)
		v := avg3(A, X, I)
		p[3][3], p[2][2], p[1][1], p[0][0] = v, v, v, v
		v = avg3(B, A, X)
		p[2][3], p[1][2], p[0][1] = v, v, v
		p[1][3], p[0][2] = avg3(C, B, A), avg3(C, B, A)
		p[0][3] = avg3(D, C, B)
	case B_LD:
		p[0][0] = avg3(A, B, C)
		p[0][1], p[1][0] = avg3(B, C, D), avg3(B, C, D)
		v := avg3(C, D, E)
		p[0][2], p[1][1], p[2][0] = v, v, v
		v = avg3(D, E, F)
		p[0][3], p[1][2], p[2][1], p[3][0] = v, v, v, v
		v = avg3(E, F, G)
		p[1][3], p[2][2], p[3][1] = v, v, v
		p[2][3], p[3][2] = avg3(F, G, H), avg3(F, G, H)
		p[3][3] = avg3(G, H, H)
	case B_VR:
		p[0][0], p[2][1] = avg2(X, A), avg2(X, A)
		p[0][1], p[2][2] = avg2(A, B), avg2(A, B)
		p[0][2], p[2][3] = avg2(B, C), avg2(B, C)
		p[0][3] = avg2(C, D)
		p[3][0] = avg3(K, J, I)
		p[2][0] = avg3(J, I, X)
		p[1][0], p[3][1] = avg3(I, X, A), avg3(I, X, A)
		p[1][1], p[3][2] = avg3(X, A, B), avg3(X, A, B)
		p[1][2], p[3][3] = avg3(A, B, C), avg3(A, B, C)
		p[1][3] = avg3(B, C, D)
	case B_VL:
		p[0][0] = avg2(A, B)
		p[0][1], p[2][0] = avg2(B, C), avg2(B, C)
		p[0][2], p[2][1] = avg2(C, D), avg2(C, D)
		p[0][3], p[2][2] = avg2(D, E), avg2(D, E)
		p[1][0] = avg3(A, B, C)
		p[1][1], p[3][0] = avg3(B, C, D), avg3(B, C, D)
		p[1][2], p[3][1] = avg3(C, D, E), avg3(C, D, E)
		p[1][3], p[3][2] = avg3(D, E, F), avg3(D, E, F)
		p[2][3] = avg3(E, F, G) // these two break the pattern (RFC 6386 12.3)
		p[3][3] = avg3(F, G, H)
	case B_HD:
		p[0][0], p[1][2] = avg2(I, X), avg2(I, X)
		p[1][0], p[2][2] = avg2(J, I), avg2(J, I)
		p[2][0], p[3][2] = avg2(K, J), avg2(K, J)
		p[3][0] = avg2(L, K)
		p[0][3] = avg3(A, B, C)
		p[0][2] = avg3(X, A, B)
		p[0][1], p[1][3] = avg3(I, X, A), avg3(I, X, A)
		p[1][1], p[2][3] = avg3(J, I, X), avg3(J, I, X)
		p[2][1], p[3][3] = avg3(K, J, I), avg3(K, J, I)
		p[3][1] = avg3(L, K, J)
	case B_HU:
		p[0][0] = avg2(I, J)
		p[0][2], p[1][0] = avg2(J, K), avg2(J, K)
		p[1][2], p[2][0] = avg2(K, L), avg2(K, L)
		p[0][1] = avg3(I, J, K)
		p[0][3], p[1][1] = avg3(J, K, L), avg3(J, K, L)
		p[1][3], p[2][1] = avg3(K, L, L), avg3(K, L, L)
		p[2][2], p[2][3], p[3] = u8(L), u8(L), u8(L)
	}
	for y in 0 ..< 4 do for x in 0 ..< 4 do ws[at + y * BPS + x] = p[y][x]
}

// The inverse DCT of a 4x4 block added to its prediction (RFC 6386 14.3),
// as libwebp computes it: 20091/65536 + 1 and 35468/65536 for the cosine
// terms.
@(private)
add_residual :: proc(ws: ^[WORKSPACE]u8, at: int, c: []i16, kind: u8) #no_bounds_check {
	switch kind {
	case 0:
		return
	case 1:
		dc := (i32(c[0]) + 4) >> 3
		for y in 0 ..< 4 do for x in 0 ..< 4 {
			o := &ws[at + y * BPS + x]
			o^ = u8(clamp(i32(o^) + dc, 0, 255))
		}
		return
	}
	mul1 :: #force_inline proc(a: i32) -> i32 {return ((a * 20091) >> 16) + a}
	mul2 :: #force_inline proc(a: i32) -> i32 {return (a * 35468) >> 16}
	tmp: [16]i32
	for i in 0 ..< 4 { // columns
		a := i32(c[i]) + i32(c[8 + i])
		b := i32(c[i]) - i32(c[8 + i])
		cc := mul2(i32(c[4 + i])) - mul1(i32(c[12 + i]))
		dd := mul1(i32(c[4 + i])) + mul2(i32(c[12 + i]))
		tmp[i * 4 + 0] = a + dd
		tmp[i * 4 + 1] = b + cc
		tmp[i * 4 + 2] = b - cc
		tmp[i * 4 + 3] = a - dd
	}
	for i in 0 ..< 4 { // rows
		dc := tmp[i] + 4
		a := dc + tmp[8 + i]
		b := dc - tmp[8 + i]
		cc := mul2(tmp[4 + i]) - mul1(tmp[12 + i])
		dd := mul1(tmp[4 + i]) + mul2(tmp[12 + i])
		row := ws[at + i * BPS:][:4]
		row[0] = u8(clamp(i32(row[0]) + ((a + dd) >> 3), 0, 255))
		row[1] = u8(clamp(i32(row[1]) + ((b + cc) >> 3), 0, 255))
		row[2] = u8(clamp(i32(row[2]) + ((b - cc) >> 3), 0, 255))
		row[3] = u8(clamp(i32(row[3]) + ((a - dd) >> 3), 0, 255))
	}
}

// The loop filter (RFC 6386 15), macroblock by macroblock in raster order:
// the left edge, the inner vertical edges, the top edge, the inner
// horizontal edges.
//
// An edge is filtered as 16 independent lanes along it, each with the 8
// pixels across it (p3 p2 p1 p0 | q0 q1 q2 q3), every lane computing all of
// the filter's outcomes and selecting one: straight-line lane code the
// compiler vectorizes. For the vertical edges the macroblock is transposed
// once into that shape (chroma: U's 8 rows and V's 8 as the 16 lanes), and
// every vertical edge is a view of it.
@(private)
loop_filter :: proc(d: ^Vp8) {
	ys, cs := d.y_stride, d.uv_stride
	for mb_y in 0 ..< d.mb_h do for mb_x in 0 ..< d.mb_w {
		at := mb_y * d.mb_w + mb_x
		f := d.strengths[d.mb_filter[at] >> 1][d.mb_filter[at] & 1]
		if f.limit == 0 do continue
		limit, inner, hev := i32(f.limit), i32(f.inner), i32(f.hev)
		filter_inner := d.mb_inner[at]
		y := mb_y * 16 * ys + mb_x * 16
		c := mb_y * 8 * cs + mb_x * 8
		left := mb_x > 0
		simple := d.filter.simple
		// Vertical edges, on the transposed macroblock: columns -4 ..< 16 of
		// luma, -4 ..< 8 of chroma (the left four only with a left
		// neighbour).
		if left || filter_inner {
			first := left ? 0 : 4
			t: [20][16]u8
			transpose_in(t[:], d.y, y - 4, ys, first, 16)
			if left do edge(&t[0], limit + 4, inner, hev, true, simple)
			if filter_inner do for k in 1 ..< 4 do edge(&t[4 * k], limit, inner, hev, false, simple)
			transpose_out(t[:], d.y, y - 4, ys, max(first, 1), 16)
			if !simple {
				tc: [12][16]u8
				transpose_in(tc[:], d.u, c - 4, cs, first, 8)
				transpose_in(tc[:], d.v, c - 4, cs, first, 8, 8)
				if left do edge(&tc[0], limit + 4, inner, hev, true, false)
				if filter_inner do edge(&tc[4], limit, inner, hev, false, false)
				transpose_out(tc[:], d.u, c - 4, cs, max(first, 1), 8)
				transpose_out(tc[:], d.v, c - 4, cs, max(first, 1), 8, 8)
			}
		}
		// Horizontal edges: the 8 rows across each, 16 lanes each.
		if mb_y > 0 {
			rows_edge(d.y, y, ys, limit + 4, inner, hev, true, simple)
			if !simple do chroma_rows_edge(d, c, cs, limit + 4, inner, hev, true)
		}
		if filter_inner {
			for k in 1 ..< 4 do rows_edge(d.y, y + 4 * k * ys, ys, limit, inner, hev, false, simple)
			if !simple do chroma_rows_edge(d, c + 4 * cs, cs, limit, inner, hev, false)
		}
	}
}

// The 8 pixels across an edge (p3 at 0 .. q3 at 7) by lane along it.
@(private)
Edge :: [8][16]u8

@(private)
edge :: #force_inline proc(e: ^[16]u8, limit, inner, hev: i32, mb_edge, simple: bool) {
	view := (^Edge)(e)
	switch {
	case simple:
		simple_lanes(view, limit)
	case mb_edge:
		filter_lanes(view, limit, inner, hev, true)
	case:
		filter_lanes(view, limit, inner, hev, false)
	}
}

// Columns first ..< len(t) of `rows` rows from buf[at:] (stride apart) into
// t[column][lane + row].
@(private)
transpose_in :: #force_inline proc(t: [][16]u8, buf: []u8, at, stride, first, rows: int, lane := 0) #no_bounds_check {
	for r in 0 ..< rows {
		src := buf[at + r * stride:]
		for c in first ..< len(t) do t[c][lane + r] = src[c]
	}
}

// Back: columns first ..< len(t) - 1 (the last is never written).
@(private)
transpose_out :: #force_inline proc(t: [][16]u8, buf: []u8, at, stride, first, rows: int, lane := 0) #no_bounds_check {
	for r in 0 ..< rows {
		dst := buf[at + r * stride:]
		for c in first ..< len(t) - 1 do dst[c] = t[c][lane + r]
	}
}

// A horizontal luma edge: the 8 rows across it, moved whole.
@(private)
rows_edge :: proc(buf: []u8, at, stride: int, limit, inner, hev: i32, mb_edge, simple: bool) #no_bounds_check {
	e: Edge
	for k in 0 ..< 8 do e[k] = (^[16]u8)(&buf[at + (k - 4) * stride])^
	edge(&e[0], limit, inner, hev, mb_edge, simple)
	for k in 1 ..< 7 do (^[16]u8)(&buf[at + (k - 4) * stride])^ = e[k]
}

// A horizontal chroma edge: U's 8 pixels and V's 8 as the 16 lanes.
@(private)
chroma_rows_edge :: proc(d: ^Vp8, at, stride: int, limit, inner, hev: i32, mb_edge: bool) #no_bounds_check {
	e: Edge
	for k in 0 ..< 8 {
		row := at + (k - 4) * stride
		(^[8]u8)(&e[k][0])^ = (^[8]u8)(&d.u[row])^
		(^[8]u8)(&e[k][8])^ = (^[8]u8)(&d.v[row])^
	}
	edge(&e[0], limit, inner, hev, mb_edge, false)
	for k in 1 ..< 7 {
		row := at + (k - 4) * stride
		(^[8]u8)(&d.u[row])^ = (^[8]u8)(&e[k][0])^
		(^[8]u8)(&d.v[row])^ = (^[8]u8)(&e[k][8])^
	}
}

// The normal filter: where the edge is smooth enough (limit, inner), lanes
// of high edge variance (hev) adjust p0 and q0; others adjust p2..q2 on
// macroblock edges and p1..q1 on inner edges.
@(private)
filter_lanes :: proc(e: ^Edge, limit, inner, hev: i32, $MB_EDGE: bool) #no_bounds_check {
	// Every value fits 16 bits: 8 lanes to a vector register.
	t, inner, hev := i16(2 * limit + 1), i16(inner), i16(hev)
	for i in 0 ..< 16 {
		p3, p2, p1, p0 := i16(e[0][i]), i16(e[1][i]), i16(e[2][i]), i16(e[3][i])
		q0, q1, q2, q3 := i16(e[4][i]), i16(e[5][i]), i16(e[6][i]), i16(e[7][i])
		interior := max(abs(p3 - p2), abs(p2 - p1), abs(p1 - p0), abs(q3 - q2), abs(q2 - q1), abs(q1 - q0))
		// & and |, not && and ||: no branches in the lanes.
		filter := (4 * abs(p0 - q0) + abs(p1 - q1) <= t) & (interior <= inner)
		high := (abs(p1 - p0) > hev) | (abs(q1 - q0) > hev)
		// With the outer taps, as high-variance lanes (and macroblock edges)
		// use them.
		w := clamp(clamp(p1 - q1, -128, 127) + 3 * (q0 - p0), -128, 127)
		f1 := clamp((w + 4) >> 3, -16, 15)
		f2 := clamp((w + 3) >> 3, -16, 15)
		np2, np1, np0, nq0, nq1, nq2: i16
		when MB_EDGE {
			a1 := (27 * w + 63) >> 7
			a2 := (18 * w + 63) >> 7
			a3 := (9 * w + 63) >> 7
			np2 = high ? p2 : p2 + a3
			np1 = high ? p1 : p1 + a2
			np0 = high ? p0 + f2 : p0 + a1
			nq0 = high ? q0 - f1 : q0 - a1
			nq1 = high ? q1 : q1 - a2
			nq2 = high ? q2 : q2 - a3
		} else {
			a := 3 * (q0 - p0)
			g1 := clamp((a + 4) >> 3, -16, 15)
			g2 := clamp((a + 3) >> 3, -16, 15)
			g3 := (g1 + 1) >> 1
			np2, nq2 = p2, q2
			np1 = high ? p1 : p1 + g3
			np0 = high ? p0 + f2 : p0 + g2
			nq0 = high ? q0 - f1 : q0 - g1
			nq1 = high ? q1 : q1 - g3
		}
		e[1][i] = u8(clamp(filter ? np2 : p2, 0, 255))
		e[2][i] = u8(clamp(filter ? np1 : p1, 0, 255))
		e[3][i] = u8(clamp(filter ? np0 : p0, 0, 255))
		e[4][i] = u8(clamp(filter ? nq0 : q0, 0, 255))
		e[5][i] = u8(clamp(filter ? nq1 : q1, 0, 255))
		e[6][i] = u8(clamp(filter ? nq2 : q2, 0, 255))
	}
}

// The simple filter (luma only): p0 and q0 where the edge is smooth enough.
@(private)
simple_lanes :: proc(e: ^Edge, limit: i32) #no_bounds_check {
	t := i16(2 * limit + 1)
	for i in 0 ..< 16 {
		p1, p0, q0, q1 := i16(e[2][i]), i16(e[3][i]), i16(e[4][i]), i16(e[5][i])
		filter := 4 * abs(p0 - q0) + abs(p1 - q1) <= t
		w := clamp(clamp(p1 - q1, -128, 127) + 3 * (q0 - p0), -128, 127)
		f1 := clamp((w + 4) >> 3, -16, 15)
		f2 := clamp((w + 3) >> 3, -16, 15)
		e[3][i] = u8(clamp(filter ? p0 + f2 : p0, 0, 255))
		e[4][i] = u8(clamp(filter ? q0 - f1 : q0, 0, 255))
	}
}

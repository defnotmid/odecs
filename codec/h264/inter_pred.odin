package h264

import "base:intrinsics"

import "core:simd"

import "core:mem"

// ---------------------------------------------------------------------------
// Border padding for motion compensation
// ---------------------------------------------------------------------------

PADDING_LENGTH :: 32

expand_picture_luma :: proc(dst: [^]u8, stride: int, pic_w: int, pic_h: int) #no_bounds_check {
	pad :: PADDING_LENGTH // 32
	last_line: [^]u8 = &dst[(pic_h - 1) * stride]

	// 1. Pad left and right borders for all image rows using fast 64-bit stores
	cur := dst
	for _ in 0 ..< pic_h {
		l_val := u64(cur[0]) * 0x0101010101010101
		(cast(^u64)&cur[-32])^ = l_val
		(cast(^u64)&cur[-24])^ = l_val
		(cast(^u64)&cur[-16])^ = l_val
		(cast(^u64)&cur[-8])^ = l_val

		r_val := u64(cur[pic_w - 1]) * 0x0101010101010101
		(cast(^u64)&cur[pic_w])^ = r_val
		(cast(^u64)&cur[pic_w + 8])^ = r_val
		(cast(^u64)&cur[pic_w + 16])^ = r_val
		(cast(^u64)&cur[pic_w + 24])^ = r_val

		cur = &cur[stride]
	}

	// 2. Pad top and bottom rows copying full span (including pre-padded borders)
	span := pic_w + 2 * pad
	src_top: [^]u8 = &dst[-pad]
	src_bot: [^]u8 = &last_line[-pad]
	for i in 1 ..= pad {
		mem.copy(&dst[-i * stride - pad], src_top, span)
		mem.copy(&last_line[i * stride - pad], src_bot, span)
	}
}

expand_picture_chroma :: proc(dst: [^]u8, stride: int, pic_w: int, pic_h: int) #no_bounds_check {
	pad :: PADDING_LENGTH / 2 // 16
	last_line: [^]u8 = &dst[(pic_h - 1) * stride]

	// 1. Pad left and right borders for all rows
	cur := dst
	for _ in 0 ..< pic_h {
		l_val := u64(cur[0]) * 0x0101010101010101
		(cast(^u64)&cur[-16])^ = l_val
		(cast(^u64)&cur[-8])^ = l_val

		r_val := u64(cur[pic_w - 1]) * 0x0101010101010101
		(cast(^u64)&cur[pic_w])^ = r_val
		(cast(^u64)&cur[pic_w + 8])^ = r_val

		cur = &cur[stride]
	}

	// 2. Pad top and bottom rows copying full span
	span := pic_w + 2 * pad
	src_top: [^]u8 = &dst[-pad]
	src_bot: [^]u8 = &last_line[-pad]
	for i in 1 ..= pad {
		mem.copy(&dst[-i * stride - pad], src_top, span)
		mem.copy(&last_line[i * stride - pad], src_bot, span)
	}
}

expand_picture :: proc(buf: ^YUV_Buffer) {
	w := buf.coded_width
	h := buf.coded_height
	expand_picture_luma(buf.y, buf.y_stride, w, h)
	expand_picture_chroma(buf.u, buf.uv_stride, w / 2, h / 2)
	expand_picture_chroma(buf.v, buf.uv_stride, w / 2, h / 2)
}

// ---------------------------------------------------------------------------
// Block indexing and motion vector prediction (8.4.1.3)
// ---------------------------------------------------------------------------

median3 :: proc "contextless" (a, b, c: i16) -> i16 {
	if a > b {
		if b > c do return b
		if a > c do return c
		return a
	} else {
		if a > c do return a
		if b > c do return c
		return b
	}
}

// Subblock partition index to (x, y) in 4x4 units. The index interleaves
// the coordinates: bits 0 and 2 carry x, bits 1 and 3 carry y.
//  0  1  4  5
//  2  3  6  7
//  8  9 12 13
// 10 11 14 15
subblock_to_xy :: #force_inline proc "contextless" (idx: int) -> (int, int) {
	return idx & 1 | (idx >> 1) & 2, (idx >> 1) & 1 | (idx >> 2) & 2
}

xy_to_subblock :: #force_inline proc "contextless" (x, y: int) -> int {
	return ((y & 2) << 2) | ((x & 2) << 1) | ((y & 1) << 1) | (x & 1)
}

MV_Neighbour :: struct {
	mv:    [2]i16,
	ref:   i8,
	avail: bool,
}

// Motion data of 4x4 block (x, y) of macroblock `idx` for one list; intra
// blocks and partitions not using the list count as available without a
// reference (8.4.1.3.2).
mv_neighbour :: proc(grid: ^Macroblock_Grid, idx, list, x, y: int) -> MV_Neighbour {
	macroblock := &grid.macroblocks[idx]
	if macroblock.is_intra do return {ref = -1, avail = true}
	sub := xy_to_subblock(x, y)
	return {
		mv = macroblock.motion_vectors[list][sub],
		ref = macroblock.reference_indices[list][sub / 4],
		avail = true,
	}
}

// Neighbours A, B, C (C replaced by D when unavailable) of a partition (6.4.11.7)
partition_neighbours :: proc(
	grid: ^Macroblock_Grid,
	macroblock_index, list, block, width: int,
) -> (
	a, b, c: MV_Neighbour,
) {
	macroblock_columns := grid.macroblock_columns
	mb_x := macroblock_index % macroblock_columns
	bx, by := subblock_to_xy(block)
	left_ok := mb_x > 0 && macroblock_is_available(grid, macroblock_index - 1)
	top_ok := macroblock_is_available(grid, macroblock_index - macroblock_columns)
	top_right_ok :=
		mb_x < macroblock_columns - 1 &&
		macroblock_is_available(grid, macroblock_index - macroblock_columns + 1)
	top_left_ok :=
		mb_x > 0 && macroblock_is_available(grid, macroblock_index - macroblock_columns - 1)
	a, b, c = {
			ref = -1,
		}, {
			ref = -1,
		}, {
			ref = -1,
		}

	if bx > 0 {
		a = mv_neighbour(grid, macroblock_index, list, bx - 1, by)
	} else if left_ok {
		a = mv_neighbour(grid, macroblock_index - 1, list, 3, by)
	}
	if by > 0 {
		b = mv_neighbour(grid, macroblock_index, list, bx, by - 1)
	} else if top_ok {
		b = mv_neighbour(grid, macroblock_index - macroblock_columns, list, bx, 3)
	}
	// C inside the macroblock only when decoded before this partition
	crx := bx + width
	switch {
	case by > 0:
		if crx < 4 && xy_to_subblock(crx, by - 1) < block do c = mv_neighbour(grid, macroblock_index, list, crx, by - 1)
	case crx < 4:
		if top_ok do c = mv_neighbour(grid, macroblock_index - macroblock_columns, list, crx, 3)
	case:
		if top_right_ok do c = mv_neighbour(grid, macroblock_index - macroblock_columns + 1, list, 0, 3)
	}
	if !c.avail {
		switch {
		case bx > 0 && by > 0:
			c = mv_neighbour(grid, macroblock_index, list, bx - 1, by - 1)
		case by > 0:
			if left_ok do c = mv_neighbour(grid, macroblock_index - 1, list, 3, by - 1)
		case bx > 0:
			if top_ok do c = mv_neighbour(grid, macroblock_index - macroblock_columns, list, bx - 1, 3)
		case:
			if top_left_ok do c = mv_neighbour(grid, macroblock_index - macroblock_columns - 1, list, 3, 3)
		}
	}
	return
}

// Motion vector prediction for a partition (8.4.1.3). `block` is the first
// 4x4 block in decoding order, `width`/`height` the partition size in 4x4 units.
predict_motion_vector :: proc(
	grid: ^Macroblock_Grid,
	macroblock_index, list, block, width, height: int,
	target_ref: i8,
) -> [2]i16 {
	a, b, c := partition_neighbours(grid, macroblock_index, list, block, width)
	if !b.avail && !c.avail && a.avail {
		b = a
		c = a
	}
	// Directional prediction for 16x8 and 8x16 partitions
	switch {
	case width == 4 && height == 2 && block == 0 && b.ref == target_ref:
		return b.mv
	case width == 4 && height == 2 && block == 8 && a.ref == target_ref:
		return a.mv
	case width == 2 && height == 4 && block == 0 && a.ref == target_ref:
		return a.mv
	case width == 2 && height == 4 && block == 4 && c.ref == target_ref:
		return c.mv
	}
	matches := int(a.ref == target_ref) + int(b.ref == target_ref) + int(c.ref == target_ref)
	if matches == 1 {
		if a.ref == target_ref do return a.mv
		if b.ref == target_ref do return b.mv
		return c.mv
	}
	return {median3(a.mv[0], b.mv[0], c.mv[0]), median3(a.mv[1], b.mv[1], c.mv[1])}
}

// P_Skip motion vector (8.4.1.1)
predict_skip_motion_vector :: proc(grid: ^Macroblock_Grid, macroblock_index: int) -> [2]i16 {
	macroblock_columns := grid.macroblock_columns
	if macroblock_index % macroblock_columns == 0 || !macroblock_is_available(grid, macroblock_index - 1) || !macroblock_is_available(grid, macroblock_index - macroblock_columns) do return {0, 0}
	a := mv_neighbour(grid, macroblock_index - 1, 0, 3, 0)
	b := mv_neighbour(grid, macroblock_index - macroblock_columns, 0, 0, 3)
	if (a.ref == 0 && a.mv == {0, 0}) || (b.ref == 0 && b.mv == {0, 0}) do return {0, 0}
	return predict_motion_vector(grid, macroblock_index, 0, 0, 4, 4, 0)
}

// ---------------------------------------------------------------------------
// Direct prediction (8.4.1.2) for the 8x8 blocks in `mask`
// ---------------------------------------------------------------------------

// Col-located 4x4 block of the current 4x4 block (8.4.1.2.1, frames only)
tap6_lanes :: #force_inline proc($N: int, p: [^]u8, step: int) -> #simd[N]i16 #no_bounds_check {
	a := load_lanes(N, &p[-2 * step])
	b := load_lanes(N, &p[-step])
	c := load_lanes(N, p)
	d := load_lanes(N, &p[step])
	e := load_lanes(N, &p[2 * step])
	f := load_lanes(N, &p[3 * step])
	return simd.add(
		simd.sub(simd.add(a, f), simd.mul(simd.add(b, e), 5)),
		simd.mul(simd.add(c, d), 20),
	)
}

// Rounded and clipped half-sample: (v + 16) >> 5
half_lanes :: #force_inline proc(v: #simd[$N]i16) -> #simd[N]i16 {
	return clamp_lanes(shr_lanes(simd.add(v, 16), 5))
}

// Luma interpolation (8.4.2.2.1) of an N-wide block, N = 8 or 16
mc_luma_lanes :: proc(
	$N: int,
	src: [^]u8,
	src_stride: int,
	dst: [^]u8,
	dst_stride: int,
	x_frac, y_frac, height: int,
) #no_bounds_check {
	L :: #simd[N]i16
	// Horizontal half-sample b of row y, and the vertical half-sample h of row y
	b_row :: #force_inline proc(
		$N: int,
		src: [^]u8,
		src_stride, y: int,
	) -> #simd[N]i16 {return half_lanes(tap6_lanes(N, &src[y * src_stride], 1))}
	h_row :: #force_inline proc(
		$N: int,
		src: [^]u8,
		src_stride, y: int,
		dx: int,
	) -> #simd[N]i16 {return half_lanes(tap6_lanes(N, &src[y * src_stride + dx], src_stride))}
	// Adjacent output rows share five of six horizontal-filter rows.
	// Keep these unrounded until the vertical pass; clipping between the
	// passes would change the diagonal half-sample.
	horizontal_rows: [21]#simd[N]i32
	if x_frac != 0 && y_frac != 0 && (x_frac == 2 || y_frac == 2) {
		for row in 0 ..< height + 5 do horizontal_rows[row] = (#simd[N]i32)(tap6_lanes(N, &src[(row - 2) * src_stride], 1))
	}
	diagonal_half_samples :: #force_inline proc(
		rows: ^[21]#simd[$Lane_Count]i32,
		y: int,
	) -> #simd[Lane_Count]i16 {
		v := simd.add(
			simd.sub(
				simd.add(rows[y], rows[y + 5]),
				simd.mul(simd.add(rows[y + 1], rows[y + 4]), 5),
			),
			simd.mul(simd.add(rows[y + 2], rows[y + 3]), 20),
		)
		return (#simd[Lane_Count]i16)(
			simd.clamp(simd.shr(simd.add(v, 512), (#simd[Lane_Count]u32)(10)), 0, 255),
		)
	}
	put :: #force_inline proc(dst: [^]u8, dst_stride, y: int, out: #simd[$N]i16) {
		intrinsics.unaligned_store((^#simd[N]u8)(&dst[y * dst_stride]), (#simd[N]u8)(out))
	}
	// The fractional position is fixed for the block, so each case owns its
	// row loop.
	switch {
	case x_frac == 0 && y_frac == 0:
		for y in 0 ..< height do put(dst, dst_stride, y, load_lanes(N, &src[y * src_stride]))
	case y_frac == 0 && x_frac == 2:
		for y in 0 ..< height do put(dst, dst_stride, y, b_row(N, src, src_stride, y))
	case x_frac == 0 && y_frac == 2:
		for y in 0 ..< height do put(dst, dst_stride, y, h_row(N, src, src_stride, y, 0))
	case y_frac == 0:
		for y in 0 ..< height {
			g := load_lanes(N, &src[y * src_stride + x_frac >> 1])
			put(dst, dst_stride, y, average_lanes(b_row(N, src, src_stride, y), g))
		}
	case x_frac == 0:
		for y in 0 ..< height {
			g := load_lanes(N, &src[(y + y_frac >> 1) * src_stride])
			put(dst, dst_stride, y, average_lanes(h_row(N, src, src_stride, y, 0), g))
		}
	case x_frac == 2 && y_frac == 2:
		for y in 0 ..< height do put(dst, dst_stride, y, diagonal_half_samples(&horizontal_rows, y))
	case x_frac == 2:
		for y in 0 ..< height {
			j := diagonal_half_samples(&horizontal_rows, y)
			put(dst, dst_stride, y, average_lanes(j, b_row(N, src, src_stride, y + y_frac >> 1)))
		}
	case y_frac == 2:
		for y in 0 ..< height {
			j := diagonal_half_samples(&horizontal_rows, y)
			put(dst, dst_stride, y, average_lanes(j, h_row(N, src, src_stride, y, x_frac >> 1)))
		}
	case:
		for y in 0 ..< height {
			b := b_row(N, src, src_stride, y + y_frac >> 1)
			put(dst, dst_stride, y, average_lanes(b, h_row(N, src, src_stride, y, x_frac >> 1)))
		}
	}
}

// Chroma bilinear interpolation (8.4.2.2.2) of an N-wide block
mc_chroma_lanes :: proc(
	$N: int,
	src: [^]u8,
	src_stride: int,
	dst: [^]u8,
	dst_stride: int,
	x_frac, y_frac, height: int,
) #no_bounds_check {
	C :: #simd[N]i16
	a := C(i16((8 - x_frac) * (8 - y_frac)))
	b := C(i16(x_frac * (8 - y_frac)))
	c := C(i16((8 - x_frac) * y_frac))
	d := C(i16(x_frac * y_frac))
	for y in 0 ..< height {
		row: [^]u8 = &src[y * src_stride]
		next: [^]u8 = &src[(y + 1) * src_stride]
		v := simd.add(
			simd.add(simd.mul(load_lanes(N, row), a), simd.mul(load_lanes(N, &row[1]), b)),
			simd.add(simd.mul(load_lanes(N, next), c), simd.mul(load_lanes(N, &next[1]), d)),
		)
		intrinsics.unaligned_store(
			(^#simd[N]u8)(&dst[y * dst_stride]),
			(#simd[N]u8)(shr_lanes(simd.add(v, 32), 6)),
		)
	}
}

filter_6tap_8bit :: proc "contextless" (src: [^]u8, stride: int) -> i32 #no_bounds_check {
	p0 := i32(src[-2 * stride])
	p1 := i32(src[-1 * stride])
	p2 := i32(src[0])
	p3 := i32(src[1 * stride])
	p4 := i32(src[2 * stride])
	p5 := i32(src[3 * stride])
	return (p0 + p5) - 5 * (p1 + p4) + 20 * (p2 + p3)
}

mc_luma :: proc(
	src: [^]u8,
	src_stride: int,
	dst: [^]u8,
	dst_stride: int,
	mv_x: i16,
	mv_y: i16,
	width: int,
	height: int,
) #no_bounds_check {
	x_int := int(mv_x >> 2)
	y_int := int(mv_y >> 2)
	x_frac := int(mv_x & 3)
	y_frac := int(mv_y & 3)

	cur_src: [^]u8 = &src[y_int * src_stride + x_int]

	// Case 0: Integer pel
	if x_frac == 0 && y_frac == 0 {
		for y in 0 ..< height {
			mem.copy(&dst[y * dst_stride], &cur_src[y * src_stride], width)
		}
		return
	}

	// Case 1: Half-pel horizontal only (2, 0)
	if x_frac == 2 && y_frac == 0 {
		for y in 0 ..< height {
			s: [^]u8 = &cur_src[y * src_stride]
			d: [^]u8 = &dst[y * dst_stride]
			for x in 0 ..< width {
				val := (filter_6tap_8bit(&s[x], 1) + 16) >> 5
				d[x] = clamp_u8(val)
			}
		}
		return
	}

	// Case 2: Half-pel vertical only (0, 2)
	if x_frac == 0 && y_frac == 2 {
		for y in 0 ..< height {
			s: [^]u8 = &cur_src[y * src_stride]
			d: [^]u8 = &dst[y * dst_stride]
			for x in 0 ..< width {
				val := (filter_6tap_8bit(&s[x], src_stride) + 16) >> 5
				d[x] = clamp_u8(val)
			}
		}
		return
	}

	// Case 3: Quarter-pel horizontal only (1, 0) or (3, 0)
	if y_frac == 0 {
		offset := x_frac == 1 ? 0 : 1
		for y in 0 ..< height {
			s: [^]u8 = &cur_src[y * src_stride]
			d: [^]u8 = &dst[y * dst_stride]
			for x in 0 ..< width {
				h := clamp_u8((filter_6tap_8bit(&s[x], 1) + 16) >> 5)
				int_val := s[x + offset]
				d[x] = u8((u32(int_val) + u32(h) + 1) >> 1)
			}
		}
		return
	}

	// Case 4: Quarter-pel vertical only (0, 1) or (0, 3)
	if x_frac == 0 {
		y_off := y_frac == 1 ? 0 : 1
		for y in 0 ..< height {
			s: [^]u8 = &cur_src[y * src_stride]
			s_int: [^]u8 = &cur_src[(y + y_off) * src_stride]
			d: [^]u8 = &dst[y * dst_stride]
			for x in 0 ..< width {
				v := clamp_u8((filter_6tap_8bit(&s[x], src_stride) + 16) >> 5)
				int_val := s_int[x]
				d[x] = u8((u32(int_val) + u32(v) + 1) >> 1)
			}
		}
		return
	}

	// Case 5: Half-pel both horizontal and vertical (2, 2)
	if x_frac == 2 && y_frac == 2 {
		tmp: [21 * 21]i32
		// Horizontal filter over height + 5 lines
		for y in 0 ..< (height + 5) {
			s: [^]u8 = &cur_src[(y - 2) * src_stride]
			for x in 0 ..< width {
				tmp[y * 21 + x] = filter_6tap_8bit(&s[x], 1)
			}
		}
		// Vertical filter on intermediate 16/32-bit values
		for y in 0 ..< height {
			d: [^]u8 = &dst[y * dst_stride]
			for x in 0 ..< width {
				p0 := tmp[(y + 0) * 21 + x]
				p1 := tmp[(y + 1) * 21 + x]
				p2 := tmp[(y + 2) * 21 + x]
				p3 := tmp[(y + 3) * 21 + x]
				p4 := tmp[(y + 4) * 21 + x]
				p5 := tmp[(y + 5) * 21 + x]
				val := ((p0 + p5) - 5 * (p1 + p4) + 20 * (p2 + p3) + 512) >> 10
				d[x] = clamp_u8(val)
			}
		}
		return
	}

	// Remaining quarter-pel positions (8.4.2.2.1): the average of two of the
	// half-pel samples b (horizontal), h (vertical) and j (centre). A fraction
	// of 3 uses the half-pel sample one pixel further right (m) or down (s).
	half_h: [17 * 16]u8 // b at rows 0..height
	half_v: [16 * 17]u8 // h at columns 0..width
	centre: [16 * 16]u8 // j
	for y in 0 ..< height + 1 {
		s: [^]u8 = &cur_src[y * src_stride]
		for x in 0 ..< width {
			half_h[y * 16 + x] = clamp_u8((filter_6tap_8bit(&s[x], 1) + 16) >> 5)
		}
	}
	for y in 0 ..< height {
		s: [^]u8 = &cur_src[y * src_stride]
		for x in 0 ..< width + 1 {
			half_v[y * 17 + x] = clamp_u8((filter_6tap_8bit(&s[x], src_stride) + 16) >> 5)
		}
	}
	if x_frac == 2 || y_frac == 2 {
		tmp: [21 * 16]i32
		for y in 0 ..< height + 5 {
			s: [^]u8 = &cur_src[(y - 2) * src_stride]
			for x in 0 ..< width {
				tmp[y * 16 + x] = filter_6tap_8bit(&s[x], 1)
			}
		}
		for y in 0 ..< height {
			for x in 0 ..< width {
				t: [^]i32 = &tmp[y * 16 + x]
				centre[y * 16 + x] = clamp_u8(
					((t[0] + t[5 * 16]) -
						5 * (t[16] + t[4 * 16]) +
						20 * (t[2 * 16] + t[3 * 16]) +
						512) >>
					10,
				)
			}
		}
	}
	row_off := y_frac == 3 ? 1 : 0
	col_off := x_frac == 3 ? 1 : 0
	for y in 0 ..< height {
		d: [^]u8 = &dst[y * dst_stride]
		for x in 0 ..< width {
			b := u32(half_h[(y + row_off) * 16 + x])
			h := u32(half_v[y * 17 + x + col_off])
			j := u32(centre[y * 16 + x])
			switch {
			case x_frac == 2:
				d[x] = u8((b + j + 1) >> 1)
			case y_frac == 2:
				d[x] = u8((h + j + 1) >> 1)
			case:
				d[x] = u8((b + h + 1) >> 1)
			}
		}
	}
}

mc_chroma :: proc(
	src: [^]u8,
	src_stride: int,
	dst: [^]u8,
	dst_stride: int,
	mv_x: i16,
	mv_y: i16,
	width: int,
	height: int,
) #no_bounds_check {
	x_int := int(mv_x >> 3)
	y_int := int(mv_y >> 3)
	x_frac := int(mv_x & 7)
	y_frac := int(mv_y & 7)

	cur_src: [^]u8 = &src[y_int * src_stride + x_int]

	if x_frac == 0 && y_frac == 0 {
		for y in 0 ..< height {
			mem.copy(&dst[y * dst_stride], &cur_src[y * src_stride], width)
		}
		return
	}

	if y_frac == 0 {
		a := i32(8 - x_frac)
		b := i32(x_frac)
		#no_bounds_check for y in 0 ..< height {
			s0: [^]u8 = &cur_src[y * src_stride]
			dst_row: [^]u8 = &dst[y * dst_stride]
			for x in 0 ..< width {
				val := (a * i32(s0[x]) + b * i32(s0[x + 1]) + 4) >> 3
				dst_row[x] = u8(val)
			}
		}
		return
	}

	if x_frac == 0 {
		a := i32(8 - y_frac)
		c := i32(y_frac)
		#no_bounds_check for y in 0 ..< height {
			s0: [^]u8 = &cur_src[y * src_stride]
			s1: [^]u8 = &cur_src[(y + 1) * src_stride]
			dst_row: [^]u8 = &dst[y * dst_stride]
			for x in 0 ..< width {
				val := (a * i32(s0[x]) + c * i32(s1[x]) + 4) >> 3
				dst_row[x] = u8(val)
			}
		}
		return
	}

	abcd := chroma_abcd[y_frac][x_frac]
	a := i32(abcd[0])
	b := i32(abcd[1])
	c := i32(abcd[2])
	d := i32(abcd[3])

	#no_bounds_check for y in 0 ..< height {
		s0: [^]u8 = &cur_src[y * src_stride]
		s1: [^]u8 = &cur_src[(y + 1) * src_stride]
		dst_row: [^]u8 = &dst[y * dst_stride]
		for x in 0 ..< width {
			p00 := i32(s0[x])
			p10 := i32(s0[x + 1])
			p01 := i32(s1[x])
			p11 := i32(s1[x + 1])
			val := (a * p00 + b * p10 + c * p01 + d * p11 + 32) >> 6
			dst_row[x] = u8(val)
		}
	}
}

// ---------------------------------------------------------------------------
// Inter prediction of a macroblock with weighting (8.4.2, 8.4.3)
// ---------------------------------------------------------------------------

// Where one block's prediction samples go: its position in a luma plane and
// both chroma planes, with their strides.
Prediction_Target :: struct {
	luma:          [^]u8,
	chroma:        [2][^]u8,
	luma_stride:   int,
	chroma_stride: int,
}

// The target at luma sample (x, y) of a picture buffer.
prediction_target :: proc(buf: ^YUV_Buffer, x, y: int) -> Prediction_Target {
	c := (y / 2) * buf.uv_stride + x / 2
	return {&buf.y[y * buf.y_stride + x], {&buf.u[c], &buf.v[c]}, buf.y_stride, buf.uv_stride}
}

// Prediction samples of one block of one list, written to `out`
motion_compensate :: proc(
	buf: ^YUV_Buffer,
	x_pos, y_pos, width, height: int,
	mv: [2]i16,
	out: ^Prediction_Target,
) #no_bounds_check {
	pic_w, pic_h := buf.coded_width, buf.coded_height
	// Keep every read inside the padded frame; a block entirely outside sees only edge samples
	lx := clamp(x_pos + int(mv[0] >> 2), 2 - PADDING_LENGTH, pic_w + PADDING_LENGTH - width - 3)
	ly := clamp(y_pos + int(mv[1] >> 2), 2 - PADDING_LENGTH, pic_h + PADDING_LENGTH - height - 3)
	luma_src: [^]u8 = &buf.y[ly * buf.y_stride + lx]
	switch width {
	case 16:
		mc_luma_lanes(
			16,
			luma_src,
			buf.y_stride,
			out.luma,
			out.luma_stride,
			int(mv[0] & 3),
			int(mv[1] & 3),
			height,
		)
	case 8:
		mc_luma_lanes(
			8,
			luma_src,
			buf.y_stride,
			out.luma,
			out.luma_stride,
			int(mv[0] & 3),
			int(mv[1] & 3),
			height,
		)
	case:
		mc_luma_lanes(
			4,
			luma_src,
			buf.y_stride,
			out.luma,
			out.luma_stride,
			int(mv[0] & 3),
			int(mv[1] & 3),
			height,
		)
	}

	cpad :: PADDING_LENGTH / 2
	cw, ch := width / 2, height / 2
	cx := clamp(x_pos / 2 + int(mv[0] >> 3), -cpad, pic_w / 2 + cpad - cw - 1)
	cy := clamp(y_pos / 2 + int(mv[1] >> 3), -cpad, pic_h / 2 + cpad - ch - 1)
	planes := [2]([^]u8){buf.u, buf.v}
	for p in 0 ..< 2 {
		src: [^]u8 = &planes[p][cy * buf.uv_stride + cx]
		switch cw {
		case 8:
			mc_chroma_lanes(
				8,
				src,
				buf.uv_stride,
				out.chroma[p],
				out.chroma_stride,
				int(mv[0] & 7),
				int(mv[1] & 7),
				ch,
			)
		case 4:
			mc_chroma_lanes(
				4,
				src,
				buf.uv_stride,
				out.chroma[p],
				out.chroma_stride,
				int(mv[0] & 7),
				int(mv[1] & 7),
				ch,
			)
		case:
			mc_chroma_lanes(
				2,
				src,
				buf.uv_stride,
				out.chroma[p],
				out.chroma_stride,
				int(mv[0] & 7),
				int(mv[1] & 7),
				ch,
			)
		}
	}
}


uniform_motion :: proc(
	macroblock: #soa^#soa[]Macroblock,
	first, count: int,
) -> bool #no_bounds_check {
	dir := macroblock.prediction_directions[first / 4]
	for block in first + 1 ..< first + count {
		if macroblock.prediction_directions[block / 4] != dir do return false
		for list in 0 ..< 2 {
			if dir & (list == 0 ? Prediction_Direction.List_0 : .List_1) == .None do continue
			if macroblock.reference_indices[list][block / 4] != macroblock.reference_indices[list][first / 4] || macroblock.motion_vectors[list][block] != macroblock.motion_vectors[list][first] do return false
		}
	}
	return true
}

// Motion compensate the largest uniform blocks: the whole macroblock, else 8x8s, else 4x4s

package h265_decoder


// ---------------------------------------------------------------------------
// Sample adaptive offset (8.7.3), ported from gen2brain/h265 hevc/sao.go
// (MIT); oxideav-h265 src/sao.rs is the per-file cross-reference. A single
// slice/tile is assumed.
// ---------------------------------------------------------------------------

SAO_OFF :: 0
SAO_BAND :: 1
SAO_EDGE :: 2

Sao_Params :: struct {
	type_idx: int,
	class:    int,
	band:     int,
	offset:   [4]i32,
}

Sao_Ctb :: [3]Sao_Params

// Table 8-16, the two sample positions each edge class compares against.
@(rodata)
SAO_EO_OFFSETS := [4][2][2]int {
	{{-1, 0}, {1, 0}},
	{{0, -1}, {0, 1}},
	{{-1, -1}, {1, 1}},
	{{1, -1}, {-1, 1}},
}

sao_grow :: proc(b: ^[dynamic]$Sample, n: int) -> []Sample {
	resize(b, n)
	return b[:]
}

// parse_sao reads 7.3.8.3 into the per-CTB parameters 8.7.3 applies.
parse_sao :: proc(d: ^Ctu_Decoder($Sample), x, y: int) {
	w := int(d.s.pic_width_in_ctbs)
	rs := (y >> uint(d.s.ctb_log2_size_y)) * w + x >> uint(d.s.ctb_log2_size_y)

	merge_left, merge_up := false, false

	// 8.7.3: the merge flags do not reach across a tile boundary the loop
	// filter may not cross (a single-slice picture has no internal slice edge).
	ts := int(d.grids.rs_to_ts[rs])

	if rs % w > 0 &&
	   rs - 1 >= d.slice_addr_rs &&
	   d.grids.tile_id[ts] == d.grids.tile_id[d.grids.rs_to_ts[rs - 1]] {
		merge_left = cabac_decode_bin(&d.c, ctxSAOMergeFlag) != 0
	}

	if !merge_left &&
	   rs >= w &&
	   rs - w >= d.slice_addr_rs &&
	   d.grids.tile_id[ts] == d.grids.tile_id[d.grids.rs_to_ts[rs - w]] {
		merge_up = cabac_decode_bin(&d.c, ctxSAOMergeFlag) != 0
	}

	ctb := rs

	if merge_left {
		d.grids.sao[ctb] = d.grids.sao[rs - 1]
		return
	}

	if merge_up {
		d.grids.sao[ctb] = d.grids.sao[rs - w]
		return
	}

	n_comp := 1
	if sps_chroma_array_type(d.s) != 0 do n_comp = 3

	for c_idx in 0 ..< n_comp {
		if c_idx == 0 && !d.sh.sao_luma do continue
		if c_idx > 0 && !d.sh.sao_chroma do continue

		c_max := 1 << uint(min(int(d.s.bit_depth_luma), 10) - 5) - 1
		if c_idx > 0 do c_max = 1 << uint(min(int(d.s.bit_depth_chroma), 10) - 5) - 1

		type_idx := 0

		if c_idx != 2 {
			if cabac_decode_bin(&d.c, ctxSAOTypeIDX) != 0 {
				type_idx = SAO_BAND
				if cabac_decode_bypass(&d.c) != 0 do type_idx = SAO_EDGE
			}

			d.sao_type[c_idx] = type_idx
		} else {
			type_idx = d.sao_type[1]
		}

		p := &d.grids.sao[ctb][c_idx]
		p.type_idx = type_idx

		if type_idx == SAO_OFF do continue

		off_abs: [4]int

		for i in 0 ..< 4 {
			v := 0
			for v < c_max && cabac_decode_bypass(&d.c) != 0 do v += 1

			off_abs[i] = v
		}

		// 7.4.9.3 scales every offset by the shift the picture carries.
		scale := d.p.log2_sao_offset_scale_luma
		if c_idx > 0 do scale = d.p.log2_sao_offset_scale_chroma

		if type_idx == SAO_BAND {
			for i in 0 ..< 4 {
				p.offset[i] = i32(off_abs[i]) << uint(scale)

				if off_abs[i] != 0 && cabac_decode_bypass(&d.c) != 0 {
					p.offset[i] = -p.offset[i]
				}
			}

			p.band = int(cabac_decode_bypass_bits(&d.c, 5))
			continue
		}

		// Edge offsets are signed by position: the first two are positive,
		// the last two negative.
		for i in 0 ..< 4 {
			p.offset[i] = i32(off_abs[i]) << uint(scale)
			if i >= 2 do p.offset[i] = -p.offset[i]
		}

		if c_idx != 2 do d.eo_class[c_idx] = int(cabac_decode_bypass_bits(&d.c, 2))

		p.class = d.eo_class[min(c_idx, 1)]
	}
}

// apply_sao is 8.7.3. It reads the picture as deblocking left it, so the source
// is copied first and every offset is taken from the unfiltered neighbourhood.
apply_sao :: proc(d: ^Ctu_Decoder($Sample)) {
	n_comp := 1
	if sps_chroma_array_type(d.s) != 0 do n_comp = 3

	// 8.7.3 leaves transform-bypass blocks unfiltered. When no block in the
	// picture carries that flag -- the common case -- a row needs no per-block
	// walk at all and every interior run is filtered in one pass.
	any_no_filter := false
	for f in d.grids.no_filter {
		if f {
			any_no_filter = true
			break
		}
	}

	for c_idx in 0 ..< n_comp {
		plane, stride := plane_at(Sample, d.pic, c_idx)

		src := sao_grow(&d.sao_src, len(plane))
		sao_plane(d, plane, stride, c_idx, src, any_no_filter)
	}
}

sao_enabled :: proc(d: ^Ctu_Decoder($Sample), ctb, c_idx: int) -> bool #no_bounds_check {
	if d.grids.sao[ctb][c_idx].type_idx == SAO_OFF do return false
	// The slice holding the coding tree block decides, not the picture's first.
	f := &d.grids.slice_filters[d.grids.ctb_slice_addr[ctb]]
	return c_idx == 0 ? f.sao_luma : f.sao_chroma
}

sao_next :: #force_inline proc(x, sw, u, ihi: int) -> int #no_bounds_check {
	return min((((x * sw) >> uint(u)) + 1) << uint(u) / sw, ihi)
}

sao_plane :: proc(
	d: ^Ctu_Decoder($Sample),
	plane: []Sample,
	stride, c_idx: int,
	src: []Sample,
	any_no_filter: bool,
) #no_bounds_check {
	sw, sh := 1, 1
	if c_idx > 0 do sw, sh = d.s.sub_width_c, d.s.sub_height_c

	w, h := d.pic.width / sw, d.pic.height / sh
	if w == 0 || h == 0 do return

	bit_depth := int(d.s.bit_depth_luma)
	if c_idx > 0 do bit_depth = int(d.s.bit_depth_chroma)

	max_v := i32(1) << uint(bit_depth) - 1
	shift := bit_depth - 5

	ctb_w := int(d.s.ctb_size_y) / sw
	ctb_h := int(d.s.ctb_size_y) / sh

	pic_w := int(d.s.pic_width_in_ctbs)

	// 8.7.3 reads the picture as deblocking left it, so the rows that filter
	// are copied first, with one row of margin for the classes reaching across.
	lo, hi := len(d.grids.sao), -1

	for ctb in 0 ..< len(d.grids.sao) {
		if !sao_enabled(d, ctb, c_idx) do continue

		lo, hi = min(lo, ctb / pic_w), max(hi, ctb / pic_w)
	}

	if hi < 0 do return

	from := max(lo * ctb_h - 1, 0) * stride
	to := min(min((hi + 1) * ctb_h + 1, h) * stride, len(plane))

	copy(src[from:to], plane[from:to])

	for ctb in 0 ..< len(d.grids.sao) {
		if !sao_enabled(d, ctb, c_idx) do continue

		p := &d.grids.sao[ctb][c_idx]
		band := p.type_idx == SAO_BAND
		a, b := SAO_EO_OFFSETS[p.class][0], SAO_EO_OFFSETS[p.class][1]
		ctb_lo := [2]int{ctb % pic_w * ctb_w, ctb / pic_w * ctb_h}
		ctb_hi := [2]int{min(ctb_lo.x + ctb_w, w), min(ctb_lo.y + ctb_h, h)}

		// An edge class leaves a sample unmodified when either neighbour is
		// outside the picture, so its region is clipped to the picture.
		lo, hi := ctb_lo, ctb_hi
		if !band {
			lo = {max(lo.x, -min(a.x, b.x)), max(lo.y, -min(a.y, b.y))}
			hi = {min(hi.x, w - max(a.x, b.x)), min(hi.y, h - max(a.y, b.y))}
		}
		admitted := sao_admission(d, ctb_lo * {sw, sh}, a, b, band)
		rows := Sao_Rows(Sample) {
			plane  = plane,
			src    = src,
			stride = stride,
			a      = a.y * stride + a.x,
			b      = b.y * stride + b.x,
			p      = p,
			shift  = shift,
			max_v  = max_v,
		}
		segments := [3][2]int {
			{lo.x, ctb_lo.x + 1},
			{ctb_lo.x + 1, ctb_hi.x - 1},
			{ctb_hi.x - 1, hi.x},
		}

		for y in lo.y ..< hi.y {
			// Only a CTB's first and last rows and columns reach a neighbour,
			// so a row splits into its first column, interior and last column.
			// Adjacent admitted segments run together.
			row := admitted[sao_part(y, ctb_lo.y, ctb_hi.y)]
			if row == {true, true, true} {
				sao_apply_run(d, &rows, y, lo.x, hi.x, {sw, sh}, any_no_filter)
				continue
			}
			run := lo.x
			for segment, part in segments {
				x0, x1 := max(segment[0], lo.x), min(segment[1], hi.x)
				if x1 <= x0 || row[part] do continue
				sao_apply_run(d, &rows, y, run, x0, {sw, sh}, any_no_filter)
				run = x1
			}
			sao_apply_run(d, &rows, y, run, hi.x, {sw, sh}, any_no_filter)
		}
	}
}

// The parameters SAO applies along the rows of one CTB: the picture plane, its
// deblocked snapshot, and the index offsets of the class neighbours.
@(private)
Sao_Rows :: struct($Sample: typeid) {
	plane, src:   []Sample,
	stride, a, b: int,
	p:            ^Sao_Params,
	shift:        int,
	max_v:        i32,
}

// sao_admission says, for the samples in each part of a CTB (first, interior
// and last row, by first, interior and last column), whether 8.7.3 lets
// both class neighbours `a` and `b` be read. A neighbour in another CTB is
// read only where filtering may cross into it; band offsets read none.
@(private)
sao_admission :: proc(
	d: ^Ctu_Decoder($Sample),
	at: [2]int,
	a, b: [2]int,
	band: bool,
) -> (
	admitted: [3][3]bool,
) {
	size := int(d.s.ctb_size_y)
	open: [3][3]bool
	for dy in 0 ..< 3 do for dx in 0 ..< 3 {
		n := at + size * [2]int{dx - 1, dy - 1}
		inside := n.x >= 0 && n.y >= 0 && n.x < int(d.s.pic_width_in_luma_samples) && n.y < int(d.s.pic_height_in_luma_samples)
		open[dy][dx] = band || !inside || filter_edge(d, at.x, at.y, n.x, n.y)
	}
	// The neighbouring CTB a part's samples reach along one axis: a first
	// row or column reaches back, a last one forward, an interior one stays.
	reach :: proc(part, step: int) -> int {
		if part == 0 && step < 0 do return 0
		if part == 2 && step > 0 do return 2
		return 1
	}
	for row in 0 ..< 3 do for column in 0 ..< 3 {
		admitted[row][column] = open[reach(row, a.y)][reach(column, a.x)] && open[reach(row, b.y)][reach(column, b.x)]
	}
	return
}

// sao_part is which part of a CTB a coordinate falls in along one axis:
// 0 the first, 2 the last, 1 between.
@(private)
sao_part :: #force_inline proc(v, lo, hi: int) -> int {
	return v == lo ? 0 : v == hi - 1 ? 2 : 1
}

// sao_apply_run filters samples [x0, x1) of row y, skipping min-TBs that
// 8.7.3 leaves unfiltered (transform bypass, or PCM with filtering off).
@(private)
sao_apply_run :: proc(
	d: ^Ctu_Decoder($Sample),
	r: ^Sao_Rows(Sample),
	y, x0, x1: int,
	sub: [2]int,
	any_no_filter: bool,
) #no_bounds_check {
	o := y * r.stride
	if !any_no_filter {
		if x1 > x0 do sao_run(r.plane, r.src, o + x0, x1 - x0, r.a, r.b, r.p, r.shift, r.max_v)
		return
	}
	for x := x0; x < x1; {
		filtered := !d.grids.no_filter[tb_index(d, x * sub.x, y * sub.y)]
		end := x
		for end < x1 && filtered != d.grids.no_filter[tb_index(d, end * sub.x, y * sub.y)] {
			end = sao_next(end, sub.x, d.grids.min_tb_log2, x1)
		}
		if filtered do sao_run(r.plane, r.src, o + x, end - x, r.a, r.b, r.p, r.shift, r.max_v)
		x = end
	}
}

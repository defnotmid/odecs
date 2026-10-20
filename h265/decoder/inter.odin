package h265_decoder

// ---------------------------------------------------------------------------
// Inter prediction syntax and motion compensation (7.3.8.6, 8.5.3), ported
// from gen2brain/h265 hevc/inter.go (MIT); oxideav-h265 src/inter_recon.rs and
// src/decode.rs are the per-file cross-references. The 4:2:0 path
// handles every bit depth through the 16-bit sample planes.
// ---------------------------------------------------------------------------

mv_index :: #force_inline proc(d: ^Ctu_Decoder($Sample), x, y: int) -> int {
	return (y >> 2) * d.grids.mv_width + x >> 2
}

// available_pb is 6.4.2. A neighbour inside the current coding block is
// available without consulting the z-scan order of 6.4.1, apart from the one
// partition the clause excludes.
available_pb :: proc(d: ^Ctu_Decoder($Sample), x_n, y_n: int) -> bool {
	if x_n < 0 ||
	   y_n < 0 ||
	   x_n >= int(d.s.pic_width_in_luma_samples) ||
	   y_n >= int(d.s.pic_height_in_luma_samples) {
		return false
	}

	same_cb :=
		x_n >= d.cu_x && x_n < d.cu_x + d.cu_size && y_n >= d.cu_y && y_n < d.cu_y + d.cu_size

	if !same_cb do return available(d, d.cur_x, d.cur_y, x_n, y_n)

	return(
		!(d.pu_w * 2 == d.cu_size &&
			d.pu_h * 2 == d.cu_size &&
			d.part_idx == 1 &&
			d.cu_y + d.pu_h <= y_n &&
			d.cu_x + d.pu_w > x_n) \
	)
}

// set_mv records the motion of a prediction unit and the pictures its reference
// indices name, which 8.5.3.2.8 reads back from a later picture.
set_mv :: proc(d: ^Ctu_Decoder($Sample), x, y, w, h: int, m: Mv_Info) #no_bounds_check {
	poc: [2]i32
	long: [2]bool

	for l in 0 ..< 2 {
		if m.pred[l] && int(m.ref_idx[l]) >= 0 && int(m.ref_idx[l]) < len(d.ref_poc[l]) {
			poc[l] = d.ref_poc[l][m.ref_idx[l]]
			long[l] = d.ref_long[l][m.ref_idx[l]]
		}
	}

	nw, nh := blocks_in(d, x, y, w, h, 2)

	for j in 0 ..< nh {
		k := (y >> 2 + j) * d.grids.mv_width + x >> 2

		for i in 0 ..< nw {
			d.grids.motion[k + i] = {m, poc, long}
		}
	}
}

// mvd_coding is 7.3.8.9.
mvd_coding :: proc(d: ^Ctu_Decoder($Sample)) -> Mv {
	g0x := cabac_decode_bin(&d.c, ctxAbsMVDGreater0Flag) != 0
	g0y := cabac_decode_bin(&d.c, ctxAbsMVDGreater0Flag) != 0

	g1x, g1y := false, false

	if g0x do g1x = cabac_decode_bin(&d.c, ctxAbsMVDGreater1Flag + 1) != 0
	if g0y do g1y = cabac_decode_bin(&d.c, ctxAbsMVDGreater1Flag + 1) != 0

	comp :: proc(d: ^Ctu_Decoder($Sample), g0, g1: bool) -> i16 {
		if !g0 do return 0

		v := i32(1)
		if g1 do v = exp_golomb_bypass(d, 1) + 2

		if cabac_decode_bypass(&d.c) != 0 do v = -v

		return i16(v)
	}

	return Mv{comp(d, g0x, g1x), comp(d, g0y, g1y)}
}

// exp_golomb_bypass reads a bypass-coded order-k exponential Golomb value.
exp_golomb_bypass :: proc(d: ^Ctu_Decoder($Sample), k: int) -> i32 {
	n := 0
	for cabac_decode_bypass(&d.c) != 0 {
		n += 1
		if n > 30 do return 0
	}

	v := i32(0)
	for _ in 0 ..< n + k {
		v = v << 1 | i32(cabac_decode_bypass(&d.c))
	}

	if n == 0 do return v

	return v + i32((1 << uint(n + k)) - (1 << uint(k)))
}

ref_idx :: proc(d: ^Ctu_Decoder($Sample), num_active: int) -> i8 {
	if num_active <= 1 do return 0

	v := 0

	for v < num_active - 1 {
		bit: u32

		if v < 2 {
			bit = cabac_decode_bin(&d.c, ctxRefIDXL0 + v)
		} else {
			bit = cabac_decode_bypass(&d.c)
		}

		if bit == 0 do break

		v += 1
	}

	return i8(v)
}

// inter_pred_idc is the binarization of 9.3.3.9.
inter_pred_idc :: proc(d: ^Ctu_Decoder($Sample), n_pb_w, n_pb_h, depth: int) -> int {
	if n_pb_w + n_pb_h != 12 {
		if cabac_decode_bin(&d.c, ctxInterPredIDC + depth) != 0 do return PRED_BI
	}

	return int(cabac_decode_bin(&d.c, ctxInterPredIDC + 4))
}

// prediction_unit is 7.3.8.6 followed by the motion compensation of 8.5.3.
prediction_unit :: proc(
	d: ^Ctu_Decoder($Sample),
	x, y, w, h, part_idx, part_mode, depth, n_cb_s, x_cb, y_cb: int,
	skip: bool,
) -> bool #no_bounds_check {
	d.cur_x, d.cur_y = x, y
	d.cu_x, d.cu_y, d.cu_size = x_cb, y_cb, n_cb_s
	d.pu_w, d.pu_h, d.part_idx = w, h, part_idx

	// 8.5.3.2.2: inside a parallel merge region a small coding block derives
	// its candidates, its neighbour availability and its temporal candidate as
	// if the whole block were one unit.
	mx, my, mw, mh, m_idx := x, y, w, h, part_idx
	if int(d.p.log2_parallel_merge_level) > 2 && n_cb_s == 8 {
		mx, my, mw, mh, m_idx = x_cb, y_cb, n_cb_s, n_cb_s, 0
	}

	lists := [2][]i32{d.ref_poc[0], d.ref_poc[1]}

	m: Mv_Info

	merge := skip
	if !skip do merge = cabac_decode_bin(&d.c, ctxMergeFlag) != 0

	if part_idx == 0 do d.last_merge = merge

	if merge {
		idx := 0

		if d.sh.max_num_merge_cand > 1 {
			for idx < int(d.sh.max_num_merge_cand) - 1 {
				bit: u32

				if idx == 0 {
					bit = cabac_decode_bin(&d.c, ctxMergeIDX)
				} else {
					bit = cabac_decode_bypass(&d.c)
				}

				if bit == 0 do break

				idx += 1
			}
		}

		d.cur_x, d.cur_y = mx, my
		d.pu_w, d.pu_h, d.part_idx = mw, mh, m_idx

		n := merge_candidates(
			d,
			mx,
			my,
			mw,
			mh,
			m_idx,
			part_mode,
			int(d.sh.max_num_merge_cand),
			int(d.p.log2_parallel_merge_level),
		)

		d.cur_x, d.cur_y = x, y
		d.pu_w, d.pu_h, d.part_idx = w, h, part_idx

		if n < int(d.sh.max_num_merge_cand) {
			if t, ok := temporal_merge(d, mx, my, mw, mh); ok {
				d.merge_cd[n] = t
				n += 1
			}
		}

		if d.sh.slice_type == .B {
			n = combine_bi_candidates(d, n, int(d.sh.max_num_merge_cand), lists)
		}

		num_ref := int(d.sh.num_ref_idx_l0_active)
		if d.sh.slice_type == .B do num_ref = min(num_ref, int(d.sh.num_ref_idx_l1_active))

		n = zero_candidates(d, n, int(d.sh.max_num_merge_cand), num_ref, d.sh.slice_type == .B)

		if idx >= n do return false

		m = d.merge_cd[idx]

		// 8.5.3.2.1: the smallest prediction units may not be bi-predicted, so
		// a merge candidate that is drops to list zero.
		if w + h == 12 && m.pred[0] && m.pred[1] {
			m.pred[1] = false
			m.mv[1] = {}
		}
	} else {
		idc := PRED_L0
		if d.sh.slice_type == .B do idc = inter_pred_idc(d, w, h, depth)

		for l in 0 ..< 2 {
			if (l == 0 && idc == PRED_L1) || (l == 1 && idc == PRED_L0) do continue

			active := int(d.sh.num_ref_idx_l0_active)
			if l == 1 do active = int(d.sh.num_ref_idx_l1_active)

			ref := ref_idx(d, active)

			mvd: Mv

			if l == 1 && d.sh.mvd_l1_zero && idc == PRED_BI {
				mvd = {}
			} else {
				mvd = mvd_coding(d)
			}

			flag := cabac_decode_bin(&d.c, ctxMVPLXFlag)

			if int(ref) >= len(lists[l]) do return false

			ab, avail := amvp_candidates(
				d,
				x,
				y,
				w,
				h,
				l,
				lists[l][ref],
				d.poc,
				lists,
				d.ref_long,
				d.ref_long[l][ref],
			)

			cand: [2]Mv
			n := 0

			if avail[0] {
				cand[n] = ab[0]
				n += 1
			}

			if avail[1] && !(avail[0] && ab[0] == ab[1]) {
				cand[n] = ab[1]
				n += 1
			}

			if n < 2 {
				if t, ok := temporal_mv(d, x, y, w, h, l, lists[l][ref], d.ref_long[l][ref]); ok {
					cand[n] = t
					n += 1
				}
			}

			p := cand[int(flag)]

			m.mv[l] = Mv{p.x + mvd.x, p.y + mvd.y}
			m.ref_idx[l] = ref
			m.pred[l] = true
		}
	}

	if !m.pred[0] do m.ref_idx[0] = -1
	if !m.pred[1] do m.ref_idx[1] = -1

	set_mv(d, x, y, w, h, m)
	mark_pu(d, x, y, w, h, false)

	return motion_compensate(d, x, y, w, h, &m)
}

motion_compensate :: proc(
	d: ^Ctu_Decoder($Sample),
	x, y, w, h: int,
	m: ^Mv_Info,
) -> bool #no_bounds_check {
	buf: [2][]i16

	for l in 0 ..< 2 {
		if !m.pred[l] do continue

		if int(m.ref_idx[l]) >= len(d.ref_pics[l]) do return false

		// A reference of another storage width (a bit-depth change outside an
		// IRAP picture) cannot be read as this picture's samples.
		ref := d.ref_pics[l][m.ref_idx[l]]
		if ref == nil || ref.sample_size != size_of(Sample) do return false

		buf[l] = d.mc_buf[l][:w * h]

		mv := [2]int{int(m.mv[l].x), int(m.mv[l].y)}
		at := Mc_Block {
			pos  = {x + mv.x >> 2, y + mv.y >> 2},
			frac = mv & 3,
			size = {w, h},
		}
		mc_luma(buf[l], mc_plane(Sample, ref, 0), at, int(d.s.bit_depth_luma), &d.mc)
	}

	if !combine(d, x, y, w, h, 0, buf, m) do return false

	if sps_chroma_array_type(d.s) == 0 do return true

	sw, sh := d.s.sub_width_c, d.s.sub_height_c
	cw, ch := w / sw, h / sh

	if cw == 0 || ch == 0 do return true

	for c_idx in 1 ..= 2 {
		cbuf: [2][]i16

		for l in 0 ..< 2 {
			if !m.pred[l] do continue

			ref := d.ref_pics[l][m.ref_idx[l]]
			cbuf[l] = d.mc_buf[l][:cw * ch]

			// Chroma vectors are in 1/8 samples on a 4:2:0 axis (8.5.3.2.10).
			mv := [2]int{int(m.mv[l].x) * 2 / sw, int(m.mv[l].y) * 2 / sh}
			at := Mc_Block {
				pos  = {x / sw + mv.x >> 3, y / sh + mv.y >> 3},
				frac = mv & 7,
				size = {cw, ch},
			}
			mc_chroma(cbuf[l], mc_plane(Sample, ref, c_idx), at, int(d.s.bit_depth_chroma), &d.mc)
		}

		if !combine(d, x / sw, y / sh, cw, ch, c_idx, cbuf, m) do return false
	}

	return true
}

weighted :: #force_inline proc(d: ^Ctu_Decoder($Sample)) -> bool {
	return(
		(d.p.weighted_pred && d.sh.slice_type == .P) ||
		(d.p.weighted_bipred && d.sh.slice_type == .B) \
	)
}

// combine is 8.5.3.3.4: the 14-bit predictions of one or both lists become
// the block's samples, by the default or the explicitly weighted process.
combine :: proc(
	d: ^Ctu_Decoder($Sample),
	x, y, w, h, c_idx: int,
	buf: [2][]i16,
	m: ^Mv_Info,
) -> bool {
	if !m.pred[0] && !m.pred[1] do return false
	plane, stride := plane_at(Sample, d.pic, c_idx)
	bit_depth := int(c_idx == 0 ? d.s.bit_depth_luma : d.s.bit_depth_chroma)
	pw := prediction_weights(d, c_idx, m, bit_depth)
	max_v := i32(1) << uint(bit_depth) - 1
	at := y * stride + x
	if m.pred[0] && m.pred[1] {
		weigh_rows(true, plane, at, stride, buf[0], buf[1], {w, h}, pw, max_v)
	} else {
		a := m.pred[0] ? buf[0] : buf[1]
		weigh_rows(false, plane, at, stride, a, a, {w, h}, pw, max_v)
	}
	return true
}

// Prediction_Weights turns 14-bit predictions a and b into samples
// clip((a * w0 + b * w1 + round) >> shift + offset). 8.5.3.3.4.2's default
// process is the unit-weight case of 8.5.3.3.4.3's explicit one.
Prediction_Weights :: struct {
	w0, w1, round, offset: i32,
	shift:                 u32,
}

// prediction_weights selects the default weights, or the slice's explicit
// ones, for one component of a block.
prediction_weights :: proc(
	d: ^Ctu_Decoder($Sample),
	c_idx: int,
	m: ^Mv_Info,
	bit_depth: int,
) -> Prediction_Weights {
	shift1 := u32(max(2, 14 - bit_depth))
	bi := m.pred[0] && m.pred[1]
	if !weighted(d) {
		if bi do return {w0 = 1, w1 = 1, round = 1 << shift1, shift = shift1 + 1}
		return {w0 = 1, round = 1 << (shift1 - 1), shift = shift1}
	}

	t := &d.sh.weights
	weight, offset: [2]i32
	for l in 0 ..< 2 {
		if !m.pred[l] do continue
		r := m.ref_idx[l]
		if c_idx == 0 {
			weight[l], offset[l] = i32(t.luma_weight[l][r]), i32(t.luma_offset[l][r])
		} else {
			weight[l] = i32(t.chroma_weight[l][r][c_idx - 1])
			offset[l] = i32(t.chroma_offset[l][r][c_idx - 1])
		}
		if !d.s.high_precision_offsets do offset[l] <<= uint(bit_depth - 8)
	}
	// shift1 >= 2, so log2WD is always at least 2.
	log2_wd := u32(c_idx == 0 ? t.luma_log2_denom : t.chroma_log2_denom) + shift1
	if bi {
		round := (offset[0] + offset[1] + 1) << log2_wd
		return {w0 = weight[0], w1 = weight[1], round = round, shift = log2_wd + 1}
	}
	l := m.pred[0] ? 0 : 1
	return {w0 = weight[l], round = 1 << (log2_wd - 1), shift = log2_wd, offset = offset[l]}
}

// store_col_motion subsamples the picture's motion field to the 16x16 grid the
// temporal predictor reads, recording reference pictures by POC.
store_col_motion :: proc(d: ^Ctu_Decoder($Sample)) {
	for y := 0; y < int(d.s.pic_height_in_luma_samples); y += 16 {
		for x := 0; x < int(d.s.pic_width_in_luma_samples); x += 16 {
			c := &d.pic.col_motion[col_index(d.pic, x, y)]

			// Each record is written whole: retained backing holds an
			// earlier picture's values.
			k := blk_index(d, x, y)
			if d.grids.blk[k].intra {
				c^ = {
					intra = true,
				}
				continue
			}

			m := &d.grids.motion[k]
			c^ = {
				info     = m.info,
				ref_poc  = m.poc,
				ref_long = m.long,
			}
		}
	}
}

// temporal_mv is 8.5.3.2.8 and 8.5.3.2.9: the collocated block at the
// bottom-right of the prediction unit, falling back to its centre.
temporal_mv :: proc(
	d: ^Ctu_Decoder($Sample),
	x_pb, y_pb, n_pb_w, n_pb_h, list: int,
	ref_poc: i32,
	ref_long: bool,
) -> (
	Mv,
	bool,
) {
	if !d.sh.temporal_mvp || d.col_pic == nil do return {}, false

	col := d.col_pic

	// 8.5.3.2.9, which the caller falls back from when it yields nothing.
	derive :: proc(
		d: ^Ctu_Decoder($Sample),
		col: ^Picture,
		c: ^Col_Motion,
		list: int,
		ref_poc: i32,
		ref_long: bool,
	) -> (
		Mv,
		bool,
	) {
		l := 0

		switch {
		case !c.info.pred[0]:
			l = 1
		case !c.info.pred[1]:
			l = 0
		case d.no_backward_pred:
			l = list
		case d.sh.collocated_from_l0:
			l = 1
		case:
			l = 0
		}

		if !c.info.pred[l] do return {}, false

		// The collocated reference must match the target in long term status,
		// and a long term one is never scaled.
		if c.ref_long[l] != ref_long do return {}, false

		if c.ref_poc[l] == d.poc || ref_poc == d.poc do return {}, false

		if ref_long || i32(col.poc) - c.ref_poc[l] == d.poc - ref_poc {
			return c.info.mv[l], true
		}

		return scale_mv(c.info.mv[l], d.poc, ref_poc, i32(col.poc), c.ref_poc[l]), true
	}

	try :: proc(col: ^Picture, x, y: int) -> (^Col_Motion, bool) {
		if x < 0 || y < 0 || x >= col.width || y >= col.height do return nil, false

		c := &col.col_motion[col_index(col, x, y)]
		if c.intra do return nil, false

		return c, true
	}

	// The bottom-right candidate is unavailable outside the picture or past the
	// coding tree row, and the centre takes over whenever it yields nothing.
	if c, ok := try(col, x_pb + n_pb_w, y_pb + n_pb_h);
	   ok && y_pb >> uint(d.s.ctb_log2_size_y) == (y_pb + n_pb_h) >> uint(d.s.ctb_log2_size_y) {
		if v, ok2 := derive(d, col, c, list, ref_poc, ref_long); ok2 do return v, true
	}

	c, ok := try(col, x_pb + n_pb_w / 2, y_pb + n_pb_h / 2)
	if !ok do return {}, false

	return derive(d, col, c, list, ref_poc, ref_long)
}

// temporal_merge builds the temporal merge candidate, which uses reference
// index zero in each list the slice has.
temporal_merge :: proc(d: ^Ctu_Decoder($Sample), x, y, w, h: int) -> (Mv_Info, bool) {
	m: Mv_Info

	m.ref_idx = [2]i8{-1, -1}

	for l in 0 ..< 2 {
		if l == 1 && d.sh.slice_type != .B do continue
		if len(d.ref_poc[l]) == 0 do continue

		v, ok := temporal_mv(d, x, y, w, h, l, d.ref_poc[l][0], d.ref_long[l][0])
		if !ok do continue

		m.mv[l] = v
		m.ref_idx[l] = 0
		m.pred[l] = true
	}

	return m, m.pred[0] || m.pred[1]
}

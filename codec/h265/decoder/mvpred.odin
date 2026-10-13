package h265_decoder

// ---------------------------------------------------------------------------
// Motion vector prediction: merge and AMVP candidates (8.5.3.2), ported from
// gen2brain/h265 hevc/mvpred.go (MIT); oxideav-h265 src/pu_mv.rs is the
// per-file cross-reference.
// ---------------------------------------------------------------------------

Mv :: struct {
	x, y: i16,
}

// Mv_Info records the motion of one prediction unit and which lists it uses.
Mv_Info :: struct {
	mv:      [2]Mv,
	ref_idx: [2]i8,
	pred:    [2]bool,
}

// Motion is the per-4x4 motion record. It is written once by set_mv and read
// together by store_col_motion and different_motion, so the fields travel as
// one record rather than three parallel grid arrays.
Motion :: struct {
	info: Mv_Info,
	poc:  [2]i32,
	long: [2]bool,
}

same_motion :: #force_inline proc(a, b: ^Mv_Info) -> bool {
	return a.pred == b.pred && a.mv == b.mv && a.ref_idx == b.ref_idx
}

// neighbour_mv supplies the motion of an already-decoded block, or reports it
// unavailable. It reads the picture-wide motion field through available_pb.
neighbour_mv :: proc(d: ^Ctu_Decoder($Sample), x, y: int) -> (Mv_Info, bool) {
	if !available_pb(d, x, y) do return {}, false

	i := mv_index(d, x, y)
	if i < 0 || i >= len(d.grids.motion) || d.grids.blk[i].intra do return {}, false

	return d.grids.motion[i].info, true
}

// merge_get is the `get` of 8.5.3.2.2: a neighbour inside the parallel merge
// region is treated as unavailable.
merge_get :: proc(d: ^Ctu_Decoder($Sample), x_pb, y_pb, x_n, y_n, level: int) -> (Mv_Info, bool) {
	if x_pb >> uint(level) == x_n >> uint(level) && y_pb >> uint(level) == y_n >> uint(level) {
		return {}, false
	}

	return neighbour_mv(d, x_n, y_n)
}

// merge_candidates is the spatial part of 8.5.3.2.2 and 8.5.3.2.3: A1, B1, B0,
// A0 and B2 in that order, with the pruning comparisons the clause specifies
// and the partition rules that stop a 2NxN or Nx2N unit from collapsing onto
// its sibling. Candidates are written into d.merge_cd and the count returned.
merge_candidates :: proc(
	d: ^Ctu_Decoder($Sample),
	x_pb, y_pb, n_pb_w, n_pb_h, part_idx, part_mode, max_cand, par_mrg_level: int,
) -> int {
	out := d.merge_cd[:]
	n := 0

	// A partition rule that excludes A1 or B1 also removes it from the pruning
	// comparisons; being pruned as a duplicate does not.
	a1, avail_a1 := merge_get(d, x_pb, y_pb, x_pb - 1, y_pb + n_pb_h - 1, par_mrg_level)
	if part_idx == 1 &&
	   (part_mode == PART_NX2N || part_mode == PART_NLX2N || part_mode == PART_NRX2N) {
		avail_a1 = false
	}

	if avail_a1 {
		out[n] = a1
		n += 1
	}

	b1, avail_b1 := merge_get(d, x_pb, y_pb, x_pb + n_pb_w - 1, y_pb - 1, par_mrg_level)
	if part_idx == 1 &&
	   (part_mode == PART_2NXN || part_mode == PART_2NXNU || part_mode == PART_2NXND) {
		avail_b1 = false
	}

	if avail_b1 && !(avail_a1 && same_motion(&a1, &b1)) {
		out[n] = b1
		n += 1
	}

	if b0, ok := merge_get(d, x_pb, y_pb, x_pb + n_pb_w, y_pb - 1, par_mrg_level);
	   ok && !(avail_b1 && same_motion(&b1, &b0)) {
		out[n] = b0
		n += 1
	}

	if a0, ok := merge_get(d, x_pb, y_pb, x_pb - 1, y_pb + n_pb_h, par_mrg_level);
	   ok && !(avail_a1 && same_motion(&a1, &a0)) {
		out[n] = a0
		n += 1
	}

	if n < 4 {
		if b2, ok := merge_get(d, x_pb, y_pb, x_pb - 1, y_pb - 1, par_mrg_level);
		   ok && !(avail_a1 && same_motion(&a1, &b2)) && !(avail_b1 && same_motion(&b1, &b2)) {
			out[n] = b2
			n += 1
		}
	}

	return min(n, max_cand)
}

// combine_bi_candidates is 8.5.3.2.4, which pairs the L0 of one candidate with
// the L1 of another until the list is full. It applies to B slices only.
combine_bi_candidates :: proc(d: ^Ctu_Decoder($Sample), n, max_cand: int, lists: [2][]i32) -> int {
	// Table 8-6, the order the pairs are tried in.
	l0_idx := [12]int{0, 1, 0, 2, 1, 2, 0, 3, 1, 3, 2, 3}
	l1_idx := [12]int{1, 0, 2, 0, 2, 1, 3, 0, 3, 1, 3, 2}

	out := d.merge_cd[:]
	orig := n
	if orig < 2 do return n

	count := n

	for k := 0; k < orig * (orig - 1) && count < max_cand; k += 1 {
		if k >= len(l0_idx) do break

		a, b := &out[l0_idx[k]], &out[l1_idx[k]]

		if !a.pred[0] || !b.pred[1] do continue
		if int(a.ref_idx[0]) >= len(lists[0]) || int(b.ref_idx[1]) >= len(lists[1]) do continue

		if lists[0][a.ref_idx[0]] == lists[1][b.ref_idx[1]] && a.mv[0] == b.mv[1] do continue

		out[count] = Mv_Info {
			mv      = [2]Mv{a.mv[0], b.mv[1]},
			ref_idx = [2]i8{a.ref_idx[0], b.ref_idx[1]},
			pred    = [2]bool{true, true},
		}
		count += 1
	}

	return count
}

// zero_candidates is 8.5.3.2.5, the zero-motion fill that guarantees the list
// reaches its full length.
zero_candidates :: proc(
	d: ^Ctu_Decoder($Sample),
	n, max_cand, num_ref_idx: int,
	bi_pred: bool,
) -> int {
	out := d.merge_cd[:]

	count := n

	for i := 0; count < max_cand; i += 1 {
		r := i8(0)
		if i < num_ref_idx do r = i8(i)

		c := Mv_Info {
			ref_idx = [2]i8{r, r},
			pred    = [2]bool{true, bi_pred},
		}
		if !bi_pred do c.ref_idx[1] = -1

		out[count] = c
		count += 1
	}

	return count
}

// scale_mv is the temporal distance scaling of 8.5.3.2.8, shared by the
// temporal merge candidate and the spatial predictors that cross references.
scale_mv :: proc(v: Mv, curr_poc, ref_poc, col_poc, col_ref_poc: i32) -> Mv {
	td := clip3(col_poc - col_ref_poc, -128, 127)
	tb := clip3(curr_poc - ref_poc, -128, 127)

	if td == 0 do return v

	tx := (16384 + abs_i32(td) / 2) / td
	scale := clip3((tb * tx + 32) >> 6, -4096, 4095)

	sx := scale * i32(v.x)
	sy := scale * i32(v.y)

	return Mv {
		x = i16(clip3(sign_i32(sx) * ((abs_i32(sx) + 127) >> 8), -32768, 32767)),
		y = i16(clip3(sign_i32(sy) * ((abs_i32(sy) + 127) >> 8), -32768, 32767)),
	}
}

sign_i32 :: #force_inline proc(v: i32) -> i32 {
	switch {
	case v < 0:
		return -1
	case v > 0:
		return 1
	}

	return 0
}

PRED_L0 :: 0
PRED_L1 :: 1
PRED_BI :: 2

amvp_direct :: proc(m: ^Mv_Info, list: int, ref_poc: i32, lists: [2][]i32) -> (Mv, bool) {
	for k in 0 ..< 2 {
		l := list ~ k

		if m.pred[l] &&
		   int(m.ref_idx[l]) >= 0 &&
		   int(m.ref_idx[l]) < len(lists[l]) &&
		   lists[l][m.ref_idx[l]] == ref_poc {
			return m.mv[l], true
		}
	}

	return {}, false
}

// amvp_scaled is the scaling branch of 8.5.3.2.7: a neighbour is taken only
// when its reference matches the target in long term status, and a long term
// vector is never scaled.
amvp_scaled :: proc(
	m: ^Mv_Info,
	list: int,
	ref_poc, curr_poc: i32,
	lists: [2][]i32,
	long: [2][]bool,
	ref_long: bool,
) -> (
	Mv,
	bool,
) {
	for k in 0 ..< 2 {
		l := list ~ k

		if !m.pred[l] || int(m.ref_idx[l]) < 0 || int(m.ref_idx[l]) >= len(lists[l]) do continue
		if long[l][m.ref_idx[l]] != ref_long do continue

		if ref_long do return m.mv[l], true

		return scale_mv(m.mv[l], curr_poc, ref_poc, curr_poc, lists[l][m.ref_idx[l]]), true
	}

	return {}, false
}

amvp_sweep :: proc(
	d: ^Ctu_Decoder($Sample),
	pos: [][2]int,
	list: int,
	ref_poc, curr_poc: i32,
	lists: [2][]i32,
	long: [2][]bool,
	ref_long, scale: bool,
) -> (
	Mv,
	bool,
) {
	for p in pos {
		m, ok := neighbour_mv(d, p[0], p[1])
		if !ok do continue

		v: Mv
		found: bool

		if scale {
			v, found = amvp_scaled(&m, list, ref_poc, curr_poc, lists, long, ref_long)
		} else {
			v, found = amvp_direct(&m, list, ref_poc, lists)
		}

		if found do return v, true
	}

	return {}, false
}

// amvp_candidates is 8.5.3.2.7. It reports the left and above predictors and
// whether each was found, leaving 8.5.3.2.6 to assemble the list.
amvp_candidates :: proc(
	d: ^Ctu_Decoder($Sample),
	x_pb, y_pb, n_pb_w, n_pb_h, list: int,
	ref_poc, curr_poc: i32,
	lists: [2][]i32,
	long: [2][]bool,
	ref_long: bool,
) -> (
	out: [2]Mv,
	avail: [2]bool,
) {
	left := [2][2]int{{x_pb - 1, y_pb + n_pb_h}, {x_pb - 1, y_pb + n_pb_h - 1}}
	above := [3][2]int {
		{x_pb + n_pb_w, y_pb - 1},
		{x_pb + n_pb_w - 1, y_pb - 1},
		{x_pb - 1, y_pb - 1},
	}

	is_scaled := false

	for p in left {
		if _, ok := neighbour_mv(d, p[0], p[1]); ok do is_scaled = true
	}

	out[0], avail[0] = amvp_sweep(
		d,
		left[:],
		list,
		ref_poc,
		curr_poc,
		lists,
		long,
		ref_long,
		false,
	)
	if !avail[0] {
		out[0], avail[0] = amvp_sweep(
			d,
			left[:],
			list,
			ref_poc,
			curr_poc,
			lists,
			long,
			ref_long,
			true,
		)
	}

	out[1], avail[1] = amvp_sweep(
		d,
		above[:],
		list,
		ref_poc,
		curr_poc,
		lists,
		long,
		ref_long,
		false,
	)

	// With no left neighbour at all the above predictor becomes the first
	// candidate and the second is derived again, this time with scaling.
	if !is_scaled {
		out[0], avail[0] = out[1], avail[1]
		out[1], avail[1] = amvp_sweep(
			d,
			above[:],
			list,
			ref_poc,
			curr_poc,
			lists,
			long,
			ref_long,
			true,
		)
	}

	return out, avail
}

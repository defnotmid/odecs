package h265_encoder

import common "../../common"
import "core:math"

// ---------------------------------------------------------------------------
// Explicit weighted prediction (7.3.6.3, 8.5.3.3.4.3). The encoder fits one
// scale and offset per reference list entry over the whole visible picture
// against the source, signals the table in the slice header and applies it in
// every inter prediction path. With the PPS flags clear (the default) no table
// is written and every resolved weight is the inferred (2^denom, 0) pair, so
// prediction is bit-identical to the unweighted process.
// ---------------------------------------------------------------------------

// The inferred weights the decoder uses when a reference's flag is zero.
WP_LUMA_DENOM :: 5

// Approximate signalling cost of one luma or chroma weight set, in bits: the
// flag plus the coded weight and offset deltas. Used only to decide whether a
// fit's distortion improvement pays for the syntax.
WP_LUMA_BITS :: 16
WP_CHROMA_BITS :: 40

// A fit has to remove this fraction of the reference's co-located distortion
// to be signalled. Small frame-level fits are dominated by motion and codec
// noise and do not survive the actual per-CU motion compensation; fades and
// flashes clear it by orders of magnitude.
WP_MIN_GAIN :: 0.05

// One plane's resolved weighted-prediction parameters for a list and reference
// index. `log2_wd` is the decoder's luma/chroma log2Wd: the denominator plus
// shift1 (6 for 8-bit samples, 4 for 10-bit). `max_v` bounds the combined
// sample.
Wp_Plane :: struct {
	weight:  i32,
	offset:  i32,
	denom:   i32,
	shift1:  i32,
	log2_wd: i32,
	max_v:   i32,
}

wp_is_default :: #force_inline proc(p: Wp_Plane) -> bool {
	return p.offset == 0 && p.weight == (i32(1) << uint(p.denom))
}

// The per-slice table, mirroring the decoder's Pred_Weight_Table plus the
// per-reference flags needed to write it.
Pred_Weights :: struct {
	present:           bool,
	luma_log2_denom:   u8,
	chroma_log2_denom: u8,
	luma_flag:         [2][MAX_REF_PICS]bool,
	chroma_flag:       [2][MAX_REF_PICS]bool,
	luma_weight:       [2][MAX_REF_PICS]i16,
	luma_offset:       [2][MAX_REF_PICS]i16,
	chroma_weight:     [2][MAX_REF_PICS][2]i16,
	chroma_offset:     [2][MAX_REF_PICS][2]i16,
}

default_weights :: proc() -> Pred_Weights {
	w: Pred_Weights
	w.luma_log2_denom = WP_LUMA_DENOM
	w.chroma_log2_denom = WP_LUMA_DENOM
	for l in 0 ..< 2 {
		for r in 0 ..< MAX_REF_PICS {
			w.luma_weight[l][r] = i16(1 << WP_LUMA_DENOM)
			w.chroma_weight[l][r] = {i16(1 << WP_LUMA_DENOM), i16(1 << WP_LUMA_DENOM)}
		}
	}
	return w
}

wp_luma :: #force_inline proc(enc: ^Encoder, l, ref: int) -> Wp_Plane {
	shift1 := i32(max(2, 14 - enc.bit_depth))
	off_shift := uint(enc.bit_depth - 8)
	return {
		weight = i32(enc.wp.luma_weight[l][ref]),
		offset = i32(enc.wp.luma_offset[l][ref]) << off_shift,
		denom = i32(enc.wp.luma_log2_denom),
		shift1 = shift1,
		log2_wd = i32(enc.wp.luma_log2_denom) + shift1,
		max_v = i32(1) << uint(enc.bit_depth) - 1,
	}
}

wp_chroma :: #force_inline proc(enc: ^Encoder, l, ref, plane: int) -> Wp_Plane {
	shift1 := i32(max(2, 14 - enc.bit_depth))
	off_shift := uint(enc.bit_depth - 8)
	return {
		weight = i32(enc.wp.chroma_weight[l][ref][plane]),
		offset = i32(enc.wp.chroma_offset[l][ref][plane]) << off_shift,
		denom = i32(enc.wp.chroma_log2_denom),
		shift1 = shift1,
		log2_wd = i32(enc.wp.chroma_log2_denom) + shift1,
		max_v = i32(1) << uint(enc.bit_depth) - 1,
	}
}

// ---------------------------------------------------------------------------
// Weight fit
// ---------------------------------------------------------------------------

// fit_plane fits pred = (x * weight + round) >> log2Wd + offset to the visible
// samples of one plane and measures the resulting distortion. The scale is the
// ratio of the plane means and the offset the residual mean difference. A
// least-squares slope would fit the *displacement* of moving content, not the
// illumination, and a deliberately overfitted slope plus its compensating
// offset wrecks the prediction under motion; the means are robust to it and
// track the fades this tool exists for. `ok` is false when the fit is
// degenerate or outside the sane weight range.
@(private)
fit_plane :: proc(
	src, ref: Plane(Sample),
	w, h: int,
	denom: i32,
	bit_depth: int,
) -> (
	wq, off: i32,
	sse_on, sse_off: u64,
	ok: bool,
) {
	if w <= 0 || h <= 0 do return

	n := i64(w * h)
	sx, sy: i64
	for j in 0 ..< h {
		for i in 0 ..< w {
			sx += i64(at(ref, i, j))
			sy += i64(at(src, i, j))
		}
	}
	if sx <= 0 do return

	b := f64(sy) / f64(sx)
	if b <= 0.25 || b >= 3.0 do return

	wq = i32(b * f64(i32(1) << uint(denom)) + 0.5)

	// The decoder's weighted combine runs on the 14-bit interpolation
	// intermediate (sample << 6), so its shift of denom + 6 reduces to a
	// sample-domain divide by 2^denom.
	round := i32(0)
	if denom >= 1 do round = i32(1) << uint(denom - 1)

	sum_q: i64
	for j in 0 ..< h {
		for i in 0 ..< w {
			x := i32(at(ref, i, j))
			q := (x * wq + round) >> uint(denom)
			sum_q += i64(q)
		}
	}

	// 7.4.7.3 signals the offset in the eight-bit domain; the sample-domain
	// offset the process applies is off << (bitDepth - 8).
	off_shift := uint(bit_depth - 8)
	off = i32(math.round(f64(sy - sum_q) / f64(n) / f64(i32(1) << off_shift)))
	if off < -128 || off > 127 do return

	max_v := i32(1) << uint(bit_depth) - 1
	off_applied := off << off_shift

	for j in 0 ..< h {
		for i in 0 ..< w {
			x := i32(at(ref, i, j))
			y := i32(at(src, i, j))
			q := (x * wq + round) >> uint(denom)
			d := y - clamp(q + off_applied, 0, max_v)
			sse_on += u64(d * d)
			e := y - x
			sse_off += u64(e * e)
		}
	}
	ok = true
	return
}

// analyze_weights refits the table for the picture about to be coded. Weights
// are per reference, so each active list entry is fitted independently; the
// picture-level distortion improvement has to cover the flag syntax or the
// reference keeps the inferred defaults.
analyze_weights :: proc(enc: ^Encoder) {
	enc.wp = default_weights()
	if !enc.config.weighted || enc.slice_type == .I do return

	enc.wp.present = true
	denom := i32(enc.wp.luma_log2_denom)
	for l in 0 ..< 2 {
		for r in 0 ..< enc.refs_active[l] {
			wq, off, on, off_dist, ok := fit_plane(
				enc.source.y,
				enc.refs[l][r].y,
				enc.width,
				enc.height,
				denom,
				enc.bit_depth,
			)
			use := ok && f64(on) + enc.lambda * WP_LUMA_BITS < f64(off_dist) * (1 - WP_MIN_GAIN)
			if use {
				enc.wp.luma_flag[l][r] = true
				enc.wp.luma_weight[l][r] = i16(wq)
				enc.wp.luma_offset[l][r] = i16(off)
			}

			if !has_chroma(enc) do continue
			sw, sh := chroma_sub(enc.config.chroma_format)
			cw, ch := enc.width / sw, enc.height / sh
			uw, uo, uon, uoff, uok := fit_plane(
				enc.source.u,
				enc.refs[l][r].u,
				cw,
				ch,
				denom,
				enc.bit_depth,
			)
			vw, vo, von, voff, vok := fit_plane(
				enc.source.v,
				enc.refs[l][r].v,
				cw,
				ch,
				denom,
				enc.bit_depth,
			)

			u_use := uok && f64(uon) + enc.lambda * WP_CHROMA_BITS < f64(uoff) * (1 - WP_MIN_GAIN)
			v_use := vok && f64(von) + enc.lambda * WP_CHROMA_BITS < f64(voff) * (1 - WP_MIN_GAIN)
			if !u_use && !v_use do continue

			enc.wp.chroma_flag[l][r] = true
			if u_use {
				enc.wp.chroma_weight[l][r][0] = i16(uw)
				enc.wp.chroma_offset[l][r][0] = i16(uo)
			}
			if v_use {
				enc.wp.chroma_weight[l][r][1] = i16(vw)
				enc.wp.chroma_offset[l][r][1] = i16(vo)
			}
		}
	}
}

// write_pred_weight_table emits 7.3.6.3 in the decoder's order. The stored
// chroma offset is the sample-domain value the decoder reconstructs, so the
// signalled delta undoes the decoder's folded-in rounding of 8.5.3.3.4.3.
write_pred_weight_table :: proc(enc: ^Encoder, w: ^common.Bit_Writer) {
	wp := &enc.wp
	common.write_ue(w, u32(wp.luma_log2_denom))
	if has_chroma(enc) do common.write_se(w, i32(wp.chroma_log2_denom) - i32(wp.luma_log2_denom))

	lists := enc.slice_type == .B ? 2 : 1
	for l in 0 ..< lists {
		n := enc.refs_active[l]
		for i in 0 ..< n do common.write_bits(w, wp.luma_flag[l][i] ? 1 : 0, 1)
		if has_chroma(enc) do for i in 0 ..< n do common.write_bits(w, wp.chroma_flag[l][i] ? 1 : 0, 1)
		for i in 0 ..< n {
			if wp.luma_flag[l][i] {
				common.write_se(
					w,
					i32(wp.luma_weight[l][i]) - (i32(1) << uint(wp.luma_log2_denom)),
				)
				common.write_se(w, i32(wp.luma_offset[l][i]))
			}
			if wp.chroma_flag[l][i] {
				for j in 0 ..< 2 {
					weight := i32(wp.chroma_weight[l][i][j])
					common.write_se(w, weight - (i32(1) << uint(wp.chroma_log2_denom)))
					// 7.4.7.3, WpOffsetHalfRangeC: eight bits without the
					// high precision extension, which the encoder does not
					// signal.
					half := i32(128)
					d_off :=
						i32(wp.chroma_offset[l][i][j]) +
						((half * weight) >> uint(wp.chroma_log2_denom)) -
						half
					common.write_se(w, d_off)
				}
			}
		}
	}
}

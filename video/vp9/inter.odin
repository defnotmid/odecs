package vp9

import "base:intrinsics"
@(require) import "base:runtime"
@(require) import "core:simd"

// Inter prediction (section 8.5.2): reference sample positions in 1/16
// samples, an 8-tap horizontal pass into a clipped intermediate, then the
// vertical pass. Reference reads clamp to the reference's visible picture.

Ref_Plane :: struct($T: typeid) {
	data:           []T,
	stride:         int,
	last_x, last_y: int, // bottom-right visible sample
}

// Largest block (64) plus the 7 extra filter taps, at the largest step a
// conforming stream uses (32: a reference twice the frame's size).
MAX_STEP :: 32
@(private)
MAX_SOURCE :: ((64 - 1) * MAX_STEP + 15) / 16 + 8

// One block to predict from one reference: where its top-left sample maps in
// the reference in 1/16 samples, the reference step per predicted sample (16
// when the reference has the frame's size), its size and filter, and where
// the clipped samples go. Passed by pointer: as arguments its slices stalled
// on store forwarding at every call.
Inter_Block :: struct($T: typeid) {
	ref:                     ^Ref_Plane(T),
	x, y:                    int,
	step_x, step_y:          int,
	w, h, filter, bit_depth: int,
	dst:                     [^]T,
	dst_stride:              int,
}

predict_inter_block :: proc(b: ^Inter_Block($T)) #no_bounds_check {
	if b.step_x != 16 || b.step_y != 16 {
		predict_scaled(b)
		return
	}
	ref := b.ref
	x, y, w, h := b.x, b.y, b.w, b.h
	max_value := i32(1) << uint(b.bit_depth) - 1
	kernels := &SUBPEL_FILTERS[b.filter]
	cols, rows := w + 7, h + 7
	x0, y0 := (x >> 4) - 3, (y >> 4) - 3
	// Direct reads when the whole footprint is inside the reference.
	src := raw_data(ref.data)
	src_stride := ref.stride
	origin := y0 * ref.stride + x0
	UNSCALED_STRIDE :: 72
	local: [UNSCALED_STRIDE * UNSCALED_STRIDE]T = ---
	if x0 < 0 || y0 < 0 || x0 + cols - 1 > ref.last_x || y0 + rows - 1 > ref.last_y {
		edge_copy(local[:], UNSCALED_STRIDE, ref, x0, y0, cols, rows)
		src, src_stride, origin = raw_data(local[:]), UNSCALED_STRIDE, 0
	}
	// Native-width lanes, as HEVC's motion compensation; narrower blocks
	// take their own width.
	LANES :: max(8, runtime.NATIVE_SIMD_BIT_WIDTH / 32)
	switch {
	case w >= LANES:
		predict_unscaled(b, src, src_stride, origin, kernels, max_value, LANES)
	case w >= 8:
		predict_unscaled(b, src, src_stride, origin, kernels, max_value, 8)
	case:
		predict_unscaled(b, src, src_stride, origin, kernels, max_value, 4)
	}
}

@(private)
predict_scaled :: proc(b: ^Inter_Block($T)) #no_bounds_check {
	ref := b.ref
	x, y, w, h := b.x, b.y, b.w, b.h
	max_value := i32(1) << uint(b.bit_depth) - 1
	kernels := &SUBPEL_FILTERS[b.filter]
	rows := (((h - 1) * b.step_y + 15) >> 4) + 8
	cols := (((w - 1) * b.step_x + 15) >> 4) + 8
	x0, y0 := (x >> 4) - 3, (y >> 4) - 3
	src := raw_data(ref.data)
	src_stride := ref.stride
	origin := y0 * ref.stride + x0
	local: [MAX_SOURCE * MAX_SOURCE]T = ---
	if x0 < 0 || y0 < 0 || x0 + cols - 1 > ref.last_x || y0 + rows - 1 > ref.last_y {
		edge_copy(local[:], MAX_SOURCE, ref, x0, y0, cols, rows)
		src, src_stride, origin = raw_data(local[:]), MAX_SOURCE, 0
	}
	intermediate: [MAX_SOURCE * 64]i32 = ---
	for r in 0 ..< rows {
		line := src[origin + r * src_stride:]
		for c in 0 ..< w {
			p := (x & 15) + b.step_x * c
			k := &kernels[p & 15]
			taps := line[p >> 4:]
			s: i32
			for t in 0 ..< 8 do s += i32(k[t]) * i32(taps[t])
			intermediate[r * 64 + c] = clamp((s + 64) >> 7, 0, max_value)
		}
	}
	for r in 0 ..< h {
		p := (y & 15) + b.step_y * r
		k := &kernels[p & 15]
		base := (p >> 4) * 64
		out := b.dst[r * b.dst_stride:]
		for c in 0 ..< w {
			s: i32
			for t in 0 ..< 8 do s += i32(k[t]) * intermediate[base + t * 64 + c]
			out[c] = T(clamp((s + 64) >> 7, 0, max_value))
		}
	}
}

// The unscaled case: one kernel per direction for the whole block. A zero
// phase is the identity kernel, so that pass is skipped (exactly:
// (128 * s + 64) >> 7 == s). Both passes of a two-axis filter are the same
// filter_pass; the first stores its clipped samples as T.
@(private)
predict_unscaled :: proc(b: ^Inter_Block($T), src: [^]T, stride, origin: int, kernels: ^[16][8]i16, max_value: i32, $N: int) #no_bounds_check {
	fx, fy, w, h := b.x & 15, b.y & 15, b.w, b.h
	dst, dst_stride := b.dst, b.dst_stride
	base := origin + 3 * stride + 3 // the block's own top-left sample
	switch {
	case fx == 0 && fy == 0:
		for r in 0 ..< h do for c := 0; c < w; c += N {
			v := intrinsics.unaligned_load((^#simd[N]T)(&src[base + r * stride + c]))
			intrinsics.unaligned_store((^#simd[N]T)(&dst[r * dst_stride + c]), v)
		}
	case fy == 0:
		filter_pass(dst, dst_stride, src[base - 3:], stride, 1, w, h, &kernels[fx], max_value, N)
	case fx == 0:
		filter_pass(dst, dst_stride, src[base - 3 * stride:], stride, stride, w, h, &kernels[fy], max_value, N)
	case:
		// Horizontal over the h + 7 rows the vertical taps need.
		mid: [(64 + 7) * 64]T = ---
		filter_pass(raw_data(mid[:]), 64, src[origin:], stride, 1, w, h + 7, &kernels[fx], max_value, N)
		filter_pass(dst, dst_stride, raw_data(mid[:]), 64, 64, w, h, &kernels[fy], max_value, N)
	}
}

// One 8-tap pass over a w x h block, N columns at a time: each output is the
// rounded, clipped sum of the eight samples `step` apart from the one at its
// own position in src. Sums stay in i32 lanes: the sharp filters' partial
// sums do not fit i16.
@(private)
filter_pass :: proc(dst: [^]$D, dst_stride: int, src: [^]$S, src_stride, step, w, h: int, k: ^[8]i16, max_value: i32, $N: int) #no_bounds_check {
	V :: #simd[N]i32
	kv: [8]V = ---
	#unroll for t in 0 ..< 8 do kv[t] = V(i32(k[t]))
	zero, hi, round := V(0), V(max_value), V(64)
	shift := (#simd[N]u32)(7)
	for r in 0 ..< h do for c := 0; c < w; c += N {
		at := r * src_stride + c
		acc := round
		#unroll for t in 0 ..< 8 do acc += kv[t] * V(intrinsics.unaligned_load((^#simd[N]S)(&src[at + t * step])))
		v := simd.clamp(simd.shr(acc, shift), zero, hi)
		intrinsics.unaligned_store((^#simd[N]D)(&dst[r * dst_stride + c]), (#simd[N]D)(v))
	}
}

// Compound prediction: the rounded average of both references.
average_into :: proc(dst: []$T, dst_stride: int, other: []T, other_stride, w, h: int) #no_bounds_check {
	W :: #simd[4]u32
	d_ptr, o_ptr := raw_data(dst), raw_data(other)
	for r in 0 ..< h {
		a := d_ptr[r * dst_stride:]
		b := o_ptr[r * other_stride:]
		for c := 0; c < w; c += 4 {
			av := W(intrinsics.unaligned_load((^#simd[4]T)(&a[c])))
			bv := W(intrinsics.unaligned_load((^#simd[4]T)(&b[c])))
			res := (#simd[4]T)(simd.shr(av + bv + W(1), W(1)))
			intrinsics.unaligned_store((^#simd[4]T)(&a[c]), res)
		}
	}
}

// Chroma motion vector for a sub-8x8 block (8.5.2.1).
round_mv_q2 :: #force_inline proc "contextless" (v: i32) -> i32 {return (v < 0 ? v - 1 : v + 1) / 2}
round_mv_q4 :: #force_inline proc "contextless" (v: i32) -> i32 {return (v < 0 ? v - 2 : v + 2) / 4}

// Copies the cols x rows region at (x0, y0) out of a reference plane,
// repeating edge samples where it falls outside, so the filters reading the
// copy need no bounds checks: each row is a left fill, one copy and a right
// fill.
@(private)
edge_copy :: proc(dst: []$T, dst_stride: int, ref: ^Ref_Plane(T), x0, y0, cols, rows: int) #no_bounds_check {
	width := ref.last_x + 1
	lo := clamp(-x0, 0, cols)
	hi := clamp(width - x0, lo, cols)
	for r in 0 ..< rows {
		line := ref.data[clamp(y0 + r, 0, ref.last_y) * ref.stride:]
		out := dst[r * dst_stride:][:cols]
		for &v in out[:lo] do v = line[0]
		copy(out[lo:hi], line[x0 + lo:x0 + hi])
		for &v in out[hi:] do v = line[ref.last_x]
	}
}

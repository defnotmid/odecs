package vp9

import "base:intrinsics"
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

// Predicts a w x h block whose top-left sample maps to (x, y) in 1/16
// reference samples, stepping step_x/step_y per output sample (16 when the
// reference has the frame's size). Writes clipped samples to dst.
predict_inter_block :: proc(ref: Ref_Plane($T), x, y, step_x, step_y, w, h, filter, bit_depth: int, dst: []T, dst_stride: int) {
	max_value := i32(1) << uint(bit_depth) - 1
	kernels := &SUBPEL_FILTERS[filter]
	rows := (((h - 1) * step_y + 15) >> 4) + 8
	cols := (((w - 1) * step_x + 15) >> 4) + 8
	x0, y0 := (x >> 4) - 3, (y >> 4) - 3
	// Direct reads when the whole footprint is inside the reference.
	src := ref.data
	src_stride := ref.stride
	origin := y0 * ref.stride + x0
	local: [MAX_SOURCE * MAX_SOURCE]T = ---
	if x0 < 0 || y0 < 0 || x0 + cols - 1 > ref.last_x || y0 + rows - 1 > ref.last_y {
		for r in 0 ..< rows {
			line := ref.data[clamp(y0 + r, 0, ref.last_y) * ref.stride:]
			for c in 0 ..< cols do local[r * MAX_SOURCE + c] = line[clamp(x0 + c, 0, ref.last_x)]
		}
		src, src_stride, origin = local[:], MAX_SOURCE, 0
	}
	if step_x == 16 && step_y == 16 {
		if w >= 8 {
			predict_unscaled(src, src_stride, origin, x & 15, y & 15, w, h, kernels, max_value, dst, dst_stride, 8)
		} else {
			predict_unscaled(src, src_stride, origin, x & 15, y & 15, w, h, kernels, max_value, dst, dst_stride, 4)
		}
		return
	}
	intermediate: [MAX_SOURCE * 64]i32 = ---
	for r in 0 ..< rows {
		line := src[origin + r * src_stride:]
		for c in 0 ..< w {
			p := (x & 15) + step_x * c
			k := &kernels[p & 15]
			taps := line[p >> 4:][:8]
			s: i32
			for t in 0 ..< 8 do s += i32(k[t]) * i32(taps[t])
			intermediate[r * 64 + c] = clamp((s + 64) >> 7, 0, max_value)
		}
	}
	for r in 0 ..< h {
		p := (y & 15) + step_y * r
		k := &kernels[p & 15]
		base := (p >> 4) * 64
		out := dst[r * dst_stride:][:w]
		for c in 0 ..< w {
			s: i32
			for t in 0 ..< 8 do s += i32(k[t]) * intermediate[base + t * 64 + c]
			out[c] = T(clamp((s + 64) >> 7, 0, max_value))
		}
	}
}

// The unscaled case: one kernel per direction for the whole block, applied
// to N columns at a time. A zero phase is the identity kernel, so that pass
// is skipped (exactly: (128 * s + 64) >> 7 == s).
@(private)
predict_unscaled :: proc(src: []$T, stride, origin, fx, fy, w, h: int, kernels: ^[16][8]i16, max_value: i32, dst: []T, dst_stride: int, $N: int) #no_bounds_check {
	V :: #simd[N]i32
	U :: #simd[N]u32
	load :: #force_inline proc(src: []$T, at: int) -> V {return V(intrinsics.unaligned_load((^#simd[N]T)(&src[at])))}
	round :: #force_inline proc(acc: V, max_value: i32) -> V {return simd.clamp(simd.shr(acc + 64, U(7)), V(0), V(max_value))}
	put :: #force_inline proc(dst: []$T, at: int, v: V) {intrinsics.unaligned_store((^#simd[N]T)(&dst[at]), (#simd[N]T)(v))}
	kx, ky := &kernels[fx], &kernels[fy]
	base := origin + 3 * stride + 3 // the block's own top-left sample
	switch {
	case fx == 0 && fy == 0:
		for r in 0 ..< h do copy(dst[r * dst_stride:][:w], src[base + r * stride:][:w])
	case fy == 0:
		for r in 0 ..< h do for c := 0; c < w; c += N {
			at := base + r * stride + c - 3
			acc: V
			for t in 0 ..< 8 do acc += V(i32(kx[t])) * load(src, at + t)
			put(dst, r * dst_stride + c, round(acc, max_value))
		}
	case fx == 0:
		for r in 0 ..< h do for c := 0; c < w; c += N {
			at := base + (r - 3) * stride + c
			acc: V
			for t in 0 ..< 8 do acc += V(i32(ky[t])) * load(src, at + t * stride)
			put(dst, r * dst_stride + c, round(acc, max_value))
		}
	case:
		// Horizontal pass over the h + 7 rows the vertical taps need.
		mid: [(64 + 7) * 64]i32 = ---
		for r in 0 ..< h + 7 do for c := 0; c < w; c += N {
			at := origin + r * stride + c
			acc: V
			for t in 0 ..< 8 do acc += V(i32(kx[t])) * load(src, at + t)
			intrinsics.unaligned_store((^V)(&mid[r * 64 + c]), round(acc, max_value))
		}
		for r in 0 ..< h do for c := 0; c < w; c += N {
			acc: V
			for t in 0 ..< 8 do acc += V(i32(ky[t])) * intrinsics.unaligned_load((^V)(&mid[(r + t) * 64 + c]))
			put(dst, r * dst_stride + c, round(acc, max_value))
		}
	}
}

// Compound prediction: the rounded average of both references.
average_into :: proc(dst: []$T, dst_stride: int, other: []T, other_stride, w, h: int) {
	for r in 0 ..< h {
		a := dst[r * dst_stride:][:w]
		b := other[r * other_stride:][:w]
		for c in 0 ..< w do a[c] = T((u32(a[c]) + u32(b[c]) + 1) >> 1)
	}
}

// Chroma motion vector for a sub-8x8 block (8.5.2.1).
round_mv_q2 :: #force_inline proc "contextless" (v: i32) -> i32 {return (v < 0 ? v - 1 : v + 1) / 2}
round_mv_q4 :: #force_inline proc "contextless" (v: i32) -> i32 {return (v < 0 ? v - 2 : v + 2) / 4}

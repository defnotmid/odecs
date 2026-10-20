package h265_decoder

import "base:intrinsics"
import "base:runtime"
import "core:simd"

// ---------------------------------------------------------------------------
// Decoder-local SIMD kernels. The arithmetic is the same as the shared scalar
// code; only the order the integer sums are accumulated in differs, which
// cannot change the result because no intermediate overflows i32.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// SAO row kernel (8.7.3). Offsets are the same along a run, so each sample's
// band or edge category becomes a vector select. Lanes are i16: samples have
// at most 12 bits and admitted offset scales keep offsets within 31 << 2.
// ---------------------------------------------------------------------------

SAO_LANES :: runtime.NATIVE_SIMD_BIT_WIDTH / 16

// sao_run applies one CTB's offsets to the n samples of a row starting at
// index o, reading src and writing dst. An edge class compares each sample
// with the ones `a` and `b` indices away.
@(private)
sao_run :: #force_inline proc "contextless" (
	dst, src: []$Sample,
	o, n, a, b: int,
	p: ^Sao_Params,
	shift: int,
	max_v: i32,
) #no_bounds_check {
	d, s := raw_data(dst)[o:], raw_data(src)[o:]
	if p.type_idx == SAO_BAND {
		sao_lanes(SAO_LANES, true, d, s, 0, n, a, b, p, shift, max_v)
	} else {
		sao_lanes(SAO_LANES, false, d, s, 0, n, a, b, p, shift, max_v)
	}
}

// sao_lanes covers samples [x, n) in vectors of N lanes, then halved vectors
// down to single samples.
@(private = "file")
sao_lanes :: #force_inline proc "contextless" (
	$N: int,
	$BAND: bool,
	d, s: [^]$Sample,
	x, n, a, b: int,
	p: ^Sao_Params,
	shift: int,
	max_v: i32,
) #no_bounds_check {
	x := x
	for ; x + N <= n; x += N do sao_chunk(N, BAND, d[x:], s[x:], a, b, p, shift, max_v)
	when N > 1 do sao_lanes(N / 2, BAND, d, s, x, n, a, b, p, shift, max_v)
}

@(private = "file")
sao_chunk :: #force_inline proc "contextless" (
	$N: int,
	$BAND: bool,
	d, s: [^]$Sample,
	a, b: int,
	p: ^Sao_Params,
	shift: int,
	max_v: i32,
) #no_bounds_check {
	V :: #simd[N]i16
	v := sao_load(N, &s[0])
	// Each sample's key selects one of the four offsets, or none.
	when BAND {
		// The band relative to the first of the four offset bands.
		key := simd.bit_and(simd.shr(v, (#simd[N]u16)(u16(shift))) - V(i16(p.band)), V(31))
		keys := [4]i16{0, 1, 2, 3}
	} else {
		// Table 8-13: the sum of the signs against both neighbours; local
		// minima and maxima take the outer offsets, flat samples none.
		key :=
			simd.clamp(v - sao_load(N, &s[a]), V(-1), V(1)) +
			simd.clamp(v - sao_load(N, &s[b]), V(-1), V(1))
		keys := [4]i16{-2, -1, 1, 2}
	}
	sel := V(0)
	#unroll for i in 0 ..< 4 do sel = simd.select(simd.lanes_eq(key, V(keys[i])), V(i16(p.offset[i])), sel)
	r := simd.clamp(v + sel, V(0), V(i16(max_v)))
	intrinsics.unaligned_store((^#simd[N]Sample)(d), (#simd[N]Sample)(r))
}

@(private = "file")
sao_load :: #force_inline proc "contextless" ($N: int, at: ^$Sample) -> #simd[N]i16 {
	return (#simd[N]i16)(intrinsics.unaligned_load((^#simd[N]Sample)(at)))
}

// ---------------------------------------------------------------------------
// Weighted sample prediction (8.5.3.3.4) in i32 lanes.
// ---------------------------------------------------------------------------

WEIGHT_LANES :: runtime.NATIVE_SIMD_BIT_WIDTH / 32

// weigh_rows writes a block of clip((a * w0 + b * w1 + round) >> shift +
// offset) into dst at index `at`. a and b are dense rows of 14-bit
// predictions; b is read only for two lists.
@(private)
weigh_rows :: proc(
	$BI: bool,
	dst: []$Sample,
	at, stride: int,
	a, b: []i16,
	size: [2]int,
	pw: Prediction_Weights,
	max_v: i32,
) #no_bounds_check {
	for j in 0 ..< size.y {
		d, ra, rb :=
			raw_data(dst)[at + j * stride:], raw_data(a)[j * size.x:], raw_data(b)[j * size.x:]
		weigh_lanes(WEIGHT_LANES, BI, d, ra, rb, 0, size.x, pw, max_v)
	}
}

// weigh_lanes covers samples [x, w) in vectors of N lanes, then halved
// vectors down to single samples.
@(private = "file")
weigh_lanes :: #force_inline proc "contextless" (
	$N: int,
	$BI: bool,
	d: [^]$Sample,
	a, b: [^]i16,
	x, w: int,
	pw: Prediction_Weights,
	max_v: i32,
) #no_bounds_check {
	V :: #simd[N]i32
	x := x
	for ; x + N <= w; x += N {
		v := (V)(intrinsics.unaligned_load((^#simd[N]i16)(&a[x]))) * V(pw.w0)
		when BI do v += (V)(intrinsics.unaligned_load((^#simd[N]i16)(&b[x]))) * V(pw.w1)
		v = simd.shr(v + V(pw.round), (#simd[N]u32)(pw.shift)) + V(pw.offset)
		intrinsics.unaligned_store(
			(^#simd[N]Sample)(&d[x]),
			(#simd[N]Sample)(simd.clamp(v, V(0), V(max_v))),
		)
	}
	when N > 1 do weigh_lanes(N / 2, BI, d, a, b, x, w, pw, max_v)
}

package h265_decoder

// ---------------------------------------------------------------------------
// Inter prediction sample interpolation (8.5.3.3). Ported from gen2brain/h265
// hevc/interpred.go (MIT); oxideav-h265 src/inter_pred.rs and src/inter_recon.rs
// are the per-file cross-references. Samples are 16-bit planes; the bit depth bounds the values.
// ---------------------------------------------------------------------------

import "base:intrinsics"
import "base:runtime"
import "core:simd"

// Table 8-11, indexed by the fractional part (xFrac/yFrac) of a luma vector.
@(rodata)
LUMA_FILTER := [4][8]i32 {
	{0, 0, 0, 64, 0, 0, 0, 0},
	{-1, 4, -10, 58, 17, -5, 1, 0},
	{-1, 4, -11, 40, 40, -11, 4, -1},
	{0, 1, -5, 17, 58, -10, 4, -1},
}

// Table 8-12, indexed by the fractional part of a chroma vector.
@(rodata)
CHROMA_FILTER := [8][4]i32 {
	{0, 64, 0, 0},
	{-2, 58, 10, -2},
	{-4, 54, 16, -2},
	{-6, 46, 28, -4},
	{-4, 36, 36, -4},
	{-4, 28, 46, -6},
	{-2, 16, 54, -4},
	{-2, 10, 58, -2},
}

// The largest prediction unit is 64x64; the support of the longest filter adds
// three samples on each side, so one padded copy covers any block.
MC_PAD_SIZE :: (64 + 7) * (64 + 7)
MC_TMP_SIZE :: (64 + 7) * 64

// Interpolation scratch: the first pass of a two-axis filter, and the edge
// copy of a block whose support leaves the picture.
Mc_Scratch :: struct($Sample: typeid) {
	tmp: [MC_TMP_SIZE]i16,
	pad: [MC_PAD_SIZE]Sample,
}

// A reference picture plane and the size its edge clamping uses.
Mc_Plane :: struct($Sample: typeid) {
	samples:       []Sample,
	stride:        int,
	width, height: int,
}

// A block to predict: the integer position of its top-left sample in the
// reference plane, the fractional phase on each axis, and its size.
Mc_Block :: struct {
	pos, frac, size: [2]int,
}

mc_plane :: proc($Sample: typeid, p: ^Picture, c_idx: int) -> Mc_Plane(Sample) {
	samples, stride := plane_at(Sample, p, c_idx)
	if c_idx == 0 do return {samples, stride, p.width, p.height}
	return {samples, stride, p.width / p.sub_w_c, p.height / p.sub_h_c}
}

// emulate copies the size.x x size.y region at `at` out of a reference plane,
// repeating edge samples where it falls outside, so a filter reading the copy
// needs no bounds check.
emulate :: proc(dst: []$Sample, ref: Mc_Plane(Sample), at, size: [2]int) #no_bounds_check {
	lo := clamp(-at.x, 0, size.x)
	hi := clamp(ref.width - at.x, 0, size.x)
	for j in 0 ..< size.y {
		row := ref.samples[clamp(at.y + j, 0, ref.height - 1) * ref.stride:]
		out := dst[j * size.x:][:size.x]
		for &v in out[:lo] do v = row[0]
		if hi > lo do copy(out[lo:hi], row[at.x + lo:at.x + hi])
		for &v in out[hi:] do v = row[ref.width - 1]
	}
}

// mc_luma is the luma sample interpolation of 8.5.3.3.3.1 into the 14-bit
// intermediate the weighted prediction process consumes, w samples per row.
mc_luma :: proc(
	dst: []i16,
	ref: Mc_Plane($Sample),
	b: Mc_Block,
	bit_depth: int,
	scratch: ^Mc_Scratch(Sample),
) {
	mc_block(LUMA_FILTER[b.frac.x], LUMA_FILTER[b.frac.y], dst, ref, b, bit_depth, scratch)
}

// mc_chroma is the chroma sample interpolation of 8.5.3.3.3.2.
mc_chroma :: proc(
	dst: []i16,
	ref: Mc_Plane($Sample),
	b: Mc_Block,
	bit_depth: int,
	scratch: ^Mc_Scratch(Sample),
) {
	mc_block(CHROMA_FILTER[b.frac.x], CHROMA_FILTER[b.frac.y], dst, ref, b, bit_depth, scratch)
}

// mc_block is the separable interpolation shared by luma and chroma: a
// fractional axis filters with its taps, an integer axis copies. Support
// outside the picture is first copied out with the edge clamping of
// 8.5.3.3.3, so the passes index the source directly.
@(private = "file")
mc_block :: proc(
	fx, fy: [$TAPS]i32,
	dst: []i16,
	ref: Mc_Plane($Sample),
	b: Mc_Block,
	bit_depth: int,
	scratch: ^Mc_Scratch(Sample),
) #no_bounds_check {
	BACK :: TAPS / 2 - 1
	// A fractional axis reads BACK samples before the block and TAPS - 1 more
	// in total, from the first tap.
	fractional := [2]int{int(b.frac.x != 0), int(b.frac.y != 0)}
	lo := -BACK * fractional
	span := b.size + (TAPS - 1) * fractional
	first := b.pos + lo

	src, origin := ref, b.pos
	if first.x < 0 ||
	   first.y < 0 ||
	   first.x + span.x > ref.width ||
	   first.y + span.y > ref.height {
		emulate(scratch.pad[:], ref, first, span)
		src, origin = Mc_Plane(Sample){scratch.pad[:], span.x, span.x, span.y}, -lo
	}
	base := origin.y * src.stride + origin.x

	// Sample passes of 8-bit pictures fit i16 lanes exactly: no partial sum
	// exceeds 112 * 255. Deeper samples use i32 lanes.
	if bit_depth == 8 {
		mc_filter(i16, dst, src, base, b, fx, fy, bit_depth, scratch)
	} else {
		mc_filter(i32, dst, src, base, b, fx, fy, bit_depth, scratch)
	}
}

// mc_filter runs the passes of one block, with sample passes in T lanes. The
// block's top-left sample is src.samples[base]; its filter support is inside.
@(private = "file")
mc_filter :: proc(
	$T: typeid,
	dst: []i16,
	src: Mc_Plane($Sample),
	base: int,
	b: Mc_Block,
	fx, fy: [$TAPS]i32,
	bit_depth: int,
	scratch: ^Mc_Scratch(Sample),
) #no_bounds_check {
	BACK :: TAPS / 2 - 1
	shift1 := u32(min(4, bit_depth - 8))
	s, stride := src.samples, src.stride
	switch {
	case b.frac == {0, 0}:
		// An integer position scales by 2^shift3 alone.
		shift3 := u32(max(2, 14 - bit_depth))
		mc_pass(i16, dst, s[base:], stride, 0, b.size, [1]i32{1 << shift3}, 0)
	case b.frac.y == 0:
		mc_pass(T, dst, s[base - BACK:], stride, 1, b.size, fx, shift1)
	case b.frac.x == 0:
		mc_pass(T, dst, s[base - BACK * stride:], stride, stride, b.size, fy, shift1)
	case:
		// The horizontal pass covers the vertical filter's support rows; the
		// vertical pass reads its 14-bit output in i32 lanes.
		rows := b.size + {0, TAPS - 1}
		tmp := scratch.tmp[:rows.x * rows.y]
		mc_pass(T, tmp, s[base - BACK * stride - BACK:], stride, 1, rows, fx, shift1)
		mc_pass(i32, dst, tmp, b.size.x, b.size.x, b.size, fy, 6)
	}
}

// mc_pass filters every row of a block into dst, w outputs per row. Each
// output is the sum of TAPS source samples `step` apart, scaled by the taps
// and shifted right; `src` addresses the first tap of the first output.
@(private = "file")
mc_pass :: proc(
	$T: typeid,
	dst: []i16,
	src: []$S,
	stride, step: int,
	size: [2]int,
	taps: [$TAPS]i32,
	shift: u32,
) #no_bounds_check {
	LANES :: runtime.NATIVE_SIMD_BIT_WIDTH / (8 * size_of(T))
	t: [TAPS]T
	for k in 0 ..< TAPS do t[k] = T(taps[k])
	for j in 0 ..< size.y {
		mc_row(
			LANES,
			raw_data(dst)[j * size.x:],
			raw_data(src)[j * stride:],
			0,
			size.x,
			step,
			t,
			shift,
		)
	}
}

// mc_row filters outputs [x, w) of one row in vectors of N lanes, then the
// remainder in halved vectors (block widths are even).
@(private = "file")
mc_row :: #force_inline proc "contextless" (
	$N: int,
	d: [^]i16,
	s: [^]$S,
	x, w, step: int,
	t: [$TAPS]$T,
	shift: u32,
) #no_bounds_check {
	x := x
	for ; x + N <= w; x += N do mc_chunk(N, d[x:], s[x:], step, t, shift)
	when N > 2 do mc_row(N / 2, d, s, x, w, step, t, shift)
}

@(private = "file")
mc_chunk :: #force_inline proc "contextless" (
	$N: int,
	d: [^]i16,
	s: [^]$S,
	step: int,
	t: [$TAPS]$T,
	shift: u32,
) #no_bounds_check {
	V :: #simd[N]T
	load :: #force_inline proc "contextless" (p: ^S) -> V {
		return (V)(intrinsics.unaligned_load((^#simd[N]S)(p)))
	}
	acc := simd.mul(load(&s[0]), (V)(t[0]))
	when TAPS > 1 {
		#unroll for k in 1 ..< TAPS do acc = simd.add(acc, simd.mul(load(&s[k * step]), (V)(t[k])))
	}
	acc = simd.shr(acc, (#simd[N]intrinsics.type_integer_to_unsigned(T))(shift))
	intrinsics.unaligned_store((^#simd[N]i16)(d), (#simd[N]i16)(acc))
}

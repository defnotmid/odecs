package h265_encoder

import hevc ".."
import "base:intrinsics"
import "core:simd"

// ---------------------------------------------------------------------------
// Encoder-local portable SIMD kernels. The arithmetic is the same scalar
// integer arithmetic; only the order the sums are accumulated in differs,
// which cannot change a result (no i32 sum here overflows). The interpolation
// intermediate layout was already row-major and unit-stride, so both filter
// passes sweep it directly.
// ---------------------------------------------------------------------------

// i32 lanes per vector operation. luma blocks are 8..32 wide, chroma 4..16.
MC_LANES :: 8

// sad_u16 sums absolute differences of two sample blocks. Native 10-bit
// blocks are at most 32x32: each i32 lane holds at most 4 * 32 * 1023,
// and the final horizontal sum is exact, so the result is the scalar SAD.
SAD_LANES :: 8

ssd_u16 :: proc(
	a: []Sample,
	a_stride: int,
	b: []Sample,
	b_stride: int,
	w, h: int,
) -> u64 #no_bounds_check {
	acc := (#simd[SAD_LANES]i32)(0)
	tail: u64
	for j in 0 ..< h {
		i := 0
		for ; i + SAD_LANES <= w; i += SAD_LANES {
			av := (#simd[SAD_LANES]i32)(
				intrinsics.unaligned_load((^#simd[SAD_LANES]u16)(&a[j * a_stride + i])),
			)
			bv := (#simd[SAD_LANES]i32)(
				intrinsics.unaligned_load((^#simd[SAD_LANES]u16)(&b[j * b_stride + i])),
			)
			d := simd.sub(av, bv)
			acc = simd.add(acc, simd.mul(d, d))
		}
		for ; i < w; i += 1 {
			d := i32(a[j * a_stride + i]) - i32(b[j * b_stride + i])
			tail += u64(d * d)
		}
	}
	return u64(simd.reduce_add_ordered(acc)) + tail
}

sad_u16 :: proc(
	a: []Sample,
	a_stride: int,
	b: []Sample,
	b_stride: int,
	w, h: int,
) -> u32 #no_bounds_check {
	acc := (#simd[SAD_LANES]i32)(0)
	tail: u32
	for j in 0 ..< h {
		i := 0
		for ; i + SAD_LANES <= w; i += SAD_LANES {
			av := (#simd[SAD_LANES]i32)(
				intrinsics.unaligned_load((^#simd[SAD_LANES]u16)(&a[j * a_stride + i])),
			)
			bv := (#simd[SAD_LANES]i32)(
				intrinsics.unaligned_load((^#simd[SAD_LANES]u16)(&b[j * b_stride + i])),
			)
			acc = simd.add(acc, intrinsics.simd_abs(simd.sub(av, bv)))
		}
		for ; i < w; i += 1 {
			d := i32(a[j * a_stride + i]) - i32(b[j * b_stride + i])
			tail += u32(d < 0 ? -d : d)
		}
	}
	return u32(simd.reduce_add_ordered(acc)) + tail
}

// ---------------------------------------------------------------------------
// Forward transform. `forward_dct_n` in the shared package accumulates one
// scalar dot product per output coefficient. Each DCT row satisfies
// B[k][N-1-i] = (-1)^k B[k][i]. Pairing reflected samples therefore gives
// one shared sum/difference row and half as many products per coefficient.
// The retained bases pack the even and odd coefficient lanes separately;
// neither transform dimension needs a horizontal vector reduction.
// ---------------------------------------------------------------------------

DCT_SIZES :: [4]int{4, 8, 16, 32}

// Retain only the first half of each DCT row, transposed within the even/odd
// coefficient groups. The existing sidecar capacity also holds the distinct
// dense 4x4 DST basis at index 4.
init_fwd_dct_t :: proc(enc: ^Encoder) {
	sizes := DCT_SIZES
	for idx in 0 ..< len(sizes) {
		n := sizes[idx]
		basis: []i32
		switch n {
		case 4:
			basis = hevc.DCT_4[:]
		case 8:
			basis = hevc.DCT_8[:]
		case 16:
			basis = hevc.DCT_16[:]
		case 32:
			basis = hevc.DCT_32[:]
		}
		pairs := n / 2
		for parity in 0 ..< 2 {
			for i in 0 ..< pairs {
				for q in 0 ..< pairs {
					k := 2 * q + parity
					enc.dct_t[idx][i * n + parity * pairs + q] = basis[k * n + i]
				}
			}
		}
	}
	init_fwd_dst_t(enc)
}

// init_fwd_dst_t is the same transposition for the 4x4 DST-VII basis, which
// luma intra blocks use. This basis does not have DCT reflection symmetry.
@(private)
init_fwd_dst_t :: proc(enc: ^Encoder) {
	basis := hevc.DST_4[:]
	for k in 0 ..< 4 {
		for i in 0 ..< 4 {
			enc.dct_t[4][i * 4 + k] = basis[k * 4 + i]
		}
	}
}

@(private)
forward_pair_lanes :: #force_inline proc($LANES: int, sum, difference: i32) -> #simd[LANES]i32 {
	s := (#simd[LANES]i32)(sum)
	d := (#simd[LANES]i32)(difference)
	when LANES == 4 {
		return simd.shuffle(s, d, 0, 0, 4, 4)
	} else {
		return simd.shuffle(s, d, 0, 0, 0, 0, 8, 8, 8, 8)
	}
}

@(private)
forward_dct_vec :: proc(
	$N: int,
	$LANES: int,
	basis_t: []i32,
	src: []i16,
	src_stride: int,
	dst: []i16,
	bit_depth: int,
) #no_bounds_check {
	Pairs :: N / 2
	Chunks :: N / LANES
	tmp: [1024]i32 = ---
	paired: [2][Pairs]i32 = ---
	when Pairs < LANES {paired_vectors: [Pairs]#simd[LANES]i32 = ---}

	// Keep both rounding boundaries of the shared matrix equation.
	shift1 := u32(log2_size(N) - 1 + (bit_depth - 8))
	round1 := i32(1) << (shift1 - 1)
	shift2 := u32(log2_size(N) + 6)
	round2 := i32(1) << (shift2 - 1)

	r1v := (#simd[LANES]i32)(round1)
	r2v := (#simd[LANES]i32)(round2)
	sh1v := (#simd[LANES]u32)(shift1)
	sh2v := (#simd[LANES]u32)(shift2)

	// First dimension. Each row's pairs are prepared once, then reused by all
	// coefficient chunks. Rows retain even frequencies followed by odd ones.
	for j in 0 ..< N {
		for i in 0 ..< Pairs {
			a := i32(src[j * src_stride + i])
			b := i32(src[j * src_stride + N - 1 - i])
			paired[0][i] = a + b
			paired[1][i] = a - b
			when Pairs < LANES {
				paired_vectors[i] = forward_pair_lanes(LANES, paired[0][i], paired[1][i])
			}
		}
		for c in 0 ..< Chunks {
			acc := (#simd[LANES]i32)(0)
			for i in 0 ..< Pairs {
				b := intrinsics.unaligned_load((^#simd[LANES]i32)(&basis_t[i * N + c * LANES]))
				v: #simd[LANES]i32
				when Pairs < LANES {
					v = paired_vectors[i]
				} else {
					v = (#simd[LANES]i32)(paired[c * LANES / Pairs][i])
				}
				acc = simd.add(acc, simd.mul(b, v))
			}
			acc = simd.shr(simd.add(acc, r1v), sh1v)
			intrinsics.unaligned_store((^#simd[LANES]i32)(&tmp[j * N + c * LANES]), acc)
		}
	}

	// Pair reflected rows in place. Each pair is loaded completely before
	// either row is replaced; the lower row retains its sum, the reflected
	// upper row its difference. Horizontal frequency lanes stay contiguous.
	for i in 0 ..< Pairs {
		for c in 0 ..< Chunks {
			lo := i * N + c * LANES
			hi := (N - 1 - i) * N + c * LANES
			a := intrinsics.unaligned_load((^#simd[LANES]i32)(&tmp[lo]))
			b := intrinsics.unaligned_load((^#simd[LANES]i32)(&tmp[hi]))
			intrinsics.unaligned_store((^#simd[LANES]i32)(&tmp[lo]), simd.add(a, b))
			intrinsics.unaligned_store((^#simd[LANES]i32)(&tmp[hi]), simd.sub(a, b))
		}
	}

	// The vertical basis coefficient is shared across each contiguous row of
	// horizontal frequencies. Accumulators cover one output row, so there is
	// no transposed coefficient buffer or column-wise publication pass.
	min_v := (#simd[LANES]i32)(-32768)
	max_v := (#simd[LANES]i32)(32767)
	for k in 0 ..< N {
		parity := k & 1
		q := k / 2
		acc: [Chunks]#simd[LANES]i32
		for i in 0 ..< Pairs {
			row := parity == 0 ? i : N - 1 - i
			b := (#simd[LANES]i32)(basis_t[i * N + parity * Pairs + q])
			for c in 0 ..< Chunks {
				v := intrinsics.unaligned_load((^#simd[LANES]i32)(&tmp[row * N + c * LANES]))
				acc[c] = simd.add(acc[c], simd.mul(b, v))
			}
		}
		for c in 0 ..< Chunks do acc[c] = simd.clamp(simd.shr(simd.add(acc[c], r2v), sh2v), min_v, max_v)

		// All source samples have been consumed by the first dimension before
		// any destination write. Caller-owned src/dst slices may overlap; the
		// retained encoder basis remains read-only throughout the transform.
		when N == 4 {
			values := simd.shuffle(acc[0], acc[0], 0, 2, 1, 3)
			intrinsics.unaligned_store((^#simd[LANES]i16)(&dst[k * N]), (#simd[LANES]i16)(values))
		} else when N == 8 {
			values := simd.shuffle(acc[0], acc[0], 0, 4, 1, 5, 2, 6, 3, 7)
			intrinsics.unaligned_store((^#simd[LANES]i16)(&dst[k * N]), (#simd[LANES]i16)(values))
		} else {
			// Even and odd groups occupy separate vectors for N=16/32.
			for c in 0 ..< Pairs / LANES {
				even, odd := acc[c], acc[c + Pairs / LANES]
				first := simd.shuffle(even, odd, 0, 8, 1, 9, 2, 10, 3, 11)
				second := simd.shuffle(even, odd, 4, 12, 5, 13, 6, 14, 7, 15)
				start := k * N + 2 * c * LANES
				intrinsics.unaligned_store(
					(^#simd[LANES]i16)(&dst[start]),
					(#simd[LANES]i16)(first),
				)
				intrinsics.unaligned_store(
					(^#simd[LANES]i16)(&dst[start + LANES]),
					(#simd[LANES]i16)(second),
				)
			}
		}
	}
}

// DST-VII has a different matrix equation: retain its dense 4x4 products,
// with the same intermediate layout, rounding and final clamp as before.
@(private)
forward_dst4_vec :: proc(
	basis_t: []i32,
	src: []i16,
	src_stride: int,
	dst: []i16,
	bit_depth: int,
) #no_bounds_check {
	N :: 4
	LANES :: 4
	tmp: [16]i32 = ---
	out_t: [16]i32 = ---
	shift1 := u32(log2_size(N) - 1 + (bit_depth - 8))
	round1 := i32(1) << (shift1 - 1)
	shift2 := u32(log2_size(N) + 6)
	round2 := i32(1) << (shift2 - 1)
	r1v := (#simd[LANES]i32)(round1)
	r2v := (#simd[LANES]i32)(round2)
	sh1v := (#simd[LANES]u32)(shift1)
	sh2v := (#simd[LANES]u32)(shift2)
	for j in 0 ..< N {
		acc := (#simd[LANES]i32)(0)
		for i in 0 ..< N {
			b := intrinsics.unaligned_load((^#simd[LANES]i32)(&basis_t[i * N]))
			acc = simd.add(acc, simd.mul(b, (#simd[LANES]i32)(i32(src[j * src_stride + i]))))
		}
		acc = simd.shr(simd.add(acc, r1v), sh1v)
		intrinsics.unaligned_store((^#simd[LANES]i32)(&tmp[j * N]), acc)
	}
	for r in 0 ..< N {
		acc := (#simd[LANES]i32)(0)
		for i in 0 ..< N {
			b := intrinsics.unaligned_load((^#simd[LANES]i32)(&basis_t[i * N]))
			acc = simd.add(acc, simd.mul(b, (#simd[LANES]i32)(tmp[i * N + r])))
		}
		acc = simd.shr(simd.add(acc, r2v), sh2v)
		intrinsics.unaligned_store((^#simd[LANES]i32)(&out_t[r * N]), acc)
	}
	for r in 0 ..< N do for k in 0 ..< N do dst[k * N + r] = i16(clamp(out_t[r * N + k], -32768, 32767))
}

// forward_transform dispatches the reshaped kernel; the shared scalar path
// stays available from hevc.forward_transform for other consumers.
forward_transform :: proc(
	enc: ^Encoder,
	size: int,
	src: []i16,
	src_stride: int,
	dst: []i16,
	bit_depth: int,
) {
	switch size {
	case 4:
		forward_dct_vec(4, 4, enc.dct_t[0][:8], src, src_stride, dst, bit_depth)
	case 8:
		forward_dct_vec(8, 8, enc.dct_t[1][:32], src, src_stride, dst, bit_depth)
	case 16:
		forward_dct_vec(16, 8, enc.dct_t[2][:128], src, src_stride, dst, bit_depth)
	case:
		forward_dct_vec(32, 8, enc.dct_t[3][:512], src, src_stride, dst, bit_depth)
	}
}

// forward_transform_dst4 is the 4x4 DST-VII forward transform: M src M^T with
// the same rounding and shifts as the DCT.
forward_transform_dst4 :: proc(
	enc: ^Encoder,
	src: []i16,
	src_stride: int,
	dst: []i16,
	bit_depth: int,
) {
	forward_dst4_vec(enc.dct_t[4][:16], src, src_stride, dst, bit_depth)
}

// ---------------------------------------------------------------------------
// Reconstruction add. The residual is already dequantized and inverse
// transformed into `q` when `cbf` is set, so this is the per-sample
// prediction + residual clamp, the sample write and the SSE accumulation over
// the same row. `pred` is a CU-sized plane addressed by row/column offset, so
// the inter transform tree's leaves share the kernel.
// ---------------------------------------------------------------------------

RECON_LANES :: 8

recon_plane_vec :: proc(
	dst: Plane(Sample),
	src: Plane(Sample),
	x, y, n: int,
	q: []i16,
	pred: []Sample,
	pred_stride, pred_ox, pred_oy: int,
	cbf: bool,
	bit_depth: int,
	sse: ^u64,
) #no_bounds_check {
	zero := (#simd[RECON_LANES]i32)(0)
	max_v := (#simd[RECON_LANES]i32)(i32(1) << uint(bit_depth) - 1)
	sse_acc := (#simd[RECON_LANES]i32)(0)
	sse_tail: u64

	for j in 0 ..< n {
		dst_row := dst.data[dst.offset + (y + j) * dst.stride + x:]
		src_row := src.data[src.offset + (y + j) * src.stride + x:]
		pred_row := pred[(pred_oy + j) * pred_stride + pred_ox:]
		q_row: []i16
		if cbf do q_row = q[j * n:]

		i := 0
		for ; i + RECON_LANES <= n; i += RECON_LANES {
			p := (#simd[RECON_LANES]i32)(
				intrinsics.unaligned_load((^#simd[RECON_LANES]u16)(&pred_row[i])),
			)
			if cbf {
				r := (#simd[RECON_LANES]i32)(
					intrinsics.unaligned_load((^#simd[RECON_LANES]i16)(&q_row[i])),
				)
				p = simd.clamp(simd.add(p, r), zero, max_v)
			}
			intrinsics.unaligned_store(
				(^#simd[RECON_LANES]u16)(&dst_row[i]),
				(#simd[RECON_LANES]u16)(p),
			)

			s := (#simd[RECON_LANES]i32)(
				intrinsics.unaligned_load((^#simd[RECON_LANES]u16)(&src_row[i])),
			)
			d := simd.sub(s, p)
			sse_acc = simd.add(sse_acc, simd.mul(d, d))
		}
		for ; i < n; i += 1 {
			p := i32(pred_row[i])
			if cbf do p = clamp(p + i32(q_row[i]), 0, i32(1) << uint(bit_depth) - 1)
			dst_row[i] = Sample(p)
			d := i32(src_row[i]) - p
			sse_tail += u64(d * d)
		}
	}

	sse^ += u64(simd.reduce_add_ordered(sse_acc)) + sse_tail
}

// Integer motion needs only edge replication, without interpolation scratch.
@(private)
mc_copy :: proc(
	dst: []Sample,
	dst_stride: int,
	plane: Plane(Sample),
	ix, iy, w, h, frame_w, frame_h: int,
) {
	for oy in 0 ..< h {
		row := plane.offset + clamp_index(iy + oy, frame_h - 1) * plane.stride
		out := dst[oy * dst_stride:][:w]
		if ix >= 0 && ix + w <= frame_w {
			copy(out, plane.data[row + ix:][:w])
		} else {
			for ox in 0 ..< w do out[ox] = plane.data[row + clamp_index(ix + ox, frame_w - 1)]
		}
	}
}

// With one identity axis the two-stage interpolation and final combine reduce
// exactly to (sum + 32) >> 6, including negative filter sums. Keep contiguous
// sample lanes on both axes; only the picture-edge path gathers with clamps.
@(private)
mc_uni_axis :: proc(
	dst: []Sample,
	dst_stride: int,
	plane: Plane(Sample),
	ix, iy, w, h, frame_w, frame_h, bit_depth: int,
	filter: [$N]i32,
	horizontal: bool,
) {
	center :: N / 2 - 1
	max_v := i32(1) << uint(bit_depth) - 1
	for oy in 0 ..< h {
		// Each pointer is obtained from a checked w-sample slice. The lane
		// loop below only loads when all MC_LANES samples fit inside it.
		rows: [N][^]Sample = ---
		edge: [N][32]Sample = ---
		for k in 0 ..< N {
			sx := ix + (horizontal ? k - center : 0)
			sy := clamp_index(iy + oy + (horizontal ? 0 : k - center), frame_h - 1)
			row := plane.offset + sy * plane.stride
			if sx >= 0 && sx + w <= frame_w {
				rows[k] = raw_data(plane.data[row + sx:][:w])
			} else {
				for ox in 0 ..< w do edge[k][ox] = plane.data[row + clamp_index(sx + ox, frame_w - 1)]
				rows[k] = raw_data(edge[k][:w])
			}
		}
		ox := 0
		for ; ox + MC_LANES <= w; ox += MC_LANES {
			acc := (#simd[MC_LANES]i32)(32)
			for k in 0 ..< N {
				v := (#simd[MC_LANES]i32)(
					intrinsics.unaligned_load((^#simd[MC_LANES]u16)(&rows[k][ox])),
				)
				acc = simd.add(acc, simd.mul(v, (#simd[MC_LANES]i32)(filter[k])))
			}
			v := simd.clamp(
				simd.shr(acc, (#simd[MC_LANES]u32)(6)),
				(#simd[MC_LANES]i32)(0),
				(#simd[MC_LANES]i32)(max_v),
			)
			intrinsics.unaligned_store(
				(^#simd[MC_LANES]u16)(&dst[oy * dst_stride + ox]),
				(#simd[MC_LANES]u16)(v),
			)
		}
		for ; ox < w; ox += 1 {
			acc: i32 = 32
			for k in 0 ..< N do acc += filter[k] * i32(rows[k][ox])
			dst[oy * dst_stride + ox] = Sample(clamp(acc >> 6, 0, max_v))
		}
	}
}

// mc_luma is 8.5.3.3.3.1 plus the default combine of 8.5.3.3.4.2 in one pass:
// the horizontal filter (Table 8-11) shifted by `shift1`, the vertical one
// shifted by 6, and the intermediate rounded by `shift3`. The bit-depth
// dependent shifts mirror the decoder's interpolation exactly.
mc_luma :: proc(
	dst: []Sample,
	dst_stride: int,
	ref: ^Frame,
	x, y, w, h: int,
	mv_x, mv_y: i16,
	bit_depth: int,
) {
	ix := x + int(i32(mv_x) >> 2)
	iy := y + int(i32(mv_y) >> 2)
	xf, yf := int(mv_x) & 3, int(mv_y) & 3
	if xf == 0 && yf == 0 {
		mc_copy(dst, dst_stride, ref.y, ix, iy, w, h, ref.coded_width, ref.coded_height)
		return
	}
	if xf == 0 || yf == 0 {
		mc_uni_axis(
			dst,
			dst_stride,
			ref.y,
			ix,
			iy,
			w,
			h,
			ref.coded_width,
			ref.coded_height,
			bit_depth,
			LUMA_FILTER[xf == 0 ? yf : xf],
			yf == 0,
		)
		return
	}
	hor: [40][40]i32 = ---
	mc_luma_horizontal(ref, ix, iy - 3, w, h + 7, xf, bit_depth, hor[:])
	mc_luma_vertical(false, dst, dst_stride, hor[:], 0, w, h, yf, bit_depth)
}

// Shared horizontal intermediate for normal MC and fractional-search reuse.
@(private)
mc_luma_horizontal :: proc(ref: ^Frame, ix, iy, w, rows, xf, bit_depth: int, hor: [][40]i32) {
	fh := LUMA_FILTER[xf]
	ref_w, ref_h := ref.coded_width - 1, ref.coded_height - 1
	shift1 := min(4, bit_depth - 8)
	interior :=
		ix >= 3 && iy >= 0 && ix + w + 4 <= ref.coded_width && iy + rows <= ref.coded_height
	ref_data, ref_off, ref_stride := ref.y.data, ref.y.offset, ref.y.stride
	edge_row: [48]Sample = ---
	src_row: []Sample
	for ry in 0 ..< rows {
		sy := iy + ry
		if interior {
			o := ref_off + sy * ref_stride + (ix - 3)
			src_row = ref_data[o:o + w + 7]
		} else {
			src_row = edge_row[:]
			sy = clamp_index(sy, ref_h)
			for u in 0 ..< w + 7 {
				src_row[u] = at(ref.y, clamp_index(ix + u - 3, ref_w), sy)
			}
		}

		// The validated support slice covers every lane and tap below.
		samples := raw_data(src_row)
		rx := 0
		for ; rx + MC_LANES <= w; rx += MC_LANES {
			acc := (#simd[MC_LANES]i32)(0)
			if xf == 0 {
				v := (#simd[MC_LANES]i32)(
					intrinsics.unaligned_load((^#simd[MC_LANES]u16)(&samples[rx + 3])),
				)
				acc = simd.shl(v, (#simd[MC_LANES]u32)(6))
			} else {
				for k in 0 ..< 8 {
					v := (#simd[MC_LANES]i32)(
						intrinsics.unaligned_load((^#simd[MC_LANES]u16)(&samples[rx + k])),
					)
					acc = simd.add(acc, simd.mul(v, (#simd[MC_LANES]i32)(fh[k])))
				}
			}
			if shift1 > 0 do acc = simd.shr(acc, (#simd[MC_LANES]u32)(u32(shift1)))
			intrinsics.unaligned_store((^#simd[MC_LANES]i32)(&hor[ry][rx]), acc)
		}
		for ; rx < w; rx += 1 {
			acc: i32
			if xf == 0 {
				acc = i32(samples[rx + 3]) << 6
			} else {
				for k in 0 ..< 8 do acc += fh[k] * i32(samples[rx + k])
			}
			hor[ry][rx] = acc >> uint(shift1)
		}
	}
}

// Both consumers share the interpolation and clipping. Search accumulates SAD
// directly; reconstruction writes samples. The unused consumer compiles away.
@(private)
mc_luma_vertical :: proc(
	$SCORE: bool,
	dst: []Sample,
	dst_stride: int,
	hor: [][40]i32,
	hor_x, w, h, yf, bit_depth: int,
	src: []Sample = nil,
	src_stride: int = 0,
) -> u32 {
	fv := LUMA_FILTER[yf]
	shift3 := max(2, 14 - bit_depth)
	off := i32(1) << uint(shift3 - 1)
	max_v := i32(1) << uint(bit_depth) - 1

	sh6 := (#simd[MC_LANES]u32)(6)
	offv := (#simd[MC_LANES]i32)(off)
	sh3v := (#simd[MC_LANES]u32)(u32(shift3))
	zero := (#simd[MC_LANES]i32)(0)
	maxv := (#simd[MC_LANES]i32)(max_v)
	sad_acc := (#simd[MC_LANES]i32)(0)
	sad_tail: u32
	for oy in 0 ..< h {
		ox := 0
		for ; ox + MC_LANES <= w; ox += MC_LANES {
			acc := (#simd[MC_LANES]i32)(0)
			if yf == 0 {
				r := intrinsics.unaligned_load((^#simd[MC_LANES]i32)(&hor[oy + 3][hor_x + ox]))
				acc = simd.shl(r, (#simd[MC_LANES]u32)(6))
			} else {
				for k in 0 ..< 8 {
					r := intrinsics.unaligned_load((^#simd[MC_LANES]i32)(&hor[oy + k][hor_x + ox]))
					acc = simd.add(acc, simd.mul(r, (#simd[MC_LANES]i32)(fv[k])))
				}
			}
			v := simd.shr(simd.add(simd.shr(acc, sh6), offv), sh3v)
			v = simd.clamp(v, zero, maxv)
			when SCORE {
				sample := (#simd[MC_LANES]i32)(
					intrinsics.unaligned_load((^#simd[MC_LANES]u16)(&src[oy * src_stride + ox])),
				)
				sad_acc = simd.add(sad_acc, intrinsics.simd_abs(simd.sub(sample, v)))
			} else {
				intrinsics.unaligned_store(
					(^#simd[MC_LANES]u16)(&dst[oy * dst_stride + ox]),
					(#simd[MC_LANES]u16)(v),
				)
			}
		}
		for ; ox < w; ox += 1 {
			acc: i32
			if yf == 0 {
				acc = hor[oy + 3][hor_x + ox] << 6
			} else {
				for k in 0 ..< 8 do acc += fv[k] * hor[oy + k][hor_x + ox]
			}
			v := clamp(((acc >> 6) + off) >> uint(shift3), 0, max_v)
			when SCORE {
				sad_tail += u32(abs(i32(src[oy * src_stride + ox]) - v))
			} else {
				dst[oy * dst_stride + ox] = Sample(v)
			}
		}
	}
	return u32(simd.reduce_add_ordered(sad_acc)) + sad_tail
}

// Scoped to one motion search over one immutable reference and block. The
// half/quarter refinements stay within one integer pixel of the initial MV.
// Horizontal phases are built lazily and reused across vertical candidates.
@(private)
Luma_Search_Interpolation :: struct {
	ready:  [4]bool,
	ix, iy: int,
	hor:    [4][42][40]i32,
}

@(private)
mc_luma_search :: proc(
	$SCORE: bool,
	cache: ^Luma_Search_Interpolation,
	dst: []Sample,
	ref: ^Frame,
	x, y, w, h: int,
	mv_x, mv_y: i16,
	bit_depth: int,
	src: []Sample = nil,
	src_stride: int = 0,
) -> u32 {
	ix, iy := x + int(i32(mv_x) >> 2), y + int(i32(mv_y) >> 2)
	xf, yf := int(mv_x) & 3, int(mv_y) & 3
	if !cache.ready[xf] {
		mc_luma_horizontal(
			ref,
			cache.ix,
			cache.iy - 3,
			w + 2,
			h + 9,
			xf,
			bit_depth,
			cache.hor[xf][:],
		)
		cache.ready[xf] = true
	}
	return mc_luma_vertical(
		SCORE,
		dst,
		w,
		cache.hor[xf][iy - cache.iy:],
		ix - cache.ix,
		w,
		h,
		yf,
		bit_depth,
		src,
		src_stride,
	)
}

// mc_chroma is 8.5.3.3.3.2 plus the default combine: the eighth-pel chroma
// filter (Table 8-12). `x`, `y` are chroma coordinates and the motion vector
// is in luma quarter-pel units.
mc_chroma :: proc(
	dst: []Sample,
	dst_stride: int,
	plane: Plane(Sample),
	x, y, w, h: int,
	mv_x, mv_y: i16,
	frame_w, frame_h, bit_depth: int,
) {
	ix := x + int(i32(mv_x) >> 3)
	iy := y + int(i32(mv_y) >> 3)
	xf, yf := int(mv_x) & 7, int(mv_y) & 7
	if xf == 0 && yf == 0 {
		mc_copy(dst, dst_stride, plane, ix, iy, w, h, frame_w, frame_h)
		return
	}
	if xf == 0 || yf == 0 {
		mc_uni_axis(
			dst,
			dst_stride,
			plane,
			ix,
			iy,
			w,
			h,
			frame_w,
			frame_h,
			bit_depth,
			CHROMA_FILTER[xf == 0 ? yf : xf],
			yf == 0,
		)
		return
	}
	fh := CHROMA_FILTER[int(mv_x) & 7]
	fv := CHROMA_FILTER[int(mv_y) & 7]
	ref_w, ref_h := frame_w - 1, frame_h - 1

	shift1 := min(4, bit_depth - 8)
	shift3 := max(2, 14 - bit_depth)
	off := i32(1) << uint(shift3 - 1)
	max_v := i32(1) << uint(bit_depth) - 1

	// The 4-tap support reaches one sample back and two forward.
	interior := ix >= 1 && iy >= 1 && ix + w + 3 <= frame_w && iy + h + 3 <= frame_h
	plane_data := plane.data
	plane_off := plane.offset
	plane_stride := plane.stride

	hor: [40][40]i32 = ---
	edge_row: [40]Sample = ---
	src_row: []Sample
	for ry in 0 ..< h + 3 {
		sy := iy + ry - 1
		if interior {
			o := plane_off + sy * plane_stride + (ix - 1)
			src_row = plane_data[o:o + w + 3]
		} else {
			src_row = edge_row[:]
			sy = clamp_index(sy, ref_h)
			for u in 0 ..< w + 3 {
				src_row[u] = at(plane, clamp_index(ix + u - 1, ref_w), sy)
			}
		}

		// The validated support slice covers every lane and tap below.
		samples := raw_data(src_row)
		rx := 0
		for ; rx + MC_LANES <= w; rx += MC_LANES {
			acc := (#simd[MC_LANES]i32)(0)
			for k in 0 ..< 4 {
				v := (#simd[MC_LANES]i32)(
					intrinsics.unaligned_load((^#simd[MC_LANES]u16)(&samples[rx + k])),
				)
				acc = simd.add(acc, simd.mul(v, (#simd[MC_LANES]i32)(fh[k])))
			}
			if shift1 > 0 do acc = simd.shr(acc, (#simd[MC_LANES]u32)(u32(shift1)))
			intrinsics.unaligned_store((^#simd[MC_LANES]i32)(&hor[ry][rx]), acc)
		}
		for ; rx < w; rx += 1 {
			acc: i32
			for k in 0 ..< 4 do acc += fh[k] * i32(samples[rx + k])
			hor[ry][rx] = acc >> uint(shift1)
		}
	}

	sh6 := (#simd[MC_LANES]u32)(6)
	offv := (#simd[MC_LANES]i32)(off)
	sh3v := (#simd[MC_LANES]u32)(u32(shift3))
	zero := (#simd[MC_LANES]i32)(0)
	maxv := (#simd[MC_LANES]i32)(max_v)
	for oy in 0 ..< h {
		ox := 0
		for ; ox + MC_LANES <= w; ox += MC_LANES {
			acc := (#simd[MC_LANES]i32)(0)
			for k in 0 ..< 4 {
				r := intrinsics.unaligned_load((^#simd[MC_LANES]i32)(&hor[oy + k][ox]))
				acc = simd.add(acc, simd.mul(r, (#simd[MC_LANES]i32)(fv[k])))
			}
			v := simd.shr(simd.add(simd.shr(acc, sh6), offv), sh3v)
			v = simd.clamp(v, zero, maxv)
			intrinsics.unaligned_store(
				(^#simd[MC_LANES]u16)(&dst[oy * dst_stride + ox]),
				(#simd[MC_LANES]u16)(v),
			)
		}
		for ; ox < w; ox += 1 {
			acc: i32
			for k in 0 ..< 4 do acc += fv[k] * hor[oy + k][ox]
			dst[oy * dst_stride + ox] = Sample(clamp(((acc >> 6) + off) >> uint(shift3), 0, max_v))
		}
	}
}

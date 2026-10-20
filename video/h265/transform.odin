package h265

// ---------------------------------------------------------------------------
// Transforms and quantization. The integer transforms are separable products
// with the HEVC basis matrices in types.odin. The forward pass rounds after
// each dimension, matching the reference partial-butterfly scaling; the
// inverse pass is bit-exact with the decoder.
//
// Odin's built-in matrix type is limited to 64 elements, so the bases are
// stored as flat row-major arrays and the products are written as matrix
// multiplication loops.
// ---------------------------------------------------------------------------

@(private)
forward_dct_n :: proc(
	basis: []i32,
	n, bit_depth: int,
	src: []i16,
	src_stride: int,
	dst: []i16,
) #no_bounds_check {
	tmp: [1024]i32 = ---
	out: [1024]i32 = ---
	// kvz_g_convert_to_bit[n] is log2(n) - 2; the reference shifts are
	// log2(n) - 1 + (bit_depth - 8) and log2(n) + 6.
	shift1 := u32(log2_size(n) - 1 + (bit_depth - 8))
	round1 := i32(1) << (shift1 - 1)
	shift2 := u32(log2_size(n) + 6)
	round2 := i32(1) << (shift2 - 1)

	// First dimension: T[k][j] = sum_i basis[k][i] * src[j][i], stored at
	// k * n + j to match the reference partial-butterfly layout.
	for j in 0 ..< n {
		row: [32]i32 = ---
		for i in 0 ..< n do row[i] = i32(src[j * src_stride + i])
		for k in 0 ..< n {
			acc: i32
			for i in 0 ..< n do acc += basis[k * n + i] * row[i]
			tmp[k * n + j] = (acc + round1) >> shift1
		}
	}

	// Second dimension: out[k][r] = sum_i basis[k][i] * T[r][i].
	for r in 0 ..< n {
		row: [32]i32 = ---
		for i in 0 ..< n do row[i] = tmp[r * n + i]
		for k in 0 ..< n {
			acc: i32
			for i in 0 ..< n do acc += basis[k * n + i] * row[i]
			out[k * n + r] = (acc + round2) >> shift2
		}
	}

	for i in 0 ..< n * n {
		dst[i] = i16(clamp(out[i], -32768, 32767))
	}
}

log2_size :: #force_inline proc(size: int) -> int {
	switch size {
	case 4:
		return 2
	case 8:
		return 3
	case 16:
		return 4
	case 32:
		return 5
	}
	return 0
}

basis_for :: #force_inline proc(size: int) -> []i32 {
	switch size {
	case 4:
		return DCT_4[:]
	case 8:
		return DCT_8[:]
	case 16:
		return DCT_16[:]
	case 32:
		return DCT_32[:]
	}
	return DCT_4[:]
}

// Forward transform of one square TU. `src` is the residual with the given
// stride, `dst` the coefficients in row-major order.
forward_transform :: proc(size: int, src: []i16, src_stride: int, dst: []i16, bit_depth: int) {
	forward_dct_n(basis_for(size), size, bit_depth, src, src_stride, dst)
}

// Chroma QP mapping (8.6.1): Table 8-10 applies to ChromaArrayType 1
// (4:2:0); every other array type (and monochrome) maps qPi to min(qPi, 51).
// `qp` is qPi with the bit depth offset already folded in; below zero the
// mapping is the identity.
chroma_qp :: proc(qp: i32, chroma_array_type: int) -> i32 {
	if qp < 0 do return qp
	if chroma_array_type != 1 do return min(qp, 51)
	q := min(qp, 57)
	return CHROMA_QP_SCALE[q]
}

// Quantize transformed coefficients (kvz_quant with the flat scaling list).
// Returns true when any coefficient is non-zero. `qp_scaled` carries the
// 6 * (bit_depth - 8) offset, so the shift below compensates it.
quantize :: proc(
	coeff: []i16,
	qcoeff: []i16,
	size, bit_depth, qp_scaled: int,
	intra: bool,
) -> bool #no_bounds_check {
	log2 := log2_size(size)
	transform_shift := MAX_TR_DYNAMIC_RANGE - bit_depth - log2
	q_bits := QUANT_SHIFT + qp_scaled / 6 + transform_shift
	add := (intra ? 171 : 85) << uint(q_bits - 9)

	scale := QUANT_SCALES[qp_scaled % 6]
	nonzero := false
	for i in 0 ..< size * size {
		level := i32(coeff[i])
		abs_level := level < 0 ? -level : level
		q := (abs_level * scale + i32(add)) >> uint(q_bits)
		if level < 0 do q = -q
		q = clamp(q, -32768, 32767)
		qcoeff[i] = i16(q)
		if q != 0 do nonzero = true
	}
	return nonzero
}

// Inverse quantization (kvz_dequant with the flat scaling list). `qp_scaled`
// carries the bit-depth offset, which the shift of bit_depth + log2 - 9 folds
// back into the coefficient scaling. Accept the decoder's i32 levels directly
// and narrow on load, preserving the i16 path without a temporary copy.
dequantize :: proc(qcoeff: []$T, coeff: []i16, size, bit_depth, qp_scaled: int) #no_bounds_check {
	log2 := log2_size(size)
	shift := bit_depth + log2 - 9
	scale := INV_QUANT_SCALES[qp_scaled % 6] << uint(qp_scaled / 6)
	add := i32(1) << uint(shift - 1)
	for i in 0 ..< size * size {
		q := (i32(i16(qcoeff[i])) * scale + add) >> uint(shift)
		coeff[i] = i16(clamp(q, -32768, 32767))
	}
}

// scaling_pos maps a coefficient position to its entry in the 8x8 scaling
// matrix: 4x4 lists are 4 entries per row, and 16x16 and 32x32 blocks sample
// the 8x8 notation at 2x and 4x coarser steps (7.4.5, the same mapping ffmpeg
// applies in the residual loop).
@(private)
scaling_pos :: #force_inline proc(size, x, y: int) -> int #no_bounds_check {
	switch size {
	case 4:
		return (y << 2) + x
	case 8:
		return (y << 3) + x
	case 16:
		return ((y >> 1) << 3) + (x >> 1)
	case 32:
		return ((y >> 2) << 3) + (x >> 2)
	}
	return 0
}

// Quantize with a scaling list: like kvazaar's quant_coeff, the flat quantizer
// scale is divided by the matrix entry, so the encoder codes levels against the
// same matrix the decoder dequantizes with. The 16x16/32x32 DC entry comes
// from the DC list, every other position from the matrix.
quantize_scaled :: proc(
	coeff: []i16,
	qcoeff: []i16,
	size, bit_depth, qp_scaled: int,
	intra: bool,
	scale_m: []u8,
	dc_scale: u8,
) -> bool #no_bounds_check {
	log2 := log2_size(size)
	transform_shift := MAX_TR_DYNAMIC_RANGE - bit_depth - log2
	q_bits := QUANT_SHIFT + qp_scaled / 6 + transform_shift
	add := (intra ? 171 : 85) << uint(q_bits - 9)
	// kvz_scalinglist_process_enc scales the flat quantizer by 16 / matrix.
	scale16 := i64(QUANT_SCALES[qp_scaled % 6]) << 4

	nonzero := false
	for y in 0 ..< size {
		for x in 0 ..< size {
			m := scale_m[scaling_pos(size, x, y)]
			if size >= 16 && x == 0 && y == 0 do m = dc_scale
			mm := i64(m)
			if mm < 1 do mm = 1

			level := i32(coeff[y * size + x])
			abs_level := i64(level < 0 ? -level : level)
			q := (abs_level * (scale16 / mm) + i64(add)) >> uint(q_bits)
			if level < 0 do q = -q
			qcoeff[y * size + x] = i16(clamp(q, -32768, 32767))
			if q != 0 do nonzero = true
		}
	}
	return nonzero
}

// Inverse quantization with a scaling list. Multiplying the flat scale by the
// matrix entry needs a wider accumulator (the entry reaches 255) and the
// bit_depth + log2 - 5 shift, exactly as ffmpeg's residual loop and
// kvz_dequant's scaling branch.
dequantize_scaled :: proc(
	qcoeff: []$T,
	coeff: []i16,
	size, bit_depth, qp_scaled: int,
	scale_m: []u8,
	dc_scale: u8,
) #no_bounds_check {
	log2 := log2_size(size)
	shift := bit_depth + log2 - 5
	scale := i64(INV_QUANT_SCALES[qp_scaled % 6]) << uint(qp_scaled / 6)
	add := i64(1) << uint(shift - 1)

	for y in 0 ..< size {
		for x in 0 ..< size {
			m := i64(scale_m[scaling_pos(size, x, y)])
			if size >= 16 && x == 0 && y == 0 do m = i64(dc_scale)
			q := (i64(i16(qcoeff[y * size + x])) * scale * m + add) >> uint(shift)
			coeff[y * size + x] = i16(clamp(q, -32768, 32767))
		}
	}
}

// Transform skip: the residual is coded directly with a scale adjustment
// (kvz_transformskip / kvz_itransformskip).
transform_skip :: proc(residual: []i16, coeff: []i16, size, bit_depth: int) {
	log2 := log2_size(size)
	shift := MAX_TR_DYNAMIC_RANGE - bit_depth - log2
	for i in 0 ..< size * size {
		coeff[i] = i16(u16(residual[i]) << uint(shift))
	}
}

inverse_transform_skip :: proc(
	coeff: []i16,
	residual: []i16,
	size, bit_depth: int,
) #no_bounds_check {
	log2 := log2_size(size)
	shift := MAX_TR_DYNAMIC_RANGE - bit_depth - log2
	offset := i32(1) << uint(shift - 1)
	for i in 0 ..< size * size {
		residual[i] = i16((i32(coeff[i]) + offset) >> uint(shift))
	}
}

// Residual DPCM (8.6.5): a transform-skip block may code the difference to its
// left (horizontal) or upper (vertical) neighbour instead of the sample, and
// the decoder accumulates the dequantized residual back. The forward form
// subtracts in reverse scan order so every difference reads an original value;
// the encoder applies it before the skip scale, which commutes with that exact
// left shift. The decoder accumulates after the skip scale-down, the order the
// reference decoder uses.
forward_rdpcm :: proc(residual: []i16, size: int, vertical: bool) #no_bounds_check {
	if vertical {
		for x in 0 ..< size {
			for y := size - 1; y >= 1; y -= 1 {
				residual[y * size + x] -= residual[(y - 1) * size + x]
			}
		}
	} else {
		for y in 0 ..< size {
			for x := size - 1; x >= 1; x -= 1 {
				residual[y * size + x] -= residual[y * size + x - 1]
			}
		}
	}
}

inverse_rdpcm :: proc(residual: []$T, size: int, vertical: bool) #no_bounds_check {
	if vertical {
		for y in 1 ..< size {
			for x in 0 ..< size {
				residual[y * size + x] += residual[(y - 1) * size + x]
			}
		}
	} else {
		for y in 0 ..< size {
			for x in 1 ..< size {
				residual[y * size + x] += residual[y * size + x - 1]
			}
		}
	}
}

// ---------------------------------------------------------------------------
// 8.6.2-8.6.4 extended forms. The i16 kernels above are the encoder's path and
// the decoder's default range; these i32/i64 forms cover the transquant-bypass
// pass-through and the extended-precision coefficient range of 8.6.3's
// log2TransformRange (max(15, bit_depth + 6)). At bit depth 8 every formula
// reduces bit-for-bit to the default-range kernel. Equations follow the spec
// numbering used by oxideav-h265 src/transform.rs; gen2brain/h265
// hevc/itransform.go is the second reference.
// ---------------------------------------------------------------------------

// dequantize_ext is 8.6.3 (eq. 8-300..8-309) in the i32 domain with the flat
// m = 16 matrix: `qcoeff` are the parsed TransCoeffLevel values, `coeff` the
// scaled coefficients clipped to [coeffMin, coeffMax].
dequantize_ext :: proc(qcoeff, coeff: []i32, size, bit_depth, qp_scaled: int) #no_bounds_check {
	rng := max(15, bit_depth + 6)
	shift := bit_depth + log2_size(size) + 10 - rng
	scale := i64(INV_QUANT_SCALES[qp_scaled % 6]) << uint(qp_scaled / 6)
	add := i64(1) << uint(shift - 1)
	lo := i64(-1) << uint(rng)
	hi := (i64(1) << uint(rng)) - 1

	for i in 0 ..< size * size {
		q := (i64(qcoeff[i]) * 16 * scale + add) >> uint(shift)
		coeff[i] = i32(clamp(q, lo, hi))
	}
}

// dequantize_scaled_ext is 8.6.3 with a ScalingFactor matrix (16x16/32x32 DC
// from the caller's `dc_scale`), eq. 8-309's m[x][y] product in i64.
dequantize_scaled_ext :: proc(
	qcoeff, coeff: []i32,
	size, bit_depth, qp_scaled: int,
	scale_m: []u8,
	dc_scale: u8,
) #no_bounds_check {
	rng := max(15, bit_depth + 6)
	shift := bit_depth + log2_size(size) + 10 - rng
	scale := i64(INV_QUANT_SCALES[qp_scaled % 6]) << uint(qp_scaled / 6)
	add := i64(1) << uint(shift - 1)
	lo := i64(-1) << uint(rng)
	hi := (i64(1) << uint(rng)) - 1

	for y in 0 ..< size {
		for x in 0 ..< size {
			m := i64(scale_m[scaling_pos(size, x, y)])
			if size >= 16 && x == 0 && y == 0 do m = i64(dc_scale)
			q := (i64(qcoeff[y * size + x]) * m * scale + add) >> uint(shift)
			coeff[y * size + x] = i32(clamp(q, lo, hi))
		}
	}
}

// inverse_transform_ext is 8.6.4.1 in sixty-four-bit products, with the
// equation 8-299 bdShift folded into the row stage. `dst4` selects the 8.6.4.2
// DST-VII basis for a 4x4 luma intra block. The intermediate column stage
// clips to the 8.6.3 coefficient range exactly as the default kernel clips to
// the 15-bit one.
inverse_transform_ext :: proc(
	size: int,
	src, dst: []i32,
	bit_depth: int,
	dst4: bool,
) #no_bounds_check {
	basis := dst4 ? DST_4[:] : basis_for(size)
	rng := max(15, bit_depth + 6)
	lo := i64(-1) << uint(rng)
	hi := (i64(1) << uint(rng)) - 1
	shift := max(20 - bit_depth, 11)
	round := i64(1) << uint(shift - 1)

	tmp: [32 * 32]i64 = ---

	// First dimension: tmp[j][k] = sum_i basis[i][k] * src[i][j].
	for j in 0 ..< size {
		for k in 0 ..< size {
			acc: i64
			for i in 0 ..< size do acc += i64(basis[i * size + k]) * i64(src[i * size + j])
			tmp[j * size + k] = clamp((acc + 64) >> 7, lo, hi)
		}
	}

	// Second dimension: dst[j][k] = sum_i basis[i][k] * tmp[i][j], rounded
	// by bdShift.
	for j in 0 ..< size {
		for k in 0 ..< size {
			acc: i64
			for i in 0 ..< size do acc += i64(basis[i * size + k]) * tmp[i * size + j]
			dst[j * size + k] = i32((acc + round) >> uint(shift))
		}
	}
}

// inverse_transform_skip_ext is the eq. 8-298 tsShift left-shift followed by
// the eq. 8-299 bdShift round, folded into one shift (extended precision keeps
// bdShift at max(20 - bit_depth, 11)).
inverse_transform_skip_ext :: proc(coeff, residual: []i32, size, bit_depth: int) #no_bounds_check {
	shift := max(20 - bit_depth, 11) - (5 + log2_size(size))
	add := i32(1) << uint(shift - 1)
	for i in 0 ..< size * size {
		residual[i] = (coeff[i] + add) >> uint(shift)
	}
}

// residual_block is the 8.6.2 scaling and transformation process for one
// transform block: TransCoeffLevel becomes the residual array. The three
// branches are `bypass` (eq. 8-297 pass-through), `skip` (scale, eq. 8-298,
// eq. 8-299) and the plain scale + 8.6.4 transform + eq. 8-299. `rotate` is
// eq. 8-297's rotateCoeffs (4x4 intra under transform_skip_rotation); `dst4`
// selects the DST-VII transform. `scale_m` is the block's ScalingFactor matrix
// (empty for the flat-16 path; the caller folds the transform-skip-n>4
// exception of 8.6.3 into the choice). Residual DPCM (8.6.5) is applied by
// the caller after this process.
residual_block :: proc(
	levels, residual: []i32,
	size, bit_depth, qp_scaled: int,
	scale_m: []u8,
	dc_scale: u8,
	bypass, skip, rotate, dst4: bool,
) #no_bounds_check {
	n2 := size * size

	if bypass {
		// The levels are the residual: no scaling, no transform, no
		// bdShift. Rotation is the index mirror i -> n2 - 1 - i.
		if rotate {
			for i in 0 ..< n2 do residual[i] = levels[n2 - 1 - i]
		} else {
			for i in 0 ..< n2 do residual[i] = levels[i]
		}

		return
	}

	d: [32 * 32]i32 = ---

	if len(scale_m) > 0 {
		dequantize_scaled_ext(levels, d[:n2], size, bit_depth, qp_scaled, scale_m, dc_scale)
	} else {
		dequantize_ext(levels, d[:n2], size, bit_depth, qp_scaled)
	}

	// rotateCoeffs on the scaled coefficients of a transform-skip block.
	if skip && rotate {
		for i in 0 ..< n2 / 2 do d[i], d[n2 - 1 - i] = d[n2 - 1 - i], d[i]
	}

	if skip {
		inverse_transform_skip_ext(d[:n2], residual, size, bit_depth)
	} else {
		inverse_transform_ext(size, d[:n2], residual, bit_depth, dst4)
	}
}

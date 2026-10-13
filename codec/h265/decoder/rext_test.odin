package h265_decoder

import hevc ".."
import "core:testing"

// ---------------------------------------------------------------------------
// Spec-form pins for the 8.6.2-8.6.5 extended kernels (hevc.residual_block and
// friends). The expected values are the equation-level vectors from
// third_party/oxideav-h265 src/transform.rs (its comments carry the spec
// equation numbers) with third_party/h265 hevc/itransform.go as the second
// reference. The i16 kernels are already byte-exact against reference
// decoders; the cross-check at bit depth 8 (where log2TransformRange is 15
// and bdShift is 12 and every extended formula reduces to the default range)
// pins the two paths to each other.
// ---------------------------------------------------------------------------

// lcg32 is a deterministic small-magnitude fill for cross-check blocks.
lcg32 :: proc(state: ^u32) -> i32 {
	s := state^ * 1664525 + 1013904223
	state^ = s
	return (i32(s >> 12) & 0x7fff) - 0x3fff
}

@(test)
test_bypass_passes_levels_through :: proc(t: ^testing.T) {
	// Rust transform.rs bypass_copies_levels_verbatim: the transquant-bypass
	// branch copies TransCoeffLevel with no scaling, no transform and no
	// bdShift. Vectors are (x, y, level): (0,0)=7, (1,0)=5, (3,3)=-2.
	levels := [16]i32{7, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -2}
	res: [16]i32 = ---

	hevc.residual_block(levels[:], res[:], 4, 8, 26, nil, 16, true, false, false, false)

	for i in 0 ..< 16 {
		testing.expectf(
			t,
			res[i] == levels[i],
			"bypass residual[%d] = %d, want %d",
			i,
			res[i],
			levels[i],
		)
	}
}

@(test)
test_bypass_rotate_mirrors_coefficients :: proc(t: ^testing.T) {
	// Rust bypass_rotate_mirrors_coefficients: eq. 8-297's rotateCoeffs maps
	// r[x][y] to level[n-x-1][n-y-1], so the level at (0,0) lands at (3,3).
	levels: [16]i32
	levels[0] = 9
	res: [16]i32 = ---

	hevc.residual_block(levels[:], res[:], 4, 8, 0, nil, 16, true, false, true, false)

	testing.expectf(t, res[3 * 4 + 3] == 9, "rotated bypass residual[15] = %d, want 9", res[15])
	testing.expectf(t, res[0] == 0, "rotated bypass residual[0] = %d, want 0", res[0])
}

@(test)
test_transform_skip_residual :: proc(t: ^testing.T) {
	// Rust transform_skip_shifts_without_transform: level 1 at (x=2, y=1),
	// qP 4, 4x4, 8-bit. 8.6.3 gives d = (1*16*64 + 16) >> 5 = 32; eq. 8-298
	// shifts by tsShift 7 and eq. 8-299 rounds by bdShift 12:
	// (32 << 7 + 2048) >> 12 = 1.
	levels: [16]i32
	levels[1 * 4 + 2] = 1
	res: [16]i32 = ---

	hevc.residual_block(levels[:], res[:], 4, 8, 4, nil, 16, false, true, false, false)

	testing.expectf(t, res[6] == 1, "skip residual[6] = %d, want 1", res[6])
	for i in 0 ..< 16 {
		if i == 6 do continue
		testing.expectf(t, res[i] == 0, "skip residual[%d] = %d, want 0", i, res[i])
	}
}

@(test)
test_scale_clips_to_coeff_max :: proc(t: ^testing.T) {
	// Rust scale_clips_to_coeff_max: a huge level at a large qP saturates the
	// 8.6.3 coefficient range (32767 at the default 15-bit log2TransformRange).
	levels: [16]i32
	levels[0] = 30000
	coeffs: [16]i32 = ---

	hevc.dequantize_ext(levels[:], coeffs[:], 4, 8, 51)

	testing.expectf(t, coeffs[0] == 32767, "clipped coeff = %d, want 32767", coeffs[0])
}

@(test)
test_dc_only_inverse_dct :: proc(t: ^testing.T) {
	// Rust dc_only_dct_4x4_exact pins the raw 8.6.4 output of a DC-only
	// block at the constant 2048 (the all-64 basis row, eq. 8-319). This
	// kernel folds the eq. 8-299 bdShift in, so (2048 + 2048) >> 12 = 1 at
	// bit depth 8.
	src: [16]i32
	src[0] = 64
	dst: [16]i32 = ---

	hevc.inverse_transform_ext(4, src[:], dst[:], 8, false)

	for i in 0 ..< 16 {
		testing.expectf(t, dst[i] == 1, "dc residual[%d] = %d, want 1", i, dst[i])
	}
}

@(test)
test_dst4_differs_from_dct4 :: proc(t: ^testing.T) {
	// Rust dst_path_selected_for_4x4_intra_luma: the DST-VII column 0 is
	// {29, 74, 84, 55} against the DCT's {64, 90, 90, 90}, so a DC impulse
	// must separate the two transforms.
	src: [16]i32
	src[0] = 100
	dct: [16]i32 = ---
	dst: [16]i32 = ---

	hevc.inverse_transform_ext(4, src[:], dct[:], 8, false)
	hevc.inverse_transform_ext(4, src[:], dst[:], 8, true)

	diff := false
	for i in 0 ..< 16 {
		if dct[i] != dst[i] do diff = true
	}
	testing.expect(t, diff)
}

@(test)
test_extended_precision_keeps_wide_coefficients :: proc(t: ^testing.T) {
	// Extended precision raises log2TransformRange to bit_depth + 6, so a
	// 10-bit scaled coefficient survives past the 15-bit clamp: level 1000
	// at QP 0 (qp_scaled 12) is (1000*16*(40<<2) + 32) >> 6 = 40000.
	levels: [16]i32
	levels[0] = 1000
	coeffs: [16]i32 = ---

	hevc.dequantize_ext(levels[:], coeffs[:], 4, 10, 12)

	testing.expectf(t, coeffs[0] == 40000, "wide coeff = %d, want 40000", coeffs[0])
}

@(test)
test_ext_matches_default_range_at_bit_depth_8 :: proc(t: ^testing.T) {
	// At bit depth 8 the extended formulas reduce to the default range and
	// must agree with the validated i16 kernels exactly: same dequantize,
	// same rotateCoeffs mirror, same skip / DST-VII / DCT dispatch.
	seed: u32 = 42

	for size in ([]int{4, 8, 16, 32}) {
		for trial in 0 ..< 4 {
			levels32: [32 * 32]i32
			levels16: [32 * 32]i16

			for i in 0 ..< size * size {
				v := lcg32(&seed)
				levels32[i] = v
				levels16[i] = i16(v)
			}

			qp := trial * 17 % 52
			skip := trial & 1 != 0
			rotate := trial & 2 != 0 && size == 4
			dst4 := size == 4 && trial == 3

			res32: [32 * 32]i32 = ---
			hevc.residual_block(
				levels32[:size * size],
				res32[:size * size],
				size,
				8,
				qp,
				nil,
				16,
				false,
				skip,
				rotate,
				dst4,
			)

			coeffs: [32 * 32]i16
			res16: [32 * 32]i16
			hevc.dequantize(levels16[:size * size], coeffs[:size * size], size, 8, qp)
			if skip && rotate {
				for i in 0 ..< size * size / 2 {
					coeffs[i], coeffs[size * size - 1 - i] = coeffs[size * size - 1 - i], coeffs[i]
				}
			}

			switch {
			case skip:
				hevc.inverse_transform_skip(coeffs[:size * size], res16[:size * size], size, 8)
			case dst4:
				hevc.inverse_transform_dst4(coeffs[:size * size], res16[:size * size], 8)
			case:
				hevc.inverse_transform(size, coeffs[:size * size], res16[:size * size], 8)
			}

			for i in 0 ..< size * size {
				testing.expectf(
					t,
					res32[i] == i32(res16[i]),
					"size %d trial %d residual[%d]: ext %d != default %d",
					size,
					trial,
					i,
					res32[i],
					res16[i],
				)
			}
		}
	}
}

@(test)
test_scaled_dequant_ext_matches_default_at_bit_depth_8 :: proc(t: ^testing.T) {
	// The ScalingFactor-matrix dequant must agree between domains at bit
	// depth 8 as well (the 16x16 DC entry reads the separate DC list).
	seed: u32 = 7
	smat: [64]u8
	for i in 0 ..< 64 do smat[i] = u8(4 + i % 17)

	for size in ([]int{4, 8, 16, 32}) {
		levels32: [32 * 32]i32
		levels16: [32 * 32]i16

		for i in 0 ..< size * size {
			v := lcg32(&seed)
			levels32[i] = v
			levels16[i] = i16(v)
		}

		qp := 5 + size
		c32: [32 * 32]i32 = ---
		c16: [32 * 32]i16

		hevc.dequantize_scaled_ext(
			levels32[:size * size],
			c32[:size * size],
			size,
			8,
			qp,
			smat[:],
			23,
		)
		hevc.dequantize_scaled(levels16[:size * size], c16[:size * size], size, 8, qp, smat[:], 23)

		for i in 0 ..< size * size {
			testing.expectf(
				t,
				c32[i] == i32(c16[i]),
				"size %d scaled coeff[%d]: ext %d != default %d",
				size,
				i,
				c32[i],
				c16[i],
			)
		}
	}
}

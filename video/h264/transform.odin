package h264

import common "../../common"
import "base:intrinsics"
import "core:simd"

// ---------------------------------------------------------------------------
// Scaling (8.5.9) and inverse transforms (8.5.10 - 8.5.13)
// ---------------------------------------------------------------------------

// Zigzag scans as decoded-order -> raster position
zigzag_scan_8x8: [64]u8 = {
	0,
	1,
	8,
	16,
	9,
	2,
	3,
	10,
	17,
	24,
	32,
	25,
	18,
	11,
	4,
	5,
	12,
	19,
	26,
	33,
	40,
	48,
	41,
	34,
	27,
	20,
	13,
	6,
	7,
	14,
	21,
	28,
	35,
	42,
	49,
	56,
	57,
	50,
	43,
	36,
	29,
	22,
	15,
	23,
	30,
	37,
	44,
	51,
	58,
	59,
	52,
	45,
	38,
	31,
	39,
	46,
	53,
	60,
	61,
	54,
	47,
	55,
	62,
	63,
}

// normAdjust4x4 (8-315): v[qp % 6][class], class 0: both even, 1: both odd, 2: mixed
norm_adjust_4x4: [6][3]i32 = {
	{10, 16, 13},
	{11, 18, 14},
	{13, 20, 16},
	{14, 23, 18},
	{16, 25, 20},
	{18, 29, 23},
}

// LevelScale tables of the active SPS/PPS: weight scale (flat 16 or a scaling
// list, with the fall-back rules of Table 7-2) times normAdjust.
compute_level_scales :: proc(
	scales: ^Level_Scales,
	sequence_parameters: ^Sequence_Parameter_Set,
	picture_parameters: ^Picture_Parameter_Set,
) {
	lists_4x4: [6][16]u8 // raster order
	lists_8x8: [6][64]u8
	for &list in lists_4x4 do for &v in list do v = 16
	for &list in lists_8x8 do for &v in list do v = 16

	if sequence_parameters.has_scaling_matrices ||
	   picture_parameters.pic_scaling_matrix_present_flag {
		// Rule A from the SPS, rule B from the PPS on top of it
		apply :: proc(
			lists_4x4: ^[6][16]u8,
			lists_8x8: ^[6][64]u8,
			present, use_default: [8]bool,
			sent_4x4: [6][16]u8,
			sent_8x8: [2][64]u8,
			chroma_present, chroma_use_default: [4]bool,
			chroma_sent_8x8: [4][64]u8,
			is_444: bool,
			fallback_is_default: bool,
		) {
			for i in 0 ..< 8 {
				if present[i] && !use_default[i] {
					if i < 6 {
						for k in 0 ..< 16 do lists_4x4[i][zigzag_scan_4x4[k]] = sent_4x4[i][k]
					} else {
						for k in 0 ..< 64 do lists_8x8[i - 6][zigzag_scan_8x8[k]] = sent_8x8[i - 6][k]
					}
					continue
				}
				use_default :=
					use_default[i] ||
					(fallback_is_default && (i == 0 || i == 3 || i == 6 || i == 7))
				switch {
				case i < 6 && use_default:
					lists_4x4[i] = default_scaling_4x4[i / 3]
				case i < 6 && (i == 1 || i == 2 || i == 4 || i == 5) && !present[i]:
					lists_4x4[i] = lists_4x4[i - 1]
				case i >= 6 && use_default:
					lists_8x8[i - 6] = default_scaling_8x8[i - 6]
				}
			}
			if is_444 {
				for c in 0 ..< 4 {
					dst := 2 + c
					if chroma_present[c] && !chroma_use_default[c] {
						for k in 0 ..< 64 do lists_8x8[dst][zigzag_scan_8x8[k]] = chroma_sent_8x8[c][k]
					} else if chroma_use_default[c] {
						lists_8x8[dst] = default_scaling_8x8[c & 1]
					} else if !chroma_present[c] {
						lists_8x8[dst] = lists_8x8[dst - 2]
					}
				}
			}
		}
		is_444 := sequence_parameters.chroma_format == .YUV_444
		if sequence_parameters.has_scaling_matrices {
			apply(
				&lists_4x4,
				&lists_8x8,
				sequence_parameters.has_scaling_list,
				sequence_parameters.use_default_scaling_list,
				sequence_parameters.scaling_list_4x4,
				sequence_parameters.scaling_list_8x8,
				sequence_parameters.has_chroma_scaling_list,
				sequence_parameters.use_default_chroma_scaling_list,
				sequence_parameters.chroma_scaling_list_8x8,
				is_444,
				true,
			)
		}
		if picture_parameters.pic_scaling_matrix_present_flag {
			apply(
				&lists_4x4,
				&lists_8x8,
				picture_parameters.has_scaling_list,
				picture_parameters.use_default_scaling_list,
				picture_parameters.scaling_list_4x4,
				picture_parameters.scaling_list_8x8,
				picture_parameters.has_chroma_scaling_list,
				picture_parameters.use_default_chroma_scaling_list,
				picture_parameters.chroma_scaling_list_8x8,
				is_444,
				!sequence_parameters.has_scaling_matrices,
			)
		}
	}

	for list in 0 ..< 6 do for m in 0 ..< 6 do for pos in 0 ..< 16 {
		x, y := pos & 3, pos >> 2
		class := x & 1 == 0 && y & 1 == 0 ? 0 : x & 1 == 1 && y & 1 == 1 ? 1 : 2
		scales.scale_4x4[list][m][pos] = i32(lists_4x4[list][pos]) * norm_adjust_4x4[m][class]
	}
	num_8x8 := sequence_parameters.chroma_format == .YUV_444 ? 6 : 2
	for list in 0 ..< num_8x8 do for m in 0 ..< 6 do for pos in 0 ..< 64 {
		scales.scale_8x8[list][m][pos] = i32(lists_8x8[list][pos]) * i32(norm_adjust_8x8[m][pos])
	}
}

// Scan order -> raster order lane permutation of a 4x4 block
@(private = "file")
raster_from_scan_4x4 :: proc(v: #simd[16]$E) -> #simd[16]E {
	return simd.swizzle(v, 0, 1, 5, 6, 2, 4, 7, 12, 3, 8, 11, 13, 9, 10, 14, 15)
}

// Scaling of 16 raster coefficients (8.5.12.1) in registers
@(private = "file")
scale_16 :: #force_inline proc(levels: #simd[16]i32, scale: ^[16]i32, qp: i32) -> #simd[16]i32 {
	product := simd.mul(levels, intrinsics.unaligned_load((^#simd[16]i32)(scale)))
	qp_per := u32(qp / 6)
	if qp >= 24 do return simd.shl(product, (#simd[16]u32)(qp_per - 4))
	return simd.shr(
		simd.add(product, (#simd[16]i32)(i32(1) << (3 - qp_per))),
		(#simd[16]u32)(4 - qp_per),
	)
}

// Dequantise a 4x4 block from its scan-order levels and add its inverse
// transform to the prediction. `dc` replaces the DC coefficient when
// `dc_separate` (Intra 16x16 luma and chroma, whose DC is transformed apart).
// Samples are u8, or u16 up to `pixel_max`; levels i16, or i32 above 8 bits.
reconstruct_4x4 :: proc(
	scales: ^Level_Scales,
	pixels: [^]$T,
	stride: int,
	levels: ^[16]$L,
	has_ac: bool,
	qp: i32,
	list: int,
	dc_separate: bool,
	dc: i32,
	pixel_max: i32 = 255,
) #no_bounds_check {
	coeffs: #simd[16]i32
	if has_ac {
		raster := raster_from_scan_4x4(intrinsics.unaligned_load((^#simd[16]L)(levels)))
		coeffs = scale_16((#simd[16]i32)(raster), &scales.scale_4x4[list][qp % 6], qp)
	}
	if dc_separate do coeffs = simd.replace(coeffs, 0, dc)
	idct_4x4_add_lanes(
		pixels,
		stride,
		simd.swizzle(coeffs, 0, 1, 2, 3),
		simd.swizzle(coeffs, 4, 5, 6, 7),
		simd.swizzle(coeffs, 8, 9, 10, 11),
		simd.swizzle(coeffs, 12, 13, 14, 15),
		pixel_max,
	)
}

// Dequantise an 8x8 block from its scan-order levels (8.5.13.1) and add its inverse transform
reconstruct_8x8 :: proc(
	scales: ^Level_Scales,
	pixels: [^]$T,
	stride: int,
	levels: ^[64]$L,
	qp: i32,
	list: int,
	pixel_max: i32 = 255,
) #no_bounds_check {
	scan := intrinsics.unaligned_load((^#simd[64]L)(levels))
	raster := simd.shuffle(
		scan,
		scan,
		0,
		1,
		5,
		6,
		14,
		15,
		27,
		28,
		2,
		4,
		7,
		13,
		16,
		26,
		29,
		42,
		3,
		8,
		12,
		17,
		25,
		30,
		41,
		43,
		9,
		11,
		18,
		24,
		31,
		40,
		44,
		53,
		10,
		19,
		23,
		32,
		39,
		45,
		52,
		54,
		20,
		22,
		33,
		38,
		46,
		51,
		55,
		60,
		21,
		34,
		37,
		47,
		50,
		56,
		59,
		61,
		35,
		36,
		48,
		49,
		57,
		58,
		62,
		63,
	)
	wide := (#simd[64]i32)(raster)
	scale := intrinsics.unaligned_load((^#simd[64]i32)(&scales.scale_8x8[list][qp % 6]))
	product := simd.mul(wide, scale)
	qp_per := u32(qp / 6)
	coeffs: #simd[64]i32
	if qp >= 36 {
		coeffs = simd.shl(product, (#simd[64]u32)(qp_per - 6))
	} else {
		coeffs = simd.shr(
			simd.add(product, (#simd[64]i32)(i32(1) << (5 - qp_per))),
			(#simd[64]u32)(6 - qp_per),
		)
	}
	rows: [8]#simd[8]i32
	rows[0] = simd.swizzle(coeffs, 0, 1, 2, 3, 4, 5, 6, 7)
	rows[1] = simd.swizzle(coeffs, 8, 9, 10, 11, 12, 13, 14, 15)
	rows[2] = simd.swizzle(coeffs, 16, 17, 18, 19, 20, 21, 22, 23)
	rows[3] = simd.swizzle(coeffs, 24, 25, 26, 27, 28, 29, 30, 31)
	rows[4] = simd.swizzle(coeffs, 32, 33, 34, 35, 36, 37, 38, 39)
	rows[5] = simd.swizzle(coeffs, 40, 41, 42, 43, 44, 45, 46, 47)
	rows[6] = simd.swizzle(coeffs, 48, 49, 50, 51, 52, 53, 54, 55)
	rows[7] = simd.swizzle(coeffs, 56, 57, 58, 59, 60, 61, 62, 63)
	idct_8x8_add_lanes(pixels, stride, rows, pixel_max)
}

// Levels in scan order to scaled coefficients in raster order (8.5.12.1).
dequant_4x4 :: proc(
	scales: ^Level_Scales,
	levels: []i16,
	coeffs: ^[16]i32,
	qp: i32,
	list: int,
	ac_only: bool,
) #no_bounds_check {
	scale := &scales.scale_4x4[list][qp % 6]
	qp_per := uint(qp / 6)
	for i in 0 ..< len(levels) {
		level := i32(levels[i])
		if level == 0 do continue
		pos := int(zigzag_scan_4x4[i + (ac_only ? 1 : 0)])
		if qp >= 24 {
			coeffs[pos] = (level * scale[pos]) << (qp_per - 4)
		} else {
			coeffs[pos] = (level * scale[pos] + (1 << (3 - qp_per))) >> (4 - qp_per)
		}
	}
}

dequant_8x8 :: proc(
	scales: ^Level_Scales,
	levels: []i16,
	coeffs: ^[64]i32,
	qp: i32,
	list: int,
) #no_bounds_check {
	scale := &scales.scale_8x8[list][qp % 6]
	qp_per := uint(qp / 6)
	for i in 0 ..< 64 {
		level := i32(levels[i])
		if level == 0 do continue
		pos := int(zigzag_scan_8x8[i])
		if qp >= 36 {
			coeffs[pos] = (level * scale[pos]) << (qp_per - 6)
		} else {
			coeffs[pos] = (level * scale[pos] + (1 << (5 - qp_per))) >> (6 - qp_per)
		}
	}
}

// A scaled DC value stored back as a level: i16 levels saturate (8 bits),
// i32 levels hold the spec's range.
@(private = "file")
store_dc :: #force_inline proc "contextless" (dc: ^$L, v: i32) {
	when L == i16 {dc^ = i16(clamp(v, -32768, 32767))} else {dc^ = v}
}

// Intra 16x16 luma (or 4:4:4 Cb/Cr) DC: levels in scan order -> inverse Hadamard -> scaled DC per 4x4 block in raster order (8.5.10)
luma_dc_dequant_idct :: proc(scales: ^Level_Scales, dc: ^[16]$L, qp: i32, list: int = 0) #no_bounds_check {
	c: [16]i32
	for i in 0 ..< 16 do c[zigzag_scan_4x4[i]] = i32(dc[i])
	rows: [16]i32
	for i in 0 ..< 4 {
		r := c[i * 4:]
		rows[i * 4 + 0] = r[0] + r[1] + r[2] + r[3]
		rows[i * 4 + 1] = r[0] + r[1] - r[2] - r[3]
		rows[i * 4 + 2] = r[0] - r[1] - r[2] + r[3]
		rows[i * 4 + 3] = r[0] - r[1] + r[2] - r[3]
	}
	scale := scales.scale_4x4[list][qp % 6][0]
	qp_per := uint(qp / 6)
	for j in 0 ..< 4 {
		f := [4]i32 {
			rows[j] + rows[4 + j] + rows[8 + j] + rows[12 + j],
			rows[j] + rows[4 + j] - rows[8 + j] - rows[12 + j],
			rows[j] - rows[4 + j] - rows[8 + j] + rows[12 + j],
			rows[j] - rows[4 + j] + rows[8 + j] - rows[12 + j],
		}
		for i in 0 ..< 4 {
			v :=
				qp >= 36 ? (f[i] * scale) << (qp_per - 6) : (f[i] * scale + (1 << (5 - qp_per))) >> (6 - qp_per)
			store_dc(&dc[i * 4 + j], v)
		}
	}
}

// Chroma DC (4:2:0): 2x2 inverse Hadamard and scaling (8.5.11)
chroma_dc_dequant_idct :: proc(scales: ^Level_Scales, dc: ^[4]$L, qp: i32, list: int) {
	c := [4]i32{i32(dc[0]), i32(dc[1]), i32(dc[2]), i32(dc[3])}
	f := [4]i32 {
		c[0] + c[1] + c[2] + c[3],
		c[0] - c[1] + c[2] - c[3],
		c[0] + c[1] - c[2] - c[3],
		c[0] - c[1] - c[2] + c[3],
	}
	scale := scales.scale_4x4[list][qp % 6][0]
	for i in 0 ..< 4 do store_dc(&dc[i], ((f[i] * scale) << uint(qp / 6)) >> 5)
}

// Chroma DC (4:2:2): levels in their 2x4 scan order (8-305), inverse
// transform (8-325) and scaling at QP'C + 3 (8.5.11.2), returned per chroma
// 4x4 block in raster order (two per row).
chroma_dc_dequant_idct_422 :: proc(scales: ^Level_Scales, dc: ^[8]$L, qp: i32, list: int) {
	// c[row][column] of the 4x2 array
	c := [4][2]i32 {
		{i32(dc[0]), i32(dc[2])},
		{i32(dc[1]), i32(dc[5])},
		{i32(dc[3]), i32(dc[6])},
		{i32(dc[4]), i32(dc[7])},
	}
	qp_dc := qp + 3
	scale := scales.scale_4x4[list][qp_dc % 6][0]
	shift := uint(qp_dc / 6)
	for j in 0 ..< 2 {
		column := [4]i32 {
			c[0][j] + c[1][j] + c[2][j] + c[3][j],
			c[0][j] + c[1][j] - c[2][j] - c[3][j],
			c[0][j] - c[1][j] - c[2][j] + c[3][j],
			c[0][j] - c[1][j] + c[2][j] - c[3][j],
		}
		for i in 0 ..< 4 do c[i][j] = column[i]
	}
	for i in 0 ..< 4 {
		f := [2]i32{c[i][0] + c[i][1], c[i][0] - c[i][1]}
		for j in 0 ..< 2 {
			v := qp_dc >= 36 ? (f[j] * scale) << (shift - 6) : (f[j] * scale + (1 << (5 - shift))) >> (6 - shift)
			store_dc(&dc[i * 2 + j], v)
		}
	}
}

// 4x4 inverse transform of scaled coefficients added to the prediction
// (8.5.12.2): rows first, then columns, each pass as lane-wise vector ops.
idct_4x4_add :: proc(pixels: [^]u8, stride: int, coeffs: ^[16]i32) #no_bounds_check {
	V :: #simd[4]i32
	idct_4x4_add_lanes(
		pixels,
		stride,
		intrinsics.unaligned_load((^V)(&coeffs[0])),
		intrinsics.unaligned_load((^V)(&coeffs[4])),
		intrinsics.unaligned_load((^V)(&coeffs[8])),
		intrinsics.unaligned_load((^V)(&coeffs[12])),
	)
}

idct_4x4_add_lanes :: proc(
	pixels: [^]$T,
	stride: int,
	r0, r1, r2, r3: #simd[4]i32,
	pixel_max: i32 = 255,
) #no_bounds_check {
	V :: #simd[4]i32
	one := (#simd[4]u32)(1)
	// Columns of the coefficient block as vectors over the row index
	c := common.transpose([4]V{r0, r1, r2, r3})
	c0, c1, c2, c3 := c[0], c[1], c[2], c[3]
	// Row pass: each row's 1-D transform, lanes are the rows
	e0 := simd.add(c0, c2)
	e1 := simd.sub(c0, c2)
	e2 := simd.sub(simd.shr(c1, one), c3)
	e3 := simd.add(c1, simd.shr(c3, one))
	f := common.transpose([4]V{simd.add(e0, e3), simd.add(e1, e2), simd.sub(e1, e2), simd.sub(e0, e3)})
	f0, f1, f2, f3 := f[0], f[1], f[2], f[3]
	// Column pass on the rows of f
	g0 := simd.add(f0, f2)
	g1 := simd.sub(f0, f2)
	g2 := simd.sub(simd.shr(f1, one), f3)
	g3 := simd.add(f1, simd.shr(f3, one))
	rows := [4]V{simd.add(g0, g3), simd.add(g1, g2), simd.sub(g1, g2), simd.sub(g0, g3)}
	for y in 0 ..< 4 {
		pred := (V)(intrinsics.unaligned_load((^#simd[4]T)(&pixels[y * stride])))
		v := simd.add(pred, simd.shr(simd.add(rows[y], 32), (#simd[4]u32)(6)))
		intrinsics.unaligned_store(
			(^#simd[4]T)(&pixels[y * stride]),
			(#simd[4]T)(simd.clamp(v, 0, V(pixel_max))),
		)
	}
}

// 8x8 inverse transform (8.5.13.2) added to the prediction: rows first,
// then columns, each 1-D pass as lane-wise ops on the eight vectors.
idct_8x8_add :: proc(pixels: [^]u8, stride: int, coeffs: ^[64]i32) #no_bounds_check {
	V :: #simd[8]i32
	rows: [8]V
	for i in 0 ..< 8 do rows[i] = intrinsics.unaligned_load((^V)(&coeffs[i * 8]))
	idct_8x8_add_lanes(pixels, stride, rows)
}

idct_8x8_add_lanes :: proc(
	pixels: [^]$T,
	stride: int,
	rows: [8]#simd[8]i32,
	pixel_max: i32 = 255,
) #no_bounds_check {
	V :: #simd[8]i32
	pass :: #force_inline proc(d: [8]V) -> [8]V {
		one, two := (#simd[8]u32)(1), (#simd[8]u32)(2)
		a0 := simd.add(d[0], d[4])
		a1 := simd.sub(simd.sub(simd.sub(d[5], d[3]), d[7]), simd.shr(d[7], one))
		a2 := simd.sub(d[0], d[4])
		a3 := simd.sub(simd.sub(simd.add(d[1], d[7]), d[3]), simd.shr(d[3], one))
		a4 := simd.sub(simd.shr(d[2], one), d[6])
		a5 := simd.add(simd.add(simd.sub(d[7], d[1]), d[5]), simd.shr(d[5], one))
		a6 := simd.add(d[2], simd.shr(d[6], one))
		a7 := simd.add(simd.add(simd.add(d[3], d[5]), d[1]), simd.shr(d[1], one))
		b0 := simd.add(a0, a6)
		b1 := simd.add(a1, simd.shr(a7, two))
		b2 := simd.add(a2, a4)
		b3 := simd.add(a3, simd.shr(a5, two))
		b4 := simd.sub(a2, a4)
		b5 := simd.sub(simd.shr(a3, two), a5)
		b6 := simd.sub(a0, a6)
		b7 := simd.sub(a7, simd.shr(a1, two))
		return {
			simd.add(b0, b7),
			simd.add(b2, b5),
			simd.add(b4, b3),
			simd.add(b6, b1),
			simd.sub(b6, b1),
			simd.sub(b4, b3),
			simd.sub(b2, b5),
			simd.sub(b0, b7),
		}
	}
	columns := pass(common.transpose(rows)) // row pass: lanes are the rows
	out := pass(common.transpose(columns)) // column pass: lanes are the columns
	for y in 0 ..< 8 {
		pred := (V)(intrinsics.unaligned_load((^#simd[8]T)(&pixels[y * stride])))
		v := simd.add(pred, simd.shr(simd.add(out[y], 32), (#simd[8]u32)(6)))
		intrinsics.unaligned_store(
			(^#simd[8]T)(&pixels[y * stride]),
			(#simd[8]T)(simd.clamp(v, 0, V(pixel_max))),
		)
	}
}

// Transform-bypass reconstruction (8.5.10 - 8.5.15 when TransformBypassModeFlag == 1):
// `dpcm_dir` is 0 for vertical DPCM (8.5.15), 1 for horizontal DPCM (8.5.15), or -1 for none.
reconstruct_bypass_4x4 :: proc(
	pixels: [^]$T,
	stride: int,
	levels: ^[16]$L,
	has_ac: bool,
	dc_separate: bool,
	dc: i32,
	dpcm_dir: int = -1,
	pixel_max: i32 = 255,
) #no_bounds_check {
	r: [16]i32
	if has_ac {
		for k in 0 ..< 16 do r[zigzag_scan_4x4[k]] = i32(levels[k])
	}
	if dc_separate do r[0] = dc
	if dpcm_dir == 0 {
		for y in 1 ..< 4 do for x in 0 ..< 4 {
			r[y * 4 + x] += r[(y - 1) * 4 + x]
		}
	} else if dpcm_dir == 1 {
		for y in 0 ..< 4 do for x in 1 ..< 4 {
			r[y * 4 + x] += r[y * 4 + x - 1]
		}
	}
	for y in 0 ..< 4 do for x in 0 ..< 4 {
		v := i32(pixels[y * stride + x]) + r[y * 4 + x]
		pixels[y * stride + x] = T(clamp(v, 0, pixel_max))
	}
}

reconstruct_bypass_8x8 :: proc(
	pixels: [^]$T,
	stride: int,
	levels: ^[64]$L,
	dpcm_dir: int = -1,
	pixel_max: i32 = 255,
) #no_bounds_check {
	r: [64]i32
	for k in 0 ..< 64 do r[zigzag_scan_8x8[k]] = i32(levels[k])
	if dpcm_dir == 0 {
		for y in 1 ..< 8 do for x in 0 ..< 8 {
			r[y * 8 + x] += r[(y - 1) * 8 + x]
		}
	} else if dpcm_dir == 1 {
		for y in 0 ..< 8 do for x in 1 ..< 8 {
			r[y * 8 + x] += r[y * 8 + x - 1]
		}
	}
	for y in 0 ..< 8 do for x in 0 ..< 8 {
		v := i32(pixels[y * stride + x]) + r[y * 8 + x]
		pixels[y * stride + x] = T(clamp(v, 0, pixel_max))
	}
}

reconstruct_bypass_16x16 :: proc(
	pixels: [^]$T,
	stride: int,
	dc_in: ^[16]$L,
	blocks_4x4: ^[16][16]L,
	nz_4x4: ^[16]bool,
	dpcm_dir: int = -1,
	pixel_max: i32 = 255,
) #no_bounds_check {
	dc: [16]L
	for i in 0 ..< 16 do dc[zigzag_scan_4x4[i]] = dc_in[i]
	r: [256]i32
	for block in 0 ..< 16 {
		bx, by := subblock_to_xy(block)
		if nz_4x4[block] {
			for k in 1 ..< 16 {
				pos := int(zigzag_scan_4x4[k])
				r[(by * 4 + (pos >> 2)) * 16 + bx * 4 + (pos & 3)] = i32(blocks_4x4[block][k])
			}
		}
		r[(by * 4) * 16 + bx * 4] = i32(dc[by * 4 + bx])
	}
	if dpcm_dir == 0 {
		for y in 1 ..< 16 do for x in 0 ..< 16 do r[y * 16 + x] += r[(y - 1) * 16 + x]
	} else if dpcm_dir == 1 {
		for y in 0 ..< 16 do for x in 1 ..< 16 do r[y * 16 + x] += r[y * 16 + x - 1]
	}
	for y in 0 ..< 16 do for x in 0 ..< 16 {
		v := i32(pixels[y * stride + x]) + r[y * 16 + x]
		pixels[y * stride + x] = T(clamp(v, 0, pixel_max))
	}
}

reconstruct_bypass_chroma :: proc(
	pixels: [^]$T,
	stride: int,
	dc_in: [8]$L,
	ac_blocks: ^[8][16]L,
	blocks: int,
	has_ac: bool,
	dpcm_dir: int = -1,
	pixel_max: i32 = 255,
) #no_bounds_check {
	dc := dc_in
	if blocks == 8 {
		// 2x4 scan order (8-305) -> raster order (two per row)
		dc = {dc[0], dc[2], dc[1], dc[5], dc[3], dc[6], dc[4], dc[7]}
	}
	ch := blocks == 8 ? 16 : 8
	r: [128]i32
	for block in 0 ..< blocks {
		bx, by := block & 1, block >> 1
		if has_ac {
			for k in 1 ..< 16 {
				pos := int(zigzag_scan_4x4[k])
				r[(by * 4 + (pos >> 2)) * 8 + bx * 4 + (pos & 3)] = i32(ac_blocks[block][k])
			}
		}
		r[(by * 4) * 8 + bx * 4] = i32(dc[block])
	}
	if dpcm_dir == 0 {
		for y in 1 ..< ch do for x in 0 ..< 8 do r[y * 8 + x] += r[(y - 1) * 8 + x]
	} else if dpcm_dir == 1 {
		for y in 0 ..< ch do for x in 1 ..< 8 do r[y * 8 + x] += r[y * 8 + x - 1]
	}
	for y in 0 ..< ch do for x in 0 ..< 8 {
		v := i32(pixels[y * stride + x]) + r[y * 8 + x]
		pixels[y * stride + x] = T(clamp(v, 0, pixel_max))
	}
}

// Clamps integer to [0, 255]
clamp_u8 :: #force_inline proc "contextless" (v: i32) -> u8 {
	return u8(clamp(v, 0, 255))
}

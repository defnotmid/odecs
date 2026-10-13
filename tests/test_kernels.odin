package main

import h264 "../codec/h264"
import avc_dec "../codec/h264/decoder"
import avc_enc "../codec/h264/encoder"
import "core:fmt"
import "core:math/rand"
import "core:os"

// SIMD kernels against scalar reference implementations on random data.

STRIDE :: 64

abs_diff :: proc "contextless" (a, b: u8) -> i32 {
	return i32(a >= b ? (a - b) : (b - a))
}

clamp_i32 :: proc "contextless" (v, low, high: i32) -> i32 {
	if v < low do return low
	if v > high do return high
	return v
}

reference_deblock_luma_edge_v :: proc(
	pix: [^]u8,
	stride: int,
	alpha: i32,
	beta: i32,
	bs: [4]u8,
	tc0: [4]i8,
) {
	cur_pix := pix
	for edge_part in 0 ..< 4 {
		b_s := bs[edge_part]
		if b_s == 0 {
			cur_pix = &cur_pix[stride * 4]
			continue
		}
		tc_init := i32(tc0[edge_part])

		if b_s == 4 {
			alpha_div4 := (alpha >> 2) + 2
			for _ in 0 ..< 4 {
				p0 := cur_pix[-1]
				p1 := cur_pix[-2]
				p2 := cur_pix[-3]
				q0 := cur_pix[0]
				q1 := cur_pix[1]
				q2 := cur_pix[2]

				dp0q0 := abs_diff(p0, q0)
				dp1p0 := abs_diff(p1, p0)
				dq1q0 := abs_diff(q1, q0)

				if dp0q0 < alpha && dp1p0 < beta && dq1q0 < beta {
					if dp0q0 < alpha_div4 {
						if abs_diff(p2, p0) < beta {
							p3 := i32(cur_pix[-4])
							cur_pix[-1] = h264.clamp_u8(
								(i32(p2) +
									2 * i32(p1) +
									2 * i32(p0) +
									2 * i32(q0) +
									i32(q1) +
									4) >>
								3,
							)
							cur_pix[-2] = h264.clamp_u8(
								(i32(p2) + i32(p1) + i32(p0) + i32(q0) + 2) >> 2,
							)
							cur_pix[-3] = h264.clamp_u8(
								(2 * p3 + 3 * i32(p2) + i32(p1) + i32(p0) + i32(q0) + 4) >> 3,
							)
						} else {
							cur_pix[-1] = h264.clamp_u8((2 * i32(p1) + i32(p0) + i32(q1) + 2) >> 2)
						}

						if abs_diff(q2, q0) < beta {
							q3 := i32(cur_pix[3])
							cur_pix[0] = h264.clamp_u8(
								(i32(p1) +
									2 * i32(p0) +
									2 * i32(q0) +
									2 * i32(q1) +
									i32(q2) +
									4) >>
								3,
							)
							cur_pix[1] = h264.clamp_u8(
								(i32(p0) + i32(q0) + i32(q1) + i32(q2) + 2) >> 2,
							)
							cur_pix[2] = h264.clamp_u8(
								(2 * q3 + 3 * i32(q2) + i32(q1) + i32(q0) + i32(p0) + 4) >> 3,
							)
						} else {
							cur_pix[0] = h264.clamp_u8((2 * i32(q1) + i32(q0) + i32(p1) + 2) >> 2)
						}
					} else {
						cur_pix[-1] = h264.clamp_u8((2 * i32(p1) + i32(p0) + i32(q1) + 2) >> 2)
						cur_pix[0] = h264.clamp_u8((2 * i32(q1) + i32(q0) + i32(p1) + 2) >> 2)
					}
				}
				cur_pix = &cur_pix[stride]
			}
		} else if tc_init >= 0 {
			for _ in 0 ..< 4 {
				p0 := cur_pix[-1]
				p1 := cur_pix[-2]
				p2 := cur_pix[-3]
				q0 := cur_pix[0]
				q1 := cur_pix[1]
				q2 := cur_pix[2]

				dp0q0 := abs_diff(p0, q0)
				dp1p0 := abs_diff(p1, p0)
				dq1q0 := abs_diff(q1, q0)

				if dp0q0 < alpha && dp1p0 < beta && dq1q0 < beta {
					tc := tc_init
					if abs_diff(p2, p0) < beta {
						cur_pix[-2] = h264.clamp_u8(
							i32(p1) +
							clamp_i32(
								(i32(p2) + ((i32(p0) + i32(q0) + 1) >> 1) - 2 * i32(p1)) >> 1,
								-tc_init,
								tc_init,
							),
						)
						tc += 1
					}
					if abs_diff(q2, q0) < beta {
						cur_pix[1] = h264.clamp_u8(
							i32(q1) +
							clamp_i32(
								(i32(q2) + ((i32(p0) + i32(q0) + 1) >> 1) - 2 * i32(q1)) >> 1,
								-tc_init,
								tc_init,
							),
						)
						tc += 1
					}
					delta := clamp_i32(
						(((i32(q0) - i32(p0)) << 2) + (i32(p1) - i32(q1)) + 4) >> 3,
						-tc,
						tc,
					)
					cur_pix[-1] = h264.clamp_u8(i32(p0) + delta)
					cur_pix[0] = h264.clamp_u8(i32(q0) - delta)
				}
				cur_pix = &cur_pix[stride]
			}
		} else {
			cur_pix = &cur_pix[stride * 4]
		}
	}
}

reference_deblock_luma_edge_h :: proc(
	pix: [^]u8,
	stride: int,
	alpha: i32,
	beta: i32,
	bs: [4]u8,
	tc0: [4]i8,
) {

	for edge_part in 0 ..< 4 {
		b_s := bs[edge_part]
		if b_s == 0 do continue
		col_start := edge_part * 4
		tc_init := i32(tc0[edge_part])

		if b_s == 4 {
			alpha_div4 := (alpha >> 2) + 2
			for i in col_start ..< col_start + 4 {
				p0 := pix[-1 * stride + i]
				p1 := pix[-2 * stride + i]
				p2 := pix[-3 * stride + i]
				q0 := pix[0 * stride + i]
				q1 := pix[1 * stride + i]
				q2 := pix[2 * stride + i]

				dp0q0 := abs_diff(p0, q0)
				dp1p0 := abs_diff(p1, p0)
				dq1q0 := abs_diff(q1, q0)

				if dp0q0 < alpha && dp1p0 < beta && dq1q0 < beta {
					if dp0q0 < alpha_div4 {
						if abs_diff(p2, p0) < beta {
							p3 := i32(pix[-4 * stride + i])
							pix[-1 * stride + i] = h264.clamp_u8(
								(i32(p2) +
									2 * i32(p1) +
									2 * i32(p0) +
									2 * i32(q0) +
									i32(q1) +
									4) >>
								3,
							)
							pix[-2 * stride + i] = h264.clamp_u8(
								(i32(p2) + i32(p1) + i32(p0) + i32(q0) + 2) >> 2,
							)
							pix[-3 * stride + i] = h264.clamp_u8(
								(2 * p3 + 3 * i32(p2) + i32(p1) + i32(p0) + i32(q0) + 4) >> 3,
							)
						} else {
							pix[-1 * stride + i] = h264.clamp_u8(
								(2 * i32(p1) + i32(p0) + i32(q1) + 2) >> 2,
							)
						}

						if abs_diff(q2, q0) < beta {
							q3 := i32(pix[3 * stride + i])
							pix[0 * stride + i] = h264.clamp_u8(
								(i32(p1) +
									2 * i32(p0) +
									2 * i32(q0) +
									2 * i32(q1) +
									i32(q2) +
									4) >>
								3,
							)
							pix[1 * stride + i] = h264.clamp_u8(
								(i32(p0) + i32(q0) + i32(q1) + i32(q2) + 2) >> 2,
							)
							pix[2 * stride + i] = h264.clamp_u8(
								(2 * q3 + 3 * i32(q2) + i32(q1) + i32(q0) + i32(p0) + 4) >> 3,
							)
						} else {
							pix[0 * stride + i] = h264.clamp_u8(
								(2 * i32(q1) + i32(q0) + i32(p1) + 2) >> 2,
							)
						}
					} else {
						pix[-1 * stride + i] = h264.clamp_u8(
							(2 * i32(p1) + i32(p0) + i32(q1) + 2) >> 2,
						)
						pix[0 * stride + i] = h264.clamp_u8(
							(2 * i32(q1) + i32(q0) + i32(p1) + 2) >> 2,
						)
					}
				}
			}
		} else if tc_init >= 0 {
			for i in col_start ..< col_start + 4 {
				p0 := pix[-1 * stride + i]
				p1 := pix[-2 * stride + i]
				p2 := pix[-3 * stride + i]
				q0 := pix[0 * stride + i]
				q1 := pix[1 * stride + i]
				q2 := pix[2 * stride + i]

				dp0q0 := abs_diff(p0, q0)
				dp1p0 := abs_diff(p1, p0)
				dq1q0 := abs_diff(q1, q0)

				if dp0q0 < alpha && dp1p0 < beta && dq1q0 < beta {
					tc := tc_init
					if abs_diff(p2, p0) < beta {
						pix[-2 * stride + i] = h264.clamp_u8(
							i32(p1) +
							clamp_i32(
								(i32(p2) + ((i32(p0) + i32(q0) + 1) >> 1) - 2 * i32(p1)) >> 1,
								-tc_init,
								tc_init,
							),
						)
						tc += 1
					}
					if abs_diff(q2, q0) < beta {
						pix[1 * stride + i] = h264.clamp_u8(
							i32(q1) +
							clamp_i32(
								(i32(q2) + ((i32(p0) + i32(q0) + 1) >> 1) - 2 * i32(q1)) >> 1,
								-tc_init,
								tc_init,
							),
						)
						tc += 1
					}
					delta := clamp_i32(
						(((i32(q0) - i32(p0)) << 2) + (i32(p1) - i32(q1)) + 4) >> 3,
						-tc,
						tc,
					)
					pix[-1 * stride + i] = h264.clamp_u8(i32(p0) + delta)
					pix[0 * stride + i] = h264.clamp_u8(i32(q0) - delta)
				}
			}
		}
	}
}

reference_deblock_chroma_edge_v :: proc(
	pix: [^]u8,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc: [4]i8,
) {
	for k in 0 ..< 4 {
		b_s := bs[k]
		if b_s == 0 do continue
		t := i32(tc[k])
		for row in 2 * k ..< 2 * k + 2 {
			cur_pix: [^]u8 = &pix[row * stride]
			p0 := cur_pix[-1]
			p1 := cur_pix[-2]
			q0 := cur_pix[0]
			q1 := cur_pix[1]
			if abs_diff(p0, q0) >= alpha || abs_diff(p1, p0) >= beta || abs_diff(q1, q0) >= beta do continue
			if b_s == 4 {
				cur_pix[-1] = h264.clamp_u8((2 * i32(p1) + i32(p0) + i32(q1) + 2) >> 2)
				cur_pix[0] = h264.clamp_u8((2 * i32(q1) + i32(q0) + i32(p1) + 2) >> 2)
			} else {
				delta := clamp_i32(
					(((i32(q0) - i32(p0)) << 2) + (i32(p1) - i32(q1)) + 4) >> 3,
					-t,
					t,
				)
				cur_pix[-1] = h264.clamp_u8(i32(p0) + delta)
				cur_pix[0] = h264.clamp_u8(i32(q0) - delta)
			}
		}
	}
}

reference_deblock_chroma_edge_h :: proc(
	pix: [^]u8,
	stride: int,
	alpha, beta: i32,
	bs: [4]u8,
	tc: [4]i8,
) {
	for k in 0 ..< 4 {
		b_s := bs[k]
		if b_s == 0 do continue
		t := i32(tc[k])
		for i in 2 * k ..< 2 * k + 2 {
			p0 := pix[-1 * stride + i]
			p1 := pix[-2 * stride + i]
			q0 := pix[0 * stride + i]
			q1 := pix[1 * stride + i]
			if abs_diff(p0, q0) >= alpha || abs_diff(p1, p0) >= beta || abs_diff(q1, q0) >= beta do continue
			if b_s == 4 {
				pix[-1 * stride + i] = h264.clamp_u8((2 * i32(p1) + i32(p0) + i32(q1) + 2) >> 2)
				pix[0 * stride + i] = h264.clamp_u8((2 * i32(q1) + i32(q0) + i32(p1) + 2) >> 2)
			} else {
				delta := clamp_i32(
					(((i32(q0) - i32(p0)) << 2) + (i32(p1) - i32(q1)) + 4) >> 3,
					-t,
					t,
				)
				pix[-1 * stride + i] = h264.clamp_u8(i32(p0) + delta)
				pix[0 * stride + i] = h264.clamp_u8(i32(q0) - delta)
			}
		}
	}
}


// 4x4 inverse transform reference (8.5.12.2)
reference_idct_4x4_add :: proc(pixels: [^]u8, stride: int, coeffs: ^[16]i32) {
	tmp: [16]i32
	for i in 0 ..< 4 {
		d := coeffs[i * 4:]
		e0, e1, e2, e3 := d[0] + d[2], d[0] - d[2], (d[1] >> 1) - d[3], d[1] + (d[3] >> 1)
		tmp[i * 4 + 0], tmp[i * 4 + 1], tmp[i * 4 + 2], tmp[i * 4 + 3] =
			e0 + e3, e1 + e2, e1 - e2, e0 - e3
	}
	for i in 0 ..< 4 {
		g0, g1 := tmp[i] + tmp[8 + i], tmp[i] - tmp[8 + i]
		g2, g3 := (tmp[4 + i] >> 1) - tmp[12 + i], tmp[4 + i] + (tmp[12 + i] >> 1)
		r := [4]i32{g0 + g3, g1 + g2, g1 - g2, g0 - g3}
		for y in 0 ..< 4 {
			p := &pixels[y * stride + i]
			p^ = h264.clamp_u8(i32(p^) + ((r[y] + 32) >> 6))
		}
	}
}

reference_idct_8x8_add :: proc(pixels: [^]u8, stride: int, coeffs: ^[64]i32) {
	idct_8x8_1d :: proc(d: []i32, out: []i32, stride_in, stride_out: int) {
		d0, d1, d2, d3 := d[0], d[stride_in], d[2 * stride_in], d[3 * stride_in]
		d4, d5, d6, d7 := d[4 * stride_in], d[5 * stride_in], d[6 * stride_in], d[7 * stride_in]
		a0 := d0 + d4
		a1 := -d3 + d5 - d7 - (d7 >> 1)
		a2 := d0 - d4
		a3 := d1 + d7 - d3 - (d3 >> 1)
		a4 := (d2 >> 1) - d6
		a5 := -d1 + d7 + d5 + (d5 >> 1)
		a6 := d2 + (d6 >> 1)
		a7 := d3 + d5 + d1 + (d1 >> 1)
		b0 := a0 + a6
		b1 := a1 + (a7 >> 2)
		b2 := a2 + a4
		b3 := a3 + (a5 >> 2)
		b4 := a2 - a4
		b5 := (a3 >> 2) - a5
		b6 := a0 - a6
		b7 := a7 - (a1 >> 2)
		out[0] = b0 + b7
		out[stride_out] = b2 + b5
		out[2 * stride_out] = b4 + b3
		out[3 * stride_out] = b6 + b1
		out[4 * stride_out] = b6 - b1
		out[5 * stride_out] = b4 - b3
		out[6 * stride_out] = b2 - b5
		out[7 * stride_out] = b0 - b7
	}
	tmp: [64]i32
	for i in 0 ..< 8 do idct_8x8_1d(coeffs[i * 8:], tmp[i * 8:], 1, 1)
	out: [64]i32
	for i in 0 ..< 8 do idct_8x8_1d(tmp[i:], out[i:], 8, 8)
	for y in 0 ..< 8 do for x in 0 ..< 8 {
		p := &pixels[y * stride + x]
		p^ = h264.clamp_u8(i32(p^) + ((out[y * 8 + x] + 32) >> 6))
	}
}

reference_predict_intra_16x16 :: proc(
	dst: [^]u8,
	stride: int,
	mode: h264.Intra_16x16_Mode,
	top_avail: bool,
	left_avail: bool,
) {
	switch mode {
	case .Vertical:
		top: [^]u8 = &dst[-stride]
		for y in 0 ..< 16 {
			for x in 0 ..< 16 {
				dst[y * stride + x] = top[x]
			}
		}

	case .Horizontal:
		for y in 0 ..< 16 {
			val := dst[y * stride - 1]
			for x in 0 ..< 16 {
				dst[y * stride + x] = val
			}
		}

	case .DC:
		val: u8 = 128
		if top_avail && left_avail {
			sum: i32 = 0
			for i in 0 ..< 16 {
				sum += i32(dst[-stride + i]) + i32(dst[i * stride - 1])
			}
			val = u8((sum + 16) >> 5)
		} else if top_avail {
			sum: i32 = 0
			for i in 0 ..< 16 {
				sum += i32(dst[-stride + i])
			}
			val = u8((sum + 8) >> 4)
		} else if left_avail {
			sum: i32 = 0
			for i in 0 ..< 16 {
				sum += i32(dst[i * stride - 1])
			}
			val = u8((sum + 8) >> 4)
		}
		for y in 0 ..< 16 {
			for x in 0 ..< 16 {
				dst[y * stride + x] = val
			}
		}

	case .Plane:
		top: [^]u8 = &dst[-stride]
		left: [^]u8 = &dst[-1]

		H: i32 = 0
		V: i32 = 0
		for i in 0 ..< 8 {
			H += i32(i + 1) * (i32(top[8 + i]) - i32(top[6 - i]))
			V += i32(i + 1) * (i32(left[(8 + i) * stride]) - i32(left[(6 - i) * stride]))
		}

		a := (i32(left[15 * stride]) + i32(top[15])) << 4
		b := (5 * H + 32) >> 6
		c := (5 * V + 32) >> 6

		for y in 0 ..< 16 {
			for x in 0 ..< 16 {
				val := (a + b * (i32(x) - 7) + c * (i32(y) - 7) + 16) >> 5
				dst[y * stride + x] = h264.clamp_u8(val)
			}
		}
	}
}

reference_predict_intra_chroma_8x8 :: proc(
	dst: [^]u8,
	stride: int,
	mode: h264.Intra_Chroma_Mode,
	top_avail: bool,
	left_avail: bool,
) {
	switch mode {
	case .DC:
		{
			// Chroma DC is per 4x4 quadrant: the top-right quadrant uses only
			// the top edge and the bottom-left only the left edge (8.3.4.1-3).
			m0, m1, m2, m3: u8 = 128, 128, 128, 128
			if top_avail && left_avail {
				top: [^]u8 = &dst[-stride]
				s_top_0 := i32(top[0]) + i32(top[1]) + i32(top[2]) + i32(top[3])
				s_top_1 := i32(top[4]) + i32(top[5]) + i32(top[6]) + i32(top[7])
				s_left_0 :=
					i32(dst[0 * stride - 1]) +
					i32(dst[1 * stride - 1]) +
					i32(dst[2 * stride - 1]) +
					i32(dst[3 * stride - 1])
				s_left_1 :=
					i32(dst[4 * stride - 1]) +
					i32(dst[5 * stride - 1]) +
					i32(dst[6 * stride - 1]) +
					i32(dst[7 * stride - 1])

				m0 = u8((s_top_0 + s_left_0 + 4) >> 3)
				m1 = u8((s_top_1 + 2) >> 2)
				m2 = u8((s_left_1 + 2) >> 2)
				m3 = u8((s_top_1 + s_left_1 + 4) >> 3)
			} else if top_avail {
				top: [^]u8 = &dst[-stride]
				s_top_0 := i32(top[0]) + i32(top[1]) + i32(top[2]) + i32(top[3])
				s_top_1 := i32(top[4]) + i32(top[5]) + i32(top[6]) + i32(top[7])
				m0 = u8((s_top_0 + 2) >> 2)
				m1 = u8((s_top_1 + 2) >> 2)
				m2 = m0
				m3 = m1
			} else if left_avail {
				s_left_0 :=
					i32(dst[0 * stride - 1]) +
					i32(dst[1 * stride - 1]) +
					i32(dst[2 * stride - 1]) +
					i32(dst[3 * stride - 1])
				s_left_1 :=
					i32(dst[4 * stride - 1]) +
					i32(dst[5 * stride - 1]) +
					i32(dst[6 * stride - 1]) +
					i32(dst[7 * stride - 1])
				m0 = u8((s_left_0 + 2) >> 2)
				m1 = m0
				m2 = u8((s_left_1 + 2) >> 2)
				m3 = m2
			}

			// Quadrant 0 (top-left 4x4)
			for y in 0 ..< 4 {
				for x in 0 ..< 4 do dst[y * stride + x] = m0
			}
			// Quadrant 1 (top-right 4x4)
			for y in 0 ..< 4 {
				for x in 4 ..< 8 do dst[y * stride + x] = m1
			}
			// Quadrant 2 (bottom-left 4x4)
			for y in 4 ..< 8 {
				for x in 0 ..< 4 do dst[y * stride + x] = m2
			}
			// Quadrant 3 (bottom-right 4x4)
			for y in 4 ..< 8 {
				for x in 4 ..< 8 do dst[y * stride + x] = m3
			}
		}

	case .Horizontal:
		for y in 0 ..< 8 {
			val := dst[y * stride - 1]
			for x in 0 ..< 8 do dst[y * stride + x] = val
		}

	case .Vertical:
		top: [^]u8 = &dst[-stride]
		for y in 0 ..< 8 {
			for x in 0 ..< 8 do dst[y * stride + x] = top[x]
		}

	case .Plane:
		top: [^]u8 = &dst[-stride]
		left: [^]u8 = &dst[-1]

		H: i32 = 0
		V: i32 = 0
		for i in 0 ..< 4 {
			H += i32(i + 1) * (i32(top[4 + i]) - i32(top[2 - i]))
			V += i32(i + 1) * (i32(left[(4 + i) * stride]) - i32(left[(2 - i) * stride]))
		}

		a := (i32(left[7 * stride]) + i32(top[7])) << 4
		b := (17 * H + 16) >> 5
		c := (17 * V + 16) >> 5

		for y in 0 ..< 8 {
			for x in 0 ..< 8 {
				val := (a + b * (i32(x) - 3) + c * (i32(y) - 3) + 16) >> 5
				dst[y * stride + x] = h264.clamp_u8(val)
			}
		}
	}
}

// Prediction combination reference (8.4.2.3)
reference_write_prediction :: proc(
	dst: [^]u8,
	dst_stride: int,
	src0, src1: [^]u8,
	src_stride, width, height: int,
	dir: h264.Prediction_Direction,
	weight: avc_dec.Weight,
	weighted: bool,
) {
	for y in 0 ..< height do for x in 0 ..< width {
		v: i32
		s0, s1 := i32(src0[y * src_stride + x]), i32(src1[y * src_stride + x])
		switch {
		case dir == h264.Prediction_Direction.Bidirectional && weighted:
			v = ((s0 * weight.w0 + s1 * weight.w1 + (1 << uint(weight.log2_denom))) >> uint(weight.log2_denom + 1)) + ((weight.o0 + weight.o1 + 1) >> 1)
		case dir == h264.Prediction_Direction.Bidirectional:
			v = (s0 + s1 + 1) >> 1
		case weighted:
			s := dir == h264.Prediction_Direction.List_0 ? s0 : s1
			w, o := dir == h264.Prediction_Direction.List_0 ? weight.w0 : weight.w1, dir == h264.Prediction_Direction.List_0 ? weight.o0 : weight.o1
			v = weight.log2_denom >= 1 ? ((s * w + (1 << uint(weight.log2_denom - 1))) >> uint(weight.log2_denom)) + o : s * w + o
		case:
			v = dir == h264.Prediction_Direction.List_0 ? s0 : s1
		}
		dst[y * dst_stride + x] = h264.clamp_u8(v)
	}
}

// SATD reference: 4x4 Hadamard of the difference, sum of magnitudes, rounded half
reference_satd_4x4 :: proc(a: [^]u8, a_stride: int, b: [^]u8, b_stride: int) -> i32 {
	d, tmp: [16]i32
	for y in 0 ..< 4 do for x in 0 ..< 4 do d[y * 4 + x] = i32(a[y * a_stride + x]) - i32(b[y * b_stride + x])
	for i in 0 ..< 4 {
		s0, s1 := d[i * 4] + d[i * 4 + 1], d[i * 4] - d[i * 4 + 1]
		s2, s3 := d[i * 4 + 2] + d[i * 4 + 3], d[i * 4 + 2] - d[i * 4 + 3]
		tmp[i * 4 + 0], tmp[i * 4 + 1], tmp[i * 4 + 2], tmp[i * 4 + 3] =
			s0 + s2, s1 + s3, s0 - s2, s1 - s3
	}
	sum: i32
	for i in 0 ..< 4 {
		s0, s1 := tmp[i] + tmp[4 + i], tmp[i] - tmp[4 + i]
		s2, s3 := tmp[8 + i] + tmp[12 + i], tmp[8 + i] - tmp[12 + i]
		sum += abs(s0 + s2) + abs(s1 + s3) + abs(s0 - s2) + abs(s1 - s3)
	}
	return (sum + 1) >> 1
}

check :: proc(name: string, a, b: []u8, fails: ^int) {
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			fmt.printfln("MISMATCH %-28s at %d: kernel=%d reference=%d", name, i, a[i], b[i])
			fails^ += 1
			return
		}
	}
}

main :: proc() {
	rand.reset(11)
	fails := 0
	for iteration in 0 ..< 450 {
		base: [STRIDE * 48]u8
		// Smooth edges exercise active strong lanes as well as the random controls.
		for &b in base do b = iteration < 300 ? u8(rand.uint32()) : u8(100 + rand.int_max(13))
		bs := [4]u8 {
			u8(rand.int_max(5)),
			u8(rand.int_max(5)),
			u8(rand.int_max(5)),
			u8(rand.int_max(5)),
		}
		alpha := i32(rand.int_max(256))
		beta := i32(rand.int_max(19))
		idx_a := rand.int_max(52)
		tc0: [4]i8
		for k in 0 ..< 4 do if bs[k] > 0 && bs[k] < 4 do tc0[k] = h264.deblock_tc0_table[idx_a + 12][bs[k]]
		tc1 := tc0
		for k in 0 ..< 4 do if bs[k] > 0 && bs[k] < 4 do tc1[k] += 1

		a := base; b := base
		h264.deblock_luma_vertical(&a[STRIDE * 8 + 16], STRIDE, alpha, beta, bs, tc0)
		reference_deblock_luma_edge_v(&b[STRIDE * 8 + 16], STRIDE, alpha, beta, bs, tc0)
		check("luma vertical edge", a[:], b[:], &fails)
		a = base; b = base
		h264.deblock_luma_horizontal(&a[STRIDE * 8 + 16], STRIDE, alpha, beta, bs, tc0)
		reference_deblock_luma_edge_h(&b[STRIDE * 8 + 16], STRIDE, alpha, beta, bs, tc0)
		check("luma horizontal edge", a[:], b[:], &fails)
		a = base; b = base
		h264.deblock_chroma_vertical(&a[STRIDE * 8 + 16], STRIDE, alpha, beta, bs, tc1)
		reference_deblock_chroma_edge_v(&b[STRIDE * 8 + 16], STRIDE, alpha, beta, bs, tc1)
		check("chroma vertical edge", a[:], b[:], &fails)
		a = base; b = base
		h264.deblock_chroma_horizontal(&a[STRIDE * 8 + 16], STRIDE, alpha, beta, bs, tc1)
		reference_deblock_chroma_edge_h(&b[STRIDE * 8 + 16], STRIDE, alpha, beta, bs, tc1)
		check("chroma horizontal edge", a[:], b[:], &fails)

		coeffs: [16]i32
		for &c in coeffs do c = i32(rand.int_max(8000) - 4000)
		a = base; b = base
		h264.idct_4x4_add(&a[STRIDE * 8 + 16], STRIDE, &coeffs)
		reference_idct_4x4_add(&b[STRIDE * 8 + 16], STRIDE, &coeffs)
		check("idct 4x4 add", a[:], b[:], &fails)

		mx := i16(rand.int_max(4))
		my := i16(rand.int_max(4))
		a = base; b = base
		h264.mc_luma_lanes(16, &base[STRIDE * 8 + 16], STRIDE, &a[0], 16, int(mx), int(my), 16)
		h264.mc_luma(&base[STRIDE * 8 + 16], STRIDE, &b[0], 16, mx, my, 16, 16)
		check("luma mc 16x16", a[:256], b[:256], &fails)
		a = base; b = base
		h264.mc_luma_lanes(8, &base[STRIDE * 8 + 16], STRIDE, &a[0], 16, int(mx), int(my), 8)
		h264.mc_luma(&base[STRIDE * 8 + 16], STRIDE, &b[0], 16, mx, my, 8, 8)
		check("luma mc 8x8", a[:128], b[:128], &fails)
		cx := i16(rand.int_max(8))
		cy := i16(rand.int_max(8))
		a = base; b = base
		h264.mc_chroma_lanes(8, &base[STRIDE * 8 + 16], STRIDE, &a[0], 8, int(cx), int(cy), 8)
		h264.mc_chroma(&base[STRIDE * 8 + 16], STRIDE, &b[0], 8, cx, cy, 8, 8)
		check("chroma mc 8x8", a[:64], b[:64], &fails)
		// register dequantisation + transform against the scalar dequantiser and transform
		levels16: [16]i16
		for &l in levels16 do l = i16(rand.int_max(200) - 100)
		qp := i32(rand.int_max(52))
		st: h264.Level_Scales
		for list in 0 ..< 6 do for m in 0 ..< 6 do for pos in 0 ..< 16 {
			x, y := pos & 3, pos >> 2
			class := x & 1 == 0 && y & 1 == 0 ? 0 : x & 1 == 1 && y & 1 == 1 ? 1 : 2
			st.scale_4x4[list][m][pos] = 16 * h264.norm_adjust_4x4[m][class]
		}
		for list in 0 ..< 2 do for m in 0 ..< 6 do for pos in 0 ..< 64 do st.scale_8x8[list][m][pos] = 16 * i32(h264.norm_adjust_8x8[m][pos])
		ref_coeffs: [16]i32
		h264.dequant_4x4(&st, levels16[:], &ref_coeffs, qp, 0, false)
		a = base; b = base
		h264.reconstruct_4x4(&st, &a[STRIDE * 8 + 16], STRIDE, &levels16, true, qp, 0, false, 0)
		reference_idct_4x4_add(&b[STRIDE * 8 + 16], STRIDE, &ref_coeffs)
		check("reconstruct 4x4", a[:], b[:], &fails)
		ref_coeffs = {}
		h264.dequant_4x4(&st, levels16[1:], &ref_coeffs, qp, 1, true)
		ref_coeffs[0] = 777
		a = base; b = base
		h264.reconstruct_4x4(&st, &a[STRIDE * 8 + 16], STRIDE, &levels16, true, qp, 1, true, 777)
		reference_idct_4x4_add(&b[STRIDE * 8 + 16], STRIDE, &ref_coeffs)
		check("reconstruct 4x4 with dc", a[:], b[:], &fails)
		levels64: [64]i16
		for &l in levels64 do l = i16(rand.int_max(200) - 100)
		ref64: [64]i32
		h264.dequant_8x8(&st, levels64[:], &ref64, qp, 0)
		a = base; b = base
		h264.reconstruct_8x8(&st, &a[STRIDE * 8 + 16], STRIDE, &levels64, qp, 0)
		reference_idct_8x8_add(&b[STRIDE * 8 + 16], STRIDE, &ref64)
		check("reconstruct 8x8", a[:], b[:], &fails)

		coeffs8: [64]i32
		for &c in coeffs8 do c = i32(rand.int_max(4000) - 2000)
		a = base; b = base
		h264.idct_8x8_add(&a[STRIDE * 8 + 16], STRIDE, &coeffs8)
		reference_idct_8x8_add(&b[STRIDE * 8 + 16], STRIDE, &coeffs8)
		check("idct 8x8 add", a[:], b[:], &fails)

		a = base; b = base
		h264.mc_luma_lanes(4, &base[STRIDE * 8 + 16], STRIDE, &a[0], 16, int(mx), int(my), 4)
		h264.mc_luma(&base[STRIDE * 8 + 16], STRIDE, &b[0], 16, mx, my, 4, 4)
		check("luma mc 4x4", a[:64], b[:64], &fails)
		a = base; b = base
		h264.mc_chroma_lanes(4, &base[STRIDE * 8 + 16], STRIDE, &a[0], 8, int(cx), int(cy), 4)
		h264.mc_chroma(&base[STRIDE * 8 + 16], STRIDE, &b[0], 8, cx, cy, 4, 4)
		check("chroma mc 4x4", a[:32], b[:32], &fails)
		a = base; b = base
		h264.mc_chroma_lanes(2, &base[STRIDE * 8 + 16], STRIDE, &a[0], 8, int(cx), int(cy), 2)
		h264.mc_chroma(&base[STRIDE * 8 + 16], STRIDE, &b[0], 8, cx, cy, 2, 2)
		check("chroma mc 2x2", a[:16], b[:16], &fails)

		weight := avc_dec.Weight {
			i32(rand.int_max(256) - 128),
			i32(rand.int_max(256) - 128),
			i32(rand.int_max(256) - 128),
			i32(rand.int_max(256) - 128),
			i32(rand.int_max(8)),
		}
		for dir in ([]h264.Prediction_Direction{.List_0, .List_1, .Bidirectional}) do for weighted in ([]bool{false, true}) do for width in ([]int{16, 8, 4, 2}) {
			a = base; b = base
			avc_dec.write_prediction(&a[STRIDE * 8 + 16], STRIDE, &base[0], &base[STRIDE * 20], STRIDE, width, width, dir, weight, weighted)
			reference_write_prediction(&b[STRIDE * 8 + 16], STRIDE, &base[0], &base[STRIDE * 20], STRIDE, width, width, dir, weight, weighted)
			check("prediction combine", a[:], b[:], &fails)
		}

		mode16 := h264.Intra_16x16_Mode(rand.int_max(4))
		a = base; b = base
		h264.predict_intra_16x16(&a[STRIDE * 8 + 16], STRIDE, mode16, true, true)
		reference_predict_intra_16x16(&b[STRIDE * 8 + 16], STRIDE, mode16, true, true)
		check("intra 16x16", a[:], b[:], &fails)
		modec := h264.Intra_Chroma_Mode(rand.int_max(4))
		a = base; b = base
		h264.predict_intra_chroma_8x8(&a[STRIDE * 8 + 16], STRIDE, modec, true, true)
		reference_predict_intra_chroma_8x8(&b[STRIDE * 8 + 16], STRIDE, modec, true, true)
		check("intra chroma 8x8", a[:], b[:], &fails)

		// Encoder distortion kernels, including the extreme all-0 vs all-255 case
		satd_a, satd_b := base, base
		if rand.int_max(8) == 0 do for &v in satd_a do v = 0
		if rand.int_max(8) == 0 do for &v in satd_b do v = 255
		kernel := avc_enc.transformed_difference_block_4x4(
			&satd_a[STRIDE * 8 + 16],
			STRIDE,
			&satd_b[STRIDE * 8 + 17],
			STRIDE,
		)
		reference := reference_satd_4x4(
			&satd_a[STRIDE * 8 + 16],
			STRIDE,
			&satd_b[STRIDE * 8 + 17],
			STRIDE,
		)
		if kernel != reference {
			fmt.printfln("MISMATCH %-28s kernel=%d reference=%d", "satd 4x4", kernel, reference)
			fails += 1
		}
		if fails > 0 do break
	}
	if fails == 0 {
		fmt.println("[SUCCESS] all SIMD kernels match their scalar references")
	} else {
		fmt.println("[FAIL] kernel mismatches:", fails)
		os.exit(1)
	}
}

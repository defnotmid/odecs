package h265_encoder

import "core:testing"

@(test)
test_search_interpolation_reuse :: proc(t: ^testing.T) {
	data: [73 * 67]Sample
	plane := Plane(Sample) {
		data   = data[:],
		stride = 73,
		offset = 5,
	}
	frame := Frame {
		y            = plane,
		coded_width  = 64,
		coded_height = 64,
	}
	actual, expected: [32 * 32]Sample
	for depth in ([2]int{8, 10}) {
		for &v, i in data do v = Sample((i * 137 + i * i * 19) & ((1 << uint(depth)) - 1))
		for size in ([6][2]int{{4, 8}, {8, 4}, {12, 16}, {16, 32}, {24, 16}, {32, 32}}) {
			w, h := size[0], size[1]
			for pos in ([3][2]int{{0, 0}, {15, 17}, {60, 61}}) {
				for base in ([4]i16{-2048, -12, 0, 2047}) {
					cache: Luma_Search_Interpolation = ---
					cache.ready = {}
					cache.ix = pos[0] + int(i32(base) >> 2) - 1
					cache.iy = pos[1] + int(i32(base) >> 2) - 1
					for dy in -3 ..= 3 {
						for dx in -3 ..= 3 {
							mx, my := base + i16(dx), base + i16(dy)
							mc_luma_search(
								false,
								&cache,
								actual[:],
								&frame,
								pos[0],
								pos[1],
								w,
								h,
								mx,
								my,
								depth,
							)
							mc_luma(expected[:], w, &frame, pos[0], pos[1], w, h, mx, my, depth)
							// The fused search consumer must score those same clipped
							// samples, including a scalar tail for 4/12-wide blocks.
							want: u32
							for v, i in expected[:w * h] do want += u32(abs(i32(data[5 + (i / w) * 73 + i % w]) - i32(v)))
							score := mc_luma_search(
								true,
								&cache,
								nil,
								&frame,
								pos[0],
								pos[1],
								w,
								h,
								mx,
								my,
								depth,
								data[5:],
								73,
							)
							testing.expect_value(t, score, want)
							for v, i in actual[:w * h] {
								if v != expected[i] {
									testing.expectf(
										t,
										false,
										"depth=%d size=%v pos=%v base=%d delta=%d,%d pixel=%d",
										depth,
										size,
										pos,
										base,
										dx,
										dy,
										i,
									)
									return
								}
							}
						}
					}
				}
			}
		}
	}
}

// Independent scalar two-axis definition, including identity filters. This
// deliberately retains both intermediate shifts to check shortcut rounding.
mc_scalar_reference :: proc(
	dst: []Sample,
	dst_stride: int,
	plane: Plane(Sample),
	ix, iy, w, h, frame_w, frame_h, depth: int,
	fh, fv: [$N]i32,
) {
	center :: N / 2 - 1
	shift1 := min(4, depth - 8)
	shift3 := max(2, 14 - depth)
	for oy in 0 ..< h {
		for ox in 0 ..< w {
			vertical: i32
			for ky in 0 ..< N {
				horizontal: i32
				for kx in 0 ..< N {
					sx := clamp(ix + ox + kx - center, 0, frame_w - 1)
					sy := clamp(iy + oy + ky - center, 0, frame_h - 1)
					horizontal += fh[kx] * i32(plane.data[plane.offset + sy * plane.stride + sx])
				}
				vertical += fv[ky] * (horizontal >> uint(shift1))
			}
			dst[oy * dst_stride + ox] = Sample(
				clamp(
					((vertical >> 6) + (1 << uint(shift3 - 1))) >> uint(shift3),
					0,
					(1 << uint(depth)) - 1,
				),
			)
		}
	}
}

@(test)
test_mc_all_phases :: proc(t: ^testing.T) {
	data: [73 * 67]Sample
	plane := Plane(Sample) {
		data   = data[:],
		stride = 73,
		offset = 5,
	}
	frame := Frame {
		y            = plane,
		coded_width  = 64,
		coded_height = 64,
	}
	actual, expected: [40 * 32]Sample
	for depth in ([3]int{8, 10, 12}) {
		for &v, i in data do v = Sample((i * 137 + i * i * 19) & ((1 << uint(depth)) - 1))
		for size in ([9][2]int{{2, 2}, {4, 2}, {4, 4}, {8, 16}, {12, 8}, {16, 32}, {24, 16}, {32, 8}, {32, 32}}) {
			w, h := size[0], size[1]
			for pos in ([5][2]int{{-7, -5}, {0, 0}, {13, 17}, {60, 61}, {70, 70}}) {
				for chroma in ([2]bool{false, true}) {
					phases := chroma ? 8 : 4
					for yf in 0 ..< phases {
						for xf in 0 ..< phases {
							for &v in actual do v = 0xffff
							for &v in expected do v = 0xffff
							// Negative motion exercises arithmetic shift and phase extraction.
							mx, my := i16(xf - 2 * phases), i16(yf - phases)
							if chroma {
								mc_chroma(
									actual[:],
									40,
									plane,
									pos[0],
									pos[1],
									w,
									h,
									mx,
									my,
									64,
									64,
									depth,
								)
								mc_scalar_reference(
									expected[:],
									40,
									plane,
									pos[0] - 2,
									pos[1] - 1,
									w,
									h,
									64,
									64,
									depth,
									CHROMA_FILTER[xf],
									CHROMA_FILTER[yf],
								)
							} else {
								mc_luma(actual[:], 40, &frame, pos[0], pos[1], w, h, mx, my, depth)
								mc_scalar_reference(
									expected[:],
									40,
									plane,
									pos[0] - 2,
									pos[1] - 1,
									w,
									h,
									64,
									64,
									depth,
									LUMA_FILTER[xf],
									LUMA_FILTER[yf],
								)
							}
							for v, i in actual {
								if v != expected[i] {
									testing.expectf(
										t,
										false,
										"depth=%d size=%v pos=%v chroma=%v phase=%d,%d sample=%d: %d != %d",
										depth,
										size,
										pos,
										chroma,
										xf,
										yf,
										i,
										v,
										expected[i],
									)
									return
								}
							}
						}
					}
				}
			}
		}
	}
}

// Golden chroma motion compensation output generated with kvazaar's
// kvz_sample_octpel_chroma_generic on the same reference data, with the
// integer part of the motion vector applied to the source pointer and edge
// samples replicated as the decoder does.
@(test)
test_mc_chroma_golden :: proc(t: ^testing.T) {
	plane_data: [16 * 16]Sample
	for y in 0 ..< 16 {
		for x in 0 ..< 16 {
			plane_data[y * 16 + x] = Sample((x * 13 + y * 29 + ((x * y) % 7) * 11) % 256)
		}
	}
	plane := Plane(Sample) {
		data   = plane_data[:],
		stride = 16,
		offset = 0,
	}

	GOLDEN_A := [16]u8 {
		89,
		126,
		137,
		130,
		140,
		164,
		157,
		160,
		162,
		170,
		199,
		216,
		193,
		203,
		159,
		140,
	}
	GOLDEN_B := [16]u8{23, 44, 65, 87, 54, 87, 122, 148, 84, 131, 169, 153, 116, 163, 162, 198}

	out: [16]Sample
	mc_chroma(out[:], 4, plane, 1, 1, 4, 4, 3, 5, 16, 16, 8)
	for i in 0 ..< 16 {
		testing.expectf(
			t,
			u8(out[i]) == GOLDEN_A[i],
			"mv(3,5) sample %d: got %d want %d",
			i,
			out[i],
			GOLDEN_A[i],
		)
	}

	mc_chroma(out[:], 4, plane, 1, 1, 4, 4, -7, -2, 16, 16, 8)
	for i in 0 ..< 16 {
		testing.expectf(
			t,
			u8(out[i]) == GOLDEN_B[i],
			"mv(-7,-2) sample %d: got %d want %d",
			i,
			out[i],
			GOLDEN_B[i],
		)
	}
}

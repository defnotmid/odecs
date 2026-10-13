package h265_encoder

import "core:testing"

// Prediction-only AMP reconstruction must cover both stacked 4:2:2 blocks
// and the full-width 4:4:4 block at the correct offset in the parent CU.
@(test)
test_chroma_prediction_only_reconstruction :: proc(t: ^testing.T) {
	for layout in ([]Chroma_Layout{.Monochrome, .YUV_420, .YUV_422, .YUV_444}) {
		enc: Encoder
		init_encoder(
			&enc,
			Config{width = 64, height = 64, bit_depth = 10, qp = 26, chroma_format = layout},
		)
		defer destroy_encoder(&enc)
		fill_frame(&enc.rec, 0)
		for &v in enc.source.y.data do v = 103
		for &v in enc.source.u.data do v = 204
		for &v in enc.source.v.data do v = 305
		py, pu, pv: [32 * 32]Sample
		for &v in py do v = 101
		for &v in pu do v = 202
		for &v in pv do v = 303
		ctx := Tf_Ctx {
			cu_x    = 8,
			cu_y    = 8,
			cu_size = 32,
			pred_y  = py[:],
			pred_u  = pu[:],
			pred_v  = pv[:],
		}
		sse := tf_recon_prediction(&enc, ctx, 24, 24, 8)
		sw, sh := chroma_sub(layout)
		expected := u64(4 * (64 + (has_chroma(&enc) ? 2 * (8 / sw) * (8 / sh) : 0)))
		testing.expect_value(t, sse, expected)
		planes := [3]Plane(Sample){enc.rec.y, enc.rec.u, enc.rec.v}
		for plane, component in planes {
			if component > 0 && !has_chroma(&enc) do continue
			sx, sy := component == 0 ? 1 : sw, component == 0 ? 1 : sh
			for y in 0 ..< 64 / sy do for x in 0 ..< 64 / sx {
				inside := x >= 24 / sx && x < 32 / sx && y >= 24 / sy && y < 32 / sy
				want := inside ? Sample(101 * (component + 1)) : 0
				testing.expect_value(t, at(plane, x, y), want)
			}
		}
	}
}

// Pin the recursive paths, not just the SPS enable flags. The changing detail
// inside larger prediction blocks must select smaller transform leaves.
@(test)
test_chroma_intra_transform_splits :: proc(t: ^testing.T) {
	for layout in ([]Chroma_Layout{.Monochrome, .YUV_420, .YUV_422, .YUV_444}) {
		for depth in ([]int{8, 10}) {
			enc: Encoder
			init_encoder(
				&enc,
				{
					width = 64,
					height = 64,
					bit_depth = depth,
					qp = 26,
					chroma_format = layout,
					forced_mode = -1,
					rqt = true,
					intra_rqt = true,
				},
			)
			defer destroy_encoder(&enc)
			pixels: [64 * 64]Sample
			out: [dynamic]u8
			defer delete(out)
			splits := 0
			for f in 0 ..< 3 {
				for y in 0 ..< 64 do for x in 0 ..< 64 {
					v := ((x * x + y * 31 + (x / 4 + y / 4 + f) % 2 * 91) & 255)
					pixels[y * 64 + x] = Sample(v << uint(depth - 8))
				}
				encode_frame(
					&enc,
					raw_data(pixels[:]),
					raw_data(pixels[:]),
					raw_data(pixels[:]),
					64,
					64,
					&out,
				)
				for cu in enc.cu.cells {
					if cu.tr_depth > 0 && int(cu.tr_depth) < MAX_CU_LOG2 - int(cu.depth) {
						if cu.type == .Intra do splits += 1
					}
				}
			}
			testing.expectf(t, splits > 0, "intra split not exercised: %v/%d", layout, depth)
		}
	}
}

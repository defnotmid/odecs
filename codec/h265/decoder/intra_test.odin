package h265_decoder

import enc "../encoder"
import "core:testing"

// Encode an intra frame with the in-loop filters off, decode it, and require
// the reconstruction to be identical sample for sample. With deblocking and
// SAO disabled the bitstream signals that too, so the comparison is exact
// without Stage 5.
@(test)
test_decode_intra_matches_encoder :: proc(t: ^testing.T) {
	for dims in ([][2]int{{16, 16}, {24, 16}, {40, 24}, {64, 48}, {64, 64}, {130, 66}}) {
		for qp in ([]i32{5, 26, 45, 51}) {
			w, h := dims[0], dims[1]

			cfg := enc.Config {
				width               = w,
				height              = h,
				qp                  = qp,
				level_idc           = 120,
				forced_mode         = -1,
				deblock             = false,
				sao                 = false,
				intra_only          = true,
				intra_only_i_slices = true,
			}

			e: enc.Encoder
			enc.init_encoder(&e, cfg)

			luma := make([]enc.Sample, w * h)
			chroma := make([]enc.Sample, w * h / 4)
			for j in 0 ..< h {
				for i in 0 ..< w {
					luma[j * w + i] = enc.Sample((i * 7 + j * 13 + i * j) & 0xff)
				}
			}
			for j in 0 ..< h / 2 {
				for i in 0 ..< w / 2 {
					chroma[j * w / 2 + i] = enc.Sample((i * 11 + j * 5 + 40) & 0xff)
				}
			}

			out := make([dynamic]u8, 0, 1 << 16)
			enc.encode_frame(
				&e,
				raw_data(luma),
				raw_data(chroma),
				raw_data(chroma),
				w,
				w / 2,
				&out,
			)

			pics, ok := decode_annex_b(out[:])
			if !ok || len(pics) != 1 {
				testing.expectf(
					t,
					false,
					"dims %dx%d qp %d: decode failed (%v, %d pics)",
					w,
					h,
					qp,
					ok,
					len(pics),
				)
			} else {
				p := pics[0]
				bad := 0
				for j in 0 ..< e.coded_height {
					for i in 0 ..< e.coded_width {
						got := enc.Sample(sample_at(p, 0, i, j))
						want := e.rec.y.data[e.rec.y.offset + j * e.rec.y.stride + i]
						if got != want && bad < 8 {
							testing.expectf(
								t,
								false,
								"luma %dx%d qp %d at %d,%d: got %d want %d",
								w,
								h,
								qp,
								i,
								j,
								got,
								want,
							)
							bad += 1
						}
					}
				}
				for j in 0 ..< e.coded_height / 2 {
					for i in 0 ..< e.coded_width / 2 {
						got := enc.Sample(sample_at(p, 1, i, j))
						want := e.rec.u.data[e.rec.u.offset + j * e.rec.u.stride + i]
						if got != want && bad < 8 {
							testing.expectf(
								t,
								false,
								"cb %dx%d qp %d at %d,%d: got %d want %d",
								w,
								h,
								qp,
								i,
								j,
								got,
								want,
							)
							bad += 1
						}
						gotv := enc.Sample(sample_at(p, 2, i, j))
						wantv := e.rec.v.data[e.rec.v.offset + j * e.rec.v.stride + i]
						if gotv != wantv && bad < 8 {
							testing.expectf(
								t,
								false,
								"cr %dx%d qp %d at %d,%d: got %d want %d",
								w,
								h,
								qp,
								i,
								j,
								gotv,
								wantv,
							)
							bad += 1
						}
					}
				}
				if bad == 0 do testing.expect(t, true)
			}

			for p in pics {
				destroy_picture(p)
				free(p)
			}
			delete(pics)
			delete(out)
			delete(luma)
			delete(chroma)
			enc.destroy_encoder(&e)
		}
	}
}

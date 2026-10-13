package h265_decoder

import enc "../encoder"
import "core:testing"

// Encode a 10-bit sequence and require the decoder's samples to equal the
// encoder's reconstruction, both with and without the in-loop filters.
@(test)
test_decode_10bit_matches_encoder :: proc(t: ^testing.T) {
	for dims in ([][2]int{{16, 16}, {40, 24}, {64, 48}, {66, 64}}) {
		for qp in ([]i32{12, 26, 45}) {
			for filters in ([]bool{false, true}) {
				w, h := dims[0], dims[1]

				cfg := enc.Config {
					width       = w,
					height      = h,
					qp          = qp,
					bit_depth   = 10,
					level_idc   = 120,
					forced_mode = -1,
					deblock     = filters,
					sao         = filters,
					intra_only  = !filters,
				}

				e: enc.Encoder
				enc.init_encoder(&e, cfg)

				luma := make([]enc.Sample, w * h)
				chroma := make([]enc.Sample, w * h / 4)
				for j in 0 ..< h {
					for i in 0 ..< w {
						luma[j * w + i] = enc.Sample((i * 37 + j * 101 + i * j) & 0x3ff)
					}
				}
				for j in 0 ..< h / 2 {
					for i in 0 ..< w / 2 {
						chroma[j * w / 2 + i] = enc.Sample((i * 53 + j * 17 + 5) & 0x3ff)
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
						"10-bit %dx%d qp %d filters %v: decode failed (%v, %d pics)",
						w,
						h,
						qp,
						filters,
						ok,
						len(pics),
					)
				} else {
					p := pics[0]
					bad := 0

					if p.bit_depth_y != 10 || p.bit_depth_c != 10 {
						testing.expectf(
							t,
							false,
							"10-bit %dx%d: decoded bit depth %d/%d",
							w,
							h,
							p.bit_depth_y,
							p.bit_depth_c,
						)
					}

					for j in 0 ..< e.coded_height {
						for i in 0 ..< e.coded_width {
							got := enc.Sample(sample_at(p, 0, i, j))
							want := e.rec.y.data[e.rec.y.offset + j * e.rec.y.stride + i]
							if got != want && bad < 8 {
								testing.expectf(
									t,
									false,
									"10-bit luma %dx%d qp %d filters %v at %d,%d: got %d want %d",
									w,
									h,
									qp,
									filters,
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
							gotu := enc.Sample(sample_at(p, 1, i, j))
							wantu := e.rec.u.data[e.rec.u.offset + j * e.rec.u.stride + i]
							gotv := enc.Sample(sample_at(p, 2, i, j))
							wantv := e.rec.v.data[e.rec.v.offset + j * e.rec.v.stride + i]
							if (gotu != wantu || gotv != wantv) && bad < 8 {
								testing.expectf(
									t,
									false,
									"10-bit chroma %dx%d qp %d filters %v at %d,%d: got %d/%d want %d/%d",
									w,
									h,
									qp,
									filters,
									i,
									j,
									gotu,
									gotv,
									wantu,
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
}

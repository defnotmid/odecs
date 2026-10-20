package h265_decoder

import enc "../encoder"
import "core:testing"

// PCM coding units (7.3.8.7): raw samples instead of prediction and residual.
// QP0 must select PCM on this detailed input. Parse the SPS and require the
// decoder to reproduce the encoder's reconstruction sample for sample in all
// layouts, with and without the in-loop filters, including cropped edges.
@(test)
test_decode_pcm_matches_encoder :: proc(t: ^testing.T) {
	for layout in ([]enc.Chroma_Layout{.Monochrome, .YUV_420, .YUV_422, .YUV_444}) {
		for bit_depth in ([]int{8, 10}) {
			for filters in ([]bool{false, true}) {
				for qp in ([]i32{0, 26, 45}) {
					w, h := 66, 50
					sw, sh := enc.chroma_sub(layout)
					cw, ch := w / sw, layout == .Monochrome ? 0 : h / sh
					mask := bit_depth > 8 ? 0x3ff : 0xff

					cfg := enc.Config {
						width         = w,
						chroma_format = layout,
						height        = h,
						qp            = qp,
						bit_depth     = bit_depth,
						level_idc     = 120,
						forced_mode   = -1,
						deblock       = filters,
						sao           = filters,
						intra_only    = true,
						pcm           = true,
					}

					e: enc.Encoder
					enc.init_encoder(&e, cfg)

					luma := make([]enc.Sample, w * h)
					chroma := make([]enc.Sample, cw * ch)
					for j in 0 ..< h {
						for i in 0 ..< w {
							luma[j * w + i] = enc.Sample((i * i * 7 + j * j * 13 + i * j) & mask)
						}
					}
					for j in 0 ..< ch {
						for i in 0 ..< cw {
							chroma[j * cw + i] = enc.Sample((i * 31 + j * 17 + (i + j) * 3) & mask)
						}
					}

					out := make([dynamic]u8, 0, 1 << 16)
					enc.encode_frame(
						&e,
						raw_data(luma),
						raw_data(chroma),
						raw_data(chroma),
						w,
						cw,
						&out,
					)

					if qp == 0 {
						selected := false
						for y := 0; y < h; y += 8 do for x := 0; x < w; x += 8 do selected = selected || enc.cu_at(e.cu, x, y).pcm
						testing.expectf(
							t,
							selected,
							"PCM was not exercised: layout %v depth %d",
							layout,
							bit_depth,
						)
					}

					// The SPS must carry the PCM parameters the encoder chose.
					nals := split_annex_b(out[:])
					sps_nal := find_nal(nals[:], .SPS_NUT)
					if sps_nal == nil {
						testing.expectf(
							t,
							false,
							"%d-bit qp %d filters %v: no SPS",
							bit_depth,
							qp,
							filters,
						)
					} else {
						sps, sok := parse_sps(sps_nal.rbsp)
						testing.expectf(
							t,
							sok &&
							sps.pcm_enabled &&
							int(sps.pcm_bit_depth_luma) == bit_depth &&
							int(sps.log2_min_pcm_cb_size) == 3 &&
							int(sps.log2_max_pcm_cb_size) == 5,
							"%d-bit qp %d: SPS pcm %v depth %d range %d..%d (ok %v)",
							bit_depth,
							qp,
							sps.pcm_enabled,
							sps.pcm_bit_depth_luma,
							sps.log2_min_pcm_cb_size,
							sps.log2_max_pcm_cb_size,
							sok,
						)
						if sok do destroy_sps(&sps)
					}
					for i in 0 ..< len(nals) do destroy_nal(&nals[i])
					delete(nals)

					pics, ok := decode_annex_b(out[:])
					if !ok || len(pics) != 1 {
						testing.expectf(
							t,
							false,
							"%d-bit qp %d filters %v: decode failed (%v, %d pics)",
							bit_depth,
							qp,
							filters,
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
										"%d-bit qp %d filters %v luma at %d,%d: got %d want %d",
										bit_depth,
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
						for j in 0 ..< (layout == .Monochrome ? 0 : e.coded_height / sh) {
							for i in 0 ..< e.coded_width / sw {
								gotu := enc.Sample(sample_at(p, 1, i, j))
								wantu := e.rec.u.data[e.rec.u.offset + j * e.rec.u.stride + i]
								gotv := enc.Sample(sample_at(p, 2, i, j))
								wantv := e.rec.v.data[e.rec.v.offset + j * e.rec.v.stride + i]
								if (gotu != wantu || gotv != wantv) && bad < 8 {
									testing.expectf(
										t,
										false,
										"%d-bit qp %d filters %v chroma at %d,%d: got %d/%d want %d/%d",
										bit_depth,
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
}

package h265_decoder

import hevc ".."
import enc "../encoder"
import "core:testing"

// Scaling lists (7.4.5): the encoder signals them and quantizes with them, the
// decoder parses them and dequantizes with them. Decode our own --scaling-list
// default and flat streams and require the decoder to reproduce the encoder's
// reconstruction sample for sample, with and without the in-loop filters. The
// flat list is all 16, so it must equal a flat encode while still carrying the
// syntax; the SPS check pins that.
@(test)
test_decode_scaling_matches_encoder :: proc(t: ^testing.T) {
	for bit_depth in ([]int{8, 10}) {
		for mode in ([]enc.Scaling_Mode{.Default, .Flat}) {
			for filters in ([]bool{false, true}) {
				w, h := 130, 66
				mask := bit_depth > 8 ? 0x3ff : 0xff

				cfg := enc.Config {
					width       = w,
					height      = h,
					qp          = 26,
					bit_depth   = bit_depth,
					level_idc   = 120,
					forced_mode = -1,
					deblock     = filters,
					sao         = filters,
					intra_only  = true,
					intra_rqt   = true,
					tskip       = true,
					scaling     = mode,
				}

				e: enc.Encoder
				enc.init_encoder(&e, cfg)

				luma := make([]enc.Sample, w * h)
				chroma := make([]enc.Sample, w * h / 4)
				for j in 0 ..< h {
					for i in 0 ..< w {
						luma[j * w + i] = enc.Sample((i * i * 7 + j * j * 13 + i * j) & mask)
					}
				}
				for j in 0 ..< h / 2 {
					for i in 0 ..< w / 2 {
						chroma[j * w / 2 + i] = enc.Sample((i * 31 + j * 17 + (i + j) * 3) & mask)
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

				// The SPS must carry the mode's list: the defaults for Default,
				// all-16 for Flat.
				nals := split_annex_b(out[:])
				sps_nal := find_nal(nals[:], .SPS_NUT)
				if sps_nal == nil {
					testing.expectf(
						t,
						false,
						"%d-bit %v filters %v: no SPS",
						bit_depth,
						mode,
						filters,
					)
				} else {
					sps, sok := parse_sps(sps_nal.rbsp)
					want := hevc.default_scaling_list()
					if mode == .Flat {
						// 7.3.4 signals only matrixId 0 and 3 for sizeId 3; the
						// others are inferred and unused in 4:2:0.
						for s in 0 ..< hevc.MAX_SCALING_LIST_SIZES {
							for m in 0 ..< hevc.MAX_SCALING_LIST_MATS {
								if s == 3 && m % 3 != 0 do continue
								n := s == 0 ? 16 : 64
								for i in 0 ..< n do want.sl[s][m][i] = 16
							}
						}
						for s in 0 ..< 2 {
							for m in 0 ..< hevc.MAX_SCALING_LIST_MATS do want.dc[s][m] = 16
						}
					}
					match := sok && sps.scaling_list_enabled
					if match {
						for s in 0 ..< hevc.MAX_SCALING_LIST_SIZES {
							for m in 0 ..< hevc.MAX_SCALING_LIST_MATS {
								n := s == 0 ? 16 : 64
								for i in 0 ..< n {
									if sps.scaling_list.sl[s][m][i] != want.sl[s][m][i] {
										match = false
									}
								}
							}
						}
					}
					testing.expectf(
						t,
						match,
						"%d-bit %v filters %v: SPS scaling list mismatch (ok %v enabled %v)",
						bit_depth,
						mode,
						filters,
						sok,
						sok && sps.scaling_list_enabled,
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
						"%d-bit %v filters %v: decode failed (%v, %d pics)",
						bit_depth,
						mode,
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
									"%d-bit %v filters %v luma at %d,%d: got %d want %d",
									bit_depth,
									mode,
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
									"%d-bit %v filters %v chroma at %d,%d: got %d/%d want %d/%d",
									bit_depth,
									mode,
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

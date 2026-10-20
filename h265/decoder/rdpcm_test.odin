package h265_decoder

import enc "../encoder"
import "core:testing"

// Implicit residual DPCM is the SPS range-extension tool that rides on the 4x4
// intra transform-skip path. Encode with it on, parse the SPS, and require the
// decoder's samples to equal the encoder's reconstruction (filters off, so the
// comparison is exact). Modes 10 and 26 are the ones that take the DPCM path.
@(test)
test_decode_rdpcm_matches_encoder :: proc(t: ^testing.T) {
	for bit_depth in ([]int{8, 10}) {
		for forced in ([]i32{-1, 10, 26}) {
			for qp in ([]i32{22, 42}) {
				w, h := 64, 48
				mask := bit_depth > 8 ? 0x3ff : 0xff

				cfg := enc.Config {
					width       = w,
					height      = h,
					qp          = qp,
					bit_depth   = bit_depth,
					level_idc   = 120,
					forced_mode = forced,
					deblock     = false,
					sao         = false,
					intra_only  = true,
					intra_rqt   = true,
					tskip       = true,
					rdpcm       = true,
				}

				e: enc.Encoder
				enc.init_encoder(&e, cfg)

				luma := make([]enc.Sample, w * h)
				chroma := make([]enc.Sample, w * h / 4)
				for j in 0 ..< h {
					for i in 0 ..< w {
						luma[j * w + i] = enc.Sample((i * 7 + j * 13 + i * j) & mask)
					}
				}
				for j in 0 ..< h / 2 {
					for i in 0 ..< w / 2 {
						chroma[j * w / 2 + i] = enc.Sample((i * 11 + j * 5 + 40) & mask)
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

				// The SPS must advertise exactly the tool the encoder applied.
				nals := split_annex_b(out[:])
				sps_nal := find_nal(nals[:], .SPS_NUT)
				if sps_nal == nil {
					testing.expectf(
						t,
						false,
						"%d-bit qp %d mode %d: no SPS",
						bit_depth,
						qp,
						forced,
					)
				} else {
					sps, sok := parse_sps(sps_nal.rbsp)
					testing.expectf(
						t,
						sok && sps.implicit_rdpcm && !sps.explicit_rdpcm,
						"%d-bit qp %d mode %d: SPS rdpcm %v/%v (ok %v)",
						bit_depth,
						qp,
						forced,
						sps.implicit_rdpcm,
						sps.explicit_rdpcm,
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
						"%d-bit qp %d mode %d: decode failed (%v, %d pics)",
						bit_depth,
						qp,
						forced,
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
									"%d-bit qp %d mode %d luma at %d,%d: got %d want %d",
									bit_depth,
									qp,
									forced,
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
									"%d-bit qp %d mode %d chroma at %d,%d: got %d/%d want %d/%d",
									bit_depth,
									qp,
									forced,
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

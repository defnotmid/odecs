package h265_decoder

import enc "../encoder"
import "core:testing"

// Encode a P-frame sequence with the in-loop filters off, decode it, and
// require every reconstruction to be identical sample for sample. The first
// frame is intra and the rest reference their predecessor, so this exercises
// reference picture lists, merge/AMVP and motion compensation end to end.
@(test)
test_decode_inter_matches_encoder :: proc(t: ^testing.T) {
	dims := [][2]int{{16, 16}, {32, 24}, {64, 48}, {130, 66}}
	qps := []i32{12, 26, 42}
	frames := 4

	for d in dims {
		for qp in qps {
			w, h := d[0], d[1]

			cfg := enc.Config {
				width       = w,
				height      = h,
				qp          = qp,
				level_idc   = 120,
				forced_mode = -1,
				deblock     = false,
				sao         = false,
			}

			e: enc.Encoder
			enc.init_encoder(&e, cfg)

			cw, ch := e.coded_width, e.coded_height
			cfs := cw * ch * 3 / 2
			rec := make([]u8, frames * cfs)
			defer delete(rec)

			out := make([dynamic]u8, 0, 1 << 16)
			defer delete(out)

			luma := make([]enc.Sample, w * h)
			chroma := make([]enc.Sample, w * h / 4)
			defer delete(luma)
			defer delete(chroma)

			for f in 0 ..< frames {
				for j in 0 ..< h {
					for i in 0 ..< w {
						sx := (i + f * 2) % w
						sy := (j + f) % h
						luma[j * w + i] = enc.Sample(
							(sx * 3 + sy * 7 + ((sx / 16 + sy / 16) % 2) * 80) & 0xff,
						)
					}
				}
				for j in 0 ..< h / 2 {
					for i in 0 ..< w / 2 {
						chroma[j * w / 2 + i] = enc.Sample((i * 5 + j * 3 + f * 9) & 0xff)
					}
				}

				enc.encode_frame(
					&e,
					raw_data(luma),
					raw_data(chroma),
					raw_data(chroma),
					w,
					w / 2,
					&out,
				)

				base := f * cfs
				for j in 0 ..< ch {
					for i in 0 ..< cw {
						rec[base + j * cw + i] = u8(
							e.rec.y.data[e.rec.y.offset + j * e.rec.y.stride + i],
						)
					}
				}
				cbase := base + cw * ch
				for j in 0 ..< ch / 2 {
					for i in 0 ..< cw / 2 {
						rec[cbase + j * (cw / 2) + i] = u8(
							e.rec.u.data[e.rec.u.offset + j * e.rec.u.stride + i],
						)
						rec[cbase + cw * ch / 4 + j * (cw / 2) + i] = u8(
							e.rec.v.data[e.rec.v.offset + j * e.rec.v.stride + i],
						)
					}
				}
			}

			pics, ok := decode_annex_b(out[:])
			if !ok || len(pics) != frames {
				testing.expectf(
					t,
					false,
					"%dx%d qp %d: decode failed (%v, %d pics)",
					w,
					h,
					qp,
					ok,
					len(pics),
				)
			} else {
				bad := 0

				for f in 0 ..< frames {
					p := pics[f]
					base := f * cfs

					for j in 0 ..< ch {
						for i in 0 ..< cw {
							if u8(p.y[j * p.stride_y + i]) != rec[base + j * cw + i] && bad < 8 {
								testing.expectf(
									t,
									false,
									"%dx%d qp %d frame %d luma at %d,%d: got %d want %d",
									w,
									h,
									qp,
									f,
									i,
									j,
									p.y[j * p.stride_y + i],
									rec[base + j * cw + i],
								)
								bad += 1
							}
						}
					}

					cbase := base + cw * ch
					for j in 0 ..< ch / 2 {
						for i in 0 ..< cw / 2 {
							if u8(p.u[j * p.stride_c + i]) != rec[cbase + j * (cw / 2) + i] &&
							   bad < 8 {
								testing.expectf(
									t,
									false,
									"%dx%d qp %d frame %d cb at %d,%d",
									w,
									h,
									qp,
									f,
									i,
									j,
								)
								bad += 1
							}
							if u8(p.v[j * p.stride_c + i]) !=
								   rec[cbase + cw * ch / 4 + j * (cw / 2) + i] &&
							   bad < 8 {
								testing.expectf(
									t,
									false,
									"%dx%d qp %d frame %d cr at %d,%d",
									w,
									h,
									qp,
									f,
									i,
									j,
								)
								bad += 1
							}
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

			enc.destroy_encoder(&e)
		}
	}
}

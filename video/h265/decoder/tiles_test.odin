package h265_decoder

import common "../../../common"
import enc "../encoder"
import "core:testing"

// Encode a sequence with wavefronts and decode it: the substream entry points,
// the 9.3.1 context handoff and the tile-scan order have to reproduce the
// encoder's reconstruction exactly, with P and B slices and the in-loop filters
// on. The PPS must advertise the tool and a multi-row picture must carry one
// entry point per row boundary.
@(test)
test_decode_wavefront_matches_encoder :: proc(t: ^testing.T) {
	dims := [][2]int{{16, 16}, {32, 24}, {64, 48}, {66, 64}, {130, 66}, {192, 66}}
	qps := []i32{12, 26, 42}
	frames := 4

	for d in dims {
		for qp in qps {
			for b_frames in ([]bool{false, true}) {
				w, h := d[0], d[1]

				cfg := enc.Config {
					width       = w,
					height      = h,
					qp          = qp,
					level_idc   = 120,
					forced_mode = -1,
					deblock     = true,
					sao         = true,
					wpp         = true,
					b_frames    = b_frames,
					capture_rec = true,
				}

				e: enc.Encoder
				enc.init_encoder(&e, cfg)

				luma := make([]enc.Sample, w * h)
				chroma := make([]enc.Sample, w * h / 4)
				defer delete(luma)
				defer delete(chroma)

				out := make([dynamic]u8, 0, 1 << 16)
				defer delete(out)

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
				}

				// The parameter sets and the first inter slice must signal what
				// the decoder is being tested on.
				nals := split_annex_b(out[:])
				sps_nal := find_nal(nals[:], .SPS_NUT)
				pps_nal := find_nal(nals[:], .PPS_NUT)

				if sps_nal == nil || pps_nal == nil {
					testing.expectf(
						t,
						false,
						"%dx%d qp %d b%d: no parameter sets",
						w,
						h,
						qp,
						b_frames,
					)
				} else {
					sps, sok := parse_sps(sps_nal.rbsp)
					pps, pok := parse_pps(pps_nal.rbsp)

					testing.expectf(
						t,
						sok && pok && pps.entropy_coding_sync,
						"%dx%d qp %d b%d: PPS entropy_coding_sync %v (ok %v/%v)",
						w,
						h,
						qp,
						b_frames,
						pps.entropy_coding_sync,
						sok,
						pok,
					)

					if sok && pok && int(sps.pic_height_in_ctbs) > 1 {
						first_trail: ^Nal_Unit
						for &n in nals {
							if n.type == .TRAIL_R {
								first_trail = &n
								break
							}
						}

						if first_trail == nil {
							testing.expectf(
								t,
								false,
								"%dx%d qp %d b%d: no TRAIL slice",
								w,
								h,
								qp,
								b_frames,
							)
						} else {
							sh, hok := parse_slice_header(
								first_trail.rbsp,
								first_trail.type,
								&sps,
								&pps,
							)
							testing.expectf(
								t,
								hok &&
								len(sh.entry_point_offsets) == int(sps.pic_height_in_ctbs) - 1,
								"%dx%d qp %d b%d: entry points %d, want %d (ok %v)",
								w,
								h,
								qp,
								b_frames,
								len(sh.entry_point_offsets),
								int(sps.pic_height_in_ctbs) - 1,
								hok,
							)
							if hok do destroy_slice_header(&sh)
						}
					}

					if sok do destroy_sps(&sps)
					if pok do destroy_pps(&pps)
				}

				for i in 0 ..< len(nals) do destroy_nal(&nals[i])
				delete(nals)

				pics, ok := decode_annex_b(out[:])
				if !ok || len(pics) != frames {
					testing.expectf(
						t,
						false,
						"%dx%d qp %d b%d: decode failed (%v, %d pics)",
						w,
						h,
						qp,
						b_frames,
						ok,
						len(pics),
					)
				} else {
					got: [dynamic]u8
					defer delete(got)

					for p in pics do append_picture_display(p, &got)

					if len(got) != len(e.rec_display) {
						testing.expectf(
							t,
							false,
							"%dx%d qp %d b%d: %d decoded bytes, want %d",
							w,
							h,
							qp,
							b_frames,
							len(got),
							len(e.rec_display),
						)
					} else {
						bad := 0
						for v, i in got {
							if v != e.rec_display[i] && bad < 8 {
								testing.expectf(
									t,
									false,
									"%dx%d qp %d b%d byte %d: got %d want %d",
									w,
									h,
									qp,
									b_frames,
									i,
									v,
									e.rec_display[i],
								)
								bad += 1
							}
						}
						if bad == 0 do testing.expect(t, true)
					}
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
}

// Tiles: the encoder's 6.5.1 tile-scan coding order, per-tile CABAC substreams
// and tile-aware availability must round-trip through the decoder exactly as
// the wavefront path does. The PPS spells the tile grid out.
@(test)
test_decode_tiles_matches_encoder :: proc(t: ^testing.T) {
	cases := [][4]int {
		{128, 64, 2, 1},
		{128, 128, 2, 2},
		{192, 128, 3, 2},
		{130, 66, 2, 2},
		{256, 192, 4, 3},
		{320, 130, 5, 3},
	}
	qps := []i32{12, 26, 42}
	frames := 4

	for cs in cases {
		for qp in qps {
			for b_frames in ([]bool{false, true}) {
				w, h, cols, rows := cs[0], cs[1], cs[2], cs[3]

				cfg := enc.Config {
					width       = w,
					height      = h,
					qp          = qp,
					level_idc   = 120,
					forced_mode = -1,
					deblock     = true,
					sao         = true,
					tiles_cols  = cols,
					tiles_rows  = rows,
					b_frames    = b_frames,
					capture_rec = true,
				}

				e: enc.Encoder
				enc.init_encoder(&e, cfg)

				luma := make([]enc.Sample, w * h)
				chroma := make([]enc.Sample, w * h / 4)
				defer delete(luma)
				defer delete(chroma)

				out := make([dynamic]u8, 0, 1 << 16)
				defer delete(out)

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
				}

				// The PPS must carry the tile grid and the slice one entry
				// point per substream (one per tile).
				nals := split_annex_b(out[:])
				sps_nal := find_nal(nals[:], .SPS_NUT)
				pps_nal := find_nal(nals[:], .PPS_NUT)

				if sps_nal == nil || pps_nal == nil {
					testing.expectf(
						t,
						false,
						"%dx%d %dx%d qp %d: no parameter sets",
						w,
						h,
						cols,
						rows,
						qp,
					)
				} else {
					sps, sok := parse_sps(sps_nal.rbsp)
					pps, pok := parse_pps(pps_nal.rbsp)

					testing.expectf(
						t,
						sok &&
						pok &&
						pps.tiles_enabled &&
						pps.num_tile_columns == cols &&
						pps.num_tile_rows == rows,
						"%dx%d %dx%d qp %d: tiles %v %dx%d (ok %v/%v)",
						w,
						h,
						cols,
						rows,
						qp,
						pps.tiles_enabled,
						pps.num_tile_columns,
						pps.num_tile_rows,
						sok,
						pok,
					)

					if sok && pok {
						first_trail: ^Nal_Unit
						for &n in nals {
							if n.type == .TRAIL_R {
								first_trail = &n
								break
							}
						}

						if first_trail == nil {
							testing.expectf(
								t,
								false,
								"%dx%d %dx%d qp %d: no TRAIL slice",
								w,
								h,
								cols,
								rows,
								qp,
							)
						} else {
							sh, hok := parse_slice_header(
								first_trail.rbsp,
								first_trail.type,
								&sps,
								&pps,
							)
							testing.expectf(
								t,
								hok && len(sh.entry_point_offsets) == cols * rows - 1,
								"%dx%d %dx%d qp %d: entry points %d, want %d (ok %v)",
								w,
								h,
								cols,
								rows,
								qp,
								len(sh.entry_point_offsets),
								cols * rows - 1,
								hok,
							)
							if hok do destroy_slice_header(&sh)
						}
					}

					if sok do destroy_sps(&sps)
					if pok do destroy_pps(&pps)
				}

				for i in 0 ..< len(nals) do destroy_nal(&nals[i])
				delete(nals)

				pics, ok := decode_annex_b(out[:])
				if !ok || len(pics) != frames {
					testing.expectf(
						t,
						false,
						"%dx%d %dx%d qp %d: decode failed (%v, %d pics)",
						w,
						h,
						cols,
						rows,
						qp,
						ok,
						len(pics),
					)
				} else {
					got: [dynamic]u8
					defer delete(got)

					for p in pics do append_picture_display(p, &got)

					if len(got) != len(e.rec_display) {
						testing.expectf(
							t,
							false,
							"%dx%d %dx%d qp %d: %d decoded bytes, want %d",
							w,
							h,
							cols,
							rows,
							qp,
							len(got),
							len(e.rec_display),
						)
					} else {
						bad := 0
						for v, i in got {
							if v != e.rec_display[i] && bad < 8 {
								testing.expectf(
									t,
									false,
									"%dx%d %dx%d qp %d byte %d: got %d want %d",
									w,
									h,
									cols,
									rows,
									qp,
									i,
									v,
									e.rec_display[i],
								)
								bad += 1
							}
						}
						if bad == 0 do testing.expect(t, true)
					}
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
}

// The parallel tile search must produce the serial bitstream exactly: the
// per-tile decisions and their trial streams never cross a tile boundary, so
// the output is independent of the thread count.
@(test)
test_tiles_threads_deterministic :: proc(t: ^testing.T) {
	w, h, frames := 256, 128, 3
	reference: [dynamic]u8
	defer delete(reference)

	luma := make([]enc.Sample, w * h)
	chroma := make([]enc.Sample, w * h / 4)
	defer delete(luma)
	defer delete(chroma)

	for threads, run in ([]int{0, 1, 2, 3}) {
		// The pool belongs to the caller (here the test): the encoder only
		// ever sees the Work_Pool interface.
		pool: common.Static_Pool
		if threads > 0 do common.init_static_pool(&pool, threads)

		cfg := enc.Config {
			width       = w,
			height      = h,
			qp          = 26,
			level_idc   = 120,
			forced_mode = -1,
			deblock     = true,
			sao         = true,
			tiles_cols  = 2,
			tiles_rows  = 2,
			b_frames    = true,
			pool        = threads > 0 ? &pool.work_pool : nil,
			capture_rec = true,
		}

		e: enc.Encoder
		enc.init_encoder(&e, cfg)

		out := make([dynamic]u8, 0, 1 << 16)
		defer delete(out)

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
		}

		if run == 0 {
			append(&reference, ..out[:])
		} else {
			testing.expectf(
				t,
				len(out) == len(reference),
				"threads %d: %d bytes, want %d",
				threads,
				len(out),
				len(reference),
			)
			same := len(out) == len(reference)
			for b, i in out {
				if !same || b == reference[i] do continue
				testing.expectf(
					t,
					false,
					"threads %d byte %d: got %d want %d",
					threads,
					i,
					b,
					reference[i],
				)
				same = false
			}
			if same do testing.expectf(t, true, "threads %d identical", threads)
		}

		pics, ok := decode_annex_b(out[:])
		testing.expectf(
			t,
			ok && len(pics) == frames,
			"threads %d: decode %v %d pics",
			threads,
			ok,
			len(pics),
		)
		if ok {
			got: [dynamic]u8
			defer delete(got)
			for p in pics do append_picture_display(p, &got)
			same := len(got) == len(e.rec_display)
			for b, i in got {
				if !same || b == e.rec_display[i] do continue
				testing.expectf(
					t,
					false,
					"threads %d rec byte %d: got %d want %d",
					threads,
					i,
					b,
					e.rec_display[i],
				)
				same = false
			}
			if same do testing.expect(t, true)
		}
		for p in pics {
			destroy_picture(p)
			free(p)
		}
		delete(pics)

		enc.destroy_encoder(&e)
		if threads > 0 do common.destroy_static_pool(&pool)
	}
}

// Repeated slice/SPS geometry resolution must retire old allocations, while
// invalid replacement geometry leaves the previous valid result intact.
@(test)
test_tile_geometry_replacement :: proc(t: ^testing.T) {
	p := PPS {
		tiles_enabled    = true,
		uniform_spacing  = true,
		num_tile_columns = 2,
		num_tile_rows    = 2,
	}
	defer destroy_pps(&p)
	for width in 4 ..< 12 {
		s := SPS {
			pic_width_in_ctbs  = u32(width),
			pic_height_in_ctbs = 6,
		}
		testing.expect(t, pps_resolve_tile_geometry(&p, &s))
		testing.expect_value(t, p.col_widths_in_ctbs[0] + p.col_widths_in_ctbs[1], u32(width))
		testing.expect_value(t, p.row_heights_in_ctbs[0] + p.row_heights_in_ctbs[1], u32(6))
	}
	old_cols, old_rows := raw_data(p.col_widths_in_ctbs), raw_data(p.row_heights_in_ctbs)
	bad := SPS {
		pic_width_in_ctbs  = 1,
		pic_height_in_ctbs = 6,
	}
	testing.expect(t, !pps_resolve_tile_geometry(&p, &bad))
	testing.expect(
		t,
		raw_data(p.col_widths_in_ctbs) == old_cols && raw_data(p.row_heights_in_ctbs) == old_rows,
	)
	p.tiles_enabled = false
	s := SPS {
		pic_width_in_ctbs  = 7,
		pic_height_in_ctbs = 3,
	}
	testing.expect(t, pps_resolve_tile_geometry(&p, &s))
	testing.expect_value(t, p.col_widths_in_ctbs[0], u32(7))
	testing.expect_value(t, p.row_heights_in_ctbs[0], u32(3))
}

package h265_decoder

import enc "../encoder"
@(require) import "core:fmt"
@(require) import "core:os"
import "core:testing"

@(private)
periodic_expect_pixels :: proc(t: ^testing.T, pics: []^Picture, e: ^enc.Encoder, first: int) {
	deep := e.bit_depth > 8
	frame_bytes := e.width * e.height * 3 / 2 * (deep ? 2 : 1)
	for p, n in pics {
		at := (first + n) * frame_bytes
		for c in 0 ..< 3 {
			w, h := e.width, e.height
			if c != 0 do w, h = w / 2, h / 2
			for y in 0 ..< h do for x in 0 ..< w {
				want := int(e.rec_display[at]); at += 1
				if deep {want |= int(e.rec_display[at]) << 8; at += 1}
				if got := sample_at(p, c, x, y); got != want {testing.expect_value(t, got, want); return}
			}
		}
	}
}

@(test)
periodic_closed_idr :: proc(t: ^testing.T) {
	frames, period, w, h :: 13, 5, 40, 24
	for depth in ([]int{8, 10}) do for refs in ([]int{1, 4}) {
		e: enc.Encoder
		enc.init_encoder(&e, {width = w, height = h, bit_depth = depth, refs = refs, idr_period = period, qp = 24, forced_mode = -1, deblock = true, sao = true, tmvp = true, capture_rec = true})
		defer enc.destroy_encoder(&e)
		y := make([]enc.Sample, w * h); defer delete(y)
		u := make([]enc.Sample, w * h / 4); defer delete(u)
		v := make([]enc.Sample, w * h / 4); defer delete(v)
		stream := make([dynamic]u8); defer delete(stream)
		starts: [4]int
		count := 0
		for frame in 0 ..< frames {
			for &pixel, i in y do pixel = enc.Sample((i * 13 + (i / w) * 29 + frame * 17) & ((1 << uint(depth)) - 1))
			for &pixel, i in u do pixel = enc.Sample((i * 7 + frame * 23 + 77) & ((1 << uint(depth)) - 1))
			for &pixel, i in v do pixel = enc.Sample((i * 11 + frame * 5 + 111) & ((1 << uint(depth)) - 1))
			if frame % period == 0 {starts[count] = len(stream); count += 1}
			enc.encode_frame(&e, raw_data(y), raw_data(u), raw_data(v), w, w / 2, &stream)
		}
		starts[count] = len(stream)
		testing.expect_value(t, len(e.rec_display), frames * w * h * 3 / 2 * int(depth > 8 ? 2 : 1))
		nals := split_annex_b(stream[:])
		defer {for &nal in nals do destroy_nal(&nal); delete(nals)}
		vps, sps, pps, idr := 0, 0, 0, 0
		for nal in nals {
			#partial switch nal.type {
			case .VPS_NUT:
				vps += 1
			case .SPS_NUT:
				sps += 1
			case .PPS_NUT:
				pps += 1
			case .IDR_W_RADL:
				idr += 1
			}
		}
		testing.expect(t, vps == 3 && sps == 3 && pps == 3 && idr == 3)
		pics, ok := decode_annex_b(stream[:])
		testing.expect(t, ok && len(pics) == frames)
		if ok do periodic_expect_pixels(t, pics[:], &e, 0)
		for pic, i in pics {
			testing.expect_value(t, int(pic.poc), i % period)
			destroy_picture(pic); free(pic)
		}
		delete(pics)
		// Every closed GOP is independently decodable from its repeated headers.
		for group in 0 ..< count {
			part, good := decode_annex_b(stream[starts[group]:starts[group + 1]])
			testing.expect(t, good && len(part) == min(period, frames - group * period))
			if good do periodic_expect_pixels(t, part[:], &e, group * period)
			for pic in part {destroy_picture(pic); free(pic)}
			delete(part)
		}
		when #config(ODECS_PERIODIC_IDR_DIR, "") != "" {
			prefix := fmt.aprintf("%s/periodic-%d-%d", #config(ODECS_PERIODIC_IDR_DIR, ""), depth, refs)
			defer delete(prefix)
			for extension, i in ([2]string{".265", ".rec.yuv"}) {
				path := fmt.aprintf("%s%s", prefix, extension)
				data := i == 0 ? stream[:] : e.rec_display[:]
				testing.expect(t, os.write_entire_file(path, data) == nil)
				delete(path)
			}
		}
	}
}

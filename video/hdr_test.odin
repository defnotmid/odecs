package video

import media "../media"
import "core:testing"

@(test)
tone_curve_bt2390 :: proc(t: ^testing.T) {
	// Identity below the knee, the 1000-nit peak onto SDR white, monotonic.
	testing.expect(t, abs(tone(0.2) - 0.2) < 1e-9)
	testing.expect(t, abs(tone(HDR_PEAK / SDR_WHITE) - 1) < 1e-6)
	testing.expect(t, abs(tone(1) - 0.78346) < 1e-4) // BT.2390 at 203 nits, worked out separately
	previous := 0.0
	for i in 1 ..= 1000 {
		v := tone(f64(i) * 0.005)
		testing.expect(t, v >= previous)
		previous = v
	}
}

// One 10-bit 4:4:4 pixel through the HDR path.
@(private = "file")
convert_pixel :: proc(c: media.Color, y, u, v: u16) -> [4]u8 {
	tm := new(Tone_Map)
	defer free(tm)
	init_tone_map(tm, c, 10)
	ys, us, vs := [1]u16{y}, [1]u16{u}, [1]u16{v}
	planes := [3][]u8{([^]u8)(&ys)[:2], ([^]u8)(&us)[:2], ([^]u8)(&vs)[:2]}
	out: [4]u8
	hdr_to_rgba(planes, {2, 2, 2}, 1, 1, 16, 0, 0, tm, out[:], 4)
	return out
}

@(test)
hlg_follows_bt2100 :: proc(t: ^testing.T) {
	hlg := media.Color{9, 18, 9, false}
	// Grey at HLG signal 0.4475 (code 456): 38.84 display nits on a
	// 1000-nit display, under the knee, so 255 * (38.84 / 203)^(1/2.4).
	testing.expect_value(t, convert_pixel(hlg, 456, 512, 512), [4]u8{128, 128, 128, 255})
	// A saturated blue, with BT.2100's luminance-based OOTF (worked out by
	// hand from the same code values).
	testing.expect_value(t, convert_pixel(hlg, 297, 695, 506), [4]u8{61, 67, 179, 255})
}

@(test)
pq_reference_white :: proc(t: ^testing.T) {
	// 203 nits (PQ code 0.5806 -> 10-bit limited 572.6) sits above the knee
	// and comes out just under SDR white.
	px := convert_pixel({9, 16, 9, false}, 573, 512, 512)
	testing.expect(t, px[0] == px[1] && px[1] == px[2] && px[0] > 225 && px[0] < 255)
}

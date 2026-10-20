// Checks video.Reader's HDR and wide-gamut conversion against FFmpeg's
// zscale: the oracle is zscale's linear BT.709 light (gbrpf32le, 1.0 = SDR
// white, 203 nits), passed through the reader's BT.2390 curve and the
// BT.1886 inverse; this isolates Y'CbCr to RGB, the PQ/HLG EOTF (and HLG's
// OOTF), the gamut conversion and the tables from the tone curve, which
// movie's unit tests check. Reports the 8-bit differences.
//
//   /tmp/hdr_compare FILE ORACLE.lin [LIGHT_SCALE]
package hdr_compare

import video "../video"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:time"

main :: proc() {
	if len(os.args) < 3 {fmt.eprintln("usage: hdr_compare FILE ORACLE.lin [LIGHT_SCALE]"); os.exit(2)}
	scale := 1.0
	if len(os.args) > 3 do scale, _ = strconv.parse_f64(os.args[3])
	r: video.Reader
	if e := video.open_reader(&r, os.args[1], {preference = .Native}); e != .None {fmt.eprintln("open", e); os.exit(1)}
	defer video.close_reader(&r)
	oracle, err := os.read_entire_file(os.args[2], context.allocator)
	if err != nil {fmt.eprintln("cannot read oracle"); os.exit(1)}
	floats := ([^]f32)(raw_data(oracle))[:len(oracle) / 4]
	w, h := r.video.width, r.video.height
	plane := w * h
	fmt.printfln("%s: %dx%d colour %v", os.args[1], w, h, r.video.color)
	histogram: [256]int
	worst, total, frames := 0, 0, 0
	elapsed: time.Duration
	for {
		t0 := time.tick_now()
		f, e := video.next_frame(&r)
		elapsed += time.tick_since(t0)
		if e != .None do break
		base := frames * 3 * plane
		if base + 3 * plane > len(floats) do break
		for i in 0 ..< plane {
			// gbrpf32le: G, B, R planes.
			rgb := [3]f64{f64(floats[base + 2 * plane + i]), f64(floats[base + i]), f64(floats[base + plane + i])}
			for &c in rgb do c = max(c * scale, 0)
			m := max(rgb[0], rgb[1], rgb[2])
			k := m > 0 ? video.tone(m) / m : 1
			for c in 0 ..< 3 {
				want := int(math.round(255 * math.pow(min(rgb[c] * k, 1), 1 / 2.4)))
				d := abs(int(f.rgba[i * 4 + c]) - want)
				histogram[d] += 1
				worst = max(worst, d)
				total += 1
			}
		}
		frames += 1
	}
	within1 := histogram[0] + histogram[1]
	fmt.printfln("  %d frames, %.2f ms/frame decode+convert: max difference %d, %.4f%% exact, %.4f%% within 1", frames, time.duration_milliseconds(elapsed) / f64(max(frames, 1)), worst, 100 * f64(histogram[0]) / f64(total), 100 * f64(within1) / f64(total))
}

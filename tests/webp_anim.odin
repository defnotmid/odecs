// Decodes an animated WebP with webp and compares every composited
// canvas with libwebp's `anim_dump -pam` frames (dump_0000.pam, ...).
// anim_dump writes fully transparent pixels as transparent black (to compare
// with GIF); the decoders keep their colour, so they are compared the same
// way.
//
//   webp_anim in.webp ref-folder
package main

import webp "../webp"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

main :: proc() {
	if len(os.args) < 3 {fmt.eprintln("usage: webp_anim in.webp ref-folder"); os.exit(2)}
	data, rerr := os.read_entire_file(os.args[1], context.allocator)
	if rerr != nil do os.exit(1)
	a: webp.Animation
	if e := webp.init_animation(&a, data); e != .None {fmt.eprintln("init:", e); os.exit(1)}
	defer webp.destroy_animation(&a)
	identical, worst_psnr, worst := 0, math.inf_f64(1), 0
	for i in 0 ..< a.features.frame_count {
		frame, err := webp.next_frame(&a)
		if err != .None {fmt.eprintln("frame", i, err); os.exit(1)}
		ref_file, e := os.read_entire_file(fmt.tprintf("%s/dump_%04d.pam", os.args[2], i), context.allocator)
		if e != nil {fmt.eprintln("no reference for frame", i); os.exit(1)}
		ref := ref_file[strings.index(string(ref_file), "ENDHDR\n") + 7:]
		if len(ref) != len(frame.pixels) {fmt.eprintln("frame", i, "size", len(ref), len(frame.pixels)); os.exit(1)}
		max_diff := 0
		sse: f64
		for k in 0 ..< len(ref) {
			ours := frame.pixels[k | 3] == 0 ? 0 : frame.pixels[k]
			d := int(ref[k]) - int(ours)
			max_diff = max(max_diff, abs(d))
			sse += f64(d * d)
		}
		if max_diff == 0 {
			identical += 1
		} else {
			worst = max(worst, max_diff)
			worst_psnr = min(worst_psnr, 10 * math.log10(255 * 255 * f64(len(ref)) / sse))
		}
	}
	n := a.features.frame_count
	if identical == n {
		fmt.printfln("%dx%d, %d frames: all identical to anim_dump", a.features.width, a.features.height, n)
	} else {
		fmt.printfln("%dx%d, %d frames: %d identical; worst max %d, PSNR %.2f dB", a.features.width, a.features.height, n, identical, worst, worst_psnr)
	}
}

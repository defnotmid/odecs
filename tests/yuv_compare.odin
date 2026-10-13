package main

import "core:fmt"
import "core:math"
import "core:os"

// yuv_compare <reference.yuv> <candidate.yuv> [name]: EXACT or PSNR over the common prefix
main :: proc() {
	if len(os.args) < 3 {
		fmt.println("usage: yuv_compare <reference.yuv> <candidate.yuv> [name]")
		os.exit(2)
	}
	name := len(os.args) > 3 ? os.args[3] : os.args[2]
	ref, ref_err := os.read_entire_file(os.args[1], context.allocator)
	ours, ours_err := os.read_entire_file(os.args[2], context.allocator)
	if ref_err != nil || ours_err != nil || len(ref) == 0 || len(ours) == 0 {
		fmt.printfln("%-44s NOOUT  ref=%d ours=%d", name, len(ref), len(ours))
		os.exit(1)
	}
	n := min(len(ref), len(ours))
	differing := 0
	sse: f64
	for i in 0 ..< n {
		d := int(ref[i]) - int(ours[i])
		if d != 0 {
			differing += 1
			sse += f64(d * d)
		}
	}
	if differing == 0 && len(ref) == len(ours) {
		fmt.printfln("%-44s EXACT  %d bytes", name, len(ref))
		return
	}
	mse := sse / f64(n)
	fmt.printfln(
		"%-44s DIFF   ref=%d ours=%d differing=%d PSNR=%.1f",
		name,
		len(ref),
		len(ours),
		differing,
		mse == 0 ? 99 : 10 * math.log10(255 * 255 / mse),
	)
	os.exit(1)
}

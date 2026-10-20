// Fuzzes webp under AddressSanitizer: mutated and truncated copies of
// WebP files (lossy, lossless, alpha, animated) through get_features,
// decode, decode_yuva and the animation decoder.
//
//   odin build tests/webp_fuzz.odin -file -sanitize:address -debug -out:fuzz
//   fuzz ROUNDS FILE.webp...
package main

import webp "../image/webp"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strconv"

mutate :: proc(data: []u8) {
	if len(data) == 0 do return
	switch rand.int_max(4) {
	case 0:
		for _ in 0 ..< 1 + rand.int_max(4) do data[rand.int_max(len(data))] ~= u8(1 << uint(rand.int_max(8)))
	case 1:
		data[rand.int_max(len(data))] = u8(rand.int_max(256))
	case 2:
		at := rand.int_max(len(data))
		for i in at ..< min(len(data), at + 8) do data[i] = u8(rand.int_max(256))
	case 3:
		// Past the headers, where the entropy-coded data is.
		at := min(len(data) - 1, 20 + rand.int_max(max(len(data) - 20, 1)))
		data[at] ~= u8(1 << uint(rand.int_max(8)))
	}
}

main :: proc() {
	if len(os.args) < 3 {fmt.eprintln("usage: fuzz ROUNDS FILE.webp..."); os.exit(2)}
	rounds, _ := strconv.parse_int(os.args[1])
	files: [dynamic][]u8
	for path in os.args[2:] {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {fmt.eprintln("cannot read", path); os.exit(1)}
		append(&files, data)
	}
	decoded, refused := 0, 0
	for _ in 0 ..< rounds {
		src := files[rand.int_max(len(files))]
		f := make([]u8, len(src))
		copy(f, src)
		for _ in 0 ..< 1 + rand.int_max(3) do mutate(f)
		if rand.int_max(6) == 0 do f = f[:rand.int_max(len(f) + 1)]
		webp.get_features(f)
		if img, err := webp.decode(f); err == .None {
			decoded += 1
			webp.destroy_image(&img)
		} else {
			refused += 1
		}
		if yuv, alpha, err := webp.decode_yuva(f); err == .None {
			webp.destroy_yuv(&yuv)
			delete(alpha)
		}
		a: webp.Animation
		if webp.init_animation(&a, f) == .None {
			for _ in 0 ..< min(a.features.frame_count, 4) do if _, e := webp.next_frame(&a); e != .None do break
			webp.destroy_animation(&a)
		}
		delete(f)
	}
	for f in files do delete(f)
	delete(files)
	fmt.printfln("%d rounds: %d decoded, %d refused; no faults", rounds, decoded, refused)
}

// Mutation fuzzing of the image inputs: image.info and image.decode for every
// format (decode_float_into for HDR), and a GIF animation played through.
// Every input must be decoded or refused with an error, and everything
// allocated released; a crash, bounds failure or sanitizer report fails the
// run.
//
//   odin build tests/image_fuzz.odin -file -o:speed -sanitize:address -out:/tmp/odecs-image-fuzz
//   /tmp/odecs-image-fuzz ITERATIONS FIXTURE...
package image_fuzz

import gif "../image/gif"
import image "../image"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"

// Flips bits, overwrites bytes with boundary values, truncates, or repeats
// a span; usually a few edits so most of the structure survives.
mutate :: proc(src: []u8, out: ^[dynamic]u8) {
	clear(out)
	append(out, ..src)
	for _ in 0 ..< 1 + rand.int_max(4) {
		n := len(out)
		if n == 0 do return
		at := rand.int_max(n)
		switch rand.int_max(6) {
		case 0:
			out[at] ~= u8(1) << uint(rand.int_max(8))
		case 1:
			values := [?]u8{0, 1, 0x7F, 0x80, 0xFE, 0xFF}
			out[at] = values[rand.int_max(len(values))]
		case 2:
			resize(out, at) // truncate
		case 3:
			span: [64]u8 // copied first: injecting reallocates the array
			count := copy(span[:min(rand.int_max(64) + 1, n - at)], out[at:])
			inject_at_elems(out, rand.int_max(n), ..span[:count])
		case 4:
			out[at] = u8(rand.int_max(256))
		case 5:
			// A size field's worth of bytes.
			for k in 0 ..< min(4, n - at) do out[at + k] = u8(rand.int_max(256))
		}
	}
}

main :: proc() {
	if len(os.args) < 3 {fmt.eprintln("usage: image_fuzz ITERATIONS FIXTURE..."); os.exit(2)}
	iterations, _ := strconv.parse_int(os.args[1])
	rand.reset(0x5EED)
	buffer: [dynamic]u8
	leaked := 0
	for path in os.args[2:] {
		file, err := os.read_entire_file(path, context.allocator)
		if err != nil {fmt.eprintln("cannot read", path); os.exit(2)}
		decoded := 0
		parent := context.allocator
		for _ in 0 ..< iterations {
			mutate(file, &buffer)
			data := buffer[:]
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, parent)
			context.allocator = mem.tracking_allocator(&track)
			_, _ = image.info(data)
			if img, e := image.decode(data); e == .None {
				decoded += 1
				image.destroy_image(&img)
			}
			// The harness bounds the size it allocates for.
			if i, e := image.info(data); e == .None && i.format == .HDR && i.width * i.height <= 1 << 24 {
				pixels := make([]f32, i.width * i.height * 4)
				if image.decode_float_into(data, pixels) == .None do decoded += 1
				delete(pixels)
			}
			if image.format_of(data) == .GIF {
				a: gif.Animation
				if gif.init_animation(&a, data) == .None {
					for _ in 0 ..< min(a.frame_count, 64) do if _, e := gif.next_frame(&a); e != .None do break
					gif.destroy_animation(&a)
				}
			}
			free_all(context.temp_allocator)
			context.allocator = parent
			if len(track.allocation_map) > 0 && leaked == 0 do for _, entry in track.allocation_map do fmt.println("leak", filepath.base(path), entry.location)
			leaked += len(track.allocation_map)
			mem.tracking_allocator_destroy(&track)
		}
		fmt.printfln("%-26s %d mutations, %d decoded", filepath.base(path), iterations, decoded)
		delete(file)
	}
	delete(buffer)
	fmt.printfln("leaked allocations: %d", leaked)
	os.exit(leaked == 0 ? 0 : 1)
}

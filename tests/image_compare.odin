// Decodes image files with odecs/image and with stb_image (the development
// oracle, through Odin's vendor:stb/image) and compares the RGBA8 results:
// identical for the lossless formats, PSNR for JPEG (IDCT rounding may
// differ). Also reports the best of five decode times and odecs' peak
// allocation.
//   odin run tests/image_compare.odin -file -o:speed -- file...
package image_compare

import image "../image"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:time"
import stbi "vendor:stb/image"

main :: proc() {
	failed := 0
	worst_psnr, worst_file := math.inf_f64(1), ""
	for path in os.args[1:] {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {fmt.println("cannot read", path); failed += 1; continue}
		name := filepath.base(path)
		w, h, ch: i32
		ref := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &ch, 4)
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		img, ierr := image.decode(data, nil, mem.tracking_allocator(&track))
		peak := track.peak_memory_allocated
		switch {
		case ref == nil && ierr != .None:
			fmt.printfln("%-26s both refuse (%v)", name, ierr)
			continue
		case ref == nil:
			fmt.printfln("%-26s stb refuses, odecs decodes %dx%d", name, img.width, img.height)
			image.destroy_image(&img, mem.tracking_allocator(&track))
			continue
		case ierr != .None:
			fmt.printfln("%-26s FAIL odecs %v, stb decodes %dx%d", name, ierr, w, h)
			stbi.image_free(ref)
			failed += 1
			continue
		}
		expected := ref[:w * h * 4]
		verdict: string
		if img.width != int(w) || img.height != int(h) {
			verdict = fmt.tprintf("FAIL size %dx%d, stb %dx%d", img.width, img.height, w, h)
			failed += 1
		} else if image.format_of(data) == .JPEG {
			se: f64
			for v, i in img.pixels do se += math.pow(f64(v) - f64(expected[i]), 2)
			mse := se / f64(len(img.pixels))
			psnr := mse == 0 ? math.inf_f64(1) : 10 * math.log10(255 * 255 / mse)
			ok := psnr >= 45
			if !ok do failed += 1
			if psnr < worst_psnr do worst_psnr, worst_file = psnr, name
			verdict = fmt.tprintf("%s PSNR %.2f dB", ok ? "ok  " : "FAIL", psnr)
		} else {
			// stb fills a GIF's background with red and blue swapped; odecs
			// writes the table's colour (gif.decode).
			gif_file := image.format_of(data) == .GIF
			swapped := 0
			first := -1
			for i := 0; i < len(img.pixels); i += 4 {
				a, b := img.pixels[i:][:4], expected[i:][:4]
				if string(a) == string(b) do continue
				if gif_file && a[3] == 255 && a[0] == b[2] && a[1] == b[1] && a[2] == b[0] {swapped += 1; continue}
				first = i
				break
			}
			if first < 0 {
				verdict = swapped > 0 ? fmt.tprintf("ok   identical but %d background pixels stb swaps", swapped) : "ok   identical"
			} else {
				p := first / 4
				verdict = fmt.tprintf("FAIL pixel (%d, %d): %v, stb %v", p % int(w), p / int(w), img.pixels[p * 4:][:4], expected[p * 4:][:4])
				failed += 1
			}
		}
		// Best of five, each side.
		ours, theirs := max(f64), max(f64)
		for _ in 0 ..< 5 {
			t := time.tick_now()
			again, _ := image.decode(data)
			ours = min(ours, time.duration_milliseconds(time.tick_since(t)))
			image.destroy_image(&again)
			t = time.tick_now()
			other := stbi.load_from_memory(raw_data(data), i32(len(data)), &w, &h, &ch, 4)
			theirs = min(theirs, time.duration_milliseconds(time.tick_since(t)))
			stbi.image_free(other)
		}
		fmt.printfln("%-26s %dx%d %s; %.2f ms (stb %.2f), peak %d KiB", name, w, h, verdict, ours, theirs, peak / 1024)
		image.destroy_image(&img, mem.tracking_allocator(&track))
		stbi.image_free(ref)
	}
	if worst_file != "" do fmt.printfln("worst JPEG: %s at %.2f dB", worst_file, worst_psnr)
	fmt.printfln("%d failed", failed)
	os.exit(failed == 0 ? 0 : 1)
}

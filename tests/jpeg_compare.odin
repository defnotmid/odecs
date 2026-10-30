// Decodes JPEG files with oicut/jpeg and with libjpeg-turbo (the reference
// and the speed to meet: TurboJPEG at its defaults, its integer IDCT and fancy
// upsampling) and compares the RGBA8 results, which must be identical.
// CMYK and YCCK files are compared through libjpeg-turbo's CMYK output and
// oicut's CMYK to RGB rule. Times are the best of several decodes each.
// tests/image_check.sh builds the pinned libjpeg-turbo (tools/fetch_third_party.sh)
// into .work/libjpeg-turbo and runs this; by hand:
//   odin run tests/jpeg_compare.odin -file -o:speed -extra-linker-flags:-L.work/libjpeg-turbo -- file...
package jpeg_compare

import jpeg "../image/jpeg"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

foreign import turbo "system:turbojpeg"

@(default_calling_convention = "c")
foreign turbo {
	tj3Init :: proc(init_type: c.int) -> rawptr ---
	tj3Destroy :: proc(handle: rawptr) ---
	tj3GetErrorStr :: proc(handle: rawptr) -> cstring ---
	tj3Get :: proc(handle: rawptr, param: c.int) -> c.int ---
	tj3DecompressHeader :: proc(handle: rawptr, jpeg: [^]u8, size: c.size_t) -> c.int ---
	tj3Decompress8 :: proc(handle: rawptr, jpeg: [^]u8, size: c.size_t, dst: [^]u8, pitch: c.int, pixel_format: c.int) -> c.int ---
}

TJINIT_DECOMPRESS :: 1
TJPARAM_JPEGWIDTH :: 5
TJPARAM_JPEGHEIGHT :: 6
TJPARAM_COLORSPACE :: 8
TJPF_RGBA :: 7
TJPF_CMYK :: 11
TJCS_CMYK :: 3
TJCS_YCCK :: 4

// libjpeg-turbo's decode as RGBA8; nil if it refuses the file.
turbo_decode :: proc(h: rawptr, data: []u8, out: ^[dynamic]u8) -> (width, height: int, ok: bool) {
	if tj3DecompressHeader(h, raw_data(data), c.size_t(len(data))) != 0 do return
	width, height = int(tj3Get(h, TJPARAM_JPEGWIDTH)), int(tj3Get(h, TJPARAM_JPEGHEIGHT))
	cmyk := tj3Get(h, TJPARAM_COLORSPACE) == TJCS_CMYK || tj3Get(h, TJPARAM_COLORSPACE) == TJCS_YCCK
	resize(out, width * height * 4)
	if tj3Decompress8(h, raw_data(data), c.size_t(len(data)), raw_data(out^), 0, cmyk ? TJPF_CMYK : TJPF_RGBA) != 0 do return
	if cmyk {
		blinn :: proc(x, y: u8) -> u8 {t := u32(x) * u32(y) + 128; return u8((t + t >> 8) >> 8)}
		for i := 0; i < len(out); i += 4 {
			k := out[i + 3]
			out[i], out[i + 1], out[i + 2], out[i + 3] = blinn(out[i], k), blinn(out[i + 1], k), blinn(out[i + 2], k), 255
		}
	}
	return width, height, true
}

main :: proc() {
	h := tj3Init(TJINIT_DECOMPRESS)
	failed := 0
	total_ours, total_turbo: f64
	reference: [dynamic]u8
	for path in os.args[1:] {
		name := filepath.base(path)
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {fmt.println("cannot read", path); failed += 1; continue}
		w, ht, ok := turbo_decode(h, data, &reference)
		img, ierr := jpeg.decode(data)
		switch {
		case !ok && ierr != .None:
			fmt.printfln("%-30s both refuse (%v)", name, ierr)
			continue
		case !ok:
			fmt.printfln("%-30s libjpeg-turbo refuses (%s), oicut decodes %dx%d", name, tj3GetErrorStr(h), img.width, img.height)
			jpeg.destroy_image(&img)
			continue
		case ierr == .Unsupported:
			fmt.printfln("%-30s unsupported by oicut (libjpeg-turbo decodes %dx%d)", name, w, ht)
			continue
		case ierr != .None:
			fmt.printfln("%-30s FAIL oicut %v, libjpeg-turbo decodes %dx%d", name, ierr, w, ht)
			failed += 1
			continue
		}
		verdict := "identical"
		if img.width != w || img.height != ht {
			verdict = fmt.tprintf("FAIL size %dx%d, libjpeg-turbo %dx%d", img.width, img.height, w, ht)
		} else {
			differ, worst := 0, 0
			first := -1
			for v, i in img.pixels {
				d := abs(int(v) - int(reference[i]))
				if d == 0 do continue
				if first < 0 do first = i
				differ += 1
				worst = max(worst, d)
			}
			if first >= 0 {
				p := first / 4
				verdict = fmt.tprintf("FAIL %d samples differ (at most %d), first (%d, %d): %v vs %v", differ, worst, p % w, p / w, img.pixels[p * 4:][:4], reference[p * 4:][:4])
			}
		}
		if verdict != "identical" do failed += 1
		jpeg.destroy_image(&img)
		// Best of seven, each side.
		ours, theirs := max(f64), max(f64)
		for _ in 0 ..< 7 {
			t := time.tick_now()
			again, _ := jpeg.decode(data)
			ours = min(ours, time.duration_milliseconds(time.tick_since(t)))
			jpeg.destroy_image(&again)
			t = time.tick_now()
			turbo_decode(h, data, &reference)
			theirs = min(theirs, time.duration_milliseconds(time.tick_since(t)))
		}
		total_ours += ours
		total_turbo += theirs
		fmt.printfln("%-30s %4dx%-4d %s; %.2f ms (turbo %.2f, %.2fx)", name, w, ht, verdict, ours, theirs, ours / theirs)
		delete(data)
	}
	if total_turbo > 0 do fmt.printfln("total %.2f ms (turbo %.2f, %.2fx)", total_ours, total_turbo, total_ours / total_turbo)
	fmt.printfln("%d failed", failed)
	tj3Destroy(h)
	os.exit(failed == 0 ? 0 : 1)
}

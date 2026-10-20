// Every frame of each GIF animation, through gif.Animation, against frames a
// browser composited (tests/image_check.sh writes them from Chromium's
// ImageDecoder as REF_DIR/NAME.K.rgba). Pixels both sides leave transparent
// are equal whatever their colour.
//   odin run tests/gif_animation_compare.odin -file -- REF_DIR file.gif...
package gif_animation_compare

import gif "../gif"
import "core:fmt"
import "core:os"
import "core:path/filepath"

main :: proc() {
	if len(os.args) < 3 {fmt.eprintln("usage: gif_animation_compare REF_DIR file.gif..."); os.exit(2)}
	failed := 0
	for path in os.args[2:] {
		name := filepath.stem(path)
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {fmt.println("cannot read", path); failed += 1; continue}
		a: gif.Animation
		if e := gif.init_animation(&a, data); e != .None {
			fmt.printfln("%-26s FAIL %v", name, e)
			failed += 1
			continue
		}
		verdict := "ok"
		for k in 0 ..< a.frame_count {
			frame, e := gif.next_frame(&a)
			ref, rerr := os.read_entire_file(fmt.tprintf("%s/%s.%d.rgba", os.args[1], name, k), context.allocator)
			switch {
			case e != .None:
				verdict = fmt.tprintf("FAIL frame %d: %v", k, e)
			case rerr != nil || len(ref) != len(frame.pixels):
				verdict = fmt.tprintf("FAIL frame %d: no reference of %d bytes", k, len(frame.pixels))
			case:
				for p := 0; p < len(ref); p += 4 {
					ours, theirs := frame.pixels[p:][:4], ref[p:][:4]
					if ours[3] == 0 && theirs[3] == 0 || string(ours) == string(theirs) do continue
					verdict = fmt.tprintf("FAIL frame %d pixel %d: %v, browser %v", k, p / 4, ours, theirs)
					break
				}
			}
			delete(ref)
			if verdict != "ok" do break
		}
		// The browser gives no more frames than the file has.
		if verdict == "ok" && os.exists(fmt.tprintf("%s/%s.%d.rgba", os.args[1], name, a.frame_count)) do verdict = "FAIL the browser has more frames"
		if verdict != "ok" do failed += 1
		fmt.printfln("%-26s %d frames %s", name, a.frame_count, verdict)
		gif.destroy_animation(&a)
		delete(data)
	}
	fmt.printfln("%d failed", failed)
	os.exit(failed == 0 ? 0 : 1)
}

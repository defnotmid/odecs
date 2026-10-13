// Checks that movie.Reader presents a file identically through the hardware
// decoder it selects (VideoToolbox on macOS, Vulkan Video elsewhere) and the
// native one: every frame's RGBA in order, then frames reached by seeking
// (which restarts the decoder at a keyframe). Prints the backend and both
// decoding rates.
//
//   odin build tests/movie_backends.odin -file -o:speed -out:.work/movie-backends
//   .work/movie-backends FILE
package movie_backends

import movie "../codec/movie"
import "core:fmt"
import "core:os"
import "core:time"

fail :: proc(args: ..any) {
	fmt.eprintln(..args)
	os.exit(1)
}

main :: proc() {
	if len(os.args) < 2 do fail("usage: movie_backends FILE")
	path := os.args[1]
	hardware, native: movie.Reader
	if e := movie.open_reader(&hardware, path, {preference = .Require_Hardware}); e != .None do fail("open with hardware:", e, hardware.error_detail)
	defer movie.close_reader(&hardware)
	if e := movie.open_reader(&native, path, {preference = .Native}); e != .None do fail("open natively:", e, native.error_detail)
	defer movie.close_reader(&native)
	v := hardware.video
	fmt.printfln("%s: %v %dx%d, %d frames, depth %d", path, v.codec, v.width, v.height, v.frame_count, v.bit_depth)

	frames := 0
	spent: [2]time.Duration
	for {
		start := time.tick_now()
		a, ea := movie.next_frame(&hardware)
		spent[0] += time.tick_since(start)
		start = time.tick_now()
		b, eb := movie.next_frame(&native)
		spent[1] += time.tick_since(start)
		if ea != eb do fail("frame", frames, ea, hardware.error_detail, "vs", eb, native.error_detail)
		if ea == .End_Of_Stream do break
		if ea != .None do fail("frame", frames, ea, hardware.error_detail)
		if a.index != b.index || string(a.rgba) != string(b.rgba) do fail("frame", frames, "differs")
		frames += 1
	}
	if frames != v.frame_count do fail("decoded", frames, "frames, expected", v.frame_count)
	fmt.printfln("  %s: %d frames identical to native; %.0f fps vs %.0f fps native (RGBA output)", hardware.session.provider_name, frames, f64(frames) / time.duration_seconds(spent[0]), f64(frames) / time.duration_seconds(spent[1]))

	// Seeks, backwards included, land on the same frames.
	for t in ([]f64{v.duration * 0.7, v.duration * 0.2, v.duration * 0.9, 0}) {
		a, ea := movie.frame_at(&hardware, t)
		b, eb := movie.frame_at(&native, t)
		if ea != .None || eb != .None do fail("seek", t, ea, hardware.error_detail, eb, native.error_detail)
		if a.index != b.index || string(a.rgba) != string(b.rgba) do fail("seek to", t, "differs: frames", a.index, b.index)
	}
	fmt.println("  seeks identical")
}

// video.Reader decode time per frame with planar output and the hardware
// decoder required: the file opened once per round (not timed), next_frame
// timed to the end of the stream, best of ROUNDS. -define:OICUT_DECODE_DEPTH=1
// keeps one picture in flight instead of three. tests/compare.sh runs it
// (the gpu/ cases) on its inputs.
//
//   odin build tests/movie_decode_timing.odin -file -o:speed -out:/tmp/oicut-movie-decode
//   /tmp/oicut-movie-decode FILE
package movie_decode_timing

import video "../video"
import "core:fmt"
import "core:os"
import "core:time"

ROUNDS :: 5

main :: proc() {
	if len(os.args) != 2 {fmt.eprintln("usage: movie_decode_timing FILE"); os.exit(2)}
	best := max(f64)
	frames := 0
	backend: string
	for _ in 0 ..< ROUNDS {
		r: video.Reader
		if e := video.open_reader(&r, os.args[1], {format = .Planar, preference = .Require_Hardware}); e != .None {
			fmt.eprintln("open", e, r.error_detail)
			os.exit(1)
		}
		frames = 0
		start := time.tick_now()
		for {
			_, e := video.next_frame(&r)
			if e == .End_Of_Stream do break
			if e != .None {fmt.eprintln("frame", frames, e, r.error_detail); os.exit(1)}
			frames += 1
		}
		ms := time.duration_milliseconds(time.tick_since(start))
		backend = fmt.tprint(r.session.backend)
		video.close_reader(&r)
		best = min(best, ms / f64(max(frames, 1)))
	}
	fmt.printfln("%s %s: %d frames, %.2f ms/frame (best of %d)", backend, os.args[1], frames, best, ROUNDS)
}

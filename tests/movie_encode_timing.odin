// video.Writer encode throughput from ready I420 planes, the onimite path:
// frames arrive faster than the encoder takes them, so wall time per frame
// is the encoder's cost as seen by the caller. Median of ROUNDS runs; the
// MP4 hash checks that every run (and every encoder change) writes the
// same bytes.
//
//   odin build tests/movie_encode_timing.odin -file -o:speed -out:/tmp/odecs-movie-encode
//   /tmp/odecs-movie-encode [h264|h265] [W H FRAMES] [out.mp4]
package movie_encode_timing

import mp4 "../container/mp4"
import video "../video"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

ROUNDS :: 5
SOURCES :: 30 // distinct pictures, cycled

main :: proc() {
	codec := video.Video_Codec.H264
	W, H, FRAMES := 1920, 1080, 900
	out := ""
	if len(os.args) >= 2 && os.args[1] == "h265" do codec = .H265
	if len(os.args) >= 5 {
		W, _ = strconv.parse_int(os.args[2])
		H, _ = strconv.parse_int(os.args[3])
		FRAMES, _ = strconv.parse_int(os.args[4])
	}
	if len(os.args) >= 6 do out = os.args[5]

	// A gradient drifting right and a square moving down, so P pictures
	// carry real motion.
	luma, chroma := W * H, W * H / 4
	pictures := make([]u8, SOURCES * (luma + 2 * chroma))
	for s in 0 ..< SOURCES {
		p := pictures[s * (luma + 2 * chroma):]
		for y in 0 ..< H do for x in 0 ..< W {
			inside := abs(x - W / 2) < H / 6 && abs(y - s * H / SOURCES) < H / 6
			p[y * W + x] = inside ? 235 : u8(16 + (x + y + s * 8) % 200)
		}
		for y in 0 ..< H / 2 do for x in 0 ..< W / 2 {
			p[luma + y * W / 2 + x] = u8(128 + (x - y + s) % 64 - 32)
			p[luma + chroma + y * W / 2 + x] = u8(96 + (x * 2 + s * 3) % 64)
		}
	}

	times: [ROUNDS]f64
	hashes: [ROUNDS]u64
	size := 0
	backend: string
	for r in 0 ..< ROUNDS {
		m: mp4.Memory_Stream
		config := video.default_writer_config(W, H, 30, 1)
		config.codec = codec
		config.preference = .Require_Hardware
		w: video.Writer
		if e := video.create_stream(&w, mp4.memory_stream(&m), config); e != .None {fmt.eprintln("create", e, w.error_detail); os.exit(1)}
		_, backend = video.video_backend(&w)
		strides := [3]int{W, W / 2, W / 2}
		start := time.tick_now()
		for f in 0 ..< FRAMES {
			p := pictures[f % SOURCES * (luma + 2 * chroma):]
			planes := [3][]u8{p[:luma], p[luma:][:chroma], p[luma + chroma:][:chroma]}
			if e := video.write_i420(&w, planes, strides); e != .None {fmt.eprintln("write", e, w.error_detail); os.exit(1)}
		}
		if e := video.finish(&w); e != .None {fmt.eprintln("finish", e, w.error_detail); os.exit(1)}
		times[r] = time.duration_milliseconds(time.tick_since(start))
		video.destroy(&w)
		hashes[r] = 14695981039346656037
		for b in m.data do hashes[r] = (hashes[r] ~ u64(b)) * 1099511628211
		size = len(m.data)
		if r == 0 && out != "" do _ = os.write_entire_file(out, m.data[:])
		delete(m.data)
	}
	for h in hashes[1:] do if h != hashes[0] {fmt.eprintln("runs wrote different bytes:", hashes); os.exit(1)}
	sorted := times
	slice.sort(sorted[:])
	ms := sorted[ROUNDS / 2]
	fmt.printfln(
		"%v %v %dx%d, %d frames: %.1f ms total, %.3f ms/frame, %.0f fps (median of %d; min %.1f max %.1f ms); %d bytes, hash %016x",
		backend, codec, W, H, FRAMES, ms, ms / f64(FRAMES), f64(FRAMES) * 1000 / ms, ROUNDS, sorted[0], sorted[ROUNDS - 1], size, hashes[0],
	)
}

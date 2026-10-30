// movie timing: colour conversion kernels and the playback path's cost
// over raw decoding, with resident input, median of 7.
//
//   odin build tests/movie_timing.odin -file -o:speed -microarch:native -out:/tmp/oicut-movie-timing
//   taskset -c 23 /tmp/oicut-movie-timing [W H FRAMES]
package movie_timing

import mp4 "../container/mp4"
import media "../media"
import native "../media/native"
import video "../video"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

ROUNDS :: 7

median :: proc(samples: []f64) -> f64 {
	slice.sort(samples)
	return samples[len(samples) / 2]
}

main :: proc() {
	W, H, FRAMES := 1920, 1080, 60
	if len(os.args) >= 4 {
		W, _ = strconv.parse_int(os.args[1])
		H, _ = strconv.parse_int(os.args[2])
		FRAMES, _ = strconv.parse_int(os.args[3])
	}
	rgba := make([]u8, W * H * 4)
	for y in 0 ..< H do for x in 0 ..< W {
		p := (y * W + x) * 4
		rgba[p], rgba[p + 1], rgba[p + 2], rgba[p + 3] = u8(x * 7), u8(y * 3), u8(x + y), u8(200 + (x & 31))
	}
	planes := make([]u8, W * H * 3 / 2)
	p := [3][]u8{planes[:W * H], planes[W * H:][:W * H / 4], planes[W * H * 5 / 4:]}
	strides := [3]int{W, W / 2, W / 2}
	forward := video.rgb_to_yuv_coefficients(.BT709, false)
	inverse := video.yuv_to_rgb_coefficients(.BT709, false, 8)
	out := make([]u8, W * H * 4)
	times: [ROUNDS]f64

	REPS :: 20
	for alpha in video.Alpha {
		for r in 0 ..< ROUNDS {
			start := time.tick_now()
			for _ in 0 ..< REPS do video.rgba_to_i420(rgba, W * 4, W, H, p, strides, &forward, alpha, {})
			times[r] = time.duration_milliseconds(time.tick_since(start)) / REPS
		}
		hash: u64 = 14695981039346656037
		for b in planes do hash = (hash ~ u64(b)) * 1099511628211
		fmt.printfln("rgba_to_i420 %v %dx%d: %.3f ms/frame (median of %d), output hash %016x", alpha, W, H, median(times[:]), ROUNDS, hash)
	}
	for r in 0 ..< ROUNDS {
		start := time.tick_now()
		for _ in 0 ..< REPS do video.yuv_to_rgba(p, strides, W, H, 8, 1, 1, &inverse, out, W * 4)
		times[r] = time.duration_milliseconds(time.tick_since(start)) / REPS
	}
	fmt.printfln("yuv_to_rgba 8-bit 4:2:0 %dx%d: %.3f ms/frame (median of %d)", W, H, median(times[:]), ROUNDS)

	if FRAMES == 0 do return // kernels only, for counters

	// A native H.264 clip in memory, then playback through video.Reader
	// against the same samples decoded without the movie layer.
	m: mp4.Memory_Stream
	config := video.default_writer_config(W, H, 30, 1)
	config.preference = .Native
	w: video.Writer
	if e := video.create_stream(&w, mp4.memory_stream(&m), config); e != .None {fmt.eprintln("create", e); os.exit(1)}
	encode_start := time.tick_now()
	for f in 0 ..< FRAMES {
		for i in 0 ..< W * H do rgba[i * 4] = u8(i + f * 5)
		if e := video.write_frame(&w, rgba, W * 4); e != .None {fmt.eprintln("write", e); os.exit(1)}
	}
	if e := video.finish(&w); e != .None {fmt.eprintln("finish", e); os.exit(1)}
	encode := time.tick_since(encode_start)
	video.destroy(&w)
	fmt.printfln("native H.264 encode incl. conversion: %.1f fps (single run, %d bytes)", f64(FRAMES) / time.duration_seconds(encode), len(m.data))

	for r in 0 ..< ROUNDS {
		reader: video.Reader
		if e := video.open_reader_stream(&reader, mp4.memory_stream(&m), {preference = .Native}); e != .None {fmt.eprintln("open", e); os.exit(1)}
		start := time.tick_now()
		for _ in 0 ..< FRAMES do if _, e := video.next_frame(&reader); e != .None {fmt.eprintln("next", e); os.exit(1)}
		times[r] = time.duration_milliseconds(time.tick_since(start)) / f64(FRAMES)
		video.close_reader(&reader)
	}
	playback := median(times[:])

	// Same samples through media.decode directly (no conversion or timing).
	demux: mp4.Reader
	mp4.open_stream(&demux, mp4.memory_stream(&m))
	t := &demux.tracks[0]
	frames_out := 0
	count :: proc(f: media.Video_Frame, user: rawptr) {(^int)(user)^ += 1}
	for r in 0 ..< ROUNDS {
		session: media.Session
		dc := media.default_config(.H264, .Decode)
		dc.preference, dc.no_reordering = .Native, true
		providers := [1]media.Provider{native.provider()}
		media.open(&session, dc, providers[:])
		receiver := media.Receiver{video = count, user = &frames_out}
		c := t.config
		sps_len := int(c[6]) << 8 | int(c[7])
		media.decode(&session, {data = c[8:][:sps_len], framing = .NAL}, receiver)
		pps_at := 8 + sps_len + 1
		media.decode(&session, {data = c[pps_at + 2:][:int(c[pps_at]) << 8 | int(c[pps_at + 1])], framing = .NAL}, receiver)
		start := time.tick_now()
		for i in 0 ..< len(t.samples) {
			s, _ := mp4.read_sample(&demux, 0, i)
			for pos := 0; pos < len(s.data); {
				n := int(s.data[pos]) << 24 | int(s.data[pos + 1]) << 16 | int(s.data[pos + 2]) << 8 | int(s.data[pos + 3])
				media.decode(&session, {data = s.data[pos + 4:][:n], framing = .NAL}, receiver)
				pos += 4 + n
			}
		}
		media.drain(&session, receiver)
		times[r] = time.duration_milliseconds(time.tick_since(start)) / f64(FRAMES)
		media.close(&session)
	}
	raw := median(times[:])
	fmt.printfln("playback next_frame: %.3f ms/frame; raw decode of the same samples: %.3f ms/frame; movie layer: %.3f ms/frame (%.1f%%)", playback, raw, playback - raw, 100 * (playback - raw) / playback)
	mp4.close(&demux)
}

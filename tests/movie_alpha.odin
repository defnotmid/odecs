// End-to-end check of movie.Reader on alpha video (ProRes .mov, VP9 .webm)
// and QuickTime PCM: sequential decode, the RGBA alpha channel against
// FFmpeg's decoded alpha plane, random frame_at seeks against the sequential
// frames, seek latency, and PCM against FFmpeg's f32 decode.
//
//   odin build tests/movie_alpha.odin -file -o:speed -out:/tmp/odecs-movie-alpha
//   /tmp/odecs-movie-alpha FILE [ORACLE.yuv|-] [THREADS] [PCM.f32]
//
// The oracle is FFmpeg's planar decode (tests/alpha_fixtures.sh writes
// NAME.yuv and NAME.fmt); without one only consistency is checked.
package movie_alpha

import common "../codec/common"
import native "../codec/media/native"
import movie "../codec/movie"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

fail :: proc(args: ..any) {
	fmt.eprintln(..args)
	os.exit(1)
}

hash :: proc(b: []u8) -> u64 {
	h: u64 = 14695981039346656037
	for v in b do h = (h ~ u64(v)) * 1099511628211
	return h
}

main :: proc() {
	if len(os.args) < 2 do fail("usage: movie_alpha FILE [ORACLE.yuv|-] [THREADS] [PCM.f32]")
	path := os.args[1]
	threads := 1
	if len(os.args) > 3 do threads, _ = strconv.parse_int(os.args[3])
	pool: common.Static_Pool
	options: native.Options
	if threads > 1 {
		common.init_static_pool(&pool, threads - 1)
		options.pool = &pool.work_pool
	}
	config := movie.Reader_Config {
		preference     = .Native,
		native_options = &options,
	}
	r: movie.Reader
	if e := movie.open_reader(&r, path, config); e != .None do fail("open", e, r.error_detail)
	defer movie.close_reader(&r)
	v := r.video
	fmt.printfln("%s: %v %dx%d %d frames %d/%d fps, %.3f s, alpha %v, colour %v", path, v.codec, v.width, v.height, v.frame_count, v.fps_num, v.fps_den, v.duration, v.has_alpha, v.color)
	fmt.printfln("  audio: %v present %v %d Hz %d ch %d samples", r.audio.codec, r.audio.present, r.audio.sample_rate, r.audio.channels, r.audio.samples)

	if r.video_index >= 0 do check_video(&r, threads)
	check_audio(&r)
}

check_video :: proc(r: ^movie.Reader, threads: int) {
	v := r.video
	// Throughput: decode and convert every frame, nothing else timed.
	start := time.tick_now()
	timed := 0
	for {
		_, e := movie.next_frame(r)
		if e == .End_Of_Stream do break
		if e != .None do fail("next_frame", timed, e, r.error_detail)
		timed += 1
	}
	elapsed := time.duration_seconds(time.tick_since(start))
	fmt.printfln("  sequential: %d frames, %.1f fps through RGBA (threads %d)", timed, f64(timed) / elapsed, threads)
	movie.frame_at(r, 0) // back to the start

	// Sequential decode for checking.
	hashes := make([dynamic]u64)
	alphas := make([dynamic][]u8) // alpha channel of each frame
	append(&hashes, 0)
	{
		f, _ := movie.frame_at(r, 0)
		hashes[0] = hash(f.rgba)
		a := make([]u8, f.width * f.height)
		for i in 0 ..< len(a) do a[i] = f.rgba[i * 4 + 3]
		append(&alphas, a)
	}
	for {
		f, e := movie.next_frame(r)
		if e == .End_Of_Stream do break
		if e != .None do fail("next_frame", len(hashes), e, r.error_detail)
		if f.index != len(hashes) do fail("frame index", f.index, "expected", len(hashes))
		append(&hashes, hash(f.rgba))
		a := make([]u8, f.width * f.height)
		for i in 0 ..< len(a) do a[i] = f.rgba[i * 4 + 3]
		append(&alphas, a)
	}
	if len(hashes) != v.frame_count do fail("decoded", len(hashes), "frames, expected", v.frame_count)

	// Alpha against FFmpeg's alpha plane, scaled to 8 bits as the reader does.
	if len(os.args) > 2 && os.args[2] != "-" && v.has_alpha {
		oracle, err := os.read_entire_file(os.args[2], context.allocator)
		if err != nil do fail("cannot read", os.args[2])
		format_path := strings.concatenate({os.args[2][:len(os.args[2]) - 4], ".fmt"})
		format_bytes, _ := os.read_entire_file(format_path, context.allocator)
		format := strings.trim_space(string(format_bytes))
		depth, bytes := 8, 1
		chroma_div := 4 // yuva420p: chroma planes a quarter of luma
		if strings.contains(format, "444") do chroma_div = 1
		if strings.contains(format, "12le") do depth, bytes = 12, 2
		if strings.contains(format, "10le") do depth, bytes = 10, 2
		mul := u32(255 * 65536 / f64(int(1) << uint(depth) - 1) + 0.5)
		luma := v.width * v.height
		frame_bytes := (luma + 2 * luma / chroma_div + luma) * bytes
		worst, differing := 0, 0
		for a, i in alphas {
			base := i * frame_bytes + (luma + 2 * luma / chroma_div) * bytes
			for k in 0 ..< luma {
				s := u32(oracle[base + k * bytes])
				if bytes == 2 do s |= u32(oracle[base + k * bytes + 1]) << 8
				want := int((s * mul + 1 << 15) >> 16)
				d := abs(int(a[k]) - want)
				worst = max(worst, d)
				if d != 0 do differing += 1
			}
		}
		fmt.printfln("  alpha vs FFmpeg: max difference %d, %d differing samples of %d", worst, differing, luma * len(alphas))
	}

	// Random seeks must return the sequential frame for the requested time.
	if v.frame_count > 0 {
		latencies := make([dynamic]f64)
		mismatches := 0
		for k in 0 ..< 40 {
			index := int(rand.int31_max(i32(v.frame_count)))
			if k == 0 do index = v.frame_count - 1
			t := (f64(index) + 0.5) * f64(v.fps_den) / f64(v.fps_num)
			seek_start := time.tick_now()
			f, e := movie.frame_at(r, t)
			append(&latencies, time.duration_milliseconds(time.tick_since(seek_start)))
			if e != .None do fail("frame_at", t, e, r.error_detail)
			if f.index != index || hash(f.rgba) != hashes[index] do mismatches += 1
		}
		slice.sort(latencies[:])
		fmt.printfln("  frame_at: %d random seeks, %d mismatches, latency median %.2f ms, max %.2f ms", len(latencies), mismatches, latencies[len(latencies) / 2], latencies[len(latencies) - 1])
		if mismatches != 0 do fail("seek mismatch")
	}

}

// PCM against FFmpeg's f32le decode: the whole stream, then reads after
// random seeks against the same positions in it.
check_audio :: proc(r: ^movie.Reader) {
	if !r.audio.present || len(os.args) <= 4 do return
	reference, err := os.read_entire_file(os.args[4], context.allocator)
	if err != nil do fail("cannot read", os.args[4])
	want := ([^]f32)(raw_data(reference))[:len(reference) / 4]
	ch := r.audio.channels
	movie.seek_audio(r, 0)
	got := make([]f32, len(want) + 4096 * ch)
	n, _ := movie.read_audio(r, got)
	worst: f32
	for i in 0 ..< min(n * ch, len(want)) do worst = max(worst, abs(got[i] - want[i]))
	fmt.printfln("  pcm: %d samples/channel (FFmpeg %d), max difference %g", n, len(want) / ch, worst)
	frames := len(want) / ch
	if frames < 2048 do return
	seek_worst: f32
	window := make([]f32, 1024 * ch)
	for k in 0 ..< 30 {
		at := int(rand.int31_max(i32(frames - 1024)))
		if k == 0 do at = frames - 1024
		movie.seek_audio(r, f64(at) / f64(r.audio.sample_rate))
		m, _ := movie.read_audio(r, window)
		if m != 1024 do fail("read after seek to", at, "returned", m)
		for i in 0 ..< 1024 * ch do seek_worst = max(seek_worst, abs(window[i] - want[at * ch + i]))
	}
	fmt.printfln("  pcm seeks: 30 random seeks, max difference %g", seek_worst)
}

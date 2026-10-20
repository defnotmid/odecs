// Synthesises a moving gradient and a sine tone, writes an MP4 through
// movie, reads it back and reports PSNR/SNR and timing. When ffprobe is
// on PATH its stream report is printed; it is an oracle only.
//
//   odin run tools/mp4_smoke -o:speed -- out.mp4 [--frames N] [--size WxH]
//       [--fps NUM/DEN] [--codec h264|h265] [--qp N] [--gop N]
//       [--native|--hardware] [--no-faststart] [--no-audio]
package mp4_smoke

import movie "../../movie"
import media "../../media"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: mp4_smoke out.mp4 [--frames N] [--size WxH] [--fps NUM/DEN] [--codec h264|h265] [--qp N] [--gop N] [--native|--hardware] [--no-faststart] [--no-audio]")
		os.exit(2)
	}
	path := os.args[1]
	frames, width, height := 90, 640, 360
	config := movie.default_writer_config(width, height, 30, 1)
	config.sample_rate, config.channels = 48000, 2
	for i := 2; i < len(os.args); i += 1 {
		arg := os.args[i]
		value := i + 1 < len(os.args) ? os.args[i + 1] : ""
		switch arg {
		case "--frames":
			frames, _ = strconv.parse_int(value); i += 1
		case "--size":
			parts := strings.split(value, "x", context.temp_allocator)
			if len(parts) == 2 {width, _ = strconv.parse_int(parts[0]); height, _ = strconv.parse_int(parts[1])}
			i += 1
		case "--fps":
			parts := strings.split(value, "/", context.temp_allocator)
			config.fps_num, _ = strconv.parse_int(parts[0])
			config.fps_den = 1
			if len(parts) == 2 do config.fps_den, _ = strconv.parse_int(parts[1])
			i += 1
		case "--codec":
			config.codec = value == "h265" ? .H265 : .H264; i += 1
		case "--qp":
			config.qp, _ = strconv.parse_int(value); i += 1
		case "--gop":
			config.gop, _ = strconv.parse_int(value); i += 1
		case "--native":
			config.preference = .Native
		case "--hardware":
			config.preference = .Require_Hardware
		case "--no-faststart":
			config.faststart = false
		case "--no-audio":
			config.sample_rate, config.channels = 0, 0
		case:
			fmt.eprintln("unknown argument", arg); os.exit(2)
		}
	}
	config.width, config.height = width, height
	fps := f64(config.fps_num) / f64(config.fps_den)

	// Source: frames and the whole soundtrack, generated up front.
	rgba := make([]u8, width * height * 4)
	audio_samples := int(f64(frames) / fps * f64(config.sample_rate))
	pcm := make([]f32, audio_samples * max(config.channels, 1))
	for i in 0 ..< audio_samples do for c in 0 ..< config.channels {
		pcm[i * config.channels + c] = f32(0.3 * math.sin(2 * math.PI * f64(i) * f64(440 * (c + 1)) / f64(config.sample_rate)))
	}

	w: movie.Writer
	if e := movie.create(&w, path, config); e != .None {
		fmt.eprintfln("create failed: %v %s", e, w.error_detail); os.exit(1)
	}
	backend, provider := movie.video_backend(&w)
	start := time.tick_now()
	convert: time.Duration
	if config.sample_rate != 0 do check(movie.write_audio(&w, pcm), "write_audio", &w)
	for f in 0 ..< frames {
		t0 := time.tick_now()
		fill(rgba, width, height, f)
		convert += time.tick_since(t0)
		check(movie.write_frame(&w, rgba, width * 4), "write_frame", &w)
	}
	check(movie.finish(&w), "finish", &w)
	movie.destroy(&w)
	encode := time.tick_since(start)
	info, _ := os.stat(path, context.temp_allocator)
	size := info.size
	fmt.printfln(
		"wrote %s: %dx%d %d frames @ %d/%d, %v via %v (%s), %d bytes, %.1f fps encode (source synthesis %.1f ms)",
		path, width, height, frames, config.fps_num, config.fps_den, config.codec, backend, provider, size,
		f64(frames) / time.duration_seconds(encode), time.duration_milliseconds(convert),
	)

	// Read back: sequential playback, random access and audio.
	r: movie.Reader
	if e := movie.open_reader(&r, path, {preference = config.preference}); e != .None {
		fmt.eprintfln("open failed: %v %s", e, r.error_detail); os.exit(1)
	}
	defer movie.close_reader(&r)
	fmt.printfln("read: %dx%d %d frames %d/%d fps %.3f s, colour %v, rotation %d", r.video.width, r.video.height, r.video.frame_count, r.video.fps_num, r.video.fps_den, r.video.duration, r.video.color, r.video.rotation)
	failures := 0
	worst := 1000.0
	start = time.tick_now()
	for f in 0 ..< frames {
		frame, e := movie.next_frame(&r)
		if e != .None || frame.index != f {fmt.eprintfln("frame %d: %v index %d", f, e, frame.index); failures += 1; break}
		fill(rgba, width, height, f)
		worst = min(worst, psnr(rgba, frame.rgba, width, height))
	}
	sequential := time.tick_since(start)
	fmt.printfln("sequential: %.1f fps decode+RGBA, worst PSNR %.2f dB", f64(frames) / time.duration_seconds(sequential), worst)
	picks := [?]int{frames / 2, 1, frames - 1, frames / 3, frames / 2 + 1, 0}
	for f in picks {
		frame, e := movie.frame_at(&r, (f64(f) + 0.5) / fps)
		fill(rgba, width, height, f)
		quality := psnr(rgba, frame.rgba, width, height)
		ok := e == .None && frame.index == f && quality > 30
		if !ok do failures += 1
		fmt.printfln("frame_at(%.3f s): index %d, PSNR %.2f dB %s", (f64(f) + 0.5) / fps, frame.index, quality, ok ? "ok" : "FAIL")
	}
	if r.audio.present {
		decoded := make([]f32, (audio_samples + 4096) * config.channels)
		total := 0
		for {
			n, e := movie.read_audio(&r, decoded[total * config.channels:])
			if e != .None || n == 0 do break
			total += n
		}
		signal, noise: f64
		for i in 2048 ..< max(total - 2048, 2048) do for c in 0 ..< config.channels {
			s := f64(pcm[i * config.channels + c])
			d := f64(decoded[i * config.channels + c]) - s
			signal += s * s
			noise += d * d
		}
		snr := 10 * math.log10(signal / max(noise, 1e-20))
		ok := total == audio_samples && snr > 12
		if !ok do failures += 1
		fmt.printfln("audio: %d/%d samples per channel at %d Hz x%d, SNR %.1f dB %s", total, audio_samples, r.audio.sample_rate, r.audio.channels, snr, ok ? "ok" : "FAIL")
	}

	state, stdout, stderr, err := os.process_exec({command = {"ffprobe", "-v", "error", "-show_entries", "format=format_name,duration,bit_rate:stream=index,codec_name,codec_tag_string,profile,width,height,pix_fmt,color_range,color_space,color_transfer,color_primaries,r_frame_rate,nb_frames,sample_rate,channels,duration", "-of", "compact", path}}, context.allocator)
	if err == nil && state.exited {
		fmt.printf("ffprobe:\n%s%s", string(stdout), string(stderr))
	} else {
		fmt.println("ffprobe not found; skipped")
	}
	if failures > 0 {
		fmt.eprintfln("%d check(s) failed", failures)
		os.exit(1)
	}
	fmt.println("ok")
}

check :: proc(e: movie.Error, what: string, w: ^movie.Writer) {
	if e == .None do return
	fmt.eprintfln("%s failed: %v %s", what, e, w.error_detail)
	os.exit(1)
}

// Moving diagonal gradient with a bright square, straight alpha opaque.
fill :: proc(rgba: []u8, w, h, f: int) {
	for y in 0 ..< h {
		row := rgba[y * w * 4:]
		for x in 0 ..< w {
			t := f64(x + 2 * f) / f64(w)
			row[x * 4] = u8(40 + 170 * (0.5 + 0.5 * math.sin(2 * math.PI * t)))
			row[x * 4 + 1] = u8(30 + 190 * f64(y) / f64(h))
			row[x * 4 + 2] = u8(60 + 140 * (0.5 + 0.5 * math.cos(2 * math.PI * (t + f64(y) / f64(h)))))
			row[x * 4 + 3] = 255
		}
	}
	side := min(w, h) / 6 &~ 1
	bx := (f * 4) % max(w - side, 2) &~ 1
	by := (h - side) / 2 &~ 1
	for y in by ..< by + side do for x in bx ..< bx + side {
		p := (y * w + x) * 4
		rgba[p], rgba[p + 1], rgba[p + 2] = 245, 240, 30
	}
}

psnr :: proc(a, b: []u8, w, h: int) -> f64 {
	sum: f64
	for i in 0 ..< w * h do for c in 0 ..< 3 {
		d := f64(a[i * 4 + c]) - f64(b[i * 4 + c])
		sum += d * d
	}
	mse := sum / f64(w * h * 3)
	return mse == 0 ? 99 : 10 * math.log10(255 * 255 / mse)
}

_ :: media

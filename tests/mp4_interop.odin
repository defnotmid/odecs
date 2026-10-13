// Interop gate for codec/movie's reader against an oracle decode of the same
// file (for example FFmpeg's), which is only a development reference:
//
//   ffmpeg -i in.mp4 -map 0:v:0 -fps_mode passthrough -f rawvideo -pix_fmt rgba ref.rgba
//   ffmpeg -i in.mp4 -map 0:a:0 -f f32le ref.pcm
//   mp4_interop in.mp4 ref.rgba ref.pcm [--native] [--min-psnr DB]
//
// Video: every frame in presentation order must match the oracle frame of the
// same index best among its neighbours (alignment) and reach the PSNR floor;
// frame_at is checked in a shuffled order. Audio: the sample count must match
// and the decode must agree (SNR). Pass "-" to skip a reference.
package mp4_interop

import movie "../codec/movie"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"

main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: mp4_interop in.mp4 ref.rgba|- ref.pcm|- [--native] [--min-psnr DB]")
		os.exit(2)
	}
	config: movie.Reader_Config
	floor := 35.0
	first_time := -1.0
	for i := 4; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--native":
			config.preference = .Native
		case "--min-psnr":
			floor, _ = strconv.parse_f64(os.args[i + 1]); i += 1
		case "--first-time":
			first_time, _ = strconv.parse_f64(os.args[i + 1]); i += 1
		}
	}
	r: movie.Reader
	if e := movie.open_reader(&r, os.args[1], config); e != .None {
		fmt.printfln("open: %v (%s)", e, r.error_detail)
		os.exit(e == .Unsupported ? 3 : 1)
	}
	defer movie.close_reader(&r)
	v := r.video
	fmt.printfln("video %v %dx%d frames=%d fps=%d/%d duration=%.4f rotation=%d colour=%v", v.codec, v.width, v.height, v.frame_count, v.fps_num, v.fps_den, v.duration, v.rotation, v.color)
	failures := 0
	if os.args[2] != "-" {
		reference, err := os.read_entire_file(os.args[2], context.allocator)
		if err != nil {fmt.eprintln("cannot read", os.args[2]); os.exit(2)}
		size := v.width * v.height * 4
		count := len(reference) / size
		frame :: proc(reference: []u8, size, i: int) -> []u8 {return reference[i * size:][:size]}
		worst := 1000.0
		decoded := 0
		times: [dynamic]f64
		// A first frame that straddles time zero (pts < 0) is on screen at
		// zero, so the reader presents it; FFmpeg drops it. It is excluded
		// from alignment: our frame i is the oracle's frame i - skip.
		skip := 0
		for {
			f, e := movie.next_frame(&r)
			if e == .End_Of_Stream do break
			if e != .None {fmt.printfln("next_frame %d: %v %s", decoded, e, r.error_detail); failures += 1; break}
			if f.index != decoded {fmt.printfln("next_frame %d reports index %d", decoded, f.index); failures += 1}
			append(&times, f.time)
			decoded += 1
			if decoded == 1 && f.time < -1e-9 {
				skip = 1
				fmt.printfln("first frame straddles zero at %.4f s; aligning from the next", f.time)
				continue
			}
			i := decoded - 1 - skip
			// After dropping a straddling frame FFmpeg re-bases the next frame
			// to zero; the reader keeps the edit list's exact time for it.
			if i == 0 && skip == 0 && first_time >= 0 && abs(f.time - first_time) > 1e-3 {
				fmt.printfln("first frame at %.4f s, oracle %.4f s", f.time, first_time)
				failures += 1
			}
			if i >= count {failures += 1; continue}
			q := psnr(frame(reference, size, i), f.rgba, v.width, v.height)
			worst = min(worst, q)
			for j in ([2]int{i - 1, i + 1}) {
				if j < 0 || j >= count do continue
				// A neighbour can only match better if the timestamps are misaligned.
				if n := psnr(frame(reference, size, j), f.rgba, v.width, v.height); n > q + 0.5 && n < 90 {
					fmt.printfln("frame %d matches reference %d better (%.2f vs %.2f dB)", i, j, n, q)
					failures += 1
				}
			}
		}
		ok := decoded - skip == count && decoded == v.frame_count && worst >= floor
		if !ok do failures += 1
		fmt.printfln("sequential: %d/%d frames (frame_count %d), worst PSNR %.2f dB %s", decoded - skip, count, v.frame_count, worst, ok ? "ok" : "FAIL")
		// frame_at a quarter frame after each frame's own time, shuffled.
		fps := f64(v.fps_num) / f64(v.fps_den)
		bad := 0
		lookups := min(len(times), 24)
		for k in 0 ..< lookups {
			i := (k * 7919) % len(times)
			f, e := movie.frame_at(&r, times[i] + 0.25 / fps)
			ri := i - skip
			if e != .None || f.index != i || ri >= 0 && ri < count && psnr(frame(reference, size, ri), f.rgba, v.width, v.height) < floor {
				fmt.printfln("frame_at %d: %v index %d", i, e, f.index)
				bad += 1
			}
		}
		// Outside the presented range, lookups clamp to its ends.
		if f, e := movie.frame_at(&r, -1000); e != .None || f.index != 0 do bad += 1
		if f, e := movie.frame_at(&r, 1e9); e != .None || f.index != v.frame_count - 1 do bad += 1
		if bad > 0 do failures += 1
		fmt.printfln("frame_at: %d shuffled lookups and both ends %s", lookups, bad == 0 ? "ok" : "FAIL")
	}
	if os.args[3] != "-" {
		if !r.audio.present {
			fmt.println("audio: no AAC-LC track")
			failures += 1
		} else {
			reference_bytes, err := os.read_entire_file(os.args[3], context.allocator)
			if err != nil {fmt.eprintln("cannot read", os.args[3]); os.exit(2)}
			reference := transmute([]f32)reference_bytes
			ch := r.audio.channels
			reference = reference[:len(reference_bytes) / 4]
			// The oracle starts at the first decoded sample; read_audio starts
			// at movie time zero, so a delayed track leads with silence.
			a := &r.demux.tracks[r.audio_index]
			delay := int(a.edit.delay * i64(r.audio.sample_rate) / i64(a.timescale))
			expected := len(reference) / ch + delay
			decoded := make([]f32, expected * ch + 8192 * ch)
			total := 0
			for {
				n, e := movie.read_audio(&r, decoded[total * ch:])
				if e != .None || n == 0 do break
				total += n
			}
			signal, noise: f64
			for i in 0 ..< delay * ch do noise += f64(decoded[i]) * f64(decoded[i])
			for i in 0 ..< (min(total, expected) - delay) * ch {
				s := f64(reference[i])
				d := f64(decoded[delay * ch + i]) - s
				signal += s * s
				noise += d * d
			}
			snr := 10 * math.log10(signal / max(noise, 1e-30))
			// The reader ends at the edit list's presented end. An oracle that
			// ignores an edit ending inside the last AU returns that AU's tail.
			trimmed := a.edit.duration > 0 && i64(total) == r.audio.samples && total < expected && expected - total < 2048
			ok := (total == expected || trimmed) && snr > 60
			if !ok do failures += 1
			fmt.printfln("audio: %d/%d samples per channel (edit end %d), %d Hz x%d, SNR vs reference %.1f dB %s", total, expected, r.audio.samples, r.audio.sample_rate, ch, snr, ok ? "ok" : "FAIL")
		}
	}
	if failures > 0 {
		fmt.printfln("FAILED (%d)", failures)
		os.exit(1)
	}
	fmt.println("ok")
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

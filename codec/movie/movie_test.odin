package movie

import mp4 "../container/mp4"
import media "../media"
import "core:math"
import "core:testing"

@(private = "file")
convert_pixel :: proc(r, g, b, a: u8, alpha: Alpha, background: [3]u8 = {}) -> (y, u, v: u8) {
	c := rgb_to_yuv_coefficients(.BT709, false)
	px := [16]u8{}
	for i in 0 ..< 4 do px[i * 4], px[i * 4 + 1], px[i * 4 + 2], px[i * 4 + 3] = r, g, b, a
	planes: [3][4]u8
	rgba_to_i420(px[:], 8, 2, 2, {planes[0][:], planes[1][:], planes[2][:]}, {2, 1, 1}, &c, alpha, background)
	return planes[0][0], planes[1][0], planes[2][0]
}

@(test)
test_bt709_limited_range_code_values :: proc(t: ^testing.T) {
	y, u, v := convert_pixel(255, 255, 255, 255, .Straight)
	testing.expect_value(t, [3]u8{y, u, v}, [3]u8{235, 128, 128})
	y, u, v = convert_pixel(0, 0, 0, 255, .Straight)
	testing.expect_value(t, [3]u8{y, u, v}, [3]u8{16, 128, 128})
	y, u, v = convert_pixel(255, 0, 0, 255, .Straight)
	testing.expect_value(t, [3]u8{y, u, v}, [3]u8{63, 102, 240})
	y, u, v = convert_pixel(0, 0, 255, 255, .Opaque)
	testing.expect_value(t, [3]u8{y, u, v}, [3]u8{32, 240, 118})

	// Alpha: straight composites over the background, premultiplied adds it
	// under the uncovered part, opaque ignores alpha.
	y, _, _ = convert_pixel(255, 255, 255, 0, .Straight, {0, 0, 0})
	testing.expect_value(t, y, 16)
	y, _, _ = convert_pixel(255, 255, 255, 0, .Opaque)
	testing.expect_value(t, y, 235)
	y, _, _ = convert_pixel(0, 0, 0, 0, .Premultiplied, {255, 255, 255})
	testing.expect_value(t, y, 235)
	y, _, _ = convert_pixel(128, 128, 128, 128, .Premultiplied, {0, 0, 0})
	a, _, _ := convert_pixel(128, 128, 128, 255, .Opaque)
	testing.expect_value(t, y, a)

	inverse := yuv_to_rgb_coefficients(.BT709, false, 8)
	samples := [3][2]u8{{16, 235}, {128, 128}, {128, 128}}
	rgba: [8]u8
	yuv_to_rgba({samples[0][:], samples[1][:1], samples[2][:1]}, {2, 1, 1}, 2, 1, 8, 1, 1, &inverse, rgba[:], 8)
	testing.expect_value(t, rgba, [8]u8{0, 0, 0, 255, 255, 255, 255, 255})
	deep := yuv_to_rgb_coefficients(.BT709, false, 10)
	words := [4]u16{64, 940, 512, 512}
	bytes := transmute([8]u8)words
	yuv_to_rgba({bytes[0:4], bytes[4:6], bytes[6:8]}, {4, 2, 2}, 2, 1, 16, 1, 1, &deep, rgba[:], 8)
	testing.expect_value(t, rgba, [8]u8{0, 0, 0, 255, 255, 255, 255, 255})
}

@(test)
test_rgb_round_trip_is_close :: proc(t: ^testing.T) {
	W, H :: 64, 32
	src := make([]u8, W * H * 4)
	defer delete(src)
	fill_gradient(src, W, H, 3)
	planes := make([]u8, W * H * 3 / 2)
	defer delete(planes)
	c := rgb_to_yuv_coefficients(.BT709, false)
	p := [3][]u8{planes[:W * H], planes[W * H:][:W * H / 4], planes[W * H * 5 / 4:]}
	rgba_to_i420(src, W * 4, W, H, p, {W, W / 2, W / 2}, &c, .Straight, {})
	back := make([]u8, W * H * 4)
	defer delete(back)
	inverse := yuv_to_rgb_coefficients(.BT709, false, 8)
	yuv_to_rgba(p, {W, W / 2, W / 2}, W, H, 8, 1, 1, &inverse, back, W * 4)
	// The remaining loss is 4:2:0 subsampling of the diagonal sine and box.
	testing.expectf(t, psnr(src, back, W, H) > 36, "psnr %v", psnr(src, back, W, H))

	// Flat colours carry no subsampling loss: the matrices must invert to
	// within the 8-bit limited-range quantization.
	for colour in ([?][3]u8{{0, 0, 0}, {255, 255, 255}, {255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {37, 150, 201}, {128, 128, 128}}) {
		for i in 0 ..< W * H do src[i * 4], src[i * 4 + 1], src[i * 4 + 2], src[i * 4 + 3] = colour[0], colour[1], colour[2], 255
		rgba_to_i420(src, W * 4, W, H, p, {W, W / 2, W / 2}, &c, .Opaque, {})
		yuv_to_rgba(p, {W, W / 2, W / 2}, W, H, 8, 1, 1, &inverse, back, W * 4)
		for k in 0 ..< 3 {
			d := abs(int(back[k]) - int(colour[k]))
			testing.expectf(t, d <= 2, "colour %v channel %d came back %d", colour, k, back[k])
		}
	}
}

// A smooth moving gradient with a moving box whose edges fall on 2x2 chroma
// block boundaries, opaque.
fill_gradient :: proc(rgba: []u8, w, h, frame: int) {
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := (y * w + x) * 4
			rgba[p] = u8(x * 200 / max(w - 1, 1) + frame % 28 * 2)
			rgba[p + 1] = u8(y * 255 / max(h - 1, 1))
			rgba[p + 2] = u8(128 + 100 * math.sin(f64(x + y + frame * 3) * 0.05))
			rgba[p + 3] = 255
			bx := (frame * 4) % max(w - 12, 2) &~ 1
			by := h / 4 &~ 1
			if x >= bx && x < bx + 12 && y >= by && y < by + 12 {
				rgba[p], rgba[p + 1], rgba[p + 2] = 250, 250, 20
			}
		}
	}
}

// PSNR of the RGB channels in dB.
psnr :: proc(a, b: []u8, w, h: int) -> f64 {
	sum: f64
	for i in 0 ..< w * h {
		for c in 0 ..< 3 {
			d := f64(a[i * 4 + c]) - f64(b[i * 4 + c])
			sum += d * d
		}
	}
	mse := sum / f64(w * h * 3)
	return mse == 0 ? 99 : 10 * math.log10(255 * 255 / mse)
}

@(private = "file")
tone :: proc(i, channel, rate: int) -> f32 {
	return f32(0.4 * math.sin(2 * math.PI * f64(i) * f64(440 + 220 * channel) / f64(rate)))
}

@(private = "file")
round_trip :: proc(t: ^testing.T, codec: Video_Codec) {
	W, H, FRAMES, FPS :: 96, 64, 14, 24
	RATE, CHANNELS :: 48000, 2
	AUDIO :: RATE * FRAMES / FPS + 333 // not a whole number of AAC frames
	m: mp4.Memory_Stream
	defer delete(m.data)
	config := default_writer_config(W, H, FPS, 1)
	config.codec = codec
	config.qp = 18
	config.gop = 5
	config.preference = .Native
	config.sample_rate, config.channels = RATE, CHANNELS
	w: Writer
	testing.expect_value(t, create_stream(&w, mp4.memory_stream(&m), config), Error.None)
	frames := make([][]u8, FRAMES)
	defer {for f in frames do delete(f); delete(frames)}
	pcm := make([]f32, AUDIO * CHANNELS)
	defer delete(pcm)
	for i in 0 ..< AUDIO do for c in 0 ..< CHANNELS do pcm[i * CHANNELS + c] = tone(i, c, RATE)
	// All audio first, as a renderer with a pre-mixed soundtrack would.
	testing.expect_value(t, write_audio(&w, pcm[:1000 * CHANNELS]), Error.None)
	testing.expect_value(t, write_audio(&w, pcm[1000 * CHANNELS:]), Error.None)
	for i in 0 ..< FRAMES {
		frames[i] = make([]u8, W * H * 4)
		fill_gradient(frames[i], W, H, i)
		testing.expect_value(t, write_frame(&w, frames[i], W * 4), Error.None)
	}
	testing.expect_value(t, finish(&w), Error.None)
	destroy(&w)

	r: Reader
	testing.expect_value(t, open_reader_stream(&r, mp4.memory_stream(&m), {preference = .Native}), Error.None)
	defer close_reader(&r)
	testing.expect_value(t, r.video.width, W)
	testing.expect_value(t, r.video.height, H)
	testing.expect_value(t, r.video.frame_count, FRAMES)
	testing.expect_value(t, r.video.fps_num, FPS)
	testing.expect_value(t, r.video.fps_den, 1)
	testing.expect_value(t, r.video.color, BT709_LIMITED)
	testing.expect(t, abs(r.video.duration - f64(FRAMES) / FPS) < 1e-9)
	testing.expect(t, r.demux.tracks[r.video_index].no_reordering)

	// Sequential playback.
	for i in 0 ..< FRAMES {
		f, err := next_frame(&r)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, f.index, i)
		testing.expect(t, abs(f.time - f64(i) / FPS) < 1e-9)
		quality := psnr(frames[i], f.rgba, W, H)
		testing.expectf(t, quality > 32, "frame %d psnr %v", i, quality)
	}
	_, end := next_frame(&r)
	testing.expect_value(t, end, Error.End_Of_Stream)

	// Random access lands on the exact frame shown at each instant.
	order := [?]int{7, 3, 3, 4, 12, 0, 13, 9, 10, 2}
	for i in order {
		at := f64(i) / FPS + 0.5 / FPS // mid-frame
		f, err := frame_at(&r, at)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, f.index, i)
		testing.expect(t, psnr(frames[i], f.rgba, W, H) > 32)
		g, e2 := frame_at(&r, f64(i) / FPS) // exact boundary
		testing.expect_value(t, e2, Error.None)
		testing.expect_value(t, g.index, i)
	}
	before, _ := frame_at(&r, -1)
	testing.expect_value(t, before.index, 0)
	after, _ := frame_at(&r, 100)
	testing.expect_value(t, after.index, FRAMES - 1)
	// next_frame continues after a random access.
	frame_at(&r, 5.0 / FPS)
	next, _ := next_frame(&r)
	testing.expect_value(t, next.index, 6)

	// Audio: priming and padding trimmed to the exact input length.
	testing.expect(t, r.audio.present)
	testing.expect_value(t, r.audio.samples, i64(AUDIO))
	decoded := make([]f32, (AUDIO + 4096) * CHANNELS)
	defer delete(decoded)
	total := 0
	for {
		n, err := read_audio(&r, decoded[total * CHANNELS:][:777 * CHANNELS])
		if err == .End_Of_Stream do break
		testing.expect_value(t, err, Error.None)
		total += n
	}
	testing.expect_value(t, total, AUDIO)
	signal, noise: f64
	for i in 2048 ..< AUDIO - 2048 {
		for c in 0 ..< CHANNELS {
			s := f64(pcm[i * CHANNELS + c])
			d := f64(decoded[i * CHANNELS + c]) - s
			signal += s * s
			noise += d * d
		}
	}
	snr := 10 * math.log10(signal / max(noise, 1e-20))
	testing.expectf(t, snr > 12, "audio SNR %v dB (alignment or decode error)", snr)

	// Seeking resumes at the same samples as sequential decoding.
	position := 12345
	testing.expect_value(t, seek_audio(&r, f64(position) / RATE), Error.None)
	chunk: [256 * CHANNELS]f32
	n, err := read_audio(&r, chunk[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, n, 256)
	worst: f32
	for v, i in chunk do worst = max(worst, abs(v - decoded[position * CHANNELS + i]))
	testing.expectf(t, worst < 1e-3, "seek mismatch %v", worst)
}

@(test)
test_h264_movie_round_trip :: proc(t: ^testing.T) {
	round_trip(t, .H264)
}

@(test)
test_h265_movie_round_trip :: proc(t: ^testing.T) {
	round_trip(t, .H265)
}

@(test)
test_writer_refuses_unrepresentable_configs :: proc(t: ^testing.T) {
	m: mp4.Memory_Stream
	defer delete(m.data)
	w: Writer
	odd := default_writer_config(65, 64, 30, 1)
	testing.expect_value(t, create_stream(&w, mp4.memory_stream(&m), odd), Error.Invalid_Config)
	rate := default_writer_config(64, 64, 30, 1)
	rate.sample_rate, rate.channels = 44056, 2
	testing.expect_value(t, create_stream(&w, mp4.memory_stream(&m), rate), Error.Unsupported)
	fps := default_writer_config(64, 64, 0, 1)
	testing.expect_value(t, create_stream(&w, mp4.memory_stream(&m), fps), Error.Invalid_Config)
}

// Remuxes a clip with its timeline shifted back by `shift` ticks and ended at
// `end`: the edit list hides pre-roll and tail frames. This is also the
// packet-level remux/concatenation path segments use.
@(private = "file")
remux_shifted :: proc(t: ^testing.T, src: ^mp4.Memory_Stream, dst: ^mp4.Memory_Stream, shift, end: i64) {
	r: mp4.Reader
	testing.expect_value(t, mp4.open_stream(&r, mp4.memory_stream(src)), mp4.Error.None)
	defer mp4.close(&r)
	v := &r.tracks[0]
	w: mp4.Writer
	config := mp4.Track_Config{codec = .H264, timescale = v.timescale, width = v.width, height = v.height, color = v.color, default_duration = v.samples[0].duration}
	testing.expect_value(t, mp4.create_stream(&w, mp4.memory_stream(dst), {config}), mp4.Error.None)
	defer mp4.destroy(&w)
	for i in 0 ..< len(v.samples) {
		p, _ := mp4.read_sample(&r, 0, i)
		testing.expect_value(t, mp4.begin_sample(&w, 0, p.pts - shift, p.dts - shift), mp4.Error.None)
		if i == 0 {
			// Parameter sets travel in avcC; hand them to the new sample entry.
			c := v.config
			pos := 6
			for set in 0 ..< 2 {
				count := set == 0 ? int(c[5] & 0x1F) : int(c[pos])
				if set == 1 do pos += 1
				for _ in 0 ..< count {
					n := int(c[pos]) << 8 | int(c[pos + 1])
					testing.expect_value(t, mp4.add_nal(&w, c[pos + 2:][:n]), mp4.Error.None)
					pos += 2 + n
				}
			}
		}
		for pos := 0; pos < len(p.data); {
			n := int(p.data[pos]) << 24 | int(p.data[pos + 1]) << 16 | int(p.data[pos + 2]) << 8 | int(p.data[pos + 3])
			testing.expect_value(t, mp4.add_nal(&w, p.data[pos + 4:][:n]), mp4.Error.None)
			pos += 4 + n
		}
		testing.expect_value(t, mp4.end_sample(&w, p.sync), mp4.Error.None)
	}
	testing.expect_value(t, mp4.set_track_end(&w, 0, end), mp4.Error.None)
	testing.expect_value(t, mp4.finish(&w), mp4.Error.None)
}

@(test)
test_edit_list_hidden_frames_are_not_presented :: proc(t: ^testing.T) {
	W, H, FRAMES :: 64, 48, 20
	src: mp4.Memory_Stream
	defer delete(src.data)
	config := default_writer_config(W, H, 30, 1)
	config.preference, config.qp, config.gop = .Native, 18, 5
	w: Writer
	testing.expect_value(t, create_stream(&w, mp4.memory_stream(&src), config), Error.None)
	frames := make([][]u8, FRAMES)
	defer {for f in frames do delete(f); delete(frames)}
	for i in 0 ..< FRAMES {
		frames[i] = make([]u8, W * H * 4)
		fill_gradient(frames[i], W, H, i)
		testing.expect_value(t, write_frame(&w, frames[i], W * 4), Error.None)
	}
	testing.expect_value(t, finish(&w), Error.None)
	destroy(&w)
	// 30/1 frames last 512 ticks. Whole frames hidden at both ends, then a
	// shift that leaves a frame straddling time zero.
	for shift in ([2]i64{3 * 512, 5 * 512 / 2}) {
		dst: mp4.Memory_Stream
		defer delete(dst.data)
		end := 14 * 512 - (shift % 512)
		remux_shifted(t, &src, &dst, shift, end)
		first := int(shift / 512) // source frame on screen at time zero
		last := int((end + shift + 511) / 512) - 1 // last source frame starting before end
		r: Reader
		testing.expect_value(t, open_reader_stream(&r, mp4.memory_stream(&dst), {preference = .Native}), Error.None)
		defer close_reader(&r)
		count := 0
		for {
			f, e := next_frame(&r)
			if e == .End_Of_Stream do break
			testing.expect_value(t, e, Error.None)
			testing.expect_value(t, f.index, count)
			testing.expectf(t, psnr(frames[first + count], f.rgba, W, H) > 30, "shift %d frame %d", shift, count)
			count += 1
		}
		testing.expect_value(t, count, r.video.frame_count)
		testing.expect_value(t, r.video.frame_count, last - first + 1)
		before, e := frame_at(&r, -1)
		testing.expect_value(t, e, Error.None)
		testing.expect_value(t, before.index, 0)
		testing.expect(t, psnr(frames[first], before.rgba, W, H) > 30)
		after, _ := frame_at(&r, 100)
		testing.expect_value(t, after.index, r.video.frame_count - 1)
		testing.expect(t, psnr(frames[first + r.video.frame_count - 1], after.rgba, W, H) > 30)
	}
}

@(test)
test_color_resolution :: proc(t: ^testing.T) {
	// QuickTime nclc has no range flag: the VUI's full range wins, and
	// unspecified container fields defer to the VUI.
	color := resolve_color({2, 2, 1, false}, false, {1, 1, 1, true}, 1080)
	testing.expect_value(t, color, media.Color{1, 1, 1, true})
	// nclx carries the range: it stands.
	color = resolve_color({1, 1, 1, false}, true, {1, 1, 1, true}, 1080)
	testing.expect_value(t, color, media.Color{1, 1, 1, false})
	// Nothing signalled: BT.601 for SD, BT.709 for HD.
	testing.expect_value(t, resolve_color({}, false, {}, 480).matrix_coeffs, 6)
	testing.expect_value(t, resolve_color({}, false, {}, 720).matrix_coeffs, 1)
}

// Planar output: the planes and their description, converted by
// planar_to_rgba, give exactly the reader's RGBA, including after a seek.
@(test)
test_planar_matches_rgba :: proc(t: ^testing.T) {
	W, H, FRAMES :: 96, 64, 6
	m: mp4.Memory_Stream
	defer delete(m.data)
	config := default_writer_config(W, H, 24, 1)
	config.codec = .H265
	config.preference = .Native
	w: Writer
	testing.expect_value(t, create_stream(&w, mp4.memory_stream(&m), config), Error.None)
	frame := make([]u8, W * H * 4)
	defer delete(frame)
	for i in 0 ..< FRAMES {
		fill_gradient(frame, W, H, i)
		write_frame(&w, frame, W * 4)
	}
	testing.expect_value(t, finish(&w), Error.None)
	destroy(&w)
	a, b: Reader
	testing.expect_value(t, open_reader_stream(&a, mp4.memory_stream(&m), {preference = .Native}), Error.None)
	testing.expect_value(t, open_reader_stream(&b, mp4.memory_stream(&m), {preference = .Native, format = .Planar}), Error.None)
	defer {close_reader(&a); close_reader(&b)}
	check :: proc(t: ^testing.T, x, y: Frame, scratch: []u8) {
		testing.expect(t, len(y.rgba) == 0)
		p := y.planar
		testing.expect(t, p.width == W && p.height == H && p.chroma == .YUV420 && p.bit_depth == 8 && p.storage_bits == 8)
		testing.expect_value(t, len(p.planes[1]), (W / 2) * (H / 2))
		testing.expect_value(t, p.color, BT709_LIMITED)
		planar_to_rgba(p, scratch)
		testing.expect(t, string(scratch) == string(x.rgba))
	}
	scratch := make([]u8, W * H * 4)
	defer delete(scratch)
	for _ in 0 ..< FRAMES {
		x, _ := next_frame(&a)
		y, _ := next_frame(&b)
		check(t, x, y, scratch)
	}
	x, _ := frame_at(&a, 2.0 / 24)
	y, _ := frame_at(&b, 2.0 / 24)
	check(t, x, y, scratch)
}

// I420 and NV12 input are the same picture in two layouts: the files match.
@(test)
test_nv12_matches_i420 :: proc(t: ^testing.T) {
	W, H :: 96, 64
	for codec in ([]Video_Codec{.H264, .H265}) {
		files: [2]mp4.Memory_Stream
		defer for f in files do delete(f.data)
		rgba := make([]u8, W * H * 4)
		defer delete(rgba)
		planes := make([]u8, W * H * 3 / 2)
		defer delete(planes)
		nv12 := make([]u8, W * H / 2)
		defer delete(nv12)
		y, u, v := planes[:W * H], planes[W * H:][:W * H / 4], planes[W * H * 5 / 4:]
		k := rgb_to_yuv_coefficients(.BT709, false)
		for &file, layout in files {
			config := default_writer_config(W, H, 30, 1)
			config.codec, config.preference = codec, .Native
			w: Writer
			testing.expect_value(t, create_stream(&w, mp4.memory_stream(&file), config), Error.None)
			for i in 0 ..< 6 {
				fill_gradient(rgba, W, H, i)
				rgba_to_i420(rgba, W * 4, W, H, {y, u, v}, {W, W / 2, W / 2}, &k, .Opaque, {})
				if layout == 0 {
					testing.expect_value(t, write_i420(&w, {y, u, v}, {W, W / 2, W / 2}), Error.None)
				} else {
					for j in 0 ..< len(u) do nv12[2 * j], nv12[2 * j + 1] = u[j], v[j]
					testing.expect_value(t, write_nv12(&w, {y, nv12}, {W, W}), Error.None)
				}
			}
			testing.expect_value(t, finish(&w), Error.None)
			destroy(&w)
		}
		testing.expectf(t, string(files[0].data[:]) == string(files[1].data[:]), "%v: NV12 file differs from I420", codec)
	}
}

// Transparent H.265 keeps alpha in both stored forms and reads back as
// written: premultiplied output is the picture over black either way.
@(test)
test_transparent_round_trip :: proc(t: ^testing.T) {
	W, H :: 96, 64
	rgba := make([]u8, W * H * 4)
	defer delete(rgba)
	for y in 0 ..< H do for x in 0 ..< W {
		a := u8(x * 255 / (W - 1))
		p := rgba[(y * W + x) * 4:][:4]
		p[0], p[1], p[2], p[3] = u8(int(a) * 200 / 255), u8(int(a) * y / H), 0, a // premultiplied
	}
	for stored in ([]Transparency{.Premultiplied, .Straight}) {
		m: mp4.Memory_Stream
		defer delete(m.data)
		config := default_writer_config(W, H, 30, 1)
		config.codec, config.qp = .H265, 12
		config.alpha, config.transparency = .Premultiplied, stored
		w: Writer
		testing.expect_value(t, create_stream(&w, mp4.memory_stream(&m), config), Error.None)
		for _ in 0 ..< 3 do testing.expect_value(t, write_frame(&w, rgba, W * 4), Error.None)
		testing.expect_value(t, finish(&w), Error.None)
		destroy(&w)

		r: Reader
		testing.expect_value(t, open_reader_stream(&r, mp4.memory_stream(&m), {preference = .Native, premultiplied_alpha = true}), Error.None)
		defer close_reader(&r)
		testing.expect(t, r.video.has_alpha)
		f, e := next_frame(&r)
		testing.expect_value(t, e, Error.None)
		worst := 0
		for v, i in f.rgba do worst = max(worst, abs(int(v) - int(rgba[i])))
		testing.expectf(t, worst <= 8, "%v: max error %d", stored, worst)
	}
}

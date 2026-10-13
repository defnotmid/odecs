// One player for everything odecs decodes: MP4/MOV (H.264, H.265, ProRes,
// AAC, FLAC, PCM), WebM/MKV (VP9 with alpha, H.264, H.265, AAC, FLAC, PCM),
// WAV, FLAC, MP3, Ogg Opus, raw Annex-B H.264/H.265 streams and ADTS AAC. Alpha shows over a checkerboard; audio plays with a visualizer.
//
//   odin build viewer -o:speed && ./viewer.bin [--native] [--fps N] FILE
//
// Space pause, Left/Right seek 5 s (step a frame when paused), Home restart,
// Up/Down volume, M mute, V visualizer, I info, F fullscreen, Q/Esc quit.
package viewer

import common "../codec/common"
import media "../codec/media"
import native "../codec/media/native"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

DEFAULT_PATH :: "third_party/openh264/res/BA_MW_D.264"
SEEK_SECONDS :: 5

// Playback time from the wall clock; audio pulls it into line when present.
Clock :: struct {
	anchor: time.Tick, // wall time of playback zero
	paused: bool,
	at:     f64, // playback time while paused
}

clock_now :: proc(c: ^Clock) -> f64 {
	return c.paused ? c.at : time.duration_seconds(time.tick_since(c.anchor))
}

clock_set :: proc(c: ^Clock, t: f64) {
	c.at = t
	c.anchor = time.tick_now()
	c.anchor._nsec -= i64(t * 1e9)
}

Player :: struct {
	source:     Source,
	audio:      Audio,
	visualizer: ^Visualizer,
	clock:      Clock,
	renderer:   ^sdl.Renderer,
	texture:    ^sdl.Texture,
	frame:      Frame, // on screen
	have_frame: bool,
	video_done: bool,
	decode_ms:  f64,
}

main :: proc() {
	path := DEFAULT_PATH
	preference := media.Preference.Automatic
	raw_fps := 30.0
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--native":
			preference = .Native
		case "--fps":
			if i + 1 < len(args) {
				i += 1
				raw_fps = strconv.parse_f64(args[i]) or_else 30
			}
		case "-h", "--help":
			fmt.println("usage: viewer [--native] [--fps N] FILE")
			fmt.println("plays .mp4 .mov .m4a .webm .mkv .wav .flac .mp3 .opus .ogg, raw .264/.h264/.265/.hevc and .aac")
			return
		case:
			path = args[i]
		}
	}

	pool: common.Static_Pool
	common.init_static_pool(&pool, 7)
	defer common.destroy_static_pool(&pool)
	options := native.Options{pool = &pool.work_pool}

	p: Player
	s := &p.source
	if !source_open(s, path, &options, preference, raw_fps) {
		fmt.eprintfln("viewer: %s: %s", path, s.error_detail)
		os.exit(1)
	}
	defer source_close(s)

	if !sdl.Init({.VIDEO, .AUDIO}) {fmt.eprintln("SDL:", sdl.GetError()); os.exit(1)}
	defer sdl.Quit()
	win_w, win_h: i32 = 960, 540
	if s.has_video {
		scale := min(1.0, 1500 / f64(s.width), 850 / f64(s.height))
		win_w, win_h = max(i32(f64(s.width) * scale), 320), max(i32(f64(s.height) * scale), 180)
	}
	name := path[strings.last_index_byte(path, '/') + 1:]
	window := sdl.CreateWindow(fmt.ctprintf("odecs viewer: %s", name), win_w, win_h, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil {fmt.eprintln("SDL:", sdl.GetError()); os.exit(1)}
	defer sdl.DestroyWindow(window)
	p.renderer = sdl.CreateRenderer(window, nil)
	defer sdl.DestroyRenderer(p.renderer)
	sdl.SetRenderVSync(p.renderer, 1)
	if s.has_video {
		p.texture = sdl.CreateTexture(p.renderer, .RGBA32, .STREAMING, i32(s.width), i32(s.height))
		sdl.SetTextureBlendMode(p.texture, sdl.BLENDMODE_BLEND_PREMULTIPLIED)
		sdl.SetTextureScaleMode(p.texture, .LINEAR)
	}
	defer if p.texture != nil do sdl.DestroyTexture(p.texture)

	if s.has_audio {
		if audio_open(&p.audio, s.sample_rate, s.channels) {
			audio_set_paused(&p.audio, false) // device streams open paused
			p.visualizer = new(Visualizer)
			visualizer_init(p.visualizer, s.sample_rate)
		} else {
			fmt.eprintln("viewer: no audio device:", sdl.GetError())
		}
	}
	defer if p.visualizer != nil {visualizer_destroy(p.visualizer); free(p.visualizer)}
	defer audio_close(&p.audio)

	show_visualizer, show_info := true, true
	fullscreen := false
	clock_set(&p.clock, 0)
	last := time.tick_now()
	running := true
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				t := clock_now(&p.clock)
				step := 1 / max(s.fps, 1)
				switch event.key.key {
				case sdl.K_ESCAPE, sdl.K_Q:
					running = false
				case sdl.K_SPACE:
					set_paused(&p, !p.clock.paused)
				case sdl.K_HOME:
					seek(&p, 0)
				case sdl.K_LEFT:
					seek(&p, p.clock.paused && s.has_video ? p.frame.time - step : t - SEEK_SECONDS)
				case sdl.K_RIGHT:
					if p.clock.paused && s.has_video {
						step_frame(&p)
					} else {
						seek(&p, t + SEEK_SECONDS)
					}
				case sdl.K_UP:
					audio_set_gain(&p.audio, p.audio.gain + 0.1)
				case sdl.K_DOWN:
					audio_set_gain(&p.audio, p.audio.gain - 0.1)
				case sdl.K_M:
					p.audio.muted = !p.audio.muted
					audio_set_gain(&p.audio, p.audio.gain)
				case sdl.K_V:
					show_visualizer = !show_visualizer
				case sdl.K_I:
					show_info = !show_info
				case sdl.K_F:
					fullscreen = !fullscreen
					sdl.SetWindowFullscreen(window, fullscreen)
				}
			}
		}
		now := time.tick_now()
		dt := f32(time.duration_seconds(time.tick_diff(last, now)))
		last = now

		advance(&p)

		w, h: i32
		sdl.GetWindowSizeInPixels(window, &w, &h)
		fw, fh := f32(w), f32(h)
		sdl.SetRenderDrawBlendMode(p.renderer, sdl.BLENDMODE_BLEND)
		if s.has_video {
			draw_video(&p, fw, fh)
		} else {
			sdl.SetRenderDrawColor(p.renderer, 0, 0, 0, 255)
			sdl.RenderClear(p.renderer)
		}
		if p.visualizer != nil {
			visualizer_update(p.visualizer, &p.audio, p.clock.paused ? 0 : dt)
			if !s.has_video do visualizer_draw_full(p.visualizer, p.renderer, fw, fh)
			else if show_visualizer do visualizer_draw_panel(p.visualizer, p.renderer, fw, fh)
		}
		if show_info do draw_info(&p, name, fh)
		sdl.RenderPresent(p.renderer)
		free_all(context.temp_allocator)
	}
}

set_paused :: proc(p: ^Player, paused: bool) {
	if paused == p.clock.paused do return
	if paused {
		p.clock.at = clock_now(&p.clock)
		p.clock.paused = true
	} else {
		p.clock.paused = false
		clock_set(&p.clock, p.clock.at)
	}
	audio_set_paused(&p.audio, paused)
}

seek :: proc(p: ^Player, target: f64) {
	s := &p.source
	end := s.duration > 0 ? s.duration - 1 / max(s.fps, 1) : 0
	t := clamp(target, 0, max(end, 0))
	start := time.tick_now()
	f, ok := source_seek(s, t)
	p.decode_ms = time.duration_milliseconds(time.tick_since(start))
	p.video_done = s.has_video && !ok
	if ok {
		show(p, f)
		t = f.time
	}
	audio_reset(&p.audio, t)
	clock_set(&p.clock, t)
}

step_frame :: proc(p: ^Player) {
	start := time.tick_now()
	f, ok := source_next_frame(&p.source)
	p.decode_ms = time.duration_milliseconds(time.tick_since(start))
	if !ok do return
	show(p, f)
	clock_set(&p.clock, f.time)
	p.clock.paused = true
	if p.source.has_audio {
		// Keep audio aligned with the stepped picture.
		source_seek_audio(&p.source, f.time)
		audio_reset(&p.audio, f.time)
	}
}

show :: proc(p: ^Player, f: Frame) {
	p.frame, p.have_frame = f, true
	sdl.UpdateTexture(p.texture, nil, raw_data(f.rgba), i32(f.width * 4))
}

// Feeds audio, follows its clock, and brings video up to the playback time;
// loops when everything has ended.
advance :: proc(p: ^Player) {
	s := &p.source
	if p.clock.paused do return
	audio_pump(&p.audio, s)
	if p.audio.stream != nil && !p.audio.ended && p.audio.fed > 0 {
		// The audio device is the master: nudge the wall clock towards it.
		d := audio_time(&p.audio) - clock_now(&p.clock)
		if abs(d) > 0.2 do clock_set(&p.clock, audio_time(&p.audio))
		else do p.clock.anchor._nsec -= i64(d * 0.05 * 1e9)
	}
	t := clock_now(&p.clock)
	if s.has_video && !p.video_done {
		frame_time := 1 / max(s.fps, 1)
		decoded := 0
		for !p.have_frame || p.frame.time + frame_time <= t {
			start := time.tick_now()
			f, ok := source_next_frame(s)
			if !ok {
				p.video_done = true
				if s.error_detail != "" do fmt.eprintln("viewer:", s.error_detail)
				break
			}
			p.decode_ms = time.duration_milliseconds(time.tick_since(start))
			p.frame, p.have_frame = f, true
			decoded += 1
			if decoded == 4 do break // behind: show what we have
		}
		if decoded > 0 do sdl.UpdateTexture(p.texture, nil, raw_data(p.frame.rgba), i32(p.frame.width * 4))
	}
	video_over := !s.has_video || p.video_done
	audio_over := audio_drained(&p.audio)
	if video_over && audio_over {
		if !s.has_video && t < s.duration && p.audio.stream == nil do return
		seek(p, 0)
	}
}

draw_video :: proc(p: ^Player, w, h: f32) {
	s := &p.source
	// A checkerboard shows through transparent pixels.
	if s.alpha {
		cell :: 24
		rects := make([dynamic]sdl.FRect, 0, 512, context.temp_allocator)
		sdl.SetRenderDrawColor(p.renderer, 120, 120, 120, 255)
		sdl.RenderClear(p.renderer)
		for y: f32 = 0; y < h; y += cell do for x: f32 = 0; x < w; x += cell {
			if (int(x / cell) + int(y / cell)) & 1 == 0 do append(&rects, sdl.FRect{x, y, cell, cell})
		}
		sdl.SetRenderDrawColor(p.renderer, 200, 200, 200, 255)
		sdl.RenderFillRects(p.renderer, raw_data(rects), i32(len(rects)))
	} else {
		sdl.SetRenderDrawColor(p.renderer, 0, 0, 0, 255)
		sdl.RenderClear(p.renderer)
	}
	if !p.have_frame do return
	k := min(w / f32(s.width), h / f32(s.height))
	dst := sdl.FRect{(w - f32(s.width) * k) / 2, (h - f32(s.height) * k) / 2, f32(s.width) * k, f32(s.height) * k}
	sdl.RenderTexture(p.renderer, p.texture, nil, &dst)
}

draw_info :: proc(p: ^Player, name: string, h: f32) {
	s := &p.source
	scale := max(1, f32(int(h / 600 + 0.5)))
	sdl.SetRenderScale(p.renderer, scale, scale)
	defer sdl.SetRenderScale(p.renderer, 1, 1)
	t := p.have_frame && !s.has_audio ? p.frame.time : clock_now(&p.clock)
	lines := make([dynamic]cstring, 0, 6, context.temp_allocator)
	append(&lines, fmt.ctprintf("%s", name))
	if s.label != "" do append(&lines, fmt.ctprintf("%s", s.label))
	if s.audio_label != "" {
		volume := p.audio.muted ? "muted" : fmt.tprintf("volume %d%%", int(p.audio.gain * 100 + 0.5))
		append(&lines, fmt.ctprintf("%s  %s", s.audio_label, volume))
	}
	position := fmt.tprintf("%s / %s", clock_text(t), clock_text(s.duration))
	if s.has_video {
		count := s.frame_count > 0 ? fmt.tprintf("%d", s.frame_count) : "?"
		append(&lines, fmt.ctprintf("%s  frame %d/%s  decode %.1f ms%s", position, p.frame.index + 1, count, p.decode_ms, p.clock.paused ? "  [paused]" : ""))
	} else {
		append(&lines, fmt.ctprintf("%s%s", position, p.clock.paused ? "  [paused]" : ""))
	}
	append(&lines, "space pause  <- -> seek  home  up/down volume  m mute  v visualizer  i info  f fullscreen  q quit")
	box_w: f32
	for l in lines do box_w = max(box_w, f32(len(l)) * sdl.DEBUG_TEXT_FONT_CHARACTER_SIZE)
	sdl.SetRenderDrawColor(p.renderer, 0, 0, 0, 140)
	box := sdl.FRect{4, 4, box_w + 12, f32(len(lines)) * 11 + 8}
	sdl.RenderFillRect(p.renderer, &box)
	for l, i in lines {
		y := 10 + f32(i) * 11
		sdl.SetRenderDrawColor(p.renderer, i == len(lines) - 1 ? 170 : 255, i == len(lines) - 1 ? 170 : 255, i == len(lines) - 1 ? 170 : 255, 255)
		sdl.RenderDebugText(p.renderer, 10, y, l)
	}
}

clock_text :: proc(t: f64) -> string {
	ms := int(max(t, 0) * 1000 + 0.5)
	return fmt.tprintf("%d:%02d.%03d", ms / 60000, ms / 1000 % 60, ms % 1000)
}

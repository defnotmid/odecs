package viewer

import "core:math"
import sdl "vendor:sdl3"

// Audio playback through an SDL audio stream, plus the visualizer that draws
// what is playing right now: a log-frequency spectrum, an oscilloscope and
// level meters.

RING :: 1 << 15 // frames of fed audio kept for the visualizer
FFT_N :: 2048
BANDS :: 64
SCOPE :: 512
QUEUE_SECONDS :: 0.25
CHUNK :: 2048 // frames per read

Audio :: struct {
	stream:          ^sdl.AudioStream,
	rate, channels:  int,
	base:            f64, // seconds of the first frame fed since the last reset
	fed:             i64, // frames fed since the reset
	ended:           bool,
	muted:           bool,
	gain:            f32,
	chunk:           []f32,
	// Fed audio as left/right, indexed by frame number since the reset.
	left, right:     []f32,
}

audio_open :: proc(a: ^Audio, rate, channels: int) -> bool {
	spec := sdl.AudioSpec{format = .F32, channels = i32(channels), freq = i32(rate)}
	a.stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if a.stream == nil do return false
	a.rate, a.channels, a.gain = rate, channels, 1
	a.chunk = make([]f32, CHUNK * channels)
	a.left = make([]f32, RING)
	a.right = make([]f32, RING)
	return true
}

audio_close :: proc(a: ^Audio) {
	if a.stream != nil do sdl.DestroyAudioStream(a.stream)
	delete(a.chunk)
	delete(a.left)
	delete(a.right)
	a^ = {}
}

// Drops queued audio; playback continues from `seconds` with the next pump.
audio_reset :: proc(a: ^Audio, seconds: f64) {
	if a.stream == nil do return
	sdl.ClearAudioStream(a.stream)
	a.base, a.fed, a.ended = seconds, 0, false
	for &x in a.left do x = 0
	for &x in a.right do x = 0
}

audio_set_paused :: proc(a: ^Audio, paused: bool) {
	if a.stream == nil do return
	if paused do sdl.PauseAudioStreamDevice(a.stream)
	else do sdl.ResumeAudioStreamDevice(a.stream)
}

audio_set_gain :: proc(a: ^Audio, gain: f32) {
	a.gain = clamp(gain, 0, 2)
	if a.stream != nil do sdl.SetAudioStreamGain(a.stream, a.muted ? 0 : a.gain)
}

audio_queued :: proc(a: ^Audio) -> i64 {
	return i64(sdl.GetAudioStreamQueued(a.stream)) / i64(4 * a.channels)
}

// Frames the device has taken since the reset.
audio_played :: proc(a: ^Audio) -> i64 {
	return a.stream == nil ? 0 : max(a.fed - audio_queued(a), 0)
}

audio_time :: proc(a: ^Audio) -> f64 {
	return a.base + f64(audio_played(a)) / f64(a.rate)
}

audio_drained :: proc(a: ^Audio) -> bool {
	return a.stream == nil || (a.ended && audio_queued(a) == 0)
}

// Keeps about QUEUE_SECONDS queued.
audio_pump :: proc(a: ^Audio, s: ^Source) {
	if a.stream == nil do return
	target := i64(QUEUE_SECONDS * f64(a.rate))
	for !a.ended && audio_queued(a) < target {
		n := source_read_audio(s, a.chunk)
		if n == 0 {
			a.ended = true
			sdl.FlushAudioStream(a.stream)
			break
		}
		sdl.PutAudioStreamData(a.stream, raw_data(a.chunk), i32(n * a.channels * 4))
		ch := a.channels
		for i in 0 ..< n {
			frame := a.chunk[i * ch:][:ch]
			at := (a.fed + i64(i)) & (RING - 1)
			if ch == 1 {
				a.left[at], a.right[at] = frame[0], frame[0]
				continue
			}
			// Even channels to the left, odd to the right.
			l, r: f32
			for k := 0; k < ch; k += 2 do l += frame[k]
			for k := 1; k < ch; k += 2 do r += frame[k]
			a.left[at], a.right[at] = l / f32((ch + 1) / 2), r / f32(ch / 2)
		}
		a.fed += i64(n)
	}
}

// ---- Visualizer -------------------------------------------------------------

Visualizer :: struct {
	window:                     [FFT_N]f32, // Hann
	re, im:                     [FFT_N]f32,
	cos_t, sin_t:               [FFT_N / 2]f32,
	reverse:                    [FFT_N]u16,
	band_lo, band_hi:           [BANDS]int, // FFT bins [lo, hi)
	level, peak, hold:          [BANDS]f32, // 0..1
	scope:                      [SCOPE]f32,
	meter, meter_peak:          [2]f32, // 0..1 RMS and held peak
	bass:                       f32,
	hue:                        f32, // slowly turning colour offset
	vertices:                   [dynamic]sdl.Vertex,
	indices:                    [dynamic]i32,
	points:                     [dynamic]sdl.FPoint,
}

visualizer_init :: proc(v: ^Visualizer, rate: int) {
	for i in 0 ..< FFT_N do v.window[i] = 0.5 - 0.5 * math.cos(2 * math.PI * f32(i) / f32(FFT_N))
	for i in 0 ..< FFT_N / 2 {
		angle := -2 * math.PI * f64(i) / f64(FFT_N)
		v.cos_t[i], v.sin_t[i] = f32(math.cos(angle)), f32(math.sin(angle))
	}
	bits :: 11 // log2(FFT_N)
	#assert(1 << bits == FFT_N)
	for i in 0 ..< FFT_N {
		r := 0
		for b in 0 ..< bits do r |= (i >> uint(b) & 1) << uint(bits - 1 - b)
		v.reverse[i] = u16(r)
	}
	// Log-spaced bands from 30 Hz to 18 kHz (or near Nyquist).
	lo_hz, hi_hz := 30.0, min(18000.0, f64(rate) * 0.48)
	bin_hz := f64(rate) / f64(FFT_N)
	for b in 0 ..< BANDS {
		f0 := lo_hz * math.pow(hi_hz / lo_hz, f64(b) / BANDS)
		f1 := lo_hz * math.pow(hi_hz / lo_hz, f64(b + 1) / BANDS)
		lo := max(1, int(f0 / bin_hz))
		v.band_lo[b], v.band_hi[b] = lo, max(lo + 1, int(f1 / bin_hz))
	}
}

visualizer_destroy :: proc(v: ^Visualizer) {
	delete(v.vertices)
	delete(v.indices)
	delete(v.points)
}

@(private = "file")
fft :: proc(v: ^Visualizer) #no_bounds_check {
	for i in 0 ..< FFT_N {
		j := int(v.reverse[i])
		if j > i {
			v.re[i], v.re[j] = v.re[j], v.re[i]
			v.im[i], v.im[j] = v.im[j], v.im[i]
		}
	}
	for size := 2; size <= FFT_N; size <<= 1 {
		half, step := size / 2, FFT_N / size
		for start := 0; start < FFT_N; start += size {
			for k in 0 ..< half {
				wr, wi := v.cos_t[k * step], v.sin_t[k * step]
				a, b := start + k, start + k + half
				tr := v.re[b] * wr - v.im[b] * wi
				ti := v.re[b] * wi + v.im[b] * wr
				v.re[b], v.im[b] = v.re[a] - tr, v.im[a] - ti
				v.re[a], v.im[a] = v.re[a] + tr, v.im[a] + ti
			}
		}
	}
}

@(private = "file")
to_unit :: proc(amplitude: f32, floor_db: f32) -> f32 {
	db := 20 * math.log10(max(amplitude, 1e-9))
	return clamp((db - floor_db) / -floor_db, 0, 1)
}

// Analyses the audio the device is playing now. dt is the frame time.
visualizer_update :: proc(v: ^Visualizer, a: ^Audio, dt: f32) {
	end := audio_played(a)
	oldest := a.fed - RING
	sample :: proc(a: ^Audio, at, oldest: i64) -> (l, r: f32) {
		if at < 0 || at < oldest || at >= a.fed do return 0, 0
		k := at & (RING - 1)
		return a.left[k], a.right[k]
	}
	for i in 0 ..< FFT_N {
		l, r := sample(a, end - FFT_N + i64(i), oldest)
		v.re[i], v.im[i] = 0.5 * (l + r) * v.window[i], 0
	}
	for i in 0 ..< SCOPE {
		l, r := sample(a, end - SCOPE + i64(i), oldest)
		v.scope[i] = 0.5 * (l + r)
	}
	// Meters over the last 1024 frames.
	sum, top: [2]f32
	for i in 0 ..< 1024 {
		l, r := sample(a, end - 1024 + i64(i), oldest)
		sum += {l * l, r * r}
		top = {max(top[0], abs(l)), max(top[1], abs(r))}
	}
	for c in 0 ..< 2 {
		rms := to_unit(math.sqrt(sum[c] / 1024), -60)
		v.meter[c] = rms > v.meter[c] ? rms : max(rms, v.meter[c] - 1.5 * dt)
		v.meter_peak[c] = max(to_unit(top[c], -60), v.meter_peak[c] - 0.5 * dt)
	}
	fft(v)
	// A full-scale sine under a Hann window peaks at FFT_N/4.
	norm := f32(4) / FFT_N
	bass: f32
	for b in 0 ..< BANDS {
		m: f32
		for k in v.band_lo[b] ..< v.band_hi[b] do m = max(m, v.re[k] * v.re[k] + v.im[k] * v.im[k])
		x := to_unit(math.sqrt(m) * norm, -70)
		// Fast attack, slow fall.
		v.level[b] = x > v.level[b] ? 0.4 * v.level[b] + 0.6 * x : max(x, v.level[b] - 1.4 * dt)
		if v.level[b] >= v.peak[b] {
			v.peak[b], v.hold[b] = v.level[b], 0.4
		} else {
			v.hold[b] -= dt
			if v.hold[b] <= 0 do v.peak[b] = max(v.level[b], v.peak[b] - 0.5 * dt)
		}
		if b < 8 do bass += v.level[b] / 8
	}
	v.bass = bass > v.bass ? bass : max(bass, v.bass - 1.2 * dt)
	v.hue += dt * (0.015 + 0.05 * v.bass)
	v.hue -= math.floor(v.hue)
}

@(private = "file")
hsv :: proc(h, s, v, alpha: f32) -> sdl.FColor {
	h6 := (h - math.floor(h)) * 6
	c := v * s
	x := c * (1 - abs(math.mod(h6, 2) - 1))
	rgb: [3]f32
	switch int(h6) {
	case 0: rgb = {c, x, 0}
	case 1: rgb = {x, c, 0}
	case 2: rgb = {0, c, x}
	case 3: rgb = {0, x, c}
	case 4: rgb = {x, 0, c}
	case: rgb = {c, 0, x}
	}
	m := v - c
	return {rgb[0] + m, rgb[1] + m, rgb[2] + m, alpha}
}

// A quad with one colour on its first edge (p0, p1) and another on (p3, p2).
@(private = "file")
quad :: proc(v: ^Visualizer, p0, p1, p2, p3: sdl.FPoint, c0, c1: sdl.FColor) {
	base := i32(len(v.vertices))
	append(&v.vertices, sdl.Vertex{p0, c0, {}}, sdl.Vertex{p1, c0, {}}, sdl.Vertex{p2, c1, {}}, sdl.Vertex{p3, c1, {}})
	append(&v.indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

@(private = "file")
rect :: proc(v: ^Visualizer, x, y, w, h: f32, bottom, top: sdl.FColor) {
	quad(v, {x, y + h}, {x + w, y + h}, {x + w, y}, {x, y}, bottom, top)
}

@(private = "file")
flush :: proc(v: ^Visualizer, renderer: ^sdl.Renderer) {
	if len(v.indices) > 0 do sdl.RenderGeometry(renderer, nil, raw_data(v.vertices), i32(len(v.vertices)), raw_data(v.indices), i32(len(v.indices)))
	clear(&v.vertices)
	clear(&v.indices)
}

@(private = "file")
band_color :: proc(v: ^Visualizer, b: int, brightness, alpha: f32) -> sdl.FColor {
	return hsv(v.hue + 0.55 + 0.5 * f32(b) / BANDS, 0.85, brightness, alpha)
}

// Level meters: green to yellow to red, with a held peak tick.
@(private = "file")
meters :: proc(v: ^Visualizer, x, y, w, h: f32) {
	stops := [4]f32{0, 0.6, 0.85, 1}
	colors := [4]sdl.FColor{{0.1, 0.85, 0.3, 0.95}, {0.6, 0.95, 0.2, 0.95}, {1, 0.85, 0.1, 0.95}, {1, 0.15, 0.1, 0.95}}
	bar := (w - 4) / 2
	for c in 0 ..< 2 {
		bx := x + f32(c) * (bar + 4)
		rect(v, bx, y, bar, h, {1, 1, 1, 0.08}, {1, 1, 1, 0.08})
		level := v.meter[c]
		for s in 0 ..< 3 {
			lo, hi := stops[s], min(stops[s + 1], level)
			if hi <= lo do break
			t := (hi - lo) / (stops[s + 1] - lo)
			top := colors[s] + (colors[s + 1] - colors[s]) * t
			rect(v, bx, y + h * (1 - hi), bar, h * (hi - lo), colors[s], top)
		}
		py := y + h * (1 - v.meter_peak[c])
		rect(v, bx, py, bar, 2, {1, 1, 1, 0.9}, {1, 1, 1, 0.9})
	}
}

// A translucent spectrum panel over the bottom of the video.
visualizer_draw_panel :: proc(v: ^Visualizer, renderer: ^sdl.Renderer, w, h: f32) {
	ph := max(90, h * 0.24)
	y0 := h - ph
	rect(v, 0, y0, w, ph, {0, 0, 0, 0.7}, {0, 0, 0, 0.15})
	meter_w: f32 = 28
	area := w - meter_w - 24
	slot := area / BANDS
	gap := max(1, slot * 0.18)
	pad: f32 = 8
	bars_h := ph - 2 * pad
	base := h - pad
	for b in 0 ..< BANDS {
		x := 8 + f32(b) * slot
		bh := max(2, v.level[b] * bars_h)
		rect(v, x, base - bh, slot - gap, bh, band_color(v, b, 0.55, 0.85), band_color(v, b, 1, 0.95))
		py := base - v.peak[b] * bars_h - 3
		rect(v, x, py, slot - gap, 2, {1, 1, 1, 0.85}, {1, 1, 1, 0.85})
	}
	meters(v, w - meter_w - 8, y0 + pad, meter_w, bars_h)
	flush(v, renderer)
	// The oscilloscope across the panel.
	clear(&v.points)
	mid := y0 + ph * 0.5
	for i in 0 ..< SCOPE do append(&v.points, sdl.FPoint{8 + area * f32(i) / (SCOPE - 1), mid - clamp(v.scope[i], -1, 1) * ph * 0.42})
	sdl.SetRenderDrawColor(renderer, 255, 255, 255, 150)
	sdl.RenderLines(renderer, raw_data(v.points), i32(len(v.points)))
}

// The audio-only scene: a radial spectrum around a ring that pulses with the
// bass, a circular oscilloscope inside it, and meters.
visualizer_draw_full :: proc(v: ^Visualizer, renderer: ^sdl.Renderer, w, h: f32) {
	glow := 0.05 + 0.12 * v.bass
	quad(v, {0, 0}, {w, 0}, {w, h}, {0, h}, hsv(v.hue + 0.6, 0.7, 0.08 + glow, 1), hsv(v.hue + 0.8, 0.8, 0.02 + glow * 0.5, 1))
	cx, cy := w * 0.5, h * 0.47
	size := min(w, h)
	r0 := size * (0.17 + 0.05 * v.bass)
	spoke := size * 0.26
	// Two mirrored half circles of bands, low frequencies at the top.
	for side in 0 ..< 2 {
		for b in 0 ..< BANDS {
			t := (f32(b) + 0.5) / BANDS
			angle := math.PI * t * (side == 0 ? 1 : -1) - math.PI / 2
			half_width := f32(math.PI / BANDS * 0.36)
			length := max(2, v.level[b] * spoke)
			a0, a1 := angle - half_width, angle + half_width
			c0 := band_color(v, b, 0.6, 0.9)
			c1 := band_color(v, b, 1, 0.95)
			quad(v, {cx + r0 * math.cos(a0), cy + r0 * math.sin(a0)}, {cx + r0 * math.cos(a1), cy + r0 * math.sin(a1)}, {cx + (r0 + length) * math.cos(a1), cy + (r0 + length) * math.sin(a1)}, {cx + (r0 + length) * math.cos(a0), cy + (r0 + length) * math.sin(a0)}, c0, c1)
			pr := r0 + v.peak[b] * spoke + 3
			quad(v, {cx + pr * math.cos(a0), cy + pr * math.sin(a0)}, {cx + pr * math.cos(a1), cy + pr * math.sin(a1)}, {cx + (pr + 2) * math.cos(a1), cy + (pr + 2) * math.sin(a1)}, {cx + (pr + 2) * math.cos(a0), cy + (pr + 2) * math.sin(a0)}, {1, 1, 1, 0.8}, {1, 1, 1, 0.8})
		}
	}
	// A flat spectrum along the bottom, mirrored.
	slot := w / BANDS
	floor_y := h - 6
	for b in 0 ..< BANDS {
		bh := v.level[b] * h * 0.12
		rect(v, f32(b) * slot + 1, floor_y - bh, slot - 2, bh, band_color(v, b, 0.4, 0.5), band_color(v, b, 0.9, 0.7))
	}
	meters(v, w - 40, h * 0.2, 28, h * 0.6)
	flush(v, renderer)
	// The circular scope.
	clear(&v.points)
	for i in 0 ..= SCOPE {
		k := i % SCOPE
		angle := 2 * math.PI * f32(i) / SCOPE - math.PI / 2
		r := r0 * (0.8 + 0.35 * clamp(v.scope[k], -1, 1))
		append(&v.points, sdl.FPoint{cx + r * math.cos(angle), cy + r * math.sin(angle)})
	}
	c := hsv(v.hue + 0.1, 0.4, 1, 1)
	sdl.SetRenderDrawColor(renderer, u8(c[0] * 255), u8(c[1] * 255), u8(c[2] * 255), 220)
	sdl.RenderLines(renderer, raw_data(v.points), i32(len(v.points)))
}

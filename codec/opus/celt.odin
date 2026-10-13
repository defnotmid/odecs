package opus

import "core:math"

// The CELT layer (RFC 6716 4.3) for the standard 48 kHz mode: 21 bands of
// 2.5 ms units, MDCTs of 120 << LM coefficients, a 120-sample overlap.

NB_BANDS :: 21
@(private)
OVERLAP :: 120
@(private)
SHORT_MDCT :: 120
@(private)
MAX_LM :: 3
@(private)
DECODE_BUFFER :: 2048 // synthesis history for the postfilter
@(private)
PREEMPH :: f32(0.85000610)
@(private)
MAX_FINE_BITS :: 8
@(private)
FINE_OFFSET :: 21
@(private)
QTHETA_OFFSET :: 4
@(private)
QTHETA_OFFSET_TWOPHASE :: 16
@(private)
COMBFILTER_MINPERIOD :: 15

Spread :: enum u8 {
	None,
	Light,
	Normal,
	Aggressive,
}

// Per channel state carried between frames, and per-frame scratch, so that
// decoding allocates nothing.
Celt :: struct {
	channels:              int, // output channels
	stream_channels:       int, // coded channels of the current frame
	start, end:            int, // coded band range
	rng:                   u32, // final range of the last frame
	postfilter_period:     int,
	postfilter_period_old: int,
	postfilter_gain:       f32,
	postfilter_gain_old:   f32,
	postfilter_tapset:     int,
	postfilter_tapset_old: int,
	preemph_mem:           [2]f32,
	// Band log energies (log2 amplitude) by channel: current, the two before
	// (anti-collapse), and the background floor.
	band_e, log_e, log_e2, background_e: [2][NB_BANDS]f32,
	history:               [2][DECODE_BUFFER + OVERLAP]f32,
	// Concealment: how long, how, and from what the last frames were made.
	loss_duration:         int, // in 2.5 ms units since the last decoded frame
	plc_duration:          int,
	last_frame:            Frame_Kind,
	skip_plc:              bool, // noise only, until two frames in a row decode
	fold:                  bool, // the history ends in a periodic concealment's overlap
	last_pitch:            int,
	lpc:                   [2][PLC_LPC_ORDER]f32,
	// Scratch.
	x:                     [2][SHORT_MDCT << MAX_LM]f32, // normalised spectrum by channel
	freq:                  [2][SHORT_MDCT << MAX_LM]f32,
	norm:                  [2][SHORT_MDCT << MAX_LM]f32, // folding source
	fft:                   Fft_Scratch,
	collapse:              [NB_BANDS * 2]u8,
}

celt_init :: proc(c: ^Celt, channels: int) {
	c^ = {
		channels        = channels,
		stream_channels = channels,
		end             = NB_BANDS,
	}
	celt_reset(c)
}

// Forgets the signal history (RFC 6716: on a mode change), keeping setup.
celt_reset :: proc(c: ^Celt) {
	c.rng = 0
	c.postfilter_period, c.postfilter_period_old = 0, 0
	c.postfilter_gain, c.postfilter_gain_old = 0, 0
	c.postfilter_tapset, c.postfilter_tapset_old = 0, 0
	c.preemph_mem = {}
	c.history = {}
	c.band_e = {}
	c.loss_duration, c.plc_duration, c.last_pitch = 0, 0, 0
	c.last_frame, c.skip_plc, c.fold = .None, true, false
	c.lpc = {}
	for ch in 0 ..< 2 do for i in 0 ..< NB_BANDS {
		c.log_e[ch][i] = -28
		c.log_e2[ch][i] = -28
		c.background_e[ch][i] = 0
	}
}

// Decodes one CELT frame of `frame_size` samples per channel (120 << LM)
// from `data` through `r` (initialised over it, possibly partly used by
// SILK) and writes it interleaved to pcm, scaled to +-1. A frame of at
// most one byte is lost and concealed.
celt_decode :: proc(c: ^Celt, data: []u8, r: ^Range_Decoder, pcm: []f32, frame_size: int, accumulate := false) -> Error {
	lm := 0
	for lm <= MAX_LM && SHORT_MDCT << uint(lm) != frame_size do lm += 1
	if lm > MAX_LM do return .Invalid_Packet
	if len(data) > 1275 do return .Invalid_Packet
	m := 1 << uint(lm)
	n := m * SHORT_MDCT
	cc := c.channels
	if len(data) <= 1 {
		celt_conceal(c, n, lm)
		deemphasis(c, pcm, n, cc, accumulate)
		return .None
	}
	if c.loss_duration == 0 do c.skip_plc = false
	ch := c.stream_channels
	start, end := c.start, c.end
	if ch == 1 do for i in 0 ..< NB_BANDS do c.band_e[0][i] = max(c.band_e[0][i], c.band_e[1][i])

	total_bits := len(data) * 8
	tell := range_tell(r)
	silence := false
	if tell >= total_bits {
		silence = true
	} else if tell == 1 {
		silence = range_bit_logp(r, 15)
	}
	if silence {
		// Treat the rest of the frame as used.
		r.nbits_total += total_bits - range_tell(r)
		tell = total_bits
	}
	postfilter_gain: f32
	postfilter_pitch, postfilter_tapset := 0, 0
	if start == 0 && tell + 16 <= total_bits {
		if range_bit_logp(r, 1) {
			octave := int(range_uint(r, 6))
			postfilter_pitch = (16 << uint(octave)) + int(range_bits(r, uint(4 + octave))) - 1
			qg := int(range_bits(r, 3))
			if range_tell(r) + 2 <= total_bits do postfilter_tapset = range_icdf(r, TAPSET_ICDF[:], 2)
			postfilter_gain = 0.09375 * f32(qg + 1)
		}
		tell = range_tell(r)
	}
	transient := false
	if lm > 0 && tell + 3 <= total_bits {
		transient = range_bit_logp(r, 3)
		tell = range_tell(r)
	}
	intra := tell + 3 <= total_bits ? range_bit_logp(r, 3) : false
	if !intra && c.loss_duration != 0 do safe_energy(c, start, end, lm)
	coarse_energy(c, r, start, end, intra, ch, lm)

	tf_res: [NB_BANDS]int
	tf_decode(r, start, end, transient, &tf_res, lm)
	spread := Spread.Normal
	if range_tell(r) + 4 <= total_bits do spread = Spread(range_icdf(r, SPREAD_ICDF[:], 5))

	caps: [NB_BANDS]int
	for i in 0 ..< NB_BANDS {
		width := int(EBANDS[i + 1] - EBANDS[i]) << uint(lm)
		caps[i] = (int(CACHE_CAPS[2 * lm + ch - 1][i]) + 64) * ch * width >> 2
	}
	// Dynamic allocation boosts per band.
	offsets: [NB_BANDS]int
	dynalloc_logp: uint = 6
	budget := total_bits << BITRES
	tell = range_tell_frac(r)
	for i in start ..< end {
		width := ch * int(EBANDS[i + 1] - EBANDS[i]) << uint(lm)
		quanta := min(width << BITRES, max(6 << BITRES, width))
		loop_logp := dynalloc_logp
		boost := 0
		for tell + int(loop_logp << BITRES) < budget && boost < caps[i] {
			flag := range_bit_logp(r, loop_logp)
			tell = range_tell_frac(r)
			if !flag do break
			boost += quanta
			budget -= quanta
			loop_logp = 1
		}
		offsets[i] = boost
		if boost > 0 do dynalloc_logp = max(2, dynalloc_logp - 1)
	}
	alloc_trim := tell + 6 << BITRES <= budget ? range_icdf(r, TRIM_ICDF[:], 7) : 5
	bits := (len(data) * 8) << BITRES - range_tell_frac(r) - 1
	anti_collapse_rsv := transient && lm >= 2 && bits >= (lm + 2) << BITRES ? 1 << BITRES : 0
	bits -= anti_collapse_rsv

	a: Allocation
	compute_allocation(&a, r, start, end, &offsets, &caps, alloc_trim, bits, ch, lm)
	fine_energy(c, r, start, end, &a.fine_quant, ch)

	for k in 0 ..< cc do copy(c.history[k][:DECODE_BUFFER - n + OVERLAP], c.history[k][n:])

	bands_decode(c, r, start, end, &a, transient ? m : 0, spread, &tf_res, (len(data) * 8) << BITRES - anti_collapse_rsv, lm, ch)

	anti_collapse_on := anti_collapse_rsv > 0 && range_bits(r, 1) == 1
	finalise_energy(c, r, start, end, &a.fine_quant, &a.fine_priority, len(data) * 8 - range_tell(r), ch)
	if anti_collapse_on do anti_collapse(c, start, end, lm, ch, n, &a.pulses)
	if silence do for k in 0 ..< 2 do for i in 0 ..< NB_BANDS do c.band_e[k][i] = -28

	if c.fold do prefilter_and_fold(c, n)
	synthesis(c, start, min(end, NB_BANDS), ch, cc, transient, lm, silence)

	for k in 0 ..< cc {
		c.postfilter_period = max(c.postfilter_period, COMBFILTER_MINPERIOD)
		c.postfilter_period_old = max(c.postfilter_period_old, COMBFILTER_MINPERIOD)
		comb_filter(c.history[k][:], DECODE_BUFFER - n, c.postfilter_period_old, c.postfilter_period, SHORT_MDCT, c.postfilter_gain_old, c.postfilter_gain, c.postfilter_tapset_old, c.postfilter_tapset)
		if lm != 0 do comb_filter(c.history[k][:], DECODE_BUFFER - n + SHORT_MDCT, c.postfilter_period, postfilter_pitch, n - SHORT_MDCT, c.postfilter_gain, postfilter_gain, c.postfilter_tapset, postfilter_tapset)
	}
	c.postfilter_period_old, c.postfilter_gain_old, c.postfilter_tapset_old = c.postfilter_period, c.postfilter_gain, c.postfilter_tapset
	c.postfilter_period, c.postfilter_gain, c.postfilter_tapset = postfilter_pitch, postfilter_gain, postfilter_tapset
	if lm != 0 do c.postfilter_period_old, c.postfilter_gain_old, c.postfilter_tapset_old = c.postfilter_period, c.postfilter_gain, c.postfilter_tapset

	if ch == 1 do c.band_e[1] = c.band_e[0]
	if !transient {
		c.log_e2 = c.log_e
		c.log_e = c.band_e
	} else {
		for k in 0 ..< 2 do for i in 0 ..< NB_BANDS do c.log_e[k][i] = min(c.log_e[k][i], c.band_e[k][i])
	}
	// The noise floor rises at most 2.4 dB/s, but a loss (or DTX) counts
	// whole toward it.
	max_increase := f32(min(160, c.loss_duration + m)) * 0.001
	for k in 0 ..< 2 do for i in 0 ..< NB_BANDS do c.background_e[k][i] = min(c.background_e[k][i] + max_increase, c.band_e[k][i])
	for k in 0 ..< 2 {
		for i in 0 ..< start {
			c.band_e[k][i] = 0
			c.log_e[k][i], c.log_e2[k][i] = -28, -28
		}
		for i in end ..< NB_BANDS {
			c.band_e[k][i] = 0
			c.log_e[k][i], c.log_e2[k][i] = -28, -28
		}
	}
	c.rng = r.rng
	c.loss_duration, c.plc_duration = 0, 0
	c.last_frame, c.fold = .Normal, false
	deemphasis(c, pcm, n, cc, accumulate)
	if range_tell(r) > 8 * len(data) do return .Invalid_Packet
	return .None
}

// Coarse energy (RFC 6716 4.3.2.1): Laplace residuals of a prediction in
// time (inter) and frequency.
@(private)
coarse_energy :: proc(c: ^Celt, r: ^Range_Decoder, start, end: int, intra: bool, ch, lm: int) {
	@(static, rodata)
	PRED := [4]f32{29440.0 / 32768, 26112.0 / 32768, 21248.0 / 32768, 16384.0 / 32768}
	@(static, rodata)
	BETA := [4]f32{30147.0 / 32768, 22282.0 / 32768, 12124.0 / 32768, 6554.0 / 32768}
	@(static, rodata)
	SMALL_ENERGY_ICDF := [3]u8{2, 1, 0}
	model := &E_PROB_MODEL[lm][intra ? 1 : 0]
	coef := intra ? 0 : PRED[lm]
	beta := intra ? f32(4915.0 / 32768) : BETA[lm]
	prev: [2]f32
	budget := len(r.data) * 8
	for i in start ..< end {
		for k in 0 ..< ch {
			tell := range_tell(r)
			qi: int
			switch {
			case budget - tell >= 15:
				pi := 2 * min(i, 20)
				qi = range_laplace(r, u32(model[pi]) << 7, u32(model[pi + 1]) << 6)
			case budget - tell >= 2:
				qi = range_icdf(r, SMALL_ENERGY_ICDF[:], 2)
				qi = (qi >> 1) ~ -(qi & 1)
			case budget - tell >= 1:
				qi = -int(range_bit_logp(r, 1))
			case:
				qi = -1
			}
			q := f32(qi)
			old := max(-9, c.band_e[k][i])
			c.band_e[k][i] = coef * old + prev[k] + q
			prev[k] = prev[k] + q - beta * q
		}
	}
}

@(private)
fine_energy :: proc(c: ^Celt, r: ^Range_Decoder, start, end: int, fine_quant: ^[NB_BANDS]int, ch: int) {
	for i in start ..< end {
		extra := fine_quant[i]
		if extra <= 0 || range_tell(r) + ch * extra > len(r.data) * 8 do continue
		for k in 0 ..< ch {
			q2 := range_bits(r, uint(extra))
			c.band_e[k][i] += (f32(q2) + 0.5) * f32(i32(1) << uint(14 - extra)) * (1.0 / 16384) - 0.5
		}
	}
}

@(private)
finalise_energy :: proc(c: ^Celt, r: ^Range_Decoder, start, end: int, fine_quant, fine_priority: ^[NB_BANDS]int, bits_left: int, ch: int) {
	left := bits_left
	for prio in 0 ..< 2 {
		for i := start; i < end && left >= ch; i += 1 {
			if fine_quant[i] >= MAX_FINE_BITS || fine_priority[i] != prio do continue
			for k in 0 ..< ch {
				q2 := range_bits(r, 1)
				c.band_e[k][i] += (f32(q2) - 0.5) * f32(i32(1) << uint(14 - fine_quant[i] - 1)) * (1.0 / 16384)
				left -= 1
			}
		}
	}
}

// Per-band changes of time/frequency resolution (RFC 6716 4.3.4.5).
@(private)
tf_decode :: proc(r: ^Range_Decoder, start, end: int, transient: bool, tf_res: ^[NB_BANDS]int, lm: int) {
	budget := len(r.data) * 8
	tell := range_tell(r)
	logp: uint = transient ? 2 : 4
	select_rsv := lm > 0 && tell + int(logp) + 1 <= budget ? 1 : 0
	budget -= select_rsv
	changed, curr := 0, 0
	for i in start ..< end {
		if tell + int(logp) <= budget {
			curr ~= int(range_bit_logp(r, logp))
			tell = range_tell(r)
			changed |= curr
		}
		tf_res[i] = curr
		logp = transient ? 4 : 5
	}
	t := transient ? 4 : 0
	tf_select := 0
	if select_rsv != 0 && TF_SELECT[lm][t + changed] != TF_SELECT[lm][t + 2 + changed] do tf_select = int(range_bit_logp(r, 1))
	for i in start ..< end do tf_res[i] = int(TF_SELECT[lm][t + 2 * tf_select + tf_res[i]])
}

// Band amplitudes back onto the normalised spectrum: amplitude
// 2^(log energy + mean) per band, zero above the coded bands.
@(private)
denormalise :: proc(x: []f32, freq: []f32, band_e: ^[NB_BANDS]f32, start, end, m: int, silence: bool) {
	n := m * SHORT_MDCT
	bound := m * int(EBANDS[end])
	s, e := start, end
	if silence do bound, s, e = 0, 0, 0
	for i in 0 ..< m * int(EBANDS[s]) do freq[i] = 0
	for i in s ..< e {
		lg := band_e[i] + E_MEANS[i]
		g := f32(math.exp(0.6931471805599453094 * f64(min(32, lg))))
		for j in m * int(EBANDS[i]) ..< m * int(EBANDS[i + 1]) do freq[j] = x[j] * g
	}
	for i in bound ..< n do freq[i] = 0
}

@(private)
synthesis :: proc(c: ^Celt, start, end, ch, cc: int, transient: bool, lm: int, silence: bool) {
	m := 1 << uint(lm)
	n := m * SHORT_MDCT
	b, nb, shift := 1, n, MAX_LM - lm
	if transient do b, nb, shift = m, SHORT_MDCT, MAX_LM
	if cc == 2 && ch == 1 {
		// A mono stream to both outputs.
		denormalise(c.x[0][:n], c.freq[0][:n], &c.band_e[0], start, end, m, silence)
		c.freq[1] = c.freq[0]
	} else if cc == 1 && ch == 2 {
		denormalise(c.x[0][:n], c.freq[0][:n], &c.band_e[0], start, end, m, silence)
		denormalise(c.x[1][:n], c.freq[1][:n], &c.band_e[1], start, end, m, silence)
		for i in 0 ..< n do c.freq[0][i] = 0.5 * c.freq[0][i] + 0.5 * c.freq[1][i]
	} else {
		for k in 0 ..< cc do denormalise(c.x[k][:n], c.freq[k][:n], &c.band_e[k], start, end, m, silence)
	}
	for k in 0 ..< cc {
		out := c.history[k][DECODE_BUFFER - n:]
		for blk in 0 ..< b do imdct(&mdct_tables, c.freq[k][blk:], b, out[nb * blk:], shift, &c.fft)
	}
}

@(private, rodata)
COMB_GAINS := [3][3]f32{{0.3066406250, 0.2170410156, 0.1296386719}, {0.4638671875, 0.2680664062, 0}, {0.7998046875, 0.1000976562, 0}}

// The pitch postfilter (RFC 6716 4.3.7.1): a 5-tap comb at period t on
// x[at ..< at + n] in place, cross-faded over the overlap from the previous
// filter (t0, g0, tapset0) to the new one.
@(private)
comb_filter :: proc(x: []f32, at, period0, period1, n: int, g0, g1: f32, tapset0, tapset1: int) {
	GAINS := &COMB_GAINS
	if g0 == 0 && g1 == 0 do return
	t0, t1 := max(period0, COMBFILTER_MINPERIOD), max(period1, COMBFILTER_MINPERIOD)
	g00, g01, g02 := g0 * GAINS[tapset0][0], g0 * GAINS[tapset0][1], g0 * GAINS[tapset0][2]
	g10, g11, g12 := g1 * GAINS[tapset1][0], g1 * GAINS[tapset1][1], g1 * GAINS[tapset1][2]
	overlap := OVERLAP
	if g0 == g1 && t0 == t1 && tapset0 == tapset1 do overlap = 0
	// The filter reads x before `at` (the history), and its own output: the
	// taps lag by at least COMBFILTER_MINPERIOD > 2.
	x1, x2, x3, x4 := x[at - t1 + 1], x[at - t1], x[at - t1 - 1], x[at - t1 - 2]
	i := 0
	#no_bounds_check for ; i < overlap; i += 1 {
		p := at + i
		x0 := x[p - t1 + 2]
		f := WINDOW[i] * WINDOW[i]
		x[p] = x[p] + (1 - f) * g00 * x[p - t0] + (1 - f) * g01 * (x[p - t0 + 1] + x[p - t0 - 1]) + (1 - f) * g02 * (x[p - t0 + 2] + x[p - t0 - 2]) + f * g10 * x2 + f * g11 * (x1 + x3) + f * g12 * (x0 + x4)
		x4, x3, x2, x1 = x3, x2, x1, x0
	}
	if g1 == 0 do return
	#no_bounds_check for ; i < n; i += 1 {
		p := at + i
		x[p] = x[p] + g10 * x[p - t1] + g11 * (x[p - t1 + 1] + x[p - t1 - 1]) + g12 * (x[p - t1 + 2] + x[p - t1 - 2])
	}
}

// The inverse of the encoder's pre-emphasis, a one-pole filter per channel,
// into interleaved output (or added to it: hybrid frames add CELT to SILK).
// Both channels per sample, so the writes are contiguous and the two
// filters' chains run side by side.
@(private)
deemphasis :: proc(c: ^Celt, pcm: []f32, n, cc: int, accumulate: bool) {
	at := DECODE_BUFFER - n
	if cc == 2 {
		l, r := c.history[0][at:][:n], c.history[1][at:][:n]
		ml, mr := c.preemph_mem[0], c.preemph_mem[1]
		out := pcm[:2 * n]
		#no_bounds_check for j in 0 ..< n {
			tl := l[j] + 1e-30 + ml
			tr := r[j] + 1e-30 + mr
			ml, mr = PREEMPH * tl, PREEMPH * tr
			if accumulate {
				out[2 * j] += tl * (1.0 / 32768)
				out[2 * j + 1] += tr * (1.0 / 32768)
			} else {
				out[2 * j], out[2 * j + 1] = tl * (1.0 / 32768), tr * (1.0 / 32768)
			}
		}
		c.preemph_mem = {ml, mr}
		return
	}
	x := c.history[0][at:][:n]
	mem := c.preemph_mem[0]
	#no_bounds_check for j in 0 ..< n {
		tmp := x[j] + 1e-30 + mem
		mem = PREEMPH * tmp
		if accumulate {pcm[j] += tmp * (1.0 / 32768)} else {pcm[j] = tmp * (1.0 / 32768)}
	}
	c.preemph_mem[0] = mem
}

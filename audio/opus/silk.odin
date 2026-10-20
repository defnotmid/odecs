package opus

// SILK (RFC 6716 4.2): linear-prediction speech coding at 8, 12 or 16 kHz,
// 10 or 20 ms frames, resampled to 48 kHz. All fixed point and so exact:
// each channel decodes its side information and excitation pulses, turns
// them into gains, LPC and long-term (pitch) predictors, and synthesises;
// stereo is mid/side with a predictor.

@(private)
SILK_MAX_FRAME :: 320 // 20 ms at 16 kHz
@(private)
SILK_MAX_SUBFR :: 4
@(private)
SILK_MAX_SUBFR_LEN :: 80
@(private)
LPC_MAX :: 16
@(private)
LTP_ORDER :: 5
@(private)
SHELL_BLOCK :: 16

Signal_Type :: enum i8 {
	Inactive,
	Unvoiced,
	Voiced,
}

@(private)
Coding :: enum {
	Independent,
	Independent_No_LTP_Scaling,
	Conditional,
}

// What a frame's bitstream says (RFC 6716 4.2.7).
@(private)
Silk_Indices :: struct {
	gains:        [SILK_MAX_SUBFR]i8,
	ltp:          [SILK_MAX_SUBFR]i8,
	nlsf:         [LPC_MAX + 1]i8, // first stage, then the residuals
	lag:          i16,
	contour:      i8,
	signal:       Signal_Type,
	quant_offset: i8,
	nlsf_interp:  i8, // Q2; 4 is none
	periodicity:  i8,
	ltp_scale:    i8,
	seed:         i8,
}

// The predictors a frame decodes to.
@(private)
Silk_Params :: struct {
	pitch:     [SILK_MAX_SUBFR]i32,
	gains_q16: [SILK_MAX_SUBFR]i32,
	lpc_q12:   [2][LPC_MAX]i16, // first and second half of the frame
	ltp_q14:   [SILK_MAX_SUBFR * LTP_ORDER]i16,
	ltp_scale: i32, // Q14
}

// The upsampler from the internal rate to 48 kHz: 2x by all-pass
// sections, then fractional 8-tap interpolation (libopus's IIR_FIR).
@(private)
Resampler :: struct {
	iir:          [6]i32,
	fir:          [8]i16,
	delay:        [16]i16,
	inv_ratio:    i32, // Q16
	batch:        int,
	in_khz:       int,
	input_delay:  int,
}

@(private)
Silk_Channel :: struct {
	fs_khz:          int,
	nb_subfr:        int,
	frame_length:    int,
	subfr_length:    int,
	ltp_mem_length:  int,
	order:           int, // LPC order: 10 or 16
	codebook:        int, // NLSF codebook: 0 narrow/medium, 1 wide
	prev_gain_q16:   i32,
	exc_q14:         [SILK_MAX_FRAME]i32,
	lpc_state:       [LPC_MAX]i32, // Q14 synthesis history
	out:             [SILK_MAX_FRAME + 2 * SILK_MAX_SUBFR_LEN]i16, // output history for the pitch predictor
	lag_prev:        i32,
	last_gain:       i8,
	prev_nlsf_q15:   [LPC_MAX]i16,
	first_frame:     bool, // after a reset
	frames_decoded:  int,
	frames_per_packet: int,
	ec_prev_signal:  Signal_Type,
	ec_prev_lag:     i16,
	vad:             [3]bool,
	lbrr:            [3]bool,
	loss_count:      int,
	prev_signal:     Signal_Type,
	indices:         Silk_Indices,
	resampler:       Resampler,
	plc:             Silk_Plc,
	cng:             Silk_Cng,
}

@(private)
Silk :: struct {
	ch:                [2]Silk_Channel,
	pred_prev_q13:     [2]i16,
	mid, side:         [2]i16, // the last two samples, for stereo
	api_channels:      int,
	internal_channels: int,
	prev_mid_only:     bool,
}

@(private)
silk_reset_channel :: proc(c: ^Silk_Channel) {
	c^ = {
		prev_gain_q16 = 65536,
		first_frame   = true,
	}
}

@(private)
silk_init :: proc(s: ^Silk) {
	s^ = {}
	for &c in s.ch do silk_reset_channel(&c)
}

// Forgets the signal (on a switch from CELT), keeping the channel layout.
@(private)
silk_reset :: proc(s: ^Silk) {
	api, internal := s.api_channels, s.internal_channels
	silk_init(s)
	s.api_channels, s.internal_channels = api, internal
}

// The frame layout for a rate and frame duration; a rate change resets the
// predictors.
@(private)
silk_set_rate :: proc(c: ^Silk_Channel, fs_khz: int) {
	c.subfr_length = 5 * fs_khz
	frame_length := c.nb_subfr * c.subfr_length
	if c.fs_khz != fs_khz {
		resampler_init(&c.resampler, fs_khz)
		c.ltp_mem_length = 20 * fs_khz
		c.order = fs_khz == 16 ? 16 : 10
		c.codebook = fs_khz == 16 ? 1 : 0
		c.first_frame = true
		c.lag_prev = 100
		c.last_gain = 10
		c.prev_signal = .Inactive
		c.out = {}
		c.lpc_state = {}
	}
	c.fs_khz = fs_khz
	c.frame_length = frame_length
}

// What a SILK call decodes: the packet's frame, nothing (a lost frame,
// concealed in the last frame's rate and channels), or the packet's LBRR
// copy of the frame before it (forward error correction), concealed where
// it has none.
@(private)
Silk_Input :: enum u8 {
	Coded,
	Lost,
	Redundant,
}

// Decodes one SILK frame (10 or 20 ms) per channel from r, the next of the
// packet's frames, into out (interleaved, 48 kHz, api channels); returns
// the samples per channel. new_packet marks a packet's first call.
@(private)
silk_decode :: proc(s: ^Silk, r: ^Range_Decoder, fs_khz, payload_ms, internal, api: int, new_packet: bool, out: []f32, input := Silk_Input.Coded) -> int {
	lost, fec := input == .Lost, input == .Redundant
	if new_packet do for &c in s.ch[:internal] do c.frames_decoded = 0
	if internal > s.internal_channels do silk_reset_channel(&s.ch[1])
	ch0 := &s.ch[0]
	// Stereo to mono at the same rate: the right channel's resampler keeps
	// running on the mono signal.
	stereo_to_mono := internal == 1 && s.internal_channels == 2 && fs_khz == ch0.fs_khz
	if ch0.frames_decoded == 0 {
		for &c in s.ch[:internal] {
			switch payload_ms {
			case 10:
				c.frames_per_packet, c.nb_subfr = 1, 2
			case 20:
				c.frames_per_packet, c.nb_subfr = 1, 4
			case 40:
				c.frames_per_packet, c.nb_subfr = 2, 4
			case 60:
				c.frames_per_packet, c.nb_subfr = 3, 4
			}
			silk_set_rate(&c, fs_khz)
		}
	}
	if api == 2 && internal == 2 && (s.api_channels == 1 || s.internal_channels == 1) {
		s.pred_prev_q13 = {}
		s.side = {}
		s.ch[1].resampler = s.ch[0].resampler
	}
	s.api_channels, s.internal_channels = api, internal

	if !lost && ch0.frames_decoded == 0 {
		// VAD and LBRR flags for the packet, then the LBRR (redundant)
		// frames, which normal decoding parses and drops; error correction
		// decodes them instead, one per call.
		// Every channel's flags, then every channel's per-frame LBRR flags.
		lbrr_any: [2]bool
		for &c, n in s.ch[:internal] {
			for i in 0 ..< c.frames_per_packet do c.vad[i] = range_bit_logp(r, 1)
			lbrr_any[n] = range_bit_logp(r, 1)
		}
		for &c, n in s.ch[:internal] {
			c.lbrr = {}
			if lbrr_any[n] {
				if c.frames_per_packet == 1 {
					c.lbrr[0] = true
				} else {
					row := LBRR_FLAGS_ICDF[LBRR_FLAGS_ICDF_AT[c.frames_per_packet - 2]:]
					symbol := range_icdf(r, row, 8) + 1
					for i in 0 ..< c.frames_per_packet do c.lbrr[i] = symbol >> uint(i) & 1 != 0
				}
			}
		}
		if !fec do for i in 0 ..< ch0.frames_per_packet {
			for n in 0 ..< internal {
				c := &s.ch[n]
				if !c.lbrr[i] do continue
				if internal == 2 && n == 0 {
					pred: [2]i32
					stereo_decode_pred(r, &pred)
					if !s.ch[1].lbrr[i] do range_icdf(r, STEREO_MID_ONLY_ICDF[:], 8)
				}
				coding := i > 0 && c.lbrr[i - 1] ? Coding.Conditional : .Independent
				decode_indices(c, r, i, true, coding)
				pulses: [SILK_MAX_FRAME]i16
				decode_pulses(r, pulses[:], c.indices.signal, int(c.indices.quant_offset), c.frame_length)
			}
		}
	}
	pred: [2]i32
	mid_only := false
	frame := ch0.frames_decoded
	if internal == 2 && (input == .Coded || fec && ch0.lbrr[frame]) {
		stereo_decode_pred(r, &pred)
		side_coded := fec ? s.ch[1].lbrr[frame] : s.ch[1].vad[frame]
		if !side_coded do mid_only = range_icdf(r, STEREO_MID_ONLY_ICDF[:], 8) != 0
	} else if internal == 2 {
		pred = {i32(s.pred_prev_q13[0]), i32(s.pred_prev_q13[1])}
	}
	if internal == 2 && !mid_only && s.prev_mid_only {
		c := &s.ch[1]
		c.out = {}
		c.lpc_state = {}
		c.lag_prev = 100
		c.last_gain = 10
		c.prev_signal = .Inactive
		c.first_frame = true
	}
	// Each channel's frame, two samples of history ahead of it.
	pcm: [2][SILK_MAX_FRAME + 2]i16
	n_samples := ch0.frame_length
	has_side := !mid_only
	if input != .Coded do has_side = !s.prev_mid_only || internal == 2 && fec && s.ch[1].lbrr[s.ch[1].frames_decoded]
	for n in 0 ..< internal {
		c := &s.ch[n]
		if n == 0 || has_side {
			coding := Coding.Conditional
			frame_index := s.ch[0].frames_decoded - n
			if frame_index <= 0 {
				coding = .Independent
			} else if fec {
				coding = c.lbrr[frame_index - 1] ? .Conditional : .Independent
			} else if n > 0 && s.prev_mid_only {
				coding = .Independent_No_LTP_Scaling
			}
			// Correction conceals the frames without an LBRR copy.
			decode_frame(c, r, pcm[n][2:][:c.frame_length], coding, lost || fec && !c.lbrr[c.frames_decoded], fec)
		}
		c.frames_decoded += 1
	}
	if api == 2 && internal == 2 {
		stereo_to_lr(s, &pcm[0], &pcm[1], pred, ch0.fs_khz, n_samples)
	} else {
		pcm[0][0], pcm[0][1] = s.mid[0], s.mid[1]
		s.mid = {pcm[0][n_samples], pcm[0][n_samples + 1]}
	}
	// To 48 kHz.
	out_samples := n_samples * 48 / ch0.fs_khz
	resampled: [SILK_MAX_FRAME * 6]i16
	for n in 0 ..< min(api, internal) {
		resample(&s.ch[n].resampler, resampled[:out_samples], pcm[n][1:][:n_samples])
		for v, i in resampled[:out_samples] do out[i * api + n] = f32(v) * (1.0 / 32768)
	}
	if api == 2 && internal == 1 {
		if stereo_to_mono {
			resample(&s.ch[1].resampler, resampled[:out_samples], pcm[0][1:][:n_samples])
			for v, i in resampled[:out_samples] do out[2 * i + 1] = f32(v) * (1.0 / 32768)
		} else {
			for i in 0 ..< out_samples do out[2 * i + 1] = out[2 * i]
		}
	}
	if lost {
		// No gain clamping after a loss, not to bounce back from a fade.
		for &c in s.ch[:internal] do c.last_gain = 10
	} else {
		s.prev_mid_only = mid_only
	}
	return out_samples
}

@(private)
stereo_decode_pred :: proc(r: ^Range_Decoder, pred: ^[2]i32) {
	n := range_icdf(r, STEREO_PRED_JOINT_ICDF[:], 8)
	ix: [2][3]int
	ix[0][2] = n / 5
	ix[1][2] = n - 5 * ix[0][2]
	for k in 0 ..< 2 {
		ix[k][0] = range_icdf(r, UNIFORM3_ICDF[:], 8)
		ix[k][1] = range_icdf(r, UNIFORM5_ICDF[:], 8)
	}
	for k in 0 ..< 2 {
		ix[k][0] += 3 * ix[k][2]
		low := i32(STEREO_PRED_Q13[ix[k][0]])
		step := smulwb(i32(STEREO_PRED_Q13[ix[k][0] + 1]) - low, 6554) // 0.5 / 5 in Q16
		pred[k] = smlabb(low, step, i32(2 * ix[k][1] + 1))
	}
	pred[0] -= pred[1]
}

// Mid/side (with the side predicted from the mid) to left/right.
@(private)
stereo_to_lr :: proc(s: ^Silk, x1, x2: ^[SILK_MAX_FRAME + 2]i16, pred: [2]i32, fs_khz, n: int) {
	x1[0], x1[1] = s.mid[0], s.mid[1]
	x2[0], x2[1] = s.side[0], s.side[1]
	s.mid = {x1[n], x1[n + 1]}
	s.side = {x2[n], x2[n + 1]}
	pred0, pred1 := i32(s.pred_prev_q13[0]), i32(s.pred_prev_q13[1])
	interp := 8 * fs_khz
	denom := i32(65536) / i32(interp)
	delta0 := rshift_round(smulbb(pred[0] - pred0, denom), 16)
	delta1 := rshift_round(smulbb(pred[1] - pred1, denom), 16)
	for i in 0 ..< n {
		if i < interp {
			pred0 += delta0
			pred1 += delta1
		} else if i == interp {
			pred0, pred1 = pred[0], pred[1]
		}
		sum := (i32(x1[i]) + i32(x1[i + 2]) + (i32(x1[i + 1]) << 1)) << 9
		sum = smlawb(i32(x2[i + 1]) << 8, sum, pred0)
		sum = smlawb(sum, i32(x1[i + 1]) << 11, pred1)
		x2[i + 1] = sat16(rshift_round(sum, 8))
	}
	s.pred_prev_q13 = {i16(pred[0]), i16(pred[1])}
	for i in 1 ..= n {
		sum := i32(x1[i]) + i32(x2[i])
		diff := i32(x1[i]) - i32(x2[i])
		x1[i], x2[i] = sat16(sum), sat16(diff)
	}
}

// One channel's frame, decoded (from its LBRR copy if redundant) or (lost)
// concealed, with comfort noise.
@(private)
decode_frame :: proc(c: ^Silk_Channel, r: ^Range_Decoder, out: []i16, coding: Coding, lost: bool, redundant := false) {
	p: Silk_Params
	if c.fs_khz != c.plc.fs_khz {
		plc_reset(c)
		c.plc.fs_khz = c.fs_khz
	}
	if !lost {
		pulses: [SILK_MAX_FRAME]i16
		decode_indices(c, r, c.frames_decoded, redundant, coding)
		decode_pulses(r, pulses[:], c.indices.signal, int(c.indices.quant_offset), c.frame_length)
		decode_parameters(c, &p, coding)
		synthesize(c, &p, out, pulses[:c.frame_length])
	} else {
		plc_conceal(c, &p, out)
	}
	keep := c.ltp_mem_length - c.frame_length
	copy(c.out[:keep], c.out[c.frame_length:][:keep])
	copy(c.out[keep:][:c.frame_length], out)
	if !lost {
		plc_update(c, &p)
		c.loss_count = 0
		c.first_frame = false
	} else {
		c.loss_count += 1
	}
	cng(c, &p, out)
	glue_frames(c, out)
	c.lag_prev = p.pitch[c.nb_subfr - 1]
}

// Side information (RFC 6716 4.2.7.3 - 4.2.7.6).
@(private)
decode_indices :: proc(c: ^Silk_Channel, r: ^Range_Decoder, frame: int, lbrr: bool, coding: Coding) {
	ix := &c.indices
	t := lbrr || c.vad[frame] ? range_icdf(r, TYPE_OFFSET_VAD_ICDF[:], 8) + 2 : range_icdf(r, TYPE_OFFSET_NO_VAD_ICDF[:], 8)
	ix.signal = Signal_Type(t >> 1)
	ix.quant_offset = i8(t & 1)
	if coding == .Conditional {
		ix.gains[0] = i8(range_icdf(r, DELTA_GAIN_ICDF[:], 8))
	} else {
		ix.gains[0] = i8(range_icdf(r, GAIN_ICDF[ix.signal][:], 8) << 3)
		ix.gains[0] += i8(range_icdf(r, UNIFORM8_ICDF[:], 8))
	}
	for i in 1 ..< c.nb_subfr do ix.gains[i] = i8(range_icdf(r, DELTA_GAIN_ICDF[:], 8))
	// NLSFs: a first-stage vector, then per-coefficient residuals.
	cb := c.codebook
	first := NLSF_CB1_ICDF[int(NLSF_CB1_ICDF_AT[cb]) + (int(ix.signal) >> 1) * 32:]
	ix.nlsf[0] = i8(range_icdf(r, first, 8))
	ec_ix: [LPC_MAX]i16
	pred_q8: [LPC_MAX]u8
	nlsf_unpack(&ec_ix, &pred_q8, cb, c.order, int(ix.nlsf[0]))
	ec_icdf := NLSF_CB2_ICDF[NLSF_CB2_ICDF_AT[cb]:]
	for i in 0 ..< c.order {
		v := range_icdf(r, ec_icdf[ec_ix[i]:], 8)
		if v == 0 {
			v -= range_icdf(r, NLSF_EXT_ICDF[:], 8)
		} else if v == 8 {
			v += range_icdf(r, NLSF_EXT_ICDF[:], 8)
		}
		ix.nlsf[i + 1] = i8(v - 4)
	}
	ix.nlsf_interp = c.nb_subfr == SILK_MAX_SUBFR ? i8(range_icdf(r, NLSF_INTERP_ICDF[:], 8)) : 4
	if ix.signal == .Voiced {
		absolute := true
		if coding == .Conditional && c.ec_prev_signal == .Voiced {
			delta := range_icdf(r, PITCH_DELTA_ICDF[:], 8)
			if delta > 0 {
				ix.lag = c.ec_prev_lag + i16(delta - 9)
				absolute = false
			}
		}
		if absolute {
			ix.lag = i16(range_icdf(r, PITCH_LAG_ICDF[:], 8) * (c.fs_khz >> 1))
			low: []u8
			switch c.fs_khz {
			case 16:
				low = UNIFORM8_ICDF[:]
			case 12:
				low = UNIFORM6_ICDF[:]
			case:
				low = UNIFORM4_ICDF[:]
			}
			ix.lag += i16(range_icdf(r, low, 8))
		}
		c.ec_prev_lag = ix.lag
		ix.contour = i8(range_icdf(r, PITCH_CONTOUR_ICDF[PITCH_CONTOUR_ICDF_AT[contour_table(c)]:], 8))
		ix.periodicity = i8(range_icdf(r, LTP_PER_INDEX_ICDF[:], 8))
		gains := LTP_GAIN_ICDF[LTP_GAIN_ICDF_AT[ix.periodicity]:]
		for k in 0 ..< c.nb_subfr do ix.ltp[k] = i8(range_icdf(r, gains, 8))
		ix.ltp_scale = coding == .Independent ? i8(range_icdf(r, LTP_SCALE_ICDF[:], 8)) : 0
	}
	c.ec_prev_signal = ix.signal
	ix.seed = i8(range_icdf(r, UNIFORM4_ICDF[:], 8))
}

// The pitch contour and lag codebook row: 20/10 ms, wide/narrow band.
@(private)
contour_table :: #force_inline proc(c: ^Silk_Channel) -> int {
	return (c.fs_khz == 8 ? 1 : 0) + (c.nb_subfr == 2 ? 2 : 0)
}

@(private)
nlsf_unpack :: proc(ec_ix: ^[LPC_MAX]i16, pred_q8: ^[LPC_MAX]u8, cb, order, index: int) {
	sel := NLSF_CB2_SELECT[int(NLSF_CB2_SELECT_AT[cb]) + index * order / 2:]
	pred := NLSF_PRED_Q8[NLSF_PRED_Q8_AT[cb]:]
	for i := 0; i < order; i += 2 {
		entry := sel[i / 2]
		ec_ix[i] = i16((entry >> 1) & 7) * 9
		pred_q8[i] = pred[i + int(entry & 1) * (order - 1)]
		ec_ix[i + 1] = i16((entry >> 5) & 7) * 9
		pred_q8[i + 1] = pred[i + int((entry >> 4) & 1) * (order - 1) + 1]
	}
}

// Excitation pulses (RFC 6716 4.2.7.8): per 16-sample block a pulse count,
// split down a binary tree, extra LSBs, then signs.
@(private)
decode_pulses :: proc(r: ^Range_Decoder, pulses: []i16, signal: Signal_Type, quant_offset, frame_length: int) {
	rate := range_icdf(r, RATE_LEVELS_ICDF[int(signal) >> 1][:], 8)
	blocks := (frame_length + SHELL_BLOCK - 1) / SHELL_BLOCK
	sums, lsbs: [SILK_MAX_FRAME / SHELL_BLOCK + 1]int
	for b in 0 ..< blocks {
		sums[b] = range_icdf(r, PULSES_PER_BLOCK_ICDF[rate][:], 8)
		for sums[b] == 17 {
			lsbs[b] += 1
			sums[b] = range_icdf(r, PULSES_PER_BLOCK_ICDF[9][lsbs[b] == 10 ? 1 : 0:], 8)
		}
	}
	for b in 0 ..< blocks {
		block := pulses[b * SHELL_BLOCK:][:SHELL_BLOCK]
		shell_split(r, block, sums[b], 3)
	}
	for b in 0 ..< blocks {
		if lsbs[b] == 0 do continue
		for &q in pulses[b * SHELL_BLOCK:][:SHELL_BLOCK] {
			v := i32(q)
			for _ in 0 ..< lsbs[b] do v = v << 1 + i32(range_icdf(r, LSB_ICDF[:], 8))
			q = i16(v)
		}
		sums[b] |= lsbs[b] << 5
	}
	// Signs, by how likely a pulse is to be negative.
	signs := SIGN_ICDF[7 * (quant_offset + (int(signal) << 1)):]
	for b in 0 ..< (frame_length + SHELL_BLOCK / 2) >> 4 {
		p := sums[b]
		if p <= 0 do continue
		icdf := [2]u8{signs[min(p & 0x1F, 6)], 0}
		for &q in pulses[b * SHELL_BLOCK:][:SHELL_BLOCK] {
			if q > 0 do q *= i16(range_icdf(r, icdf[:], 8) << 1 - 1)
		}
	}
}

// Splits `count` pulses over x (2^(level+1) samples), the left half first.
@(private)
shell_split :: proc(r: ^Range_Decoder, x: []i16, count, level: int) {
	if level < 0 {
		x[0] = i16(count)
		return
	}
	half := len(x) / 2
	left := 0
	if count > 0 do left = range_icdf(r, SHELL_ICDF[level][SHELL_OFFSETS[count]:], 8)
	shell_split(r, x[:half], left, level - 1)
	shell_split(r, x[half:], count - left, level - 1)
}

// Gains, LPC and LTP predictors from the indices (RFC 6716 4.2.7.4 -
// 4.2.7.6).
@(private)
decode_parameters :: proc(c: ^Silk_Channel, p: ^Silk_Params, coding: Coding) {
	ix := &c.indices
	// Gains: the first absolute or relative, then relative, in Q7 log.
	OFFSET :: (2 * 128) / 6 + 16 * 128
	INV_SCALE_Q16 :: (65536 * (((88 - 2) * 128) / 6)) / (64 - 1)
	for k in 0 ..< c.nb_subfr {
		if k == 0 && coding != .Conditional {
			c.last_gain = max(ix.gains[k], c.last_gain - 16)
		} else {
			delta := i32(ix.gains[k]) - 4
			threshold := 2 * 36 - 64 + i32(c.last_gain)
			if delta > threshold {
				c.last_gain += i8((delta << 1) - threshold)
			} else {
				c.last_gain += i8(delta)
			}
		}
		c.last_gain = clamp(c.last_gain, 0, 63)
		p.gains_q16[k] = log2lin(min(smulwb(INV_SCALE_Q16, i32(c.last_gain)) + OFFSET, 3967))
	}
	nlsf: [LPC_MAX]i16
	nlsf_decode(&nlsf, ix, c.codebook, c.order)
	nlsf_to_lpc(&p.lpc_q12[1], nlsf[:c.order])
	if c.first_frame do ix.nlsf_interp = 4
	if ix.nlsf_interp < 4 {
		// The first half of the frame from NLSFs between the last frame's and this one's.
		mixed: [LPC_MAX]i16
		for i in 0 ..< c.order {
			mixed[i] = c.prev_nlsf_q15[i] + i16((i32(ix.nlsf_interp) * (i32(nlsf[i]) - i32(c.prev_nlsf_q15[i]))) >> 2)
		}
		nlsf_to_lpc(&p.lpc_q12[0], mixed[:c.order])
	} else {
		p.lpc_q12[0] = p.lpc_q12[1]
	}
	copy(c.prev_nlsf_q15[:c.order], nlsf[:c.order])
	if c.loss_count != 0 {
		// Back from a loss: widen the bandwidths.
		bwexpander16(p.lpc_q12[0][:c.order], 63570)
		bwexpander16(p.lpc_q12[1][:c.order], 63570)
	}
	if ix.signal != .Voiced {
		p.pitch = {}
		p.ltp_q14 = {}
		ix.periodicity = 0
		p.ltp_scale = 0
		return
	}
	// Pitch lags: a base lag plus a contour across subframes.
	table := contour_table(c)
	cb := PITCH_LAG_CB[PITCH_LAG_CB_AT[table]:PITCH_LAG_CB_AT[table + 1]]
	size := len(cb) / c.nb_subfr
	min_lag, max_lag := i32(2 * c.fs_khz), i32(18 * c.fs_khz)
	for k in 0 ..< c.nb_subfr {
		p.pitch[k] = clamp(min_lag + i32(ix.lag) + i32(cb[k * size + int(ix.contour)]), min_lag, max_lag)
	}
	vq := LTP_VQ_Q7[int(LTP_VQ_Q7_AT[ix.periodicity]) * LTP_ORDER:]
	for k in 0 ..< c.nb_subfr do for i in 0 ..< LTP_ORDER {
		p.ltp_q14[k * LTP_ORDER + i] = i16(vq[int(ix.ltp[k]) * LTP_ORDER + i]) << 7
	}
	p.ltp_scale = i32(LTP_SCALES_Q14[ix.ltp_scale])
}

// NLSFs (Q15) from the first-stage vector and the residuals.
@(private)
nlsf_decode :: proc(nlsf: ^[LPC_MAX]i16, ix: ^Silk_Indices, cb, order: int) {
	ec_ix: [LPC_MAX]i16
	pred_q8: [LPC_MAX]u8
	first := int(ix.nlsf[0])
	nlsf_unpack(&ec_ix, &pred_q8, cb, order, first)
	// Residuals, backwards: each predicted from the next.
	res_q10: [LPC_MAX]i16
	step := NLSF_STEP_Q16[cb]
	out: i32
	for i := order - 1; i >= 0; i -= 1 {
		pred := smulbb(out, i32(pred_q8[i])) >> 8
		out = i32(ix.nlsf[i + 1]) << 10
		if out > 0 {
			out -= 102 // 0.1 in Q10
		} else if out < 0 {
			out += 102
		}
		out = smlawb(pred, out, step)
		res_q10[i] = i16(out)
	}
	vec := NLSF_CB1_Q8[int(NLSF_CB1_Q8_AT[cb]) + first * order:]
	weights := NLSF_CB1_WGHT_Q9[int(NLSF_CB1_WGHT_Q9_AT[cb]) + first * order:]
	for i in 0 ..< order {
		v := ((i32(res_q10[i]) << 14) / i32(weights[i])) + (i32(vec[i]) << 7)
		nlsf[i] = i16(clamp(v, 0, 32767))
	}
	nlsf_stabilize(nlsf[:order], NLSF_DELTA_MIN_Q15[NLSF_DELTA_MIN_Q15_AT[cb]:][:order + 1])
}

// Keeps NLSFs apart by at least the minimum distances (RFC 6716 4.2.7.5.4).
@(private)
nlsf_stabilize :: proc(nlsf: []i16, delta_min: []i16) {
	n := len(nlsf)
	for _ in 0 ..< 20 {
		// The closest pair (or edge).
		min_diff := i32(nlsf[0]) - i32(delta_min[0])
		at := 0
		for i in 1 ..< n {
			d := i32(nlsf[i]) - (i32(nlsf[i - 1]) + i32(delta_min[i]))
			if d < min_diff {min_diff, at = d, i}
		}
		d := i32(1 << 15) - (i32(nlsf[n - 1]) + i32(delta_min[n]))
		if d < min_diff {min_diff, at = d, n}
		if min_diff >= 0 do return
		switch at {
		case 0:
			nlsf[0] = delta_min[0]
		case n:
			nlsf[n - 1] = i16(i32(1 << 15) - i32(delta_min[n]))
		case:
			lo: i32 = 0
			for k in 0 ..< at do lo += i32(delta_min[k])
			lo += i32(delta_min[at]) >> 1
			hi: i32 = 1 << 15
			for k := n; k > at; k -= 1 do hi -= i32(delta_min[k])
			hi -= i32(delta_min[at]) >> 1
			center := i16(clamp(rshift_round(i32(nlsf[at - 1]) + i32(nlsf[at]), 1), lo, hi))
			nlsf[at - 1] = center - (delta_min[at] >> 1)
			nlsf[at] = nlsf[at - 1] + delta_min[at]
		}
	}
	// Still too close: sort and push apart.
	for i in 1 ..< n {
		v := nlsf[i]
		j := i - 1
		for ; j >= 0 && nlsf[j] > v; j -= 1 do nlsf[j + 1] = nlsf[j]
		nlsf[j + 1] = v
	}
	nlsf[0] = max(nlsf[0], delta_min[0])
	for i in 1 ..< n do nlsf[i] = i16(max(i32(nlsf[i]), i32(sat16(i32(nlsf[i - 1]) + i32(delta_min[i])))))
	nlsf[n - 1] = i16(min(i32(nlsf[n - 1]), i32(1 << 15) - i32(delta_min[n])))
	for i := n - 2; i >= 0; i -= 1 do nlsf[i] = i16(min(i32(nlsf[i]), i32(nlsf[i + 1]) - i32(delta_min[i + 1])))
}

// NLSFs to LPC coefficients (Q12), stable (RFC 6716 4.2.7.5.6 - 4.2.7.5.8).
@(private)
nlsf_to_lpc :: proc(a_q12: ^[LPC_MAX]i16, nlsf: []i16) {
	@(static, rodata)
	ORDERING16 := [16]u8{0, 15, 8, 7, 4, 11, 12, 3, 2, 13, 10, 5, 6, 9, 14, 1}
	@(static, rodata)
	ORDERING10 := [10]u8{0, 9, 6, 3, 4, 5, 8, 1, 2, 7}
	QA :: 16
	d := len(nlsf)
	ordering := d == 16 ? ORDERING16[:] : ORDERING10[:]
	cos_lsf: [LPC_MAX]i32
	for k in 0 ..< d {
		f_int := i32(nlsf[k]) >> 8
		f_frac := i32(nlsf[k]) - (f_int << 8)
		c := i32(LSF_COS_Q12[f_int])
		delta := i32(LSF_COS_Q12[f_int + 1]) - c
		cos_lsf[ordering[k]] = rshift_round((c << 8) + delta * f_frac, 20 - QA)
	}
	// The symmetric and antisymmetric polynomials.
	find_poly :: proc(out: []i32, c_lsf: []i32, dd: int) {
		out[0] = 1 << QA
		out[1] = -c_lsf[0]
		for k in 1 ..< dd {
			f := c_lsf[2 * k]
			out[k + 1] = (out[k - 1] << 1) - i32(rshift_round64(i64(f) * i64(out[k]), QA))
			for n := k; n > 1; n -= 1 do out[n] += out[n - 2] - i32(rshift_round64(i64(f) * i64(out[n - 1]), QA))
			out[1] -= f
		}
	}
	dd := d >> 1
	p, q: [LPC_MAX / 2 + 1]i32
	find_poly(p[:], cos_lsf[:], dd)
	find_poly(q[:], cos_lsf[1:], dd)
	a32: [LPC_MAX]i32
	for k in 0 ..< dd {
		pt := p[k + 1] + p[k]
		qt := q[k + 1] - q[k]
		a32[k] = -qt - pt
		a32[d - k - 1] = qt - pt
	}
	lpc_fit(a_q12[:d], a32[:d], 12, QA + 1)
	for i := 0; lpc_inverse_pred_gain(a_q12[:d]) == 0 && i < 16; i += 1 {
		bwexpander32(a32[:d], 65536 - (i32(2) << uint(i)))
		for k in 0 ..< d do a_q12[k] = i16(rshift_round(a32[k], QA + 1 - 12))
	}
}

// Rounds a QIN filter to QOUT 16-bit coefficients, widening its bandwidth
// until they fit.
@(private)
lpc_fit :: proc(a_out: []i16, a_in: []i32, qout, qin: uint) {
	i := 0
	for ; i < 10; i += 1 {
		maxabs: i32
		idx := 0
		for v, k in a_in {
			if abs(v) > maxabs {maxabs, idx = abs(v), k}
		}
		maxabs = rshift_round(maxabs, qin - qout)
		if maxabs <= 32767 do break
		maxabs = min(maxabs, 163838)
		chirp := i32(65470) - ((maxabs - 32767) << 14) / ((maxabs * i32(idx + 1)) >> 2) // 0.999 in Q16
		bwexpander32(a_in, chirp)
	}
	if i == 10 {
		for k in 0 ..< len(a_in) {
			a_out[k] = sat16(rshift_round(a_in[k], qin - qout))
			a_in[k] = i32(a_out[k]) << (qin - qout)
		}
	} else {
		for k in 0 ..< len(a_in) do a_out[k] = i16(rshift_round(a_in[k], qin - qout))
	}
}

@(private)
bwexpander32 :: proc(ar: []i32, chirp_q16: i32) {
	chirp := chirp_q16
	minus_one := chirp - 65536
	for i in 0 ..< len(ar) - 1 {
		ar[i] = smulww(chirp, ar[i])
		chirp += rshift_round(chirp * minus_one, 16)
	}
	ar[len(ar) - 1] = smulww(chirp, ar[len(ar) - 1])
}

// 1/prediction gain in Q30, or 0 when the filter is unstable.
@(private)
lpc_inverse_pred_gain :: proc(a_q12: []i16) -> i32 {
	QA :: 24
	A_LIMIT :: i32(16773022) // 0.99975 in Q24
	a: [LPC_MAX]i32
	dc: i32
	for v, k in a_q12 {
		dc += i32(v)
		a[k] = i32(v) << (QA - 12)
	}
	if dc >= 4096 do return 0
	inv_gain: i32 = 1 << 30
	order := len(a_q12)
	for k := order - 1; k > 0; k -= 1 {
		if a[k] > A_LIMIT || a[k] < -A_LIMIT do return 0
		rc := -(a[k] << (31 - QA))
		rc_mult1 := (i32(1) << 30) - smmul(rc, rc)
		inv_gain = smmul(inv_gain, rc_mult1) << 2
		if inv_gain < 107374 do return 0 // 1 / MAX_PREDICTION_POWER_GAIN in Q30
		mult2q := 32 - clz32(abs(rc_mult1))
		rc_mult2 := inverse32_varq(rc_mult1, mult2q + 30)
		for n in 0 ..< (k + 1) >> 1 {
			t1, t2 := a[n], a[k - n - 1]
			v := rshift_round64(i64(sub_sat32(t1, i32(rshift_round64(i64(t2) * i64(rc), 31)))) * i64(rc_mult2), mult2q)
			if v > i64(max(i32)) || v < i64(min(i32)) do return 0
			a[n] = i32(v)
			v = rshift_round64(i64(sub_sat32(t2, i32(rshift_round64(i64(t1) * i64(rc), 31)))) * i64(rc_mult2), mult2q)
			if v > i64(max(i32)) || v < i64(min(i32)) do return 0
			a[k - n - 1] = i32(v)
		}
	}
	if a[0] > A_LIMIT || a[0] < -A_LIMIT do return 0
	rc := -(a[0] << (31 - QA))
	rc_mult1 := (i32(1) << 30) - smmul(rc, rc)
	inv_gain = smmul(inv_gain, rc_mult1) << 2
	if inv_gain < 107374 do return 0
	return inv_gain
}

// Excitation through the long-term (pitch) and short-term (LPC) synthesis
// filters (RFC 6716 4.2.7.9).
@(private)
synthesize :: proc(c: ^Silk_Channel, p: ^Silk_Params, xq: []i16, pulses: []i16) {
	ix := &c.indices
	offset := i32(QUANT_OFFSETS_Q10[int(ix.signal) >> 1][ix.quant_offset])
	nlsf_interpolated := ix.nlsf_interp < 4
	// Excitation from the pulses, offset and pseudo-randomly signed.
	seed := i32(ix.seed)
	for i in 0 ..< c.frame_length {
		seed = silk_rand(seed)
		e := i32(pulses[i]) << 14
		if e > 0 {
			e -= 80 << 4
		} else if e < 0 {
			e += 80 << 4
		}
		e += offset << 4
		if seed < 0 do e = -e
		c.exc_q14[i] = e
		seed += i32(pulses[i])
	}
	lpc: [SILK_MAX_SUBFR_LEN + LPC_MAX]i32
	copy(lpc[:LPC_MAX], c.lpc_state[:])
	ltp_res: [2 * SILK_MAX_FRAME]i16 // the LPC residual of the past output
	ltp_q15: [2 * SILK_MAX_FRAME]i32 // ltp_mem_length + frame_length
	ltp_at := c.ltp_mem_length
	order := c.order
	for k in 0 ..< c.nb_subfr {
		sub := c.subfr_length
		// The LPC input: the excitation, plus the pitch prediction when voiced
		// (the excitation itself stays for concealment and comfort noise).
		exc := c.exc_q14[k * sub:][:sub]
		res_buf: [SILK_MAX_SUBFR_LEN]i32
		out := xq[k * sub:][:sub]
		a := p.lpc_q12[k >> 1]
		b := p.ltp_q14[k * LTP_ORDER:][:LTP_ORDER]
		signal := ix.signal
		gain_q10 := p.gains_q16[k] >> 6
		inv_gain := inverse32_varq(p.gains_q16[k], 47)
		gain_adj: i32 = 1 << 16
		if p.gains_q16[k] != c.prev_gain_q16 {
			gain_adj = div32_varq(c.prev_gain_q16, p.gains_q16[k], 16)
			for &v in lpc[:LPC_MAX] do v = smulww(gain_adj, v)
		}
		c.prev_gain_q16 = p.gains_q16[k]
		if c.loss_count != 0 && c.prev_signal == .Voiced && signal != .Voiced && k < SILK_MAX_SUBFR / 2 {
			// From concealed voicing into unvoiced: a soft pitch tail.
			for &t in b do t = 0
			b[LTP_ORDER / 2] = 4096 // 0.25 in Q14
			signal = .Voiced
			p.pitch[k] = c.lag_prev
		}
		if signal == .Voiced {
			lag := p.pitch[k]
			if k == 0 || (k == 2 && nlsf_interpolated) {
				// Re-whiten the past output with this subframe's LPC.
				start := c.ltp_mem_length - int(lag) - order - LTP_ORDER / 2
				if k == 2 do copy(c.out[c.ltp_mem_length:][:2 * sub], xq[:2 * sub])
				lpc_analysis(ltp_res[start:c.ltp_mem_length], c.out[start + k * sub:][:c.ltp_mem_length - start], a[:order])
				if k == 0 do inv_gain = smulwb(inv_gain, p.ltp_scale) << 2
				for i in 0 ..< int(lag) + LTP_ORDER / 2 {
					ltp_q15[ltp_at - i - 1] = smulwb(inv_gain, i32(ltp_res[c.ltp_mem_length - i - 1]))
				}
			} else if gain_adj != 1 << 16 {
				for i in 0 ..< int(lag) + LTP_ORDER / 2 do ltp_q15[ltp_at - i - 1] = smulww(gain_adj, ltp_q15[ltp_at - i - 1])
			}
			// Long-term prediction: a 5-tap filter around the lag.
			pred_at := ltp_at - int(lag) + LTP_ORDER / 2
			for i in 0 ..< sub {
				v: i32 = 2
				#unroll for t in 0 ..< LTP_ORDER do v = smlawb(v, ltp_q15[pred_at + i - t], i32(b[t]))
				res_buf[i] = exc[i] + (v << 1)
				ltp_q15[ltp_at] = res_buf[i] << 1
				ltp_at += 1
			}
			exc = res_buf[:sub]
		}
		// Short-term prediction.
		for i in 0 ..< sub {
			v := i32(order >> 1)
			hist := lpc[LPC_MAX + i - order:][:order]
			for t in 0 ..< order do v = smlawb(v, hist[order - 1 - t], i32(a[t]))
			lpc[LPC_MAX + i] = add_sat32(exc[i], lshift_sat32(v, 4))
			out[i] = sat16(rshift_round(smulww(lpc[LPC_MAX + i], gain_q10), 8))
		}
		copy(lpc[:LPC_MAX], lpc[sub:][:LPC_MAX])
	}
	copy(c.lpc_state[:], lpc[:LPC_MAX])
}

// out = the LPC residual of x (out[:order] zero), in Q0.
@(private)
lpc_analysis :: proc(out: []i16, x: []i16, b: []i16) {
	d := len(b)
	for ix in d ..< len(out) {
		acc: i32
		for j in 0 ..< d do acc += i32(x[ix - 1 - j]) * i32(b[j])
		acc = (i32(x[ix]) << 12) - acc
		out[ix] = sat16(rshift_round(acc, 12))
	}
	for &v in out[:d] do v = 0
}

@(private)
resampler_init :: proc(s: ^Resampler, in_khz: int) {
	@(static, rodata)
	DELAY := [3]int{0, 4, 7} // 8, 12, 16 kHz to 48 kHz
	s^ = {
		in_khz      = in_khz,
		batch       = in_khz * 10,
		input_delay = DELAY[(in_khz - 8) / 4],
	}
	// Input samples per output in Q16 (doubled by the 2x stage).
	fs_in, fs_out := i32(in_khz * 1000), i32(48000)
	s.inv_ratio = ((fs_in << 15) / fs_out) << 2
	for smulww(s.inv_ratio, fs_out) < fs_in << 1 do s.inv_ratio += 1
}

// Upsamples x to 48 kHz into out (len(x) * 48 / in_khz samples).
@(private)
resample :: proc(s: ^Resampler, out: []i16, x: []i16) {
	// The first millisecond comes through the delay line.
	n := s.in_khz - s.input_delay
	copy(s.delay[s.input_delay:][:n], x[:n])
	resample_iir_fir(s, out[:48], s.delay[:s.in_khz])
	resample_iir_fir(s, out[48:], x[n:][:len(x) - s.in_khz])
	copy(s.delay[:s.input_delay], x[len(x) - s.input_delay:])
}

@(private)
resample_iir_fir :: proc(s: ^Resampler, out: []i16, input: []i16) {
	buf: [2 * 16 * 10 + 8]i16
	copy(buf[:8], s.fir[:])
	at := 0
	x := input
	for {
		n := min(len(x), s.batch)
		up2_hq(&s.iir, buf[8:][:2 * n], x[:n])
		// Fractional interpolation over the 2x signal.
		max_index := i32(n) << 17
		for index: i32 = 0; index < max_index; index += s.inv_ratio {
			phase := smulwb(index & 0xFFFF, 12)
			p := buf[index >> 16:]
			f, g := RESAMPLER_FRAC_FIR_12[phase], RESAMPLER_FRAC_FIR_12[11 - phase]
			acc := i32(p[0]) * i32(f[0]) + i32(p[1]) * i32(f[1]) + i32(p[2]) * i32(f[2]) + i32(p[3]) * i32(f[3])
			acc += i32(p[4]) * i32(g[3]) + i32(p[5]) * i32(g[2]) + i32(p[6]) * i32(g[1]) + i32(p[7]) * i32(g[0])
			out[at] = sat16(rshift_round(acc, 15))
			at += 1
		}
		x = x[n:]
		if len(x) == 0 {
			copy(s.fir[:], buf[2 * n:][:8])
			return
		}
		copy(buf[:8], buf[2 * n:][:8])
	}
}

// 2x upsampling by two chains of three all-pass sections.
@(private)
up2_hq :: proc(st: ^[6]i32, out: []i16, input: []i16) {
	c0, c1 := RESAMPLER_UP2_HQ[0], RESAMPLER_UP2_HQ[1]
	for v, k in input {
		x := i32(v) << 10
		for phase in 0 ..< 2 {
			c := phase == 0 ? c0 : c1
			s := st[3 * phase:][:3]
			y := x - s[0]
			t := smulwb(y, i32(c[0]))
			o1 := s[0] + t
			s[0] = x + t
			y = o1 - s[1]
			t = smulwb(y, i32(c[1]))
			o2 := s[1] + t
			s[1] = o1 + t
			y = o2 - s[2]
			t = smlawb(y, y, i32(c[2]))
			o1 = s[2] + t
			s[2] = o2 + t
			out[2 * k + phase] = sat16(rshift_round(o1, 10))
		}
	}
}

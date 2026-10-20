package opus

import "core:math/bits"

// SILK loss concealment and comfort noise (RFC 6716 4.2.8): good frames
// keep the last pitch, LTP, LPC and gains; a lost frame extrapolates them
// with decaying periodic and noise excitation; comfort noise follows the
// background between talk spurts and fills losses; the first good frame
// after a loss is ramped from the concealed energy.

@(private)
Silk_Plc :: struct {
	pitch_q8:        i32,
	ltp_q14:         [LTP_ORDER]i16,
	prev_lpc_q12:    [LPC_MAX]i16,
	last_lost:       bool,
	rand_seed:       i32,
	rand_scale_q14:  i16,
	conc_energy:     i32,
	conc_shift:      int,
	prev_ltp_scale:  i32, // Q14
	prev_gain_q16:   [2]i32,
	fs_khz:          int,
	nb_subfr:        int,
	subfr_length:    int,
}

@(private)
Silk_Cng :: struct {
	exc_q14:      [SILK_MAX_FRAME]i32,
	smooth_nlsf:  [LPC_MAX]i16, // Q15
	synth:        [LPC_MAX]i32,
	smooth_gain:  i32, // Q16
	rand_seed:    i32,
	fs_khz:       int,
}

@(private)
plc_reset :: proc(c: ^Silk_Channel) {
	c.plc.pitch_q8 = i32(c.frame_length) << 7
	c.plc.prev_gain_q16 = {65536, 65536}
	c.plc.subfr_length = 20
	c.plc.nb_subfr = 2
}

@(private)
cng_reset :: proc(c: ^Silk_Channel) {
	step := i32(32767) / i32(c.order + 1)
	acc: i32
	for i in 0 ..< c.order {
		acc += step
		c.cng.smooth_nlsf[i] = i16(acc)
	}
	c.cng.smooth_gain = 0
	c.cng.rand_seed = 3176576
}

// Keeps what concealment extrapolates from a good frame.
@(private)
plc_update :: proc(c: ^Silk_Channel, p: ^Silk_Params) {
	V_GAIN_MIN :: 11469 // 0.7 in Q14
	V_GAIN_MAX :: 15565 // 0.95 in Q14
	plc := &c.plc
	c.prev_signal = c.indices.signal
	ltp_gain: i32
	if c.indices.signal == .Voiced {
		// The strongest LTP filter of the subframes the last lag reaches.
		for j := 0; j * c.subfr_length < int(p.pitch[c.nb_subfr - 1]) && j < c.nb_subfr; j += 1 {
			taps := p.ltp_q14[(c.nb_subfr - 1 - j) * LTP_ORDER:][:LTP_ORDER]
			g: i32
			for t in taps do g += i32(t)
			if g > ltp_gain {
				ltp_gain = g
				plc.pitch_q8 = p.pitch[c.nb_subfr - 1 - j] << 8
			}
		}
		plc.ltp_q14 = {}
		plc.ltp_q14[LTP_ORDER / 2] = i16(ltp_gain)
		if ltp_gain < V_GAIN_MIN {
			scale := (i32(V_GAIN_MIN) << 10) / max(ltp_gain, 1)
			for &t in plc.ltp_q14 do t = i16(smulbb(i32(t), scale) >> 10)
		} else if ltp_gain > V_GAIN_MAX {
			scale := (i32(V_GAIN_MAX) << 14) / max(ltp_gain, 1)
			for &t in plc.ltp_q14 do t = i16(smulbb(i32(t), scale) >> 14)
		}
	} else {
		plc.pitch_q8 = i32(c.fs_khz * 18) << 8
		plc.ltp_q14 = {}
	}
	copy(plc.prev_lpc_q12[:c.order], p.lpc_q12[1][:c.order])
	plc.prev_ltp_scale = p.ltp_scale
	plc.prev_gain_q16 = {p.gains_q16[c.nb_subfr - 2], p.gains_q16[c.nb_subfr - 1]}
	plc.subfr_length = c.subfr_length
	plc.nb_subfr = c.nb_subfr
}

// The energy of x as a 32-bit value and a right shift.
@(private)
sum_sqr_shift :: proc(x: []i16) -> (energy: i32, shift: int) {
	accumulate :: proc(x: []i16, shift: uint) -> i32 {
		nrg: i32
		i := 0
		for ; i < len(x) - 1; i += 2 {
			t := u32(smulbb(i32(x[i]), i32(x[i])) + smulbb(i32(x[i + 1]), i32(x[i + 1])))
			nrg = i32(u32(nrg) + (t >> shift))
		}
		if i < len(x) do nrg = i32(u32(nrg) + (u32(smulbb(i32(x[i]), i32(x[i]))) >> shift))
		return nrg
	}
	s := 31 - clz32(i32(len(x)))
	nrg := i32(len(x)) + accumulate(x, s)
	s = uint(max(0, int(s) + 3 - int(clz32(nrg))))
	return accumulate(x, s), int(s)
}

@(private)
sqrt_approx :: proc(x: i32) -> i32 {
	if x <= 0 do return 0
	lz := i32(clz32(x))
	frac := i32(bits.rotate_left32(u32(x), int(lz) - 24)) & 0x7F // the 7 bits after the leading one
	y: i32 = lz & 1 != 0 ? 32768 : 46214
	y >>= uint(lz >> 1)
	return smlawb(y, y, smulbb(213, frac))
}

@(private)
bwexpander16 :: proc(ar: []i16, chirp_q16: i32) {
	chirp := chirp_q16
	minus_one := chirp - 65536
	for i in 0 ..< len(ar) - 1 {
		ar[i] = i16(rshift_round(chirp * i32(ar[i]), 16))
		chirp += rshift_round(chirp * minus_one, 16)
	}
	ar[len(ar) - 1] = i16(rshift_round(chirp * i32(ar[len(ar) - 1]), 16))
}

// A lost frame: the last pitch period and noise from the last excitation,
// through the last LPC filter, both decaying.
@(private)
plc_conceal :: proc(c: ^Silk_Channel, p: ^Silk_Params, frame: []i16) {
	@(static, rodata)
	HARM_ATT := [2]i32{32440, 31130}
	@(static, rodata)
	RAND_ATT_V := [2]i32{31130, 26214}
	@(static, rodata)
	RAND_ATT_UV := [2]i32{32440, 29491}
	RAND_BUF :: 128
	plc := &c.plc
	prev_gain_q10 := [2]i32{plc.prev_gain_q16[0] >> 6, plc.prev_gain_q16[1] >> 6}
	if c.first_frame do plc.prev_lpc_q12 = {}
	// Noise from the quieter of the last two subframes' excitation.
	exc_buf: [2 * SILK_MAX_SUBFR_LEN]i16
	sub := c.subfr_length
	for k in 0 ..< 2 do for i in 0 ..< sub {
		exc_buf[k * sub + i] = sat16(smulww(c.exc_q14[i + (k + c.nb_subfr - 2) * sub], prev_gain_q10[k]) >> 8)
	}
	e1, s1 := sum_sqr_shift(exc_buf[:sub])
	e2, s2 := sum_sqr_shift(exc_buf[sub:][:sub])
	rand_at := e1 >> uint(s2) < e2 >> uint(s1) ? max(0, (plc.nb_subfr - 1) * plc.subfr_length - RAND_BUF) : max(0, plc.nb_subfr * plc.subfr_length - RAND_BUF)
	rand_src := c.exc_q14[rand_at:]
	b := &plc.ltp_q14 // decays across lost frames
	rand_scale := plc.rand_scale_q14
	att := min(1, c.loss_count)
	harm_gain := HARM_ATT[att]
	rand_gain := c.prev_signal == .Voiced ? RAND_ATT_V[att] : RAND_ATT_UV[att]
	bwexpander16(plc.prev_lpc_q12[:c.order], 64881) // 0.99 in Q16
	a := plc.prev_lpc_q12
	if c.loss_count == 0 {
		rand_scale = 1 << 14
		if c.prev_signal == .Voiced {
			for t in b do rand_scale -= t
			rand_scale = max(3277, rand_scale)
			rand_scale = i16(smulbb(i32(rand_scale), plc.prev_ltp_scale) >> 14)
		} else {
			inv_gain := lpc_inverse_pred_gain(plc.prev_lpc_q12[:c.order])
			down := clamp(inv_gain, (i32(1) << 30) >> 8, (i32(1) << 30) >> 3) << 3
			rand_gain = smulwb(down, rand_gain) >> 14
		}
	}
	seed := plc.rand_seed
	lag := rshift_round(plc.pitch_q8, 8)
	at := c.ltp_mem_length
	start := c.ltp_mem_length - int(lag) - c.order - LTP_ORDER / 2
	// The past output re-whitened with the expanded LPC, then the pitch
	// prediction and noise continuing it.
	res: [SILK_MAX_FRAME]i16
	lpc_analysis(res[start:c.ltp_mem_length], c.out[start:][:c.ltp_mem_length - start], a[:c.order])
	inv_gain := min(inverse32_varq(plc.prev_gain_q16[1], 46), max(i32) >> 1)
	ltp: [2 * SILK_MAX_FRAME]i32 // Q14, ltp_mem_length + frame_length
	for i in start + c.order ..< c.ltp_mem_length do ltp[i] = smulwb(inv_gain, i32(res[i]))
	for _ in 0 ..< c.nb_subfr {
		pred_at := at - int(lag) + LTP_ORDER / 2
		for i in 0 ..< sub {
			v: i32 = 2
			#unroll for t in 0 ..< LTP_ORDER do v = smlawb(v, ltp[pred_at + i - t], i32(b[t]))
			seed = silk_rand(seed)
			idx := (seed >> 25) & (RAND_BUF - 1)
			ltp[at] = smlawb(v, rand_src[idx], i32(rand_scale)) << 2
			at += 1
		}
		for &t in b do t = i16(smulbb(harm_gain, i32(t)) >> 15)
		rand_scale = i16(smulbb(i32(rand_scale), rand_gain) >> 15)
		plc.pitch_q8 = smlawb(plc.pitch_q8, plc.pitch_q8, 655) // 1% drift
		plc.pitch_q8 = min(plc.pitch_q8, i32(18 * c.fs_khz) << 8)
		lag = rshift_round(plc.pitch_q8, 8)
	}
	// LPC synthesis over the extrapolated excitation, its state ahead of it.
	lpc := ltp[c.ltp_mem_length - LPC_MAX:][:LPC_MAX + c.frame_length]
	copy(lpc[:LPC_MAX], c.lpc_state[:])
	order := c.order
	for i in 0 ..< c.frame_length {
		v := i32(order >> 1)
		for t in 0 ..< order do v = smlawb(v, lpc[LPC_MAX + i - 1 - t], i32(a[t]))
		lpc[LPC_MAX + i] = add_sat32(lpc[LPC_MAX + i], lshift_sat32(v, 4))
		frame[i] = sat16(rshift_round(smulww(lpc[LPC_MAX + i], prev_gain_q10[1]), 8))
	}
	copy(c.lpc_state[:], lpc[c.frame_length:][:LPC_MAX])
	plc.rand_seed = seed
	plc.rand_scale_q14 = rand_scale
	p.pitch = {lag, lag, lag, lag}
}

// Comfort noise: smoothed background LPC and gain from inactive frames,
// added into lost frames.
@(private)
cng :: proc(c: ^Silk_Channel, p: ^Silk_Params, frame: []i16) {
	s := &c.cng
	if c.fs_khz != s.fs_khz {
		cng_reset(c)
		s.fs_khz = c.fs_khz
	}
	if c.loss_count == 0 && c.prev_signal == .Inactive {
		for i in 0 ..< c.order do s.smooth_nlsf[i] += i16(smulwb(i32(c.prev_nlsf_q15[i]) - i32(s.smooth_nlsf[i]), 16348))
		// The loudest subframe's excitation joins the noise buffer.
		max_gain: i32
		loudest := 0
		for k in 0 ..< c.nb_subfr do if p.gains_q16[k] > max_gain {max_gain, loudest = p.gains_q16[k], k}
		sub := c.subfr_length
		copy(s.exc_q14[sub:][:(c.nb_subfr - 1) * sub], s.exc_q14[:(c.nb_subfr - 1) * sub])
		copy(s.exc_q14[:sub], c.exc_q14[loudest * sub:][:sub])
		for k in 0 ..< c.nb_subfr {
			s.smooth_gain += smulwb(p.gains_q16[k] - s.smooth_gain, 4634)
			if smulww(s.smooth_gain, 46396) > p.gains_q16[k] do s.smooth_gain = p.gains_q16[k]
		}
	}
	if c.loss_count == 0 {
		for &v in s.synth[:c.order] do v = 0 // only the order's worth, as libopus clears it
		return
	}
	gain := smulww(i32(c.plc.rand_scale_q14), c.plc.prev_gain_q16[1])
	if gain >= 1 << 21 || s.smooth_gain > 1 << 23 {
		gain = (gain >> 16) * (gain >> 16)
		gain = ((s.smooth_gain >> 16) * (s.smooth_gain >> 16)) - (gain << 5)
		gain = sqrt_approx(gain) << 16
	} else {
		gain = smulww(gain, gain)
		gain = smulww(s.smooth_gain, s.smooth_gain) - (gain << 5)
		gain = sqrt_approx(gain) << 8
	}
	gain_q10 := gain >> 6
	sig: [SILK_MAX_FRAME + LPC_MAX]i32
	mask: i32 = 255
	for mask > i32(len(frame)) do mask >>= 1
	seed := s.rand_seed
	for i in 0 ..< len(frame) {
		seed = silk_rand(seed)
		sig[LPC_MAX + i] = s.exc_q14[(seed >> 24) & mask]
	}
	s.rand_seed = seed
	a: [LPC_MAX]i16
	nlsf_to_lpc(&a, s.smooth_nlsf[:c.order])
	copy(sig[:LPC_MAX], s.synth[:])
	order := c.order
	for i in 0 ..< len(frame) {
		v := i32(order >> 1)
		for t in 0 ..< order do v = smlawb(v, sig[LPC_MAX + i - 1 - t], i32(a[t]))
		sig[LPC_MAX + i] = add_sat32(sig[LPC_MAX + i], lshift_sat32(v, 4))
		frame[i] = sat16(i32(frame[i]) + i32(sat16(rshift_round(smulww(sig[LPC_MAX + i], gain_q10), 8))))
	}
	copy(s.synth[:], sig[len(frame):][:LPC_MAX])
}

// The first good frame after a loss rises from the concealed energy.
@(private)
glue_frames :: proc(c: ^Silk_Channel, frame: []i16) {
	plc := &c.plc
	if c.loss_count != 0 {
		plc.conc_energy, plc.conc_shift = sum_sqr_shift(frame)
		plc.last_lost = true
		return
	}
	if plc.last_lost {
		energy, shift := sum_sqr_shift(frame)
		if shift > plc.conc_shift {
			plc.conc_energy >>= uint(shift - plc.conc_shift)
		} else if shift < plc.conc_shift {
			energy >>= uint(plc.conc_shift - shift)
		}
		if energy > plc.conc_energy {
			lz := clz32(plc.conc_energy) - 1
			plc.conc_energy <<= lz
			energy >>= uint(max(24 - int(lz), 0))
			frac := plc.conc_energy / max(energy, 1)
			gain := sqrt_approx(frac) << 4
			slope := (((i32(1) << 16) - gain) / i32(len(frame))) << 2 // 4x steeper, not to miss onsets
			for &v in frame {
				v = i16(smulwb(gain, i32(v)))
				gain += slope
				if gain > 1 << 16 do break
			}
		}
	}
	plc.last_lost = false
}

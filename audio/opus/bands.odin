package opus

import "core:math"

// Band shapes (RFC 6716 4.3.4): each band's unit-norm vector, as PVQ pulses
// (split recursively while too many bits for one codeword), or folded from
// lower bands when it gets none. Mid/side or dual stereo, with the time and
// frequency resolution of each band changed by Haar transforms.

// What decoding one frame's bands shares.
@(private)
Band_Ctx :: struct {
	r:              ^Range_Decoder,
	i:              int, // band
	intensity:      int,
	spread:         Spread,
	tf_change:      int,
	remaining_bits: int,
	seed:           u32,
	avoid_split_noise: bool,
	// One output channel: the inversion of intensity stereo is decoded but
	// not applied, so a downmix does not cancel (RFC 8251).
	disable_inv:    bool,
}

@(private)
Split :: struct {
	inv:          bool,
	imid, iside:  int,
	delta:        int,
	itheta:       int,
	qalloc:       int,
}

@(private)
lcg_rand :: #force_inline proc "contextless" (seed: u32) -> u32 {
	return 1664525 * seed + 1013904223
}

// Fixed-point helpers, exact on every platform because the allocation
// depends on them.
@(private)
frac_mul16 :: #force_inline proc "contextless" (a, b: int) -> int {
	return (16384 + int(i32(i16(a)) * i32(i16(b)))) >> 15
}

@(private)
bitexact_cos :: proc "contextless" (x: int) -> int {
	tmp := (4096 + x * x) >> 13
	x2 := tmp
	x2 = (32767 - x2) + frac_mul16(x2, -7651 + frac_mul16(x2, 8277 + frac_mul16(-626, x2)))
	return 1 + x2
}

@(private)
bitexact_log2tan :: proc "contextless" (isin, icos: int) -> int {
	lc := ilog(u32(icos))
	ls := ilog(u32(isin))
	c := icos << uint(15 - lc)
	s := isin << uint(15 - ls)
	return (ls - lc) * (1 << 11) + frac_mul16(s, frac_mul16(s, -2597) + 7932) - frac_mul16(c, frac_mul16(c, -2597) + 7932)
}

@(private)
isqrt32 :: proc "contextless" (v: u32) -> u32 {
	r := u32(math.sqrt(f64(v)))
	for r * r > v do r -= 1
	for (r + 1) * (r + 1) <= v do r += 1
	return r
}

// Number of pulses for a codeword of `bits`, from the band's pulse cache.
@(private)
bits_to_pulses :: proc(band, lm, bits: int) -> int {
	cache := CACHE_BITS[CACHE_INDEX[lm + 1][band]:]
	lo, hi := 0, int(cache[0])
	b := bits - 1
	for _ in 0 ..< 6 {
		mid := (lo + hi + 1) >> 1
		if int(cache[mid]) >= b {
			hi = mid
		} else {
			lo = mid
		}
	}
	return b - (lo == 0 ? -1 : int(cache[lo])) <= int(cache[hi]) - b ? lo : hi
}

@(private)
pulses_to_bits :: proc(band, lm, pulses: int) -> int {
	if pulses == 0 do return 0
	return int(CACHE_BITS[int(CACHE_INDEX[lm + 1][band]) + pulses]) + 1
}

@(private)
get_pulses :: #force_inline proc "contextless" (i: int) -> int {
	return i < 8 ? i : (8 + (i & 7)) << uint((i >> 3) - 1)
}

// U(n, k) for n <= k: row n of the codebook sizes, indexed by k.
@(private)
pvq_row :: #force_inline proc(n: int) -> [^]u32 {
	#no_bounds_check return ([^]u32)(&PVQ_U[PVQ_ROW[n]])
}

@(private)
pvq_u :: #force_inline proc(n, k: int) -> u32 {
	return pvq_row(min(n, k))[max(n, k)]
}

// The PVQ codeword with index i of n dimensions and k pulses (RFC 6716
// 4.3.4.2); returns the sum of squares. Each search walks one row of U.
@(private)
cwrsi :: proc(n_, k_: int, index: u32, y: []int) -> int {
	n, k, i := n_, k_, index
	yy := 0
	at := 0
	// The largest k' < k with U(k', n) <= i: down column n, k' < n.
	down_column :: #force_inline proc(k, n: int, i: u32) -> (int, u32) {
		k := k
		for {
			k -= 1
			p := pvq_row(k)[n]
			if p <= i do return k, p
		}
	}
	#no_bounds_check for n > 2 {
		val, s: int
		k0 := k
		if k >= n {
			// Many pulses: along row n.
			row := pvq_row(n)
			p := row[k + 1]
			s = i >= p ? -1 : 0
			if s != 0 do i -= p
			if row[n] > i {
				k, p = down_column(n, n, i)
			} else {
				for p = row[k]; p > i; p = row[k] do k -= 1
			}
			i -= p
		} else {
			// Many dimensions.
			p := pvq_row(k)[n]
			q := pvq_row(k + 1)[n]
			if p <= i && i < q {
				i -= p
				y[at] = 0
				at += 1
				n -= 1
				continue
			}
			s = i >= q ? -1 : 0
			if s != 0 do i -= q
			k, p = down_column(k, n, i)
			i -= p
		}
		val = (k0 - k + s) ~ s
		y[at] = val
		at += 1
		yy += val * val
		n -= 1
	}
	// n == 2
	p := u32(2 * k + 1)
	s := i >= p ? -1 : 0
	if s != 0 do i -= p
	k0 := k
	k = int((i + 1) >> 1)
	if k != 0 do i -= u32(2 * k - 1)
	val := (k0 - k + s) ~ s
	y[at] = val
	yy += val * val
	// n == 1
	s = -int(i)
	val = (k + s) ~ s
	y[at + 1] = val
	yy += val * val
	return yy
}

// Spreading (RFC 6716 4.3.4.3): rotations in the plane of neighbours (and
// of samples stride2 apart) that smear a few pulses over the band.
@(private)
exp_rotation1 :: proc(x: []f32, length, stride: int, c, s: f32) {
	ms := -s
	#no_bounds_check {
		for i in 0 ..< length - stride {
			x1, x2 := x[i], x[i + stride]
			x[i + stride] = c * x2 + s * x1
			x[i] = c * x1 + ms * x2
		}
		for i := length - 2 * stride - 1; i >= 0; i -= 1 {
			x1, x2 := x[i], x[i + stride]
			x[i + stride] = c * x2 + s * x1
			x[i] = c * x1 + ms * x2
		}
	}
}

@(private)
exp_rotation_inverse :: proc(x: []f32, length, stride, k: int, spread: Spread) {
	@(static, rodata)
	FACTOR := [3]int{15, 10, 5}
	if 2 * k >= length || spread == .None do return
	gain := f32(length) / f32(length + FACTOR[int(spread) - 1] * k)
	theta := 0.5 * gain * gain
	c := f32(math.cos(f64(0.5 * math.PI) * f64(theta)))
	s := f32(math.cos(f64(0.5 * math.PI) * f64(1 - theta)))
	stride2 := 0
	if length >= 8 * stride {
		stride2 = 1
		for (stride2 * stride2 + stride2) * stride + (stride >> 2) < length do stride2 += 1
	}
	n := length / stride
	for i in 0 ..< stride {
		v := x[i * n:][:n]
		if stride2 != 0 do exp_rotation1(v, n, stride2, s, c)
		exp_rotation1(v, n, 1, c, s)
	}
}

// Decodes k pulses over x (n > 1), scaled to `gain` and spread; returns
// which of the b short blocks got pulses.
@(private)
alg_unquant :: proc(x: []f32, n, k: int, spread: Spread, b: int, r: ^Range_Decoder, gain: f32) -> u32 {
	iy: [176]int
	v := pvq_u(n, k) + pvq_u(n, k + 1)
	ryy := cwrsi(n, k, range_uint(r, v), iy[:n])
	g := gain / f32(math.sqrt(f64(ryy)))
	for i in 0 ..< n do x[i] = f32(iy[i]) * g
	exp_rotation_inverse(x, n, b, k, spread)
	if b <= 1 do return 1
	n0 := n / b
	mask: u32
	for blk in 0 ..< b {
		any := 0
		for j in 0 ..< n0 do any |= iy[blk * n0 + j]
		if any != 0 do mask |= 1 << uint(blk)
	}
	return mask
}

@(private)
renormalise :: proc(x: []f32, gain: f32) {
	e: f32 = 1e-15
	for v in x do e += v * v
	g := gain / f32(math.sqrt(f64(e)))
	for &v in x do v *= g
}

@(private)
haar1 :: proc(x: []f32, n0, stride: int) {
	half := n0 >> 1
	#no_bounds_check for i in 0 ..< stride do for j in 0 ..< half {
		a := 0.70710678 * x[stride * 2 * j + i]
		b := 0.70710678 * x[stride * (2 * j + 1) + i]
		x[stride * 2 * j + i] = a + b
		x[stride * (2 * j + 1) + i] = a - b
	}
}

@(private, rodata)
ORDERY := [30]int{1, 0, 3, 0, 2, 1, 7, 0, 4, 3, 6, 1, 5, 2, 15, 0, 8, 7, 12, 3, 11, 4, 14, 1, 9, 6, 13, 2, 10, 5}

// Short blocks from interleaved (frequency) order to block order, and back.
@(private)
deinterleave :: proc(x: []f32, n0, stride: int, hadamard: bool) {
	tmp: [176]f32
	n := n0 * stride
	for i in 0 ..< stride {
		o := hadamard ? ORDERY[stride - 2 + i] : i
		for j in 0 ..< n0 do tmp[o * n0 + j] = x[j * stride + i]
	}
	copy(x[:n], tmp[:n])
}

@(private)
interleave :: proc(x: []f32, n0, stride: int, hadamard: bool) {
	tmp: [176]f32
	n := n0 * stride
	for i in 0 ..< stride {
		o := hadamard ? ORDERY[stride - 2 + i] : i
		for j in 0 ..< n0 do tmp[j * stride + i] = x[o * n0 + j]
	}
	copy(x[:n], tmp[:n])
}

// The quantisation resolution of a split angle.
@(private)
compute_qn :: proc(n, b, offset, pulse_cap: int, stereo: bool) -> int {
	@(static, rodata)
	EXP2_TABLE8 := [8]int{16384, 17866, 19483, 21247, 23170, 25267, 27554, 30048}
	n2 := 2 * n - 1
	if stereo && n == 2 do n2 -= 1
	// Rounds toward zero, as celt_sudiv.
	qb := (b + n2 * offset) / n2
	qb = min(b - pulse_cap - (4 << BITRES), qb)
	qb = min(8 << BITRES, qb)
	if qb < (1 << BITRES >> 1) do return 1
	qn := EXP2_TABLE8[qb & 7] >> uint(14 - (qb >> BITRES))
	return (qn + 1) >> 1 << 1
}

// The split angle theta between halves (or mid/side), and the bits it took.
@(private)
compute_theta :: proc(ctx: ^Band_Ctx, sc: ^Split, n: int, b: ^int, blocks, b0, lm: int, stereo: bool, fill: ^u32) {
	r := ctx.r
	i := ctx.i
	pulse_cap := int(LOG_N[i]) + lm * (1 << BITRES)
	offset := (pulse_cap >> 1) - (stereo && n == 2 ? QTHETA_OFFSET_TWOPHASE : QTHETA_OFFSET)
	qn := compute_qn(n, b^, offset, pulse_cap, stereo)
	if stereo && i >= ctx.intensity do qn = 1
	tell := range_tell_frac(r)
	itheta := 0
	inv := false
	if qn != 1 {
		if stereo && n > 2 {
			// A step pdf: probability 3 up to the middle, 1 after.
			p0 := 3
			x0 := qn / 2
			ft := u32(p0 * (x0 + 1) + x0)
			fs := int(range_decode(r, ft))
			x := fs < (x0 + 1) * p0 ? fs / p0 : x0 + 1 + (fs - (x0 + 1) * p0)
			fl := x <= x0 ? p0 * x : (x - 1 - x0) + (x0 + 1) * p0
			fh := x <= x0 ? p0 * (x + 1) : (x - x0) + (x0 + 1) * p0
			range_update(r, u32(fl), u32(fh), ft)
			itheta = x
		} else if b0 > 1 || stereo {
			itheta = int(range_uint(r, u32(qn + 1)))
		} else {
			// Triangular pdf.
			half := qn >> 1
			ft := u32((half + 1) * (half + 1))
			fm := range_decode(r, ft)
			fs, fl: int
			if int(fm) < (half * (half + 1) >> 1) {
				itheta = int((isqrt32(8 * fm + 1) - 1) >> 1)
				fs = itheta + 1
				fl = itheta * (itheta + 1) >> 1
			} else {
				itheta = int((2 * u32(qn + 1) - isqrt32(8 * (ft - fm - 1) + 1)) >> 1)
				fs = qn + 1 - itheta
				fl = int(ft) - ((qn + 1 - itheta) * (qn + 2 - itheta) >> 1)
			}
			range_update(r, u32(fl), u32(fl + fs), ft)
		}
		itheta = itheta * 16384 / qn
	} else if stereo {
		if b^ > 2 << BITRES && ctx.remaining_bits > 2 << BITRES do inv = range_bit_logp(r, 2)
		if ctx.disable_inv do inv = false
		itheta = 0
	}
	sc.qalloc = range_tell_frac(r) - tell
	b^ -= sc.qalloc
	switch itheta {
	case 0:
		sc.imid, sc.iside = 32767, 0
		fill^ &= (1 << uint(blocks)) - 1
		sc.delta = -16384
	case 16384:
		sc.imid, sc.iside = 0, 32767
		fill^ &= ((1 << uint(blocks)) - 1) << uint(blocks)
		sc.delta = 16384
	case:
		sc.imid = bitexact_cos(itheta)
		sc.iside = bitexact_cos(16384 - itheta)
		// The mid/side split of bits minimising the squared error.
		sc.delta = frac_mul16((n - 1) << 7, bitexact_log2tan(sc.iside, sc.imid))
	}
	sc.inv = inv
	sc.itheta = itheta
}

@(private)
quant_band_n1 :: proc(ctx: ^Band_Ctx, x, y: []f32, lowband_out: []f32) -> u32 {
	for v in ([2][]f32{x, y}) {
		if v == nil do continue
		sign: u32
		if ctx.remaining_bits >= 1 << BITRES {
			sign = range_bits(ctx.r, 1)
			ctx.remaining_bits -= 1 << BITRES
		}
		v[0] = sign != 0 ? -1 : 1
	}
	if lowband_out != nil do lowband_out[0] = x[0]
	return 1
}

// A mono partition: split in two while it has too many bits for one
// codeword, else PVQ, else folding or noise.
@(private)
quant_partition :: proc(ctx: ^Band_Ctx, x: []f32, n_, b_, blocks_: int, lowband: []f32, lm_: int, gain: f32, fill_: u32) -> u32 {
	n, b, blocks, lm, fill := n_, b_, blocks_, lm_, fill_
	i := ctx.i
	b0 := blocks
	cache := CACHE_BITS[CACHE_INDEX[lm + 1][i]:]
	if lm != -1 && b > int(cache[cache[0]]) + 12 && n > 2 {
		n >>= 1
		y := x[n:]
		lm -= 1
		if blocks == 1 do fill = (fill & 1) | (fill << 1)
		blocks = (blocks + 1) >> 1
		sc: Split
		compute_theta(ctx, &sc, n, &b, blocks, b0, lm, false, &fill)
		mid := (1.0 / 32768) * f32(sc.imid)
		side := (1.0 / 32768) * f32(sc.iside)
		delta := sc.delta
		// More bits to low-energy short blocks than they would otherwise get.
		if b0 > 1 && sc.itheta & 0x3fff != 0 {
			if sc.itheta > 8192 {
				delta -= delta >> uint(4 - lm) // pre-echo masking
			} else {
				delta = min(0, delta + (n << BITRES >> uint(5 - lm))) // forward masking
			}
		}
		mbits := max(0, min(b, (b - delta) / 2))
		sbits := b - mbits
		ctx.remaining_bits -= sc.qalloc
		next_lowband2: []f32
		if lowband != nil do next_lowband2 = lowband[n:]
		rebalance := ctx.remaining_bits
		cm: u32
		if mbits >= sbits {
			cm = quant_partition(ctx, x, n, mbits, blocks, lowband, lm, gain * mid, fill)
			rebalance = mbits - (rebalance - ctx.remaining_bits)
			if rebalance > 3 << BITRES && sc.itheta != 0 do sbits += rebalance - (3 << BITRES)
			cm |= quant_partition(ctx, y, n, sbits, blocks, next_lowband2, lm, gain * side, fill >> uint(blocks)) << uint(b0 >> 1)
		} else {
			cm = quant_partition(ctx, y, n, sbits, blocks, next_lowband2, lm, gain * side, fill >> uint(blocks)) << uint(b0 >> 1)
			rebalance = sbits - (rebalance - ctx.remaining_bits)
			if rebalance > 3 << BITRES && sc.itheta != 16384 do mbits += rebalance - (3 << BITRES)
			cm |= quant_partition(ctx, x, n, mbits, blocks, lowband, lm, gain * mid, fill)
		}
		return cm
	}
	// No split.
	q := bits_to_pulses(i, lm, b)
	curr_bits := pulses_to_bits(i, lm, q)
	ctx.remaining_bits -= curr_bits
	// Never bust the budget.
	for ctx.remaining_bits < 0 && q > 0 {
		ctx.remaining_bits += curr_bits
		q -= 1
		curr_bits = pulses_to_bits(i, lm, q)
		ctx.remaining_bits -= curr_bits
	}
	if q != 0 do return alg_unquant(x, n, get_pulses(q), ctx.spread, blocks, ctx.r, gain)
	// No pulses: fill the band anyway.
	mask := u32(1 << uint(blocks)) - 1
	fill &= mask
	if fill == 0 {
		for &v in x[:n] do v = 0
		return 0
	}
	cm: u32
	if lowband == nil {
		// Noise.
		for j in 0 ..< n {
			ctx.seed = lcg_rand(ctx.seed)
			x[j] = f32(i32(ctx.seed) >> 20)
		}
		cm = mask
	} else {
		// Folded spectrum, with noise about 48 dB below.
		for j in 0 ..< n {
			ctx.seed = lcg_rand(ctx.seed)
			tmp: f32 = ctx.seed & 0x8000 != 0 ? 1.0 / 256 : -1.0 / 256
			x[j] = lowband[j] + tmp
		}
		cm = fill
	}
	renormalise(x[:n], gain)
	return cm
}

// A mono band (or one channel of dual stereo), with its resolution changes.
@(private)
quant_band :: proc(ctx: ^Band_Ctx, x: []f32, n, b, blocks_: int, lowband_in: []f32, lm: int, lowband_out: []f32, gain: f32, lowband_scratch: []f32, fill_: u32) -> u32 {
	n0 := n
	n_b := n / blocks_
	blocks, fill := blocks_, fill_
	b0 := blocks
	long_blocks := b0 == 1
	tf_change := ctx.tf_change
	if n == 1 do return quant_band_n1(ctx, x, nil, lowband_out)
	recombine := tf_change > 0 ? tf_change : 0
	lowband := lowband_in
	// The folding source is changed in place, so work on a copy.
	if lowband_scratch != nil && lowband != nil && (recombine != 0 || (n_b & 1 == 0 && tf_change < 0) || b0 > 1) {
		copy(lowband_scratch[:n], lowband[:n])
		lowband = lowband_scratch[:n]
	}
	@(static, rodata)
	BIT_INTERLEAVE := [16]u32{0, 1, 1, 1, 2, 3, 3, 3, 2, 3, 3, 3, 2, 3, 3, 3}
	for k in 0 ..< recombine {
		if lowband != nil do haar1(lowband, n >> uint(k), 1 << uint(k))
		fill = BIT_INTERLEAVE[fill & 0xF] | BIT_INTERLEAVE[fill >> 4] << 2
	}
	blocks >>= uint(recombine)
	n_b <<= uint(recombine)
	// Increasing the time resolution.
	time_divide := 0
	for n_b & 1 == 0 && tf_change < 0 {
		if lowband != nil do haar1(lowband, n_b, blocks)
		fill |= fill << uint(blocks)
		blocks <<= 1
		n_b >>= 1
		time_divide += 1
		tf_change += 1
	}
	b0 = blocks
	n_b0 := n_b
	// Short blocks to time order.
	if b0 > 1 && lowband != nil do deinterleave(lowband, n_b >> uint(recombine), b0 << uint(recombine), long_blocks)
	cm := quant_partition(ctx, x, n, b, blocks, lowband, lm, gain, fill)
	if b0 > 1 do interleave(x, n_b >> uint(recombine), b0 << uint(recombine), long_blocks)
	n_b = n_b0
	blocks = b0
	for _ in 0 ..< time_divide {
		blocks >>= 1
		n_b <<= 1
		cm |= cm >> uint(blocks)
		haar1(x, n_b, blocks)
	}
	@(static, rodata)
	BIT_DEINTERLEAVE := [16]u32{0x00, 0x03, 0x0C, 0x0F, 0x30, 0x33, 0x3C, 0x3F, 0xC0, 0xC3, 0xCC, 0xCF, 0xF0, 0xF3, 0xFC, 0xFF}
	for k in 0 ..< recombine {
		cm = BIT_DEINTERLEAVE[cm]
		haar1(x, n0 >> uint(k), 1 << uint(k))
	}
	blocks <<= uint(recombine)
	// Scaled for later folding.
	if lowband_out != nil {
		s := f32(math.sqrt(f64(n0)))
		for j in 0 ..< n0 do lowband_out[j] = s * x[j]
	}
	return cm & ((1 << uint(blocks)) - 1)
}

// A stereo band: mid and side split by theta.
@(private)
quant_band_stereo :: proc(ctx: ^Band_Ctx, x, y: []f32, n, b_, blocks: int, lowband: []f32, lm: int, lowband_out: []f32, lowband_scratch: []f32, fill_: u32) -> u32 {
	if n == 1 do return quant_band_n1(ctx, x, y, lowband_out)
	b, fill := b_, fill_
	orig_fill := fill
	sc: Split
	compute_theta(ctx, &sc, n, &b, blocks, blocks, lm, true, &fill)
	mid := (1.0 / 32768) * f32(sc.imid)
	side := (1.0 / 32768) * f32(sc.iside)
	cm: u32
	if n == 2 {
		// The side is orthogonal to the mid: one sign bit.
		sbits := sc.itheta != 0 && sc.itheta != 16384 ? 1 << BITRES : 0
		mbits := b - sbits
		c := sc.itheta > 8192
		ctx.remaining_bits -= sc.qalloc + sbits
		x2, y2 := c ? y : x, c ? x : y
		sign: f32 = 1
		if sbits != 0 && range_bits(ctx.r, 1) != 0 do sign = -1
		cm = quant_band(ctx, x2, n, mbits, blocks, lowband, lm, lowband_out, 1, lowband_scratch, orig_fill)
		y2[0] = -sign * x2[1]
		y2[1] = sign * x2[0]
		x[0], x[1] = mid * x[0], mid * x[1]
		y[0], y[1] = side * y[0], side * y[1]
		t := x[0]
		x[0], y[0] = t - y[0], t + y[0]
		t = x[1]
		x[1], y[1] = t - y[1], t + y[1]
	} else {
		mbits := max(0, min(b, (b - sc.delta) / 2))
		sbits := b - mbits
		ctx.remaining_bits -= sc.qalloc
		rebalance := ctx.remaining_bits
		if mbits >= sbits {
			// The mid stays unscaled: it is the folding source.
			cm = quant_band(ctx, x, n, mbits, blocks, lowband, lm, lowband_out, 1, lowband_scratch, fill)
			rebalance = mbits - (rebalance - ctx.remaining_bits)
			if rebalance > 3 << BITRES && sc.itheta != 0 do sbits += rebalance - (3 << BITRES)
			cm |= quant_band(ctx, y, n, sbits, blocks, nil, lm, nil, side, nil, fill >> uint(blocks))
		} else {
			cm = quant_band(ctx, y, n, sbits, blocks, nil, lm, nil, side, nil, fill >> uint(blocks))
			rebalance = sbits - (rebalance - ctx.remaining_bits)
			if rebalance > 3 << BITRES && sc.itheta != 16384 do mbits += rebalance - (3 << BITRES)
			cm |= quant_band(ctx, x, n, mbits, blocks, lowband, lm, lowband_out, 1, lowband_scratch, fill)
		}
		stereo_merge(x[:n], y[:n], mid)
	}
	if sc.inv do for &v in y[:n] do v = -v
	return cm
}

// Mid and side back to left and right, each renormalised.
@(private)
stereo_merge :: proc(x, y: []f32, mid: f32) {
	xp, side: f32
	for j in 0 ..< len(x) {
		xp += y[j] * x[j]
		side += y[j] * y[j]
	}
	xp *= mid
	el := mid * mid + side - 2 * xp
	er := mid * mid + side + 2 * xp
	if er < 6e-4 || el < 6e-4 {
		copy(y, x)
		return
	}
	lgain := 1 / f32(math.sqrt(f64(el)))
	rgain := 1 / f32(math.sqrt(f64(er)))
	for j in 0 ..< len(x) {
		l := mid * x[j]
		rr := y[j]
		x[j] = lgain * (l - rr)
		y[j] = rgain * (l + rr)
	}
}

// All bands of a frame into c.x (RFC 6716 4.3.4).
@(private)
bands_decode :: proc(c: ^Celt, r: ^Range_Decoder, start, end: int, a: ^Allocation, short_blocks: int, spread: Spread, tf_res: ^[NB_BANDS]int, total_bits, lm, ch: int) {
	m := 1 << uint(lm)
	blocks := short_blocks != 0 ? m : 1
	norm_offset := m * int(EBANDS[start])
	x_all := c.x[0][:]
	y_all: []f32 = ch == 2 ? c.x[1][:] : nil
	norm := c.norm[0][:]
	norm2 := c.norm[1][:]
	// The last band's room in x is free until it is decoded.
	lowband_scratch := x_all[m * int(EBANDS[NB_BANDS - 1]):]
	ctx := Band_Ctx {
		r                 = r,
		intensity         = a.intensity,
		spread            = spread,
		seed              = c.rng,
		avoid_split_noise = blocks > 1,
		disable_inv       = c.channels == 1,
	}
	balance := a.balance
	dual_stereo := a.dual_stereo
	lowband_offset := 0
	update_lowband := true
	for i in start ..< end {
		ctx.i = i
		last := i == end - 1
		x := x_all[m * int(EBANDS[i]):]
		y: []f32 = y_all != nil ? y_all[m * int(EBANDS[i]):] : nil
		n := m * int(EBANDS[i + 1]) - m * int(EBANDS[i])
		tell := range_tell_frac(r)
		if i != start do balance -= tell
		remaining := total_bits - tell - 1
		ctx.remaining_bits = remaining
		b := 0
		if i <= a.coded_bands - 1 {
			curr_balance := balance / min(3, a.coded_bands - i)
			b = max(0, min(16383, min(remaining + 1, a.pulses[i] + curr_balance)))
		}
		if (m * int(EBANDS[i]) - n >= m * int(EBANDS[start]) || i == start + 1) && (update_lowband || lowband_offset == 0) do lowband_offset = i
		if i == start + 1 {
			// Enough of the first band to fold the second (hybrid only).
			n1 := m * int(EBANDS[start + 1] - EBANDS[start])
			n2 := m * int(EBANDS[start + 2] - EBANDS[start + 1])
			if n2 > n1 {
				copy(norm[n1:n2], norm[2 * n1 - n2:][:n2 - n1])
				if dual_stereo do copy(norm2[n1:n2], norm2[2 * n1 - n2:][:n2 - n1])
			}
		}
		ctx.tf_change = tf_res[i]
		scratch := last ? nil : lowband_scratch
		// Collapse masks of the bands folded from.
		x_cm, y_cm: u32
		effective_lowband := -1
		if lowband_offset != 0 && (spread != .Aggressive || blocks > 1 || ctx.tf_change < 0) {
			effective_lowband = max(0, m * int(EBANDS[lowband_offset]) - norm_offset - n)
			fold_start := lowband_offset
			for {
				fold_start -= 1
				if m * int(EBANDS[fold_start]) <= effective_lowband + norm_offset do break
			}
			fold_end := lowband_offset - 1
			for {
				fold_end += 1
				if !(fold_end < i && m * int(EBANDS[fold_end]) < effective_lowband + norm_offset + n) do break
			}
			for fold_i := fold_start; fold_i < fold_end; fold_i += 1 {
				x_cm |= u32(c.collapse[fold_i * ch])
				y_cm |= u32(c.collapse[fold_i * ch + ch - 1])
			}
		} else {
			x_cm = (1 << uint(blocks)) - 1
			y_cm = x_cm
		}
		if dual_stereo && i == a.intensity {
			dual_stereo = false
			for j in 0 ..< m * int(EBANDS[i]) - norm_offset do norm[j] = 0.5 * (norm[j] + norm2[j])
		}
		lowband: []f32 = effective_lowband != -1 ? norm[effective_lowband:] : nil
		out: []f32 = last ? nil : norm[m * int(EBANDS[i]) - norm_offset:]
		if dual_stereo {
			lowband2: []f32 = effective_lowband != -1 ? norm2[effective_lowband:] : nil
			out2: []f32 = last ? nil : norm2[m * int(EBANDS[i]) - norm_offset:]
			x_cm = quant_band(&ctx, x, n, b / 2, blocks, lowband, lm, out, 1, scratch, x_cm)
			y_cm = quant_band(&ctx, y, n, b / 2, blocks, lowband2, lm, out2, 1, scratch, y_cm)
		} else {
			if y != nil {
				x_cm = quant_band_stereo(&ctx, x, y, n, b, blocks, lowband, lm, out, scratch, x_cm | y_cm)
			} else {
				x_cm = quant_band(&ctx, x, n, b, blocks, lowband, lm, out, 1, scratch, x_cm | y_cm)
			}
			y_cm = x_cm
		}
		c.collapse[i * ch] = u8(x_cm)
		c.collapse[i * ch + ch - 1] = u8(y_cm)
		balance += a.pulses[i] + tell
		// Fold from this band only while it has at least a bit per sample.
		update_lowband = b > n << BITRES
		ctx.avoid_split_noise = false
	}
	c.rng = ctx.seed
}

// Noise into short blocks that got no pulses after a transient (RFC 6716
// 4.3.5).
@(private)
anti_collapse :: proc(c: ^Celt, start, end, lm, ch, size: int, pulses: ^[NB_BANDS]int) {
	seed := c.rng
	for i in start ..< end {
		n0 := int(EBANDS[i + 1] - EBANDS[i])
		depth := ((1 + pulses[i]) / n0) >> uint(lm)
		thresh := 0.5 * f32(math.exp(0.6931471805599453094 * f64(-0.125 * f32(depth))))
		sqrt_1 := 1 / f32(math.sqrt(f64(n0 << uint(lm))))
		for k in 0 ..< ch {
			prev1, prev2 := c.log_e[k][i], c.log_e2[k][i]
			if ch == 1 {
				prev1 = max(prev1, c.log_e[1][i])
				prev2 = max(prev2, c.log_e2[1][i])
			}
			ediff := max(0, c.band_e[k][i] - min(prev1, prev2))
			rr := 2 * f32(math.exp(0.6931471805599453094 * f64(-ediff)))
			if lm == 3 do rr *= 1.41421356
			rr = min(thresh, rr) * sqrt_1
			x := c.x[k][int(EBANDS[i]) << uint(lm):]
			renormalize := false
			for blk in 0 ..< 1 << uint(lm) {
				if c.collapse[i * ch + k] & (1 << uint(blk)) != 0 do continue
				for j in 0 ..< n0 {
					seed = lcg_rand(seed)
					x[(j << uint(lm)) + blk] = seed & 0x8000 != 0 ? rr : -rr
				}
				renormalize = true
			}
			if renormalize do renormalise(x[:n0 << uint(lm)], 1)
		}
	}
}

package opus

import "core:math"

// CELT's inverse MDCT (RFC 6716 4.3.7): an N/4-point complex FFT between a
// pre- and a post-rotation, then the windowed TDAC overlap with the previous
// block. N is 1920 >> shift: 1920 for a 20 ms long block, 240 for a short
// block, so the FFTs are 480, 240, 120 and 60 points (radices 4, 2, 3, 5).
//
// The FFT is laid out for its loops: split real and imaginary arrays, an
// input permutation the pre-rotation writes through, then in-place stages
// whose twiddles are stored [j][k] so every inner loop over k is contiguous.

@(private)
MDCT_N :: 1920
@(private)
FFT_MAX :: MDCT_N / 4
@(private)
TWIDDLES_MAX :: FFT_MAX + FFT_MAX / 2 + FFT_MAX / 4 + FFT_MAX / 8 - 4 // n - 1 per plan

@(private)
Fft_Stage :: struct {
	radix:   int,
	m:       int, // sub-transform length before this stage
	twiddle: int, // offset of its [radix - 1][m] twiddles
}

@(private)
Fft_Plan :: struct {
	n:      int,
	perm:   [FFT_MAX]u16, // the input index of each position before the first stage
	stages: [6]Fft_Stage,
	count:  int,
}

@(private)
Mdct_Tables :: struct {
	plans:  [4]Fft_Plan, // by shift
	tw_re:  [TWIDDLES_MAX]f32,
	tw_im:  [TWIDDLES_MAX]f32,
	trig:   [MDCT_N]f32, // cos(2 pi (i + 1/8) / N) for i < N/2, N = 1920, 960, 480, 240
}

// The tables, the same for every decoder, computed once at startup.
@(private)
mdct_tables: Mdct_Tables

@(private, init)
init_mdct :: proc "contextless" () {
	init_mdct_tables(&mdct_tables)
}

// Per-frame FFT data, split complex.
@(private)
Fft_Scratch :: struct {
	re, im: [FFT_MAX]f32,
}

@(private)
init_mdct_tables :: proc "contextless" (t: ^Mdct_Tables) {
	at, tw := 0, 0
	for shift in 0 ..< 4 {
		n := MDCT_N >> uint(shift)
		for i in 0 ..< n / 2 do t.trig[at + i] = f32(math.cos(2 * math.PI * (f64(i) + 0.125) / f64(n)))
		at += n / 2
		plan := &t.plans[shift]
		plan.n = n / 4
		// Radices outermost first (4s, then 2, 3, 5).
		factors: [6]int
		count := 0
		m := plan.n
		for p in ([4]int{4, 2, 3, 5}) {
			for m % p == 0 {
				factors[count] = p
				count += 1
				m /= p
			}
		}
		permute(plan.perm[:plan.n], 0, 1, factors[:count])
		// Stages from the innermost factor out.
		sub := 1
		for f := count - 1; f >= 0; f -= 1 {
			p := factors[f]
			s := &plan.stages[plan.count]
			s^ = {radix = p, m = sub, twiddle = tw}
			length := sub * p
			for j in 1 ..< p do for k in 0 ..< sub {
				phase := -2 * math.PI * f64(j * k) / f64(length)
				t.tw_re[tw] = f32(math.cos(phase))
				t.tw_im[tw] = f32(math.sin(phase))
				tw += 1
			}
			plan.count += 1
			sub = length
		}
	}
}

// The decimation-in-time input order: position q of the first stage holds
// input perm[q].
@(private)
permute :: proc "contextless" (perm: []u16, at, stride: int, factors: []int) {
	p := factors[0]
	m := len(perm) / p
	if m == 1 {
		for j in 0 ..< p do perm[j] = u16(at + j * stride)
		return
	}
	for j in 0 ..< p do permute(perm[j * m:][:m], at + j * stride, stride * p, factors[1:])
}

// The forward DFT of re/im (already in plan.perm order), in place.
@(private)
fft :: proc(plan: ^Fft_Plan, t: ^Mdct_Tables, re, im: []f32) {
	n := plan.n
	for s in plan.stages[:plan.count] {
		m := s.m
		length := m * s.radix
		wr := t.tw_re[s.twiddle:]
		wi := t.tw_im[s.twiddle:]
		for base := 0; base < n; base += length {
			switch s.radix {
			case 2:
				stage(re[base:], im[base:], m, wr, wi, 2)
			case 3:
				stage(re[base:], im[base:], m, wr, wi, 3)
			case 4:
				stage(re[base:], im[base:], m, wr, wi, 4)
			case 5:
				stage(re[base:], im[base:], m, wr, wi, 5)
			}
		}
	}
}

// One radix-P butterfly group: for each k, a_j = x[j m + k] times W^(j k)
// (twiddles w[(j-1) m + k]), the P-point DFT of the a_j into x[q m + k].
@(private)
stage :: #force_inline proc(re, im: []f32, m: int, wr, wi: []f32, $P: int) {
	#no_bounds_check for k in 0 ..< m {
		xr, xi: [P]f32
		xr[0], xi[0] = re[k], im[k]
		#unroll for j in 1 ..< P {
			r, i := re[j * m + k], im[j * m + k]
			c, s := wr[(j - 1) * m + k], wi[(j - 1) * m + k]
			xr[j], xi[j] = r * c - i * s, r * s + i * c
		}
		yr, yi := dft(xr, xi)
		#unroll for q in 0 ..< P do re[q * m + k], im[q * m + k] = yr[q], yi[q]
	}
}

// The P-point forward DFT, its constant twiddles folded.
@(private)
dft :: #force_inline proc(r, i: [$P]f32) -> (yr, yi: [P]f32) {
	when P == 2 {
		yr = {r[0] + r[1], r[0] - r[1]}
		yi = {i[0] + i[1], i[0] - i[1]}
	} else when P == 3 {
		S :: f32(0.86602540378443864676) // sin(2 pi / 3)
		sr, si := r[1] + r[2], i[1] + i[2]
		dr, di := r[1] - r[2], i[1] - i[2]
		cr, ci := r[0] - 0.5 * sr, i[0] - 0.5 * si
		// y1 = c - i S d, y2 = c + i S d
		yr = {r[0] + sr, cr + S * di, cr - S * di}
		yi = {i[0] + si, ci - S * dr, ci + S * dr}
	} else when P == 4 {
		t0r, t0i := r[0] + r[2], i[0] + i[2]
		t1r, t1i := r[0] - r[2], i[0] - i[2]
		t2r, t2i := r[1] + r[3], i[1] + i[3]
		t3r, t3i := i[1] - i[3], r[3] - r[1] // (a1 - a3) times -i
		yr = {t0r + t2r, t1r + t3r, t0r - t2r, t1r - t3r}
		yi = {t0i + t2i, t1i + t3i, t0i - t2i, t1i - t3i}
	} else when P == 5 {
		C1 :: f32(0.30901699437494742410) // cos(2 pi / 5)
		C2 :: f32(-0.80901699437494742410) // cos(4 pi / 5)
		S1 :: f32(0.95105651629515357212) // sin(2 pi / 5)
		S2 :: f32(0.58778525229247312917) // sin(4 pi / 5)
		s14r, s14i := r[1] + r[4], i[1] + i[4]
		d14r, d14i := r[1] - r[4], i[1] - i[4]
		s23r, s23i := r[2] + r[3], i[2] + i[3]
		d23r, d23i := r[2] - r[3], i[2] - i[3]
		// y1, y4 = a -+ i b; y2, y3 = c -+ i e
		ar, ai := r[0] + C1 * s14r + C2 * s23r, i[0] + C1 * s14i + C2 * s23i
		br, bi := S1 * d14r + S2 * d23r, S1 * d14i + S2 * d23i
		cr, ci := r[0] + C2 * s14r + C1 * s23r, i[0] + C2 * s14i + C1 * s23i
		er, ei := S2 * d14r - S1 * d23r, S2 * d14i - S1 * d23i
		yr = {r[0] + s14r + s23r, ar + bi, cr + ei, cr - ei, ar - bi}
		yi = {i[0] + s14i + s23i, ai - br, ci - er, ci + er, ai + br}
	} else {
		#panic("radix not implemented")
	}
	return
}

// The inverse MDCT of the N/2 coefficients in[0], in[stride], ... into
// out[overlap/2 ..< overlap/2 + N/2], overlapped with what out[0 ..< overlap]
// holds from the previous block.
@(private)
imdct :: proc(t: ^Mdct_Tables, input: []f32, stride: int, out: []f32, shift: int, f: ^Fft_Scratch) {
	n := MDCT_N >> uint(shift)
	n2, n4 := n / 2, n / 4
	trig_at := 0
	for s in 0 ..< shift do trig_at += (MDCT_N >> uint(s)) / 2
	trig := t.trig[trig_at:][:n2]
	plan := &t.plans[shift]
	re, im := f.re[:n4], f.im[:n4]
	// Pre-rotation, written in the FFT's input order; real and imaginary
	// swapped to use a forward FFT.
	#no_bounds_check for q in 0 ..< n4 {
		i := int(plan.perm[q])
		x1 := input[2 * i * stride]
		x2 := input[(n2 - 1 - 2 * i) * stride]
		re[q] = x1 * trig[i] - x2 * trig[n4 + i]
		im[q] = x2 * trig[i] + x1 * trig[n4 + i]
	}
	fft(plan, t, re, im)
	// Post-rotation, the halves of each output pair from opposite ends.
	o := out[OVERLAP / 2:][:n2]
	#no_bounds_check for j in 0 ..< n4 {
		a, b := im[j], re[j]
		o[2 * j] = a * trig[j] + b * trig[n4 + j]
		o[n2 - 1 - 2 * j] = a * trig[n4 + j] - b * trig[j]
	}
	// TDAC: mirror the overlap with the window.
	#no_bounds_check for i in 0 ..< OVERLAP / 2 {
		x1 := out[OVERLAP - 1 - i]
		x2 := out[i]
		out[i] = x2 * WINDOW[OVERLAP - 1 - i] - x1 * WINDOW[i]
		out[OVERLAP - 1 - i] = x2 * WINDOW[i] + x1 * WINDOW[OVERLAP - 1 - i]
	}
}

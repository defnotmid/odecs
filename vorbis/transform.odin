package vorbis

import "core:math"
import "core:mem"

// The inverse MDCT of one block size, through a DCT-IV of n / 2 points
// computed with an n / 4-point complex FFT (split real and imaginary
// planes, stage-contiguous twiddles). All tables and scratch are in one
// allocation owned by the Transform.
@(private)
Transform :: struct {
	n:        int,
	memory:   []f32,
	pre:      [2][]f32, // exp(-i pi (4m + 1) / (4 M)), M = n / 2
	post:     [2][]f32, // exp(-i pi k / M)
	twiddle:  [2][]f32, // per FFT stage of size s, exp(-2 pi i k / s) at s / 2 - 1 + k
	work:     [2][]f32, // the FFT's planes
	reverse:  []u16, // bit reversal of the FFT's indices
	dct:      []f32, // the DCT-IV output, M values
}

@(private)
init_transform :: proc(t: ^Transform, n: int, allocator: mem.Allocator) -> Error {
	m, h := n / 2, n / 4
	t.n = n
	err: mem.Allocator_Error
	t.memory, err = make([]f32, 6 * h + 2 * max(h - 1, 0) + m, allocator)
	if err != nil do return .Out_Of_Memory
	t.reverse, err = make([]u16, h, allocator)
	if err != nil do return .Out_Of_Memory
	rest := t.memory
	take :: proc(rest: ^[]f32, k: int) -> []f32 {s := rest[:k]; rest^ = rest[k:]; return s}
	for p in 0 ..< 2 {
		t.pre[p] = take(&rest, h)
		t.post[p] = take(&rest, h)
		t.work[p] = take(&rest, h)
		t.twiddle[p] = take(&rest, max(h - 1, 0))
	}
	t.dct = take(&rest, m)
	for k in 0 ..< h {
		a := -math.PI * f64(4 * k + 1) / f64(4 * m)
		t.pre[0][k], t.pre[1][k] = f32(math.cos(a)), f32(math.sin(a))
		b := -math.PI * f64(k) / f64(m)
		t.post[0][k], t.post[1][k] = f32(math.cos(b)), f32(math.sin(b))
	}
	for s := 2; s <= h; s *= 2 {
		for k in 0 ..< s / 2 {
			a := -2 * math.PI * f64(k) / f64(s)
			t.twiddle[0][s / 2 - 1 + k], t.twiddle[1][s / 2 - 1 + k] = f32(math.cos(a)), f32(math.sin(a))
		}
	}
	levels := uint(ilog(h) - 1)
	for i in 0 ..< h {
		r := 0
		for b in 0 ..< levels do r |= (i >> b & 1) << (levels - 1 - b)
		t.reverse[i] = u16(r)
	}
	return .None
}

@(private)
destroy_transform :: proc(t: ^Transform, allocator: mem.Allocator) {
	delete(t.memory, allocator)
	delete(t.reverse, allocator)
	t^ = {}
}

// spectrum (n / 2 coefficients) to n time samples:
// out[j] = sum_k X[k] cos(pi / M (j + 1/2 + M / 2)(k + 1/2)), unscaled.
@(private)
imdct :: proc(t: ^Transform, spectrum, out: []f32) #no_bounds_check {
	m, h := t.n / 2, t.n / 4
	re, im := t.work[0], t.work[1]
	// Pre-twiddle, in bit-reversed order for the FFT.
	for k in 0 ..< h {
		a, b := spectrum[2 * k], spectrum[m - 1 - 2 * k]
		c, s := t.pre[0][k], t.pre[1][k]
		r := t.reverse[k]
		re[r], im[r] = a * c - b * s, a * s + b * c
	}
	fft(t, h)
	// Post-twiddle: the DCT-IV's even outputs from the real parts, odd
	// (from the end) from the imaginary.
	for k in 0 ..< h {
		a, b := re[k], im[k]
		c, s := t.post[0][k], t.post[1][k]
		t.dct[2 * k] = a * c - b * s
		t.dct[m - 1 - 2 * k] = -(a * s + b * c)
	}
	// The DCT-IV's symmetries give the n outputs.
	y := t.dct
	q := m / 2
	for j in 0 ..< q do out[j] = y[j + q]
	for j in q ..< m + q do out[j] = -y[m + q - 1 - j]
	for j in m + q ..< t.n do out[j] = -y[j - m - q]
}

// An in-place radix-2 FFT over the bit-reversed planes.
@(private)
fft :: proc(t: ^Transform, h: int) #no_bounds_check {
	re, im := t.work[0], t.work[1]
	for s := 2; s <= h; s *= 2 {
		half := s / 2
		wr, wi := t.twiddle[0][half - 1:][:half], t.twiddle[1][half - 1:][:half]
		for base := 0; base < h; base += s {
			for k in 0 ..< half {
				i, j := base + k, base + k + half
				xr := re[j] * wr[k] - im[j] * wi[k]
				xi := re[j] * wi[k] + im[j] * wr[k]
				re[j], im[j] = re[i] - xr, im[i] - xi
				re[i], im[i] = re[i] + xr, im[i] + xi
			}
		}
	}
}

// A rising window half of len(slope) samples:
// sin(pi / 2 * sin^2((i + 1/2) / len * pi / 2)).
@(private)
window_slope :: proc(slope: []f32) {
	n := f64(len(slope))
	for &v, i in slope {
		s := math.sin((f64(i) + 0.5) / n * math.PI / 2)
		v = f32(math.sin(math.PI / 2 * s * s))
	}
}

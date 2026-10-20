package aac

import "base:intrinsics"
import "core:math"
import "core:simd"

Window_Sequence :: enum u8 {
	Long,
	Start,
	Short,
	Stop,
}

// Fold the MDCT into a DCT-IV, which needs one N/2-point forward FFT. The
// same DCT-IV evaluates synthesis before unfolding its N distinct values.
// Separate real/imaginary planes and stage-contiguous twiddles feed native
// SIMD butterflies. State and scratch are caller-owned; no transform allocates.
Transform :: struct {
	frame_length:   int,
	twiddle:        [2][511]f64,
	long_rotate:    [2][512]f64,
	short_rotate:   [2][64]f64,
	reverse:        [512]u16,
	scratch:        [2][512]f64,
	long_window:    [2][1024]f64,
	short_window:   [2][128]f64,
	// 960/120 use 15 power-of-two columns, then radix-3 and radix-5.
	// Every table and intermediate plane belongs to this caller-owned plan.
	reverse960:     [480]u16,
	reverse120:     [60]u16,
	phase960:       [2][480]f64,
	phase120:       [2][60]f64,
	root3:          [2][3]f64,
	root5:          [2][5]f64,
	root15:         [2][15]f64,
	mixed_work:     [2][512]f64,
	analysis_input: [2048]f64,
	analysis_short: [256]f64,
}

init_transform :: proc(t: ^Transform, frame_length: int = 1024) {
	assert(frame_length == 1024 || frame_length == 960)
	t.frame_length = frame_length
	for size := 2; size <= 512; size *= 2 {
		half := size / 2
		for k in 0 ..< half {
			a := -2 * math.PI * f64(k) / f64(size)
			t.twiddle[0][half - 1 + k] = math.cos(a)
			t.twiddle[1][half - 1 + k] = math.sin(a)
		}
	}
	for i in 0 ..< 512 {
		index, reversed := i, 0
		for _ in 0 ..< 9 {reversed = (reversed << 1) | (index & 1); index >>= 1}
		t.reverse[i] = u16(reversed)
	}
	if frame_length == 960 {
		for n in ([2]int{60, 480}) {
			length := n / 15
			bits := n == 60 ? 2 : 5
			reverse := n == 60 ? t.reverse120[:] : t.reverse960[:]
			phase_r := n == 60 ? t.phase120[0][:] : t.phase960[0][:]
			phase_i := n == 60 ? t.phase120[1][:] : t.phase960[1][:]
			for j in 0 ..< n {
				index, reversed := j / 15, 0
				for _ in 0 ..< bits {reversed = (reversed << 1) | (index & 1); index >>= 1}
				reverse[j] = u16((j % 15) * length + reversed)
				a := -2 * math.PI * f64(j / length) * f64(j % length) / f64(n)
				phase_r[j], phase_i[j] = math.cos(a), math.sin(a)
			}
		}
		for radix in ([3]int{3, 5, 15}) {
			r := radix == 3 ? t.root3[0][:] : (radix == 5 ? t.root5[0][:] : t.root15[0][:])
			im := radix == 3 ? t.root3[1][:] : (radix == 5 ? t.root5[1][:] : t.root15[1][:])
			for k in 0 ..< radix {
				a := -2 * math.PI * f64(k) / f64(radix)
				r[k], im[k] = math.cos(a), math.sin(a)
			}
		}
	}
	for n in ([]int{frame_length / 8, frame_length}) {
		short := n == frame_length / 8
		rotate_real := short ? t.short_rotate[0][:] : t.long_rotate[0][:]
		rotate_imag := short ? t.short_rotate[1][:] : t.long_rotate[1][:]
		for i in 0 ..< n / 2 {
			a := -math.PI * (f64(i) + 0.125) / f64(n)
			rotate_real[i], rotate_imag[i] = math.cos(a), math.sin(a)
		}
		sine := short ? t.short_window[0][:] : t.long_window[0][:]
		kbd := short ? t.short_window[1][:] : t.long_window[1][:]
		alpha: f64 = short ? 6 : 4
		kernel: [1025]f64
		total: f64
		for i in 0 ..= n {
			x := 2 * f64(i) / f64(n) - 1
			v := math.PI * alpha * math.sqrt(max(0, 1 - x * x))
			term, sum: f64 = 1, 1
			for k in 1 ..< 100 {
				term *= v * v / (4 * f64(k * k))
				sum += term
				if term < sum * 1e-18 do break
			}
			kernel[i] = sum
			total += sum
		}
		running: f64
		for i in 0 ..< n {
			sine[i] = math.sin(math.PI * (f64(i) + 0.5) / f64(2 * n))
			running += kernel[i]
			kbd[i] = math.sqrt(running / total)
		}
	}
}

@(private)
fft_stage8 :: #force_inline proc(
	$Half: int,
	r, im, wr, wi: simd.f64x8,
) -> (
	out_r, out_im: simd.f64x8,
) {
	#assert(Half == 1 || Half == 2 || Half == 4)
	ur, ui, br, bi: simd.f64x8
	plus: #simd[8]bool
	when Half == 1 {
		ur = simd.shuffle(r, r, 0, 0, 2, 2, 4, 4, 6, 6)
		ui = simd.shuffle(im, im, 0, 0, 2, 2, 4, 4, 6, 6)
		br = simd.shuffle(r, r, 1, 1, 3, 3, 5, 5, 7, 7)
		bi = simd.shuffle(im, im, 1, 1, 3, 3, 5, 5, 7, 7)
		plus = {true, false, true, false, true, false, true, false}
	} else when Half == 2 {
		ur = simd.shuffle(r, r, 0, 1, 0, 1, 4, 5, 4, 5)
		ui = simd.shuffle(im, im, 0, 1, 0, 1, 4, 5, 4, 5)
		br = simd.shuffle(r, r, 2, 3, 2, 3, 6, 7, 6, 7)
		bi = simd.shuffle(im, im, 2, 3, 2, 3, 6, 7, 6, 7)
		plus = {true, true, false, false, true, true, false, false}
	} else {
		ur = simd.shuffle(r, r, 0, 1, 2, 3, 0, 1, 2, 3)
		ui = simd.shuffle(im, im, 0, 1, 2, 3, 0, 1, 2, 3)
		br = simd.shuffle(r, r, 4, 5, 6, 7, 4, 5, 6, 7)
		bi = simd.shuffle(im, im, 4, 5, 6, 7, 4, 5, 6, 7)
		plus = {true, true, true, true, false, false, false, false}
	}
	// Keep each component's original multiply/add/subtract sequence, including
	// the initialized twiddles' signed zeros and finite quarter-turn rounding.
	vr := simd.sub(simd.mul(br, wr), simd.mul(bi, wi))
	vi := simd.add(simd.mul(br, wi), simd.mul(bi, wr))
	return simd.select(
		plus,
		simd.add(ur, vr),
		simd.sub(ur, vr),
	), simd.select(plus, simd.add(ui, vi), simd.sub(ui, vi))
}

@(private)
fft_mixed :: proc(t: ^Transform, n: int) #no_bounds_check {
	assert(n == 60 || n == 480)
	length := n / 15 // 4 or32; input is fifteen bit-reversed columns.
	r, im := &t.scratch[0], &t.scratch[1]
	mask: #simd[8]bool = {true, true, true, true, true, true, true, true}
	if length == 4 do mask = {true, true, true, true, false, false, false, false}
	early_r := intrinsics.unaligned_load((^simd.f64x8)(&t.twiddle[0][0]))
	early_i := intrinsics.unaligned_load((^simd.f64x8)(&t.twiddle[1][0]))
	wr1 := simd.shuffle(early_r, early_r, 0, 0, 0, 0, 0, 0, 0, 0)
	wi1 := simd.shuffle(early_i, early_i, 0, 0, 0, 0, 0, 0, 0, 0)
	wr2 := simd.shuffle(early_r, early_r, 1, 2, 1, 2, 1, 2, 1, 2)
	wi2 := simd.shuffle(early_i, early_i, 1, 2, 1, 2, 1, 2, 1, 2)
	wr4 := simd.shuffle(early_r, early_r, 3, 4, 5, 6, 3, 4, 5, 6)
	wi4 := simd.shuffle(early_i, early_i, 3, 4, 5, 6, 3, 4, 5, 6)
	for column in 0 ..< 15 {
		offset := column * length
		for base := offset; base < offset + length; base += 8 {
			gr := simd.masked_load(&r[base], simd.f64x8{}, mask)
			gi := simd.masked_load(&im[base], simd.f64x8{}, mask)
			gr, gi = fft_stage8(1, gr, gi, wr1, wi1)
			gr, gi = fft_stage8(2, gr, gi, wr2, wi2)
			if length >= 8 do gr, gi = fft_stage8(4, gr, gi, wr4, wi4)
			simd.masked_store(&r[base], gr, mask)
			simd.masked_store(&im[base], gi, mask)
		}
		for size := 16; size <= length; size *= 2 {
			half := size / 2
			for base := offset; base < offset + length; base += size {
				for k := 0; k < half; k += 8 {
					lo, hi := base + k, base + k + half
					ur := intrinsics.unaligned_load((^simd.f64x8)(&r[lo]))
					ui := intrinsics.unaligned_load((^simd.f64x8)(&im[lo]))
					br := intrinsics.unaligned_load((^simd.f64x8)(&r[hi]))
					bi := intrinsics.unaligned_load((^simd.f64x8)(&im[hi]))
					wr := intrinsics.unaligned_load((^simd.f64x8)(&t.twiddle[0][half - 1 + k]))
					wi := intrinsics.unaligned_load((^simd.f64x8)(&t.twiddle[1][half - 1 + k]))
					vr := simd.sub(simd.mul(br, wr), simd.mul(bi, wi))
					vi := simd.add(simd.mul(br, wi), simd.mul(bi, wr))
					intrinsics.unaligned_store((^simd.f64x8)(&r[lo]), simd.add(ur, vr))
					intrinsics.unaligned_store((^simd.f64x8)(&im[lo]), simd.add(ui, vi))
					intrinsics.unaligned_store((^simd.f64x8)(&r[hi]), simd.sub(ur, vr))
					intrinsics.unaligned_store((^simd.f64x8)(&im[hi]), simd.sub(ui, vi))
				}
			}
		}
	}
	phase_r := n == 60 ? t.phase120[0][:] : t.phase960[0][:]
	phase_i := n == 60 ? t.phase120[1][:] : t.phase960[1][:]
	// j=15*v+c and k=k1+L*k0 split the exponent into an L-point
	// transform, c*k1/(15L), and c*k0/15. For c=5*b+a, the last
	// term is a radix-3 followed by radix-5 with a*r/15 rotation.
	for k1 := 0; k1 < length; k1 += 8 {
		for a in 0 ..< 5 {
			for rho in 0 ..< 3 {
				sr, si: simd.f64x8
				for b in 0 ..< 3 {
					index := (5 * b + a) * length + k1
					xr := simd.masked_load(&r[index], simd.f64x8{}, mask)
					xi := simd.masked_load(&im[index], simd.f64x8{}, mask)
					wr := simd.masked_load(&phase_r[index], simd.f64x8{}, mask)
					wi := simd.masked_load(&phase_i[index], simd.f64x8{}, mask)
					pr := simd.sub(simd.mul(xr, wr), simd.mul(xi, wi))
					pi := simd.add(simd.mul(xr, wi), simd.mul(xi, wr))
					rr, ri :=
						simd.f64x8(t.root3[0][b * rho % 3]), simd.f64x8(t.root3[1][b * rho % 3])
					sr = simd.add(sr, simd.sub(simd.mul(pr, rr), simd.mul(pi, ri)))
					si = simd.add(si, simd.add(simd.mul(pr, ri), simd.mul(pi, rr)))
				}
				index := (rho * 5 + a) * length + k1
				simd.masked_store(&t.mixed_work[0][index], sr, mask)
				simd.masked_store(&t.mixed_work[1][index], si, mask)
			}
		}
	}
	// The separate intermediate plane makes every output store independent
	// of inputs still needed by another radix; there is no permutation copy.
	for k1 := 0; k1 < length; k1 += 8 {
		for rho in 0 ..< 3 {
			for sigma in 0 ..< 5 {
				sr, si: simd.f64x8
				for a in 0 ..< 5 {
					index := (rho * 5 + a) * length + k1
					xr := simd.masked_load(&t.mixed_work[0][index], simd.f64x8{}, mask)
					xi := simd.masked_load(&t.mixed_work[1][index], simd.f64x8{}, mask)
					rr, ri :=
						simd.f64x8(t.root15[0][a * rho % 15]),
						simd.f64x8(t.root15[1][a * rho % 15])
					pr := simd.sub(simd.mul(xr, rr), simd.mul(xi, ri))
					pi := simd.add(simd.mul(xr, ri), simd.mul(xi, rr))
					wr, wi :=
						simd.f64x8(t.root5[0][a * sigma % 5]),
						simd.f64x8(t.root5[1][a * sigma % 5])
					sr = simd.add(sr, simd.sub(simd.mul(pr, wr), simd.mul(pi, wi)))
					si = simd.add(si, simd.add(simd.mul(pr, wi), simd.mul(pi, wr)))
				}
				index := (rho + 3 * sigma) * length + k1
				simd.masked_store(&r[index], sr, mask)
				simd.masked_store(&im[index], si, mask)
			}
		}
	}
}

@(private)
fft :: proc(t: ^Transform, n: int) #no_bounds_check {
	if n == 60 || n == 480 {fft_mixed(t, n); return}
	// Packing has already produced the bit-reversed input, avoiding a separate
	// permutation pass. Every active scratch value is written before this call.
	r, im := &t.scratch[0], &t.scratch[1]
	// FFT64/512 partition into complete groups of eight. The first three stages
	// share each group's register planes instead of storing/reloading each stage.
	early_wr := intrinsics.unaligned_load((^simd.f64x8)(&t.twiddle[0][0]))
	early_wi := intrinsics.unaligned_load((^simd.f64x8)(&t.twiddle[1][0]))
	wr1 := simd.shuffle(early_wr, early_wr, 0, 0, 0, 0, 0, 0, 0, 0)
	wi1 := simd.shuffle(early_wi, early_wi, 0, 0, 0, 0, 0, 0, 0, 0)
	wr2 := simd.shuffle(early_wr, early_wr, 1, 2, 1, 2, 1, 2, 1, 2)
	wi2 := simd.shuffle(early_wi, early_wi, 1, 2, 1, 2, 1, 2, 1, 2)
	wr4 := simd.shuffle(early_wr, early_wr, 3, 4, 5, 6, 3, 4, 5, 6)
	wi4 := simd.shuffle(early_wi, early_wi, 3, 4, 5, 6, 3, 4, 5, 6)
	for base := 0; base < n; base += 8 {
		group_r := intrinsics.unaligned_load((^simd.f64x8)(&r[base]))
		group_im := intrinsics.unaligned_load((^simd.f64x8)(&im[base]))
		group_r, group_im = fft_stage8(1, group_r, group_im, wr1, wi1)
		group_r, group_im = fft_stage8(2, group_r, group_im, wr2, wi2)
		group_r, group_im = fft_stage8(4, group_r, group_im, wr4, wi4)
		intrinsics.unaligned_store((^simd.f64x8)(&r[base]), group_r)
		intrinsics.unaligned_store((^simd.f64x8)(&im[base]), group_im)
	}
	for size := 16; size <= n; size *= 2 {
		half := size / 2
		tw := half - 1
		for base := 0; base < n; base += size {
			for k := 0; k < half; k += 8 {
				lo, hi := base + k, base + k + half
				ur := intrinsics.unaligned_load((^simd.f64x8)(&r[lo]))
				ui := intrinsics.unaligned_load((^simd.f64x8)(&im[lo]))
				br := intrinsics.unaligned_load((^simd.f64x8)(&r[hi]))
				bi := intrinsics.unaligned_load((^simd.f64x8)(&im[hi]))
				wr := intrinsics.unaligned_load((^simd.f64x8)(&t.twiddle[0][tw + k]))
				wi := intrinsics.unaligned_load((^simd.f64x8)(&t.twiddle[1][tw + k]))
				vr := simd.sub(simd.mul(br, wr), simd.mul(bi, wi))
				vi := simd.add(simd.mul(br, wi), simd.mul(bi, wr))
				intrinsics.unaligned_store((^simd.f64x8)(&r[lo]), simd.add(ur, vr))
				intrinsics.unaligned_store((^simd.f64x8)(&im[lo]), simd.add(ui, vi))
				intrinsics.unaligned_store((^simd.f64x8)(&r[hi]), simd.sub(ur, vr))
				intrinsics.unaligned_store((^simd.f64x8)(&im[hi]), simd.sub(ui, vi))
			}
		}
	}
}

@(private)
pack_dct :: #force_inline proc(
	t: ^Transform,
	reverse: []u16,
	j, shift: int,
	a, b, wr, wi: f64,
) #no_bounds_check {
	index := int(reverse[j]) >> uint(shift)
	t.scratch[0][index] = a * wr - b * wi
	t.scratch[1][index] = a * wi + b * wr
}

// Pairing u[2j] with u[N-1-2j], rotated by exp(-i*pi*(j+1/8)/N),
// produces DCT-IV[2j] in the real part and DCT-IV[N-1-2j] in the
// negative imaginary part after the same rotation of the forward FFT.
mdct :: proc(t: ^Transform, input, spectrum: []f64) #no_bounds_check {
	n := len(spectrum)
	assert((n == t.frame_length || n == t.frame_length / 8) && len(input) == 2 * n)
	m := n / 2
	wr := n < 960 ? t.short_rotate[0][:] : t.long_rotate[0][:]
	wi := n < 960 ? t.short_rotate[1][:] : t.long_rotate[1][:]
	shift := n == 128 ? 3 : 0
	reverse := t.reverse[:]
	if n == 120 do reverse = t.reverse120[:]
	if n == 960 do reverse = t.reverse960[:]
	// Fold directly into rotated, bit-reversed scratch: no sparse zeros or
	// intermediate folded plane. The two domains remove per-item fold branches.
	for j in 0 ..< m / 2 {
		a := -input[3 * m - 1 - 2 * j] - input[3 * m + 2 * j]
		b := input[m - 1 - 2 * j] - input[m + 2 * j]
		pack_dct(t, reverse, j, shift, a, b, wr[j], wi[j])
	}
	for j in m / 2 ..< m {
		a := input[2 * j - m] - input[3 * m - 1 - 2 * j]
		b := -input[m + 2 * j] - input[5 * m - 1 - 2 * j]
		pack_dct(t, reverse, j, shift, a, b, wr[j], wi[j])
	}
	fft(t, m)
	for j in 0 ..< m {
		a, b := t.scratch[0][j], t.scratch[1][j]
		spectrum[2 * j] = 2 * (a * wr[j] - b * wi[j])
		spectrum[n - 1 - 2 * j] = -2 * (a * wi[j] + b * wr[j])
	}
}

@(private)
unfold_rotate8 :: #force_inline proc(
	t: ^Transform,
	wr, wi: []f64,
	j: int,
	scale: simd.f64x8,
) -> (
	even, odd: simd.f64x8,
) #no_bounds_check {
	a := intrinsics.unaligned_load((^simd.f64x8)(&t.scratch[0][j]))
	b := intrinsics.unaligned_load((^simd.f64x8)(&t.scratch[1][j]))
	real := intrinsics.unaligned_load((^simd.f64x8)(&wr[j]))
	imag := intrinsics.unaligned_load((^simd.f64x8)(&wi[j]))
	// Preserve the scalar component order, including negation before scaling.
	even = simd.mul(simd.sub(simd.mul(a, real), simd.mul(b, imag)), scale)
	odd = simd.mul(simd.neg(simd.add(simd.mul(a, imag), simd.mul(b, real))), scale)
	return
}

@(private)
unfold_store_pairs8 :: #force_inline proc(
	output: []f64,
	base: int,
	first, second: simd.f64x8,
) #no_bounds_check {
	// A forward coefficient plane meets a reverse plane in adjacent samples.
	lo := simd.shuffle(first, second, 0, 15, 1, 14, 2, 13, 3, 12)
	hi := simd.shuffle(first, second, 4, 11, 5, 10, 6, 9, 7, 8)
	intrinsics.unaligned_store((^simd.f64x8)(&output[base]), lo)
	intrinsics.unaligned_store((^simd.f64x8)(&output[base + 8]), hi)
}

@(private)
unfold_dct :: proc(t: ^Transform, n: int, output: []f64) #no_bounds_check {
	m := n / 2
	wr := n < 960 ? t.short_rotate[0][:] : t.long_rotate[0][:]
	wi := n < 960 ? t.short_rotate[1][:] : t.long_rotate[1][:]
	scale := 1 / f64(n)
	// Caller-owned output normally lies outside Transform. Retain the original
	// write order if a caller supplies overlapping transform storage; no alias
	// annotation or new admission restriction is needed for the SIMD path.
	output_address, transform_address := uintptr(raw_data(output)), uintptr(t)
	output_bytes := uintptr(2 * n * size_of(f64))
	overlaps: bool
	if output_address >= transform_address {
		overlaps = output_address - transform_address < size_of(Transform)
	} else {
		overlaps = transform_address - output_address < output_bytes
	}
	if overlaps || n == 120 {
		for j in 0 ..< m / 2 {
			a, b := t.scratch[0][j], t.scratch[1][j]
			even := (a * wr[j] - b * wi[j]) * scale
			odd := -(a * wi[j] + b * wr[j]) * scale
			output[3 * m - 1 - 2 * j], output[3 * m + 2 * j] = -even, -even
			output[m - 1 - 2 * j], output[m + 2 * j] = odd, -odd
		}
		for j in m / 2 ..< m {
			a, b := t.scratch[0][j], t.scratch[1][j]
			even := (a * wr[j] - b * wi[j]) * scale
			odd := -(a * wi[j] + b * wr[j]) * scale
			output[2 * j - m], output[3 * m - 1 - 2 * j] = even, -even
			output[m + 2 * j], output[5 * m - 1 - 2 * j] = -odd, -odd
		}
		return
	}
	// Pair p with m-1-p. The two ascending scratch ranges then own adjacent
	// samples in four disjoint output regions of m samples each. For both
	// supported sizes, m/2 is a multiple of eight and all stores are complete.
	scale_lanes := simd.f64x8(scale)
	for p := 0; p < m / 2; p += 8 {
		q := m - p - 8
		even_p, odd_p := unfold_rotate8(t, wr, wi, p, scale_lanes)
		even_q, odd_q := unfold_rotate8(t, wr, wi, q, scale_lanes)
		unfold_store_pairs8(output, m - 2 * (p + 8), even_q, odd_p)
		unfold_store_pairs8(output, m + 2 * p, simd.neg(odd_p), simd.neg(even_q))
		unfold_store_pairs8(output, 3 * m - 2 * (p + 8), simd.neg(odd_q), simd.neg(even_p))
		unfold_store_pairs8(output, 3 * m + 2 * p, simd.neg(even_p), simd.neg(odd_q))
	}
}

imdct :: proc(t: ^Transform, spectrum, output: []f64) #no_bounds_check {
	n := len(spectrum)
	assert((n == t.frame_length || n == t.frame_length / 8) && len(output) == 2 * n)
	m := n / 2
	wr := n < 960 ? t.short_rotate[0][:] : t.long_rotate[0][:]
	wi := n < 960 ? t.short_rotate[1][:] : t.long_rotate[1][:]
	shift := n == 128 ? 3 : 0
	reverse := t.reverse[:]
	if n == 120 do reverse = t.reverse120[:]
	if n == 960 do reverse = t.reverse960[:]
	for j in 0 ..< m do pack_dct(t, reverse, j, shift, spectrum[2 * j], spectrum[n - 1 - 2 * j], wr[j], wi[j])
	fft(t, m)
	unfold_dct(t, n, output)
}

Filterbank :: struct {
	overlap:        [1024]f64,
	previous_shape: u8,
}

@(private)
long_window_left :: #force_inline proc(
	t: ^Transform,
	n: int,
	sequence: Window_Sequence,
	previous: u8,
	i: int,
) -> f64 {
	if sequence != .Stop do return t.long_window[previous][i]
	small := n / 8
	flat := (n - small) / 2
	return i < flat ? 0 : (i < flat + small ? t.short_window[previous][i - flat] : 1)
}

@(private)
long_window_right :: #force_inline proc(
	t: ^Transform,
	n: int,
	sequence: Window_Sequence,
	shape: u8,
	i: int,
) -> f64 {
	if sequence != .Start do return t.long_window[shape][n - 1 - i]
	small := n / 8
	flat := (n - small) / 2
	return i < flat ? 1 : (i < flat + small ? t.short_window[shape][flat + small - 1 - i] : 0)
}

// Analyze a caller's two-frame PCM block in the same 32768-unit scale as
// mdct. The plan is independent mutable scratch; input/spectrum do not alias
// it. Input and spectrum may overlap: all input is captured before publication.
// Eight-short output is eight consecutive short spectra in time-window order.
analysis :: proc(
	t: ^Transform,
	sequence: Window_Sequence,
	previous_shape, shape: u8,
	input, spectrum: []f64,
) {
	n := t.frame_length
	assert(previous_shape < 2 && shape < 2 && len(input) == 2 * n && len(spectrum) == n)
	copy(t.analysis_input[:2 * n], input)
	if sequence == .Short {
		small := n / 8
		flat := (n - small) / 2
		for w in 0 ..< 8 {
			left := w == 0 ? previous_shape : shape
			base := flat + w * small
			for i in 0 ..< small {
				t.analysis_short[i] = t.analysis_input[base + i] * t.short_window[left][i]
				t.analysis_short[small + i] =
					t.analysis_input[base + small + i] * t.short_window[shape][small - 1 - i]
			}
			mdct(t, t.analysis_short[:2 * small], spectrum[w * small:(w + 1) * small])
		}
	} else {
		for i in 0 ..< n {
			t.analysis_input[i] *= long_window_left(t, n, sequence, previous_shape, i)
			t.analysis_input[n + i] *= long_window_right(t, n, sequence, shape, i)
		}
		mdct(t, t.analysis_input[:2 * n], spectrum)
	}
}

synthesize :: proc(
	t: ^Transform,
	bank: ^Filterbank,
	sequence: Window_Sequence,
	shape: u8,
	spectrum: []f64,
	output: []f32,
) {
	synthesize_to(1, t, bank, sequence, shape, spectrum, output)
}

@(private)
synthesis_storage_intersects :: #force_inline proc(
	a: rawptr,
	a_bytes: uintptr,
	b: rawptr,
	b_bytes: uintptr,
) -> bool {
	a_address, b_address := uintptr(a), uintptr(b)
	if a_address >= b_address do return a_address - b_address < b_bytes
	return b_address - a_address < a_bytes
}

// Write directly to the caller's sample slots. A stride of two with output
// sliced at the channel offset owns one channel of interleaved stereo PCM.
// The existing contiguous API above uses this same synthesis owner.
synthesize_to :: proc(
	$Stride: int,
	t: ^Transform,
	bank: ^Filterbank,
	sequence: Window_Sequence,
	shape: u8,
	spectrum: []f64,
	output: []f32,
) {
	#assert(Stride >= 1 && Stride <= 8)
	n := t.frame_length
	small_n := n / 8
	flat := (n - small_n) / 2
	assert(shape < 2 && len(spectrum) == n && len(output) >= (n - 1) * Stride + 1)
	// IMDCT writes the entire long block. Only short-window accumulation needs
	// a zero base, including its uncoded leading/trailing samples.
	block: [2048]f64 = ---
	if sequence == .Short {
		block = {}
		small: [256]f64 = ---
		for w in 0 ..< 8 {
			imdct(t, spectrum[w * small_n:(w + 1) * small_n], small[:2 * small_n])
			left := w == 0 ? bank.previous_shape : shape
			for i in 0 ..< small_n {
				block[flat + w * small_n + i] += small[i] * t.short_window[left][i]
				block[flat + w * small_n + small_n + i] +=
					small[small_n + i] * t.short_window[shape][small_n - 1 - i]
			}
		}
		for i in 0 ..< n {
			output[i * Stride] = f32((block[i] + bank.overlap[i]) / 32768)
			bank.overlap[i] = block[n + i]
		}
	} else {
		imdct(t, spectrum, block[:2 * n])
		// Full Long windows have a contiguous eight-sample domain. Preserve the
		// former scalar publication order for genuine exported-storage aliases.
		output_bytes := uintptr(((n - 1) * Stride + 1) * size_of(f32))
		disjoint :=
			!synthesis_storage_intersects(
				raw_data(output),
				output_bytes,
				bank,
				size_of(Filterbank),
			) &&
			!synthesis_storage_intersects(raw_data(output), output_bytes, t, size_of(Transform)) &&
			!synthesis_storage_intersects(bank, size_of(Filterbank), t, size_of(Transform))
		// Mono and interleaved stereo have a vector path; more channels take the
		// sample loop.
		fast := sequence == .Long && disjoint
		when Stride > 2 do fast = false
		when Stride <= 2 do if fast {
			left_window := t.long_window[bank.previous_shape][:]
			right_window := t.long_window[shape][:]
			for i := 0; i < n; i += 8 {
				current := intrinsics.unaligned_load((^simd.f64x8)(&block[i]))
				future := intrinsics.unaligned_load((^simd.f64x8)(&block[n + i]))
				left := intrinsics.unaligned_load((^simd.f64x8)(&left_window[i]))
				right := intrinsics.unaligned_load((^simd.f64x8)(&right_window[n - 8 - i]))
				right = simd.shuffle(right, right, 7, 6, 5, 4, 3, 2, 1, 0)
				overlap := intrinsics.unaligned_load((^simd.f64x8)(&bank.overlap[i]))
				value := simd.div(simd.add(simd.mul(current, left), overlap), simd.f64x8(32768))
				pcm := simd.f32x8(value)
				when Stride == 1 {
					intrinsics.unaligned_store((^simd.f32x8)(&output[i]), pcm)
				} else {
					stereo_mask :: #simd[16]bool{true, false, true, false, true, false, true, false, true, false, true, false, true, false, true, false}
					lanes := simd.shuffle(pcm, pcm, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7)
					// Inactive odd lanes are neither read nor written, including
					// lane 15 of the final store past a minimum 2047-slot slice.
					simd.masked_store(&output[2 * i], lanes, stereo_mask)
				}
				intrinsics.unaligned_store(
					(^simd.f64x8)(&bank.overlap[i]),
					simd.mul(future, right),
				)
			}
		}
		if !fast {
			for i in 0 ..< n {
				left := long_window_left(t, n, sequence, bank.previous_shape, i)
				right := long_window_right(t, n, sequence, shape, i)
				// Window, overlap, conversion and publication share one traversal.
				// No intermediate windowed plane or later interleave copy is needed.
				output[i * Stride] = f32((block[i] * left + bank.overlap[i]) / 32768)
				bank.overlap[i] = block[n + i] * right
			}
		}
	}
	bank.previous_shape = shape
}

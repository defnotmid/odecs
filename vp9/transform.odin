package vp9

// Inverse transforms (section 8.7). The 1-D transforms work in place on T,
// exactly as the butterfly sequences of the specification describe them.

@(private)
round2 :: #force_inline proc "contextless" (x: i64, n: uint) -> i32 {
	return i32((x + (i64(1) << (n - 1))) >> n)
}

@(private)
cos64 :: #force_inline proc "contextless" (angle: int) -> i64 {
	a := angle & 127
	switch {
	case a <= 32:
		return i64(COS64_LOOKUP[a])
	case a <= 64:
		return -i64(COS64_LOOKUP[64 - a])
	case a <= 96:
		return -i64(COS64_LOOKUP[a - 64])
	}
	return i64(COS64_LOOKUP[128 - a])
}

@(private)
sin64 :: #force_inline proc "contextless" (angle: int) -> i64 {return cos64(angle - 32)}

@(private)
brev :: #force_inline proc "contextless" (bits: uint, x: int) -> int {
	t := 0
	for i in 0 ..< bits do t |= ((x >> i) & 1) << (bits - 1 - i)
	return t
}

// Butterfly rotation, optionally swapping the outputs.
@(private)
B :: #force_inline proc "contextless" (t: ^[32]i32, a, b, angle: int, flip: bool) {
	x := i64(t[a]) * cos64(angle) - i64(t[b]) * sin64(angle)
	y := i64(t[a]) * sin64(angle) + i64(t[b]) * cos64(angle)
	t[a], t[b] = round2(x, 14), round2(y, 14)
	if flip do t[a], t[b] = t[b], t[a]
}

// Hadamard rotation; flip uses (b, a).
@(private)
H :: #force_inline proc "contextless" (t: ^[32]i32, a, b: int, flip: bool) {
	a, b := a, b
	if flip do a, b = b, a
	x, y := t[a], t[b]
	t[a], t[b] = x + y, x - y
}

@(private)
SB :: #force_inline proc "contextless" (t: ^[32]i32, s: ^[32]i64, a, b, angle: int, flip: bool) {
	s[a] = i64(t[a]) * cos64(angle) - i64(t[b]) * sin64(angle)
	s[b] = i64(t[a]) * sin64(angle) + i64(t[b]) * cos64(angle)
	if flip do s[a], s[b] = s[b], s[a]
}

@(private)
SH :: #force_inline proc "contextless" (t: ^[32]i32, s: ^[32]i64, a, b: int) {
	t[a], t[b] = round2(s[a] + s[b], 14), round2(s[a] - s[b], 14)
}

// Inverse DCT of 1 << n samples (8.7.1.2 permutation, then 8.7.1.3).
@(private)
idct :: proc "contextless" (t: ^[32]i32, n: uint) {
	copy_t := t^
	for i in 0 ..< 1 << n do t[i] = copy_t[brev(n, i)]
	idct_permuted(t, n)
}

@(private)
idct_permuted :: proc "contextless" (t: ^[32]i32, n: uint) {
	n0, n1 := 1 << n, 1 << (n - 1)
	n2 := 1 << (n - 2)
	n3 := n >= 3 ? 1 << (n - 3) : 0
	N := int(n)
	if n == 2 {
		B(t, 0, 1, 16, true)
	} else {
		idct_permuted(t, n - 1)
	}
	for i in 0 ..< n2 do B(t, n1 + i, n0 - 1 - i, 32 - brev(5, n1 + i), false)
	if n >= 3 {
		for i in 0 ..< n3 do for j in 0 ..< 2 do H(t, n1 + 4 * i + 2 * j, n1 + 1 + 4 * i + 2 * j, j == 1)
	}
	if n == 5 {
		for i in 0 ..< 2 do for j in 0 ..< 2 do B(t, n0 - N + 3 - n2 * j - 4 * i, n1 + N - 4 + n2 * j + 4 * i, 28 - 16 * i + 56 * j, true)
		for i in 0 ..< 2 do for j in 0 ..< 4 do H(t, n1 + n3 * j + i, n1 + n2 - 5 + n3 * j - i, j & 1 == 1)
	}
	if n >= 4 {
		for i in 0 ..= (n == 5 ? 1 : 0) do for j in 0 ..< 2 do B(t, n0 - N + 2 - i - n2 * j, n1 + N - 3 + i + n2 * j, 24 + 48 * j, true)
		for i in 0 ..= 2 * N - 7 do for j in 0 ..< 2 do H(t, n1 + n2 * j + i, n1 + n2 - 1 + n2 * j - i, j & 1 == 1)
	}
	if n >= 3 {
		for i in 0 ..< n3 do B(t, n0 - n3 - 1 - i, n1 + n3 + i, 16, true)
	}
	for i in 0 ..< n1 do H(t, i, n0 - 1 - i, false)
}

SINPI_1_9 :: 5283
SINPI_2_9 :: 9929
SINPI_3_9 :: 13377
SINPI_4_9 :: 15212

@(private)
iadst4 :: proc "contextless" (t: ^[32]i32) {
	s0 := i64(SINPI_1_9) * i64(t[0])
	s1 := i64(SINPI_2_9) * i64(t[0])
	s2 := i64(SINPI_3_9) * i64(t[1])
	s3 := i64(SINPI_4_9) * i64(t[2])
	s4 := i64(SINPI_1_9) * i64(t[2])
	s5 := i64(SINPI_2_9) * i64(t[3])
	s6 := i64(SINPI_4_9) * i64(t[3])
	v := i64(t[0]) - i64(t[2]) + i64(t[3])
	s7 := i64(SINPI_3_9) * v
	x0 := s0 + s3 + s5
	x1 := s1 - s4 - s6
	x2 := s7
	x3 := s2
	t[0] = round2(x0 + x3, 14)
	t[1] = round2(x1 + x3, 14)
	t[2] = round2(x2, 14)
	t[3] = round2(x0 + x1 - x3, 14)
}

@(private)
adst_input_permute :: proc "contextless" (t: ^[32]i32, n: uint) {
	n0, n1 := 1 << n, 1 << (n - 1)
	c := t^
	for i in 0 ..< n1 {
		t[2 * i] = c[n0 - 1 - 2 * i]
		t[2 * i + 1] = c[2 * i]
	}
}

@(private)
adst_output_permute :: proc "contextless" (t: ^[32]i32, n: uint) {
	c := t^
	if n == 4 {
		for a in 0 ..< 2 do for b in 0 ..< 2 do for cc in 0 ..< 2 do for d in 0 ..< 2 {
			t[8 * a + 4 * b + 2 * cc + d] = c[8 * (d ~ cc) + 4 * (cc ~ b) + 2 * (b ~ a) + a]
		}
	} else {
		for a in 0 ..< 2 do for b in 0 ..< 2 do for cc in 0 ..< 2 {
			t[4 * a + 2 * b + cc] = c[4 * (cc ~ b) + 2 * (b ~ a) + a]
		}
	}
}

@(private)
iadst8 :: proc "contextless" (t: ^[32]i32) {
	s: [32]i64
	adst_input_permute(t, 3)
	for i in 0 ..< 4 do SB(t, &s, 2 * i, 1 + 2 * i, 30 - 8 * i, true)
	for i in 0 ..< 4 do SH(t, &s, i, 4 + i)
	for i in 0 ..< 2 do SB(t, &s, 4 + 3 * i, 5 + i, 24 - 16 * i, true)
	for i in 0 ..< 2 do SH(t, &s, 4 + i, 6 + i)
	for i in 0 ..< 2 do H(t, i, 2 + i, false)
	for i in 0 ..< 2 do B(t, 2 + 4 * i, 3 + 4 * i, 16, true)
	adst_output_permute(t, 3)
	for i in 0 ..< 4 do t[1 + 2 * i] = -t[1 + 2 * i]
}

@(private)
iadst16 :: proc "contextless" (t: ^[32]i32) {
	s: [32]i64
	adst_input_permute(t, 4)
	for i in 0 ..< 8 do SB(t, &s, 2 * i, 1 + 2 * i, 31 - 4 * i, true)
	for i in 0 ..< 8 do SH(t, &s, i, 8 + i)
	for i in 0 ..< 4 do SB(t, &s, 8 + 2 * i, 9 + 2 * i, 28 - 16 * i, true)
	for i in 0 ..< 4 do SH(t, &s, 8 + i, 12 + i)
	for i in 0 ..< 4 do H(t, i, 4 + i, false)
	for i in 0 ..< 2 do for j in 0 ..< 2 do SB(t, &s, 4 + 8 * i + 3 * j, 5 + 8 * i + j, 24 - 16 * j, true)
	for i in 0 ..< 2 do for j in 0 ..< 2 do SH(t, &s, 4 + 8 * j + i, 6 + 8 * j + i)
	for i in 0 ..< 2 do for j in 0 ..< 2 do H(t, 8 * j + i, 2 + 8 * j + i, false)
	for i in 0 ..< 2 do for j in 0 ..< 2 do B(t, 2 + 4 * j + 8 * i, 3 + 4 * j + 8 * i, 48 + 64 * (i ~ j), false)
	adst_output_permute(t, 4)
	for i in 0 ..< 2 do for j in 0 ..< 2 do t[1 + 12 * j + 2 * i] = -t[1 + 12 * j + 2 * i]
}

@(private)
iadst :: #force_inline proc "contextless" (t: ^[32]i32, n: uint) {
	switch n {
	case 2:
		iadst4(t)
	case 3:
		iadst8(t)
	case:
		iadst16(t)
	}
}

@(private)
iwht :: proc "contextless" (t: ^[32]i32, shift: uint) {
	a := t[0] >> shift
	c := t[1] >> shift
	d := t[2] >> shift
	b := t[3] >> shift
	a += c
	d -= b
	e := (a - d) >> 1
	b = e - b
	c = e - c
	a -= b
	d += c
	t[0], t[1], t[2], t[3] = a, b, c, d
}

// 2-D inverse transform of a (1 << n)-square block of dequantized
// coefficients in raster order, in place (section 8.7.2). Rows at or past
// `rows` are known to be zero.
inverse_transform :: proc(block: []i32, n: uint, tx_type: int, lossless: bool, rows: int) {
	n0 := 1 << n
	t: [32]i32
	for i in 0 ..< n0 {
		row := block[i * n0:][:n0]
		if i >= rows {
			for &v in row do v = 0
			continue
		}
		copy(t[:n0], row)
		switch {
		case lossless:
			iwht(&t, 2)
		case tx_type == DCT_DCT || tx_type == ADST_DCT:
			idct(&t, n)
		case:
			iadst(&t, n)
		}
		copy(row, t[:n0])
	}
	for j in 0 ..< n0 {
		for i in 0 ..< n0 do t[i] = block[i * n0 + j]
		switch {
		case lossless:
			iwht(&t, 0)
		case tx_type == DCT_DCT || tx_type == DCT_ADST:
			idct(&t, n)
		case:
			iadst(&t, n)
		}
		shift := min(6, n + 2)
		for i in 0 ..< n0 do block[i * n0 + j] = lossless ? t[i] : round2(i64(t[i]), shift)
	}
}

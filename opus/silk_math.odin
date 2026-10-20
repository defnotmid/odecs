package opus

// SILK's fixed-point arithmetic (RFC 6716 4.2): Q-format multiplies with a
// 16-bit operand, rounding shifts and saturation. Odin integers wrap, so
// these are exact equivalents of libopus's macros.

@(private)
smulwb :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	return i32((i64(a) * i64(i16(b))) >> 16)
}

@(private)
smlawb :: #force_inline proc "contextless" (a, b, c: i32) -> i32 {
	return a + i32((i64(b) * i64(i16(c))) >> 16)
}

@(private)
smulww :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	return i32((i64(a) * i64(b)) >> 16)
}

@(private)
smlaww :: #force_inline proc "contextless" (a, b, c: i32) -> i32 {
	return a + i32((i64(b) * i64(c)) >> 16)
}

@(private)
smulbb :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	return i32(i16(a)) * i32(i16(b))
}

@(private)
smlabb :: #force_inline proc "contextless" (a, b, c: i32) -> i32 {
	return a + i32(i16(b)) * i32(i16(c))
}

@(private)
smmul :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	return i32((i64(a) * i64(b)) >> 32)
}

@(private)
rshift_round :: #force_inline proc "contextless" (a: i32, shift: uint) -> i32 {
	return shift == 1 ? (a >> 1) + (a & 1) : ((a >> (shift - 1)) + 1) >> 1
}

@(private)
rshift_round64 :: #force_inline proc "contextless" (a: i64, shift: uint) -> i64 {
	return shift == 1 ? (a >> 1) + (a & 1) : ((a >> (shift - 1)) + 1) >> 1
}

@(private)
sat16 :: #force_inline proc "contextless" (a: i32) -> i16 {
	return i16(clamp(a, -32768, 32767))
}

@(private)
add_sat32 :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	s := i64(a) + i64(b)
	return i32(clamp(s, i64(min(i32)), i64(max(i32))))
}

@(private)
sub_sat32 :: #force_inline proc "contextless" (a, b: i32) -> i32 {
	s := i64(a) - i64(b)
	return i32(clamp(s, i64(min(i32)), i64(max(i32))))
}

@(private)
lshift_sat32 :: #force_inline proc "contextless" (a: i32, shift: uint) -> i32 {
	return clamp(a, min(i32) >> shift, max(i32) >> shift) << shift
}

// Leading zeros of a 32-bit value (32 for 0).
@(private)
clz32 :: #force_inline proc "contextless" (x: i32) -> uint {
	return uint(32 - ilog(u32(x)))
}

// (1 << q) / b, approximated as libopus does.
@(private)
inverse32_varq :: proc "contextless" (b: i32, q: uint) -> i32 {
	headroom := clz32(abs(b)) - 1
	b_nrm := b << headroom
	b_inv := (max(i32) >> 2) / (b_nrm >> 16)
	result := b_inv << 16
	err_q32 := ((i32(1) << 29) - smulwb(b_nrm, b_inv)) << 3
	result = smlaww(result, err_q32, b_inv)
	shift := 61 - int(headroom) - int(q)
	if shift <= 0 do return lshift_sat32(result, uint(-shift))
	return shift < 32 ? result >> uint(shift) : 0
}

// (a << q) / b, approximated as libopus does.
@(private)
div32_varq :: proc "contextless" (a, b: i32, q: uint) -> i32 {
	a_headroom := clz32(abs(a)) - 1
	a_nrm := a << a_headroom
	b_headroom := clz32(abs(b)) - 1
	b_nrm := b << b_headroom
	b_inv := (max(i32) >> 2) / (b_nrm >> 16)
	result := smulwb(a_nrm, b_inv)
	a_nrm -= smmul(b_nrm, result) << 3
	result = smlawb(result, a_nrm, b_inv)
	shift := 29 + int(a_headroom) - int(b_headroom) - int(q)
	if shift < 0 do return lshift_sat32(result, uint(-shift))
	return shift < 32 ? result >> uint(shift) : 0
}

// 2^(x / 128), x in Q7.
@(private)
log2lin :: proc "contextless" (x: i32) -> i32 {
	if x < 0 do return 0
	if x >= 3967 do return max(i32)
	out := i32(1) << uint(x >> 7)
	frac := x & 0x7F
	poly := smlawb(frac, smulbb(frac, 128 - frac), -174)
	if x < 2048 do return out + ((out * poly) >> 7)
	return out + (out >> 7) * poly
}

@(private)
silk_rand :: #force_inline proc "contextless" (seed: i32) -> i32 {
	return i32(907633515 + u32(seed) * 196314165)
}

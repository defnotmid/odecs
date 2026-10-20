package h265_decoder

import "core:math/bits"

// ---------------------------------------------------------------------------
// MSB-first bit reader for RBSP syntax parsing, ported from gen2brain/h265
// hevc/getbits.go (MIT). oxideav-h265 src/bitreader.rs uses a bit cursor
// instead; this keeps the reference's 64-bit shift register so the ports line
// up one to one.
// ---------------------------------------------------------------------------

Get_Bits :: struct {
	state:     u64,
	bits_left: int,
	err:       bool,
	index:     int,
	data:      []u8,
}

get_bits_init :: proc(c: ^Get_Bits, data: []u8) {
	c^ = Get_Bits {
		data = data,
	}
}

@(private)
get_bits_refill :: proc(c: ^Get_Bits, n: int) {
	state: u32

	for {
		if c.index >= len(c.data) {
			c.err = true
			if state != 0 do break
			return
		}

		state = (state << 8) | u32(c.data[c.index])
		c.index += 1
		c.bits_left += 8

		if n <= c.bits_left do break
	}

	c.state |= u64(state) << uint(64 - c.bits_left)
}

get_bits_bit :: proc(c: ^Get_Bits) -> u32 {
	if c.bits_left == 0 do get_bits_refill(c, 1)

	state := c.state
	c.bits_left -= 1
	c.state = state << 1

	return u32(state >> 63)
}

get_bits_bits :: proc(c: ^Get_Bits, n: int) -> u32 {
	if n == 0 do return 0

	if n > c.bits_left do get_bits_refill(c, n)

	state := c.state
	c.bits_left -= n
	c.state = state << uint(n)

	return u32(state >> uint(64 - n))
}

get_bits_skip :: proc(c: ^Get_Bits, n_in: int) {
	n := n_in
	for n > 32 {
		get_bits_bits(c, 32)
		n -= 32
	}
	get_bits_bits(c, n)
}

// ue is the 0-th order unsigned Exp-Golomb descriptor of 9.2
// (codeNum = 2^n - 1 + read_bits(n)).
get_bits_ue :: proc(c: ^Get_Bits) -> u32 {
	n := 0
	for get_bits_bit(c) == 0 {
		n += 1
		if n > 31 {
			c.err = true
			return 0
		}
	}

	if n == 0 do return 0
	return (1 << uint(n)) - 1 + get_bits_bits(c, n)
}

// se is the signed mapping of 9.2.2: even codeNum is negative, odd positive.
get_bits_se :: proc(c: ^Get_Bits) -> i32 {
	v := get_bits_ue(c)
	k := i32((v + 1) / 2)

	if v & 1 == 0 do return -k
	return k
}

get_bits_pos :: proc(c: ^Get_Bits) -> int {
	return c.index * 8 - c.bits_left
}

get_bits_byte_align :: proc(c: ^Get_Bits) {
	n := get_bits_pos(c) & 7
	if n != 0 do get_bits_bits(c, 8 - n)
}

// moreRBSPData is 7.4.3.2.1: an RBSP still carries syntax after the reader
// position if more than the trailing one and zero bits remain.
get_bits_more_rbsp_data :: proc(c: ^Get_Bits) -> bool {
	p := get_bits_pos(c)
	byte_off := p >> 3
	bit_off := p & 7

	if byte_off >= len(c.data) do return false

	last := len(c.data)
	for last > byte_off && c.data[last - 1] == 0 do last -= 1

	if last <= byte_off do return false
	if byte_off < last - 1 do return true

	return bit_off < 7 - int(bits.trailing_zeros(c.data[byte_off]))
}

package common

import "core:math/bits"

// ---------------------------------------------------------------------------
// RBSP bit writer shared by the H.264 and H.265 encoders. `cache` holds up to
// 7 pending bits LSB-aligned; whole bytes are appended to the caller-owned
// `buf` as they complete.
// ---------------------------------------------------------------------------

Bit_Writer :: struct {
	buf:   ^[dynamic]u8,
	cache: u64,
	nbits: int,
}

init_bit_writer :: proc(out_buf: ^[dynamic]u8) -> Bit_Writer {
	clear(out_buf)
	return Bit_Writer{buf = out_buf}
}

// Append the low `n` bits of `value`, MSB first. n <= 32.
write_bits :: proc(writer: ^Bit_Writer, value: u32, n: int) {
	if n <= 0 do return
	writer.cache = writer.cache << uint(n) | u64(bits.bitfield_extract(value, 0, uint(n)))
	writer.nbits += n
	for writer.nbits >= 8 {
		writer.nbits -= 8
		append(writer.buf, u8(writer.cache >> uint(writer.nbits)))
	}
}

// Unsigned Exp-Golomb: len(val+1)-1 zeros followed by val+1 in binary.
write_ue :: proc(writer: ^Bit_Writer, val: u32) {
	v := val + 1
	lz := bits.len_u32(v) - 1
	write_bits(writer, 0, lz)
	write_bits(writer, v, lz + 1)
}

// Signed Exp-Golomb
write_se :: proc(writer: ^Bit_Writer, val: i32) {
	write_ue(writer, val > 0 ? u32(2 * val - 1) : u32(-2 * val))
}

// rbsp_trailing_bits: a one bit, then zero bits up to the byte boundary.
write_rbsp_trailing_bits :: proc(writer: ^Bit_Writer) {
	write_bits(writer, 1, 1)
	write_bits(writer, 0, -writer.nbits & 7)
}

// Flush the pending bits as a whole byte, padding with zero bits.
write_align_zero :: proc(writer: ^Bit_Writer) {
	if writer.nbits > 0 do write_bits(writer, 0, 8 - writer.nbits)
}

bits_written :: proc(writer: ^Bit_Writer) -> int {
	return len(writer.buf) * 8 + writer.nbits
}

// ---------------------------------------------------------------------------
// Annex B framing with emulation prevention (00 00 03).
// ---------------------------------------------------------------------------

// Append a start code, the NAL header bytes and the emulation-prevented RBSP.
append_nal_annex_b :: proc(out: ^[dynamic]u8, header: []u8, rbsp: []u8, long_start_code := true) {
	start := len(out)
	prefix := long_start_code ? 1 : 0
	resize(out, start + prefix + 3 + len(header) + len(rbsp) + len(rbsp) / 2 + 1)
	dst := out[start:]
	n := 0
	if long_start_code {
		dst[n] = 0
		n += 1
	}
	dst[n], dst[n + 1], dst[n + 2] = 0, 0, 1
	n += 3
	copy(dst[n:], header)
	n += len(header)
	zeros := 0
	#no_bounds_check for b in rbsp {
		if zeros == 2 && b <= 3 {
			dst[n] = 3
			n += 1
			zeros = 0
		}
		dst[n] = b
		n += 1
		zeros = b == 0 ? zeros + 1 : 0
	}
	resize(out, start + n)
}

package common

import "base:intrinsics"
import "core:math/bits"

// ---------------------------------------------------------------------------
// MSB-first bit reader with a 64-bit cache. Reading past the end yields zero
// bits and drives `left` negative, which callers check once per stage.
// ---------------------------------------------------------------------------

Bit_Reader :: struct {
	cache: u64,
	count: int, // valid bits in cache
	left:  int, // bits remaining in data; negative after an overrun
	next:  int, // next byte to load
	data:  []u8,
}

// A reader at the first bit of data.
bit_reader :: #force_inline proc "contextless" (data: []u8) -> Bit_Reader {
	return {data = data, left = len(data) * 8}
}

refill_bits :: #force_inline proc(r: ^Bit_Reader) {
	if r.count > 56 do return
	if r.next + 8 <= len(r.data) {
		v := u64(intrinsics.unaligned_load((^u64be)(raw_data(r.data[r.next:]))))
		r.cache |= v >> uint(r.count)
		r.next += (63 - r.count) >> 3
		r.count |= 56
		return
	}
	for r.count <= 56 {
		b := r.next < len(r.data) ? r.data[r.next] : 0
		r.cache |= u64(b) << uint(56 - r.count)
		r.next += 1
		r.count += 8
	}
}

skip_bits :: #force_inline proc(r: ^Bit_Reader, n: int) {
	r.cache <<= uint(n)
	r.count -= n
	r.left -= n
}

// Up to 32 bits, unsigned.
read_bits :: #force_inline proc(r: ^Bit_Reader, n: int) -> u32 {
	if n <= 0 do return 0
	refill_bits(r)
	v := u32(r.cache >> uint(64 - n))
	skip_bits(r, n)
	return v
}

// Up to 33 bits (e.g. a 32-bit FLAC side channel), two's complement.
read_signed_bits :: #force_inline proc(r: ^Bit_Reader, n: int) -> i64 {
	if n <= 0 do return 0
	v := n > 32 ? i64(read_bits(r, n - 32)) << 32 | i64(read_bits(r, 32)) : i64(read_bits(r, n))
	return v << uint(64 - n) >> uint(64 - n)
}

// A unary count of zero bits ended by a one bit. The one bit counts only
// within the cache's valid bits: the cache can hold more of the stream than
// `count` says (refill_bits' wide load), and a one bit past `count` is taken
// on the next refill, not now (that would make `count` negative).
read_unary :: #force_inline proc(r: ^Bit_Reader) -> (q: u64) {
	refill_bits(r)
	for {
		z := int(intrinsics.count_leading_zeros(r.cache))
		if z < r.count {
			skip_bits(r, z + 1)
			return q + u64(z)
		}
		q += u64(r.count)
		skip_bits(r, r.count)
		if r.left < 0 do return
		refill_bits(r)
	}
}

advance_bits :: proc(r: ^Bit_Reader, n: int) {
	if n <= r.count {
		skip_bits(r, n)
		return
	}
	pos := (len(r.data) * 8 - r.left) + n
	r.left = len(r.data) * 8 - pos
	if r.left < 0 {
		r.cache, r.count, r.next = 0, 0, len(r.data)
		return
	}
	r.next = pos >> 3
	bit_off := pos & 7
	r.cache, r.count = 0, 0
	refill_bits(r)
	r.cache <<= uint(bit_off)
	r.count -= bit_off
}

align_byte :: #force_inline proc(r: ^Bit_Reader) {
	bit_off := (len(r.data) * 8 - r.left) & 7
	if bit_off != 0 do skip_bits(r, 8 - bit_off)
}

byte_position :: #force_inline proc(r: ^Bit_Reader) -> int {
	return len(r.data) - (r.left + 7) / 8
}

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

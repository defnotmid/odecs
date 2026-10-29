package h264

import common "../../common"

// Locate Annex B NAL payloads. Returned offsets exclude start codes.
find_nal_units :: proc(data: []u8, allocator := context.allocator) -> []Nal_Location {
	nals := make([dynamic]Nal_Location, 0, 64, allocator)
	start := -1
	for i := 0; i + 3 <= len(data); {
		sc := 0
		if data[i] == 0 && data[i + 1] == 0 {
			if data[i + 2] ==
			   1 {sc = 3} else if i + 4 <= len(data) && data[i + 2] == 0 && data[i + 3] == 1 {sc = 4}
		}
		if sc == 0 {i += 1; continue}
		if start >= 0 do append(&nals, Nal_Location{start, i - start})
		start = i + sc
		i = start
	}
	if start >= 0 do append(&nals, Nal_Location{start, len(data) - start})
	return nals[:]
}

import "base:intrinsics"

// ---------------------------------------------------------------------------
// RBSP bit reader. `cache` holds the next unread bits MSB-aligned; `pos` is
// the next byte of `data` not yet loaded into the cache. Reads past the end
// of `data` yield zero bits; callers bound their loops with `bit_pos`.
// ---------------------------------------------------------------------------

Bit_Reader :: struct {
	data:         []u8,
	pos:          int,
	cache:        u64,
	bits_left:    int,
	bit_pos:      int,
	stop_bit_pos: int, // position of rbsp_stop_one_bit, -1 if absent
}

init_bit_reader :: proc(data: []u8) -> Bit_Reader {
	reader := Bit_Reader {
		data         = data,
		stop_bit_pos = -1,
	}
	#no_bounds_check for i := len(data) - 1; i >= 0; i -= 1 {
		if b := data[i]; b != 0 {
			reader.stop_bit_pos = i * 8 + 7 - int(intrinsics.count_trailing_zeros(b))
			break
		}
	}
	refill(&reader)
	refill(&reader)
	return reader
}

// Top up the cache to more than 32 valid bits with the next 32 bits of input.
refill :: #force_inline proc(reader: ^Bit_Reader) #no_bounds_check {
	if reader.bits_left > 32 do return
	val: u32
	avail := len(reader.data) - reader.pos
	if avail >= 4 {
		#no_bounds_check val = u32(intrinsics.unaligned_load((^u32be)(&reader.data[reader.pos])))
		reader.pos += 4
	} else {
		#no_bounds_check for i in 0 ..< avail {
			val = val << 8 | u32(reader.data[reader.pos + i])
		}
		val <<= uint(4 - avail) * 8
		reader.pos = len(reader.data)
	}
	reader.cache |= u64(val) << uint(32 - reader.bits_left)
	reader.bits_left += 32
}

skip_bits :: #force_inline proc(reader: ^Bit_Reader, n: uint) #no_bounds_check {
	reader.cache <<= n
	reader.bits_left -= int(n)
	reader.bit_pos += int(n)
	refill(reader)
}

// The cache is MSB-aligned, so the top n bits are the field: no mask needed
// (bits.bitfield_extract's redundant mask costs ~1% of decode time in CAVLC).
peek_bits :: #force_inline proc(reader: ^Bit_Reader, n: uint) -> u32 #no_bounds_check {
	return u32(reader.cache >> (64 - n))
}

read_bits :: #force_inline proc(reader: ^Bit_Reader, n: uint) -> u32 #no_bounds_check {
	val := peek_bits(reader, n)
	skip_bits(reader, n)
	return val
}

read_bit :: #force_inline proc(reader: ^Bit_Reader) -> u32 {
	return read_bits(reader, 1)
}

// Exp-Golomb unsigned integer
read_ue :: #force_inline proc(reader: ^Bit_Reader) -> u32 {
	lz := uint(intrinsics.count_leading_zeros(reader.cache))
	if lz >= 32 {
		skip_bits(reader, 32)
		return 0
	}
	return read_bits(reader, 2 * lz + 1) - 1
}

// Exp-Golomb signed integer
read_se :: #force_inline proc(reader: ^Bit_Reader) -> i32 {
	ue := read_ue(reader)
	return (ue & 1) != 0 ? i32((ue + 1) >> 1) : -i32(ue >> 1)
}

// Truncated Exp-Golomb
read_te :: #force_inline proc(reader: ^Bit_Reader, max_val: u32) -> u32 {
	if max_val > 1 {
		return read_ue(reader)
	}
	return 1 - read_bit(reader)
}

// Reposition to an absolute bit position
seek_bits :: proc(reader: ^Bit_Reader, bit_pos: int) {
	reader.pos = bit_pos >> 3
	reader.cache = 0
	reader.bits_left = 0
	reader.bit_pos = bit_pos - (bit_pos & 7)
	refill(reader)
	refill(reader)
	skip_bits(reader, uint(bit_pos & 7))
}

byte_align :: #force_inline proc(reader: ^Bit_Reader) {
	skip_bits(reader, uint(-reader.bit_pos & 7))
}

has_more_rbsp_data :: #force_inline proc(reader: ^Bit_Reader) -> bool {
	return reader.bit_pos < reader.stop_bit_pos
}

// ---------------------------------------------------------------------------
// NAL payload <-> RBSP: emulation prevention (00 00 03) removal and insertion.
// ---------------------------------------------------------------------------

has_emulation_prevention :: proc(data: []u8) -> bool {
	#no_bounds_check for i := 0; i + 2 < len(data); i += 1 {
		if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 3 do return true
	}
	return false
}

// Strip emulation prevention bytes. Returns `nal` itself when there are none,
// otherwise the unescaped copy in the caller-owned scratch buffer.
unescape_rbsp_into_buffer :: proc(nal: []u8, scratch: ^[dynamic]u8) -> []u8 {
	if !has_emulation_prevention(nal) do return nal
	resize(scratch, len(nal))
	n := 0
	#no_bounds_check for i := 0; i < len(nal); {
		if i + 2 < len(nal) && nal[i] == 0 && nal[i + 1] == 0 && nal[i + 2] == 3 {
			scratch[n], scratch[n + 1] = 0, 0
			n += 2
			i += 3
		} else {
			scratch[n] = nal[i]
			n += 1
			i += 1
		}
	}
	return scratch[:n]
}

// Append a 4-byte start code, NAL header and emulation-prevented RBSP.
write_nal_annex_b :: proc(out: ^[dynamic]u8, nal_ref_idc, nal_unit_type: u8, rbsp: []u8) {
	start := len(out)
	resize(out, start + 5 + len(rbsp) + len(rbsp) / 2 + 1) // worst case: every 00 00 xx grows by one
	dst := out[start:]
	dst[0], dst[1], dst[2], dst[3] = 0, 0, 0, 1
	dst[4] = (nal_ref_idc & 3) << 5 | (nal_unit_type & 0x1F)
	n := 5
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

// ---------------------------------------------------------------------------
// RBSP bit writer (shared via package common).
// ---------------------------------------------------------------------------

Bit_Writer :: common.Bit_Writer
init_bit_writer :: common.init_bit_writer
write_bits :: common.write_bits
write_unsigned_exp_golomb :: common.write_ue
write_signed_exp_golomb :: common.write_se
flush_bits_rbsp :: common.write_rbsp_trailing_bits

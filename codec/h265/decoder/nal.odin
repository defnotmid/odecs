package h265_decoder

import hevc ".."

Nal_Type :: hevc.Nal_Type

// ---------------------------------------------------------------------------
// NAL unit framing (ITU-T H.265 7.3.1.2). Ported from gen2brain/h265
// hevc/nal.go (MIT); oxideav-h265 src/nal.rs is a per-file cross-reference.
// ---------------------------------------------------------------------------

// IsVCL reports whether the unit carries a coded slice segment.
nal_type_is_vcl :: #force_inline proc(t: Nal_Type) -> bool {
	return u8(t) < 32
}

// IsIDR reports whether the unit starts an instantaneous decoding refresh picture.
nal_type_is_idr :: #force_inline proc(t: Nal_Type) -> bool {
	return t == .IDR_W_RADL || t == .IDR_N_LP
}

// IsIRAP reports whether the unit starts an intra random access point picture.
nal_type_is_irap :: #force_inline proc(t: Nal_Type) -> bool {
	return t >= .BLA_W_LP && t <= .CRA_NUT
}

Nal_Unit :: struct {
	type:        Nal_Type,
	layer_id:    u8,
	temporal_id: u8,
	rbsp:        []u8,
	epb:         []u32, // payload-relative positions of removed 0x03 bytes
	borrowed:    bool, // parse_nal_into views belong to its Nal_Scratch
}

// Streaming parsers reuse both allocations. A returned borrowed NAL is valid
// until the next parse into this scratch or destroy_nal_scratch. A scratch is
// owned by one decoder thread; it must not be copied after its first parse.
Nal_Scratch :: struct {
	rbsp: [dynamic]u8,
	epb:  [dynamic]u32,
}

destroy_nal_scratch :: proc(scratch: ^Nal_Scratch) {
	delete(scratch.rbsp)
	delete(scratch.epb)
	scratch^ = {}
}

@(private)
nal_unescape_into :: proc(data: []u8, scratch: ^Nal_Scratch) {
	// One size admission covers every output byte, avoiding a dynamic append
	// and capacity check for each byte of the compressed slice payload.
	resize(&scratch.rbsp, len(data))
	clear(&scratch.epb)
	j := 0
	for i := 0; i < len(data); {
		if i + 2 < len(data) && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 3 {
			scratch.rbsp[j], scratch.rbsp[j + 1] = 0, 0
			j += 2
			append(&scratch.epb, u32(i + 2))
			i += 3
			continue
		}
		scratch.rbsp[j] = data[i]
		j += 1
		i += 1
	}
	resize(&scratch.rbsp, j)
}

// DestroyNal frees owned buffers; borrowed views are merely cleared.
destroy_nal :: proc(n: ^Nal_Unit) {
	if !n.borrowed {
		delete(n.rbsp)
		delete(n.epb)
	}
	n^ = {}
}

// ParseNAL parses a single NAL unit with a two-byte header and no framing.
// Its returned buffers are owned and must be released with destroy_nal.
parse_nal :: proc(data: []u8) -> (nal: Nal_Unit, ok: bool) {
	scratch: Nal_Scratch
	nal, ok = parse_nal_into(data, &scratch)
	nal.borrowed = false
	return nal, ok
}

// The parsed NAL borrows scratch buffers, so a streaming decoder can parse
// successive packets without allocating after capacity has warmed up. Invalid
// headers do not mutate the scratch. destroy_nal never frees borrowed buffers.
parse_nal_into :: proc(data: []u8, scratch: ^Nal_Scratch) -> (nal: Nal_Unit, ok: bool) {
	if scratch == nil do return {}, false
	if len(data) < 2 do return {}, false

	b0, b1 := data[0], data[1]
	if b0 & 0x80 != 0 do return {}, false

	tid_plus1 := b1 & 0x07
	if tid_plus1 == 0 do return {}, false

	nal_unescape_into(data[2:], scratch)
	return Nal_Unit {
			type = Nal_Type((b0 >> 1) & 0x3f),
			layer_id = ((b0 & 0x01) << 5) | (b1 >> 3),
			temporal_id = tid_plus1 - 1,
			rbsp = scratch.rbsp[:],
			epb = scratch.epb[:],
			borrowed = true,
		},
		true
}

@(private)
nal_start_code :: proc(data: []u8, off: int) -> (next, start: int, ok: bool) {
	for i := off; i + 2 < len(data); i += 1 {
		if data[i] != 0 || data[i + 1] != 0 do continue
		if data[i + 2] == 1 do return i + 3, i, true
		if i + 3 < len(data) && data[i + 2] == 0 && data[i + 3] == 1 do return i + 4, i, true
	}
	return 0, 0, false
}

// SplitAnnexB splits a start-code delimited byte stream into NAL units.
split_annex_b :: proc(data: []u8) -> [dynamic]Nal_Unit {
	nals: [dynamic]Nal_Unit

	i, _, ok := nal_start_code(data, 0)
	if !ok do return nals

	for i < len(data) {
		next, sc_start, found := nal_start_code(data, i)

		end := len(data)
		if found {
			end = sc_start
			for end > i && data[end - 1] == 0 do end -= 1
		}

		if nal, good := parse_nal(data[i:end]); good do append(&nals, nal)
		if !found do break

		i = next
	}
	return nals
}

// SplitHVCC splits length-prefixed NAL units, as framed inside hvcC.
split_hvcc :: proc(data: []u8, length_size: int) -> [dynamic]Nal_Unit {
	nals: [dynamic]Nal_Unit
	if length_size < 1 || length_size > 4 do return nals

	for i := 0; i + length_size <= len(data); {
		n := 0
		for j in 0 ..< length_size do n = n << 8 | int(data[i + j])

		i += length_size
		if n == 0 || i + n > len(data) do break

		if nal, ok := parse_nal(data[i:i + n]); ok do append(&nals, nal)
		i += n
	}
	return nals
}

// RBSPOffset converts a payload-relative byte position, as entry point offsets
// count them, into an index into RBSP.
nal_rbsp_offset :: proc(n: Nal_Unit, off: int) -> int {
	rbsp := off
	for p in n.epb {
		if int(p) >= off do break
		rbsp -= 1
	}
	return rbsp
}

// NALOffset is the inverse of RBSPOffset.
nal_offset :: proc(n: Nal_Unit, off_in: int) -> int {
	off := off_in
	for p in n.epb {
		if int(p) <= off {
			off += 1
			continue
		}
		break
	}
	return off
}

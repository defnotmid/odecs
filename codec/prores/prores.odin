// Apple ProRes bitstream syntax shared by the decoder (and a future encoder):
// frame and picture headers, the slice layout of a picture, scan orders and
// the entropy codebooks. Written from SMPTE RDD 36 (Apple ProRes Bitstream
// Syntax and Decoding Process).
package prores

import "core:math/bits"

Error :: enum {
	None,
	Invalid_Data, // malformed or truncated
	Unsupported,  // valid, outside the implemented scope
	Out_Of_Memory,
}

Chroma :: enum u8 {
	YUV422,
	YUV444,
}

Interlace :: enum u8 {
	Progressive,
	Top_First,    // first picture holds the top field (even lines)
	Bottom_First, // first picture holds the bottom field
}

// Frame header fields, with the quantization matrices resolved: a matrix the
// frame does not load is all 4s (luma) or a copy of luma (chroma). Matrices
// are in raster order.
Frame_Header :: struct {
	frame_size:           int, // bytes of the whole frame, header included
	header_size:          int,
	version:              u8,
	encoder:              [4]u8,
	width, height:        int,
	chroma:               Chroma,
	interlace:            Interlace,
	aspect_ratio:         u8,
	frame_rate:           u8,
	primaries, transfer:  u8, // ITU-T H.273 code points; 0 is unspecified
	matrix_coeffs:        u8,
	alpha_bits:           int, // 0 (no alpha), 8 or 16
	luma_qmat, chroma_qmat: [64]u8,
	pictures:             []u8, // the coded pictures (two fields when interlaced)
}

Picture_Header :: struct {
	header_size:         int,
	size:                int, // bytes of the picture, header included
	log2_slice_mb_width: uint, // 0..3: slices are up to 8 macroblocks wide
	slice_sizes:         []u8, // big-endian u16 per slice, in slice order
	slices:              []u8, // slice data, consecutive
}

MAX_SLICE_MBS :: 8

parse_frame_header :: proc(data: []u8) -> (h: Frame_Header, err: Error) {
	if len(data) < 28 do return h, .Invalid_Data
	h.frame_size = int(be32(data))
	if h.frame_size < 28 || h.frame_size > len(data) || string(data[4:8]) != "icpf" do return h, .Invalid_Data
	frame := data[:h.frame_size]
	b := frame[8:]
	h.header_size = int(be16(b))
	if h.header_size < 20 || h.header_size > len(b) do return h, .Invalid_Data
	h.version = b[3]
	if h.version > 1 do return h, .Unsupported
	copy(h.encoder[:], b[4:8])
	h.width, h.height = int(be16(b[8:])), int(be16(b[10:]))
	if h.width == 0 || h.height == 0 do return h, .Invalid_Data
	switch b[12] >> 6 {
	case 2:
		h.chroma = .YUV422
	case 3:
		h.chroma = .YUV444
	case:
		return h, .Unsupported
	}
	switch (b[12] >> 2) & 3 {
	case 0:
		h.interlace = .Progressive
	case 1:
		h.interlace = .Top_First
	case 2:
		h.interlace = .Bottom_First
	case:
		return h, .Invalid_Data
	}
	h.aspect_ratio, h.frame_rate = b[13] >> 4, b[13] & 15
	h.primaries, h.transfer, h.matrix_coeffs = b[14], b[15], b[16]
	switch b[17] & 15 {
	case 0:
		h.alpha_bits = 0
	case 1:
		h.alpha_bits = 8
	case 2:
		h.alpha_bits = 16
	case:
		return h, .Unsupported
	}
	flags := b[19]
	at := 20
	if flags & 2 != 0 {
		if at + 64 > h.header_size do return h, .Invalid_Data
		copy(h.luma_qmat[:], b[at:][:64])
		at += 64
	} else {
		for &q in h.luma_qmat do q = 4
	}
	if flags & 1 != 0 {
		if at + 64 > h.header_size do return h, .Invalid_Data
		copy(h.chroma_qmat[:], b[at:][:64])
	} else {
		h.chroma_qmat = h.luma_qmat
	}
	for q in h.luma_qmat do if q == 0 do return h, .Invalid_Data
	for q in h.chroma_qmat do if q == 0 do return h, .Invalid_Data
	h.pictures = b[h.header_size:]
	return h, .None
}

// Parses the picture at the start of `data`; `rest` follows it (the second
// field of an interlaced frame).
parse_picture_header :: proc(data: []u8, slice_count: int) -> (p: Picture_Header, rest: []u8, err: Error) {
	if len(data) < 8 do return p, nil, .Invalid_Data
	p.header_size = int(data[0] >> 3)
	p.size = int(be32(data[1:]))
	if p.header_size < 8 || p.size < p.header_size + 2 * slice_count || p.size > len(data) do return p, nil, .Invalid_Data
	p.log2_slice_mb_width = uint(data[7] >> 4)
	if p.log2_slice_mb_width > 3 || data[7] & 15 != 0 do return p, nil, .Unsupported
	table := p.header_size + 2 * slice_count
	p.slice_sizes = data[p.header_size:table]
	p.slices = data[table:p.size]
	return p, data[p.size:], .None
}

// Macroblock grid of one coded picture: a field picture covers the frame's
// lines of its parity, so it has half the rows (rounded up).
picture_mbs :: proc(h: Frame_Header) -> (mb_width, mb_height: int) {
	rows := h.interlace == .Progressive ? h.height : (h.height + 1) / 2
	return (h.width + 15) / 16, (rows + 15) / 16
}

// Slices per macroblock row: full slices of 1 << log2 macroblocks, then the
// remainder split into decreasing powers of two (20 MBs at 8 -> 8, 8, 4).
slices_per_row :: proc(mb_width: int, log2_slice_mb_width: uint) -> int {
	return mb_width >> log2_slice_mb_width + bits.count_ones(mb_width & (1 << log2_slice_mb_width - 1))
}

// Width in macroblocks of the slice starting at mb_x.
slice_mb_count :: proc(mb_width, mb_x: int, log2_slice_mb_width: uint) -> int {
	n := 1 << log2_slice_mb_width
	for n > mb_width - mb_x do n >>= 1
	return n
}

// Quantization index 1..224 to the scale applied to both matrices.
qscale :: proc(index: u8) -> i32 {
	return index <= 128 ? i32(index) : 128 + (i32(index) - 128) * 4
}

// Entropy codebooks: bits 7..5 Rice order, 4..2 exp-Golomb order, 1..0 the
// largest Rice prefix before the code switches to exp-Golomb.
FIRST_DC_CODEBOOK :: 0xB8
@(rodata)
DC_CODEBOOKS := [7]u8{0x04, 0x28, 0x28, 0x4D, 0x4D, 0x70, 0x70}
@(rodata)
RUN_CODEBOOKS := [16]u8{0x06, 0x06, 0x05, 0x05, 0x04, 0x29, 0x29, 0x29, 0x29, 0x28, 0x28, 0x28, 0x28, 0x28, 0x28, 0x4C}
@(rodata)
LEVEL_CODEBOOKS := [10]u8{0x04, 0x0A, 0x05, 0x06, 0x04, 0x28, 0x28, 0x28, 0x28, 0x4C}

// Scan order to raster position, for progressive frames and field pictures.
@(rodata)
PROGRESSIVE_SCAN := [64]u8 {
	0, 1, 8, 9, 2, 3, 10, 11,
	16, 17, 24, 25, 18, 19, 26, 27,
	4, 5, 12, 20, 13, 6, 7, 14,
	21, 28, 29, 22, 15, 23, 30, 31,
	32, 33, 40, 48, 41, 34, 35, 42,
	49, 56, 57, 50, 43, 36, 37, 44,
	51, 58, 59, 52, 45, 38, 39, 46,
	53, 60, 61, 54, 47, 55, 62, 63,
}
@(rodata)
INTERLACED_SCAN := [64]u8 {
	0, 8, 1, 9, 16, 24, 17, 25,
	2, 10, 3, 11, 18, 26, 19, 27,
	32, 40, 33, 34, 41, 48, 56, 49,
	42, 35, 43, 50, 57, 58, 51, 59,
	4, 12, 5, 6, 13, 20, 28, 21,
	14, 7, 15, 22, 29, 36, 44, 37,
	30, 23, 31, 38, 45, 52, 60, 53,
	46, 39, 47, 54, 61, 62, 55, 63,
}

be16 :: #force_inline proc "contextless" (b: []u8) -> u16 {return u16(b[0]) << 8 | u16(b[1])}
be32 :: #force_inline proc "contextless" (b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

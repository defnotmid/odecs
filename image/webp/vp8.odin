package webp

import common "../../common"
import "base:intrinsics"

// VP8 key frames (RFC 6386), WebP's lossy format: macroblocks of 16x16 luma
// and two 8x8 chroma blocks, intra predicted (whole-block or per 4x4 luma
// subblock) from the unfiltered pixels above and to the left, plus residuals
// from boolean-coded DCT/WHT coefficients; then the in-loop deblocking filter
// over the whole frame.
//
// Written from RFC 6386 and libwebp 1.6.0 (BSD-3-Clause), whose tables
// tables.odin copies.

// The boolean entropy decoder (RFC 6386 7) is common's, shared with VP9;
// these read it as VP8 does: bits as bools, and n-bit values with a sign.
@(private)
get_bit :: #force_inline proc(br: ^common.Bool_Decoder, prob: u8) -> bool {return common.bool_decode(br, prob) == 1}

@(private)
get_value :: #force_inline proc(br: ^common.Bool_Decoder, bits: int) -> int {return common.bool_literal(br, bits)}

@(private)
get_signed_value :: proc(br: ^common.Bool_Decoder, bits: int) -> int {
	v := get_value(br, bits)
	return get_bit(br, 128) ? -v : v
}

// Intra modes, in libwebp's order (its probability tables are indexed so).
@(private)
B_DC, B_TM, B_VE, B_HE, B_RD, B_VR, B_LD, B_VL, B_HD, B_HU :: 0, 1, 2, 3, 4, 5, 6, 7, 8, 9
// Whole-block modes share the first four values; DC has edge variants.
@(private)
DC_PRED, TM_PRED, V_PRED, H_PRED :: B_DC, B_TM, B_VE, B_HE
@(private)
DC_NO_TOP, DC_NO_LEFT, DC_NO_TOP_LEFT :: 4, 5, 6

@(private)
Segment_Header :: struct {
	enabled:     bool,
	update_map:  bool,
	absolute:    bool,
	quantizer:   [4]int,
	filter:      [4]int,
	tree_probs:  [3]u8,
}

@(private)
Filter_Header :: struct {
	simple:          bool,
	level:           int,
	sharpness:       int,
	use_deltas:      bool,
	ref_delta:       [4]int,
	mode_delta:      [4]int,
}

// Per segment and block type (whole-block, 4x4): the filter parameters.
@(private)
Filter_Strength :: struct {
	limit:      u8, // 0: no filtering
	inner:      u8, // interior limit
	hev:        u8, // high edge variance threshold
}

@(private)
Quant :: struct {
	y1, y2, uv: [2]i32, // DC, AC steps
}

// A decoded frame: Y, U and V planes, the size rounded up to whole
// macroblocks.
Yuv :: struct {
	width, height:     int,
	y, u, v:           []u8,
	y_stride:          int,
	uv_stride:         int,
}

@(private)
Vp8 :: struct {
	using frame:   Yuv,
	mb_w, mb_h:    int,
	segments:      Segment_Header,
	filter:        Filter_Header,
	quant:         [4]Quant,
	probs:         [4][8][3][11]u8,
	skip_prob:     u8,
	use_skip:      bool,
	parts:         [8]common.Bool_Decoder,
	part_count:    int,
	strengths:     [4][2]Filter_Strength,
	// Per macroblock, for the filter pass (row-major).
	mb_filter:     []u8, // segment * 2 + is 4x4
	mb_inner:      []bool, // inner edges filtered: 4x4, or any coefficient
	// Contexts carried along a row and down the columns.
	intra_top:     []u8, // the 4x4 modes along the bottom of the row above, 4 per macroblock
	nz_top:        []u8, // nonzero flags: 4 luma, 2 U, 2 V bits per macroblock
	nz_dc_top:     []u8,
}

@(private)
Macroblock :: struct {
	segment:   int,
	skip:      bool,
	is_4x4:    bool,
	ymode:     int,
	modes:     [16]u8, // 4x4 modes, raster order
	uvmode:    int,
	coeffs:    [384]i16, // 16 luma, 4 U, 4 V blocks of 16
	kind:      [24]u8, // per block: 0 nothing, 1 DC only, 2 full transform
}

@(private)
ZIGZAG := [16]u8{0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15}
@(private)
BANDS := [17]u8{0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0} // the 17th: past the end

// Decodes a VP8 key frame into planes allocated with `allocator`.
decode_vp8 :: proc(data: []u8, allocator := context.allocator) -> (out: Yuv, err: Error) {
	d: Vp8
	if len(data) < 10 do return {}, .Invalid
	tag := u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16
	if tag & 1 != 0 do return {}, .Unsupported // an inter frame
	if (tag >> 1) & 7 > 3 do return {}, .Invalid
	if (tag >> 4) & 1 == 0 do return {}, .Unsupported // not shown
	first_size := int(tag >> 5)
	if data[3] != 0x9d || data[4] != 0x01 || data[5] != 0x2a do return {}, .Invalid
	d.width = int(u16(data[6]) | u16(data[7]) << 8) & 0x3fff
	d.height = int(u16(data[8]) | u16(data[9]) << 8) & 0x3fff // the scale bits are ignored, as libwebp does
	if d.width == 0 || d.height == 0 do return {}, .Invalid
	rest := data[10:]
	if first_size > len(rest) do return {}, .Invalid
	d.mb_w, d.mb_h = (d.width + 15) >> 4, (d.height + 15) >> 4

	br: common.Bool_Decoder
	common.bool_start(&br, rest[:first_size])
	get_bit(&br, 128) // colour space
	get_bit(&br, 128) // clamping type
	parse_segments(&br, &d.segments)
	parse_filter(&br, &d.filter)
	parse_partitions(&d, &br, rest[first_size:]) or_return
	parse_quant(&br, &d)
	get_bit(&br, 128) // refresh entropy probabilities: one frame only
	d.probs = COEFF_PROBS
	for &t, ti in d.probs do for &b, bi in t do for &c, ci in b do for &p, pi in c {
		if get_bit(&br, COEFF_UPDATE_PROBS[ti][bi][ci][pi]) do p = u8(get_value(&br, 8))
	}
	d.use_skip = get_bit(&br, 128)
	if d.use_skip do d.skip_prob = u8(get_value(&br, 8))
	filter_strengths(&d)

	d.y_stride, d.uv_stride = d.mb_w * 16, d.mb_w * 8
	ok := true
	alloc :: proc(n: int, ok: ^bool, allocator := context.allocator) -> []u8 {
		s, e := make([]u8, n, allocator)
		if e != nil do ok^ = false
		return s
	}
	d.y = alloc(d.y_stride * d.mb_h * 16, &ok, allocator)
	d.u = alloc(d.uv_stride * d.mb_h * 8, &ok, allocator)
	d.v = alloc(d.uv_stride * d.mb_h * 8, &ok, allocator)
	// Per-macroblock and per-column state, freed on return.
	d.mb_filter = alloc(d.mb_w * d.mb_h, &ok, allocator)
	inner, ie := make([]bool, d.mb_w * d.mb_h, allocator)
	d.mb_inner = inner
	d.intra_top = alloc(d.mb_w * 4, &ok, allocator)
	d.nz_top = alloc(d.mb_w, &ok, allocator)
	d.nz_dc_top = alloc(d.mb_w, &ok, allocator)
	defer {
		delete(d.mb_filter, allocator)
		delete(d.mb_inner, allocator)
		delete(d.intra_top, allocator)
		delete(d.nz_top, allocator)
		delete(d.nz_dc_top, allocator)
	}
	if !ok || ie != nil {
		destroy_yuv(&d.frame, allocator)
		return {}, .Out_Of_Memory
	}
	mb: Macroblock
	for mb_y in 0 ..< d.mb_h {
		tokens := &d.parts[mb_y & (d.part_count - 1)]
		intra_left := [4]u8{B_DC, B_DC, B_DC, B_DC}
		nz_left, nz_dc_left: u8
		for mb_x in 0 ..< d.mb_w {
			parse_modes(&d, &br, &mb, mb_x, &intra_left)
			coded := !(d.use_skip && mb.skip)
			any_coeff := false
			if coded {
				any_coeff = parse_residuals(&d, tokens, &mb, mb_x, &nz_left, &nz_dc_left)
			} else {
				nz_left, d.nz_top[mb_x] = 0, 0
				if !mb.is_4x4 do nz_dc_left, d.nz_dc_top[mb_x] = 0, 0
				mb.kind = {}
			}
			at := mb_y * d.mb_w + mb_x
			d.mb_filter[at] = u8(mb.segment * 2 + int(mb.is_4x4))
			d.mb_inner[at] = mb.is_4x4 || any_coeff
			reconstruct(&d, &mb, mb_x, mb_y)
		}
	}
	if d.filter.level > 0 do loop_filter(&d)
	return d.frame, .None
}

destroy_yuv :: proc(f: ^Yuv, allocator := context.allocator) {
	delete(f.y, allocator)
	delete(f.u, allocator)
	delete(f.v, allocator)
	f^ = {}
}

@(private)
parse_segments :: proc(br: ^common.Bool_Decoder, s: ^Segment_Header) {
	s^ = {absolute = true, tree_probs = {255, 255, 255}}
	s.enabled = get_bit(br, 128)
	if !s.enabled do return
	s.update_map = get_bit(br, 128)
	if get_bit(br, 128) {
		s.absolute = get_bit(br, 128)
		for &q in s.quantizer do q = get_bit(br, 128) ? get_signed_value(br, 7) : 0
		for &f in s.filter do f = get_bit(br, 128) ? get_signed_value(br, 6) : 0
	}
	if s.update_map do for &p in s.tree_probs do p = get_bit(br, 128) ? u8(get_value(br, 8)) : 255
}

@(private)
parse_filter :: proc(br: ^common.Bool_Decoder, f: ^Filter_Header) {
	f.simple = get_bit(br, 128)
	f.level = get_value(br, 6)
	f.sharpness = get_value(br, 3)
	f.use_deltas = get_bit(br, 128)
	if f.use_deltas && get_bit(br, 128) {
		for &r in f.ref_delta do if get_bit(br, 128) do r = get_signed_value(br, 6)
		for &m in f.mode_delta do if get_bit(br, 128) do m = get_signed_value(br, 6)
	}
}

// The token partitions: 1, 2, 4 or 8, their sizes (but the last's) in 3
// bytes each ahead of them. Rows use them in turn.
@(private)
parse_partitions :: proc(d: ^Vp8, br: ^common.Bool_Decoder, data: []u8) -> Error {
	d.part_count = 1 << uint(get_value(br, 2))
	sizes := (d.part_count - 1) * 3
	if len(data) < sizes do return .Invalid
	at := sizes
	for p in 0 ..< d.part_count - 1 {
		size := int(data[3 * p]) | int(data[3 * p + 1]) << 8 | int(data[3 * p + 2]) << 16
		size = min(size, len(data) - at)
		common.bool_start(&d.parts[p], data[at:][:size])
		at += size
	}
	if at >= len(data) do return .Invalid
	common.bool_start(&d.parts[d.part_count - 1], data[at:])
	return .None
}

@(private)
parse_quant :: proc(br: ^common.Bool_Decoder, d: ^Vp8) {
	base := get_value(br, 7)
	delta :: proc(br: ^common.Bool_Decoder) -> int {return get_bit(br, 128) ? get_signed_value(br, 4) : 0}
	y1_dc, y2_dc, y2_ac, uv_dc, uv_ac := delta(br), delta(br), delta(br), delta(br), delta(br)
	for &q, s in d.quant {
		qi := base
		if d.segments.enabled {
			qi = d.segments.quantizer[s] + (d.segments.absolute ? 0 : base)
		}
		step :: proc(table: ^[128]u16, i, top: int) -> i32 {return i32(table[clamp(i, 0, top)])}
		q.y1 = {step(&DC_STEP, qi + y1_dc, 127), step(&AC_STEP, qi, 127)}
		// x * 155 / 100, exactly, for every step there is.
		q.y2 = {step(&DC_STEP, qi + y2_dc, 127) * 2, max((step(&AC_STEP, qi + y2_ac, 127) * 101581) >> 16, 8)}
		q.uv = {step(&DC_STEP, qi + uv_dc, 117), step(&AC_STEP, qi + uv_ac, 127)}
	}
}

@(private)
filter_strengths :: proc(d: ^Vp8) {
	f := &d.filter
	for s in 0 ..< 4 {
		base := f.level
		if d.segments.enabled {
			base = d.segments.filter[s] + (d.segments.absolute ? 0 : f.level)
		}
		for i4x4 in 0 ..< 2 {
			level := base
			if f.use_deltas {
				level += f.ref_delta[0] // intra frame
				if i4x4 == 1 do level += f.mode_delta[0]
			}
			level = clamp(level, 0, 63)
			if level == 0 {
				d.strengths[s][i4x4] = {}
				continue
			}
			inner := level
			if f.sharpness > 0 {
				inner >>= uint(f.sharpness > 4 ? 2 : 1)
				inner = min(inner, 9 - f.sharpness)
			}
			inner = max(inner, 1)
			d.strengths[s][i4x4] = {
				limit = u8(2 * level + inner),
				inner = u8(inner),
				hev   = level >= 40 ? 2 : level >= 15 ? 1 : 0,
			}
		}
	}
}

// Segment, skip flag and intra modes (RFC 6386 11), from the first
// partition.
@(private)
parse_modes :: proc(d: ^Vp8, br: ^common.Bool_Decoder, mb: ^Macroblock, mb_x: int, left: ^[4]u8) {
	mb.segment = 0
	if d.segments.update_map {
		p := &d.segments.tree_probs
		mb.segment = !get_bit(br, p[0]) ? int(get_bit(br, p[1])) : 2 + int(get_bit(br, p[2]))
	}
	mb.skip = d.use_skip && get_bit(br, d.skip_prob)
	top := d.intra_top[mb_x * 4:][:4]
	mb.is_4x4 = !get_bit(br, 145)
	if !mb.is_4x4 {
		ymode := get_bit(br, 156) ? (get_bit(br, 128) ? TM_PRED : H_PRED) : (get_bit(br, 163) ? V_PRED : DC_PRED)
		mb.ymode = ymode
		for &t in top do t = u8(ymode)
		left^ = u8(ymode)
	} else {
		for y in 0 ..< 4 {
			mode := left[y]
			for x in 0 ..< 4 {
				p := &BMODE_PROBS[top[x]][mode]
				switch {
				case !get_bit(br, p[0]):
					mode = B_DC
				case !get_bit(br, p[1]):
					mode = B_TM
				case !get_bit(br, p[2]):
					mode = B_VE
				case !get_bit(br, p[3]):
					mode = !get_bit(br, p[4]) ? B_HE : (!get_bit(br, p[5]) ? B_RD : B_VR)
				case:
					mode = !get_bit(br, p[6]) ? B_LD : (!get_bit(br, p[7]) ? B_VL : (!get_bit(br, p[8]) ? B_HD : B_HU))
				}
				top[x] = mode
				mb.modes[y * 4 + x] = mode
			}
			left[y] = mode
		}
	}
	mb.uvmode = !get_bit(br, 142) ? DC_PRED : !get_bit(br, 114) ? V_PRED : get_bit(br, 183) ? TM_PRED : H_PRED
}

// Coefficient tokens of one 4x4 block (RFC 6386 13) from position `first`,
// dequantized into out in raster order; returns one past the last position
// read (0 when the block has no coefficients).
@(private)
get_coeffs :: #force_inline proc(br: ^common.Bool_Decoder, probs: ^[8][3][11]u8, ctx: int, dq: [2]i32, first: int, out: []i16) -> int {
	n := first
	p := &probs[BANDS[n]][ctx]
	#no_bounds_check for ; n < 16; n += 1 {
		if !get_bit(br, p[0]) do return n // end of block
		for !get_bit(br, p[1]) { // a zero
			n += 1
			if n == 16 do return 16
			p = &probs[BANDS[n]][0]
		}
		next := &probs[BANDS[n + 1]]
		v: int
		if !get_bit(br, p[2]) {
			v = 1
			p = &next[1]
		} else {
			v = large_value(br, p)
			p = &next[2]
		}
		if get_bit(br, 128) do v = -v
		out[ZIGZAG[n]] = i16(i32(v) * dq[n > 0 ? 1 : 0])
	}
	return 16
}

@(private)
large_value :: #force_inline proc(br: ^common.Bool_Decoder, p: ^[11]u8) -> int #no_bounds_check {
	@(static, rodata)
	CAT := [4][]u8{{173, 148, 140}, {176, 155, 140, 135}, {180, 157, 141, 134, 130}, {254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129}}
	if !get_bit(br, p[3]) {
		if !get_bit(br, p[4]) do return 2
		return 3 + int(get_bit(br, p[5]))
	}
	if !get_bit(br, p[6]) {
		if !get_bit(br, p[7]) do return 5 + int(get_bit(br, 159))
		v := 7 + 2 * int(get_bit(br, 165))
		return v + int(get_bit(br, 145))
	}
	bit1 := int(get_bit(br, p[8]))
	bit0 := int(get_bit(br, p[9 + bit1]))
	cat := 2 * bit1 + bit0
	v := 0
	for prob in CAT[cat] do v = 2 * v + int(get_bit(br, prob))
	return v + 3 + (8 << uint(cat))
}

// All coefficients of a macroblock, with the nonzero contexts above and to
// the left; returns whether any block has something to add. The decoder
// state is a local meanwhile: nothing else can reach it, so it stays in
// registers while the coefficients are stored.
@(private)
parse_residuals :: proc(d: ^Vp8, tokens: ^common.Bool_Decoder, mb: ^Macroblock, mb_x: int, nz_left, nz_dc_left: ^u8) -> bool {
	local := tokens^
	defer tokens^ = local
	br := &local
	q := &d.quant[mb.segment]
	mb.coeffs = {}
	mb.kind = {}
	first := 0
	ac_probs := &d.probs[3]
	if !mb.is_4x4 {
		// The Y2 block: the luma blocks' DCs, through the inverse WHT.
		dc: [16]i16
		ctx := int(d.nz_dc_top[mb_x] + nz_dc_left^)
		n := get_coeffs(br, &d.probs[1], ctx, q.y2, 0, dc[:])
		flag := u8(n > 0)
		d.nz_dc_top[mb_x], nz_dc_left^ = flag, flag
		inverse_wht(&dc, mb.coeffs[:])
		first = 1
		ac_probs = &d.probs[0]
	}
	// Luma: each block's context is whether the blocks above and to the left
	// had coefficients.
	top := d.nz_top[mb_x]
	left := nz_left^
	for y in 0 ..< 4 {
		l := (left >> uint(y)) & 1
		for x in 0 ..< 4 {
			t := (top >> uint(x)) & 1
			b := y * 4 + x
			block := mb.coeffs[b * 16:][:16]
			n := get_coeffs(br, ac_probs, int(l + t), q.y1, first, block)
			l = u8(n > first)
			top = top &~ (1 << uint(x)) | l << uint(x)
			mb.kind[b] = n > 1 ? 2 : (block[0] != 0 ? 1 : 0)
		}
		left = left &~ (1 << uint(y)) | l << uint(y)
	}
	// Chroma: U then V, 2x2 blocks each; their flags in bits 4-5 and 6-7.
	for c in 0 ..< 2 {
		shift := uint(4 + 2 * c)
		for y in 0 ..< 2 {
			l := (left >> (shift + uint(y))) & 1
			for x in 0 ..< 2 {
				t := (top >> (shift + uint(x))) & 1
				b := 16 + c * 4 + y * 2 + x
				block := mb.coeffs[b * 16:][:16]
				n := get_coeffs(br, &d.probs[2], int(l + t), q.uv, 0, block)
				l = u8(n > 0)
				top = top &~ (1 << (shift + uint(x))) | l << (shift + uint(x))
				mb.kind[b] = n > 1 ? 2 : (block[0] != 0 ? 1 : 0)
			}
			left = left &~ (1 << (shift + uint(y))) | l << (shift + uint(y))
		}
	}
	d.nz_top[mb_x], nz_left^ = top, left
	return mb.kind != {}
}

@(private)
inverse_wht :: proc(input: ^[16]i16, out: []i16) {
	tmp: [16]i32
	for i in 0 ..< 4 {
		a0 := i32(input[i]) + i32(input[12 + i])
		a1 := i32(input[4 + i]) + i32(input[8 + i])
		a2 := i32(input[4 + i]) - i32(input[8 + i])
		a3 := i32(input[i]) - i32(input[12 + i])
		tmp[i], tmp[8 + i] = a0 + a1, a0 - a1
		tmp[4 + i], tmp[12 + i] = a3 + a2, a3 - a2
	}
	for i in 0 ..< 4 {
		dc := tmp[i * 4] + 3
		a0 := dc + tmp[3 + i * 4]
		a1 := tmp[1 + i * 4] + tmp[2 + i * 4]
		a2 := tmp[1 + i * 4] - tmp[2 + i * 4]
		a3 := dc - tmp[3 + i * 4]
		// Output i*4 + k goes to the DC of luma block i*4 + k.
		out[(i * 4 + 0) * 16] = i16((a0 + a1) >> 3)
		out[(i * 4 + 1) * 16] = i16((a3 + a2) >> 3)
		out[(i * 4 + 2) * 16] = i16((a0 - a1) >> 3)
		out[(i * 4 + 3) * 16] = i16((a3 - a2) >> 3)
	}
}

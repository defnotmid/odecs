package webp

import "base:runtime"
import "core:simd"
import "core:slice"

// WebP lossless (VP8L, RFC 9649): ARGB pixels as prefix-coded literals,
// LZ77 copies and colour-cache hits, under up to four inverse transforms
// (predictor, cross-colour, subtract-green, colour indexing). Subimages of
// the same coding carry the transforms' per-block data and the choice of
// prefix codes per block.
//
// Written from RFC 9649 (libwebp's doc/webp-lossless-bitstream-spec.txt)
// and libwebp 1.6.0 (BSD-3-Clause).

// LSB-first bits, 57 to 64 buffered after a fill. Past the end it reads
// zero bytes, counted: the stream has been overrun once fewer bits are
// buffered than were padded.
@(private)
Bit_Reader :: struct {
	data:  []u8,
	at:    int,
	value: u64,
	count: uint, // bits buffered
	over:  uint, // zero bytes read past the end
}

@(private)
bits_fill :: #force_inline proc(br: ^Bit_Reader) {
	for br.count <= 56 {
		b: u64
		if br.at < len(br.data) {
			b = u64(br.data[br.at])
			br.at += 1
		} else {
			br.over += 1
		}
		br.value |= b << br.count
		br.count += 8
	}
}

@(private)
overrun :: #force_inline proc(br: ^Bit_Reader) -> bool {
	return br.count < br.over * 8
}

@(private)
read_bits :: #force_inline proc(br: ^Bit_Reader, n: uint) -> u32 {
	if br.count < n do bits_fill(br)
	v := u32(br.value & (u64(1) << n - 1))
	br.value >>= n
	br.count -= n
	return v
}

// Prefix codes are decoded through 8-bit root tables; longer codes continue
// in second-level tables after them. Every code's entries live in one flat
// array at the code's offset.
@(private)
ROOT_BITS :: 8

@(private)
Huff_Entry :: struct {
	bits:  u8, // code length; above ROOT_BITS in a root entry: the second level's bits + ROOT_BITS
	value: u16, // symbol, or the offset from this root entry to its second-level table
}

@(private)
read_symbol :: #force_inline proc(br: ^Bit_Reader, table: []Huff_Entry) -> int #no_bounds_check {
	if br.count < 15 do bits_fill(br) // the longest code
	at := int(br.value & (1 << ROOT_BITS - 1))
	e := table[at]
	if e.bits > ROOT_BITS {
		sub := uint(e.bits - ROOT_BITS)
		br.value >>= ROOT_BITS
		br.count -= ROOT_BITS
		at += int(e.value) + int(br.value & (u64(1) << sub - 1))
		e = table[at]
	}
	br.value >>= e.bits
	br.count -= uint(e.bits)
	return int(e.value)
}

// Appends the decoding table of a canonical prefix code (LSB-first codes)
// to `entries`; returns its offset, or -1 for an invalid (incomplete or
// over-subscribed) code. A code of a single symbol consumes no bits.
@(private)
build_table :: proc(entries: ^[dynamic]Huff_Entry, lengths: []u8) -> int {
	MAX_LENGTH :: 15
	count: [MAX_LENGTH + 1]int
	for l in lengths do count[l] += 1
	if count[0] == len(lengths) do return -1
	offset: [MAX_LENGTH + 2]int
	for l in 1 ..= MAX_LENGTH {
		if count[l] > 1 << uint(l) do return -1
		offset[l + 1] = offset[l] + count[l]
	}
	sorted: [256 + 24 + 2048]u16 = --- // the largest alphabet; filled before use
	symbols := offset[MAX_LENGTH + 1]
	{
		next := offset
		for l, s in lengths do if l > 0 {
			sorted[next[l]] = u16(s)
			next[l] += 1
		}
	}
	start := len(entries)
	if symbols == 1 {
		resize(entries, start + 1 << ROOT_BITS)
		for &e in entries[start:] do e = {0, sorted[0]}
		return start
	}
	// Check completeness first: the tables are only built for full codes.
	open := 1
	for l in 1 ..= MAX_LENGTH {
		open = open * 2 - count[l]
		if open < 0 do return -1
	}
	if open != 0 do return -1
	resize(entries, start + 1 << ROOT_BITS)
	// Root entries for codes up to ROOT_BITS, each replicated over the bits
	// it does not use; longer codes grouped by their low ROOT_BITS into
	// second-level tables sized for the codes that share them.
	key := 0 // the current code, bit-reversed
	symbol := 0
	for l in 1 ..= ROOT_BITS {
		for _ in 0 ..< count[l] {
			for k := key; k < 1 << ROOT_BITS; k += 1 << uint(l) do entries[start + k] = {u8(l), sorted[symbol]}
			symbol += 1
			key = next_key(key, l)
		}
	}
	low := -1
	table_at, table_bits := 0, 0
	remaining := count
	for l in ROOT_BITS + 1 ..= MAX_LENGTH {
		for remaining[l] > 0 {
			if key & (1 << ROOT_BITS - 1) != low {
				low = key & (1 << ROOT_BITS - 1)
				// Enough bits for every code of this length and longer that
				// shares the prefix.
				table_bits = l - ROOT_BITS
				left := 1 << uint(table_bits)
				for b := l; b <= MAX_LENGTH; b += 1 {
					left -= remaining[b]
					if left <= 0 do break
					left <<= 1
					table_bits += 1
				}
				table_bits = min(table_bits, MAX_LENGTH - ROOT_BITS)
				table_at = len(entries)
				resize(entries, table_at + 1 << uint(table_bits))
				entries[start + low] = {u8(table_bits + ROOT_BITS), u16(table_at - (start + low))}
			}
			sub := key >> ROOT_BITS
			step := 1 << uint(l - ROOT_BITS)
			for k := sub; k < 1 << uint(table_bits); k += step do entries[table_at + k] = {u8(l - ROOT_BITS), sorted[symbol]}
			symbol += 1
			remaining[l] -= 1
			key = next_key(key, l)
		}
	}
	return start
}

// The next code of a length, bit-reversed: increment from the top bit.
@(private)
next_key :: proc(key, length: int) -> int {
	step := 1 << uint(length - 1)
	for key & step != 0 do step >>= 1
	return step != 0 ? (key & (step - 1)) + step : key
}

// The five prefix codes of a group, as offsets into the shared entries.
@(private)
GREEN, RED, BLUE, ALPHA, DIST :: 0, 1, 2, 3, 4
@(private)
ALPHABET := [5]int{256 + 24, 256, 256, 256, 40}

@(private)
Allocator :: runtime.Allocator

@(private)
Lossless :: struct {
	br:        Bit_Reader,
	allocator: Allocator,
	scratch:   [dynamic]Huff_Entry, // the code-length code's table
}

// A group's five prefix codes, and what is known of them once read: red,
// blue and alpha with one symbol each (a "trivial literal": their part of
// every literal known), green too (every pixel known), or all four short
// enough together that one lookup of PACKED_BITS decodes a pixel.
@(private)
Group :: struct {
	tables:          [5]int, // offsets into Codes.entries
	packed:          int, // offset into Codes.packed, or -1
	literal:         u32, // alpha, red and blue of a trivial literal (and green, trivial)
	trivial_literal: bool,
	trivial:         bool,
}

@(private)
PACKED_BITS :: 6

// A packed lookup: a whole literal pixel and its bits, or (bits above
// PACKED_NOT_LITERAL) a green symbol that is a copy or cache code.
@(private)
Packed :: struct {
	bits:  u32,
	value: u32,
}

@(private)
PACKED_NOT_LITERAL :: 0x100

// One entropy-coded image's codes: groups of five prefix codes, the
// subsampled image choosing a group per block, and the colour cache.
@(private)
Codes :: struct {
	entries:     [dynamic]Huff_Entry,
	packed:      [dynamic]Packed,
	groups:      []Group,
	group_image: []u32, // nil: group 0 everywhere
	group_bits:  uint,
	group_width: int,
	cache_bits:  uint,
}

@(private)
destroy_codes :: proc(c: ^Codes, allocator: Allocator) {
	delete(c.entries)
	delete(c.packed)
	delete(c.groups, allocator)
	delete(c.group_image, allocator)
}

@(private)
Transform_Kind :: enum u8 {
	Predictor,
	Cross_Colour,
	Subtract_Green,
	Colour_Indexing,
}

@(private)
Transform :: struct {
	kind:  Transform_Kind,
	bits:  uint, // block size (predictor, cross-colour) or pixels per packed pixel (indexing)
	width: int, // the image width the transform applies at
	data:  []u32, // block image or palette
}

// Decodes a VP8L bitstream (after the chunk header) into ARGB pixels.
@(private)
decode_vp8l :: proc(data: []u8, allocator: Allocator) -> (argb: []u32, width, height: int, err: Error) {
	if len(data) < 5 || data[0] != 0x2f do return nil, 0, 0, .Invalid
	l := Lossless{br = {data = data[1:]}, allocator = allocator}
	defer delete(l.scratch)
	l.scratch.allocator = allocator
	width = int(read_bits(&l.br, 14)) + 1
	height = int(read_bits(&l.br, 14)) + 1
	read_bits(&l.br, 1) // alpha is used: a hint
	if read_bits(&l.br, 3) != 0 do return nil, 0, 0, .Invalid
	argb = decode_main_image(&l, width, height) or_return
	return argb, width, height, .None
}

// Decodes a headerless VP8L image of a known size (an ALPH chunk's).
@(private)
decode_vp8l_image :: proc(data: []u8, width, height: int, allocator: Allocator) -> (argb: []u32, err: Error) {
	l := Lossless{br = {data = data}, allocator = allocator}
	defer delete(l.scratch)
	l.scratch.allocator = allocator
	return decode_main_image(&l, width, height)
}

@(private)
decode_main_image :: proc(l: ^Lossless, width, height: int) -> (argb: []u32, err: Error) {
	transforms: [4]Transform
	count := 0
	defer for t in transforms[:count] do delete(t.data, l.allocator)
	seen: bit_set[Transform_Kind]
	coded_width := width
	for read_bits(&l.br, 1) == 1 {
		t := &transforms[count]
		t.kind = Transform_Kind(read_bits(&l.br, 2))
		if t.kind in seen do return nil, .Invalid
		seen += {t.kind}
		t.width = coded_width
		count += 1
		switch t.kind {
		case .Predictor, .Cross_Colour:
			t.bits = uint(read_bits(&l.br, 3)) + 2
			t.data = decode_image(l, subsample(coded_width, t.bits), subsample(height, t.bits), false) or_return
		case .Colour_Indexing:
			colours := int(read_bits(&l.br, 8)) + 1
			t.bits = colours > 16 ? 0 : colours > 4 ? 1 : colours > 2 ? 2 : 3
			coded_width = subsample(coded_width, t.bits)
			palette := decode_image(l, colours, 1, false) or_return
			defer delete(palette, l.allocator)
			// Delta-coded; indices past the palette are transparent black.
			full, e := make([]u32, 256, l.allocator)
			if e != nil do return nil, .Out_Of_Memory
			full[0] = palette[0]
			for i in 1 ..< colours do full[i] = add_pixels(palette[i], full[i - 1])
			t.data = full
		case .Subtract_Green:
		}
	}
	argb = decode_image(l, coded_width, height, true) or_return
	// Undo the transforms, the last read first.
	for i := count - 1; i >= 0; i -= 1 {
		t := &transforms[i]
		switch t.kind {
		case .Predictor:
			inverse_predictor(argb, t.width, height, t.data, t.bits)
		case .Cross_Colour:
			inverse_cross_colour(argb, t.width, height, t.data, t.bits)
		case .Subtract_Green:
			for &p in argb {
				g := (p >> 8) & 0xff
				p = p & 0xff00ff00 | ((p & 0x00ff00ff) + (g << 16 | g)) & 0x00ff00ff
			}
		case .Colour_Indexing:
			out, e := make([]u32, t.width * height, l.allocator)
			if e != nil {
				delete(argb, l.allocator)
				return nil, .Out_Of_Memory
			}
			unpack_indices(out, argb, t.width, height, t.data, t.bits)
			delete(argb, l.allocator)
			argb = out
		}
	}
	if overrun(&l.br) {
		delete(argb, l.allocator)
		return nil, .Invalid
	}
	return argb, .None
}

@(private)
subsample :: #force_inline proc(size: int, bits: uint) -> int {
	return (size + (1 << bits) - 1) >> bits
}

// An entropy-coded image: its colour cache, prefix codes (per block for the
// main image), then the pixels.
@(private)
decode_image :: proc(l: ^Lossless, width, height: int, main: bool) -> (pixels: []u32, err: Error) {
	codes: Codes
	defer destroy_codes(&codes, l.allocator)
	codes.entries.allocator = l.allocator
	codes.packed.allocator = l.allocator
	if read_bits(&l.br, 1) == 1 {
		codes.cache_bits = uint(read_bits(&l.br, 4))
		if codes.cache_bits < 1 || codes.cache_bits > 11 do return nil, .Invalid
	}
	group_count := 1
	if main && read_bits(&l.br, 1) == 1 {
		codes.group_bits = uint(read_bits(&l.br, 3)) + 2
		codes.group_width = subsample(width, codes.group_bits)
		codes.group_image = decode_image(l, codes.group_width, subsample(height, codes.group_bits), false) or_return
		for &g in codes.group_image {
			g = (g >> 8) & 0xffff // red and green
			group_count = max(group_count, int(g) + 1)
		}
	}
	codes.groups = make([]Group, group_count, l.allocator)
	reserve(&codes.entries, group_count * 5 * (1 << ROOT_BITS + 64)) // root tables, and some second-level room
	lengths: [256 + 24 + 2048]u8
	for &group in codes.groups {
		literal_bits := 0 // the longest codes of green, red, blue and alpha, summed
		for kind in 0 ..< 5 {
			size := ALPHABET[kind] + (kind == GREEN && codes.cache_bits > 0 ? 1 << codes.cache_bits : 0)
			read_code_lengths(l, lengths[:size]) or_return
			group.tables[kind] = build_table(&codes.entries, lengths[:size])
			if group.tables[kind] < 0 || overrun(&l.br) do return nil, .Invalid
			if kind != DIST do literal_bits += int(slice.max(lengths[:size]))
		}
		summarize_group(&codes, &group, literal_bits)
	}
	pixels, _ = make([]u32, width * height, l.allocator)
	if pixels == nil do return nil, .Out_Of_Memory
	if e := decode_pixels(&l.br, &codes, pixels, width); e != .None {
		delete(pixels, l.allocator)
		return nil, e
	}
	return pixels, .None
}

@(private)
summarize_group :: proc(codes: ^Codes, g: ^Group, literal_bits: int) {
	e := codes.entries[:]
	first :: #force_inline proc(e: []Huff_Entry, at: int) -> Huff_Entry {return e[at]}
	green, red, blue, alpha := first(e, g.tables[GREEN]), first(e, g.tables[RED]), first(e, g.tables[BLUE]), first(e, g.tables[ALPHA])
	g.packed = -1
	g.trivial_literal = red.bits == 0 && blue.bits == 0 && alpha.bits == 0
	if g.trivial_literal {
		g.literal = u32(alpha.value) << 24 | u32(red.value) << 16 | u32(blue.value)
		if green.bits == 0 && green.value < 256 {
			g.trivial = true
			g.literal |= u32(green.value) << 8
			return
		}
	}
	if literal_bits >= PACKED_BITS do return
	// Codes this short all resolve in the root tables.
	g.packed = len(codes.packed)
	resize(&codes.packed, g.packed + 1 << PACKED_BITS)
	for bits in 0 ..< u32(1 << PACKED_BITS) {
		p := &codes.packed[g.packed + int(bits)]
		gc := e[g.tables[GREEN] + int(bits)]
		if gc.value >= 256 {
			p^ = {u32(gc.bits) + PACKED_NOT_LITERAL, u32(gc.value)}
			continue
		}
		used := u32(gc.bits)
		value := u32(gc.value) << 8
		for k in ([3][2]int{{RED, 16}, {BLUE, 0}, {ALPHA, 24}}) {
			c := e[g.tables[k[0]] + int(bits >> used)]
			value |= u32(c.value) << uint(k[1])
			used += u32(c.bits)
		}
		p^ = {used, value}
	}
}

// A prefix code's lengths (RFC 9649 3.7.2.1): one or two symbols directly,
// or lengths prefix-coded with run-length codes.
@(private)
read_code_lengths :: proc(l: ^Lossless, lengths: []u8) -> Error {
	br := &l.br
	for &v in lengths do v = 0
	if read_bits(br, 1) == 1 {
		// Symbols beyond the alphabet leave it empty: an invalid code.
		two := read_bits(br, 1) == 1
		first := int(read_bits(br, read_bits(br, 1) == 1 ? 8 : 1))
		if first < len(lengths) do lengths[first] = 1
		if two {
			second := int(read_bits(br, 8))
			if second < len(lengths) do lengths[second] = 1
		}
		return .None
	}
	@(static, rodata)
	ORDER := [19]u8{17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
	code_lengths: [19]u8
	count := int(read_bits(br, 4)) + 4 // not in the range: its bound is evaluated per iteration
	for i in 0 ..< count do code_lengths[ORDER[i]] = u8(read_bits(br, 3))
	clear(&l.scratch)
	at := build_table(&l.scratch, code_lengths[:])
	if at < 0 do return .Invalid
	table := l.scratch[at:]
	limit := len(lengths)
	if read_bits(br, 1) == 1 {
		n := 2 + 2 * uint(read_bits(br, 3))
		limit = 2 + int(read_bits(br, n))
		if limit > len(lengths) do return .Invalid
	}
	prev: u8 = 8
	for s := 0; s < len(lengths); {
		if limit == 0 do break
		limit -= 1
		code := read_symbol(br, table)
		if code < 16 {
			lengths[s] = u8(code)
			s += 1
			if code != 0 do prev = u8(code)
			continue
		}
		repeat: int
		value: u8
		switch code {
		case 16:
			repeat, value = 3 + int(read_bits(br, 2)), prev
		case 17:
			repeat = 3 + int(read_bits(br, 3))
		case:
			repeat = 11 + int(read_bits(br, 7))
		}
		if s + repeat > len(lengths) do return .Invalid
		for _ in 0 ..< repeat {
			lengths[s] = value
			s += 1
		}
	}
	return .None
}

@(private)
decode_pixels :: proc(br: ^Bit_Reader, codes: ^Codes, pixels: []u32, width: int) -> Error {
	// Every pixel, however coded, goes through the colour cache in order.
	cache: [1 << 11]u32
	cache_shift := 32 - codes.cache_bits
	cached := 0 // pixels before this are in the cache
	group_mask := codes.group_image != nil ? (1 << codes.group_bits) - 1 : -1
	group_of :: #force_inline proc(codes: ^Codes, x, y: int) -> ^Group {
		if codes.group_image == nil do return &codes.groups[0]
		return &codes.groups[codes.group_image[(y >> codes.group_bits) * codes.group_width + (x >> codes.group_bits)]]
	}
	total := len(pixels)
	pos, x, y := 0, 0, 0
	group := group_of(codes, 0, 0)
	entries := codes.entries[:]
	packed := codes.packed[:]
	for pos < total {
		if x & group_mask == 0 do group = group_of(codes, x, y)
		code: int
		literal: u32
		switch {
		case group.trivial:
			code, literal = 0, group.literal
		case group.packed >= 0:
			if br.count < PACKED_BITS do bits_fill(br)
			p := packed[group.packed + int(br.value & (1 << PACKED_BITS - 1))]
			if p.bits < PACKED_NOT_LITERAL {
				br.value >>= p.bits
				br.count -= uint(p.bits)
				literal = p.value
			} else {
				br.value >>= p.bits - PACKED_NOT_LITERAL
				br.count -= uint(p.bits - PACKED_NOT_LITERAL)
				code = int(p.value)
			}
		case:
			code = read_symbol(br, entries[group.tables[GREEN]:])
			if code >= 256 do break
			if group.trivial_literal {
				literal = group.literal | u32(code) << 8
			} else {
				r := read_symbol(br, entries[group.tables[RED]:])
				b := read_symbol(br, entries[group.tables[BLUE]:])
				a := read_symbol(br, entries[group.tables[ALPHA]:])
				literal = u32(a) << 24 | u32(r) << 16 | u32(code) << 8 | u32(b)
			}
		}
		switch {
		case code < 256:
			pixels[pos] = literal
			pos += 1
			x += 1
			if x == width {
				x = 0
				y += 1
			}
		case code < 256 + 24:
			length := prefix_value(br, code - 256)
			dist_code := prefix_value(br, read_symbol(br, entries[group.tables[DIST]:]))
			dist := plane_distance(width, dist_code)
			if dist > pos || length > total - pos do return .Invalid
			// An overlapping copy repeats the pattern, in order.
			if dist >= length {
				copy(pixels[pos:][:length], pixels[pos - dist:][:length])
			} else {
				#no_bounds_check for i in 0 ..< length do pixels[pos + i] = pixels[pos + i - dist]
			}
			pos += length
			x += length
			for x >= width {
				x -= width
				y += 1
			}
			if x & group_mask != 0 && pos < total do group = group_of(codes, x, y)
		case:
			key := code - (256 + 24)
			if codes.cache_bits == 0 || key >= 1 << codes.cache_bits do return .Invalid
			pixels[pos] = cache[key]
			pos += 1
			x += 1
			if x == width {
				x = 0
				y += 1
			}
		}
		if codes.cache_bits > 0 {
			for ; cached < pos; cached += 1 do cache[(0x1e35a7bd * pixels[cached]) >> cache_shift] = pixels[cached]
		}
		if overrun(br) do return .Invalid
	}
	return .None
}

// A length or distance from its prefix symbol and extra bits.
@(private)
prefix_value :: #force_inline proc(br: ^Bit_Reader, symbol: int) -> int {
	if symbol < 4 do return symbol + 1
	extra := uint(symbol - 2) >> 1
	offset := (2 + (symbol & 1)) << extra
	return offset + int(read_bits(br, extra)) + 1
}

// Distance codes 1..120 are the nearest neighbours (DISTANCE_MAP); larger
// ones are plain distances offset by 120.
@(private)
plane_distance :: proc(width, code: int) -> int {
	if code > 120 do return code - 120
	m := int(DISTANCE_MAP[code - 1])
	dist := (m >> 4) * width + 8 - (m & 0xf)
	return max(dist, 1)
}

@(private)
add_pixels :: #force_inline proc(a, b: u32) -> u32 {
	ag := (a & 0xff00ff00) + (b & 0xff00ff00)
	rb := (a & 0x00ff00ff) + (b & 0x00ff00ff)
	return ag & 0xff00ff00 | rb & 0x00ff00ff
}

@(private)
average2 :: #force_inline proc(a, b: u32) -> u32 {
	return (((a ~ b) & 0xfefefefe) >> 1) + (a & b)
}

// The predictor transform (RFC 9649 4.1), in place: residuals to pixels in
// scan order, each from its already decoded neighbours. The top-right of
// the last column is the first pixel of the current row, which is where it
// lies in memory. The mode is constant across a block, so each block's run
// of a row is one tight loop.
@(private)
inverse_predictor :: proc(px: []u32, width, height: int, modes: []u32, bits: uint) #no_bounds_check {
	px[0] = add_pixels(px[0], 0xff000000)
	for x in 1 ..< width do px[x] = add_pixels(px[x], px[x - 1])
	blocks := subsample(width, bits)
	for y in 1 ..< height {
		row := y * width
		px[row] = add_pixels(px[row], px[row - width])
		mode_row := modes[(y >> bits) * blocks:]
		for x := 1; x < width; {
			end := min((x >> bits + 1) << bits, width)
			// In each case: i the pixel, i - width above it.
			switch (mode_row[x >> bits] >> 8) & 0xf {
			case 1:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], px[i - 1])
			case 2:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], px[i - width])
			case 3:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], px[i - width + 1])
			case 4:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], px[i - width - 1])
			case 5:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], average2(average2(px[i - 1], px[i - width + 1]), px[i - width]))
			case 6:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], average2(px[i - 1], px[i - width - 1]))
			case 7:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], average2(px[i - 1], px[i - width]))
			case 8:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], average2(px[i - width - 1], px[i - width]))
			case 9:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], average2(px[i - width], px[i - width + 1]))
			case 10:
				for i in row + x ..< row + end {
					px[i] = add_pixels(px[i], average2(average2(px[i - 1], px[i - width - 1]), average2(px[i - width], px[i - width + 1])))
				}
			case 11:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], select(px[i - width], px[i - 1], px[i - width - 1]))
			case 12:
				// A chain through the left pixel: it stays in lanes, and
				// T - TL is computed off the chain.
				left := lanes(px[row + x - 1])
				for i in row + x ..< row + end {
					pred := simd.clamp(left + (lanes(px[i - width]) - lanes(px[i - width - 1])), 0, 255)
					left = (pred + lanes(px[i])) & 0xff
					px[i] = pixel(left)
				}
			case 13:
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], clamped_add_subtract_half(average2(px[i - 1], px[i - width]), px[i - width - 1]))
			case: // 0, and 14 and 15 as libwebp
				for i in row + x ..< row + end do px[i] = add_pixels(px[i], 0xff000000)
			}
			x = end
		}
	}
}

// A pixel's four channels as vector lanes, wide enough for sums and
// differences, and back.
@(private)
lanes :: #force_inline proc(p: u32) -> #simd[4]i16 {
	return cast(#simd[4]i16)transmute(#simd[4]u8)p
}

@(private)
pixel :: #force_inline proc(v: #simd[4]i16) -> u32 {
	return transmute(u32)cast(#simd[4]u8)v
}

// Top or left, whichever is nearer (Manhattan) to the gradient estimate.
@(private)
select :: #force_inline proc(t, l, tl: u32) -> u32 {
	c := lanes(tl)
	d := simd.reduce_add_ordered(simd.abs(lanes(l) - c)) - simd.reduce_add_ordered(simd.abs(lanes(t) - c))
	return d <= 0 ? t : l
}

// a + (a - b) / 2 per channel, the division truncating toward zero:
// negative differences are moved up by one (their sign, -1) before the
// arithmetic shift.
@(private)
clamped_add_subtract_half :: #force_inline proc(a, b: u32) -> u32 {
	x := lanes(a)
	d := x - lanes(b) // [-255, 255]
	half := simd.shr(d - simd.shr(d, 15), 1)
	return pixel(simd.clamp(x + half, 0, 255))
}

// The cross-colour transform (RFC 9649 4.2): red from green, blue from
// green and red, by per-block 3.5 fixed-point factors.
@(private)
inverse_cross_colour :: proc(px: []u32, width, height: int, elements: []u32, bits: uint) #no_bounds_check {
	delta :: #force_inline proc(t: i32, c: u32) -> u32 {return u32((t * i32(i8(c))) >> 5)}
	blocks := subsample(width, bits)
	for y in 0 ..< height {
		row := px[y * width:][:width]
		block_row := elements[(y >> bits) * blocks:]
		for x := 0; x < width; {
			end := min((x >> bits + 1) << bits, width)
			e := block_row[x >> bits]
			g2r, g2b, r2b := i32(i8(e)), i32(i8(e >> 8)), i32(i8(e >> 16))
			for &p in row[x:end] {
				g := (p >> 8) & 0xff
				r := ((p >> 16) + delta(g2r, g)) & 0xff
				b := (p + delta(g2b, g) + delta(r2b, r)) & 0xff
				p = p & 0xff00ff00 | r << 16 | b
			}
			x = end
		}
	}
}

// Colour indexing (RFC 9649 4.4): palette indices in the green channel,
// 1, 2, 4 or 8 to a packed pixel.
@(private)
unpack_indices :: proc(out, packed: []u32, width, height: int, palette: []u32, bits: uint) {
	packed_width := subsample(width, bits)
	index_bits := uint(8) >> bits
	mask := u32(1) << index_bits - 1
	per := 1 << bits
	for y in 0 ..< height {
		src := packed[y * packed_width:][:packed_width]
		dst := out[y * width:][:width]
		for &o, x in dst {
			g := (src[x >> bits] >> 8) & 0xff
			o = palette[(g >> (uint(x & (per - 1)) * index_bits)) & mask]
		}
	}
}

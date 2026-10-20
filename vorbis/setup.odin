package vorbis

import "core:math"
import "core:math/bits"
import "core:mem"

@(private)
MAX_FLOOR_POINTS :: 65

// The setup header's tables. Codebooks refer to the pools by offset; the
// pools are complete before any packet is decoded.
@(private)
Setup :: struct {
	books:        []Codebook,
	floors:       []Floor,
	residues:     []Residue,
	mappings:     []Mapping,
	modes:        []Mode,
	// Pools.
	fast:         [dynamic]u32, // per book 1 << fast_bits: entry << 6 | length, 0 for a longer code
	long_codes:   [dynamic]u32, // codes longer than fast_bits, left-justified, ascending per book
	long_entries: [dynamic]u32, // entry << 6 | length, beside long_codes
	values:       [dynamic]f32, // per book with a lookup: entries * dimensions
}

@(private)
FAST_BITS :: 10

@(private)
Codebook :: struct {
	dimensions:  int,
	entries:     int,
	values:      int, // offset in Setup.values, -1 without a lookup
	fast:        int, // offset in Setup.fast
	fast_bits:   int,
	long_first:  int, // range in Setup.long_codes
	long_count:  int,
	single:      int, // the entry of a book with one used entry, else -1
}

@(private)
Floor :: struct {
	partitions:      int,
	partition_class: [32]u8,
	class_dims:      [16]u8,
	class_subs:      [16]u8, // log2 of the subclass count
	class_master:    [16]u8,
	subclass_books:  [16][8]i16, // -1: none
	multiplier:      int,
	points:          int, // X values, the two ends included
	x:               [MAX_FLOOR_POINTS]i32,
	low, high:       [MAX_FLOOR_POINTS]u8, // each point's neighbours for prediction
	sorted:          [MAX_FLOOR_POINTS]u8, // point indices by ascending X
}

@(private)
Residue :: struct {
	type:            int,
	begin, end:      int,
	partition_size:  int,
	classifications: int,
	classbook:       int,
	books:           [64][8]i16, // per classification and pass, -1: none
}

@(private)
Mapping :: struct {
	submaps:        int,
	couplings:      int,
	magnitude:      [256]u8,
	angle:          [256]u8,
	mux:            [256]u8, // submap per channel
	submap_floor:   [16]u8,
	submap_residue: [16]u8,
}

@(private)
Mode :: struct {
	long:    bool,
	mapping: int,
}

@(private)
destroy_setup :: proc(s: ^Setup, allocator: mem.Allocator) {
	delete(s.books, allocator)
	delete(s.floors, allocator)
	delete(s.residues, allocator)
	delete(s.mappings, allocator)
	delete(s.modes, allocator)
	delete(s.fast)
	delete(s.long_codes)
	delete(s.long_entries)
	delete(s.values)
	s^ = {}
}

@(private)
read_setup :: proc(s: ^Setup, info: Info, packet: []u8, allocator: mem.Allocator) -> Error {
	if len(packet) < 7 || packet[0] != 5 || string(packet[1:7]) != "vorbis" do return .Invalid
	s.fast.allocator = allocator
	s.long_codes.allocator = allocator
	s.long_entries.allocator = allocator
	s.values.allocator = allocator
	b := Bits{data = packet[7:]}
	err: mem.Allocator_Error
	s.books, err = make([]Codebook, int(read(&b, 8)) + 1, allocator)
	if err != nil do return .Out_Of_Memory
	for &book in s.books do read_codebook(s, &book, &b) or_return
	// Time domain transforms: placeholders, each zero.
	times := int(read(&b, 6)) + 1
	for _ in 0 ..< times do if read(&b, 16) != 0 do return .Invalid
	s.floors, err = make([]Floor, int(read(&b, 6)) + 1, allocator)
	if err != nil do return .Out_Of_Memory
	for &f in s.floors {
		switch read(&b, 16) {
		case 0:
			return .Unsupported
		case 1:
			read_floor(&f, len(s.books), &b) or_return
		case:
			return .Invalid
		}
	}
	s.residues, err = make([]Residue, int(read(&b, 6)) + 1, allocator)
	if err != nil do return .Out_Of_Memory
	for &r in s.residues do read_residue(s, &r, &b) or_return
	s.mappings, err = make([]Mapping, int(read(&b, 6)) + 1, allocator)
	if err != nil do return .Out_Of_Memory
	for &m in s.mappings do read_mapping(s, &m, info.channels, &b) or_return
	s.modes, err = make([]Mode, int(read(&b, 6)) + 1, allocator)
	if err != nil do return .Out_Of_Memory
	for &m in s.modes {
		m.long = read(&b, 1) == 1
		window, transform := read(&b, 16), read(&b, 16)
		m.mapping = int(read(&b, 8))
		if window != 0 || transform != 0 || m.mapping >= len(s.mappings) do return .Invalid
	}
	if read(&b, 1) != 1 || b.overrun do return .Invalid // framing
	return .None
}

@(private)
read_codebook :: proc(s: ^Setup, c: ^Codebook, b: ^Bits) -> Error {
	if read(b, 24) != 0x564342 do return .Invalid
	c.dimensions = int(read(b, 16))
	c.entries = int(read(b, 24))
	if c.entries == 0 || b.overrun do return .Invalid
	// Lengths: 0 marks an unused entry.
	lengths := make([]u8, c.entries, context.temp_allocator)
	defer delete(lengths, context.temp_allocator)
	if read(b, 1) == 1 {
		// Ordered: runs of entries per length, ascending.
		length := int(read(b, 5)) + 1
		for i := 0; i < c.entries; length += 1 {
			n := int(read(b, ilog(c.entries - i)))
			if i + n > c.entries || length > 32 || b.overrun do return .Invalid
			for k in i ..< i + n do lengths[k] = u8(length)
			i += n
		}
	} else {
		sparse := read(b, 1) == 1
		for &l in lengths {
			if sparse && read(b, 1) == 0 do continue
			l = u8(read(b, 5) + 1)
		}
	}
	if b.overrun do return .Invalid
	build_codes(s, c, lengths) or_return
	// The VQ lookup, unpacked to every entry's vector.
	c.values = -1
	lookup := read(b, 4)
	switch lookup {
	case 0:
	case 1, 2:
		minimum := unpack_float(read(b, 32))
		delta := unpack_float(read(b, 32))
		value_bits := int(read(b, 4)) + 1
		sequence := read(b, 1) == 1
		count := lookup == 1 ? lookup1_values(c.entries, c.dimensions) : c.entries * c.dimensions
		if count <= 0 || c.entries * c.dimensions > 1 << 24 do return .Unsupported
		multiplicands := make([]u32, count, context.temp_allocator)
		defer delete(multiplicands, context.temp_allocator)
		for &m in multiplicands do m = read(b, value_bits)
		if b.overrun do return .Invalid
		c.values = len(s.values)
		if resize(&s.values, len(s.values) + c.entries * c.dimensions) != nil do return .Out_Of_Memory
		out := s.values[c.values:]
		for e in 0 ..< c.entries {
			last: f32
			divisor := 1
			for k in 0 ..< c.dimensions {
				m := lookup == 1 ? multiplicands[e / divisor % count] : multiplicands[e * c.dimensions + k]
				v := f32(m) * delta + minimum + last
				out[e * c.dimensions + k] = v
				if sequence do last = v
				divisor *= count
			}
		}
	case:
		return .Invalid
	}
	return .None
}

// The specification's float format: a 21-bit mantissa, a sign, and a
// 10-bit exponent biased by 788.
@(private)
unpack_float :: proc(x: u32) -> f32 {
	mantissa := f64(x & 0x1F_FFFF)
	if x & 0x8000_0000 != 0 do mantissa = -mantissa
	return f32(math.ldexp(mantissa, int((x & 0x7FE0_0000) >> 21) - 788))
}

// The largest r with r ^ dimensions <= entries.
@(private)
lookup1_values :: proc(entries, dimensions: int) -> int {
	if dimensions == 0 do return 0
	fits :: proc(r, dimensions, entries: int) -> bool {
		p := 1
		for _ in 0 ..< dimensions {
			p *= r
			if p > entries do return false
		}
		return true
	}
	r := int(math.pow(f64(entries), 1 / f64(dimensions)))
	for fits(r + 1, dimensions, entries) do r += 1
	for r > 0 && !fits(r, dimensions, entries) do r -= 1
	return r
}

// Codewords, as the specification assigns them: each used entry in order
// takes the lowest codeword of its length that neither has an assigned
// codeword as a prefix nor is one's prefix. A binary trie of the codeword
// space records, for each node, the depth of its shallowest wholly free
// node, so the leftmost free codeword of a length is a walk from the root.
// Then the decode tables: codes up to fast_bits long fill a table indexed by
// the next bits; longer ones are kept left-justified and sorted.
@(private)
build_codes :: proc(s: ^Setup, c: ^Codebook, lengths: []u8) -> Error {
	NONE :: 255
	Node :: struct {
		child: [2]i32, // 0: not split
		free:  u8, // depth of the shallowest wholly free node below, NONE if full
	}
	used, longest := 0, 0
	for l in lengths do if l > 0 {used += 1; longest = max(longest, int(l))}
	c.single = -1
	if used == 0 do return .None // no entry can be decoded
	nodes := make([dynamic]Node, 0, 2 * used * longest + 1, context.temp_allocator)
	defer delete(nodes)
	codes := make([]u32, len(lengths), context.temp_allocator)
	defer delete(codes, context.temp_allocator)
	append(&nodes, Node{})
	path: [33]i32
	for l, e in lengths {
		if l == 0 do continue
		length := int(l)
		if int(nodes[0].free) > length do return .Invalid // overpopulated
		node, code := i32(0), u32(0)
		for depth in 0 ..< length {
			path[depth] = node
			if nodes[node].child[0] == 0 {
				// Split a free node into two free halves.
				first := i32(len(nodes))
				append(&nodes, Node{free = u8(depth + 1)}, Node{free = u8(depth + 1)})
				nodes[node].child = {first, first + 1}
			}
			left := nodes[node].child[0]
			side := int(nodes[left].free) <= length ? 0 : 1
			node = nodes[node].child[side]
			code = code << 1 | u32(side)
		}
		nodes[node].free = NONE
		for depth := length - 1; depth >= 0; depth -= 1 {
			n := &nodes[path[depth]]
			n.free = min(nodes[n.child[0]].free, nodes[n.child[1]].free)
		}
		codes[e] = code
	}
	if nodes[0].free != NONE {
		// Underpopulated: allowed only for a book of one entry of length 1.
		if used != 1 || longest != 1 do return .Invalid
		for l, e in lengths do if l > 0 do c.single = e
		return .None
	}
	c.fast_bits = min(FAST_BITS, longest)
	c.fast = len(s.fast)
	if resize(&s.fast, len(s.fast) + 1 << uint(c.fast_bits)) != nil do return .Out_Of_Memory
	fast := s.fast[c.fast:]
	c.long_first = len(s.long_codes)
	for l, e in lengths {
		length := int(l)
		switch {
		case length == 0:
		case length <= c.fast_bits:
			// The next bits arrive least significant first: the codeword reversed.
			reversed := int(bits.reverse_bits(codes[e]) >> uint(32 - length))
			for i := reversed; i < len(fast); i += 1 << uint(length) do fast[i] = u32(e) << 6 | u32(length)
		case:
			append(&s.long_codes, codes[e] << uint(32 - length))
			append(&s.long_entries, u32(e) << 6 | u32(length))
		}
	}
	c.long_count = len(s.long_codes) - c.long_first
	// Ascending left-justified codes, entries beside them.
	codes_of := s.long_codes[c.long_first:]
	entries_of := s.long_entries[c.long_first:]
	for i in 1 ..< len(codes_of) {
		for j := i; j > 0 && codes_of[j - 1] > codes_of[j]; j -= 1 {
			codes_of[j - 1], codes_of[j] = codes_of[j], codes_of[j - 1]
			entries_of[j - 1], entries_of[j] = entries_of[j], entries_of[j - 1]
		}
	}
	return .None
}

// The next codeword's entry, or -1 at the end of the packet.
@(private)
decode_entry :: #force_inline proc(s: ^Setup, c: ^Codebook, b: ^Bits) -> int #no_bounds_check {
	if c.single >= 0 {
		read(b, 1)
		return b.overrun ? -1 : c.single
	}
	if b.count < 32 do refill(b)
	f := s.fast[c.fast + int(b.window & (1 << uint(c.fast_bits) - 1))]
	if f == 0 && c.long_count > 0 {
		// Longer than the table: the next 32 bits in codeword order, against
		// the sorted left-justified codes.
		p := bits.reverse_bits(u32(b.window))
		lo, hi := c.long_first, c.long_first + c.long_count
		for hi - lo > 1 {
			mid := (lo + hi) >> 1
			if s.long_codes[mid] <= p {lo = mid} else {hi = mid}
		}
		f = s.long_entries[lo]
		if (p ~ s.long_codes[lo]) >> uint(32 - f & 63) != 0 do f = 0
	}
	length := int(f & 63)
	if f == 0 || length > b.count {
		b.overrun = true
		b.window, b.count = 0, 0
		return -1
	}
	b.window >>= uint(length)
	b.count -= length
	return int(f >> 6)
}

@(private)
read_floor :: proc(f: ^Floor, books: int, b: ^Bits) -> Error {
	f.partitions = int(read(b, 5))
	classes := 0
	for &c in f.partition_class[:f.partitions] {
		c = u8(read(b, 4))
		classes = max(classes, int(c) + 1)
	}
	for k in 0 ..< classes {
		f.class_dims[k] = u8(read(b, 3) + 1)
		f.class_subs[k] = u8(read(b, 2))
		if f.class_subs[k] != 0 {
			f.class_master[k] = u8(read(b, 8))
			if int(f.class_master[k]) >= books do return .Invalid
		}
		for j in 0 ..< 1 << f.class_subs[k] {
			book := i16(read(b, 8)) - 1
			if int(book) >= books do return .Invalid
			f.subclass_books[k][j] = book
		}
	}
	f.multiplier = int(read(b, 2)) + 1
	range_bits := int(read(b, 4))
	f.x[0], f.x[1] = 0, 1 << uint(range_bits)
	f.points = 2
	for c in f.partition_class[:f.partitions] {
		for _ in 0 ..< f.class_dims[c] {
			if f.points == MAX_FLOOR_POINTS do return .Invalid
			f.x[f.points] = i32(read(b, range_bits))
			f.points += 1
		}
	}
	if b.overrun do return .Invalid
	// Facts used by every packet: the sort by X (values unique), and each
	// point's neighbours among the points before it.
	for i in 0 ..< f.points do f.sorted[i] = u8(i)
	for i in 1 ..< f.points {
		for j := i; j > 0 && f.x[f.sorted[j - 1]] > f.x[f.sorted[j]]; j -= 1 do f.sorted[j - 1], f.sorted[j] = f.sorted[j], f.sorted[j - 1]
	}
	for i in 1 ..< f.points do if f.x[f.sorted[i - 1]] == f.x[f.sorted[i]] do return .Invalid
	for i in 2 ..< f.points {
		low, high := 0, 1
		for j in 0 ..< i {
			if f.x[j] < f.x[i] && f.x[j] > f.x[low] do low = j
			if f.x[j] > f.x[i] && f.x[j] < f.x[high] do high = j
		}
		f.low[i], f.high[i] = u8(low), u8(high)
	}
	return .None
}

@(private)
read_residue :: proc(s: ^Setup, r: ^Residue, b: ^Bits) -> Error {
	r.type = int(read(b, 16))
	if r.type > 2 do return .Invalid
	r.begin = int(read(b, 24))
	r.end = int(read(b, 24))
	r.partition_size = int(read(b, 24)) + 1
	r.classifications = int(read(b, 6)) + 1
	r.classbook = int(read(b, 8))
	if r.classbook >= len(s.books) do return .Invalid
	cascade: [64]u32
	for &c in cascade[:r.classifications] {
		c = read(b, 3)
		if read(b, 1) == 1 do c |= read(b, 5) << 3
	}
	for c, k in cascade[:r.classifications] {
		for pass in 0 ..< 8 {
			r.books[k][pass] = -1
			if c >> uint(pass) & 1 == 0 do continue
			book := int(read(b, 8))
			if book >= len(s.books) || s.books[book].values < 0 do return .Invalid
			r.books[k][pass] = i16(book)
		}
	}
	// Classification words must stay within the classbook's entries.
	cb := s.books[r.classbook]
	words := 1
	for _ in 0 ..< cb.dimensions do words = min(words * r.classifications, 1 << 30)
	if cb.dimensions == 0 || words > cb.entries do return .Invalid
	return b.overrun ? .Invalid : .None
}

@(private)
read_mapping :: proc(s: ^Setup, m: ^Mapping, channels: int, b: ^Bits) -> Error {
	if read(b, 16) != 0 do return .Invalid
	m.submaps = read(b, 1) == 1 ? int(read(b, 4)) + 1 : 1
	if read(b, 1) == 1 {
		m.couplings = int(read(b, 8)) + 1
		width := ilog(channels - 1)
		for k in 0 ..< m.couplings {
			mag, ang := int(read(b, width)), int(read(b, width))
			if mag == ang || mag >= channels || ang >= channels do return .Invalid
			m.magnitude[k], m.angle[k] = u8(mag), u8(ang)
		}
	}
	if read(b, 2) != 0 do return .Invalid
	if m.submaps > 1 {
		for &x in m.mux[:channels] {
			x = u8(read(b, 4))
			if int(x) >= m.submaps do return .Invalid
		}
	}
	for k in 0 ..< m.submaps {
		read(b, 8)
		m.submap_floor[k] = u8(read(b, 8))
		m.submap_residue[k] = u8(read(b, 8))
		if int(m.submap_floor[k]) >= len(s.floors) || int(m.submap_residue[k]) >= len(s.residues) do return .Invalid
	}
	return b.overrun ? .Invalid : .None
}

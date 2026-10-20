package aac

Error :: enum {
	None,
	Truncated,
	Invalid_Data,
	Invalid_Config,
	Unsupported_Profile,
	Unsupported_Channels,
	Unsupported_Transport,
	Unsupported_Tool,
	Output_Too_Small,
	Invalid_State,
	Crc_Mismatch,
	Allocation_Failed,
}

Bit_Reader :: struct {
	data: []u8,
	pos:  int,
	err:  Error,
}

@(private)
peek_bits_unchecked :: #force_inline proc(r: ^Bit_Reader, n: int) -> u32 #no_bounds_check {
	// The caller proves all one-to-five bytes exist. No input padding or
	// persistent reservoir is needed; public pos/skip/align remain authoritative.
	first := r.pos >> 3
	bytes := ((r.pos & 7) + n + 7) >> 3
	v := u64(r.data[first])
	if bytes > 1 do v = v << 8 | u64(r.data[first + 1])
	if bytes > 2 do v = v << 8 | u64(r.data[first + 2])
	if bytes > 3 do v = v << 8 | u64(r.data[first + 3])
	if bytes > 4 do v = v << 8 | u64(r.data[first + 4])
	return u32((v >> uint(bytes * 8 - (r.pos & 7) - n)) & ((u64(1) << uint(n)) - 1))
}

read_bits :: proc(r: ^Bit_Reader, n: int) -> u32 {
	if r.err != .None do return 0
	if n < 0 || n > 32 || r.pos < 0 {
		r.err = .Truncated
		return 0
	}
	first := r.pos >> 3
	bytes := ((r.pos & 7) + n + 7) >> 3
	if first > len(r.data) || bytes > len(r.data) - first {
		r.err = .Truncated
		return 0
	}
	if n == 0 do return 0
	v := peek_bits_unchecked(r, n)
	r.pos += n
	return v
}

read_flag :: proc(r: ^Bit_Reader) -> bool {return read_bits(r, 1) != 0}

skip_bits :: proc(r: ^Bit_Reader, n: int) {
	if n < 0 || n > len(r.data) * 8 - r.pos {r.err = .Truncated; return}
	r.pos += n
}

align_reader :: proc(r: ^Bit_Reader) {skip_bits(r, -r.pos & 7)}

Huffman_Node :: struct {
	child:  [2]i16,
	symbol: i16,
}
Huffman_Prefix :: struct {
	target: i16, // Symbol if leaf, otherwise the continuation node or missing edge.
	bits:   u8,
	leaf:   bool,
}
Huffman_Tables :: struct {
	nodes:        [12][578]Huffman_Node,
	prefix:       [12][256]Huffman_Prefix,
	prefix_ready: bool,
}

init_huffman :: proc(t: ^Huffman_Tables) {
	t.prefix_ready = false
	for book in 0 ..< 12 {
		for &node in t.nodes[book] do node = {
			child  = {-1, -1},
			symbol = -1,
		}
		next := 1
		for code, symbol in CODEBOOKS[book] {
			n := 0
			for b := int(code.length) - 1; b >= 0; b -= 1 {
				bit := (code.bits >> uint(b)) & 1
				if t.nodes[book][n].child[bit] < 0 {
					assert(next < len(t.nodes[book]))
					t.nodes[book][n].child[bit] = i16(next)
					next += 1
				}
				n = int(t.nodes[book][n].child[bit])
			}
			t.nodes[book][n].symbol = i16(symbol)
		}
		// Compile eight-bit prefixes from this same tree. Each entry retains
		// its actual consumed depth, including a missing edge, so error positions
		// agree with the scalar walk. Rare long codes resume at the stored node.
		for prefix in 0 ..< 256 {
			n, depth := 0, 0
			for depth < 8 && n >= 0 && t.nodes[book][n].symbol < 0 {
				bit := (prefix >> uint(7 - depth)) & 1
				n = int(t.nodes[book][n].child[bit])
				depth += 1
			}
			leaf := n >= 0 && t.nodes[book][n].symbol >= 0
			t.prefix[book][prefix] = {
				target = leaf ? t.nodes[book][n].symbol : i16(n),
				bits   = u8(depth),
				leaf   = leaf,
			}
		}
	}
	t.prefix_ready = true
}

read_huffman :: proc(r: ^Bit_Reader, t: ^Huffman_Tables, book: int) -> int {
	if book < 0 || book >= 12 {r.err = .Invalid_Data; return 0}
	n, depth := 0, 0
	first := r.pos >> 3
	// Short tails and existing errors use the original walk. A zero/custom
	// tree without init_huffman also keeps its old scalar interpretation.
	if t.prefix_ready &&
	   r.err == .None &&
	   r.pos >= 0 &&
	   first < len(r.data) &&
	   (r.pos & 7 == 0 || len(r.data) - first >= 2) {
		entry := t.prefix[book][peek_bits_unchecked(r, 8)]
		r.pos += int(entry.bits)
		if entry.leaf do return int(entry.target)
		if entry.target < 0 {r.err = .Invalid_Data; return 0}
		n, depth = int(entry.target), int(entry.bits)
	}
	for _ in depth ..< 20 {
		if t.nodes[book][n].symbol >= 0 do return int(t.nodes[book][n].symbol)
		n = int(t.nodes[book][n].child[read_bits(r, 1)])
		if n < 0 || r.err != .None {r.err = r.err == .None ? .Invalid_Data : r.err; return 0}
	}
	r.err = .Invalid_Data
	return 0
}

package png_encoder

import "core:slice"

// A zlib stream (RFC 1950) of deflate data (RFC 1951) for PNG writing, in
// Odin so oicut links no C compression library. Like zlib's Z_RLE strategy:
// runs of the previous byte become length/distance-1 matches, which is what
// Paeth-filtered images compress to, and every DEFLATE_BLOCK symbols go out
// as a dynamic Huffman block.

@(private)
DEFLATE_BLOCK :: 1 << 15

@(private)
Deflate :: struct {
	// Compressed bytes not yet taken by the caller, after `reserve` bytes
	// it keeps free in front (room for a PNG chunk header).
	out:      [dynamic]u8,
	reserve:  int,
	bits:     u64,
	nbits:    u32,
	// Literals (< 256) and runs (256 + length - 3) of the open block.
	syms:     []u16,
	nsyms:    int,
	lit_freq: [286]u32,
	// The previous byte, or -1 before the first.
	prev:     i32,
	adler_a:  u32,
	adler_b:  u32,
}

@(private)
deflate_init :: proc(d: ^Deflate, reserve: int, allocator := context.allocator) {
	d^ = {reserve = reserve, prev = -1, adler_a = 1}
	d.out = make([dynamic]u8, reserve, 1 << 16, allocator)
	d.syms = make([]u16, DEFLATE_BLOCK, allocator)
	append(&d.out, 0x78, 0x01) // deflate, 32 KB window, fastest
}

@(private)
deflate_destroy :: proc(d: ^Deflate) {
	delete(d.out)
	delete(d.syms)
}

@(private)
deflate_write :: proc(d: ^Deflate, data: []u8) {
	deflate_adler(d, data)
	n := len(data)
	for i := 0; i < n; {
		b := data[i]
		if i32(b) == d.prev {
			r := 1
			for i + r < n && r < 258 && data[i + r] == b {
				r += 1
			}
			if r >= 3 {
				d.syms[d.nsyms] = u16(256 + r - 3)
				d.lit_freq[257 + int(DEFLATE_LEN_CODE[r - 3])] += 1
				d.nsyms += 1
				if d.nsyms == DEFLATE_BLOCK {
					deflate_block(d, false)
				}
				i += r
				continue
			}
		}
		d.syms[d.nsyms] = u16(b)
		d.lit_freq[b] += 1
		d.nsyms += 1
		if d.nsyms == DEFLATE_BLOCK {
			deflate_block(d, false)
		}
		d.prev = i32(b)
		i += 1
	}
}

// Ends the stream: the last block, padding to a byte, the Adler-32.
@(private)
deflate_finish :: proc(d: ^Deflate) {
	deflate_block(d, true)
	for d.nbits > 0 {
		append(&d.out, u8(d.bits))
		d.bits >>= 8
		d.nbits = d.nbits - 8 if d.nbits > 8 else 0
	}
	adler := d.adler_b << 16 | d.adler_a
	append(&d.out, u8(adler >> 24), u8(adler >> 16), u8(adler >> 8), u8(adler))
}

@(private = "file")
deflate_adler :: proc "contextless" (d: ^Deflate, data: []u8) {
	a, b := d.adler_a, d.adler_b
	for rest := data; len(rest) > 0; {
		// 5552 bytes keep the sums within 32 bits before the modulo.
		k := min(len(rest), 5552)
		for v in rest[:k] {
			a += u32(v)
			b += a
		}
		a %= 65521
		b %= 65521
		rest = rest[k:]
	}
	d.adler_a, d.adler_b = a, b
}

@(private = "file")
put_bits :: #force_inline proc(d: ^Deflate, code: u32, n: u32) {
	d.bits |= u64(code) << d.nbits
	d.nbits += n
	if d.nbits >= 32 {
		v := u32(d.bits)
		append(&d.out, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
		d.bits >>= 32
		d.nbits -= 32
	}
}

// Length codes 257.. by run length - 3, and each code's base length and
// extra bits.
@(private = "file", rodata)
DEFLATE_LEN_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
@(private = "file", rodata)
DEFLATE_LEN_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
@(private = "file")
DEFLATE_LEN_CODE := #partial [256]u8{}

@(init, private = "file")
deflate_tables :: proc "contextless" () {
	for c in 0 ..< 28 {
		for l in DEFLATE_LEN_BASE[c] ..< DEFLATE_LEN_BASE[c + 1] {
			DEFLATE_LEN_CODE[l - 3] = u8(c)
		}
	}
	DEFLATE_LEN_CODE[255] = 28
}

// Order the code length code lengths are sent in.
@(private = "file", rodata)
DEFLATE_CL_ORDER := [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

@(private = "file")
deflate_block :: proc(d: ^Deflate, final: bool) {
	d.lit_freq[256] = 1
	// Every run is distance 1; a second code keeps the distance code
	// complete, as zlib does.
	dist_freq: [30]u32
	dist_freq[0], dist_freq[1] = 1, 1
	lit_len: [286]u8
	dist_len: [30]u8
	huffman_lengths(d.lit_freq[:], lit_len[:], 15)
	huffman_lengths(dist_freq[:], dist_len[:], 15)
	hlit := 286
	for hlit > 257 && lit_len[hlit - 1] == 0 {
		hlit -= 1
	}
	hdist := 2

	// The code lengths, run-length coded with 16 (repeat the previous 3-6
	// times), 17 (3-10 zeros) and 18 (11-138 zeros).
	lens: [286 + 30]u8
	copy(lens[:], lit_len[:hlit])
	copy(lens[hlit:], dist_len[:hdist])
	all := lens[:hlit + hdist]
	cl_syms: [286 + 30][2]u8 // code, extra value
	ncl := 0
	cl_freq: [19]u32
	for i := 0; i < len(all); {
		l := all[i]
		r := 1
		for i + r < len(all) && all[i + r] == l {
			r += 1
		}
		i += r
		if l == 0 {
			for r >= 11 {
				k := min(r, 138)
				cl_syms[ncl] = {18, u8(k - 11)}
				ncl += 1
				r -= k
			}
			if r >= 3 {
				cl_syms[ncl] = {17, u8(r - 3)}
				ncl += 1
				r = 0
			}
		} else {
			cl_syms[ncl] = {l, 0}
			ncl += 1
			r -= 1
			for r >= 3 {
				k := min(r, 6)
				cl_syms[ncl] = {16, u8(k - 3)}
				ncl += 1
				r -= k
			}
		}
		for _ in 0 ..< r {
			cl_syms[ncl] = {l, 0}
			ncl += 1
		}
	}
	for s in cl_syms[:ncl] {
		cl_freq[s[0]] += 1
	}
	cl_len: [19]u8
	huffman_lengths(cl_freq[:], cl_len[:], 7)
	hclen := 19
	for hclen > 4 && cl_len[DEFLATE_CL_ORDER[hclen - 1]] == 0 {
		hclen -= 1
	}

	lit_code: [286]u16
	dist_code: [30]u16
	cl_code: [19]u16
	huffman_codes(lit_len[:], lit_code[:])
	huffman_codes(dist_len[:], dist_code[:])
	huffman_codes(cl_len[:], cl_code[:])

	put_bits(d, u32(final), 1)
	put_bits(d, 2, 2)
	put_bits(d, u32(hlit - 257), 5)
	put_bits(d, u32(hdist - 1), 5)
	put_bits(d, u32(hclen - 4), 4)
	for i in 0 ..< hclen {
		put_bits(d, u32(cl_len[DEFLATE_CL_ORDER[i]]), 3)
	}
	for s in cl_syms[:ncl] {
		put_bits(d, u32(cl_code[s[0]]), u32(cl_len[s[0]]))
		switch s[0] {
		case 16: put_bits(d, u32(s[1]), 2)
		case 17: put_bits(d, u32(s[1]), 3)
		case 18: put_bits(d, u32(s[1]), 7)
		}
	}
	for s in d.syms[:d.nsyms] {
		if s < 256 {
			put_bits(d, u32(lit_code[s]), u32(lit_len[s]))
			continue
		}
		run := int(s) - 256
		c := DEFLATE_LEN_CODE[run]
		put_bits(d, u32(lit_code[257 + int(c)]), u32(lit_len[257 + int(c)]))
		if e := DEFLATE_LEN_EXTRA[c]; e > 0 {
			put_bits(d, u32(run + 3 - int(DEFLATE_LEN_BASE[c])), u32(e))
		}
		put_bits(d, u32(dist_code[0]), u32(dist_len[0]))
	}
	put_bits(d, u32(lit_code[256]), u32(lit_len[256]))
	d.nsyms = 0
	d.lit_freq = {}
}

// Code lengths of at most `limit` bits for the symbols with a frequency:
// minimum-redundancy lengths (Moffat and Katajainen's in-place method), then
// the longest codes folded under the limit.
@(private = "file")
huffman_lengths :: proc(freq: []u32, lens: []u8, limit: int) {
	Sym :: struct {
		key: u32,
		sym: u16,
	}
	syms: [286]Sym
	n := 0
	for f, s in freq {
		lens[s] = 0
		if f > 0 {
			syms[n] = {f, u16(s)}
			n += 1
		}
	}
	a := syms[:n]
	slice.sort_by(a, proc(x, y: Sym) -> bool {return x.key < y.key || (x.key == y.key && x.sym < y.sym)})
	if n == 0 {
		return
	}
	if n == 1 {
		// A one-symbol code is incomplete, which inflaters reject for code
		// length codes: pair it with an unused symbol.
		lens[a[0].sym] = 1
		lens[1 if a[0].sym == 0 else 0] = 1
		return
	}
	// a[i].key becomes the length of the i-th rarest symbol.
	a[0].key += a[1].key
	root, leaf := 0, 2
	for next in 1 ..< n - 1 {
		if leaf >= n || a[root].key < a[leaf].key {
			a[next].key = a[root].key
			a[root].key = u32(next)
			root += 1
		} else {
			a[next].key = a[leaf].key
			leaf += 1
		}
		if leaf >= n || (root < next && a[root].key < a[leaf].key) {
			a[next].key += a[root].key
			a[root].key = u32(next)
			root += 1
		} else {
			a[next].key += a[leaf].key
			leaf += 1
		}
	}
	a[n - 2].key = 0
	for next := n - 3; next >= 0; next -= 1 {
		a[next].key = a[a[next].key].key + 1
	}
	avail, used, depth := 1, 0, u32(0)
	root2, next := n - 2, n - 1
	for avail > 0 {
		for root2 >= 0 && a[root2].key == depth {
			used += 1
			root2 -= 1
		}
		for avail > used {
			a[next].key = depth
			next -= 1
			avail -= 1
		}
		avail = 2 * used
		depth += 1
		used = 0
	}

	count: [64]int
	for s in a {
		count[min(int(s.key), 63)] += 1
	}
	for l in limit + 1 ..< 64 {
		count[limit] += count[l]
	}
	// Kraft sum in units of 2^-limit: shorten nothing, lengthen until it fits.
	total := 0
	for l in 1 ..= limit {
		total += count[l] << uint(limit - l)
	}
	for total != 1 << uint(limit) {
		count[limit] -= 1
		for l := limit - 1; l > 0; l -= 1 {
			if count[l] != 0 {
				count[l] -= 1
				count[l + 1] += 2
				break
			}
		}
		total -= 1
	}
	// The shortest codes go to the most frequent symbols.
	j := n
	for l in 1 ..= limit {
		for _ in 0 ..< count[l] {
			j -= 1
			lens[a[j].sym] = u8(l)
		}
	}
}

// Canonical codes for `lens`, bit-reversed since deflate sends codes most
// significant bit first into a least-significant-first stream.
@(private = "file")
huffman_codes :: proc(lens: []u8, codes: []u16) {
	count: [16]u16
	for l in lens {
		count[l] += 1
	}
	count[0] = 0
	next: [16]u16
	code: u16
	for l in 1 ..< 16 {
		code = (code + count[l - 1]) << 1
		next[l] = code
	}
	for l, s in lens {
		if l == 0 {
			continue
		}
		c := next[l]
		next[l] += 1
		r: u16
		for _ in 0 ..< l {
			r = r << 1 | c & 1
			c >>= 1
		}
		codes[s] = r
	}
}

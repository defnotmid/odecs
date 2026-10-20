package mp3

import "base:runtime"
import "core:math"

// Layer III decoding (ISO/IEC 11172-3, with the lower sampling frequencies
// of ISO/IEC 13818-3 and MPEG-2.5). The front end -- side information,
// scalefactors, Huffman decoding, stereo processing, reordering and alias
// reduction -- follows minimp3 (CC0). The hybrid filterbank and polyphase
// synthesis follow the standard's definitions (as PDMP3 does), so samples
// stay at the standard's scale and come out in [-1, 1). Each channel keeps
// its own planes: spectrum, overlap, synthesis vector and output.

MAX_RESERVOIR :: 511
@(private)
MAX_FRAME :: 2304 // above the largest Layer III frame (1441 bytes)

Granule :: struct {
	sfb:               []u8, // scalefactor band widths, zero-terminated
	part23_length:     int,
	big_values:        int,
	global_gain:       int,
	scalefac_compress: int,
	block_type:        u8, // 0 normal, 1 start, 2 short, 3 stop
	mixed:             bool,
	long_bands:        int, // scalefactor bands coded as long
	short_bands:       int, // and as short (three windows each)
	table_select:      [3]u8,
	region_count:      [3]u8, // bands per Huffman region, less one; 255 is the rest
	subblock_gain:     [3]u8,
	preflag:           bool,
	scalefac_scale:    u8,
	count1_table:      u8,
	scfsi:             u8, // granule 1 reuses these scalefactor groups of granule 0
}

Decoder :: struct {
	reservoir:     [MAX_RESERVOIR]u8,
	reservoir_len: int,
	overlap:       [2][576]f32, // second halves of the previous IMDCT outputs
	synth:         [2][2 * 1024]f32, // V vectors, each value stored at i and i+1024
	synth_at:      int,
	pcm:           [2][1152]f32,
	// Per-frame scratch.
	main:          [MAX_RESERVOIR + MAX_FRAME + 8]u8,
	spectrum:      [2][576]f32, // frequency lines, subband-major (32 x 18)
	slots:         [2][18 * 32]f32, // subband samples, time-major (18 x 32) for the synthesis
	ist_pos:       [2][40]u8, // right-channel scalefactors: intensity positions (and scfsi reuse)
	scf:           [40]f32,
	granules:      [4]Granule,
}

// A decoded frame: header.channels planes of header.samples samples,
// borrowed until the next decode_frame. `complete` is false when the frame's
// main data began in bytes the decoder has not seen (the first frames after
// a seek); its granules are then decoded as silence.
Frame :: struct {
	header:   Header,
	pcm:      [2][]f32,
	complete: bool,
}

// Clears the stream state, as for a seek.
reset :: proc(d: ^Decoder) {
	d.reservoir_len = 0
	d.overlap = {}
	d.synth = {}
	d.synth_at = 0
}

// Decodes one whole frame (header to padding) at the start of data.
decode_frame :: proc(d: ^Decoder, data: []u8) -> (f: Frame, err: Error) {
	h := parse_header(data) or_return
	if len(data) < h.frame_bytes do return f, .Invalid_Data
	f.header = h
	nch := h.channels
	b := Bits {
		data  = data[:h.frame_bytes],
		pos   = h.crc ? 48 : 32,
		limit = h.frame_bytes * 8,
	}
	main_begin := read_side_info(&b, d.granules[:], h) or_return
	// Main data: the reservoir's last main_begin bytes, then this frame's.
	payload := data[b.pos / 8:h.frame_bytes]
	have := min(d.reservoir_len, main_begin)
	copy(d.main[:have], d.reservoir[d.reservoir_len - have:d.reservoir_len])
	copy(d.main[have:], payload)
	total := have + len(payload)
	m := Bits {
		data  = d.main[:total],
		limit = total * 8,
	}
	f.complete = d.reservoir_len >= main_begin
	granules := h.version == .MPEG1 ? 2 : 1
	for gr in 0 ..< granules {
		for &s in d.spectrum[:nch] do s = {}
		if f.complete do decode_granule(d, &m, d.granules[gr * nch:][:nch], h)
		for ch in 0 ..< nch {
			hybrid_synthesis(d.spectrum[ch][:], d.overlap[ch][:], d.slots[ch][:], &d.granules[gr * nch + ch], h)
		}
		synthesize(d, nch, d.pcm[0][gr * 576:][:576], d.pcm[1][gr * 576:][:576])
	}
	// Keep the unread tail (at most 511 bytes) for the following frames.
	pos := min((m.pos + 7) / 8, total)
	remains := total - pos
	if remains > MAX_RESERVOIR {
		pos += remains - MAX_RESERVOIR
		remains = MAX_RESERVOIR
	}
	copy(d.reservoir[:remains], d.main[pos:total])
	d.reservoir_len = remains
	for ch in 0 ..< nch do f.pcm[ch] = d.pcm[ch][:h.samples]
	return f, .None
}

// ---- Side information (2.4.1.7) ---------------------------------------------

@(private)
read_side_info :: proc(b: ^Bits, granules: []Granule, h: Header) -> (main_begin: int, err: Error) {
	row := max(h.rate_index - 1, 0) // 11.025 and 12 kHz share a band table
	nch := h.channels
	mpeg1 := h.version == .MPEG1
	scfsi: [2]u8
	if mpeg1 {
		main_begin = int(get_bits(b, 9))
		get_bits(b, nch == 1 ? 5 : 3) // private bits
		for ch in 0 ..< nch do scfsi[ch] = u8(get_bits(b, 4))
	} else {
		main_begin = int(get_bits(b, 8))
		get_bits(b, nch) // private bits
	}
	count := nch * (mpeg1 ? 2 : 1)
	part23_sum := 0
	for i in 0 ..< count {
		g := &granules[i]
		g^ = {}
		gr, ch := i / nch, i % nch
		g.part23_length = int(get_bits(b, 12))
		part23_sum += g.part23_length
		g.big_values = int(get_bits(b, 9))
		if g.big_values > 288 do return 0, .Invalid_Data
		g.global_gain = int(get_bits(b, 8))
		g.scalefac_compress = int(get_bits(b, mpeg1 ? 4 : 9))
		g.sfb = SFB_LONG[row][:]
		g.long_bands = 22
		tables: u32
		if get_bits(b, 1) == 1 {
			g.block_type = u8(get_bits(b, 2))
			if g.block_type == 0 do return 0, .Invalid_Data
			g.mixed = get_bits(b, 1) == 1
			g.region_count = {7, 255, 0}
			if g.block_type == 2 {
				if g.mixed {
					g.sfb = SFB_MIXED[row][:]
					g.long_bands = mpeg1 ? 8 : 6
					g.short_bands = 30
				} else {
					g.region_count[0] = 8
					g.sfb = SFB_SHORT[row][:]
					g.long_bands = 0
					g.short_bands = 39
				}
			}
			tables = get_bits(b, 10) << 5
			for &s in g.subblock_gain do s = u8(get_bits(b, 3))
		} else {
			tables = get_bits(b, 15)
			g.region_count = {u8(get_bits(b, 4)), u8(get_bits(b, 3)), 255}
		}
		g.table_select = {u8(tables >> 10), u8(tables >> 5 & 31), u8(tables & 31)}
		g.preflag = mpeg1 ? get_bits(b, 1) == 1 : g.scalefac_compress >= 500
		g.scalefac_scale = u8(get_bits(b, 1))
		g.count1_table = u8(get_bits(b, 1))
		// Scalefactor reuse applies to the second granule, and not to short
		// blocks in either granule.
		if mpeg1 && gr == 1 && g.block_type != 2 && granules[ch].block_type != 2 do g.scfsi = scfsi[ch]
	}
	if b.pos > b.limit || part23_sum > b.limit - b.pos + main_begin * 8 do return 0, .Invalid_Data
	return main_begin, .None
}

// ---- Scalefactors (2.4.3.4.4; 13818-3 2.4.3.2) -------------------------------

@(private, rodata)
PRETAB := [10]u8{1, 1, 1, 1, 2, 2, 3, 3, 3, 2}

// Reads a granule's scalefactors and turns each band's into its gain:
// 2^((global_gain - 210 - 8 * subblock_gain - 2 * ms) / 4 - multiplier *
// (scalefactor + pretab)). Mid/side's 1/sqrt(2) is folded in here.
@(private)
decode_scalefactors :: proc(h: Header, ist_pos: []u8, b: ^Bits, g: ^Granule, scf: []f32, ch: int) {
	partitions := SCF_PARTITIONS[(g.short_bands != 0 ? 1 : 0) + (g.long_bands == 0 ? 1 : 0)][:]
	sizes: [4]u8
	scfsi := int(g.scfsi)
	if h.version == .MPEG1 {
		part := SCF_COMPRESS[g.scalefac_compress]
		sizes = {part >> 2, part >> 2, part & 3, part & 3}
	} else {
		// 13818-3: scalefac_compress splits into four widths by moduli
		// that select one of the partition groups.
		ist := intensity_stereo(h) && ch == 1 ? 1 : 0
		sfc := g.scalefac_compress >> uint(ist)
		k := ist * 3 * 4
		for sfc >= 0 {
			product := 1
			for i := 3; i >= 0; i -= 1 {
				m := int(SCF_MOD[k + i])
				sizes[i] = u8(sfc / product % m)
				product *= m
			}
			sfc -= product
			k += 4
		}
		partitions = partitions[k:]
		scfsi = -16 // no reuse; the largest value marks an illegal intensity position
	}
	iscf: [43]int
	at := 0
	for i := 0; i < 4 && partitions[i] != 0; i += 1 {
		n := int(partitions[i])
		switch {
		case scfsi & 8 != 0:
			for k in 0 ..< n do iscf[at + k] = int(ist_pos[at + k])
		case sizes[i] == 0:
			for k in 0 ..< n do ist_pos[at + k] = 0
		case:
			bits := int(sizes[i])
			illegal := scfsi < 0 ? 1 << uint(bits) - 1 : -1
			for k in 0 ..< n {
				s := int(get_bits(b, bits))
				ist_pos[at + k] = s == illegal ? 255 : u8(s)
				iscf[at + k] = s
			}
		}
		at += n
		scfsi *= 2
	}
	shift := uint(g.scalefac_scale) + 1
	if g.short_bands != 0 {
		for i := 0; i < g.short_bands; i += 3 {
			for w in 0 ..< 3 do iscf[g.long_bands + i + w] += int(g.subblock_gain[w]) << (3 - shift)
		}
	} else if g.preflag {
		for p, i in PRETAB do iscf[11 + i] += int(p)
	}
	gain := g.global_gain - 210 - (mid_side_stereo(h) ? 2 : 0)
	for i in 0 ..< g.long_bands + g.short_bands {
		scf[i] = f32(math.pow(2, f64(gain - iscf[i] << shift) / 4))
	}
}

@(private)
intensity_stereo :: proc(h: Header) -> bool {
	return h.mode == .Joint_Stereo && h.mode_extension & 1 != 0
}

@(private)
mid_side_stereo :: proc(h: Header) -> bool {
	return h.mode == .Joint_Stereo && h.mode_extension & 2 != 0
}

// ---- Huffman decoding and requantization (2.4.3.4.6-7) -----------------------

// A 32-bit MSB-first window into the main data: peek reads its top bits,
// skip consumes them, refill tops it up to at least 25 bits (zeros past
// the end of the data).
@(private)
Cache :: struct {
	bits: u32,
	sh:   int, // refill point: the window holds 24 - sh valid bits
	next: int, // next byte to load
	data: []u8,
}

@(private)
cache_at :: proc(data: []u8, pos: int) -> Cache {
	c := Cache {
		data = data,
		next = pos / 8,
		sh   = 24,
	}
	refill(&c)
	skip(&c, pos & 7)
	return c
}

@(private)
peek :: #force_inline proc(c: ^Cache, n: int) -> u32 {return c.bits >> uint(32 - n)}

@(private)
skip :: #force_inline proc(c: ^Cache, n: int) {
	c.bits <<= uint(n)
	c.sh += n
}

@(private)
refill :: #force_inline proc(c: ^Cache) {
	for c.sh >= 0 {
		c.bits |= c.next < len(c.data) ? u32(c.data[c.next]) << uint(c.sh) : 0
		c.next += 1
		c.sh -= 8
	}
}

// v with the sign bit at the top of the window applied (and consumed).
@(private)
signed :: #force_inline proc(c: ^Cache, v: f32) -> f32 {
	negative := c.bits >> 31 != 0
	skip(c, 1)
	return negative ? -v : v
}

// Big values (pairs, with escape bits beyond 15), then count1 quadruples
// until the granule's bits end. Each value is requantized as it is decoded:
// sign * |x|^(4/3) * its band's gain. The Huffman tables are minimp3's
// multi-level lookups (see tables.odin).
@(private)
huffman :: proc(dst: []f32, b: ^Bits, g: ^Granule, scf: []f32, limit: int) {
	c := cache_at(b.data, b.pos)
	band, di := 0, 0 // scalefactor band (and gain) and output index
	big := g.big_values
	for region := 0; big > 0 && region < 3; region += 1 {
		table := g.table_select[region]
		codebook := HUFFMAN[HUFFMAN_START[table]:]
		linbits := int(LINBITS[table])
		for bands := int(g.region_count[region]); big > 0 && bands >= 0 && g.sfb[band] != 0; bands -= 1 {
			pairs := int(g.sfb[band]) / 2
			gain := scf[band]
			band += 1
			for _ in 0 ..< min(big, pairs) {
				w := 5
				leaf := int(codebook[peek(&c, w)])
				for leaf < 0 {
					skip(&c, w)
					w = leaf & 7
					leaf = int(codebook[int(peek(&c, w)) - (leaf >> 3)])
				}
				skip(&c, leaf >> 8)
				for _ in 0 ..< 2 {
					x := leaf & 15
					if x == 15 && linbits > 0 {
						x += int(peek(&c, linbits))
						skip(&c, linbits)
						refill(&c)
					}
					dst[di] = x == 0 ? 0 : signed(&c, POW43[x] * gain)
					di += 1
					leaf >>= 4
				}
				refill(&c)
			}
			big -= pairs
		}
	}
	// Count1: four values of magnitude 0 or 1 per codeword. `left` counts
	// the pairs remaining in the current band.
	left := 1 - big
	gain := band > 0 ? scf[band - 1] : 0
	codebook := g.count1_table != 0 ? COUNT1_B[:] : COUNT1_A[:]
	quads: for {
		leaf := int(codebook[peek(&c, 4)])
		if leaf & 8 == 0 do leaf = int(codebook[(leaf >> 3) + int(c.bits << 4 >> uint(32 - (leaf & 3)))])
		skip(&c, leaf & 7)
		if c.next * 8 - 24 + c.sh > limit do break
		for half in 0 ..< 2 {
			left -= 1
			if left == 0 {
				left = int(g.sfb[band]) / 2
				if left == 0 do break quads
				gain = scf[band]
				band += 1
			}
			for k in 0 ..< 2 {
				s := half * 2 + k
				if leaf & (128 >> uint(s)) != 0 do dst[di + s] = signed(&c, gain)
			}
		}
		refill(&c)
		di += 4
	}
	b.pos = limit
}

// ---- Stereo (2.4.3.4.9) -------------------------------------------------------

@(private)
decode_granule :: proc(d: ^Decoder, m: ^Bits, granules: []Granule, h: Header) {
	for ch in 0 ..< len(granules) {
		g := &granules[ch]
		limit := m.pos + g.part23_length
		decode_scalefactors(h, d.ist_pos[ch][:], m, g, d.scf[:], ch)
		huffman(d.spectrum[ch][:], m, g, d.scf[:], limit)
	}
	if len(granules) == 2 {
		if intensity_stereo(h) {
			stereo_intensity(&d.spectrum, d.ist_pos[1][:], granules, h)
		} else if mid_side_stereo(h) {
			mid_side(d.spectrum[0][:], d.spectrum[1][:])
		}
	}
	for ch in 0 ..< len(granules) {
		g := &granules[ch]
		alias_bands := 31
		if g.short_bands != 0 {
			low := mixed_subbands(g, h)
			alias_bands = low - 1
			reorder(d.spectrum[ch][low * 18:], g.sfb[g.long_bands:])
		}
		antialias(d.spectrum[ch][:], alias_bands)
	}
}

// The lowest subbands that a mixed block transforms with the normal long
// window, whatever its block type: 2, or 4 at MPEG-2.5's 8 kHz.
@(private)
mixed_subbands :: proc(g: ^Granule, h: Header) -> int {
	return g.mixed ? (h.rate_index == 2 ? 4 : 2) : 0
}

@(private)
mid_side :: proc(left, right: []f32) #no_bounds_check {
	for i in 0 ..< len(left) {
		a, b := left[i], right[i]
		left[i], right[i] = a + b, a - b
	}
}

// Intensity stereo above the right channel's last nonzero band (per window
// for short blocks); mid/side, where enabled, below it.
@(private)
stereo_intensity :: proc(spectrum: ^[2][576]f32, ist_pos: []u8, granules: []Granule, h: Header) {
	g := &granules[0]
	bands := g.long_bands + g.short_bands
	windows := g.short_bands != 0 ? 3 : 1
	// The highest band with a nonzero right-channel value, per window.
	top := [3]int{-1, -1, -1}
	at := 0
	for i in 0 ..< bands {
		n := int(g.sfb[i])
		for k := 0; k < n; k += 2 {
			if spectrum[1][at + k] != 0 || spectrum[1][at + k + 1] != 0 {top[i % 3] = i; break}
		}
		at += n
	}
	if g.long_bands != 0 do top = max(top[0], top[1], top[2])
	mpeg1 := h.version == .MPEG1
	for i in 0 ..< windows {
		last := bands - windows + i
		prev := last - windows
		ist_pos[last] = top[i] >= prev ? (mpeg1 ? 3 : 0) : ist_pos[prev]
	}
	ms := mid_side_stereo(h)
	shift := uint(granules[1].scalefac_compress & 1)
	at = 0
	for i := 0; g.sfb[i] != 0; i += 1 {
		n := int(g.sfb[i])
		left, right := spectrum[0][at:][:n], spectrum[1][at:][:n]
		position := int(ist_pos[i])
		if i > top[i % 3] && position < (mpeg1 ? 7 : 64) {
			kl, kr: f32
			if mpeg1 {
				kl, kr = INTENSITY_PAN[position][0], INTENSITY_PAN[position][1]
			} else {
				kl, kr = 1, f32(math.pow(2, -f64(((position + 1) >> 1) << shift) / 4))
				if position & 1 != 0 do kl, kr = kr, 1
			}
			// Undo mid/side's 1/sqrt(2), folded into the gains, here.
			s: f32 = ms ? math.SQRT_TWO : 1
			for k in 0 ..< n {
				right[k] = left[k] * kr * s
				left[k] *= kl * s
			}
		} else if ms {
			mid_side(left, right)
		}
		at += n
	}
}

// Short-block values from window-major to frequency-major order: for each
// band, (line, window) interleaved.
@(private)
reorder :: proc(x: []f32, sfb: []u8) {
	scratch: [576]f32
	src, dst := 0, 0
	for i := 0; sfb[i] != 0; i += 3 {
		n := int(sfb[i])
		for k in 0 ..< n {
			scratch[dst], scratch[dst + 1], scratch[dst + 2] = x[src + k], x[src + n + k], x[src + 2 * n + k]
			dst += 3
		}
		src += 3 * n
	}
	copy(x[:dst], scratch[:dst])
}

// Alias reduction butterflies across subband boundaries (2.4.3.4.10).
@(private)
antialias :: proc(x: []f32, bands: int) #no_bounds_check {
	for b in 0 ..< max(bands, 0) {
		base := 18 * b
		for i in 0 ..< 8 {
			u, d := x[base + 18 + i], x[base + 17 - i]
			x[base + 18 + i] = u * ALIAS_CS[i] - d * ALIAS_CA[i]
			x[base + 17 - i] = u * ALIAS_CA[i] + d * ALIAS_CS[i]
		}
	}
}

// ---- Hybrid filterbank (2.4.3.4.10.2) ----------------------------------------

// IMDCT and windowing of each subband, overlap-add with the previous
// granule and frequency inversion, written time-major: slots[t*32 + sb].
// Each transform accumulates whole rows of its cosine table, so the inner
// loops run over contiguous outputs.
@(private)
hybrid_synthesis :: proc(x, overlap, slots: []f32, g: ^Granule, h: Header) #no_bounds_check {
	low := mixed_subbands(g, h)
	for sb in 0 ..< 32 {
		in_ := x[sb * 18:][:18]
		saved := overlap[sb * 18:][:18]
		out: [36]f32
		block := sb < low ? 0 : int(g.block_type)
		if block == 2 {
			// Three 12-point IMDCTs, windowed, at 6, 12 and 18.
			for w in 0 ..< 3 {
				acc: [12]f32
				for m in 0 ..< 6 {
					v := in_[w + 3 * m]
					if v != 0 do for p in 0 ..< 12 do acc[p] += v * IMDCT12[m][p]
				}
				for p in 0 ..< 12 do out[6 * w + p + 6] += acc[p] * WINDOWS[2][p]
			}
		} else {
			for m in 0 ..< 18 {
				v := in_[m]
				if v != 0 do for p in 0 ..< 36 do out[p] += v * IMDCT36[m][p]
			}
			for p in 0 ..< 36 do out[p] *= WINDOWS[block][p]
		}
		// Odd subbands of odd time samples are inverted.
		sign: f32 = sb & 1 == 1 ? -1 : 1
		for t in 0 ..< 18 {
			v := out[t] + saved[t]
			slots[t * 32 + sb] = t & 1 == 1 ? v * sign : v
			saved[t] = out[t + 18]
		}
	}
}

// ---- Polyphase synthesis (2.4.3.2.2 and annex A.3) ---------------------------

// 18 time slots of 32 subband samples per channel to 576 PCM samples.
// Matrixing adds one 64-wide row per subband (SYNTH_ROWS[k] scaled by
// sample k) and windowing one 32-wide row per tap, so both loops run over
// contiguous outputs.
@(private)
synthesize :: proc(d: ^Decoder, channels: int, left, right: []f32) #no_bounds_check {
	outputs := [2][]f32{left, right}
	for t in 0 ..< 18 {
		d.synth_at = (d.synth_at - 64) & 1023
		at := d.synth_at
		for ch in 0 ..< channels {
			s := d.slots[ch][t * 32:][:32]
			v := d.synth[ch][:]
			row: [64]f32
			for k in 0 ..< 32 {
				if s[k] != 0 do for i in 0 ..< 64 do row[i] += s[k] * SYNTH_ROWS[k][i]
			}
			copy(v[at:][:64], row[:])
			copy(v[at + 1024:][:64], row[:])
			out: [32]f32
			for i in 0 ..< 8 {
				a, b := v[at + i * 128:][:32], v[at + i * 128 + 96:][:32]
				wa, wb := SYNTH_WINDOW[i * 64:][:32], SYNTH_WINDOW[i * 64 + 32:][:32]
				for j in 0 ..< 32 {
					out[j] += a[j] * wa[j]
					out[j] += b[j] * wb[j]
				}
			}
			copy(outputs[ch][t * 32:][:32], out[:])
		}
	}
}

// ---- Computed tables ------------------------------------------------------------

@(private)
POW43: [8207]f32 // x^(4/3) for every magnitude a big value can carry
@(private)
IMDCT36: [18][36]f32
@(private)
IMDCT12: [6][12]f32
@(private)
WINDOWS: [4][36]f32 // normal, start, short (12 values), stop
@(private)
SYNTH_ROWS: [32][64]f32 // cos((16 + i)(2k + 1) pi / 64), one row per subband k
@(private)
ALIAS_CS, ALIAS_CA: [8]f32
@(private)
INTENSITY_PAN: [7][2]f32 // MPEG-1: (left, right) factors per position

@(private, init)
init_tables :: proc "contextless" () {
	context = runtime.default_context()
	for x in 0 ..< len(POW43) do POW43[x] = f32(math.pow(f64(x), 4.0 / 3))
	for m in 0 ..< 18 do for p in 0 ..< 36 {
		IMDCT36[m][p] = f32(math.cos(math.PI / 72 * f64(2 * p + 1 + 18) * f64(2 * m + 1)))
	}
	for m in 0 ..< 6 do for p in 0 ..< 12 {
		IMDCT12[m][p] = f32(math.cos(math.PI / 24 * f64(2 * p + 1 + 6) * f64(2 * m + 1)))
	}
	sin36 :: proc(i: int) -> f32 {return f32(math.sin(math.PI / 36 * (f64(i) + 0.5)))}
	sin12 :: proc(i: int) -> f32 {return f32(math.sin(math.PI / 12 * (f64(i) + 0.5)))}
	for i in 0 ..< 36 do WINDOWS[0][i] = sin36(i)
	for i in 0 ..< 18 do WINDOWS[1][i] = sin36(i)
	for i in 18 ..< 24 do WINDOWS[1][i] = 1
	for i in 24 ..< 30 do WINDOWS[1][i] = sin12(i - 18)
	for i in 0 ..< 12 do WINDOWS[2][i] = sin12(i)
	for i in 6 ..< 12 do WINDOWS[3][i] = sin12(i - 6)
	for i in 12 ..< 18 do WINDOWS[3][i] = 1
	for i in 18 ..< 36 do WINDOWS[3][i] = sin36(i)
	for k in 0 ..< 32 do for i in 0 ..< 64 {
		SYNTH_ROWS[k][i] = f32(math.cos(f64((16 + i) * (2 * k + 1)) * math.PI / 64))
	}
	ci := [8]f64{-0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037}
	for c, i in ci {
		n := math.sqrt(1 + c * c)
		ALIAS_CS[i], ALIAS_CA[i] = f32(1 / n), f32(-c / n)
	}
	for p in 0 ..< 7 {
		angle := f64(p) * math.PI / 12
		s, c := math.sin(angle), math.cos(angle)
		INTENSITY_PAN[p] = {f32(s / (s + c)), f32(c / (s + c))}
	}
}

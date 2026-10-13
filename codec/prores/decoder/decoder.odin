// Apple ProRes decoding (SMPTE RDD 36): 4:2:2 Proxy/LT/Standard/HQ and 4:4:4
// 4444/4444 XQ with 8- or 16-bit alpha, progressive or interlaced. Slices are
// independent, so a caller's Work_Pool decodes them in parallel; each slice
// keeps its coefficients on its own stack and writes only its own samples.
package prores_decoder

import prores ".."
import common "../../common"
import "base:intrinsics"
import "core:simd"

// A decoded frame, valid until the next decode call on the same decoder.
// Samples are u16 at bit_depth: 10 for 4:2:2 and 12 for 4:4:4, the depths
// the format's 4:2:2 and 4:4:4 profiles are specified for. Alpha has the same
// depth as luma.
Frame :: struct {
	width, height: int,
	bit_depth:     int,
	chroma:        prores.Chroma,
	planes:        [3][]u16, // Y, Cb, Cr
	strides:       [3]int, // in samples
	alpha:         []u16, // nil without alpha
	alpha_stride:  int,
	header:        prores.Frame_Header, // colour, interlacing, encoder
}

// One decoder per stream. Planes and slice records persist across frames and
// grow only when a larger frame arrives.
Decoder :: struct {
	pool:    ^common.Work_Pool, // optional: slices run on the caller's pool
	samples: [dynamic]u16, // Y, Cb, Cr and alpha planes, macroblock aligned
	slices:  [dynamic]Slice,
}

@(private)
Slice :: struct {
	data:     []u8,
	mb_x:     i32,
	mb_y:     i32,
	mb_count: i32,
	err:      prores.Error,
}

// Everything a slice needs from its picture: one field of an interlaced
// frame addresses every other row through doubled strides.
@(private)
Picture :: struct {
	slices:     []Slice,
	planes:     [4][^]u16,
	strides:    [4]int,
	scan:       ^[64]u8,
	luma_qmat:  ^[64]u8,
	chroma_qmat: ^[64]u8,
	chroma444:  bool,
	alpha_bits: int,
	rows:       int, // lines of this picture inside the frame
	output:     Output,
}

// Sample reconstruction: round(idct * scale) + bias, clipped to [min, max].
@(private)
Output :: struct {
	scale:    f32,
	bias:     f32,
	min, max: f32,
	depth:    uint,
}

init_decoder :: proc(d: ^Decoder, pool: ^common.Work_Pool = nil) {
	d^ = {
		pool = pool,
	}
}

destroy_decoder :: proc(d: ^Decoder) {
	delete(d.samples)
	delete(d.slices)
	d^ = {}
}

decode_frame :: proc(d: ^Decoder, data: []u8) -> (f: Frame, err: prores.Error) {
	h := prores.parse_frame_header(data) or_return
	mb_width, mb_height := prores.picture_mbs(h)
	fields := h.interlace == .Progressive ? 1 : 2
	luma_w, coded_rows := mb_width * 16, mb_height * 16 * fields
	chroma_w := h.chroma == .YUV444 ? luma_w : luma_w / 2
	plane_sizes := [4]int{luma_w * coded_rows, chroma_w * coded_rows, chroma_w * coded_rows, h.alpha_bits != 0 ? luma_w * coded_rows : 0}
	total := plane_sizes[0] + plane_sizes[1] + plane_sizes[2] + plane_sizes[3]
	if len(d.samples) < total {
		if resize(&d.samples, total) != nil do return f, .Out_Of_Memory
	}
	planes: [4][^]u16
	offset := 0
	for size, i in plane_sizes {
		planes[i] = raw_data(d.samples[offset:])
		offset += size
	}
	depth: uint = h.chroma == .YUV444 ? 12 : 10
	// Coefficients are in 12-bit sample units around mid-grey. Samples keep
	// clear of the four codes at each end, which SDI reserves.
	output := Output {
		scale = 1.0 / f32(u32(1) << (12 - depth)),
		bias  = f32(u32(1) << (depth - 1)),
		min   = 4,
		max   = f32(u32(1) << depth - 5),
		depth = depth,
	}
	per_row := prores.slices_per_row(mb_width, 0)
	pictures := h.pictures
	for field in 0 ..< fields {
		// Slice layout depends on the picture header's slice width, so parse
		// the header with a provisional count, then the actual table.
		if len(pictures) < 8 do return f, .Invalid_Data
		log2_width := uint(pictures[7] >> 4)
		if log2_width > 3 do return f, .Unsupported
		per_row = prores.slices_per_row(mb_width, log2_width)
		count := per_row * mb_height
		p, rest := prores.parse_picture_header(pictures, count) or_return
		pictures = rest
		clear(&d.slices)
		if reserve(&d.slices, count) != nil do return f, .Out_Of_Memory
		at := 0
		for mb_y in 0 ..< mb_height {
			mb_x := 0
			for mb_x < mb_width {
				n := prores.slice_mb_count(mb_width, mb_x, log2_width)
				size := int(prores.be16(p.slice_sizes[len(d.slices) * 2:]))
				if size > len(p.slices) - at do return f, .Invalid_Data
				append(&d.slices, Slice{data = p.slices[at:][:size], mb_x = i32(mb_x), mb_y = i32(mb_y), mb_count = i32(n)})
				at += size
				mb_x += n
			}
		}
		// A field starts on its parity row and steps over the other field.
		parity := fields == 1 ? 0 : field ~ (h.interlace == .Bottom_First ? 1 : 0)
		rows := fields == 1 ? h.height : (h.height + 1 - parity) / 2
		picture := Picture {
			slices      = d.slices[:],
			scan        = fields == 1 ? &prores.PROGRESSIVE_SCAN : &prores.INTERLACED_SCAN,
			luma_qmat   = &h.luma_qmat,
			chroma_qmat = &h.chroma_qmat,
			chroma444   = h.chroma == .YUV444,
			alpha_bits  = h.alpha_bits,
			rows        = rows,
			output      = output,
		}
		widths := [4]int{luma_w, chroma_w, chroma_w, luma_w}
		for i in 0 ..< 4 {
			picture.strides[i] = widths[i] * fields
			picture.planes[i] = planes[i][parity * widths[i]:]
		}
		if d.pool != nil {
			d.pool.run(d.pool, len(picture.slices), decode_slices, &picture)
		} else {
			decode_slices(&picture, 0, len(picture.slices))
		}
		for s in picture.slices do if s.err != .None do return f, s.err
	}
	f = {
		width        = h.width,
		height       = h.height,
		bit_depth    = int(depth),
		chroma       = h.chroma,
		header       = h,
		strides      = {luma_w, chroma_w, chroma_w},
		alpha_stride = luma_w,
	}
	for i in 0 ..< 3 do f.planes[i] = planes[i][:plane_sizes[i]]
	if h.alpha_bits != 0 do f.alpha = planes[3][:plane_sizes[3]]
	return f, .None
}

@(private)
decode_slices :: proc(data: rawptr, first, end: int) {
	p := (^Picture)(data)
	for &s in p.slices[first:end] do s.err = decode_slice(p, &s)
}

@(private)
decode_slice :: proc(p: ^Picture, s: ^Slice) -> prores.Error {
	d := s.data
	if len(d) < 6 do return .Invalid_Data
	header := int(d[0] >> 3)
	if header < 6 || header > len(d) || d[1] == 0 || d[1] > 224 do return .Invalid_Data
	scale := f32(prores.qscale(d[1]))
	sizes: [4]int
	sizes[0], sizes[1] = int(prores.be16(d[2:])), int(prores.be16(d[4:]))
	rest := len(d) - header - sizes[0] - sizes[1]
	if rest < 0 do return .Invalid_Data
	sizes[2] = header > 7 ? int(prores.be16(d[6:])) : rest
	sizes[3] = rest - sizes[2]
	if sizes[3] < 0 do return .Invalid_Data
	data := d[header:]

	// Up to 8 macroblocks of 4 blocks per component; one component at a time.
	coefficients: [prores.MAX_SLICE_MBS * 4 * 64]i32 = ---
	mbs := int(s.mb_count)
	x, y := int(s.mb_x) * 16, int(s.mb_y) * 16
	chroma_blocks := p.chroma444 ? 4 : 2
	for component in 0 ..< 3 {
		blocks := mbs * (component == 0 ? 4 : chroma_blocks)
		coeffs := coefficients[:blocks * 64]
		intrinsics.mem_zero(raw_data(coeffs), len(coeffs) * size_of(i32))
		r := init_reader(data[:sizes[component]])
		data = data[sizes[component]:]
		decode_coefficients(&r, coeffs, uint(intrinsics.count_trailing_zeros(blocks)), p.scan) or_return
		qmat := component == 0 ? p.luma_qmat : p.chroma_qmat
		weights: [64]f32 = ---
		for q, i in qmat do weights[i] = f32(q) * scale
		stride := p.strides[component]
		if component == 0 {
			// Luma blocks: top-left, top-right, bottom-left, bottom-right.
			for mb in 0 ..< mbs {
				dst := p.planes[0][y * stride + x + mb * 16:]
				for b in 0 ..< 4 {
					idct_put(coeffs[(mb * 4 + b) * 64:][:64], &weights, dst[(b >> 1) * 8 * stride + (b & 1) * 8:], stride, p.output)
				}
			}
		} else {
			// Chroma blocks run down each 8-sample column of the macroblock.
			cx := p.chroma444 ? x : x / 2
			for column in 0 ..< blocks / 2 {
				dst := p.planes[component][y * stride + cx + column * 8:]
				idct_put(coeffs[column * 128:][:64], &weights, dst, stride, p.output)
				idct_put(coeffs[column * 128 + 64:][:64], &weights, dst[8 * stride:], stride, p.output)
			}
		}
	}
	if p.alpha_bits != 0 {
		stride := p.strides[3]
		r := init_reader(data[:sizes[3]])
		visible := min(16, p.rows - y)
		decode_alpha(&r, p.planes[3][y * stride + x:], stride, mbs * 16, visible, p.alpha_bits, p.output.depth) or_return
	}
	return .None
}

// Big-endian bit cache: `cache` holds `count` unread bits MSB-first. Bytes
// past the end read as zero; `left` going negative marks an overrun.
@(private)
Bit_Reader :: struct {
	cache: u64,
	count: int,
	left:  int,
	next:  int,
	data:  []u8,
}

@(private)
init_reader :: proc(data: []u8) -> Bit_Reader {
	return {data = data, left = len(data) * 8}
}

@(private)
refill :: #force_inline proc(r: ^Bit_Reader) {
	if r.count > 56 do return
	if r.next + 8 <= len(r.data) {
		// Bits already cached past `count` are these same bits again.
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

@(private)
skip :: #force_inline proc(r: ^Bit_Reader, n: uint) {
	r.cache <<= n
	r.count -= int(n)
	r.left -= int(n)
}

@(private)
read :: #force_inline proc(r: ^Bit_Reader, n: uint) -> u32 {
	refill(r)
	v := u32(r.cache >> (64 - n)) if n > 0 else 0
	skip(r, n)
	return v
}

// One adaptive codeword: a Rice code with a short unary prefix, switching
// to exp-Golomb for longer prefixes (codebook layout in prores.odin).
@(private)
read_codeword :: #force_inline proc(r: ^Bit_Reader, codebook: u8) -> u32 {
	refill(r)
	switch_bits := u32(codebook & 3)
	rice := uint(codebook >> 5)
	exp_order := u32(codebook >> 2) & 7
	q := u32(intrinsics.count_leading_zeros(r.cache))
	if q > switch_bits {
		n := exp_order - switch_bits + q << 1
		if n > 32 {
			r.left = -1 // longer than any valid code: corrupt data
			return 0
		}
		v := u32(r.cache >> (64 - n)) - 1 << exp_order + (switch_bits + 1) << rice
		skip(r, uint(n))
		return v
	}
	skip(r, uint(q) + 1)
	if rice == 0 do return q
	v := q << rice + u32(r.cache >> (64 - rice))
	skip(r, rice)
	return v
}

// Coefficients of one component of a slice, interleaved across its blocks:
// every block's DC, then each scan position for every block in turn.
@(private)
decode_coefficients :: proc(r: ^Bit_Reader, out: []i32, log2_blocks: uint, scan: ^[64]u8) -> prores.Error {
	blocks := 1 << log2_blocks
	// DC: the first absolutely, the rest as differences whose sign persists
	// until a zero difference.
	code := read_codeword(r, prores.FIRST_DC_CODEBOOK)
	dc := i32(code >> 1) ~ -i32(code & 1)
	out[0] = dc
	code = 5
	sign: i32
	for b in 1 ..< blocks {
		code = read_codeword(r, prores.DC_CODEBOOKS[min(code, 6)])
		sign = code == 0 ? 0 : sign ~ -i32(code & 1)
		dc += (i32((code + 1) >> 1) ~ sign) - sign
		out[b * 64] = dc
	}
	// AC: (run, level, sign) triples with codebooks adapted to the previous
	// run and level; trailing zero padding ends the component.
	mask := blocks - 1
	limit := 64 << log2_blocks
	pos := mask
	run, level: u32 = 4, 2
	for {
		if r.left <= 0 do break
		refill(r)
		if r.left < 32 && r.cache >> uint(64 - r.left) == 0 do break
		run = read_codeword(r, prores.RUN_CODEBOOKS[min(run, 15)])
		pos += int(run) + 1
		if pos >= limit do return .Invalid_Data
		level = read_codeword(r, prores.LEVEL_CODEBOOKS[min(level, 9)]) + 1
		negative := -i32(read(r, 1))
		out[(pos & mask) << 6 + int(scan[pos >> log2_blocks])] = (i32(level) ~ negative) - negative
	}
	return r.left < 0 ? .Invalid_Data : .None
}

// Alpha: raster order over the slice's 16 rows, each value a difference
// (modulo 2^bits) from the previous one, either full width or a short signed
// step, with runs of repeated values. Encoders may stop after the last row
// inside the picture (then only zero padding follows); the uncoded rows
// below it repeat the last value.
@(private)
decode_alpha :: proc(r: ^Bit_Reader, dst: [^]u16, stride, width, visible_rows, bits: int, depth: uint) -> prores.Error {
	mask := u32(1) << uint(bits) - 1
	short := uint(bits == 16 ? 7 : 4)
	total, visible := width * 16, width * visible_rows
	value := mask
	at := 0
	put :: #force_inline proc(dst: [^]u16, stride, width, at: int, v: u16) {
		dst[at / width * stride + at % width] = v
	}
	// Scale to the output depth by replicating the top bits.
	scaled :: #force_inline proc(v: u32, bits: int, depth: uint) -> u16 {
		return bits == 16 ? u16(v >> (16 - depth)) : u16(v << (depth - 8) | v >> (16 - depth))
	}
	ended :: #force_inline proc(r: ^Bit_Reader, at, total, visible: int) -> bool {
		if at >= total do return true
		if at < visible do return false
		refill(r)
		return r.left <= 0 || r.left < 32 && r.cache >> uint(64 - r.left) == 0
	}
	outer: for !ended(r, at, total, visible) {
		for {
			step: u32
			if read(r, 1) == 1 {
				step = read(r, uint(bits))
			} else {
				v := read(r, short)
				step = (v + 2) >> 1
				if v & 1 != 0 do step = -step
			}
			value = (value + step) & mask
			put(dst, stride, width, at, scaled(value, bits, depth))
			at += 1
			if ended(r, at, total, visible) do break outer
			if read(r, 1) == 0 do break
		}
		run := int(read(r, 4))
		if run == 0 do run = int(read(r, 11))
		v := scaled(value, bits, depth)
		end := min(at + run, total)
		for ; at < end; at += 1 do put(dst, stride, width, at, v)
		if r.left < 0 do break
	}
	if r.left < 0 || at < visible do return .Invalid_Data
	v := scaled(value, bits, depth)
	for ; at < total; at += 1 do put(dst, stride, width, at, v)
	return .None
}

@(private)
F8 :: #simd[8]f32

// Orthonormal 8-point DCT basis: BASIS[u][x] = c(u)/2 * cos((2x+1)u*pi/16).
@(private, rodata)
BASIS := [8][8]f32 {
	{0.35355339, 0.35355339, 0.35355339, 0.35355339, 0.35355339, 0.35355339, 0.35355339, 0.35355339},
	{0.49039264, 0.41573481, 0.27778512, 0.09754516, -0.09754516, -0.27778512, -0.41573481, -0.49039264},
	{0.46193977, 0.19134172, -0.19134172, -0.46193977, -0.46193977, -0.19134172, 0.19134172, 0.46193977},
	{0.41573481, -0.09754516, -0.49039264, -0.27778512, 0.27778512, 0.49039264, 0.09754516, -0.41573481},
	{0.35355339, -0.35355339, -0.35355339, 0.35355339, 0.35355339, -0.35355339, -0.35355339, 0.35355339},
	{0.27778512, -0.49039264, 0.09754516, 0.41573481, -0.41573481, -0.09754516, 0.49039264, -0.27778512},
	{0.19134172, -0.46193977, 0.46193977, -0.19134172, -0.19134172, 0.46193977, -0.46193977, 0.19134172},
	{0.09754516, -0.27778512, 0.41573481, -0.49039264, 0.49039264, -0.41573481, 0.27778512, -0.09754516},
}

// Dequantizes one block (coefficients in raster order) and writes its 8x8
// inverse transform. Vectors hold the eight x positions of a row: the row
// pass weights the basis rows by each coded row's coefficients, the column
// pass combines rows up to the last nonzero one (often only the DC row).
@(private)
idct_put :: proc(block: []i32, weights: ^[64]f32, dst: [^]u16, stride: int, o: Output) {
	basis := transmute([8]F8)BASIS
	rows: [8]F8
	last := -1
	for v in 0 ..< 8 {
		coded := intrinsics.unaligned_load((^#simd[8]i32)(raw_data(block[v * 8:])))
		if simd.reduce_or(coded) == 0 do continue
		f := simd.to_array(cast(F8)coded * intrinsics.unaligned_load((^F8)(&weights[v * 8])))
		rows[v] = F8(f[0]) * basis[0] + F8(f[1]) * basis[1] + F8(f[2]) * basis[2] + F8(f[3]) * basis[3] + F8(f[4]) * basis[4] + F8(f[5]) * basis[5] + F8(f[6]) * basis[6] + F8(f[7]) * basis[7]
		last = v
	}
	for y in 0 ..< 8 {
		acc: F8
		for v in 0 ..= last do acc += F8(BASIS[v][y]) * rows[v]
		s := simd.clamp(simd.nearest(acc * F8(o.scale)) + F8(o.bias), F8(o.min), F8(o.max))
		out := simd.to_array(cast(#simd[8]u16)s)
		copy(dst[y * stride:][:8], out[:])
	}
}

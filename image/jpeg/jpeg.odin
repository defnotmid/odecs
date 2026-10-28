// JPEG (baseline and progressive, 8-bit, 1, 3 or 4 components) to RGBA8,
// exactly as libjpeg-turbo decodes it with its defaults: its integer IDCT,
// "fancy" (triangle) upsampling with its rounding, its YCbCr constants, and
// its reading of JFIF, Adobe and component IDs for the colour space. CMYK
// (and YCCK, through CMYK) becomes RGB as Adobe files store it, inverted:
// R = C * K / 255.
//
// The data: the markers are read once into a Decoder (quantisation and
// Huffman tables, the components). Samples live only as long as their rows
// are needed: each component keeps a ring of three bands of one MCU row's
// height (the band being output and its neighbours above and below, which
// fancy upsampling reads). An image in one scan streams: a band is decoded
// (entropy decoding, then each block's IDCT into the ring) and the band
// before it is converted to RGBA. An image in several scans (progressive, or
// one component per scan) keeps every block's coefficients until the last
// scan, then makes its bands by IDCT into the same ring.
package jpeg

import "core:mem"
import "core:slice"

Error :: enum {
	None,
	Unsupported, // not a JPEG, or a kind odecs does not decode (lossless, 12-bit, arithmetic)
	Invalid,     // malformed or truncated, or `pixels` too small for decode_into
	Out_Of_Memory,
}

Features :: struct {
	width, height: int,
	components:    int, // 1 gray, 3 YCbCr or RGB, 4 CMYK or YCCK
	progressive:   bool,
}

// A decoded picture: width * height RGBA8 pixels, alpha 255, rows top-down.
Image :: struct {
	width, height: int,
	pixels:        []u8,
}

@(private)
MAX_SIDE :: 1 << 24

@(private)
Component :: struct {
	id:                 u8,
	h, v:               int, // sampling factors
	tq:                 int, // quantisation table
	dc, ac:             int, // Huffman tables, set by each scan
	width, height:      int, // samples covering the image: ceil(image * h / h_max)
	blocks_x, blocks_y: int, // blocks covering those samples (a lone component's scan)
	stride:             int, // samples in a band row: whole MCUs
	band:               int, // rows in a band: one MCU row, v * 8
	plane:              int, // where its ring of three bands starts in Decoder.planes
	coeffs:             int, // where its blocks start in Decoder.coeffs (several scans)
	dc_pred:            int,
}

@(private)
Decoder :: struct {
	data:         []u8,
	at:           int, // the marker parser's position
	features:     Features,
	quant:        [4][8]#simd[8]u16, // natural order
	dc_tables:    [4]Huffman,
	ac_tables:    [4]Huffman,
	comps:        [4]Component,
	h_max, v_max: int,
	mcu_x, mcu_y: int, // MCUs across and down
	restart:      int, // MCUs between restart markers, 0: none
	jfif:         bool,
	transform:    int, // the Adobe marker's colour transform, -1: none
	// The current scan.
	order:        [4]int,
	scan_n:       int,
	spec_start:   int,
	spec_end:     int,
	succ_high:    int,
	succ_low:     int,
	eob_run:      int,
	bits:         Bits,
	todo:         int, // MCUs left in the restart interval
	stopped:      bool, // the scan's data ended early: its remaining blocks stay as they are
	// Storage and the output's choices.
	planes:       []u8,
	coeffs:       [][8]#simd[8]i16,
	lines:        []u8, // a row buffer per component for upsampling
	colour:       Colour,
	resample:     [4]Resample,
	allocator:    mem.Allocator,
}

get_features :: proc(data: []u8) -> (ft: Features, err: Error) {
	d := Decoder{data = data}
	read_header(&d) or_return
	return d.features, .None
}

decode :: proc(data: []u8, allocator := context.allocator) -> (img: Image, err: Error) {
	ft := get_features(data) or_return
	pixels, aerr := make([]u8, ft.width * ft.height * 4, allocator)
	if aerr != nil do return img, .Out_Of_Memory
	if err = decode_into(data, pixels, allocator); err != .None {
		delete(pixels, allocator)
		return img, err
	}
	return {ft.width, ft.height, pixels}, .None
}

// Decodes into `pixels`, width * height * 4 bytes (from get_features).
// Scratch (the decoder with its tables, the bands, a multi-scan image's
// coefficients) comes from `allocator` and is freed before returning.
decode_into :: proc(data: []u8, pixels: []u8, allocator := context.allocator) -> Error {
	d := new(Decoder, allocator)
	if d == nil do return .Out_Of_Memory
	d^ = {data = data, allocator = allocator}
	defer {
		delete(d.planes, allocator)
		delete(d.coeffs, allocator)
		delete(d.lines, allocator)
		free(d, allocator)
	}
	read_header(d) or_return
	if len(pixels) < d.features.width * d.features.height * 4 do return .Invalid
	prepare(d) or_return
	// The segments up to the first scan.
	m := next_marker(d)
	for m != 0xDA {
		if m == 0xD9 do return .Invalid
		read_segment(d, m) or_return
		m = next_marker(d)
	}
	read_scan_header(d) or_return
	if !d.features.progressive && d.scan_n == d.features.components {
		// One scan holds every component: band m is decoded, then band m - 1
		// output, while its rows are still in cache.
		begin_scan(d)
		for band in 0 ..= d.mcu_y {
			if band < d.mcu_y do decode_band(d, band) or_return
			if band > 0 do output_band(d, band - 1, pixels)
		}
		return .None
	}
	blocks := 0
	for &c in d.comps[:d.features.components] {
		c.coeffs = blocks
		blocks += c.stride / 8 * d.mcu_y * c.v
	}
	if blocks > 4 * MAX_SIDE do return .Invalid
	err: mem.Allocator_Error
	d.coeffs, err = make([][8]#simd[8]i16, blocks, allocator)
	if err != nil do return .Out_Of_Memory
	read_scans(d) or_return
	for band in 0 ..= d.mcu_y {
		if band < d.mcu_y do transform_band(d, band)
		if band > 0 do output_band(d, band - 1, pixels)
	}
	return .None
}

destroy_image :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.pixels, allocator)
	img^ = {}
}

@(private)
MARKER_NONE :: 0xFF

@(private)
byte_at :: #force_inline proc(d: ^Decoder) -> int {
	if d.at >= len(d.data) {
		d.at += 1
		return 0 // past the end reads as zeros
	}
	d.at += 1
	return int(d.data[d.at - 1])
}

@(private)
u16_at :: #force_inline proc(d: ^Decoder) -> int {
	hi := byte_at(d)
	return hi << 8 | byte_at(d)
}

// The next marker: 0xFF, any fill bytes, the code. MARKER_NONE where
// something else stands.
@(private)
next_marker :: proc(d: ^Decoder) -> int {
	if byte_at(d) != 0xFF do return MARKER_NONE
	m := 0xFF
	for m == 0xFF {
		if d.at >= len(d.data) do return MARKER_NONE
		m = byte_at(d)
	}
	return m
}

// SOI, then the tables and segments up to and including the frame header.
@(private)
read_header :: proc(d: ^Decoder) -> Error {
	d.transform = -1
	if len(d.data) < 3 || d.data[0] != 0xFF || d.data[1] != 0xD8 do return .Unsupported
	d.at = 2
	m := next_marker(d)
	for m != 0xC0 && m != 0xC1 && m != 0xC2 {
		switch m {
		case 0xC3, 0xC5 ..= 0xC7, 0xC9 ..= 0xCB, 0xCD ..= 0xCF:
			return .Unsupported // lossless, hierarchical, arithmetic
		}
		read_segment(d, m) or_return
		m = next_marker(d)
		// Some files pad between segments.
		for m == MARKER_NONE {
			if d.at >= len(d.data) do return .Invalid
			m = next_marker(d)
		}
	}
	d.features.progressive = m == 0xC2
	return read_frame_header(d)
}

// DQT, DHT, DRI, APPn and COM; anything else is an error.
@(private)
read_segment :: proc(d: ^Decoder, m: int) -> Error {
	switch m {
	case MARKER_NONE:
		return .Invalid
	case 0xDD: // restart interval
		if u16_at(d) != 4 do return .Invalid
		d.restart = u16_at(d)
		return .None
	case 0xDB: // quantisation tables
		left := u16_at(d) - 2
		for left > 0 {
			q := byte_at(d)
			precision, t := q >> 4, q & 15
			if precision > 1 || t > 3 do return .Invalid
			qtable := slice.reinterpret([]u16, d.quant[t][:])
			for i in 0 ..< 64 do qtable[DEZIGZAG[i]] = u16(precision == 1 ? u16_at(d) : byte_at(d))
			left -= precision == 1 ? 129 : 65
		}
		return left == 0 ? .None : .Invalid
	case 0xC4: // Huffman tables
		left := u16_at(d) - 2
		for left > 0 {
			q := byte_at(d)
			class, t := q >> 4, q & 15
			if class > 1 || t > 3 do return .Invalid
			counts: [16]int
			n := 0
			for &c in counts {
				c = byte_at(d)
				n += c
			}
			if n > 256 do return .Invalid
			left -= 17
			h := class == 0 ? &d.dc_tables[t] : &d.ac_tables[t]
			build_huffman(h, counts) or_return
			for i in 0 ..< n do h.values[i] = u8(byte_at(d))
			if class == 1 do build_fast_ac(h)
			left -= n
		}
		return left == 0 ? .None : .Invalid
	}
	if m >= 0xE0 && m <= 0xEF || m == 0xFE {
		length := u16_at(d)
		if length < 2 do return .Invalid
		start := d.at
		left := length - 2
		tag :: proc(d: ^Decoder, at, left: int, s: string) -> bool {
			return left >= len(s) && at + len(s) <= len(d.data) && string(d.data[at:][:len(s)]) == s
		}
		// As libjpeg recognises them: JFIF with its 14 bytes, Adobe with 12.
		if m == 0xE0 && left >= 14 && tag(d, start, left, "JFIF\x00") {
			d.jfif = true
		} else if m == 0xEE && left >= 12 && tag(d, start, left, "Adobe") {
			d.at = start + 11
			d.transform = byte_at(d)
		}
		d.at = start + left
		return .None
	}
	return .Invalid
}

@(private)
read_frame_header :: proc(d: ^Decoder) -> Error {
	length := u16_at(d)
	if length < 11 do return .Invalid
	if byte_at(d) != 8 do return .Unsupported // 12-bit
	ft := &d.features
	ft.height = u16_at(d)
	ft.width = u16_at(d)
	if ft.height == 0 do return .Unsupported // the height from a DNL marker
	if ft.width == 0 do return .Invalid
	n := byte_at(d)
	if n != 1 && n != 3 && n != 4 do return .Invalid
	ft.components = n
	if length != 8 + 3 * n do return .Invalid
	d.h_max, d.v_max = 1, 1
	for &c in d.comps[:n] {
		c.id = u8(byte_at(d))
		q := byte_at(d)
		c.h, c.v = q >> 4, q & 15
		c.tq = byte_at(d)
		if c.h == 0 || c.h > 4 || c.v == 0 || c.v > 4 || c.tq > 3 do return .Invalid
		d.h_max, d.v_max = max(d.h_max, c.h), max(d.v_max, c.v)
	}
	// Whole ratios only, as libjpeg requires.
	for c in d.comps[:n] do if d.h_max % c.h != 0 || d.v_max % c.v != 0 do return .Invalid
	d.mcu_x = (ft.width + d.h_max * 8 - 1) / (d.h_max * 8)
	d.mcu_y = (ft.height + d.v_max * 8 - 1) / (d.v_max * 8)
	for &c in d.comps[:n] {
		c.width = (ft.width * c.h + d.h_max - 1) / d.h_max
		c.height = (ft.height * c.v + d.v_max - 1) / d.v_max
		c.blocks_x, c.blocks_y = (c.width + 7) / 8, (c.height + 7) / 8
		c.stride = d.mcu_x * c.h * 8
		c.band = c.v * 8
	}
	return .None
}

// The rings of bands, the row buffers, and the output's choices.
@(private)
prepare :: proc(d: ^Decoder) -> Error {
	n := d.features.components
	samples := 0
	for &c in d.comps[:n] {
		c.plane = samples
		samples += 3 * c.band * c.stride
	}
	// Room for a 4x ratio's overshoot in each row buffer.
	line := d.features.width + 3
	err: mem.Allocator_Error
	d.planes, err = make([]u8, samples, d.allocator)
	if err != nil do return .Out_Of_Memory
	d.lines, err = make([]u8, n * line, d.allocator)
	if err != nil do return .Out_Of_Memory
	d.colour = colour_of(d)
	for c, k in d.comps[:n] do d.resample[k] = resample_of(d, c)
	return .None
}

// Where row r of a component's samples lies in its ring of bands.
@(private)
plane_row :: #force_inline proc "contextless" (c: ^Component, r: int) -> int {
	return c.plane + ((r / c.band) % 3 * c.band + r % c.band) * c.stride
}

// The scans after the first, to the end of the image, with the tables and
// restart intervals between them; every scan's coefficients are kept.
@(private)
read_scans :: proc(d: ^Decoder) -> Error {
	for {
		begin_scan(d)
		decode_rows(d, 0, scan_rows(d)) or_return
		d.at = d.bits.at
		m := d.bits.marker
		if m == MARKER_NONE {
			// The scan stopped short of a marker (trailing zeros, as some
			// cameras write): the next 0xFF starts one.
			for d.at < len(d.data) {
				if byte_at(d) == 0xFF {
					m = byte_at(d)
					break
				}
			}
		}
		for m != 0xDA {
			switch m {
			case 0xD9:
				return .None
			case MARKER_NONE:
				return .Invalid
			case 0xDC: // number of lines
				if u16_at(d) != 4 || u16_at(d) != d.features.height do return .Invalid
			case:
				read_segment(d, m) or_return
			}
			m = next_marker(d)
		}
		read_scan_header(d) or_return
	}
}

@(private)
read_scan_header :: proc(d: ^Decoder) -> Error {
	length := u16_at(d)
	d.scan_n = byte_at(d)
	if d.scan_n < 1 || d.scan_n > d.features.components || length != 6 + 2 * d.scan_n do return .Invalid
	for i in 0 ..< d.scan_n {
		id := u8(byte_at(d))
		q := byte_at(d)
		which := -1
		for c, k in d.comps[:d.features.components] do if c.id == id {which = k; break}
		if which < 0 do return .Invalid
		c := &d.comps[which]
		c.dc, c.ac = q >> 4, q & 15
		if c.dc > 3 || c.ac > 3 do return .Invalid
		d.order[i] = which
	}
	d.spec_start = byte_at(d)
	d.spec_end = byte_at(d)
	a := byte_at(d)
	d.succ_high, d.succ_low = a >> 4, a & 15
	if d.features.progressive {
		if d.spec_start > 63 || d.spec_end > 63 || d.spec_start > d.spec_end || d.succ_high > 13 || d.succ_low > 13 do return .Invalid
	} else {
		if d.spec_start != 0 || d.succ_high != 0 || d.succ_low != 0 do return .Invalid
		d.spec_end = 63
	}
	return .None
}

// Zigzag order to natural order; corrupt runs past the end land on 63.
@(private, rodata)
DEZIGZAG := [64 + 15]u8 {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
	12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
	63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,
}

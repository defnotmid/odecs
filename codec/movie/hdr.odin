package movie

import media "../media"
import "core:math"
import "core:math/linalg"

// HDR (BT.2100 PQ and HLG) and wide-gamut (BT.2020) video to SDR BT.709
// RGBA8. Per pixel: normalized R'G'B' from Y'CbCr, the transfer's EOTF to
// light relative to SDR reference white (203 nits, BT.2408; HLG adds its
// system-gamma OOTF), BT.2020 to BT.709 primaries (clipped), the BT.2390
// EETF on max(R, G, B) so hue is kept, and the BT.1886 inverse (gamma 2.4)
// to 8 bits. Each curve is one table load: tables over light are indexed by
// the f32's exponent and top mantissa bits (log-spaced steps, fine near
// black where the curves need them), the EOTF by the signal itself. A row
// is processed in runs held as separate R, G and B arrays, a step at a time.

Transfer :: enum u8 {
	SDR, // BT.709/BT.2020 SDR: gamma 2.4 display light
	PQ,  // SMPTE ST 2084 (H.273 transfer 16)
	HLG, // ARIB STD-B67 (H.273 transfer 18)
}

// Light tables cover [2^-LIGHT_OCTAVES, 2^LIGHT_TOP) with LIGHT_STEPS
// entries per octave; below is black.
@(private)
LIGHT_OCTAVES :: 20
@(private)
LIGHT_TOP :: 3 // 8x SDR white, above the 1000-nit peak (4.93)
@(private)
LIGHT_BITS :: 10
@(private)
LIGHT_SIZE :: (LIGHT_OCTAVES + LIGHT_TOP) << LIGHT_BITS
@(private)
SIGNAL_SIZE :: 1 << 14
@(private)
SDR_WHITE :: 203.0 // nits
@(private)
HDR_PEAK :: 1000.0 // nits assumed for PQ mastering and the HLG display

Tone_Map :: struct {
	transfer:             Transfer,
	wide:                 bool, // BT.2020 primaries: convert to BT.709
	gamut:                [3][3]f32,
	// Samples to normalized Y' in [0, 1] and C' in [-0.5, 0.5], then R'G'B'.
	y_mul, y_off:         f32,
	c_mul, c_off:         f32,
	rv, gu, gv, bu:       f32,
	peak:                 f32, // display peak relative to SDR white
	linear:               [SIGNAL_SIZE + 1]f32, // E' in [0, 1] -> light (HLG: scene light)
	ootf:                 [LIGHT_SIZE]f32, // HLG: scene luminance -> display gain
	gain:                 [LIGHT_SIZE]f32, // max(R, G, B) -> tone(m) / m
	encode:               [LIGHT_SIZE]u8, // light in [0, 1] -> 8-bit code
}

// The table slot of a light value: its exponent and LIGHT_BITS of mantissa,
// counted from 2^-LIGHT_OCTAVES; -1 below that (black), clamped at the top.
@(private)
light_slot :: #force_inline proc "contextless" (x: f32) -> int {
	bits := transmute(i32)x >> (23 - LIGHT_BITS) // negative light stays negative: black
	slot := int(bits - ((127 - LIGHT_OCTAVES) << LIGHT_BITS))
	return min(slot, LIGHT_SIZE - 1)
}

// The light value at the centre of a slot.
@(private)
slot_light :: proc(slot: int) -> f64 {
	bits := u32((slot + ((127 - LIGHT_OCTAVES) << LIGHT_BITS)) << (23 - LIGHT_BITS)) | 1 << (22 - LIGHT_BITS)
	return f64(transmute(f32)bits)
}

// Whether a colour description needs this path rather than the integer
// SDR conversion.
needs_tone_map :: proc(c: media.Color) -> bool {
	return c.transfer == 16 || c.transfer == 18 || c.primaries == 9
}

init_tone_map :: proc(t: ^Tone_Map, c: media.Color, bit_depth: int) {
	t.transfer = c.transfer == 16 ? .PQ : c.transfer == 18 ? .HLG : .SDR
	t.wide = c.primaries == 9
	t.gamut = t.wide ? bt2020_to_bt709() : {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
	full := f64(int(1) << uint(bit_depth) - 1)
	scale := f64(int(1) << uint(bit_depth - 8))
	if c.full_range {
		t.y_mul, t.y_off = f32(1 / full), 0
		t.c_mul, t.c_off = f32(1 / full), f32(f64(int(1) << uint(bit_depth - 1)) / full)
	} else {
		t.y_mul, t.y_off = f32(1 / (219 * scale)), f32(16.0 / 219)
		t.c_mul, t.c_off = f32(1 / (224 * scale)), f32(128.0 / 224)
	}
	m: Matrix = .BT709
	switch c.matrix_coeffs {
	case 5, 6:
		m = .BT601
	case 9, 10:
		m = .BT2020
	}
	kr, kb := matrix_weights(m)
	kg := 1 - kr - kb
	t.rv, t.bu = f32(2 * (1 - kr)), f32(2 * (1 - kb))
	t.gu, t.gv = f32(-2 * kb * (1 - kb) / kg), f32(-2 * kr * (1 - kr) / kg)
	t.peak = t.transfer == .SDR ? 1 : f32(HDR_PEAK / SDR_WHITE)
	for i in 0 ..= SIGNAL_SIZE {
		e := f64(i) / SIGNAL_SIZE
		switch t.transfer {
		case .PQ:
			t.linear[i] = f32(pq_eotf(e) / SDR_WHITE)
		case .HLG:
			t.linear[i] = f32(hlg_inverse_oetf(e))
		case .SDR:
			t.linear[i] = f32(math.pow(e, 2.4))
		}
	}
	for slot in 0 ..< LIGHT_SIZE {
		x := slot_light(slot)
		// HLG display light = peak * Ys^(gamma - 1) * scene light, gamma 1.2
		// at a 1000-nit display (BT.2100), relative to SDR white.
		t.ootf[slot] = f32(HDR_PEAK / SDR_WHITE * math.pow(min(x, 1), 0.2))
		t.gain[slot] = t.transfer == .SDR ? 1 : f32(tone(x) / x)
		t.encode[slot] = u8(math.round(255 * math.pow(min(x, 1), 1 / 2.4)))
	}
}

// The BT.2390 EETF from a HDR_PEAK display to an SDR_WHITE peak, in PQ
// space; light is relative to SDR white.
tone :: proc(light: f64) -> f64 {
	if light <= 0 do return 0
	source := pq_inverse(HDR_PEAK)
	x := min(pq_inverse(light * SDR_WHITE) / source, 1)
	max_lum := pq_inverse(SDR_WHITE) / source
	knee := 1.5 * max_lum - 0.5
	if x > knee {
		s := (x - knee) / (1 - knee)
		s2, s3 := s * s, s * s * s
		x = (2 * s3 - 3 * s2 + 1) * knee + (s3 - 2 * s2 + s) * (1 - knee) + (-2 * s3 + 3 * s2) * max_lum
	}
	return pq_eotf(x * source) / SDR_WHITE
}

// SMPTE ST 2084: signal in [0, 1] to nits, and back.
@(private)
PQ_M1 :: 2610.0 / 16384
@(private)
PQ_M2 :: 2523.0 / 4096 * 128
@(private)
PQ_C1 :: 3424.0 / 4096
@(private)
PQ_C2 :: 2413.0 / 4096 * 32
@(private)
PQ_C3 :: 2392.0 / 4096 * 32

@(private)
pq_eotf :: proc(e: f64) -> f64 {
	p := math.pow(e, 1 / PQ_M2)
	return 10000 * math.pow(max(p - PQ_C1, 0) / (PQ_C2 - PQ_C3 * p), 1 / PQ_M1)
}

@(private)
pq_inverse :: proc(nits: f64) -> f64 {
	y := math.pow(nits / 10000, PQ_M1)
	return math.pow((PQ_C1 + PQ_C2 * y) / (1 + PQ_C3 * y), PQ_M2)
}

// ARIB STD-B67 / BT.2100 HLG: signal to normalized scene light.
@(private)
hlg_inverse_oetf :: proc(e: f64) -> f64 {
	A :: 0.17883277
	B :: 1 - 4 * A
	C :: 0.55991073 // 0.5 - A * ln(4 * A)
	return e <= 0.5 ? e * e / 3 : (math.exp((e - C) / A) + B) / 12
}

// Linear BT.2020 RGB to linear BT.709 RGB, from the primaries and D65.
@(private)
bt2020_to_bt709 :: proc() -> (m: [3][3]f32) {
	npm :: proc(xy: [4][2]f64) -> (n: matrix[3, 3]f64) {
		p: matrix[3, 3]f64
		for c in 0 ..< 3 {
			x, y := xy[c][0], xy[c][1]
			p[0, c], p[1, c], p[2, c] = x / y, 1, (1 - x - y) / y
		}
		wx, wy := xy[3][0], xy[3][1]
		w := [3]f64{wx / wy, 1, (1 - wx - wy) / wy}
		s := linalg.inverse(p) * w
		for r in 0 ..< 3 do for c in 0 ..< 3 do n[r, c] = p[r, c] * s[c]
		return
	}
	d65 :: [2]f64{0.3127, 0.3290}
	to_xyz := npm({{0.708, 0.292}, {0.170, 0.797}, {0.131, 0.046}, d65})
	from_xyz := linalg.inverse(npm({{0.64, 0.33}, {0.30, 0.60}, {0.15, 0.06}, d65}))
	product := from_xyz * to_xyz
	for r in 0 ..< 3 do for c in 0 ..< 3 do m[r][c] = f32(product[r, c])
	return
}

@(private)
signal :: #force_inline proc "contextless" (t: ^Tone_Map, e: f32) -> f32 #no_bounds_check {
	return t.linear[int(clamp(e, 0, 1) * SIGNAL_SIZE + 0.5)]
}

// Pixels per run: the row's R, G and B arrays live on the stack.
@(private)
TONE_RUN :: 256

// Planar Y'CbCr (8- or 16-bit storage, subsampling given as shifts) to SDR
// RGBA8 through `t`, with optional alpha as in yuv_to_rgba.
hdr_to_rgba :: proc(
	planes: [3][]u8,
	strides: [3]int,
	width, height: int,
	storage_bits: int,
	shift_x, shift_y: uint,
	t: ^Tone_Map,
	dst: []u8,
	dst_stride: int,
	alpha := Alpha_Plane{},
	bit_depth := 8,
) {
	a := alpha_scale(alpha, bit_depth)
	if storage_bits == 8 {
		hdr_rows(planes, strides, width, height, shift_x, shift_y, t, dst, dst_stride, &a, u8)
	} else {
		hdr_rows(planes, strides, width, height, shift_x, shift_y, t, dst, dst_stride, &a, u16)
	}
}

@(private)
hdr_rows :: proc(planes: [3][]u8, strides: [3]int, width, height: int, shift_x, shift_y: uint, t: ^Tone_Map, dst: []u8, dst_stride: int, a: ^Alpha_Scale, $T: typeid) #no_bounds_check {
	mono := len(planes[1]) == 0
	g := t.gamut
	for row in 0 ..< height {
		ys := ([^]T)(raw_data(planes[0][row * strides[0]:]))
		us, vs: [^]T
		if !mono {
			crow := row >> shift_y
			us = ([^]T)(raw_data(planes[1][crow * strides[1]:]))
			vs = ([^]T)(raw_data(planes[2][crow * strides[2]:]))
		}
		out := ([^]u32)(raw_data(dst[row * dst_stride:]))
		for x0 := 0; x0 < width; x0 += TONE_RUN {
			n := min(TONE_RUN, width - x0)
			r, gr, b: [TONE_RUN]f32
			// Y'CbCr to R'G'B'.
			for i in 0 ..< n {
				x := x0 + i
				y := f32(ys[x]) * t.y_mul - t.y_off
				u, v: f32
				if !mono {
					u = f32(us[x >> shift_x]) * t.c_mul - t.c_off
					v = f32(vs[x >> shift_x]) * t.c_mul - t.c_off
				}
				r[i], gr[i], b[i] = y + t.rv * v, y + t.gu * u + t.gv * v, y + t.bu * u
			}
			// To light, relative to SDR white.
			for i in 0 ..< n do r[i], gr[i], b[i] = signal(t, r[i]), signal(t, gr[i]), signal(t, b[i])
			if t.transfer == .HLG {
				for i in 0 ..< n {
					slot := light_slot(0.2627 * r[i] + 0.6780 * gr[i] + 0.0593 * b[i])
					k := slot < 0 ? 0 : t.ootf[slot]
					r[i], gr[i], b[i] = r[i] * k, gr[i] * k, b[i] * k
				}
			}
			if t.wide {
				for i in 0 ..< n {
					rr, gg, bb := r[i], gr[i], b[i]
					r[i] = max(g[0][0] * rr + g[0][1] * gg + g[0][2] * bb, 0)
					gr[i] = max(g[1][0] * rr + g[1][1] * gg + g[1][2] * bb, 0)
					b[i] = max(g[2][0] * rr + g[2][1] * gg + g[2][2] * bb, 0)
				}
			}
			// Tone map on the brightest channel, then encode.
			for i in 0 ..< n {
				slot := light_slot(max(r[i], gr[i], b[i]))
				k := slot < 0 ? 1 : t.gain[slot]
				code :: #force_inline proc "contextless" (t: ^Tone_Map, v: f32) -> u32 #no_bounds_check {
					slot := light_slot(v)
					return slot < 0 ? 0 : u32(t.encode[slot])
				}
				out[x0 + i] = code(t, r[i] * k) | code(t, gr[i] * k) << 8 | code(t, b[i] * k) << 16 | 0xFF000000
			}
		}
		alpha_row(a, row, out, width, T)
	}
}

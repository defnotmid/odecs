package h265_decoder

// ---------------------------------------------------------------------------
// Intra prediction (8.4.4.2), ported from gen2brain/h265 hevc/intrapred.go
// (MIT); oxideav-h265 src/intra_pred.rs is the per-file cross-reference.
// Only the 8-bit sample path is needed so far.
// ---------------------------------------------------------------------------

INTRA_PLANAR :: 0
INTRA_DC :: 1
INTRA_HOR :: 10
INTRA_VER :: 26

// Table 8-4, indexed by predModeIntra - 2.
INTRA_PRED_ANGLE := [33]i32 {
	32,
	26,
	21,
	17,
	13,
	9,
	5,
	2,
	0,
	-2,
	-5,
	-9,
	-13,
	-17,
	-21,
	-26,
	-32,
	-26,
	-21,
	-17,
	-13,
	-9,
	-5,
	-2,
	0,
	2,
	5,
	9,
	13,
	17,
	21,
	26,
	32,
}

// Table 8-5, indexed by predModeIntra - 11.
INTRA_INV_ANGLE := [15]i32 {
	-4096,
	-1638,
	-910,
	-630,
	-482,
	-390,
	-315,
	-256,
	-315,
	-390,
	-482,
	-630,
	-910,
	-1638,
	-4096,
}

// Ref_Samples holds p[][] flattened in the order 8.4.4.2.2 scans it: the left
// column bottom to top, the corner, then the top row left to right.
Ref_Samples :: struct {
	s: [4 * 32 + 1]i32,
	n: int,
}

ref_corner :: #force_inline proc(r: ^Ref_Samples) -> i32 {return r.s[2 * r.n]}
ref_top :: #force_inline proc(r: ^Ref_Samples, x: int) -> i32 {return r.s[2 * r.n + 1 + x]}
ref_left :: #force_inline proc(r: ^Ref_Samples, y: int) -> i32 {return r.s[2 * r.n - 1 - y]}
ref_set_top :: #force_inline proc(r: ^Ref_Samples, x: int, v: i32) {r.s[2 * r.n + 1 + x] = v}
ref_set_left :: #force_inline proc(r: ^Ref_Samples, y: int, v: i32) {r.s[2 * r.n - 1 - y] = v}

// ref_substitute is 8.4.4.2.2. `avail` runs in the same order as `s`.
ref_substitute :: proc(r: ^Ref_Samples, avail: []bool, bit_depth: int) #no_bounds_check {
	n := 4 * r.n + 1

	first := -1

	for i in 0 ..< n {
		if avail[i] {
			first = i
			break
		}
	}

	if first < 0 {
		v := i32(1) << uint(bit_depth - 1)
		for i in 0 ..< n do r.s[i] = v

		return
	}

	r.s[0] = r.s[first]

	for i in 1 ..< n {
		if !avail[i] do r.s[i] = r.s[i - 1]
	}
}

// filter_flag is the derivation in 8.4.4.2.3.
filter_flag :: proc(mode, n, c_idx: int, s: ^SPS) -> bool {
	if c_idx != 0 && sps_chroma_array_type(s) != 3 do return false
	if mode == INTRA_DC || n == 4 do return false

	thres: int
	switch n {
	case 8:
		thres = 7
	case 16:
		thres = 1
	case 32:
		thres = 0
	case:
		return false
	}

	return min(abs_int(mode - INTRA_VER), abs_int(mode - INTRA_HOR)) > thres
}

// filter_ref is 8.4.4.2.3.
filter_ref :: proc(r: ^Ref_Samples, mode, c_idx, bit_depth: int, s: ^SPS) #no_bounds_check {
	if s.intra_smoothing_disabled || !filter_flag(mode, r.n, c_idx, s) do return

	n := r.n

	if s.strong_intra_smoothing && c_idx == 0 && n == 32 {
		lim := i32(1) << uint(bit_depth - 5)

		if abs_i32(ref_corner(r) + ref_top(r, 2 * n - 1) - 2 * ref_top(r, n - 1)) < lim &&
		   abs_i32(ref_corner(r) + ref_left(r, 2 * n - 1) - 2 * ref_left(r, n - 1)) < lim {
			c, tr, bl := ref_corner(r), ref_top(r, 2 * n - 1), ref_left(r, 2 * n - 1)

			for i in 0 ..< 2 * n - 1 {
				ref_set_left(r, i, ((63 - i32(i)) * c + i32(i + 1) * bl + 32) >> 6)
				ref_set_top(r, i, ((63 - i32(i)) * c + i32(i + 1) * tr + 32) >> 6)
			}

			return
		}
	}

	f: [4 * 32 + 1]i32

	f[0] = r.s[0]
	f[4 * n] = r.s[4 * n]

	for i in 1 ..< 4 * n {
		f[i] = (r.s[i - 1] + 2 * r.s[i] + r.s[i + 1] + 2) >> 2
	}

	copy(r.s[:4 * n + 1], f[:4 * n + 1])
}

// intra_predict is 8.4.4.2.4 through 8.4.4.2.6. `disable_boundary` is
// 8.4.4.2.6's disableIntraBoundaryFilter, which suppresses the mode-10/26
// edge smoothing.
intra_predict :: proc(
	dst: []$Sample,
	off, stride: int,
	r: ^Ref_Samples,
	mode, c_idx, bit_depth: int,
	disable_boundary: bool,
) #no_bounds_check {
	switch {
	case mode == INTRA_PLANAR:
		pred_planar(dst, off, stride, r)
	case mode == INTRA_DC:
		pred_dc(dst, off, stride, r, c_idx)
	case:
		pred_angular(dst, off, stride, r, mode, c_idx, bit_depth, disable_boundary)
	}
}

pred_planar :: proc(dst: []$Sample, off, stride: int, r: ^Ref_Samples) #no_bounds_check {
	n := r.n
	shift := log2_int(n) + 1
	tr, bl := ref_top(r, n), ref_left(r, n)

	for y in 0 ..< n {
		l := ref_left(r, y)

		for x in 0 ..< n {
			v :=
				(i32(n - 1 - x) * l +
					i32(x + 1) * tr +
					i32(n - 1 - y) * ref_top(r, x) +
					i32(y + 1) * bl +
					i32(n)) >>
				uint(shift)
			dst[off + y * stride + x] = Sample(v)
		}
	}
}

pred_dc :: proc(dst: []$Sample, off, stride: int, r: ^Ref_Samples, c_idx: int) #no_bounds_check {
	n := r.n

	sum: i32
	for i in 0 ..< n do sum += ref_top(r, i) + ref_left(r, i)

	dc := (sum + i32(n)) >> uint(log2_int(n) + 1)

	for y in 0 ..< n {
		for x in 0 ..< n {
			dst[off + y * stride + x] = Sample(dc)
		}
	}

	if c_idx != 0 || n >= 32 do return

	dst[off] = Sample((ref_left(r, 0) + 2 * dc + ref_top(r, 0) + 2) >> 2)

	for x in 1 ..< n {
		dst[off + x] = Sample((ref_top(r, x) + 3 * dc + 2) >> 2)
	}

	for y in 1 ..< n {
		dst[off + y * stride] = Sample((ref_left(r, y) + 3 * dc + 2) >> 2)
	}
}

pred_angular :: proc(
	dst: []$Sample,
	off, stride: int,
	r: ^Ref_Samples,
	mode, c_idx, bit_depth: int,
	disable_boundary: bool,
) #no_bounds_check {
	n := r.n
	angle := INTRA_PRED_ANGLE[mode - 2]

	ref: [3 * 32 * 2]i32

	// The corner sits at 2n in both r.s and ref.
	base := 2 * n

	vertical := mode >= 18

	m := n
	if angle >= 0 do m = 2 * n

	if vertical {
		copy(ref[base:base + m + 1], r.s[base:base + m + 1])
	} else {
		ref[base] = r.s[base]

		for x in 1 ..= m {
			ref[base + x] = r.s[base - x]
		}
	}

	if angle < 0 {
		if lim := int(i32(n) * angle >> 5); lim < -1 {
			inv := INTRA_INV_ANGLE[mode - 11]

			for x := -1; x >= lim; x -= 1 {
				i := int((i32(x) * inv + 128) >> 8)

				switch {
				case i == 0:
					ref[base + x] = r.s[base]
				case vertical:
					ref[base + x] = r.s[base - i]
				case:
					ref[base + x] = r.s[base + i]
				}
			}
		}
	}

	for b in 0 ..< n {
		idx := int(i32(b + 1) * angle >> 5)
		fact := i32(b + 1) * angle & 31
		row := ref[base + idx + 1:base + idx + 2 + n]

		switch {
		case fact == 0 && vertical:
			out := dst[off + b * stride:off + b * stride + n]

			for a in 0 ..< len(out) do out[a] = Sample(row[a])
		case fact == 0:
			for a in 0 ..< n do dst[off + a * stride + b] = Sample(row[a])
		case vertical:
			out := dst[off + b * stride:off + b * stride + n]

			for a in 0 ..< len(out) {
				out[a] = Sample(((32 - fact) * row[a] + fact * row[a + 1] + 16) >> 5)
			}
		case:
			for a in 0 ..< n {
				dst[off + a * stride + b] = Sample(
					((32 - fact) * row[a] + fact * row[a + 1] + 16) >> 5,
				)
			}
		}
	}

	// finish_angular is the boundary smoothing of 8.4.4.2.6, suppressed by
	// disableIntraBoundaryFilter.
	if disable_boundary || c_idx != 0 || n >= 32 do return

	if mode == INTRA_VER {
		for y in 0 ..< n {
			v := ref_top(r, 0) + (ref_left(r, y) - ref_corner(r)) >> 1
			dst[off + y * stride] = Sample(clip1_8(v, bit_depth))
		}

		return
	}

	if mode == INTRA_HOR {
		for x in 0 ..< n {
			v := ref_left(r, 0) + (ref_top(r, x) - ref_corner(r)) >> 1
			dst[off + x] = Sample(clip1_8(v, bit_depth))
		}
	}
}

@(private)
clip1_8 :: #force_inline proc(v: i32, bit_depth: int) -> i32 {
	return clamp(v, 0, i32(1) << uint(bit_depth) - 1)
}

@(private)
log2_int :: #force_inline proc(n: int) -> int {
	m := n
	k := 0
	for m > 1 {
		m >>= 1
		k += 1
	}
	return k
}

@(private)
abs_int :: #force_inline proc(v: int) -> int {
	return v < 0 ? -v : v
}

@(private)
abs_i32 :: #force_inline proc(v: i32) -> i32 {
	return v < 0 ? -v : v
}

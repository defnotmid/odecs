package h265_encoder

import "base:intrinsics"
import "core:simd"

// ---------------------------------------------------------------------------
// Intra prediction (8.4.2): reference sample construction, substitution,
// smoothing and the 35 prediction modes.
// ---------------------------------------------------------------------------

INTRA_REF_LEN :: 2 * 32 + 1

Intra_Refs :: struct {
	left:                 [INTRA_REF_LEN]Sample, // [0] = top-left, [1..] = left
	top:                  [INTRA_REF_LEN]Sample, // [0] = top-left, [1..] = top
	filtered_left:        [INTRA_REF_LEN]Sample,
	filtered_top:         [INTRA_REF_LEN]Sample,
	filtered_initialized: bool,
}

@(private)
filter_reference :: proc(log2_width: int, refs: ^Intra_Refs) #no_bounds_check {
	if refs.filtered_initialized do return
	refs.filtered_initialized = true

	ref_width := 2 * (1 << uint(log2_width)) + 1
	refs.filtered_left[0] = Sample(
		(i32(refs.left[1]) + 2 * i32(refs.left[0]) + i32(refs.top[1]) + 2) / 4,
	)
	refs.filtered_top[0] = refs.filtered_left[0]

	for y in 1 ..< ref_width - 1 {
		refs.filtered_left[y] = Sample(
			(i32(refs.left[y - 1]) + 2 * i32(refs.left[y]) + i32(refs.left[y + 1]) + 2) / 4,
		)
	}
	refs.filtered_left[ref_width - 1] = refs.left[ref_width - 1]

	for x in 1 ..< ref_width - 1 {
		refs.filtered_top[x] = Sample(
			(i32(refs.top[x - 1]) + 2 * i32(refs.top[x]) + i32(refs.top[x + 1]) + 2) / 4,
		)
	}
	refs.filtered_top[ref_width - 1] = refs.top[ref_width - 1]
}

// kvz_intra_build_reference_any against the reconstructed frame. Tile
// boundaries are picture edges for reference purposes (6.4.1): a tile never
// reads another tile's reconstruction, and an unavailable left column or top
// row is substituted exactly as at a picture edge.
build_reference :: proc(
	enc: ^Encoder,
	frame: ^Frame,
	x, y, log2_width: int,
	color: Color,
	refs: ^Intra_Refs,
	bit_depth: int,
) #no_bounds_check {
	refs.filtered_initialized = false
	width := 1 << uint(log2_width)
	shift_x := 0
	shift_y := 0
	if color != .Y {
		sw, sh := chroma_sub(enc.config.chroma_format)
		shift_x = sw == 2 ? 1 : 0
		shift_y = sh == 2 ? 1 : 0
	}
	plane := color == .Y ? frame.y : (color == .U ? frame.u : frame.v)
	px_x, px_y := x >> uint(shift_x), y >> uint(shift_y)
	pic_w, pic_h := frame.coded_width >> uint(shift_x), frame.coded_height >> uint(shift_y)

	lcu_x, lcu_y := x & (CTU_WIDTH - 1), y & (CTU_WIDTH - 1)
	ref_top := int(NUM_REF_PIXELS_TOP[lcu_y >> 2][lcu_x >> 2]) >> uint(shift_x)
	ref_left := int(NUM_REF_PIXELS_LEFT[lcu_y >> 2][lcu_x >> 2]) >> uint(shift_y)

	// The tile edges bounding this block, in luma pixels.
	tl, tr, tt, tb := tile_bounds(enc, x, y)

	// Left reference.
	if x > tl {
		avail := min(min(min(ref_left, 2 * width), pic_h - px_y), (tb >> uint(shift_y)) - px_y)
		for i in 0 ..< avail {
			refs.left[i + 1] = at(plane, px_x - 1, px_y + i)
		}
		nearest := refs.left[avail]
		for i in avail ..< 2 * width do refs.left[i + 1] = nearest
	} else {
		nearest := y > tt ? at(plane, px_x, px_y - 1) : Sample(1) << uint(bit_depth - 1)
		for i in 0 ..< 2 * width do refs.left[i + 1] = nearest
	}

	// Top reference.
	if y > tt {
		avail := min(min(min(ref_top, 2 * width), pic_w - px_x), (tr >> uint(shift_x)) - px_x)
		for i in 0 ..< avail {
			refs.top[i + 1] = at(plane, px_x + i, px_y - 1)
		}
		nearest := at(plane, px_x + avail - 1, px_y - 1)
		for i in avail ..< 2 * width do refs.top[i + 1] = nearest
	} else {
		nearest := x > tl ? at(plane, px_x - 1, px_y) : Sample(1) << uint(bit_depth - 1)
		for i in 0 ..< 2 * width do refs.top[i + 1] = nearest
	}

	// Top-left.
	if x > tl && y > tt {
		refs.left[0] = at(plane, px_x - 1, px_y - 1)
		refs.top[0] = refs.left[0]
	} else {
		refs.left[0] = refs.left[1]
		refs.top[0] = refs.left[1]
	}
}

// Four input rows become four output columns. Interleave adjacent rows first,
// then join their two-row column pairs; every lane is moved without arithmetic.
@(private)
intra_transpose_4x4 :: #force_inline proc(
	a, b, c, d: #simd[4]u16,
) -> (
	#simd[4]u16,
	#simd[4]u16,
	#simd[4]u16,
	#simd[4]u16,
) {
	ab0 := simd.shuffle(a, b, 0, 4, 1, 5)
	ab1 := simd.shuffle(a, b, 2, 6, 3, 7)
	cd0 := simd.shuffle(c, d, 0, 4, 1, 5)
	cd1 := simd.shuffle(c, d, 2, 6, 3, 7)
	return simd.shuffle(
		ab0,
		cd0,
		0,
		1,
		4,
		5,
	), simd.shuffle(ab0, cd0, 2, 3, 6, 7), simd.shuffle(ab1, cd1, 0, 1, 4, 5), simd.shuffle(ab1, cd1, 2, 3, 6, 7)
}

@(private)
transpose_intra_square :: proc(dst: []Sample, width, stride: int) #no_bounds_check {
	// Native predictions are 4/8/16/32 squares. Retain the scalar definition
	// for smaller or nonmultiple widths without reading their row padding.
	if (width & 3) != 0 {
		for y in 0 ..< width - 1 {
			for x in y + 1 ..< width {
				dst[y * stride + x], dst[x * stride + y] = dst[x * stride + y], dst[y * stride + x]
			}
		}
		return
	}
	Row :: #simd[4]u16
	for row := 0; row < width; row += 4 {
		base := row * stride + row
		a0 := intrinsics.unaligned_load((^Row)(&dst[base]))
		a1 := intrinsics.unaligned_load((^Row)(&dst[base + stride]))
		a2 := intrinsics.unaligned_load((^Row)(&dst[base + 2 * stride]))
		a3 := intrinsics.unaligned_load((^Row)(&dst[base + 3 * stride]))
		a0, a1, a2, a3 = intra_transpose_4x4(a0, a1, a2, a3)
		intrinsics.unaligned_store((^Row)(&dst[base]), a0)
		intrinsics.unaligned_store((^Row)(&dst[base + stride]), a1)
		intrinsics.unaligned_store((^Row)(&dst[base + 2 * stride]), a2)
		intrinsics.unaligned_store((^Row)(&dst[base + 3 * stride]), a3)
		for col := row + 4; col < width; col += 4 {
			upper := row * stride + col
			lower := col * stride + row
			a0 = intrinsics.unaligned_load((^Row)(&dst[upper]))
			a1 = intrinsics.unaligned_load((^Row)(&dst[upper + stride]))
			a2 = intrinsics.unaligned_load((^Row)(&dst[upper + 2 * stride]))
			a3 = intrinsics.unaligned_load((^Row)(&dst[upper + 3 * stride]))
			b0 := intrinsics.unaligned_load((^Row)(&dst[lower]))
			b1 := intrinsics.unaligned_load((^Row)(&dst[lower + stride]))
			b2 := intrinsics.unaligned_load((^Row)(&dst[lower + 2 * stride]))
			b3 := intrinsics.unaligned_load((^Row)(&dst[lower + 3 * stride]))
			// Both tiles are fully borrowed into registers before either is
			// replaced by its partner's columns.
			a0, a1, a2, a3 = intra_transpose_4x4(a0, a1, a2, a3)
			b0, b1, b2, b3 = intra_transpose_4x4(b0, b1, b2, b3)
			intrinsics.unaligned_store((^Row)(&dst[upper]), b0)
			intrinsics.unaligned_store((^Row)(&dst[upper + stride]), b1)
			intrinsics.unaligned_store((^Row)(&dst[upper + 2 * stride]), b2)
			intrinsics.unaligned_store((^Row)(&dst[upper + 3 * stride]), b3)
			intrinsics.unaligned_store((^Row)(&dst[lower]), a0)
			intrinsics.unaligned_store((^Row)(&dst[lower + stride]), a1)
			intrinsics.unaligned_store((^Row)(&dst[lower + 2 * stride]), a2)
			intrinsics.unaligned_store((^Row)(&dst[lower + 3 * stride]), a3)
		}
	}
}

@(private)
intra_load_samples :: #force_inline proc(
	$LANES: int,
	source: []Sample,
	offset: int,
) -> #simd[LANES]i32 #no_bounds_check {
	return (#simd[LANES]i32)(intrinsics.unaligned_load((^#simd[LANES]u16)(&source[offset])))
}

// One consumer owns publication and distortion. Measurement never needs a
// materialized prediction block; its source view follows the predictor's row
// orientation. Each lane's square fits i32 for admitted 8/10-bit samples.
@(private)
intra_consume :: #force_inline proc(
	$Publish: bool,
	$Measure: bool,
	values, measured: #simd[$LANES]i32,
	dst, source: []Sample,
	dst_stride, source_stride, x, y: int,
	acc: ^#simd[LANES]i32,
) #no_bounds_check {
	when Measure {
		d := simd.sub(intra_load_samples(LANES, source, y * source_stride + x), measured)
		acc^ = simd.add(acc^, simd.mul(d, d))
	}
	when Publish {
		when LANES == 1 {
			dst[y * dst_stride + x] = Sample(simd.extract(values, 0))
		} else {
			intrinsics.unaligned_store(
				(^#simd[LANES]u16)(&dst[y * dst_stride + x]),
				(#simd[LANES]u16)(values),
			)
		}
	}
}

@(private)
intra_angular_boundary_value :: #force_inline proc(value, reference, origin, max_v: i32) -> i32 {
	return clamp(value + ((reference - origin) >> 1), 0, max_v)
}

// The angular equations are shared by the publishing and score-only paths.
@(private)
angular_pred :: #force_inline proc(
	$Publish: bool,
	$Measure: bool,
	log2_width: int,
	intra_mode: u8,
	ref_top, ref_left: []Sample,
	dst, source: []Sample,
	stride, source_stride: int,
	boundary: bool,
	max_v: i32,
	acc: ^#simd[$LANES]i32,
) #no_bounds_check {
	MODE_DISP_TO_SAMPLE := [9]i32{0, 2, 5, 9, 13, 17, 21, 26, 32}
	MODE_DISP_TO_INV := [9]i32{0, 4096, 1638, 910, 630, 482, 390, 315, 256}

	width := 1 << uint(log2_width)
	mode := i32(intra_mode)
	vertical_mode := mode >= 18
	mode_disp := vertical_mode ? mode - 26 : 10 - mode
	sample_disp := (mode_disp < 0 ? -1 : 1) * MODE_DISP_TO_SAMPLE[abs(mode_disp)]

	tmp_ref: [2 * 32]Sample = ---
	ref_main: []Sample
	ref_main_off: int
	ref_side: []Sample

	if sample_disp < 0 {
		side_src := vertical_mode ? ref_left : ref_top
		main_src := vertical_mode ? ref_top : ref_left
		ref_side = side_src[1:]
		// Room for negative indices in the second half of tmp_ref.
		for i in -1 ..< width {
			tmp_ref[i + width] = main_src[i + 1]
		}
		ref_main = tmp_ref[:]
		ref_main_off = width

		col_sample_disp := i32(128)
		inv_abs := MODE_DISP_TO_INV[abs(mode_disp)]
		most_negative := (i32(width) * sample_disp) >> 5
		x := i32(-2)
		for ; x >= most_negative; x -= 1 {
			col_sample_disp += inv_abs
			side_index := int(col_sample_disp >> 8)
			tmp_ref[int(x) + width] = ref_side[side_index - 1]
		}
	} else {
		ref_main = (vertical_mode ? ref_top : ref_left)
		ref_main_off = 1
		ref_side = (vertical_mode ? ref_left : ref_top)[1:]
	}

	V :: #simd[LANES]i32
	delta_pos := i32(0)
	for y in 0 ..< width {
		delta_pos += sample_disp
		delta_int := int(delta_pos >> 5)
		delta_fract := i32(delta_pos & 31)
		for x := 0; x < width; x += LANES {
			values := intra_load_samples(LANES, ref_main, ref_main_off + x + delta_int)
			if delta_fract != 0 {
				next := intra_load_samples(LANES, ref_main, ref_main_off + x + delta_int + 1)
				values = simd.shr(
					simd.add(
						simd.add(
							simd.mul(V(32 - delta_fract), values),
							simd.mul(V(delta_fract), next),
						),
						V(16),
					),
					(#simd[LANES]u32)(5),
				)
			}
			measured := values
			when Measure {
				// The horizontal source is transposed once by the CU owner. Its
				// first-column correction is the final picture's first row.
				if boundary && x == 0 {
					ref := vertical_mode ? ref_left : ref_top
					measured = simd.replace(
						measured,
						0,
						intra_angular_boundary_value(
							simd.extract(values, 0),
							i32(ref[y + 1]),
							i32(ref[0]),
							max_v,
						),
					)
				}
			}
			intra_consume(
				Publish,
				Measure,
				values,
				measured,
				dst,
				source,
				stride,
				source_stride,
				x,
				y,
				acc,
			)
		}
	}
	when Publish do if !vertical_mode do transpose_intra_square(dst, width, stride)
}

// kvz_intra_pred_planar_generic
@(private)
pred_planar :: #force_inline proc(
	$Publish: bool,
	$Measure: bool,
	log2_width: int,
	ref_top, ref_left: []Sample,
	dst, source: []Sample,
	stride, source_stride: int,
	acc: ^#simd[$LANES]i32,
) #no_bounds_check {
	width := 1 << uint(log2_width)
	top_right := ref_top[width + 1]
	bottom_left := ref_left[width + 1]

	top: [32]i32 = ---
	for i in 0 ..< width {
		top[i] = i32(ref_top[i + 1]) << uint(log2_width)
	}
	V :: #simd[LANES]i32
	when LANES > 1 {
		offsets: [LANES]i32 = ---
		for &offset, lane in offsets do offset = i32(lane + 1)
		lane_offsets := intrinsics.unaligned_load((^V)(&offsets[0]))
	}
	for y in 0 ..< width {
		left := i32(ref_left[y + 1])
		hor := (left << uint(log2_width)) + i32(width)
		for x := 0; x < width; x += LANES {
			top_v := intrinsics.unaligned_load((^V)(&top[x]))
			top_v = simd.add(
				top_v,
				simd.sub(V(i32(bottom_left)), intra_load_samples(LANES, ref_top, x + 1)),
			)
			intrinsics.unaligned_store((^V)(&top[x]), top_v)
			hor_v: V
			when LANES == 1 {
				// Preserve the publishing path's scalar reference-read order.
				hor += i32(top_right) - i32(ref_left[y + 1])
				hor_v = V(hor)
			} else {
				hor_v = simd.add(
					V(hor),
					simd.mul(V(i32(top_right) - left), simd.add(V(i32(x)), lane_offsets)),
				)
			}
			values := simd.shr(simd.add(hor_v, top_v), (#simd[LANES]u32)(u32(log2_width + 1)))
			intra_consume(
				Publish,
				Measure,
				values,
				values,
				dst,
				source,
				stride,
				source_stride,
				x,
				y,
				acc,
			)
		}
	}
}

@(private)
pred_dc :: #force_inline proc(
	$Publish: bool,
	$Measure: bool,
	log2_width: int,
	ref_top, ref_left: []Sample,
	dst, source: []Sample,
	stride, source_stride: int,
	filtered: bool,
	acc: ^#simd[$LANES]i32,
) #no_bounds_check {
	width := 1 << uint(log2_width)
	sum: i32
	for i in 0 ..< width {
		sum += i32(ref_top[i + 1]) + i32(ref_left[i + 1])
	}
	dc_val := (sum + i32(width)) >> uint(log2_width + 1)
	V :: #simd[LANES]i32
	for y in 0 ..< width {
		for x := 0; x < width; x += LANES {
			values := V(dc_val)
			if filtered {
				if y == 0 {
					values = simd.shr(
						simd.add(intra_load_samples(LANES, ref_top, x + 1), V(3 * dc_val + 2)),
						(#simd[LANES]u32)(2),
					)
					if x == 0 do values = simd.replace(values, 0, (i32(ref_left[1]) + 2 * dc_val + i32(ref_top[1]) + 2) / 4)
				} else if x == 0 {
					values = simd.replace(values, 0, (i32(ref_left[y + 1]) + 3 * dc_val + 2) / 4)
				}
			}
			intra_consume(
				Publish,
				Measure,
				values,
				values,
				dst,
				source,
				stride,
				source_stride,
				x,
				y,
				acc,
			)
		}
	}
}

@(private)
post_process_angular :: proc(
	width, stride: int,
	ref: []Sample,
	dst: []Sample,
	max_v: i32,
) #no_bounds_check {
	origin := i32(ref[0])
	for i in 0 ..< width {
		dst[i * stride] = Sample(
			intra_angular_boundary_value(i32(dst[i * stride]), i32(ref[i + 1]), origin, max_v),
		)
	}
}

// Reference smoothing also applies to chroma at 4:4:4. DC and angular
// boundary smoothing remain luma-only (8.4.4.2.5 and 8.4.4.2.6).
@(private)
intra_predict_consume :: proc(
	$Publish: bool,
	$Measure: bool,
	$LANES: int,
	refs: ^Intra_Refs,
	log2_width: int,
	mode: u8,
	color: Color,
	dst: []Sample,
	stride: int,
	source: []Sample,
	source_stride: int,
	bit_depth: int,
	layout: Chroma_Layout = .YUV_420,
) -> u64 #no_bounds_check {
	width := 1 << uint(log2_width)
	acc := (#simd[LANES]i32)(0)

	use_filtered: bool
	if (color != .Y && layout != .YUV_444) || mode == 1 || width == 4 {
		use_filtered = false
	} else if mode == 0 {
		use_filtered = true
	} else {
		DIST_THRESHOLD := [5]i32{0, 7, 1, 0, 0}
		threshold := DIST_THRESHOLD[log2_width - 2]
		dist := abs(i32(mode) - 26)
		d := abs(i32(mode) - 10)
		if d < dist do dist = d
		use_filtered = dist > threshold
	}

	if use_filtered && !refs.filtered_initialized {
		filter_reference(log2_width, refs)
	}
	top := use_filtered ? refs.filtered_top[:] : refs.top[:]
	left := use_filtered ? refs.filtered_left[:] : refs.left[:]

	switch mode {
	case 0:
		pred_planar(
			Publish,
			Measure,
			log2_width,
			top,
			left,
			dst,
			source,
			stride,
			source_stride,
			&acc,
		)
	case 1:
		pred_dc(
			Publish,
			Measure,
			log2_width,
			top,
			left,
			dst,
			source,
			stride,
			source_stride,
			color == .Y && width < 32,
			&acc,
		)
	case:
		boundary := color == .Y && width < 32 && (mode == 10 || mode == 26)
		max_v := i32(1) << uint(bit_depth) - 1
		angular_pred(
			Publish,
			Measure,
			log2_width,
			mode,
			top,
			left,
			dst,
			source,
			stride,
			source_stride,
			boundary,
			max_v,
			&acc,
		)
		when Publish {
			if boundary {
				if mode == 10 {
					post_process_angular(width, 1, top, dst, max_v)
				} else {
					post_process_angular(width, stride, left, dst, max_v)
				}
			}
		}
	}
	return u64(simd.reduce_add_ordered(acc))
}

// Publication retains scalar lane order and the existing transpose/post-filter
// order. Only the score-only consumer groups samples into native SIMD lanes.
intra_predict :: proc(
	refs: ^Intra_Refs,
	log2_width: int,
	mode: u8,
	color: Color,
	dst: []Sample,
	stride: int,
	bit_depth: int,
	layout: Chroma_Layout = .YUV_420,
) #no_bounds_check {
	intra_predict_consume(
		true,
		false,
		1,
		refs,
		log2_width,
		mode,
		color,
		dst,
		stride,
		nil,
		0,
		bit_depth,
		layout,
	)
}

@(private)
intra_measure :: proc(
	refs: ^Intra_Refs,
	log2_width: int,
	mode: u8,
	color: Color,
	source: []Sample,
	source_stride: int,
	bit_depth: int,
	layout: Chroma_Layout = .YUV_420,
) -> u64 #no_bounds_check {
	if log2_width == 2 {
		return intra_predict_consume(
			false,
			true,
			4,
			refs,
			log2_width,
			mode,
			color,
			nil,
			0,
			source,
			source_stride,
			bit_depth,
			layout,
		)
	}
	return intra_predict_consume(
		false,
		true,
		8,
		refs,
		log2_width,
		mode,
		color,
		nil,
		0,
		source,
		source_stride,
		bit_depth,
		layout,
	)
}

// ---------------------------------------------------------------------------
// Intra mode signalling (8.4.2 / 8.4.3)
// ---------------------------------------------------------------------------

// kvz_intra_get_dir_luma_predictor. The above prediction unit is not used
// across a CTU boundary, matching the decoder's availability rules.
get_mpm_predictors :: proc(enc: ^Encoder, x, y: int, out: ^[3]u8) {
	// 8.4.2's availableA/availableB: a neighbour in another tile is never
	// available, and the above neighbour must share the CTB row.
	left_mode: u8 = 1
	if x > 0 && z_scan_available(enc, x, y, x - 1, y) {
		left := cu_at(enc.cu, x - 1, y)
		if left.type == .Intra do left_mode = left.mode
	}
	above_mode: u8 = 1
	if y > 0 && (y & (CTU_WIDTH - 1)) != 0 && z_scan_available(enc, x, y, x, y - 1) {
		above := cu_at(enc.cu, x, y - 1)
		if above.type == .Intra do above_mode = above.mode
	}

	if left_mode == above_mode {
		if left_mode > 1 {
			out[0] = left_mode
			out[1] = u8(((i32(left_mode) + 29) % 32) + 2)
			out[2] = u8(((i32(left_mode) + 31) % 32) + 2)
		} else {
			out[0] = 0
			out[1] = 1
			out[2] = 26
		}
	} else {
		out[0] = left_mode
		out[1] = above_mode
		if left_mode != 0 && above_mode != 0 {
			out[2] = 0
		} else {
			out[2] = i32(left_mode) + i32(above_mode) < 2 ? 26 : 1
		}
	}
}

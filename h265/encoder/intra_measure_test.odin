package h265_encoder

import "core:testing"

// Frozen pre-consumer scalar equations form an independent oracle. They use
// scalar publication, substitution and a triangular transpose, never SIMD
// lane emission, score-source orientation, or the production consumer.
@(private)
intra_oracle_filter_reference :: proc(log2_width: int, refs: ^Intra_Refs) #no_bounds_check {
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


@(private)
intra_oracle_angular_pred :: proc(
	log2_width: int,
	intra_mode: u8,
	ref_top, ref_left: []Sample,
	dst: []Sample,
	stride: int,
) #no_bounds_check {
	MODE_DISP_TO_SAMPLE := [9]i32{0, 2, 5, 9, 13, 17, 21, 26, 32}
	MODE_DISP_TO_INV := [9]i32{0, 4096, 1638, 910, 630, 482, 390, 315, 256}

	width := 1 << uint(log2_width)
	mode := i32(intra_mode)
	vertical_mode := mode >= 18
	mode_disp := vertical_mode ? mode - 26 : 10 - mode
	sample_disp := (mode_disp < 0 ? -1 : 1) * MODE_DISP_TO_SAMPLE[abs(mode_disp)]

	tmp_ref: [2 * 32]Sample
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

	if sample_disp != 0 {
		delta_pos := i32(0)
		for y in 0 ..< width {
			delta_pos += sample_disp
			delta_int := int(delta_pos >> 5)
			delta_fract := int(delta_pos & 31)

			if delta_fract != 0 {
				for x in 0 ..< width {
					r1 := i32(ref_main[ref_main_off + x + delta_int])
					r2 := i32(ref_main[ref_main_off + x + delta_int + 1])
					dst[y * stride + x] = Sample(
						((i32(32 - delta_fract)) * r1 + i32(delta_fract) * r2 + 16) >> 5,
					)
				}
			} else {
				for x in 0 ..< width {
					dst[y * stride + x] = ref_main[ref_main_off + x + delta_int]
				}
			}
		}
	} else {
		for y in 0 ..< width {
			for x in 0 ..< width {
				dst[y * stride + x] = ref_main[ref_main_off + x]
			}
		}
	}

	if !vertical_mode {

		for y in 0 ..< width - 1 do for x in y + 1 ..< width do dst[y * stride + x], dst[x * stride + y] = dst[x * stride + y], dst[y * stride + x]
	}
}


@(private)
intra_oracle_pred_planar :: proc(
	log2_width: int,
	ref_top, ref_left: []Sample,
	dst: []Sample,
	stride: int,
) #no_bounds_check {
	width := 1 << uint(log2_width)
	top_right := ref_top[width + 1]
	bottom_left := ref_left[width + 1]

	top: [32]i32
	for i in 0 ..< width {
		top[i] = i32(ref_top[i + 1]) << uint(log2_width)
	}
	for y in 0 ..< width {
		hor := (i32(ref_left[y + 1]) << uint(log2_width)) + i32(width)
		for x in 0 ..< width {
			hor += i32(top_right) - i32(ref_left[y + 1])
			top[x] += i32(bottom_left) - i32(ref_top[x + 1])
			dst[y * stride + x] = Sample((hor + top[x]) >> uint(log2_width + 1))
		}
	}
}


@(private)
intra_oracle_pred_filtered_dc :: proc(
	log2_width: int,
	ref_top, ref_left: []Sample,
	dst: []Sample,
	stride: int,
) #no_bounds_check {
	width := 1 << uint(log2_width)
	sum: i32
	for i in 0 ..< width {
		sum += i32(ref_top[i + 1]) + i32(ref_left[i + 1])
	}
	dc_val := Sample((sum + i32(width)) >> uint(log2_width + 1))

	dst[0] = Sample((i32(ref_left[1]) + 2 * i32(dc_val) + i32(ref_top[1]) + 2) / 4)
	for x in 1 ..< width {
		dst[x] = Sample((i32(ref_top[x + 1]) + 3 * i32(dc_val) + 2) / 4)
	}
	for y in 1 ..< width {
		dst[y * stride] = Sample((i32(ref_left[y + 1]) + 3 * i32(dc_val) + 2) / 4)
		for x in 1 ..< width {
			dst[y * stride + x] = dc_val
		}
	}
}

@(private)
intra_oracle_pred_dc :: proc(
	log2_width: int,
	ref_top, ref_left: []Sample,
	dst: []Sample,
	stride: int,
) #no_bounds_check {
	width := 1 << uint(log2_width)
	sum: i32
	for i in 0 ..< width {
		sum += i32(ref_top[i + 1]) + i32(ref_left[i + 1])
	}
	dc_val := Sample((sum + i32(width)) >> uint(log2_width + 1))
	for y in 0 ..< width {
		for x in 0 ..< width {
			dst[y * stride + x] = dc_val
		}
	}
}

@(private)
intra_oracle_post_process_angular :: proc(
	width, stride: int,
	ref: []Sample,
	dst: []Sample,
	max_v: i32,
) #no_bounds_check {
	ref2 := i32(ref[0])
	for i in 0 ..< width {
		val := i32(dst[i * stride])
		ref1 := i32(ref[i + 1])
		dst[i * stride] = Sample(clamp(val + ((ref1 - ref2) >> 1), 0, max_v))
	}
}

// Reference smoothing also applies to chroma at 4:4:4. DC and angular
// boundary smoothing remain luma-only (8.4.4.2.5 and 8.4.4.2.6).
intra_oracle_intra_predict :: proc(
	refs: ^Intra_Refs,
	log2_width: int,
	mode: u8,
	color: Color,
	dst: []Sample,
	stride: int,
	bit_depth: int,
	layout: Chroma_Layout = .YUV_420,
) #no_bounds_check {
	width := 1 << uint(log2_width)

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
		intra_oracle_filter_reference(log2_width, refs)
	}
	top := use_filtered ? refs.filtered_top[:] : refs.top[:]
	left := use_filtered ? refs.filtered_left[:] : refs.left[:]

	switch mode {
	case 0:
		intra_oracle_pred_planar(log2_width, top, left, dst, stride)
	case 1:
		if color == .Y && width < 32 {
			intra_oracle_pred_filtered_dc(log2_width, top, left, dst, stride)
		} else {
			intra_oracle_pred_dc(log2_width, top, left, dst, stride)
		}
	case:
		intra_oracle_angular_pred(log2_width, mode, top, left, dst, stride)
		if color == .Y && width < 32 {
			max_v := i32(1) << uint(bit_depth) - 1

			if mode == 10 {
				intra_oracle_post_process_angular(width, 1, top, dst, max_v)
			} else if mode == 26 {
				intra_oracle_post_process_angular(width, stride, left, dst, max_v)
			}
		}
	}
}


Intra_Oracle_Case :: struct {
	color:  Color,
	layout: Chroma_Layout,
}

@(test)
test_intra_prediction_consumers_scalar_oracle :: proc(t: ^testing.T) {
	cases := [3]Intra_Oracle_Case{{.Y, .YUV_420}, {.U, .YUV_420}, {.V, .YUV_444}}
	source: [32 * 43 + 41]Sample
	published: [32 * 43 + 41]Sample
	oriented: [32 * 32 + 11]Sample
	state: u32 = 0x13579BDF
	// 6720 controls cover all modes, both native depths, each prediction
	// width, reference smoothing admission, gradient clipping and row padding.
	for n in ([4]int{4, 8, 16, 32}) do for depth in ([2]int{8, 10}) do for pattern in 0 ..< 4 {
		max_v := (1 << uint(depth)) - 1
		refs: Intra_Refs
		for &value, index in refs.top {
			state ~= state << 13
			state ~= state >> 17
			state ~= state << 5
			value = Sample(state & u32(max_v))
			refs.left[index] = Sample((int(value) * 17 + index * 43) & max_v)
			if pattern == 0 do value, refs.left[index] = 0, 0
			if pattern == 1 do value, refs.left[index] = Sample(max_v), Sample(max_v)
			if pattern == 2 do value, refs.left[index] = Sample((index & 1) * max_v), Sample(((index + 1) & 1) * max_v)
		}
		refs.left[0] = refs.top[0]
		for &value in refs.filtered_top do value = 0xBEEF
		for &value in refs.filtered_left do value = 0xDEAD
		for padding in ([2]int{0, 7}) {
			source_stride, dst_stride := n + padding, n + padding + 3
			source_start :: 3
			dst_start :: 5
			for &value, index in source do value = Sample((index * 31 + index * index * 7 + 193) & max_v)
			for &value in published do value = 0x7139
			source_before := source
			for mode in 0 ..< 35 do for c in cases {
				want, got := published, published
				oracle_refs, publish_refs, measure_refs, both_refs := refs, refs, refs, refs
				src := source[source_start:source_start + (n - 1) * source_stride + n]
				dst := got[dst_start:dst_start + (n - 1) * dst_stride + n]
				intra_oracle_intra_predict(&oracle_refs, log2_size(n), u8(mode), c.color, want[dst_start:dst_start + (n - 1) * dst_stride + n], dst_stride, depth, c.layout)
				intra_predict(&publish_refs, log2_size(n), u8(mode), c.color, dst, dst_stride, depth, c.layout)
				for value, index in got {
					if value != want[index] {
						testing.expectf(t, false, "intra publish n=%d depth=%d mode=%d color=%v layout=%v pattern=%d padding=%d index=%d got=%d want=%d", n, depth, mode, c.color, c.layout, pattern, padding, index, value, want[index])
						return
					}
				}
				expected: u64
				for y in 0 ..< n do for x in 0 ..< n {
					d := i32(src[y * source_stride + x]) - i32(want[dst_start + y * dst_stride + x])
					expected += u64(d * d)
				}
				score_source, score_stride := src, source_stride
				if mode >= 2 && mode < 18 {
					for &value in oriented do value = 0x5197
					// Independent coordinate definition, not the register transpose.
					for y in 0 ..< n do for x in 0 ..< n do oriented[y * n + x] = src[x * source_stride + y]
					score_source, score_stride = oriented[:n * n], n
				}
				measured := intra_measure(&measure_refs, log2_size(n), u8(mode), c.color, score_source, score_stride, depth, c.layout)
				testing.expect_value(t, measured, expected)
				got = published
				both: u64
				if n == 4 {
					both = intra_predict_consume(true, true, 4, &both_refs, log2_size(n), u8(mode), c.color, got[dst_start:dst_start + (n - 1) * dst_stride + n], dst_stride, score_source, score_stride, depth, c.layout)
				} else {
					both = intra_predict_consume(true, true, 8, &both_refs, log2_size(n), u8(mode), c.color, got[dst_start:dst_start + (n - 1) * dst_stride + n], dst_stride, score_source, score_stride, depth, c.layout)
				}
				testing.expect_value(t, both, expected)
				for value, index in got do testing.expect_value(t, value, want[index])
				for value, index in source do testing.expect_value(t, value, source_before[index])
				for index in 0 ..< INTRA_REF_LEN {
					testing.expect_value(t, measure_refs.top[index], refs.top[index])
					testing.expect_value(t, measure_refs.left[index], refs.left[index])
					testing.expect_value(t, measure_refs.filtered_top[index], oracle_refs.filtered_top[index])
					testing.expect_value(t, measure_refs.filtered_left[index], oracle_refs.filtered_left[index])
				}
			}
		}
	}
}

@(test)
test_intra_source_transpose_prefix_and_guards :: proc(t: ^testing.T) {
	source: [32 * 41 + 39]Sample
	dst: [32 * 32 + 29]Sample
	for n in ([4]int{4, 8, 16, 32}) do for padding in ([3]int{0, 1, 9}) {
		stride := n + padding
		for &value, index in source do value = Sample((index * 73 + index * index * 11 + 0x5139) & 0xffff)
		for &value in dst do value = 0xE913
		src_start :: 3
		dst_start :: 7
		want := dst
		for y in 0 ..< n do for x in 0 ..< n do want[dst_start + y * n + x] = source[src_start + x * stride + y]
		source_before := source
		transpose_intra_source(source[src_start:src_start + (n - 1) * stride + n], stride, n, dst[dst_start:dst_start + n * n])
		for value, index in dst do testing.expect_value(t, value, want[index])
		for value, index in source do testing.expect_value(t, value, source_before[index])
	}
}

intra_oracle_consider :: proc(costs: ^[35]u64, mode: u8, tried: ^[35]bool, best: ^Intra_Mode) {
	if tried[mode] do return
	tried[mode] = true
	if costs[mode] < best.sse do best^ = {
		mode = mode,
		sse  = costs[mode],
	}
}

@(test)
test_intra_search_modes_and_borrowed_references :: proc(t: ^testing.T) {
	source, reconstruction: [64 * 64]Sample
	cells: [16 * 16]Cu_Info
	enc: Encoder
	enc.coded_width, enc.coded_height = 64, 64
	enc.ctu_cols, enc.ctu_rows = 1, 1
	enc.source = {
		y = {data = source[:], stride = 64},
		coded_width = 64,
		coded_height = 64,
	}
	enc.rec = {
		y = {data = reconstruction[:], stride = 64},
		coded_width = 64,
		coded_height = 64,
	}
	enc.cu = {
		cells = cells[:],
		cols  = 16,
	}
	enc.config.forced_mode = -1
	for &cell, index in cells do cell = {
		type = .Intra,
		mode = index % 3 == 0 ? 10 : 26,
	}
	predicted: [32 * 32]Sample
	costs: [35]u64
	for depth in ([2]int{8, 10}) do for pattern in 0 ..< 4 {
		enc.bit_depth = depth
		max_v := (1 << uint(depth)) - 1
		for &value, index in source {
			value = Sample((index * 17 + index / 64 * 31 + index * index * 3) & max_v)
			reconstruction[index] = Sample((index * 29 + index / 64 * 7 + 113) & max_v)
			if pattern == 0 do value, reconstruction[index] = 0, 0
			if pattern == 1 do value, reconstruction[index] = Sample(max_v), Sample(max_v)
			if pattern == 2 do value, reconstruction[index] = Sample((index & 1) * max_v), Sample(((index + index / 64) & 1) * max_v)
		}
		for n in ([3]int{8, 16, 32}) do for position in 0 ..< 3 {
			x := position == 0 ? 0 : 32
			y := position == 2 ? 32 : 0
			refs: Intra_Refs
			build_reference(&enc, &enc.rec, x, y, log2_size(n), .Y, &refs, depth)
			for mode in 0 ..< 35 {
				oracle_refs := refs
				intra_oracle_intra_predict(&oracle_refs, log2_size(n), u8(mode), .Y, predicted[:n * n], n, depth)
				costs[mode] = 0
				for py in 0 ..< n do for px in 0 ..< n {
					d := i32(source[(y + py) * 64 + x + px]) - i32(predicted[py * n + px])
					costs[mode] += u64(d * d)
				}
			}
			want := Intra_Mode {
				sse = max(u64),
			}
			tried: [35]bool
			if n == 8 {
				for mode in 0 ..< 35 do intra_oracle_consider(&costs, u8(mode), &tried, &want)
			} else {
				mpm: [3]u8
				get_mpm_predictors(&enc, x, y, &mpm)
				for mode in mpm do intra_oracle_consider(&costs, mode, &tried, &want)
				intra_oracle_consider(&costs, 0, &tried, &want)
				intra_oracle_consider(&costs, 1, &tried, &want)
				for mode in ([5]u8{2, 10, 18, 26, 34}) do intra_oracle_consider(&costs, mode, &tried, &want)
				for step in ([3]i32{4, 2, 1}) {
					center := i32(want.mode)
					if center < 2 do break
					for delta in ([2]i32{-step, step}) {
						mode := center + delta
						if mode >= 2 && mode <= 34 do intra_oracle_consider(&costs, u8(mode), &tried, &want)
					}
				}
			}
			inputs: Intra_Search_Inputs = ---
			got := choose_intra_mode(&enc, x, y, n, &inputs)
			testing.expect_value(t, got.mode, want.mode)
			testing.expect_value(t, got.sse, want.sse)
			// The admitted leaf borrows this same reference snapshot. Its
			// published winning pixels equal a fresh scalar prediction.
			oracle_refs := refs
			intra_oracle_intra_predict(&oracle_refs, log2_size(n), got.mode, .Y, predicted[:n * n], n, depth)
			published: [32 * 32]Sample = ---
			intra_predict(&inputs.refs, log2_size(n), got.mode, .Y, published[:n * n], n, depth)
			for value, index in published[:n * n] do testing.expect_value(t, value, predicted[index])
			enc.config.forced_mode = 17
			forced := choose_intra_mode(&enc, x, y, n, &inputs)
			testing.expect_value(t, forced.mode, 17)
			testing.expect_value(t, forced.sse, 0)
			testing.expect(t, !inputs.transpose_ready)
			enc.config.forced_mode = -1
		}
	}
}

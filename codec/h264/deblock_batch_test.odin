package h264

import "core:slice"
import "core:testing"

// Independent strengths use decoded fields and coordinate-derived block pairs.
// The normative arithmetic is H.264 (06/2026) 8.7.2.1 and 8.7.2.2.
@(private)
deblock_oracle_fields :: proc(m: #soa^#soa[]Macroblock) -> Deblock_Facts_Oracle {
	return {
		intra = m.is_intra,
		transform8 = m.uses_8x8_transform,
		group_coded = m.has_8x8_coefficients,
		counts = m.nonzero_coefficient_counts,
		directions = m.prediction_directions,
		pictures = m.reference_picture_ids,
		motion = m.motion_vectors,
	}
}

@(private)
deblock_oracle_admitted_strengths :: proc(
	blocks: #soa[]Macroblock,
	columns, x, y, orientation, edge: int,
) -> [4]u8 {
	q := &blocks[y * columns + x]
	if q.deblocking_mode == .Disabled do return {}
	uncoded :=
		!q.is_intra &&
		q.luma_coded_block_mask == 0 &&
		q.chroma_residual_mode == .None &&
		q.has_uniform_motion
	p := q
	if edge == 0 {
		if (orientation == 0 ? x == 0 : y == 0) do return {}
		p = &blocks[y * columns + x - (orientation == 0 ? 1 : columns)]
		if q.deblocking_mode == .Within_Slice && p.slice_index != q.slice_index do return {}
		if uncoded && !p.is_intra && p.luma_coded_block_mask == 0 && p.chroma_residual_mode == .None && p.has_uniform_motion && p.prediction_directions[0] == q.prediction_directions[0] && p.reference_picture_ids == q.reference_picture_ids && p.motion_vectors[0][0] == q.motion_vectors[0][0] && p.motion_vectors[1][0] == q.motion_vectors[1][0] do return {}
	} else if uncoded || (q.uses_8x8_transform && edge % 2 == 1) {
		return {}
	}
	p_fields, q_fields := deblock_oracle_fields(p), deblock_oracle_fields(q)
	return deblock_facts_old_strengths(&p_fields, &q_fields, edge, orientation == 0)
}

@(private)
deblock_oracle_params :: proc(
	p, q: #soa^#soa[]Macroblock,
	chroma_offset: i32,
	chroma: bool,
	bs: [4]u8,
) -> (
	alpha, beta: i32,
	tc: [4]i8,
) {
	p_qp, q_qp := p.type == .I_PCM ? 0 : i32(p.quantizer), q.type == .I_PCM ? 0 : i32(q.quantizer)
	if chroma {
		p_qp = i32(chroma_qp_table[clamp(p_qp + chroma_offset, 0, 51)])
		q_qp = i32(chroma_qp_table[clamp(q_qp + chroma_offset, 0, 51)])
	}
	average := (p_qp + q_qp + 1) / 2
	a, b :=
		clamp(average + i32(q.alpha_offset) * 2, 0, 51),
		clamp(average + i32(q.beta_offset) * 2, 0, 51)
	alpha, beta = i32(deblock_alpha_table[12 + a]), i32(deblock_beta_table[12 + b])
	for k in 0 ..< 4 do if bs[k] >= 1 && bs[k] <= 3 do tc[k] = deblock_tc0_table[12 + a][bs[k]] + (chroma ? 1 : 0)
	return
}

// Only the unchanged normative pixel kernels are shared. This retains the old
// raster/vertical-then-horizontal owner, independent per-edge QP preparation,
// and corrected per-plane admission rather than the new MB preparation path.
@(private)
deblock_oracle_picture :: proc(
	blocks: #soa[]Macroblock,
	buffer: ^YUV_Buffer,
	columns, rows: int,
	offsets: [2]i32,
) {
	for y in 0 ..< rows do for x in 0 ..< columns {
		q := &blocks[y * columns + x]
		for orientation in 0 ..< 2 do for edge in 0 ..< 4 {
			bs := deblock_oracle_admitted_strengths(blocks, columns, x, y, orientation, edge)
			if bs == ([4]u8{}) do continue
			p := edge == 0 ? &blocks[y * columns + x - (orientation == 0 ? 1 : columns)] : q
			alpha, beta, tc := deblock_oracle_params(p, q, 0, false, bs)
			pixel := &buffer.y[(y * 16) * buffer.y_stride + x * 16 + (orientation == 0 ? edge * 4 : edge * 4 * buffer.y_stride)]
			if alpha != 0 && beta != 0 {
				if orientation == 0 do deblock_luma_vertical(pixel, buffer.y_stride, alpha, beta, bs, tc)
				else do deblock_luma_horizontal(pixel, buffer.y_stride, alpha, beta, bs, tc)
			}
			if edge % 2 != 0 do continue
			for plane in 0 ..< 2 {
				ca, cb, ct := deblock_oracle_params(p, q, offsets[plane], true, bs)
				if ca == 0 || cb == 0 do continue
				pixels := plane == 0 ? buffer.u : buffer.v
				cp := &pixels[(y * 8) * buffer.uv_stride + x * 8 + (orientation == 0 ? edge * 2 : edge * 2 * buffer.uv_stride)]
				if orientation == 0 do deblock_chroma_vertical(cp, buffer.uv_stride, ca, cb, bs, ct)
				else do deblock_chroma_horizontal(cp, buffer.uv_stride, ca, cb, bs, ct)
			}
		}
	}
}

@(private)
deblock_batch_seed :: proc(blocks: #soa[]Macroblock, seed: ^u32) {
	for index in 0 ..< len(blocks) {
		m := &blocks[index]
		m^ = {}
		m.is_intra = deblock_facts_random(seed) % 7 == 0
		m.type = deblock_facts_random(seed) % 13 == 0 ? .I_PCM : .P_L0_16x16
		m.quantizer = i8(deblock_facts_random(seed) % 52)
		m.alpha_offset = i8(int(deblock_facts_random(seed) % 13) - 6)
		m.beta_offset = i8(int(deblock_facts_random(seed) % 13) - 6)
		m.deblocking_mode = Deblocking_Mode(deblock_facts_random(seed) % 3)
		m.slice_index = u16(deblock_facts_random(seed) % 3)
		m.uses_8x8_transform = deblock_facts_random(seed) & 1 != 0
		m.has_uniform_motion = deblock_facts_random(seed) % 5 == 0
		m.luma_coded_block_mask = u8(deblock_facts_random(seed) % 16)
		m.chroma_residual_mode = Chroma_Residual_Mode(deblock_facts_random(seed) % 3)
		for group in 0 ..< 4 {
			m.has_8x8_coefficients[group] = deblock_facts_random(seed) % 3 == 0
			m.prediction_directions[group] = Prediction_Direction(deblock_facts_random(seed) % 4)
			for list in 0 ..< 2 do m.reference_picture_ids[list][group] = i32(deblock_facts_random(seed) % 5) * 65536 + 1
		}
		for sub in 0 ..< 16 {
			m.nonzero_coefficient_counts[sub] =
				deblock_facts_random(seed) % 5 == 0 ? u8(1 + deblock_facts_random(seed) % 16) : 0
			for list in 0 ..< 2 do for component in 0 ..< 2 do m.motion_vectors[list][sub][component] = i16(deblock_facts_random(seed) & 65535)
		}
	}
}

@(test)
test_deblock_preparation_matches_independent_metadata_and_pixel_order :: proc(t: ^testing.T) {
	blocks := make(#soa[]Macroblock, 9)
	defer delete(blocks)
	actual, expected := alloc_yuv_buffer(48, 48), alloc_yuv_buffer(48, 48)
	defer free_yuv_buffer(&actual)
	defer free_yuv_buffer(&expected)
	seed: u32 = 0x895dd614
	data: Deblock_MB_Data
	for _ in 0 ..< 256 {
		deblock_batch_seed(blocks, &seed)
		offsets := [2]i32 {
			i32(deblock_facts_random(&seed) % 25) - 12,
			i32(deblock_facts_random(&seed) % 25) - 12,
		}
		for y in 0 ..< 3 do for x in 0 ..< 3 {
			prepare_deblock_mb(&data, blocks, offsets, 3, x, y)
			for orientation in 0 ..< 2 do for edge in 0 ..< 4 {
				testing.expect_value(t, data.strengths[orientation][edge], deblock_oracle_admitted_strengths(blocks, 3, x, y, orientation, edge))
			}
		}
		for &v in actual.memory do v = u8(96 + deblock_facts_random(&seed) % 17)
		copy(expected.memory, actual.memory)
		deblock_oracle_picture(blocks, &expected, 3, 3, offsets)
		deblock_picture(blocks, &actual, 3, 3, offsets)
		testing.expect(
			t,
			slice.equal(actual.memory, expected.memory),
			"full coded planes and padding must match independent raster V/H oracle",
		)
	}
	// Disabled and border+uncoded admission must precede all pixel-buffer reads.
	blocks[0] = {}
	blocks[0].deblocking_mode = .Disabled
	deblock_picture(blocks[:1], nil, 1, 1, {})
	blocks[0].deblocking_mode = .All_Edges
	blocks[0].has_uniform_motion = true
	deblock_picture(blocks[:1], nil, 1, 1, {})
}

@(test)
test_deblock_uncoded_internal_lanes_match_independent_geometry :: proc(t: ^testing.T) {
	blocks := make(#soa[]Macroblock, 1)
	defer delete(blocks)
	// Keep every coded override and uniform shortcut off. These patterns must
	// therefore expose the sixteen-lane motion/ref matching owner itself.
	steps := [8]i32{-32768, -4, -3, 0, 3, 4, 32764, 32767}
	data: Deblock_MB_Data
	for direction in 0 ..< 8 do for reference_case in 0 ..< 6 {
		for component in 0 ..< 2 do for a in steps do for b in steps {
			old: Deblock_Facts_Oracle
			for group in 0 ..< 4 {
				old.directions[group] = Prediction_Direction(direction < 4 ? direction : (group + direction) % 4)
				old.pictures[0][group], old.pictures[1][group] = 1, 257
				if reference_case == 1 && group % 2 != 0 {
					old.pictures[0][group], old.pictures[1][group] = 257, 1
				} else if reference_case == 2 {
					old.pictures[1][group] = 1 // duplicate refs: either MV order may match
				} else if reference_case == 3 && group % 2 != 0 {
					old.pictures[0][group], old.pictures[1][group] = 65537, 257
				} else if reference_case == 4 && group / 2 != 0 {
					old.pictures[0][group], old.pictures[1][group] = 257, 65537
				} else if reference_case == 5 {
					old.pictures[0][group], old.pictures[1][group] = -2147483648, 2147483647
				}
			}
			for y in 0 ..< 4 do for x in 0 ..< 4 {
				sub := (x / 2 + 2 * (y / 2)) * 4 + x % 2 + 2 * (y % 2)
				// Checkerboard small/extreme differences cross every V/H seam.
				old.motion[0][sub][component] = i16((x + y) % 2 == 0 ? a : b)
				old.motion[1][sub][component] = i16((x + y) % 2 == 0 ? b : a)
			}
			blocks[0] = {}
			blocks[0].deblocking_mode = .All_Edges
			deblock_facts_publish_oracle(&blocks[0], &old)
			prepare_deblock_mb(&data, blocks, {}, 1, 0, 0)
			for orientation in 0 ..< 2 do for edge in 1 ..< 4 {
				testing.expect_value(t, data.strengths[orientation][edge], deblock_facts_old_strengths(&old, &old, edge, orientation == 0))
			}
		}
	}
	// Duplicate refs must also accept direct-only matching, independently of
	// the crossed-only checkerboard cases above.
	old: Deblock_Facts_Oracle
	for group in 0 ..< 4 {
		old.directions[group] = .Bidirectional
		old.pictures[0][group], old.pictures[1][group] = 1, 1
	}
	for sub in 0 ..< 16 do old.motion[1][sub] = {16, 0}
	blocks[0] = {}
	blocks[0].deblocking_mode = .All_Edges
	deblock_facts_publish_oracle(&blocks[0], &old)
	prepare_deblock_mb(&data, blocks, {}, 1, 0, 0)
	testing.expect_value(t, data.strengths, [2][4][4]u8{})
}

@(test)
test_deblock_motion_extremes_full_ids_and_reference_matching :: proc(t: ^testing.T) {
	blocks := make(#soa[]Macroblock, 2)
	defer delete(blocks)
	components := [8]i16{-32768, -32765, -4, -3, 0, 3, 4, 32767}
	ids := [5]i32{-2147483648, 1, 257, 65537, 2147483647}
	for pd in 0 ..< 4 do for qd in 0 ..< 4 do for component in 0 ..< 2 {
		for a in components do for b in components do for order in 0 ..< 4 {
			old: [2]Deblock_Facts_Oracle
			for i in 0 ..< 2 do for group in 0 ..< 4 {
				old[i].directions[group] = Prediction_Direction(i == 0 ? pd : qd)
				old[i].pictures[0][group] = ids[order]
				old[i].pictures[1][group] = order == 3 ? ids[order] : ids[order + 1]
			}
			for sub in 0 ..< 16 {
				old[0].motion[0][sub][component], old[1].motion[0][sub][component] = a, b
				old[0].motion[1][sub][component], old[1].motion[1][sub][component] = b, a
			}
			if order & 1 != 0 do old[1].pictures[0], old[1].pictures[1] = old[1].pictures[1], old[1].pictures[0]
			for i in 0 ..< 2 do deblock_facts_publish_oracle(&blocks[i], &old[i])
			testing.expect_value(t, edge_strengths(&blocks[0], &blocks[1], 0, true), deblock_facts_old_strengths(&old[0], &old[1], 0, true))
		}
	}
	// Full picture identities must never be narrowed to 8 or 16 bits.
	for id in ([2]i32{257, 65537}) {
		for i in 0 ..< 2 {
			blocks[i] = {}
			blocks[i].prediction_directions = {.List_0, .List_0, .List_0, .List_0}
			blocks[i].reference_picture_ids[0] = {1, 1, 1, 1}
		}
		blocks[1].reference_picture_ids[0] = {id, id, id, id}
		testing.expect_value(t, edge_strengths(&blocks[0], &blocks[1], 0, true), [4]u8{1, 1, 1, 1})
	}
}

@(test)
test_deblock_chroma_admission_is_independent_of_zero_luma_thresholds :: proc(t: ^testing.T) {
	blocks := make(#soa[]Macroblock, 2)
	defer delete(blocks)
	buffer := alloc_yuv_buffer(32, 16)
	defer free_yuv_buffer(&buffer)
	for strong in ([2]bool{false, true}) {
		for i in 0 ..< 2 {
			blocks[i] = {}
			blocks[i].quantizer = 15
			blocks[i].is_intra = strong
			blocks[i].deblocking_mode = .All_Edges
			blocks[i].luma_coded_block_mask = 15
			for sub in 0 ..< 16 do blocks[i].nonzero_coefficient_counts[sub] = 1
		}
		for y in 0 ..< 16 do for x in 0 ..< 32 do buffer.y[y * buffer.y_stride + x] = x < 16 ? 100 : 104
		for y in 0 ..< 8 do for x in 0 ..< 16 {
			buffer.u[y * buffer.uv_stride + x] = x < 8 ? 100 : 104
			buffer.v[y * buffer.uv_stride + x] = x < 8 ? 100 : 104
		}
		deblock_picture(blocks, &buffer, 2, 1, {12, -12})
		for y in 0 ..< 16 do for x in 0 ..< 32 do testing.expect_value(t, buffer.y[y * buffer.y_stride + x], u8(x < 16 ? 100 : 104))
		for y in 0 ..< 8 {
			testing.expect_value(t, buffer.u[y * buffer.uv_stride + 7], u8(strong ? 101 : 102))
			testing.expect_value(t, buffer.u[y * buffer.uv_stride + 8], u8(strong ? 103 : 102))
			testing.expect_value(t, buffer.v[y * buffer.uv_stride + 7], u8(100))
			testing.expect_value(t, buffer.v[y * buffer.uv_stride + 8], u8(104))
		}
	}
}

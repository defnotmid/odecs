package h264

import "core:testing"

// The independent input representation is test-only. An 8x8 coded flag
// is independent of the four CAVLC counts: one nonzero interleaved block
// makes every 4x4 boundary in that transform group coded for deblocking.
@(private)
Deblock_Facts_Oracle :: struct {
	intra, transform8: bool,
	group_coded:       [4]bool,
	counts:            [32]u8,
	directions:        [4]Prediction_Direction,
	pictures:          [2][4]i32,
	motion:            [2][16][2]i16,
}

@(private)
deblock_facts_publish_oracle :: proc(dst: #soa^#soa[]Macroblock, src: ^Deblock_Facts_Oracle) {
	dst.is_intra, dst.uses_8x8_transform = src.intra, src.transform8
	dst.has_8x8_coefficients = src.group_coded
	dst.nonzero_coefficient_counts = src.counts
	dst.prediction_directions = src.directions
	dst.reference_picture_ids = src.pictures
	dst.motion_vectors = src.motion
}

@(private)
deblock_facts_old_strengths :: proc(
	p, q: ^Deblock_Facts_Oracle,
	edge: int,
	vertical: bool,
) -> (
	result: [4]u8,
) {
	if p.intra || q.intra {
		value: u8 = edge == 0 ? 4 : 3
		return {value, value, value, value}
	}
	for lane in 0 ..< 4 {
		// Derive geometry independently of production's edge_blocks table.
		px, py := vertical ? (edge + 3) % 4 : lane, vertical ? lane : (edge + 3) % 4
		qx, qy := vertical ? edge : lane, vertical ? lane : edge
		ps := (px / 2 + 2 * (py / 2)) * 4 + px % 2 + 2 * (py % 2)
		qs := (qx / 2 + 2 * (qy / 2)) * 4 + qx % 2 + 2 * (qy % 2)
		if (p.transform8 ? p.group_coded[ps / 4] : p.counts[ps] > 0) ||
		   (q.transform8 ? q.group_coded[qs / 4] : q.counts[qs] > 0) {
			result[lane] = 2
			continue
		}
		pd, qd := p.directions[ps / 4], q.directions[qs / 4]
		if pd != .Bidirectional && qd != .Bidirectional {
			pl, ql := pd == .List_0 ? 0 : 1, qd == .List_0 ? 0 : 1
			if p.pictures[pl][ps / 4] != q.pictures[ql][qs / 4] ||
			   abs(i32(p.motion[pl][ps][0]) - i32(q.motion[ql][qs][0])) >= 4 ||
			   abs(i32(p.motion[pl][ps][1]) - i32(q.motion[ql][qs][1])) >= 4 {result[lane] = 1}
			continue
		}
		if pd != qd {result[lane] = 1; continue}
		p0, p1 := p.pictures[0][ps / 4], p.pictures[1][ps / 4]
		q0, q1 := q.pictures[0][qs / 4], q.pictures[1][qs / 4]
		same, swapped := p0 == q0 && p1 == q1, p0 == q1 && p1 == q0
		if !same && !swapped {result[lane] = 1; continue}
		matching: [2]bool
		for order in 0 ..< 2 {
			matching[order] = true
			for list in 0 ..< 2 {
				other := order == 0 ? list : 1 - list
				if abs(i32(p.motion[list][ps][0]) - i32(q.motion[other][qs][0])) >= 4 ||
				   abs(i32(p.motion[list][ps][1]) - i32(q.motion[other][qs][1])) >=
					   4 {matching[order] = false}
			}
		}
		if p0 != p1 {
			result[lane] = (same ? matching[0] : matching[1]) ? 0 : 1
		} else {
			result[lane] = matching[0] || matching[1] ? 0 : 1
		}
	}
	return
}

@(private)
deblock_facts_random :: proc(seed: ^u32) -> u32 {
	seed^ = seed^ * 1664525 + 1013904223
	return seed^ >> 8
}

@(test)
test_deblock_strengths_match_independent_geometry_and_reference_oracle :: proc(t: ^testing.T) {
	blocks := make(#soa[]Macroblock, 2)
	defer delete(blocks)
	seed: u32 = 0x942ad57b
	for trial in 0 ..< 4096 {
		old: [2]Deblock_Facts_Oracle
		for &m in old {
			m.intra = deblock_facts_random(&seed) % 17 == 0
			m.transform8 = deblock_facts_random(&seed) & 1 != 0
			for k in 0 ..< 4 {
				m.group_coded[k] = deblock_facts_random(&seed) % 4 == 0
				m.directions[k] = Prediction_Direction(deblock_facts_random(&seed) % 4)
				for list in 0 ..< 2 do m.pictures[list][k] = i32(deblock_facts_random(&seed) % 4) - 1
			}
			for k in 0 ..< 16 {
				m.counts[k] =
					deblock_facts_random(&seed) % 5 == 0 ? u8(1 + deblock_facts_random(&seed) % 16) : 0
				for list in 0 ..< 2 do m.motion[list][k] = {i16(int(deblock_facts_random(&seed) % 17) - 8), i16(int(deblock_facts_random(&seed) % 17) - 8)}
			}
		}
		// Give the oracle substantial equal/swap/duplicate-reference exposure,
		// including None with unequal inactive vectors: no uniform shortcut.
		if trial % 4 != 0 {
			old[1].pictures = old[0].pictures
			old[1].directions = old[0].directions
			old[1].motion = old[0].motion
			if trial % 4 == 2 {
				for k in 0 ..< 4 do old[1].pictures[0][k], old[1].pictures[1][k] = old[0].pictures[1][k], old[0].pictures[0][k]
				old[1].motion[0], old[1].motion[1] = old[0].motion[1], old[0].motion[0]
			}
			if trial % 4 == 3 do old[1].motion[1][7][0] += 4
		}
		for i in 0 ..< 2 do deblock_facts_publish_oracle(&blocks[i], &old[i])
		for vertical in ([2]bool{false, true}) do for edge in 0 ..< 4 {
			for internal in ([2]bool{false, true}) {
				p := internal ? 1 : 0
				testing.expect_value(t, edge_strengths(&blocks[p], &blocks[1], edge, vertical), deblock_facts_old_strengths(&old[p], &old[1], edge, vertical))
			}
		}
	}
}

@(test)
test_deblock_8x8_coded_group_is_not_four_independent_counts :: proc(t: ^testing.T) {
	blocks := make(#soa[]Macroblock, 2)
	defer delete(blocks)
	for group in 0 ..< 4 {
		old: [2]Deblock_Facts_Oracle
		old[1].transform8 = true
		old[1].group_coded[group] = true
		// The nonzero CAVLC block may lie away from the sampled boundary;
		// an 8x8 transform nevertheless supplies coded admission to all four.
		old[1].counts[group * 4 + 3] = 1
		for i in 0 ..< 2 do deblock_facts_publish_oracle(&blocks[i], &old[i])
		for vertical in ([2]bool{false, true}) do for edge in 0 ..< 4 {
			testing.expect_value(t, edge_strengths(&blocks[0], &blocks[1], edge, vertical), deblock_facts_old_strengths(&old[0], &old[1], edge, vertical))
		}
	}
}

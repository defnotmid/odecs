package h265_decoder

import "core:testing"

// A literal scalar 8.7.2.5.3 decision and 8.7.2.5.6/7 filter of one group
// of four lines. Line l's sample i (p3..q3 for i = -4..3) is at
// plane[base + l * line + i * step].
@(private = "file")
luma_group_oracle :: proc(plane: []$Sample, base, line, step: int, g: Luma_Group, max_v: i32) {
	at :: proc(plane: []Sample, base, line, step, l, i: int) -> i32 {
		return i32(plane[base + l * line + i * step])
	}
	set :: proc(plane: []Sample, base, line, step, l, i: int, v, max_v: i32) {
		plane[base + l * line + i * step] = Sample(clamp(v, 0, max_v))
	}
	if g.tc == 0 do return
	beta, tc := g.beta, g.tc
	dp: [4]i32
	dq: [4]i32
	for l in ([2]int{0, 3}) {
		dp[l] = abs(
			at(plane, base, line, step, l, -3) -
			2 * at(plane, base, line, step, l, -2) +
			at(plane, base, line, step, l, -1),
		)
		dq[l] = abs(
			at(plane, base, line, step, l, 2) -
			2 * at(plane, base, line, step, l, 1) +
			at(plane, base, line, step, l, 0),
		)
	}
	if dp[0] + dq[0] + dp[3] + dq[3] >= beta do return
	sam :: proc(plane: []Sample, base, line, step, l: int, dpq, beta, tc: i32) -> bool {
		p3, p0 := at(plane, base, line, step, l, -4), at(plane, base, line, step, l, -1)
		q0, q3 := at(plane, base, line, step, l, 0), at(plane, base, line, step, l, 3)
		return(
			2 * dpq < beta >> 2 &&
			abs(p3 - p0) + abs(q0 - q3) < beta >> 3 &&
			abs(p0 - q0) < (5 * tc + 1) >> 1 \
		)
	}
	strong :=
		sam(plane, base, line, step, 0, dp[0] + dq[0], beta, tc) &&
		sam(plane, base, line, step, 3, dp[3] + dq[3], beta, tc)
	side := (beta + beta >> 1) >> 3
	ep, eq := dp[0] + dp[3] < side, dq[0] + dq[3] < side
	for l in 0 ..< 4 {
		p: [4]i32
		q: [4]i32
		for i in 0 ..< 4 {
			p[i] = at(plane, base, line, step, l, -1 - i)
			q[i] = at(plane, base, line, step, l, i)
		}
		if strong {
			c := 2 * tc
			np := [3]i32 {
				clamp((p[2] + 2 * p[1] + 2 * p[0] + 2 * q[0] + q[1] + 4) >> 3, p[0] - c, p[0] + c),
				clamp((p[2] + p[1] + p[0] + q[0] + 2) >> 2, p[1] - c, p[1] + c),
				clamp((2 * p[3] + 3 * p[2] + p[1] + p[0] + q[0] + 4) >> 3, p[2] - c, p[2] + c),
			}
			nq := [3]i32 {
				clamp((p[1] + 2 * p[0] + 2 * q[0] + 2 * q[1] + q[2] + 4) >> 3, q[0] - c, q[0] + c),
				clamp((p[0] + q[0] + q[1] + q[2] + 2) >> 2, q[1] - c, q[1] + c),
				clamp((p[0] + q[0] + q[1] + 3 * q[2] + 2 * q[3] + 4) >> 3, q[2] - c, q[2] + c),
			}
			for i in 0 ..< 3 {
				if !g.no_p do set(plane, base, line, step, l, -1 - i, np[i], max_v)
				if !g.no_q do set(plane, base, line, step, l, i, nq[i], max_v)
			}
			continue
		}
		delta := (9 * (q[0] - p[0]) - 3 * (q[1] - p[1]) + 8) >> 4
		if abs(delta) >= tc * 10 do continue
		delta = clamp(delta, -tc, tc)
		if !g.no_p {
			set(plane, base, line, step, l, -1, p[0] + delta, max_v)
			if ep {
				dpv := clamp((((p[2] + p[0] + 1) >> 1) - p[1] + delta) >> 1, -(tc >> 1), tc >> 1)
				set(plane, base, line, step, l, -2, p[1] + dpv, max_v)
			}
		}
		if !g.no_q {
			set(plane, base, line, step, l, 0, q[0] - delta, max_v)
			if eq {
				dqv := clamp((((q[2] + q[0] + 1) >> 1) - q[1] - delta) >> 1, -(tc >> 1), tc >> 1)
				set(plane, base, line, step, l, 1, q[1] + dqv, max_v)
			}
		}
	}
}

@(private = "file")
check_luma_lines :: proc(t: ^testing.T, $Sample: typeid, depth: int) -> bool {
	max_v := i32(1) << uint(depth) - 1
	seed: u32 = 0x5eed_0000 + u32(depth)
	next :: proc(seed: ^u32) -> u32 {seed^ = seed^ * 1664525 + 1013904223; return seed^ >> 8}
	for trial in 0 ..< 3000 {
		// A 16x16 plane with an edge through its centre: smooth ramps make
		// strong and weak decisions likely, noise and steps exercise refusals.
		plane: [16 * 16]Sample
		slope, noise := i32(next(&seed) % 9) - 4, i32(next(&seed) % 6)
		step_size := i32(next(&seed) % 40) << uint(depth - 8)
		for y in 0 ..< 16 do for x in 0 ..< 16 {
			v := max_v / 2 + slope * i32(x + y) + (x >= 8 ? step_size : 0)
			if noise != 0 do v += i32(next(&seed) % u32(noise * 2 + 1)) - noise
			plane[y * 16 + x] = Sample(clamp(v, 0, max_v))
		}
		groups: [2]Luma_Group
		for &g in groups {
			if next(&seed) % 5 == 0 do continue
			g = {
				beta = i32(next(&seed) % 65) << uint(depth - 8),
				tc   = i32(next(&seed) % 25 + 1) << uint(depth - 8),
				no_p = next(&seed) % 7 == 0,
				no_q = next(&seed) % 7 == 0,
			}
		}
		vertical := trial % 2 == 0
		base, line, step := 4 * 16 + 8, 16, 1 // vertical edge at x = 8, rows 4..11
		if !vertical do base, line, step = 8 * 16 + 4, 1, 16 // horizontal edge at y = 8
		actual, expected := plane, plane
		deblock_luma_lines(actual[:], base, line, step, &groups, depth)
		for g in 0 ..< 2 do luma_group_oracle(expected[:], base + 4 * g * line, line, step, groups[g], max_v)
		if actual != expected {
			testing.expectf(
				t,
				false,
				"%v depth %d trial %d vertical %v groups %v",
				typeid_of(Sample),
				depth,
				trial,
				vertical,
				groups,
			)
			return false
		}
	}
	return true
}

@(test)
test_luma_edge_lines_match_specification_filter :: proc(t: ^testing.T) {
	_ =
		check_luma_lines(t, u8, 8) &&
		check_luma_lines(t, u16, 8) &&
		check_luma_lines(t, u16, 10) &&
		check_luma_lines(t, u16, 12)
}

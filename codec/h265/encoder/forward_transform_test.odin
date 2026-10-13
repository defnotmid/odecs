package h265_encoder

import hevc ".."
import "core:testing"

// Independent dense matrix equations in the original coefficient-major
// intermediate layout. Widening each dot product before its i32 narrowing
// also specifies the old modular arithmetic for full-i16 stress inputs.
@(private)
forward_dense_oracle :: proc(
	basis: []i32,
	n, depth: int,
	src: []i16,
	src_stride: int,
	dst: []i16,
) {
	tmp: [1024]i32 = ---
	log2: u32
	for extent := n; extent > 1; extent /= 2 do log2 += 1
	shift1 := log2 - 1 + u32(depth - 8)
	shift2 := log2 + 6
	round1 := i64(1) << (shift1 - 1)
	round2 := i64(1) << (shift2 - 1)
	for j in 0 ..< n do for k in 0 ..< n {
		acc: i64
		for i in 0 ..< n do acc += i64(basis[k * n + i]) * i64(src[j * src_stride + i])
		tmp[k * n + j] = i32(acc + round1) >> shift1
	}
	for k in 0 ..< n do for r in 0 ..< n {
		acc: i64
		for i in 0 ..< n do acc += i64(basis[k * n + i]) * i64(tmp[r * n + i])
		dst[k * n + r] = i16(clamp(i32(acc + round2) >> shift2, -32768, 32767))
	}
}

@(private)
forward_pattern :: proc(pattern, x, y, n, depth: int, state: ^u32) -> i16 {
	limit := (1 << uint(depth)) - 1
	switch pattern {
	case 0:
		return 0
	case 1:
		return i16(limit)
	case 2:
		return i16(-limit)
	case 3:
		return (x + y) % 2 == 0 ? i16(limit) : i16(-limit)
	case 4:
		return i16((x * 127 + y * 73 + x * y * 19) % (2 * limit + 1) - limit)
	case 5:
		return x == n / 2 && y == n / 2 ? i16(-limit) : 0
	case 6:
		state^ ~= state^ << 13
		state^ ~= state^ >> 17
		state^ ~= state^ << 5
		return i16(int(state^ % u32(2 * limit + 1)) - limit)
	case 7:
		return (x + y) % 2 == 0 ? -32768 : 32767
	case:
		state^ ~= state^ << 13
		state^ ~= state^ >> 17
		state^ ~= state^ << 5
		return i16(u16(state^))
	}
}

@(test)
test_forward_dct_reflection_and_packed_basis :: proc(t: ^testing.T) {
	enc: Encoder
	// Poison inactive sidecar entries: the paired layout must not rely on
	// either the discarded matrix half or another size's retained storage.
	for &basis_storage in enc.dct_t do for &value in basis_storage do value = 0x35271945
	init_fwd_dct_t(&enc)
	for n, index in ([4]int{4, 8, 16, 32}) {
		basis := hevc.basis_for(n)
		pairs := n / 2
		for k in 0 ..< n do for i in 0 ..< n {
			sign := (k & 1) == 0 ? i32(1) : i32(-1)
			testing.expect_value(t, basis[k * n + n - 1 - i], sign * basis[k * n + i])
		}
		for parity in 0 ..< 2 do for i in 0 ..< pairs do for q in 0 ..< pairs {
			testing.expect_value(t, enc.dct_t[index][i * n + parity * pairs + q], basis[(2 * q + parity) * n + i])
		}
		for value in enc.dct_t[index][n * n / 2:] do testing.expect_value(t, value, i32(0x35271945))
	}
	for k in 0 ..< 4 do for i in 0 ..< 4 do testing.expect_value(t, enc.dct_t[4][i * 4 + k], hevc.DST_4[k * 4 + i])
}

@(test)
test_forward_transform_dense_equations_and_guards :: proc(t: ^testing.T) {
	enc: Encoder
	for &basis_storage in enc.dct_t do for &value in basis_storage do value = -0x21654379
	init_fwd_dct_t(&enc)
	source: [32 * 39 + 19]i16
	output: [1024 + 19]i16
	coefficients: [1024]i16
	state: u32 = 0x36B71D95
	// 270 complete-buffer cases include the separate DST basis, both native
	// depths, minimum source extents, padding, shifted starts and i16 extremes.
	for kind in 0 ..< 5 {
		n := kind == 4 ? 4 : (4 << uint(kind))
		basis := kind == 4 ? hevc.DST_4[:] : hevc.basis_for(n)
		for depth in ([2]int{8, 10}) do for layout in 0 ..< 3 do for pattern in 0 ..< 9 {
			stride := n + (layout == 2 ? 7 : layout)
			src_start := layout == 2 ? 11 : layout
			dst_start := layout == 2 ? 7 : layout
			for &value, index in source do value = i16((index * 137 + 0xA579) & 0xffff)
			for &value, index in output do value = i16((index * 61 + 0x517B) & 0xffff)
			for y in 0 ..< n do for x in 0 ..< n do source[src_start + y * stride + x] = forward_pattern(pattern, x, y, n, depth, &state)
			source_before := source
			want := output
			src_end := src_start + (n - 1) * stride + n
			forward_dense_oracle(basis, n, depth, source[src_start:src_end], stride, coefficients[:n * n])
			copy(want[dst_start:dst_start + n * n], coefficients[:n * n])
			if kind == 4 {
				forward_transform_dst4(&enc, source[src_start:src_end], stride, output[dst_start:dst_start + n * n], depth)
			} else {
				forward_transform(&enc, n, source[src_start:src_end], stride, output[dst_start:dst_start + n * n], depth)
			}
			for value, index in output {
				if value != want[index] {
					testing.expectf(t, false, "forward transform n=%d dst4=%t depth=%d layout=%d pattern=%d index=%d got=%d want=%d", n, kind == 4, depth, layout, pattern, index, value, want[index])
					return
				}
			}
			for value, index in source {
				if value != source_before[index] {
					testing.expectf(t, false, "forward transform changed source n=%d dst4=%t depth=%d layout=%d pattern=%d index=%d", n, kind == 4, depth, layout, pattern, index)
					return
				}
			}
		}
	}
}

@(test)
test_forward_transform_overlapping_source_output :: proc(t: ^testing.T) {
	enc: Encoder
	init_fwd_dct_t(&enc)
	input: [32 * 37 + 67]i16
	coefficients: [1024]i16
	state: u32 = 0x5D9368E7
	for kind in 0 ..< 5 {
		n := kind == 4 ? 4 : (4 << uint(kind))
		basis := kind == 4 ? hevc.DST_4[:] : hevc.basis_for(n)
		for depth in ([2]int{8, 10}) do for dst_start in ([3]int{0, 12, 49}) do for pattern in ([3]int{4, 7, 8}) {
			stride := n + 5
			src_start :: 11
			for &value, index in input do value = i16((index * 173 + 0xA753) & 0xffff)
			for y in 0 ..< n do for x in 0 ..< n do input[src_start + y * stride + x] = forward_pattern(pattern, x, y, n, depth, &state)
			got, want := input, input
			src_end := src_start + (n - 1) * stride + n
			forward_dense_oracle(basis, n, depth, input[src_start:src_end], stride, coefficients[:n * n])
			copy(want[dst_start:dst_start + n * n], coefficients[:n * n])
			if kind == 4 {
				forward_transform_dst4(&enc, got[src_start:src_end], stride, got[dst_start:dst_start + n * n], depth)
			} else {
				forward_transform(&enc, n, got[src_start:src_end], stride, got[dst_start:dst_start + n * n], depth)
			}
			for value, index in got {
				if value != want[index] {
					testing.expectf(t, false, "overlapping forward transform n=%d dst4=%t depth=%d dst_start=%d pattern=%d index=%d got=%d want=%d", n, kind == 4, depth, dst_start, pattern, index, value, want[index])
					return
				}
			}
		}
	}
}

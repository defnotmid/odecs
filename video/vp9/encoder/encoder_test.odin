package vp9_encoder

import "core:testing"
import "core:fmt"
import "core:mem"
import decoder "../decoder"
import common "../../../common"

@(test)
roundtrip :: proc(t: ^testing.T) {
	pool: common.Static_Pool
	common.init_static_pool(&pool, 3)
	defer common.destroy_static_pool(&pool)
	for size in ([][2]int{{1,1}, {7,5}, {8,8}, {17,19}, {64,64}, {65,67}, {257,73}, {513,65}}) {
		for q in ([]int{0,1,4,32,100,200,255}) {
			for block_log2 in 3 ..= 5 do if !roundtrip_case(t, &pool.work_pool, size, q, block_log2) do return
		}
	}
}

@(private = "file")
roundtrip_case :: proc(t: ^testing.T, pool: ^common.Work_Pool, size: [2]int, q, block_log2: int) -> bool {
	e: Encoder
	if !testing.expect_value(t, init_encoder(&e, {width = size[0], height = size[1], base_q_idx = q, keyframe_interval = 3, block_log2 = block_log2, tile_cols_log2 = 2, pool = pool}), .None) do return false
	defer destroy_encoder(&e)
	d: decoder.Decoder
	decoder.init_decoder(&d)
	defer decoder.destroy_decoder(&d)
	input: [3][]u8
	strides: [3]int
	for p in 0 ..< 3 {
		shift := p > 0 ? uint(1) : 0
		strides[p] = (size[0] + int(shift)) >> shift
		input[p] = make([]u8, strides[p] * ((size[1] + int(shift)) >> shift))
	}
	defer for v in input do delete(v)
	for f in 0 ..< 5 {
		for p in 0 ..< 3 do for &v, i in input[p] do v = u8((i * 17 + i / strides[p] * 23 + f * 19 + p * 31) & 255)
		packet, key, err := encode_frame(&e, input, strides)
		if !testing.expect_value(t, err, .None) || !testing.expect_value(t, key, f % 3 == 0) do return false
		pic, shown, de := decoder.decode_packet(&d, packet)
		if !testing.expect_value(t, de, .None) || !testing.expect(t, shown) do return false
		rec, rs := reconstruction(&e)
		for p in 0 ..< 3 {
			shift := p > 0 ? uint(1) : 0
			h := (size[1] + int(shift)) >> shift
			for y in 0 ..< h do for x in 0 ..< strides[p] {
				case_name := fmt.tprintf("size=%v q=%d block_log2=%d frame=%d plane=%d xy=%d,%d", size, q, block_log2, f, p, x, y)
				if rec[p][y * rs[p] + x] != pic.planes8[p][y * pic.strides[p] + x] {testing.expect(t, false, case_name); return false}
				if q == 0 && rec[p][y * rs[p] + x] != input[p][y * strides[p] + x] {testing.expect(t, false, case_name); return false}
			}
		}
	}
	return true
}

@(test)
invalid_input :: proc(t: ^testing.T) {
	e: Encoder
	testing.expect_value(t, init_encoder(&e, {width = 0, height = 10}), .Invalid_Argument)
	testing.expect_value(t, init_encoder(&e, {width = 16, height = 16}), .None)
	defer destroy_encoder(&e)
	_, _, err := encode_frame(&e, {}, {})
	testing.expect_value(t, err, .Invalid_Argument)
	plane: [256]u8
	planes := [3][]u8{plane[:], plane[:64], plane[:64]}
	// Extents whose products would wrap a 64-bit int must still be rejected.
	for strides in ([][3]int{{max(int), 8, 8}, {16, max(int), 8}, {16, 8, min(int)}, {15, 8, 8}}) {
		_, _, err = encode_frame(&e, planes, strides)
		testing.expect_value(t, err, .Invalid_Argument)
	}
	testing.expect_value(t, e.frames, u64(0))
	_, key, ok := encode_frame(&e, planes, {16, 8, 8})
	testing.expect_value(t, ok, .None)
	testing.expect(t, key)
}

@(private = "file")
Failing_Allocator :: struct {backing: mem.Allocator, fail: bool}

@(private = "file")
failing_allocator_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	f := cast(^Failing_Allocator)data
	if f.fail && mode != .Free && mode != .Free_All && mode != .Query_Features && mode != .Query_Info do return nil, .Out_Of_Memory
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

// A failed packet append reports Out_Of_Memory without advancing the encoder;
// the same frame then encodes to the bytes a fresh encoder produces.
@(test)
encode_allocation_failure :: proc(t: ^testing.T) {
	failing := Failing_Allocator{backing = context.allocator}
	config := Encoder_Config{width = 64, height = 48, base_q_idx = 60, keyframe_interval = 4}
	e, fresh: Encoder
	{
		context.allocator = {failing_allocator_proc, &failing}
		testing.expect_value(t, init_encoder(&e, config), .None)
	}
	defer destroy_encoder(&e)
	testing.expect_value(t, init_encoder(&fresh, config), .None)
	defer destroy_encoder(&fresh)
	input: [3][]u8
	strides := [3]int{64, 32, 32}
	for p in 0 ..< 3 do input[p] = make([]u8, strides[p] * (p == 0 ? 48 : 24))
	defer for v in input do delete(v)
	for p in 0 ..< 3 do for &v, i in input[p] do v = u8((i * 13 + i / strides[p] * 5) & 255)
	for stage in 0 ..< 2 {
		// Drop the pre-reserved capacity so the next append must allocate.
		if stage == 0 {
			shrink(&e.tiles[0].b.data, 0)
		} else {
			testing.expect_value(t, reserve(&e.tiles[0].b.data, 1 << 16), nil)
			shrink(&e.packet, 0)
		}
		failing.fail = true
		_, _, err := encode_frame(&e, input, strides)
		failing.fail = false
		testing.expect_value(t, err, .Out_Of_Memory)
		testing.expect_value(t, e.frames, u64(0))
	}
	x, kx, ex := encode_frame(&e, input, strides)
	y, ky, ey := encode_frame(&fresh, input, strides)
	testing.expect_value(t, ex, .None); testing.expect_value(t, ey, .None)
	testing.expect(t, kx && ky)
	testing.expect_value(t, string(x), string(y))
}

@(test)
pool_packet_identity :: proc(t: ^testing.T) {
	pool: common.Static_Pool
	common.init_static_pool(&pool, 3)
	defer common.destroy_static_pool(&pool)
	a, b: Encoder
	config := Encoder_Config{width = 1025, height = 73, base_q_idx = 100, tile_cols_log2 = 2, block_log2 = 5}
	testing.expect_value(t, init_encoder(&a, config), .None)
	defer destroy_encoder(&a)
	config.pool = &pool.work_pool
	testing.expect_value(t, init_encoder(&b, config), .None)
	defer destroy_encoder(&b)
	input: [3][]u8
	strides := [3]int{1031, 521, 521}
	for p in 0 ..< 3 do input[p] = make([]u8, strides[p] * (p == 0 ? 73 : 37))
	defer for v in input do delete(v)
	for f in 0 ..< 5 {
		for p in 0 ..< 3 do for &v, i in input[p] do v = u8((i * 7 + f * 17) & 255)
		x, kx, ex := encode_frame(&a, input, strides)
		y, ky, ey := encode_frame(&b, input, strides)
		testing.expect_value(t, ex, .None); testing.expect_value(t, ey, .None)
		testing.expect_value(t, kx, ky)
		testing.expect_value(t, string(x), string(y))
	}
}

@(test)
bool_range_subdivision :: proc(t: ^testing.T) {
	b: Bool_Writer
	defer delete(b.data)
	start_bool(&b)
	seed: u32 = 12345
	probs: [20000]u8
	bits: [20000]int
	for i in 0 ..< len(bits) {
		seed ~= seed << 13; seed ~= seed >> 17; seed ~= seed << 5
		probs[i], bits[i] = u8(seed % 255 + 1), int(seed >> 16 & 1)
		put_bool(&b, bits[i], probs[i])
	}
	finish_bool(&b)
	// Direct section 9.2 bit-at-a-time decoder, independent of the byte writer.
	value, interval := int(b.data[0]), 255
	at := 8
	for i in -1 ..< len(bits) {
		prob := i < 0 ? 128 : int(probs[i])
		split := 1 + ((interval - 1) * prob >> 8)
		bit := int(value >= split)
		if bit != 0 {value -= split; interval -= split} else {interval = split}
		testing.expect_value(t, bit, i < 0 ? 0 : bits[i])
		for interval < 128 {
			value = value << 1 | int(b.data[at >> 3] >> uint(7 - (at & 7)) & 1)
			interval *= 2
			at += 1
		}
	}
}

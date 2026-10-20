package main

import h264 "../h264"
import avc_enc "../h264/encoder"
import "core:fmt"
import "core:mem"
import "core:thread"
import "core:time"

random :: proc(r: ^u32) -> u32 {r^ ~= r^ << 13; r^ ~= r^ >> 17; r^ ~= r^ << 5; return r^}

finish :: proc(c: ^avc_enc.Compute_State) {
	start := time.tick_now()
	for {
		done, err := avc_enc.advance_compute(c)
		assert(err == .None, avc_enc.error_description(err))
		if done do break
		assert(time.duration_seconds(time.tick_since(start)) < 30, "compute fence timeout")
		thread.yield()
	}
}

equal_pixels :: proc(a, b: ^h264.YUV_Buffer) {
	ap := [3][^]u8{a.y, a.u, a.v}; bp := [3][^]u8{b.y, b.u, b.v}
	for p in 0 ..< 3 {
		w, h := a.coded_width / (p == 0 ? 1 : 2), a.coded_height / (p == 0 ? 1 : 2)
		astride, bstride := p == 0 ? a.y_stride : a.uv_stride, p == 0 ? b.y_stride : b.uv_stride
		for y in 0 ..< h do for x in 0 ..< w {
			if ap[p][y * astride + x] != bp[p][y * bstride + x] {
				fmt.printfln("pixel mismatch plane=%d x=%d y=%d CPU=%d GPU=%d", p, x, y, ap[p][y * astride + x], bp[p][y * bstride + x])
				assert(false)
			}
		}
	}
}

strength_oracle :: proc(macroblocks: #soa[]h264.Macroblock, width, height: int, dst: []u32) {
	for i in 0 ..< len(macroblocks) do for orientation in 0 ..< 2 do for edge in 0 ..< 4 {
		q := &macroblocks[i]; p := q
		index := i * 8 + orientation * 4 + edge
		dst[index] = 0
		if q.deblocking_mode == .Disabled || (edge > 0 && q.uses_8x8_transform && edge & 1 != 0) do continue
		if edge == 0 {
			if orientation == 0 ? i % width == 0 : i < width do continue
			p = &macroblocks[i - (orientation == 0 ? 1 : width)]
			if q.deblocking_mode == .Within_Slice && p.slice_index != q.slice_index do continue
		}
		bs := h264.edge_strengths(p, q, edge, orientation == 0)
		for k in 0 ..< 4 do dst[index] |= u32(bs[k]) << u32(k * 8)
	}
}

test_stage :: proc(
	device: ^avc_enc.Compute_Device,
	width, height, cases: int,
	placement: avc_enc.Compute_Memory = .Host_Cached,
) {
	mbw, mbh := width / 16, height / 16
	c: avc_enc.Compute_State
	err := avc_enc.init_compute(&c, device, mbw, mbh, 2, placement)
	assert(err == .None, avc_enc.error_description(err))
	defer avc_enc.destroy_compute(&c)
	macroblocks := make(#soa[]h264.Macroblock, mbw * mbh); defer delete(macroblocks)
	cpu := h264.alloc_yuv_buffer(width, height); defer h264.free_yuv_buffer(&cpu)
	gpu := c.pictures[0].buf
	expected := make([]u32, len(macroblocks) * 8); defer delete(expected)
	rng: u32 = 0x634ABEEF
	resources := c.pictures[0].planes
	cpu_ms, gpu_ms: f64
	for test in 0 ..< cases {
		for i in 0 ..< len(macroblocks) {
			m := &macroblocks[i]
			m^ = {}
			m.is_intra = test % 8 == 0 || random(&rng) % 7 == 0
			m.type = random(&rng) % 29 == 0 ? .I_PCM : .I_4x4
			m.uses_8x8_transform = random(&rng) % 2 == 0
			m.quantizer = i8(test % 8 == 0 ? 42 : random(&rng) % 52)
			m.alpha_offset, m.beta_offset =
				i8(int(random(&rng) % 13) - 6), i8(int(random(&rng) % 13) - 6)
			m.deblocking_mode, m.slice_index =
				h264.Deblocking_Mode(random(&rng) % 3), u16(i / mbw / 3)
			m.luma_coded_block_mask = 15 // no uniform-motion shortcut in this synthetic descriptor set
			for k in 0 ..< 4 {
				m.has_8x8_coefficients[k] = random(&rng) % 5 == 0
				m.prediction_directions[k] =
					test % 4 == 0 ? .Bidirectional : h264.Prediction_Direction(1 + random(&rng) % 3)
				for l in 0 ..< 2 do m.reference_picture_ids[l][k] = i32(test % 4 == 0 ? (l + i) % 2 : int(random(&rng) % 5))
			}
			for k in 0 ..< 16 {
				m.nonzero_coefficient_counts[k] = u8(random(&rng) % 5 == 0)
				for l in 0 ..< 2 do m.motion_vectors[l][k] = {i16(int(random(&rng) % 9) - 4), i16(int(random(&rng) % 9) - 4)}
			}
		}
		cp := [3][^]u8{cpu.y, cpu.u, cpu.v}; gp := [3][^]u8{gpu.y, gpu.u, gpu.v}
		for p in 0 ..< 3 {
			w, h := width / (p == 0 ? 1 : 2), height / (p == 0 ? 1 : 2)
			cs, gs := p == 0 ? cpu.y_stride : cpu.uv_stride, p == 0 ? gpu.y_stride : gpu.uv_stride
			for y in 0 ..< h do for x in 0 ..< w {
				v := test % 3 == 0 ? u8(random(&rng) % 256) : u8(clamp(100 + (x / 4 + y / 4) % 13 + int(random(&rng) % 5) - 2, 0, 255))
				cp[p][y * cs + x], gp[p][y * gs + x] = v, v
			}
		}
		offsets := [2]i32{i32(test % 25) - 12, 12 - i32(test % 25)}
		strength_oracle(macroblocks, mbw, mbh, expected)
		start := time.tick_now()
		h264.deblock_picture(macroblocks, &cpu, mbw, mbh, offsets)
		cpu_ms += time.duration_milliseconds(time.tick_since(start))
		start = time.tick_now()
		assert(avc_enc.begin_compute_deblock(&c, macroblocks, 0, u64(test + 1), offsets) == .None)
		finish(&c)
		gpu_ms += time.duration_milliseconds(time.tick_since(start))
		actual := c.strengths
		for value, i in expected {
			if actual[i] !=
			   value {fmt.printfln("strength mismatch case=%d edge=%d CPU=%x GPU=%x", test, i, value, actual[i]); assert(false)}
		}
		equal_pixels(&cpu, &gpu)
		assert(c.pictures[0].planes == resources && c.pictures[0].generation == u64(test + 1))
	}
	device_ms := c.gpu_ms
	ack_ms, retire_ms: f64
	// Cancel after strength and filtering submissions. The shared writable slot
	// stays unavailable until its fence retires; completed references are untouched.
	for submit_filter in ([2]bool{false, true}) {
		other := &c.pictures[1].buf
		for y in 0 ..< height do mem.copy(&other.y[y * other.y_stride], &gpu.y[y * gpu.y_stride], width)
		for y in 0 ..< height / 2 {
			mem.copy(&other.u[y * other.uv_stride], &gpu.u[y * gpu.uv_stride], width / 2)
			mem.copy(&other.v[y * other.uv_stride], &gpu.v[y * gpu.uv_stride], width / 2)
		}
		assert(avc_enc.begin_compute_deblock(&c, macroblocks, 1, 999, {0, 0}) == .None)
		if submit_filter do for c.next_wave == 0 {_, wave_err := avc_enc.advance_compute(&c); assert(wave_err == .None); thread.yield()}
		start := time.tick_now()
		avc_enc.cancel_compute(&c)
		ack_ms = max(ack_ms, time.duration_milliseconds(time.tick_since(start)))
		assert(avc_enc.begin_compute_deblock(&c, macroblocks, 1, 1000, {0, 0}) != .None)
		before := c.submissions
		start = time.tick_now()
		finish(&c)
		retire_ms = max(retire_ms, time.duration_milliseconds(time.tick_since(start)))
		assert(c.submissions == before && c.pictures[1].generation == 0)
		equal_pixels(&cpu, &gpu)
	}
	fmt.printfln(
		"[SUCCESS] Slang pointer strength/pixel/cancel parity: %dx%d %v, %d cases; CPU %.3f ms GPU end-to-end %.3f ms device %.3f ms/frame; cancel acknowledgment <= %.6f ms retirement <= %.3f ms; memory=%v",
		width,
		height,
		placement,
		cases,
		cpu_ms / f64(cases),
		gpu_ms / f64(cases),
		device_ms / f64(cases),
		ack_ms,
		retire_ms,
		c.allocation.properties,
	)
}

// This case intentionally differs from the former shared luma-threshold gate.
// QPY15 has zero Y thresholds; Cb+12 is active while Cr-12 remains inactive.
test_chroma_threshold_admission :: proc(device: ^avc_enc.Compute_Device) {
	c: avc_enc.Compute_State
	err := avc_enc.init_compute(&c, device, 2, 1, 1)
	assert(err == .None, avc_enc.error_description(err))
	defer avc_enc.destroy_compute(&c)
	blocks := make(#soa[]h264.Macroblock, 2)
	defer delete(blocks)
	cpu := h264.alloc_yuv_buffer(32, 16)
	defer h264.free_yuv_buffer(&cpu)
	gpu := &c.pictures[0].buf
	for strong in ([2]bool{false, true}) {
		for i in 0 ..< 2 {
			blocks[i] = {}
			blocks[i].type = .P_L0_16x16
			blocks[i].quantizer = 15
			blocks[i].is_intra = strong
			blocks[i].deblocking_mode = .All_Edges
			blocks[i].luma_coded_block_mask = 15
			for sub in 0 ..< 16 do blocks[i].nonzero_coefficient_counts[sub] = 1
		}
		cp := [3][^]u8{cpu.y, cpu.u, cpu.v}
		gp := [3][^]u8{gpu.y, gpu.u, gpu.v}
		for plane in 0 ..< 3 {
			w, h := plane == 0 ? 32 : 16, plane == 0 ? 16 : 8
			cs, gs :=
				plane == 0 ? cpu.y_stride : cpu.uv_stride,
				plane == 0 ? gpu.y_stride : gpu.uv_stride
			for y in 0 ..< h do for x in 0 ..< w {
				value := u8(x < w / 2 ? 100 : 104)
				cp[plane][y * cs + x], gp[plane][y * gs + x] = value, value
			}
		}
		h264.deblock_picture(blocks, &cpu, 2, 1, {12, -12})
		assert(avc_enc.begin_compute_deblock(&c, blocks, 0, strong ? 2 : 1, {12, -12}) == .None)
		finish(&c)
		equal_pixels(&cpu, gpu)
		for y in 0 ..< 8 {
			assert(gpu.u[y * gpu.uv_stride + 7] == u8(strong ? 101 : 102))
			assert(gpu.u[y * gpu.uv_stride + 8] == u8(strong ? 103 : 102))
			assert(gpu.v[y * gpu.uv_stride + 7] == 100 && gpu.v[y * gpu.uv_stride + 8] == 104)
		}
		for y in 0 ..< 16 do assert(gpu.y[y * gpu.y_stride + 15] == 100 && gpu.y[y * gpu.y_stride + 16] == 104)
	}
	fmt.println(
		"[SUCCESS] independent chroma/luma threshold admission: weak/strong, QPY15 Cb+12 Cr-12",
	)
}

test_encoder :: proc(device: ^avc_enc.Compute_Device) {
	cpu, gpu: avc_enc.Encoder_State
	config := avc_enc.Encoder_Config {
		width               = 258,
		height              = 146,
		qp                  = 29,
		gop_size            = 7,
		num_ref_frames      = 3,
		checkpoint_capacity = 2,
		slice_count         = 4,
	}
	avc_enc.init_encoder(&cpu, config); defer avc_enc.destroy_encoder(&cpu)
	avc_enc.init_encoder(&gpu, config); defer avc_enc.destroy_encoder(&gpu)
	assert(avc_enc.attach_encoder_compute(&gpu, device) == .None)
	src := h264.alloc_yuv_buffer(config.width, config.height); defer h264.free_yuv_buffer(&src)
	a, b := make([dynamic]u8), make([dynamic]u8); defer delete(a); defer delete(b)
	initial, initial_err := avc_enc.capture_encoder_checkpoint(&gpu, &b)
	assert(initial_err == .None)
	allocation_address := gpu.compute.allocation.address
	point: avc_enc.Encoder_Checkpoint_Handle
	for frame in 0 ..< 20 {
		for y in 0 ..< config.height do for x in 0 ..< config.width do src.y[y * src.y_stride + x] = u8((x * 2 + y + frame * 7) & 255)
		for y in 0 ..< config.height / 2 do for x in 0 ..< config.width / 2 {src.u[y * src.uv_stride + x] = u8(80 + (x + frame) % 80); src.v[y * src.uv_stride + x] = u8(90 + (y + frame) % 90)}
		assert(
			avc_enc.encode_frame(
				&cpu,
				src.y,
				src.u,
				src.v,
				src.y_stride,
				src.uv_stride,
				frame % 7 == 0,
				&a,
			) ==
			.None,
		)
		// Callers may fill the permanent source view directly. Passing that view
		// does not copy overlapping memory; only edge padding is refreshed.
		avc_enc.import_source(&gpu, src.y, src.u, src.v, src.y_stride, src.uv_stride)
		assert(
			avc_enc.encode_frame(
				&gpu,
				gpu.source.y,
				gpu.source.u,
				gpu.source.v,
				gpu.source.y_stride,
				gpu.source.uv_stride,
				frame % 7 == 0,
				&b,
			) ==
			.None,
		)
		equal_pixels(&cpu.curr.buf, &gpu.curr.buf)
		assert(len(a) == len(b) && mem.compare(a[:], b[:]) == 0)
		if frame ==
		   18 {p, err := avc_enc.capture_encoder_checkpoint(&gpu); assert(err == .None); point = p}
	}
	assert(avc_enc.restore_encoder_checkpoint(&gpu, point) == .None)
	// Source still contains frame 19. Cancel with filtering in flight, then replay.
	assert(
		avc_enc.begin_encode_frame(
			&gpu,
			src.y,
			src.u,
			src.v,
			src.y_stride,
			src.uv_stride,
			false,
		) ==
		.None,
	)
	for !gpu.frame.compute_started {_, err := avc_enc.advance_encode_frame(&gpu, gpu.macroblock_count); assert(err == .None)}
	canceled_slot := gpu.compute.slot
	avc_enc.cancel_encode_frame(&gpu)
	assert(
		avc_enc.begin_encode_frame(
			&gpu,
			src.y,
			src.u,
			src.v,
			src.y_stride,
			src.uv_stride,
			false,
		) ==
		.None,
	)
	assert(gpu.curr.slot != canceled_slot)
	for {done, err := avc_enc.advance_encode_frame(&gpu, 32); assert(err == .None); if done do break; thread.yield()}
	assert(avc_enc.commit_encode_frame(&gpu, &b) == .None)
	assert(len(a) == len(b) && mem.compare(a[:], b[:]) == 0)
	assert(avc_enc.release_encoder_checkpoint(&gpu, point) == .None)
	assert(
		avc_enc.restore_encoder_checkpoint(&gpu, initial) == .None &&
		len(b) == 0 &&
		gpu.num_refs == 0,
	)
	for frame in 0 ..< 20 {
		for y in 0 ..< config.height do for x in 0 ..< config.width do src.y[y * src.y_stride + x] = u8((x * 2 + y + frame * 7) & 255)
		for y in 0 ..< config.height / 2 do for x in 0 ..< config.width / 2 {src.u[y * src.uv_stride + x] = u8(80 + (x + frame) % 80); src.v[y * src.uv_stride + x] = u8(90 + (y + frame) % 90)}
		assert(
			avc_enc.encode_frame(
				&gpu,
				src.y,
				src.u,
				src.v,
				src.y_stride,
				src.uv_stride,
				frame % 7 == 0,
				&b,
			) ==
			.None,
		)
	}
	assert(len(a) == len(b) && mem.compare(a[:], b[:]) == 0)
	assert(gpu.compute.allocation.address == allocation_address)
	fmt.println(
		"[SUCCESS] GPU encoder/checkpoint/in-flight cancel/restart at frame zero: 20 frames, byte-identical CPU stream, stable allocation",
	)
}

main :: proc() {
	device: avc_enc.Compute_Device
	err := avc_enc.init_compute_device(&device)
	assert(err == .None, avc_enc.error_description(err))
	defer avc_enc.destroy_compute_device(&device)
	fmt.println("GPU:", string(cstring(raw_data(device.properties.deviceName[:]))))
	test_chroma_threshold_admission(&device)
	test_stage(&device, 272, 144, 96)
	test_stage(&device, 1280, 720, 4)
	test_stage(&device, 1920, 1088, 3)
	test_stage(&device, 1280, 720, 4, .Device_Local)
	test_encoder(&device)
}

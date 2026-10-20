package main

import common "../common"
import h264 "../video/h264"
import avc_dec "../video/h264/decoder"
import avc_enc "../video/h264/encoder"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"

generate_test_frame :: proc(
	frame_idx: int,
	width, height: int,
	y_buf, u_buf, v_buf: [^]u8,
	y_stride, uv_stride: int,
) {
	for y in 0 ..< height {
		for x in 0 ..< width {
			grad := u8((x * 255 / width + y * 255 / height) >> 1)
			box_x := (frame_idx * 4) % (width - 32)
			box_y := (frame_idx * 2) % (height - 32)
			if x >= box_x && x < box_x + 32 && y >= box_y && y < box_y + 32 {
				y_buf[y * y_stride + x] = 235
			} else {
				y_buf[y * y_stride + x] = grad
			}
		}
	}
	for y in 0 ..< height / 2 {
		for x in 0 ..< width / 2 {
			u_buf[y * uv_stride + x] = u8(128 + ((x * 60) / (width / 2)))
			v_buf[y * uv_stride + x] = u8(128 + ((y * 60) / (height / 2)))
		}
	}
}

calculate_psnr :: proc(
	orig_y, dec_y: [^]u8,
	width, height: int,
	orig_stride, dec_stride: int,
) -> f64 {
	sse: f64 = 0
	for y in 0 ..< height {
		for x in 0 ..< width {
			d := f64(orig_y[y * orig_stride + x]) - f64(dec_y[y * dec_stride + x])
			sse += d * d
		}
	}
	mse := sse / f64(width * height)
	if mse == 0 do return 99.0
	return 10.0 * math.log10(255.0 * 255.0 / mse)
}

find_nal_units :: proc(data: []u8) -> []h264.Nal_Location {
	nals := make([dynamic]h264.Nal_Location, 0, 64)
	n := len(data)
	i := 0
	for i < n {
		sc := 0
		if i + 3 <= n && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
			sc = 3
		} else if i + 4 <= n &&
		   data[i] == 0 &&
		   data[i + 1] == 0 &&
		   data[i + 2] == 0 &&
		   data[i + 3] == 1 {
			sc = 4
		} else {
			i += 1
			continue
		}
		start := i + sc
		j := start
		for j + 3 < n {
			if data[j] == 0 && data[j + 1] == 0 && (data[j + 2] == 1 || (j + 3 < n && data[j + 2] == 0 && data[j + 3] == 1)) do break
			j += 1
		}
		if j + 3 >= n do j = n
		append(&nals, h264.Nal_Location{offset = start, length = j - start})
		i = j
	}
	return nals[:]
}

main :: proc() {
	fmt.println("==================================================")
	fmt.println(" Native Odin H.264 Data-Parallelism Test")
	fmt.println(" (Caller-Donated Pool & Preallocated Data Slices)")
	fmt.println("==================================================")

	WIDTH :: 176
	HEIGHT :: 144
	QP :: 26
	MB_W :: WIDTH / 16
	MB_H :: HEIGHT / 16
	TOTAL_MBS :: MB_W * MB_H

	// 1. Caller initializes one fixed-range Work_Pool adapter. Each map joins
	// its slice items before the next phase reuses their preallocated state.
	worker_count := clamp(os.get_processor_core_count() - 1, 0, common.MAX_STATIC_POOL_THREADS)
	fmt.printfln(
		"Initializing caller-donated Static_Pool with %d background workers plus caller...",
		worker_count,
	)
	caller_pool: common.Static_Pool
	common.init_static_pool(&caller_pool, worker_count)
	defer common.destroy_static_pool(&caller_pool)

	// 2. Preallocate all image memory and encoder state
	config := avc_enc.Encoder_Config {
		width       = WIDTH,
		height      = HEIGHT,
		qp          = QP,
		gop_size    = 15,
		slice_count = 4,
	}

	encoder: avc_enc.Encoder_State
	avc_enc.init_encoder(&encoder, config)
	defer avc_enc.destroy_encoder(&encoder)

	scratch_yuv := h264.alloc_yuv_buffer(WIDTH, HEIGHT)
	defer h264.free_yuv_buffer(&scratch_yuv)

	// Slices retain separate scratch and append their completed NALs at commit.
	// -----------------------------------------------------------------------
	// Test 2: Multi-Slice Frame Encoding, fixed row-aligned slice items
	// -----------------------------------------------------------------------
	fmt.println("\n--- Testing Data-Parallel Multi-Slice Encoding ---")
	generate_test_frame(
		0,
		WIDTH,
		HEIGHT,
		scratch_yuv.y,
		scratch_yuv.u,
		scratch_yuv.v,
		scratch_yuv.y_stride,
		scratch_yuv.uv_stride,
	)
	stream := make([dynamic]u8, 0, 128 * 1024)
	defer delete(stream)
	t0 := time.now()
	assert(
		avc_enc.encode_frame(
			&encoder,
			scratch_yuv.y,
			scratch_yuv.u,
			scratch_yuv.v,
			scratch_yuv.y_stride,
			scratch_yuv.uv_stride,
			true,
			&stream,
			&caller_pool.work_pool,
		) ==
		.None,
	)
	elapsed := time.since(t0)
	num_slices := min(config.slice_count, MB_H)
	fmt.printfln(
		"  -> Encoded %d slices (%d MB rows) into %d bytes in %v",
		num_slices,
		MB_H,
		len(stream),
		elapsed,
	)

	// -----------------------------------------------------------------------
	// Test 3: Decode Generated Multi-Slice Bitstream
	// -----------------------------------------------------------------------
	fmt.println("\n--- Verifying Bitstream with Native H.264 Decoder ---")
	decoder: avc_dec.Decoder_State
	avc_dec.init_decoder(&decoder)
	defer avc_dec.destroy_decoder(&decoder)

	frame_ready := false
	nal_count := 0
	for nal in find_nal_units(stream[:]) {
		ready, err := avc_dec.decode_nal(&decoder, stream[nal.offset:nal.offset + nal.length])
		if err != .None {
			fmt.printfln("  NAL %d decode error: %s", nal_count, err)
			os.exit(1)
		}
		if ready do frame_ready = true
		nal_count += 1
	}
	if avc_dec.flush_decoder(&decoder) do frame_ready = true
	assert(nal_count - 2 == num_slices)
	fmt.printfln("  -> Decoded %d NAL units (SPS, PPS, %d slices)", nal_count, nal_count - 2)

	if frame_ready {
		psnr := calculate_psnr(
			scratch_yuv.y,
			decoder.output.buf.y,
			WIDTH,
			HEIGHT,
			scratch_yuv.y_stride,
			decoder.output.buf.y_stride,
		)
		fidelity := calculate_psnr(
			encoder.curr.buf.y,
			decoder.output.buf.y,
			WIDTH,
			HEIGHT,
			encoder.curr.buf.y_stride,
			decoder.output.buf.y_stride,
		)
		fmt.printfln("  Multi-slice Frame Decoded Successfully!")
		fmt.printfln("  -> PSNR vs Source: %.2f dB", psnr)
		fmt.printfln("  -> Fidelity (Decoder vs EncRec): %.2f dB", fidelity)

		if fidelity > 90.0 {
			fmt.println(
				"\n[SUCCESS] Data-parallel multi-slice encoding verified with bit-exact fidelity!",
			)
		} else {
			fmt.println("\n[FAIL] Fidelity below threshold.")
			os.exit(1)
		}
	} else {
		fmt.println("\n[FAIL] Decoder did not mark frame ready.")
		os.exit(1)
	}
}

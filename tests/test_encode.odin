package main

import h264 "../video/h264"
import avc_dec "../video/h264/decoder"
import avc_enc "../video/h264/encoder"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:time"

generate_test_frame :: proc(
	frame_idx: int,
	width, height: int,
	y_buf, u_buf, v_buf: [^]u8,
	y_stride, uv_stride: int,
) {
	// Generate dynamic moving gradient and box pattern
	for y in 0 ..< height {
		for x in 0 ..< width {
			grad := u8((x * 255 / width + y * 255 / height) >> 1)
			// Moving box
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

main :: proc() {
	fmt.println("==================================================")
	fmt.println(" Native Odin H.264 End-to-End Encode/Decode Test")
	fmt.println("==================================================")

	WIDTH :: 176
	HEIGHT :: 144
	NUM_FRAMES :: 30
	QP :: 26

	config := avc_enc.Encoder_Config {
		width    = WIDTH,
		height   = HEIGHT,
		qp       = QP,
		gop_size = 15,
	}

	encoder: avc_enc.Encoder_State
	avc_enc.init_encoder(&encoder, config)
	defer avc_enc.destroy_encoder(&encoder)

	encoded_bitstream := make([dynamic]u8, 0, 1024 * 1024)
	defer delete(encoded_bitstream)

	// Pre-allocate raw frame storage for PSNR comparison
	raw_y := make([]u8, WIDTH * HEIGHT * NUM_FRAMES)
	defer delete(raw_y)

	enc_rec_y := make([]u8, WIDTH * HEIGHT * NUM_FRAMES)
	defer delete(enc_rec_y)

	scratch_yuv := h264.alloc_yuv_buffer(WIDTH, HEIGHT)
	defer h264.free_yuv_buffer(&scratch_yuv)

	fmt.printfln(
		"Encoding %d frames (%dx%d, QP=%d, Baseline Profile)...",
		NUM_FRAMES,
		WIDTH,
		HEIGHT,
		QP,
	)
	t_enc_start := time.now()

	for f in 0 ..< NUM_FRAMES {
		generate_test_frame(
			f,
			WIDTH,
			HEIGHT,
			scratch_yuv.y,
			scratch_yuv.u,
			scratch_yuv.v,
			scratch_yuv.y_stride,
			scratch_yuv.uv_stride,
		)

		// Store raw Y plane for PSNR comparison
		for y in 0 ..< HEIGHT {
			mem.copy(
				&raw_y[(f * HEIGHT + y) * WIDTH],
				&scratch_yuv.y[y * scratch_yuv.y_stride],
				WIDTH,
			)
		}

		is_idr := (f % config.gop_size) == 0
		avc_enc.encode_frame(
			&encoder,
			scratch_yuv.y,
			scratch_yuv.u,
			scratch_yuv.v,
			scratch_yuv.y_stride,
			scratch_yuv.uv_stride,
			is_idr,
			&encoded_bitstream,
		)

		for y in 0 ..< HEIGHT {
			mem.copy(
				&enc_rec_y[(f * HEIGHT + y) * WIDTH],
				&encoder.curr.buf.y[y * encoder.curr.buf.y_stride],
				WIDTH,
			)
		}
	}

	d_enc := time.since(t_enc_start)
	enc_secs := time.duration_seconds(d_enc)
	enc_fps := enc_secs > 0 ? (f64(NUM_FRAMES) / enc_secs) : 0
	fmt.printfln(
		"  -> Encoded %d frames into %d bytes in %v (%.1f FPS)",
		NUM_FRAMES,
		len(encoded_bitstream),
		d_enc,
		enc_fps,
	)

	// Save encoded stream to disk for independent verification
	out_path := "test_encoded_output.264"
	_ = os.write_entire_file(out_path, encoded_bitstream[:])
	fmt.printfln("  -> Saved Annex B bitstream to %s", out_path)

	// -----------------------------------------------------------------------
	// Decode generated bitstream with our Native Decoder!
	// -----------------------------------------------------------------------
	fmt.println("\nDecoding generated bitstream with Native Odin H.264 Decoder...")
	decoder: avc_dec.Decoder_State
	avc_dec.init_decoder(&decoder)
	defer avc_dec.destroy_decoder(&decoder)

	nals := make([dynamic]h264.Nal_Location)
	defer delete(nals)

	// Simple Annex B parser
	data := encoded_bitstream[:]
	n := len(data)
	i := 0
	for i < n {
		sc_len := 0
		if i + 3 <= n && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
			sc_len = 3
		} else if i + 4 <= n &&
		   data[i] == 0 &&
		   data[i + 1] == 0 &&
		   data[i + 2] == 0 &&
		   data[i + 3] == 1 {
			sc_len = 4
		} else {
			i += 1
			continue
		}
		start := i + sc_len
		j := start
		for j + 3 < n {
			if data[j] == 0 && data[j + 1] == 0 {
				if data[j + 2] == 1 do break
				if j + 3 < n && data[j + 2] == 0 && data[j + 3] == 1 do break
			}
			j += 1
		}
		if j + 3 >= n do j = n
		append(&nals, h264.Nal_Location{offset = start, length = j - start})
		i = j
	}

	fmt.printfln("  -> Found %d NAL units in bitstream", len(nals))

	frames_decoded := 0
	psnr_sum: f64 = 0
	t_dec_start := time.now()

	for loc, nal_idx in nals {
		nal_slice := data[loc.offset:loc.offset + loc.length]
		nal_type := nal_slice[0] & 0x1F
		fmt.printfln("Decoding NAL %d: type=%d, len=%d", nal_idx, nal_type, len(nal_slice))
		ready, err := avc_dec.decode_nal(&decoder, nal_slice)
		if err != .None {
			fmt.printfln("  Decode error on NAL %d: %s", nal_idx, err)
		}
		if ready {
			orig_slice := raw_y[frames_decoded *
			WIDTH *
			HEIGHT:(frames_decoded + 1) *
			WIDTH *
			HEIGHT]
			enc_rec_slice := enc_rec_y[frames_decoded *
			WIDTH *
			HEIGHT:(frames_decoded + 1) *
			WIDTH *
			HEIGHT]

			fidelity_psnr := calculate_psnr(
				raw_data(enc_rec_slice),
				decoder.output.buf.y,
				WIDTH,
				HEIGHT,
				WIDTH,
				decoder.output.buf.y_stride,
			)

			psnr := calculate_psnr(
				raw_data(orig_slice),
				decoder.output.buf.y,
				WIDTH,
				HEIGHT,
				WIDTH,
				decoder.output.buf.y_stride,
			)
			fmt.printfln(
				"  Frame %d decoded: PSNR = %.2f dB (Decoder vs EncRec Fidelity = %.2f dB)",
				frames_decoded,
				psnr,
				fidelity_psnr,
			)
			psnr_sum += psnr
			frames_decoded += 1
		}
	}

	d_dec := time.since(t_dec_start)
	dec_secs := time.duration_seconds(d_dec)
	dec_fps := dec_secs > 0 ? (f64(frames_decoded) / dec_secs) : 0

	avg_psnr := frames_decoded > 0 ? (psnr_sum / f64(frames_decoded)) : 0
	fmt.printfln("  -> Decoded %d frames in %v (%.1f FPS)", frames_decoded, d_dec, dec_fps)
	fmt.printfln("  -> Average Luma PSNR: %.2f dB", avg_psnr)

	if frames_decoded == NUM_FRAMES && avg_psnr > 30.0 {
		fmt.println("\n[SUCCESS] Full End-to-End Encode/Decode Verification PASSED!")
	} else {
		fmt.println("\n[FAIL] End-to-End verification failed.")
	}
}

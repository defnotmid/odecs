package main

import common "../common"
import h264 "../h264"
import avc_enc "../h264/encoder"
import "core:fmt"
import "core:mem"

fill :: proc(buf: ^h264.YUV_Buffer, frame: int) {
	for y in 0 ..< buf.height do for x in 0 ..< buf.width do buf.y[y * buf.y_stride + x] = u8((x * 3 + y * 2 + (x > frame % 48 ? 17 : 0)) & 255)
	for y in 0 ..< buf.height / 2 do for x in 0 ..< buf.width / 2 {
		buf.u[y * buf.uv_stride + x] = u8(100 + x)
		buf.v[y * buf.uv_stride + x] = u8(120 + y)
	}
}

main :: proc() {
	pool: common.Static_Pool
	common.init_static_pool(&pool, 3)
	defer common.destroy_static_pool(&pool)
	for gop in ([2]int{7, 1000}) do for bitrate in ([2]int{0, 150}) {
		config := avc_enc.Encoder_Config {
			width               = 66,
			height              = 50,
			qp                  = 26,
			gop_size            = gop,
			num_ref_frames      = 3,
			checkpoint_capacity = 3,
			slice_count         = 4,
			bitrate_kbps        = bitrate,
		}
		st: avc_enc.Encoder_State
		avc_enc.init_encoder(&st, config)
		defer avc_enc.destroy_encoder(&st)
		src := h264.alloc_yuv_buffer(config.width, config.height)
		defer h264.free_yuv_buffer(&src)
		out := make([dynamic]u8)
		defer delete(out)
		points: [2]avc_enc.Encoder_Checkpoint_Handle
		for f in 0 ..< 270 {
			fill(&src, f)
			assert(avc_enc.encode_frame(&st, src.y, src.u, src.v, src.y_stride, src.uv_stride, f % gop == 0, &out) == .None)
			if f == 9 || f == 260 {
				point, err := avc_enc.capture_encoder_checkpoint(&st)
				assert(err == .None)
				points[f == 9 ? 0 : 1] = point
			}
		}
		original := make([]u8, len(out))
		copy(original, out[:])
		defer delete(original)
		for index in ([2]int{1, 0}) {
			assert(avc_enc.restore_encoder_checkpoint(&st, points[index]) == .None)
			if index == 0 do assert(!avc_enc.encoder_checkpoint_valid(&st, points[1]))
			before_rate, before_num, before_refs := st.rate, st.frame_num, st.refs
			before_len := len(out)
			// An interrupted IDR must not discard references or append SPS/PPS.
			fill(&src, 99)
			assert(avc_enc.begin_encode_frame(&st, src.y, src.u, src.v, src.y_stride, src.uv_stride, true) == .None)
			_, err := avc_enc.advance_encode_frame(&st, 1, &pool.work_pool)
			assert(err == .None)
			assert(avc_enc.commit_encode_frame(&st, &out) != .None)
			avc_enc.cancel_encode_frame(&st)
			assert(st.rate == before_rate && st.frame_num == before_num && st.refs == before_refs && len(out) == before_len)
			for f in (index == 0 ? 10 : 261) ..< 270 {
				fill(&src, f)
				assert(avc_enc.begin_encode_frame(&st, src.y, src.u, src.v, src.y_stride, src.uv_stride, f % gop == 0) == .None)
				for {
					ready, step_err := avc_enc.advance_encode_frame(&st, 1 + f % 3, &pool.work_pool)
					assert(step_err == .None)
					if ready do break
				}
				assert(avc_enc.commit_encode_frame(&st, &out) == .None)
			}
			assert(len(original) == len(out) && mem.compare(original, out[:]) == 0)
		}
		assert(avc_enc.release_encoder_checkpoint(&st, points[0]) == .None)
		assert(avc_enc.release_encoder_checkpoint(&st, points[0]) == .Invalid_Checkpoint)
		assert(avc_enc.restore_encoder_checkpoint(&st, points[0]) != .None)
		for pic in st.pictures do assert(pic.pins == 0)
		fmt.printfln("[SUCCESS] checkpoint/replay/cancel/worker parity: gop=%d bitrate=%d, 270 frames", gop, bitrate)
	}
	// An edited suffix must match an uninterrupted encode of that exact source
	// history, including rate-control carry across the intervening IDR.
	a, b: avc_enc.Encoder_State
	config := avc_enc.Encoder_Config {
		width               = 66,
		height              = 50,
		qp                  = 26,
		gop_size            = 7,
		num_ref_frames      = 3,
		checkpoint_capacity = 1,
		bitrate_kbps        = 150,
	}
	avc_enc.init_encoder(&a, config); defer avc_enc.destroy_encoder(&a)
	avc_enc.init_encoder(&b, config); defer avc_enc.destroy_encoder(&b)
	src := h264.alloc_yuv_buffer(config.width, config.height); defer h264.free_yuv_buffer(&src)
	oa, ob := make([dynamic]u8), make([dynamic]u8); defer delete(oa); defer delete(ob)
	point: avc_enc.Encoder_Checkpoint_Handle
	for frame in 0 ..< 22 {
		fill(&src, frame)
		assert(
			avc_enc.encode_frame(
				&a,
				src.y,
				src.u,
				src.v,
				src.y_stride,
				src.uv_stride,
				frame % 7 == 0,
				&oa,
			) ==
			.None,
		)
		if frame == 9 {
			p, err := avc_enc.capture_encoder_checkpoint(&a); assert(err == .None); point = p
			_, full := avc_enc.capture_encoder_checkpoint(&a); assert(full != .None)
			assert(avc_enc.restore_encoder_checkpoint(&b, point) != .None)
		}
		if frame >= 10 do fill(&src, frame + 31)
		assert(
			avc_enc.encode_frame(
				&b,
				src.y,
				src.u,
				src.v,
				src.y_stride,
				src.uv_stride,
				frame % 7 == 0,
				&ob,
				&pool.work_pool,
			) ==
			.None,
		)
	}
	a.config.qp += 1
	assert(avc_enc.restore_encoder_checkpoint(&a, point) != .None)
	a.config.qp -= 1
	restart, rewind_err := avc_enc.rewind_encoder_to_edit(&a, 10)
	assert(rewind_err == .None && restart == 10)
	for frame in 10 ..< 22 {
		fill(&src, frame + 31)
		assert(
			avc_enc.encode_frame(
				&a,
				src.y,
				src.u,
				src.v,
				src.y_stride,
				src.uv_stride,
				frame % 7 == 0,
				&oa,
			) ==
			.None,
		)
	}
	assert(len(oa) == len(ob) && mem.compare(oa[:], ob[:]) == 0 && a.rate == b.rate)
	fmt.println(
		"[SUCCESS] changed-source replay equals uninterrupted encode, capacity/config/owner validation",
	)
}

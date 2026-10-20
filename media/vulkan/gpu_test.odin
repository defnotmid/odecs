package media_vulkan

@(require) import "core:os"
import "core:testing"

@(test)
plane_bounds :: proc(t: ^testing.T) {
	storage: [32]u8
	testing.expect(t, valid_plane({storage[:], 8}, 4, 4))
	testing.expect(t, !valid_plane({storage[:], 3}, 4, 4))
	testing.expect(t, !valid_plane({storage[:], max(int)}, 4, 4))
	testing.expect(t, !valid_plane({storage[:], 8}, 4, 5))
	testing.expect(t, valid_plane({storage[:4], max(int)}, 4, 1))
}

@(test)
invalid_config :: proc(t: ^testing.T) {
	e: Encoder
	testing.expect(
		t,
		init_encoder(&e, {width = 321, height = 240, qp = 26, device_index = -1}) ==
		.Invalid_Argument,
	)
	testing.expect(
		t,
		init_encoder(&e, {width = 320, height = 240, qp = 52, device_index = -1}) ==
		.Invalid_Argument,
	)
	testing.expect(
		t,
		init_encoder(&e, {width = 320, height = 240, qp = 26, device_index = -2}) ==
		.Invalid_Argument,
	)
	destroy_encoder(&e)
	destroy_encoder(&e)
}

// Explicit hardware gate: odin test media/vulkan -define:ODECS_GPU_TEST=true.
// A requested hardware gate must fail when hardware is unavailable, rather
// than turn a skipped test into a claim of working hardware encoding.
@(test)
hardware_encode :: proc(t: ^testing.T) {
	when #config(ODECS_GPU_TEST, false) {
		w, h := #config(ODECS_GPU_WIDTH, 320), #config(ODECS_GPU_HEIGHT, 240)
		qp := #config(ODECS_GPU_QP, 26)
		depth := #config(ODECS_GPU_DEPTH, 8)
		gop := #config(ODECS_GPU_GOP, 1)
		frames := #config(ODECS_GPU_FRAMES, 3)
		codec: Codec = #config(ODECS_GPU_CODEC, "h264") == "h265" ? .H265 : .H264
		// The synchronous encoder and one with three pictures in flight must
		// write the same stream; the latter returns each packet two calls late.
		streams: [2][dynamic]u8
		defer for stream in streams do delete(stream)
		for in_flight, run in ([2]int{1, 3}) {
			e: Encoder
			err := init_encoder(
				&e,
				{
					codec = codec,
					bit_depth = depth,
					gop_size = gop,
					width = w,
					height = h,
					qp = qp,
					device_index = -1,
					frames_in_flight = in_flight,
				},
			)
			testing.expect_value(t, err, Error.None)
			if err != .None do return
			defer destroy_encoder(&e)
			y := make([]u8, w * h); defer delete(y)
			u := make([]u8, w * h / 4); defer delete(u)
			v := make([]u8, w * h / 4); defer delete(v)
			y16 := make([]u16, w * h); defer delete(y16)
			chroma_u16 := make([]u16, w * h / 4); defer delete(chroma_u16)
			chroma_v16 := make([]u16, w * h / 4); defer delete(chroma_v16)
			stream := &streams[run]
			for frame in 0 ..< frames {
				for row in 0 ..< h {
					for col in 0 ..< w do y[row * w + col] = u8(32 + (row + col + frame * 17) % 180)
				}
				for &sample in u do sample = u8(100 + frame % 8 * 8)
				for &sample in v do sample = u8(150 - frame % 8 * 8)
				packet: []u8
				encode_error: Error
				if depth == 8 {
					packet, encode_error = encode_frame(&e, {y, w}, {u, w / 2}, {v, w / 2})
				} else {
					for &sample, i in y16 do sample = u16(y[i]) << 2
					for &sample, i in chroma_u16 do sample = u16(u[i]) << 2
					for &sample, i in chroma_v16 do sample = u16(v[i]) << 2
					packet, encode_error = encode_frame16(
						&e,
						{y16, w},
						{chroma_u16, w / 2},
						{chroma_v16, w / 2},
					)
				}
				testing.expect_value(t, encode_error, Error.None)
				if encode_error != .None do return
				testing.expect_value(t, len(packet) > 0, frame >= in_flight - 1)
				append(stream, ..packet)
				delete(packet)
			}
			for {
				packet, flush_error := flush_encoder(&e)
				testing.expect_value(t, flush_error, Error.None)
				if packet == nil || flush_error != .None do break
				append(stream, ..packet)
				delete(packet)
			}
			testing.expect_value(t, e.returned, frames)
		}
		testing.expect(t, len(streams[0]) > 0 && string(streams[0][:]) == string(streams[1][:]))
		stream := streams[0]
		path := codec == .H264 ? "/tmp/odecs-gpu-h264.264" : "/tmp/odecs-gpu-h265.265"
		testing.expect(t, os.write_entire_file(path, stream[:]) == nil)
	}
}

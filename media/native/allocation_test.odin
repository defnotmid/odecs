package media_native

import media ".."
import avcd "../../video/h264/decoder"
import "base:runtime"
import "core:mem"
import "core:testing"

@(private)
Native_Allocation_Failure :: struct {
	backing:   mem.Allocator,
	remaining: int,
}

@(private)
native_allocation_failure :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old: rawptr,
	old_size: int,
	loc: runtime.Source_Code_Location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	f := (^Native_Allocation_Failure)(data)
	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		if f.remaining == 0 do return nil, .Out_Of_Memory
		if f.remaining > 0 do f.remaining -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old, old_size, loc)
}

@(test)
test_native_avc_lazy_storage_failure_maps_diagnostic_and_preserves_delivery_lifetime :: proc(
	t: ^testing.T,
) {
	when !OICUT_NATIVE_H264 do return
	cfg := media.Config {
		codec      = .H264,
		operation  = .Encode,
		preference = .Native,
		width      = 16,
		height     = 16,
		bit_depth  = 8,
		qp         = 26,
		gop_size   = 1,
	}
	encoder: media.Session
	testing.expect_value(
		t,
		media.open(&encoder, cfg, []media.Provider{provider()}),
		media.Error.None,
	)
	if encoder.state == nil do return
	encoded: Packet_Sink
	defer {delete(encoded.data); delete(encoded.ranges)}
	input: [3][1024]u8
	testing.expect_value(
		t,
		media.encode_video(
			&encoder,
			test_video_input(cfg, 0, &input),
			{packet = capture_packet, user = &encoded},
		),
		media.Error.None,
	)
	testing.expect_value(t, media.close(&encoder), media.Error.None)
	cfg.operation = .Decode
	for allowed in 0 ..< 3 {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
		f := Native_Allocation_Failure{mem.tracking_allocator(&track), -1}
		decoder: media.Session
		testing.expect_value(
			t,
			media.open(
				&decoder,
				cfg,
				[]media.Provider{provider()},
				{procedure = native_allocation_failure, data = &f},
			),
			media.Error.None,
		)
		if decoder.state == nil do return
		f.remaining = allowed
		frames := 0
		packet := media.Packet {
			data    = encoded.data[:],
			framing = .Annex_B,
		}
		receiver := media.Receiver {
			video = count_video,
			user  = &frames,
		}
		testing.expect_value(t, media.decode(&decoder, packet, receiver), media.Error.Codec_Error)
		testing.expect_value(t, decoder.error_detail, avcd.error_description(.Allocation_Failed))
		testing.expect_value(t, frames, 0)
		testing.expect(t, decoder.failed && ((^State)(decoder.state)).avc_decoder.curr == nil)
		testing.expect_value(t, media.decode(&decoder, packet, receiver), media.Error.Failed)
		testing.expect_value(t, media.drain(&decoder, receiver), media.Error.Failed)
		testing.expect_value(t, media.close(&decoder), media.Error.None)
		testing.expect_value(t, track.current_memory_allocated, i64(0))
		testing.expect_value(t, len(track.bad_free_array), 0)
	}
}

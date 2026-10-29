package media_avcodec

import "core:testing"
import media ".."

@(private)
Test_Sink :: struct {
	packets: [dynamic]u8,
	frames:  int,
	width:   int,
	height:  int,
	depth:   int,
	chroma:  media.Chroma,
	color:   media.Color,
	pocs:    [dynamic]int,
}

@(private)
on_test_packet :: proc(packet: media.Packet, user: rawptr) {
	sink := (^Test_Sink)(user)
	append(&sink.packets, ..packet.data)
}

@(private)
on_test_frame :: proc(frame: media.Video_Frame, user: rawptr) {
	sink := (^Test_Sink)(user)
	sink.frames += 1
	sink.width = frame.width
	sink.height = frame.height
	sink.depth = frame.bit_depth
	sink.chroma = frame.chroma
	sink.color = frame.color
	append(&sink.pocs, frame.poc)
}

@(test)
test_avcodec_round_trip_h264_and_h265 :: proc(t: ^testing.T) {
	_, ok := ensure_api()
	if !ok do return

	for codec in ([2]media.Codec{.H264, .H265}) {
		enc_cfg := media.default_config(codec, .Encode)
		enc_cfg.width, enc_cfg.height = 64, 48
		enc_cfg.qp = 20
		enc_cfg.gop_size = 4
		enc_cfg.color = {1, 1, 1, false}
		if probe(enc_cfg, nil) != .None do continue

		providers := []media.Provider{provider()}

		// Require_Hardware must not accept a software system codec.
		hw_cfg := enc_cfg
		hw_cfg.preference = .Require_Hardware
		hw_session: media.Session
		testing.expect_value(t, media.open(&hw_session, hw_cfg, providers), media.Error.Unavailable)

		encoder: media.Session
		testing.expect_value(t, media.open(&encoder, enc_cfg, providers), media.Error.None)
		testing.expect_value(t, encoder.backend, media.Backend.AVCodec)

		sink: Test_Sink
		defer {
			delete(sink.packets)
			delete(sink.pocs)
		}

		y_plane := make([]u8, 64 * 48)
		u_plane := make([]u8, 32 * 24)
		v_plane := make([]u8, 32 * 24)
		defer {
			delete(y_plane)
			delete(u_plane)
			delete(v_plane)
		}

		for f in 0 ..< 6 {
			for i in 0 ..< len(y_plane) do y_plane[i] = u8((i + f * 17) & 0xFF)
			for i in 0 ..< len(u_plane) {
				u_plane[i] = 128
				v_plane[i] = 128
			}
			vf := media.Video_Frame {
				width        = 64,
				height       = 48,
				bit_depth    = 8,
				storage_bits = 8,
				chroma       = .YUV420,
				planes       = {{y_plane, 64}, {u_plane, 32}, {v_plane, 32}},
				storage      = .Host,
			}
			testing.expect_value(t, media.encode_video(&encoder, vf, {packet = on_test_packet, user = &sink}), media.Error.None)
		}
		testing.expect_value(t, media.drain(&encoder, {packet = on_test_packet, user = &sink}), media.Error.None)
		testing.expect_value(t, media.close(&encoder), media.Error.None)
		testing.expect(t, len(sink.packets) > 0)

		dec_cfg := media.default_config(codec, .Decode)
		if probe(dec_cfg, nil) != .None do continue

		decoder: media.Session
		testing.expect_value(t, media.open(&decoder, dec_cfg, providers), media.Error.None)
		testing.expect_value(t, media.decode(&decoder, {data = sink.packets[:], framing = .Annex_B}, {video = on_test_frame, user = &sink}), media.Error.None)
		testing.expect_value(t, media.drain(&decoder, {video = on_test_frame, user = &sink}), media.Error.None)
		testing.expect_value(t, media.close(&decoder), media.Error.None)

		testing.expect_value(t, sink.frames, 6)
		testing.expect_value(t, sink.width, 64)
		testing.expect_value(t, sink.height, 48)
		testing.expect_value(t, sink.depth, 8)
		testing.expect_value(t, sink.chroma, media.Chroma.YUV420)
		testing.expect_value(t, sink.color, media.Color{1, 1, 1, false})
	}
}

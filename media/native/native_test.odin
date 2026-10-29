package media_native

import media ".."
import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"

Packet_Range :: struct {
	offset, length: int,
}
Packet_Sink :: struct {
	data:   [dynamic]u8,
	ranges: [dynamic]Packet_Range,
}
Video_Sink :: struct {
	t:      ^testing.T,
	config: media.Config,
	frames: int,
	bytes:  [dynamic]u8,
}
Audio_Sink :: struct {
	frames:  int,
	samples: [dynamic]f32,
}

capture_packet :: proc(packet: media.Packet, user: rawptr) {
	s := (^Packet_Sink)(user)
	append(&s.ranges, Packet_Range{len(s.data), len(packet.data)})
	append(&s.data, ..packet.data)
}

capture_video :: proc(frame: media.Video_Frame, user: rawptr) {
	s := (^Video_Sink)(user)
	testing.expect_value(s.t, media.validate_frame(frame), media.Error.None)
	testing.expect_value(s.t, frame.width, s.config.width)
	testing.expect_value(s.t, frame.height, s.config.height)
	testing.expect_value(s.t, frame.chroma, s.config.chroma)
	testing.expect_value(s.t, frame.bit_depth, s.config.bit_depth)
	sw, sh := media.chroma_subsampling(frame.chroma)
	for c in 0 ..< 3 {
		if c > 0 && frame.chroma == .Monochrome do break
		w := c == 0 ? frame.width : frame.width / sw
		h := c == 0 ? frame.height : frame.height / sh
		p := frame.planes[c]
		for y in 0 ..< h {
			row := p.data[y * p.stride:][:w * (frame.storage_bits / 8)]
			append(&s.bytes, ..row)
		}
	}
	s.frames += 1
}

capture_audio :: proc(frame: media.Audio_Frame, user: rawptr) {
	s := (^Audio_Sink)(user)
	s.frames += 1
	append(&s.samples, ..frame.samples)
}

count_video :: proc(frame: media.Video_Frame, user: rawptr) {
	(^int)(user)^ += 1
}

test_video_input :: proc(
	config: media.Config,
	index: int,
	buffers: ^[3][1024]u8,
) -> media.Video_Frame {
	f := media.Video_Frame {
		width        = config.width,
		height       = config.height,
		bit_depth    = config.bit_depth,
		storage_bits = config.bit_depth == 8 ? 8 : 16,
		chroma       = config.chroma,
	}
	sw, sh := media.chroma_subsampling(config.chroma)
	for c in 0 ..< 3 {
		if c > 0 && config.chroma == .Monochrome do break
		w := c == 0 ? config.width : config.width / sw
		h := c == 0 ? config.height : config.height / sh
		stride := w * (f.storage_bits / 8) + 4
		f.planes[c] = {buffers[c][:stride * h], stride}
		for y in 0 ..< h do for x in 0 ..< w {
			value := u16((x * 13 + y * 7 + index * 11 + c * 23) & ((1 << uint(config.bit_depth)) - 1))
			at := y * stride + x * (f.storage_bits / 8)
			buffers[c][at] = u8(value)
			if f.storage_bits == 16 do buffers[c][at + 1] = u8(value >> 8)
		}
	}
	return f
}

// Compare public decoded planes to the native encoder's independent
// reconstruction, including padding removal and HEVC's u16 storage at 8-bit.
append_reconstruction :: proc(session: ^media.Session, out: ^[dynamic]u8) {
	s := (^State)(session.state)
	cfg := session.config
	sw, sh := media.chroma_subsampling(cfg.chroma)
	for c in 0 ..< 3 {
		if c > 0 && cfg.chroma == .Monochrome do break
		w := c == 0 ? cfg.width : cfg.width / sw
		h := c == 0 ? cfg.height : cfg.height / sh
		if s.avc_encoder != nil {
			b := s.avc_encoder.curr.buf
			p := c == 0 ? b.y : (c == 1 ? b.u : b.v)
			stride := c == 0 ? b.y_stride : b.uv_stride
			for y in 0 ..< h do append(out, ..p[y * stride:y * stride + w])
		} else {
			// Decoded HEVC uses one byte per sample for 8-bit pictures, two
			// little-endian bytes otherwise.
			r := s.hevc_encoder.rec
			p := c == 0 ? r.y : (c == 1 ? r.u : r.v)
			for y in 0 ..< h do for x in 0 ..< w {
				value := p.data[p.offset + y * p.stride + x]
				append(out, u8(value))
				if cfg.bit_depth > 8 do append(out, u8(value >> 8))
			}
		}
	}
}

@(test)
test_video_round_trip_matches_reconstruction :: proc(t: ^testing.T) {
	configs := []media.Config {
		{
			codec = .H264,
			operation = .Encode,
			width = 16,
			height = 16,
			bit_depth = 8,
			qp = 26,
			gop_size = 3,
		},
		{codec = .H265, operation = .Encode, width = 16, height = 16, bit_depth = 8, qp = 26},
		{
			codec = .H265,
			operation = .Encode,
			width = 16,
			height = 16,
			bit_depth = 8,
			qp = 26,
			gop_size = 3,
		},
		{
			codec = .H265,
			operation = .Encode,
			width = 16,
			height = 16,
			bit_depth = 10,
			qp = 26,
			gop_size = 4,
		},
		{
			codec = .H265,
			operation = .Encode,
			width = 16,
			height = 16,
			bit_depth = 10,
			chroma = .YUV444,
			qp = 26,
		},
		{
			codec = .H265,
			operation = .Encode,
			width = 17,
			height = 19,
			bit_depth = 10,
			chroma = .Monochrome,
			qp = 26,
		},
	}
	for config in configs {
		cfg := config
		cfg.preference = .Native
		packets: Packet_Sink
		reconstructed: [dynamic]u8
		defer {delete(packets.data); delete(packets.ranges); delete(reconstructed)}
		encoder: media.Session
		enabled := (cfg.codec == .H264 && ODECS_NATIVE_H264) || (cfg.codec == .H265 && ODECS_NATIVE_H265)
		testing.expect_value(
			t,
			media.open(&encoder, cfg, []media.Provider{provider()}),
			enabled ? media.Error.None : media.Error.Unavailable,
		)
		if !enabled do continue
		if encoder.state == nil do continue
		receiver := media.Receiver {
			packet = capture_packet,
			user   = &packets,
		}
		for i in 0 ..< 12 {
			buffers: [3][1024]u8
			frame := test_video_input(cfg, i, &buffers)
			testing.expect_value(
				t,
				media.encode_video(&encoder, frame, receiver),
				media.Error.None,
			)
			append_reconstruction(&encoder, &reconstructed)
		}
		testing.expect_value(t, media.drain(&encoder, receiver), media.Error.None)
		bytes, calls := len(packets.data), len(packets.ranges)
		testing.expect_value(t, media.drain(&encoder, receiver), media.Error.None)
		testing.expect_value(t, len(packets.data), bytes)
		testing.expect_value(t, len(packets.ranges), calls)
		testing.expect_value(t, media.close(&encoder), media.Error.None)

		cfg.operation = .Decode
		decoder: media.Session
		testing.expect_value(
			t,
			media.open(&decoder, cfg, []media.Provider{provider()}),
			media.Error.None,
		)
		decoded := Video_Sink {
			t      = t,
			config = cfg,
		}
		defer delete(decoded.bytes)
		for r in packets.ranges {
			testing.expect_value(
				t,
				media.decode(
					&decoder,
					{data = packets.data[r.offset:][:r.length], framing = .Annex_B},
					{video = capture_video, user = &decoded},
				),
				media.Error.None,
			)
		}
		testing.expect_value(
			t,
			media.drain(&decoder, {video = capture_video, user = &decoded}),
			media.Error.None,
		)
		testing.expect_value(t, decoded.frames, 12)
		testing.expect(t, slice.equal(decoded.bytes[:], reconstructed[:]))
		testing.expect_value(
			t,
			media.drain(&decoder, {video = capture_video, user = &decoded}),
			media.Error.None,
		)
		testing.expect_value(t, decoded.frames, 12)
		testing.expect_value(t, media.close(&decoder), media.Error.None)
		testing.expect_value(t, media.close(&decoder), media.Error.None)
	}
}

@(test)
test_aac_round_trip_and_drain_once :: proc(t: ^testing.T) {
	for channels in 1 ..= 2 {
		cfg := media.Config {
			codec       = .AAC,
			operation   = .Encode,
			preference  = .Native,
			sample_rate = 48000,
			channels    = channels,
			bit_rate    = 64000 * channels,
		}
		encoder: media.Session
		testing.expect_value(
			t,
			media.open(&encoder, cfg, []media.Provider{provider()}),
			media.Error.None,
		)
		packets: Packet_Sink
		defer {delete(packets.data); delete(packets.ranges)}
		input: [5 * 2048]f32
		for &v, i in input[:5 * 1024 * channels] do v = f32(0.4 * math.sin(2 * math.PI * f64(997 + 320 * (i % channels)) * f64(i / channels) / 48000))
		for i in 0 ..< 5 {
			testing.expect_value(
				t,
				media.encode_audio(
					&encoder,
					{
						samples = input[i * 1024 * channels:(i + 1) * 1024 * channels],
						sample_rate = 48000,
						channels = channels,
						samples_per_channel = 1024,
					},
					{packet = capture_packet, user = &packets},
				),
				media.Error.None,
			)
		}
		testing.expect_value(
			t,
			media.drain(&encoder, {packet = capture_packet, user = &packets}),
			media.Error.None,
		)
		testing.expect_value(t, len(packets.ranges), 6)
		testing.expect_value(
			t,
			media.drain(&encoder, {packet = capture_packet, user = &packets}),
			media.Error.None,
		)
		testing.expect_value(t, len(packets.ranges), 6)
		testing.expect_value(t, media.close(&encoder), media.Error.None)
		cfg.operation = .Decode
		decoder: media.Session
		testing.expect_value(
			t,
			media.open(&decoder, cfg, []media.Provider{provider()}),
			media.Error.None,
		)
		decoded: Audio_Sink
		defer delete(decoded.samples)
		testing.expect_value(
			t,
			media.decode(
				&decoder,
				{data = packets.data[:], framing = .ADTS},
				{audio = capture_audio, user = &decoded},
			),
			media.Error.None,
		)
		testing.expect_value(
			t,
			media.drain(&decoder, {audio = capture_audio, user = &decoded}),
			media.Error.None,
		)
		testing.expect_value(t, decoded.frames, 6)
		power, error: f64
		for v, i in input[:5 * 1024 * channels] {
			delta := f64(v - decoded.samples[1024 * channels + i])
			power += f64(v) * f64(v)
			error += delta * delta
		}
		testing.expect(t, error / power < 0.002)
		testing.expect_value(t, media.close(&decoder), media.Error.None)
	}
}

unavailable_probe :: proc(config: media.Config, user: rawptr) -> media.Error {return .Unavailable}
unavailable_open :: proc(
	session: ^media.Session,
	config: media.Config,
	user: rawptr,
) -> media.Error {return .Unavailable}
unsupported_probe :: proc(config: media.Config, user: rawptr) -> media.Error {return .Unsupported}
must_not_probe :: proc(config: media.Config, user: rawptr) -> media.Error {panic(
		"Native preference probed hardware",
	)}

@(test)
test_native_device_input_is_rejected_before_consumption :: proc(t: ^testing.T) {
	cfg := media.default_config(ODECS_NATIVE_H264 ? .H264 : .VP9, .Encode)
	cfg.width, cfg.height, cfg.preference = 16, 16, .Native
	session: media.Session
	testing.expect_value(
		t,
		media.open(&session, cfg, []media.Provider{provider()}),
		media.Error.None,
	)
	defer media.close(&session)
	// This is deliberately not a Vulkan descriptor: native must reject it
	// before interpreting provider-specific storage or advancing the encoder.
	dummy: u8
	frame := media.Video_Frame {
		width     = 16,
		height    = 16,
		bit_depth = 8,
		chroma    = .YUV420,
		storage   = .Device,
		surface   = &dummy,
	}
	testing.expect_value(t, media.encode_video(&session, frame, {}), media.Error.Unsupported)
	when ODECS_NATIVE_H264 {
		testing.expect(t, !session.failed && ((^State)(session.state)).avc_encoder.frames_coded == 0)
	}
	buffers: [3][1024]u8
	testing.expect_value(
		t,
		media.encode_video(&session, test_video_input(cfg, 0, &buffers), {}),
		media.Error.None,
	)
	when ODECS_NATIVE_H264 {
		testing.expect(t, ((^State)(session.state)).avc_encoder.frames_coded == 1)
	}
}

@(test)
test_selection_fallback_and_owned_allocator :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	providers := []media.Provider {
		provider(),
		{
			backend = .Vulkan,
			name = "unavailable hardware",
			probe = unavailable_probe,
			open = unavailable_open,
		},
	}
	cfg := media.default_config(ODECS_NATIVE_H265 ? .H265 : .VP9, .Decode)
	session: media.Session
	cfg.preference = .Require_Hardware
	testing.expect_value(
		t,
		media.open(&session, cfg, providers, mem.tracking_allocator(&track)),
		media.Error.Unavailable,
	)
	testing.expect_value(t, session.state, rawptr(nil))
	cfg.preference = .Automatic
	providers[1].probe = unsupported_probe
	testing.expect_value(
		t,
		media.open(&session, cfg, providers, mem.tracking_allocator(&track)),
		media.Error.None,
	)
	testing.expect_value(t, session.backend, media.Backend.Native)
	testing.expect_value(t, session.hardware_error, media.Error.Unsupported)
	testing.expect(t, track.current_memory_allocated > 0)
	testing.expect_value(t, media.close(&session), media.Error.None)
	testing.expect_value(t, track.current_memory_allocated, i64(0))
	cfg.preference = .Native
	providers[1].probe = must_not_probe
	testing.expect_value(
		t,
		media.open(&session, cfg, providers, mem.tracking_allocator(&track)),
		media.Error.None,
	)
	testing.expect_value(t, session.backend, media.Backend.Native)
	testing.expect_value(t, media.close(&session), media.Error.None)
	testing.expect_value(t, track.current_memory_allocated, i64(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_streaming_decode_is_bounded_and_malformed_input_stops :: proc(t: ^testing.T) {
	for codec in ([]media.Codec{.H264, .H265}) {
		if (codec == .H264 && !ODECS_NATIVE_H264) || (codec == .H265 && !ODECS_NATIVE_H265) do continue
		cfg := media.default_config(codec, .Encode)
		cfg.preference, cfg.width, cfg.height = .Native, 16, 16
		encoder: media.Session
		testing.expect_value(
			t,
			media.open(&encoder, cfg, []media.Provider{provider()}),
			media.Error.None,
		)
		packets: Packet_Sink
		defer {delete(packets.data); delete(packets.ranges)}
		for i in 0 ..< 96 {
			buffers: [3][1024]u8
			testing.expect_value(
				t,
				media.encode_video(
					&encoder,
					test_video_input(cfg, i, &buffers),
					{packet = capture_packet, user = &packets},
				),
				media.Error.None,
			)
		}
		testing.expect_value(
			t,
			media.drain(&encoder, {packet = capture_packet, user = &packets}),
			media.Error.None,
		)
		testing.expect_value(t, media.close(&encoder), media.Error.None)
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		cfg.operation = .Decode
		decoder: media.Session
		testing.expect_value(
			t,
			media.open(
				&decoder,
				cfg,
				[]media.Provider{provider()},
				mem.tracking_allocator(&track),
			),
			media.Error.None,
		)
		frames := 0
		warm_peak: i64
		for r, i in packets.ranges {
			testing.expect_value(
				t,
				media.decode(
					&decoder,
					{data = packets.data[r.offset:][:r.length], framing = .Annex_B},
					{video = count_video, user = &frames},
				),
				media.Error.None,
			)
			if i < 32 {warm_peak = max(warm_peak, track.current_memory_allocated)} else {
				testing.expect(t, track.current_memory_allocated <= warm_peak + 32 * 1024)
			}
		}
		testing.expect_value(
			t,
			media.drain(&decoder, {video = count_video, user = &frames}),
			media.Error.None,
		)
		testing.expect_value(t, frames, 96)
		testing.expect_value(t, media.close(&decoder), media.Error.None)
		testing.expect_value(t, track.current_memory_allocated, i64(0))

		testing.expect_value(
			t,
			media.open(
				&decoder,
				cfg,
				[]media.Provider{provider()},
				mem.tracking_allocator(&track),
			),
			media.Error.None,
		)
		bad := []u8{0xFF, 0}
		testing.expect_value(
			t,
			media.decode(&decoder, {data = bad, framing = .NAL}, {}),
			media.Error.Invalid_Input,
		)
		testing.expect_value(
			t,
			media.decode(&decoder, {data = packets.data[:], framing = .Annex_B}, {}),
			media.Error.Failed,
		)
		testing.expect_value(t, media.drain(&decoder, {}), media.Error.Failed)
		testing.expect_value(t, media.close(&decoder), media.Error.None)
		testing.expect_value(t, track.current_memory_allocated, i64(0))
	}
	// Audio uses the same fail-stop contract after a malformed ADTS packet.
	audio: media.Session
	testing.expect_value(
		t,
		media.open(
			&audio,
			{
				codec = .AAC,
				operation = .Decode,
				preference = .Native,
				sample_rate = 48000,
				channels = 1,
			},
			[]media.Provider{provider()},
		),
		media.Error.None,
	)
	testing.expect_value(
		t,
		media.decode(&audio, {data = []u8{0xFF, 0xF1}, framing = .ADTS}, {}),
		media.Error.Invalid_Input,
	)
	testing.expect_value(
		t,
		media.decode(&audio, {data = []u8{0xFF, 0xF1}, framing = .ADTS}, {}),
		media.Error.Failed,
	)
	testing.expect_value(t, media.drain(&audio, {}), media.Error.Failed)
	testing.expect_value(t, media.close(&audio), media.Error.None)
}

Reentrant_Sink :: struct {
	t:       ^testing.T,
	session: ^media.Session,
	calls:   int,
}
reentrant_packet :: proc(packet: media.Packet, user: rawptr) {
	s := (^Reentrant_Sink)(user)
	s.calls += 1
	testing.expect_value(s.t, media.close(s.session), media.Error.Busy)
	testing.expect_value(s.t, media.drain(s.session, {}), media.Error.Busy)
	testing.expect_value(s.t, media.encode_audio(s.session, {}, {}), media.Error.Busy)
}

@(test)
test_callback_reentry_is_rejected :: proc(t: ^testing.T) {
	session: media.Session
	cfg := media.default_config(.AAC, .Encode)
	cfg.preference, cfg.sample_rate, cfg.channels = .Native, 48000, 1
	testing.expect_value(
		t,
		media.open(&session, cfg, []media.Provider{provider()}),
		media.Error.None,
	)
	input: [1024]f32
	sink := Reentrant_Sink {
		t       = t,
		session = &session,
	}
	testing.expect_value(
		t,
		media.encode_audio(
			&session,
			{samples = input[:], sample_rate = 48000, channels = 1, samples_per_channel = 1024},
			{packet = reentrant_packet, user = &sink},
		),
		media.Error.None,
	)
	testing.expect_value(t, sink.calls, 0)
	testing.expect_value(
		t,
		media.encode_audio(
			&session,
			{samples = input[:], sample_rate = 48000, channels = 1, samples_per_channel = 1024},
			{packet = reentrant_packet, user = &sink},
		),
		media.Error.None,
	)
	testing.expect_value(t, sink.calls, 1)
	testing.expect_value(t, media.close(&session), media.Error.None)
}

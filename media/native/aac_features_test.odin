package media_native

import media ".."
import aac "../../audio/aac"
import aacd "../../audio/aac/decoder"
import aace "../../audio/aac/encoder"
import "core:mem"
import "core:slice"
import "core:testing"

AAC_Feature_Packet :: struct {
	offset, bytes:                 int,
	framing:                       media.Framing,
	sample_index:                  i64,
	duration_samples, sample_rate: int,
}
AAC_Feature_Packets :: struct {
	t:       ^testing.T,
	state:   ^State,
	data:    [dynamic]u8,
	packets: [dynamic]AAC_Feature_Packet,
}
capture_feature_packet :: proc(packet: media.Packet, user: rawptr) {
	s := (^AAC_Feature_Packets)(user)
	if s.state != nil {
		testing.expect_value(s.t, raw_data(packet.data), raw_data(s.state.aac_encoder.packet))
		testing.expect_value(s.t, len(packet.data), len(s.state.aac_encoder.packet))
		testing.expect_value(s.t, len(s.state.encoded), 0)
	}
	append(
		&s.packets,
		AAC_Feature_Packet {
			len(s.data),
			len(packet.data),
			packet.framing,
			packet.sample_index,
			packet.duration_samples,
			packet.sample_rate,
		},
	)
	append(&s.data, ..packet.data)
}
AAC_Feature_Audio :: struct {
	t:                 ^testing.T,
	n, channels, rate: int,
	first_index:       i64,
	calls:             int,
	samples:           [dynamic]f32,
}
capture_feature_audio :: proc(frame: media.Audio_Frame, user: rawptr) {
	s := (^AAC_Feature_Audio)(user)
	testing.expect_value(s.t, frame.samples_per_channel, s.n)
	testing.expect_value(s.t, frame.channels, s.channels)
	testing.expect_value(s.t, frame.sample_rate, s.rate)
	testing.expect_value(s.t, frame.sample_index, s.first_index + i64(s.calls * s.n))
	testing.expect_value(s.t, len(frame.samples), s.n * s.channels)
	append(&s.samples, ..frame.samples)
	s.calls += 1
}
aac_feature_input :: proc(input: []f32, n, channels, frame: int) {
	for i in 0 ..< n do for ch in 0 ..< channels {
		input[i * channels + ch] = f32(((i * (ch + 3) + frame * 67) % 511) - 255) / 768
	}
}

// Direct codec output is the transport/priming oracle. The common path must
// publish the same complete individual AUs, including the two drain packets.
@(test)
aac_feature_transport_frame_shapes_and_borrowed_packets :: proc(t: ^testing.T) {
	cases := []media.Config {
		{channels = 1},
		{channels = 2},
		{channels = 6},
		{channels = 7},
		{channels = 8},
		{channels = 2, frame_samples = 960, audio_transport = .Raw},
		{channels = 7, frame_samples = 960, audio_transport = .LOAS},
		{channels = 8, audio_transport = .LOAS},
		{channels = 1, sample_rate = 7350, bit_rate = 32000, audio_transport = .LOAS},
	}
	for base in cases {
		cfg := base
		cfg.codec, cfg.operation, cfg.preference = .AAC, .Encode, .Native
		if cfg.sample_rate == 0 do cfg.sample_rate = 48000
		n := cfg.frame_samples == 0 ? 1024 : cfg.frame_samples
		encoder: media.Session
		testing.expect_value(
			t,
			media.open(&encoder, cfg, []media.Provider{provider()}),
			media.Error.None,
		)
		if encoder.state == nil do continue
		packets := AAC_Feature_Packets {
			t     = t,
			state = (^State)(encoder.state),
		}
		defer {delete(packets.data); delete(packets.packets)}
		direct := new(aace.Encoder)
		defer {aace.destroy_encoder(direct); free(direct)}
		acfg := aac.Config {
			sample_rate   = cfg.sample_rate,
			channels      = cfg.channels,
			bit_rate      = cfg.bit_rate,
			frame_samples = cfg.frame_samples,
		}
		testing.expect_value(
			t,
			aace.init_encoder(direct, acfg, aac_transport(cfg.audio_transport)),
			aac.Error.None,
		)
		expected: [dynamic]u8
		defer delete(expected)
		input: [8 * 1024]f32
		for frame in 0 ..< 3 {
			aac_feature_input(input[:n * cfg.channels], n, cfg.channels, frame)
			packet, e := aace.encode_frame_borrowed(direct, input[:n * cfg.channels])
			testing.expect_value(t, e, aac.Error.None)
			append(&expected, ..packet)
			testing.expect_value(
				t,
				media.encode_audio(
					&encoder,
					{
						samples = input[:n * cfg.channels],
						sample_rate = cfg.sample_rate,
						channels = cfg.channels,
						samples_per_channel = n,
					},
					{packet = capture_feature_packet, user = &packets},
				),
				media.Error.None,
			)
			testing.expect_value(t, len(packets.packets), frame)
		}
		for {
			packet, e := aace.flush_encoder_next_borrowed(direct)
			testing.expect_value(t, e, aac.Error.None)
			if e != .None || len(packet) == 0 do break
			append(&expected, ..packet)
		}
		testing.expect_value(
			t,
			media.drain(&encoder, {packet = capture_feature_packet, user = &packets}),
			media.Error.None,
		)
		testing.expect_value(t, len(packets.packets), 4)
		testing.expect(t, slice.equal(packets.data[:], expected[:]))
		for packet, i in packets.packets {
			testing.expect_value(t, packet.framing, aac_framing(cfg.audio_transport))
			testing.expect_value(t, packet.sample_index, i64((i - 1) * n))
			testing.expect_value(t, packet.duration_samples, n)
			testing.expect_value(t, packet.sample_rate, cfg.sample_rate)
			if packet.framing == .ADTS {
				h, _, e := aac.parse_adts(packets.data[packet.offset:][:packet.bytes])
				testing.expect_value(t, e, aac.Error.None)
				testing.expect_value(t, h.frame_bytes, packet.bytes)
				testing.expect_value(t, h.raw_block_count, 1)
			}
		}
		testing.expect_value(
			t,
			media.drain(&encoder, {packet = capture_feature_packet, user = &packets}),
			media.Error.None,
		)
		testing.expect_value(t, len(packets.packets), 4)
		testing.expect_value(t, media.close(&encoder), media.Error.None)

		cfg.operation = .Decode
		decoder: media.Session
		testing.expect_value(
			t,
			media.open(&decoder, cfg, []media.Provider{provider()}),
			media.Error.None,
		)
		decoded := AAC_Feature_Audio {
			t           = t,
			n           = n,
			channels    = cfg.channels,
			rate        = cfg.sample_rate,
			first_index = -i64(n),
		}
		defer delete(decoded.samples)
		for p in packets.packets do testing.expect_value(t, media.decode(&decoder, {data = packets.data[p.offset:][:p.bytes], framing = p.framing, sample_index = p.sample_index, duration_samples = p.duration_samples, sample_rate = p.sample_rate}, {audio = capture_feature_audio, user = &decoded}), media.Error.None)
		testing.expect_value(t, decoded.calls, 4)
		testing.expect_value(t, media.close(&decoder), media.Error.None)
	}
}

// An out-of-band PCE with nondefault tags is consumed at open. Transport
// batches still publish one frame view per AU with exact raw-decoder PCM.
@(test)
aac_feature_asc_pce_and_transactional_transport_batches :: proc(t: ^testing.T) {
	for n in ([2]int{1024, 960}) {
		acfg := aac.Config {
			sample_rate   = 48000,
			channels      = 3,
			frame_samples = n,
			use_pce       = true,
		}
		program, pe := aac.default_program_config(acfg)
		testing.expect_value(t, pe, aac.Error.None)
		program.front[0].tag, program.front[1].tag = 5, 9
		acfg.program_config = program
		asc: [dynamic]u8
		defer delete(asc)
		testing.expect_value(t, aac.append_audio_specific_config(&asc, acfg), aac.Error.None)
		direct := new(aace.Encoder)
		defer {aace.destroy_encoder(direct); free(direct)}
		testing.expect_value(t, aace.init_encoder(direct, acfg, .Raw), aac.Error.None)
		units: [3][dynamic]u8
		defer for &unit in units do delete(unit)
		input: [3 * 1024]f32
		for frame in 0 ..< 2 {
			aac_feature_input(input[:n * 3], n, 3, frame)
			packet, e := aace.encode_frame_borrowed(direct, input[:n * 3])
			testing.expect_value(t, e, aac.Error.None)
			if frame == 1 do append(&units[0], ..packet)
		}
		for i in 1 ..< 3 {
			packet, e := aace.flush_encoder_next_borrowed(direct)
			testing.expect_value(t, e, aac.Error.None)
			append(&units[i], ..packet)
		}
		oracle := new(aacd.Decoder)
		defer free(oracle)
		testing.expect_value(t, aacd.init_decoder(oracle, acfg), aac.Error.None)
		expected: [dynamic]f32
		defer delete(expected)
		pcm: [3 * 1024]f32
		for unit in units {
			samples, e := aacd.decode_frame(oracle, unit[:], pcm[:])
			testing.expect_value(t, e, aac.Error.None)
			testing.expect_value(t, samples, n)
			append(&expected, ..pcm[:n * 3])
		}
		cfg := media.Config {
			codec         = .AAC,
			operation     = .Decode,
			preference    = .Native,
			sample_rate   = 48000,
			channels      = 3,
			frame_samples = n,
			extradata     = asc[:],
		}
		for framing in ([]media.Framing{.Raw_AAC, .LOAS, .ADTS}) {
			if framing == .ADTS && n == 960 do continue
			data: [dynamic]u8
			defer delete(data)
			#partial switch framing {
			case .Raw_AAC:
				for unit in units do append(&data, ..unit[:])
			case .LOAS:
				views := [3][]u8{units[0][:], units[1][:], units[2][:]}
				testing.expect_value(
					t,
					aac.append_loas_blocks(&data, acfg, views[:], false, true),
					aac.Error.None,
				)
			case .ADTS:
				blocks := [3]aac.ADTS_Block {
					{data = units[0][:]},
					{data = units[1][:]},
					{data = units[2][:]},
				}
				testing.expect_value(
					t,
					aac.append_adts_blocks(&data, acfg, blocks[:]),
					aac.Error.None,
				)
			case:
				unreachable()
			}
			decoder: media.Session
			testing.expect_value(
				t,
				media.open(&decoder, cfg, []media.Provider{provider()}),
				media.Error.None,
			)
			decoded := AAC_Feature_Audio {
				t           = t,
				n           = n,
				channels    = 3,
				rate        = 48000,
				first_index = 37,
			}
			defer delete(decoded.samples)
			// The ASC storage is borrowed only during open, then the codec owns
			// its parsed program mapping. Poisoning it cannot change this session.
			saved_asc := asc[0]
			asc[0] = 0xff
			testing.expect_value(
				t,
				media.decode(
					&decoder,
					{
						data = data[:],
						framing = framing,
						sample_index = 37,
						sample_rate = 48000,
						duration_samples = n * 3,
					},
					{audio = capture_feature_audio, user = &decoded},
				),
				media.Error.None,
			)
			asc[0] = saved_asc
			testing.expect_value(t, decoded.calls, 3)
			testing.expect(t, slice.equal(decoded.samples[:], expected[:]))
			testing.expect_value(t, media.close(&decoder), media.Error.None)
			if framing != .Raw_AAC {
				// A late malformed AU inside a transport batch emits no partial
				// callback; the public session then retains its fail-stop contract.
				testing.expect_value(
					t,
					media.open(&decoder, cfg, []media.Provider{provider()}),
					media.Error.None,
				)
				broken_last := make([]u8, len(units[2]))
				defer delete(broken_last)
				copy(broken_last, units[2][:])
				testing.expect(t, broken_last[len(broken_last) - 1] != 0)
				broken_last[len(broken_last) - 1] = 0
				broken: [dynamic]u8
				defer delete(broken)
				if framing == .LOAS {
					views := [3][]u8{units[0][:], units[1][:], broken_last}
					testing.expect_value(
						t,
						aac.append_loas_blocks(&broken, acfg, views[:], false, true),
						aac.Error.None,
					)
				} else {
					blocks := [3]aac.ADTS_Block {
						{data = units[0][:]},
						{data = units[1][:]},
						{data = broken_last},
					}
					testing.expect_value(
						t,
						aac.append_adts_blocks(&broken, acfg, blocks[:]),
						aac.Error.None,
					)
				}
				refused := AAC_Feature_Audio {
					t        = t,
					n        = n,
					channels = 3,
					rate     = 48000,
				}
				defer delete(refused.samples)
				testing.expect_value(
					t,
					media.decode(
						&decoder,
						{data = broken[:], framing = framing},
						{audio = capture_feature_audio, user = &refused},
					),
					media.Error.Invalid_Input,
				)
				testing.expect_value(t, refused.calls, 0)
				testing.expect_value(
					t,
					media.decode(&decoder, {data = data[:], framing = framing}, {}),
					media.Error.Failed,
				)
				testing.expect_value(t, media.close(&decoder), media.Error.None)
			}
		}
		// The caller's Config cannot silently override ASC sample geometry.
		cfg.channels = 2
		invalid: media.Session
		testing.expect_value(
			t,
			media.open(&invalid, cfg, []media.Provider{provider()}),
			media.Error.Invalid_Config,
		)
		testing.expect_value(t, invalid.state, rawptr(nil))
		cfg.channels, cfg.frame_samples = 3, n == 1024 ? 960 : 1024
		testing.expect_value(
			t,
			media.open(&invalid, cfg, []media.Provider{provider()}),
			media.Error.Invalid_Config,
		)
		cfg.frame_samples, cfg.sample_rate = n, 44100
		testing.expect_value(
			t,
			media.open(&invalid, cfg, []media.Provider{provider()}),
			media.Error.Invalid_Config,
		)
	}
}

AAC_No_Allocation_Sink :: struct {
	t:                ^testing.T,
	encoder, decoder: ^media.Session,
	packets, frames:  int,
}
no_allocation_audio :: proc(frame: media.Audio_Frame, user: rawptr) {
	s := (^AAC_No_Allocation_Sink)(user)
	testing.expect_value(s.t, frame.sample_index, i64((s.frames - 1) * 960))
	testing.expect_value(s.t, frame.samples_per_channel, 960)
	s.frames += 1
}
no_allocation_packet :: proc(packet: media.Packet, user: rawptr) {
	s := (^AAC_No_Allocation_Sink)(user)
	state := (^State)(s.encoder.state)
	testing.expect_value(s.t, raw_data(packet.data), raw_data(state.aac_encoder.packet))
	testing.expect_value(s.t, packet.sample_index, i64((s.packets - 1) * 960))
	s.packets += 1
	testing.expect_value(
		s.t,
		media.decode(s.decoder, packet, {audio = no_allocation_audio, user = user}),
		media.Error.None,
	)
}

@(test)
aac_feature_session_allocator_and_no_frame_allocation :: proc(t: ^testing.T) {
	owner, ambient: mem.Tracking_Allocator
	mem.tracking_allocator_init(&owner, context.allocator)
	mem.tracking_allocator_init(&ambient, context.allocator)
	defer mem.tracking_allocator_destroy(&owner)
	defer mem.tracking_allocator_destroy(&ambient)
	owner.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	ambient.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	cfg := media.Config {
		codec           = .AAC,
		operation       = .Encode,
		preference      = .Native,
		sample_rate     = 48000,
		channels        = 8,
		frame_samples   = 960,
		audio_transport = .LOAS,
	}
	encoder, decoder: media.Session
	testing.expect_value(
		t,
		media.open(&encoder, cfg, []media.Provider{provider()}, mem.tracking_allocator(&owner)),
		media.Error.None,
	)
	cfg.operation = .Decode
	testing.expect_value(
		t,
		media.open(&decoder, cfg, []media.Provider{provider()}, mem.tracking_allocator(&owner)),
		media.Error.None,
	)
	if encoder.state == nil ||
	   decoder.state == nil {media.close(&encoder); media.close(&decoder); return}
	allocations := owner.total_allocation_count
	input: [8 * 960]f32
	sink := AAC_No_Allocation_Sink {
		t       = t,
		encoder = &encoder,
		decoder = &decoder,
	}
	{
		context.allocator = mem.tracking_allocator(&ambient)
		for frame in 0 ..< 6 {
			aac_feature_input(input[:], 960, 8, frame)
			testing.expect_value(
				t,
				media.encode_audio(
					&encoder,
					{
						samples = input[:],
						sample_rate = 48000,
						channels = 8,
						samples_per_channel = 960,
					},
					{packet = no_allocation_packet, user = &sink},
				),
				media.Error.None,
			)
		}
		testing.expect_value(
			t,
			media.drain(&encoder, {packet = no_allocation_packet, user = &sink}),
			media.Error.None,
		)
		testing.expect_value(t, media.drain(&decoder, {}), media.Error.None)
		testing.expect_value(t, owner.total_allocation_count, allocations)
		testing.expect_value(t, ambient.total_allocation_count, i64(0))
		testing.expect_value(t, media.close(&encoder), media.Error.None)
		testing.expect_value(t, media.close(&decoder), media.Error.None)
	}
	testing.expect_value(t, sink.packets, 7)
	testing.expect_value(t, sink.frames, 7)
	testing.expect_value(t, owner.current_memory_allocated, i64(0))
	testing.expect_value(t, len(owner.allocation_map), 0)
	testing.expect_value(t, len(owner.bad_free_array), 0)
	testing.expect_value(t, len(ambient.bad_free_array), 0)
	// Allocation refusal is typed before any codec input is consumed.
	cfg.operation = .Encode
	cfg.audio_transport = .ADTS
	failed: media.Session
	testing.expect_value(
		t,
		media.open(&failed, cfg, []media.Provider{provider()}),
		media.Error.Unsupported,
	)
	cfg.audio_transport = .LOAS
	testing.expect_value(
		t,
		media.open(&failed, cfg, []media.Provider{provider()}, mem.nil_allocator()),
		media.Error.Codec_Error,
	)
	testing.expect_value(t, failed.state, rawptr(nil))
}

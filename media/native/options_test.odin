package media_native

import media ".."
import common "../../common"
import avce "../../video/h264/encoder"
import "core:slice"
import "core:testing"

@(test)
test_native_options_admit_only_relevant_encode_geometry :: proc(t: ^testing.T) {
	cfg := media.Config {
		codec      = .H264,
		operation  = .Encode,
		preference = .Native,
		width      = 128,
		height     = 128,
		bit_depth  = 8,
		qp         = 26,
	}
	bad_pool: common.Work_Pool
	for &options in ([]Options{{h264_slice_count = -1}, {h264_slice_count = 9}, {h265_tile_rows = -1}, {pool = &bad_pool}}) {
		testing.expect_value(t, probe(cfg, &options), media.Error.Invalid_Config)
	}
	// The same binding can carry settings for both video encoders and audio;
	// geometry is checked only by the corresponding encode operation.
	options := Options {
		h264_slice_count = 4,
		h265_tile_cols   = 999,
		h265_tile_rows   = 999,
	}
	testing.expect_value(t, probe(cfg, &options), media.Error.None)
	cfg.codec = .H265
	for &bad in ([]Options{{h265_tile_cols = 2}, {h265_tile_cols = 3, h265_tile_rows = 2}, {h265_tile_cols = 2, h265_tile_rows = 3}}) {
		testing.expect_value(t, probe(cfg, &bad), media.Error.Invalid_Config)
	}
	options = {
		h264_slice_count = 999,
		h265_tile_cols   = 2,
		h265_tile_rows   = 2,
	}
	testing.expect_value(t, probe(cfg, &options), media.Error.None)
	cfg.width, cfg.height = 8192, 8192
	options.h265_tile_cols, options.h265_tile_rows = 16, 9
	testing.expect_value(t, probe(cfg, &options), media.Error.Invalid_Config)
	options.h265_tile_rows = 8
	testing.expect_value(t, probe(cfg, &options), media.Error.None)
	cfg.operation, cfg.width, cfg.height = .Decode, 0, 0
	options.h265_tile_rows = 0
	testing.expect_value(t, probe(cfg, &options), media.Error.None)
	cfg = {
		codec       = .AAC,
		operation   = .Encode,
		sample_rate = 48000,
		channels    = 1,
	}
	testing.expect_value(t, probe(cfg, &options), media.Error.None)
}

@(private)
Observed_Native_Pool :: struct {
	work:                 common.Work_Pool,
	delegate:             ^common.Work_Pool,
	calls, largest_range: int,
}

@(private)
observed_native_run :: proc(
	p: ^common.Work_Pool,
	count: int,
	task: common.Range_Proc,
	data: rawptr,
) {
	s := (^Observed_Native_Pool)(p.user)
	s.calls += 1
	s.largest_range = max(s.largest_range, count)
	s.delegate.run(s.delegate, count, task, data)
}

// Native, deterministic planar samples. Starts can deliberately be aligned or
// unaligned, and byte strides can be even, odd or unequal between chroma planes.
@(private)
bound_native_frame :: proc(
	cfg: media.Config,
	index, storage_bits: int,
	buffers: ^[3][32768]u8,
	misaligned: bool = false,
	odd_stride: bool = false,
	unequal_chroma: bool = false,
) -> media.Video_Frame {
	f := media.Video_Frame {
		width        = cfg.width,
		height       = cfg.height,
		bit_depth    = cfg.bit_depth,
		storage_bits = storage_bits,
		chroma       = cfg.chroma,
	}
	sw, sh := media.chroma_subsampling(cfg.chroma)
	for c in 0 ..< 3 {
		if c > 0 && cfg.chroma == .Monochrome do break
		w, h := c == 0 ? cfg.width : cfg.width / sw, c == 0 ? cfg.height : cfg.height / sh
		stride := w * (storage_bits / 8) + 4
		if odd_stride do stride += 1
		if c == 2 && unequal_chroma do stride += 2
		start := int(uintptr(raw_data(buffers[c][:])) % align_of(u16))
		if misaligned do start += 1
		f.planes[c] = {buffers[c][start:start + stride * h], stride}
		for row in 0 ..< h do for col in 0 ..< w {
			value := u16((col * 13 + row * 7 + index * 11 + c * 23) & ((1 << uint(cfg.bit_depth)) - 1))
			at := start + row * stride + col * (storage_bits / 8)
			buffers[c][at] = u8(value)
			if storage_bits == 16 do buffers[c][at + 1] = u8(value >> 8)
		}
	}
	return f
}

@(private)
Native_Lane_Sink :: struct {
	t:       ^testing.T,
	session: ^media.Session,
	output:  Packet_Sink,
	lane:    int,
	idr:     bool,
}

@(private)
capture_native_lane :: proc(packet: media.Packet, user: rawptr) {
	s := (^Native_Lane_Sink)(user)
	state := (^State)(s.session.state)
	encoder := state.avc_encoder
	testing.expect_value(s.t, packet.framing, media.Framing.Annex_B)
	testing.expect(s.t, len(packet.data) != 0 && raw_data(state.encoded) == nil)
	expected := encoder.nal_lanes[s.lane]
	testing.expect(
		s.t,
		raw_data(packet.data) == raw_data(expected) && len(packet.data) == len(expected),
	)
	// One callback owns exactly one complete NAL, rather than a partial row or
	// a whole-frame concatenation. No allocation is needed to inspect framing.
	it := media.Nal_Iterator {
		packet = packet,
	}
	nal, done, error := media.next_nal(&it)
	testing.expect_value(s.t, error, media.Error.None)
	testing.expect(s.t, !done && len(nal) != 0)
	if len(nal) != 0 {
		kind := s.idr ? u8(5) : u8(1)
		if s.idr && s.lane < 2 do kind = s.lane == 0 ? 7 : 8
		testing.expect_value(s.t, nal[0] & 31, kind)
	}
	_, done, error = media.next_nal(&it)
	testing.expect(s.t, done && error == .None)
	testing.expect_value(s.t, media.close(s.session), media.Error.Busy)
	testing.expect_value(s.t, media.drain(s.session, {}), media.Error.Busy)
	testing.expect_value(s.t, media.encode_video(s.session, {}, {}), media.Error.Busy)
	capture_packet(packet, &s.output)
	s.lane += 1
}

@(test)
test_native_provider_pool_and_ordered_lanes_preserve_bytes :: proc(t: ^testing.T) {
	for codec in ([]media.Codec{.H264, .H265}) {
		cfg := media.Config {
			codec      = codec,
			operation  = .Encode,
			preference = .Native,
			width      = 128,
			height     = 128,
			bit_depth  = 8,
			qp         = 26,
			gop_size   = 3,
		}
		pool: common.Static_Pool
		common.init_static_pool(&pool, 2)
		defer common.destroy_static_pool(&pool)
		observed := Observed_Native_Pool {
			delegate = &pool.work_pool,
		}
		observed.work = {
			run  = observed_native_run,
			user = &observed,
		}
		serial_options := Options {
			h264_slice_count = 4,
			h265_tile_cols   = 2,
			h265_tile_rows   = 2,
		}
		parallel_options := serial_options
		parallel_options.pool = &observed.work
		serial, parallel: media.Session
		defer media.close(&serial)
		defer media.close(&parallel)
		testing.expect_value(
			t,
			media.open(&serial, cfg, []media.Provider{provider(&serial_options)}),
			media.Error.None,
		)
		testing.expect_value(
			t,
			media.open(&parallel, cfg, []media.Provider{provider(&parallel_options)}),
			media.Error.None,
		)
		if serial.state == nil || parallel.state == nil do return
		// Scalar settings are captured at open; future provider edits cannot
		// change this session's immutable bitstream/task geometry or pool.
		parallel_options = {
			h264_slice_count = 1,
			h265_tile_cols   = 1,
			h265_tile_rows   = 1,
		}
		state := (^State)(parallel.state)
		testing.expect(t, state.pool == &observed.work)
		if codec == .H264 {
			testing.expect_value(t, state.avc_encoder.config.slice_count, 4)
			testing.expect_value(t, state.avc_encoder.config.checkpoint_capacity, 0)
		} else {
			testing.expect(t, state.hevc_encoder.config.pool == &observed.work)
			testing.expect(
				t,
				state.hevc_encoder.config.tiles_cols == 2 &&
				state.hevc_encoder.config.tiles_rows == 2,
			)
		}
		serial_output: Packet_Sink
		parallel_output := Native_Lane_Sink {
			t       = t,
			session = &parallel,
		}
		defer {delete(serial_output.data); delete(serial_output.ranges)
			delete(parallel_output.output.data)
			delete(parallel_output.output.ranges)}
		oracle: avce.Encoder_State
		oracle_output: [dynamic]u8
		defer avce.destroy_encoder(&oracle)
		if codec == .H264 {
			testing.expect_value(
				t,
				avce.init_encoder(
					&oracle,
					{
						width = cfg.width,
						height = cfg.height,
						qp = cfg.qp,
						gop_size = 3,
						slice_count = 4,
					},
				),
				avce.Error.None,
			)
		}
		defer delete(oracle_output)
		for frame_index in 0 ..< 5 {
			buffers: [3][32768]u8
			frame := bound_native_frame(cfg, frame_index, 8, &buffers)
			testing.expect_value(
				t,
				media.encode_video(
					&serial,
					frame,
					{packet = capture_packet, user = &serial_output},
				),
				media.Error.None,
			)
			if codec == .H264 {
				parallel_output.lane, parallel_output.idr = 0, frame_index % 3 == 0
				testing.expect_value(
					t,
					media.encode_video(
						&parallel,
						frame,
						{packet = capture_native_lane, user = &parallel_output},
					),
					media.Error.None,
				)
				testing.expect_value(t, parallel_output.lane, parallel_output.idr ? 6 : 4)
				testing.expect_value(
					t,
					avce.encode_frame(
						&oracle,
						raw_data(frame.planes[0].data),
						raw_data(frame.planes[1].data),
						raw_data(frame.planes[2].data),
						frame.planes[0].stride,
						frame.planes[1].stride,
						frame_index % 3 == 0,
						&oracle_output,
					),
					avce.Error.None,
				)
				testing.expect(t, slice.equal(serial_output.data[:], oracle_output[:]))
			} else {
				testing.expect_value(
					t,
					media.encode_video(
						&parallel,
						frame,
						{packet = capture_packet, user = &parallel_output.output},
					),
					media.Error.None,
				)
			}
			testing.expect(t, slice.equal(serial_output.data[:], parallel_output.output.data[:]))
		}
		testing.expect(t, observed.calls > 0 && observed.largest_range == 4)
		testing.expect_value(t, media.drain(&serial, {}), media.Error.None)
		testing.expect_value(t, media.drain(&parallel, {}), media.Error.None)
	}
}

@(test)
test_native_hevc_borrowed_u16_matches_normalized_fallback :: proc(t: ^testing.T) {
	for depth in ([]int{8, 10}) do for chroma in ([]media.Chroma{.YUV420, .YUV422, .YUV444, .Monochrome}) {
		cfg := media.Config {
			codec      = .H265,
			operation  = .Encode,
			preference = .Native,
			width      = 16,
			height     = 16,
			bit_depth  = depth,
			chroma     = chroma,
			qp         = 26,
			gop_size   = 2,
		}
		if chroma == .Monochrome do cfg.width, cfg.height = 17, 19
		direct, fallback: media.Session
		defer media.close(&direct)
		defer media.close(&fallback)
		testing.expect_value(t, media.open(&direct, cfg, []media.Provider{provider()}), media.Error.None)
		testing.expect_value(t, media.open(&fallback, cfg, []media.Provider{provider()}), media.Error.None)
		if direct.state == nil || fallback.state == nil do return
		direct_output, fallback_output: Packet_Sink
		defer {delete(direct_output.data); delete(direct_output.ranges); delete(fallback_output.data); delete(fallback_output.ranges)}
		for index in 0 ..< 3 {
			direct_bytes, fallback_bytes: [3][32768]u8
			frame := bound_native_frame(cfg, index, 16, &direct_bytes)
			fallback_frame := bound_native_frame(cfg, index, 16, &fallback_bytes, misaligned = index == 0, odd_stride = index == 1 || chroma == .Monochrome, unequal_chroma = index == 2 && chroma != .Monochrome)
			// The direct input is really aligned, not a claim inferred from its
			// pixel values. Rejected samples leave history and scratch untouched.
			testing.expect(t, uintptr(raw_data(frame.planes[0].data)) % align_of(u16) == 0)
			bad := frame
			old := [2]u8{bad.planes[0].data[0], bad.planes[0].data[1]}
			limit := u16(1) << uint(depth)
			bad.planes[0].data[0], bad.planes[0].data[1] = u8(limit), u8(limit >> 8)
			testing.expect_value(t, media.encode_video(&direct, bad, {}), media.Error.Invalid_Input)
			testing.expect(t, !direct.failed && ((^State)(direct.state)).hevc_encoder.frame_index == index)
			bad.planes[0].data[0], bad.planes[0].data[1] = old[0], old[1]
			before := direct_bytes
			testing.expect_value(t, media.encode_video(&direct, frame, {packet = capture_packet, user = &direct_output}), media.Error.None)
			testing.expect_value(t, media.encode_video(&fallback, fallback_frame, {packet = capture_packet, user = &fallback_output}), media.Error.None)
			testing.expect(t, direct_bytes == before)
			testing.expect(t, raw_data(((^State)(direct.state)).input) == nil)
			testing.expect(t, len(((^State)(fallback.state)).input) > 0)
			testing.expect(t, slice.equal(direct_output.data[:], fallback_output.data[:]))
		}
	}
}

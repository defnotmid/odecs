package media_vulkan

@(require) import avc "../../video/h264"
@(require) import "core:os"
@(require) import "core:slice"
@(require) import "core:testing"

// This gate is explicitly requested with ODECS_GPU_CONTEXT_TEST=true. It uses
// actual devices/sessions and fails rather than skipping unavailable hardware.
when #config(ODECS_GPU_CONTEXT_TEST, false) {
	Context_GPU_Host_Frame :: struct {
		y, u, v: []u16,
	}
	Context_GPU_Decoder :: struct {
		codec: Codec,
		h264:  H264_Decoder,
		h265:  H265_Decoder,
	}
	Context_GPU_Sink :: struct {
		shared:                                                                             ^Context,
		encoder,
		other:                                                                     ^Encoder,
		host:                                                                               [dynamic]Context_GPU_Host_Frame,
		stream:                                                                             [dynamic]u8,
		width,
		height,
		frames,
		host_frames,
		device_frames,
		foreign_refusals,
		self_refusals: int,
		err:                                                                                Error,
	}

	context_gpu_init_decoder :: proc(
		d: ^Context_GPU_Decoder,
		codec: Codec,
		shared: ^Context,
		w, h, depth: int,
		storage: Output_Storage,
	) -> Error {
		d.codec = codec
		if codec == .H264 do return init_h264_decoder(&d.h264, {shared_context = shared, device_index = -1, width = w, height = h, bit_depth = depth, output_storage = storage})
		return init_h265_decoder(
			&d.h265,
			{
				shared_context = shared,
				device_index = -1,
				width = w,
				height = h,
				bit_depth = depth,
				output_storage = storage,
			},
		)
	}
	context_gpu_destroy_decoder :: proc(d: ^Context_GPU_Decoder) {
		destroy_h264_decoder(&d.h264)
		destroy_h265_decoder(&d.h265)
	}
	context_gpu_receive_host :: proc(frame: H265_Frame, user: rawptr) {
		s := (^Context_GPU_Sink)(user)
		if s.err != .None do return
		if frame.width != s.width ||
		   frame.height != s.height ||
		   len(frame.planes[0]) == 0 ||
		   frame.surface.image != 0 {s.err = .Invalid_Argument; return}
		// Samples widened to u16 for encode_frame16.
		widen :: proc(plane: []u8, stride, w, h, bits: int) -> []u16 {
			out := make([]u16, w * h)
			for row in 0 ..< h do for x in 0 ..< w {
				out[row * w + x] = bits == 8 ? u16(plane[row * stride + x]) : u16(plane[row * stride + 2 * x]) | u16(plane[row * stride + 2 * x + 1]) << 8
			}
			return out
		}
		owned := Context_GPU_Host_Frame {
			widen(frame.planes[0], frame.strides[0], s.width, s.height, frame.storage_bits),
			widen(frame.planes[1], frame.strides[1], s.width / 2, s.height / 2, frame.storage_bits),
			widen(frame.planes[2], frame.strides[2], s.width / 2, s.height / 2, frame.storage_bits),
		}
		append(&s.host, owned)
	}
	context_gpu_receive_device :: proc(frame: H265_Frame, user: rawptr) {
		s := (^Context_GPU_Sink)(user)
		if s.err != .None do return
		if s.frames >= len(s.host) ||
		   frame.width != s.width ||
		   frame.height != s.height ||
		   len(frame.planes[0]) != 0 ||
		   len(frame.planes[1]) != 0 ||
		   len(frame.planes[2]) != 0 ||
		   frame.surface.image == 0 ||
		   frame.surface.device != context_descriptor(s.shared).device ||
		   frame.surface.ready_value == 0 {
			s.err = .Invalid_Argument
			return
		}
		if s.frames == 0 {
			// Use the original borrowed image against an actual second device;
			// no mutation or invented handle can stand in for this boundary.
			packet, error := encode_surface(s.other, frame.surface, frame.crop_x, frame.crop_y)
			defer delete(packet)
			if error != .Unsupported ||
			   len(packet) != 0 ||
			   s.other.submitted != 0 ||
			   s.other.failed {s.err = .Invalid_Argument; return}
			s.foreign_refusals += 1
			self_copy := frame.surface
			self_copy.image = s.encoder.slots[0].input.handle
			self_packet, self_error := encode_surface(
				s.encoder,
				self_copy,
				frame.crop_x,
				frame.crop_y,
			)
			defer delete(self_packet)
			if self_error != .Invalid_Argument ||
			   len(self_packet) != 0 ||
			   s.encoder.submitted != 0 ||
			   s.encoder.failed {s.err = .Invalid_Argument; return}
			s.self_refusals += 1
		}
		packet: []u8
		error: Error
		if s.frames % 3 == 1 {
			f := s.host[s.frames]
			packet, error = encode_frame16(
				s.encoder,
				{f.y, s.width},
				{f.u, s.width / 2},
				{f.v, s.width / 2},
			)
			s.host_frames += 1
		} else {
			packet, error = encode_surface(s.encoder, frame.surface, frame.crop_x, frame.crop_y)
			s.device_frames += 1
		}
		if s.frames == 0 &&
		   (s.encoder.slots[0].upload.handle != 0 ||
				   s.encoder.slots[0].upload.mapped !=
					   nil) {s.err = .Invalid_Argument; delete(packet); return}
		if s.frames == 1 &&
		   (s.encoder.slots[0].upload.handle == 0 ||
				   s.encoder.slots[0].upload.mapped ==
					   nil) {s.err = .Invalid_Argument; delete(packet); return}
		defer delete(packet)
		if error != .None {s.err = error; return}
		if len(packet) == 0 {s.err = .Output_Overflow; return}
		append(&s.stream, ..packet)
		s.frames += 1
	}
	context_gpu_receive_avc_host :: proc(frame: H264_Frame, user: rawptr) {
		context_gpu_receive_host(frame, user)
	}
	context_gpu_receive_avc_device :: proc(frame: H264_Frame, user: rawptr) {
		context_gpu_receive_device(frame, user)
	}
	context_gpu_decode :: proc(
		d: ^Context_GPU_Decoder,
		stream: []u8,
		sink: ^Context_GPU_Sink,
		device: bool,
	) -> Error {
		nals := avc.find_nal_units(stream)
		defer delete(nals)
		for nal in nals {
			data := stream[nal.offset:][:nal.length]
			error: Error
			if d.codec ==
			   .H264 {error = decode_h264_nal(&d.h264, data, device ? context_gpu_receive_avc_device : context_gpu_receive_avc_host, sink)} else {error = decode_h265_nal(&d.h265, data, device ? context_gpu_receive_device : context_gpu_receive_host, sink)}
			if error != .None do return error
			if sink.err != .None do return sink.err
		}
		if d.codec == .H264 do return flush_h264_decoder(&d.h264, device ? context_gpu_receive_avc_device : context_gpu_receive_avc_host, sink)
		return flush_h265_decoder(
			&d.h265,
			device ? context_gpu_receive_device : context_gpu_receive_host,
			sink,
		)
	}

	@(test)
	context_real_foreign_device_and_mixed_inputs :: proc(t: ^testing.T) {
		w, h := #config(ODECS_GPU_WIDTH, 386), #config(ODECS_GPU_HEIGHT, 242)
		depth, gop := #config(ODECS_GPU_DEPTH, 8), #config(ODECS_GPU_GOP, 15)
		codec_name := #config(ODECS_GPU_CODEC, "h264")
		codec: Codec = codec_name == "h265" ? .H265 : .H264
		testing.expect(
			t,
			(codec_name == "h264" || codec_name == "h265") &&
			(depth == 8 || depth == 10) &&
			(codec == .H265 || depth == 8),
		)
		if codec_name != "h264" && codec_name != "h265" || depth != 8 && depth != 10 || codec == .H264 && depth != 8 do return
		requests := [2]Request {
			{
				codec = codec,
				operation = .Decode,
				width = w,
				height = h,
				bit_depth = depth,
				require_compute = true,
			},
			{codec = codec, operation = .Encode, width = w, height = h, bit_depth = depth},
		}
		shared, other: Context
		error := init_context(&shared, {requests = requests[:], device_index = -1})
		testing.expect_value(t, error, Error.None)
		if error != .None do return
		defer testing.expect_value(t, destroy_context(&shared), Error.None)
		host_decoder := new(Context_GPU_Decoder)
		defer free(host_decoder)
		error = context_gpu_init_decoder(host_decoder, codec, &shared, w, h, depth, .Host)
		testing.expect_value(t, error, Error.None)
		if error != .None do return
		defer context_gpu_destroy_decoder(host_decoder)
		// Only the lazy frontend holds the real Context at this point.
		testing.expect_value(t, shared.holds, 1)
		testing.expect_value(t, destroy_context(&shared), Error.Busy)
		// Trigger real capability admission after retaining this Context, then
		// verify constructor rollback releases its hold and clears the borrower.
		capabilities, probe_error := probe_capabilities(requests[0], &shared)
		defer delete(capabilities)
		testing.expect_value(t, probe_error, Error.None)
		testing.expect_value(t, len(capabilities), 1)
		if probe_error != .None || len(capabilities) != 1 do return
		capability := capabilities[0]
		bad_w, bad_h := w, h
		expected_refusal: Error = .Unsupported
		bad_slots := 2
		switch {
		case capability.min_width > 2 && capability.min_width % 2 == 0:
			bad_w = capability.min_width - 2
		case capability.max_width < 8191:
			bad_w = (capability.max_width + 2) &~ 1
		case capability.min_height > 2 && capability.min_height % 2 == 0:
			bad_h = capability.min_height - 2
		case capability.max_height < 8191:
			bad_h = (capability.max_height + 2) &~ 1
		case capability.max_dpb_slots < 17:
			bad_slots = capability.max_dpb_slots + 1
		case:
			testing.expect(t, false); return
		}
		failed_decoder: Decoder
		holds := shared.holds
		error = init_decoder(
			&failed_decoder,
			{
				shared_context = &shared,
				codec = codec,
				device_index = -1,
				width = bad_w,
				height = bad_h,
				bit_depth = depth,
				dpb_slots = bad_slots,
				max_references = 1,
			},
		)
		testing.expect_value(t, error, expected_refusal)
		testing.expect(
			t,
			!failed_decoder.initialized &&
			failed_decoder.session == 0 &&
			failed_decoder.device.a == nil &&
			failed_decoder.config.shared_context == nil,
		)
		testing.expect_value(t, shared.holds, holds)
		destroy_decoder(&failed_decoder)
		source_encoder: Encoder
		config := Config {
			codec          = codec,
			bit_depth      = depth,
			gop_size       = gop,
			width          = w,
			height         = h,
			qp             = 26,
			device_index   = -1,
			shared_context = &shared,
		}
		error = init_encoder(&source_encoder, config)
		testing.expect_value(t, error, Error.None)
		if error != .None do return
		defer destroy_encoder(&source_encoder)
		y, u, v := make([]u16, w * h), make([]u16, w * h / 4), make([]u16, w * h / 4)
		defer {delete(y); delete(u); delete(v)}
		source: [dynamic]u8
		defer delete(source)
		for picture in 0 ..< 37 {
			mask := (1 << uint(depth)) - 1
			for &sample, i in y do sample = u16((i % w * 11 + i / w * 17 + picture * 47) & mask)
			for &sample, i in u do sample = u16((i % (w / 2) * 7 + i / (w / 2) * 13 + picture * 29 + 71) & mask)
			for &sample, i in v do sample = u16((i % (w / 2) * 19 + i / (w / 2) * 3 + picture * 37 + 151) & mask)
			packet, encode_error := encode_frame16(&source_encoder, {y, w}, {u, w / 2}, {v, w / 2})
			testing.expect_value(t, encode_error, Error.None)
			if encode_error != .None {delete(packet); return}
			append(&source, ..packet)
			delete(packet)
		}
		destroy_encoder(&source_encoder)
		sink := Context_GPU_Sink {
			shared = &shared,
			width  = w,
			height = h,
		}
		defer {
			for frame in sink.host {delete(frame.y); delete(frame.u); delete(frame.v)}
			delete(sink.host)
			delete(sink.stream)
		}
		error = context_gpu_decode(host_decoder, source[:], &sink, false)
		testing.expect_value(t, error, Error.None)
		testing.expect_value(t, sink.err, Error.None)
		testing.expect_value(t, len(sink.host), 37)
		if error != .None || sink.err != .None || len(sink.host) != 37 do return
		context_gpu_destroy_decoder(host_decoder)
		oracle: Encoder
		error = init_encoder(&oracle, config)
		testing.expect_value(t, error, Error.None)
		if error != .None do return
		defer destroy_encoder(&oracle)
		testing.expect(t, oracle.slots[0].upload.handle == 0 && oracle.slots[0].upload.mapped == nil)
		expected: [dynamic]u8
		defer delete(expected)
		for frame in sink.host {
			packet, encode_error := encode_frame16(
				&oracle,
				{frame.y, w},
				{frame.u, w / 2},
				{frame.v, w / 2},
			)
			testing.expect_value(t, encode_error, Error.None)
			if encode_error != .None {delete(packet); return}
			append(&expected, ..packet)
			delete(packet)
		}
		destroy_encoder(&oracle)
		error = init_context(
			&other,
			{requests = requests[1:], device_index = context_descriptor(&shared).device_index},
		)
		testing.expect_value(t, error, Error.None)
		if error != .None do return
		defer testing.expect_value(t, destroy_context(&other), Error.None)
		testing.expect(t, context_descriptor(&other).device != context_descriptor(&shared).device)
		mixed, foreign_encoder: Encoder
		error = init_encoder(&mixed, config)
		testing.expect_value(t, error, Error.None)
		if error != .None do return
		defer destroy_encoder(&mixed)
		testing.expect(t, mixed.slots[0].upload.handle == 0 && mixed.slots[0].upload.mapped == nil)
		foreign_config := config
		foreign_config.shared_context = &other
		error = init_encoder(&foreign_encoder, foreign_config)
		testing.expect_value(t, error, Error.None)
		if error != .None do return
		defer destroy_encoder(&foreign_encoder)
		sink.encoder, sink.other = &mixed, &foreign_encoder
		device_decoder := new(Context_GPU_Decoder)
		defer free(device_decoder)
		error = context_gpu_init_decoder(device_decoder, codec, &shared, w, h, depth, .Device)
		testing.expect_value(t, error, Error.None)
		if error != .None do return
		defer context_gpu_destroy_decoder(device_decoder)
		testing.expect_value(t, destroy_context(&shared), Error.Busy)
		testing.expect_value(t, destroy_context(&other), Error.Busy)
		error = context_gpu_decode(device_decoder, source[:], &sink, true)
		testing.expect_value(t, error, Error.None)
		testing.expect_value(t, sink.err, Error.None)
		testing.expect_value(t, sink.frames, 37)
		testing.expect_value(t, sink.host_frames, 12)
		testing.expect_value(t, sink.device_frames, 25)
		testing.expect_value(t, sink.foreign_refusals, 1)
		testing.expect_value(t, sink.self_refusals, 1)
		testing.expect(t, slice.equal(expected[:], sink.stream[:]))
		path := codec == .H264 ? "/tmp/odecs-context-mixed.264" : "/tmp/odecs-context-mixed.265"
		testing.expect(t, os.write_entire_file(path, sink.stream[:]) == nil)
		context_gpu_destroy_decoder(device_decoder)
		destroy_encoder(&mixed)
		destroy_encoder(&foreign_encoder)
		testing.expect_value(t, shared.holds, 0)
		testing.expect_value(t, other.holds, 0)
		testing.expect_value(t, destroy_context(&shared), Error.None)
		testing.expect_value(t, destroy_context(&other), Error.None)
	}
}

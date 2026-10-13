package media_vulkan

import media ".."
import gpu "../../gpu"

// A shared context is borrowed; keep it at a stable address until all sessions
// opened with this provider have closed. Nil retains independent sessions.
provider :: proc(shared_context: ^gpu.Context = nil) -> media.Provider {
	return {
		backend = .Vulkan,
		name = "Vulkan Video",
		user = shared_context,
		probe = probe,
		open = open_vulkan,
	}
}

@(private)
map_error :: proc(err: gpu.Error) -> media.Error {
	switch err {
	case .None:
		return .None
	case .Invalid_Argument:
		return .Invalid_Config
	case .Loader_Unavailable, .No_Device:
		return .Unavailable
	case .Unsupported:
		return .Unsupported
	case .Busy:
		return .Busy
	case .Driver_Error, .Out_Of_Memory, .Output_Overflow:
		return .Driver_Error
	}
	return .Driver_Error
}

probe :: proc(config: media.Config, user: rawptr) -> media.Error {
	if err := media.validate_config(config); err != .None do return err
	if config.alpha do return .Unsupported // single-layer sessions
	if config.chroma != .YUV420 || config.codec != .H264 && config.codec != .H265 && config.codec != .AV1 do return .Unsupported
	// AV1 shows hidden frames again from host copies.
	if config.codec == .AV1 && (config.operation != .Decode || config.output_storage != .Host || config.profile_idc != 0) do return .Unsupported
	depth := config.bit_depth == 0 ? 8 : config.bit_depth
	if depth != 8 && depth != 10 || config.codec == .H264 && depth != 8 do return .Unsupported
	codec: gpu.Codec
	operation: gpu.Operation
	if config.operation == .Encode {
		if config.gop_size > 32768 || config.qp < 0 do return .Unsupported
		codec, operation = config.codec == .H264 ? gpu.Codec.H264 : .H265, .Encode
		if config.codec == .H264 && config.bit_depth != 0 && config.bit_depth != 8 do return .Unsupported
	} else if config.operation == .Decode {
		// Supply indexed source metadata for reliable hardware admission. Native
		// can still decode streams whose dimensions have not been inspected.
		if config.width <= 0 || config.height <= 0 do return .Unsupported
		if config.codec == .H264 && config.profile_idc != 0 && config.profile_idc != 66 && config.profile_idc != 77 && config.profile_idc != 100 do return .Unsupported
		if config.codec == .H265 && config.profile_idc != 0 && config.profile_idc != 1 && config.profile_idc != 2 do return .Unsupported
		codec, operation = GPU_CODECS[config.codec], .Decode
	} else {return .Unsupported}
	list, err := gpu.probe(
		{
			codec = codec,
			operation = operation,
			width = config.width,
			height = config.height,
			bit_depth = depth,
			profile_idc = config.profile_idc,
			require_compute = config.operation == .Decode && config.output_storage == .Device,
		},
		(^gpu.Context)(user),
	)
	defer delete(list)
	if err != .None do return map_error(err)
	for capability in list do if capability.annex_b_implemented do return .None
	return .Unsupported
}

// Encode pictures in flight: each encode call publishes the packet of the
// picture submitted ENCODE_DEPTH-1 calls earlier and drain publishes the rest,
// so upload, encode and readback overlap across pictures. At 1080p on RADV
// two already keep the encoder busy (3.6 -> 2.0 ms/frame H.264).
ENCODE_DEPTH :: 3

@(private, rodata)
GPU_CODECS := #partial [media.Codec]gpu.Codec {
	.H264 = .H264,
	.H265 = .H265,
	.AV1  = .AV1,
}

@(private)
State :: struct {
	encoder:     gpu.Encoder,
	decoder:     gpu.H265_Decoder,
	avc_decoder: gpu.H264_Decoder,
	av1_decoder: gpu.AV1_Decoder,
	input:       []u16,
}

@(private)
open_vulkan :: proc(session: ^media.Session, config: media.Config, user: rawptr) -> media.Error {
	s := new(State)
	shared := (^gpu.Context)(user)
	if config.operation == .Encode {
		gop := config.gop_size == 0 ? 15 : config.gop_size
		if err := gpu.init_encoder(
			&s.encoder,
			{
				codec = config.codec == .H264 ? .H264 : .H265,
				bit_depth = config.bit_depth,
				width = config.width,
				height = config.height,
				qp = int(config.qp),
				gop_size = gop,
				device_index = -1,
				shared_context = shared,
				frames_in_flight = ENCODE_DEPTH,
				colour_primaries = config.color.primaries,
				transfer = config.color.transfer,
				matrix_coefficients = config.color.matrix_coeffs,
				full_range = config.color.full_range,
			},
		); err != .None {free(s); return map_error(err)}
	} else if config.codec == .AV1 {
		if err := gpu.init_av1_decoder(&s.av1_decoder, {device_index = -1, shared_context = shared}); err != .None {free(s); return map_error(err)}
	} else if config.codec == .H265 {
		if err := gpu.init_h265_decoder(
			&s.decoder,
			{
				width = config.width,
				height = config.height,
				bit_depth = config.bit_depth == 0 ? 8 : config.bit_depth,
				profile_idc = config.profile_idc,
				device_index = -1,
				output_storage = config.output_storage == .Host ? .Host : .Device,
				shared_context = shared,
			},
		); err != .None {free(s); return map_error(err)}
	} else {
		if err := gpu.init_h264_decoder(
			&s.avc_decoder,
			{
				width = config.width,
				height = config.height,
				bit_depth = config.bit_depth == 0 ? 8 : config.bit_depth,
				profile_idc = config.profile_idc,
				device_index = -1,
				output_storage = config.output_storage == .Host ? .Host : .Device,
				shared_context = shared,
				no_reordering = config.no_reordering,
			},
		); err != .None {free(s); return map_error(err)}
	}
	session.state = s
	session.close_impl = close_vulkan
	session.video_impl = encode_video_vulkan
	session.decode_impl = decode_vulkan
	session.drain_impl = drain_vulkan
	return .None
}

@(private)
encode_video_vulkan :: proc(
	session: ^media.Session,
	frame: media.Video_Frame,
	receiver: media.Receiver,
) -> media.Error {
	s := (^State)(session.state)
	packet: []u8
	err: gpu.Error
	if frame.storage == .Device {
		packet, err = gpu.encode_surface_borrowed(
			&s.encoder,
			(^gpu.Surface)(frame.surface)^,
			frame.crop_x,
			frame.crop_y,
		)
	} else if frame.chroma_interleaved {
		if frame.storage_bits != 8 do return .Unsupported
		packet, err = gpu.encode_frame_borrowed(&s.encoder, {frame.planes[0].data, frame.planes[0].stride}, {frame.planes[1].data, frame.planes[1].stride})
	} else if frame.storage_bits == 8 {
		packet, err = gpu.encode_frame_borrowed(
			&s.encoder,
			{frame.planes[0].data, frame.planes[0].stride},
			{frame.planes[1].data, frame.planes[1].stride},
			{frame.planes[2].data, frame.planes[2].stride},
		)
	} else {
		planes: [3]gpu.Plane16
		direct := true
		for p in frame.planes do if p.stride % 2 != 0 || uintptr(raw_data(p.data)) % align_of(u16) != 0 do direct = false
		if direct {
			for p, i in frame.planes do planes[i] = {([^]u16)(raw_data(p.data))[:len(p.data) / 2], p.stride / 2}
		} else {
			// Unaligned/odd-stride byte planes remain valid API input. Normalize
			// them into retained u16 scratch instead of casting invalid rows.
			total := frame.width * frame.height * 3 / 2
			if len(s.input) != total {delete(s.input); s.input = make([]u16, total)}
			offset := 0
			for p, i in frame.planes {
				w, h :=
					i == 0 ? frame.width : frame.width / 2,
					i == 0 ? frame.height : frame.height / 2
				for row in 0 ..< h do for col in 0 ..< w {
					at := row * p.stride + col * 2
					s.input[offset + row * w + col] = u16(p.data[at]) | u16(p.data[at + 1]) << 8
				}
				planes[i] = {s.input[offset:][:w * h], w}
				offset += w * h
			}
		}
		packet, err = gpu.encode_frame16_borrowed(&s.encoder, planes[0], planes[1], planes[2])
	}
	if err == .Invalid_Argument do return .Invalid_Input
	if err != .None do return map_error(err)
	if packet != nil && receiver.packet != nil do receiver.packet({data = packet, framing = .Annex_B}, receiver.user)
	return .None
}

@(private)
drain_vulkan :: proc(session: ^media.Session, receiver: media.Receiver) -> media.Error {
	state := (^State)(session.state)
	if session.config.operation == .Encode {
		for {
			packet, err := gpu.flush_encoder_borrowed(&state.encoder)
			if err != .None do return map_error(err)
			if packet == nil do return .None
			if receiver.packet != nil do receiver.packet({data = packet, framing = .Annex_B}, receiver.user)
		}
	}
	sink := Decode_Sink {
		receiver = receiver,
		storage  = session.config.output_storage,
	}
	if session.config.codec == .H264 do return map_error(gpu.flush_h264_decoder(&state.avc_decoder, receive_video, &sink))
	if session.config.codec == .AV1 do return map_error(gpu.flush_av1_decoder(&state.av1_decoder, receive_video, &sink))
	return map_error(gpu.flush_h265_decoder(&state.decoder, receive_video, &sink))
}

@(private)
Decode_Sink :: struct {
	receiver: media.Receiver,
	storage:  media.Storage,
}

// One callback for every hardware decoder: they share gpu.Decoder_Frame,
// whose host planes already have media.Video_Frame's shape.
@(private)
receive_video :: proc(decoded: gpu.Decoder_Frame, user: rawptr) {
	sink := (^Decode_Sink)(user)
	if sink.receiver.video == nil do return
	frame := media.Video_Frame {
		width        = decoded.width,
		height       = decoded.height,
		coded_width  = decoded.coded_width,
		coded_height = decoded.coded_height,
		crop_x       = decoded.crop_x,
		crop_y       = decoded.crop_y,
		bit_depth    = decoded.bit_depth,
		storage_bits = decoded.storage_bits,
		chroma       = .YUV420,
		poc          = decoded.poc,
		storage      = sink.storage,
	}
	surface := decoded.surface
	if frame.storage == .Device {
		frame.surface = &surface
	} else {
		// Each plane runs from the crop origin to the end of its last visible
		// row; chroma of an odd size (AV1) covers the last luma row and column.
		b := decoded.storage_bits / 8
		for i in 0 ..< 3 {
			sub := i == 0 ? 1 : 2
			rows, row_bytes := (decoded.height + sub - 1) / sub, (decoded.width + sub - 1) / sub * b
			frame.planes[i] = {decoded.planes[i][:(rows - 1) * decoded.strides[i] + row_bytes], decoded.strides[i]}
		}
	}
	sink.receiver.video(frame, sink.receiver.user)
}

// A typed surface is valid only during the frame callback. It is decode-ready;
// wait on ready_semaphore/ready_value on compute_queue before shader access.
// Complete consumer work on that queue before returning. Images remain owned
// by the codec and must not be destroyed or retained as unleased frame handles.
surface :: proc(frame: media.Video_Frame) -> ^gpu.Surface {
	if frame.storage != .Device do return nil
	return (^gpu.Surface)(frame.surface)
}

@(private)
decode_vulkan :: proc(
	session: ^media.Session,
	packet: media.Packet,
	receiver: media.Receiver,
) -> media.Error {
	state := (^State)(session.state)
	sink := Decode_Sink {
		receiver = receiver,
		storage  = session.config.output_storage,
	}
	if session.config.codec == .AV1 {
		if packet.framing != .Frame do return .Invalid_Input
		e := gpu.decode_av1_temporal_unit(&state.av1_decoder, packet.data, receive_video, &sink)
		if e == .Invalid_Argument do return .Invalid_Input
		return map_error(e)
	}
	it := media.Nal_Iterator {
		packet = packet,
	}
	for {
		nal, done, err := media.next_nal(&it)
		if err != .None do return err
		if done do return .None
		e: gpu.Error
		if session.config.codec ==
		   .H264 {e = gpu.decode_h264_nal(&state.avc_decoder, nal, receive_video, &sink)} else {e = gpu.decode_h265_nal(&state.decoder, nal, receive_video, &sink)}
		if e == .Invalid_Argument do return .Invalid_Input
		if e != .None do return map_error(e)
	}
}

@(private)
close_vulkan :: proc(session: ^media.Session) {
	s := (^State)(session.state)
	gpu.destroy_encoder(&s.encoder)
	gpu.destroy_h265_decoder(&s.decoder)
	gpu.destroy_h264_decoder(&s.avc_decoder)
	gpu.destroy_av1_decoder(&s.av1_decoder)
	delete(s.input)
	free(s)
}

package media_videotoolbox

import media ".."
import "core:fmt"

// H.264 and HEVC on Apple platforms: decoding (host output, 4:2:0; HEVC at 8
// or 10 bits) and encoding (8-bit 4:2:0, I/P, constant QP). Require_Hardware
// admits only the hardware codecs; Automatic lets VideoToolbox fall back to
// Apple's software codecs.
// Elsewhere every probe reports .Unavailable, so the provider can be listed
// unconditionally.
provider :: proc() -> media.Provider {
	return {backend = .VideoToolbox, name = "VideoToolbox", probe = probe, open = open_videotoolbox}
}

probe :: proc(config: media.Config, user: rawptr) -> media.Error {
	if err := media.validate_config(config); err != .None do return err
	if config.codec != .H264 && config.codec != .H265 || config.chroma != .YUV420 do return .Unsupported
	depth := config.bit_depth == 0 ? 8 : config.bit_depth
	if config.operation == .Encode {
		if depth != 8 || config.alpha do return .Unsupported
		return ODIN_OS == .Darwin ? .None : .Unavailable // open admits the hardware encoder
	}
	if config.output_storage != .Host do return .Unsupported
	if config.codec == .H264 {
		if depth != 8 do return .Unsupported
		if config.profile_idc != 0 && config.profile_idc != 66 && config.profile_idc != 77 && config.profile_idc != 100 do return .Unsupported
	} else {
		if depth != 8 && depth != 10 do return .Unsupported
		if config.profile_idc != 0 && config.profile_idc != 1 && config.profile_idc != 2 do return .Unsupported
	}
	if config.preference == .Require_Hardware {
		return hardware_decode_supported(config.codec == .H264 ? .H264 : .HEVC) ? .None : .Unavailable
	}
	return ODIN_OS == .Darwin ? .None : .Unavailable
}

@(private)
State :: struct {
	avc:    H264_Decoder,
	hevc:   H265_Decoder,
	encoder: Encoder,
	detail: string,
}

@(private)
map_error :: proc(err: Error) -> media.Error {
	switch err {
	case .None:
		return .None
	case .Invalid_Argument:
		return .Invalid_Input
	case .Unsupported:
		return .Unsupported
	case .Unavailable:
		return .Unavailable
	case .Decoder_Error, .Encoder_Error:
		return .Driver_Error
	}
	return .Driver_Error
}

@(private)
open_videotoolbox :: proc(session: ^media.Session, config: media.Config, user: rawptr) -> media.Error {
	s := new(State)
	if config.operation == .Encode do return open_encoder(session, s, config)
	require_hw := config.preference == .Require_Hardware
	err := config.codec == .H264 ? init_h264_decoder(&s.avc, config.no_reordering, require_hw) : init_h265_decoder(&s.hevc, require_hw)
	if err != .None {
		free(s)
		return map_error(err)
	}
	session.state = s
	session.decode_impl = decode_videotoolbox
	session.drain_impl = drain_videotoolbox
	session.close_impl = close_videotoolbox
	return .None
}

@(private)
receive :: proc(frame: Frame, user: rawptr) {
	receiver := (^media.Receiver)(user)
	if receiver.video == nil do return
	out := media.Video_Frame {
		width        = frame.width,
		height       = frame.height,
		coded_width  = frame.coded_width,
		coded_height = frame.coded_height,
		crop_x       = frame.crop_x,
		crop_y       = frame.crop_y,
		bit_depth    = frame.bit_depth,
		storage_bits = frame.storage_bits,
		chroma       = .YUV420,
		poc          = frame.poc,
		storage      = .Host,
	}
	for i in 0 ..< 3 do out.planes[i] = {frame.planes[i], frame.strides[i]}
	receiver.video(out, receiver.user)
}

@(private)
report :: proc(session: ^media.Session, err: Error, status: i32, pixel_format: u32 = 0) -> media.Error {
	if err == .None do return .None
	s := (^State)(session.state)
	delete(s.detail)
	format := transmute([4]u8)u32be(pixel_format)
	if pixel_format == 0 {
		s.detail = fmt.aprintf("VideoToolbox: %v (OSStatus %d)", err, status)
	} else {
		s.detail = fmt.aprintf("VideoToolbox: %v (OSStatus %d, pixel format %s)", err, status, format)
	}
	session.error_detail = s.detail
	return map_error(err)
}

@(private)
decode_videotoolbox :: proc(session: ^media.Session, packet: media.Packet, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	receiver := receiver
	it := media.Nal_Iterator {
		packet = packet,
	}
	for {
		nal, done, err := media.next_nal(&it)
		if err != .None do return err
		if done do return .None
		if session.config.codec == .H264 {
			if e := decode_h264_nal(&s.avc, nal, receive, &receiver); e != .None do return report(session, e, s.avc.pictures.session.status, s.avc.pictures.session.pixel_format)
		} else {
			if e := decode_h265_nal(&s.hevc, nal, receive, &receiver); e != .None do return report(session, e, s.hevc.pictures.session.status, s.hevc.pictures.session.pixel_format)
		}
	}
}

@(private)
drain_videotoolbox :: proc(session: ^media.Session, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	receiver := receiver
	if session.config.codec == .H264 do return report(session, flush_h264_decoder(&s.avc, receive, &receiver), s.avc.pictures.session.status, s.avc.pictures.session.pixel_format)
	return report(session, flush_h265_decoder(&s.hevc, receive, &receiver), s.hevc.pictures.session.status, s.hevc.pictures.session.pixel_format)
}

@(private)
close_videotoolbox :: proc(session: ^media.Session) {
	s := (^State)(session.state)
	destroy_h264_decoder(&s.avc)
	destroy_h265_decoder(&s.hevc)
	encoder_destroy(&s.encoder)
	delete(s.detail)
	free(s)
}

@(private)
open_encoder :: proc(session: ^media.Session, s: ^State, config: media.Config) -> media.Error {
	gop := config.gop_size == 0 ? 15 : config.gop_size
	err := encoder_create(&s.encoder, {codec = config.codec == .H264 ? .H264 : .HEVC, width = config.width, height = config.height, qp = int(clamp(config.qp, 1, 51)), keyframe_interval = gop, require_hardware = config.preference == .Require_Hardware})
	session.state = s
	session.video_impl = encode_videotoolbox
	session.close_impl = close_videotoolbox
	session.drain_impl = proc(session: ^media.Session, receiver: media.Receiver) -> media.Error {return .None} // one packet per frame
	if err != .None do return report(session, err, s.encoder.status)
	return .None
}

@(private)
encode_videotoolbox :: proc(session: ^media.Session, frame: media.Video_Frame, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	if frame.storage != .Host || frame.storage_bits != 8 do return .Unsupported
	chroma := Encoder_Chroma {
		planes      = {frame.planes[1].data, frame.planes[2].data},
		strides     = {frame.planes[1].stride, frame.planes[2].stride},
		interleaved = frame.chroma_interleaved,
	}
	packet, keyframe, err := encoder_encode(&s.encoder, frame.planes[0].data, frame.planes[0].stride, chroma)
	if err != .None do return report(session, err, s.encoder.status)
	if receiver.packet != nil do receiver.packet({data = packet, framing = .Annex_B, keyframe = keyframe}, receiver.user)
	return .None
}

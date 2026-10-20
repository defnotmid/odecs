package media_native

import media ".."
import aac "../../audio/aac"
import audio "../../audio"
import aace "../../audio/aac/encoder"
import common "../../common"
import avcd "../../video/h264/decoder"
import avce "../../video/h264/encoder"
import hevcd "../../video/h265/decoder"
import hevce "../../video/h265/encoder"
import proresd "../../video/prores/decoder"
import vp9d "../../video/vp9/decoder"
import vp9e "../../video/vp9/encoder"

// The binding is read at probe/open. Each session snapshots its geometry and
// borrows only the caller's persistent pool until close. Calls remain serial
// per session, and the same pool must not be used by concurrent codec calls.
Options :: struct {
	pool:                           ^common.Work_Pool,
	h264_slice_count:               int, // zero preserves the native default of four slices
	h265_tile_cols, h265_tile_rows: int, // both zero preserves the untiled stream
}

provider :: proc(options: ^Options = nil) -> media.Provider {
	return {
		backend = .Native,
		name = "Odin native",
		user = options,
		probe = probe,
		open = open_native,
	}
}

@(private)
aac_config :: proc(config: media.Config) -> (cfg: aac.Config, err: aac.Error) {
	cfg = {
		sample_rate   = config.sample_rate,
		channels      = config.channels,
		bit_rate      = config.bit_rate,
		frame_samples = config.frame_samples,
	}
	if config.operation == .Decode && len(config.extradata) != 0 {
		parsed, e := aac.parse_audio_specific_config(config.extradata)
		if e != .None do return {}, e
		if parsed.sample_rate != cfg.sample_rate || parsed.channels != cfg.channels || aac.resolved_frame_samples(parsed) != aac.resolved_frame_samples(cfg) do return {}, .Invalid_Config
		cfg = parsed
		cfg.bit_rate = config.bit_rate
	}
	return cfg, aac.validate_config(cfg)
}

@(private)
aac_transport :: proc(transport: media.Audio_Transport) -> aace.Transport {
	switch transport {
	case .ADTS:
		return .ADTS
	case .Raw:
		return .Raw
	case .LOAS:
		return .LOAS
	}
	return .ADTS
}

@(private)
aac_framing :: proc(transport: media.Audio_Transport) -> media.Framing {
	switch transport {
	case .ADTS:
		return .ADTS
	case .Raw:
		return .Raw_AAC
	case .LOAS:
		return .LOAS
	}
	return .ADTS
}

@(private)
options_error :: proc(config: media.Config, options: Options) -> media.Error {
	if options.pool != nil && options.pool.run == nil do return .Invalid_Config
	if options.h264_slice_count < 0 || options.h265_tile_cols < 0 || options.h265_tile_rows < 0 do return .Invalid_Config
	if config.operation != .Encode do return .None
	if config.codec == .H264 && options.h264_slice_count > (config.height + 15) / 16 do return .Invalid_Config
	if config.codec == .H265 {
		cols, rows := options.h265_tile_cols, options.h265_tile_rows
		if (cols == 0) != (rows == 0) do return .Invalid_Config
		if cols > (config.width + 63) / 64 || rows > (config.height + 63) / 64 do return .Invalid_Config
		// Both dimensions are now within the admitted CTU grid; the quotient
		// keeps the fixed native 128-substream bound independent of overflow.
		if rows > 0 && cols > 128 / rows do return .Invalid_Config
	}
	return .None
}

probe :: proc(config: media.Config, user: rawptr) -> media.Error {
	if err := media.validate_config(config); err != .None do return err
	if config.operation == .Decode && config.output_storage != .Host do return .Unsupported
	depth := config.bit_depth == 0 ? 8 : config.bit_depth
	switch config.codec {
	case .H264:
		// Decoding: High 10 and High 4:2:2 too. Encoding: 8-bit 4:2:0.
		high := config.operation == .Decode
		if depth < 8 || depth > (high ? 10 : 8) do return .Unsupported
		if config.chroma != .YUV420 && !(high && config.chroma == .YUV422) do return .Unsupported
	case .H265:
		if config.operation == .Encode && depth != 8 && depth != 10 do return .Unsupported
	case .ProRes:
		if config.operation == .Encode do return .Unsupported // decoder only
	case .VP9:
		if config.operation == .Encode && (depth != 8 || config.chroma != .YUV420) do return .Unsupported // profile 0
	case .AV1:
		return .Unsupported // hardware only (media/vulkan)
	case .FLAC, .MP3, .Opus, .ALAC, .Vorbis:
		// Decoded by the audio package, the one audio decode implementation.
		switch audio.check_config(AUDIO_CODECS[config.codec], config.sample_rate, config.channels, config.extradata) {
		case .None:
		case .Unsupported:
			return .Unsupported
		case .Invalid_Config, .Invalid_Input, .Invalid_Data, .IO_Error, .Out_Of_Memory, .Codec_Error, .End_Of_Stream, .Closed:
			return .Invalid_Config
		}
	case .AAC:
		cfg, e := aac_config(config)
		if e != .None {
			#partial switch e {
			case .Unsupported_Profile,
			     .Unsupported_Channels,
			     .Unsupported_Tool,
			     .Unsupported_Transport:
				return .Unsupported
			case:
				return .Invalid_Config
			}
		}
		if config.operation == .Encode {
			if config.audio_transport == .ADTS && aac.resolved_frame_samples(cfg) != 1024 do return .Unsupported
			layout, le := aac.resolve_channel_layout(cfg)
			if le != .None do return .Invalid_Config
			independent := 0
			for element in layout.elements[:layout.element_count] do if element.kind != .LFE do independent += element.channels
			rate := cfg.bit_rate == 0 ? 64000 * cfg.channels : cfg.bit_rate
			if rate < 8000 * cfg.channels || rate > min(512000 * cfg.channels, cfg.sample_rate * 6 * independent) do return .Invalid_Config
		}
	}
	// The native encoder tile/WPP tables have a fixed 128-row limit. Refuse
	// beyond that product envelope rather than letting dimensions overflow.
	// Decoders take what the levels allow: sides up to sqrt(8 * MaxLumaPs),
	// 16888 at H.265 level 6 (H.264 level 6's 16880 is within it).
	limit := config.operation == .Encode ? 8192 : 16888
	if !media.is_audio(config.codec) && (config.width > limit || config.height > limit) do return .Unsupported
	if config.operation == .Encode && !media.is_audio(config.codec) && (config.width < 16 || config.height < 16) do return .Unsupported
	if user != nil do return options_error(config, (^Options)(user)^)
	return .None
}

@(private)
State :: struct {
	avc_decoder:        ^avcd.Decoder_State,
	avc_encoder:        ^avce.Encoder_State,
	hevc_decoder:       ^hevcd.Decoder,
	hevc_alpha:         ^hevcd.Decoder, // the auxiliary alpha layer, once a VPS declares one
	alpha_pictures:     [dynamic]^hevcd.Picture, // alpha output awaiting its base picture
	alpha_premultiplied: bool, // the latest alpha channel information SEI says so
	hevc_encoder:       ^hevce.Encoder,
	hevc_alpha_encoder: ^hevce.Encoder, // the auxiliary alpha layer (Config.alpha)
	alpha_encoded:      [dynamic]u8,
	alpha_input:        []u16, // the alpha plane, then flat chroma planes
	joined:             [dynamic]u8, // both layers' access unit
	aac_encoder:        ^aace.Encoder,
	prores_decoder:     ^proresd.Decoder,
	vp9_decoder:        ^vp9d.Decoder,
	vp9_alpha:          ^vp9d.Decoder, // the alpha stream, opened on its first packet
	vp9_encoders:       [2]^vp9e.Encoder, // colour, and alpha with Config.alpha
	vp9_alpha_planes:   []u8, // the alpha encoder's input: alpha as luma, flat chroma
	audio_decoder:      ^audio.Decoder, // AAC, FLAC, MP3, Opus, ALAC and Vorbis decoding, the audio package's
	encoded:            [dynamic]u8,
	decoded:            [dynamic]^hevcd.Picture,
	input:              []u16,
	chroma_planes:      []u8, // NV12 input split into U then V
	pcm:                []f32,
	audio_sample_index: i64,
	nal_scratch:        hevcd.Nal_Scratch,
	pool:               ^common.Work_Pool,
}

@(private)
open_native :: proc(session: ^media.Session, config: media.Config, user: rawptr) -> media.Error {
	s := new(State)
	if s == nil {session.error_detail = "native session allocation failed"; return .Codec_Error}
	session.state = s
	session.close_impl = close_native
	session.drain_impl = drain_native
	session.decode_impl = decode_native
	session.video_impl = encode_video_native
	session.audio_impl = encode_audio_native
	options: Options
	if user != nil do options = (^Options)(user)^
	s.pool = options.pool
	if config.codec == .AAC do s.audio_sample_index = -i64(config.frame_samples == 0 ? 1024 : config.frame_samples)
	if config.operation == .Decode {
		switch config.codec {
		case .H264:
			s.avc_decoder = new(avcd.Decoder_State); avcd.init_decoder(s.avc_decoder)
			s.avc_decoder.no_reordering = config.no_reordering
		case .H265:
			s.hevc_decoder = new(hevcd.Decoder); hevcd.init_decoder(s.hevc_decoder)
		case .ProRes:
			s.prores_decoder = new(proresd.Decoder); proresd.init_decoder(s.prores_decoder, s.pool)
		case .VP9:
			s.vp9_decoder = new(vp9d.Decoder); vp9d.init_decoder(s.vp9_decoder, s.pool)
		case .AV1:
			return .Unsupported
		case .FLAC, .MP3, .Opus, .ALAC, .Vorbis, .AAC:
			s.audio_decoder = new(audio.Decoder)
			if s.audio_decoder == nil do return .Codec_Error
			if e := audio.init_decoder(s.audio_decoder, AUDIO_CODECS[config.codec], config.sample_rate, config.channels, config.extradata, config.frame_samples); e != .None {
				session.error_detail = s.audio_decoder.error_detail
				return e == .Unsupported ? .Unsupported : .Invalid_Config
			}
		}
		return .None
	}
	if config.codec == .H265 do s.encoded = make([dynamic]u8, 0, 65536)
	switch config.codec {
	case .ProRes, .FLAC, .MP3, .Opus, .ALAC, .Vorbis, .AV1:
		return .Unsupported // probe admits these for decoding only (AV1 not at all)
	case .VP9:
		return open_vp9_encoders(session, s, config, options)
	case .H264:
		s.avc_encoder = new(avce.Encoder_State)
		avc_config := avce.Encoder_Config {
			width               = config.width,
			height              = config.height,
			qp                  = config.qp,
			gop_size            = config.gop_size == 0 ? 15 : config.gop_size,
			slice_count         = options.h264_slice_count,
			colour_primaries    = config.color.primaries,
			transfer            = config.color.transfer,
			matrix_coefficients = config.color.matrix_coeffs,
			full_range          = config.color.full_range,
		}
		if config.frame_rate_den > 0 do avc_config.fps = f32(f64(config.frame_rate_num) / f64(config.frame_rate_den))
		if err := avce.init_encoder(s.avc_encoder, avc_config); err != .None do return map_avc_encoder_error(session, err)
	case .H265:
		s.hevc_encoder = new(hevce.Encoder)
		chroma: hevce.Chroma_Layout
		switch config.chroma {
		case .YUV420:
			chroma = .YUV_420
		case .YUV422:
			chroma = .YUV_422
		case .YUV444:
			chroma = .YUV_444
		case .Monochrome:
			chroma = .Monochrome
		}
		gop := config.gop_size == 0 ? 15 : config.gop_size
		hevc_config := hevce.Config {
			width = config.width,
			height = config.height,
			qp = config.qp,
			bit_depth = config.bit_depth,
			chroma_format = chroma,
			deblock = true,
			sao = true,
			forced_mode = -1,
			refs = 1,
			intra_only_i_slices = gop == 1,
			idr_period = gop > 1 ? gop : 0,
			pool = options.pool,
			tiles_cols = options.h265_tile_cols,
			tiles_rows = options.h265_tile_rows,
			fps_num = config.frame_rate_num,
			fps_den = config.frame_rate_den,
			colour_primaries = config.color.primaries,
			transfer = config.color.transfer,
			matrix_coeffs = config.color.matrix_coeffs,
			full_range = config.color.full_range,
		}
		if config.alpha {
			hevc_config.layer = .Base_With_Alpha
			hevc_config.alpha_premultiplied = config.alpha_premultiplied
			alpha_config := hevc_config
			alpha_config.layer = .Alpha
			// Full-range samples with no colour meaning, as Apple signals its
			// alpha layer.
			alpha_config.colour_primaries, alpha_config.transfer, alpha_config.matrix_coeffs = 2, 2, 2
			alpha_config.full_range = true
			s.hevc_alpha_encoder = new(hevce.Encoder)
			hevce.init_encoder(s.hevc_alpha_encoder, alpha_config)
		}
		hevce.init_encoder(s.hevc_encoder, hevc_config)
	case .AAC:
		cfg, e := aac_config(config)
		if e != .None do return .Invalid_Config
		s.aac_encoder = new(aace.Encoder)
		if s.aac_encoder == nil do return map_aac_error(session, .Allocation_Failed)
		if err := aace.init_encoder(s.aac_encoder, cfg, aac_transport(config.audio_transport));
		   err != .None {
			mapped := map_aac_error(session, err)
			return err == .Invalid_Config ? .Invalid_Config : mapped
		}
	}
	return .None
}

@(private)
close_native :: proc(session: ^media.Session) {
	s := (^State)(session.state)
	if s.avc_decoder != nil {avcd.destroy_decoder(s.avc_decoder); free(s.avc_decoder)}
	if s.avc_encoder != nil {avce.destroy_encoder(s.avc_encoder); free(s.avc_encoder)}
	if s.hevc_decoder != nil {
		for p in s.decoded do hevcd.release_picture(s.hevc_decoder, p)
		hevcd.destroy_decoder(s.hevc_decoder); free(s.hevc_decoder)
	}
	if s.hevc_alpha != nil {
		for p in s.alpha_pictures do hevcd.release_picture(s.hevc_alpha, p)
		hevcd.destroy_decoder(s.hevc_alpha); free(s.hevc_alpha)
	}
	delete(s.alpha_pictures)
	if s.hevc_encoder != nil {hevce.destroy_encoder(s.hevc_encoder); free(s.hevc_encoder)}
	if s.hevc_alpha_encoder != nil {hevce.destroy_encoder(s.hevc_alpha_encoder); free(s.hevc_alpha_encoder)}
	delete(s.alpha_encoded); delete(s.alpha_input); delete(s.joined)
	delete(s.chroma_planes)
	if s.prores_decoder != nil {proresd.destroy_decoder(s.prores_decoder); free(s.prores_decoder)}
	if s.vp9_decoder != nil {vp9d.destroy_decoder(s.vp9_decoder); free(s.vp9_decoder)}
	if s.vp9_alpha != nil {vp9d.destroy_decoder(s.vp9_alpha); free(s.vp9_alpha)}
	for e in s.vp9_encoders do if e != nil {vp9e.destroy_encoder(e); free(e)}
	delete(s.vp9_alpha_planes)
	if s.audio_decoder != nil {audio.destroy_decoder(s.audio_decoder); free(s.audio_decoder)}
	if s.aac_encoder != nil {aace.destroy_encoder(s.aac_encoder); free(s.aac_encoder)}
	hevcd.destroy_nal_scratch(&s.nal_scratch)
	delete(s.encoded); delete(s.decoded); delete(s.input); delete(s.pcm)
	free(s)
}

@(private)
u16_bytes :: #force_inline proc(samples: []u16) -> []u8 {
	return ([^]u8)(raw_data(samples))[:len(samples) * 2]
}

@(private)
decode_prores :: proc(session: ^media.Session, s: ^State, packet: media.Packet, receiver: media.Receiver) -> media.Error {
	if packet.framing != .Frame do return .Invalid_Input
	f, err := proresd.decode_frame(s.prores_decoder, packet.data)
	switch err {
	case .None:
	case .Unsupported:
		session.error_detail = "ProRes frame uses unsupported syntax"
		return .Unsupported
	case .Out_Of_Memory:
		return .Codec_Error
	case .Invalid_Data:
		session.error_detail = "malformed ProRes frame"
		return .Codec_Error
	}
	if receiver.video == nil do return .None
	h := f.header
	frame := media.Video_Frame {
		width        = f.width,
		height       = f.height,
		coded_width  = f.strides[0],
		coded_height = f.height,
		bit_depth    = f.bit_depth,
		storage_bits = 16,
		chroma       = f.chroma == .YUV444 ? .YUV444 : .YUV422,
		color        = {h.primaries, h.transfer, h.matrix_coeffs, false},
	}
	for i in 0 ..< 3 do frame.planes[i] = {u16_bytes(f.planes[i]), f.strides[i] * 2}
	if f.alpha != nil do frame.alpha = {u16_bytes(f.alpha), f.alpha_stride * 2}
	receiver.video(frame, receiver.user)
	return .None
}

// VP9 colour_space as H.273 code points; the range comes from the frame.
@(private)
vp9_color :: proc(p: vp9d.Picture) -> media.Color {
	c := media.Color{2, 2, 2, p.full_range}
	switch p.color_space {
	case 1:
		c = {6, 6, 6, p.full_range}
	case 2:
		c = {1, 1, 1, p.full_range}
	case 3:
		c = {6, 6, 6, p.full_range}
	case 4:
		c = {7, 7, 7, p.full_range}
	case 5:
		c = {9, 14, 9, p.full_range}
	case 7:
		c = {1, 13, 0, true} // sRGB in G, B, R planes
	}
	return c
}

@(private)
decode_vp9 :: proc(session: ^media.Session, s: ^State, packet: media.Packet, receiver: media.Receiver) -> media.Error {
	if packet.framing != .Frame do return .Invalid_Input
	map_error :: proc(session: ^media.Session, err: vp9d.Error) -> media.Error {
		switch err {
		case .None:
			return .None
		case .Unsupported:
			session.error_detail = "VP9 frame uses unsupported features"
			return .Unsupported
		case .Invalid_Data:
			session.error_detail = "malformed or incomplete VP9 frame"
			return .Codec_Error
		case .Out_Of_Memory:
			return .Codec_Error
		}
		return .Codec_Error
	}
	p, shown, err := vp9d.decode_packet(s.vp9_decoder, packet.data)
	if err != .None do return map_error(session, err)
	alpha: vp9d.Picture
	has_alpha := false
	if len(packet.alpha) > 0 {
		if s.vp9_alpha == nil {
			s.vp9_alpha = new(vp9d.Decoder)
			vp9d.init_decoder(s.vp9_alpha, s.pool)
		}
		a, alpha_shown, alpha_err := vp9d.decode_packet(s.vp9_alpha, packet.alpha)
		if alpha_err != .None do return map_error(session, alpha_err)
		has_alpha = alpha_shown && a.width == p.width && a.height == p.height && a.bit_depth == p.bit_depth
		alpha = a
	}
	if !shown || receiver.video == nil do return .None
	frame := media.Video_Frame {
		width        = p.width,
		height       = p.height,
		coded_width  = p.strides[0],
		coded_height = p.height,
		bit_depth    = p.bit_depth,
		storage_bits = p.bit_depth == 8 ? 8 : 16,
		color        = vp9_color(p),
	}
	switch {
	case p.ss_x == 1 && p.ss_y == 1:
		frame.chroma = .YUV420
	case p.ss_x == 1 && p.ss_y == 0:
		frame.chroma = .YUV422
	case p.ss_x == 0 && p.ss_y == 0:
		frame.chroma = .YUV444
	case:
		session.error_detail = "VP9 4:4:0 output has no common frame layout"
		return .Unsupported
	}
	plane_bytes :: proc(p: vp9d.Picture, i: int) -> media.Plane {
		if p.bit_depth == 8 do return {p.planes8[i], p.strides[i]}
		return {u16_bytes(p.planes16[i]), p.strides[i] * 2}
	}
	for i in 0 ..< 3 do frame.planes[i] = plane_bytes(p, i)
	if has_alpha do frame.alpha = plane_bytes(alpha, 0)
	receiver.video(frame, receiver.user)
	return .None
}

// The media codecs the audio package decodes.
@(private, rodata)
AUDIO_CODECS := #partial [media.Codec]audio.Codec {
	.AAC    = .AAC,
	.FLAC   = .FLAC,
	.MP3    = .MP3,
	.Opus   = .Opus,
	.ALAC   = .ALAC,
	.Vorbis = .Vorbis,
}

// An audio packet through the audio package's decoder, the one audio decode
// implementation. Its position is the packet's when the caller times
// packets (sample_rate set), else it follows on.
@(private)
decode_audio :: proc(session: ^media.Session, s: ^State, packet: media.Packet, receiver: media.Receiver) -> media.Error {
	framing: audio.Framing
	#partial switch packet.framing {
	case .Frame:
		framing = .Frame
	case .Raw_AAC:
		framing = .Raw_AAC
	case .ADTS:
		framing = .ADTS
	case .LOAS:
		framing = .LOAS
	case:
		return .Invalid_Input
	}
	index := audio.UNTIMED
	if packet.sample_rate != 0 {
		if packet.sample_rate != session.config.sample_rate do return .Invalid_Input
		index = packet.sample_index
	}
	pcm, first, err := audio.decode_packet(s.audio_decoder, packet.data, framing, index)
	switch err {
	case .None:
	case .Unsupported:
		session.error_detail = s.audio_decoder.error_detail
		return .Unsupported
	case .Codec_Error, .Out_Of_Memory:
		session.error_detail = s.audio_decoder.error_detail
		return .Codec_Error
	case .Invalid_Config, .Invalid_Input, .Invalid_Data, .IO_Error, .End_Of_Stream, .Closed:
		session.error_detail = s.audio_decoder.error_detail
		return .Invalid_Input
	}
	if receiver.audio == nil do return .None
	ch := session.config.channels
	// AAC is delivered a frame at a time, the others a packet at a time.
	frames := len(pcm) / ch
	step := session.config.codec == .AAC ? s.audio_decoder.aac.frame_samples : max(frames, 1)
	for at := 0; at < frames; at += step {
		n := min(step, frames - at)
		receiver.audio({samples = pcm[at * ch:][:n * ch], sample_rate = session.config.sample_rate, channels = ch, samples_per_channel = n, sample_index = first + i64(at)}, receiver.user)
	}
	return .None
}

@(private)
emit_avc :: proc(p: ^avcd.Picture, receiver: media.Receiver) {
	if receiver.video == nil do return
	b := p.buf
	size := b.high_depth ? 2 : 1
	sub_y := b.chroma_422 ? 1 : 2
	// The displayed samples of a plane, `size` bytes each.
	cropped :: proc(p: [^]u8, stride, x, y, w, h, size: int) -> media.Plane {
		return {p[(y * stride + x) * size:][:((h - 1) * stride + w) * size], stride * size}
	}
	receiver.video(
		{
			width = b.width,
			height = b.height,
			coded_width = b.coded_width,
			coded_height = b.coded_height,
			crop_x = b.crop_x,
			crop_y = b.crop_y,
			bit_depth = p.bit_depth,
			storage_bits = 8 * size,
			chroma = b.chroma_422 ? .YUV422 : .YUV420,
			poc = int(p.poc),
			planes = {
				cropped(b.y, b.y_stride, b.crop_x, b.crop_y, b.width, b.height, size),
				cropped(b.u, b.uv_stride, b.crop_x / 2, b.crop_y / sub_y, b.width / 2, b.height / sub_y, size),
				cropped(b.v, b.uv_stride, b.crop_x / 2, b.crop_y / sub_y, b.width / 2, b.height / sub_y, size),
			},
		},
		receiver.user,
	)
}

// Base-layer pictures in output order, each with the alpha picture of the
// same POC when the stream has an alpha layer. A base picture waits for
// its alpha picture until the stream drains; alpha pictures passed over
// (their base picture was never output) are released.
@(private)
emit_hevc :: proc(s: ^State, receiver: media.Receiver, draining := false) {
	for len(s.decoded) > 0 {
		p := s.decoded[0]
		alpha: ^hevcd.Picture
		if s.hevc_alpha != nil {
			match := -1
			for a, i in s.alpha_pictures do if a.poc == p.poc {match = i; break}
			if match < 0 && !draining do break
			if match >= 0 {
				for a in s.alpha_pictures[:match] do hevcd.release_picture(s.hevc_alpha, a)
				alpha = s.alpha_pictures[match]
				remove_range(&s.alpha_pictures, 0, match + 1)
			}
		}
		if receiver.video != nil {
			f := media.Video_Frame {
				width        = p.crop_w,
				height       = p.crop_h,
				coded_width  = p.width,
				coded_height = p.height,
				crop_x       = p.crop_x,
				crop_y       = p.crop_y,
				bit_depth    = int(p.bit_depth_y),
				storage_bits = 8 * p.sample_size,
				poc          = p.poc,
			}
			f.chroma =
				p.stride_c == 0 ? .Monochrome : (p.sub_w_c == 1 ? .YUV444 : (p.sub_h_c == 1 ? .YUV422 : .YUV420))
			for i in 0 ..< 3 {
				if i > 0 && p.stride_c == 0 do break
				f.planes[i] = cropped_plane(p, i)
			}
			// The alpha picture's luma, when it matches the base picture's
			// size, depth and storage.
			if alpha != nil && alpha.crop_w == p.crop_w && alpha.crop_h == p.crop_h && alpha.bit_depth_y == p.bit_depth_y && alpha.sample_size == p.sample_size {
				f.alpha = cropped_plane(alpha, 0)
				f.alpha_premultiplied = s.alpha_premultiplied
			}
			receiver.video(f, receiver.user)
		}
		hevcd.release_picture(s.hevc_decoder, p)
		if alpha != nil do hevcd.release_picture(s.hevc_alpha, alpha)
		ordered_remove(&s.decoded, 0)
	}
	if draining {
		for a in s.alpha_pictures do hevcd.release_picture(s.hevc_alpha, a)
		clear(&s.alpha_pictures)
	}
}

@(private)
cropped_plane :: proc(p: ^hevcd.Picture, i: int) -> media.Plane {
	bytes, stride := hevcd.plane_bytes(p, i)
	sw := i == 0 ? 1 : p.sub_w_c
	sh := i == 0 ? 1 : p.sub_h_c
	offset := (p.crop_y / sh) * stride + p.crop_x / sw
	count := (p.crop_h / sh - 1) * stride + p.crop_w / sw
	size := p.sample_size
	return {bytes[offset * size:(offset + count) * size], stride * size}
}

@(private)
decode_one_nal :: proc(
	session: ^media.Session,
	s: ^State,
	data: []u8,
	receiver: media.Receiver,
) -> media.Error {
	if s.avc_decoder != nil {
		if len(data) == 0 || data[0] & 0x80 != 0 do return .Invalid_Input
		ready, err := avcd.decode_nal(s.avc_decoder, data)
		if err != .None {
			session.error_detail = avcd.error_description(err)
			return avcd.is_unsupported(err) ? .Unsupported : .Codec_Error
		}
		if ready do emit_avc(s.avc_decoder.output, receiver)
		for {p := avcd.next_output_frame(s.avc_decoder); if p == nil do break; emit_avc(p, receiver)}
		return .None
	}
	nal, ok := hevcd.parse_nal_into(data, &s.nal_scratch)
	if !ok do return .Invalid_Input
	if nal.type == .PREFIX_SEI_NUT {
		if use, found := hevcd.parse_alpha_channel_info(nal.rbsp); found do s.alpha_premultiplied = use == .Premultiplied
	}
	if !hevcd.decode_nal(
		s.hevc_decoder,
		nal,
		&s.decoded,
	) {session.error_detail = "native HEVC rejected NAL"; return .Codec_Error}
	// A VPS that declares an auxiliary alpha layer starts its decoder.
	if nal.type == .VPS_NUT && s.hevc_alpha == nil {
		for _, v in s.hevc_decoder.vps do if v.alpha_layer_id != 0 {
			s.hevc_alpha = new(hevcd.Decoder)
			hevcd.init_decoder(s.hevc_alpha)
			s.hevc_alpha.layer = v.alpha_layer_id
			break
		}
	}
	if s.hevc_alpha != nil && (nal.layer_id == s.hevc_alpha.layer || nal.type == .VPS_NUT) {
		if !hevcd.decode_nal(s.hevc_alpha, nal, &s.alpha_pictures) {
			session.error_detail = "native HEVC rejected an alpha-layer NAL"
			return .Codec_Error
		}
	}
	emit_hevc(s, receiver)
	return .None
}

@(private)
decode_native :: proc(
	session: ^media.Session,
	packet: media.Packet,
	receiver: media.Receiver,
) -> media.Error {
	s := (^State)(session.state)
	switch session.config.codec {
	case .AV1:
		return .Unsupported
	case .ProRes:
		return decode_prores(session, s, packet, receiver)
	case .VP9:
		return decode_vp9(session, s, packet, receiver)
	case .FLAC, .MP3, .Opus, .ALAC, .Vorbis, .AAC:
		return decode_audio(session, s, packet, receiver)
	case .H264, .H265:
	}
	it := media.Nal_Iterator {
		packet = packet,
	}
	for {
		nal, done, err := media.next_nal(&it)
		if err != .None do return err
		if done do return .None
		if e := decode_one_nal(session, s, nal, receiver); e != .None do return e
	}
}

@(private)
emit_packet :: proc(s: ^State, framing: media.Framing, receiver: media.Receiver) {
	if len(s.encoded) != 0 && receiver.packet != nil do receiver.packet({data = s.encoded[:], framing = framing}, receiver.user)
	clear(&s.encoded)
}

@(private)
emit_aac_packet :: proc(
	session: ^media.Session,
	s: ^State,
	packet: []u8,
	receiver: media.Receiver,
) {
	if len(packet) == 0 do return
	n := s.aac_encoder.frame_samples
	if receiver.packet != nil do receiver.packet({data = packet, framing = aac_framing(session.config.audio_transport), sample_index = s.audio_sample_index, duration_samples = n, sample_rate = session.config.sample_rate}, receiver.user)
	s.audio_sample_index += i64(n)
}

@(private)
map_avc_encoder_error :: proc(session: ^media.Session, err: avce.Error) -> media.Error {
	if err == .None do return .None
	session.error_detail = avce.error_description(err)
	if s := (^State)(session.state); s.avc_encoder != nil && s.avc_encoder.error_detail != "" do session.error_detail = s.avc_encoder.error_detail
	#partial switch err {
	case .Invalid_Config:
		return .Invalid_Config
	case .Invalid_Input, .Output_Required:
		return .Invalid_Input
	case .Busy:
		return .Busy
	case .Unsupported_Platform, .Unsupported_Device, .Memory_Placement_Unavailable:
		return .Unsupported
	case .Vulkan_Unavailable:
		return .Unavailable
	case .Driver_Error:
		return .Driver_Error
	case:
		return .Codec_Error
	}
}

@(private)
encode_video_native :: proc(
	session: ^media.Session,
	frame: media.Video_Frame,
	receiver: media.Receiver,
) -> media.Error {
	s := (^State)(session.state)
	if frame.storage != .Host do return .Unsupported
	frame := frame
	if frame.chroma_interleaved do split_chroma(s, &frame) or_return
	if s.vp9_encoders[0] != nil do return encode_vp9(session, s, frame, receiver)
	if s.avc_encoder != nil {
		if frame.storage_bits != 8 || frame.planes[1].stride != frame.planes[2].stride do return .Unsupported
		is_idr := s.avc_encoder.frames_coded % s.avc_encoder.config.gop_size == 0
		lanes, err := avce.encode_frame_lanes(
			s.avc_encoder,
			raw_data(frame.planes[0].data),
			raw_data(frame.planes[1].data),
			raw_data(frame.planes[2].data),
			frame.planes[0].stride,
			frame.planes[1].stride,
			is_idr,
			s.pool,
		)
		if err != .None do return map_avc_encoder_error(session, err)
		if receiver.packet != nil {
			for nal in lanes do receiver.packet({data = nal, framing = .Annex_B}, receiver.user)
		}
		return .None
	} else {
		// The alpha plane is checked and copied before either layer advances.
		if e := load_alpha(s, frame); e != .None do return e
		sw, sh := media.chroma_subsampling(frame.chroma)
		cw, ch := frame.width / sw, frame.height / sh
		chroma_samples := frame.chroma == .Monochrome ? 0 : cw * ch
		direct := frame.storage_bits == 16
		if chroma_samples != 0 && frame.planes[1].stride != frame.planes[2].stride do direct = false
		for p, i in frame.planes {
			if i > 0 && chroma_samples == 0 do break
			if p.stride <= 0 || p.stride % 2 != 0 || uintptr(raw_data(p.data)) % align_of(u16) != 0 do direct = false
		}
		if direct {
			planes: [3][^]u16
			for p, i in frame.planes {
				if i > 0 && chroma_samples == 0 do break
				planes[i] = cast([^]u16)raw_data(p.data)
				w, h := i == 0 ? frame.width : cw, i == 0 ? frame.height : ch
				stride := p.stride / 2
				for row in 0 ..< h do for sample in planes[i][row * stride:row * stride + w] {
					if sample >= u16(1) << uint(frame.bit_depth) do return .Invalid_Input
				}
			}
			// Source planes are borrowed only until encode_frame returns. The
			// native encoder retains its own padded source; no alias is assumed.
			hevce.encode_frame(
				s.hevc_encoder,
				planes[0],
				planes[1],
				planes[2],
				frame.planes[0].stride / 2,
				chroma_samples == 0 ? 0 : frame.planes[1].stride / 2,
				&s.encoded,
			)
			if e := encode_alpha_layer(s, frame); e != .None do return e
			emit_packet(s, .Annex_B, receiver)
			return .None
		}
		total := frame.width * frame.height + 2 * chroma_samples
		// Native HEVC uses u16 even for 8-bit. Conversion scratch is retained
		// across calls; no picture retention or per-frame heap allocation.
		if len(s.input) != total {delete(s.input); s.input = make([]u16, total)}
		dst_offset := 0
		for i in 0 ..< 3 {
			if i > 0 && frame.chroma == .Monochrome do break
			w := i == 0 ? frame.width : cw
			h := i == 0 ? frame.height : ch
			p := frame.planes[i]
			for y in 0 ..< h do for x in 0 ..< w {
				value := u16(p.data[y * p.stride + x])
				if frame.storage_bits == 16 {
					at := y * p.stride + 2 * x
					value = u16(p.data[at]) | u16(p.data[at + 1]) << 8
				}
				if value >= u16(1) << uint(frame.bit_depth) do return .Invalid_Input
				s.input[dst_offset + y * w + x] = value
			}
			dst_offset += w * h
		}
		base := raw_data(s.input)
		hevce.encode_frame(
			s.hevc_encoder,
			base,
			chroma_samples == 0 ? nil : &base[frame.width * frame.height],
			chroma_samples == 0 ? nil : &base[frame.width * frame.height + chroma_samples],
			frame.width,
			cw,
			&s.encoded,
		)
	}
	if e := encode_alpha_layer(s, frame); e != .None do return e
	emit_packet(s, .Annex_B, receiver)
	return .None
}

// Copies the frame's alpha plane (luma's size, depth and storage) into the
// alpha layer's input, whose chroma stays flat at mid-grey.
@(private)
load_alpha :: proc(s: ^State, frame: media.Video_Frame) -> media.Error {
	if s.hevc_alpha_encoder == nil do return .None
	a := frame.alpha
	size := frame.storage_bits == 16 ? 2 : 1
	if a.stride < frame.width * size || len(a.data) < (frame.height - 1) * a.stride + frame.width * size do return .Invalid_Input
	sw, sh := media.chroma_subsampling(frame.chroma)
	cw, ch := frame.width / sw, frame.height / sh
	chroma := frame.chroma == .Monochrome ? 0 : cw * ch
	luma := frame.width * frame.height
	if len(s.alpha_input) != luma + 2 * chroma {
		delete(s.alpha_input)
		s.alpha_input = make([]u16, luma + 2 * chroma)
		for &v in s.alpha_input[luma:] do v = u16(1) << uint(frame.bit_depth - 1)
	}
	limit := u16(1) << uint(frame.bit_depth)
	for y in 0 ..< frame.height {
		row := s.alpha_input[y * frame.width:][:frame.width]
		src := a.data[y * a.stride:][:frame.width * size]
		if size == 1 {
			for &v, x in row do v = u16(src[x])
		} else {
			for &v, x in row {
				v = u16(src[2 * x]) | u16(src[2 * x + 1]) << 8
				if v >= limit do return .Invalid_Input
			}
		}
	}
	return .None
}

// Codes the loaded alpha plane as the alpha layer and joins both layers'
// access unit in s.encoded. The native H.265 encoder is low-delay, so each
// frame yields exactly one access unit per layer.
@(private)
encode_alpha_layer :: proc(s: ^State, frame: media.Video_Frame) -> media.Error {
	if s.hevc_alpha_encoder == nil do return .None
	sw, sh := media.chroma_subsampling(frame.chroma)
	cw, ch := frame.width / sw, frame.height / sh
	chroma := frame.chroma == .Monochrome ? 0 : cw * ch
	luma := frame.width * frame.height
	base := raw_data(s.alpha_input)
	hevce.encode_frame(
		s.hevc_alpha_encoder,
		base,
		chroma == 0 ? nil : &base[luma],
		chroma == 0 ? nil : &base[luma + chroma],
		frame.width,
		cw,
		&s.alpha_encoded,
	)
	clear(&s.joined)
	hevce.interleave_alpha(s.encoded[:], s.alpha_encoded[:], &s.joined)
	clear(&s.alpha_encoded)
	s.encoded, s.joined = s.joined, s.encoded
	return .None
}

@(private)
encode_audio_native :: proc(
	session: ^media.Session,
	frame: media.Audio_Frame,
	receiver: media.Receiver,
) -> media.Error {
	s := (^State)(session.state)
	if s.audio_sample_index > max(i64) - i64(s.aac_encoder.frame_samples) do return .Invalid_Input
	packet, err := aace.encode_frame_borrowed(s.aac_encoder, frame.samples)
	if err != .None do return map_aac_error(session, err)
	emit_aac_packet(session, s, packet, receiver)
	return .None
}

@(private)
drain_native :: proc(session: ^media.Session, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	if session.config.operation == .Encode {
		if s.hevc_encoder != nil do hevce.flush_encoder(s.hevc_encoder, &s.encoded)
		if s.aac_encoder != nil {
			for {
				if s.audio_sample_index > max(i64) - i64(s.aac_encoder.frame_samples) do return .Invalid_Input
				packet, err := aace.flush_encoder_next_borrowed(s.aac_encoder)
				if err != .None do return map_aac_error(session, err)
				if len(packet) == 0 do break
				emit_aac_packet(session, s, packet, receiver)
			}
			return .None
		}
		emit_packet(s, .Annex_B, receiver)
	} else {
		if s.avc_decoder != nil {
			if avcd.flush_decoder(s.avc_decoder) do emit_avc(s.avc_decoder.output, receiver)
			for {p := avcd.next_output_frame(s.avc_decoder); if p == nil do break; emit_avc(p, receiver)}
		}
		if s.hevc_decoder != nil {
			if !hevcd.flush_decoder(s.hevc_decoder, &s.decoded) do return .Codec_Error
			if s.hevc_alpha != nil && !hevcd.flush_decoder(s.hevc_alpha, &s.alpha_pictures) do return .Codec_Error
			emit_hevc(s, receiver, true)
		}
	}
	return .None
}

@(private)
map_aac_error :: proc(session: ^media.Session, err: aac.Error) -> media.Error {
	switch err {
	case .None:
		return .None
	case .Unsupported_Profile:
		session.error_detail = "AAC profile is unsupported"; return .Unsupported
	case .Unsupported_Channels:
		session.error_detail = "AAC channels are unsupported"; return .Unsupported
	case .Unsupported_Transport:
		session.error_detail = "AAC transport is unsupported"; return .Unsupported
	case .Unsupported_Tool:
		session.error_detail = "AAC coding tool is unsupported"; return .Unsupported
	case .Truncated:
		session.error_detail = "AAC input is truncated"; return .Invalid_Input
	case .Invalid_Data:
		session.error_detail = "AAC input is malformed"; return .Invalid_Input
	case .Crc_Mismatch:
		session.error_detail = "AAC integrity check failed"; return .Invalid_Input
	case .Allocation_Failed:
		session.error_detail = "AAC output allocation failed"; return .Codec_Error
	case .Invalid_Config:
		session.error_detail = "AAC configuration does not match the input"; return .Invalid_Input
	case .Output_Too_Small:
		session.error_detail = "AAC output buffer is too small"; return .Invalid_Input
	case .Invalid_State:
		session.error_detail = "AAC codec state is invalid"; return .Codec_Error
	}
	return .Codec_Error
}

// The native encoders read separate chroma planes: NV12 input (8-bit
// 4:2:0) is split once into U and V.
@(private)
split_chroma :: proc(s: ^State, frame: ^media.Video_Frame) -> media.Error {
	uv := frame.planes[1]
	cw, ch := frame.width / 2, frame.height / 2
	if frame.storage_bits != 8 || frame.chroma != .YUV420 do return .Unsupported
	if uv.stride < 2 * cw || len(uv.data) < (ch - 1) * uv.stride + 2 * cw do return .Invalid_Input
	if len(s.chroma_planes) != 2 * cw * ch {delete(s.chroma_planes); s.chroma_planes = make([]u8, 2 * cw * ch)}
	u, v := s.chroma_planes[:cw * ch], s.chroma_planes[cw * ch:]
	for y in 0 ..< ch {
		pairs := ([^][2]u8)(raw_data(uv.data[y * uv.stride:]))[:cw]
		for p, x in pairs do u[y * cw + x], v[y * cw + x] = p[0], p[1]
	}
	frame.planes[1], frame.planes[2] = {u, cw}, {v, cw}
	frame.chroma_interleaved = false
	return .None
}

// VP9 takes a quantizer index (0..255, 0 lossless) rather than a QP; five
// steps per QP spans it from the same 0..51 setting.
@(private)
vp9_q_index :: proc(qp: i32) -> int {
	return clamp(int(qp) * 5, 0, 255)
}

@(private)
open_vp9_encoders :: proc(session: ^media.Session, s: ^State, config: media.Config, options: Options) -> media.Error {
	gop := config.gop_size == 0 ? 15 : config.gop_size
	vp9_config := vp9e.Encoder_Config {
		width             = config.width,
		height            = config.height,
		base_q_idx        = vp9_q_index(config.qp),
		keyframe_interval = gop,
		tile_cols_log2    = 2,
		pool              = options.pool,
	}
	for i in 0 ..< (config.alpha ? 2 : 1) {
		s.vp9_encoders[i] = new(vp9e.Encoder)
		if vp9e.init_encoder(s.vp9_encoders[i], vp9_config) != .None {
			session.error_detail = "VP9 encoder refused the configuration"
			return .Invalid_Config
		}
	}
	if config.alpha {
		// Alpha is coded as the luma of a second stream whose chroma stays
		// flat at mid-grey.
		luma, chroma := config.width * config.height, ((config.width + 1) / 2) * ((config.height + 1) / 2)
		s.vp9_alpha_planes = make([]u8, luma + 2 * chroma)
		for &v in s.vp9_alpha_planes[luma:] do v = 128
	}
	return .None
}

// Encodes the colour and, with alpha, the alpha stream; one packet carries
// both frames (the alpha frame in Packet.alpha, for WebM BlockAdditional 1).
@(private)
encode_vp9 :: proc(session: ^media.Session, s: ^State, frame: media.Video_Frame, receiver: media.Receiver) -> media.Error {
	if frame.storage_bits != 8 do return .Unsupported
	// The alpha plane is checked and copied before either stream advances.
	w, h := frame.width, frame.height
	if s.vp9_encoders[1] != nil {
		a := frame.alpha
		if a.stride < w || len(a.data) < (h - 1) * a.stride + w do return .Invalid_Input
		for y in 0 ..< h do copy(s.vp9_alpha_planes[y * w:][:w], a.data[y * a.stride:][:w])
	}
	strides := [3]int{frame.planes[0].stride, frame.planes[1].stride, frame.planes[2].stride}
	packet, keyframe, err := vp9e.encode_frame(s.vp9_encoders[0], {frame.planes[0].data, frame.planes[1].data, frame.planes[2].data}, strides)
	if err != .None do return err == .Out_Of_Memory ? .Codec_Error : .Invalid_Input
	out := media.Packet {
		data     = packet,
		framing  = .Frame,
		keyframe = keyframe,
	}
	if s.vp9_encoders[1] != nil {
		cw, ch := (w + 1) / 2, (h + 1) / 2
		planes := s.vp9_alpha_planes
		alpha, alpha_key, alpha_err := vp9e.encode_frame(s.vp9_encoders[1], {planes[:w * h], planes[w * h:][:cw * ch], planes[w * h + cw * ch:]}, {w, cw, cw})
		if alpha_err != .None do return alpha_err == .Out_Of_Memory ? .Codec_Error : .Invalid_Input
		if alpha_key != keyframe {session.error_detail = "VP9 colour and alpha keyframes disagree"; return .Codec_Error}
		out.alpha = alpha
	}
	if receiver.packet != nil do receiver.packet(out, receiver.user)
	return .None
}

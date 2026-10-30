package media

import "core:mem"

// Providers are explicit imports. Applications using only hardware need not
// import/link the native codecs, and native-only applications need no GPU loader.
Codec :: enum {
	H264,
	H265,
	AAC,
	ProRes, // decode only; one frame per packet (Framing.Frame)
	VP9,    // a frame or superframe per packet, alpha in Packet.alpha; native encode is profile 0 (8-bit 4:2:0)
	FLAC,   // decode only; one frame per packet (Framing.Frame), streaminfo in Config.extradata
	MP3,    // decode only; MPEG-1/2/2.5 Layer III, one frame per packet (Framing.Frame)
	AV1,    // decode only, Vulkan Video; one temporal unit per packet (Framing.Frame), Main 4:2:0 8/10-bit
	Opus,   // decode only, 48 kHz; one packet per Packet (Framing.Frame), OpusHead in Config.extradata; channels in the Opus mapping order
	ALAC,   // decode only; one packet per Packet (Framing.Frame), 24-byte ALACSpecificConfig in Config.extradata
	Vorbis, // decode only; one packet per Packet (Framing.Frame), the three headers Xiph-laced in Config.extradata (Matroska's CodecPrivate)
}

is_audio :: proc(codec: Codec) -> bool {
	return codec == .AAC || codec == .FLAC || codec == .MP3 || codec == .Opus || codec == .ALAC || codec == .Vorbis
}
Operation :: enum {
	Decode,
	Encode,
}
Backend :: enum {
	Native,
	Vulkan,
	VideoToolbox,
	AVCodec,
	MediaFoundation,
}
// Automatic tries the tiers in this order: hardware, then odecs' own codecs,
// then a system library (libavcodec) for what neither has.
Tier :: enum {
	Hardware,
	Native,
	System,
}

provider_tier :: proc(backend: Backend) -> Tier {
	switch backend {
	case .Vulkan, .VideoToolbox:
		return .Hardware
	case .AVCodec, .MediaFoundation:
		return .System
	case .Native:
		return .Native
	}
	return .Native
}
Preference :: enum {
	Automatic,
	Require_Hardware,
	Native,
}
Chroma :: enum {
	YUV420,
	YUV422,
	YUV444,
	Monochrome,
}
Storage :: enum {
	Host,
	Device,
}
Framing :: enum {
	Annex_B,
	NAL,
	ADTS,
	Raw_AAC,
	LOAS,
	Frame, // one complete coded frame (ProRes), VP9 frame/superframe or AV1 temporal unit
}
Audio_Transport :: enum {
	ADTS,
	Raw,
	LOAS,
}
// ITU-T H.273 colour code points (the H.264/H.265 VUI and MP4 `colr`
// values). Zero primaries means no colour description. BT.709 limited range
// is {1, 1, 1, false}.
Color :: struct {
	primaries, transfer, matrix_coeffs: u8,
	full_range:                         bool,
}

Error :: enum {
	None,
	Invalid_Config,
	Invalid_Input,
	Unsupported,
	Unavailable,
	Driver_Error,
	Codec_Error,
	Closed,
	Wrong_Operation,
	Busy,
	Ended,
	Failed,
}

Config :: struct {
	codec:                           Codec,
	operation:                       Operation,
	preference:                      Preference,
	width, height:                   int,
	bit_depth:                       int, // 0 means 8; native HEVC may store 8-bit samples in u16.
	profile_idc:                     int, // decode: indexed source profile for hardware admission; 0 is unspecified
	// decode: the container shows presentation order equals decode order
	// (no reordered samples). H.264 then outputs each picture as soon as it
	// completes even when the SPS declares no reorder bound, which device
	// output requires.
	no_reordering:                   bool,
	chroma:                          Chroma,
	// encode: colour description written to the SPS VUI, so players convert
	// to RGB with the intended matrix and range. Zero leaves it unsignalled.
	color:                           Color,
	// encode: nominal frame rate for level selection; zero means unspecified.
	frame_rate_num, frame_rate_den:  int,
	output_storage:                  Storage, // decode: Host views or provider-native Device surfaces
	qp:                              i32,
	gop_size:                        int, // 0 uses the provider default; 1 requests all-intra encoding.
	sample_rate, channels, bit_rate: int,
	frame_samples:                   int, // AAC: 0 means 1024; 960 is available with Raw/LOAS.
	audio_transport:                 Audio_Transport, // AAC encoder framing; decode uses Packet.framing.
	extradata:                       []u8, // decode: borrowed AudioSpecificConfig, read during open only
	// encode: also code Video_Frame.alpha: an auxiliary alpha layer (H.265,
	// Annex F) or a second stream (VP9, Packet.alpha). alpha_premultiplied
	// says the colour planes are premultiplied by it (H.265 signals it as
	// alpha_channel_use_idc 1; VP9 colour is always straight).
	alpha:                           bool,
	alpha_premultiplied:             bool,
	// encode: prefer encode speed over size. Against the default at equal
	// quality (BD-rate over QP 22-34 on four 720p and 1080p clips), native
	// H.264 takes 0.55-0.58 of the time for 1% smaller to 32% larger output
	// and H.265 0.32-0.37 of the time for 28-66% larger. VP9 and the
	// hardware encoders do not use it yet.
	ultrafast:                       bool,
}

// Strides and lengths are in bytes. Each slice starts at the visible origin;
// it must contain (height-1)*stride + width*storage_bits/8 bytes.
Plane :: struct {
	data:   []u8,
	stride: int,
}
Video_Frame :: struct {
	width, height:                             int,
	coded_width, coded_height, crop_x, crop_y: int,
	bit_depth, storage_bits:                   int,
	chroma:                                    Chroma,
	planes:                                    [3]Plane,
	// encode, 4:2:0: planes[1] holds Cb and Cr interleaved (NV12, Vulkan
	// Video's own layout) and planes[2] is unused.
	chroma_interleaved:                        bool,
	poc:                                       int,
	storage:                                   Storage,
	// Alpha with the luma plane's size, depth and storage; empty without
	// alpha (decode: ProRes 4444, VP9 with an alpha stream, HEVC with an
	// auxiliary alpha layer, decoded natively).
	alpha:                                     Plane,
	// decode: the colour planes are premultiplied by alpha (HEVC
	// alpha_channel_use_idc 1); false for straight colour.
	alpha_premultiplied:                       bool,
	// decode: the colour description the bitstream carries for this frame;
	// zero primaries when it has none. Matrix 0 (identity) marks RGB
	// stored as G, B, R planes.
	color:                                     Color,
	// Device surfaces are interpreted by the selected provider, never as CPU
	// pointers. A provider must document synchronization and borrowing rules.
	surface:                                   rawptr,
}
Audio_Frame :: struct {
	samples:                                    []f32, // interleaved; exactly samples_per_channel*channels values
	sample_rate, channels, samples_per_channel: int,
	sample_index:                               i64,
}
Packet :: struct {
	data:             []u8,
	framing:          Framing,
	// AAC samples/channel, in the input PCM timeline. Encoded output starts
	// at -frame_samples for priming; input sample zero follows that delay.
	// Preserve the original unpadded input length separately for final padding.
	// A nonzero sample_rate marks explicit timing on decoder input packets.
	sample_index:     i64,
	duration_samples: int,
	sample_rate:      int,
	// VP9: the alpha stream's frame for this packet (WebM BlockAdditional 1),
	// decoded by its own decoder into Video_Frame.alpha. Nil without alpha.
	alpha:            []u8,
	// encode, VP9: the packet is a keyframe (H.264/H.265 say so in their NAL units).
	keyframe:         bool,
}

// Output is borrowed for the callback only. Consume/copy it before returning.
// Callbacks execute on the calling thread and must not re-enter the session.
Receiver :: struct {
	video:  proc(frame: Video_Frame, user: rawptr),
	audio:  proc(frame: Audio_Frame, user: rawptr),
	packet: proc(packet: Packet, user: rawptr),
	user:   rawptr,
}

Provider :: struct {
	backend: Backend,
	name:    string,
	// Optional provider binding, borrowed through every session opened with it.
	user:    rawptr,
	// Probe describes implemented support for this exact config, not merely
	// extensions advertised by a driver. Open performs final resource admission.
	probe:   proc(config: Config, user: rawptr) -> Error,
	open:    proc(session: ^Session, config: Config, user: rawptr) -> Error,
}

Session :: struct {
	config:              Config,
	backend:             Backend,
	provider_name:       string,
	// Automatic mode preserves the hardware admission error when using native.
	hardware_error:      Error,
	error_detail:        string, // provider-owned diagnostic, valid until the next call/close
	allocator:           mem.Allocator,
	state:               rawptr,
	decode_impl:         proc(session: ^Session, packet: Packet, receiver: Receiver) -> Error,
	video_impl:          proc(session: ^Session, frame: Video_Frame, receiver: Receiver) -> Error,
	audio_impl:          proc(session: ^Session, frame: Audio_Frame, receiver: Receiver) -> Error,
	drain_impl:          proc(session: ^Session, receiver: Receiver) -> Error,
	close_impl:          proc(session: ^Session),
	busy, ended, failed: bool,
}

default_config :: proc(codec: Codec, operation: Operation) -> Config {
	config := Config {
		codec     = codec,
		operation = operation,
		qp        = 26,
		bit_depth = 8,
	}
	if !is_audio(codec) && operation == .Encode do config.gop_size = 15
	return config
}

validate_config :: proc(config: Config) -> Error {
	if config.codec == .Opus {
		if config.channels < 1 || config.channels > 255 || config.sample_rate != 48000 do return .Invalid_Config // multistream
		return config.operation == .Decode ? .None : .Unsupported
	}
	if config.codec == .FLAC || config.codec == .MP3 || config.codec == .ALAC {
		if config.channels < 1 || config.channels > (config.codec == .MP3 ? 2 : 8) || config.sample_rate <= 0 do return .Invalid_Config
		return config.operation == .Decode ? .None : .Unsupported
	}
	if config.codec == .AAC {
		if config.channels < 1 || config.channels > 8 || config.sample_rate <= 0 || config.bit_rate < 0 do return .Invalid_Config
		if config.frame_samples != 0 && config.frame_samples != 1024 && config.frame_samples != 960 do return .Invalid_Config
		if config.operation == .Encode && len(config.extradata) != 0 do return .Invalid_Config
		return .None
	}
	depth := config.bit_depth == 0 ? 8 : config.bit_depth
	if depth != 8 && depth != 10 && depth != 12 do return .Unsupported
	if config.width < 0 || config.height < 0 || config.gop_size < 0 || config.profile_idc < 0 do return .Invalid_Config
	if config.frame_rate_num < 0 || config.frame_rate_den < 0 || (config.frame_rate_num == 0) != (config.frame_rate_den == 0) do return .Invalid_Config
	if config.codec == .AV1 && config.operation == .Encode do return .Unsupported
	if config.alpha && config.operation != .Encode do return .Invalid_Config
	if config.alpha && config.codec != .H265 && config.codec != .VP9 do return .Unsupported
	if config.alpha_premultiplied && config.codec == .VP9 do return .Invalid_Config
	if config.operation == .Encode {
		if config.profile_idc != 0 || config.no_reordering do return .Invalid_Config
		if config.width == 0 || config.height == 0 do return .Invalid_Config
		if config.qp < -6 * i32(depth - 8) || config.qp > 51 do return .Invalid_Config
		sw, sh := chroma_subsampling(config.chroma)
		if config.width % sw != 0 || config.height % sh != 0 do return .Invalid_Config
	}
	return .None
}

// Keep the Session at a stable address, do not copy it, and close before reuse.
// Fallback occurs only during open, never after consuming stream input.
open :: proc(
	session: ^Session,
	config: Config,
	providers: []Provider,
	allocator := context.allocator,
) -> Error {
	if session == nil do return .Invalid_Input
	if session.state != nil || session.busy do return .Busy
	if err := validate_config(config); err != .None do return err
	context.allocator = allocator
	last: Error = .Unavailable
	hardware_error: Error = config.preference == .Native ? .None : .Unavailable
	tiers := [3]Tier{.Hardware, .Native, .System}
	for tier in tiers {
		if tier != .Native && config.preference == .Native do continue
		if tier != .Hardware && config.preference == .Require_Hardware do continue
		for provider in providers {
			if provider_tier(provider.backend) != tier do continue
			if provider.probe == nil || provider.open == nil do continue
			err := provider.probe(config, provider.user)
			if err == .None {
				session^ = {
					config         = config,
					backend        = provider.backend,
					provider_name  = provider.name,
					allocator      = allocator,
					hardware_error = hardware_error,
				}
				err = provider.open(session, config, provider.user)
				if err == .None {
					missing_handler :=
						config.operation == .Decode ? session.decode_impl == nil : (is_audio(config.codec) ? session.audio_impl == nil : session.video_impl == nil)
					if session.state == nil ||
					   session.close_impl == nil ||
					   session.drain_impl == nil ||
					   missing_handler {
						if session.close_impl != nil do session.close_impl(session)
						session^ = {}
						return .Invalid_Config
					}
					if tier == .Hardware do session.hardware_error = .None
					return .None
				}
				if session.state != nil && session.close_impl != nil do session.close_impl(session)
				session^ = {}
			}
			last = err
			if tier == .Hardware do hardware_error = err
		}
	}
	return last
}

close :: proc(session: ^Session) -> Error {
	if session == nil do return .Invalid_Input
	if session.busy do return .Busy
	if session.state == nil do return .None
	context.allocator = session.allocator
	session.close_impl(session)
	session^ = {}
	return .None
}

@(private)
begin_call :: proc(session: ^Session, operation: Operation) -> Error {
	if session == nil || session.state == nil do return .Closed
	if session.busy do return .Busy
	if session.failed do return .Failed
	if session.ended do return .Ended
	if session.config.operation != operation do return .Wrong_Operation
	session.error_detail = ""
	session.busy = true
	return .None
}

decode :: proc(session: ^Session, packet: Packet, receiver: Receiver) -> Error {
	if err := begin_call(session, .Decode); err != .None do return err
	defer session.busy = false
	context.allocator = session.allocator
	if session.decode_impl == nil do return .Unsupported
	if len(packet.data) == 0 do return .Invalid_Input
	err := session.decode_impl(session, packet, receiver)
	// A rejected codec call may have advanced references or emitted outputs.
	// Recovery starts a new session at a random-access point, never switches
	// backends in the middle of a stream.
	if err != .None && err != .Busy do session.failed = true
	return err
}

encode_video :: proc(session: ^Session, frame: Video_Frame, receiver: Receiver) -> Error {
	if err := begin_call(session, .Encode); err != .None do return err
	defer session.busy = false
	context.allocator = session.allocator
	if is_audio(session.config.codec) || session.video_impl == nil do return .Wrong_Operation
	if frame.width != session.config.width || frame.height != session.config.height || frame.chroma != session.config.chroma || frame.bit_depth != (session.config.bit_depth == 0 ? 8 : session.config.bit_depth) do return .Invalid_Input
	if err := validate_frame(frame); err != .None do return err
	err := session.video_impl(session, frame, receiver)
	if err == .Codec_Error || err == .Driver_Error do session.failed = true
	return err
}

encode_audio :: proc(session: ^Session, frame: Audio_Frame, receiver: Receiver) -> Error {
	if err := begin_call(session, .Encode); err != .None do return err
	defer session.busy = false
	context.allocator = session.allocator
	if session.config.codec != .AAC || session.audio_impl == nil do return .Wrong_Operation
	n := session.config.frame_samples == 0 ? 1024 : session.config.frame_samples
	if frame.sample_rate != session.config.sample_rate || frame.channels != session.config.channels || frame.samples_per_channel != n || len(frame.samples) != n * frame.channels do return .Invalid_Input
	err := session.audio_impl(session, frame, receiver)
	if err == .Codec_Error || err == .Driver_Error do session.failed = true
	return err
}

drain :: proc(session: ^Session, receiver: Receiver) -> Error {
	if session == nil || session.state == nil do return .Closed
	if session.busy do return .Busy
	if session.failed do return .Failed
	if session.ended do return .None
	session.busy = true
	defer session.busy = false
	session.error_detail = ""
	context.allocator = session.allocator
	err := session.drain_impl(session, receiver)
	if err == .None do session.ended = true
	if err != .None && err != .Busy do session.failed = true
	return err
}

chroma_subsampling :: proc(chroma: Chroma) -> (int, int) {
	switch chroma {
	case .YUV420:
		return 2, 2
	case .YUV422:
		return 2, 1
	case .YUV444, .Monochrome:
		return 1, 1
	}
	return 1, 1
}

validate_frame :: proc(frame: Video_Frame) -> Error {
	if frame.width <= 0 || frame.height <= 0 do return .Invalid_Input
	if frame.storage == .Device do return frame.surface != nil ? .None : .Invalid_Input
	if frame.storage_bits != 8 && frame.storage_bits != 16 do return .Invalid_Input
	if frame.bit_depth <= 0 || frame.bit_depth > frame.storage_bits do return .Invalid_Input
	if frame.chroma_interleaved && frame.chroma != .YUV420 do return .Invalid_Input
	sw, sh := chroma_subsampling(frame.chroma)
	planes := frame.chroma == .Monochrome ? 1 : (frame.chroma_interleaved ? 2 : 3)
	for i in 0 ..< planes {
		w := i == 0 ? frame.width : 1 + (frame.width - 1) / sw
		if i == 1 && frame.chroma_interleaved do w *= 2 // Cb, Cr pairs
		h := i == 0 ? frame.height : 1 + (frame.height - 1) / sh
		if w > max(int) / (frame.storage_bits / 8) do return .Invalid_Input
		row := w * (frame.storage_bits / 8)
		p := frame.planes[i]
		if p.stride < row || len(p.data) < row do return .Invalid_Input
		// Division avoids overflowing the required buffer length.
		if h - 1 > (len(p.data) - row) / p.stride do return .Invalid_Input
	}
	return .None
}

// Borrowed NAL framing shared by native and hardware providers. Each input
// packet contains complete units; there is no retained packet-fragment state.
Nal_Iterator :: struct {
	packet:            Packet,
	offset:            int,
	started, finished: bool,
}

@(private)
find_start_code :: proc(data: []u8, off: int) -> (payload, start: int, ok: bool) {
	for i := off; i + 2 < len(data); i += 1 {
		if data[i] != 0 || data[i + 1] != 0 do continue
		if data[i + 2] == 1 do return i + 3, i, true
		if i + 3 < len(data) && data[i + 2] == 0 && data[i + 3] == 1 do return i + 4, i, true
	}
	return 0, 0, false
}

next_nal :: proc(it: ^Nal_Iterator) -> (data: []u8, done: bool, err: Error) {
	if it == nil do return nil, false, .Invalid_Input
	if it.finished do return nil, true, .None
	if len(it.packet.data) == 0 do return nil, false, .Invalid_Input
	if it.packet.framing == .NAL {
		it.finished = true
		return it.packet.data, false, .None
	}
	if it.packet.framing != .Annex_B do return nil, false, .Invalid_Input
	if !it.started {
		payload, start, found := find_start_code(it.packet.data, 0)
		if !found do return nil, false, .Invalid_Input
		for b in it.packet.data[:start] do if b != 0 do return nil, false, .Invalid_Input
		it.offset, it.started = payload, true
	}
	pos := it.offset
	next, end, more := find_start_code(it.packet.data, pos)
	if !more do end = len(it.packet.data)
	for end > pos && it.packet.data[end - 1] == 0 do end -= 1
	if end <= pos do return nil, false, .Invalid_Input
	if more {it.offset = next} else {it.finished = true}
	return it.packet.data[pos:end], false, .None
}

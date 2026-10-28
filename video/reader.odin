package video

import audio "../audio"
import mp4 "../container/mp4"
import webm "../container/webm"
import av1 "./av1"
import "base:intrinsics"
import "core:io"
import h264 "./h264"
import avcd "./h264/decoder"
import hevcd "./h265/decoder"
import media "../media"
import native "../media/native"
import videotoolbox "../media/videotoolbox"
import vulkan "../media/vulkan"
import prores "./prores"

Reader_Config :: struct {
	preference:          media.Preference, // Automatic decodes with Vulkan Video when admitted
	native_options:      ^native.Options, // its pool also runs ProRes slices and VP9 tiles
	gpu_context:         ^vulkan.Context,
	premultiplied_alpha: bool, // Frame.rgba premultiplied by alpha instead of straight
	format:              Frame_Format, // RGBA (default) or Planar
}

// The container, the audio codecs and the audio track's description are
// the audio package's: the reader opens the file through it.
Container :: audio.Container
Audio_Codec :: audio.Codec
Audio_Info :: audio.Info

Video_Info :: struct {
	width, height:    int, // decoded (cropped) size; frames come out in this size
	rotation:         int, // clockwise degrees the container asks players to rotate by
	codec:            Video_Codec,
	timescale:        u32, // ticks per second of Frame.pts
	frame_count:      int,
	duration:         f64, // presented seconds
	fps_num, fps_den: int, // nominal rate from the most common frame duration
	color:            media.Color, // colour description used for conversion
	has_alpha:        bool, // ProRes 4444 with alpha, VP9 with an alpha stream, or HEVC with an alpha layer
	bit_depth:        int, // coded sample depth; 0 until known (VP9: after the first frame)
	chroma:           media.Chroma,
	decodable:        bool, // a decoder admits the track (probed at open); else error_detail says why
}

// A decoded frame: RGBA8, top-down, tight rows. Alpha comes from the video
// when Video_Info.has_alpha (else 255), straight or premultiplied as
// configured. With Reader_Config.format = .Planar, `planar` holds the
// decoded planes instead and rgba is empty. Both are valid until the next
// frame call on the reader.
Frame :: struct {
	rgba:                  []u8,
	planar:                Planar,
	width, height, stride: int,
	pts:                   i64, // Video_Info.timescale ticks; the frame shows from pts until the next frame
	time:                  f64, // seconds
	index:                 int, // presentation-order frame number
}

Reader :: struct {
	config:         Reader_Config,
	// The opened file and its audio track (audio.Reader): the video track
	// reads its samples from the same container (audio.demux, audio.webm).
	audio:          audio.Reader,
	index:          Sample_Index, // the video track's samples, in Video_Info.timescale ticks
	color_from_frames: bool, // the container has no colour; use the bitstream's
	video_index:    int, // demuxer track, -1 when absent
	video:          Video_Info,
	chapters:       []Chapter,
	error_detail:   string,
	conversion:     Conversion_Cache,
	bit_depth:      int,
	parameter_sets: [dynamic][]u8, // views into the track's configuration record
	config_record:  []u8, // H.264 avcC or H.265 hvcC, borrowed from the demuxer
	nal_length_size: int, // bytes before each NAL unit in a sample
	// Video decode state.
	session:        media.Session,
	session_open:   bool,
	// A device the reader created once Vulkan won admission, so that seeks
	// reopen sessions on it instead of creating a device per restart.
	own_context:    ^vulkan.Context,
	preference:     media.Preference, // fixed after the first open selects a backend
	video_end:      i64, // presented end of the video track, in its ticks
	// Presentation ranks (positions in the pts order) of the first and last
	// presented frames; frames an edit list hides fall outside them.
	first_rank:     int,
	last_rank:      int,
	keyframes:      [dynamic]f64, // keyframe_times, built on the first call
	next_feed:      int, // next decode-order sample
	skip_before:    i64, // leading pictures of the starting keyframe are not fed
	pending:        [dynamic]i64, // pts of fed samples not yet output
	last_output:    i64,
	want_from:      i64, // earlier output is dropped without conversion
	drained:        bool,
	queue:          [dynamic]Queued_Frame,
	queue_head:     int,
	current:        Queued_Frame,
	has_current:    bool,
	free:           [dynamic][]u8,
	err:            Error,
}

// The video samples in decode order (borrowed from the demuxer's tables) and
// their presentation order.
@(private)
Sample_Index :: struct {
	pts:          []i64,
	sync:         []bool,
	presentation: []i32,
}

@(private)
Queued_Frame :: struct {
	pts:           i64,
	data:          []u8, // RGBA, or the planes of `planar`
	planar:        Planar,
	width, height: int,
}

open_reader :: proc(r: ^Reader, path: string, config := Reader_Config{}) -> Error {
	return open_input(r, config, path, {})
}

// Reads a stream with Read_At and Size; the reader borrows it until close.
open_reader_stream :: proc(r: ^Reader, stream: io.Stream, config := Reader_Config{}) -> Error {
	if stream.procedure == nil do return .Invalid_Config
	return open_input(r, config, "", stream)
}

@(private)
open_input :: proc(r: ^Reader, config: Reader_Config, path: string, stream: io.Stream) -> Error {
	if r == nil do return .Invalid_Config
	r^ = {
		config      = config,
		video_index = -1,
		preference  = config.preference,
	}
	// The file and its audio track; the video track is found in the same
	// container.
	if e := stream.procedure != nil ? audio.open_stream(&r.audio, stream) : audio.open(&r.audio, path); e != .None {
		r.error_detail = r.audio.error_detail
		return e
	}
	#partial switch r.audio.container {
	case .WebM:
		r.chapters = r.audio.webm.chapters
		for &t, i in r.audio.webm.tracks {
			video := t.codec == .VP9 || t.codec == .H264 || t.codec == .H265 || t.codec == .AV1
			if t.kind == .Video && video && len(t.samples) > 0 {r.video_index = i; break}
		}
	case .MP4:
		r.chapters = r.audio.demux.chapters
		for &t, i in r.audio.demux.tracks {
			video := t.codec == .H264 || t.codec == .H265 || t.codec == .ProRes || t.codec == .AV1
			if t.kind == .Video && video && len(t.samples) > 0 {r.video_index = i; break}
		}
	}
	if r.video_index >= 0 do if e := describe_video(r); e != .None {close_reader(r); return e}
	if r.video_index >= 0 do check_video(r)
	return .None
}

// A container reader's error: every container names them alike.
@(private)
container_error :: proc(e: $E) -> Error where intrinsics.type_is_enum(E) {
	#partial switch e {
	case .None:
		return .None
	case .Invalid_Argument:
		return .Invalid_Input
	case .Unsupported:
		return .Unsupported
	case .IO_Error:
		return .IO_Error
	case .Out_Of_Memory:
		return .Out_Of_Memory
	case .End_Of_Stream:
		return .End_Of_Stream
	case .Closed:
		return .Closed
	}
	return .Invalid_Data
}

@(private)
describe_video :: proc(r: ^Reader) -> Error {
	if r.audio.container == .WebM do return describe_webm_video(r)
	t := &r.audio.demux.tracks[r.video_index]
	n := len(t.samples)
	r.index = {t.samples.pts[:n], t.samples.sync[:n], t.presentation}
	r.video.timescale = t.timescale
	r.video.rotation = t.rotation
	r.video.width, r.video.height = t.width, t.height
	r.video_end = mp4.track_end(t)
	// Nominal rate from the most common sample duration.
	best, best_count, run, run_count: u32
	for i in 0 ..< n {
		d := t.samples[i].duration
		if d == run {run_count += 1} else {run, run_count = d, 1}
		if run_count > best_count do best, best_count = run, run_count
	}
	set_rate(r, i64(t.timescale), i64(best))
	count_frames(r)
	if t.codec == .ProRes do return describe_prores(r, t)
	if t.codec == .AV1 do return describe_av1_video(r, t.config, mp4_color(t.color), t.color_range_signalled)
	codec: Video_Codec = t.codec == .H264 ? .H264 : .H265
	return describe_nal_video(r, codec, t.config, mp4_color(t.color), t.color_range_signalled)
}

// H.264/H.265 in either container: parameter sets and NAL length size from
// the configuration record, then depth and colour from the SPS.
@(private)
describe_nal_video :: proc(r: ^Reader, codec: Video_Codec, record: []u8, container: media.Color, range_signalled: bool) -> Error {
	r.video.codec = codec
	r.video.chroma = .YUV420
	r.config_record = record
	c := record
	if codec == .H264 {
		if len(c) < 6 do return .Invalid_Data
		pos := 6
		count := int(c[5] & 0x1F)
		for set in 0 ..< 2 {
			for _ in 0 ..< count {
				if pos + 2 > len(c) do return .Invalid_Data
				n := int(c[pos]) << 8 | int(c[pos + 1])
				if n == 0 || pos + 2 + n > len(c) do return .Invalid_Data
				append(&r.parameter_sets, c[pos + 2:][:n])
				pos += 2 + n
			}
			if set == 0 {
				r.nal_length_size = int(c[4] & 3) + 1
				if pos >= len(c) do return .Invalid_Data
				count = int(c[pos])
				pos += 1
			}
		}
	} else {
		if len(c) < 23 do return .Invalid_Data
		r.nal_length_size = int(c[21] & 3) + 1
		pos := 23
		for _ in 0 ..< int(c[22]) {
			if pos + 3 > len(c) do return .Invalid_Data
			count := int(c[pos + 1]) << 8 | int(c[pos + 2])
			pos += 3
			for _ in 0 ..< count {
				if pos + 2 > len(c) do return .Invalid_Data
				n := int(c[pos]) << 8 | int(c[pos + 1])
				if n == 0 || pos + 2 + n > len(c) do return .Invalid_Data
				append(&r.parameter_sets, c[pos + 2:][:n])
				pos += 2 + n
			}
		}
	}
	if r.nal_length_size == 3 do return .Invalid_Data
	r.bit_depth = 8
	r.video.color = resolve_color(container, range_signalled, sps_color(r, codec), r.video.height)
	r.video.bit_depth = r.bit_depth
	return .None
}

// ProRes: geometry, depth, alpha and colour from the first frame header.
// ProRes video is limited range.
@(private)
describe_prores :: proc(r: ^Reader, t: ^mp4.Track) -> Error {
	p, e := mp4.read_sample(&r.audio.demux, r.video_index, 0)
	if e != .None do return mp4_error(e)
	h, he := prores.parse_frame_header(p.data)
	if he != .None {
		r.error_detail = "the first ProRes frame is unreadable"
		return he == .Unsupported ? .Unsupported : .Invalid_Data
	}
	r.video.codec = .ProRes
	r.video.width, r.video.height = h.width, h.height
	r.video.has_alpha = h.alpha_bits != 0
	r.video.chroma = h.chroma == .YUV444 ? .YUV444 : .YUV422
	r.bit_depth = h.chroma == .YUV444 ? 12 : 10
	r.video.bit_depth = r.bit_depth
	header := media.Color{h.primaries, h.transfer, h.matrix_coeffs, false}
	if header.primaries == 0 do header = {}
	container := mp4_color(t.color)
	container.full_range = false
	r.video.color = resolve_color(container, true, header, r.video.height)
	return .None
}

// AV1 in either container: the av1C record (a 4-byte header, then the
// configuration OBUs) gives the sequence header, and with it depth, chroma
// and colour. The OBUs are fed to the decoder once, ahead of the samples.
@(private)
describe_av1_video :: proc(r: ^Reader, record: []u8, container: media.Color, range_signalled: bool) -> Error {
	r.video.codec = .AV1
	r.config_record = record
	if len(record) < 4 || record[0] != 0x81 do return .Invalid_Data
	obus := record[4:]
	for at := 0; at < len(obus); {
		o, next, e := av1.next_obu(obus, at)
		if e != .None do return .Invalid_Data
		at = next
		if o.type != .Sequence_Header do continue
		s, se := av1.parse_sequence_header(o.payload)
		if se != .None {
			r.error_detail = "unsupported AV1 sequence header"
			return se == .Unsupported ? .Unsupported : .Invalid_Data
		}
		c := s.color
		switch {
		case c.mono_chrome:
			r.video.chroma = .Monochrome
		case c.subsampling_x == 1 && c.subsampling_y == 1:
			r.video.chroma = .YUV420
		case c.subsampling_x == 1:
			r.video.chroma = .YUV422
		case:
			r.video.chroma = .YUV444
		}
		r.bit_depth = int(c.bit_depth)
		r.video.bit_depth = r.bit_depth
		stream: media.Color
		if c.color_description_present_flag do stream = {c.color_primaries, c.transfer_characteristics, c.matrix_coefficients, c.color_range}
		stream.full_range = c.color_range
		r.video.color = resolve_color(container, range_signalled, stream, r.video.height)
		append(&r.parameter_sets, obus)
		return .None
	}
	return .Invalid_Data // av1C must carry the sequence header
}

// Matroska video: timing and geometry from the track. H.264/H.265 continue
// as in MP4; for VP9, alpha and colour come from the track and depth, chroma
// and the bitstream's colour space from the first decoded frame.
@(private)
describe_webm_video :: proc(r: ^Reader) -> Error {
	t := &r.audio.webm.tracks[r.video_index]
	n := len(t.samples)
	r.index = {t.samples.pts[:n], t.samples.sync[:n], t.presentation}
	r.video.timescale = 1_000_000_000 // WebM timestamps are nanoseconds
	r.video.width, r.video.height = t.width, t.height
	r.video_end = webm.track_end(t)
	step := t.default_duration
	if step == 0 && n > 1 {
		// The most common timestamp step.
		best, best_count, run, run_count: i64
		for k in 1 ..< n {
			d := t.samples[t.presentation[k]].pts - t.samples[t.presentation[k - 1]].pts
			if d == run {run_count += 1} else {run, run_count = d, 1}
			if run_count > best_count do best, best_count = run, run_count
		}
		step = best
	}
	set_rate(r, 1_000_000_000, step)
	// A last frame without a duration lasts the typical step.
	if last := t.presentation[n - 1]; t.samples[last].duration <= 0 do r.video_end = max(r.video_end, t.samples[last].pts + step)
	count_frames(r)
	// Matroska Colour: 2 means unspecified, range 1 limited and 2 full.
	c := t.color
	container: media.Color
	if c.matrix_coeffs != 2 || c.primaries != 2 || c.transfer != 2 {
		container = {c.primaries, c.transfer, c.matrix_coeffs, c.range == 2}
	}
	if t.codec == .H264 || t.codec == .H265 {
		return describe_nal_video(r, t.codec == .H264 ? .H264 : .H265, t.codec_private, container, c.range == 1 || c.range == 2)
	}
	if t.codec == .AV1 do return describe_av1_video(r, t.codec_private, container, c.range == 1 || c.range == 2)
	r.video.codec = .VP9
	r.video.has_alpha = t.alpha
	r.video.chroma = .YUV420
	r.video.bit_depth = int(t.color.bits_per_channel)
	r.bit_depth = r.video.bit_depth
	r.color_from_frames = container.primaries == 0 && container.matrix_coeffs == 0
	r.video.color = resolve_color(container, c.range == 1 || c.range == 2, {}, r.video.height)
	if c.matrix_coeffs == 0 do r.video.color.matrix_coeffs = 0 // stated identity: RGB
	return .None
}

// Nominal frame rate from ticks per second and the typical frame duration.
// Rates within rounding of an integer or NTSC (x/1001) rate are reported as
// that rate: WebM stores whole nanoseconds, so 30 fps is 33333333 ns.
@(private)
set_rate :: proc(r: ^Reader, ticks_per_second, frame_ticks: i64) {
	if frame_ticks <= 0 do return
	fps := f64(ticks_per_second) / f64(frame_ticks)
	for den in ([2]i64{1, 1001}) {
		num := i64(fps * f64(den) + 0.5)
		if num > 0 && abs(f64(num) / f64(den) - fps) < fps * 1e-6 {
			r.video.fps_num, r.video.fps_den = int(num), int(den)
			return
		}
	}
	a, b := ticks_per_second, frame_ticks
	for b != 0 do a, b = b, a % b
	r.video.fps_num, r.video.fps_den = int(ticks_per_second / a), int(frame_ticks / a)
}

// Presented frames run from the frame on screen at time zero to the last
// frame that starts before the presented end.
@(private)
count_frames :: proc(r: ^Reader) {
	r.video.duration = f64(r.video_end) / f64(r.video.timescale)
	if s := sample_at(&r.index, 0); s >= 0 do r.first_rank = rank_of(&r.index, r.index.pts[s])
	r.last_rank = rank_of(&r.index, r.video_end) - 1
	r.video.frame_count = max(r.last_rank - r.first_rank + 1, 0)
}

// Colour for conversion: the container's `colr`, with fields it leaves
// unspecified (and the range, which QuickTime nclc cannot carry) from the SPS
// VUI; without either, the common player assumption of BT.601 up to 576
// lines and BT.709 above. Zero primaries mean absent.
resolve_color :: proc(container: media.Color, range_signalled: bool, vui: media.Color, height: int) -> (color: media.Color) {
	color = container
	if color.primaries == 0 {
		color = vui
	} else {
		if !range_signalled do color.full_range = vui.full_range
		if color.primaries == 2 && vui.primaries != 0 do color.primaries = vui.primaries
		if color.transfer == 2 && vui.transfer != 0 do color.transfer = vui.transfer
		if color.matrix_coeffs == 2 && vui.matrix_coeffs != 0 do color.matrix_coeffs = vui.matrix_coeffs
	}
	if color.matrix_coeffs == 2 || color.matrix_coeffs == 0 do color.matrix_coeffs = height <= 576 ? 6 : 1
	if color.primaries == 0 do color.primaries = 2
	if color.transfer == 0 do color.transfer = 2
	return
}

@(private)
mp4_color :: proc(c: mp4.Color) -> media.Color {
	return {c.primaries, c.transfer, c.matrix_coeffs, c.full_range}
}

@(private, rodata)
SPS_CHROMA := [4]media.Chroma{.Monochrome, .YUV420, .YUV422, .YUV444}

// The VUI colour description, bit depth and chroma format of the first SPS,
// through the native decoders' own SPS parsers.
@(private)
sps_color :: proc(r: ^Reader, codec: Video_Codec) -> (color: media.Color) {
	scratch: [dynamic]u8
	defer delete(scratch)
	for nal in r.parameter_sets {
		if codec == .H264 && nal[0] & 0x1F == 7 {
			reader := h264.init_bit_reader(h264.unescape_rbsp_into_buffer(nal[1:], &scratch))
			sps, ok := avcd.parse_sequence_parameter_set(&reader)
			if !ok do return
			r.bit_depth = 8 + int(sps.luma_bit_depth_minus_8)
			r.video.chroma = SPS_CHROMA[u32(sps.chroma_format)]
			if sps.colour_primaries == 2 && sps.matrix_coefficients == 2 && !sps.video_full_range do return
			return {sps.colour_primaries, sps.transfer_characteristics, sps.matrix_coefficients, sps.video_full_range}
		}
		if codec == .H265 && len(nal) > 2 && (nal[0] >> 1) & 0x3F == 32 {
			// A VPS declaring an auxiliary alpha layer (decoded natively).
			clear(&scratch)
			zeros := 0
			for b in nal[2:] {
				if zeros >= 2 && b == 3 {zeros = 0; continue}
				append(&scratch, b)
				zeros = b == 0 ? zeros + 1 : 0
			}
			if v, ok := hevcd.parse_vps(scratch[:]); ok && v.alpha_layer_id != 0 do r.video.has_alpha = true
			continue
		}
		// The base layer's SPS (an alpha layer has its own, with layer id 1).
		if codec == .H265 && len(nal) > 2 && (nal[0] >> 1) & 0x3F == 33 && (nal[0] & 1) << 5 | nal[1] >> 3 == 0 {
			clear(&scratch)
			zeros := 0
			for b in nal[2:] {
				if zeros >= 2 && b == 3 {zeros = 0; continue}
				append(&scratch, b)
				zeros = b == 0 ? zeros + 1 : 0
			}
			sps, ok := hevcd.parse_sps(scratch[:])
			if !ok do return
			defer hevcd.destroy_sps(&sps)
			r.bit_depth = int(sps.bit_depth_luma)
			r.video.chroma = SPS_CHROMA[min(sps.chroma_format_idc, 3)]
			if sps.colour_primaries == 2 && sps.matrix_coeffs == 2 && !sps.full_range do return
			return {u8(sps.colour_primaries), u8(sps.transfer_char), u8(sps.matrix_coeffs), sps.full_range}
		}
	}
	return
}

close_reader :: proc(r: ^Reader) {
	if r == nil do return
	if r.session_open do media.close(&r.session)
	if r.own_context != nil {
		vulkan.destroy_context(r.own_context)
		free(r.own_context)
	}
	audio.close(&r.audio)
	for q in r.queue[r.queue_head:] do delete(q.data)
	if r.has_current do delete(r.current.data)
	for b in r.free do delete(b)
	delete(r.free)
	delete(r.queue)
	delete(r.pending)
	delete(r.parameter_sets)
	delete(r.keyframes)
	free(r.conversion.tone)
	r^ = {}
}

@(private, rodata)
VIDEO_CODECS := [Video_Codec]media.Codec {
	.H264   = .H264,
	.H265   = .H265,
	.ProRes = .ProRes,
	.VP9    = .VP9,
	.AV1    = .AV1,
}

// The video track's decoder configuration.
@(private)
video_config :: proc(r: ^Reader) -> media.Config {
	codec := VIDEO_CODECS[r.video.codec]
	config := media.default_config(codec, .Decode)
	config.preference = r.preference
	// The hardware decoders decode only an HEVC stream's base layer.
	if codec == .H265 && r.video.has_alpha do config.preference = .Native
	config.width, config.height = r.video.width, r.video.height
	config.bit_depth = r.bit_depth
	config.chroma = r.video.chroma
	if codec == .H264 || codec == .H265 {
		// Matroska does not say whether frames are reordered.
		config.no_reordering = r.audio.container == .MP4 && codec == .H264 && r.audio.demux.tracks[r.video_index].no_reordering
		c := r.config_record
		if codec == .H264 && len(c) > 1 {
			switch c[1] {
			case 66, 77, 100:
				config.profile_idc = int(c[1])
			}
		} else if codec == .H265 && len(c) > 1 {
			profile := int(c[1] & 0x1F)
			if profile >= 1 && profile <= 4 do config.profile_idc = profile
		}
	} else {
		config.no_reordering = true
	}
	return config
}

// The video decoders in admission order. VideoToolbox reports itself
// unavailable off Apple platforms, Vulkan Video on them.
@(private)
video_providers :: proc(r: ^Reader) -> [3]media.Provider {
	shared := r.config.gpu_context != nil ? r.config.gpu_context : r.own_context
	return {native.provider(r.config.native_options), videotoolbox.provider(), vulkan.provider(shared)}
}

@(private)
undecodable_detail :: proc(r: ^Reader) -> string {
	if r.video.codec == .AV1 do return "AV1 needs a GPU with Vulkan Video AV1 decoding (Main, 4:2:0, 8 or 10 bits)"
	return "no decoder admits this video track"
}

// Whether a decoder admits the video track, from the providers' probes
// without opening a session: native first, then the hardware probes (which
// enumerate GPUs) only when native refuses.
@(private)
check_video :: proc(r: ^Reader) {
	config := video_config(r)
	for p in video_providers(r) {
		hardware := p.backend != .Native
		if hardware && config.preference == .Native || !hardware && config.preference == .Require_Hardware do continue
		if p.probe != nil && p.probe(config, p.user) == .None {r.video.decodable = true; return}
	}
	r.error_detail = undecodable_detail(r)
}

// Restarts video decoding at decode-order sample k (a keyframe).
@(private)
reset_video :: proc(r: ^Reader, k: int) -> Error {
	if r.session_open {media.close(&r.session); r.session_open = false}
	config := video_config(r)
	codec := config.codec
	shared := r.config.gpu_context != nil ? r.config.gpu_context : r.own_context
	providers := video_providers(r)
	if e := media.open(&r.session, config, providers[:]); e != .None {
		r.error_detail = undecodable_detail(r)
		return media_error(e)
	}
	r.session_open = true
	if r.session.backend == .Vulkan && shared == nil {
		// First hardware admission with a provider-owned device: move to a
		// reader-owned Context. If that fails the provider device still works.
		c := new(vulkan.Context)
		request := vulkan.Request {
			codec       = codec == .H264 ? .H264 : (codec == .AV1 ? .AV1 : .H265),
			operation   = .Decode,
			width       = config.width,
			height      = config.height,
			bit_depth   = config.bit_depth,
			profile_idc = config.profile_idc,
		}
		if vulkan.init_context(c, {requests = {request}, device_index = -1}) == .None {
			media.close(&r.session)
			config.preference = .Require_Hardware
			providers[2] = vulkan.provider(c)
			if media.open(&r.session, config, providers[:]) != .None {
				r.session_open = false
				vulkan.destroy_context(c)
				free(c)
				r.error_detail = "hardware decoder failed on its shared device"
				return .Codec_Error
			}
			r.own_context = c
		} else {
			free(c)
		}
	}
	// Later restarts use the backend the first open selected.
	r.preference = r.session.backend == .Native ? .Native : .Require_Hardware
	for nal in r.parameter_sets {
		// AV1's configuration OBUs go in as a packet without frames.
		framing: media.Framing = codec == .AV1 ? .Frame : .NAL
		if e := media.decode(&r.session, {data = nal, framing = framing}, {video = on_frame, user = r}); e != .None {
			r.error_detail = r.session.error_detail
			return media_error(e)
		}
	}
	r.next_feed = k
	r.skip_before = r.index.pts[k]
	clear(&r.pending)
	for q in r.queue[r.queue_head:] do append(&r.free, q.data)
	clear(&r.queue)
	r.queue_head = 0
	r.last_output = min(i64)
	r.drained = false
	r.err = .None
	return .None
}

@(private)
on_frame :: proc(f: media.Video_Frame, user: rawptr) {
	r := (^Reader)(user)
	if len(r.pending) == 0 {r.err = .Codec_Error; r.error_detail = "decoder produced more pictures than samples"; return}
	// Pictures leave the decoder in presentation order: each takes the
	// smallest outstanding timestamp.
	first := 0
	for p, i in r.pending do if p < r.pending[first] do first = i
	pts := r.pending[first]
	unordered_remove(&r.pending, first)
	r.last_output = pts
	if r.video.bit_depth == 0 || r.video.codec == .VP9 {
		r.video.bit_depth = f.bit_depth
		r.video.chroma = f.chroma
	}
	if r.color_from_frames && f.color.primaries != 0 {
		// Matrix 0 is H.273's identity: RGB in G, B, R planes, kept as is.
		c := f.color
		if c.matrix_coeffs != 0 do c = resolve_color({}, true, c, r.video.height)
		r.video.color = c
		r.color_from_frames = false
	}
	if pts < r.want_from || f.storage != .Host do return
	color := r.video.color
	// Matrix 0, H.273's identity, marks G, B, R planes (VP9 sRGB).
	if f.color.primaries != 0 && f.color.matrix_coeffs == 0 do color.matrix_coeffs = 0
	planar := r.config.format == .Planar
	size := planar ? planar_bytes(f) : f.width * f.height * 4
	buffer: []u8
	for len(r.free) > 0 {
		b := pop(&r.free)
		if len(b) == size {buffer = b; break}
		delete(b)
	}
	if buffer == nil do buffer = make([]u8, size)
	job := Convert_Job {
		frame = f,
		dst   = buffer,
	}
	set_alpha(&job, {f.alpha.data, f.alpha.stride, r.config.premultiplied_alpha}, f.alpha_premultiplied)
	queued := Queued_Frame{pts = pts, data = buffer, width = f.width, height = f.height}
	if planar {
		queued.planar = planar_layout(f, color, buffer)
		job.planar = &queued.planar
	} else {
		prepare_conversion(&r.conversion, &job, color)
	}
	// Bands of rows convert (or copy) independently on the caller's pool.
	run_bands(&job, r.config.native_options != nil ? r.config.native_options.pool : nil)
	append(&r.queue, queued)
}

// Rows per conversion band; even, so subsampled chroma rows align.
@(private)
CONVERT_BAND :: 64

@(private)
Convert_Job :: struct {
	frame:        media.Video_Frame,
	alpha:        Alpha_Plane,
	coefficients: ^Yuv_To_Rgb,
	tone:         ^Tone_Map, // set: HDR or wide-gamut conversion instead
	planar:       ^Planar, // set: copy the planes here instead of converting
	dst:          []u8,
	gbr:          bool,
	// The decoded colour is premultiplied and straight RGBA is wanted.
	unpremultiply: bool,
}

// Sets the job's alpha for output premultiplied or straight, as
// `want.premultiply` says, from decoded colour that is premultiplied or
// straight.
@(private)
set_alpha :: proc(job: ^Convert_Job, want: Alpha_Plane, premultiplied_source: bool) {
	job.alpha = want
	if len(want.data) == 0 || !premultiplied_source do return
	job.alpha.premultiply = false
	job.unpremultiply = !want.premultiply
}

@(private)
convert_bands :: proc(data: rawptr, first, end: int) {
	job := (^Convert_Job)(data)
	f := &job.frame
	sx, sy := media.chroma_subsampling(f.chroma)
	shift_x, shift_y := uint(sx >> 1), uint(sy >> 1)
	for band in first ..< end {
		y0 := band * CONVERT_BAND
		rows := min(CONVERT_BAND, f.height - y0)
		if job.planar != nil {
			copy_planar_band(f, job.planar, y0, rows)
			continue
		}
		planes: [3][]u8
		strides: [3]int
		for i in 0 ..< 3 {
			if i > 0 && f.chroma == .Monochrome do break
			row := i == 0 ? y0 : y0 >> shift_y
			strides[i] = f.planes[i].stride
			planes[i] = f.planes[i].data[row * strides[i]:]
		}
		alpha := job.alpha
		if len(alpha.data) > 0 do alpha.data = alpha.data[y0 * alpha.stride:]
		dst := job.dst[y0 * f.width * 4:]
		if job.gbr {
			gbr_to_rgba(planes, strides, f.width, rows, f.storage_bits, f.bit_depth, alpha, dst, f.width * 4)
		} else if job.tone != nil {
			hdr_to_rgba(planes, strides, f.width, rows, f.storage_bits, shift_x, shift_y, job.tone, dst, f.width * 4, alpha, f.bit_depth)
		} else {
			yuv_to_rgba(planes, strides, f.width, rows, f.storage_bits, shift_x, shift_y, job.coefficients, dst, f.width * 4, alpha, f.bit_depth)
		}
		if job.unpremultiply do unpremultiply_rgba(dst[:rows * f.width * 4])
	}
}


// Reads one decode-order video sample: its coded data and, for VP9 in
// WebM, the alpha stream's frame.
@(private)
read_video_sample :: proc(r: ^Reader, i: int) -> (data, alpha: []u8, err: Error) {
	if r.audio.container == .WebM {
		p, e := webm.read_sample(&r.audio.webm, r.video_index, i)
		if e != .None do return nil, nil, container_error(e)
		return p.data, p.additional, .None
	}
	p, e := mp4.read_sample(&r.audio.demux, r.video_index, i)
	if e != .None do return nil, nil, mp4_error(e)
	return p.data, nil, .None
}

// Feeds one decode-order sample, or drains after the last.
@(private)
advance_video :: proc(r: ^Reader) -> Error {
	receiver := media.Receiver {
		video = on_frame,
		user  = r,
	}
	if r.next_feed >= len(r.index.pts) {
		if e := media.drain(&r.session, receiver); e != .None {r.error_detail = r.session.error_detail; return media_error(e)}
		r.drained = true
		return r.err
	}
	i := r.next_feed
	r.next_feed += 1
	pts := r.index.pts[i]
	if pts < r.skip_before do return .None
	data, alpha := read_video_sample(r, i) or_return
	append(&r.pending, pts)
	if r.video.codec == .ProRes || r.video.codec == .VP9 || r.video.codec == .AV1 {
		if de := media.decode(&r.session, {data = data, framing = .Frame, alpha = alpha}, receiver); de != .None {
			r.error_detail = r.session.error_detail
			return media_error(de)
		}
		// ProRes and VP9 deliver each packet's picture during the call; a VP9
		// packet holding only hidden frames leaves its timestamp unused. AV1
		// pictures come back from the GPU a few packets later, one per
		// temporal unit, so their timestamps stay queued.
		if r.video.codec != .AV1 do clear(&r.pending)
		return r.err
	}
	size := r.nal_length_size
	for pos := 0; pos < len(data); {
		if pos + size > len(data) do return .Invalid_Data
		n := 0
		for b in data[pos:][:size] do n = n << 8 | int(b)
		pos += size
		if n == 0 do continue
		if n > len(data) - pos do return .Invalid_Data
		if de := media.decode(&r.session, {data = data[pos:][:n], framing = .NAL}, receiver); de != .None {
			r.error_detail = r.session.error_detail
			return media_error(de)
		}
		if r.err != .None do return r.err
		pos += n
	}
	return r.err
}

// Number of samples presented before pts (its rank in the pts order).
@(private)
rank_of :: proc(ix: ^Sample_Index, pts: i64) -> int {
	order := ix.presentation
	lo, hi := 0, len(order)
	for lo < hi {
		mid := (lo + hi) / 2
		if ix.pts[order[mid]] < pts {lo = mid + 1} else {hi = mid}
	}
	return lo
}

// Decode-order index of the sample presented at pts (the greatest pts at or
// before it), or -1 before the first.
@(private)
sample_at :: proc(ix: ^Sample_Index, pts: i64) -> int {
	order := ix.presentation
	lo, hi := 0, len(order)
	for lo < hi {
		mid := (lo + hi) / 2
		if ix.pts[order[mid]] <= pts {lo = mid + 1} else {hi = mid}
	}
	return lo == 0 ? -1 : int(order[lo - 1])
}

// Decode-order index of the keyframe to start from to present pts: the last
// sync sample at or before it (intra-only ProRes: the sample itself).
@(private)
keyframe_at :: proc(ix: ^Sample_Index, pts: i64) -> int {
	if len(ix.pts) == 0 do return -1
	target := max(sample_at(ix, pts), 0)
	for i := target; i >= 0; i -= 1 do if ix.sync[i] && ix.pts[i] <= pts do return i
	for i in 0 ..< len(ix.pts) do if ix.sync[i] do return i
	return 0
}

@(private)
present :: proc(r: ^Reader) -> Frame {
	q := r.current
	planar := r.config.format == .Planar
	return {
		rgba = planar ? nil : q.data,
		planar = q.planar,
		width = q.width,
		height = q.height,
		stride = planar ? 0 : q.width * 4,
		pts = q.pts,
		time = f64(q.pts) / f64(r.video.timescale),
		index = rank_of(&r.index, q.pts) - r.first_rank,
	}
}

@(private)
take_queued :: proc(r: ^Reader) {
	if r.has_current do append(&r.free, r.current.data)
	r.current = r.queue[r.queue_head]
	r.has_current = true
	r.queue_head += 1
	if r.queue_head == len(r.queue) {
		clear(&r.queue)
		r.queue_head = 0
	}
}

// Returns the next frame in presentation order: first the frame shown at
// time zero, then each following frame until the presented end (frames an
// edit list hides are skipped). It continues from frame_at's frame.
next_frame :: proc(r: ^Reader) -> (frame: Frame, err: Error) {
	if r == nil do return {}, .Closed
	if r.video_index < 0 do return {}, .Unsupported // no decodable video track
	if r.video.frame_count == 0 do return {}, .End_Of_Stream
	if !r.session_open {
		target := r.index.pts[r.index.presentation[r.first_rank]]
		reset_video(r, keyframe_at(&r.index, target)) or_return
		r.want_from = target
	}
	for r.queue_head == len(r.queue) {
		if r.drained do return {}, .End_Of_Stream
		advance_video(r) or_return
	}
	if r.queue[r.queue_head].pts >= r.video_end do return {}, .End_Of_Stream
	take_queued(r)
	return present(r), .None
}

// Returns the frame shown at `seconds`: the last presented frame whose pts
// is at or before it, clamped to the first and last presented frames.
// Requests that move forward within the decoded GOP continue decoding;
// others restart at the keyframe (for intra-only ProRes, the frame itself).
frame_at :: proc(r: ^Reader, seconds: f64) -> (Frame, Error) {
	if r == nil do return {}, .Closed
	if r.video_index < 0 do return {}, .Unsupported // no decodable video track
	// Round to the nearest tick so a time computed from an exact frame
	// boundary does not land one tick early.
	ticks := clamp(seconds * f64(r.video.timescale), -9e18, 9e18)
	return frame_at_pts(r, i64(ticks + (ticks >= 0 ? 0.5 : -0.5)))
}

frame_at_pts :: proc(r: ^Reader, pts: i64) -> (frame: Frame, err: Error) {
	if r == nil do return {}, .Closed
	if r.video_index < 0 do return {}, .Unsupported // no decodable video track
	if r.video.frame_count == 0 do return {}, .End_Of_Stream
	ix := &r.index
	rank := r.first_rank
	if s := sample_at(ix, pts); s >= 0 do rank = clamp(rank_of(ix, ix.pts[s]), r.first_rank, r.last_rank)
	target := ix.pts[ix.presentation[rank]]
	if r.has_current && r.current.pts == target do return present(r), .None
	k := keyframe_at(ix, target)
	forward := r.session_open && !r.drained && r.err == .None && target > r.last_output && k <= r.next_feed
	queued := false
	for q in r.queue[r.queue_head:] do if q.pts == target do queued = true
	if !forward && !queued {
		reset_video(r, k) or_return
	}
	r.want_from = target
	for {
		for r.queue_head < len(r.queue) {
			if r.queue[r.queue_head].pts < target {
				append(&r.free, r.queue[r.queue_head].data)
				r.queue_head += 1
				continue
			}
			// The target itself, or the next frame when the decoder never
			// produced the target's picture.
			take_queued(r)
			return present(r), .None
		}
		clear(&r.queue)
		r.queue_head = 0
		if r.drained do return {}, .Invalid_Data
		advance_video(r) or_return
	}
}

// The presented times (Frame.time) at which decoding can restart, ascending:
// the first presented frame, then each presented keyframe after it (every
// frame for intra-only ProRes). frame_at one of these times decodes no
// earlier frame, and next_frame from it returns the frames up to the next
// time. The first frame is not a keyframe when an edit list starts mid-GOP;
// its frame_at decodes from the hidden keyframe before it. Borrowed: valid
// until close_reader.
keyframe_times :: proc(r: ^Reader) -> []f64 {
	if r == nil || r.video_index < 0 || r.video.frame_count == 0 do return nil
	if len(r.keyframes) == 0 {
		ix := &r.index
		scale := f64(r.video.timescale)
		for rank in r.first_rank ..= r.last_rank {
			i := ix.presentation[rank]
			if rank == r.first_rank || ix.sync[i] do append(&r.keyframes, f64(ix.pts[i]) / scale)
		}
	}
	return r.keyframes[:]
}

// Fills out with interleaved f32 PCM from the current audio position and
// returns the samples per channel written. Zero with End_Of_Stream means the
// presented audio is exhausted. PCM index zero is movie time zero: priming
// and padding are trimmed and a delayed track starts with silence.
read_audio :: proc(r: ^Reader, out: []f32) -> (samples: int, err: Error) {
	if r == nil do return 0, .Unsupported
	return audio.read(&r.audio, out)
}

// Moves the audio position to `seconds`; read_audio continues from there.
seek_audio :: proc(r: ^Reader, seconds: f64) -> Error {
	if r == nil do return .Unsupported
	return audio.seek(&r.audio, seconds)
}

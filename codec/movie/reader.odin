package movie

import alac "../alac"
import common "../common"
import mp4 "../container/mp4"
import flac "../flac"
import ogg "../container/ogg"
import opus "../opus"
import mp3 "../mp3"
import wav "../container/wav"
import webm "../container/webm"
import av1 "../av1"
import "core:io"
import "core:os"
import "core:slice"
import gpu "../gpu"
import h264 "../h264"
import avcd "../h264/decoder"
import hevcd "../h265/decoder"
import media "../media"
import native "../media/native"
import videotoolbox "../media/videotoolbox"
import vulkan "../media/vulkan"
import prores "../prores"

Reader_Config :: struct {
	preference:          media.Preference, // Automatic decodes with Vulkan Video when admitted
	native_options:      ^native.Options, // its pool also runs ProRes slices and VP9 tiles
	gpu_context:         ^gpu.Context,
	premultiplied_alpha: bool, // Frame.rgba premultiplied by alpha instead of straight
	format:              Frame_Format, // RGBA (default) or Planar
}

// MP4 includes QuickTime .mov; WebM includes Matroska; WAV includes RF64;
// FLAC and MP3 are native .flac and .mp3 files.
Container :: enum u8 {
	MP4,
	WebM,
	WAV,
	FLAC,
	MP3,
	Ogg, // Ogg Opus (.opus, .ogg)
}

Audio_Codec :: enum u8 {
	None,
	AAC,
	PCM, // uncompressed audio (QuickTime, Matroska, WAV)
	FLAC,
	MP3, // MPEG-1/2/2.5 Layer III
	Opus, // CELT packets; SILK and hybrid (speech) packets are not decoded yet
	ALAC, // Apple Lossless (.m4a, .mov, .mp4)
	Vorbis, // demuxed, not decoded
	Other,
}

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
}

Audio_Info :: struct {
	present:               bool, // AAC-LC or PCM that read_audio decodes
	codec:                 Audio_Codec, // the first audio track's codec, decodable or not
	sample_rate, channels: int,
	samples:               i64, // presented samples per channel
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
	container:      Container,
	demux:          mp4.Reader,
	webm:           webm.Reader,
	wave:           wav.Reader, // WAV
	flac_file:      flac.Reader, // native FLAC
	mp3_file:       mp3.Reader, // native MP3
	ogg_file:       ogg.Reader, // Ogg Opus
	audio_header:   []u8, // owned: Ogg Opus's OpusHead (audio_config points here)
	index:          Sample_Index, // the video track's samples, in Video_Info.timescale ticks
	color_from_frames: bool, // the container has no colour; use the bitstream's
	video_index:    int, // demuxer track, -1 when absent
	audio_index:    int,
	video:          Video_Info,
	audio:          Audio_Info,
	error_detail:   string,
	conversion:     Conversion_Cache,
	bit_depth:      int,
	parameter_sets: [dynamic][]u8, // views into the track's configuration record
	config_record:  []u8, // H.264 avcC or H.265 hvcC, borrowed from the demuxer
	nal_length_size: int, // bytes before each NAL unit in a sample
	audio_config:   []u8, // AAC AudioSpecificConfig or FLAC metadata, borrowed from the demuxer
	audio_done:     bool, // native FLAC: the last frame has been fed
	pcm_sample:     common.Sample_Format, // PCM: how each sample is stored
	// Matroska: the PCM index of each audio packet, from the frame sizes
	// (block timestamps are rounded to the timestamp scale), and the
	// decoded samples to discard at the start (CodecDelay).
	audio_starts:   []i64,
	audio_delay:    i64,
	// Video decode state.
	session:        media.Session,
	session_open:   bool,
	// A device the reader created once Vulkan won admission, so that seeks
	// reopen sessions on it instead of creating a device per restart.
	own_context:    ^gpu.Context,
	preference:     media.Preference, // fixed after the first open selects a backend
	video_end:      i64, // presented end of the video track, in its ticks
	// Presentation ranks (positions in the pts order) of the first and last
	// presented frames; frames an edit list hides fall outside them.
	first_rank:     int,
	last_rank:      int,
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
	// Audio decode state.
	audio_session:  media.Session,
	audio_open:     bool,
	audio_cursor:   int, // next AAC sample to feed
	audio_next:     i64, // index of the next PCM sample to queue
	audio_end:      i64,
	pcm:            [dynamic]f32,
	pcm_head:       int,
	pcm_input:      [dynamic]f32, // one PCM chunk converted to f32
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
		audio_index = -1,
		preference  = config.preference,
	}
	// EBML's magic number marks WebM/Matroska and RIFF-style WAVE marks WAV;
	// anything else is ISO BMFF.
	magic: [12]u8
	if stream.procedure != nil {
		io.read_at(stream, magic[:], 0)
	} else if f, err := os.open(path); err == nil {
		os.read(f, magic[:])
		os.close(f)
	}
	riff := string(magic[:4])
	if is_flac(&magic, path, stream) {
		r.container = .FLAC
		if e := stream.procedure != nil ? flac.open_stream(&r.flac_file, stream) : flac.open(&r.flac_file, path); e != .None {
			r.error_detail = "not a readable FLAC file"
			return flac_error(e)
		}
		r.audio_index = 0
	} else if string(magic[8:]) == "WAVE" && (riff == "RIFF" || riff == "RIFX" || riff == "RF64" || riff == "BW64") {
		r.container = .WAV
		if e := stream.procedure != nil ? wav.open_stream(&r.wave, stream) : wav.open(&r.wave, path); e != .None {
			r.error_detail = e == .Unsupported ? "ADPCM and other compressed WAV audio is not supported" : "not a readable WAV file"
			return wav_error(e)
		}
		r.audio_index = 0
	} else if is_mp3(&magic) {
		r.container = .MP3
		if e := stream.procedure != nil ? mp3.open_stream(&r.mp3_file, stream) : mp3.open(&r.mp3_file, path); e != .None {
			r.error_detail = e == .Unsupported ? "MP3 Layer I/II or free-format streams are not supported" : "not a readable MP3 file"
			return mp3_error(e)
		}
		r.audio_index = 0
	} else if riff == "OggS" {
		r.container = .Ogg
		if e := stream.procedure != nil ? ogg.open_stream(&r.ogg_file, stream, "OpusHead") : ogg.open(&r.ogg_file, path, "OpusHead"); e != .None {
			r.error_detail = "not a readable Ogg Opus file"
			return ogg_error(e)
		}
		r.audio_index = 0
	} else if riff == "\x1A\x45\xDF\xA3" {
		r.container = .WebM
		if e := stream.procedure != nil ? webm.open_stream(&r.webm, stream) : webm.open(&r.webm, path); e != .None {
			r.error_detail = e == .Unsupported ? "unsupported Matroska document" : "not a readable WebM file"
			return webm_error(e)
		}
		for &t, i in r.webm.tracks {
			video := t.codec == .VP9 || t.codec == .H264 || t.codec == .H265 || t.codec == .AV1
			if t.kind == .Video && r.video_index < 0 && video && len(t.samples) > 0 do r.video_index = i
			if t.kind == .Audio && r.audio_index < 0 && len(t.samples) > 0 do r.audio_index = i
		}
	} else {
		if e := stream.procedure != nil ? mp4.open_stream(&r.demux, stream) : mp4.open(&r.demux, path); e != .None {
			r.error_detail = e == .Unsupported ? "fragmented or multi-description MP4 is not supported" : "not a readable MP4 file"
			return mp4_error(e)
		}
		for &t, i in r.demux.tracks {
			video := t.codec == .H264 || t.codec == .H265 || t.codec == .ProRes || t.codec == .AV1
			if t.kind == .Video && r.video_index < 0 && video && len(t.samples) > 0 do r.video_index = i
			if t.kind == .Audio && r.audio_index < 0 && len(t.samples) > 0 do r.audio_index = i
		}
	}
	if r.video_index >= 0 do if e := describe_video(r); e != .None {close_reader(r); return e}
	if r.audio_index >= 0 do describe_audio(r)
	return .None
}

// "fLaC", possibly after an ID3v2 tag (which MP3 files also start with).
@(private)
is_flac :: proc(magic: ^[12]u8, path: string, stream: io.Stream) -> bool {
	if string(magic[:4]) == "fLaC" do return true
	if string(magic[:3]) != "ID3" do return false
	at := i64(magic[6]) << 21 | i64(magic[7]) << 14 | i64(magic[8]) << 7 | i64(magic[9])
	at += 10 + (magic[5] & 0x10 != 0 ? 10 : 0)
	marker: [4]u8
	if stream.procedure != nil {
		io.read_at(stream, marker[:], at)
	} else if f, err := os.open(path); err == nil {
		os.read_at(f, marker[:], at)
		os.close(f)
	}
	return string(marker[:]) == "fLaC"
}

// An ID3v2 tag (FLAC's was ruled out first) or an MPEG audio frame sync.
@(private)
is_mp3 :: proc(magic: ^[12]u8) -> bool {
	if string(magic[:3]) == "ID3" do return true
	_, e := mp3.parse_header(magic[:4])
	return e == .None
}

@(private)
ogg_error :: proc(e: ogg.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Invalid_Argument:
		return .Invalid_Input
	case .Invalid_Data:
		return .Invalid_Data
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
mp3_error :: proc(e: mp3.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Invalid_Argument:
		return .Invalid_Input
	case .Invalid_Data:
		return .Invalid_Data
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
flac_error :: proc(e: flac.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Invalid_Argument:
		return .Invalid_Input
	case .Invalid_Data:
		return .Invalid_Data
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
wav_error :: proc(e: wav.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Invalid_Argument:
		return .Invalid_Input
	case .Invalid_Data:
		return .Invalid_Data
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
webm_error :: proc(e: webm.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Invalid_Argument:
		return .Invalid_Input
	case .Invalid_Data:
		return .Invalid_Data
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
	if r.container == .WebM do return describe_webm_video(r)
	t := &r.demux.tracks[r.video_index]
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
	p, e := mp4.read_sample(&r.demux, r.video_index, 0)
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
	t := &r.webm.tracks[r.video_index]
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

// The VUI colour description and bit depth of the first SPS, through the
// native decoders' own SPS parsers.
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
			if sps.colour_primaries == 2 && sps.matrix_coeffs == 2 && !sps.full_range do return
			return {u8(sps.colour_primaries), u8(sps.transfer_char), u8(sps.matrix_coeffs), sps.full_range}
		}
	}
	return
}

@(private)
describe_audio :: proc(r: ^Reader) {
	if r.container == .WebM {
		describe_webm_audio(r)
		return
	}
	if r.container == .Ogg {
		describe_ogg_audio(r)
		return
	}
	if r.container == .MP3 {
		h := r.mp3_file.header
		r.audio = {
			present     = true,
			codec       = .MP3,
			sample_rate = h.sample_rate,
			channels    = h.channels,
			samples     = mp3.total_samples(&r.mp3_file),
		}
		r.audio_end = r.audio.samples
		return
	}
	if r.container == .FLAC {
		info := r.flac_file.info
		total, e := flac.total_samples(&r.flac_file)
		r.audio = {
			present     = e == .None && info.channels <= 8 && info.sample_rate > 0,
			codec       = .FLAC,
			sample_rate = info.sample_rate,
			channels    = info.channels,
			samples     = total,
		}
		r.audio_end = total
		r.audio_config = r.flac_file.stream_info[:]
		return
	}
	if r.container == .WAV {
		f := r.wave.format
		r.audio = {
			present     = true,
			codec       = .PCM,
			sample_rate = f.sample_rate,
			channels    = f.channels,
			samples     = r.wave.frames,
		}
		r.audio_end = r.wave.frames
		r.pcm_sample = f.sample
		return
	}
	t := &r.demux.tracks[r.audio_index]
	r.audio.sample_rate, r.audio.channels = t.sample_rate, t.channels
	r.audio.samples = mp4.track_end(t) * i64(t.sample_rate) / i64(t.timescale)
	r.audio_end = r.audio.samples
	r.audio_config = t.audio_specific_config
	#partial switch t.codec {
	case .PCM:
		r.audio.codec = .PCM
		ok: bool
		r.pcm_sample, ok = common.sample_format(int(t.pcm.bits), t.pcm.float, t.pcm.unsigned, !t.pcm.little_endian)
		r.audio.present = ok && t.channels >= 1
	case .AAC:
		r.audio.codec = .AAC
		info, ok := mp4.parse_asc(t.audio_specific_config)
		r.audio.present = ok && info.object_type == 2 && t.channels >= 1 && t.channels <= 8
	case .FLAC:
		r.audio.codec = .FLAC
		r.audio.present = flac_config_ok(t.audio_specific_config, t.sample_rate, t.channels)
	case .MP3:
		r.audio.codec = .MP3
		r.audio.present = t.sample_rate > 0 && t.channels >= 1 && t.channels <= 2
	case .ALAC:
		r.audio.codec = .ALAC
		cfg, e := alac.parse_config(t.audio_specific_config)
		r.audio.present = e == .None && cfg.sample_rate == t.sample_rate && cfg.channels == t.channels
	case .Opus:
		r.audio.codec = .Opus
		h, e := opus.parse_head(t.audio_specific_config)
		r.audio.present = e == .None && h.channels == t.channels && t.sample_rate == 48000
	case:
		r.audio.codec = .Other
	}
}

// Ogg Opus (RFC 7845): OpusHead and OpusTags, then audio packets. Packet
// positions run on from the first page's granule position by each
// packet's duration; the last granule position trims the end.
@(private)
OGG_HEADERS :: 2

@(private)
describe_ogg_audio :: proc(r: ^Reader) {
	f := &r.ogg_file
	head, e := ogg.read_packet(f, 0)
	if e != .None || len(f.packets) <= OGG_HEADERS do return
	r.audio_header = slice.clone(head)
	h, he := opus.parse_head(r.audio_header)
	r.audio = {
		present     = he == .None,
		codec       = .Opus,
		sample_rate = 48000,
		channels    = h.channels,
	}
	r.audio_config = r.audio_header
	r.audio_delay = i64(h.pre_skip)
	n := len(f.packets) - OGG_HEADERS
	r.audio_starts = make([]i64, n)
	position, offset: i64
	anchored := false
	last_granule: i64 = -1
	for i in 0 ..< n {
		p := f.packets[OGG_HEADERS + i]
		lead := p.lead
		samples, _ := opus.packet_samples(lead[:])
		r.audio_starts[i] = position
		position += i64(samples)
		if p.granule >= 0 {
			if !anchored {
				offset = max(p.granule - position, 0)
				anchored = true
			}
			last_granule = p.granule
		}
	}
	for &start in r.audio_starts do start += offset
	end := position + offset
	if last_granule >= 0 do end = min(end, last_granule)
	r.audio.samples = max(end - r.audio_delay, 0)
	r.audio_end = r.audio.samples
}

@(private)
flac_config_ok :: proc(metadata: []u8, rate, channels: int) -> bool {
	info, _, e := flac.parse_metadata(metadata)
	return e == .None && info.sample_rate == rate && info.channels == channels && channels <= 8 && rate > 0
}

// Matroska audio. Block timestamps are rounded to the timestamp scale
// (usually 1 ms), too coarse to place PCM, so packet positions come from
// frame sizes: AAC's fixed frame length, or a PCM block's byte count. A
// timestamp further than a packet from that running position (a gap in the
// recording) restarts it there.
@(private)
describe_webm_audio :: proc(r: ^Reader) {
	t := &r.webm.tracks[r.audio_index]
	rate := t.sample_rate
	r.audio.sample_rate, r.audio.channels = rate, t.channels
	frame_samples := 0
	#partial switch t.codec {
	case .Opus:
		r.audio.codec = .Opus
		h, he := opus.parse_head(t.codec_private)
		if he == .None && h.channels == t.channels {
			r.audio.present = true
			r.audio_config = t.codec_private
			rate = 48000 // Opus always decodes at 48 kHz
			r.audio.sample_rate = rate
			// Packets are as long as the first one says, block timestamps
			// correcting any change.
			if len(t.samples) > 0 {
				if p, pe := webm.read_sample(&r.webm, r.audio_index, 0); pe == .None do frame_samples, _ = opus.packet_samples(p.data)
			}
			if t.codec_delay == 0 do t.codec_delay = i64(h.pre_skip) * 1_000_000_000 / 48000
		}
	case .Vorbis:
		r.audio.codec = .Vorbis
	case .AAC:
		r.audio.codec = .AAC
		info, ok := mp4.parse_asc(t.codec_private)
		if ok && info.object_type == 2 && t.channels >= 1 && t.channels <= 8 && info.sample_rate == rate {
			r.audio.present = true
			r.audio_config = t.codec_private
			frame_samples = info.frame_samples
		}
	case .MP3:
		r.audio.codec = .MP3
		r.audio.present = t.channels >= 1 && t.channels <= 2
		frame_samples = rate >= 32000 ? 1152 : 576 // MPEG-1 rates, else MPEG-2/2.5
	case .FLAC:
		r.audio.codec = .FLAC
		if flac_config_ok(t.codec_private, rate, t.channels) {
			r.audio.present = true
			r.audio_config = t.codec_private
			// Fixed-blocking streams place every frame exactly; otherwise the
			// block timestamps do.
			info, _, _ := flac.parse_metadata(t.codec_private)
			if info.min_block == info.max_block do frame_samples = info.max_block
		}
	case .PCM:
		r.audio.codec = .PCM
		f := t.pcm_format
		ok: bool
		r.pcm_sample, ok = common.sample_format(int(f.bits), f.float, f.unsigned, !f.little_endian)
		r.audio.present = ok && t.channels >= 1 && rate > 0
	case:
		r.audio.codec = .Other
	}
	if rate <= 0 {r.audio.present = false; return}
	r.audio.samples = webm.track_end(t) * i64(rate) / 1_000_000_000
	if !r.audio.present do return
	n := len(t.samples)
	r.audio_starts = make([]i64, n)
	frame_bytes := i64(common.SAMPLE_BYTES[r.pcm_sample]) * i64(t.channels)
	position: i64
	for i in 0 ..< n {
		s := t.samples[i]
		stated := (s.pts * i64(rate) + 500_000_000) / 1_000_000_000
		length := i64(frame_samples)
		if t.codec == .PCM do length = (i64(s.size) + i64(len(t.stripped))) / frame_bytes
		if i == 0 || length == 0 || abs(stated - position) > max(length, i64(rate) / 100) do position = stated
		r.audio_starts[i] = position
		position += length
	}
	// Nanoseconds are not exact sample counts (1024 at 48 kHz is 21333333 ns).
	r.audio_delay = (t.codec_delay * i64(rate) + 500_000_000) / 1_000_000_000
	r.audio.samples = max(position - r.audio_delay - (t.end_discard * i64(rate) + 500_000_000) / 1_000_000_000, 0)
	// FLAC's last frame is shorter than the rest; streaminfo has the count.
	if t.codec == .FLAC {
		if info, _, _ := flac.parse_metadata(t.codec_private); info.total_samples > 0 do r.audio.samples = min(r.audio.samples, info.total_samples)
	}
	r.audio_end = r.audio.samples
}

close_reader :: proc(r: ^Reader) {
	if r == nil do return
	if r.session_open do media.close(&r.session)
	if r.audio_open do media.close(&r.audio_session)
	if r.own_context != nil {
		gpu.destroy_context(r.own_context)
		free(r.own_context)
	}
	mp4.close(&r.demux)
	webm.close(&r.webm)
	wav.close(&r.wave)
	flac.close(&r.flac_file)
	mp3.close(&r.mp3_file)
	ogg.close(&r.ogg_file)
	delete(r.audio_header)
	for q in r.queue[r.queue_head:] do delete(q.data)
	if r.has_current do delete(r.current.data)
	for b in r.free do delete(b)
	delete(r.free)
	delete(r.queue)
	delete(r.pending)
	delete(r.parameter_sets)
	delete(r.audio_starts)
	free(r.conversion.tone)
	delete(r.pcm)
	delete(r.pcm_input)
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

// Restarts video decoding at decode-order sample k (a keyframe).
@(private)
reset_video :: proc(r: ^Reader, k: int) -> Error {
	if r.session_open {media.close(&r.session); r.session_open = false}
	codec := VIDEO_CODECS[r.video.codec]
	config := media.default_config(codec, .Decode)
	config.preference = r.preference
	// The hardware decoders decode only an HEVC stream's base layer.
	if codec == .H265 && r.video.has_alpha do config.preference = .Native
	config.width, config.height = r.video.width, r.video.height
	config.bit_depth = r.bit_depth
	if codec == .AV1 do config.chroma = r.video.chroma // the provider admits 4:2:0 only
	if codec == .H264 || codec == .H265 {
		// Matroska does not say whether frames are reordered.
		config.no_reordering = r.container == .MP4 && codec == .H264 && r.demux.tracks[r.video_index].no_reordering
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
	shared := r.config.gpu_context != nil ? r.config.gpu_context : r.own_context
	// VideoToolbox reports itself unavailable off Apple platforms, Vulkan Video on them.
	providers := [3]media.Provider{native.provider(r.config.native_options), videotoolbox.provider(), vulkan.provider(shared)}
	if e := media.open(&r.session, config, providers[:]); e != .None {
		r.error_detail = codec == .AV1 ? "AV1 needs a GPU with Vulkan Video AV1 decoding (Main, 4:2:0, 8 or 10 bits)" : "no decoder admits this video track"
		return media_error(e)
	}
	r.session_open = true
	if r.session.backend == .Vulkan && shared == nil {
		// First hardware admission with a provider-owned device: move to a
		// reader-owned Context. If that fails the provider device still works.
		c := new(gpu.Context)
		request := gpu.Request {
			codec       = codec == .H264 ? .H264 : (codec == .AV1 ? .AV1 : .H265),
			operation   = .Decode,
			width       = config.width,
			height      = config.height,
			bit_depth   = config.bit_depth,
			profile_idc = config.profile_idc,
		}
		if gpu.init_context(c, {requests = {request}, device_index = -1}) == .None {
			media.close(&r.session)
			config.preference = .Require_Hardware
			providers[2] = vulkan.provider(c)
			if media.open(&r.session, config, providers[:]) != .None {
				r.session_open = false
				gpu.destroy_context(c)
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
	if r.container == .WebM {
		p, e := webm.read_sample(&r.webm, r.video_index, i)
		if e != .None do return nil, nil, webm_error(e)
		return p.data, p.additional, .None
	}
	p, e := mp4.read_sample(&r.demux, r.video_index, i)
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

// Fills out with interleaved f32 PCM from the current audio position and
// returns the samples per channel written. Zero with End_Of_Stream means the
// presented audio is exhausted. PCM index zero is movie time zero: priming
// and padding are trimmed and a delayed track starts with silence.
read_audio :: proc(r: ^Reader, out: []f32) -> (samples: int, err: Error) {
	if r == nil || !r.audio.present do return 0, .Unsupported
	ch := r.audio.channels
	want := len(out) / ch
	got := 0
	for got < want {
		available := (len(r.pcm) - r.pcm_head) / ch
		if available > 0 {
			n := min(available, want - got)
			copy(out[got * ch:][:n * ch], r.pcm[r.pcm_head:][:n * ch])
			r.pcm_head += n * ch
			got += n
			continue
		}
		clear(&r.pcm)
		r.pcm_head = 0
		if r.audio_next >= r.audio_end || r.audio_open && audio_exhausted(r) do break
		if !r.audio_open {
			if e := reset_audio(r, r.audio_next); e != .None do return got, e
		}
		// Samples already copied are reported along with a later failure.
		if e := advance_audio(r); e != .None do return got, e
	}
	return got, got == 0 ? .End_Of_Stream : .None
}

// Moves the audio position to `seconds`; read_audio continues from there.
seek_audio :: proc(r: ^Reader, seconds: f64) -> Error {
	if r == nil || !r.audio.present do return .Unsupported
	target := i64(seconds * f64(r.audio.sample_rate) + 0.5)
	return reset_audio(r, clamp(target, 0, r.audio_end))
}

@(private, rodata)
AUDIO_CODECS := #partial [Audio_Codec]media.Codec {
	.AAC  = .AAC,
	.FLAC = .FLAC,
	.MP3  = .MP3,
	.Opus = .Opus,
	.ALAC = .ALAC,
}

@(private)
reset_audio :: proc(r: ^Reader, position: i64) -> Error {
	if r.audio_open {media.close(&r.audio_session); r.audio_open = false}
	coded := r.audio.codec == .AAC || r.audio.codec == .FLAC || r.audio.codec == .MP3 || r.audio.codec == .Opus || r.audio.codec == .ALAC
	if coded {
		config := media.default_config(AUDIO_CODECS[r.audio.codec], .Decode)
		config.sample_rate, config.channels = r.audio.sample_rate, r.audio.channels
		config.extradata = r.audio_config
		providers := [1]media.Provider{native.provider()}
		if e := media.open(&r.audio_session, config, providers[:]); e != .None {
			r.error_detail = "the audio decoder refused the track configuration"
			return media_error(e)
		}
	}
	r.audio_open = true
	r.audio_next = position
	clear(&r.pcm)
	r.pcm_head = 0
	if r.container == .FLAC {
		r.audio_done = false
		if e := flac.seek(&r.flac_file, position); e != .None do return flac_error(e)
		return .None
	}
	// One packet of pre-roll restores the AAC overlap of the target's frame,
	// and covers a FLAC frame placed by a rounded timestamp; MP3 needs the
	// bit reservoir (up to 511 bytes back, 11 of the smallest frames) and
	// the frame before; ALAC frames and PCM chunks start exactly.
	k := audio_packet_at(r, position)
	preroll := r.audio.codec == .AAC || r.audio.codec == .FLAC ? 1 : 0
	if r.audio.codec == .MP3 do preroll = MP3_PREROLL
	if r.audio.codec == .Opus {
		// 80 ms for the decoder to converge (RFC 7845 4.6).
		k = audio_packet_at(r, position - OPUS_PREROLL)
		preroll = 0
	}
	r.audio_cursor = max(k - preroll, 0)
	return .None
}

@(private)
MP3_PREROLL :: 13

@(private)
OPUS_PREROLL :: 3840 // samples at 48 kHz

// WAV has no packets: its data is read in runs of this many frames.
@(private)
WAV_PACKET :: 4096

@(private)
audio_exhausted :: proc(r: ^Reader) -> bool {
	return r.container == .FLAC ? r.audio_done : r.audio_cursor >= audio_packet_count(r)
}

@(private)
audio_packet_count :: proc(r: ^Reader) -> int {
	switch r.container {
	case .MP3:
		return len(r.mp3_file.frames)
	case .FLAC:
		return 0 // read frame by frame; see audio_exhausted
	case .WAV:
		return int((r.wave.frames + WAV_PACKET - 1) / WAV_PACKET)
	case .WebM:
		return len(r.webm.tracks[r.audio_index].samples)
	case .Ogg:
		return max(len(r.ogg_file.packets) - OGG_HEADERS, 0)
	case .MP4:
	}
	return len(r.demux.tracks[r.audio_index].samples)
}

// Decode-order index of the audio packet holding PCM index `position`, or
// -1 before the first.
@(private)
audio_packet_at :: proc(r: ^Reader, position: i64) -> int {
	if r.container == .WAV do return position < 0 ? -1 : int(position / WAV_PACKET)
	if r.container == .MP3 {
		at := position + i64(r.mp3_file.tag.delay)
		return at < 0 ? -1 : int(at / i64(r.mp3_file.header.samples))
	}
	if r.container == .WebM || r.container == .Ogg {
		starts := r.audio_starts
		lo, hi := 0, len(starts)
		for lo < hi {
			mid := (lo + hi) / 2
			if starts[mid] - r.audio_delay <= position {lo = mid + 1} else {hi = mid}
		}
		return lo - 1
	}
	t := &r.demux.tracks[r.audio_index]
	ix := Sample_Index{t.samples.pts[:len(t.samples)], t.samples.sync[:len(t.samples)], t.presentation}
	return sample_at(&ix, position * i64(t.timescale) / i64(r.audio.sample_rate))
}

// One audio packet and the PCM index of its first decoded sample.
@(private)
read_audio_packet :: proc(r: ^Reader, i: int) -> (data: []u8, sample_index: i64, err: Error) {
	if r.container == .MP3 {
		bytes, e := mp3.read_frame(&r.mp3_file, i)
		if e != .None do return nil, 0, mp3_error(e)
		return bytes, mp3.frame_sample(&r.mp3_file, i), .None
	}
	if r.container == .WAV {
		first := i64(i) * WAV_PACKET
		bytes, e := wav.read_frames(&r.wave, first, WAV_PACKET)
		if e != .None do return nil, 0, wav_error(e)
		return bytes, first, .None
	}
	if r.container == .Ogg {
		bytes, e := ogg.read_packet(&r.ogg_file, OGG_HEADERS + i)
		if e != .None do return nil, 0, ogg_error(e)
		return bytes, r.audio_starts[i] - r.audio_delay, .None
	}
	if r.container == .WebM {
		p, e := webm.read_sample(&r.webm, r.audio_index, i)
		if e != .None do return nil, 0, webm_error(e)
		return p.data, r.audio_starts[i] - r.audio_delay, .None
	}
	t := &r.demux.tracks[r.audio_index]
	p, e := mp4.read_sample(&r.demux, r.audio_index, i)
	if e != .None do return nil, 0, mp4_error(e)
	return p.data, p.pts * i64(r.audio.sample_rate) / i64(t.timescale), .None
}

@(private)
on_audio :: proc(f: media.Audio_Frame, user: rawptr) {
	r := (^Reader)(user)
	ch := f.channels
	// Time before the track's first sample (an empty edit) reads as silence,
	// so PCM index zero is always movie time zero.
	gap := min(f.sample_index, r.audio_end) - r.audio_next
	if gap > 0 {
		resize(&r.pcm, len(r.pcm) + int(gap) * ch)
		r.audio_next += gap
	}
	lo := max(f.sample_index, r.audio_next)
	hi := min(f.sample_index + i64(f.samples_per_channel), r.audio_end)
	if hi <= lo do return
	start := int(lo - f.sample_index) * ch
	append(&r.pcm, ..f.samples[start:][:int(hi - lo) * ch])
	r.audio_next = hi
}

@(private)
advance_audio :: proc(r: ^Reader) -> Error {
	if audio_exhausted(r) do return .None
	data: []u8
	sample_index: i64
	if r.container == .FLAC {
		p, e := flac.read_frame(&r.flac_file)
		if e == .End_Of_Stream {r.audio_done = true; return .None}
		if e != .None do return flac_error(e)
		data, sample_index = p.data, p.first_sample
	} else {
		data, sample_index = read_audio_packet(r, r.audio_cursor) or_return
		r.audio_cursor += 1
	}
	if r.audio.codec == .PCM {
		ch := r.audio.channels
		resize(&r.pcm_input, len(data) / common.SAMPLE_BYTES[r.pcm_sample])
		frames := common.convert_pcm(data, r.pcm_sample, ch, r.pcm_input[:], ch)
		on_audio({samples = r.pcm_input[:frames * ch], sample_rate = r.audio.sample_rate, channels = r.audio.channels, samples_per_channel = frames, sample_index = sample_index}, r)
		return .None
	}
	packet := media.Packet {
		data         = data,
		framing      = r.audio.codec == .AAC ? .Raw_AAC : .Frame,
		sample_index = sample_index,
		sample_rate  = r.audio.sample_rate,
	}
	if de := media.decode(&r.audio_session, packet, {audio = on_audio, user = r}); de != .None {
		r.error_detail = r.audio_session.error_detail
		return media_error(de)
	}
	return .None
}


package video

import aac "../audio/aac"
import audio "../audio"
import "../common"
import "core:io"
import mp4 "../container/mp4"
import hevce "./h265/encoder"
import media "../media"
import avcodec "../media/avcodec"
import native "../media/native"
import videotoolbox "../media/videotoolbox"
import vulkan "../media/vulkan"
import webm "../container/webm"

Chapter :: common.Chapter

Video_Codec :: enum u8 {
	H264,
	H265,
	ProRes, // reading only
	VP9,    // written to WebM (native encoder, no audio); alpha needs transparency Straight
	AV1,    // reading only, with Vulkan Video AV1 decoding
}

// The audio package's errors, shared by reading and writing.
Error :: audio.Error

BT709_LIMITED :: media.Color{1, 1, 1, false}

Writer_Config :: struct {
	width, height:         int, // even, 16..8192
	fps_num, fps_den:      int, // exact rational rate, for example 30/1 or 30000/1001
	codec:                 Video_Codec,
	qp:                    int, // 1..51 constant quantizer, lower is better; 0 selects 23
	gop:                   int, // frames from one keyframe to the next; 0 selects about one second
	preference:            media.Preference, // Automatic: Vulkan Video when admitted, else native
	alpha:                 Alpha, // how the RGBA input's colour relates to its alpha
	background:            [3]u8, // shows through transparent pixels when transparency is None
	// Keep alpha in the video (H.265 only, native encoder): an auxiliary
	// alpha layer that Safari, QuickTime and VideoToolbox play as
	// transparent video. The value is how colour is stored beside it.
	transparency:          Transparency,
	faststart:             bool, // moov before mdat, for progressive playback
	// Audio: interleaved f32 PCM at a standard AAC rate; zero sample_rate
	// writes no audio track.
	sample_rate, channels: int,
	audio_bit_rate:        int, // 0 selects 64 kb/s per channel
	ultrafast:             bool, // prefer encode speed over size (media.Config.ultrafast)
	native_options:        ^native.Options, // optional worker pool and slice/tile geometry
	gpu_context:           ^vulkan.Context, // optional shared Vulkan device
	chapters:              []Chapter,
}

default_writer_config :: proc(width, height, fps_num, fps_den: int) -> Writer_Config {
	return {width = width, height = height, fps_num = fps_num, fps_den = fps_den, qp = 23, faststart = true}
}

default_audio_writer_config :: proc(sample_rate, channels: int) -> Writer_Config {
	return {sample_rate = sample_rate, channels = channels, faststart = true}
}

// RGBA frames and PCM in, an MP4 or M4A file out. Video is BT.709 limited-range
// 4:2:0 with the colour description in both the bitstream and `colr`.
Writer :: struct {
	config:         Writer_Config,
	mux:            mp4.Writer,
	webm:           webm.Writer, // VP9 output
	video, audio:   media.Session,
	has_video:      bool,
	has_audio:      bool,
	video_track:    int,
	audio_track:    int,
	timescale:      u32,
	frame_duration: i64,
	frames:         i64, // frames submitted
	samples:        i64, // video samples started in the file
	picture:        bool, // the open video sample already holds a picture
	planes:         [3][]u8,
	alpha_plane:    []u8, // with transparency: full-range alpha, luma-sized
	alpha_scratch:  Alpha_Scratch,
	coefficients:   Rgb_To_Yuv,
	pcm:            []f32, // one AAC frame of pending input
	pcm_fill:       int, // samples per channel in pcm
	aac_order:      [8]u8, // AAC channel j takes WAVE-order input channel aac_order[j]
	reorder:        bool,
	pcm_total:      i64, // input samples per channel
	queue:          [dynamic]u8, // encoded audio waiting to interleave
	queued:         [dynamic]Queued_Audio,
	queue_head:     int,
	err:            Error,
	error_detail:   string, // static diagnostic for the last failure
	open:           bool,
}

@(private)
Queued_Audio :: struct {
	offset, size: int,
	pts:          i64,
}

// Interleave window: audio is written in runs reaching this far past the
// video sample that triggers them.
@(private)
INTERLEAVE_SECONDS :: 0.5

@(private)
media_error :: proc(e: media.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Invalid_Config:
		return .Invalid_Config
	case .Invalid_Input:
		return .Invalid_Input
	case .Unsupported, .Unavailable:
		return .Unsupported
	case .Driver_Error, .Codec_Error, .Failed:
		return .Codec_Error
	case .Closed, .Wrong_Operation, .Busy, .Ended:
		return .Closed
	}
	return .Codec_Error
}

@(private)
mp4_error :: proc(e: mp4.Error) -> Error {
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

// Creates the file and opens the encoders. On failure nothing stays open.
create :: proc(w: ^Writer, path: string, config: Writer_Config) -> Error {
	return create_output(w, config, path, {})
}

// Writes to a stream with Write_At (and Read_At for faststart), such as an
// mp4.Memory_Stream for in-memory segments. The writer borrows it.
create_stream :: proc(w: ^Writer, stream: io.Stream, config: Writer_Config) -> Error {
	if stream.procedure == nil do return .Invalid_Config
	return create_output(w, config, "", stream)
}

@(private)
create_output :: proc(w: ^Writer, config: Writer_Config, path: string, stream: io.Stream) -> Error {
	if w == nil do return .Invalid_Config
	w^ = {
		config      = config,
		video_track = -1,
		audio_track = -1,
	}
	c := &w.config
	w.has_video = c.width != 0 || c.height != 0
	w.has_audio = c.sample_rate != 0
	if !w.has_video && !w.has_audio do return .Invalid_Config
	providers := [4]media.Provider{native.provider(c.native_options), videotoolbox.provider(), vulkan.provider(c.gpu_context), avcodec.provider()}
	if w.has_video {
		if c.qp == 0 do c.qp = 23
		if c.width < 16 || c.height < 16 || c.width > 8192 || c.height > 8192 || (c.width | c.height) & 1 != 0 do return .Invalid_Config
		if c.codec != .H264 && c.codec != .H265 && c.codec != .VP9 do return .Unsupported // ProRes and AV1 are decoded, not written
		if c.fps_num <= 0 || c.fps_den <= 0 || c.fps_num > 1 << 20 || c.fps_den > 1 << 20 || c.qp < 1 || c.qp > 51 || c.gop < 0 do return .Invalid_Config
		if c.transparency != .None {
			if c.codec == .H264 do return .Unsupported
			if c.codec == .VP9 && c.transparency != .Straight do return .Invalid_Config // VP9 alpha is straight
			if c.alpha == .Opaque do return .Invalid_Config
		}
		if c.gop == 0 do c.gop = max(1, (c.fps_num + c.fps_den / 2) / c.fps_den)
		if w.has_audio && c.codec == .VP9 do return .Unsupported // WebM audio would need an Opus encoder
		// Video ticks: the frame rate's numerator doubled up to at least 10 kHz,
		// so every frame lasts an exact integer number of ticks.
		timescale := c.fps_num
		for timescale < 10000 do timescale *= 2
		w.timescale = u32(timescale)
		w.frame_duration = i64(c.fps_den * (timescale / c.fps_num))

		video := media.default_config(c.codec == .H264 ? .H264 : (c.codec == .H265 ? .H265 : .VP9), .Encode)
		video.preference = c.preference
		video.width, video.height = c.width, c.height
		video.qp = i32(c.qp)
		video.gop_size = c.gop
		video.color = BT709_LIMITED
		video.frame_rate_num, video.frame_rate_den = c.fps_num, c.fps_den
		video.alpha = c.transparency != .None
		video.alpha_premultiplied = c.transparency == .Premultiplied
		video.ultrafast = c.ultrafast
		if e := media.open(&w.video, video, providers[:]); e != .None {
			w.error_detail = "video encoder unavailable for this configuration"
			when !native.ODECS_NATIVE_H264 do if c.codec == .H264 do w.error_detail = "no VideoToolbox, Vulkan Video or libavcodec H.264 encoder admits this configuration, and native H.264 is not built in (-define:ODECS_PATENTED=true)"
			when !native.ODECS_NATIVE_H265 do if c.codec == .H265 do w.error_detail = "no VideoToolbox, Vulkan Video or libavcodec H.265 encoder admits this configuration, and native H.265 is not built in (-define:ODECS_PATENTED=true)"
			return media_error(e)
		}
		if c.codec == .VP9 do return create_webm(w, path, stream)
	} else {
		if c.transparency != .None || c.codec == .VP9 do return .Invalid_Config
	}
	if w.has_audio {
		if aac.sample_rate_index(c.sample_rate) < 0 {
			media.close(&w.video)
			return .Unsupported
		}
		if c.channels < 1 || c.channels > 8 || c.audio_bit_rate < 0 {
			media.close(&w.video)
			return .Invalid_Config
		}
	}
	tracks: [2]mp4.Track_Config
	track_count := 0
	hevc_sei: []u8
	defer delete(hevc_sei)
	if w.has_video {
		// hvcC declares the alpha channel information beside the parameter
		// sets, as Apple's files do; the encoder repeats it at each keyframe.
		if c.transparency != .None do hevc_sei = hevce.alpha_info_sei_nal(c.transparency == .Premultiplied, 8)
		w.video_track = track_count
		tracks[track_count] = {
			codec            = c.codec == .H264 ? .H264 : .H265,
			timescale        = w.timescale,
			width            = c.width,
			height           = c.height,
			color            = {1, 1, 1, false},
			hevc_sei         = hevc_sei,
			default_duration = u32(w.frame_duration),
		}
		track_count += 1
	}
	asc: [dynamic]u8
	defer delete(asc)
	if w.has_audio {
		audio := media.default_config(.AAC, .Encode)
		audio.sample_rate, audio.channels, audio.bit_rate = c.sample_rate, c.channels, c.audio_bit_rate
		audio.audio_transport = .Raw
		if e := media.open(&w.audio, audio, providers[:]); e != .None {
			media.close(&w.video)
			w.error_detail = "AAC encoder refused the audio configuration"
			return media_error(e)
		}
		if aac.append_audio_specific_config(&asc, {sample_rate = c.sample_rate, channels = c.channels}) != .None {
			media.close(&w.video)
			media.close(&w.audio)
			return .Unsupported
		}
		w.audio_track = track_count
		tracks[track_count] = {
			codec                 = .AAC,
			timescale             = u32(c.sample_rate),
			sample_rate           = c.sample_rate,
			channels              = c.channels,
			audio_specific_config = asc[:],
			default_duration      = 1024,
		}
		track_count += 1
	}
	options := mp4.Options {
		faststart = c.faststart,
		chapters  = c.chapters,
	}
	e := stream.procedure != nil ? mp4.create_stream(&w.mux, stream, tracks[:track_count], options) : mp4.create(&w.mux, path, tracks[:track_count], options)
	if e != .None {
		media.close(&w.video)
		media.close(&w.audio)
		w.error_detail = "could not create the output file"
		return mp4_error(e)
	}
	if w.has_audio {
		w.pcm = make([]f32, 1024 * c.channels)
		// Input arrives in WAVE order; the encoder takes AAC's.
		source: [8]u8
		source, w.reorder = audio.channel_order(.AAC, c.channels)
		for s, k in source do w.aac_order[s] = u8(k)
	}
	if w.has_video {
		open_frames(w)
	} else {
		w.open = true
	}
	return .None
}

// The WebM side of create: video only, timed in nanoseconds.
@(private)
create_webm :: proc(w: ^Writer, path: string, stream: io.Stream) -> Error {
	c := &w.config
	config := webm.Writer_Config {
		width    = c.width,
		height   = c.height,
		alpha    = c.transparency != .None,
		chapters = c.chapters,
	}
	e := stream.procedure != nil ? webm.create_stream(&w.webm, stream, config) : webm.create(&w.webm, path, config)
	if e != .None {
		media.close(&w.video)
		w.error_detail = "could not create the output file"
		return container_error(e)
	}
	open_frames(w)
	return .None
}

// The conversion buffers every output keeps, then the writer is open.
@(private)
open_frames :: proc(w: ^Writer) {
	c := &w.config
	w.coefficients = rgb_to_yuv_coefficients(.BT709, false)
	luma := c.width * c.height
	w.planes[0] = make([]u8, luma + luma / 2)
	w.planes[1] = w.planes[0][luma:][:luma / 4]
	w.planes[2] = w.planes[0][luma + luma / 4:][:luma / 4]
	if c.transparency != .None do w.alpha_plane = make([]u8, luma)
	w.open = true
}

// Encodes one frame of tightly or loosely packed RGBA8 (stride in bytes).
write_frame :: proc(w: ^Writer, rgba: []u8, stride: int) -> Error {
	if w == nil || !w.open do return .Closed
	if !w.has_video do return .Invalid_Config
	if w.err != .None do return w.err
	c := &w.config
	if stride < c.width * 4 || len(rgba) < (c.height - 1) * stride + c.width * 4 do return .Invalid_Input
	strides := [3]int{c.width, c.width / 2, c.width / 2}
	if c.transparency != .None {
		rgba_to_i420a(rgba, stride, c.width, c.height, w.planes, strides, w.alpha_plane, c.width, &w.coefficients, c.alpha, c.transparency, &w.alpha_scratch)
	} else {
		rgba_to_i420(rgba, stride, c.width, c.height, w.planes, strides, &w.coefficients, c.alpha, c.background)
	}
	frame := media.Video_Frame {
		width        = c.width,
		height       = c.height,
		bit_depth    = 8,
		storage_bits = 8,
		chroma       = .YUV420,
		planes       = {{w.planes[0], strides[0]}, {w.planes[1], strides[1]}, {w.planes[2], strides[2]}},
		alpha        = {w.alpha_plane, c.width},
	}
	return encode_planes(w, frame)
}

// Encodes one frame already in 8-bit 4:2:0 BT.709 limited range, for callers
// that convert on the GPU or elsewhere: I420 (Y, U, V) or NV12 (Y and
// interleaved UV, Vulkan Video's own layout, which uploads row by row). A
// transparent video also takes its full-range alpha plane, with colour
// stored as `transparency` says (rgba_to_i420a is the reference).
write_i420 :: proc(w: ^Writer, planes: [3][]u8, strides: [3]int, alpha: []u8 = nil, alpha_stride := 0) -> Error {
	return write_converted(w, planes, strides, false, alpha, alpha_stride)
}

write_nv12 :: proc(w: ^Writer, planes: [2][]u8, strides: [2]int, alpha: []u8 = nil, alpha_stride := 0) -> Error {
	return write_converted(w, {planes[0], planes[1], nil}, {strides[0], strides[1], 0}, true, alpha, alpha_stride)
}

@(private)
write_converted :: proc(w: ^Writer, planes: [3][]u8, strides: [3]int, interleaved: bool, alpha: []u8, alpha_stride: int) -> Error {
	if w == nil || !w.open do return .Closed
	if !w.has_video do return .Invalid_Config
	if w.err != .None do return w.err
	if (w.config.transparency != .None) != (len(alpha) > 0) do return .Invalid_Input
	frame := media.Video_Frame {
		width              = w.config.width,
		height             = w.config.height,
		bit_depth          = 8,
		storage_bits       = 8,
		chroma             = .YUV420,
		planes             = {{planes[0], strides[0]}, {planes[1], strides[1]}, {planes[2], strides[2]}},
		chroma_interleaved = interleaved,
		alpha              = {alpha, alpha_stride},
	}
	return encode_planes(w, frame)
}

@(private)
encode_planes :: proc(w: ^Writer, frame: media.Video_Frame) -> Error {
	if e := media.encode_video(&w.video, frame, {packet = on_video_packet, user = w}); e != .None {
		w.error_detail = w.video.error_detail
		w.err = media_error(e)
		return w.err
	}
	w.frames += 1
	return w.err
}

@(private)
on_video_packet :: proc(packet: media.Packet, user: rawptr) {
	w := (^Writer)(user)
	if w.err != .None do return
	if w.config.codec == .VP9 {
		add_vp9_packet(w, packet)
		return
	}
	codec: mp4.Codec = w.config.codec == .H264 ? .H264 : .H265
	if packet.framing == .NAL {
		add_video_nal(w, codec, packet.data)
		return
	}
	pos := 0
	for {
		nal, ok := mp4.next_annex_b_nal(packet.data, &pos)
		if !ok do break
		add_video_nal(w, codec, nal)
		if w.err != .None do return
	}
}

// Groups the encoder's NAL units into access units. The encoders emit I/P
// pictures in order, so the k-th access unit is frame k.
@(private)
add_video_nal :: proc(w: ^Writer, codec: mp4.Codec, nal: []u8) {
	if mp4.starts_access_unit(codec, nal, w.picture) do close_video_sample(w)
	if !mp4.sample_open(&w.mux) {
		pts := w.samples * w.frame_duration
		if w.queue_head < len(w.queued) && audio_before(w, w.queued[w.queue_head].pts, pts, 0) {
			flush_audio(w, pts, INTERLEAVE_SECONDS)
		}
		if e := mp4.begin_sample(&w.mux, w.video_track, pts, pts); e != .None {w.err = mp4_error(e); return}
	}
	if e := mp4.add_nal(&w.mux, nal); e != .None {
		w.err = mp4_error(e)
		w.error_detail = "the encoder produced a NAL unit the MP4 writer cannot store"
		return
	}
	if mp4.is_picture_nal(codec, nal) do w.picture = true
}

@(private)
close_video_sample :: proc(w: ^Writer) {
	if !mp4.sample_open(&w.mux) do return
	if e := mp4.end_sample(&w.mux, false); e != .None {w.err = mp4_error(e); return}
	w.samples += 1
	w.picture = false
}

// Whether audio at pts (samples) starts before video ticks plus seconds.
@(private)
audio_before :: proc(w: ^Writer, pts: i64, video: i64, seconds: f64) -> bool {
	return f64(pts) / f64(w.config.sample_rate) <= f64(video) / f64(w.timescale) + seconds
}

@(private)
flush_audio :: proc(w: ^Writer, video: i64, seconds: f64) {
	for w.queue_head < len(w.queued) && w.err == .None {
		q := w.queued[w.queue_head]
		if seconds >= 0 && !audio_before(w, q.pts, video, seconds) do break
		if e := mp4.write_audio_packet(&w.mux, w.audio_track, w.queue[q.offset:][:q.size], q.pts); e != .None {
			w.err = mp4_error(e)
			return
		}
		w.queue_head += 1
	}
	if w.queue_head == len(w.queued) {
		clear(&w.queue)
		clear(&w.queued)
		w.queue_head = 0
	}
}

@(private)
on_audio_packet :: proc(packet: media.Packet, user: rawptr) {
	w := (^Writer)(user)
	if w.err != .None do return
	offset := len(w.queue)
	if _, e := append(&w.queue, ..packet.data); e != nil {w.err = .Out_Of_Memory; return}
	append(&w.queued, Queued_Audio{offset = offset, size = len(packet.data), pts = packet.sample_index})
}

// Appends interleaved PCM (len a multiple of the channel count). Samples are
// clamped to [-1, 1]; NaN becomes silence. Supply audio before or alongside
// the video it accompanies to interleave the file; audio written after the
// last frame is stored after the video.
write_audio :: proc(w: ^Writer, samples: []f32) -> Error {
	if w == nil || !w.open do return .Closed
	if !w.has_audio do return .Invalid_Config
	if w.err != .None do return w.err
	ch := w.config.channels
	if len(samples) % ch != 0 do return .Invalid_Input
	frame := len(w.pcm)
	pos := 0
	for pos < len(samples) {
		n := min(len(samples) - pos, frame - w.pcm_fill * ch)
		dst := w.pcm[w.pcm_fill * ch:][:n]
		src := samples[pos:][:n]
		if w.reorder {
			for i := 0; i < n; i += ch do for j in 0 ..< ch {
				v := src[i + int(w.aac_order[j])]
				dst[i + j] = v != v ? 0 : clamp(v, -1, 1)
			}
		} else {
			for v, i in src do dst[i] = v != v ? 0 : clamp(v, -1, 1)
		}
		pos += n
		w.pcm_fill += n / ch
		if w.pcm_fill * ch == frame do encode_pcm(w) or_return
	}
	w.pcm_total += i64(len(samples) / ch)
	return .None
}

@(private)
encode_pcm :: proc(w: ^Writer) -> Error {
	frame := media.Audio_Frame {
		samples             = w.pcm,
		sample_rate         = w.config.sample_rate,
		channels            = w.config.channels,
		samples_per_channel = 1024,
	}
	if e := media.encode_audio(&w.audio, frame, {packet = on_audio_packet, user = w}); e != .None {
		w.error_detail = w.audio.error_detail
		w.err = media_error(e)
		return w.err
	}
	w.pcm_fill = 0
	return w.err
}

// Drains the encoders, trims the AAC padding through the edit list, writes
// the sample tables and closes the file. Call destroy afterwards.
finish :: proc(w: ^Writer) -> Error {
	if w == nil || !w.open do return .Closed
	if w.err != .None do return w.err
	if w.has_audio {
		if w.pcm_fill > 0 {
			for &v in w.pcm[w.pcm_fill * w.config.channels:] do v = 0
			encode_pcm(w) or_return
		}
		if e := media.drain(&w.audio, {packet = on_audio_packet, user = w}); e != .None {
			w.err = media_error(e)
			return w.err
		}
		if e := mp4.set_track_end(&w.mux, w.audio_track, w.pcm_total); e != .None do return mp4_error(e)
	}
	if w.has_video {
		if e := media.drain(&w.video, {packet = on_video_packet, user = w}); e != .None {
			w.error_detail = w.video.error_detail
			w.err = media_error(e)
			return w.err
		}
		close_video_sample(w)
		if w.err != .None do return w.err
		if w.samples != w.frames {
			w.error_detail = "encoder access units do not match submitted frames"
			w.err = .Codec_Error
			return w.err
		}
	}
	flush_audio(w, 0, -1)
	if w.err != .None do return w.err
	if w.config.codec == .VP9 {
		if e := webm.finish(&w.webm); e != .None {w.err = container_error(e); return w.err}
	} else if e := mp4.finish(&w.mux); e != .None {
		w.err = mp4_error(e)
		return w.err
	}
	w.open = false
	return .None
}

// Releases everything; an unfinished file is left incomplete.
destroy :: proc(w: ^Writer) {
	if w == nil do return
	media.close(&w.video)
	media.close(&w.audio)
	mp4.destroy(&w.mux)
	webm.destroy(&w.webm)
	delete(w.planes[0])
	delete(w.alpha_plane)
	destroy_alpha_scratch(&w.alpha_scratch)
	delete(w.pcm)
	delete(w.queue)
	delete(w.queued)
	w^ = {}
}

// Backend actually encoding video, for logs.
video_backend :: proc(w: ^Writer) -> (media.Backend, string) {
	return w.video.backend, w.video.provider_name
}

// A VP9 frame (with its alpha frame) is one WebM block, timed in
// nanoseconds from the exact frame rate.
@(private)
add_vp9_packet :: proc(w: ^Writer, packet: media.Packet) {
	pts, next := frame_time_ns(w, w.samples), frame_time_ns(w, w.samples + 1)
	if e := webm.write_sample(&w.webm, packet.data, pts, packet.keyframe, packet.alpha, next - pts); e != .None {
		w.err = container_error(e)
		return
	}
	w.samples += 1
}

@(private)
frame_time_ns :: proc(w: ^Writer, frame: i64) -> i64 {
	return i64(i128(frame) * i128(w.config.fps_den) * 1_000_000_000 / i128(w.config.fps_num))
}

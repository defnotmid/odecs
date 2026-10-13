package viewer

import media "../codec/media"
import native "../codec/media/native"
import movie "../codec/movie"
import "core:fmt"
import "core:os"
import "core:strings"

// What the viewer plays: a container through movie.Reader (MP4, MOV, WebM),
// or a raw elementary stream decoded directly (Annex-B H.264/H.265, ADTS AAC).
Source_Kind :: enum {
	Movie,
	Raw_Video,
	Raw_Audio,
}

Frame :: struct {
	rgba:          []u8, // RGBA8, premultiplied, tight rows
	width, height: int,
	time:          f64,
	index:         int,
}

Source :: struct {
	kind:                  Source_Kind,
	label:                 string, // codec summary for the HUD
	audio_label:           string,
	has_video, has_audio:  bool,
	alpha, seekable:       bool,
	width, height:         int,
	fps:                   f64,
	duration:              f64, // seconds; 0 when unknown
	frame_count:           int, // 0 when unknown
	sample_rate, channels: int,
	reader:                movie.Reader,
	// Raw streams: the whole file, a decoder session and its output.
	data:                  []u8,
	codec:                 media.Codec,
	options:               ^native.Options,
	session:               media.Session,
	session_open:          bool,
	nals:                  media.Nal_Iterator,
	drained:               bool, // the session was drained at the end of the stream
	cursor:                int, // next ADTS frame
	queue:                 [dynamic]Frame, // decoded raw video, oldest first
	spare:                 [dynamic][]u8, // RGBA buffers for reuse
	shown:                 []u8, // the buffer of the frame last returned
	decoded:               int, // raw video pictures decoded since the start
	pcm:                   [dynamic]f32,
	pcm_head:              int,
	coefficients:          movie.Yuv_To_Rgb,
	error_detail:          string,
}

source_open :: proc(s: ^Source, path: string, options: ^native.Options, preference: media.Preference, raw_fps: f64) -> bool {
	s.options = options
	lower := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".264") || strings.has_suffix(lower, ".h264") || strings.has_suffix(lower, ".avc") || strings.has_suffix(lower, ".jsv") || strings.has_suffix(lower, ".jvt"):
		return open_raw_video(s, path, .H264, raw_fps)
	case strings.has_suffix(lower, ".265") || strings.has_suffix(lower, ".h265") || strings.has_suffix(lower, ".hevc") || strings.has_suffix(lower, ".bit") || strings.has_suffix(lower, ".bin"):
		return open_raw_video(s, path, .H265, raw_fps)
	case strings.has_suffix(lower, ".aac") || strings.has_suffix(lower, ".adts"):
		return open_raw_audio(s, path)
	}
	s.kind = .Movie
	if e := movie.open_reader(&s.reader, path, {preference = preference, native_options = options, premultiplied_alpha = true}); e != .None {
		s.error_detail = fmt.aprintf("%v: %s", e, s.reader.error_detail)
		return false
	}
	v, a := s.reader.video, s.reader.audio
	s.seekable = true
	s.has_video = s.reader.video_index >= 0 && v.frame_count > 0
	s.has_audio = a.present
	if s.has_video {
		s.width, s.height, s.alpha = v.width, v.height, v.has_alpha
		s.fps = v.fps_num > 0 ? f64(v.fps_num) / f64(v.fps_den) : 30
		s.duration, s.frame_count = v.duration, v.frame_count
		s.label = fmt.aprintf("%v %dx%d %.4g fps%s", v.codec, v.width, v.height, s.fps, v.has_alpha ? " alpha" : "")
	}
	if a.codec != .None {
		s.sample_rate, s.channels = a.sample_rate, a.channels
		s.audio_label = fmt.aprintf("%v %d Hz %d ch%s", a.codec, a.sample_rate, a.channels, a.present ? "" : " (not decoded)")
		if s.has_audio do s.duration = max(s.duration, f64(a.samples) / f64(a.sample_rate))
	}
	if !s.has_video && !s.has_audio {
		s.error_detail = "no decodable video or audio track"
		return false
	}
	return true
}

source_close :: proc(s: ^Source) {
	if s.kind == .Movie do movie.close_reader(&s.reader)
	if s.session_open do media.close(&s.session)
	for f in s.queue do delete(f.rgba)
	for b in s.spare do delete(b)
	delete(s.shown)
	delete(s.queue)
	delete(s.spare)
	delete(s.pcm)
	delete(s.data)
	delete(s.label)
	delete(s.audio_label)
	s^ = {}
}

// The next frame in presentation order, or ok = false at the end.
source_next_frame :: proc(s: ^Source) -> (f: Frame, ok: bool) {
	if s.kind == .Movie {
		mf, e := movie.next_frame(&s.reader)
		if e != .None {
			if e != .End_Of_Stream do s.error_detail = fmt.aprintf("decode: %v %s", e, s.reader.error_detail)
			return {}, false
		}
		return {mf.rgba, mf.width, mf.height, mf.time, mf.index}, true
	}
	if s.kind != .Raw_Video do return {}, false
	for len(s.queue) == 0 {
		if !feed_raw_video(s) do return {}, false
	}
	if s.shown != nil do append(&s.spare, s.shown)
	f = pop_front(&s.queue)
	s.shown = f.rgba
	return f, true
}

// The frame on screen at `seconds` (ok = false without video). Raw streams
// have no index: they restart and decode forward to the target.
source_seek :: proc(s: ^Source, seconds: f64) -> (f: Frame, ok: bool) {
	switch s.kind {
	case .Movie:
		if s.has_audio do movie.seek_audio(&s.reader, seconds)
		if !s.has_video do return {}, false
		mf, e := movie.frame_at(&s.reader, seconds)
		if e != .None do return {}, false
		return {mf.rgba, mf.width, mf.height, mf.time, mf.index}, true
	case .Raw_Video:
		restart_raw(s) or_return
		f = source_next_frame(s) or_return
		for f.time + 1 / s.fps <= seconds {
			next := source_next_frame(s) or_break
			f = next
		}
		return f, true
	case .Raw_Audio:
		restart_raw(s)
		skip := int(seconds * f64(s.sample_rate))
		discard: [4096]f32
		for skip > 0 {
			n := source_read_audio(s, discard[:min(skip, len(discard) / s.channels) * s.channels])
			if n == 0 do break
			skip -= n
		}
	}
	return {}, false
}

// Moves only the audio position (movies; raw video has no audio).
source_seek_audio :: proc(s: ^Source, seconds: f64) {
	if s.kind == .Movie && s.has_audio do movie.seek_audio(&s.reader, seconds)
}

// Interleaved f32 PCM at the current audio position; 0 at the end.
source_read_audio :: proc(s: ^Source, out: []f32) -> int {
	if s.kind == .Movie {
		n, _ := movie.read_audio(&s.reader, out)
		return n
	}
	if s.kind != .Raw_Audio do return 0
	for len(s.pcm) - s.pcm_head < len(out) {
		if !feed_raw_audio(s) do break
	}
	n := min(len(out), len(s.pcm) - s.pcm_head) / s.channels
	copy(out, s.pcm[s.pcm_head:][:n * s.channels])
	s.pcm_head += n * s.channels
	if s.pcm_head == len(s.pcm) {
		clear(&s.pcm)
		s.pcm_head = 0
	}
	return n
}

// ---- Raw elementary streams -------------------------------------------------

@(private)
open_raw_video :: proc(s: ^Source, path: string, codec: media.Codec, fps: f64) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {s.error_detail = fmt.aprintf("cannot read %s", path); return false}
	s.kind, s.data, s.codec = .Raw_Video, data, codec
	s.fps = fps
	s.has_video = true
	if !restart_raw(s) do return false
	// The first picture gives the size.
	f, ok := source_next_frame(s)
	if !ok {
		if s.error_detail == "" do s.error_detail = "no picture in the stream"
		return false
	}
	s.width, s.height = f.width, f.height
	s.label = fmt.aprintf("raw %v %dx%d (%.4g fps assumed)", codec, f.width, f.height, fps)
	restart_raw(s)
	return true
}

@(private)
ADTS_RATES := [13]int{96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350}

@(private)
open_raw_audio :: proc(s: ^Source, path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {s.error_detail = fmt.aprintf("cannot read %s", path); return false}
	s.kind, s.data, s.codec = .Raw_Audio, data, .AAC
	if len(data) < 7 || data[0] != 0xFF || data[1] & 0xF0 != 0xF0 {s.error_detail = "not an ADTS AAC stream"; return false}
	rate_index := int(data[2] >> 2 & 15)
	if rate_index >= len(ADTS_RATES) {s.error_detail = "unsupported ADTS sample rate"; return false}
	s.sample_rate = ADTS_RATES[rate_index]
	s.channels = int(data[2] & 1) << 2 | int(data[3] >> 6)
	if s.channels == 7 do s.channels = 8
	if s.channels == 0 {s.error_detail = "ADTS without a channel configuration"; return false}
	// Count frames for the duration.
	frames := 0
	for at := 0; at + 7 <= len(data); frames += 1 {
		length := adts_length(data[at:])
		if length < 7 do break
		at += length
	}
	s.duration = f64(frames * 1024) / f64(s.sample_rate)
	s.has_audio = true
	s.audio_label = fmt.aprintf("raw AAC %d Hz %d ch", s.sample_rate, s.channels)
	return restart_raw(s)
}

@(private)
adts_length :: proc(b: []u8) -> int {
	if len(b) < 7 || b[0] != 0xFF || b[1] & 0xF0 != 0xF0 do return 0
	return int(b[3] & 3) << 11 | int(b[4]) << 3 | int(b[5]) >> 5
}

// Reopens the decoder at the start of the stream.
@(private)
restart_raw :: proc(s: ^Source) -> bool {
	if s.session_open {media.close(&s.session); s.session_open = false}
	config := media.default_config(s.codec, .Decode)
	config.preference = .Native
	if s.codec == .AAC {
		config.sample_rate, config.channels = s.sample_rate, s.channels
	}
	providers := [1]media.Provider{native.provider(s.options)}
	if e := media.open(&s.session, config, providers[:]); e != .None {
		s.error_detail = fmt.aprintf("decoder refused the stream: %v", e)
		return false
	}
	s.session_open = true
	s.nals = {packet = {data = s.data, framing = .Annex_B}}
	s.cursor = 0
	s.decoded = 0
	s.drained = false
	for f in s.queue do append(&s.spare, f.rgba)
	clear(&s.queue)
	clear(&s.pcm)
	s.pcm_head = 0
	return true
}

// Feeds NAL units until a picture comes out, then drains at the end.
@(private)
feed_raw_video :: proc(s: ^Source) -> bool {
	receiver := media.Receiver{video = on_raw_frame, user = s}
	for len(s.queue) == 0 {
		if s.drained do return false
		nal, done, err := media.next_nal(&s.nals)
		if err != .None || done {
			s.drained = true
			media.drain(&s.session, receiver)
			return len(s.queue) > 0
		}
		if e := media.decode(&s.session, {data = nal, framing = .NAL}, receiver); e != .None {
			s.error_detail = fmt.aprintf("decode: %v %s", e, s.session.error_detail)
			return false
		}
	}
	return true
}

@(private)
on_raw_frame :: proc(f: media.Video_Frame, user: rawptr) {
	s := (^Source)(user)
	size := f.width * f.height * 4
	rgba: []u8
	for len(s.spare) > 0 {
		b := pop(&s.spare)
		if len(b) == size {rgba = b; break}
		delete(b)
	}
	if rgba == nil do rgba = make([]u8, size)
	// Raw streams carry no container colour: the common player rule.
	m: movie.Matrix = f.height <= 576 ? .BT601 : .BT709
	s.coefficients = movie.yuv_to_rgb_coefficients(m, false, f.bit_depth)
	sx, sy := media.chroma_subsampling(f.chroma)
	planes := [3][]u8{f.planes[0].data, f.planes[1].data, f.planes[2].data}
	strides := [3]int{f.planes[0].stride, f.planes[1].stride, f.planes[2].stride}
	if f.chroma == .Monochrome do planes[1], planes[2] = nil, nil
	movie.yuv_to_rgba(planes, strides, f.width, f.height, f.storage_bits, uint(sx >> 1), uint(sy >> 1), &s.coefficients, rgba, f.width * 4)
	append(&s.queue, Frame{rgba, f.width, f.height, f64(s.decoded) / s.fps, s.decoded})
	s.decoded += 1
}

// Decodes ADTS frames until some PCM is available.
@(private)
feed_raw_audio :: proc(s: ^Source) -> bool {
	for {
		if s.cursor >= len(s.data) do return false
		length := adts_length(s.data[s.cursor:])
		if length < 7 || length > len(s.data) - s.cursor do return false
		packet := s.data[s.cursor:][:length]
		s.cursor += length
		before := len(s.pcm)
		if media.decode(&s.session, {data = packet, framing = .ADTS}, {audio = on_raw_audio, user = s}) != .None do continue
		if len(s.pcm) > before do return true
	}
}

@(private)
on_raw_audio :: proc(f: media.Audio_Frame, user: rawptr) {
	s := (^Source)(user)
	append(&s.pcm, ..f.samples)
}

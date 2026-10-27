// odecs half of tests/compare.sh's decode cases: one track of a file, demuxed once
// by video.Reader's containers into resident packets, then decoded by the
// native provider through media, a fresh session per round. Decode and drain
// are timed (opening the session is not), median of seven after a warmup.
// Frames or samples are counted, never touched. An image is a WebP file
// decoded whole to RGBA, its bytes resident. THREADS=n gives the native
// provider a pool of n workers (the caller and n - 1 threads).
//   [THREADS=n] decode_benchmark FILE video|audio|image
package decode_benchmark

import common "../common"
import flac "../audio/flac"
import media "../media"
import native "../media/native"
import video "../video"
import mp3 "../audio/mp3"
import mp4 "../container/mp4"
import ogg "../container/ogg"
import webm "../container/webm"
import webp "../image/webp"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

ROUNDS :: 8 // the first is a warmup

fail :: proc(what: string, args: ..any) -> ! {
	fmt.eprint("decode benchmark: ")
	fmt.eprintfln(what, ..args)
	os.exit(1)
}

Count :: struct {
	units: i64,
}

on_video :: proc(f: media.Video_Frame, user: rawptr) {(^Count)(user).units += 1}
on_audio :: proc(f: media.Audio_Frame, user: rawptr) {(^Count)(user).units += i64(f.samples_per_channel)}

main :: proc() {
	if len(os.args) != 3 || os.args[2] != "video" && os.args[2] != "audio" && os.args[2] != "image" {
		fmt.eprintln("usage: decode_benchmark FILE video|audio|image")
		os.exit(2)
	}
	if os.args[2] == "image" {
		image(os.args[1])
		return
	}
	is_video := os.args[2] == "video"
	r: video.Reader
	if e := video.open_reader(&r, os.args[1], {preference = .Native}); e != .None do fail("open: %v %s", e, r.error_detail)
	config: media.Config
	setup: [dynamic][]u8 // parameter sets, fed first each round
	packets: [dynamic]media.Packet
	if is_video {
		config = video_track(&r, &setup, &packets)
	} else {
		config = audio_track(&r, &packets)
	}
	pool: common.Static_Pool
	options: native.Options
	if threads, _ := strconv.parse_int(os.get_env("THREADS", context.temp_allocator)); threads > 1 {
		common.init_static_pool(&pool, threads - 1)
		options.pool = &pool.work_pool
	}
	providers := [1]media.Provider{native.provider(&options)}
	count: Count
	receiver := media.Receiver{video = on_video, audio = on_audio, user = &count}
	times: [ROUNDS - 1]f64
	units: i64
	for round in 0 ..< ROUNDS {
		session: media.Session
		if e := media.open(&session, config, providers[:]); e != .None do fail("session: %v %s", e, session.error_detail)
		count = {}
		start := time.tick_now()
		for nal in setup do if e := media.decode(&session, {data = nal, framing = .NAL}, receiver); e != .None do fail("parameter set: %v", e)
		for p in packets do if e := media.decode(&session, p, receiver); e != .None do fail("decode: %v %s", e, session.error_detail)
		if e := media.drain(&session, receiver); e != .None do fail("drain: %v", e)
		ms := time.duration_milliseconds(time.tick_since(start))
		media.close(&session)
		if round > 0 do times[round - 1] = ms
		if round > 0 && count.units != units do fail("rounds disagree: %d then %d", units, count.units)
		units = count.units
	}
	slice.sort(times[:])
	fmt.printfln("odecs decode: codec=%v %s=%d packets=%d codec_ms=%.3f min_ms=%.3f max_ms=%.3f",
		config.codec, is_video ? "frames" : "samples", units, len(packets), times[3], times[0], times[6])
}

image :: proc(path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do fail("cannot read %s", path)
	times: [ROUNDS - 1]f64
	width, height: int
	for round in 0 ..< ROUNDS {
		start := time.tick_now()
		img, e := webp.decode(data)
		ms := time.duration_milliseconds(time.tick_since(start))
		if e != .None do fail("webp: %v", e)
		width, height = img.width, img.height
		webp.destroy_image(&img)
		if round > 0 do times[round - 1] = ms
	}
	slice.sort(times[:])
	fmt.printfln("odecs decode: codec=WebP pixels=%d codec_ms=%.3f min_ms=%.3f max_ms=%.3f", width * height, times[3], times[0], times[6])
}

video_track :: proc(r: ^video.Reader, setup: ^[dynamic][]u8, packets: ^[dynamic]media.Packet) -> media.Config {
	if r.video_index < 0 do fail("no video track")
	codec: media.Codec
	switch r.video.codec {
	case .H264: codec = .H264
	case .H265: codec = .H265
	case .ProRes: codec = .ProRes
	case .VP9: codec = .VP9
	case .AV1: fail("AV1 decodes only in hardware")
	}
	config := media.default_config(codec, .Decode)
	config.preference = .Native
	config.width, config.height = r.video.width, r.video.height
	config.bit_depth = r.bit_depth
	config.chroma = r.video.chroma
	config.no_reordering = codec == .ProRes || codec == .VP9
	nal := codec == .H264 || codec == .H265
	if nal do for p in r.parameter_sets do append(setup, slice.clone(p))
	for i in 0 ..< len(r.index.pts) {
		data, alpha: []u8
		if r.audio.container == .WebM {
			p, e := webm.read_sample(&r.audio.webm, r.video_index, i)
			if e != .None do fail("video sample %d: %v", i, e)
			data, alpha = p.data, p.additional
		} else {
			p, e := mp4.read_sample(&r.audio.demux, r.video_index, i)
			if e != .None do fail("video sample %d: %v", i, e)
			data = p.data
		}
		if !nal {
			append(packets, media.Packet{data = slice.clone(data), framing = .Frame, alpha = alpha != nil ? slice.clone(alpha) : nil})
			continue
		}
		size := r.nal_length_size
		for pos := 0; pos < len(data); {
			n := 0
			for b in data[pos:][:size] do n = n << 8 | int(b)
			pos += size
			if n > 0 do append(packets, media.Packet{data = slice.clone(data[pos:][:n]), framing = .NAL})
			pos += n
		}
	}
	return config
}

audio_track :: proc(r: ^video.Reader, packets: ^[dynamic]media.Packet) -> media.Config {
	codec: media.Codec
	#partial switch r.audio.codec {
	case .AAC: codec = .AAC
	case .FLAC: codec = .FLAC
	case .MP3: codec = .MP3
	case .Opus: codec = .Opus
	case .ALAC: codec = .ALAC
	case: fail("no coded audio track (%v)", r.audio.codec)
	}
	config := media.default_config(codec, .Decode)
	config.sample_rate, config.channels = r.audio.sample_rate, r.audio.channels
	config.extradata = r.audio.config
	framing: media.Framing = codec == .AAC ? .Raw_AAC : .Frame
	add :: proc(packets: ^[dynamic]media.Packet, data: []u8, framing: media.Framing) {
		append(packets, media.Packet{data = slice.clone(data), framing = framing})
	}
	switch r.audio.container {
	case .FLAC:
		if e := flac.seek(&r.audio.flac_file, 0); e != .None do fail("flac seek: %v", e)
		for {
			p, e := flac.read_frame(&r.audio.flac_file)
			if e == .End_Of_Stream do break
			if e != .None do fail("flac frame: %v", e)
			add(packets, p.data, framing)
		}
	case .MP3:
		for i in 0 ..< len(r.audio.mp3_file.frames) {
			data, e := mp3.read_frame(&r.audio.mp3_file, i)
			if e != .None do fail("mp3 frame %d: %v", i, e)
			add(packets, data, framing)
		}
	case .Ogg:
		for i in 2 ..< len(r.audio.ogg_file.packets) { 	// after OpusHead and OpusTags
			data, e := ogg.read_packet(&r.audio.ogg_file, i)
			if e != .None do fail("ogg packet %d: %v", i, e)
			add(packets, data, framing)
		}
	case .WebM:
		for i in 0 ..< len(r.audio.webm.tracks[r.audio.track].samples) {
			p, e := webm.read_sample(&r.audio.webm, r.audio.track, i)
			if e != .None do fail("audio sample %d: %v", i, e)
			add(packets, p.data, framing)
		}
	case .MP4:
		for i in 0 ..< len(r.audio.demux.tracks[r.audio.track].samples) {
			p, e := mp4.read_sample(&r.audio.demux, r.audio.track, i)
			if e != .None do fail("audio sample %d: %v", i, e)
			add(packets, p.data, framing)
		}
	case .WAV:
		fail("WAV is PCM, not decoded")
	}
	return config
}

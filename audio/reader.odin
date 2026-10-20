package audio

import alac "./alac"
import common "../common"
import flac "./flac"
import mp3 "./mp3"
import mp4 "../container/mp4"
import ogg "../container/ogg"
import opus "./opus"
import vorbis "./vorbis"
import wav "./wav"
import webm "../container/webm"
import "core:io"
import "core:os"

// MP4 includes QuickTime .mov; WebM includes Matroska; WAV includes RF64;
// FLAC and MP3 are native .flac and .mp3 files; Ogg holds Opus or Vorbis.
Container :: enum u8 {
	MP4,
	WebM,
	WAV,
	FLAC,
	MP3,
	Ogg,
}

Codec :: enum u8 {
	None,
	AAC,
	PCM, // uncompressed audio (QuickTime, Matroska, WAV)
	FLAC,
	MP3, // MPEG-1/2/2.5 Layer III
	Opus,
	ALAC, // Apple Lossless (.m4a, .mov, .mp4)
	Vorbis,
	Other,
}

Info :: struct {
	present:               bool, // a track read decodes
	codec:                 Codec, // the first audio track's codec, decodable or not
	sample_rate, channels: int,
	samples:               i64, // presented samples per channel
}

// A file opened for its audio: the container (whose other tracks a video
// reader may also read) and the first audio track's decode state. PCM index
// zero is time zero: priming and padding are trimmed, and a delayed track
// starts with silence.
Reader :: struct {
	using info:   Info,
	container:    Container,
	demux:        mp4.Reader,
	webm:         webm.Reader,
	wave:         wav.Reader,
	flac_file:    flac.Reader,
	mp3_file:     mp3.Reader,
	ogg_file:     ogg.Reader,
	track:        int, // the audio track in demux or webm, -1 when absent
	error_detail: string,
	// The track's configuration.
	header:       []u8, // owned: Ogg Opus's OpusHead, or Vorbis' headers Xiph-laced
	config:       []u8, // the decoder's extradata (AudioSpecificConfig, FLAC metadata, ...)
	ogg_headers:  int, // header packets before the audio in an Ogg stream
	pcm_sample:   common.Sample_Format, // PCM: how each sample is stored
	order:        [8]u8, // WAVE-order channel k is decoded channel order[k] (channel_order)
	reorder:      bool,
	// Ogg and Matroska: the PCM index of each packet's first sample, from
	// the packets' sizes (Matroska timestamps are rounded to its scale), and
	// the decoded samples to discard at the start.
	starts:       []i64,
	delay:        i64,
	// Decode state.
	decoder:      Decoder,
	open:         bool,
	done:         bool, // native FLAC: the last frame has been fed
	cursor:       int, // next packet to feed
	next:         i64, // PCM index of the next sample to queue
	end:          i64,
	pcm:          [dynamic]f32,
	pcm_head:     int,
	pcm_input:    [dynamic]f32, // one PCM chunk converted to f32
}

open :: proc(r: ^Reader, path: string) -> Error {
	return open_file(r, path, {})
}

// Reads a stream with Read_At and Size; the reader borrows it until close.
open_stream :: proc(r: ^Reader, stream: io.Stream) -> Error {
	return open_file(r, "", stream)
}

// Detects and opens the container, and describes the first audio track.
@(private)
open_file :: proc(r: ^Reader, path: string, stream: io.Stream) -> Error {
	if r == nil do return .Invalid_Config
	r^ = {track = -1}
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
	switch {
	case is_flac(&magic, path, stream):
		r.container = .FLAC
		if e := stream.procedure != nil ? flac.open_stream(&r.flac_file, stream) : flac.open(&r.flac_file, path); e != .None {
			r.error_detail = "not a readable FLAC file"
			return container_error(e)
		}
		r.track = 0
	case string(magic[8:]) == "WAVE" && (riff == "RIFF" || riff == "RIFX" || riff == "RF64" || riff == "BW64"):
		r.container = .WAV
		if e := stream.procedure != nil ? wav.open_stream(&r.wave, stream) : wav.open(&r.wave, path); e != .None {
			r.error_detail = e == .Unsupported ? "ADPCM and other compressed WAV audio is not supported" : "not a readable WAV file"
			return container_error(e)
		}
		r.track = 0
	case is_mp3(&magic):
		r.container = .MP3
		if e := stream.procedure != nil ? mp3.open_stream(&r.mp3_file, stream) : mp3.open(&r.mp3_file, path); e != .None {
			r.error_detail = e == .Unsupported ? "MP3 Layer I/II or free-format streams are not supported" : "not a readable MP3 file"
			return container_error(e)
		}
		r.track = 0
	case riff == "OggS":
		r.container = .Ogg
		// The first Opus stream, else the first Vorbis one.
		e := stream.procedure != nil ? ogg.open_stream(&r.ogg_file, stream, "OpusHead") : ogg.open(&r.ogg_file, path, "OpusHead")
		if e == .Invalid_Data {
			e = stream.procedure != nil ? ogg.open_stream(&r.ogg_file, stream, "\x01vorbis") : ogg.open(&r.ogg_file, path, "\x01vorbis")
		}
		if e != .None {
			r.error_detail = "not a readable Ogg file"
			return container_error(e)
		}
		r.track = 0
	case riff == "\x1A\x45\xDF\xA3":
		r.container = .WebM
		if e := stream.procedure != nil ? webm.open_stream(&r.webm, stream) : webm.open(&r.webm, path); e != .None {
			r.error_detail = e == .Unsupported ? "unsupported Matroska document" : "not a readable WebM file"
			return container_error(e)
		}
		for &t, i in r.webm.tracks do if t.kind == .Audio && len(t.samples) > 0 {r.track = i; break}
	case:
		if e := stream.procedure != nil ? mp4.open_stream(&r.demux, stream) : mp4.open(&r.demux, path); e != .None {
			r.error_detail = e == .Unsupported ? "fragmented or multi-description MP4 is not supported" : "not a readable MP4 file"
			return container_error(e)
		}
		for &t, i in r.demux.tracks do if t.kind == .Audio && len(t.samples) > 0 {r.track = i; break}
	}
	if r.track >= 0 do describe(r)
	return .None
}

close :: proc(r: ^Reader) {
	if r == nil do return
	if r.open do destroy_decoder(&r.decoder)
	mp4.close(&r.demux)
	webm.close(&r.webm)
	wav.close(&r.wave)
	flac.close(&r.flac_file)
	mp3.close(&r.mp3_file)
	ogg.close(&r.ogg_file)
	delete(r.header)
	delete(r.starts)
	delete(r.pcm)
	delete(r.pcm_input)
	r^ = {}
}

// Fills out with interleaved f32 PCM from the current position and returns
// the samples per channel written. Zero with End_Of_Stream means the
// presented audio is exhausted.
read :: proc(r: ^Reader, out: []f32) -> (samples: int, err: Error) {
	if r == nil || !r.present do return 0, .Unsupported
	ch := r.channels
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
		if r.next >= r.end || r.open && exhausted(r) do break
		if !r.open {
			if e := reset(r, r.next); e != .None do return got, e
		}
		// Samples already copied are reported along with a later failure.
		if e := advance(r); e != .None do return got, e
	}
	return got, got == 0 ? .End_Of_Stream : .None
}

// Moves the position to `seconds`; read continues from there.
seek :: proc(r: ^Reader, seconds: f64) -> Error {
	if r == nil || !r.present do return .Unsupported
	target := i64(seconds * f64(r.sample_rate) + 0.5)
	return reset(r, clamp(target, 0, r.end))
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
describe :: proc(r: ^Reader) {
	switch r.container {
	case .WebM:
		describe_webm(r)
	case .Ogg:
		describe_ogg(r)
	case .MP3:
		h := r.mp3_file.header
		r.info = {
			present     = true,
			codec       = .MP3,
			sample_rate = h.sample_rate,
			channels    = h.channels,
			samples     = mp3.total_samples(&r.mp3_file),
		}
		r.end = r.samples
	case .FLAC:
		info := r.flac_file.info
		total, e := flac.total_samples(&r.flac_file)
		r.info = {
			present     = e == .None && info.channels <= 8 && info.sample_rate > 0,
			codec       = .FLAC,
			sample_rate = info.sample_rate,
			channels    = info.channels,
			samples     = total,
		}
		r.end = total
		r.config = r.flac_file.stream_info[:]
	case .WAV:
		f := r.wave.format
		r.info = {
			present     = true,
			codec       = .PCM,
			sample_rate = f.sample_rate,
			channels    = f.channels,
			samples     = r.wave.frames,
		}
		r.end = r.wave.frames
		r.pcm_sample = f.sample
	case .MP4:
		describe_mp4(r)
	}
	// Channels in WAVE order, whatever the codec stores.
	family := 1
	if r.codec == .Opus {
		if h, e := opus.parse_head(r.config); e == .None do family = h.mapping_family
	}
	r.order, r.reorder = channel_order(r.codec, r.channels, family)
}

@(private)
describe_mp4 :: proc(r: ^Reader) {
	t := &r.demux.tracks[r.track]
	r.sample_rate, r.channels = t.sample_rate, t.channels
	r.samples = mp4.track_end(t) * i64(t.sample_rate) / i64(t.timescale)
	r.end = r.samples
	r.config = t.audio_specific_config
	#partial switch t.codec {
	case .PCM:
		r.codec = .PCM
		ok: bool
		r.pcm_sample, ok = common.sample_format(int(t.pcm.bits), t.pcm.float, t.pcm.unsigned, !t.pcm.little_endian)
		r.present = ok && t.channels >= 1
	case .AAC:
		r.codec = .AAC
		info, ok := mp4.parse_asc(t.audio_specific_config)
		r.present = ok && info.object_type == 2 && t.channels >= 1 && t.channels <= 8
	case .FLAC:
		r.codec = .FLAC
		r.present = flac_config_ok(t.audio_specific_config, t.sample_rate, t.channels)
	case .MP3:
		r.codec = .MP3
		r.present = t.sample_rate > 0 && t.channels >= 1 && t.channels <= 2
	case .ALAC:
		r.codec = .ALAC
		cfg, e := alac.parse_config(t.audio_specific_config)
		r.present = e == .None && cfg.sample_rate == t.sample_rate && cfg.channels == t.channels
	case .Opus:
		r.codec = .Opus
		h, e := opus.parse_head(t.audio_specific_config)
		r.present = e == .None && h.channels == t.channels && t.sample_rate == 48000
	case:
		r.codec = .Other
	}
}

// Ogg Opus (RFC 7845): OpusHead and OpusTags, then audio packets placed
// from the first page's granule position by each packet's duration, the
// last granule position trimming the end. Ogg Vorbis: three headers, then
// packets whose lengths come from their block sizes (see vorbis_positions).
@(private)
describe_ogg :: proc(r: ^Reader) {
	f := &r.ogg_file
	head, e := ogg.read_packet(f, 0)
	if e != .None do return
	if len(head) >= 7 && head[0] == 1 && string(head[1:7]) == "vorbis" {
		describe_ogg_vorbis(r)
		return
	}
	r.ogg_headers = 2
	if len(f.packets) <= r.ogg_headers do return
	r.header = make([]u8, len(head))
	copy(r.header, head)
	h, he := opus.parse_head(r.header)
	r.info = {
		present     = he == .None,
		codec       = .Opus,
		sample_rate = 48000,
		channels    = h.channels,
	}
	r.config = r.header
	r.delay = i64(h.pre_skip)
	n := len(f.packets) - r.ogg_headers
	r.starts = make([]i64, n)
	position, offset: i64
	anchored := false
	last_granule: i64 = -1
	for i in 0 ..< n {
		p := f.packets[r.ogg_headers + i]
		lead := p.lead
		samples, _ := opus.packet_samples(lead[:])
		r.starts[i] = position
		position += i64(samples)
		if p.granule >= 0 {
			if !anchored {
				offset = max(p.granule - position, 0)
				anchored = true
			}
			last_granule = p.granule
		}
	}
	for &start in r.starts do start += offset
	end := position + offset
	if last_granule >= 0 do end = min(end, last_granule)
	r.samples = max(end - r.delay, 0)
	r.end = r.samples
}

// Ogg Vorbis. The headers become one Xiph-laced block (the decoder's
// configuration, as Matroska stores it). Granule positions are PCM
// positions: the first page's, less what its packets return, places the
// stream (a negative start drops samples; a stream on one page has only an
// end to trim), and the last page's ends it.
@(private)
describe_ogg_vorbis :: proc(r: ^Reader) {
	f := &r.ogg_file
	r.ogg_headers = 3
	r.codec = .Vorbis
	if len(f.packets) <= r.ogg_headers do return
	headers: [3][]u8
	for i in 0 ..< 3 {
		p, e := ogg.read_packet(f, i)
		if e != .None do return
		headers[i] = make([]u8, len(p), context.temp_allocator)
		copy(headers[i], p)
	}
	defer for h in headers do delete(h, context.temp_allocator)
	r.header = xiph_lace(headers[:])
	if r.header == nil do return
	info, ie := vorbis.read_identification(headers[0])
	shape, se := vorbis.packet_shape(headers[0], headers[2])
	if ie != .None || se != .None do return
	r.sample_rate, r.channels = info.rate, info.channels
	r.config = r.header
	n := len(f.packets) - r.ogg_headers
	r.starts = make([]i64, n)
	produced: i64
	previous := 0
	first_granule, first_produced, last_granule: i64 = -1, 0, -1
	for i in 0 ..< n {
		p := f.packets[r.ogg_headers + i]
		lead := p.lead
		r.starts[i] = produced
		if size := vorbis.packet_blocksize(shape, lead[:]); size > 0 {
			produced += i64(vorbis.packet_frames(previous, size))
			previous = size
		}
		if p.granule >= 0 {
			if first_granule < 0 do first_granule, first_produced = p.granule, produced
			last_granule = p.granule
		}
	}
	start: i64
	if first_granule >= 0 && first_granule != last_granule do start = first_granule - first_produced
	for &s in r.starts do s += start
	end := produced + start
	if last_granule >= 0 do end = min(end, last_granule)
	r.samples = max(end, 0)
	r.end = r.samples
	r.present = true
}

// Headers as Xiph lacing (nil if out of memory): their count less one, each
// length but the last as runs of 255 and a final byte, then the headers.
@(private)
xiph_lace :: proc(headers: [][]u8) -> []u8 {
	size := 1 + len(headers[len(headers) - 1])
	for h in headers[:len(headers) - 1] do size += len(h) / 255 + 1 + len(h)
	out, err := make([]u8, size)
	if err != nil do return nil
	out[0] = u8(len(headers) - 1)
	at := 1
	for h in headers[:len(headers) - 1] {
		for _ in 0 ..< len(h) / 255 {out[at] = 255; at += 1}
		out[at] = u8(len(h) % 255)
		at += 1
	}
	for h in headers {
		copy(out[at:], h)
		at += len(h)
	}
	return out
}

@(private)
flac_config_ok :: proc(metadata: []u8, rate, channels: int) -> bool {
	info, _, e := flac.parse_metadata(metadata)
	return e == .None && info.sample_rate == rate && info.channels == channels && channels <= 8 && rate > 0
}

// Matroska audio. Block timestamps are rounded to the timestamp scale
// (usually 1 ms), too coarse to place PCM, so packet positions come from
// frame sizes: AAC's fixed frame length, a PCM block's byte count, or each
// Vorbis packet's block size. A timestamp further than a packet from that
// running position (a gap in the recording) restarts it there.
@(private)
describe_webm :: proc(r: ^Reader) {
	t := &r.webm.tracks[r.track]
	rate := t.sample_rate
	r.sample_rate, r.channels = rate, t.channels
	frame_samples := 0
	shape: vorbis.Packet_Shape
	#partial switch t.codec {
	case .Opus:
		r.codec = .Opus
		h, he := opus.parse_head(t.codec_private)
		if he == .None && h.channels == t.channels {
			r.present = true
			r.config = t.codec_private
			rate = 48000 // Opus always decodes at 48 kHz
			r.sample_rate = rate
			// Packets are as long as the first one says, block timestamps
			// correcting any change.
			if len(t.samples) > 0 {
				if p, pe := webm.read_sample(&r.webm, r.track, 0); pe == .None do frame_samples, _ = opus.packet_samples(p.data)
			}
			if t.codec_delay == 0 do t.codec_delay = i64(h.pre_skip) * 1_000_000_000 / 48000
		}
	case .Vorbis:
		r.codec = .Vorbis
		identification, _, setup, ok := vorbis.split_headers(t.codec_private)
		info, ie := vorbis.read_identification(identification)
		se: vorbis.Error
		shape, se = vorbis.packet_shape(identification, setup)
		if ok && ie == .None && se == .None && info.channels == t.channels {
			r.present = true
			r.config = t.codec_private
			rate = info.rate
			r.sample_rate = rate
		}
	case .AAC:
		r.codec = .AAC
		info, ok := mp4.parse_asc(t.codec_private)
		if ok && info.object_type == 2 && t.channels >= 1 && t.channels <= 8 && info.sample_rate == rate {
			r.present = true
			r.config = t.codec_private
			frame_samples = info.frame_samples
		}
	case .MP3:
		r.codec = .MP3
		r.present = t.channels >= 1 && t.channels <= 2
		frame_samples = rate >= 32000 ? 1152 : 576 // MPEG-1 rates, else MPEG-2/2.5
	case .FLAC:
		r.codec = .FLAC
		if flac_config_ok(t.codec_private, rate, t.channels) {
			r.present = true
			r.config = t.codec_private
			// Fixed-blocking streams place every frame exactly; otherwise the
			// block timestamps do.
			info, _, _ := flac.parse_metadata(t.codec_private)
			if info.min_block == info.max_block do frame_samples = info.max_block
		}
	case .PCM:
		r.codec = .PCM
		f := t.pcm_format
		ok: bool
		r.pcm_sample, ok = common.sample_format(int(f.bits), f.float, f.unsigned, !f.little_endian)
		r.present = ok && t.channels >= 1 && rate > 0
	case:
		r.codec = .Other
	}
	if rate <= 0 {r.present = false; return}
	r.samples = webm.track_end(t) * i64(rate) / 1_000_000_000
	if !r.present do return
	n := len(t.samples)
	r.starts = make([]i64, n)
	frame_bytes := i64(common.SAMPLE_BYTES[r.pcm_sample]) * i64(t.channels)
	position: i64
	previous_block := 0
	for i in 0 ..< n {
		s := t.samples[i]
		stated := (s.pts * i64(rate) + 500_000_000) / 1_000_000_000
		length := i64(frame_samples)
		#partial switch t.codec {
		case .PCM:
			length = (i64(s.size) + i64(len(t.stripped))) / frame_bytes
		case .Vorbis:
			length = 0
			if p, pe := webm.read_sample(&r.webm, r.track, i); pe == .None {
				if size := vorbis.packet_blocksize(shape, p.data); size > 0 {
					length = i64(vorbis.packet_frames(previous_block, size))
					previous_block = size
				}
			}
		}
		if t.codec == .Vorbis {
			// Exact from the block sizes; the first packet returns nothing.
			if i == 0 do position = stated
		} else if i == 0 || length == 0 || abs(stated - position) > max(length, i64(rate) / 100) {
			position = stated
		}
		r.starts[i] = position
		position += length
	}
	// Nanoseconds are not exact sample counts (1024 at 48 kHz is 21333333 ns).
	r.delay = (t.codec_delay * i64(rate) + 500_000_000) / 1_000_000_000
	r.samples = max(position - r.delay - (t.end_discard * i64(rate) + 500_000_000) / 1_000_000_000, 0)
	// FLAC's last frame is shorter than the rest; streaminfo has the count.
	if t.codec == .FLAC {
		if info, _, _ := flac.parse_metadata(t.codec_private); info.total_samples > 0 do r.samples = min(r.samples, info.total_samples)
	}
	r.end = r.samples
}

@(private)
reset :: proc(r: ^Reader, position: i64) -> Error {
	if r.open {destroy_decoder(&r.decoder); r.open = false}
	if r.codec != .PCM {
		if e := init_decoder(&r.decoder, r.codec, r.sample_rate, r.channels, r.config); e != .None {
			r.error_detail = r.decoder.error_detail != "" ? r.decoder.error_detail : "the audio decoder refused the track configuration"
			return e
		}
	}
	r.open = true
	r.next = position
	clear(&r.pcm)
	r.pcm_head = 0
	if r.container == .FLAC {
		r.done = false
		if e := flac.seek(&r.flac_file, position); e != .None do return container_error(e)
		return .None
	}
	// One packet of pre-roll restores the AAC and Vorbis overlap of the
	// target's frame, and covers a FLAC frame placed by a rounded timestamp;
	// MP3 needs the bit reservoir (up to 511 bytes back, 11 of the smallest
	// frames) and the frame before; ALAC frames and PCM chunks start exactly.
	k := packet_at(r, position)
	preroll := r.codec == .AAC || r.codec == .FLAC || r.codec == .Vorbis ? 1 : 0
	if r.codec == .MP3 do preroll = MP3_PREROLL
	if r.codec == .Opus {
		// 80 ms for the decoder to converge (RFC 7845 4.6).
		k = packet_at(r, position - OPUS_PREROLL)
		preroll = 0
	}
	r.cursor = max(k - preroll, 0)
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
exhausted :: proc(r: ^Reader) -> bool {
	return r.container == .FLAC ? r.done : r.cursor >= packet_count(r)
}

@(private)
packet_count :: proc(r: ^Reader) -> int {
	switch r.container {
	case .MP3:
		return len(r.mp3_file.frames)
	case .FLAC:
		return 0 // read frame by frame; see exhausted
	case .WAV:
		return int((r.wave.frames + WAV_PACKET - 1) / WAV_PACKET)
	case .WebM:
		return len(r.webm.tracks[r.track].samples)
	case .Ogg:
		return max(len(r.ogg_file.packets) - r.ogg_headers, 0)
	case .MP4:
	}
	return len(r.demux.tracks[r.track].samples)
}

// Decode-order index of the packet holding PCM index `position`, or -1
// before the first.
@(private)
packet_at :: proc(r: ^Reader, position: i64) -> int {
	switch r.container {
	case .WAV:
		return position < 0 ? -1 : int(position / WAV_PACKET)
	case .MP3:
		at := position + i64(r.mp3_file.tag.delay)
		return at < 0 ? -1 : int(at / i64(r.mp3_file.header.samples))
	case .WebM, .Ogg:
		lo, hi := 0, len(r.starts)
		for lo < hi {
			mid := (lo + hi) / 2
			if r.starts[mid] - r.delay <= position {lo = mid + 1} else {hi = mid}
		}
		return lo - 1
	case .FLAC, .MP4:
	}
	// MP4: the packet presented at the position's time, in presentation order.
	t := &r.demux.tracks[r.track]
	pts := position * i64(t.timescale) / i64(r.sample_rate)
	order := t.presentation
	lo, hi := 0, len(order)
	for lo < hi {
		mid := (lo + hi) / 2
		if t.samples.pts[order[mid]] <= pts {lo = mid + 1} else {hi = mid}
	}
	return lo == 0 ? -1 : int(order[lo - 1])
}

// One packet and the PCM index of its first decoded sample.
@(private)
read_packet :: proc(r: ^Reader, i: int) -> (data: []u8, sample_index: i64, err: Error) {
	switch r.container {
	case .MP3:
		bytes, e := mp3.read_frame(&r.mp3_file, i)
		if e != .None do return nil, 0, container_error(e)
		return bytes, mp3.frame_sample(&r.mp3_file, i), .None
	case .WAV:
		first := i64(i) * WAV_PACKET
		bytes, e := wav.read_frames(&r.wave, first, WAV_PACKET)
		if e != .None do return nil, 0, container_error(e)
		return bytes, first, .None
	case .Ogg:
		bytes, e := ogg.read_packet(&r.ogg_file, r.ogg_headers + i)
		if e != .None do return nil, 0, container_error(e)
		return bytes, r.starts[i] - r.delay, .None
	case .WebM:
		p, e := webm.read_sample(&r.webm, r.track, i)
		if e != .None do return nil, 0, container_error(e)
		return p.data, r.starts[i] - r.delay, .None
	case .FLAC, .MP4:
	}
	t := &r.demux.tracks[r.track]
	p, e := mp4.read_sample(&r.demux, r.track, i)
	if e != .None do return nil, 0, container_error(e)
	return p.data, p.pts * i64(r.sample_rate) / i64(t.timescale), .None
}

@(private)
// A packet's PCM (frames from sample index `first`) into the queue, in WAVE
// order, within the presented range.
on_audio :: proc(r: ^Reader, samples: []f32, first: i64) {
	ch := r.channels
	frames := i64(len(samples) / ch)
	// Time before the track's first sample (an empty edit) reads as silence,
	// so PCM index zero is always time zero.
	gap := min(first, r.end) - r.next
	if gap > 0 {
		resize(&r.pcm, len(r.pcm) + int(gap) * ch)
		r.next += gap
	}
	lo := max(first, r.next)
	hi := min(first + frames, r.end)
	if hi <= lo do return
	start := int(lo - first) * ch
	src := samples[start:][:int(hi - lo) * ch]
	if r.reorder {
		base := len(r.pcm)
		resize(&r.pcm, base + len(src))
		dst := r.pcm[base:]
		for i := 0; i < len(src); i += ch do for k in 0 ..< ch do dst[i + k] = src[i + int(r.order[k])]
	} else {
		append(&r.pcm, ..src)
	}
	r.next = hi
}

@(private)
advance :: proc(r: ^Reader) -> Error {
	if exhausted(r) do return .None
	data: []u8
	sample_index: i64
	if r.container == .FLAC {
		p, e := flac.read_frame(&r.flac_file)
		if e == .End_Of_Stream {r.done = true; return .None}
		if e != .None do return container_error(e)
		data, sample_index = p.data, p.first_sample
	} else {
		data, sample_index = read_packet(r, r.cursor) or_return
		r.cursor += 1
	}
	if r.codec == .PCM {
		ch := r.channels
		resize(&r.pcm_input, len(data) / common.SAMPLE_BYTES[r.pcm_sample])
		frames := common.convert_pcm(data, r.pcm_sample, ch, r.pcm_input[:], ch)
		on_audio(r, r.pcm_input[:frames * ch], sample_index)
		return .None
	}
	pcm, first, e := decode_packet(&r.decoder, data, r.codec == .AAC ? .Raw_AAC : .Frame, sample_index)
	if e != .None {
		r.error_detail = r.decoder.error_detail
		return e
	}
	if len(pcm) > 0 do on_audio(r, pcm, first)
	return .None
}

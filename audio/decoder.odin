package audio

import aac "./aac"
import aacd "./aac/decoder"
import alac "./alac"
import common "../common"
import flac "./flac"
import mp3 "./mp3"
import opus "./opus"
import vorbis "./vorbis"

_ :: common // used by decode_packet's i16 instances

// The audio codecs' packet decoding, the one implementation: Reader decodes
// through it, and so does media's native provider. A packet's PCM goes into
// the caller's buffer, interleaved at the decoder's channel count, with the
// sample index of its first frame.
Decoder :: struct {
	codec:        Codec,
	sample_rate:  int,
	channels:     int,
	error_detail: string,
	max_frames:   int, // the most frames a packet decodes to (an output reservation)
	next:         i64, // where an untimed packet's output starts
	pcm:          [dynamic]f32, // the lossy codecs' f32 output, read as i16
	aac:          ^aacd.Decoder,
	flac:         ^flac.Decoder,
	mp3:          ^mp3.Decoder,
	opus:         ^opus.Multistream,
	alac:         ^alac.Decoder,
	vorbis:       ^vorbis.Decoder,
}

// How a packet's bytes are framed; AAC alone has more than one form.
Framing :: enum {
	Frame, // one codec frame or packet
	Raw_AAC, // raw AAC access units
	ADTS,
	LOAS,
}

// A packet without a position continues from the previous one (FLAC: from
// its frame header).
UNTIMED :: min(i64)

// Whether a decoder takes this configuration: the extradata is AAC's
// AudioSpecificConfig, FLAC's metadata, Opus's OpusHead, ALAC's
// ALACSpecificConfig or Vorbis' three headers Xiph-laced. frame_samples is
// AAC's frame length when there is no AudioSpecificConfig (0: 1024).
check_config :: proc(codec: Codec, sample_rate, channels: int, extradata: []u8, frame_samples := 0) -> Error {
	#partial switch codec {
	case .AAC:
		_, e := aac_config(sample_rate, channels, extradata, frame_samples)
		#partial switch e {
		case .None:
			return .None
		case .Unsupported_Profile, .Unsupported_Channels, .Unsupported_Tool, .Unsupported_Transport:
			return .Unsupported
		}
		return .Invalid_Config
	case .FLAC:
		info, _, e := flac.parse_metadata(extradata)
		if e != .None || info.sample_rate != sample_rate || info.channels != channels do return .Invalid_Config
	case .MP3:
	case .Opus:
		h, e := opus.parse_head(extradata)
		if e == .Unsupported do return .Unsupported // ambisonics with a demixing matrix
		if e != .None || h.channels != channels do return .Invalid_Config
	case .ALAC:
		cfg, e := alac.parse_config(extradata)
		if e == .Unsupported do return .Unsupported
		if e != .None || cfg.sample_rate != sample_rate || cfg.channels != channels do return .Invalid_Config
	case .Vorbis:
		identification, _, _, ok := vorbis.split_headers(extradata)
		info, e := vorbis.read_identification(identification)
		if !ok || e != .None || info.channels != channels || info.rate != sample_rate do return .Invalid_Config
	case:
		return .Unsupported
	}
	return .None
}

@(private)
aac_config :: proc(sample_rate, channels: int, extradata: []u8, frame_samples: int) -> (cfg: aac.Config, err: aac.Error) {
	cfg = {sample_rate = sample_rate, channels = channels, frame_samples = frame_samples}
	if len(extradata) != 0 {
		parsed := aac.parse_audio_specific_config(extradata) or_return
		if parsed.sample_rate != cfg.sample_rate || parsed.channels != cfg.channels || aac.resolved_frame_samples(parsed) != aac.resolved_frame_samples(cfg) do return {}, .Invalid_Config
		cfg = parsed
	}
	return cfg, aac.validate_config(cfg)
}

init_decoder :: proc(d: ^Decoder, codec: Codec, sample_rate, channels: int, extradata: []u8, frame_samples := 0) -> (err: Error) {
	d^ = {codec = codec, sample_rate = sample_rate, channels = channels}
	defer if err != .None do destroy_decoder(d)
	check_config(codec, sample_rate, channels, extradata, frame_samples) or_return
	#partial switch codec {
	case .AAC:
		cfg, _ := aac_config(sample_rate, channels, extradata, frame_samples)
		d.aac = new(aacd.Decoder)
		if d.aac == nil do return .Out_Of_Memory
		if aacd.init_decoder(d.aac, cfg) != .None do return .Invalid_Config
		// An access unit carries up to 64 frames (LATM).
		d.max_frames = 64 * d.aac.frame_samples
		d.next = -i64(d.aac.frame_samples) // AAC's first frame primes the overlap
	case .FLAC:
		info, _, _ := flac.parse_metadata(extradata)
		d.flac = new(flac.Decoder)
		flac.init_decoder(d.flac, info)
		d.max_frames = max(info.max_block, 4096)
	case .MP3:
		d.mp3 = new(mp3.Decoder)
		d.max_frames = 1152
	case .Opus:
		h, _ := opus.parse_head(extradata)
		d.opus = new(opus.Multistream)
		if opus.init_multistream(d.opus, h) != .None do return .Invalid_Config
		d.max_frames = opus.MAX_FRAME_SAMPLES
	case .ALAC:
		cfg, _ := alac.parse_config(extradata)
		d.alac = new(alac.Decoder)
		if alac.init_decoder(d.alac, cfg) != .None do return .Invalid_Config
		d.max_frames = cfg.frame_length
	case .Vorbis:
		identification, _, setup, _ := vorbis.split_headers(extradata)
		d.vorbis = new(vorbis.Decoder)
		switch vorbis.init_decoder(d.vorbis, identification, setup) {
		case .None:
		case .Unsupported:
			d.error_detail = "Vorbis floor type 0 is not supported"
			return .Unsupported
		case .Invalid, .Out_Of_Memory:
			return .Invalid_Config
		}
		d.max_frames = vorbis.max_frames(d.vorbis)
	}
	return .None
}

destroy_decoder :: proc(d: ^Decoder) {
	if d.aac != nil do free(d.aac)
	if d.flac != nil {flac.destroy_decoder(d.flac); free(d.flac)}
	if d.mp3 != nil do free(d.mp3)
	if d.opus != nil {opus.destroy_multistream(d.opus); free(d.opus)}
	if d.alac != nil {alac.destroy_decoder(d.alac); free(d.alac)}
	if d.vorbis != nil {vorbis.destroy_decoder(d.vorbis); free(d.vorbis)}
	delete(d.pcm)
	d^ = {}
}

// Decodes one packet into out, interleaved at the decoder's channel count,
// as f32 or i16 (empty for a packet that only primes), and returns the
// sample index of its first frame (sample_index, or following on from the
// previous packet when UNTIMED). out is the caller's, reserved for
// max_frames * channels; it grows only for a packet holding more. FLAC and
// ALAC convert their integer samples to either type directly (exact for
// f32, common.scale_i16 for i16); the lossy codecs decode f32, which i16
// rounds with common.to_i16.
decode_packet :: proc(d: ^Decoder, data: []u8, framing: Framing, out: ^[dynamic]$T, sample_index: i64 = UNTIMED) -> (first: i64, err: Error) where T == f32 || T == i16 {
	clear(out)
	if sample_index != UNTIMED do d.next = sample_index
	first = d.next
	if d.codec != .AAC && framing != .Frame do return first, .Invalid_Input
	ch := d.channels
	// The lossy codecs' output: out itself for f32, else scratch converted at the end.
	floats: ^[dynamic]f32
	when T == f32 {
		floats = out
	} else {
		floats = &d.pcm
		clear(floats)
	}
	#partial switch d.codec {
	case .AAC:
		n := d.aac.frame_samples
		for pos := 0; pos < len(data); {
			// Room for the largest access unit: 64 frames (LATM).
			at := len(floats)
			if non_zero_resize(floats, at + 64 * n * ch) != nil do return first, .Out_Of_Memory
			consumed, samples: int
			e: aac.Error
			dst := floats[at:]
			switch framing {
			case .ADTS:
				consumed, samples, e = aacd.decode_adts_frame(d.aac, data[pos:], dst)
			case .LOAS:
				consumed, samples, e = aacd.decode_loas_frame(d.aac, data[pos:], dst)
			case .Raw_AAC:
				consumed, samples, e = aacd.decode_frame_prefix(d.aac, data[pos:], dst)
			case .Frame:
				return first, .Invalid_Input
			}
			if e != .None do return first, aac_error(d, e)
			if consumed <= 0 || consumed > len(data) - pos || samples <= 0 || samples % n != 0 || samples > len(dst) / ch do return first, .Codec_Error
			non_zero_resize(floats, at + samples * ch)
			pos += consumed
		}
	case .FLAC:
		f, _, e := flac.decode_frame(d.flac, data)
		#partial switch e {
		case .None:
		case .Out_Of_Memory:
			d.error_detail = "FLAC frame allocation failed"
			return first, .Codec_Error
		case:
			d.error_detail = "invalid FLAC frame"
			return first, .Invalid_Input
		}
		h := f.header
		if h.channels != ch || h.sample_rate != d.sample_rate {
			d.error_detail = "FLAC frame changes the channel count or sample rate"
			return first, .Unsupported
		}
		non_zero_resize(out, h.block_size * ch)
		flac.interleave(f, out[:])
		if sample_index == UNTIMED do first = flac.first_sample(h, d.flac.info)
		d.next = first + i64(h.block_size)
		return first, .None
	case .MP3:
		// At the decoder's channel count: a stream may switch between mono and
		// stereo frames. A frame whose main data began in bytes not given (after
		// a seek) decodes as silence, so the timeline stays intact.
		f, e := mp3.decode_frame(d.mp3, data)
		#partial switch e {
		case .None:
		case .Unsupported:
			d.error_detail = "MP3 frame uses unsupported syntax (Layer I/II or free format)"
			return first, .Unsupported
		case:
			d.error_detail = "invalid MP3 frame"
			return first, .Invalid_Input
		}
		h := f.header
		if h.sample_rate != d.sample_rate {
			d.error_detail = "MP3 frame changes the sample rate"
			return first, .Unsupported
		}
		n := h.samples
		non_zero_resize(floats, n * ch)
		switch {
		case h.channels == ch:
			for c in 0 ..< ch do for x, i in f.pcm[c] do floats[i * ch + c] = x
		case h.channels == 1:
			for x, i in f.pcm[0] do floats[i * 2], floats[i * 2 + 1] = x, x
		case:
			for i in 0 ..< n do floats[i] = 0.5 * (f.pcm[0][i] + f.pcm[1][i])
		}
	case .Opus:
		non_zero_resize(floats, opus.MAX_FRAME_SAMPLES * ch)
		n, e := opus.decode_multistream(d.opus, data, floats[:])
		if e != .None {
			d.error_detail = "invalid Opus packet"
			return first, .Invalid_Input
		}
		non_zero_resize(floats, n * ch)
	case .ALAC:
		f, e := alac.decode_frame(d.alac, data)
		switch e {
		case .None:
		case .Unsupported:
			d.error_detail = "ALAC packet uses unsupported syntax"
			return first, .Unsupported
		case .Out_Of_Memory:
			return first, .Codec_Error
		case .Invalid_Data:
			d.error_detail = "invalid ALAC packet"
			return first, .Invalid_Input
		}
		non_zero_resize(out, f.samples * f.channels)
		alac.interleave(f, out[:])
		d.next = first + i64(f.samples)
		return first, .None
	case .Vorbis:
		// The first packet returns nothing: it primes the overlap.
		non_zero_resize(floats, vorbis.max_frames(d.vorbis) * ch)
		n, e := vorbis.decode_packet(d.vorbis, data, floats[:])
		if e != .None {
			d.error_detail = "invalid Vorbis packet"
			return first, .Invalid_Input
		}
		non_zero_resize(floats, n * ch)
	case:
		return first, .Unsupported
	}
	when T == i16 {
		non_zero_resize(out, len(floats))
		for x, i in floats do out[i] = common.to_i16(x)
	}
	d.next = first + i64(len(floats) / ch)
	return first, .None
}

@(private)
aac_error :: proc(d: ^Decoder, e: aac.Error) -> Error {
	switch e {
	case .None:
		return .None
	case .Unsupported_Profile:
		d.error_detail = "AAC profile is unsupported"; return .Unsupported
	case .Unsupported_Channels:
		d.error_detail = "AAC channels are unsupported"; return .Unsupported
	case .Unsupported_Transport:
		d.error_detail = "AAC transport is unsupported"; return .Unsupported
	case .Unsupported_Tool:
		d.error_detail = "AAC coding tool is unsupported"; return .Unsupported
	case .Truncated:
		d.error_detail = "AAC input is truncated"; return .Invalid_Input
	case .Invalid_Data:
		d.error_detail = "AAC input is malformed"; return .Invalid_Input
	case .Crc_Mismatch:
		d.error_detail = "AAC integrity check failed"; return .Invalid_Input
	case .Allocation_Failed:
		d.error_detail = "AAC output allocation failed"; return .Codec_Error
	case .Invalid_Config:
		d.error_detail = "AAC configuration does not match the input"; return .Invalid_Input
	case .Output_Too_Small:
		d.error_detail = "AAC output buffer is too small"; return .Invalid_Input
	case .Invalid_State:
		d.error_detail = "AAC codec state is invalid"; return .Codec_Error
	}
	return .Codec_Error
}

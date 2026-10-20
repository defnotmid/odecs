package audio

import aac "../aac"
import aacd "../aac/decoder"
import alac "../alac"
import flac "../flac"
import mp3 "../mp3"
import opus "../opus"
import vorbis "../vorbis"

// The audio codecs' packet decoding, the one implementation: Reader decodes
// through it, and so does media's native provider. A packet's PCM comes back
// interleaved at the decoder's channel count, borrowed until the next call,
// with the sample index of its first frame.
Decoder :: struct {
	codec:        Codec,
	sample_rate:  int,
	channels:     int,
	error_detail: string,
	next:         i64, // where an untimed packet's output starts
	pcm:          [dynamic]f32,
	frame:        []f32, // AAC: one access unit's output
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
		// An access unit can carry several frames (LATM); a packet's frames are
		// decoded one after another into this buffer.
		d.frame = make([]f32, 8 * 1024 * 64)
		if d.frame == nil do return .Out_Of_Memory
		d.next = -i64(d.aac.frame_samples) // AAC's first frame primes the overlap
	case .FLAC:
		info, _, _ := flac.parse_metadata(extradata)
		d.flac = new(flac.Decoder)
		flac.init_decoder(d.flac, info)
		reserve(&d.pcm, max(info.max_block, 4096) * channels)
	case .MP3:
		d.mp3 = new(mp3.Decoder)
		reserve(&d.pcm, 1152 * channels)
	case .Opus:
		h, _ := opus.parse_head(extradata)
		d.opus = new(opus.Multistream)
		if opus.init_multistream(d.opus, h) != .None do return .Invalid_Config
		reserve(&d.pcm, opus.MAX_FRAME_SAMPLES * channels)
	case .ALAC:
		cfg, _ := alac.parse_config(extradata)
		d.alac = new(alac.Decoder)
		if alac.init_decoder(d.alac, cfg) != .None do return .Invalid_Config
		reserve(&d.pcm, cfg.frame_length * channels)
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
		reserve(&d.pcm, vorbis.max_frames(d.vorbis) * channels)
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
	delete(d.frame)
	d^ = {}
}

// Decodes one packet: its PCM, interleaved and borrowed until the next call
// (empty for a packet that only primes), and the sample index of its first
// frame (sample_index, or following on from the previous packet when
// UNTIMED).
decode_packet :: proc(d: ^Decoder, data: []u8, framing: Framing, sample_index: i64 = UNTIMED) -> (pcm: []f32, first: i64, err: Error) {
	clear(&d.pcm)
	if sample_index != UNTIMED do d.next = sample_index
	first = d.next
	if d.codec != .AAC && framing != .Frame do return nil, first, .Invalid_Input
	ch := d.channels
	#partial switch d.codec {
	case .AAC:
		pos, out := 0, 0 // bytes read, frames decoded
		n := d.aac.frame_samples
		for pos < len(data) {
			// Room for the largest access unit; a packet of very many grows it.
			if len(d.frame) - out * ch < 64 * n * ch {
				grown := make([]f32, 2 * len(d.frame))
				if grown == nil do return nil, first, .Out_Of_Memory
				copy(grown, d.frame[:out * ch])
				delete(d.frame)
				d.frame = grown
			}
			consumed, samples: int
			e: aac.Error
			dst := d.frame[out * ch:]
			switch framing {
			case .ADTS:
				consumed, samples, e = aacd.decode_adts_frame(d.aac, data[pos:], dst)
			case .LOAS:
				consumed, samples, e = aacd.decode_loas_frame(d.aac, data[pos:], dst)
			case .Raw_AAC:
				consumed, samples, e = aacd.decode_frame_prefix(d.aac, data[pos:], dst)
			case .Frame:
				return nil, first, .Invalid_Input
			}
			if e != .None do return nil, first, aac_error(d, e)
			if consumed <= 0 || consumed > len(data) - pos || samples <= 0 || samples % n != 0 || samples > len(dst) / ch do return nil, first, .Codec_Error
			out += samples
			pos += consumed
		}
		d.next = first + i64(out)
		return d.frame[:out * ch], first, .None
	case .FLAC:
		f, _, e := flac.decode_frame(d.flac, data)
		#partial switch e {
		case .None:
		case .Out_Of_Memory:
			d.error_detail = "FLAC frame allocation failed"
			return nil, first, .Codec_Error
		case:
			d.error_detail = "invalid FLAC frame"
			return nil, first, .Invalid_Input
		}
		h := f.header
		if h.channels != ch || h.sample_rate != d.sample_rate {
			d.error_detail = "FLAC frame changes the channel count or sample rate"
			return nil, first, .Unsupported
		}
		resize(&d.pcm, h.block_size * ch)
		flac.interleave_f32(f, d.pcm[:])
		if sample_index == UNTIMED do first = flac.first_sample(h, d.flac.info)
		d.next = first
	case .MP3:
		// At the decoder's channel count: a stream may switch between mono and
		// stereo frames. A frame whose main data began in bytes not given (after
		// a seek) decodes as silence, so the timeline stays intact.
		f, e := mp3.decode_frame(d.mp3, data)
		#partial switch e {
		case .None:
		case .Unsupported:
			d.error_detail = "MP3 frame uses unsupported syntax (Layer I/II or free format)"
			return nil, first, .Unsupported
		case:
			d.error_detail = "invalid MP3 frame"
			return nil, first, .Invalid_Input
		}
		h := f.header
		if h.sample_rate != d.sample_rate {
			d.error_detail = "MP3 frame changes the sample rate"
			return nil, first, .Unsupported
		}
		n := h.samples
		resize(&d.pcm, n * ch)
		switch {
		case h.channels == ch:
			for c in 0 ..< ch do for x, i in f.pcm[c] do d.pcm[i * ch + c] = x
		case h.channels == 1:
			for x, i in f.pcm[0] do d.pcm[i * 2], d.pcm[i * 2 + 1] = x, x
		case:
			for i in 0 ..< n do d.pcm[i] = 0.5 * (f.pcm[0][i] + f.pcm[1][i])
		}
	case .Opus:
		resize(&d.pcm, opus.MAX_FRAME_SAMPLES * ch)
		n, e := opus.decode_multistream(d.opus, data, d.pcm[:])
		if e != .None {
			d.error_detail = "invalid Opus packet"
			return nil, first, .Invalid_Input
		}
		resize(&d.pcm, n * ch)
	case .ALAC:
		f, e := alac.decode_frame(d.alac, data)
		switch e {
		case .None:
		case .Unsupported:
			d.error_detail = "ALAC packet uses unsupported syntax"
			return nil, first, .Unsupported
		case .Out_Of_Memory:
			return nil, first, .Codec_Error
		case .Invalid_Data:
			d.error_detail = "invalid ALAC packet"
			return nil, first, .Invalid_Input
		}
		resize(&d.pcm, f.samples * f.channels)
		alac.interleave_f32(f, d.pcm[:])
	case .Vorbis:
		// The first packet returns nothing: it primes the overlap.
		resize(&d.pcm, vorbis.max_frames(d.vorbis) * ch)
		n, e := vorbis.decode_packet(d.vorbis, data, d.pcm[:])
		if e != .None {
			d.error_detail = "invalid Vorbis packet"
			return nil, first, .Invalid_Input
		}
		resize(&d.pcm, n * ch)
	case:
		return nil, first, .Unsupported
	}
	d.next = first + i64(len(d.pcm) / ch)
	return d.pcm[:], first, .None
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

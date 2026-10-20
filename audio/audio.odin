// The suite's one audio path: the container from the first bytes (MP4/M4A/
// MOV, WebM/Matroska, WAV, FLAC, MP3, Ogg), the first audio track decoded
// (AAC-LC, PCM, FLAC, MP3, Opus, ALAC, Vorbis) to interleaved f32 at the
// file's own rate and channel count. Reader reads and seeks; decode reads a
// whole file in memory. Mixing down and resampling are the caller's.
package audio

import media "../media"
import ogg "../ogg"
import "base:intrinsics"
import "core:bytes"

Error :: enum {
	None,
	Invalid_Config,
	Invalid_Input,
	Unsupported,
	Invalid_Data,
	IO_Error,
	Out_Of_Memory,
	Codec_Error,
	End_Of_Stream,
	Closed,
}

// Decoded audio: frames * channels samples, interleaved.
Audio :: struct {
	rate, channels: int,
	samples:        []f32,
}

// The most samples decode returns (4 GiB of f32, three hours of 48 kHz 5.1):
// a few bytes of a stream can claim far more.
MAX_SAMPLES :: 1 << 30

// The first audio track of a file in memory.
info :: proc(data: []u8) -> (i: Info, err: Error) {
	reader: bytes.Reader
	bytes.reader_init(&reader, data)
	r: Reader
	open_stream(&r, bytes.reader_to_stream(&reader)) or_return
	defer close(&r)
	return r.info, r.track < 0 ? .Unsupported : .None
}

// The first audio track of a file in memory, whole: its sample count is
// known at open, so the output is allocated once and filled.
decode :: proc(data: []u8, allocator := context.allocator) -> (a: Audio, err: Error) {
	reader: bytes.Reader
	bytes.reader_init(&reader, data)
	r: Reader
	open_stream(&r, bytes.reader_to_stream(&reader)) or_return
	defer close(&r)
	if !r.present do return a, .Unsupported
	total := int(r.samples) * r.channels
	if total > MAX_SAMPLES do return a, .Unsupported
	samples, aerr := make([]f32, total, allocator)
	if aerr != nil do return a, .Out_Of_Memory
	got := 0
	for got < int(r.samples) {
		n, e := read(&r, samples[got * r.channels:])
		got += n
		if e == .End_Of_Stream do break
		if e != .None {
			delete(samples, allocator)
			return a, e
		}
	}
	return {rate = r.sample_rate, channels = r.channels, samples = samples[:got * r.channels]}, .None
}

destroy_audio :: proc(a: ^Audio, allocator := context.allocator) {
	delete(a.samples, allocator)
	a^ = {}
}

// A container reader's error: every container names them alike (Ogg has no
// Unsupported).
@(private)
container_error :: proc(e: $E) -> Error where intrinsics.type_is_enum(E) {
	when E != ogg.Error {
		if e == .Unsupported do return .Unsupported
	}
	#partial switch e {
	case .None:
		return .None
	case .Invalid_Argument:
		return .Invalid_Input
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

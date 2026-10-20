// The suite's one audio path: the format from the first bytes, decoded to
// interleaved f32 at the file's own rate and channel count. Mixing down,
// resampling and trimming are the caller's.
package audio

Format :: enum {
	Unknown,
	Vorbis, // Ogg Vorbis
}

Error :: enum {
	None,
	Unsupported, // not audio this package decodes
	Invalid,     // malformed or truncated
	Out_Of_Memory,
}

// The most samples decode returns (4 GiB of f32, three hours of 48 kHz 5.1):
// a few bytes of a stream can claim far more.
MAX_SAMPLES :: 1 << 30

// Decoded audio: frames * channels samples, interleaved.
Audio :: struct {
	rate, channels: int,
	samples:        []f32,
}

// The format from the file's first bytes, not its name.
format_of :: proc(data: []u8) -> Format {
	if len(data) >= 36 && string(data[:4]) == "OggS" && string(data[29:35]) == "vorbis" do return .Vorbis
	return .Unknown
}

decode :: proc(data: []u8, allocator := context.allocator) -> (a: Audio, err: Error) {
	switch format_of(data) {
	case .Vorbis:
		return decode_vorbis(data, allocator)
	case .Unknown:
	}
	return a, .Unsupported
}

destroy_audio :: proc(a: ^Audio, allocator := context.allocator) {
	delete(a.samples, allocator)
	a^ = {}
}

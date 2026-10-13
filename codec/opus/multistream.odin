package opus

// Multistream decoding (RFC 7845 5.1.1, RFC 6716 Appendix B): a packet
// holds one packet per stream, every one but the last self-delimited; the
// first `coupled` streams are stereo, the rest mono, and the channel
// mapping places each output channel on a stream's channel (or mutes it).

Multistream :: struct {
	channels: int, // output channels
	decoders: []Decoder, // by stream
	source:   [255]Channel_Source, // by output channel
	buf:      [MAX_FRAME_SAMPLES * 2]f32, // one stream's decoded packet
}

@(private)
Channel_Source :: struct {
	stream:  i16, // -1: muted
	channel: i16,
}

// A decoder for the streams and mapping of an identification header.
init_multistream :: proc(m: ^Multistream, h: Head, allocator := context.allocator) -> Error {
	if h.streams < 1 || h.coupled > h.streams || h.channels < 1 do return .Invalid_Packet
	m.channels = h.channels
	m.decoders = make([]Decoder, h.streams, allocator)
	for &d, s in m.decoders do init_decoder(&d, s < h.coupled ? 2 : 1, h.gain)
	for c in 0 ..< h.channels {
		i := int(h.mapping[c])
		switch {
		case i == 255:
			m.source[c] = {-1, 0}
		case i < 2 * h.coupled:
			m.source[c] = {i16(i / 2), i16(i & 1)}
		case:
			m.source[c] = {i16(i - h.coupled), 0}
		}
	}
	return .None
}

destroy_multistream :: proc(m: ^Multistream, allocator := context.allocator) {
	delete(m.decoders, allocator)
	m.decoders = nil
}

// Decodes a multistream packet into pcm (interleaved output channels) and
// returns the samples per channel.
decode_multistream :: proc(m: ^Multistream, data: []u8, pcm: []f32) -> (samples: int, err: Error) {
	n := len(m.decoders)
	if len(data) < 2 * n - 1 do return 0, .Invalid_Packet
	// The streams' packets must all parse and agree on the duration before
	// any decoder state changes.
	rest := data
	for s in 0 ..< n {
		if len(rest) == 0 do return 0, .Invalid_Packet
		p := parse_packet(rest, s != n - 1) or_return
		duration := p.count * p.frame_samples
		if s > 0 && duration != samples do return 0, .Invalid_Packet
		samples = duration
		rest = rest[p.length:]
	}
	if len(pcm) < samples * m.channels do return 0, .Buffer_Too_Small
	rest = data
	for &d, s in m.decoders {
		p, _ := parse_packet(rest, s != n - 1)
		rest = rest[p.length:]
		decode_parsed(&d, &p, m.buf[:]) or_return
		scatter(m, s, samples, pcm)
	}
	mute(m, samples, pcm)
	return samples, .None
}

// Recovers `samples` lost samples per channel from the multistream packet
// after the gap, each stream as decode_fec does.
decode_multistream_fec :: proc(m: ^Multistream, next: []u8, samples: int, pcm: []f32) -> Error {
	n := len(m.decoders)
	if samples > MAX_FRAME_SAMPLES do return .Invalid_Packet
	if len(next) < 2 * n - 1 do return .Invalid_Packet
	if len(pcm) < samples * m.channels do return .Buffer_Too_Small
	rest := next
	for s in 0 ..< n {
		if len(rest) == 0 do return .Invalid_Packet
		p := parse_packet(rest, s != n - 1) or_return
		rest = rest[p.length:]
	}
	rest = next
	for &d, s in m.decoders {
		p, _ := parse_packet(rest, s != n - 1)
		rest = rest[p.length:]
		decode_fec_parsed(&d, &p, samples, m.buf[:]) or_return
		scatter(m, s, samples, pcm)
	}
	mute(m, samples, pcm)
	return .None
}

// Conceals `samples` lost samples per channel (a multiple of 120) in every
// stream.
decode_multistream_lost :: proc(m: ^Multistream, samples: int, pcm: []f32) -> Error {
	if samples > MAX_FRAME_SAMPLES do return .Invalid_Packet
	if len(pcm) < samples * m.channels do return .Buffer_Too_Small
	for &d, s in m.decoders {
		decode_lost(&d, samples, m.buf[:]) or_return
		scatter(m, s, samples, pcm)
	}
	mute(m, samples, pcm)
	return .None
}

// Stream s's channels (in m.buf) to the output channels mapped to them.
@(private)
scatter :: proc(m: ^Multistream, s, samples: int, pcm: []f32) {
	width := m.decoders[s].channels
	for src, c in m.source[:m.channels] {
		if int(src.stream) != s do continue
		from := m.buf[src.channel:]
		#no_bounds_check for i in 0 ..< samples do pcm[i * m.channels + c] = from[i * width]
	}
}

@(private)
mute :: proc(m: ^Multistream, samples: int, pcm: []f32) {
	for src, c in m.source[:m.channels] {
		if src.stream < 0 do for i in 0 ..< samples do pcm[i * m.channels + c] = 0
	}
}

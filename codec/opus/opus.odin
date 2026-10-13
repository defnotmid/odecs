// Opus (RFC 6716, with the RFC 8251 updates) decoding at 48 kHz: SILK,
// CELT and hybrid frames, mode switches with and without redundancy, and
// concealment of lost packets and DTX.
//
// The decoder is a restructured port of libopus 1.6.1 (BSD-3-Clause;
// copyright and conditions in LICENSE-libopus.txt), written to RFC 6716's
// description; tables.odin and silk_tables.odin are copied from it by
// tools/tables.
package opus

import "core:math"

Error :: enum {
	None,
	Invalid_Packet,
	Unsupported,
	Buffer_Too_Small,
}

Mode :: enum u8 {
	SILK,
	Hybrid,
	CELT,
}

Bandwidth :: enum u8 {
	Narrow, // 4 kHz
	Medium, // 6 kHz
	Wide, // 8 kHz
	Super_Wide, // 12 kHz
	Full, // 20 kHz
}

// A packet's table of contents and frames (RFC 6716 3.1, 3.2).
Packet :: struct {
	mode:          Mode,
	bandwidth:     Bandwidth,
	stereo:        bool,
	frame_samples: int, // per frame, at 48 kHz
	count:         int,
	frames:        [48][]u8,
	length:        int, // bytes of data the packet takes, padding included
}

MAX_FRAME_SAMPLES :: 5760 // 120 ms at 48 kHz: the most one packet holds

// Parses a packet; a self-delimited one (RFC 6716 Appendix B: all but the
// last stream of a multistream packet) codes its last frame's size too,
// and is followed by the next.
parse_packet :: proc(data: []u8, self_delimited := false) -> (p: Packet, err: Error) {
	if len(data) < 1 do return p, .Invalid_Packet
	toc := data[0]
	config := toc >> 3
	switch {
	case config < 12:
		p.mode = .SILK
		p.bandwidth = Bandwidth(config >> 2)
		p.frame_samples = config & 3 == 3 ? 2880 : 480 << (config & 3) // 10, 20, 40, 60 ms
	case config < 16:
		p.mode = .Hybrid
		p.bandwidth = config < 14 ? .Super_Wide : .Full
		p.frame_samples = config & 1 != 0 ? 960 : 480
	case:
		p.mode = .CELT
		b := (config - 16) >> 2
		p.bandwidth = b == 0 ? .Narrow : Bandwidth(b + 1)
		p.frame_samples = 120 << (config & 3)
	}
	p.stereo = toc & 4 != 0
	rest := data[1:]
	size_of :: proc(d: []u8) -> (size, used: int, ok: bool) {
		if len(d) < 1 do return
		if d[0] < 252 do return int(d[0]), 1, true
		if len(d) < 2 do return
		return 4 * int(d[1]) + int(d[0]), 2, true
	}
	// Frame sizes, the last one implicit unless self-delimited.
	sizes: [48]int
	cbr := false
	padding := 0
	switch toc & 3 {
	case 0:
		p.count = 1
	case 1:
		p.count, cbr = 2, true
	case 2:
		p.count = 2
		size, used, ok := size_of(rest)
		if !ok || size > len(rest) - used do return p, .Invalid_Packet
		sizes[0] = size
		rest = rest[used:]
	case 3:
		if len(rest) < 1 do return p, .Invalid_Packet
		ch := rest[0]
		rest = rest[1:]
		p.count = int(ch & 0x3F)
		if p.count == 0 || p.frame_samples * p.count > MAX_FRAME_SAMPLES do return p, .Invalid_Packet
		if ch & 0x40 != 0 {
			for {
				if len(rest) < 1 do return p, .Invalid_Packet
				b := int(rest[0])
				rest = rest[1:]
				padding += b == 255 ? 254 : b
				if b != 255 do break
			}
		}
		if padding > len(rest) do return p, .Invalid_Packet
		cbr = ch & 0x80 == 0
		if !cbr {
			total := 0
			for i in 0 ..< p.count - 1 {
				size, used, ok := size_of(rest[:len(rest) - padding])
				if !ok do return p, .Invalid_Packet
				rest = rest[used:]
				sizes[i] = size
				total += size
			}
			if total > len(rest) - padding do return p, .Invalid_Packet
		}
	}
	body := len(rest) - padding // frames, and what follows a self-delimited packet
	explicit := 0
	for i in 0 ..< p.count - 1 do explicit += sizes[i]
	if self_delimited {
		size, used, ok := size_of(rest[:body])
		if !ok || size > body - used do return p, .Invalid_Packet
		rest = rest[used:]
		body -= used
		if cbr {
			if size * p.count > body do return p, .Invalid_Packet
			for i in 0 ..< p.count do sizes[i] = size
		} else {
			if explicit + size > body do return p, .Invalid_Packet
			sizes[p.count - 1] = size
		}
	} else if cbr {
		if body % p.count != 0 do return p, .Invalid_Packet
		for i in 0 ..< p.count do sizes[i] = body / p.count
	} else {
		sizes[p.count - 1] = body - explicit
	}
	at := 0
	for i in 0 ..< p.count {
		if sizes[i] > 1275 do return p, .Invalid_Packet
		p.frames[i] = rest[at:][:sizes[i]]
		at += sizes[i]
	}
	p.length = len(data) - len(rest) + at + padding
	return p, .None
}

// The identification header of Ogg Opus (RFC 7845 5.1), also Matroska's
// CodecPrivate.
Head :: struct {
	channels:       int,
	pre_skip:       int, // samples at 48 kHz to discard at the start
	input_rate:     int, // the original rate, informational
	gain:           i16, // output gain, Q7.8 dB
	mapping_family: int,
	streams:        int,
	coupled:        int,
	mapping:        [255]u8,
}

parse_head :: proc(data: []u8) -> (h: Head, err: Error) {
	if len(data) < 19 || string(data[:8]) != "OpusHead" || data[8] >> 4 != 0 do return h, .Invalid_Packet
	h.channels = int(data[9])
	h.pre_skip = int(data[10]) | int(data[11]) << 8
	h.input_rate = int(data[12]) | int(data[13]) << 8 | int(data[14]) << 16 | int(data[15]) << 24
	h.gain = i16(u16(data[16]) | u16(data[17]) << 8)
	h.mapping_family = int(data[18])
	if h.channels == 0 do return h, .Invalid_Packet
	if h.mapping_family == 0 {
		if h.channels > 2 do return h, .Invalid_Packet
		h.streams, h.coupled = 1, h.channels - 1
		h.mapping[0], h.mapping[1] = 0, 1
		return h, .None
	}
	// Family 1 is the Vorbis channel order for 1 to 8 channels, 255 any
	// layout, 2 ambisonics as plain streams; 3 needs a demixing matrix.
	switch h.mapping_family {
	case 1:
		if h.channels > 8 do return h, .Invalid_Packet
	case 2, 255:
	case:
		return h, .Unsupported
	}
	if len(data) < 21 + h.channels do return h, .Invalid_Packet
	h.streams, h.coupled = int(data[19]), int(data[20])
	if h.streams == 0 || h.coupled > h.streams || h.streams + h.coupled > 255 do return h, .Invalid_Packet
	copy(h.mapping[:h.channels], data[21:][:h.channels])
	for i in h.mapping[:h.channels] do if int(i) >= h.streams + h.coupled && i != 255 do return h, .Invalid_Packet
	return h, .None
}

// Samples per channel at 48 kHz in a packet, from its TOC.
packet_samples :: proc(data: []u8) -> (samples: int, err: Error) {
	if len(data) < 1 do return 0, .Invalid_Packet
	config := data[0] >> 3
	frame: int
	switch {
	case config < 12:
		frame = config & 3 == 3 ? 2880 : 480 << (config & 3)
	case config < 16:
		frame = config & 1 != 0 ? 960 : 480
	case:
		frame = 120 << (config & 3)
	}
	count := 1
	switch data[0] & 3 {
	case 1, 2:
		count = 2
	case 3:
		if len(data) < 2 do return 0, .Invalid_Packet
		count = int(data[1] & 0x3F)
	}
	if count == 0 || count * frame > MAX_FRAME_SAMPLES do return 0, .Invalid_Packet
	return count * frame, .None
}

// One Opus stream: its SILK and CELT states and what carries between
// packets.
Decoder :: struct {
	gain:            f32, // linear output gain from the header
	channels:        int,
	celt:            Celt,
	silk:            Silk,
	prev_mode:       Mode,
	have_prev:       bool,
	prev_redundancy: bool, // the last frame ended in CELT redundancy
	frame_samples:   int, // of the last packet: the most a lost frame conceals
	packet_celt:     bool, // the last packet was CELT: no error correction follows it
	final_range:     u32, // of the last frame, for conformance checks
	softclip_mem:    [2]f32,
	redundant:       [240 * 2]f32, // a 5 ms redundancy frame
	transition:      [240 * 2]f32, // 5 ms concealed in the old mode, to fade from
}

// A decoder for 1 or 2 output channels; gain is a header's output gain
// (Q7.8 dB).
init_decoder :: proc(d: ^Decoder, channels: int, gain: i16 = 0) {
	d^ = {
		channels      = channels,
		gain          = f32(math.pow(10, f64(gain) / (20 * 256))),
		frame_samples = 120,
	}
	celt_init(&d.celt, channels)
	silk_init(&d.silk)
}

// Decodes a packet into pcm (interleaved, len >= samples * channels, +-1
// soft-clipped) and returns the samples per channel. Frames of at most one
// byte (DTX) are concealed.
decode_packet :: proc(d: ^Decoder, data: []u8, pcm: []f32) -> (samples: int, err: Error) {
	p := parse_packet(data) or_return
	return decode_parsed(d, &p, pcm)
}

@(private)
decode_parsed :: proc(d: ^Decoder, p: ^Packet, pcm: []f32) -> (samples: int, err: Error) {
	if len(pcm) < p.count * p.frame_samples * d.channels do return 0, .Buffer_Too_Small
	d.frame_samples = p.frame_samples
	d.packet_celt = p.mode == .CELT
	for frame in p.frames[:p.count] {
		out := pcm[samples * d.channels:][:p.frame_samples * d.channels]
		if len(frame) <= 1 {
			conceal(d, out, p.frame_samples)
		} else {
			decode_frame_opus(d, frame, p, out) or_return
		}
		samples += p.frame_samples
	}
	soft_clip(pcm[:samples * d.channels], d.channels, &d.softclip_mem)
	return samples, .None
}

// Conceals `samples` lost samples per channel (a multiple of 120, 2.5 ms)
// into pcm, continuing the last packet's signal: the duration of the gap,
// as the container's timestamps give it.
decode_lost :: proc(d: ^Decoder, samples: int, pcm: []f32) -> Error {
	if samples <= 0 || samples % 120 != 0 do return .Invalid_Packet
	if len(pcm) < samples * d.channels do return .Buffer_Too_Small
	for done := 0; done < samples; {
		done += conceal(d, pcm[done * d.channels:], samples - done)
	}
	return .None
}

// Recovers `samples` lost samples per channel (a multiple of 120, like
// decode_lost) from the packet that follows the gap, which is then decoded
// as usual. A SILK or hybrid packet sent with in-band FEC carries an LBRR
// (low bit-rate) copy of the frame before it: that restores the gap's last
// frame, and the rest of the gap is concealed. Without one, the whole gap
// is concealed.
decode_fec :: proc(d: ^Decoder, next: []u8, samples: int, pcm: []f32) -> Error {
	p := parse_packet(next) or_return
	return decode_fec_parsed(d, &p, samples, pcm)
}

@(private)
decode_fec_parsed :: proc(d: ^Decoder, p: ^Packet, samples: int, pcm: []f32) -> Error {
	if samples < p.frame_samples || p.mode == .CELT || d.packet_celt do return decode_lost(d, samples, pcm)
	if samples % 120 != 0 do return .Invalid_Packet
	if len(pcm) < samples * d.channels do return .Buffer_Too_Small
	gap := samples - p.frame_samples
	if gap > 0 do decode_lost(d, gap, pcm) or_return
	d.frame_samples = p.frame_samples
	d.packet_celt = false
	out := pcm[gap * d.channels:][:p.frame_samples * d.channels]
	if len(p.frames[0]) <= 1 {
		conceal(d, out, p.frame_samples)
		return .None
	}
	return decode_frame_opus(d, p.frames[0], p, out, true)
}

// One lost frame, up to frame_size samples and at most the last packet's
// frame, in the last frame's mode; returns the samples written.
@(private)
conceal :: proc(d: ^Decoder, out: []f32, frame_size: int) -> int {
	F20, F10, F5 :: 960, 480, 240
	ch := d.channels
	n := min(frame_size, d.frame_samples)
	if !d.have_prev {
		for &v in out[:n * ch] do v = 0
		return n
	}
	mode := d.prev_redundancy ? Mode.CELT : d.prev_mode
	// Concealment runs in 2.5, 5, 10 or 20 ms frames.
	if n > F20 {
		for done := 0; done < n; done += conceal(d, out[done * ch:], min(n - done, F20)) {}
		return n
	}
	if n > F10 && n < F20 {
		n = F10
	} else if mode != .SILK && n > F5 && n < F10 {
		n = F5
	}
	if mode != .CELT {
		// SILK conceals at least 10 ms.
		short: [F10 * 2]f32
		dst := n < F10 ? short[:F10 * ch] : out[:n * ch]
		for decoded := 0; decoded < n; {
			decoded += silk_decode(&d.silk, nil, d.silk.ch[0].fs_khz, max(10, n / 48), d.silk.internal_channels, ch, decoded == 0, dst[decoded * ch:], .Lost)
		}
		if n < F10 do copy(out[:n * ch], short[:n * ch])
	}
	if mode != .SILK {
		d.celt.start = mode == .CELT ? 0 : 17
		celt_decode(&d.celt, nil, nil, out, min(F20, n), mode != .CELT)
	}
	if d.gain != 1 do for &v in out[:n * ch] do v *= d.gain
	d.final_range = 0
	d.prev_mode = mode
	d.prev_redundancy = false
	return n
}

// One frame of a packet (RFC 6716 4): SILK, CELT, or both (hybrid: SILK
// below 8 kHz, CELT above), with an optional 5 ms CELT redundancy frame
// smoothing a switch between them. For error correction (fec), the SILK
// layer decodes the frame's LBRR copy of the frame before it, and CELT
// conceals.
@(private)
decode_frame_opus :: proc(d: ^Decoder, data: []u8, p: ^Packet, out: []f32, fec := false) -> Error {
	@(static, rodata)
	END_BAND := [Bandwidth]int{.Narrow = 13, .Medium = 17, .Wide = 17, .Super_Wide = 19, .Full = 21}
	F5, F2_5 :: 240, 120
	mode := p.mode
	ch := d.channels
	n := p.frame_samples
	stream_channels := p.stereo ? 2 : 1
	transition := d.have_prev && ((mode == .CELT && d.prev_mode != .CELT && !d.prev_redundancy) || (mode != .CELT && d.prev_mode == .CELT))
	// Switching without redundancy, the old mode's concealment fades into
	// the new frame.
	trans := d.transition[:F5 * ch]
	if transition && mode == .CELT do conceal(d, trans, min(F5, n))
	r: Range_Decoder
	range_init(&r, data)
	if mode != .CELT {
		if d.have_prev && d.prev_mode == .CELT do silk_reset(&d.silk)
		@(static, rodata)
		SILK_KHZ := [Bandwidth]int{.Narrow = 8, .Medium = 12, .Wide = 16, .Super_Wide = 16, .Full = 16}
		fs_khz := mode == .SILK ? SILK_KHZ[p.bandwidth] : 16
		decoded := 0
		for decoded < n {
			decoded += silk_decode(&d.silk, &r, fs_khz, max(10, n / 48), stream_channels, ch, decoded == 0, out[decoded * ch:], fec ? .Redundant : .Coded)
		}
	}
	// Redundancy: a CELT frame in the last bytes.
	length := len(data)
	redundancy, celt_to_silk := false, false
	redundancy_bytes := 0
	if !fec && mode != .CELT && range_tell(&r) + 17 + (mode == .Hybrid ? 20 : 0) <= 8 * length {
		redundancy = mode == .Hybrid ? range_bit_logp(&r, 12) : true
		if redundancy {
			celt_to_silk = range_bit_logp(&r, 1)
			redundancy_bytes = mode == .Hybrid ? int(range_uint(&r, 256)) + 2 : length - ((range_tell(&r) + 7) >> 3)
			length -= redundancy_bytes
			if length * 8 < range_tell(&r) {
				length, redundancy_bytes, redundancy = 0, 0, false
			}
		}
	}
	if redundancy do transition = false
	if transition && mode != .CELT do conceal(d, trans, min(F5, n))
	r.data = r.data[:len(data) - redundancy_bytes]
	d.celt.end = END_BAND[p.bandwidth]
	d.celt.stream_channels = stream_channels
	redundant := d.redundant[:F5 * ch]
	redundant_rng: u32
	decode_redundant :: proc(d: ^Decoder, bytes: []u8, into: []f32) -> (rng: u32, err: Error) {
		rr: Range_Decoder
		range_init(&rr, bytes)
		d.celt.start = 0
		celt_decode(&d.celt, bytes, &rr, into, 240) or_return
		return d.celt.rng, .None
	}
	if redundancy && celt_to_silk do redundant_rng = decode_redundant(d, data[length:][:redundancy_bytes], redundant) or_return
	d.celt.start = mode == .CELT ? 0 : 17
	if mode != .SILK {
		if d.have_prev && mode != d.prev_mode && !d.prev_redundancy do celt_reset(&d.celt)
		celt_decode(&d.celt, fec ? nil : data[:length], &r, out, min(960, n), mode != .CELT) or_return
		d.final_range = d.celt.rng
	} else {
		// From hybrid to SILK, CELT fades out over a silence frame.
		if d.have_prev && d.prev_mode == .Hybrid && !(redundancy && celt_to_silk && d.prev_redundancy) {
			silence := [2]u8{0xFF, 0xFF}
			rs: Range_Decoder
			range_init(&rs, silence[:])
			d.celt.start = 0
			celt_decode(&d.celt, silence[:], &rs, out, F2_5, true) or_return
		}
		d.final_range = r.rng
	}
	if redundancy && !celt_to_silk {
		celt_reset(&d.celt)
		redundant_rng = decode_redundant(d, data[length:][:redundancy_bytes], redundant) or_return
		at := ch * (n - F2_5)
		smooth_fade(out[at:], redundant[ch * F2_5:], out[at:], F2_5, ch)
	}
	if redundancy && celt_to_silk && (d.prev_mode != .SILK || d.prev_redundancy) {
		copy(out[:F2_5 * ch], redundant[:F2_5 * ch])
		smooth_fade(redundant[ch * F2_5:], out[ch * F2_5:], out[ch * F2_5:], F2_5, ch)
	}
	if transition {
		if n >= F5 {
			copy(out[:F2_5 * ch], trans[:F2_5 * ch])
			smooth_fade(trans[F2_5 * ch:], out[F2_5 * ch:], out[F2_5 * ch:], F2_5, ch)
		} else {
			smooth_fade(trans, out, out, F2_5, ch)
		}
	}
	if d.gain != 1 do for &v in out[:n * ch] do v *= d.gain
	d.final_range ~= redundant_rng
	d.prev_mode, d.have_prev = mode, true
	d.prev_redundancy = redundancy && !celt_to_silk
	return .None
}

// out = in1 faded into in2 over n samples with the squared CELT window.
@(private)
smooth_fade :: proc(in1, in2, out: []f32, n, channels: int) {
	for c in 0 ..< channels do for i in 0 ..< n {
		w := WINDOW[i] * WINDOW[i]
		k := i * channels + c
		out[k] = w * in2[k] + (1 - w) * in1[k]
	}
}

// Keeps the output in +-1 with a smooth curve over each excursion
// (libopus's opus_pcm_soft_clip), continuing the last frame's curve.
soft_clip :: proc(x: []f32, channels: int, mem: ^[2]f32) {
	n := len(x) / channels
	// One contiguous pass: clamp to the curve's domain and see whether
	// anything is out of +-1 at all (usually nothing is).
	over := false
	#no_bounds_check for &v in x {
		v = clamp(v, -2, 2)
		over |= v > 1 || v < -1
	}
	if !over && mem^ == {} do return
	for c in 0 ..< channels {
		at :: #force_inline proc(x: []f32, i, channels, c: int) -> ^f32 {return &x[i * channels + c]}
		a := mem[c]
		for i in 0 ..< n {
			s := at(x, i, channels, c)
			if s^ * a >= 0 do break
			s^ = s^ + a * s^ * s^
		}
		curr := 0
		x0 := at(x, 0, channels, c)^
		for {
			i := curr
			for i < n && abs(at(x, i, channels, c)^) <= 1 do i += 1
			if i == n {
				a = 0
				break
			}
			peak_pos := i
			start, end := i, i
			xi := at(x, i, channels, c)^
			maxval := abs(xi)
			for start > 0 && xi * at(x, start - 1, channels, c)^ >= 0 do start -= 1
			for end < n && xi * at(x, end, channels, c)^ >= 0 {
				if abs(at(x, end, channels, c)^) > maxval {
					maxval = abs(at(x, end, channels, c)^)
					peak_pos = end
				}
				end += 1
			}
			special := start == 0 && xi * at(x, 0, channels, c)^ >= 0
			a = (maxval - 1) / (maxval * maxval)
			a += a * 2.4e-7
			if xi > 0 do a = -a
			for j in start ..< end {
				s := at(x, j, channels, c)
				s^ = s^ + a * s^ * s^
			}
			if special && peak_pos >= 2 {
				// A ramp from the first sample to the peak.
				offset := x0 - at(x, 0, channels, c)^
				delta := offset / f32(peak_pos)
				for j in curr ..< peak_pos {
					offset -= delta
					s := at(x, j, channels, c)
					s^ = clamp(s^ + offset, -1, 1)
				}
			}
			curr = end
			if curr == n do break
		}
		mem[c] = a
	}
}

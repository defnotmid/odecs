package media_audiotoolbox

import media ".."
import aac "../../audio/aac"
import native "../native"
import "core:log"
import "core:math"
import "core:testing"

@(private = "file")
Packets :: struct {
	data:    [dynamic]u8,
	ranges:  [dynamic][2]int,
	indices: [dynamic]i64,
}

@(private = "file")
on_packet :: proc(p: media.Packet, user: rawptr) {
	c := (^Packets)(user)
	append(&c.ranges, [2]int{len(c.data), len(c.data) + len(p.data)})
	append(&c.data, ..p.data)
	append(&c.indices, p.sample_index)
}

@(private = "file")
Decoded :: struct {
	samples: map[i64]f32, // interleaved index (sample * channels + channel) -> value
	rate:    int,
}

@(private = "file")
on_audio :: proc(f: media.Audio_Frame, user: rawptr) {
	d := (^Decoded)(user)
	d.rate = f.sample_rate
	for v, i in f.samples do d.samples[(f.sample_index + i64(i / f.channels)) * i64(f.channels) + i64(i % f.channels)] = v
}

@(private = "file")
RATE :: 44100
@(private = "file")
FRAMES :: 80 // about 1.9 s

@(private = "file")
tone :: proc(i: int, channel: int) -> f32 {
	return 0.4 * f32(math.sin(2 * math.PI * f64(channel == 0 ? 440 : 660) * f64(i) / RATE))
}

// Encodes FRAMES frames of a stereo tone through the provider.
@(private = "file")
encode :: proc(t: ^testing.T, providers: []media.Provider, out: ^Packets) -> bool {
	config := media.default_config(.AAC, .Encode)
	config.sample_rate, config.channels, config.bit_rate = RATE, 2, 128_000
	config.audio_transport = .Raw
	session: media.Session
	if !testing.expect_value(t, media.open(&session, config, providers), media.Error.None) do return false
	defer media.close(&session)
	pcm: [1024 * 2]f32
	for frame in 0 ..< FRAMES {
		for i in 0 ..< 1024 do for c in 0 ..< 2 do pcm[i * 2 + c] = tone(frame * 1024 + i, c)
		e := media.encode_audio(&session, {samples = pcm[:], sample_rate = RATE, channels = 2, samples_per_channel = 1024}, {packet = on_packet, user = out})
		if !testing.expect_value(t, e, media.Error.None) do return false
	}
	return testing.expect_value(t, media.drain(&session, {packet = on_packet, user = out}), media.Error.None)
}

@(private = "file")
decode :: proc(t: ^testing.T, providers: []media.Provider, packets: ^Packets, out: ^Decoded) -> bool {
	asc: [dynamic]u8
	defer delete(asc)
	aac.append_audio_specific_config(&asc, {sample_rate = RATE, channels = 2})
	config := media.default_config(.AAC, .Decode)
	config.sample_rate, config.channels, config.extradata = RATE, 2, asc[:]
	session: media.Session
	if !testing.expect_value(t, media.open(&session, config, providers), media.Error.None) do return false
	defer media.close(&session)
	receiver := media.Receiver{audio = on_audio, user = out}
	for r, i in packets.ranges {
		e := media.decode(&session, {data = packets.data[r[0]:r[1]], framing = .Raw_AAC, sample_index = packets.indices[i], sample_rate = RATE}, receiver)
		if !testing.expect_value(t, e, media.Error.None) do return false
	}
	return testing.expect_value(t, media.drain(&session, receiver), media.Error.None)
}

// Signal-to-noise of b against a over the samples both have from 0 to
// FRAMES * 1024 - 2048 (the end lets the encoders' tails settle).
@(private = "file")
snr :: proc(a, b: ^Decoded) -> (db: f64, compared: int) {
	signal, noise: f64
	for i in 0 ..< i64((FRAMES * 1024 - 2048) * 2) {
		x, ok_a := a.samples[i]
		y, ok_b := b.samples[i]
		if !ok_a || !ok_b do continue
		signal += f64(x) * f64(x)
		noise += (f64(x) - f64(y)) * (f64(x) - f64(y))
		compared += 1
	}
	return 10 * math.log10(signal / max(noise, 1e-20)), compared
}

@(test)
test_audiotoolbox_aac :: proc(t: ^testing.T) {
	config := media.default_config(.AAC, .Encode)
	config.sample_rate, config.channels = RATE, 2
	config.audio_transport = .Raw
	when ODIN_OS != .Darwin {
		testing.expect_value(t, probe(config, nil), media.Error.Unavailable)
		return
	}
	testing.expect_value(t, probe(config, nil), media.Error.None)
	at := []media.Provider{provider()}
	oicut := []media.Provider{native.provider()}

	// The source, keyed like the decoders' output.
	source: Decoded
	defer delete(source.samples)
	for i in 0 ..< FRAMES * 1024 do for c in 0 ..< 2 do source.samples[i64(i * 2 + c)] = tone(i, c)

	// Apple's encoder and decoder: the tone back at its position.
	apple: Packets
	defer {delete(apple.data); delete(apple.ranges); delete(apple.indices)}
	if !encode(t, at, &apple) do return
	testing.expect(t, apple.indices[0] < 0) // priming before sample zero
	round: Decoded
	defer delete(round.samples)
	if !decode(t, at, &apple, &round) do return
	testing.expect_value(t, round.rate, RATE)
	db, n := snr(&source, &round)
	log.infof("Apple round trip: %.1f dB over %d samples, priming %d", db, n, -apple.indices[0])
	testing.expectf(t, n > (FRAMES - 4) * 2048 && db > 20, "Apple round trip: %.1f dB over %d samples", db, n)

	// oicut's encoder, decoded by Apple and by oicut: the same picture of it.
	ours: Packets
	defer {delete(ours.data); delete(ours.ranges); delete(ours.indices)}
	if !encode(t, oicut, &ours) do return
	by_apple, by_oicut: Decoded
	defer {delete(by_apple.samples); delete(by_oicut.samples)}
	if !decode(t, at, &ours, &by_apple) || !decode(t, oicut, &ours, &by_oicut) do return
	db, n = snr(&by_oicut, &by_apple)
	log.infof("oicut's AAC through Apple against oicut: %.1f dB over %d samples", db, n)
	testing.expectf(t, n > (FRAMES - 4) * 2048 && db > 40, "oicut's AAC through Apple and oicut: %.1f dB over %d samples", db, n)
}

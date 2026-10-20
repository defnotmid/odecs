package aac_decoder

import aac ".."
import enc "../encoder"
import "core:math"
import "core:slice"
import "core:testing"

@(test)
test_codec_round_trip_and_reset :: proc(t: ^testing.T) {
	for rate in ([]int{32000, 44100, 48000}) do for channels in 1 ..= 2 {
		e := new(enc.Encoder)
		defer free(e)
		testing.expect_value(t, enc.init_encoder(e, {sample_rate = rate, channels = channels, bit_rate = 64000 * channels}), Error.None)
		defer enc.destroy_encoder(e)
		d := new(Decoder)
		defer free(d)
		testing.expect_value(t, init_decoder(d, e.config), Error.None)
		input := make([]f32, 5 * 1024 * channels)
		defer delete(input)
		for &v, i in input {
			ch, sample := i % channels, i / channels
			v = f32(0.4 * math.sin(2 * math.PI * f64(997 + ch * 320) * f64(sample) / f64(rate)))
		}
		encoded: [dynamic]u8
		defer delete(encoded)
		for f in 0 ..< 5 do testing.expect_value(t, enc.encode_frame(e, input[f * 1024 * channels:(f + 1) * 1024 * channels], &encoded), Error.None)
		testing.expect_value(t, enc.flush_encoder(e, &encoded), Error.None)
		bytes := len(encoded)
		testing.expect_value(t, enc.flush_encoder(e, &encoded), Error.None)
		testing.expect_value(t, len(encoded), bytes)
		testing.expect_value(t, enc.encode_frame(e, input[:1024 * channels], &encoded), Error.Invalid_State)
		decoded := make([]f32, 6 * 1024 * channels)
		defer delete(decoded)
		position := 0
		for f in 0 ..< 6 {
			n, count, err := decode_adts_frame(d, encoded[position:], decoded[f * 1024 * channels:])
			testing.expect_value(t, err, Error.None)
			testing.expect_value(t, count, 1024)
			position += n
		}
		testing.expect_value(t, position, len(encoded))
		power, error: f64
		for v, i in input {
			delta := f64(v - decoded[1024 * channels + i])
			power += f64(v) * f64(v)
			error += delta * delta
		}
		testing.expectf(t, error / power < 0.002, "%d Hz/%d channels: error/power %g", rate, channels, error / power)
		enc.reset_encoder(e)
		replay: [dynamic]u8
		defer delete(replay)
		for f in 0 ..< 5 do testing.expect_value(t, enc.encode_frame(e, input[f * 1024 * channels:(f + 1) * 1024 * channels], &replay), Error.None)
		testing.expect_value(t, enc.flush_encoder(e, &replay), Error.None)
		testing.expect(t, slice.equal(encoded[:], replay[:]))
		reset_decoder(d)
		first: [2048]f32
		_, _, err := decode_adts_frame(d, encoded[:], first[:])
		testing.expect_value(t, err, Error.None)
		testing.expect(t, slice.equal(first[:1024 * channels], decoded[:1024 * channels]))
	}
}

@(test)
test_rejected_frame_does_not_advance :: proc(t: ^testing.T) {
	e := new(enc.Encoder)
	defer free(e)
	testing.expect_value(t, enc.init_encoder(e, {sample_rate = 48000, channels = 1}), Error.None)
	defer enc.destroy_encoder(e)
	pcm: [1024]f32
	for &v, i in pcm do v = f32(0.2 * math.sin(f64(i) / 11))
	out: [dynamic]u8
	defer delete(out)
	pcm[0] = math.nan_f32()
	testing.expect_value(t, enc.encode_frame(e, pcm[:], &out), Error.Invalid_Data)
	testing.expect_value(t, e.frames, 0)
	testing.expect_value(t, len(out), 0)
	pcm[0] = 0
	testing.expect_value(t, enc.encode_frame(e, pcm[:], &out), Error.None)
	// Analysis owns one input frame of lookahead; the second accepted input
	// publishes the first access unit used by these truncation controls.
	testing.expect_value(t, enc.encode_frame(e, pcm[:], &out), Error.None)
	d := new(Decoder)
	defer free(d)
	testing.expect_value(t, init_decoder(d, e.config), Error.None)
	decoded: [1024]f32
	for n in 0 ..< len(out) {
		_, _, err := decode_adts_frame(d, out[:n], decoded[:])
		testing.expect(t, err != .None)
		testing.expect_value(t, d.bank[0].previous_shape, u8(0))
		for v in d.bank[0].overlap do testing.expect_value(t, v, f64(0))
	}
	_, payload, _ := aac.parse_adts(out[:])
	for n in 0 ..< len(payload) {
		_, err := decode_frame(d, payload[:n], decoded[:])
		testing.expect(t, err != .None)
		for v in d.bank[0].overlap do testing.expect_value(t, v, f64(0))
	}
	_, samples, err := decode_adts_frame(d, out[:], decoded[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, samples, 1024)
}

@(test)
test_malformed_payloads_are_bounded :: proc(t: ^testing.T) {
	d := new(Decoder)
	defer free(d)
	testing.expect_value(t, init_decoder(d, {sample_rate = 44100, channels = 2}), Error.None)
	seed: u32 = 9127
	data: [128]u8
	out: [2048]f32
	for n in 0 ..< 2048 {
		for &v in data {seed = seed * 1664525 + 1013904223; v = u8(seed >> 24)}
		reset_decoder(d)
		count, err := decode_frame(d, data[:n % len(data)], out[:])
		testing.expect(t, (err == .None && count == 1024) || (err != .None && count == 0))
	}
}

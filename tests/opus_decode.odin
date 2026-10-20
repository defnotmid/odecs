// Decodes an opus_demo bitstream (.bit: per packet a big-endian length and
// final range, then the packet) to 16-bit PCM like `opus_demo -d 48000
// CHANNELS`, and checks every packet's final range against the encoder's.
// With a loss file (one 0 or 1 per packet), the marked packets are lost and
// concealed for the last packet's duration, like tests/opus_loss_ref.c;
// with a reference PCM file, the output is compared to it (identical, or
// the SNR); with "fec", the last packet of each loss is recovered from the
// next packet's in-band FEC.
//
//   opus_decode in.bit out.pcm [channels: 2] [loss.txt|-] [reference.pcm|-] [fec]
package main

import opus "../opus"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

// lrintf in the default rounding mode: halves to even.
round_even :: proc(x: f32) -> f32 {
	r := math.floor(x + 0.5)
	if r - x == 0.5 && i64(r) & 1 != 0 do r -= 1
	return r
}

main :: proc() {
	if len(os.args) < 3 {fmt.eprintln("usage: opus_decode in.bit out.pcm"); os.exit(2)}
	data, rerr := os.read_entire_file(os.args[1], context.allocator)
	if rerr != nil do os.exit(1)
	out, oerr := os.create(os.args[2])
	if oerr != nil do os.exit(1)
	defer os.close(out)
	channels := len(os.args) > 3 && os.args[3] == "1" ? 1 : 2
	losses: []string
	if len(os.args) > 4 && os.args[4] != "-" {
		text, lerr := os.read_entire_file(os.args[4], context.allocator)
		if lerr != nil do os.exit(1)
		losses = strings.fields(string(text))
	}
	fec := len(os.args) > 6 && os.args[6] == "fec"
	d: opus.Decoder
	opus.init_decoder(&d, channels)
	pcm := make([]f32, opus.MAX_FRAME_SAMPLES * 2)
	s16 := make([]u8, opus.MAX_FRAME_SAMPLES * 2 * 2)
	packets, range_ok, range_bad, lost := 0, 0, 0, 0
	last := 0
	first_bad := -1
	decode_time: time.Duration
	be32 :: proc(b: []u8) -> u32 {return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])}
	for at := 0; at + 8 <= len(data); {
		size := int(be32(data[at:]))
		final_range := be32(data[at + 4:])
		at += 8
		if size > len(data) - at do break
		packet := data[at:][:size]
		at += size
		start := time.now()
		n: int
		err: opus.Error
		lost_now := packets < len(losses) && losses[packets] == "1"
		if lost_now {
			n = last
			lost += 1
			// The next packet, if it arrived.
			next: []u8
			if at + 8 <= len(data) && !(packets + 1 < len(losses) && losses[packets + 1] == "1") {
				next_size := int(be32(data[at:]))
				if next_size <= len(data) - at - 8 do next = data[at + 8:][:next_size]
			}
			if fec && next != nil {
				err = opus.decode_fec(&d, next, n, pcm)
			} else {
				err = opus.decode_lost(&d, n, pcm)
			}
		} else {
			n, err = opus.decode_packet(&d, packet, pcm)
		}
		decode_time += time.since(start)
		last = n
		if err != .None {
			fmt.eprintln("packet", packets, err)
			os.exit(1)
		}
		// Like opus_demo, no final range for a concealed packet or the one
		// after it.
		if lost_now || packets > 0 && packets - 1 < len(losses) && losses[packets - 1] == "1" {
		} else if d.final_range == final_range {
			range_ok += 1
		} else {
			range_bad += 1
			if first_bad < 0 do first_bad = packets
		}
		for i in 0 ..< n * channels {
			v := i16(round_even(clamp(pcm[i] * 32768, -32768, 32767)))
			s16[2 * i], s16[2 * i + 1] = u8(v), u8(u16(v) >> 8)
		}
		os.write(out, s16[:n * channels * 2])
		packets += 1
	}
	fmt.printf("%d packets: final range %d ok, %d wrong (first %d), %d lost; %.3f ms decoding", packets, range_ok, range_bad, first_bad, lost, time.duration_milliseconds(decode_time))
	if len(os.args) > 5 && os.args[5] != "-" {
		os.close(out)
		ours, _ := os.read_entire_file(os.args[2], context.allocator)
		ref, ferr := os.read_entire_file(os.args[5], context.allocator)
		if ferr != nil || len(ref) != len(ours) {
			fmt.printfln("; reference length %d, ours %d", len(ref), len(ours))
			os.exit(1)
		}
		signal, noise: f64
		max_diff := 0
		for i := 0; i + 1 < len(ref); i += 2 {
			a := f64(i16(u16(ref[i]) | u16(ref[i + 1]) << 8))
			b := f64(i16(u16(ours[i]) | u16(ours[i + 1]) << 8))
			signal += a * a
			noise += (a - b) * (a - b)
			max_diff = max(max_diff, int(abs(a - b)))
		}
		if noise == 0 {
			fmt.println("; identical to the reference")
		} else {
			fmt.printfln("; vs reference %.1f dB SNR, max difference %d", 10 * math.log10(signal / noise), max_diff)
		}
	} else {
		fmt.println()
	}
	if range_bad != 0 do os.exit(1)
}

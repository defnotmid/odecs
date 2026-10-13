// Decodes an MP3 elementary stream (raw .mp3 or a conformance .bit) with
// codec/mp3 and compares it with a reference: a conformance suite .pcm
// (interleaved s16le; reports PSNR and the largest difference in 16-bit
// steps, ISO/IEC 11172-4 asks for at most 2) or FFmpeg's f32le decode
// (gapless-trimmed like FFmpeg when the stream has a LAME tag). Reports the
// decode speed.
//
//   odin build tests/mp3_compare.odin -file -o:speed -out:/tmp/odecs-mp3-compare
//   /tmp/odecs-mp3-compare FILE [REF.pcm|REF.f32]
package mp3_compare

import mp3 "../codec/mp3"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

fail :: proc(args: ..any) {
	fmt.eprintln(..args)
	os.exit(1)
}

main :: proc() {
	if len(os.args) < 2 do fail("usage: mp3_compare FILE [REF.pcm|REF.f32]")
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil do fail("cannot read", os.args[1])
	at := 0
	if len(data) >= 10 && string(data[:3]) == "ID3" {
		at = 10 + (int(data[6]) << 21 | int(data[7]) << 14 | int(data[8]) << 7 | int(data[9])) + (data[5] & 0x10 != 0 ? 10 : 0)
	}
	d := new(mp3.Decoder)
	pcm: [dynamic]f32 // interleaved
	native: [dynamic]f32 // each frame at its own channel count, as conformance references store it
	switched := false
	channels, rate, frames, incomplete := 0, 0, 0, 0
	tag: mp3.Info_Tag
	first := true
	decode_time: time.Duration
	for at + 4 <= len(data) {
		h, he := mp3.parse_header(data[at:])
		if he != .None || at + h.frame_bytes > len(data) {at += 1; continue}
		frame := data[at:][:h.frame_bytes]
		at += h.frame_bytes
		if first {
			first = false
			if t, ok := mp3.parse_info_tag(frame, h); ok {tag = t; continue}
		}
		t0 := time.tick_now()
		f, e := mp3.decode_frame(d, frame)
		decode_time += time.tick_since(t0)
		if e != .None {fmt.eprintln("frame", frames, "error", e); continue}
		if channels == 0 do channels, rate = h.channels, h.sample_rate
		if h.sample_rate != rate do fail("sample rate changes at frame", frames)
		frames += 1
		// Frames whose main data began before the stream did are dropped,
		// as references do.
		if !f.complete {incomplete += 1; continue}
		// The stream keeps its first frame's channel count: mono frames are
		// doubled, stereo frames in a mono stream averaged.
		switched ||= h.channels != channels
		for i in 0 ..< h.samples do for c in 0 ..< h.channels do append(&native, f.pcm[c][i])
		for i in 0 ..< h.samples do for c in 0 ..< channels {
			v := h.channels == channels ? f.pcm[c][i] : h.channels == 1 ? f.pcm[0][i] : 0.5 * (f.pcm[0][i] + f.pcm[1][i])
			append(&pcm, v)
		}
	}
	if channels == 0 do fail("no frames decoded")
	seconds := f64(len(pcm) / channels) / f64(rate)
	fmt.printfln("%s: %d Hz %d ch, %d frames (%d without their reservoir), %.2f s, decode %.0fx real time", os.args[1], rate, channels, frames, incomplete, seconds, seconds / time.duration_seconds(decode_time))
	if len(os.args) < 3 do return
	ref_path := os.args[2]
	ref, rerr := os.read_entire_file(ref_path, context.allocator)
	if rerr != nil do fail("cannot read", ref_path)
	// Gapless trimming of a LAME-tagged stream.
	trimmed := pcm[min(tag.delay * channels, len(pcm)):]
	trimmed = trimmed[:max(len(trimmed) - tag.padding * channels, 0)]
	if strings.has_suffix(ref_path, ".pcm") {
		// Conformance: 16-bit output, rounded and clipped.
		pcm := switched ? native[:] : trimmed
		want := ([^]i16)(raw_data(ref))[:len(ref) / 2]
		n := min(len(want), len(pcm))
		worst := 0
		mse: f64
		for i in 0 ..< n {
			s := int(math.round(pcm[i] * 32768))
			s = clamp(s, -32768, 32767)
			diff := abs(s - int(want[i]))
			worst = max(worst, diff)
			mse += f64(diff * diff)
		}
		mse /= f64(max(n, 1))
		psnr := mse == 0 ? 99.0 : 10 * math.log10(f64(32767 * 32767) / mse)
		fmt.printfln("  vs reference: %d samples (reference %d), max difference %d, PSNR %.1f dB", len(pcm), len(want), worst, psnr)
		if len(want) != len(pcm) && abs(len(want) - len(pcm)) > channels * 1152 do fail("  length differs")
		if psnr < 96 do fail("  below 96 dB")
		return
	}
	got := trimmed
	want := ([^]f32)(raw_data(ref))[:len(ref) / 4]
	n := min(len(want), len(got))
	worst, sum: f64
	for i in 0 ..< n {
		diff := f64(abs(got[i] - want[i]))
		worst = max(worst, diff)
		sum += diff * diff
	}
	rms := math.sqrt(sum / f64(max(n, 1)))
	fmt.printfln("  vs FFmpeg: %d values (FFmpeg %d), max difference %.2g, RMS %.2g (in 16-bit steps: %.2f, %.3f)", len(got), len(want), worst, rms, worst * 32768, rms * 32768)
}

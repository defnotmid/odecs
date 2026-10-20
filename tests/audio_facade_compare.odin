// Decodes audio files with odecs/audio and with miniaudio (vendor:miniaudio,
// what the suite used before: dr_wav, dr_flac, dr_mp3, stb_vorbis) and
// compares the f32 PCM. WAV and FLAC must be identical, but for two
// limits of miniaudio's: dr_wav maps 8-bit 128 to 1/255 where FFmpeg and
// odecs give 0, and dr_flac decodes no 32-bit FLAC. MP3 and Vorbis are
// reported, not gated: their accuracy is gated against FFmpeg, the ISO
// streams and libvorbis (mp3_check.sh, vorbis_check.sh), where dr_mp3 is
// 70-89 dB from FFmpeg and miniaudio's 5.1 Vorbis is wrong. They are
// aligned within a few thousand samples first, since decoders trim
// encoder delay differently. Times are the
// best of five; memory is odecs' peak allocation.
//   odin run tests/audio_facade_compare.odin -file -o:speed -- file...
package audio_facade_compare

import audio "../audio"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:time"
import ma "vendor:miniaudio"

reference :: proc(data: []u8, out: ^[dynamic]f32) -> (channels, rate: int, ok: bool) {
	config := ma.decoder_config_init(.f32, 0, 0)
	d: ma.decoder
	if ma.decoder_init_memory(raw_data(data), len(data), &config, &d) != .SUCCESS do return
	defer ma.decoder_uninit(&d)
	channels, rate = int(d.outputChannels), int(d.outputSampleRate)
	clear(out)
	chunk: [4096 * 8]f32
	for {
		frames := u64(len(chunk) / channels)
		got: u64
		r := ma.decoder_read_pcm_frames(&d, raw_data(chunk[:]), frames, &got)
		append(out, ..chunk[:int(got) * channels])
		if r != .SUCCESS || got < frames do break
	}
	return channels, rate, true
}

// The SNR of b against a after shifting b by `shift` frames, over their
// overlap.
snr_at :: proc(a, b: []f32, channels, shift: int) -> f64 {
	signal, noise: f64
	frames_a, frames_b := len(a) / channels, len(b) / channels
	for i in max(0, -shift) ..< min(frames_a, frames_b - shift) {
		for c in 0 ..< channels {
			x, y := f64(a[i * channels + c]), f64(b[(i + shift) * channels + c])
			signal += x * x
			noise += (x - y) * (x - y)
		}
	}
	return noise == 0 ? math.inf_f64(1) : 10 * math.log10(signal / noise)
}

main :: proc() {
	failed := 0
	ref: [dynamic]f32
	total_ours, total_theirs: f64
	for path in os.args[1:] {
		name := filepath.base(path)
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {fmt.println("cannot read", path); failed += 1; continue}
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		a, aerr := audio.decode(data, mem.tracking_allocator(&track))
		peak := track.peak_memory_allocated
		channels, rate, ok := reference(data, &ref)
		switch {
		case !ok && aerr != .None:
			fmt.printfln("%-28s both refuse (%v)", name, aerr)
			continue
		case !ok:
			fmt.printfln("%-28s miniaudio refuses, odecs decodes %d ch %d Hz", name, a.channels, a.rate)
			audio.destroy_audio(&a, mem.tracking_allocator(&track))
			continue
		case aerr != .None:
			fmt.printfln("%-28s FAIL odecs %v, miniaudio decodes", name, aerr)
			failed += 1
			continue
		}
		info, _ := audio.info(data)
		lossless := info.codec == .PCM || info.codec == .FLAC
		verdict: string
		ours, theirs := len(a.samples) / max(a.channels, 1), len(ref) / max(channels, 1)
		switch {
		case a.channels != channels || a.rate != rate:
			verdict = fmt.tprintf("FAIL %d ch %d Hz, miniaudio %d ch %d Hz", a.channels, a.rate, channels, rate)
			failed += 1
		case lossless && theirs == 0:
			verdict = "miniaudio decodes nothing (dr_flac has no 32-bit FLAC)"
		case lossless:
			same := len(a.samples) == len(ref)
			worst: f32
			if same do for v, i in a.samples do worst = max(worst, abs(v - ref[i]))
			switch {
			case same && worst == 0:
				verdict = "identical"
			case same && worst <= 1.0 / 128:
				verdict = fmt.tprintf("8-bit convention: within %v (dr_wav maps 128 to 1/255)", worst)
			case:
				verdict = fmt.tprintf("FAIL not identical (%d frames, miniaudio %d)", ours, theirs)
				failed += 1
			}
		case:
			best, best_shift := math.inf_f64(-1), 0
			for shift := -2400; shift <= 2400; shift += 1 {
				if s := snr_at(a.samples, ref[:], channels, shift); s > best do best, best_shift = s, shift
			}
			verdict = fmt.tprintf("SNR %.1f dB at offset %d, %d frames (miniaudio %d)", best, best_shift, ours, theirs)
		}
		audio.destroy_audio(&a, mem.tracking_allocator(&track))
		mine, other := max(f64), max(f64)
		for _ in 0 ..< 5 {
			t := time.tick_now()
			again, _ := audio.decode(data)
			mine = min(mine, time.duration_milliseconds(time.tick_since(t)))
			audio.destroy_audio(&again)
			t = time.tick_now()
			reference(data, &ref)
			other = min(other, time.duration_milliseconds(time.tick_since(t)))
		}
		total_ours += mine
		total_theirs += other
		fmt.printfln("%-28s %v %d ch %d Hz: %s; %.2f ms (miniaudio %.2f), peak %d KiB", name, info.codec, channels, rate, verdict, mine, other, peak / 1024)
		delete(data)
	}
	if total_theirs > 0 do fmt.printfln("total %.1f ms (miniaudio %.1f, %.2fx)", total_ours, total_theirs, total_ours / total_theirs)
	fmt.printfln("%d failed", failed)
	os.exit(failed == 0 ? 0 : 1)
}

// Decodes Ogg Vorbis files with odecs/audio and with libvorbis (vorbisfile,
// the reference decoder and the speed to meet) and compares the f32 PCM:
// the same frame count, and the SNR of the difference (float decoders
// differ in rounding). Times are the best of several decodes each.
// tests/vorbis_check.sh builds the pinned libogg and libvorbis into
// .work/vorbis-oracle and runs this; by hand:
//   odin run tests/vorbis_compare.odin -file -o:speed -extra-linker-flags:"-L.work/vorbis-oracle/lib" -- file.ogg...
package vorbis_compare

import audio "../audio"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

foreign import vorbisfile {"system:vorbisfile", "system:vorbis", "system:ogg"}

// OggVorbis_File is opaque here: room enough, aligned.
File :: struct #align (16) {
	_: [4096]u8,
}

Vorbis_Info :: struct {
	version:  c.int,
	channels: c.int,
	rate:     c.long,
}

@(default_calling_convention = "c")
foreign vorbisfile {
	ov_fopen :: proc(path: cstring, vf: ^File) -> c.int ---
	ov_info :: proc(vf: ^File, link: c.int) -> ^Vorbis_Info ---
	ov_read_float :: proc(vf: ^File, pcm: ^[^][^]f32, samples: c.int, bitstream: ^c.int) -> c.long ---
	ov_clear :: proc(vf: ^File) -> c.int ---
}

// libvorbis' decode, interleaved.
reference :: proc(path: string, out: ^[dynamic]f32) -> (channels, rate: int, ok: bool) {
	vf: File
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if ov_fopen(cpath, &vf) != 0 do return
	defer ov_clear(&vf)
	info := ov_info(&vf, -1)
	channels, rate = int(info.channels), int(info.rate)
	clear(out)
	for {
		pcm: [^][^]f32
		section: c.int
		n := int(ov_read_float(&vf, &pcm, 4096, &section))
		if n < 0 do return
		if n == 0 do break
		for i in 0 ..< n do for ch in 0 ..< channels do append(out, pcm[ch][i])
	}
	return channels, rate, true
}

main :: proc() {
	failed := 0
	worst_snr, worst_file := math.inf_f64(1), ""
	total_ours, total_theirs: f64
	ref: [dynamic]f32
	for path in os.args[1:] {
		name := filepath.base(path)
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {fmt.println("cannot read", path); failed += 1; continue}
		channels, rate, ok := reference(path, &ref)
		a, aerr := audio.decode(data)
		switch {
		case !ok && aerr != .None:
			fmt.printfln("%-24s both refuse (%v)", name, aerr)
			continue
		case !ok:
			fmt.printfln("%-24s libvorbis refuses, odecs decodes", name)
			continue
		case aerr != .None:
			fmt.printfln("%-24s FAIL odecs %v", name, aerr)
			failed += 1
			continue
		}
		verdict: string
		switch {
		case a.channels != channels || a.rate != rate:
			verdict = fmt.tprintf("FAIL %d ch %d Hz, libvorbis %d ch %d Hz", a.channels, a.rate, channels, rate)
		case len(a.samples) != len(ref):
			verdict = fmt.tprintf("FAIL %d frames, libvorbis %d", len(a.samples) / max(channels, 1), len(ref) / channels)
		case:
			signal, noise, peak: f64
			for v, i in a.samples {
				d := f64(v) - f64(ref[i])
				signal += f64(ref[i]) * f64(ref[i])
				noise += d * d
				peak = max(peak, abs(d))
			}
			snr := noise == 0 ? math.inf_f64(1) : 10 * math.log10(signal / noise)
			if snr < worst_snr do worst_snr, worst_file = snr, name
			good := snr >= 90
			verdict = fmt.tprintf("%s SNR %.1f dB, peak difference %.2e", good ? "ok  " : "FAIL", snr, peak)
			if !good do failed += 1
		}
		if strings.has_prefix(verdict, "FAIL") && !strings.has_prefix(verdict, "FAIL SNR") do failed += 1
		audio.destroy_audio(&a)
		ours, theirs := max(f64), max(f64)
		for _ in 0 ..< 5 {
			t := time.tick_now()
			again, _ := audio.decode(data)
			ours = min(ours, time.duration_milliseconds(time.tick_since(t)))
			audio.destroy_audio(&again)
			t = time.tick_now()
			reference(path, &ref)
			theirs = min(theirs, time.duration_milliseconds(time.tick_since(t)))
		}
		total_ours += ours
		total_theirs += theirs
		fmt.printfln("%-24s %d ch %6d Hz %7d frames %s; %.2f ms (libvorbis %.2f)", name, channels, rate, len(ref) / channels, verdict, ours, theirs)
		delete(data)
	}
	if worst_file != "" do fmt.printfln("worst: %s at %.1f dB", worst_file, worst_snr)
	if total_theirs > 0 do fmt.printfln("total %.1f ms (libvorbis %.1f, %.2fx)", total_ours, total_theirs, total_ours / total_theirs)
	fmt.printfln("%d failed", failed)
	os.exit(failed == 0 ? 0 : 1)
}

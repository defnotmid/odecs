// Signals and comparisons for tests/aac_check.sh, on s16le PCM files:
//
//	aac_check signal RATE CHANNELS tone|transient|noise OUT.pcm
//	aac_check compare PREFIX     PREFIX.native.pcm and PREFIX.ff.pcm differ by at most 2
//	aac_check snr DIR            delay-aligned SNR floors of the native round trips
//	aac_check pns DIR            PNS decode: same length and energy as FFmpeg's
package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strconv"
import "core:strings"

main :: proc() {
	args := os.args[1:]
	switch {
	case len(args) == 5 && args[0] == "signal":
		rate, channels := number(args[1]), number(args[2])
		write_pcm(args[4], signal(rate, channels, args[3]))
	case len(args) == 2 && args[0] == "compare":
		compare(args[1])
	case len(args) == 2 && args[0] == "snr":
		snr(args[1])
	case len(args) == 2 && args[0] == "pns":
		pns(args[1])
	case:
		fmt.eprintln("usage: aac_check signal RATE CHANNELS KIND OUT | compare PREFIX | snr DIR | pns DIR")
		os.exit(2)
	}
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

number :: proc(text: string) -> int {
	value, ok := strconv.parse_int(text, 10)
	if !ok do fail("not a number: %s", text)
	return value
}

// A third of a second of interleaved samples: two tones per channel, the
// same tones under periodic loud bursts, or uniform noise.
signal :: proc(rate, channels: int, kind: string) -> []i16 {
	if kind != "tone" && kind != "transient" && kind != "noise" do fail("unknown signal %s", kind)
	samples := make([]i16, rate / 3 * channels)
	generator := rand.create(123)
	random := rand.default_random_generator(&generator)
	for n in 0 ..< rate / 3 {
		t := f64(n) / f64(rate)
		for c in 0 ..< channels {
			v := 0.35 * math.sin(2 * math.PI * f64(997 + c * 334) * t) + 0.1 * math.sin(2 * math.PI * f64(3001 + c * 252) * t)
			switch kind {
			case "transient":
				burst := n % (rate / 20) < rate / 300
				v = burst ? 0.5 * math.sin(2 * math.PI * f64(6000 + c * 500) * t) : v * 0.05
			case "noise":
				v = rand.float64_range(-0.6, 0.6, random)
			}
			samples[n * channels + c] = i16(math.round(v * 32767))
		}
	}
	return samples
}

read_pcm :: proc(path: string) -> []i16 {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do fail("cannot read %s: %v", path, err)
	samples := make([]i16, len(data) / 2)
	for &s, i in samples do s = i16(u16(data[2 * i]) | u16(data[2 * i + 1]) << 8)
	return samples
}

write_pcm :: proc(path: string, samples: []i16) {
	data := make([]u8, 2 * len(samples))
	for s, i in samples {
		data[2 * i], data[2 * i + 1] = u8(u16(s)), u8(u16(s) >> 8)
	}
	if err := os.write_entire_file(path, data); err != nil do fail("cannot write %s: %v", path, err)
}

energy :: proc(samples: []i16) -> f64 {
	sum: f64
	for s in samples do sum += f64(s) * f64(s)
	return sum
}

// Our decoder and FFmpeg's on the same stream.
compare :: proc(prefix: string) {
	a := read_pcm(strings.concatenate({prefix, ".native.pcm"}))
	b := read_pcm(strings.concatenate({prefix, ".ff.pcm"}))
	if len(a) != len(b) do fail("%s: %d and %d samples", prefix, len(a), len(b))
	error := 0
	for x, i in a do error = max(error, abs(int(x) - int(b[i])))
	fmt.println(prefix, "max_error", error)
	if error > 2 do fail("%s: max error %d", prefix, error)
}

// A weak, explicit quality floor that catches accidental all-zero or noise
// output: signal preservation, not a perceptual quality claim.
snr :: proc(dir: string) {
	SIGNALS :: [?]struct {
		kind:  string,
		floor: f64,
	}{{"tone", 27}, {"transient", 5}, {"noise", 1}}
	for rate in ([]int{44100, 48000}) {
		for channels in 1 ..= 2 {
			for s in SIGNALS {
				kind, floor := s.kind, s.floor
				name := fmt.tprintf("%d-%d-%s", rate, channels, kind)
				source := read_pcm(fmt.tprintf("%s/%s.pcm", dir, name))
				decoded := read_pcm(fmt.tprintf("%s/%s.native.native.pcm", dir, name))
				delay := 1024 * channels // the encoder's priming frame
				if len(decoded) < delay + len(source) do fail("%s: decoded output is short", name)
				decoded = decoded[delay:][:len(source)]
				error: f64
				for x, i in source do error += (f64(x) - f64(decoded[i])) * (f64(x) - f64(decoded[i]))
				ratio := 10 * math.log10(energy(source) / max(1, error))
				if ratio < floor do fail("%s: SNR %.2f below %v", name, ratio, floor)
				fmt.printfln("%s delay-aligned SNR %.2f", name, ratio)
			}
		}
	}
}

// Noise substitution has random phases, so only length and energy compare.
pns :: proc(dir: string) {
	log, err := os.read_entire_file(fmt.tprintf("%s/pns.log", dir), context.allocator)
	if err != nil do fail("cannot read the PNS log")
	at := strings.index(string(log), "pns=")
	if at < 0 do fail("the decoder did not report PNS bands")
	digits := string(log[at + 4:])
	end := 0
	for end < len(digits) && digits[end] >= '0' && digits[end] <= '9' do end += 1
	if end == 0 || number(digits[:end]) == 0 do fail("no PNS bands were decoded")
	a := read_pcm(fmt.tprintf("%s/pns.native.pcm", dir))
	b := read_pcm(fmt.tprintf("%s/pns.ff.pcm", dir))
	if len(a) != len(b) || len(a) == 0 do fail("PNS: %d and %d samples", len(a), len(b))
	ratio := energy(a) / energy(b)
	if ratio <= 0.9 || ratio >= 1.1 do fail("PNS: energy ratio %v", ratio)
	fmt.println("PNS length and energy passed; energy ratio", ratio)
}


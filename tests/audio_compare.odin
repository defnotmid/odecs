package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"

// Raw interleaved s16le only: no codec dependency and no automatic alignment.
// Quality compares exactly the original sample count after the supplied delay
// in samples per channel, and requires fewer than 2048 trailing sample frames.
// Energy uses samples/32768, and SNR=10*log10(signal_energy/error_energy).
// SNR is an objective error measurement, not a perceptual quality score.

integer :: proc(value, name: string) -> int {
	result, ok := strconv.parse_int(value)
	if !ok {
		fmt.eprintfln("invalid %s: %s", name, value)
		os.exit(2)
	}
	return result
}

read_pcm :: proc(path: string) -> []u8 {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil || len(data) == 0 || len(data) % 2 != 0 {
		fmt.eprintfln("invalid s16le file: %s bytes=%d error=%v", path, len(data), err)
		os.exit(1)
	}
	return data
}

sample_s16le :: proc(data: []u8, index: int) -> i16 {
	word := u16(data[2 * index]) | u16(data[2 * index + 1]) << 8
	return i16(word)
}

Measurement :: struct {
	samples:                                     int,
	signal_energy, decoded_energy, error_energy: f64,
}

add_sample :: proc(measurement: ^Measurement, source, decoded: i16) {
	a, b := f64(source) / 32768, f64(decoded) / 32768
	difference := a - b
	measurement.samples += 1
	measurement.signal_energy += a * a
	measurement.decoded_energy += b * b
	measurement.error_energy += difference * difference
}

report_measurement :: proc(name: string, measurement: Measurement) {
	if measurement.samples == 0 ||
	   measurement.signal_energy <= 0 ||
	   math.is_nan(measurement.signal_energy) ||
	   math.is_inf(measurement.signal_energy) ||
	   math.is_nan(measurement.decoded_energy) ||
	   math.is_inf(measurement.decoded_energy) ||
	   math.is_nan(measurement.error_energy) ||
	   math.is_inf(measurement.error_energy) {
		fmt.eprintfln(
			"invalid quality energies: section=%s samples=%d signal=%v decoded=%v error=%v",
			name,
			measurement.samples,
			measurement.signal_energy,
			measurement.decoded_energy,
			measurement.error_energy,
		)
		os.exit(1)
	}
	signal_rms := math.sqrt(measurement.signal_energy / f64(measurement.samples))
	error_rms := math.sqrt(measurement.error_energy / f64(measurement.samples))
	if measurement.error_energy == 0 {
		// Exact PCM has mathematical +infinity SNR; do not invent a noise floor.
		fmt.printfln(
			"section=%s interleaved_samples=%d signal_energy=%.12f decoded_energy=%.12f error_energy=0 signal_rms=%.9f error_rms=0 snr_db=inf exact=true",
			name,
			measurement.samples,
			measurement.signal_energy,
			measurement.decoded_energy,
			signal_rms,
		)
		return
	}
	snr := 10 * math.log10(measurement.signal_energy / measurement.error_energy)
	if math.is_nan(snr) || math.is_inf(snr) {
		fmt.eprintfln("nonfinite quality SNR: section=%s", name)
		os.exit(1)
	}
	fmt.printfln(
		"section=%s interleaved_samples=%d signal_energy=%.12f decoded_energy=%.12f error_energy=%.12f signal_rms=%.9f error_rms=%.9f snr_db=%.6f exact=false",
		name,
		measurement.samples,
		measurement.signal_energy,
		measurement.decoded_energy,
		measurement.error_energy,
		signal_rms,
		error_rms,
		snr,
	)
}

quality :: proc(source_path, decoded_path: string, rate, channels, delay: int) {
	if rate <= 0 || channels < 1 || channels > 2 || delay < 0 {
		fmt.eprintln(
			"require a positive sample rate, one or two channels, and a nonnegative delay per channel",
		)
		os.exit(2)
	}
	source := read_pcm(source_path)
	defer delete(source)
	decoded := read_pcm(decoded_path)
	defer delete(decoded)
	if len(source) % (2 * channels) != 0 || len(decoded) % (2 * channels) != 0 {
		fmt.eprintln("incomplete interleaved PCM sample frame")
		os.exit(1)
	}
	source_frames := len(source) / (2 * channels)
	decoded_frames := len(decoded) / (2 * channels)
	if source_frames < 3 || source_frames % 3 != 0 {
		fmt.eprintln("source must contain three equal nonempty sections")
		os.exit(1)
	}
	if delay > decoded_frames || source_frames > decoded_frames - delay {
		fmt.eprintfln(
			"truncated decoded PCM: original_samples_per_channel=%d decoded_samples_per_channel=%d delay_samples_per_channel=%d",
			source_frames,
			decoded_frames,
			delay,
		)
		os.exit(1)
	}
	padding := decoded_frames - delay - source_frames
	if padding >= 2048 {
		fmt.eprintfln(
			"excess decoded padding: original_samples_per_channel=%d decoded_samples_per_channel=%d delay_samples_per_channel=%d trailing_samples_per_channel=%d limit_exclusive=2048",
			source_frames,
			decoded_frames,
			delay,
			padding,
		)
		os.exit(1)
	}
	section_frames := source_frames / 3
	sections: [3]Measurement
	overall: Measurement
	for frame in 0 ..< source_frames {
		section := frame / section_frames
		for channel in 0 ..< channels {
			a := sample_s16le(source, frame * channels + channel)
			b := sample_s16le(decoded, (frame + delay) * channels + channel)
			add_sample(&sections[section], a, b)
			add_sample(&overall, a, b)
		}
	}
	fmt.printfln(
		"PCM quality: metric=objective_snr rate=%d channels=%d original_samples_per_channel=%d decoded_samples_per_channel=%d delay_samples_per_channel=%d trailing_samples_per_channel=%d padding_verified=true",
		rate,
		channels,
		source_frames,
		decoded_frames,
		delay,
		padding,
	)
	report_measurement("overall", overall)
	names := [3]string{"tone_chirp", "transient", "noise"}
	for section in 0 ..< 3 do report_measurement(names[section], sections[section])
}

pair :: proc(a_path, b_path: string) {
	a := read_pcm(a_path)
	defer delete(a)
	b := read_pcm(b_path)
	defer delete(b)
	if len(a) != len(b) {
		fmt.eprintfln("PCM pair length mismatch: a_bytes=%d b_bytes=%d", len(a), len(b))
		os.exit(1)
	}
	samples := len(a) / 2
	max_error: i32
	differing, over_two := 0, 0
	absolute_error, squared_error: f64
	for n in 0 ..< samples {
		error := abs(i32(sample_s16le(a, n)) - i32(sample_s16le(b, n)))
		max_error = max(max_error, error)
		if error != 0 do differing += 1
		if error > 2 do over_two += 1
		absolute_error += f64(error)
		squared_error += f64(error) * f64(error)
	}
	fmt.printfln(
		"PCM pair: bytes=%d interleaved_samples=%d exact_samples=%d differing_samples=%d over_two_samples=%d max_s16_error=%d mean_s16_error=%.9f rms_s16_error=%.9f tolerance_s16=2 passed=%v",
		len(a),
		samples,
		samples - differing,
		differing,
		over_two,
		max_error,
		absolute_error / f64(samples),
		math.sqrt(squared_error / f64(samples)),
		max_error <= 2,
	)
	if max_error > 2 do os.exit(1)
}

main :: proc() {
	if len(os.args) == 7 && os.args[1] == "quality" {
		quality(
			os.args[2],
			os.args[3],
			integer(os.args[4], "sample rate"),
			integer(os.args[5], "channels"),
			integer(os.args[6], "delay per channel"),
		)
		return
	}
	if len(os.args) == 4 && os.args[1] == "pair" {
		pair(os.args[2], os.args[3])
		return
	}
	fmt.eprintln(
		"usage: audio_compare quality source.s16le decoded.s16le sample_rate channels delay_per_channel",
	)
	fmt.eprintln("       audio_compare pair A.s16le B.s16le")
	os.exit(2)
}

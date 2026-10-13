package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"

// Native fixture v1, with three equal sections. No external signal is used.
// All phases use section-local t=n/rate and T=section_samples/rate.
//
// 0: (0.85+0.15*sin(TAU*1.7*t)) times the sum of:
//    0.24*sin(TAU*min(997,0.071*rate)*t),
//    0.11*sin(TAU*min(3001,0.17*rate)*t+0.2),
//    0.13*sin(TAU*min(1373+431*channel,0.13*rate)*t+0.7*channel),
//    0.15*sin(TAU*(0.011*rate*t+0.5*0.359*rate*t*t/T)+0.3*channel).
// 1: 0.025*sin(TAU*min(241,0.02*rate)*t+0.2*channel), plus
//    a burst every max(1,rate/11) samples. For its first max(1,rate/250)
//    samples p, add 0.55*(1-p/burst_length)^2*sin(TAU*0.23*p+0.4*channel).
//    At p=0 also add +/-0.22, alternating by burst index plus channel.
// 2: 0.18*channel_noise+0.06*common_noise, plus
//    0.04*sin(TAU*0.043*rate*t) and
//    0.03*sin(TAU*(0.061+0.004*channel)*rate*t+0.5*channel).
// Noise is xorshift32 (13 left, 17 right, 5 left); its upper 24 bits map
// to [-1,1] as 2*bits/16777215-1. Seeds: common=0x6d2b79f5,
// channel 0=0x9e3779b9, channel 1=0x243f6a88. Each state advances once
// per noise-section sample frame; channel 0 is unchanged by stereo/mono.
// Absolute amplitude bounds are 0.63, 0.795 and 0.31 before quantization.
// Conversion is round(value*32768), clamped to the signed 16-bit range;
// interleaved samples are packed explicitly as low byte, then high byte.

integer :: proc(value, name: string) -> int {
	result, ok := strconv.parse_int(value)
	if !ok {
		fmt.eprintfln("invalid %s: %s", name, value)
		os.exit(2)
	}
	return result
}

noise_sample :: proc(state: ^u32) -> f64 {
	state^ ~= state^ << 13
	state^ ~= state^ >> 17
	state^ ~= state^ << 5
	return 2 * f64(state^ >> 8) / 16777215 - 1
}

signal_sample :: proc(
	section, sample, channel, rate, section_samples: int,
	common_noise, channel_noise: f64,
) -> f64 {
	t := f64(sample) / f64(rate)
	c := f64(channel)
	switch section {
	case 0:
		duration := f64(section_samples) / f64(rate)
		tones :=
			0.24 * math.sin(math.TAU * min(997.0, 0.071 * f64(rate)) * t) +
			0.11 * math.sin(math.TAU * min(3001.0, 0.17 * f64(rate)) * t + 0.2) +
			0.13 * math.sin(math.TAU * min(1373.0 + 431 * c, 0.13 * f64(rate)) * t + 0.7 * c)
		chirp_phase :=
			math.TAU * (0.011 * f64(rate) * t + 0.5 * 0.359 * f64(rate) * t * t / duration) +
			0.3 * c
		return(
			(0.85 + 0.15 * math.sin(math.TAU * 1.7 * t)) *
			(tones + 0.15 * math.sin(chirp_phase)) \
		)
	case 1:
		period := max(1, rate / 11)
		burst_length := max(1, rate / 250)
		position := sample % period
		value := 0.025 * math.sin(math.TAU * min(241.0, 0.02 * f64(rate)) * t + 0.2 * c)
		if position < burst_length {
			envelope := 1 - f64(position) / f64(burst_length)
			value +=
				0.55 * envelope * envelope * math.sin(math.TAU * 0.23 * f64(position) + 0.4 * c)
		}
		if position == 0 {
			value += (sample / period + channel) % 2 == 0 ? 0.22 : -0.22
		}
		return value
	case 2:
		return(
			0.18 * channel_noise +
			0.06 * common_noise +
			0.04 * math.sin(math.TAU * 0.043 * f64(rate) * t) +
			0.03 * math.sin(math.TAU * (0.061 + 0.004 * c) * f64(rate) * t + 0.5 * c) \
		)
	}
	panic("invalid fixture section")
}

main :: proc() {
	if len(os.args) != 4 && len(os.args) != 5 {
		fmt.eprintln("usage: audio_fixture output.s16le sample_rate channels [seconds=12]")
		os.exit(2)
	}
	rate := integer(os.args[2], "sample rate")
	channels := integer(os.args[3], "channels")
	seconds := len(os.args) == 5 ? integer(os.args[4], "seconds") : 12
	if rate <= 0 || channels < 1 || channels > 2 || seconds <= 0 || rate > max(int) / seconds {
		fmt.eprintln(
			"require positive rate/seconds, one or two channels, and a representable sample count",
		)
		os.exit(2)
	}
	sample_frames := rate * seconds
	if sample_frames < 3 || sample_frames % 3 != 0 || sample_frames > max(int) / (2 * channels) {
		fmt.eprintln(
			"sample frames must split into three equal nonempty sections and fit the byte count",
		)
		os.exit(2)
	}
	section_samples := sample_frames / 3
	data := make([]u8, sample_frames * channels * 2)
	defer delete(data)
	common_state: u32 = 0x6d2b79f5
	channel_states := [2]u32{0x9e3779b9, 0x243f6a88}
	energy: [3]f64
	peak: [3]i32
	for section in 0 ..< 3 {
		for n in 0 ..< section_samples {
			common_noise: f64
			if section == 2 do common_noise = noise_sample(&common_state)
			for channel in 0 ..< channels {
				channel_noise: f64
				if section == 2 do channel_noise = noise_sample(&channel_states[channel])
				value := signal_sample(
					section,
					n,
					channel,
					rate,
					section_samples,
					common_noise,
					channel_noise,
				)
				if math.is_nan(value) || math.is_inf(value) || value < -1 || value > 1 {
					fmt.eprintln("fixture produced an invalid floating-point sample")
					os.exit(1)
				}
				pcm := i16(clamp(math.round(value * 32768), -32768, 32767))
				word := u16(pcm)
				index := 2 * ((section * section_samples + n) * channels + channel)
				data[index], data[index + 1] = u8(word & 255), u8(word >> 8)
				normalized := f64(pcm) / 32768
				energy[section] += normalized * normalized
				peak[section] = max(peak[section], abs(i32(pcm)))
			}
		}
	}
	if err := os.write_entire_file(os.args[1], data); err != nil {
		fmt.eprintln("cannot write PCM fixture:", err)
		os.exit(1)
	}
	fmt.printfln(
		"PCM fixture: formula=native_audio_v1 rate=%d channels=%d seconds=%d original_samples_per_channel=%d section_samples_per_channel=%d bytes=%d",
		rate,
		channels,
		seconds,
		sample_frames,
		section_samples,
		len(data),
	)
	names := [3]string{"tone_chirp", "transient", "noise"}
	for section in 0 ..< 3 {
		fmt.printfln(
			"section=%s signal_energy=%.12f signal_rms=%.9f peak_s16=%d",
			names[section],
			energy[section],
			math.sqrt(energy[section] / f64(section_samples * channels)),
			peak[section],
		)
	}
}

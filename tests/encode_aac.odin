package main

import enc "../audio/aac/encoder"
import "core:fmt"
import "core:os"
import "core:strconv"

main :: proc() {
	if len(os.args) < 6 {
		fmt.eprintln(
			"usage: encode_aac input.s16le sample_rate channels bit_rate output.aac [--frame-samples 1024|960] [--transport adts|loas|raw] [--disable-pns] [--disable-tns]",
		)
		os.exit(2)
	}
	integer :: proc(s: string) -> int {
		n, ok := strconv.parse_int(s)
		if !ok {fmt.eprintln("invalid integer:", s); os.exit(2)}
		return n
	}
	config := enc.Config {
		sample_rate = integer(os.args[2]),
		channels    = integer(os.args[3]),
		bit_rate    = integer(os.args[4]),
	}
	transport := enc.Transport.ADTS
	options: enc.Options
	index := 6
	for index < len(os.args) {
		name := os.args[index]
		index += 1
		if name == "--disable-pns" {options.disable_pns = true; continue}
		if name == "--disable-tns" {options.disable_tns = true; continue}
		if index == len(os.args) {fmt.eprintln("missing value for", name); os.exit(2)}
		value := os.args[index]; index += 1
		switch name {
		case "--frame-samples":
			config.frame_samples = integer(value)
		case "--transport":
			switch value {
			case "adts":
				transport = .ADTS
			case "loas":
				transport = .LOAS
			case "raw":
				transport = .Raw
			case:
				fmt.eprintln("invalid transport:", value); os.exit(2)
			}
		case:
			fmt.eprintln("unknown option:", name); os.exit(2)
		}
	}
	// Large state is owned by this invocation, outside the small main stack.
	e := new(enc.Encoder)
	if e == nil {fmt.eprintln(enc.Error.Allocation_Failed); os.exit(1)}
	defer free(e)
	if error := enc.init_encoder(e, config, transport, options);
	   error != .None {fmt.eprintln(error); os.exit(2)}
	defer enc.destroy_encoder(e)
	data, error := os.read_entire_file(os.args[1], context.allocator)
	if error != nil {fmt.eprintln(error); os.exit(1)}
	defer delete(data)
	if len(data) % (2 * config.channels) !=
	   0 {fmt.eprintln("incomplete PCM sample frame"); os.exit(2)}
	out: [dynamic]u8
	defer delete(out)
	samples, pos := len(data) / 2, 0
	frame_values := e.frame_samples * config.channels
	for pos < samples {
		pcm: [8 * 1024]f32
		count := min(samples - pos, frame_values)
		for i in 0 ..< count {
			v := i16(u16(data[2 * (pos + i)]) | u16(data[2 * (pos + i) + 1]) << 8)
			pcm[i] = f32(v) / 32768
		}
		if error := enc.encode_frame(e, pcm[:frame_values], &out);
		   error != .None {fmt.eprintln(error); os.exit(1)}
		pos += count
	}
	if error := enc.flush_encoder(e, &out); error != .None {fmt.eprintln(error); os.exit(1)}
	if os.write_entire_file(os.args[5], out[:]) != nil do os.exit(1)
	fmt.printfln(
		"AAC-LC: sample_rate=%d channels=%d frame_samples=%d transport=%v input_samples=%d delay=%d frames=%d bytes=%d pns_disabled=%v",
		config.sample_rate,
		config.channels,
		e.frame_samples,
		transport,
		samples / config.channels,
		enc.encoder_delay(e),
		e.frames,
		len(out),
		options.disable_pns,
	)
}

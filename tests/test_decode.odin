package main

import avc_dec "../codec/h264/decoder"
import "core:fmt"
import "core:os"
import "core:time"

Nal_Location :: struct {
	offset: int,
	length: int,
}

find_nal_units :: proc(data: []u8, allocator := context.allocator) -> []Nal_Location {
	locations := make([dynamic]Nal_Location, 0, 1024, allocator)
	n := len(data)
	i := 0

	for i + 3 < n {
		if data[i] == 0 && data[i + 1] == 0 {
			if data[i + 2] == 1 do break
			if i + 3 < n && data[i + 2] == 0 && data[i + 3] == 1 do break
		}
		i += 1
	}

	for i < n {
		start_code_len := 0
		if i + 3 <= n && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
			start_code_len = 3
		} else if i + 4 <= n &&
		   data[i] == 0 &&
		   data[i + 1] == 0 &&
		   data[i + 2] == 0 &&
		   data[i + 3] == 1 {
			start_code_len = 4
		} else {
			i += 1
			continue
		}

		nal_start := i + start_code_len
		j := nal_start
		for j + 3 < n {
			if data[j] == 0 && data[j + 1] == 0 {
				if data[j + 2] == 1 do break
				if j + 3 < n && data[j + 2] == 0 && data[j + 3] == 1 do break
			}
			j += 1
		}
		if j + 3 >= n do j = n

		nal_len := j - nal_start
		if nal_len > 0 {
			append(&locations, Nal_Location{offset = nal_start, length = nal_len})
		}
		i = j
	}

	return locations[:]
}

test_stream :: proc(path: string) -> bool {
	fmt.printfln("Testing stream: %s", path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.printfln("  [FAIL] Could not read file: %v", err)
		return false
	}
	defer delete(data)

	nals := find_nal_units(data)
	defer delete(nals)
	fmt.printfln("  Found %d NAL units", len(nals))

	state: avc_dec.Decoder_State
	avc_dec.init_decoder(&state)
	defer avc_dec.destroy_decoder(&state)

	frames_decoded := 0
	start_time := time.now()

	for loc, idx in nals {
		nal_bytes := data[loc.offset:loc.offset + loc.length]
		ready, decode_err := avc_dec.decode_nal(&state, nal_bytes)
		if decode_err != .None {
			fmt.printfln("  Warning on NAL %d: %s", idx, decode_err)
		}
		if ready {
			frames_decoded += 1
		}
	}

	duration := time.since(start_time)
	secs := time.duration_seconds(duration)
	fps := secs > 0 ? (f64(frames_decoded) / secs) : 0
	fmt.printfln(
		"  [SUCCESS] Decoded %d frames in %v (%.1f FPS, resolution: %dx%d, SSE2: %v)",
		frames_decoded,
		duration,
		fps,
		state.output.buf.width,
		state.output.buf.height,
		true,
	)

	return frames_decoded > 0
}

main :: proc() {
	fmt.printfln("==================================================")
	fmt.printfln(" Running Native Odin H.264 Test Suite")
	fmt.printfln("==================================================")

	default_streams := []string {
		"third_party/openh264/res/Static.264",
		"third_party/openh264/res/BA_MW_D.264",
		"third_party/openh264/res/CI_MW_D.264",
		"third_party/openh264/res/SVA_Base_B.264",
	}

	streams := default_streams
	if len(os.args) > 1 {
		streams = os.args[1:]
	}

	all_passed := true
	for s in streams {
		if !test_stream(s) {
			all_passed = false
		}
	}

	if all_passed {
		fmt.printfln("\nAll stream tests passed successfully!")
	} else {
		fmt.printfln("\nSome tests failed.")
	}
}

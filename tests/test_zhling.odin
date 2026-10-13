package main

import h264 "../codec/h264"
import avc_dec "../codec/h264/decoder"
import "core:fmt"
import "core:os"
import "core:time"

main :: proc() {
	data, err := os.read_entire_file(
		"third_party/openh264/res/Zhling_1280x720.264",
		context.allocator,
	)
	if err != nil do return
	defer delete(data)

	nals := make([dynamic]h264.Nal_Location, 0, 1024)
	defer delete(nals)
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
		sc_len := 0
		if i + 3 <= n && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
			sc_len = 3
		} else if i + 4 <= n &&
		   data[i] == 0 &&
		   data[i + 1] == 0 &&
		   data[i + 2] == 0 &&
		   data[i + 3] == 1 {
			sc_len = 4
		} else {
			i += 1
			continue
		}
		start := i + sc_len
		j := start
		for j + 3 < n {
			if data[j] == 0 && data[j + 1] == 0 {
				if data[j + 2] == 1 do break
				if j + 3 < n && data[j + 2] == 0 && data[j + 3] == 1 do break
			}
			j += 1
		}
		if j + 3 >= n do j = n
		append(&nals, h264.Nal_Location{offset = start, length = j - start})
		i = j
	}

	state: avc_dec.Decoder_State
	avc_dec.init_decoder(&state)
	defer avc_dec.destroy_decoder(&state)

	t0 := time.now()
	reps :: 50
	frames := 0
	for _ in 0 ..< reps {
		for loc in nals {
			ready, _ := avc_dec.decode_nal(&state, data[loc.offset:loc.offset + loc.length])
			if ready do frames += 1
		}
	}
	dur := time.since(t0)
	fmt.printfln(
		"Decoded %d frames in %v (%.1f FPS)",
		frames,
		dur,
		f64(frames) / time.duration_seconds(dur),
	)
}

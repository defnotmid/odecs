package main

// Decodes a raw AV1 OBU stream with Vulkan Video and writes its shown frames
// as raw YUV 4:2:0 (bytes at 8 bits, little-endian u16 above) for
// tests/av1_check.sh to compare with FFmpeg's libdav1d.

import vulkan "../media/vulkan"
import av1 "../video/av1"
import "core:fmt"
import "core:os"
import "core:time"

Sink :: struct {
	out:    ^os.File,
	frames: int,
	bytes:  [dynamic]u8,
}

receive :: proc(frame: vulkan.AV1_Frame, user: rawptr) {
	s := (^Sink)(user)
	clear(&s.bytes)
	vulkan.append_frame_samples(&s.bytes, frame)
	os.write(s.out, s.bytes[:])
	s.frames += 1
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: av1_decode in.obu out.yuv")
		os.exit(2)
	}
	data, rerr := os.read_entire_file(os.args[1], context.allocator)
	if rerr != nil do os.exit(1)
	out, oerr := os.create(os.args[2])
	if oerr != nil do os.exit(1)
	defer os.close(out)
	d: vulkan.AV1_Decoder
	if err := vulkan.init_av1_decoder(&d, {}); err != .None {
		fmt.eprintln("init:", err)
		os.exit(1)
	}
	defer vulkan.destroy_av1_decoder(&d)
	sink := Sink {
		out = out,
	}
	start := time.now()
	unit := 0
	for at := 0; at < len(data); {
		// A temporal unit runs to the next temporal delimiter.
		end := at
		for end < len(data) {
			o, next, err := av1.next_obu(data, end)
			if err != .None {
				fmt.eprintln("obu:", err)
				os.exit(1)
			}
			if o.type == .Temporal_Delimiter && end > at do break
			end = next
		}
		if err := vulkan.decode_av1_temporal_unit(&d, data[at:end], receive, &sink); err != .None {
			fmt.eprintln("unit", unit, ":", err)
			os.exit(1)
		}
		unit += 1
		at = end
	}
	vulkan.flush_av1_decoder(&d, receive, &sink)
	fmt.eprintfln("%d frames, %d units, %.2f ms", sink.frames, unit, time.duration_milliseconds(time.since(start)))
}

package main

import vulkan "../media/vulkan"
import h264 "../h264"
import "core:fmt"
import "core:os"

State :: struct {
	data:   [dynamic]u8,
	frames: int,
}
receive :: proc(frame: vulkan.H265_Frame, user: rawptr) {
	s := cast(^State)user
	vulkan.append_frame_samples(&s.data, frame)
	s.frames += 1
}
main :: proc() {
	if len(os.args) != 3 {fmt.eprintln("usage: gpu_h265_decode stream.265 output.yuv"); os.exit(2)}
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil do os.exit(1)
	defer delete(data)
	nals := h264.find_nal_units(data)
	defer delete(nals)
	d: vulkan.H265_Decoder
	if e := vulkan.init_h265_decoder(&d, {device_index = -1});
	   e != .None {fmt.eprintln("init:", e); os.exit(1)}
	defer vulkan.destroy_h265_decoder(&d)
	s: State
	defer delete(s.data)
	for nal, i in nals {
		if e := vulkan.decode_h265_nal(&d, data[nal.offset:nal.offset + nal.length], receive, &s);
		   e != .None {
			fmt.eprintln("decode NAL", i, "failed:", e); os.exit(1)
		}
	}
	if e := vulkan.flush_h265_decoder(&d, receive, &s);
	   e != .None {fmt.eprintln("flush:", e); os.exit(1)}
	if e := os.write_entire_file(os.args[2], s.data[:]); e != nil do os.exit(1)
	fmt.printfln("%d hardware HEVC frames, %d bytes", s.frames, len(s.data))
}

package main

import vulkan "../media/vulkan"
import avc "../h264"
import "core:fmt"
import "core:os"

State :: struct {
	data:   [dynamic]u8,
	frames: int,
}
receive :: proc(frame: vulkan.H264_Frame, user: rawptr) {
	s := cast(^State)user
	vulkan.append_frame_samples(&s.data, frame)
	s.frames += 1
}
main :: proc() {
	if len(os.args) != 3 {fmt.eprintln("usage: gpu_h264_decode stream.264 output.yuv"); os.exit(2)}
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil do os.exit(1)
	defer delete(data)
	nals := avc.find_nal_units(data)
	defer delete(nals)
	d: vulkan.H264_Decoder
	if e := vulkan.init_h264_decoder(&d, {device_index = -1});
	   e != .None {fmt.eprintln("init:", e); os.exit(1)}
	defer vulkan.destroy_h264_decoder(&d)
	s: State
	defer delete(s.data)
	for nal, i in nals {
		if e := vulkan.decode_h264_nal(&d, data[nal.offset:nal.offset + nal.length], receive, &s);
		   e != .None {
			fmt.eprintln("decode NAL", i, "failed:", e); os.exit(1)
		}
	}
	if e := vulkan.flush_h264_decoder(&d, receive, &s);
	   e != .None {fmt.eprintln("flush:", e); os.exit(1)}
	if e := os.write_entire_file(os.args[2], s.data[:]); e != nil do os.exit(1)
	fmt.printfln("%d hardware AVC frames, %d bytes", s.frames, len(s.data))
}

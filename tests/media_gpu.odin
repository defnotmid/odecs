// Common-API integration gate. --hardware refuses software fallback on both
// encode and decode. Native and Vulkan pixels must match, including final drain.
// Optional arguments: prefix h264|h265 depth gop frames width height.
package main

import media "../media"
import native "../media/native"
import vulkan "../media/vulkan"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"

Sink :: struct {
	stream, pixels:               [dynamic]u8,
	frames, width, height, depth: int,
}
packet_output :: proc(packet: media.Packet, user: rawptr) {
	s := (^Sink)(user)
	append(&s.stream, ..packet.data)
}
frame_output :: proc(frame: media.Video_Frame, user: rawptr) {
	s := (^Sink)(user)
	if media.validate_frame(frame) != .None || frame.width != s.width || frame.height != s.height || frame.bit_depth != s.depth do os.exit(1)
	for i in 0 ..< 3 {
		w, h := i == 0 ? frame.width : frame.width / 2, i == 0 ? frame.height : frame.height / 2
		for row in 0 ..< h {
			data := frame.planes[i].data[row * frame.planes[i].stride:]
			if frame.storage_bits ==
			   8 {append(&s.pixels, ..data[:w])} else if frame.bit_depth > 8 {append(&s.pixels, ..data[:w * 2])} else {for col in 0 ..< w do append(&s.pixels, data[col * 2])}
		}
	}
	s.frames += 1
}
check :: proc(err: media.Error) {if err != .None {fmt.eprintln(err); os.exit(1)}}
argument_int :: proc(index, fallback: int) -> int {
	if len(os.args) <= index do return fallback
	value, ok := strconv.parse_int(os.args[index]); if !ok do os.exit(1)
	return value
}

main :: proc() {
	hardware := len(os.args) > 1 && os.args[1] == "--hardware"
	prefix := len(os.args) > 2 ? os.args[2] : "/tmp/oicut-media"
	codec: media.Codec = .H264
	if len(os.args) > 3 {
		if os.args[3] == "h265" {codec = .H265} else if os.args[3] != "h264" do os.exit(1)
	}
	depth, gop, frames := argument_int(4, 8), argument_int(5, 15), argument_int(6, 37)
	w, h := argument_int(7, 320), argument_int(8, 240)
	if frames < 1 || frames > 1000 do os.exit(1)
	providers := []media.Provider{native.provider(), vulkan.provider()}
	config := media.default_config(codec, .Encode)
	config.width, config.height, config.bit_depth, config.gop_size = w, h, depth, gop
	if hardware do config.preference = .Require_Hardware
	encoder: media.Session
	check(media.open(&encoder, config, providers)); defer media.close(&encoder)
	fmt.printfln(
		"selected=%s hardware_admission=%v",
		encoder.provider_name,
		encoder.hardware_error,
	)
	sink := Sink {
		width  = w,
		height = h,
		depth  = depth,
	}
	defer {delete(sink.stream); delete(sink.pixels)}
	sample_bytes := depth > 8 ? 2 : 1
	planes: [3][]u8
	defer for plane in planes do delete(plane)
	for &plane, i in planes do plane = make([]u8, (i == 0 ? w * h : w * h / 4) * sample_bytes)
	frame := media.Video_Frame {
		width        = w,
		height       = h,
		bit_depth    = depth,
		storage_bits = sample_bytes * 8,
		chroma       = .YUV420,
	}
	for plane, i in planes do frame.planes[i] = {plane, (i == 0 ? w : w / 2) * sample_bytes}
	mask := (1 << uint(depth)) - 1
	for f in 0 ..< frames {
		for plane, i in planes {
			pw, ph := i == 0 ? w : w / 2, i == 0 ? h : h / 2
			for row in 0 ..< ph do for col in 0 ..< pw {
				value := i == 0 ? (col + row + f * 17) & mask : ((i == 1 ? 80 : 170) + f * (i == 1 ? 20 : -15)) & mask
				at := (row * pw + col) * sample_bytes
				plane[at] = u8(value & 255)
				if sample_bytes == 2 do plane[at + 1] = u8(value >> 8)
			}
		}
		check(media.encode_video(&encoder, frame, {packet = packet_output, user = &sink}))
	}
	check(media.drain(&encoder, {packet = packet_output, user = &sink}))
	check(media.close(&encoder))
	extension := codec == .H264 ? "264" : "265"
	if os.write_entire_file(fmt.tprintf("%s.%s", prefix, extension), sink.stream[:]) != nil do os.exit(1)
	config.operation, config.preference = .Decode, .Native
	decoder: media.Session
	check(media.open(&decoder, config, providers)); defer media.close(&decoder)
	check(
		media.decode(
			&decoder,
			{data = sink.stream[:], framing = .Annex_B},
			{video = frame_output, user = &sink},
		),
	)
	check(media.drain(&decoder, {video = frame_output, user = &sink}))
	check(media.close(&decoder))
	if sink.frames !=
	   frames {fmt.eprintfln("decoded %d frames, expected %d", sink.frames, frames); os.exit(1)}
	if hardware {
		actual := Sink {
			width  = w,
			height = h,
			depth  = depth,
		}; defer delete(actual.pixels)
		config.preference = .Require_Hardware
		check(media.open(&decoder, config, providers))
		check(
			media.decode(
				&decoder,
				{data = sink.stream[:], framing = .Annex_B},
				{video = frame_output, user = &actual},
			),
		)
		check(media.drain(&decoder, {video = frame_output, user = &actual}))
		check(media.close(&decoder))
		if actual.frames != frames ||
		   !slice.equal(
				   actual.pixels[:],
				   sink.pixels[:],
			   ) {fmt.eprintln("Vulkan/native decoded pixels differ"); os.exit(1)}
	}
	if os.write_entire_file(fmt.tprintf("%s.yuv", prefix), sink.pixels[:]) != nil do os.exit(1)
	fmt.printfln(
		"frames=%d bytes=%d pixels=%d depth=%d gop=%d native/hardware_exact=%v",
		sink.frames,
		len(sink.stream),
		len(sink.pixels),
		depth,
		gop,
		hardware,
	)
}

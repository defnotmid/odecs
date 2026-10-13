// Public-API integration gate: decode -> borrowed GPU image -> encode on one
// Context, compared with native decode -> host upload on the same GPU.
package main

import gpu "../codec/gpu"
import media "../codec/media"
import native "../codec/media/native"
import vulkan "../codec/media/vulkan"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"

Sink :: struct {
	stream, pixels: [dynamic]u8,
	frames:         int,
}
Pipeline :: struct {
	shared:                   ^gpu.Context,
	encoder:                  ^media.Session,
	sink:                     ^Sink,
	left, top, width, height: int,
	device:                   bool,
	refusals:                 int,
}
fail :: proc(message: string) {fmt.eprintln(message); os.exit(1)}
check :: proc(err: media.Error) {if err != .None {fmt.eprintln(err); os.exit(1)}}
check_gpu :: proc(err: gpu.Error) {if err != .None {fmt.eprintln(err); os.exit(1)}}
integer :: proc(index: int) -> int {v, ok := strconv.parse_int(os.args[index]); if !ok do fail("invalid integer")
	return v}
packet_output :: proc(packet: media.Packet, user: rawptr) {append(
		&((^Sink)(user)).stream,
		..packet.data,
	)}
pixel_output :: proc(frame: media.Video_Frame, user: rawptr) {
	s := (^Sink)(user)
	check(media.validate_frame(frame))
	for p, i in frame.planes {
		w, h := i == 0 ? frame.width : frame.width / 2, i == 0 ? frame.height : frame.height / 2
		for row in 0 ..< h {
			data := p.data[row * p.stride:]
			if frame.bit_depth > 8 ||
			   frame.storage_bits ==
				   8 {append(&s.pixels, ..data[:w * (frame.bit_depth > 8 ? 2 : 1)])} else {for col in 0 ..< w do append(&s.pixels, data[col * 2])}
		}
	}
	s.frames += 1
}

refuse :: proc(p: ^Pipeline, frame: media.Video_Frame, expected: media.Error = .Invalid_Input) {
	err := media.encode_video(p.encoder, frame, {packet = packet_output, user = p.sink})
	if err != expected || p.encoder.failed do fail("invalid device input advanced or poisoned the encoder")
	p.refusals += 1
}

transcode :: proc(decoded: media.Video_Frame, user: rawptr) {
	frame := decoded
	p := (^Pipeline)(user)
	if frame.width < p.left + p.width || frame.height < p.top + p.height do fail("source crop out of bounds")
	if p.device {
		if frame.storage != .Device || len(frame.planes[0].data) != 0 do fail("hardware decode unexpectedly returned host pixels")
		s := vulkan.surface(frame)
		if s == nil || s.device != gpu.context_descriptor(p.shared).device do fail("decoder did not borrow the shared device")
		frame.crop_x += p.left
		frame.crop_y += p.top
		if p.sink.frames == 0 {
			bad := s^
			bad_frame := frame
			bad_frame.width, bad_frame.height = p.width, p.height
			bad_frame.surface = &bad
			bad.device = nil; refuse(p, bad_frame, .Unsupported); bad = s^
			bad.usage = {}; refuse(p, bad_frame, .Unsupported); bad = s^
			bad.bit_depth = 12; refuse(p, bad_frame, .Unsupported); bad = s^
			bad.format = .UNDEFINED; refuse(p, bad_frame, .Unsupported); bad = s^
			bad.layout = .UNDEFINED; refuse(p, bad_frame, .Unsupported); bad = s^
			bad.ready_value = 0; refuse(p, bad_frame); bad = s^
			bad.ready_semaphore = 0; refuse(p, bad_frame); bad = s^
			bad.width = s.width + 1; refuse(p, bad_frame); bad = s^
			bad.width = max(int) - 1
			bad_frame.crop_x = int(max(i32)) + 1; refuse(p, bad_frame); bad = s^
			bad_frame.crop_x = max(int); refuse(p, bad_frame)
			bad_frame.crop_x = frame.crop_x + 1; refuse(p, bad_frame)
		}
	} else {
		if frame.storage != .Host do fail("native decode did not return host pixels")
		for &plane, i in frame.planes {
			left, top := i == 0 ? p.left : p.left / 2, i == 0 ? p.top : p.top / 2
			plane.data = plane.data[top * plane.stride + left * (frame.storage_bits / 8):]
		}
	}
	frame.width, frame.height = p.width, p.height
	check(media.encode_video(p.encoder, frame, {packet = packet_output, user = p.sink}))
	p.sink.frames += 1
}

decode_pixels :: proc(stream: []u8, source_config: media.Config, sink: ^Sink) {
	config := source_config
	config.operation, config.preference, config.output_storage = .Decode, .Native, .Host
	session: media.Session
	check(
		media.open(&session, config, []media.Provider{native.provider()}),
	); defer media.close(&session)
	check(
		media.decode(
			&session,
			{data = stream, framing = .Annex_B},
			{video = pixel_output, user = sink},
		),
	)
	check(media.drain(&session, {video = pixel_output, user = sink}))
}

main :: proc() {
	if len(os.args) != 7 && len(os.args) != 11 do fail("usage: media_pipeline input.264|265 h264|h265 width height depth prefix [left top output_width output_height]")
	codec: media.Codec = .H265
	if os.args[2] == "h264" {codec = .H264} else if os.args[2] != "h265" do fail("invalid codec")
	w, h, depth := integer(3), integer(4), integer(5)
	left, top, ow, oh := 0, 0, w, h
	if len(os.args) == 11 {left, top, ow, oh = integer(7), integer(8), integer(9), integer(10)}
	if left < 0 || top < 0 || left % 2 != 0 || top % 2 != 0 || ow < 16 || oh < 16 || ow % 2 != 0 || oh % 2 != 0 || ow > w || oh > h || left > w - ow || top > h - oh do fail("invalid visible crop")
	input, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil do fail("cannot read source")
	defer delete(input)
	gc := codec == .H264 ? gpu.Codec.H264 : gpu.Codec.H265
	requests := []gpu.Request {
		{
			codec = gc,
			operation = .Decode,
			width = w,
			height = h,
			bit_depth = depth,
			require_compute = true,
		},
		{codec = gc, operation = .Encode, width = ow, height = oh, bit_depth = depth},
	}
	shared: gpu.Context
	check_gpu(gpu.init_context(&shared, {requests = requests, device_index = -1}))
	defer check_gpu(gpu.destroy_context(&shared))
	providers := []media.Provider{vulkan.provider(&shared)}
	config := media.default_config(codec, .Encode)
	config.width, config.height, config.bit_depth, config.preference =
		ow, oh, depth, .Require_Hardware
	device_encoder, host_encoder, decoder: media.Session
	check(media.open(&device_encoder, config, providers)); defer media.close(&device_encoder)
	check(media.open(&host_encoder, config, providers)); defer media.close(&host_encoder)
	config.operation, config.width, config.height, config.output_storage = .Decode, w, h, .Device
	check(media.open(&decoder, config, providers)); defer media.close(&decoder)
	// The lazy decoder already holds the Context before its first SPS.
	if gpu.destroy_context(&shared) != .Busy do fail("live sessions did not retain the Context")
	actual, expected := Sink{}, Sink{}
	defer {delete(actual.stream); delete(actual.pixels); delete(expected.stream)
		delete(expected.pixels)}
	pipeline := Pipeline {
		shared  = &shared,
		encoder = &device_encoder,
		sink    = &actual,
		left    = left,
		top     = top,
		width   = ow,
		height  = oh,
		device  = true,
	}
	check(
		media.decode(
			&decoder,
			{data = input, framing = .Annex_B},
			{video = transcode, user = &pipeline},
		),
	)
	check(media.drain(&decoder, {video = transcode, user = &pipeline}))
	check(media.drain(&device_encoder, {packet = packet_output, user = &actual}))
	if actual.frames == 0 do fail("no device frames")
	check(media.close(&decoder))
	check(media.close(&device_encoder))
	if gpu.context_descriptor(&shared).device == nil do fail("closing borrowed sessions destroyed their shared device")
	config.preference, config.output_storage = .Native, .Host
	check(media.open(&decoder, config, []media.Provider{native.provider()}))
	pipeline.encoder, pipeline.sink, pipeline.device = &host_encoder, &expected, false
	check(
		media.decode(
			&decoder,
			{data = input, framing = .Annex_B},
			{video = transcode, user = &pipeline},
		),
	)
	check(media.drain(&decoder, {video = transcode, user = &pipeline}))
	check(media.drain(&host_encoder, {packet = packet_output, user = &expected}))
	check(media.close(&decoder))
	check(media.close(&host_encoder))
	if actual.frames != expected.frames do fail("device/host frame counts differ")
	frames := actual.frames
	actual.frames, expected.frames = 0, 0
	config.width, config.height = ow, oh
	decode_pixels(actual.stream[:], config, &actual)
	decode_pixels(expected.stream[:], config, &expected)
	if actual.frames != frames || expected.frames != frames || !slice.equal(actual.pixels[:], expected.pixels[:]) do fail("device/host transcoded pixels differ")
	if !slice.equal(actual.stream[:], expected.stream[:]) do fail("device copy and host upload produced different bitstreams")
	ext := codec == .H264 ? "264" : "265"
	if os.write_entire_file(fmt.tprintf("%s.%s", os.args[6], ext), actual.stream[:]) != nil do fail("cannot save bitstream")
	if os.write_entire_file(fmt.tprintf("%s.yuv", os.args[6]), actual.pixels[:]) != nil do fail("cannot save pixels")
	check_gpu(gpu.destroy_context(&shared))
	fmt.printfln(
		"shared_device_pipeline frames=%d refusals=%d size=%dx%d depth=%d crop=%d,%d bitstream/pixels_exact=true",
		frames,
		pipeline.refusals,
		ow,
		oh,
		depth,
		left,
		top,
	)
}

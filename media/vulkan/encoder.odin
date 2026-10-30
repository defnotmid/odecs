package media_vulkan

@(require) import "core:fmt" // the opt-in OICUT_GPU_TRACE output
import vk "vendor:vulkan"

// Progressive H.264 High / HEVC Main or Main10, 4:2:0, constant QP, low-delay
// P pictures and periodic IDRs carrying driver-generated parameter sets.
Config :: struct {
	codec:            Codec,
	bit_depth:        int, // zero selects 8-bit
	width, height:    int,
	qp:               int,
	gop_size:         int, // zero selects all-intra; maximum 32768
	device_index:     int, // -1 selects a compatible GPU, preferring discrete devices
	max_packet_bytes: int, // 0 selects a bound based on the raw picture size
	shared_context:   ^Context, // optional borrowed shared device; keep at a stable address
	// Pictures in flight, up to MAX_FRAMES_IN_FLIGHT. 0 or 1 returns each
	// packet from its own encode call; N keeps up to N pictures on the GPU
	// and returns each packet N-1 calls later, in order. After the last
	// picture, call flush_encoder until it returns no packet.
	frames_in_flight: int,
	// VUI colour description in ITU-T H.273 code points; zero primaries
	// leaves it unsignalled.
	colour_primaries, transfer, matrix_coefficients: u8,
	full_range:       bool,
}

Plane :: struct {
	data:   []u8,
	stride: int,
}
Plane16 :: struct {
	data:   []u16,
	stride: int,
}

// Most pictures an encoder holds between submission and packet return.
MAX_FRAMES_IN_FLIGHT :: 8

Encoder :: struct {
	config:              Config,
	device:              Device,
	session:             vk.VideoSessionKHR,
	parameters:          vk.VideoSessionParametersKHR,
	session_memory:      [dynamic]vk.DeviceMemory,
	// Picture k uses slots[k % depth] from submission until its packet is
	// returned, so up to depth pictures upload, encode and wait at once.
	slots:               [MAX_FRAMES_IN_FLIGHT]Encode_Slot,
	depth:               int,
	reconstructed:       [2]Image,
	// Drivers without SEPARATE_REFERENCE_IMAGES require one layered image for
	// all DPB slots. It has its own lifetime; reconstructed[] stays empty.
	reconstructed_array: Image,
	query:               vk.QueryPool, // query i belongs to slots[i]
	// Timelines: picture k signals k+1 on uploaded once its input image is
	// written, and on encoded once its packet is in its bitstream buffer.
	uploaded, encoded:   vk.Semaphore,
	headers:             []u8,
	packet_buffer:       [dynamic]u8, // borrowed publication; retained until encoder destruction
	surface_copies:      [dynamic]vk.ImageCopy,
	encode_caps:         vk.VideoEncodeH264CapabilitiesKHR,
	h265_caps:           vk.VideoEncodeH265CapabilitiesKHR,
	initialized, failed: bool,
	submitted, returned: int, // pictures submitted / whose packets were returned
}

@(private)
Encode_Slot :: struct {
	input:             Image,
	upload, bitstream: Buffer, // upload is allocated on the slot's first host input
	transfer, command: Command,
}

init_encoder :: proc(e: ^Encoder, config: Config) -> (err: Error) {
	if e == nil || e.device.instance != nil do return .Invalid_Argument
	if config.width < 16 || config.height < 16 || config.width > 8192 || config.height > 8192 || config.width % 2 != 0 || config.height % 2 != 0 || config.qp < 0 || config.qp > 51 || config.device_index < -1 do return .Invalid_Argument
	if config.max_packet_bytes < 0 || config.max_packet_bytes > 1 << 30 do return .Invalid_Argument
	if config.gop_size < 0 || config.gop_size > 32768 do return .Invalid_Argument
	if config.frames_in_flight < 0 || config.frames_in_flight > MAX_FRAMES_IN_FLIGHT do return .Invalid_Argument
	e.config = config
	e.depth = max(1, config.frames_in_flight)
	if e.config.gop_size == 0 do e.config.gop_size = 1
	if e.config.bit_depth == 0 do e.config.bit_depth = 8
	if e.config.bit_depth != 8 && e.config.bit_depth != 10 do return .Unsupported
	if e.config.codec == .H264 && e.config.bit_depth != 8 do return .Unsupported
	defer if err != .None do destroy_encoder(e)
	r := Request {
		codec     = config.codec,
		operation = .Encode,
		width     = config.width,
		height    = config.height,
		bit_depth = e.config.bit_depth,
	}
	caps, encode_caps, h264_caps := open_device(&e.device, r, config.device_index, config.shared_context) or_return
	when #config(
		OICUT_GPU_TRACE,
		false,
	) {fmt.eprintln("Vulkan encoder:", string(cstring(raw_data(e.device.properties.deviceName[:]))), "DPB capability", caps.flags)}
	e.encode_caps = h264_caps
	if .DISABLED not_in encode_caps.rateControlModes || caps.maxDpbSlots < 1 do return .Unsupported
	if config.codec == .H264 && (config.qp < int(h264_caps.minQp) || config.qp > int(h264_caps.maxQp) || h264_caps.requiresGopRemainingFrames) do return .Unsupported
	if e.config.gop_size > 1 && (caps.maxDpbSlots < 2 || caps.maxActiveReferencePictures < 1 || (config.codec == .H264 && h264_caps.maxPPictureL0ReferenceCount < 1)) do return .Unsupported
	feedback: vk.VideoEncodeFeedbackFlagsKHR = {.BITSTREAM_BUFFER_OFFSET, .BITSTREAM_BYTES_WRITTEN}
	if encode_caps.supportedEncodeFeedbackFlags & feedback != feedback do return .Unsupported
	profile264 := vk.VideoEncodeH264ProfileInfoKHR {
		sType         = .VIDEO_ENCODE_H264_PROFILE_INFO_KHR,
		stdProfileIdc = vk.VideoH264ProfileIdc(100),
	}
	profile265 := vk.VideoEncodeH265ProfileInfoKHR {
		sType         = .VIDEO_ENCODE_H265_PROFILE_INFO_KHR,
		stdProfileIdc = vk.VideoH265ProfileIdc(i32(e.config.bit_depth == 10 ? 2 : 1)),
	}
	profile := vk.VideoProfileInfoKHR {
		sType               = .VIDEO_PROFILE_INFO_KHR,
		pNext               = &profile264,
		videoCodecOperation = {.ENCODE_H264},
		chromaSubsampling   = {._420},
		lumaBitDepth        = {._8},
		chromaBitDepth      = {._8},
	}
	if config.codec == .H265 {
		profile.pNext, profile.videoCodecOperation = &profile265, {.ENCODE_H265}
		if e.config.bit_depth == 10 {profile.lumaBitDepth, profile.chromaBitDepth = {._10}, {._10}}
		e.h265_caps = {
			sType = .VIDEO_ENCODE_H265_CAPABILITIES_KHR,
		}
		encode_caps.pNext = &e.h265_caps
		caps.pNext = &encode_caps
		if e.device.i.GetPhysicalDeviceVideoCapabilitiesKHR(e.device.physical, &profile, &caps) != .SUCCESS do return .Unsupported
		if config.qp < int(e.h265_caps.minQp) || config.qp > int(e.h265_caps.maxQp) || e.h265_caps.requiresGopRemainingFrames do return .Unsupported
		if e.config.gop_size > 1 && e.h265_caps.maxPPictureL0ReferenceCount < 1 do return .Unsupported
		caps.pNext, encode_caps.pNext = nil, nil
	}
	profiles := vk.VideoProfileListInfoKHR {
		sType        = .VIDEO_PROFILE_LIST_INFO_KHR,
		profileCount = 1,
		pProfiles    = cast([^]vk.VideoProfileInfoKHR)&profile,
	}
	extent := vk.Extent2D{u32(config.width), u32(config.height)}
	// Picture allocations include macroblock and device-required padding; the
	// visible extent remains exact and is represented by SPS cropping.
	aligned := vk.Extent2D {
		align_u32(extent.width, max(16, caps.pictureAccessGranularity.width)),
		align_u32(extent.height, max(16, caps.pictureAccessGranularity.height)),
	}
	format :=
		e.config.bit_depth == 10 ? vk.Format.G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16 : vk.Format.G8_B8R8_2PLANE_420_UNORM
	if !supports_format(&e.device, &profiles, format, {.VIDEO_ENCODE_SRC_KHR, .TRANSFER_DST}) || !supports_format(&e.device, &profiles, format, {.VIDEO_ENCODE_DPB_KHR}) do return .Unsupported
	info := vk.VideoSessionCreateInfoKHR {
		sType                      = .VIDEO_SESSION_CREATE_INFO_KHR,
		queueFamilyIndex           = e.device.queue_family,
		pVideoProfile              = &profile,
		pictureFormat              = format,
		maxCodedExtent             = extent,
		referencePictureFormat     = format,
		maxDpbSlots                = e.config.gop_size > 1 ? 2 : 1,
		maxActiveReferencePictures = e.config.gop_size > 1 ? 1 : 0,
		pStdHeaderVersion          = &caps.stdHeaderVersion,
	}
	if e.device.a.CreateVideoSessionKHR(e.device.handle, &info, nil, &e.session) != .SUCCESS do return .Driver_Error
	bind_session_memory(e) or_return
	if config.codec == .H264 {
		create_parameters(e, h264_caps.maxLevelIdc) or_return
	} else {
		create_h265_encoder_parameters(e) or_return
	}
	if .SEPARATE_REFERENCE_IMAGES not_in caps.flags && info.maxDpbSlots > 1 {
		alloc_image(&e.device, &e.reconstructed_array, aligned, format, {.VIDEO_ENCODE_DPB_KHR}, &profile, array_layers = info.maxDpbSlots) or_return
	} else {
		for i in 0 ..< int(info.maxDpbSlots) {
			alloc_image(&e.device, &e.reconstructed[i], aligned, format, {.VIDEO_ENCODE_DPB_KHR}, &profile) or_return
		}
	}
	raw_size :=
		int(aligned.width) * int(aligned.height) * 3 / 2 * (e.config.bit_depth == 10 ? 2 : 1)
	packet_bytes := config.max_packet_bytes
	if packet_bytes == 0 do packet_bytes = raw_size * 2 + 65536
	packet_bytes = int(
		align_u64(u64(packet_bytes), max(1, u64(caps.minBitstreamBufferSizeAlignment))),
	)
	if packet_bytes > 1 << 30 do return .Invalid_Argument
	for &slot in e.slots[:e.depth] {
		alloc_image(&e.device, &slot.input, aligned, format, {.VIDEO_ENCODE_SRC_KHR, .TRANSFER_DST}, &profile) or_return
		alloc_buffer(&e.device, &slot.bitstream, packet_bytes, {.VIDEO_ENCODE_DST_KHR}, &profile) or_return
		alloc_command(&e.device, &slot.transfer, e.device.transfer_family) or_return
		alloc_command(&e.device, &slot.command, e.device.queue_family) or_return
	}
	alloc_semaphore(&e.device, &e.uploaded, timeline = true) or_return
	alloc_semaphore(&e.device, &e.encoded, timeline = true) or_return
	query_feedback := vk.QueryPoolVideoEncodeFeedbackCreateInfoKHR {
		sType               = .QUERY_POOL_VIDEO_ENCODE_FEEDBACK_CREATE_INFO_KHR,
		pNext               = &profile,
		encodeFeedbackFlags = feedback,
	}
	query := vk.QueryPoolCreateInfo {
		sType      = .QUERY_POOL_CREATE_INFO,
		pNext      = &query_feedback,
		queryType  = .VIDEO_ENCODE_FEEDBACK_KHR,
		queryCount = u32(e.depth),
	}
	if e.device.a.CreateQueryPool(e.device.handle, &query, nil, &e.query) != .SUCCESS do return .Driver_Error
	e.initialized = true
	return .None
}

@(private)
align_u64 :: proc(value, alignment: u64) -> u64 {return(
		(value + alignment - 1) /
		alignment *
		alignment \
	)}
@(private)
align_u32 :: proc(value, alignment: u32) -> u32 {return(
		(value + alignment - 1) /
		alignment *
		alignment \
	)}

@(private)
supports_format :: proc(
	d: ^Device,
	profiles: ^vk.VideoProfileListInfoKHR,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	flags: vk.ImageCreateFlags = {},
) -> bool {
	return supports_physical_format(d, d.physical, profiles, format, usage, flags)
}

@(private)
supports_physical_format :: proc(
	d: ^Device,
	physical: vk.PhysicalDevice,
	profiles: ^vk.VideoProfileListInfoKHR,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	flags: vk.ImageCreateFlags = {},
) -> bool {
	if d.i.GetPhysicalDeviceVideoFormatPropertiesKHR == nil do return false
	info := vk.PhysicalDeviceVideoFormatInfoKHR {
		sType      = .PHYSICAL_DEVICE_VIDEO_FORMAT_INFO_KHR,
		pNext      = profiles,
		imageUsage = usage,
	}
	count: u32
	if d.i.GetPhysicalDeviceVideoFormatPropertiesKHR(physical, &info, &count, nil) != .SUCCESS do return false
	properties := make([]vk.VideoFormatPropertiesKHR, count); defer delete(properties)
	for &p in properties do p.sType = .VIDEO_FORMAT_PROPERTIES_KHR
	if d.i.GetPhysicalDeviceVideoFormatPropertiesKHR(physical, &info, &count, raw_data(properties)) != .SUCCESS do return false
	for p in properties[:count] {
		if p.format == format &&
		   p.imageType == .D2 &&
		   p.imageTiling == .OPTIMAL &&
		   p.imageUsageFlags & usage == usage &&
		   p.imageCreateFlags & flags == flags &&
		   (p.componentMapping.r == .IDENTITY || p.componentMapping.r == .R) &&
		   (p.componentMapping.g == .IDENTITY || p.componentMapping.g == .G) &&
		   (p.componentMapping.b == .IDENTITY || p.componentMapping.b == .B) &&
		   (p.componentMapping.a == .IDENTITY || p.componentMapping.a == .A) {return true}
	}
	return false
}

@(private)
bind_session_memory :: proc(e: ^Encoder) -> Error {
	return bind_video_session_memory(&e.device, e.session, &e.session_memory)
}

@(private)
bind_video_session_memory :: proc(
	d: ^Device,
	session: vk.VideoSessionKHR,
	memory_list: ^[dynamic]vk.DeviceMemory,
) -> Error {
	count: u32
	if d.a.GetVideoSessionMemoryRequirementsKHR(d.handle, session, &count, nil) != .SUCCESS do return .Driver_Error
	requirements := make([]vk.VideoSessionMemoryRequirementsKHR, count); defer delete(requirements)
	for &r in requirements do r.sType = .VIDEO_SESSION_MEMORY_REQUIREMENTS_KHR
	if d.a.GetVideoSessionMemoryRequirementsKHR(d.handle, session, &count, raw_data(requirements)) != .SUCCESS do return .Driver_Error
	bindings := make([]vk.BindVideoSessionMemoryInfoKHR, count); defer delete(bindings)
	for r, i in requirements[:count] {
		index := memory_type(d, r.memoryRequirements.memoryTypeBits, {}, {.DEVICE_LOCAL})
		if index < 0 do return .Unsupported
		info := vk.MemoryAllocateInfo {
			sType           = .MEMORY_ALLOCATE_INFO,
			allocationSize  = r.memoryRequirements.size,
			memoryTypeIndex = u32(index),
		}
		memory: vk.DeviceMemory
		if d.a.AllocateMemory(d.handle, &info, nil, &memory) != .SUCCESS do return .Out_Of_Memory
		append(memory_list, memory)
		bindings[i] = {
			sType           = .BIND_VIDEO_SESSION_MEMORY_INFO_KHR,
			memoryBindIndex = r.memoryBindIndex,
			memory          = memory,
			memorySize      = r.memoryRequirements.size,
		}
	}
	if count > 0 && d.a.BindVideoSessionMemoryKHR(d.handle, session, count, raw_data(bindings)) != .SUCCESS do return .Driver_Error
	return .None
}

@(private)
create_parameters :: proc(e: ^Encoder, max_level: vk.VideoH264LevelIdc) -> Error {
	d := &e.device
	w, h := e.config.width, e.config.height
	vui := vk.VideoH264SequenceParameterSetVui {
		flags                   = {.bitstream_restriction_flag},
		max_num_reorder_frames  = 0,
		max_dec_frame_buffering = 1,
	}
	if e.config.colour_primaries != 0 {
		vui.flags += {.video_signal_type_present_flag, .color_description_present_flag}
		if e.config.full_range do vui.flags += {.video_full_range_flag}
		vui.video_format = 5
		vui.colour_primaries = e.config.colour_primaries
		vui.transfer_characteristics = e.config.transfer
		vui.matrix_coefficients = e.config.matrix_coefficients
	}
	sps := vk.VideoH264SequenceParameterSet {
		flags                             = {
			.frame_mbs_only_flag,
			.direct_8x8_inference_flag,
			.vui_parameters_present_flag,
		},
		pSequenceParameterSetVui          = &vui,
		profile_idc                       = vk.VideoH264ProfileIdc(100),
		level_idc                         = max_level,
		chroma_format_idc                 = vk.VideoH264ChromaFormatIdc(1),
		pic_order_cnt_type                = vk.VideoH264PocType(0),
		log2_max_frame_num_minus4         = 12,
		log2_max_pic_order_cnt_lsb_minus4 = 12,
		max_num_ref_frames                = 1,
		pic_width_in_mbs_minus1           = u32((w + 15) / 16 - 1),
		pic_height_in_map_units_minus1    = u32((h + 15) / 16 - 1),
	}
	if w % 16 != 0 || h % 16 != 0 {
		sps.flags += {.frame_cropping_flag}
		sps.frame_crop_right_offset, sps.frame_crop_bottom_offset =
			u32((16 - w % 16) % 16 / 2), u32((16 - h % 16) % 16 / 2)
	}
	pps := vk.VideoH264PictureParameterSet {
		flags = {.entropy_coding_mode_flag, .deblocking_filter_control_present_flag},
	}
	add := vk.VideoEncodeH264SessionParametersAddInfoKHR {
		sType       = .VIDEO_ENCODE_H264_SESSION_PARAMETERS_ADD_INFO_KHR,
		stdSPSCount = 1,
		pStdSPSs    = cast([^]vk.VideoH264SequenceParameterSet)&sps,
		stdPPSCount = 1,
		pStdPPSs    = cast([^]vk.VideoH264PictureParameterSet)&pps,
	}
	codec := vk.VideoEncodeH264SessionParametersCreateInfoKHR {
		sType              = .VIDEO_ENCODE_H264_SESSION_PARAMETERS_CREATE_INFO_KHR,
		maxStdSPSCount     = 1,
		maxStdPPSCount     = 1,
		pParametersAddInfo = &add,
	}
	info := vk.VideoSessionParametersCreateInfoKHR {
		sType        = .VIDEO_SESSION_PARAMETERS_CREATE_INFO_KHR,
		pNext        = &codec,
		videoSession = e.session,
	}
	if d.a.CreateVideoSessionParametersKHR(d.handle, &info, nil, &e.parameters) != .SUCCESS do return .Driver_Error
	get264 := vk.VideoEncodeH264SessionParametersGetInfoKHR {
		sType       = .VIDEO_ENCODE_H264_SESSION_PARAMETERS_GET_INFO_KHR,
		writeStdSPS = true,
		writeStdPPS = true,
	}
	get := vk.VideoEncodeSessionParametersGetInfoKHR {
		sType                  = .VIDEO_ENCODE_SESSION_PARAMETERS_GET_INFO_KHR,
		pNext                  = &get264,
		videoSessionParameters = e.parameters,
	}
	feedback := vk.VideoEncodeSessionParametersFeedbackInfoKHR {
		sType = .VIDEO_ENCODE_SESSION_PARAMETERS_FEEDBACK_INFO_KHR,
	}
	size: int
	if d.a.GetEncodedVideoSessionParametersKHR(d.handle, &get, &feedback, &size, nil) != .SUCCESS || size <= 0 || size > 65536 do return .Driver_Error
	e.headers = make([]u8, size)
	if d.a.GetEncodedVideoSessionParametersKHR(d.handle, &get, &feedback, &size, raw_data(e.headers)) != .SUCCESS do return .Driver_Error
	if size <= 0 || size > len(e.headers) do return .Driver_Error
	e.headers = e.headers[:size]
	return .None
}

// encode_frame copies the planes during this call and returns an owned
// Annex-B packet (delete it after use): this picture's with one frame in
// flight, otherwise the oldest picture's once Config.frames_in_flight are
// queued, else nil. The encoder has one submitting owner. Invalid inputs
// leave the session usable; a failed GPU submission poisons it. The
// picture is 8-bit I420 (y, u, v) or NV12 (y and interleaved uv, the
// device's own layout, uploaded row by row).
encode_frame :: proc {
	encode_i420,
	encode_nv12,
}

// Borrowed packets belong to the encoder and are valid until the next encode
// call or destruction. Consume them before encoding again; do not delete them.
encode_frame_borrowed :: proc {
	encode_i420_borrowed,
	encode_nv12_borrowed,
}

encode_i420 :: proc(e: ^Encoder, y, u, v: Plane) -> (packet: []u8, err: Error) {
	return encode_frame_impl(e, y, {u, v}, false, false)
}
encode_i420_borrowed :: proc(e: ^Encoder, y, u, v: Plane) -> (packet: []u8, err: Error) {
	return encode_frame_impl(e, y, {u, v}, false, true)
}
encode_nv12 :: proc(e: ^Encoder, y, uv: Plane) -> (packet: []u8, err: Error) {
	return encode_frame_impl(e, y, {uv, {}}, true, false)
}
encode_nv12_borrowed :: proc(e: ^Encoder, y, uv: Plane) -> (packet: []u8, err: Error) {
	return encode_frame_impl(e, y, {uv, {}}, true, true)
}

// The chroma planes are U and V, or interleaved UV in chroma[0].
@(private)
encode_frame_impl :: proc(
	e: ^Encoder,
	y: Plane,
	chroma: [2]Plane,
	interleaved: bool,
	borrow_packet: bool,
) -> (
	packet: []u8,
	err: Error,
) {
	if e == nil || !e.initialized || e.failed || e.config.bit_depth != 8 do return nil, .Invalid_Argument
	w, h := e.config.width, e.config.height
	if !valid_plane(y, w, h) do return nil, .Invalid_Argument
	if interleaved {
		if !valid_plane(chroma[0], w, h / 2) || chroma[0].stride % 2 != 0 do return nil, .Invalid_Argument
	} else if !valid_plane(chroma[0], w / 2, h / 2) || !valid_plane(chroma[1], w / 2, h / 2) {
		return nil, .Invalid_Argument
	}
	slot := &e.slots[e.submitted % e.depth]
	if error := ensure_upload(e, slot); error != .None do return nil, error
	defer if err != .None && err != .Invalid_Argument do e.failed = true
	pitch, rows := int(slot.input.extent.width), int(slot.input.extent.height)
	upload := slot.upload.mapped[:slot.upload.size]
	// NV12 on the device: the Y rows, then rows of U, V pairs. Edge
	// replication prevents undefined reads in macroblock/device padding.
	luma := upload[:pitch * rows]
	pairs := ([^][2]u8)(raw_data(upload[pitch * rows:]))[:pitch / 2 * rows / 2]
	upload_rows(luma, pitch, y.data, y.stride, {w, h})
	if interleaved {
		uv := ([^][2]u8)(raw_data(chroma[0].data))[:len(chroma[0].data) / 2]
		upload_rows(pairs, pitch / 2, uv, chroma[0].stride / 2, {w / 2, h / 2})
	} else {
		u, v := chroma[0], chroma[1]
		for row in 0 ..< rows / 2 {
			at := min(row, h / 2 - 1)
			ur, vr := u.data[at * u.stride:][:w / 2], v.data[at * v.stride:][:w / 2]
			out := pairs[row * pitch / 2:][:pitch / 2]
			for x in 0 ..< w / 2 do out[x] = {ur[x], vr[x]}
			for &p in out[w / 2:] do p = out[w / 2 - 1]
		}
	}
	return encode_uploaded_frame(e, slot, borrow_packet)
}

// Copies size.x samples of each source row into dst rows `pitch` samples
// apart, repeating the last column and row into the padding.
@(private)
upload_rows :: proc(dst: []$T, pitch: int, src: []T, stride: int, size: [2]int) {
	rows := len(dst) / pitch
	for row in 0 ..< rows {
		line := src[min(row, size.y - 1) * stride:][:size.x]
		out := dst[row * pitch:][:pitch]
		copy(out, line)
		for &v in out[size.x:] do v = line[size.x - 1]
	}
}

encode_frame16 :: proc(e: ^Encoder, y, u, v: Plane16) -> (packet: []u8, err: Error) {
	return encode_frame16_impl(e, y, u, v, false)
}

// Same borrowed packet lifetime as encode_frame_borrowed.
encode_frame16_borrowed :: proc(e: ^Encoder, y, u, v: Plane16) -> (packet: []u8, err: Error) {
	return encode_frame16_impl(e, y, u, v, true)
}

@(private)
encode_frame16_impl :: proc(
	e: ^Encoder,
	y, u, v: Plane16,
	borrow_packet: bool,
) -> (
	packet: []u8,
	err: Error,
) {
	if e == nil || !e.initialized || e.failed do return nil, .Invalid_Argument
	w, h := e.config.width, e.config.height
	if !valid_plane16(y, w, h) || !valid_plane16(u, w / 2, h / 2) || !valid_plane16(v, w / 2, h / 2) do return nil, .Invalid_Argument
	slot := &e.slots[e.submitted % e.depth]
	pitch, rows := int(slot.input.extent.width), int(slot.input.extent.height)
	max_sample := u16(1 << uint(e.config.bit_depth) - 1)
	for plane, i in ([3]Plane16{y, u, v}) {
		pw, ph := i == 0 ? w : w / 2, i == 0 ? h : h / 2
		for row in 0 ..< ph do for sample in plane.data[row * plane.stride:row * plane.stride + pw] {
			if sample > max_sample do return nil, .Invalid_Argument
		}
	}
	if error := ensure_upload(e, slot); error != .None do return nil, error
	if e.config.bit_depth == 8 {
		for row in 0 ..< rows do for col in 0 ..< pitch {
			slot.upload.mapped[row * pitch + col] = u8(y.data[min(row, h - 1) * y.stride + min(col, w - 1)])
		}
		for row in 0 ..< rows / 2 do for col in 0 ..< pitch / 2 {
			x, yy := min(col, w / 2 - 1), min(row, h / 2 - 1)
			slot.upload.mapped[pitch * rows + row * pitch + col * 2] = u8(u.data[yy * u.stride + x])
			slot.upload.mapped[pitch * rows + row * pitch + col * 2 + 1] = u8(v.data[yy * v.stride + x])
		}
	} else {
		mapped := cast([^]u16)slot.upload.mapped
		for row in 0 ..< rows do for col in 0 ..< pitch {
			mapped[row * pitch + col] = y.data[min(row, h - 1) * y.stride + min(col, w - 1)] << 6
		}
		for row in 0 ..< rows / 2 do for col in 0 ..< pitch / 2 {
			x, yy := min(col, w / 2 - 1), min(row, h / 2 - 1)
			mapped[pitch * rows + row * pitch + col * 2] = u.data[yy * u.stride + x] << 6
			mapped[pitch * rows + row * pitch + col * 2 + 1] = v.data[yy * v.stride + x] << 6
		}
	}
	return encode_uploaded_frame(e, slot, borrow_packet)
}

@(private)
ensure_upload :: proc(e: ^Encoder, slot: ^Encode_Slot) -> Error {
	if slot.upload.handle != 0 do return .None
	bytes :=
		int(slot.input.extent.width) *
		int(slot.input.extent.height) *
		3 /
		2 *
		(e.config.bit_depth == 10 ? 2 : 1)
	return alloc_buffer(&e.device, &slot.upload, bytes, {.TRANSFER_SRC})
}

// encode_surface borrows a same-device NV12/P010 surface for this synchronous
// call. It copies visible planes and clamped edge padding entirely on the GPU;
// compressed output is an owned host packet. The source layout is unchanged.
// A timeline readiness wait is optional only when both semaphore/value are 0
// and the caller has already completed producer work on the exposed queue.
encode_surface :: proc(
	e: ^Encoder,
	source: Surface,
	crop_x, crop_y: int,
) -> (
	packet: []u8,
	err: Error,
) {
	return encode_surface_impl(e, source, crop_x, crop_y, false)
}

// Same GPU copy and readiness contract as encode_surface; the packet has the
// borrowed lifetime of encode_frame_borrowed.
encode_surface_borrowed :: proc(
	e: ^Encoder,
	source: Surface,
	crop_x, crop_y: int,
) -> (
	packet: []u8,
	err: Error,
) {
	return encode_surface_impl(e, source, crop_x, crop_y, true)
}

@(private)
encode_surface_impl :: proc(
	e: ^Encoder,
	source: Surface,
	crop_x, crop_y: int,
	borrow_packet: bool,
) -> (
	packet: []u8,
	err: Error,
) {
	if error := validate_encode_surface(e, source, crop_x, crop_y); error != .None do return nil, error
	d := &e.device
	slot := &e.slots[e.submitted % e.depth]
	defer if err != .None do e.failed = true
	if error := begin_command(d, &slot.transfer); error != .None do return nil, error
	image_barrier(
		d,
		slot.transfer.handle,
		&slot.input,
		.TRANSFER_DST_OPTIMAL,
		{.ALL_COMMANDS},
		{.COPY},
		{.MEMORY_READ},
		{.TRANSFER_WRITE},
	)
	src_image := Image {
		handle       = source.image,
		layout       = source.layout,
		array_layers = 1,
	}
	image_barrier(
		d,
		slot.transfer.handle,
		&src_image,
		source.layout,
		{.ALL_COMMANDS},
		{.COPY},
		{.MEMORY_WRITE},
		{.TRANSFER_READ},
	)
	clear(&e.surface_copies)
	for plane in 0 ..< 2 {
		divisor := 1 << uint(plane)
		w, h := e.config.width / divisor, e.config.height / divisor
		x, y := crop_x / divisor, crop_y / divisor
		pitch, rows := int(slot.input.extent.width) / divisor, int(slot.input.extent.height) / divisor
		aspect: vk.ImageAspectFlags = plane == 0 ? {.PLANE_0} : {.PLANE_1}
		region := vk.ImageCopy {
			srcSubresource = {aspectMask = aspect, layerCount = 1},
			srcOffset = {i32(x), i32(y), 0},
			dstSubresource = {aspectMask = aspect, layerCount = 1},
			extent = {u32(w), u32(h), 1},
		}
		append(&e.surface_copies, region)
		// Copy from valid source edges, never undefined coded-picture padding.
		for col in w ..< pitch {
			r := region
			r.srcOffset.x, r.dstOffset.x, r.extent.width = i32(x + w - 1), i32(col), 1
			append(&e.surface_copies, r)
		}
		for row in h ..< rows {
			r := region
			r.srcOffset.y, r.dstOffset.y, r.extent.height = i32(y + h - 1), i32(row), 1
			append(&e.surface_copies, r)
			for col in w ..< pitch {
				corner := r
				corner.srcOffset.x, corner.dstOffset.x, corner.extent.width =
					i32(x + w - 1), i32(col), 1
				append(&e.surface_copies, corner)
			}
		}
	}
	d.a.CmdCopyImage(
		slot.transfer.handle,
		source.image,
		source.layout,
		slot.input.handle,
		.TRANSFER_DST_OPTIMAL,
		u32(len(e.surface_copies)),
		raw_data(e.surface_copies[:]),
	)
	image_barrier(
		d,
		slot.transfer.handle,
		&slot.input,
		.VIDEO_ENCODE_SRC_KHR,
		{.COPY},
		{.ALL_COMMANDS},
		{.TRANSFER_WRITE},
		{.MEMORY_READ},
	)
	uploaded := Timeline_Point{e.uploaded, u64(e.submitted + 1)}
	if error := submit_async(d, d.transfer_queue, slot.transfer.handle, uploaded, {source.ready_semaphore, source.ready_value}); error != .None do return nil, error
	// The source is borrowed for this call only: release it once copied.
	if error := wait_timeline(d, uploaded); error != .None do return nil, error
	return encode_ready_frame(e, borrow_packet)
}

@(private)
validate_encode_surface :: proc(e: ^Encoder, source: Surface, crop_x, crop_y: int) -> Error {
	if e == nil || !e.initialized || e.failed || e.device.handle == nil do return .Invalid_Argument
	if source.device != e.device.handle do return .Unsupported
	limit := min(int(max(i32)), int(e.device.properties.limits.maxImageDimension2D))
	if source.image == 0 || source.width <= 0 || source.height <= 0 || source.width > limit || source.height > limit || source.width % 2 != 0 || source.height % 2 != 0 || crop_x < 0 || crop_y < 0 || crop_x % 2 != 0 || crop_y % 2 != 0 do return .Invalid_Argument
	for slot in e.slots[:e.depth] do if source.image == slot.input.handle do return .Invalid_Argument
	if crop_x > source.width || crop_y > source.height || e.config.width > source.width - crop_x || e.config.height > source.height - crop_y do return .Invalid_Argument
	if (source.ready_semaphore == 0) != (source.ready_value == 0) do return .Invalid_Argument
	if source.bit_depth != e.config.bit_depth || source.compute_queue_family != e.device.transfer_family do return .Unsupported
	expected :=
		e.config.bit_depth == 10 ? vk.Format.G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16 : vk.Format.G8_B8R8_2PLANE_420_UNORM
	if source.format != expected || .TRANSFER_SRC not_in source.usage || (source.layout != .GENERAL && source.layout != .TRANSFER_SRC_OPTIMAL) do return .Unsupported
	return .None
}

@(private)
encode_uploaded_frame :: proc(
	e: ^Encoder,
	slot: ^Encode_Slot,
	borrow_packet: bool,
) -> (
	packet: []u8,
	err: Error,
) {
	d := &e.device
	pitch, rows := int(slot.input.extent.width), int(slot.input.extent.height)
	chroma := pitch * rows * (e.config.bit_depth == 10 ? 2 : 1)
	defer if err != .None do e.failed = true
	if error := sync_buffer(d, &slot.upload, true); error != .None do return nil, error
	if error := begin_command(d, &slot.transfer); error != .None do return nil, error
	image_barrier(
		d,
		slot.transfer.handle,
		&slot.input,
		.TRANSFER_DST_OPTIMAL,
		{.ALL_COMMANDS},
		{.COPY},
		{.MEMORY_READ},
		{.TRANSFER_WRITE},
	)
	copies := [2]vk.BufferImageCopy {
		{
			imageSubresource = {aspectMask = {.PLANE_0}, layerCount = 1},
			imageExtent = {u32(pitch), u32(rows), 1},
		},
		{
			bufferOffset = vk.DeviceSize(chroma),
			imageSubresource = {aspectMask = {.PLANE_1}, layerCount = 1},
			imageExtent = {u32(pitch / 2), u32(rows / 2), 1},
		},
	}
	d.a.CmdCopyBufferToImage(
		slot.transfer.handle,
		slot.upload.handle,
		slot.input.handle,
		.TRANSFER_DST_OPTIMAL,
		2,
		raw_data(copies[:]),
	)
	image_barrier(
		d,
		slot.transfer.handle,
		&slot.input,
		.VIDEO_ENCODE_SRC_KHR,
		{.COPY},
		{.ALL_COMMANDS},
		{.TRANSFER_WRITE},
		{.MEMORY_READ},
	)
	if error := submit_async(d, d.transfer_queue, slot.transfer.handle, {e.uploaded, u64(e.submitted + 1)}); error != .None do return nil, error
	return encode_ready_frame(e, borrow_packet)
}

@(private)
// Encodes the uploaded picture in its slot, after the upload and in queue
// order after every earlier picture, then returns the oldest packet once
// depth pictures are in flight.
encode_ready_frame :: proc(e: ^Encoder, borrow_packet: bool) -> (packet: []u8, err: Error) {
	d := &e.device
	w, h := e.config.width, e.config.height
	index := e.submitted % e.depth
	slot := &e.slots[index]
	defer if err != .None do e.failed = true
	if error := begin_command(d, &slot.command); error != .None do return nil, error
	in_gop := e.submitted % e.config.gop_size
	idr := in_gop == 0
	current := e.config.gop_size > 1 ? e.submitted & 1 : 0
	previous := current ~ 1
	if e.reconstructed_array.handle != 0 {
		image_barrier(
			d,
			slot.command.handle,
			&e.reconstructed_array,
			.VIDEO_ENCODE_DPB_KHR,
			{.ALL_COMMANDS},
			{.VIDEO_ENCODE_KHR},
			{.MEMORY_WRITE},
			{.VIDEO_ENCODE_READ_KHR, .VIDEO_ENCODE_WRITE_KHR},
		)
	} else {
		image_barrier(
			d,
			slot.command.handle,
			&e.reconstructed[current],
			.VIDEO_ENCODE_DPB_KHR,
			{.ALL_COMMANDS},
			{.VIDEO_ENCODE_KHR},
			{.MEMORY_WRITE},
			{.VIDEO_ENCODE_READ_KHR, .VIDEO_ENCODE_WRITE_KHR},
		)
		if !idr do image_barrier(d, slot.command.handle, &e.reconstructed[previous], .VIDEO_ENCODE_DPB_KHR, {.ALL_COMMANDS}, {.VIDEO_ENCODE_KHR}, {.MEMORY_WRITE}, {.VIDEO_ENCODE_READ_KHR})
	}
	d.a.CmdResetQueryPool(slot.command.handle, e.query, u32(index), 1)
	extent := vk.Extent2D{u32(w), u32(h)}
	dpb := encoder_dpb_resource(e, current)
	ref_info := vk.VideoEncodeH264ReferenceInfo {
		primary_pic_type = vk.VideoH264PictureType(i32(idr ? 5 : 0)),
		FrameNum         = u32(in_gop),
		PicOrderCnt      = i32(in_gop * 2),
	}
	ref264 := vk.VideoEncodeH264DpbSlotInfoKHR {
		sType             = .VIDEO_ENCODE_H264_DPB_SLOT_INFO_KHR,
		pStdReferenceInfo = &ref_info,
	}
	previous_resource := encoder_dpb_resource(e, previous)
	previous_info264 := vk.VideoEncodeH264ReferenceInfo {
		primary_pic_type = vk.VideoH264PictureType(i32(in_gop == 1 ? 5 : 0)),
		FrameNum         = u32(max(0, in_gop - 1)),
		PicOrderCnt      = i32(max(0, in_gop - 1) * 2),
	}
	previous_codec264 := vk.VideoEncodeH264DpbSlotInfoKHR {
		sType             = .VIDEO_ENCODE_H264_DPB_SLOT_INFO_KHR,
		pStdReferenceInfo = &previous_info264,
	}
	previous_info265 := vk.VideoEncodeH265ReferenceInfo {
		pic_type       = vk.VideoH265PictureType(i32(in_gop == 1 ? 3 : 0)),
		PicOrderCntVal = i32(max(0, in_gop - 1) * 2),
	}
	previous_codec265 := vk.VideoEncodeH265DpbSlotInfoKHR {
		sType             = .VIDEO_ENCODE_H265_DPB_SLOT_INFO_KHR,
		pStdReferenceInfo = &previous_info265,
	}
	previous_slot := vk.VideoReferenceSlotInfoKHR {
		sType            = .VIDEO_REFERENCE_SLOT_INFO_KHR,
		pNext            = e.config.codec == .H264 ? &previous_codec264 : &previous_codec265,
		slotIndex        = i32(previous),
		pPictureResource = &previous_resource,
	}
	bound := [2]vk.VideoReferenceSlotInfoKHR {
		{sType = .VIDEO_REFERENCE_SLOT_INFO_KHR, slotIndex = -1, pPictureResource = &dpb},
		previous_slot,
	}
	begin := vk.VideoBeginCodingInfoKHR {
		sType                  = .VIDEO_BEGIN_CODING_INFO_KHR,
		videoSession           = e.session,
		videoSessionParameters = e.parameters,
		referenceSlotCount     = idr ? 1 : 2,
		pReferenceSlots        = raw_data(bound[:]),
	}
	d.a.CmdBeginVideoCodingKHR(slot.command.handle, &begin)
	reset := vk.VideoCodingControlInfoKHR {
		sType = .VIDEO_CODING_CONTROL_INFO_KHR,
		flags = {.RESET},
	}
	if idr do d.a.CmdControlVideoCodingKHR(slot.command.handle, &reset)
	rate := vk.VideoEncodeRateControlInfoKHR {
		sType           = .VIDEO_ENCODE_RATE_CONTROL_INFO_KHR,
		rateControlMode = {.DISABLED},
	}
	control := vk.VideoCodingControlInfoKHR {
		sType = .VIDEO_CODING_CONTROL_INFO_KHR,
		pNext = &rate,
		flags = {.ENCODE_RATE_CONTROL},
	}
	d.a.CmdControlVideoCodingKHR(slot.command.handle, &control)
	list264: vk.VideoEncodeH264ReferenceListsInfo
	list265: vk.VideoEncodeH265ReferenceListsInfo
	for &entry in list264.RefPicList0 do entry = 0xff
	for &entry in list264.RefPicList1 do entry = 0xff
	for &entry in list265.RefPicList0 do entry = 0xff
	for &entry in list265.RefPicList1 do entry = 0xff
	list264.RefPicList0[0], list265.RefPicList0[0] = u8(previous), u8(previous)
	std_pic := vk.VideoEncodeH264PictureInfo {
		flags            = {.is_reference},
		primary_pic_type = vk.VideoH264PictureType(i32(idr ? 5 : 0)),
		frame_num        = u32(in_gop),
		PicOrderCnt      = i32(in_gop * 2),
	}
	if idr {std_pic.flags += {.IdrPicFlag, .no_output_of_prior_pics_flag}} else {std_pic.pRefLists = cast([^]vk.VideoEncodeH264ReferenceListsInfo)&list264}
	slice := vk.VideoEncodeH264SliceHeader {
		slice_type                    = vk.VideoH264SliceType(i32(idr ? 2 : 0)),
		disable_deblocking_filter_idc = vk.VideoH264DisableDeblockingFilterIdc(0),
	}
	nalu := vk.VideoEncodeH264NaluSliceInfoKHR {
		sType           = .VIDEO_ENCODE_H264_NALU_SLICE_INFO_KHR,
		constantQp      = i32(e.config.qp),
		pStdSliceHeader = &slice,
	}
	pic := vk.VideoEncodeH264PictureInfoKHR {
		sType               = .VIDEO_ENCODE_H264_PICTURE_INFO_KHR,
		naluSliceEntryCount = 1,
		pNaluSliceEntries   = cast([^]vk.VideoEncodeH264NaluSliceInfoKHR)&nalu,
		pStdPictureInfo     = &std_pic,
	}
	setup := vk.VideoReferenceSlotInfoKHR {
		sType            = .VIDEO_REFERENCE_SLOT_INFO_KHR,
		pNext            = &ref264,
		slotIndex        = i32(current),
		pPictureResource = &dpb,
	}
	ref265_info := vk.VideoEncodeH265ReferenceInfo {
		pic_type       = vk.VideoH265PictureType(i32(idr ? 3 : 0)),
		PicOrderCntVal = i32(in_gop * 2),
	}
	ref265 := vk.VideoEncodeH265DpbSlotInfoKHR {
		sType             = .VIDEO_ENCODE_H265_DPB_SLOT_INFO_KHR,
		pStdReferenceInfo = &ref265_info,
	}
	inline_rps := vk.VideoH265ShortTermRefPicSet {
		num_negative_pics        = 1,
		used_by_curr_pic_s0_flag = 1,
	}
	inline_rps.delta_poc_s0_minus1[0] = 1 // adjacent pictures have POCs 0, 2, 4, ...
	std_pic265 := vk.VideoEncodeH265PictureInfo {
		flags          = {.is_reference, .pic_output_flag},
		pic_type       = vk.VideoH265PictureType(i32(idr ? 3 : 0)),
		PicOrderCntVal = i32(in_gop * 2),
	}
	if idr {std_pic265.flags += {.IrapPicFlag, .no_output_of_prior_pics_flag}} else {std_pic265.pRefLists = cast([^]vk.VideoEncodeH265ReferenceListsInfo)&list265; std_pic265.pShortTermRefPicSet = &inline_rps}
	slice265 := vk.VideoEncodeH265SliceSegmentHeader {
		flags           = {.first_slice_segment_in_pic_flag},
		slice_type      = vk.VideoH265SliceType(i32(idr ? 2 : 1)),
		MaxNumMergeCand = 5,
	}
	nalu265 := vk.VideoEncodeH265NaluSliceSegmentInfoKHR {
		sType                  = .VIDEO_ENCODE_H265_NALU_SLICE_SEGMENT_INFO_KHR,
		constantQp             = i32(e.config.qp),
		pStdSliceSegmentHeader = &slice265,
	}
	pic265 := vk.VideoEncodeH265PictureInfoKHR {
		sType                      = .VIDEO_ENCODE_H265_PICTURE_INFO_KHR,
		naluSliceSegmentEntryCount = 1,
		pNaluSliceSegmentEntries   = cast([^]vk.VideoEncodeH265NaluSliceSegmentInfoKHR)&nalu265,
		pStdPictureInfo            = &std_pic265,
	}
	encode := vk.VideoEncodeInfoKHR {
		sType = .VIDEO_ENCODE_INFO_KHR,
		pNext = &pic,
		dstBuffer = slot.bitstream.handle,
		dstBufferRange = vk.DeviceSize(slot.bitstream.size),
		srcPictureResource = {
			sType = .VIDEO_PICTURE_RESOURCE_INFO_KHR,
			codedExtent = extent,
			imageViewBinding = slot.input.view,
		},
		pSetupReferenceSlot = &setup,
		referenceSlotCount = idr ? 0 : 1,
		pReferenceSlots = cast([^]vk.VideoReferenceSlotInfoKHR)&previous_slot,
	}
	if e.config.codec == .H265 {encode.pNext = &pic265; setup.pNext = &ref265}
	d.a.CmdBeginQuery(slot.command.handle, e.query, u32(index), {})
	d.a.CmdEncodeVideoKHR(slot.command.handle, &encode)
	d.a.CmdEndQuery(slot.command.handle, e.query, u32(index))
	end := vk.VideoEndCodingInfoKHR {
		sType = .VIDEO_END_CODING_INFO_KHR,
	}
	d.a.CmdEndVideoCodingKHR(slot.command.handle, &end)
	memory_barrier(
		d,
		slot.command.handle,
		{.VIDEO_ENCODE_KHR},
		{.HOST},
		{.VIDEO_ENCODE_WRITE_KHR},
		{.HOST_READ},
	)
	ready := Timeline_Point{e.uploaded, u64(e.submitted + 1)}
	if error := submit_async(d, d.queue, slot.command.handle, {e.encoded, u64(e.submitted + 1)}, ready); error != .None do return nil, error
	e.submitted += 1
	if e.submitted - e.returned < e.depth do return nil, .None
	return return_oldest(e, borrow_packet)
}

// Waits for the oldest picture in flight and publishes its packet, freeing
// its slot for picture `returned + depth`.
@(private)
return_oldest :: proc(e: ^Encoder, borrow_packet: bool) -> (packet: []u8, err: Error) {
	d := &e.device
	index := e.returned % e.depth
	bitstream := &e.slots[index].bitstream
	defer if err != .None do e.failed = true
	wait_timeline(d, {e.encoded, u64(e.returned + 1)}) or_return
	result: [3]u64
	query_flags: vk.QueryResultFlags = {._64, .WAIT}
	if d.query_status do query_flags += {.WITH_STATUS_KHR}
	if d.a.GetQueryPoolResults(d.handle, e.query, u32(index), 1, size_of(result), raw_data(result[:]), size_of(result), query_flags) != .SUCCESS do return nil, .Driver_Error
	if d.query_status && i64(result[2]) <= 0 do return nil, .Driver_Error
	offset, bytes := result[0], result[1]
	if bytes == 0 || offset > u64(bitstream.size) || bytes > u64(bitstream.size) - offset do return nil, .Output_Overflow
	sync_buffer(d, bitstream, false) or_return
	headers := e.returned % e.config.gop_size == 0 ? e.headers : nil
	packet = publish_encoded_packet(
		headers,
		bitstream.mapped[int(offset):int(offset + bytes)],
		borrow_packet ? &e.packet_buffer : nil,
	) or_return
	e.returned += 1
	return packet, .None
}

// flush_encoder returns the packets still in flight, one per call and in
// order, then nil once every submitted picture has been returned. Call it
// after the last picture. Packets are owned, as from encode_frame.
flush_encoder :: proc(e: ^Encoder) -> (packet: []u8, err: Error) {
	return flush_encoder_impl(e, false)
}

// Same borrowed packet lifetime as encode_frame_borrowed.
flush_encoder_borrowed :: proc(e: ^Encoder) -> (packet: []u8, err: Error) {
	return flush_encoder_impl(e, true)
}

@(private)
flush_encoder_impl :: proc(e: ^Encoder, borrow_packet: bool) -> (packet: []u8, err: Error) {
	if e == nil || !e.initialized || e.failed do return nil, .Invalid_Argument
	if e.returned == e.submitted do return nil, .None
	return return_oldest(e, borrow_packet)
}

// Both publication contracts use the same contiguous headers/body copy. The
// GPU-mapped body and retained headers are disjoint from the destination.
// Retention removes allocation after warm-up, not the compressed-byte copy.
@(private)
publish_encoded_packet :: proc(
	headers, body: []u8,
	retained: ^[dynamic]u8,
) -> (
	packet: []u8,
	err: Error,
) {
	if len(headers) > max(int) - len(body) do return nil, .Output_Overflow
	bytes := len(headers) + len(body)
	if retained == nil {
		owned, allocation_error := make([]u8, bytes)
		if allocation_error != nil || (bytes != 0 && raw_data(owned) == nil) do return nil, .Out_Of_Memory
		packet = owned
	} else {
		// Every exposed byte is overwritten below, including after shrink/grow.
		if error := non_zero_resize(retained, bytes); error != nil do return nil, .Out_Of_Memory
		packet = retained^[:]
	}
	copy(packet, headers)
	copy(packet[len(headers):], body)
	return packet, .None
}

@(private)
valid_plane :: proc(p: Plane, width, height: int) -> bool {
	return valid_plane_data(p.data, p.stride, width, height)
}

@(private)
encoder_dpb_resource :: proc(e: ^Encoder, slot: int) -> vk.VideoPictureResourceInfoKHR {
	resource := vk.VideoPictureResourceInfoKHR {
		sType       = .VIDEO_PICTURE_RESOURCE_INFO_KHR,
		codedExtent = {u32(e.config.width), u32(e.config.height)},
	}
	if e.reconstructed_array.handle != 0 {
		resource.imageViewBinding = e.reconstructed_array.view
		resource.baseArrayLayer = u32(slot)
	} else {
		resource.imageViewBinding = e.reconstructed[slot].view
	}
	return resource
}

@(private)
valid_plane16 :: proc(p: Plane16, width, height: int) -> bool {
	return valid_plane_data(p.data, p.stride, width, height)
}

@(private)
valid_plane_data :: proc(data: []$T, stride, width, height: int) -> bool {
	if stride < width || width <= 0 || height <= 0 do return false
	// Division prevents a malicious stride from overflowing the range check.
	return len(data) >= width && (height == 1 || stride <= (len(data) - width) / (height - 1))
}

destroy_encoder :: proc(e: ^Encoder) {
	if e == nil do return
	d := &e.device
	if d.handle != nil {
		d.a.DeviceWaitIdle(d.handle)
		if e.query != 0 do d.a.DestroyQueryPool(d.handle, e.query, nil)
		if e.uploaded != 0 do d.a.DestroySemaphore(d.handle, e.uploaded, nil)
		if e.encoded != 0 do d.a.DestroySemaphore(d.handle, e.encoded, nil)
		for &slot in e.slots {
			free_command(d, &slot.command)
			free_command(d, &slot.transfer)
			free_image(d, &slot.input)
			free_buffer(d, &slot.upload)
			free_buffer(d, &slot.bitstream)
		}
		for &image in e.reconstructed do free_image(d, &image)
		free_image(d, &e.reconstructed_array)
		if e.parameters != 0 do d.a.DestroyVideoSessionParametersKHR(d.handle, e.parameters, nil)
		if e.session != 0 do d.a.DestroyVideoSessionKHR(d.handle, e.session, nil)
		for memory in e.session_memory do d.a.FreeMemory(d.handle, memory, nil)
	}
	delete(e.session_memory)
	delete(e.headers)
	delete(e.packet_buffer)
	delete(e.surface_copies)
	destroy_device(d)
	e^ = {}
}

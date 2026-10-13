package gpu

@(require) import "core:fmt" // the opt-in ODECS_GPU_TRACE output
import vk "vendor:vulkan"

Output_Storage :: enum {
	Host,
	Device,
}
Decoder_Config :: struct {
	codec:            Codec,
	width, height:    int,
	bit_depth:        int,
	profile_idc:      int, // 0 selects Main for 8-bit or Main10 for 10-bit
	dpb_slots:        int,
	max_references:   int,
	device_index:     int,
	max_packet_bytes: int,
	output_storage:   Output_Storage,
	film_grain:       bool, // AV1: apply film grain to the output
	shared_context:   ^Context,
}
Decode_Parameters :: struct {
	h264_sps: []vk.VideoH264SequenceParameterSet,
	h264_pps: []vk.VideoH264PictureParameterSet,
	h265_vps: []vk.VideoH265VideoParameterSet,
	h265_sps: []vk.VideoH265SequenceParameterSet,
	h265_pps: []vk.VideoH265PictureParameterSet,
	av1:      ^vk.VideoAV1SequenceHeader, // AV1 parameters cannot be updated: each sequence header makes a new object
}
Decode_Reference :: struct {
	slot:          int,
	width, height: int, // AV1 coded extent when not the session's
	h264:          vk.VideoDecodeH264ReferenceInfo,
	h265:          vk.VideoDecodeH265ReferenceInfo,
	av1:           vk.VideoDecodeAV1ReferenceInfo,
}
Decode_Picture :: struct {
	h264:              vk.VideoDecodeH264PictureInfo,
	h264_setup:        vk.VideoDecodeH264ReferenceInfo,
	h265:              vk.VideoDecodeH265PictureInfo,
	av1:               vk.VideoDecodeAV1PictureInfo, // its pointers borrowed for the call
	av1_setup:         vk.VideoDecodeAV1ReferenceInfo,
	av1_slots:         [7]i32, // DPB slot of each reference name LAST..ALTREF, -1 for none
	av1_header_offset: u32,
	slice_offsets:     []u32, // AV1: tile offsets
	tile_sizes:        []u32, // AV1
	width, height:     int, // AV1 coded extent when not the session's
	setup_slot:        int,
	references:        []Decode_Reference,
	reset:             bool,
}
// The surface is borrowed until the next decode call. Decode is complete on
// return. Applications using another queue must finish their use before that
// next call; externally retained images require an application-owned copy.
Surface :: struct {
	device:                   vk.Device,
	physical_device:          vk.PhysicalDevice,
	// Borrowed dispatch and memory-property function remain valid until the
	// decoder closes. They avoid global tables or a second Vulkan loader.
	device_api:               ^vk.Device_VTable,
	get_memory_properties:    vk.ProcGetPhysicalDeviceMemoryProperties,
	image:                    vk.Image,
	view:                     vk.ImageView,
	format:                   vk.Format,
	usage:                    vk.ImageUsageFlags,
	layout:                   vk.ImageLayout,
	queue_family:             u32,
	compute_queue_family:     u32,
	compute_queue:            vk.Queue,
	y_view, uv_view:          vk.ImageView,
	ready_semaphore:          vk.Semaphore, // timeline wait before using on compute_queue
	ready_value:              u64,
	width, height, bit_depth: int,
}
// A decoded picture, the one frame type of every hardware frontend. Host
// planes hold Y', Cb and Cr at the stream's storage width, as
// media.Video_Frame describes them: bytes at 8 bits, LSB-aligned
// little-endian u16 above, strides in bytes. Frontends slice them to start
// at the crop origin. Borrowed until the next decoder call.
Decoder_Frame :: struct {
	width, height, bit_depth:  int, // the visible size
	storage_bits:              int, // 8 or 16 (host planes)
	crop_x, crop_y:            int,
	coded_width, coded_height: int,
	poc:                       int,
	planes:                    [3][]u8,
	strides:                   [3]int,
	surface:                   Surface,
}
H264_Frame :: Decoder_Frame
H265_Frame :: Decoder_Frame
AV1_Frame :: Decoder_Frame

// Appends a host frame's visible samples, plane after plane with tight
// rows: yuv420p bytes at 8 bits, yuv420p10le above.
append_frame_samples :: proc(dst: ^[dynamic]u8, f: Decoder_Frame) {
	b := f.storage_bits / 8
	for plane, i in f.planes {
		sub := i == 0 ? 1 : 2
		rows, row_bytes := (f.height + sub - 1) / sub, (f.width + sub - 1) / sub * b
		for y in 0 ..< rows do append(dst, ..plane[y * f.strides[i]:][:row_bytes])
	}
}

// Slices full planes to start at the frame's crop origin.
@(private)
crop_planes :: proc(f: ^Decoder_Frame, planes: [3][]u8) {
	if len(planes[0]) == 0 do return // device output
	b := f.storage_bits / 8
	f.planes[0] = planes[0][f.crop_y * f.strides[0] + f.crop_x * b:]
	for i in 1 ..= 2 do f.planes[i] = planes[i][(f.crop_y / 2) * f.strides[i] + (f.crop_x / 2) * b:]
}
// Host pictures in flight: decode, readback and the caller's work on the
// previous picture overlap. Device output keeps one, as its surface is
// borrowed until the next call.
DECODE_DEPTH :: #config(ODECS_DECODE_DEPTH, 3)

// What one picture in flight owns from submission until it is returned.
@(private)
Decode_Slot :: struct {
	output:              Image,
	bitstream, readback: Buffer, // the bitstream grows on demand; readback is host output only
	command, transfer:   Command,
	width, height:       int,
}

Decoder :: struct {
	config:              Decoder_Config,
	request:             Request, // rebuilds the video profile for buffer growth
	device:              Device,
	session:             vk.VideoSessionKHR,
	parameters:          vk.VideoSessionParametersKHR,
	session_memory:      [dynamic]vk.DeviceMemory,
	// Picture k uses slots[k % depth] until it is returned.
	slots:               [DECODE_DEPTH]Decode_Slot,
	depth:               int,
	dpb:                 []Image,
	// Host output timelines: picture k signals k+1 on decoded once decoded
	// and on read once its readback buffer is written.
	decoded, read:       vk.Semaphore,
	surface_ready:       vk.Semaphore,
	surface_value:       u64,
	chroma:              []u8, // 8-bit Cb and Cr deinterleaved; 16-bit, all three planes shifted down
	bitstream_alignment: int,
	submitted, returned: int, // pictures submitted / returned
	initialized, failed: bool,
}

init_decoder :: proc(dec: ^Decoder, config: Decoder_Config) -> (err: Error) {
	stage := "arguments"
	defer when #config(
		ODECS_GPU_TRACE,
		false,
	) {if err != .None do fmt.eprintln("Vulkan decoder init:", stage, err)}
	if dec == nil || dec.device.instance != nil do return .Invalid_Argument
	if config.codec == .H264 && config.bit_depth != 8 do return .Unsupported
	if config.width <= 0 || config.height <= 0 || config.width > 8192 || config.height > 8192 || config.width % 2 != 0 || config.height % 2 != 0 || (config.bit_depth != 8 && config.bit_depth != 10) || config.dpb_slots < 1 || config.dpb_slots > 17 || config.max_references < 0 || config.max_references >= config.dpb_slots || config.device_index < -1 || config.max_packet_bytes < 0 || config.max_packet_bytes > 1 << 30 do return .Invalid_Argument
	dec.config = config
	dec.depth = config.output_storage == .Host ? DECODE_DEPTH : 1
	defer if err != .None do destroy_decoder(dec)
	r := Request {
		codec           = config.codec,
		operation       = .Decode,
		width           = config.width,
		height          = config.height,
		bit_depth       = config.bit_depth,
		profile_idc     = config.profile_idc,
		require_compute = config.output_storage == .Device,
		film_grain      = config.film_grain,
	}
	dec.request = r
	stage = "open device"
	caps, _, _ := open_device(&dec.device, r, config.device_index, config.shared_context) or_return
	if config.dpb_slots > int(caps.maxDpbSlots) || config.max_references > int(caps.maxActiveReferencePictures) || .SEPARATE_REFERENCE_IMAGES not_in caps.flags do return .Unsupported
	d := &dec.device
	vp: Video_Profile
	configure_video_profile(&vp, r) or_return
	profile := &vp.info
	c: Decode_Capabilities
	chain_decode_capabilities(&c, config.codec)
	if d.i.GetPhysicalDeviceVideoCapabilitiesKHR(d.physical, profile, &c.caps) != .SUCCESS || .DPB_AND_OUTPUT_DISTINCT not_in c.decode.flags do return .Unsupported
	profiles := vk.VideoProfileListInfoKHR {
		sType        = .VIDEO_PROFILE_LIST_INFO_KHR,
		profileCount = 1,
		pProfiles    = profile,
	}
	extent := vk.Extent2D{u32(config.width), u32(config.height)}
	aligned := vk.Extent2D {
		align_u32(extent.width, caps.pictureAccessGranularity.width),
		align_u32(extent.height, caps.pictureAccessGranularity.height),
	}
	format :=
		config.bit_depth == 10 ? vk.Format.G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16 : vk.Format.G8_B8R8_2PLANE_420_UNORM
	usage: vk.ImageUsageFlags = {.VIDEO_DECODE_DST_KHR, .TRANSFER_SRC}
	flags: vk.ImageCreateFlags
	if config.output_storage == .Device {usage += {.SAMPLED}; flags += {.MUTABLE_FORMAT}}
	if !supports_format(d, &profiles, format, usage, flags) || !supports_format(d, &profiles, format, {.VIDEO_DECODE_DPB_KHR}) do return .Unsupported
	info := vk.VideoSessionCreateInfoKHR {
		sType                      = .VIDEO_SESSION_CREATE_INFO_KHR,
		queueFamilyIndex           = d.queue_family,
		pVideoProfile              = profile,
		pictureFormat              = format,
		maxCodedExtent             = extent,
		referencePictureFormat     = format,
		maxDpbSlots                = u32(config.dpb_slots),
		maxActiveReferencePictures = u32(config.max_references),
		pStdHeaderVersion          = &caps.stdHeaderVersion,
	}
	stage = "create video session"
	if result := d.a.CreateVideoSessionKHR(d.handle, &info, nil, &dec.session);
	   result !=
	   .SUCCESS {when #config(ODECS_GPU_TRACE, false) {fmt.eprintln(result)}; return .Driver_Error}
	stage = "bind video session memory"
	bind_video_session_memory(d, dec.session, &dec.session_memory) or_return
	stage = "allocate output images"
	for &slot in dec.slots[:dec.depth] {
		alloc_image(d, &slot.output, aligned, format, usage, profile, flags) or_return
		if config.output_storage == .Device {
			view := vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = slot.output.handle,
				viewType = .D2,
				format = config.bit_depth == 10 ? .R16_UNORM : .R8_UNORM,
				subresourceRange = {aspectMask = {.PLANE_0}, levelCount = 1, layerCount = 1},
			}
			if d.a.CreateImageView(d.handle, &view, nil, &slot.output.y_view) != .SUCCESS do return .Unsupported
			view.format, view.subresourceRange.aspectMask =
				config.bit_depth == 10 ? .R16G16_UNORM : .R8G8_UNORM, {.PLANE_1}
			if d.a.CreateImageView(d.handle, &view, nil, &slot.output.uv_view) != .SUCCESS do return .Unsupported
		}
	}
	dec.dpb = make([]Image, config.dpb_slots)
	stage = "allocate DPB images"
	for &image in dec.dpb {
		alloc_image(d, &image, aligned, format, {.VIDEO_DECODE_DPB_KHR}, profile) or_return
	}
	dec.bitstream_alignment = max(1, int(caps.minBitstreamBufferSizeAlignment))
	stage = "allocate command and readback resources"
	pixel_count := config.width * config.height * 3 / 2
	for &slot in dec.slots[:dec.depth] {
		alloc_command(d, &slot.command, d.queue_family) or_return
		if config.output_storage == .Host {
			alloc_buffer(d, &slot.readback, pixel_count * (config.bit_depth == 10 ? 2 : 1), {.TRANSFER_DST}) or_return
			alloc_command(d, &slot.transfer, d.transfer_family) or_return
		}
	}
	if config.output_storage == .Host {
		dec.chroma = make([]u8, pixel_count * (config.bit_depth == 10 ? 2 : 1))
		alloc_semaphore(d, &dec.decoded, true) or_return
		alloc_semaphore(d, &dec.read, true) or_return
	} else {
		alloc_semaphore(d, &dec.surface_ready, true) or_return
	}
	dec.initialized = true
	return .None
}

set_decoder_parameters :: proc(dec: ^Decoder, parameters: ^Decode_Parameters) -> (err: Error) {
	defer when #config(
		ODECS_GPU_TRACE,
		false,
	) {if err != .None do fmt.eprintln("Vulkan decoder parameters:", err)}
	if dec == nil || !dec.initialized || dec.failed || parameters == nil do return .Invalid_Argument
	d := &dec.device
	add := vk.VideoDecodeH265SessionParametersAddInfoKHR {
		sType       = .VIDEO_DECODE_H265_SESSION_PARAMETERS_ADD_INFO_KHR,
		stdVPSCount = u32(len(parameters.h265_vps)),
		pStdVPSs    = raw_data(parameters.h265_vps),
		stdSPSCount = u32(len(parameters.h265_sps)),
		pStdSPSs    = raw_data(parameters.h265_sps),
		stdPPSCount = u32(len(parameters.h265_pps)),
		pStdPPSs    = raw_data(parameters.h265_pps),
	}
	codec := vk.VideoDecodeH265SessionParametersCreateInfoKHR {
		sType              = .VIDEO_DECODE_H265_SESSION_PARAMETERS_CREATE_INFO_KHR,
		maxStdVPSCount     = 16,
		maxStdSPSCount     = 16,
		maxStdPPSCount     = 64,
		pParametersAddInfo = &add,
	}
	add264 := vk.VideoDecodeH264SessionParametersAddInfoKHR {
		sType       = .VIDEO_DECODE_H264_SESSION_PARAMETERS_ADD_INFO_KHR,
		stdSPSCount = u32(len(parameters.h264_sps)),
		pStdSPSs    = raw_data(parameters.h264_sps),
		stdPPSCount = u32(len(parameters.h264_pps)),
		pStdPPSs    = raw_data(parameters.h264_pps),
	}
	codec264 := vk.VideoDecodeH264SessionParametersCreateInfoKHR {
		sType              = .VIDEO_DECODE_H264_SESSION_PARAMETERS_CREATE_INFO_KHR,
		maxStdSPSCount     = 32,
		maxStdPPSCount     = 256,
		pParametersAddInfo = &add264,
	}
	codec_av1 := vk.VideoDecodeAV1SessionParametersCreateInfoKHR {
		sType              = .VIDEO_DECODE_AV1_SESSION_PARAMETERS_CREATE_INFO_KHR,
		pStdSequenceHeader = parameters.av1,
	}
	info := vk.VideoSessionParametersCreateInfoKHR {
		sType        = .VIDEO_SESSION_PARAMETERS_CREATE_INFO_KHR,
		pNext        = &codec,
		videoSession = dec.session,
	}
	switch dec.config.codec {
	case .H264:
		if len(parameters.h264_sps) == 0 || len(parameters.h264_pps) == 0 || len(parameters.h264_sps) > 32 || len(parameters.h264_pps) > 256 do return .Invalid_Argument
		info.pNext = &codec264
	case .H265:
		if len(parameters.h265_vps) == 0 || len(parameters.h265_sps) == 0 || len(parameters.h265_pps) == 0 || len(parameters.h265_vps) > 16 || len(parameters.h265_sps) > 16 || len(parameters.h265_pps) > 64 do return .Invalid_Argument
	case .AV1:
		if parameters.av1 == nil || parameters.av1.pColorConfig == nil do return .Invalid_Argument
		info.pNext = &codec_av1
	}
	handle: vk.VideoSessionParametersKHR
	if result := d.a.CreateVideoSessionParametersKHR(d.handle, &info, nil, &handle);
	   result !=
	   .SUCCESS {when #config(ODECS_GPU_TRACE, false) {fmt.eprintln(result)}; return .Driver_Error}
	if dec.parameters != 0 do d.a.DestroyVideoSessionParametersKHR(d.handle, dec.parameters, nil)
	dec.parameters = handle
	return .None
}

// decode_picture submits one fully prepared picture. The frontend remains
// responsible for valid syntax, references and display order; `picture` and
// `packet` are borrowed only until this call returns.
//
// Pictures come back in submission order. Device output and the first
// depth-1 host pictures aside, each call returns the picture submitted
// depth-1 calls earlier (`ready`); finish_decoder returns the rest. A
// returned frame's host planes are valid until the next call.
decode_picture :: proc(
	dec: ^Decoder,
	packet: []u8,
	picture: Decode_Picture,
) -> (
	frame: Decoder_Frame,
	ready: bool,
	err: Error,
) {
	stage := "arguments"
	defer when #config(
		ODECS_GPU_TRACE,
		false,
	) {if err != .None do fmt.eprintln("Vulkan decode:", stage, err)}
	if dec == nil || !dec.initialized || dec.failed || dec.parameters == 0 || len(packet) == 0 || len(picture.slice_offsets) == 0 || picture.setup_slot < 0 || picture.setup_slot >= len(dec.dpb) || len(picture.references) > dec.config.max_references do return frame, false, .Invalid_Argument
	for offset, i in picture.slice_offsets {
		if int(offset) >= len(packet) || (i > 0 && offset <= picture.slice_offsets[i - 1]) do return frame, false, .Invalid_Argument
	}
	if dec.config.codec == .AV1 {
		if len(picture.tile_sizes) != len(picture.slice_offsets) || int(picture.av1_header_offset) >= len(packet) do return frame, false, .Invalid_Argument
		for size, i in picture.tile_sizes do if size == 0 || int(size) > len(packet) - int(picture.slice_offsets[i]) do return frame, false, .Invalid_Argument
	}
	w, h := dec.config.width, dec.config.height
	if picture.width != 0 do w, h = picture.width, picture.height
	if w <= 0 || h <= 0 || w > dec.config.width || h > dec.config.height do return frame, false, .Invalid_Argument
	for reference, i in picture.references {
		if reference.slot < 0 || reference.slot >= len(dec.dpb) || reference.slot == picture.setup_slot || reference.width > dec.config.width || reference.height > dec.config.height do return frame, false, .Invalid_Argument
		for previous in picture.references[:i] {
			if reference.slot == previous.slot do return frame, false, .Invalid_Argument
		}
	}
	first := dec.submitted == 0
	if (first || picture.reset) && len(picture.references) != 0 do return frame, false, .Invalid_Argument
	range := int(align_u64(u64(len(packet)), u64(dec.bitstream_alignment)))
	limit := dec.config.max_packet_bytes != 0 ? dec.config.max_packet_bytes : 128 * 1024 * 1024
	if range > limit do return frame, false, .Output_Overflow
	d := &dec.device
	slot := &dec.slots[dec.submitted % dec.depth]
	if dec.config.output_storage == .Device && !first {
		// External consumers use the exported compute queue and finish their
		// submissions before returning the borrowed frame callback.
		if d.a.QueueWaitIdle(d.transfer_queue) != .SUCCESS do return frame, false, .Driver_Error
	}
	defer if err != .None && err != .Invalid_Argument && err != .Output_Overflow do dec.failed = true
	// The slot's previous picture has been returned, so its buffers are idle.
	if range > slot.bitstream.size {
		stage = "grow bitstream buffer"
		size := max(range, 2 * slot.bitstream.size, w * h / 2 + 65536)
		size = int(align_u64(u64(min(size, limit)), u64(dec.bitstream_alignment)))
		vp: Video_Profile
		if error := configure_video_profile(&vp, dec.request); error != .None do return frame, false, error
		free_buffer(d, &slot.bitstream)
		if error := alloc_buffer(d, &slot.bitstream, size, {.VIDEO_DECODE_SRC_KHR}, &vp.info); error != .None do return frame, false, error
	}
	copy(slot.bitstream.mapped[:len(packet)], packet)
	stage = "flush bitstream"
	for &byte in slot.bitstream.mapped[len(packet):range] do byte = 0
	if error := sync_buffer(d, &slot.bitstream, true); error != .None do return frame, false, error
	if error := begin_command(d, &slot.command); error != .None do return frame, false, error
	stage = "record picture"
	command := slot.command.handle
	// Earlier pictures in flight wrote the DPB images this one reads.
	memory_barrier(d, command, {.VIDEO_DECODE_KHR}, {.VIDEO_DECODE_KHR}, {.VIDEO_DECODE_WRITE_KHR}, {.VIDEO_DECODE_READ_KHR, .VIDEO_DECODE_WRITE_KHR})
	image_barrier(
		d,
		command,
		&slot.output,
		.VIDEO_DECODE_DST_KHR,
		{.ALL_COMMANDS},
		{.VIDEO_DECODE_KHR},
		{.MEMORY_READ},
		{.VIDEO_DECODE_WRITE_KHR},
	)
	image_barrier(
		d,
		command,
		&dec.dpb[picture.setup_slot],
		.VIDEO_DECODE_DPB_KHR,
		{.ALL_COMMANDS},
		{.VIDEO_DECODE_KHR},
		{.MEMORY_READ, .MEMORY_WRITE},
		{.VIDEO_DECODE_READ_KHR, .VIDEO_DECODE_WRITE_KHR},
	)
	resources: [18]vk.VideoPictureResourceInfoKHR
	ref_info: [18]vk.VideoDecodeH265ReferenceInfo
	ref_codec: [18]vk.VideoDecodeH265DpbSlotInfoKHR
	ref_info264: [18]vk.VideoDecodeH264ReferenceInfo
	ref_codec264: [18]vk.VideoDecodeH264DpbSlotInfoKHR
	ref_info_av1: [18]vk.VideoDecodeAV1ReferenceInfo
	ref_codec_av1: [18]vk.VideoDecodeAV1DpbSlotInfoKHR
	slots: [18]vk.VideoReferenceSlotInfoKHR
	extent := vk.Extent2D{u32(w), u32(h)}
	for reference, i in picture.references {
		resources[i] = {
			sType            = .VIDEO_PICTURE_RESOURCE_INFO_KHR,
			codedExtent      = reference.width != 0 ? {u32(reference.width), u32(reference.height)} : {u32(dec.config.width), u32(dec.config.height)},
			imageViewBinding = dec.dpb[reference.slot].view,
		}
		slots[i] = {
			sType            = .VIDEO_REFERENCE_SLOT_INFO_KHR,
			slotIndex        = i32(reference.slot),
			pPictureResource = &resources[i],
		}
		switch dec.config.codec {
		case .H264:
			ref_info264[i] = reference.h264
			ref_codec264[i] = {sType = .VIDEO_DECODE_H264_DPB_SLOT_INFO_KHR, pStdReferenceInfo = &ref_info264[i]}
			slots[i].pNext = &ref_codec264[i]
		case .H265:
			ref_info[i] = reference.h265
			ref_codec[i] = {sType = .VIDEO_DECODE_H265_DPB_SLOT_INFO_KHR, pStdReferenceInfo = &ref_info[i]}
			slots[i].pNext = &ref_codec[i]
		case .AV1:
			ref_info_av1[i] = reference.av1
			ref_codec_av1[i] = {sType = .VIDEO_DECODE_AV1_DPB_SLOT_INFO_KHR, pStdReferenceInfo = &ref_info_av1[i]}
			slots[i].pNext = &ref_codec_av1[i]
		}
	}
	i := len(picture.references)
	resources[i] = {
		sType            = .VIDEO_PICTURE_RESOURCE_INFO_KHR,
		codedExtent      = extent,
		imageViewBinding = dec.dpb[picture.setup_slot].view,
	}
	slots[i] = {
		sType            = .VIDEO_REFERENCE_SLOT_INFO_KHR,
		slotIndex        = -1,
		pPictureResource = &resources[i],
	}
	begin := vk.VideoBeginCodingInfoKHR {
		sType                  = .VIDEO_BEGIN_CODING_INFO_KHR,
		videoSession           = dec.session,
		videoSessionParameters = dec.parameters,
		referenceSlotCount     = u32(i + 1),
		pReferenceSlots        = raw_data(slots[:]),
	}
	d.a.CmdBeginVideoCodingKHR(command, &begin)
	if first || picture.reset {
		reset := vk.VideoCodingControlInfoKHR {
			sType = .VIDEO_CODING_CONTROL_INFO_KHR,
			flags = {.RESET},
		}
		d.a.CmdControlVideoCodingKHR(command, &reset)
	}
	setup := vk.VideoReferenceSlotInfoKHR {
		sType            = .VIDEO_REFERENCE_SLOT_INFO_KHR,
		slotIndex        = i32(picture.setup_slot),
		pPictureResource = &resources[i],
	}
	std_pic := picture.h265
	codec := vk.VideoDecodeH265PictureInfoKHR {
		sType                = .VIDEO_DECODE_H265_PICTURE_INFO_KHR,
		pStdPictureInfo      = &std_pic,
		sliceSegmentCount    = u32(len(picture.slice_offsets)),
		pSliceSegmentOffsets = raw_data(picture.slice_offsets),
	}
	std_pic264 := picture.h264
	codec264 := vk.VideoDecodeH264PictureInfoKHR {
		sType           = .VIDEO_DECODE_H264_PICTURE_INFO_KHR,
		pStdPictureInfo = &std_pic264,
		sliceCount      = u32(len(picture.slice_offsets)),
		pSliceOffsets   = raw_data(picture.slice_offsets),
	}
	std_pic_av1 := picture.av1
	codec_av1 := vk.VideoDecodeAV1PictureInfoKHR {
		sType                    = .VIDEO_DECODE_AV1_PICTURE_INFO_KHR,
		pStdPictureInfo          = &std_pic_av1,
		referenceNameSlotIndices = picture.av1_slots,
		frameHeaderOffset        = picture.av1_header_offset,
		tileCount                = u32(len(picture.slice_offsets)),
		pTileOffsets             = raw_data(picture.slice_offsets),
		pTileSizes               = raw_data(picture.tile_sizes),
	}
	decode := vk.VideoDecodeInfoKHR {
		sType = .VIDEO_DECODE_INFO_KHR,
		srcBuffer = slot.bitstream.handle,
		srcBufferRange = vk.DeviceSize(range),
		dstPictureResource = {
			sType = .VIDEO_PICTURE_RESOURCE_INFO_KHR,
			codedExtent = extent,
			imageViewBinding = slot.output.view,
		},
		pSetupReferenceSlot = &setup,
		referenceSlotCount = u32(i),
		pReferenceSlots = raw_data(slots[:]),
	}
	switch dec.config.codec {
	case .H264:
		ref_info264[i] = picture.h264_setup
		ref_codec264[i] = {sType = .VIDEO_DECODE_H264_DPB_SLOT_INFO_KHR, pStdReferenceInfo = &ref_info264[i]}
		setup.pNext, decode.pNext = &ref_codec264[i], &codec264
	case .H265:
		ref_info[i] = {PicOrderCntVal = picture.h265.PicOrderCntVal}
		ref_codec[i] = {sType = .VIDEO_DECODE_H265_DPB_SLOT_INFO_KHR, pStdReferenceInfo = &ref_info[i]}
		setup.pNext, decode.pNext = &ref_codec[i], &codec
	case .AV1:
		ref_info_av1[i] = picture.av1_setup
		ref_codec_av1[i] = {sType = .VIDEO_DECODE_AV1_DPB_SLOT_INFO_KHR, pStdReferenceInfo = &ref_info_av1[i]}
		setup.pNext, decode.pNext = &ref_codec_av1[i], &codec_av1
	}
	d.a.CmdDecodeVideoKHR(command, &decode)
	end := vk.VideoEndCodingInfoKHR {
		sType = .VIDEO_END_CODING_INFO_KHR,
	}
	d.a.CmdEndVideoCodingKHR(command, &end)
	slot.width, slot.height = w, h
	if dec.config.output_storage == .Device {
		stage = "submit device picture"
		image_barrier(
			d,
			command,
			&slot.output,
			.GENERAL,
			{.VIDEO_DECODE_KHR},
			{.ALL_COMMANDS},
			{.VIDEO_DECODE_WRITE_KHR},
			{.MEMORY_READ},
		)
		dec.surface_value += 1
		if error := submit_command(d, &slot.command, d.queue, dec.surface_ready, 0, {.ALL_COMMANDS}, dec.surface_value); error != .None do return frame, false, error
		dec.submitted += 1
		dec.returned += 1
		frame = {
			width = w,
			height = h,
			coded_width = w,
			coded_height = h,
			bit_depth = dec.config.bit_depth,
			storage_bits = 16,
			surface = {
				device = d.handle,
				physical_device = d.physical,
				device_api = d.a,
				get_memory_properties = d.i.GetPhysicalDeviceMemoryProperties,
				image = slot.output.handle,
				view = slot.output.view,
				usage = {.VIDEO_DECODE_DST_KHR, .TRANSFER_SRC, .SAMPLED},
				format = dec.config.bit_depth == 10 ? .G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16 : .G8_B8R8_2PLANE_420_UNORM,
				layout = .GENERAL,
				queue_family = d.queue_family,
				compute_queue_family = d.transfer_family,
				compute_queue = d.transfer_queue,
				y_view = slot.output.y_view,
				uv_view = slot.output.uv_view,
				ready_semaphore = dec.surface_ready,
				ready_value = dec.surface_value,
				width = w,
				height = h,
				bit_depth = dec.config.bit_depth,
			},
		}
		return frame, true, .None
	}
	k := u64(dec.submitted)
	stage = "submit host picture"
	if error := submit_async(d, d.queue, command, {dec.decoded, k + 1}); error != .None do return frame, false, error
	stage = "record readback"
	if error := begin_command(d, &slot.transfer); error != .None do return frame, false, error
	transfer := slot.transfer.handle
	image_barrier(
		d,
		transfer,
		&slot.output,
		.TRANSFER_SRC_OPTIMAL,
		{.ALL_COMMANDS},
		{.COPY},
		{.MEMORY_WRITE},
		{.TRANSFER_READ},
	)
	cw, ch := (w + 1) / 2, (h + 1) / 2
	bytes_per_pixel := dec.config.bit_depth == 10 ? 2 : 1
	copies := [2]vk.BufferImageCopy {
		{
			imageSubresource = {aspectMask = {.PLANE_0}, layerCount = 1},
			imageExtent = {u32(w), u32(h), 1},
		},
		{
			bufferOffset = vk.DeviceSize(w * h * bytes_per_pixel),
			imageSubresource = {aspectMask = {.PLANE_1}, layerCount = 1},
			imageExtent = {u32(cw), u32(ch), 1},
		},
	}
	d.a.CmdCopyImageToBuffer(transfer, slot.output.handle, .TRANSFER_SRC_OPTIMAL, slot.readback.handle, 2, raw_data(copies[:]))
	memory_barrier(d, transfer, {.COPY}, {.HOST}, {.TRANSFER_WRITE}, {.HOST_READ})
	stage = "submit readback"
	if error := submit_async(d, d.transfer_queue, transfer, {dec.read, k + 1}, {dec.decoded, k + 1}); error != .None do return frame, false, error
	dec.submitted += 1
	if dec.submitted - dec.returned < dec.depth do return frame, false, .None
	return collect_picture(dec)
}

// Returns the oldest picture still in flight, if any. Call it until it
// returns nothing to drain the decoder (at the end of a stream, or before
// output that must not wait).
finish_decoder :: proc(dec: ^Decoder) -> (frame: Decoder_Frame, ready: bool, err: Error) {
	if dec == nil || !dec.initialized || dec.failed do return frame, false, .Invalid_Argument
	if dec.returned == dec.submitted do return frame, false, .None
	return collect_picture(dec)
}

// Waits for the oldest host picture's readback and lays its NV12/P010
// samples out as planes. NV12 luma is already a byte plane and stays in the
// readback buffer; its interleaved chroma is split. P010 keeps its samples
// in the high bits, so every plane is shifted down.
@(private)
collect_picture :: proc(dec: ^Decoder) -> (frame: Decoder_Frame, ready: bool, err: Error) {
	defer if err != .None do dec.failed = true
	d := &dec.device
	slot := &dec.slots[dec.returned % dec.depth]
	if error := wait_timeline(d, {dec.read, u64(dec.returned + 1)}); error != .None do return frame, false, error
	if error := sync_buffer(d, &slot.readback, false); error != .None do return frame, false, error
	dec.returned += 1
	w, h := slot.width, slot.height
	cw, ch := (w + 1) / 2, (h + 1) / 2
	frame = {
		width        = w,
		height       = h,
		coded_width  = w,
		coded_height = h,
		bit_depth    = dec.config.bit_depth,
	}
	if dec.config.bit_depth == 8 {
		frame.storage_bits = 8
		frame.strides = {w, cw, cw}
		chroma := slot.readback.mapped[w * h:][:2 * cw * ch]
		u, v := dec.chroma[:cw * ch], dec.chroma[cw * ch:][:cw * ch]
		#no_bounds_check for i in 0 ..< cw * ch {
			u[i] = chroma[2 * i]
			v[i] = chroma[2 * i + 1]
		}
		frame.planes = {slot.readback.mapped[:w * h], u, v}
	} else {
		frame.storage_bits = 16
		frame.strides = {2 * w, 2 * cw, 2 * cw}
		mapped := ([^]u16)(slot.readback.mapped)
		out := ([^]u16)(raw_data(dec.chroma))
		luma, chroma := mapped[:w * h], mapped[w * h:][:2 * cw * ch]
		y, u, v := out[:w * h], out[w * h:][:cw * ch], out[w * h + cw * ch:][:cw * ch]
		#no_bounds_check {
			for i in 0 ..< w * h do y[i] = luma[i] >> 6
			for i in 0 ..< cw * ch {
				u[i] = chroma[2 * i] >> 6
				v[i] = chroma[2 * i + 1] >> 6
			}
		}
		bytes := dec.chroma[:2 * (w * h + 2 * cw * ch)]
		frame.planes = {bytes[:2 * w * h], bytes[2 * w * h:][:2 * cw * ch], bytes[2 * (w * h + cw * ch):][:2 * cw * ch]}
	}
	return frame, true, .None
}

destroy_decoder :: proc(dec: ^Decoder) {
	if dec == nil do return
	d := &dec.device
	if d.handle != nil {
		d.a.DeviceWaitIdle(d.handle)
		if dec.decoded != 0 do d.a.DestroySemaphore(d.handle, dec.decoded, nil)
		if dec.read != 0 do d.a.DestroySemaphore(d.handle, dec.read, nil)
		if dec.surface_ready != 0 do d.a.DestroySemaphore(d.handle, dec.surface_ready, nil)
		for &slot in dec.slots {
			free_command(d, &slot.command)
			free_command(d, &slot.transfer)
			free_image(d, &slot.output)
			free_buffer(d, &slot.bitstream)
			free_buffer(d, &slot.readback)
		}
		for &image in dec.dpb do free_image(d, &image)
		if dec.parameters != 0 do d.a.DestroyVideoSessionParametersKHR(d.handle, dec.parameters, nil)
		if dec.session != 0 do d.a.DestroyVideoSessionKHR(d.handle, dec.session, nil)
		for memory in dec.session_memory do d.a.FreeMemory(d.handle, memory, nil)
	}
	delete(dec.session_memory)
	delete(dec.dpb)
	delete(dec.chroma)
	destroy_device(d)
	dec^ = {}
}

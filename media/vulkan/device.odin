package media_vulkan

import "core:dynlib"
import "core:reflect"
import "core:strings"
import "core:sync"
import vk "vendor:vulkan"

// Vulkan is loaded only when a hardware session/probe is requested. Importing
// this package does not require an installed Vulkan loader or a GPU.
Error :: enum {
	None,
	Invalid_Argument,
	Loader_Unavailable,
	No_Device,
	Unsupported,
	Driver_Error,
	Out_Of_Memory,
	Output_Overflow,
	Busy,
}

Codec :: enum {
	H264,
	H265,
	AV1, // decode only
}
Operation :: enum {
	Decode,
	Encode,
}
Request :: struct {
	codec:           Codec,
	operation:       Operation,
	width, height:   int,
	bit_depth:       int,
	profile_idc:     int, // AV1: 0, Main
	require_compute: bool, // resident output needs a usable compute queue
	film_grain:      bool, // AV1: the decoder applies film grain to its output
}
Capability :: struct {
	device_index:                                 int,
	device_name:                                  [vk.MAX_PHYSICAL_DEVICE_NAME_SIZE]u8,
	request:                                      Request,
	min_width, min_height, max_width, max_height: int,
	max_references, max_dpb_slots:                int,
	// Driver support is distinct from the operational Annex-B implementations.
	driver_supported:                             bool,
	annex_b_implemented:                          bool,
}

@(private)
Instance_API :: struct {
	EnumeratePhysicalDevices:                  vk.ProcEnumeratePhysicalDevices,
	GetPhysicalDeviceProperties:               vk.ProcGetPhysicalDeviceProperties,
	GetPhysicalDeviceMemoryProperties:         vk.ProcGetPhysicalDeviceMemoryProperties,
	GetPhysicalDeviceFeatures2:                vk.ProcGetPhysicalDeviceFeatures2,
	GetPhysicalDeviceFormatProperties:         vk.ProcGetPhysicalDeviceFormatProperties,
	GetPhysicalDeviceQueueFamilyProperties2:   vk.ProcGetPhysicalDeviceQueueFamilyProperties2,
	EnumerateDeviceExtensionProperties:        vk.ProcEnumerateDeviceExtensionProperties,
	GetPhysicalDeviceVideoCapabilitiesKHR:     vk.ProcGetPhysicalDeviceVideoCapabilitiesKHR,
	GetPhysicalDeviceVideoFormatPropertiesKHR: vk.ProcGetPhysicalDeviceVideoFormatPropertiesKHR,
	CreateDevice:                              vk.ProcCreateDevice,
	GetDeviceProcAddr:                         vk.ProcGetDeviceProcAddr,
}

@(private)
Device :: struct {
	get_instance_proc:             vk.ProcGetInstanceProcAddr,
	instance:                      vk.Instance,
	i:                             Instance_API,
	physical:                      vk.PhysicalDevice,
	handle:                        vk.Device,
	api:                           vk.Device_VTable,
	a:                             ^vk.Device_VTable,
	shared_context:                ^Context,
	queue, transfer_queue:         vk.Queue,
	queue_family, transfer_family: u32,
	query_status:                  bool,
	properties:                    vk.PhysicalDeviceProperties,
	memory:                        vk.PhysicalDeviceMemoryProperties,
}

// One Vulkan instance serves the process: the loader is opened once, the
// instance created once, and neither is released. With the Khronos loader
// (1.4.363), a vkCreateInstance on one thread while another thread was in
// vkEnumerateInstanceExtensionProperties (SDL creating its GPU device) made
// the loader call a null driver entry; each probe used to create and destroy
// its own instance.
@(private)
Shared_Instance :: struct {
	once:              sync.Once,
	err:               Error,
	get_instance_proc: vk.ProcGetInstanceProcAddr,
	instance:          vk.Instance,
	i:                 Instance_API,
}
@(private)
shared_instance: Shared_Instance

@(private)
create_shared_instance :: proc() {
	s := &shared_instance
	s.err = .Loader_Unavailable
	lib, loaded := dynlib.load_library(ODIN_OS == .Windows ? "vulkan-1.dll" : "libvulkan.so.1")
	if !loaded do return
	address, found := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	if !found do return
	s.get_instance_proc = cast(vk.ProcGetInstanceProcAddr)address
	create := cast(vk.ProcCreateInstance)s.get_instance_proc(nil, "vkCreateInstance")
	if create == nil do return
	app := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "odecs hardware video",
		apiVersion       = vk.API_VERSION_1_3,
	}
	info := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &app,
	}
	s.err = .Driver_Error
	if create(&info, nil, &s.instance) != .SUCCESS do return
	for field in reflect.struct_fields_zipped(Instance_API) {
		name := strings.clone_to_cstring(
			strings.concatenate({"vk", field.name}, context.temp_allocator),
			context.temp_allocator,
		)
		(cast(^rawptr)(uintptr(&s.i) + field.offset))^ = rawptr(
			s.get_instance_proc(s.instance, name),
		)
	}
	if s.i.EnumeratePhysicalDevices == nil do return
	s.err = .None
}

@(private)
load_instance :: proc(d: ^Device) -> Error {
	when ODIN_OS != .Linux && ODIN_OS != .Windows do return .Unsupported
	sync.once_do(&shared_instance.once, create_shared_instance)
	if shared_instance.err != .None do return shared_instance.err
	d.get_instance_proc = shared_instance.get_instance_proc
	d.instance = shared_instance.instance
	d.i = shared_instance.i
	return .None
}

@(private)
destroy_device :: proc(d: ^Device) {
	if d.shared_context != nil {
		release_context(d.shared_context)
		d^ = {}
		return
	}
	if d.handle != nil {
		d.a.DeviceWaitIdle(d.handle)
		d.a.DestroyDevice(d.handle, nil)
	}
	d^ = {}
}

@(private)
extensions :: proc(
	d: ^Device,
	physical: vk.PhysicalDevice,
) -> (
	result: []vk.ExtensionProperties,
	err: Error,
) {
	count: u32
	if d.i.EnumerateDeviceExtensionProperties(physical, nil, &count, nil) != .SUCCESS do return nil, .Driver_Error
	result = make([]vk.ExtensionProperties, count)
	if d.i.EnumerateDeviceExtensionProperties(physical, nil, &count, raw_data(result)) !=
	   .SUCCESS {
		delete(result)
		return nil, .Driver_Error
	}
	return result[:count], .None
}

@(private)
has_extension :: proc(list: []vk.ExtensionProperties, name: string) -> bool {
	for &e in list {
		if string(cstring(raw_data(e.extensionName[:]))) == name do return true
	}
	return false
}

// Per codec and operation: the extension and the video operation. AV1
// encoding is not implemented.
@(private, rodata)
CODEC_EXTENSIONS := [Codec][Operation]cstring {
	.H264 = {.Decode = "VK_KHR_video_decode_h264", .Encode = "VK_KHR_video_encode_h264"},
	.H265 = {.Decode = "VK_KHR_video_decode_h265", .Encode = "VK_KHR_video_encode_h265"},
	.AV1 = {.Decode = "VK_KHR_video_decode_av1", .Encode = "VK_KHR_video_encode_av1"},
}
@(private, rodata)
CODEC_OPERATIONS := [Codec][Operation]vk.VideoCodecOperationFlagKHR {
	.H264 = {.Decode = .DECODE_H264, .Encode = .ENCODE_H264},
	.H265 = {.Decode = .DECODE_H265, .Encode = .ENCODE_H265},
	.AV1 = {.Decode = .DECODE_AV1, .Encode = .ENCODE_AV1},
}

@(private)
required_extensions :: proc(r: Request) -> [3]cstring {
	return {
		"VK_KHR_video_queue",
		r.operation == .Encode ? "VK_KHR_video_encode_queue" : "VK_KHR_video_decode_queue",
		CODEC_EXTENSIONS[r.codec][r.operation],
	}
}

@(private)
Video_Profile :: struct {
	info:        vk.VideoProfileInfoKHR,
	encode_h264: vk.VideoEncodeH264ProfileInfoKHR,
	decode_h264: vk.VideoDecodeH264ProfileInfoKHR,
	encode_h265: vk.VideoEncodeH265ProfileInfoKHR,
	decode_h265: vk.VideoDecodeH265ProfileInfoKHR,
	decode_av1:  vk.VideoDecodeAV1ProfileInfoKHR,
}

// Decode capabilities with the codec's structure chained, at a stable
// address because the chain points into this storage.
@(private)
Decode_Capabilities :: struct {
	caps:   vk.VideoCapabilitiesKHR,
	decode: vk.VideoDecodeCapabilitiesKHR,
	h264:   vk.VideoDecodeH264CapabilitiesKHR,
	h265:   vk.VideoDecodeH265CapabilitiesKHR,
	av1:    vk.VideoDecodeAV1CapabilitiesKHR,
}

@(private)
chain_decode_capabilities :: proc(c: ^Decode_Capabilities, codec: Codec) {
	c.h264 = {sType = .VIDEO_DECODE_H264_CAPABILITIES_KHR}
	c.h265 = {sType = .VIDEO_DECODE_H265_CAPABILITIES_KHR}
	c.av1 = {sType = .VIDEO_DECODE_AV1_CAPABILITIES_KHR}
	codec_caps: rawptr
	switch codec {
	case .H264:
		codec_caps = &c.h264
	case .H265:
		codec_caps = &c.h265
	case .AV1:
		codec_caps = &c.av1
	}
	c.decode = {sType = .VIDEO_DECODE_CAPABILITIES_KHR, pNext = codec_caps}
	c.caps = {sType = .VIDEO_CAPABILITIES_KHR, pNext = &c.decode}
}

// Populate at a stable address because info points into this storage.
@(private)
configure_video_profile :: proc(p: ^Video_Profile, r: Request) -> Error {
	if r.profile_idc < 0 || r.profile_idc > 255 do return .Unsupported
	if r.bit_depth != 8 && r.bit_depth != 10 do return .Unsupported
	if r.codec == .H264 && r.bit_depth != 8 do return .Unsupported
	if r.codec == .AV1 && (r.operation == .Encode || r.profile_idc != 0) do return .Unsupported
	p.info = {
		sType             = .VIDEO_PROFILE_INFO_KHR,
		chromaSubsampling = {._420},
		lumaBitDepth      = r.bit_depth == 10 ? vk.VideoComponentBitDepthFlagsKHR{._10} : {._8},
		chromaBitDepth    = r.bit_depth == 10 ? vk.VideoComponentBitDepthFlagsKHR{._10} : {._8},
	}
	p.info.videoCodecOperation = {CODEC_OPERATIONS[r.codec][r.operation]}
	if r.codec == .AV1 {
		p.decode_av1 = {
			sType            = .VIDEO_DECODE_AV1_PROFILE_INFO_KHR,
			stdProfile       = vk.VideoAV1Profile(0), // Main (the std enum is empty in the bindings)
			filmGrainSupport = b32(r.film_grain),
		}
		p.info.pNext = &p.decode_av1
		return .None
	}
	profile :=
		r.profile_idc != 0 ? r.profile_idc : (r.codec == .H264 ? 100 : (r.bit_depth == 10 ? 2 : 1))
	if r.codec == .H264 {
		if r.operation == .Encode {
			p.encode_h264 = {
				sType         = .VIDEO_ENCODE_H264_PROFILE_INFO_KHR,
				stdProfileIdc = vk.VideoH264ProfileIdc(i32(profile)),
			}
			p.info.pNext = &p.encode_h264
		} else {
			p.decode_h264 = {
				sType         = .VIDEO_DECODE_H264_PROFILE_INFO_KHR,
				stdProfileIdc = vk.VideoH264ProfileIdc(i32(profile)),
			}
			p.info.pNext = &p.decode_h264
		}
	} else {
		if profile != 1 && profile != 2 do return .Unsupported
		if r.operation == .Encode {
			p.encode_h265 = {
				sType         = .VIDEO_ENCODE_H265_PROFILE_INFO_KHR,
				stdProfileIdc = vk.VideoH265ProfileIdc(i32(profile)),
			}
			p.info.pNext = &p.encode_h265
		} else {
			p.decode_h265 = {
				sType         = .VIDEO_DECODE_H265_PROFILE_INFO_KHR,
				stdProfileIdc = vk.VideoH265ProfileIdc(i32(profile)),
			}
			p.info.pNext = &p.decode_h265
		}
	}
	return .None
}

@(private)
query_capability :: proc(
	d: ^Device,
	physical: vk.PhysicalDevice,
	r: Request,
) -> (
	caps: vk.VideoCapabilitiesKHR,
	enc: vk.VideoEncodeCapabilitiesKHR,
	h264: vk.VideoEncodeH264CapabilitiesKHR,
	err: Error,
) {
	if r.bit_depth != 8 && r.bit_depth != 10 do return caps, enc, h264, .Unsupported
	if r.codec == .H264 && r.bit_depth != 8 do return caps, enc, h264, .Unsupported
	if d.i.GetPhysicalDeviceVideoCapabilitiesKHR == nil do return caps, enc, h264, .Unsupported
	list, e := extensions(d, physical)
	if e != .None do return caps, enc, h264, e
	defer delete(list)
	for name in required_extensions(r) {
		if !has_extension(list, string(name)) do return caps, enc, h264, .Unsupported
	}
	profile: Video_Profile
	if e = configure_video_profile(&profile, r); e != .None do return caps, enc, h264, e
	decode: Decode_Capabilities
	chain_decode_capabilities(&decode, r.codec)
	ce265 := vk.VideoEncodeH265CapabilitiesKHR {
		sType = .VIDEO_ENCODE_H265_CAPABILITIES_KHR,
	}
	h264 = {
		sType = .VIDEO_ENCODE_H264_CAPABILITIES_KHR,
	}
	enc = {
		sType = .VIDEO_ENCODE_CAPABILITIES_KHR,
	}
	caps = {
		sType = .VIDEO_CAPABILITIES_KHR,
	}
	if r.operation == .Encode {
		caps.pNext = &enc
		if r.codec == .H264 {enc.pNext = &h264} else {enc.pNext = &ce265}
	} else {
		caps.pNext = &decode.decode
	}
	result := d.i.GetPhysicalDeviceVideoCapabilitiesKHR(physical, &profile.info, &caps)
	caps.pNext, enc.pNext, h264.pNext = nil, nil, nil
	if result != .SUCCESS do return caps, enc, h264, .Unsupported
	if r.width < 0 || r.height < 0 do return caps, enc, h264, .Invalid_Argument
	if (r.width > 0 &&
		   (r.width < int(caps.minCodedExtent.width) ||
				   r.width > int(caps.maxCodedExtent.width))) ||
	   (r.height > 0 &&
			   (r.height < int(caps.minCodedExtent.height) ||
					   r.height > int(caps.maxCodedExtent.height))) {
		return caps, enc, h264, .Unsupported
	}
	return caps, enc, h264, .None
}

// probe_capabilities queries codec profiles and compatible queue operations, not just the
// presence of an extension. The returned array belongs to the caller.
probe_capabilities :: proc(
	r: Request,
	shared_context: ^Context = nil,
) -> (
	list: [dynamic]Capability,
	err: Error,
) {
	if shared_context != nil {
		d: Device
		caps, _, _, e := borrow_context_device(&d, shared_context, r, -1)
		if e != .None do return nil, e
		defer destroy_device(&d)
		append(
			&list,
			capability_info(r, caps, shared_context.device_index, d.properties.deviceName, true),
		)
		return list, .None
	}
	d: Device
	if e := load_instance(&d); e != .None do return nil, e
	defer destroy_device(&d)
	count: u32
	if d.i.EnumeratePhysicalDevices(d.instance, &count, nil) != .SUCCESS do return nil, .Driver_Error
	if count == 0 do return nil, .No_Device
	devices := make([]vk.PhysicalDevice, count); defer delete(devices)
	if d.i.EnumeratePhysicalDevices(d.instance, &count, raw_data(devices)) != .SUCCESS do return nil, .Driver_Error
	for physical, index in devices[:count] {
		caps, _, _, e := query_capability(&d, physical, r)
		if e != .None do continue
		if family, transfer, _ := video_queue(&d, physical, r); family < 0 || transfer < 0 do continue
		props: vk.PhysicalDeviceProperties
		d.i.GetPhysicalDeviceProperties(physical, &props)
		features13 := vk.PhysicalDeviceVulkan13Features {
			sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		}
		features12 := vk.PhysicalDeviceVulkan12Features {
			sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
			pNext = &features13,
		}
		features := vk.PhysicalDeviceFeatures2 {
			sType = .PHYSICAL_DEVICE_FEATURES_2,
			pNext = &features12,
		}
		d.i.GetPhysicalDeviceFeatures2(physical, &features)
		if props.apiVersion < vk.API_VERSION_1_3 || !features13.synchronization2 || !features12.timelineSemaphore do continue
		append(
			&list,
			capability_info(
				r,
				caps,
				index,
				props.deviceName,
				operational_resources_supported(&d, physical, r),
			),
		)
	}
	if len(list) == 0 do return nil, .Unsupported
	return list, .None
}

@(private)
capability_info :: proc(
	r: Request,
	caps: vk.VideoCapabilitiesKHR,
	index: int,
	name: [vk.MAX_PHYSICAL_DEVICE_NAME_SIZE]u8,
	resources: bool,
) -> Capability {
	profile :=
		r.profile_idc != 0 ? r.profile_idc : (r.codec == .H264 ? 100 : (r.bit_depth == 10 ? 2 : 1))
	implemented := false
	if r.codec == .H264 && r.bit_depth == 8 {
		implemented =
			r.operation == .Encode ? profile == 100 : (profile == 66 || profile == 77 || profile == 100)
	} else if r.codec == .H265 {
		implemented =
			r.operation == .Encode ? profile == (r.bit_depth == 10 ? 2 : 1) : ((profile == 1 && r.bit_depth == 8) || (profile == 2 && (r.bit_depth == 8 || r.bit_depth == 10)))
	} else if r.codec == .AV1 {
		implemented = r.operation == .Decode && r.profile_idc == 0
	}
	if r.operation == .Decode && .SEPARATE_REFERENCE_IMAGES not_in caps.flags do implemented = false
	return {
		device_index = index,
		device_name = name,
		request = r,
		min_width = int(caps.minCodedExtent.width),
		min_height = int(caps.minCodedExtent.height),
		max_width = int(caps.maxCodedExtent.width),
		max_height = int(caps.maxCodedExtent.height),
		max_references = int(caps.maxActiveReferencePictures),
		max_dpb_slots = int(caps.maxDpbSlots),
		driver_supported = true,
		annex_b_implemented = implemented && resources,
	}
}

// Validate requirements knowable before any stream syntax is consumed. Source
// SPS cropping, DPB/reorder depth and optional tools are admitted by frontends.
@(private)
operational_resources_supported :: proc(
	d: ^Device,
	physical: vk.PhysicalDevice,
	r: Request,
) -> bool {
	profile: Video_Profile
	if configure_video_profile(&profile, r) != .None do return false
	profiles := vk.VideoProfileListInfoKHR {
		sType        = .VIDEO_PROFILE_LIST_INFO_KHR,
		profileCount = 1,
		pProfiles    = cast([^]vk.VideoProfileInfoKHR)&profile.info,
	}
	format :=
		r.bit_depth == 10 ? vk.Format.G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16 : vk.Format.G8_B8R8_2PLANE_420_UNORM
	if r.operation == .Encode {
		return(
			supports_physical_format(
				d,
				physical,
				&profiles,
				format,
				{.VIDEO_ENCODE_SRC_KHR, .TRANSFER_DST},
			) &&
			supports_physical_format(d, physical, &profiles, format, {.VIDEO_ENCODE_DPB_KHR}) \
		)
	}
	c: Decode_Capabilities
	chain_decode_capabilities(&c, r.codec)
	if d.i.GetPhysicalDeviceVideoCapabilitiesKHR(physical, &profile.info, &c.caps) != .SUCCESS || .DPB_AND_OUTPUT_DISTINCT not_in c.decode.flags || .SEPARATE_REFERENCE_IMAGES not_in c.caps.flags do return false
	usage: vk.ImageUsageFlags = {.VIDEO_DECODE_DST_KHR, .TRANSFER_SRC}
	flags: vk.ImageCreateFlags
	if r.require_compute {
		usage += {.SAMPLED}
		flags += {.MUTABLE_FORMAT}
		if d.i.GetPhysicalDeviceFormatProperties == nil do return false
		for plane in ([2]vk.Format{r.bit_depth == 10 ? .R16_UNORM : .R8_UNORM, r.bit_depth == 10 ? .R16G16_UNORM : .R8G8_UNORM}) {
			p: vk.FormatProperties
			d.i.GetPhysicalDeviceFormatProperties(physical, plane, &p)
			if .SAMPLED_IMAGE not_in p.optimalTilingFeatures do return false
		}
	}
	return(
		supports_physical_format(d, physical, &profiles, format, usage, flags) &&
		supports_physical_format(d, physical, &profiles, format, {.VIDEO_DECODE_DPB_KHR}) \
	)
}

@(private)
video_queue :: proc(
	d: ^Device,
	physical: vk.PhysicalDevice,
	r: Request,
) -> (
	video, transfer: int,
	status: bool,
) {
	count: u32
	d.i.GetPhysicalDeviceQueueFamilyProperties2(physical, &count, nil)
	queues := make([]vk.QueueFamilyProperties2, count); defer delete(queues)
	video_info := make([]vk.QueueFamilyVideoPropertiesKHR, count); defer delete(video_info)
	status_info := make(
		[]vk.QueueFamilyQueryResultStatusPropertiesKHR,
		count,
	); defer delete(status_info)
	for i in 0 ..< int(count) {
		status_info[i] = {
			sType = .QUEUE_FAMILY_QUERY_RESULT_STATUS_PROPERTIES_KHR,
		}
		video_info[i] = {
			sType = .QUEUE_FAMILY_VIDEO_PROPERTIES_KHR,
			pNext = &status_info[i],
		}
		queues[i] = {
			sType = .QUEUE_FAMILY_PROPERTIES_2,
			pNext = &video_info[i],
		}
	}
	d.i.GetPhysicalDeviceQueueFamilyProperties2(physical, &count, raw_data(queues))
	op := vk.VideoCodecOperationFlagsKHR{CODEC_OPERATIONS[r.codec][r.operation]}
	video, transfer = -1, -1
	compute := -1
	for q, i in queues[:count] {
		if q.queueFamilyProperties.queueCount == 0 do continue
		if video_info[i].videoCodecOperations & op == op {
			video = i; status = bool(status_info[i].queryResultStatusSupport)
		}
		if transfer < 0 && (.TRANSFER in q.queueFamilyProperties.queueFlags || .GRAPHICS in q.queueFamilyProperties.queueFlags || .COMPUTE in q.queueFamilyProperties.queueFlags) do transfer = i
		if compute < 0 && .COMPUTE in q.queueFamilyProperties.queueFlags do compute = i
	}
	if compute >= 0 do transfer = compute
	else if r.require_compute do transfer = -1
	return
}

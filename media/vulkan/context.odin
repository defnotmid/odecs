package media_vulkan

import "core:mem"
import vk "vendor:vulkan"

Context_Config :: struct {
	requests:     []Request, // borrowed for initialization; codec operations form a union
	device_index: int, // -1 selects one compatible GPU, preferring discrete devices
}

// A Context owns one loader, device and dispatch table. Keep it at a stable
// address; sessions and exported descriptors borrow that owner. Calls and
// external queue submission have one serialized submitting owner.
Context :: struct {
	device:       Device,
	requests:     []Request,
	routes:       []Context_Route,
	device_index: int,
	holds:        int,
	self:         ^Context,
	initialized:  bool,
	allocator:    mem.Allocator,
}

Context_Descriptor :: struct {
	device:                vk.Device,
	physical_device:       vk.PhysicalDevice,
	device_api:            ^vk.Device_VTable,
	get_memory_properties: vk.ProcGetPhysicalDeviceMemoryProperties,
	compute_queue:         vk.Queue,
	compute_queue_family:  u32,
	device_index:          int,
}

@(private)
Context_Route :: struct {
	codec:        Codec,
	operation:    Operation,
	queue_family: u32,
	queue:        vk.Queue,
	query_status: bool,
}

init_context :: proc(c: ^Context, config: Context_Config) -> (err: Error) {
	if c == nil || c.device.instance != nil || c.initialized || len(config.requests) == 0 || len(config.requests) > 32 || config.device_index < -1 do return .Invalid_Argument
	for r in config.requests {
		if r.width < 0 || r.height < 0 do return .Invalid_Argument
		profile: Video_Profile
		if error := configure_video_profile(&profile, r); error != .None do return error
	}
	c.self = c
	c.allocator = context.allocator
	c.requests = make([]Request, len(config.requests))
	copy(c.requests, config.requests)
	defer if err != .None do destroy_context(c)
	d := &c.device
	if error := load_instance(d); error != .None do return error
	count: u32
	if d.i.EnumeratePhysicalDevices(d.instance, &count, nil) != .SUCCESS do return .Driver_Error
	if count == 0 do return .No_Device
	devices := make([]vk.PhysicalDevice, count); defer delete(devices)
	if d.i.EnumeratePhysicalDevices(d.instance, &count, raw_data(devices)) != .SUCCESS do return .Driver_Error
	best := -1
	for physical, index in devices[:count] {
		if config.device_index >= 0 && config.device_index != index do continue
		properties: vk.PhysicalDeviceProperties
		d.i.GetPhysicalDeviceProperties(physical, &properties)
		if properties.apiVersion < vk.API_VERSION_1_3 do continue
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
		if !features13.synchronization2 || !features12.timelineSemaphore do continue
		routes := make([dynamic]Context_Route)
		transfer := -1
		compatible := true
		for requested in c.requests {
			r := requested
			// A shared context is also a compute owner; never export a
			// transfer-only queue under the compute-queue contract.
			r.require_compute = true
			if _, _, _, error := query_capability(d, physical, r);
			   error != .None {compatible = false; break}
			if !operational_resources_supported(d, physical, requested) {compatible = false; break}
			video, compute, status := video_queue(d, physical, r)
			if video < 0 || compute < 0 {compatible = false; break}
			transfer = compute
			found := false
			for route in routes do if route.codec == r.codec && route.operation == r.operation {found = true; break}
			if !found do append(&routes, Context_Route{codec = r.codec, operation = r.operation, queue_family = u32(video), query_status = status})
		}
		score := properties.deviceType == .DISCRETE_GPU ? 2 : 1
		if compatible && score > best {
			best = score
			d.physical, d.properties, d.transfer_family = physical, properties, u32(transfer)
			c.device_index = index
			delete(c.routes)
			c.routes = make([]Context_Route, len(routes))
			copy(c.routes, routes[:])
		}
		delete(routes)
	}
	if d.physical == nil do return .Unsupported
	families := make([dynamic]u32); defer delete(families)
	append(&families, d.transfer_family)
	for route in c.routes {
		found := false
		for family in families do if family == route.queue_family {found = true; break}
		if !found do append(&families, route.queue_family)
	}
	extensions := make([dynamic]cstring); defer delete(extensions)
	for r in c.requests do for name in required_extensions(r) {
		found := false
		for enabled in extensions do if string(enabled) == string(name) {found = true; break}
		if !found do append(&extensions, name)
	}
	if error := create_logical_device(d, families[:], extensions[:]); error != .None do return error
	if d.a.CreateVideoSessionKHR == nil do return .Unsupported
	for &route in c.routes {
		if route.operation == .Encode && (d.a.CmdEncodeVideoKHR == nil || d.a.GetEncodedVideoSessionParametersKHR == nil) do return .Unsupported
		if route.operation == .Decode && d.a.CmdDecodeVideoKHR == nil do return .Unsupported
		d.a.GetDeviceQueue(d.handle, route.queue_family, 0, &route.queue)
	}
	d.a.GetDeviceQueue(d.handle, d.transfer_family, 0, &d.transfer_queue)
	d.i.GetPhysicalDeviceMemoryProperties(d.physical, &d.memory)
	c.initialized = true
	return .None
}

// Busy leaves every context handle and dispatch entry intact. Close borrowed
// sessions first. Empty contexts can be destroyed repeatedly.
destroy_context :: proc(c: ^Context) -> Error {
	if c == nil do return .Invalid_Argument
	if c.self != nil && c.self != c do return .Invalid_Argument
	if c.holds != 0 do return .Busy
	context.allocator = c.allocator.procedure != nil ? c.allocator : context.allocator
	destroy_device(&c.device)
	delete(c.routes)
	delete(c.requests)
	c^ = {}
	return .None
}

context_descriptor :: proc(c: ^Context) -> Context_Descriptor {
	if c == nil || !c.initialized || c.self != c do return {}
	d := &c.device
	return {
		device = d.handle,
		physical_device = d.physical,
		device_api = d.a,
		get_memory_properties = d.i.GetPhysicalDeviceMemoryProperties,
		compute_queue = d.transfer_queue,
		compute_queue_family = d.transfer_family,
		device_index = c.device_index,
	}
}

@(private)
retain_context :: proc(c: ^Context) -> Error {
	if c == nil || !c.initialized || c.self != c || c.holds == max(int) do return .Invalid_Argument
	c.holds += 1
	return .None
}

@(private)
release_context :: proc(c: ^Context) {
	if c == nil do return
	assert(c.initialized && c.self == c && c.holds > 0)
	c.holds -= 1
}

@(private)
borrow_context_device :: proc(
	d: ^Device,
	c: ^Context,
	r: Request,
	index: int,
) -> (
	caps: vk.VideoCapabilitiesKHR,
	enc: vk.VideoEncodeCapabilitiesKHR,
	h264: vk.VideoEncodeH264CapabilitiesKHR,
	err: Error,
) {
	if error := retain_context(c); error != .None do return caps, enc, h264, error
	d^ = c.device
	d.shared_context = c
	defer if err != .None do destroy_device(d)
	if index >= 0 && index != c.device_index do return caps, enc, h264, .Unsupported
	found := false
	for route in c.routes do if route.codec == r.codec && route.operation == r.operation {
		d.queue_family, d.queue, d.query_status = route.queue_family, route.queue, route.query_status
		found = true
		break
	}
	if !found do return caps, enc, h264, .Unsupported
	caps, enc, h264, err = query_capability(d, d.physical, r)
	if err != .None do return
	if !operational_resources_supported(d, d.physical, r) do return caps, enc, h264, .Unsupported
	return
}

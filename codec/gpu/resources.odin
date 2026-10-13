package gpu

import "core:reflect"
import "core:strings"
import vk "vendor:vulkan"

@(private)
open_device :: proc(
	d: ^Device,
	r: Request,
	index: int,
	shared_context: ^Context = nil,
) -> (
	caps: vk.VideoCapabilitiesKHR,
	enc: vk.VideoEncodeCapabilitiesKHR,
	h264: vk.VideoEncodeH264CapabilitiesKHR,
	err: Error,
) {
	if shared_context != nil do return borrow_context_device(d, shared_context, r, index)
	if e := load_instance(d); e != .None do return caps, enc, h264, e
	defer if err != .None do destroy_device(d)
	count: u32
	if d.i.EnumeratePhysicalDevices(d.instance, &count, nil) != .SUCCESS do return caps, enc, h264, .Driver_Error
	if count == 0 do return caps, enc, h264, .No_Device
	devices := make([]vk.PhysicalDevice, count); defer delete(devices)
	if d.i.EnumeratePhysicalDevices(d.instance, &count, raw_data(devices)) != .SUCCESS do return caps, enc, h264, .Driver_Error
	best := -1
	for physical, device_index in devices[:count] {
		if index >= 0 && index != device_index do continue
		c, e, h, error := query_capability(d, physical, r)
		if error != .None do continue
		if !operational_resources_supported(d, physical, r) do continue
		video, transfer, status := video_queue(d, physical, r)
		if video < 0 || transfer < 0 do continue
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
		props: vk.PhysicalDeviceProperties
		d.i.GetPhysicalDeviceProperties(physical, &props)
		if props.apiVersion < vk.API_VERSION_1_3 do continue
		score := props.deviceType == .DISCRETE_GPU ? 2 : 1
		if score <= best do continue
		best = score
		d.physical, d.properties, d.queue_family, d.transfer_family =
			physical, props, u32(video), u32(transfer)
		d.query_status = status
		caps, enc, h264 = c, e, h
	}
	if d.physical == nil do return caps, enc, h264, .Unsupported
	ext := required_extensions(r)
	families := [2]u32{d.queue_family, d.transfer_family}
	if error := create_logical_device(d, families[:d.queue_family == d.transfer_family ? 1 : 2], ext[:]); error != .None do return caps, enc, h264, error
	if d.a.CreateVideoSessionKHR == nil do return caps, enc, h264, .Unsupported
	if r.operation == .Encode && (d.a.CmdEncodeVideoKHR == nil || d.a.GetEncodedVideoSessionParametersKHR == nil) do return caps, enc, h264, .Unsupported
	if r.operation == .Decode && d.a.CmdDecodeVideoKHR == nil do return caps, enc, h264, .Unsupported
	d.a.GetDeviceQueue(d.handle, d.queue_family, 0, &d.queue)
	d.a.GetDeviceQueue(d.handle, d.transfer_family, 0, &d.transfer_queue)
	d.i.GetPhysicalDeviceMemoryProperties(d.physical, &d.memory)
	return caps, enc, h264, .None
}

@(private)
create_logical_device :: proc(d: ^Device, families: []u32, extensions: []cstring) -> Error {
	priority: f32 = 1
	queues := make([]vk.DeviceQueueCreateInfo, len(families)); defer delete(queues)
	for family, i in families do queues[i] = {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	features13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		synchronization2 = true,
	}
	features12 := vk.PhysicalDeviceVulkan12Features {
		sType             = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext             = &features13,
		timelineSemaphore = true,
	}
	info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features12,
		queueCreateInfoCount    = u32(len(queues)),
		pQueueCreateInfos       = raw_data(queues),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
	}
	if d.i.CreateDevice(d.physical, &info, nil, &d.handle) != .SUCCESS do return .Driver_Error
	d.a = &d.api
	for field in reflect.struct_fields_zipped(vk.Device_VTable) {
		name := strings.clone_to_cstring(
			strings.concatenate({"vk", field.name}, context.temp_allocator),
			context.temp_allocator,
		)
		(cast(^rawptr)(uintptr(&d.api) + field.offset))^ = rawptr(
			d.i.GetDeviceProcAddr(d.handle, name),
		)
	}
	return .None
}

@(private)
memory_type :: proc(d: ^Device, bits: u32, required, preferred: vk.MemoryPropertyFlags) -> int {
	best := -1
	for i in 0 ..< int(d.memory.memoryTypeCount) {
		flags := d.memory.memoryTypes[i].propertyFlags
		if bits & (1 << u32(i)) == 0 || flags & required != required do continue
		if flags & preferred == preferred do return i
		if best < 0 do best = i
	}
	return best
}

@(private)
Buffer :: struct {
	handle:   vk.Buffer,
	memory:   vk.DeviceMemory,
	mapped:   [^]u8,
	size:     int,
	coherent: bool,
}

@(private)
alloc_buffer :: proc(
	d: ^Device,
	b: ^Buffer,
	size: int,
	usage: vk.BufferUsageFlags,
	profile: ^vk.VideoProfileInfoKHR = nil,
) -> (
	err: Error,
) {
	defer if err != .None do free_buffer(d, b)
	profiles := vk.VideoProfileListInfoKHR {
		sType        = .VIDEO_PROFILE_LIST_INFO_KHR,
		profileCount = 1,
		pProfiles    = cast([^]vk.VideoProfileInfoKHR)profile,
	}
	info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(size),
		usage       = usage,
		sharingMode = .EXCLUSIVE,
		pNext       = profile != nil ? &profiles : nil,
	}
	if d.a.CreateBuffer(d.handle, &info, nil, &b.handle) != .SUCCESS do return .Driver_Error
	req: vk.MemoryRequirements
	d.a.GetBufferMemoryRequirements(d.handle, b.handle, &req)
	index := memory_type(d, req.memoryTypeBits, {.HOST_VISIBLE}, {.HOST_COHERENT, .HOST_CACHED})
	if index < 0 do return .Unsupported
	allocate := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = u32(index),
	}
	if d.a.AllocateMemory(d.handle, &allocate, nil, &b.memory) != .SUCCESS do return .Out_Of_Memory
	if d.a.BindBufferMemory(d.handle, b.handle, b.memory, 0) != .SUCCESS do return .Driver_Error
	if d.a.MapMemory(d.handle, b.memory, 0, vk.DeviceSize(vk.WHOLE_SIZE), {}, cast(^rawptr)&b.mapped) != .SUCCESS do return .Driver_Error
	b.size, b.coherent = size, .HOST_COHERENT in d.memory.memoryTypes[index].propertyFlags
	return .None
}

@(private)
free_buffer :: proc(d: ^Device, b: ^Buffer) {
	if b.mapped != nil do d.a.UnmapMemory(d.handle, b.memory)
	if b.handle != 0 do d.a.DestroyBuffer(d.handle, b.handle, nil)
	if b.memory != 0 do d.a.FreeMemory(d.handle, b.memory, nil)
	b^ = {}
}

@(private)
sync_buffer :: proc(d: ^Device, b: ^Buffer, flush: bool) -> Error {
	if b.coherent do return .None
	range := vk.MappedMemoryRange {
		sType  = .MAPPED_MEMORY_RANGE,
		memory = b.memory,
		size   = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	result :=
		flush ? d.a.FlushMappedMemoryRanges(d.handle, 1, &range) : d.a.InvalidateMappedMemoryRanges(d.handle, 1, &range)
	return result == .SUCCESS ? .None : .Driver_Error
}

@(private)
Image :: struct {
	handle:          vk.Image,
	memory:          vk.DeviceMemory,
	view:            vk.ImageView,
	y_view, uv_view: vk.ImageView,
	extent:          vk.Extent2D,
	array_layers:    u32,
	layout:          vk.ImageLayout,
}

@(private)
alloc_image :: proc(
	d: ^Device,
	image: ^Image,
	extent: vk.Extent2D,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	profile: ^vk.VideoProfileInfoKHR,
	flags: vk.ImageCreateFlags = {},
	array_layers: u32 = 1,
) -> (
	err: Error,
) {
	if array_layers == 0 do return .Invalid_Argument
	defer if err != .None do free_image(d, image)
	profiles := vk.VideoProfileListInfoKHR {
		sType        = .VIDEO_PROFILE_LIST_INFO_KHR,
		profileCount = 1,
		pProfiles    = cast([^]vk.VideoProfileInfoKHR)profile,
	}
	families := [2]u32{d.queue_family, d.transfer_family}
	info := vk.ImageCreateInfo {
		sType                 = .IMAGE_CREATE_INFO,
		pNext                 = &profiles,
		flags                 = flags,
		imageType             = .D2,
		format                = format,
		extent                = {extent.width, extent.height, 1},
		mipLevels             = 1,
		arrayLayers           = array_layers,
		samples               = {._1},
		tiling                = .OPTIMAL,
		usage                 = usage,
		sharingMode           = d.queue_family == d.transfer_family ? .EXCLUSIVE : .CONCURRENT,
		queueFamilyIndexCount = d.queue_family == d.transfer_family ? 0 : 2,
		pQueueFamilyIndices   = raw_data(families[:]),
	}
	if d.a.CreateImage(d.handle, &info, nil, &image.handle) != .SUCCESS do return .Unsupported
	req: vk.MemoryRequirements
	d.a.GetImageMemoryRequirements(d.handle, image.handle, &req)
	index := memory_type(d, req.memoryTypeBits, {}, {.DEVICE_LOCAL})
	if index < 0 do return .Unsupported
	allocate := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = u32(index),
	}
	if d.a.AllocateMemory(d.handle, &allocate, nil, &image.memory) != .SUCCESS do return .Out_Of_Memory
	if d.a.BindImageMemory(d.handle, image.handle, image.memory, 0) != .SUCCESS do return .Driver_Error
	view := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = image.handle,
		viewType = array_layers > 1 ? .D2_ARRAY : .D2,
		format = format,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = array_layers},
	}
	if d.a.CreateImageView(d.handle, &view, nil, &image.view) != .SUCCESS do return .Driver_Error
	image.extent = extent
	image.array_layers = array_layers
	return .None
}

@(private)
free_image :: proc(d: ^Device, image: ^Image) {
	if image.y_view != 0 do d.a.DestroyImageView(d.handle, image.y_view, nil)
	if image.uv_view != 0 do d.a.DestroyImageView(d.handle, image.uv_view, nil)
	if image.view != 0 do d.a.DestroyImageView(d.handle, image.view, nil)
	if image.handle != 0 do d.a.DestroyImage(d.handle, image.handle, nil)
	if image.memory != 0 do d.a.FreeMemory(d.handle, image.memory, nil)
	image^ = {}
}

@(private)
Command :: struct {
	pool:   vk.CommandPool,
	handle: vk.CommandBuffer,
	fence:  vk.Fence,
}

@(private)
alloc_command :: proc(d: ^Device, c: ^Command, family: u32) -> (err: Error) {
	defer if err != .None do free_command(d, c)
	pool := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = family,
		flags            = {.RESET_COMMAND_BUFFER},
	}
	if d.a.CreateCommandPool(d.handle, &pool, nil, &c.pool) != .SUCCESS do return .Driver_Error
	allocate := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = c.pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if d.a.AllocateCommandBuffers(d.handle, &allocate, &c.handle) != .SUCCESS do return .Driver_Error
	fence := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	if d.a.CreateFence(d.handle, &fence, nil, &c.fence) != .SUCCESS do return .Driver_Error
	return .None
}

@(private)
free_command :: proc(d: ^Device, c: ^Command) {
	if c.fence != 0 do d.a.DestroyFence(d.handle, c.fence, nil)
	if c.pool != 0 do d.a.DestroyCommandPool(d.handle, c.pool, nil)
	c^ = {}
}

@(private)
begin_command :: proc(d: ^Device, c: ^Command) -> Error {
	if d.a.ResetCommandBuffer(c.handle, {}) != .SUCCESS do return .Driver_Error
	info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	return d.a.BeginCommandBuffer(c.handle, &info) == .SUCCESS ? .None : .Driver_Error
}

@(private)
submit_command :: proc(
	d: ^Device,
	c: ^Command,
	queue: vk.Queue,
	signal: vk.Semaphore = 0,
	wait: vk.Semaphore = 0,
	wait_stage: vk.PipelineStageFlags = {.ALL_COMMANDS},
	timeline_signal: u64 = 0,
	timeline_wait: u64 = 0,
	extra_wait: vk.Semaphore = 0,
	extra_wait_value: u64 = 0,
) -> Error {
	if d.a.EndCommandBuffer(c.handle) != .SUCCESS do return .Driver_Error
	if d.a.ResetFences(d.handle, 1, &c.fence) != .SUCCESS do return .Driver_Error
	signal_handle := signal
	timeline_value := timeline_signal
	waits: [2]vk.Semaphore
	stages: [2]vk.PipelineStageFlags
	values: [2]u64
	wait_count: u32
	if wait != 0 {
		waits[wait_count], stages[wait_count], values[wait_count] = wait, wait_stage, timeline_wait
		wait_count += 1
	}
	if extra_wait != 0 {
		waits[wait_count], stages[wait_count], values[wait_count] =
			extra_wait, wait_stage, extra_wait_value
		wait_count += 1
	}
	timeline := vk.TimelineSemaphoreSubmitInfo {
		sType                     = .TIMELINE_SEMAPHORE_SUBMIT_INFO,
		signalSemaphoreValueCount = signal != 0 ? 1 : 0,
		pSignalSemaphoreValues    = cast([^]u64)&timeline_value,
		waitSemaphoreValueCount   = wait_count,
		pWaitSemaphoreValues      = raw_data(values[:]),
	}
	info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		commandBufferCount   = 1,
		pCommandBuffers      = cast([^]vk.CommandBuffer)&c.handle,
		pNext                = timeline_signal != 0 || timeline_wait != 0 || extra_wait_value != 0 ? &timeline : nil,
		waitSemaphoreCount   = wait_count,
		pWaitSemaphores      = raw_data(waits[:]),
		pWaitDstStageMask    = raw_data(stages[:]),
		signalSemaphoreCount = signal != 0 ? 1 : 0,
		pSignalSemaphores    = cast([^]vk.Semaphore)&signal_handle,
	}
	if d.a.QueueSubmit(queue, 1, &info, c.fence) != .SUCCESS do return .Driver_Error
	return(
		d.a.WaitForFences(d.handle, 1, &c.fence, true, max(u64)) == .SUCCESS ? .None : .Driver_Error \
	)
}

// A semaphore value; a zero semaphore is no point. Binary semaphores ignore
// the value.
@(private)
Timeline_Point :: struct {
	semaphore: vk.Semaphore,
	value:     u64,
}

// Submits without a host wait: the command runs after `wait` and signals
// `signal` when it completes.
@(private)
submit_async :: proc(
	d: ^Device,
	queue: vk.Queue,
	command: vk.CommandBuffer,
	signal: Timeline_Point,
	wait: Timeline_Point = {},
) -> Error {
	if d.a.EndCommandBuffer(command) != .SUCCESS do return .Driver_Error
	points := [2]vk.SemaphoreSubmitInfo {
		{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = signal.semaphore, value = signal.value, stageMask = {.ALL_COMMANDS}},
		{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = wait.semaphore, value = wait.value, stageMask = {.ALL_COMMANDS}},
	}
	commands := [1]vk.CommandBufferSubmitInfo{{sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = command}}
	info := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = wait.semaphore != 0 ? 1 : 0,
		pWaitSemaphoreInfos      = raw_data(points[1:]),
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = raw_data(commands[:]),
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = raw_data(points[:1]),
	}
	return d.a.QueueSubmit2(queue, 1, &info, 0) == .SUCCESS ? .None : .Driver_Error
}

@(private)
wait_timeline :: proc(d: ^Device, point: Timeline_Point) -> Error {
	semaphores, values := [1]vk.Semaphore{point.semaphore}, [1]u64{point.value}
	info := vk.SemaphoreWaitInfo {
		sType          = .SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = raw_data(semaphores[:]),
		pValues        = raw_data(values[:]),
	}
	return d.a.WaitSemaphores(d.handle, &info, max(u64)) == .SUCCESS ? .None : .Driver_Error
}

@(private)
alloc_semaphore :: proc(d: ^Device, semaphore: ^vk.Semaphore, timeline: bool = false) -> Error {
	type_info := vk.SemaphoreTypeCreateInfo {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = .TIMELINE,
	}
	info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = timeline ? &type_info : nil,
	}
	return d.a.CreateSemaphore(d.handle, &info, nil, semaphore) == .SUCCESS ? .None : .Driver_Error
}

@(private)
image_barrier :: proc(
	d: ^Device,
	command: vk.CommandBuffer,
	image: ^Image,
	layout: vk.ImageLayout,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	src_access, dst_access: vk.AccessFlags2,
) {
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage,
		srcAccessMask = src_access,
		dstStageMask = dst_stage,
		dstAccessMask = dst_access,
		oldLayout = image.layout,
		newLayout = layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image.handle,
		subresourceRange = {
			aspectMask = {.COLOR},
			levelCount = 1,
			layerCount = max(1, image.array_layers),
		},
	}
	dependency := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = cast([^]vk.ImageMemoryBarrier2)&barrier,
	}
	d.a.CmdPipelineBarrier2(command, &dependency)
	image.layout = layout
}

@(private)
memory_barrier :: proc(
	d: ^Device,
	command: vk.CommandBuffer,
	src_stage, dst_stage: vk.PipelineStageFlags2,
	src_access, dst_access: vk.AccessFlags2,
) {
	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = src_stage,
		dstStageMask  = dst_stage,
		srcAccessMask = src_access,
		dstAccessMask = dst_access,
	}
	info := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = cast([^]vk.MemoryBarrier2)&barrier,
	}
	d.a.CmdPipelineBarrier2(command, &info)
}

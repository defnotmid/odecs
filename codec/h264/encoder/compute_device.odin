package h264_encoder

import "core:dynlib"
import vk "vendor:vulkan"

// Direct Vulkan compute, using Slang physical-storage pointers. No video engine,
// descriptor pools, staging buffers, image copies, or SDL transfer abstraction.
// Device creation/loading is serialized by the application. A device and its
// queue have one submitting owner; multiple contexts may use it sequentially.
Compute_Device :: struct {
	error_detail:   string,
	loader:         dynlib.Library,
	instance:       vk.Instance,
	physical:       vk.PhysicalDevice,
	handle:         vk.Device,
	api:            vk.Device_VTable,
	queue:          vk.Queue,
	queue_family:   u32,
	properties:     vk.PhysicalDeviceProperties,
	memory:         vk.PhysicalDeviceMemoryProperties,
	timestamp_bits: u32,
}

init_compute_device :: proc(d: ^Compute_Device, physical_index: int = -1) -> (err: Error) {
	if d.instance != nil do return .Busy
	path: string
	when ODIN_OS == .Linux {path = "libvulkan.so.1"} else when ODIN_OS == .Windows {path = "vulkan-1.dll"} else {return .Unsupported_Platform}
	loader, loaded := dynlib.load_library(path)
	if !loaded do return compute_device_error(d, .Vulkan_Unavailable, "Vulkan loader is unavailable")
	d.loader = loader
	defer if err != .None {
		detail := d.error_detail
		destroy_compute_device(d)
		d.error_detail = detail
	}
	address, found := dynlib.symbol_address(loader, "vkGetInstanceProcAddr")
	if !found do return compute_device_error(d, .Vulkan_Unavailable, "Vulkan loader lacks vkGetInstanceProcAddr")
	vk.load_proc_addresses_global(address)
	app := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "oicu compute",
		apiVersion       = vk.API_VERSION_1_2,
	}
	info := vk.InstanceCreateInfo {
		sType            = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &app,
	}
	if vk.CreateInstance(&info, nil, &d.instance) != .SUCCESS do return compute_device_error(d, .Driver_Error, "Vulkan instance creation failed")
	vk.load_proc_addresses_instance(d.instance)
	count: u32
	if vk.EnumeratePhysicalDevices(d.instance, &count, nil) != .SUCCESS || count == 0 do return compute_device_error(d, .Vulkan_Unavailable, "no Vulkan physical devices")
	devices := make([]vk.PhysicalDevice, int(count)); defer delete(devices)
	if vk.EnumeratePhysicalDevices(d.instance, &count, raw_data(devices)) != .SUCCESS do return compute_device_error(d, .Driver_Error, "Vulkan device enumeration failed")
	best := -1
	for physical, index in devices {
		if physical_index >= 0 && physical_index != index do continue
		features12 := vk.PhysicalDeviceVulkan12Features {
			sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		}
		features := vk.PhysicalDeviceFeatures2 {
			sType = .PHYSICAL_DEVICE_FEATURES_2,
			pNext = &features12,
		}
		vk.GetPhysicalDeviceFeatures2(physical, &features)
		props: vk.PhysicalDeviceProperties
		vk.GetPhysicalDeviceProperties(physical, &props)
		if props.apiVersion < vk.API_VERSION_1_2 || !features12.bufferDeviceAddress || !features12.storageBuffer8BitAccess || !features12.shaderInt8 || !features.features.shaderInt64 do continue
		families: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(physical, &families, nil)
		queues := make([]vk.QueueFamilyProperties, int(families)); defer delete(queues)
		vk.GetPhysicalDeviceQueueFamilyProperties(physical, &families, raw_data(queues))
		for queue, family in queues {
			if .COMPUTE not_in queue.queueFlags || queue.queueCount == 0 || queue.timestampValidBits == 0 do continue
			score := props.deviceType == .DISCRETE_GPU ? 2 : 1
			if score > best {
				best = score
				d.physical, d.properties, d.queue_family, d.timestamp_bits =
					physical, props, u32(family), queue.timestampValidBits
			}
			break
		}
	}
	if d.physical == nil do return compute_device_error(d, .Unsupported_Device, "GPU requires Vulkan 1.2, buffer addresses, 8-bit storage/arithmetic and timestamps")
	priority: f32 = 1
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = d.queue_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	features12 := vk.PhysicalDeviceVulkan12Features {
		sType                   = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		bufferDeviceAddress     = true,
		storageBuffer8BitAccess = true,
		shaderInt8              = true,
	}
	features := vk.PhysicalDeviceFeatures {
		shaderInt64 = true,
	}
	device_info := vk.DeviceCreateInfo {
		sType                = .DEVICE_CREATE_INFO,
		pNext                = &features12,
		queueCreateInfoCount = 1,
		pQueueCreateInfos    = &queue_info,
		pEnabledFeatures     = &features,
	}
	if vk.CreateDevice(d.physical, &device_info, nil, &d.handle) != .SUCCESS do return compute_device_error(d, .Driver_Error, "Vulkan compute device creation failed")
	vk.load_proc_addresses_device_vtable(d.handle, &d.api)
	d.api.GetDeviceQueue(d.handle, d.queue_family, 0, &d.queue)
	vk.GetPhysicalDeviceMemoryProperties(d.physical, &d.memory)
	return .None
}

destroy_compute_device :: proc(d: ^Compute_Device) {
	// All attached contexts must be destroyed first; each retires its own fence.
	if d.handle != nil do d.api.DestroyDevice(d.handle, nil)
	if d.instance != nil do vk.DestroyInstance(d.instance, nil)
	if d.loader != nil do dynlib.unload_library(d.loader)
	d^ = {}
}

Compute_Memory :: enum {
	Host_Cached, // one shared allocation, cached CPU access while reconstruction is CPU-owned
	Device_Local, // mapped VRAM, for stages where most accesses originate on the GPU
}
Compute_Allocation :: struct {
	buffer:     vk.Buffer,
	memory:     vk.DeviceMemory,
	mapped:     [^]u8,
	address:    vk.DeviceAddress,
	size:       int,
	properties: vk.MemoryPropertyFlags,
}

alloc_compute_memory :: proc(
	d: ^Compute_Device,
	a: ^Compute_Allocation,
	size: int,
	placement: Compute_Memory,
) -> (
	err: Error,
) {
	if d == nil || d.handle == nil || size <= 0 do return .Invalid_Input
	defer if err != .None do free_compute_memory(d, a)
	info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(size),
		usage       = {.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS},
		sharingMode = .EXCLUSIVE,
	}
	if d.api.CreateBuffer(d.handle, &info, nil, &a.buffer) != .SUCCESS do return compute_device_error(d, .Allocation_Failed, "GPU buffer allocation failed")
	requirements: vk.MemoryRequirements
	d.api.GetBufferMemoryRequirements(d.handle, a.buffer, &requirements)
	wanted: vk.MemoryPropertyFlags = {.HOST_VISIBLE, .HOST_COHERENT}
	wanted +=
		placement == .Device_Local ? vk.MemoryPropertyFlags{.DEVICE_LOCAL} : vk.MemoryPropertyFlags{.HOST_CACHED}
	index := -1
	for i in 0 ..< int(d.memory.memoryTypeCount) {
		if requirements.memoryTypeBits & (1 << u32(i)) != 0 &&
		   d.memory.memoryTypes[i].propertyFlags & wanted == wanted {
			index = i
			a.properties = d.memory.memoryTypes[i].propertyFlags
			break
		}
	}
	if index < 0 do return .Memory_Placement_Unavailable
	flags := vk.MemoryAllocateFlagsInfo {
		sType = .MEMORY_ALLOCATE_FLAGS_INFO,
		flags = {.DEVICE_ADDRESS},
	}
	allocation := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		pNext           = &flags,
		allocationSize  = requirements.size,
		memoryTypeIndex = u32(index),
	}
	if d.api.AllocateMemory(d.handle, &allocation, nil, &a.memory) != .SUCCESS do return compute_device_error(d, .Allocation_Failed, "GPU memory allocation failed")
	if d.api.BindBufferMemory(d.handle, a.buffer, a.memory, 0) != .SUCCESS do return compute_device_error(d, .Driver_Error, "GPU memory binding failed")
	if d.api.MapMemory(d.handle, a.memory, 0, requirements.size, {}, cast(^rawptr)&a.mapped) != .SUCCESS do return compute_device_error(d, .Driver_Error, "GPU direct mapping failed")
	address_info := vk.BufferDeviceAddressInfo {
		sType  = .BUFFER_DEVICE_ADDRESS_INFO,
		buffer = a.buffer,
	}
	a.address = d.api.GetBufferDeviceAddress(d.handle, &address_info)
	if a.address == 0 do return compute_device_error(d, .Unsupported_Device, "GPU buffer device address is unavailable")
	a.size = size
	return .None
}

free_compute_memory :: proc(d: ^Compute_Device, a: ^Compute_Allocation) {
	if a.mapped != nil do d.api.UnmapMemory(d.handle, a.memory)
	if a.buffer != 0 do d.api.DestroyBuffer(d.handle, a.buffer, nil)
	if a.memory != 0 do d.api.FreeMemory(d.handle, a.memory, nil)
	a^ = {}
}

@(private)
compute_device_error :: proc(d: ^Compute_Device, err: Error, detail: string) -> Error {
	d.error_detail = detail
	return err
}

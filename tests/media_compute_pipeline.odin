// External public-API gate: resident decode -> sampled-plane compute -> generic
// transfer image -> device encode. No source pixels are downloaded or uploaded.
package main

import media "../media"
import native "../media/native"
import vulkan "../media/vulkan"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import vk "vendor:vulkan"

Sink :: struct {
	stream, pixels: [dynamic]u8,
	frames:         int,
}
Producer :: struct {
	descriptor:                      vulkan.Context_Descriptor,
	buffer:                          vk.Buffer,
	buffer_memory:                   vk.DeviceMemory,
	image_memory:                    vk.DeviceMemory,
	surface:                         vulkan.Surface,
	pool:                            vk.CommandPool,
	command:                         vk.CommandBuffer,
	fence:                           vk.Fence,
	ready:                           vk.Semaphore,
	ready_value:                     u64,
	set_layout:                      vk.DescriptorSetLayout,
	descriptor_pool:                 vk.DescriptorPool,
	set:                             vk.DescriptorSet,
	layout:                          vk.PipelineLayout,
	pipeline:                        vk.Pipeline,
	width, height, depth, row_pitch: int,
	produced:                        bool,
}
Pipeline :: struct {
	shared:                   ^vulkan.Context,
	producer:                 ^Producer,
	encoder:                  ^media.Session,
	sink:                     ^Sink,
	left, top, width, height: int,
	device:                   bool,
}
fail :: proc(message: string) {fmt.eprintln(message); os.exit(1)}
check :: proc(err: media.Error) {if err != .None {fmt.eprintln(err); os.exit(1)}}
check_gpu :: proc(err: vulkan.Error) {if err != .None {fmt.eprintln(err); os.exit(1)}}
check_vk :: proc(result: vk.Result) {if result != .SUCCESS {fmt.eprintln(result); os.exit(1)}}
integer :: proc(index: int) -> int {v, ok := strconv.parse_int(os.args[index]); if !ok do fail("invalid integer")
	return v}
packet_output :: proc(packet: media.Packet, user: rawptr) {append(
		&((^Sink)(user)).stream,
		..packet.data,
	)}
pixel_output :: proc(frame: media.Video_Frame, user: rawptr) {
	s := (^Sink)(user)
	check(media.validate_frame(frame))
	for plane, i in frame.planes {
		w, h := i == 0 ? frame.width : frame.width / 2, i == 0 ? frame.height : frame.height / 2
		for row in 0 ..< h {
			data := plane.data[row * plane.stride:]
			if frame.bit_depth > 8 ||
			   frame.storage_bits ==
				   8 {append(&s.pixels, ..data[:w * (frame.bit_depth > 8 ? 2 : 1)])} else {for col in 0 ..< w do append(&s.pixels, data[col * 2])}
		}
	}
	s.frames += 1
}

allocate_device_memory :: proc(
	d: vulkan.Context_Descriptor,
	requirements: vk.MemoryRequirements,
) -> vk.DeviceMemory {
	properties: vk.PhysicalDeviceMemoryProperties
	d.get_memory_properties(d.physical_device, &properties)
	index: i32 = -1
	for property, i in properties.memoryTypes[:properties.memoryTypeCount] {
		if requirements.memoryTypeBits & (1 << u32(i)) == 0 || .DEVICE_LOCAL not_in property.propertyFlags do continue
		index = i32(i)
		break
	}
	if index < 0 do fail("no compatible device-local producer memory")
	info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = requirements.size,
		memoryTypeIndex = u32(index),
	}
	result: vk.DeviceMemory
	check_vk(d.device_api.AllocateMemory(d.device, &info, nil, &result))
	return result
}

init_producer :: proc(
	p: ^Producer,
	descriptor: vulkan.Context_Descriptor,
	width, height, depth: int,
) {
	if descriptor.device == nil || descriptor.device_api == nil || descriptor.get_memory_properties == nil || descriptor.compute_queue == nil do fail("incomplete public Context descriptor")
	p.descriptor, p.width, p.height, p.depth = descriptor, width, height, depth
	bytes := depth == 10 ? 2 : 1
	p.row_pitch = (width * bytes + 3) &~ 3
	d, a := descriptor.device, descriptor.device_api
	buffer := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(p.row_pitch * height * 3 / 2),
		usage       = {.STORAGE_BUFFER, .TRANSFER_SRC},
		sharingMode = .EXCLUSIVE,
	}
	check_vk(a.CreateBuffer(d, &buffer, nil, &p.buffer))
	requirements: vk.MemoryRequirements
	a.GetBufferMemoryRequirements(d, p.buffer, &requirements)
	p.buffer_memory = allocate_device_memory(descriptor, requirements)
	check_vk(a.BindBufferMemory(d, p.buffer, p.buffer_memory, 0))
	format :=
		depth == 10 ? vk.Format.G10X6_B10X6R10X6_2PLANE_420_UNORM_3PACK16 : vk.Format.G8_B8R8_2PLANE_420_UNORM
	// A caller-owned generic transfer image: no video profile pNext or video usage.
	image := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = format,
		extent        = {u32(width), u32(height), 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .OPTIMAL,
		usage         = {.TRANSFER_DST, .TRANSFER_SRC},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .UNDEFINED,
	}
	check_vk(a.CreateImage(d, &image, nil, &p.surface.image))
	a.GetImageMemoryRequirements(d, p.surface.image, &requirements)
	p.image_memory = allocate_device_memory(descriptor, requirements)
	check_vk(a.BindImageMemory(d, p.surface.image, p.image_memory, 0))
	p.surface = vulkan.Surface {
		device                = d,
		physical_device       = descriptor.physical_device,
		device_api            = a,
		get_memory_properties = descriptor.get_memory_properties,
		image                 = p.surface.image,
		format                = format,
		usage                 = image.usage,
		layout                = .GENERAL,
		queue_family          = descriptor.compute_queue_family,
		compute_queue_family  = descriptor.compute_queue_family,
		compute_queue         = descriptor.compute_queue,
		width                 = width,
		height                = height,
		bit_depth             = depth,
	}
	pool := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = descriptor.compute_queue_family,
	}
	check_vk(a.CreateCommandPool(d, &pool, nil, &p.pool))
	commands := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = p.pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	check_vk(a.AllocateCommandBuffers(d, &commands, &p.command))
	fence := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	check_vk(a.CreateFence(d, &fence, nil, &p.fence))
	timeline := vk.SemaphoreTypeCreateInfo {
		sType         = .SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = .TIMELINE,
	}
	semaphore := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		pNext = &timeline,
	}
	check_vk(a.CreateSemaphore(d, &semaphore, nil, &p.ready))
	bindings := [3]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		},
		{
			binding = 1,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		},
		{
			binding = 2,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1,
			stageFlags = {.COMPUTE},
		},
	}
	set_layout := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 3,
		pBindings    = raw_data(bindings[:]),
	}
	check_vk(a.CreateDescriptorSetLayout(d, &set_layout, nil, &p.set_layout))
	sizes := [2]vk.DescriptorPoolSize {
		{type = .SAMPLED_IMAGE, descriptorCount = 2},
		{type = .STORAGE_BUFFER, descriptorCount = 1},
	}
	descriptor_pool := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		maxSets       = 1,
		poolSizeCount = 2,
		pPoolSizes    = raw_data(sizes[:]),
	}
	check_vk(a.CreateDescriptorPool(d, &descriptor_pool, nil, &p.descriptor_pool))
	sets := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = p.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = cast([^]vk.DescriptorSetLayout)&p.set_layout,
	}
	check_vk(a.AllocateDescriptorSets(d, &sets, &p.set))
	push := vk.PushConstantRange {
		stageFlags = {.COMPUTE},
		size       = 24,
	}
	layout := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = cast([^]vk.DescriptorSetLayout)&p.set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push,
	}
	check_vk(a.CreatePipelineLayout(d, &layout, nil, &p.layout))
	code :: #load("../shaders/video_pack.comp.spv")
	words := make([]u32, len(code) / 4); defer delete(words)
	mem.copy(raw_data(words), raw_data(code), len(code))
	shader := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(words),
	}
	module: vk.ShaderModule
	check_vk(
		a.CreateShaderModule(d, &shader, nil, &module),
	); defer a.DestroyShaderModule(d, module, nil)
	pipeline := vk.ComputePipelineCreateInfo {
		sType = .COMPUTE_PIPELINE_CREATE_INFO,
		layout = p.layout,
		stage = {
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.COMPUTE},
			module = module,
			pName = "main",
		},
	}
	check_vk(a.CreateComputePipelines(d, 0, 1, &pipeline, nil, &p.pipeline))
}

destroy_producer :: proc(p: ^Producer) {
	d, a := p.descriptor.device, p.descriptor.device_api
	if d == nil do return
	check_vk(a.DeviceWaitIdle(d))
	if p.pipeline != 0 do a.DestroyPipeline(d, p.pipeline, nil)
	if p.layout != 0 do a.DestroyPipelineLayout(d, p.layout, nil)
	if p.descriptor_pool != 0 do a.DestroyDescriptorPool(d, p.descriptor_pool, nil)
	if p.set_layout != 0 do a.DestroyDescriptorSetLayout(d, p.set_layout, nil)
	if p.fence != 0 do a.DestroyFence(d, p.fence, nil)
	if p.ready != 0 do a.DestroySemaphore(d, p.ready, nil)
	if p.pool != 0 do a.DestroyCommandPool(d, p.pool, nil)
	if p.buffer != 0 do a.DestroyBuffer(d, p.buffer, nil)
	if p.buffer_memory != 0 do a.FreeMemory(d, p.buffer_memory, nil)
	if p.surface.image != 0 do a.DestroyImage(d, p.surface.image, nil)
	if p.image_memory != 0 do a.FreeMemory(d, p.image_memory, nil)
	p^ = {}
}

produce :: proc(p: ^Producer, source: vulkan.Surface, crop_x, crop_y: int) {
	if source.device != p.descriptor.device || source.bit_depth != p.depth || source.y_view == 0 || source.uv_view == 0 || source.ready_semaphore == 0 || source.ready_value == 0 do fail("invalid sampled source surface")
	d, a := p.descriptor.device, p.descriptor.device_api
	images := [2]vk.DescriptorImageInfo {
		{imageView = source.y_view, imageLayout = source.layout},
		{imageView = source.uv_view, imageLayout = source.layout},
	}
	buffer := vk.DescriptorBufferInfo {
		buffer = p.buffer,
		range  = vk.DeviceSize(p.row_pitch * p.height * 3 / 2),
	}
	writes := [3]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = p.set,
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &images[0],
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = p.set,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &images[1],
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = p.set,
			dstBinding = 2,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &buffer,
		},
	}
	a.UpdateDescriptorSets(d, 3, raw_data(writes[:]), 0, nil)
	check_vk(a.ResetFences(d, 1, &p.fence))
	check_vk(a.ResetCommandBuffer(p.command, {}))
	begin := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	check_vk(a.BeginCommandBuffer(p.command, &begin))
	before_compute := vk.BufferMemoryBarrier2 {
		sType               = .BUFFER_MEMORY_BARRIER_2,
		dstStageMask        = {.COMPUTE_SHADER},
		dstAccessMask       = {.SHADER_WRITE},
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = p.buffer,
		size                = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	if p.produced {before_compute.srcStageMask, before_compute.srcAccessMask = {.COPY}, {.TRANSFER_READ}}
	before_dependency := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers    = &before_compute,
	}
	a.CmdPipelineBarrier2(p.command, &before_dependency)
	a.CmdBindPipeline(p.command, .COMPUTE, p.pipeline)
	a.CmdBindDescriptorSets(p.command, .COMPUTE, p.layout, 0, 1, &p.set, 0, nil)
	params := [6]u32 {
		u32(p.width),
		u32(p.height),
		u32(p.depth),
		u32(crop_x),
		u32(crop_y),
		u32(p.row_pitch),
	}
	a.CmdPushConstants(p.command, p.layout, {.COMPUTE}, 0, size_of(params), raw_data(params[:]))
	a.CmdDispatch(p.command, u32((p.row_pitch / 4 + 15) / 16), u32((p.height + 15) / 16), 1)
	buffer_barrier := vk.BufferMemoryBarrier2 {
		sType               = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask        = {.COMPUTE_SHADER},
		srcAccessMask       = {.SHADER_WRITE},
		dstStageMask        = {.COPY},
		dstAccessMask       = {.TRANSFER_READ},
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = p.buffer,
		size                = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	image_barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {.ALL_COMMANDS},
		srcAccessMask = {.MEMORY_READ},
		dstStageMask = {.COPY},
		dstAccessMask = {.TRANSFER_WRITE},
		oldLayout = p.produced ? .GENERAL : .UNDEFINED,
		newLayout = .TRANSFER_DST_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = p.surface.image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	dependency := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers    = &buffer_barrier,
		imageMemoryBarrierCount  = 1,
		pImageMemoryBarriers     = &image_barrier,
	}
	a.CmdPipelineBarrier2(p.command, &dependency)
	bytes := p.depth == 10 ? 2 : 1
	copies := [2]vk.BufferImageCopy {
		{
			bufferRowLength = u32(p.row_pitch / bytes),
			imageSubresource = {aspectMask = {.PLANE_0}, layerCount = 1},
			imageExtent = {u32(p.width), u32(p.height), 1},
		},
		{
			bufferOffset = vk.DeviceSize(p.row_pitch * p.height),
			bufferRowLength = u32(p.row_pitch / (bytes * 2)),
			imageSubresource = {aspectMask = {.PLANE_1}, layerCount = 1},
			imageExtent = {u32(p.width / 2), u32(p.height / 2), 1},
		},
	}
	a.CmdCopyBufferToImage(
		p.command,
		p.buffer,
		p.surface.image,
		.TRANSFER_DST_OPTIMAL,
		2,
		raw_data(copies[:]),
	)
	image_barrier.srcStageMask, image_barrier.srcAccessMask = {.COPY}, {.TRANSFER_WRITE}
	image_barrier.dstStageMask, image_barrier.dstAccessMask = {.ALL_COMMANDS}, {.MEMORY_READ}
	image_barrier.oldLayout, image_barrier.newLayout = .TRANSFER_DST_OPTIMAL, .GENERAL
	dependency.bufferMemoryBarrierCount, dependency.pBufferMemoryBarriers = 0, nil
	a.CmdPipelineBarrier2(p.command, &dependency)
	check_vk(a.EndCommandBuffer(p.command))
	wait := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = source.ready_semaphore,
		value     = source.ready_value,
		stageMask = {.COMPUTE_SHADER},
	}
	command := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = p.command,
	}
	p.ready_value += 1
	signal := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = p.ready,
		value     = p.ready_value,
		stageMask = {.ALL_COMMANDS},
	}
	submit := vk.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = 1,
		pWaitSemaphoreInfos      = &wait,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &command,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal,
	}
	// The test is the sole submitting owner; all producer/session queue use is serial.
	check_vk(a.QueueSubmit2(p.descriptor.compute_queue, 1, &submit, p.fence))
	if !p.produced {
		// First picture explicitly completes the producer and tests readiness 0/0.
		check_vk(a.WaitForFences(d, 1, &p.fence, true, max(u64)))
		p.surface.ready_semaphore, p.surface.ready_value = 0, 0
	} else {
		// Subsequent calls pass pending producer work directly to common encode.
		p.surface.ready_semaphore, p.surface.ready_value = p.ready, p.ready_value
	}
	p.produced = true
}

transcode :: proc(decoded: media.Video_Frame, user: rawptr) {
	p := (^Pipeline)(user)
	frame := decoded
	if frame.width < p.left + p.width || frame.height < p.top + p.height do fail("source crop out of bounds")
	if p.device {
		if frame.storage != .Device || len(frame.planes[0].data) != 0 do fail("hardware decode returned host pixels")
		source := vulkan.surface(frame)
		if source == nil do fail("missing public decoded surface")
		if p.producer.pipeline == 0 do init_producer(p.producer, vulkan.context_descriptor(p.shared), p.width, p.height, frame.bit_depth)
		produce(p.producer, source^, frame.crop_x + p.left, frame.crop_y + p.top)
		frame.surface, frame.crop_x, frame.crop_y = &p.producer.surface, 0, 0
	} else {
		if frame.storage != .Host do fail("native decode did not return host pixels")
		for &plane, i in frame.planes {
			left, top := i == 0 ? p.left : p.left / 2, i == 0 ? p.top : p.top / 2
			plane.data = plane.data[top * plane.stride + left * (frame.storage_bits / 8):]
		}
	}
	frame.width, frame.height = p.width, p.height
	check(media.encode_video(p.encoder, frame, {packet = packet_output, user = p.sink}))
	if p.device do check_vk(p.producer.descriptor.device_api.WaitForFences(p.producer.descriptor.device, 1, &p.producer.fence, true, max(u64)))
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
	if len(os.args) != 7 && len(os.args) != 11 do fail("usage: media_compute_pipeline input.264|265 h264|h265 width height depth prefix [left top output_width output_height]")
	codec: media.Codec = .H265
	if os.args[2] == "h264" {codec = .H264} else if os.args[2] != "h265" do fail("invalid codec")
	w, h, depth := integer(3), integer(4), integer(5)
	left, top, ow, oh := 0, 0, w, h
	if len(os.args) == 11 {left, top, ow, oh = integer(7), integer(8), integer(9), integer(10)}
	if left < 0 || top < 0 || left % 2 != 0 || top % 2 != 0 || ow < 16 || oh < 16 || ow % 2 != 0 || oh % 2 != 0 || ow > w || oh > h || left > w - ow || top > h - oh do fail("invalid visible crop")
	input, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil do fail("cannot read source")
	defer delete(input)
	gc := codec == .H264 ? vulkan.Codec.H264 : vulkan.Codec.H265
	requests := []vulkan.Request {
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
	shared: vulkan.Context
	check_gpu(vulkan.init_context(&shared, {requests = requests, device_index = -1}))
	defer check_gpu(vulkan.destroy_context(&shared))
	producer: Producer
	defer destroy_producer(&producer)
	providers := []media.Provider{vulkan.provider(&shared)}
	config := media.default_config(codec, .Encode)
	config.width, config.height, config.bit_depth, config.preference =
		ow, oh, depth, .Require_Hardware
	device_encoder, host_encoder, decoder: media.Session
	check(media.open(&device_encoder, config, providers)); defer media.close(&device_encoder)
	check(media.open(&host_encoder, config, providers)); defer media.close(&host_encoder)
	config.operation, config.width, config.height, config.output_storage = .Decode, w, h, .Device
	check(media.open(&decoder, config, providers)); defer media.close(&decoder)
	if vulkan.destroy_context(&shared) != .Busy do fail("live sessions did not retain the Context")
	actual, expected := Sink{}, Sink{}
	defer {delete(actual.stream); delete(actual.pixels); delete(expected.stream)
		delete(expected.pixels)}
	pipeline := Pipeline {
		shared   = &shared,
		producer = &producer,
		encoder  = &device_encoder,
		sink     = &actual,
		left     = left,
		top      = top,
		width    = ow,
		height   = oh,
		device   = true,
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
	if vulkan.context_descriptor(&shared).device == nil do fail("closing borrowed sessions destroyed their shared device")
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
	if actual.frames != expected.frames do fail("compute/host frame counts differ")
	if !slice.equal(actual.stream[:], expected.stream[:]) do fail("compute producer and host upload produced different bitstreams")
	frames := actual.frames
	actual.frames, expected.frames = 0, 0
	config.width, config.height = ow, oh
	decode_pixels(actual.stream[:], config, &actual)
	decode_pixels(expected.stream[:], config, &expected)
	if actual.frames != frames || expected.frames != frames || !slice.equal(actual.pixels[:], expected.pixels[:]) do fail("compute/host transcoded pixels differ")
	ext := codec == .H264 ? "264" : "265"
	if os.write_entire_file(fmt.tprintf("%s.%s", os.args[6], ext), actual.stream[:]) != nil do fail("cannot save bitstream")
	if os.write_entire_file(fmt.tprintf("%s.yuv", os.args[6]), actual.pixels[:]) != nil do fail("cannot save pixels")
	destroy_producer(&producer)
	check_gpu(vulkan.destroy_context(&shared))
	fmt.printfln(
		"shared_compute_pipeline frames=%d size=%dx%d depth=%d crop=%d,%d bitstream/pixels_exact=true resident_host_pixel_transfers=0 readiness_completed=1 readiness_timeline=%d",
		frames,
		ow,
		oh,
		depth,
		left,
		top,
		frames - 1,
	)
}

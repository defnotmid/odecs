// External consumer gate: only the public common API and exported Vulkan
// surface/dispatch are used. Runs a real Slang shader, then saves visible YUV.
package main

import media "../codec/media"
import vulkan "../codec/media/vulkan"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import vk "vendor:vulkan"

Consumer :: struct {
	device:                       vk.Device,
	api:                          ^vk.Device_VTable,
	queue:                        vk.Queue,
	buffer:                       vk.Buffer,
	memory:                       vk.DeviceMemory,
	mapped:                       [^]u32,
	coherent:                     bool,
	pool:                         vk.CommandPool,
	command:                      vk.CommandBuffer,
	fence:                        vk.Fence,
	set_layout:                   vk.DescriptorSetLayout,
	descriptor_pool:              vk.DescriptorPool,
	set:                          vk.DescriptorSet,
	layout:                       vk.PipelineLayout,
	pipeline:                     vk.Pipeline,
	width, height, depth, frames: int,
	pixels:                       [dynamic]u8,
}
fail :: proc(message: string) {fmt.eprintln(message); os.exit(1)}
check_vk :: proc(result: vk.Result) {if result != .SUCCESS {fmt.eprintln(result); os.exit(1)}}
check :: proc(err: media.Error) {if err != .None {fmt.eprintln(err); os.exit(1)}}
integer :: proc(s: string) -> int {v, ok := strconv.parse_int(s); if !ok do fail("invalid integer")
	return v}

init_consumer :: proc(c: ^Consumer, frame: media.Video_Frame) {
	s := vulkan.surface(frame)
	if s == nil || s.device_api == nil || s.get_memory_properties == nil do fail("incomplete public surface")
	c.device, c.api, c.queue = s.device, s.device_api, s.compute_queue
	c.width, c.height, c.depth = frame.width, frame.height, frame.bit_depth
	a := c.api
	buffer := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(frame.width * frame.height * 6),
		usage       = {.STORAGE_BUFFER},
		sharingMode = .EXCLUSIVE,
	}
	check_vk(a.CreateBuffer(c.device, &buffer, nil, &c.buffer))
	req: vk.MemoryRequirements
	a.GetBufferMemoryRequirements(c.device, c.buffer, &req)
	properties: vk.PhysicalDeviceMemoryProperties
	s.get_memory_properties(s.physical_device, &properties)
	index: i32 = -1
	for p, i in properties.memoryTypes[:properties.memoryTypeCount] {
		if req.memoryTypeBits & (1 << u32(i)) == 0 || .HOST_VISIBLE not_in p.propertyFlags do continue
		if index < 0 ||
		   .HOST_COHERENT in
			   p.propertyFlags {index = i32(i); c.coherent = .HOST_COHERENT in p.propertyFlags}
		if c.coherent do break
	}
	if index < 0 do fail("no host-visible output memory")
	allocate := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = u32(index),
	}
	check_vk(a.AllocateMemory(c.device, &allocate, nil, &c.memory))
	check_vk(a.BindBufferMemory(c.device, c.buffer, c.memory, 0))
	check_vk(
		a.MapMemory(
			c.device,
			c.memory,
			0,
			vk.DeviceSize(vk.WHOLE_SIZE),
			{},
			cast(^rawptr)&c.mapped,
		),
	)
	pool := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = s.compute_queue_family,
	}
	check_vk(a.CreateCommandPool(c.device, &pool, nil, &c.pool))
	commands := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = c.pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	check_vk(a.AllocateCommandBuffers(c.device, &commands, &c.command))
	fence := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	check_vk(a.CreateFence(c.device, &fence, nil, &c.fence))
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
	check_vk(a.CreateDescriptorSetLayout(c.device, &set_layout, nil, &c.set_layout))
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
	check_vk(a.CreateDescriptorPool(c.device, &descriptor_pool, nil, &c.descriptor_pool))
	sets := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = c.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = cast([^]vk.DescriptorSetLayout)&c.set_layout,
	}
	check_vk(a.AllocateDescriptorSets(c.device, &sets, &c.set))
	push := vk.PushConstantRange {
		stageFlags = {.COMPUTE},
		size       = 20,
	}
	layout := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = cast([^]vk.DescriptorSetLayout)&c.set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push,
	}
	check_vk(a.CreatePipelineLayout(c.device, &layout, nil, &c.layout))
	code :: #load("../shaders/video_readback.comp.spv")
	words := make([]u32, len(code) / 4); defer delete(words)
	mem.copy(raw_data(words), raw_data(code), len(code))
	shader := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = raw_data(words),
	}
	module: vk.ShaderModule
	check_vk(
		a.CreateShaderModule(c.device, &shader, nil, &module),
	); defer a.DestroyShaderModule(c.device, module, nil)
	pipeline := vk.ComputePipelineCreateInfo {
		sType = .COMPUTE_PIPELINE_CREATE_INFO,
		layout = c.layout,
		stage = {
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.COMPUTE},
			module = module,
			pName = "main",
		},
	}
	check_vk(a.CreateComputePipelines(c.device, 0, 1, &pipeline, nil, &c.pipeline))
}

destroy_consumer :: proc(c: ^Consumer) {
	if c.device != nil {
		a := c.api
		a.DeviceWaitIdle(c.device)
		if c.pipeline != 0 do a.DestroyPipeline(c.device, c.pipeline, nil)
		if c.layout != 0 do a.DestroyPipelineLayout(c.device, c.layout, nil)
		if c.descriptor_pool != 0 do a.DestroyDescriptorPool(c.device, c.descriptor_pool, nil)
		if c.set_layout != 0 do a.DestroyDescriptorSetLayout(c.device, c.set_layout, nil)
		if c.fence != 0 do a.DestroyFence(c.device, c.fence, nil)
		if c.pool != 0 do a.DestroyCommandPool(c.device, c.pool, nil)
		if c.mapped != nil do a.UnmapMemory(c.device, c.memory)
		if c.buffer != 0 do a.DestroyBuffer(c.device, c.buffer, nil)
		if c.memory != 0 do a.FreeMemory(c.device, c.memory, nil)
	}
	delete(c.pixels)
}

receive :: proc(frame: media.Video_Frame, user: rawptr) {
	c := (^Consumer)(user)
	if frame.storage != .Device || len(frame.planes[0].data) != 0 do fail("expected resident decode output")
	s := vulkan.surface(frame)
	if s == nil || s.y_view == 0 || s.uv_view == 0 || s.ready_value == 0 do fail("invalid Vulkan surface")
	if c.pipeline == 0 do init_consumer(c, frame)
	if c.device != s.device || c.width != frame.width || c.height != frame.height || c.depth != frame.bit_depth do fail("surface contract changed")
	a := c.api
	images := [2]vk.DescriptorImageInfo {
		{imageView = s.y_view, imageLayout = s.layout},
		{imageView = s.uv_view, imageLayout = s.layout},
	}
	buffer := vk.DescriptorBufferInfo {
		buffer = c.buffer,
		range  = vk.DeviceSize(c.width * c.height * 6),
	}
	writes := [3]vk.WriteDescriptorSet {
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = c.set,
			dstBinding = 0,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &images[0],
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = c.set,
			dstBinding = 1,
			descriptorCount = 1,
			descriptorType = .SAMPLED_IMAGE,
			pImageInfo = &images[1],
		},
		{
			sType = .WRITE_DESCRIPTOR_SET,
			dstSet = c.set,
			dstBinding = 2,
			descriptorCount = 1,
			descriptorType = .STORAGE_BUFFER,
			pBufferInfo = &buffer,
		},
	}
	a.UpdateDescriptorSets(c.device, 3, raw_data(writes[:]), 0, nil)
	check_vk(a.ResetFences(c.device, 1, &c.fence))
	check_vk(a.ResetCommandBuffer(c.command, {}))
	begin := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	check_vk(a.BeginCommandBuffer(c.command, &begin))
	a.CmdBindPipeline(c.command, .COMPUTE, c.pipeline)
	a.CmdBindDescriptorSets(c.command, .COMPUTE, c.layout, 0, 1, &c.set, 0, nil)
	params := [5]u32 {
		u32(frame.width),
		u32(frame.height),
		u32(frame.bit_depth),
		u32(frame.crop_x),
		u32(frame.crop_y),
	}
	a.CmdPushConstants(c.command, c.layout, {.COMPUTE}, 0, size_of(params), raw_data(params[:]))
	a.CmdDispatch(c.command, u32((frame.width + 15) / 16), u32((frame.height + 15) / 16), 1)
	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.HOST},
		dstAccessMask = {.HOST_READ},
	}
	dependency := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &barrier,
	}
	a.CmdPipelineBarrier2(c.command, &dependency)
	check_vk(a.EndCommandBuffer(c.command))
	wait := vk.SemaphoreSubmitInfo {
		sType     = .SEMAPHORE_SUBMIT_INFO,
		semaphore = s.ready_semaphore,
		value     = s.ready_value,
		stageMask = {.COMPUTE_SHADER},
	}
	command := vk.CommandBufferSubmitInfo {
		sType         = .COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = c.command,
	}
	submit := vk.SubmitInfo2 {
		sType                  = .SUBMIT_INFO_2,
		waitSemaphoreInfoCount = 1,
		pWaitSemaphoreInfos    = &wait,
		commandBufferInfoCount = 1,
		pCommandBufferInfos    = &command,
	}
	check_vk(a.QueueSubmit2(c.queue, 1, &submit, c.fence))
	check_vk(a.WaitForFences(c.device, 1, &c.fence, true, max(u64)))
	if !c.coherent {
		range := vk.MappedMemoryRange {
			sType  = .MAPPED_MEMORY_RANGE,
			memory = c.memory,
			size   = vk.DeviceSize(vk.WHOLE_SIZE),
		}
		check_vk(a.InvalidateMappedMemoryRanges(c.device, 1, &range))
	}
	for sample in c.mapped[:c.width * c.height * 3 / 2] {
		append(&c.pixels, u8(sample))
		if c.depth > 8 do append(&c.pixels, u8(sample >> 8))
	}
	c.frames += 1
}

main :: proc() {
	if len(os.args) != 7 do fail("usage: media_surface input.264|265 h264|h265 width height depth output.yuv")
	config := media.default_config(.H265, .Decode)
	if os.args[2] ==
	   "h264" {config.codec = .H264} else if os.args[2] != "h265" do fail("invalid codec")
	config.width, config.height, config.bit_depth =
		integer(os.args[3]), integer(os.args[4]), integer(os.args[5])
	config.preference, config.output_storage = .Require_Hardware, .Device
	input, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil do fail("cannot read source")
	defer delete(input)
	session: media.Session
	check(
		media.open(&session, config, []media.Provider{vulkan.provider()}),
	); defer media.close(&session)
	consumer: Consumer
	defer destroy_consumer(&consumer)
	check(
		media.decode(
			&session,
			{data = input, framing = .Annex_B},
			{video = receive, user = &consumer},
		),
	)
	check(media.drain(&session, {video = receive, user = &consumer}))
	if consumer.frames == 0 do fail("no decoded frames")
	if os.write_entire_file(os.args[6], consumer.pixels[:]) != nil do fail("cannot save result")
	fmt.printfln("public_surface_shader_frames=%d bytes=%d", consumer.frames, len(consumer.pixels))
}

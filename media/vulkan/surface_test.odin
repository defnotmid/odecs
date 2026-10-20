package media_vulkan

@(require) import h264 "../../video/h264"
@(require) import "core:mem"
@(require) import "core:os"
@(require) import "core:testing"
@(require) import vk "vendor:vulkan"

// This gate executes a real sampled-plane Slang compute shader on the exposed
// queue, with the exported readiness timeline, before checking its output.
when #config(ODECS_GPU_SURFACE_TEST, false) {
	Surface_Consumer :: struct {
		decoder:    ^Decoder,
		command:    Command,
		buffer:     Buffer,
		set_layout: vk.DescriptorSetLayout,
		pool:       vk.DescriptorPool,
		set:        vk.DescriptorSet,
		layout:     vk.PipelineLayout,
		pipeline:   vk.Pipeline,
		result:     [dynamic]u8,
		frames:     int,
		err:        Error,
	}

	init_surface_consumer :: proc(c: ^Surface_Consumer, frame: H265_Frame) -> Error {
		d := &c.decoder.device
		if err := alloc_buffer(d, &c.buffer, frame.width * frame.height * 6, {.STORAGE_BUFFER}); err != .None do return err
		if err := alloc_command(d, &c.command, d.transfer_family); err != .None do return err
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
		if d.a.CreateDescriptorSetLayout(d.handle, &set_layout, nil, &c.set_layout) != .SUCCESS do return .Driver_Error
		sizes := [2]vk.DescriptorPoolSize {
			{type = .SAMPLED_IMAGE, descriptorCount = 2},
			{type = .STORAGE_BUFFER, descriptorCount = 1},
		}
		pool := vk.DescriptorPoolCreateInfo {
			sType         = .DESCRIPTOR_POOL_CREATE_INFO,
			maxSets       = 1,
			poolSizeCount = 2,
			pPoolSizes    = raw_data(sizes[:]),
		}
		if d.a.CreateDescriptorPool(d.handle, &pool, nil, &c.pool) != .SUCCESS do return .Driver_Error
		allocate := vk.DescriptorSetAllocateInfo {
			sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool     = c.pool,
			descriptorSetCount = 1,
			pSetLayouts        = cast([^]vk.DescriptorSetLayout)&c.set_layout,
		}
		if d.a.AllocateDescriptorSets(d.handle, &allocate, &c.set) != .SUCCESS do return .Driver_Error
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
		if d.a.CreatePipelineLayout(d.handle, &layout, nil, &c.layout) != .SUCCESS do return .Driver_Error
		code :: #load("../../shaders/video_readback.comp.spv")
		words := make([]u32, len(code) / 4); defer delete(words)
		mem.copy(raw_data(words), raw_data(code), len(code))
		shader := vk.ShaderModuleCreateInfo {
			sType    = .SHADER_MODULE_CREATE_INFO,
			codeSize = len(code),
			pCode    = raw_data(words),
		}
		module: vk.ShaderModule
		if d.a.CreateShaderModule(d.handle, &shader, nil, &module) != .SUCCESS do return .Driver_Error
		defer d.a.DestroyShaderModule(d.handle, module, nil)
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
		if d.a.CreateComputePipelines(d.handle, 0, 1, &pipeline, nil, &c.pipeline) != .SUCCESS do return .Driver_Error
		return .None
	}

	destroy_surface_consumer :: proc(c: ^Surface_Consumer) {
		d := &c.decoder.device
		if d.handle != nil {
			d.a.DeviceWaitIdle(d.handle)
			if c.pipeline != 0 do d.a.DestroyPipeline(d.handle, c.pipeline, nil)
			if c.layout != 0 do d.a.DestroyPipelineLayout(d.handle, c.layout, nil)
			if c.pool != 0 do d.a.DestroyDescriptorPool(d.handle, c.pool, nil)
			if c.set_layout != 0 do d.a.DestroyDescriptorSetLayout(d.handle, c.set_layout, nil)
			free_command(d, &c.command)
			free_buffer(d, &c.buffer)
		}
		delete(c.result)
	}

	receive_surface :: proc(frame: H265_Frame, user: rawptr) {
		c := cast(^Surface_Consumer)user
		if c.err != .None do return
		if len(frame.planes[0]) != 0 ||
		   frame.surface.y_view == 0 ||
		   frame.surface.uv_view == 0 ||
		   frame.surface.ready_value == 0 {c.err = .Invalid_Argument; return}
		if c.pipeline == 0 {
			c.err = init_surface_consumer(c, frame)
			if c.err != .None do return
		}
		d := &c.decoder.device
		images := [2]vk.DescriptorImageInfo {
			{imageView = frame.surface.y_view, imageLayout = .GENERAL},
			{imageView = frame.surface.uv_view, imageLayout = .GENERAL},
		}
		buffer := vk.DescriptorBufferInfo {
			buffer = c.buffer.handle,
			range  = vk.DeviceSize(c.buffer.size),
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
		d.a.UpdateDescriptorSets(d.handle, 3, raw_data(writes[:]), 0, nil)
		c.err = begin_command(d, &c.command)
		if c.err != .None do return
		d.a.CmdBindPipeline(c.command.handle, .COMPUTE, c.pipeline)
		d.a.CmdBindDescriptorSets(c.command.handle, .COMPUTE, c.layout, 0, 1, &c.set, 0, nil)
		params := [5]u32 {
			u32(frame.width),
			u32(frame.height),
			u32(frame.bit_depth),
			u32(frame.crop_x),
			u32(frame.crop_y),
		}
		d.a.CmdPushConstants(
			c.command.handle,
			c.layout,
			{.COMPUTE},
			0,
			size_of(params),
			raw_data(params[:]),
		)
		d.a.CmdDispatch(
			c.command.handle,
			u32((frame.width + 15) / 16),
			u32((frame.height + 15) / 16),
			1,
		)
		memory_barrier(
			d,
			c.command.handle,
			{.COMPUTE_SHADER},
			{.HOST},
			{.SHADER_WRITE},
			{.HOST_READ},
		)
		c.err = submit_command(
			d,
			&c.command,
			frame.surface.compute_queue,
			0,
			frame.surface.ready_semaphore,
			{.COMPUTE_SHADER},
			0,
			frame.surface.ready_value,
		)
		if c.err != .None do return
		c.err = sync_buffer(d, &c.buffer, false)
		if c.err != .None do return
		pixels := (cast([^]u32)c.buffer.mapped)[:frame.width * frame.height * 3 / 2]
		for pixel in pixels {
			append(&c.result, u8(pixel))
			if frame.bit_depth == 10 do append(&c.result, u8(pixel >> 8))
		}
		c.frames += 1
	}

	@(test)
	device_decode_compute :: proc(t: ^testing.T) {
		fixture :: #config(ODECS_GPU_SURFACE_FIXTURE, "")
		testing.expect(t, fixture != "")
		if fixture == "" do return
		data, error := os.read_entire_file(fixture, context.allocator)
		testing.expect(t, error == nil)
		if error != nil do return
		defer delete(data)
		nals := h264.find_nal_units(data); defer delete(nals)
		d: H265_Decoder
		testing.expect_value(
			t,
			init_h265_decoder(&d, {device_index = -1, output_storage = .Device}),
			Error.None,
		)
		defer destroy_h265_decoder(&d)
		c := Surface_Consumer {
			decoder = &d.backend,
		}
		defer destroy_surface_consumer(&c)
		for nal in nals {
			err := decode_h265_nal(
				&d,
				data[nal.offset:nal.offset + nal.length],
				receive_surface,
				&c,
			)
			testing.expect_value(t, err, Error.None)
			if err != .None do return
			testing.expect_value(t, c.err, Error.None)
			if c.err != .None do return
		}
		testing.expect_value(t, flush_h265_decoder(&d, receive_surface, &c), Error.None)
		testing.expect_value(t, c.err, Error.None)
		testing.expect(t, c.frames > 0)
		testing.expect(t, os.write_entire_file("/tmp/odecs-gpu-surface.yuv", c.result[:]) == nil)
	}

	receive_avc_surface :: proc(frame: H264_Frame, user: rawptr) {
		receive_surface(frame, user)
	}

	@(test)
	device_avc_decode_compute :: proc(t: ^testing.T) {
		fixture :: #config(ODECS_GPU_AVC_SURFACE_FIXTURE, "")
		if fixture == "" do return
		data, error := os.read_entire_file(fixture, context.allocator)
		testing.expect(t, error == nil)
		if error != nil do return
		defer delete(data)
		nals := h264.find_nal_units(data); defer delete(nals)
		d: H264_Decoder
		testing.expect_value(
			t,
			init_h264_decoder(&d, {device_index = -1, output_storage = .Device}),
			Error.None,
		)
		defer destroy_h264_decoder(&d)
		c := Surface_Consumer {
			decoder = &d.backend,
		}
		defer destroy_surface_consumer(&c)
		for nal in nals {
			err := decode_h264_nal(
				&d,
				data[nal.offset:nal.offset + nal.length],
				receive_avc_surface,
				&c,
			)
			testing.expect_value(t, err, Error.None)
			if err != .None do return
			testing.expect_value(t, c.err, Error.None)
			if c.err != .None do return
		}
		testing.expect_value(t, flush_h264_decoder(&d, receive_avc_surface, &c), Error.None)
		testing.expect_value(t, c.err, Error.None)
		testing.expect(t, c.frames > 0)
		testing.expect(
			t,
			os.write_entire_file("/tmp/odecs-gpu-avc-surface.yuv", c.result[:]) == nil,
		)
	}
}

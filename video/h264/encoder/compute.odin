package h264_encoder

import h264 ".."

import "core:mem"
import vk "vendor:vulkan"

// Wire layout is shared with shaders/deblock_common.slang.
Compute_MB :: struct {
	flags, deblocking_mode, slice_index: u32,
	qp, alpha_offset, beta_offset:       i32,
	coded_mask, reserved:                u32,
	prediction_directions:               [4]u32,
	reference_picture_ids:               [2][4]i32,
	motion_vectors:                      [2][16][2]i32,
}
Compute_Params :: struct {
	macroblocks, strengths, tables, y, cb, cr:                      vk.DeviceAddress,
	macroblock_columns, macroblock_rows, wave, y_stride, uv_stride: u32,
	chroma0, chroma1:                                               i32,
	reserved:                                                       u32,
}
#assert(size_of(Compute_MB) == 336)
#assert(size_of(Compute_Params) == 80)

Compute_Picture :: struct {
	buf:        h264.YUV_Buffer, // CPU view of the SAME storage the Slang pointers address
	planes:     [3]vk.DeviceAddress,
	generation: u64, // zero until the complete uncancelled stage has finished
}
Compute_State :: struct {
	error_detail:                       string,
	device:                             ^Compute_Device, // borrowed; must outlive this context
	allocator:                          mem.Allocator,
	allocation:                         Compute_Allocation,
	pictures:                           []Compute_Picture,
	source:                             Compute_Picture,
	macroblocks:                        []Compute_MB,
	strengths:                          []u32,
	params:                             Compute_Params,
	pool:                               vk.CommandPool,
	command:                            vk.CommandBuffer,
	fence:                              vk.Fence,
	queries:                            vk.QueryPool,
	layout:                             vk.PipelineLayout,
	strength_pipeline, filter_pipeline: vk.Pipeline,
	slot:                               int,
	generation:                         u64,
	active, canceled, pending:          bool,
	next_wave:                          u32,
	submissions:                        u64,
	gpu_ms:                             f64, // sum of actual device timestamps, excludes host scheduling
}
COMPUTE_WAVES_PER_BATCH :: 8
COMPUTE_TABLE_SIZE :: 364 * size_of(i32)

init_compute :: proc(
	c: ^Compute_State,
	device: ^Compute_Device,
	macroblock_columns, macroblock_rows, slots: int,
	placement: Compute_Memory = .Host_Cached,
	allocator := context.allocator,
) -> (
	err: Error,
) {
	if device == nil || device.handle == nil || macroblock_columns <= 0 || macroblock_rows <= 0 || slots <= 0 do return .Invalid_Input
	if c.device != nil do return .Busy
	c.device, c.allocator = device, allocator
	defer if err != .None {
		detail := c.error_detail
		destroy_compute(c)
		c.error_detail = detail
	}
	d := device
	w, h := macroblock_columns * 16, macroblock_rows * 16
	picture_bytes := (h264.yuv_buffer_size(w, h) + 255) &~ 255
	mb_count := macroblock_columns * macroblock_rows
	metadata_offset := picture_bytes * (slots + 1)
	strength_offset := metadata_offset + mb_count * size_of(Compute_MB)
	table_offset := strength_offset + mb_count * 8 * size_of(u32)
	if e := alloc_compute_memory(d, &c.allocation, table_offset + COMPUTE_TABLE_SIZE, placement);
	   e != .None {
		c.error_detail = d.error_detail
		return e
	}
	c.pictures = make([]Compute_Picture, slots, allocator)
	if raw_data(c.pictures) == nil {c.pictures = nil; return .Allocation_Failed}
	for i in 0 ..= slots {
		pic := i == slots ? &c.source : &c.pictures[i]
		base := &c.allocation.mapped[i * picture_bytes]
		pic.buf = h264.yuv_buffer_view(w, h, base)
		planes := [3][^]u8{pic.buf.y, pic.buf.u, pic.buf.v}
		for p in 0 ..< 3 do pic.planes[p] = c.allocation.address + vk.DeviceAddress(uintptr(planes[p]) - uintptr(c.allocation.mapped))
	}
	c.macroblocks = (cast([^]Compute_MB)&c.allocation.mapped[metadata_offset])[:mb_count]
	c.strengths = (cast([^]u32)&c.allocation.mapped[strength_offset])[:mb_count * 8]
	tables := cast([^]i32)&c.allocation.mapped[table_offset]
	for i in 0 ..< 52 {
		tables[i], tables[52 + i], tables[312 + i] =
			i32(h264.deblock_alpha_table[i + 12]),
			i32(h264.deblock_beta_table[i + 12]),
			i32(h264.chroma_qp_table[i])
		for k in 0 ..< 4 do tables[104 + i * 4 + k] = i32(h264.deblock_tc0_table[i + 12][k])
	}
	c.params = {
		macroblocks        = c.allocation.address + vk.DeviceAddress(metadata_offset),
		strengths          = c.allocation.address + vk.DeviceAddress(strength_offset),
		tables             = c.allocation.address + vk.DeviceAddress(table_offset),
		macroblock_columns = u32(macroblock_columns),
		macroblock_rows    = u32(macroblock_rows),
		y_stride           = u32(c.pictures[0].buf.y_stride),
		uv_stride          = u32(c.pictures[0].buf.uv_stride),
	}
	pool_info := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = d.queue_family,
	}
	if d.api.CreateCommandPool(d.handle, &pool_info, nil, &c.pool) != .SUCCESS do return compute_error(c, .Driver_Error, "compute command pool creation failed")
	cmd_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = c.pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if d.api.AllocateCommandBuffers(d.handle, &cmd_info, &c.command) != .SUCCESS do return compute_error(c, .Driver_Error, "compute command allocation failed")
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
	}
	if d.api.CreateFence(d.handle, &fence_info, nil, &c.fence) != .SUCCESS do return compute_error(c, .Driver_Error, "compute fence creation failed")
	query_info := vk.QueryPoolCreateInfo {
		sType      = .QUERY_POOL_CREATE_INFO,
		queryType  = .TIMESTAMP,
		queryCount = 2,
	}
	if d.api.CreateQueryPool(d.handle, &query_info, nil, &c.queries) != .SUCCESS do return compute_error(c, .Driver_Error, "compute timestamp allocation failed")
	push := vk.PushConstantRange {
		stageFlags = {.COMPUTE},
		size       = size_of(Compute_Params),
	}
	layout_info := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push,
	}
	if d.api.CreatePipelineLayout(d.handle, &layout_info, nil, &c.layout) != .SUCCESS do return compute_error(c, .Driver_Error, "compute pipeline layout creation failed")
	bs_code :: #load("../../../shaders/deblock_bs.comp.spv")
	filter_code :: #load("../../../shaders/deblock_filter.comp.spv")
	for code, i in ([2][]u8{bs_code, filter_code}) {
		words := make([]u32, len(code) / 4, allocator)
		defer delete(words, allocator)
		if raw_data(words) == nil do return .Allocation_Failed
		mem.copy(raw_data(words), raw_data(code), len(code))
		module_info := vk.ShaderModuleCreateInfo {
			sType    = .SHADER_MODULE_CREATE_INFO,
			codeSize = len(code),
			pCode    = raw_data(words),
		}
		module: vk.ShaderModule
		if d.api.CreateShaderModule(d.handle, &module_info, nil, &module) != .SUCCESS do return compute_error(c, .Driver_Error, "compute shader creation failed")
		defer d.api.DestroyShaderModule(d.handle, module, nil)
		info := vk.ComputePipelineCreateInfo {
			sType = .COMPUTE_PIPELINE_CREATE_INFO,
			layout = c.layout,
			stage = {
				sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
				stage = {.COMPUTE},
				module = module,
				pName = "main",
			},
		}
		pipeline := i == 0 ? &c.strength_pipeline : &c.filter_pipeline
		if d.api.CreateComputePipelines(d.handle, 0, 1, &info, nil, pipeline) != .SUCCESS do return compute_error(c, .Driver_Error, "compute pipeline creation failed")
	}
	return .None
}

destroy_compute :: proc(c: ^Compute_State) {
	if c.device == nil do return
	d := c.device
	if c.pending do _ = d.api.WaitForFences(d.handle, 1, &c.fence, true, ~u64(0))
	if c.pool != 0 do d.api.DestroyCommandPool(d.handle, c.pool, nil)
	if c.fence != 0 do d.api.DestroyFence(d.handle, c.fence, nil)
	if c.queries != 0 do d.api.DestroyQueryPool(d.handle, c.queries, nil)
	for pipeline in ([2]vk.Pipeline{c.strength_pipeline, c.filter_pipeline}) do if pipeline != 0 do d.api.DestroyPipeline(d.handle, pipeline, nil)
	if c.layout != 0 do d.api.DestroyPipelineLayout(d.handle, c.layout, nil)
	free_compute_memory(d, &c.allocation)
	delete(c.pictures, c.allocator)
	c^ = {}
}

pack_compute_mb :: proc(dst: ^Compute_MB, src: #soa^#soa[]h264.Macroblock) {
	// Assemble in CPU registers/stack, then publish once. Reading a partially
	// written descriptor through a mapped VRAM pointer is particularly costly.
	packed: Compute_MB
	packed.flags = u32(src.is_intra) | (u32(src.uses_8x8_transform) << 1)
	packed.deblocking_mode, packed.slice_index = u32(src.deblocking_mode), u32(src.slice_index)
	packed.qp = src.type == .I_PCM ? 0 : i32(src.quantizer)
	packed.alpha_offset, packed.beta_offset = i32(src.alpha_offset) * 2, i32(src.beta_offset) * 2
	for i in 0 ..< 16 {
		if src.uses_8x8_transform ? src.has_8x8_coefficients[i / 4] : src.nonzero_coefficient_counts[i] > 0 do packed.coded_mask |= 1 << u32(i)
		for l in 0 ..< 2 do packed.motion_vectors[l][i] = {i32(src.motion_vectors[l][i][0]), i32(src.motion_vectors[l][i][1])}
	}
	for i in 0 ..< 4 {
		packed.prediction_directions[i] = u32(src.prediction_directions[i])
		for l in 0 ..< 2 do packed.reference_picture_ids[l][i] = src.reference_picture_ids[l][i]
	}
	dst^ = packed
}


compute_barrier :: proc(
	c: ^Compute_State,
	src, dst: vk.PipelineStageFlags,
	src_access, dst_access: vk.AccessFlags,
) {
	barrier := vk.MemoryBarrier {
		sType         = .MEMORY_BARRIER,
		srcAccessMask = src_access,
		dstAccessMask = dst_access,
	}
	c.device.api.CmdPipelineBarrier(c.command, src, dst, {}, 1, &barrier, 0, nil, 0, nil)
}

// Submit a bounded batch against stable addresses. Host and shader visibility is
// established explicitly even though the mapped allocation is host-coherent.
submit_compute :: proc(c: ^Compute_State, strengths: bool) -> Error {
	d := c.device
	if d.api.ResetCommandBuffer(c.command, {}) != .SUCCESS do return compute_error(c, .Driver_Error, "compute command reset failed")
	info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if d.api.BeginCommandBuffer(c.command, &info) != .SUCCESS do return compute_error(c, .Driver_Error, "compute command begin failed")
	d.api.CmdResetQueryPool(c.command, c.queries, 0, 2)
	d.api.CmdWriteTimestamp(c.command, {.TOP_OF_PIPE}, c.queries, 0)
	if strengths {
		compute_barrier(
			c,
			{.HOST},
			{.COMPUTE_SHADER},
			{.HOST_WRITE},
			{.SHADER_READ, .SHADER_WRITE},
		)
		d.api.CmdBindPipeline(c.command, .COMPUTE, c.strength_pipeline)
		d.api.CmdPushConstants(
			c.command,
			c.layout,
			{.COMPUTE},
			0,
			size_of(Compute_Params),
			&c.params,
		)
		d.api.CmdDispatch(
			c.command,
			(c.params.macroblock_columns * c.params.macroblock_rows * 8 + 63) / 64,
			1,
			1,
		)
	} else {
		d.api.CmdBindPipeline(c.command, .COMPUTE, c.filter_pipeline)
		total := c.params.macroblock_columns + 2 * (c.params.macroblock_rows - 1)
		last := min(c.next_wave + COMPUTE_WAVES_PER_BATCH, total)
		for wave in c.next_wave ..< last {
			compute_barrier(
				c,
				{.COMPUTE_SHADER},
				{.COMPUTE_SHADER},
				{.SHADER_WRITE},
				{.SHADER_READ, .SHADER_WRITE},
			)
			c.params.wave = wave
			d.api.CmdPushConstants(
				c.command,
				c.layout,
				{.COMPUTE},
				0,
				size_of(Compute_Params),
				&c.params,
			)
			d.api.CmdDispatch(c.command, c.params.macroblock_rows, 1, 1)
		}
		c.next_wave = last
	}
	compute_barrier(c, {.COMPUTE_SHADER}, {.HOST}, {.SHADER_WRITE}, {.HOST_READ, .HOST_WRITE})
	d.api.CmdWriteTimestamp(c.command, {.BOTTOM_OF_PIPE}, c.queries, 1)
	if d.api.EndCommandBuffer(c.command) != .SUCCESS do return compute_error(c, .Driver_Error, "compute command end failed")
	if d.api.ResetFences(d.handle, 1, &c.fence) != .SUCCESS do return compute_error(c, .Driver_Error, "compute fence reset failed")
	submit := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &c.command,
	}
	if d.api.QueueSubmit(d.queue, 1, &submit, c.fence) != .SUCCESS do return compute_error(c, .Driver_Error, "compute submission failed")
	c.pending = true
	c.submissions += 1
	return .None
}

// No frame upload or readback. Reconstruction must already be in this context's
// picture slot, accessible via pictures[slot].buf on the CPU and Slang pointers
// on the GPU. The metadata is packed directly into its permanent mapped range.
begin_compute_deblock :: proc(
	c: ^Compute_State,
	macroblocks: #soa[]h264.Macroblock,
	slot: int,
	generation: u64,
	chroma_offsets: [2]i32,
) -> Error {
	if c.active do return .Busy
	if c.device == nil || slot < 0 || slot >= len(c.pictures) || generation == 0 do return .Invalid_Input
	if len(macroblocks) != len(c.macroblocks) do return .Invalid_Input
	for i in 0 ..< len(macroblocks) do pack_compute_mb(&c.macroblocks[i], &macroblocks[i])
	c.slot, c.generation = slot, generation
	c.params.y, c.params.cb, c.params.cr =
		c.pictures[slot].planes[0], c.pictures[slot].planes[1], c.pictures[slot].planes[2]
	c.params.chroma0, c.params.chroma1 = chroma_offsets[0], chroma_offsets[1]
	c.active, c.canceled, c.next_wave = true, false, 0
	c.pictures[slot].generation = 0
	if err := submit_compute(c, true); err != .None {c.active = false; return err}
	return .None
}

cancel_compute :: proc(c: ^Compute_State) {
	if c.active do c.canceled = true
}

// Nonblocking poll and at most one bounded batch submission. A canceled slot
// remains unavailable to both CPU and GPU writers until its fence has retired.
advance_compute :: proc(c: ^Compute_State) -> (ready: bool, err: Error) {
	if !c.active do return true, .None
	d := c.device
	if c.pending {
		status := d.api.GetFenceStatus(d.handle, c.fence)
		if status == .NOT_READY do return false, .None
		if status != .SUCCESS do return false, compute_error(c, .Driver_Error, "compute fence failed")
		c.pending = false
		ticks: [2]u64
		if d.api.GetQueryPoolResults(d.handle, c.queries, 0, 2, size_of(ticks), &ticks, size_of(u64), {._64}) != .SUCCESS do return false, compute_error(c, .Driver_Error, "compute timestamp query failed")
		mask := d.timestamp_bits == 64 ? ~u64(0) : (u64(1) << d.timestamp_bits) - 1
		c.gpu_ms +=
			f64((ticks[1] - ticks[0]) & mask) * f64(d.properties.limits.timestampPeriod) / 1e6
	}
	if c.canceled {c.active = false; return true, .None}
	if c.next_wave == c.params.macroblock_columns + 2 * (c.params.macroblock_rows - 1) {
		c.pictures[c.slot].generation = c.generation
		c.active = false
		return true, .None
	}
	submit_compute(c, false) or_return
	return false, .None
}

// Attach before the first frame. Replace the cold CPU allocations with borrowed
// views of the compute allocation; there is one physical copy of each picture.
// The default is shared cached memory while CPU RD dominates. Device_Local uses
// mapped VRAM without changing the Slang pointer contract or adding transfers.
attach_encoder_compute :: proc(
	state: ^Encoder_State,
	device: ^Compute_Device,
	placement: Compute_Memory = .Host_Cached,
	allocator := context.allocator,
) -> Error {
	if state.macroblocks == nil || state.pictures == nil do return .Invalid_State
	if state.frame.phase != .Idle || state.frames_coded != 0 || state.compute != nil do return .Invalid_State
	c := new(Compute_State, allocator)
	if c == nil do return .Allocation_Failed
	if err := init_compute(
		c,
		device,
		state.macroblock_columns,
		state.macroblock_rows,
		len(state.pictures),
		placement,
		allocator,
	); err != .None {
		state.error_detail = c.error_detail
		free(c, allocator)
		return err
	}
	// The replaced CPU planes belong to init_encoder's allocator, independently
	// of the allocator used for this compute context.
	context.allocator = state.allocator
	for &pic, i in state.pictures {
		h264.free_yuv_buffer(&pic.buf)
		pic.buf = c.pictures[i].buf
	}
	h264.free_yuv_buffer(&state.source)
	state.source = c.source.buf
	state.compute = c
	return .None
}

@(private)
compute_error :: proc(c: ^Compute_State, err: Error, detail: string) -> Error {
	c.error_detail = detail
	return err
}

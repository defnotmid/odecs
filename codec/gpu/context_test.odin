package gpu

import "core:mem"
import "core:testing"

// These are argument and ownership-metadata controls. They neither create nor
// fabricate Vulkan handles and do not claim hardware availability or execution.
// The initialized metadata model permits testing lazy frontend ownership before
// the first SPS creates a GPU session; live-device gates remain opt-in.
@(private)
context_lifetime_model :: proc(c: ^Context) {
	c.initialized = true
	c.self = c
	c.device.a = &c.device.api
}

@(test)
context_rejects_invalid_configuration_before_loading :: proc(t: ^testing.T) {
	r := Request {
		codec     = .H264,
		operation = .Decode,
		width     = 384,
		height    = 240,
		bit_depth = 8,
	}
	requests := [1]Request{r}
	testing.expect_value(
		t,
		init_context(nil, {requests = requests[:], device_index = -1}),
		Error.Invalid_Argument,
	)
	c: Context
	testing.expect_value(t, init_context(&c, {device_index = -1}), Error.Invalid_Argument)
	testing.expect_value(
		t,
		init_context(&c, {requests = requests[:], device_index = -2}),
		Error.Invalid_Argument,
	)
	requests[0].width = -1
	testing.expect_value(
		t,
		init_context(&c, {requests = requests[:], device_index = -1}),
		Error.Invalid_Argument,
	)
	requests[0].width, requests[0].height = 384, -1
	testing.expect_value(
		t,
		init_context(&c, {requests = requests[:], device_index = -1}),
		Error.Invalid_Argument,
	)
	too_many: [33]Request
	for &request in too_many do request = r
	testing.expect_value(
		t,
		init_context(&c, {requests = too_many[:], device_index = -1}),
		Error.Invalid_Argument,
	)
	testing.expect(t, !c.initialized && c.self == nil && c.device.instance == nil && c.holds == 0)
	testing.expect_value(t, destroy_context(&c), Error.None)
	testing.expect_value(t, destroy_context(&c), Error.None)
	testing.expect_value(t, destroy_context(nil), Error.Invalid_Argument)
}

@(test)
context_rejects_unsupported_profiles_before_loading :: proc(t: ^testing.T) {
	cases := []Request {
		{codec = .H264, operation = .Decode, bit_depth = 10},
		{codec = .H264, operation = .Encode, bit_depth = 10},
		{codec = .H265, operation = .Decode, bit_depth = 8, profile_idc = 4},
		{codec = .H265, operation = .Encode, bit_depth = 10, profile_idc = 4},
		{codec = .H265, operation = .Decode, bit_depth = 12},
		{codec = .H265, operation = .Decode, bit_depth = 8, profile_idc = -1},
	}
	for request in cases {
		c: Context
		requests := [1]Request{request}
		testing.expect_value(
			t,
			init_context(&c, {requests = requests[:], device_index = -1}),
			Error.Unsupported,
		)
		testing.expect(
			t,
			!c.initialized && c.self == nil && c.device.instance == nil && c.holds == 0,
		)
		testing.expect_value(t, destroy_context(&c), Error.None)
	}
}

@(test)
context_uninitialized_consumers_reject_without_retaining :: proc(t: ^testing.T) {
	c: Context
	descriptor := context_descriptor(&c)
	testing.expect(
		t,
		descriptor.device == nil &&
		descriptor.device_api == nil &&
		descriptor.compute_queue == nil,
	)
	list, error := probe(
		{codec = .H264, operation = .Decode, width = 384, height = 240, bit_depth = 8},
		&c,
	)
	defer delete(list)
	testing.expect_value(t, error, Error.Invalid_Argument)
	testing.expect_value(t, len(list), 0)
	e: Encoder
	testing.expect_value(
		t,
		init_encoder(
			&e,
			{shared_context = &c, device_index = -1, width = 384, height = 240, qp = 26},
		),
		Error.Invalid_Argument,
	)
	testing.expect(t, !e.initialized && e.device.instance == nil && e.device.a == nil)
	destroy_encoder(&e)
	d: Decoder
	testing.expect_value(
		t,
		init_decoder(
			&d,
			{
				shared_context = &c,
				codec = .H265,
				device_index = -1,
				width = 384,
				height = 240,
				bit_depth = 8,
				dpb_slots = 2,
				max_references = 1,
			},
		),
		Error.Invalid_Argument,
	)
	testing.expect(t, !d.initialized && d.device.instance == nil && d.device.a == nil)
	destroy_decoder(&d)
	avc: H264_Decoder
	testing.expect_value(
		t,
		init_h264_decoder(&avc, {shared_context = &c, device_index = -1}),
		Error.Invalid_Argument,
	)
	testing.expect(t, !avc.initialized)
	destroy_h264_decoder(&avc)
	hevc: H265_Decoder
	testing.expect_value(
		t,
		init_h265_decoder(&hevc, {shared_context = &c, device_index = -1}),
		Error.Invalid_Argument,
	)
	testing.expect(t, !hevc.initialized)
	destroy_h265_decoder(&hevc)
	testing.expect_value(t, c.holds, 0)
	testing.expect_value(t, destroy_context(&c), Error.None)
}

@(test)
context_lazy_frontends_hold_owner_before_first_sps :: proc(t: ^testing.T) {
	c: Context
	context_lifetime_model(&c)
	avc: H264_Decoder
	hevc: H265_Decoder
	testing.expect_value(
		t,
		init_h264_decoder(&avc, {shared_context = &c, device_index = -1}),
		Error.None,
	)
	testing.expect_value(
		t,
		init_h265_decoder(&hevc, {shared_context = &c, device_index = -1}),
		Error.None,
	)
	testing.expect(t, avc.backend.session == 0 && hevc.backend.session == 0)
	testing.expect_value(t, c.holds, 2)
	api := c.device.a
	testing.expect_value(t, destroy_context(&c), Error.Busy)
	testing.expect(t, c.initialized && c.self == &c && c.device.a == api && c.holds == 2)
	destroy_h264_decoder(&avc)
	destroy_h264_decoder(&avc)
	testing.expect_value(t, c.holds, 1)
	testing.expect_value(t, destroy_context(&c), Error.Busy)
	destroy_h265_decoder(&hevc)
	destroy_h265_decoder(&hevc)
	testing.expect_value(t, c.holds, 0)
	testing.expect_value(t, destroy_context(&c), Error.None)
}

@(test)
context_moved_owner_is_refused_without_touching_original :: proc(t: ^testing.T) {
	c: Context
	context_lifetime_model(&c)
	moved := c
	testing.expect_value(t, retain_context(&moved), Error.Invalid_Argument)
	testing.expect_value(t, destroy_context(&moved), Error.Invalid_Argument)
	testing.expect(t, context_descriptor(&moved).device_api == nil)
	testing.expect(t, c.initialized && c.self == &c && c.device.a == &c.device.api && c.holds == 0)
	testing.expect_value(t, destroy_context(&c), Error.None)
}

@(test)
context_failed_borrow_releases_hold_and_keeps_owner_dispatch :: proc(t: ^testing.T) {
	c: Context
	context_lifetime_model(&c)
	c.device_index = 3
	c.routes = make([]Context_Route, 1)
	c.routes[0] = {
		codec     = .H265,
		operation = .Decode,
	}
	defer destroy_context(&c)
	request := Request {
		codec     = .H265,
		operation = .Decode,
		bit_depth = 8,
	}
	cases := []struct {
		request: Request,
		index:   int,
	} {
		{request, 4}, // wrong selected physical-device index
		{{codec = .H264, operation = .Encode, bit_depth = 8}, -1}, // undeclared operation
		{request, -1}, // matching route, absent dispatch: post-acquire failure
	}
	for control in cases {
		d: Device
		_, _, _, error := borrow_context_device(&d, &c, control.request, control.index)
		testing.expect_value(t, error, Error.Unsupported)
		testing.expect(t, d.shared_context == nil && d.a == nil && d.instance == nil)
		testing.expect(
			t,
			c.initialized && c.self == &c && c.holds == 0 && c.device.a == &c.device.api,
		)
	}
}

@(test)
context_owned_arrays_use_captured_allocator_at_destroy :: proc(t: ^testing.T) {
	owner, ambient: mem.Tracking_Allocator
	mem.tracking_allocator_init(&owner, context.allocator)
	mem.tracking_allocator_init(&ambient, context.allocator)
	defer mem.tracking_allocator_destroy(&owner)
	defer mem.tracking_allocator_destroy(&ambient)
	owner.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	ambient.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	c: Context
	{
		context.allocator = mem.tracking_allocator(&owner)
		context_lifetime_model(&c)
		c.allocator = context.allocator
		c.requests = make([]Request, 2)
		c.routes = make([]Context_Route, 2)
	}
	testing.expect(t, owner.current_memory_allocated > 0 && len(owner.allocation_map) == 2)
	{
		context.allocator = mem.tracking_allocator(&ambient)
		testing.expect_value(t, destroy_context(&c), Error.None)
	}
	testing.expect_value(t, owner.current_memory_allocated, i64(0))
	testing.expect_value(t, len(owner.allocation_map), 0)
	testing.expect_value(t, len(owner.bad_free_array), 0)
	testing.expect_value(t, ambient.current_memory_allocated, i64(0))
	testing.expect_value(t, len(ambient.allocation_map), 0)
	testing.expect_value(t, len(ambient.bad_free_array), 0)
}

package media_vulkan

import avc "../../h264"
import avcd "../../h264/decoder"
import "core:slice"
import vk "vendor:vulkan"

H264_Decoder_Config :: struct {
	shared_context:           ^Context, // optional shared device, held until this frontend is destroyed
	device_index:             int,
	width, height, bit_depth: int, // zero accepts the stream's value
	profile_idc:              int, // zero accepts the stream's profile
	max_packet_bytes:         int, // zero admits up to 128 MiB per coded picture
	output_storage:           Output_Storage,
	no_reordering:            bool, // the caller asserts the stream has no reordered pictures
}
H264_Receiver :: proc(frame: H264_Frame, user: rawptr)

// A picture from submission to display: its frame (planes owned once held).
@(private)
H264_Queued_Frame :: struct {
	frame:  H264_Frame,
	planes: [3][]u8,
	pic_id: i32,
}
// A picture the native decoder has put in display order.
@(private)
H264_Display :: struct {
	pic_id: i32,
	poc:    i32,
}

// Parsing, POC, MMCO, reference lists and display order use the native AVC
// owners. Only picture assembly and the association with Vulkan slots live here.
// The receiver borrows each output until it returns; do not move an active decoder.
H264_Decoder :: struct {
	config:                                       H264_Decoder_Config,
	backend:                                      Decoder,
	syntax:                                       avcd.Decoder_State,
	parameters:                                   H264_Parameter_Storage,
	parameters_dirty:                             bool,
	active_pps:                                   u32,
	packet:                                       [dynamic]u8,
	slice_offsets:                                [dynamic]u32,
	gpu_slots:                                    [avcd.MAX_PICTURES]int,
	gpu_pic_ids:                                  [avcd.MAX_PICTURES]i32,
	// Submitted pictures (in order) until the hardware returns them, then
	// held until their turn in display order.
	in_flight, held:                              [dynamic]H264_Queued_Frame,
	display:                                      [dynamic]H264_Display,
	seen_picture, all_intra, initialized, failed: bool,
}

init_h264_decoder :: proc(d: ^H264_Decoder, config: H264_Decoder_Config) -> Error {
	if d == nil || d.initialized || config.device_index < -1 || config.width < 0 || config.height < 0 || config.profile_idc < 0 || config.max_packet_bytes < 0 || config.max_packet_bytes > 1 << 30 do return .Invalid_Argument
	if config.bit_depth != 0 && config.bit_depth != 8 do return .Unsupported
	if config.shared_context != nil {
		if err := retain_context(config.shared_context); err != .None do return err
	}
	d^ = {
		config           = config,
		initialized      = true,
		parameters_dirty = true,
	}
	for &slot in d.gpu_slots do slot = -1
	avcd.init_decoder(&d.syntax)
	d.syntax.no_reordering = config.no_reordering
	return .None
}

@(private)
h264_free_queued :: proc(q: ^H264_Queued_Frame) {
	for plane in q.planes do delete(plane)
	q^ = {}
}

destroy_h264_decoder :: proc(d: ^H264_Decoder) {
	if d == nil do return
	for &q in d.held do h264_free_queued(&q)
	delete(d.held)
	delete(d.in_flight)
	delete(d.display)
	delete(d.packet)
	delete(d.slice_offsets)
	avcd.destroy_decoder(&d.syntax)
	destroy_decoder(&d.backend)
	if d.initialized && d.config.shared_context != nil do release_context(d.config.shared_context)
	d^ = {}
}

@(private)
h264_picture_index :: proc(d: ^H264_Decoder, pic: ^avcd.Picture) -> int {
	for &entry, i in d.syntax.pics do if &entry == pic do return i
	return -1
}

// Takes the pictures the native decoder has released for output, in order.
@(private)
h264_take_display :: proc(d: ^H264_Decoder) {
	for {
		pic := avcd.next_output_frame(&d.syntax)
		if pic == nil do return
		append(&d.display, H264_Display{pic.pic_id, pic.poc})
	}
}

// Whether a picture will still be shown: queued for display, or held by
// the native decoder for output (an IDR can discard pictures unshown).
@(private)
h264_awaited :: proc(d: ^H264_Decoder, pic_id: i32) -> bool {
	for e in d.display do if e.pic_id == pic_id do return true
	for &pic in d.syntax.pics do if pic.in_use && pic.pic_id == pic_id && pic.needed_for_output do return true
	return false
}

// A picture back from the hardware, the oldest submitted: shown at once
// when it is next in display order, else copied and held.
@(private)
h264_receive :: proc(d: ^H264_Decoder, decoded: Decoder_Frame, receiver: H264_Receiver, user: rawptr) {
	h264_emit(d, receiver, user) // held pictures due before this one
	q := d.in_flight[0]
	ordered_remove(&d.in_flight, 0)
	q.frame.surface, q.frame.storage_bits, q.frame.strides = decoded.surface, decoded.storage_bits, decoded.strides
	if len(d.display) > 0 && d.display[0].pic_id == q.pic_id {
		crop_planes(&q.frame, decoded.planes)
		q.frame.poc = int(d.display[0].poc)
		ordered_remove(&d.display, 0)
		if receiver != nil do receiver(q.frame, user)
		return
	}
	if !h264_awaited(d, q.pic_id) do return
	if d.config.output_storage == .Host {
		for plane, k in decoded.planes do q.planes[k] = slice.clone(plane)
		crop_planes(&q.frame, q.planes)
		q.frame.surface = {}
	}
	append(&d.held, q)
}

// Shows held pictures while the next in display order is held.
@(private)
h264_emit :: proc(d: ^H264_Decoder, receiver: H264_Receiver, user: rawptr) {
	outer: for len(d.display) > 0 {
		for &q, i in d.held {
			if q.pic_id != d.display[0].pic_id do continue
			q.frame.poc = int(d.display[0].poc)
			ordered_remove(&d.display, 0)
			if receiver != nil do receiver(q.frame, user)
			h264_free_queued(&q)
			ordered_remove(&d.held, i)
			continue outer
		}
		break
	}
	// Held pictures an IDR discarded.
	for i := 0; i < len(d.held); {
		if h264_awaited(d, d.held[i].pic_id) {i += 1; continue}
		h264_free_queued(&d.held[i])
		ordered_remove(&d.held, i)
	}
}

// Receives every picture still in flight.
@(private)
h264_drain_backend :: proc(d: ^H264_Decoder, receiver: H264_Receiver, user: rawptr) -> Error {
	if !d.backend.initialized do return .None
	for {
		decoded, ready, err := finish_decoder(&d.backend)
		if err != .None do return err
		if !ready do return .None
		h264_receive(d, decoded, receiver, user)
	}
}

@(private)
h264_ensure_backend :: proc(
	d: ^H264_Decoder,
	s: ^avc.Sequence_Parameter_Set,
	p: ^avc.Picture_Parameter_Set,
	reset: bool,
	receiver: H264_Receiver = nil,
	user: rawptr = nil,
) -> Error {
	w, h := s.macroblock_columns * 16, s.macroblock_rows * 16
	slots := d.syntax.dpb_size + 1
	if slots < 2 ||
	   slots > 17 ||
	   (d.config.width != 0 && d.config.width != s.width) ||
	   (d.config.height != 0 && d.config.height != s.height) ||
	   (d.config.profile_idc != 0 && d.config.profile_idc != int(s.profile)) {return .Unsupported}
	if d.config.output_storage == .Device && d.syntax.max_reorder != 0 do return .Unsupported
	if d.backend.initialized &&
	   (d.backend.config.width != w ||
			   d.backend.config.height != h ||
			   d.backend.config.profile_idc != int(s.profile) ||
			   d.backend.config.dpb_slots != slots) {
		if d.config.output_storage == .Device do return .Unsupported
		if !reset do return .Unsupported
		if err := h264_drain_backend(d, receiver, user); err != .None do return err
		destroy_decoder(&d.backend)
		d.parameters_dirty = true
	}
	if !d.backend.initialized {
		limit := d.config.max_packet_bytes
		if limit == 0 do limit = 128 * 1024 * 1024
		config := Decoder_Config {
			codec            = .H264,
			width            = w,
			height           = h,
			bit_depth        = 8,
			profile_idc      = int(s.profile),
			dpb_slots        = slots,
			max_references   = slots - 1,
			device_index     = d.config.device_index,
			max_packet_bytes = limit,
			output_storage   = d.config.output_storage,
			shared_context   = d.config.shared_context,
		}
		if err := init_decoder(&d.backend, config); err != .None do return err
	}
	if d.parameters_dirty || d.active_pps != p.pic_parameter_set_id {
		if err := map_h264_parameters(&d.parameters, s, p); err != .None do return err
		sps := [1]vk.VideoH264SequenceParameterSet{d.parameters.sps}
		pps := [1]vk.VideoH264PictureParameterSet{d.parameters.pps}
		params := Decode_Parameters {
			h264_sps = sps[:],
			h264_pps = pps[:],
		}
		if err := set_decoder_parameters(&d.backend, &params); err != .None do return err
		d.parameters_dirty = false
		d.active_pps = p.pic_parameter_set_id
	}
	return .None
}

@(private)
h264_finish_picture :: proc(d: ^H264_Decoder, receiver: H264_Receiver, user: rawptr) -> Error {
	state := &d.syntax
	if state.curr == nil do return .None
	s := &state.sequence_parameters[state.current_sequence_parameter_set_id]
	p := &state.picture_parameters[state.current_picture_parameter_set_id]
	header := &state.prev_slice
	if err := h264_ensure_backend(d, s, p, header.is_idr, receiver, user); err != .None do return err
	refs: [16]Decode_Reference
	used: [17]bool
	count := 0
	if !header.is_idr {
		for &pic, i in state.pics {
			if &pic == state.curr || !pic.in_use || (!pic.is_short_ref && !pic.is_long_ref) do continue
			if pic.non_existing || d.gpu_slots[i] < 0 || d.gpu_pic_ids[i] != pic.pic_id || count >= len(refs) do return .Unsupported
			slot := d.gpu_slots[i]
			if slot >= d.backend.config.dpb_slots || used[slot] do return .Unsupported
			used[slot] = true
			frame_num := pic.is_long_ref ? pic.long_term_frame_idx : pic.frame_num
			if frame_num < 0 || frame_num > i32(max(u16)) do return .Unsupported
			refs[count] = {
				slot = slot,
				h264 = {FrameNum = u16(frame_num), PicOrderCnt = pic.field_order_counts},
			}
			if pic.is_long_ref do refs[count].h264.flags += {.used_for_long_term_reference}
			count += 1
		}
	}
	setup := -1
	for taken, i in used[:d.backend.config.dpb_slots] do if !taken {setup = i; break}
	if setup < 0 do return .Unsupported
	picture := Decode_Picture {
		setup_slot    = setup,
		slice_offsets = d.slice_offsets[:],
		references    = refs[:count],
		reset         = header.is_idr,
	}
	picture.h264 = {
		seq_parameter_set_id = u8(s.sequence_parameter_set_id),
		pic_parameter_set_id = u8(p.pic_parameter_set_id),
		frame_num            = u16(header.frame_num),
		idr_pic_id           = u16(header.idr_pic_id),
		PicOrderCnt          = state.curr.field_order_counts,
	}
	if header.is_idr do picture.h264.flags += {.IdrPicFlag}
	if header.nal_ref_idc != 0 do picture.h264.flags += {.is_reference}
	if d.all_intra do picture.h264.flags += {.is_intra}
	// The decode picture uses its original syntax counts. The reconstructed
	// reference uses the shared marking result (including MMCO5/6).
	avcd.finish_picture_marking(state, s, header)
	stored_frame_num :=
		state.curr.is_long_ref ? state.curr.long_term_frame_idx : state.curr.frame_num
	if stored_frame_num < 0 || stored_frame_num > i32(max(u16)) do return .Unsupported
	picture.h264_setup = {
		FrameNum    = u16(stored_frame_num),
		PicOrderCnt = state.curr.field_order_counts,
	}
	if state.curr.is_long_ref do picture.h264_setup.flags += {.used_for_long_term_reference}
	decoded, ready, err := decode_picture(&d.backend, d.packet[:], picture)
	if err != .None do return err
	i := h264_picture_index(d, state.curr)
	if i < 0 do return .Invalid_Argument
	d.gpu_slots[i], d.gpu_pic_ids[i] = setup, state.curr.pic_id
	coded_width, coded_height := d.backend.config.width, d.backend.config.height
	append(&d.in_flight, H264_Queued_Frame {
		pic_id = state.curr.pic_id,
		frame = {
			width = s.width,
			height = s.height,
			bit_depth = 8,
			coded_width = coded_width,
			coded_height = coded_height,
			crop_x = int(s.crop_left) * 2,
			crop_y = int(s.crop_top) * 2,
		},
	})
	h264_take_display(d)
	if ready do h264_receive(d, decoded, receiver, user)
	state.curr = nil
	state.have_prev_slice = false
	clear(&d.packet)
	clear(&d.slice_offsets)
	h264_emit(d, receiver, user)
	return .None
}

decode_h264_nal :: proc(
	d: ^H264_Decoder,
	data: []u8,
	receiver: H264_Receiver,
	user: rawptr,
) -> (
	err: Error,
) {
	if d == nil || !d.initialized || d.failed do return .Invalid_Argument
	defer if err != .None && err != .Busy do d.failed = true
	if len(data) < 1 || data[0] & 0x80 != 0 do return .Invalid_Argument
	nal_type := avc.Nal_Unit_Type(data[0] & 31)
	nal_ref := (data[0] >> 5) & 3
	state := &d.syntax
	rbsp := avc.unescape_rbsp_into_buffer(data[1:], &state.rbsp_buffer)
	reader := avc.init_bit_reader(rbsp)
	#partial switch nal_type {
	case .Sequence_Parameter_Set, .Picture_Parameter_Set:
		if err = h264_finish_picture(d, receiver, user); err != .None do return
		if nal_type == .Sequence_Parameter_Set {
			value, ok := avcd.parse_sequence_parameter_set(&reader)
			if !ok do return .Invalid_Argument
			if avcd.sequence_parameter_set_error(&value) != .None ||
			   (value.profile != .Baseline &&
					   value.profile != .Main &&
					   value.profile != .High) {return .Unsupported}
			state.sequence_parameters[value.sequence_parameter_set_id] = value
			state.sequence_parameter_set_valid[value.sequence_parameter_set_id] = true
		} else {
			value, ok := avcd.parse_picture_parameter_set(&reader, state)
			if !ok do return .Invalid_Argument
			if avcd.picture_parameter_set_error(&value) != .None do return .Unsupported
			state.picture_parameters[value.pic_parameter_set_id] = value
			state.picture_parameter_set_valid[value.pic_parameter_set_id] = true
		}
		d.parameters_dirty = true
		return .None
	case .End_Of_Seq, .End_Of_Stream:
		return flush_h264_decoder(d, receiver, user)
	case .Slice_IDR, .Slice_Non_IDR:
	case .Slice_DPA, .Slice_DPB, .Slice_DPC:
		return .Unsupported
	case:
		return .None
	}
	header, ok := avcd.parse_slice_header(&reader, nal_type, nal_ref, state)
	if !ok do return .Invalid_Argument
	if header.is_idr && header.idr_pic_id > u32(max(u16)) do return .Invalid_Argument
	s := &state.sequence_parameters[state.active_sequence_parameter_set_id]
	p := &state.picture_parameters[state.active_picture_parameter_set_id]
	if avcd.sequence_parameter_set_error(s) != .None ||
	   avcd.picture_parameter_set_error(p) != .None ||
	   header.slice_type == .SP ||
	   header.slice_type == .SI {return .Unsupported}
	if header.redundant_pic_cnt > 0 do return .None
	if avcd.starts_new_picture(state, &header, s) {
		if err = h264_finish_picture(d, receiver, user); err != .None do return
		if !d.seen_picture && !header.is_idr do return .Unsupported
		d.seen_picture = true
		avcd.release_unused_pictures(state)
		avcd.activate_sequence_parameter_set_metadata(state, s)
		if s.max_reference_frames > 16 || state.dpb_size > 16 do return .Unsupported
		if header.slice_type == .B && state.max_reorder == 0 && !state.no_reordering do state.max_reorder = state.dpb_size
		if d.config.output_storage == .Device && state.max_reorder != 0 do return .Unsupported
		if _, reason := avcd.start_picture_metadata(state, s, &header); reason != .None do return .Unsupported
		state.current_sequence_parameter_set_id = state.active_sequence_parameter_set_id
		state.current_picture_parameter_set_id = state.active_picture_parameter_set_id
		d.all_intra = true
	}
	state.slice, state.prev_slice, state.have_prev_slice = header, header, true
	d.all_intra = d.all_intra && header.slice_type == .I
	if !avcd.build_ref_lists(state, s, &header) do return .Unsupported
	for l in 0 ..< 2 do for pic in state.ref_list[l][:state.ref_count[l]] do if pic == nil || pic.non_existing do return .Unsupported
	limit := d.config.max_packet_bytes
	if limit == 0 do limit = 128 * 1024 * 1024
	if len(data) + 3 > limit - len(d.packet) do return .Output_Overflow
	append(&d.slice_offsets, u32(len(d.packet)))
	append(&d.packet, u8(0), u8(0), u8(1))
	append(&d.packet, ..data)
	return .None
}

flush_h264_decoder :: proc(
	d: ^H264_Decoder,
	receiver: H264_Receiver,
	user: rawptr,
) -> (
	err: Error,
) {
	if d == nil || !d.initialized || d.failed do return .Invalid_Argument
	defer if err != .None && err != .Busy do d.failed = true
	if err = h264_finish_picture(d, receiver, user); err != .None do return
	avcd.flush_output(&d.syntax)
	h264_take_display(d)
	if err = h264_drain_backend(d, receiver, user); err != .None do return
	h264_emit(d, receiver, user)
	return .None
}

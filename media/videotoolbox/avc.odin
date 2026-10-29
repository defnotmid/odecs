package media_videotoolbox

import avc "../../video/h264"
import avcd "../../video/h264/decoder"

// Parsing, POC, reference marking and display order use the native AVC
// decoder's metadata path; VideoToolbox decodes each assembled picture.
// Do not move an initialized decoder: its session is VideoToolbox's
// callback context.
H264_Decoder :: struct {
	pictures:                          Pictures,
	syntax:                            avcd.Decoder_State,
	// Parameter set NAL units as received, for the format description.
	sps_nal:                           [32][dynamic]u8,
	pps_nal:                           [256][dynamic]u8,
	format_sps:                        int, // the SPS the session's format describes
	format_dirty:                      bool,
	display:                           [dynamic]H264_Display, // pictures the parser has released, in display order
	seen_picture, initialized, failed: bool,
}
@(private)
H264_Display :: struct {
	pic_id: i32,
	poc:    i32,
}

// no_reordering: the caller asserts that presentation order is decode order.
init_h264_decoder :: proc(d: ^H264_Decoder, no_reordering := false, require_hardware := false) -> Error {
	if d == nil || d.initialized do return .Invalid_Argument
	when ODIN_OS != .Darwin do return .Unavailable
	if require_hardware && !hardware_decode_supported(.H264) do return .Unavailable
	d^ = {
		pictures     = {session = {require_hardware = require_hardware}},
		initialized  = true,
		format_dirty = true,
	}
	avcd.init_decoder(&d.syntax)
	d.syntax.no_reordering = no_reordering
	return .None
}

destroy_h264_decoder :: proc(d: ^H264_Decoder) {
	if d == nil || !d.initialized do return
	destroy_pictures(&d.pictures)
	avcd.destroy_decoder(&d.syntax)
	for nal in d.sps_nal do delete(nal)
	for nal in d.pps_nal do delete(nal)
	delete(d.display)
	d^ = {}
}

decode_h264_nal :: proc(d: ^H264_Decoder, data: []u8, receiver: Receiver, user: rawptr) -> (err: Error) {
	if d == nil || !d.initialized || d.failed do return .Invalid_Argument
	defer if err != .None do d.failed = true
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
			if avcd.sequence_parameter_set_error(&value) != .None || (value.profile != .Baseline && value.profile != .Main && value.profile != .High) do return .Unsupported
			id := value.sequence_parameter_set_id
			state.sequence_parameters[id], state.sequence_parameter_set_valid[id] = value, true
			if !uncropped_sps(data, .H264, &d.sps_nal[id]) do return .Invalid_Argument
		} else {
			value, ok := avcd.parse_picture_parameter_set(&reader, state)
			if !ok do return .Invalid_Argument
			if avcd.picture_parameter_set_error(&value) != .None do return .Unsupported
			id := value.pic_parameter_set_id
			state.picture_parameters[id], state.picture_parameter_set_valid[id] = value, true
			replace(&d.pps_nal[id], data)
		}
		d.format_dirty = true
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
	s := &state.sequence_parameters[state.active_sequence_parameter_set_id]
	p := &state.picture_parameters[state.active_picture_parameter_set_id]
	if avcd.sequence_parameter_set_error(s) != .None || avcd.picture_parameter_set_error(p) != .None || header.slice_type == .SP || header.slice_type == .SI do return .Unsupported
	if header.redundant_pic_cnt > 0 do return .None
	if avcd.starts_new_picture(state, &header, s) {
		if err = h264_finish_picture(d, receiver, user); err != .None do return
		if !d.seen_picture && !header.is_idr do return .Unsupported
		d.seen_picture = true
		avcd.release_unused_pictures(state)
		avcd.activate_sequence_parameter_set_metadata(state, s)
		if header.slice_type == .B && state.max_reorder == 0 && !state.no_reordering do state.max_reorder = state.dpb_size
		if _, reason := avcd.start_picture_metadata(state, s, &header); reason != .None do return .Unsupported
		state.current_sequence_parameter_set_id = state.active_sequence_parameter_set_id
		state.current_picture_parameter_set_id = state.active_picture_parameter_set_id
	}
	state.slice, state.prev_slice, state.have_prev_slice = header, header, true
	// The lists themselves are VideoToolbox's business, but building them
	// updates each reference's FrameNumWrap, which marking's sliding window
	// reads: without it the wrong reference goes and pictures leave early.
	avcd.build_ref_lists(state, s, &header)
	return append_nal(&d.pictures, data)
}

// Shows every picture still waiting, at the end of the stream.
flush_h264_decoder :: proc(d: ^H264_Decoder, receiver: Receiver, user: rawptr) -> (err: Error) {
	if d == nil || !d.initialized || d.failed do return .Invalid_Argument
	defer if err != .None do d.failed = true
	if err = h264_finish_picture(d, receiver, user); err != .None do return
	avcd.flush_output(&d.syntax)
	h264_show(d, receiver, user)
	return .None
}

@(private)
replace :: proc(stored: ^[dynamic]u8, data: []u8) {
	clear(stored)
	append(stored, ..data)
}

// Points the session at the current SPS and every PPS that refers to it.
@(private)
h264_update_format :: proc(d: ^H264_Decoder) -> Error {
	sps := d.syntax.current_sequence_parameter_set_id
	if !d.format_dirty && d.format_sps == sps do return .None
	sets: [MAX_PARAMETER_SETS][]u8
	sets[0] = d.sps_nal[sps][:]
	n := 1
	for valid, id in d.syntax.picture_parameter_set_valid {
		if !valid || int(d.syntax.picture_parameters[id].sequence_parameter_set_id) != sps do continue
		sets[n] = d.pps_nal[id][:]
		n += 1
	}
	if err := session_set_format(&d.pictures.session, .H264, sets[:n], 8, d.syntax.sequence_parameters[sps].video_full_range); err != .None do return err
	d.format_sps, d.format_dirty = sps, false
	return .None
}

@(private)
h264_finish_picture :: proc(d: ^H264_Decoder, receiver: Receiver, user: rawptr) -> Error {
	state := &d.syntax
	if state.curr == nil do return .None
	s := &state.sequence_parameters[state.current_sequence_parameter_set_id]
	if err := h264_update_format(d); err != .None do return err
	avcd.finish_picture_marking(state, s, &state.prev_slice)
	frame := Frame {
		width        = s.width,
		height       = s.height,
		bit_depth    = 8,
		storage_bits = 8,
		coded_width  = s.macroblock_columns * 16,
		coded_height = s.macroblock_rows * 16,
		crop_x       = int(s.crop_left) * 2,
		crop_y       = int(s.crop_top) * 2,
	}
	pic_id := state.curr.pic_id
	state.curr = nil
	state.have_prev_slice = false
	if err := decode_picture(&d.pictures, frame, i64(pic_id)); err != .None do return err
	h264_show(d, receiver, user)
	return .None
}

// Shows held pictures while the next in display order has been decoded,
// and drops those the parser will never show (an IDR can discard them).
@(private)
h264_show :: proc(d: ^H264_Decoder, receiver: Receiver, user: rawptr) {
	for {
		pic := avcd.next_output_frame(&d.syntax)
		if pic == nil do break
		append(&d.display, H264_Display{pic.pic_id, pic.poc})
	}
	p := &d.pictures
	outer: for len(d.display) > 0 {
		for &h, i in p.held {
			if i64(d.display[0].pic_id) != h.id do continue
			h.frame.poc = int(d.display[0].poc)
			ordered_remove(&d.display, 0)
			show(p, i, receiver, user)
			continue outer
		}
		break
	}
	for i := 0; i < len(p.held); {
		if h264_awaited(d, i32(p.held[i].id)) {i += 1} else {discard(p, i)}
	}
}

@(private)
h264_awaited :: proc(d: ^H264_Decoder, pic_id: i32) -> bool {
	for e in d.display do if e.pic_id == pic_id do return true
	for &pic in d.syntax.pics do if pic.in_use && pic.pic_id == pic_id && pic.needed_for_output do return true
	return false
}

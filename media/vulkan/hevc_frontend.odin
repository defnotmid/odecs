package media_vulkan

import hevc "../../h265/decoder"
import "core:slice"
import vk "vendor:vulkan"

H265_Decoder_Config :: struct {
	shared_context:           ^Context, // optional shared device, held until this frontend is destroyed
	device_index:             int,
	width, height, bit_depth: int, // zero accepts the stream's value
	profile_idc:              int, // zero accepts the native parser's source profile
	max_packet_bytes:         int, // zero admits up to 128 MiB per coded picture
	output_storage:           Output_Storage,
}
H265_Receiver :: proc(frame: H265_Frame, user: rawptr)

// A returned picture held, as a host copy, until its turn in display order.
@(private)
H265_Queued_Frame :: struct {
	frame:  H265_Frame,
	planes: [3][]u8,
	id:     i64,
}
// A submitted picture until the hardware returns it.
@(private)
H265_Pending :: struct {
	frame: H265_Frame, // without planes or surface
	id:    i64,
}
// A picture in the decoded picture buffer as C.5.2 models it in decode
// order: the model decides display order, and the samples follow when the
// hardware returns them. Pictures go by a decode counter, since POCs restart.
@(private)
H265_Entry :: struct {
	id:                i64,
	poc:               i32,
	reference, output: bool, // still referenced; waiting for output
	latency:           int, // pictures decoded since, while it waits
}
@(private)
H265_Slot :: struct {
	poc:             i32,
	live, long_term: bool,
}

// Syntax, POC and reference-set derivation use the native HEVC owners. This
// frontend assembles pictures, associates their POCs with GPU slots, and
// orders output by the bumping process of C.5.2.
// Outputs borrow callback storage; consume or copy before returning.
H265_Decoder :: struct {
	config:                                                    H265_Decoder_Config,
	backend:                                                   Decoder,
	syntax:                                                    hevc.Nal_Scratch,
	vps:                                                       [16]hevc.VPS,
	sps:                                                       [16]hevc.SPS,
	pps:                                                       [64]hevc.PPS,
	has_vps:                                                   [16]bool,
	has_sps:                                                   [16]bool,
	has_pps:                                                   [64]bool,
	parameters:                                                H265_Parameter_Storage,
	parameters_dirty:                                          bool,
	active_pps:                                                u32,
	pending:                                                   hevc.Slice_Header,
	pending_type:                                              hevc.Nal_Type,
	pending_temporal_id:                                       u8,
	packet:                                                    [dynamic]u8,
	slice_offsets:                                             [dynamic]u32,
	slots:                                                     [16]H265_Slot,
	held:                                                      [dynamic]H265_Queued_Frame,
	in_flight:                                                 [dynamic]H265_Pending, // submitted, in order
	dpb:                                                       [dynamic]H265_Entry,
	display:                                                   [dynamic]i64, // ids the model has output, not yet shown
	next_id:                                                   i64,
	// The active SPS's max_num_reorder_pics, max_latency_increase_plus1, max_dec_pic_buffering + 1.
	max_reorder, max_latency, max_dpb:                         int,
	poc:                                                       hevc.Poc_State,
	seen_picture, skip_rasl, has_pending, initialized, failed: bool,
}

init_h265_decoder :: proc(d: ^H265_Decoder, config: H265_Decoder_Config) -> Error {
	if d == nil || d.initialized || config.width < 0 || config.height < 0 || config.max_packet_bytes < 0 do return .Invalid_Argument
	if config.bit_depth != 0 && config.bit_depth != 8 && config.bit_depth != 10 do return .Unsupported
	if config.profile_idc != 0 && config.profile_idc != 1 && config.profile_idc != 2 do return .Unsupported
	if config.shared_context != nil {
		if err := retain_context(config.shared_context); err != .None do return err
	}
	d^ = {
		config           = config,
		initialized      = true,
		parameters_dirty = true,
	}
	return .None
}

@(private)
h265_free_queued :: proc(q: ^H265_Queued_Frame) {
	for plane in q.planes do delete(plane)
	q^ = {}
}

destroy_h265_decoder :: proc(d: ^H265_Decoder) {
	if d == nil do return
	if d.has_pending do hevc.destroy_slice_header(&d.pending)
	for &s, i in d.sps do if d.has_sps[i] do hevc.destroy_sps(&s)
	for &p, i in d.pps do if d.has_pps[i] do hevc.destroy_pps(&p)
	for &q in d.held do h265_free_queued(&q)
	delete(d.held)
	delete(d.in_flight)
	delete(d.dpb)
	delete(d.display)
	delete(d.packet)
	delete(d.slice_offsets)
	hevc.destroy_nal_scratch(&d.syntax)
	destroy_decoder(&d.backend)
	if d.initialized && d.config.shared_context != nil do release_context(d.config.shared_context)
	d^ = {}
}

// C.5.2.4: outputs the waiting picture with the lowest POC, to the display queue.
@(private)
h265_bump :: proc(d: ^H265_Decoder) -> bool {
	best := -1
	for e, i in d.dpb do if e.output && (best < 0 || e.poc < d.dpb[best].poc) do best = i
	if best < 0 do return false
	d.dpb[best].output = false
	append(&d.display, d.dpb[best].id)
	h265_remove_unused(d)
	return true
}

@(private)
h265_remove_unused :: proc(d: ^H265_Decoder) {
	kept := 0
	for e in d.dpb {
		if !e.reference && !e.output do continue
		d.dpb[kept] = e
		kept += 1
	}
	resize(&d.dpb, kept)
}

// The bumping condition of C.5.2.2 (with the buffer's size) and C.5.2.3.
@(private)
h265_full :: proc(d: ^H265_Decoder, include_buffering: bool) -> bool {
	waiting := 0
	for e in d.dpb {
		if !e.output do continue
		waiting += 1
		if d.max_latency != 0 && e.latency >= d.max_reorder + d.max_latency - 1 do return true
	}
	return waiting > d.max_reorder || include_buffering && len(d.dpb) >= d.max_dpb
}

// Whether a picture will still be shown: queued for display, or waiting in the model.
@(private)
h265_awaited :: proc(d: ^H265_Decoder, id: i64) -> bool {
	for e in d.display do if e == id do return true
	for e in d.dpb do if e.id == id && e.output do return true
	return false
}

// Shows held pictures while the next in display order is held, and drops
// those the model will never show.
@(private)
h265_emit :: proc(d: ^H265_Decoder, receiver: H265_Receiver, user: rawptr) {
	outer: for len(d.display) > 0 {
		for &q, i in d.held {
			if q.id != d.display[0] do continue
			ordered_remove(&d.display, 0)
			if receiver != nil do receiver(q.frame, user)
			h265_free_queued(&q)
			ordered_remove(&d.held, i)
			continue outer
		}
		break
	}
	for i := 0; i < len(d.held); {
		if h265_awaited(d, d.held[i].id) {i += 1; continue}
		h265_free_queued(&d.held[i])
		ordered_remove(&d.held, i)
	}
}

@(private)
h265_slot :: proc(d: ^H265_Decoder, poc: i32) -> int {
	for entry, i in d.slots do if entry.live && entry.poc == poc do return i
	return -1
}

@(private)
h265_resolve_long_term :: proc(d: ^H265_Decoder, r: ^hevc.Ref_Pic_Set, log2_lsb: u8) -> Error {
	available: [16]i32
	count := 0
	for entry in d.slots do if entry.live {available[count] = entry.poc; count += 1}
	// Best effort, as in the native decoder: an entry that stays unresolved is
	// missing, which matters only if this picture uses it.
	hevc.resolve_long_term_ref_pocs(r, available[:count], log2_lsb)
	return .None
}

@(private)
h265_ensure_backend :: proc(
	d: ^H265_Decoder,
	v: ^hevc.VPS,
	s: ^hevc.SPS,
	p: ^hevc.PPS,
	reset: bool,
) -> Error {
	w, h, depth :=
		int(s.pic_width_in_luma_samples), int(s.pic_height_in_luma_samples), int(s.bit_depth_luma)
	// The SPS bound includes the current reconstruction as well as references.
	slots := int(s.max_dec_pic_buffering) + 1
	if slots < 1 || slots > len(d.slots) do return .Unsupported
	if (d.config.width != 0 && d.config.width != int(hevc.sps_cropped_width(s))) ||
	   (d.config.height != 0 && d.config.height != int(hevc.sps_cropped_height(s))) ||
	   (d.config.bit_depth != 0 && d.config.bit_depth != depth) ||
	   (d.config.profile_idc != 0 &&
			   d.config.profile_idc != int(s.ptl.profile_idc)) {return .Unsupported}
	// A borrowed output surface cannot wait through later readbacks for B
	// picture reordering. Host output owns those delayed pictures explicitly.
	if d.config.output_storage == .Device && s.max_num_reorder_pics != 0 do return .Unsupported
	if d.backend.initialized &&
	   (d.backend.config.width != w ||
			   d.backend.config.height != h ||
			   d.backend.config.bit_depth != depth ||
			   d.backend.config.profile_idc != int(s.ptl.profile_idc) ||
			   d.backend.config.dpb_slots != slots) {
		// Device consumers may retain pipelines on the exported VkDevice for
		// the decoder's lifetime. Require a new decoder for resource changes.
		if d.config.output_storage == .Device do return .Unsupported
		if !reset do return .Unsupported
		destroy_decoder(&d.backend)
		d.parameters_dirty = true
	}
	if !d.backend.initialized {
		limit := d.config.max_packet_bytes
		if limit == 0 do limit = 128 * 1024 * 1024
		config := Decoder_Config {
			codec            = .H265,
			width            = w,
			height           = h,
			bit_depth        = depth,
			profile_idc      = int(s.ptl.profile_idc),
			dpb_slots        = slots,
			max_references   = slots - 1,
			device_index     = d.config.device_index,
			max_packet_bytes = limit,
			output_storage   = d.config.output_storage,
			shared_context   = d.config.shared_context,
		}
		if err := init_decoder(&d.backend, config); err != .None do return err
	}
	if d.parameters_dirty || d.active_pps != p.id {
		if err := map_h265_parameters(&d.parameters, v, s, p); err != .None do return err
		vps := [1]vk.VideoH265VideoParameterSet{d.parameters.vps}
		sps := [1]vk.VideoH265SequenceParameterSet{d.parameters.sps}
		pps := [1]vk.VideoH265PictureParameterSet{d.parameters.pps}
		params := Decode_Parameters {
			h265_vps = vps[:],
			h265_sps = sps[:],
			h265_pps = pps[:],
		}
		if err := set_decoder_parameters(&d.backend, &params); err != .None do return err
		d.parameters_dirty = false
		d.active_pps = p.id
	}
	return .None
}

@(private)
h265_finish_picture :: proc(d: ^H265_Decoder, receiver: H265_Receiver, user: rawptr) -> Error {
	if !d.has_pending do return .None
	header := &d.pending
	p := &d.pps[header.pps_id]
	s := &d.sps[p.sps_id]
	v := &d.vps[s.vps_id]
	d.max_reorder, d.max_latency, d.max_dpb = int(s.max_num_reorder_pics), int(s.max_latency_increase), int(s.max_dec_pic_buffering) + 1
	no_rasl := hevc.nal_type_is_irap(d.pending_type) && d.skip_rasl
	if no_rasl {
		// Pictures still on the GPU belong before the reset.
		if err := h265_drain_backend(d, receiver, user); err != .None do return err
		// C.5.2.2: a random access point that starts decoding either releases
		// the buffer or outputs all of it first; a CRA always releases.
		if !header.no_output_of_prior_pics && d.pending_type != .CRA_NUT do for h265_bump(d) {}
		clear(&d.dpb)
		h265_emit(d, receiver, user)
		d.slots = {}
		d.poc = {}
	}
	poc := hevc.derive_poc(
		&d.poc,
		d.pending_type,
		i32(header.pic_order_cnt_lsb),
		s.log2_max_poc_lsb,
		no_rasl,
	)
	rps := hevc.derive_ref_pic_set(
		poc,
		s.log2_max_poc_lsb,
		&header.st_rps,
		&header.lt_rps,
		header.lt_rps.num_sps,
	)
	defer hevc.destroy_ref_pic_set(&rps)
	if err := h265_resolve_long_term(d, &rps, s.log2_max_poc_lsb); err != .None do return err
	keep: [16]bool
	groups := [5]([]i32) {
		rps.st_curr_before[:],
		rps.st_curr_after[:],
		rps.lt_curr[:],
		rps.st_foll[:],
		rps.lt_foll[:],
	}
	for group, g in groups do for ref_poc in group {
		slot := h265_slot(d, ref_poc)
		if slot < 0 {
			// 8.3.3: after a random access point, the Foll sets may name pictures
			// that were never decoded; this picture does not use them, and no
			// picture that would is decoded. One this picture uses is missing.
			if g >= 3 do continue
			return .Unsupported
		}
		keep[slot] = true
	}
	for &entry, slot in d.slots {
		entry.live = keep[slot]
		entry.long_term = false
	}
	for group in ([2]([]i32){rps.lt_curr[:], rps.lt_foll[:]}) do for ref_poc in group {
		if slot := h265_slot(d, ref_poc); slot >= 0 do d.slots[slot].long_term = true
	}
	if !no_rasl {
		// C.5.2.2: the reference picture set decides what the buffer keeps, and
		// it outputs while it is too full to take this picture.
		for &e in d.dpb {
			e.reference = false
			for group in groups do for ref_poc in group do if ref_poc == e.poc do e.reference = true
		}
		h265_remove_unused(d)
		for h265_full(d, true) do if !h265_bump(d) do break
		h265_emit(d, receiver, user)
	}
	if err := h265_ensure_backend(d, v, s, p, no_rasl); err != .None do return err
	setup := -1
	for entry, slot in d.slots[:d.backend.config.dpb_slots] do if !entry.live {setup = slot; break}
	if setup < 0 do return .Unsupported
	// No session reset at a random access point: the references it ends are
	// simply no longer bound. (A reset before a BLA picture leaves RADV
	// decoding nothing from then on; the session resets once, at first use.)
	picture := Decode_Picture {
		setup_slot    = setup,
		slice_offsets = d.slice_offsets[:],
	}
	picture.h265 = {
		sps_video_parameter_set_id = s.vps_id,
		pps_seq_parameter_set_id   = u8(s.id),
		pps_pic_parameter_set_id   = u8(p.id),
		PicOrderCntVal             = poc,
	}
	for &slot in picture.h265.RefPicSetStCurrBefore do slot = 0xff
	for &slot in picture.h265.RefPicSetStCurrAfter do slot = 0xff
	for &slot in picture.h265.RefPicSetLtCurr do slot = 0xff
	if hevc.nal_type_is_irap(d.pending_type) do picture.h265.flags += {.IrapPicFlag}
	if hevc.nal_type_is_idr(d.pending_type) do picture.h265.flags += {.IdrPicFlag}
	is_reference := !hevc.is_sub_layer_non_ref(d.pending_type)
	if is_reference do picture.h265.flags += {.IsReference}
	if header.st_rps_from_sps {
		picture.h265.flags += {.short_term_ref_pic_set_sps_flag}
		picture.h265.NumDeltaPocsOfRefRpsIdx = header.st_rps.ref_delta_poc_count
	} else {
		if header.st_rps_num_bits > int(max(u16)) do return .Unsupported
		picture.h265.NumBitsForSTRefPicSetInSlice = u16(header.st_rps_num_bits)
	}
	if hevc.ref_pic_set_num_poc_total_curr(&rps) > d.backend.config.max_references do return .Unsupported
	std_groups := [3]([]u8) {
		picture.h265.RefPicSetStCurrBefore[:],
		picture.h265.RefPicSetStCurrAfter[:],
		picture.h265.RefPicSetLtCurr[:],
	}
	for group, i in groups[:3] {
		if len(group) > len(std_groups[i]) do return .Unsupported
		for ref_poc, j in group do std_groups[i][j] = u8(h265_slot(d, ref_poc))
	}
	// Every picture the RPS keeps is bound, those only later pictures use
	// (the Foll sets) included: RADV's firmware loses what an unbound slot
	// held, and the leading pictures of a CRA reference pictures the CRA
	// itself does not.
	references: [16]Decode_Reference
	ref_count := 0
	for entry, slot in d.slots {
		if !entry.live do continue
		if ref_count >= d.backend.config.max_references do return .Unsupported
		references[ref_count] = {
			slot = slot,
			h265 = {PicOrderCntVal = entry.poc},
		}
		if entry.long_term do references[ref_count].h265.flags += {.used_for_long_term_reference}
		ref_count += 1
	}
	picture.references = references[:ref_count]
	decoded, ready, err := decode_picture(&d.backend, d.packet[:], picture)
	if err != .None do return err
	d.slots[setup] = {
		poc  = poc,
		live = is_reference,
	}
	hevc.poc_state_update(
		&d.poc,
		d.pending_type,
		d.pending_temporal_id,
		poc,
		i32(header.pic_order_cnt_lsb),
		s.log2_max_poc_lsb,
	)
	coded_width, coded_height := d.backend.config.width, d.backend.config.height
	id := d.next_id
	d.next_id += 1
	append(&d.in_flight, H265_Pending {
		id = id,
		frame = {
			width = int(hevc.sps_cropped_width(s)),
			height = int(hevc.sps_cropped_height(s)),
			bit_depth = d.backend.config.bit_depth,
			coded_width = coded_width,
			coded_height = coded_height,
			poc = int(poc),
			crop_x = int(s.conf_win_left) * 2,
			crop_y = int(s.conf_win_top) * 2,
		},
	})
	// C.5.2.3: store the picture, then output what the limits no longer let wait.
	output := header.pic_output_flag
	if output do for &e in d.dpb do if e.output do e.latency += 1
	append(&d.dpb, H265_Entry{id = id, poc = poc, reference = true, output = output})
	for h265_full(d, false) do if !h265_bump(d) do break
	if ready do h265_receive(d, decoded, receiver, user)
	h265_emit(d, receiver, user)
	hevc.destroy_slice_header(&d.pending)
	d.has_pending = false
	clear(&d.packet)
	clear(&d.slice_offsets)
	return .None
}

// A picture back from the hardware, the oldest submitted: shown now when it
// is next in display order, copied and held while it is still awaited, and
// dropped otherwise.
@(private)
h265_receive :: proc(d: ^H265_Decoder, decoded: Decoder_Frame, receiver: H265_Receiver, user: rawptr) {
	h265_emit(d, receiver, user) // held pictures due before this one
	p := d.in_flight[0]
	ordered_remove(&d.in_flight, 0)
	frame := p.frame
	frame.surface, frame.storage_bits, frame.strides = decoded.surface, decoded.storage_bits, decoded.strides
	crop_planes(&frame, decoded.planes)
	if len(d.display) > 0 && d.display[0] == p.id {
		ordered_remove(&d.display, 0)
		if receiver != nil do receiver(frame, user)
		return
	}
	if !h265_awaited(d, p.id) do return
	q := H265_Queued_Frame {
		frame = frame,
		id    = p.id,
	}
	for plane, i in decoded.planes do q.planes[i] = slice.clone(plane)
	crop_planes(&q.frame, q.planes)
	q.frame.surface = {} // the queued host copy has no retained device surface
	append(&d.held, q)
}

// Receives every picture still in flight.
@(private)
h265_drain_backend :: proc(d: ^H265_Decoder, receiver: H265_Receiver, user: rawptr) -> Error {
	if !d.backend.initialized do return .None
	for {
		decoded, ready, err := finish_decoder(&d.backend)
		if err != .None do return err
		if !ready do return .None
		h265_receive(d, decoded, receiver, user)
	}
}

decode_h265_nal :: proc(
	d: ^H265_Decoder,
	data: []u8,
	receiver: H265_Receiver,
	user: rawptr,
) -> (
	err: Error,
) {
	if d == nil || !d.initialized || d.failed do return .Invalid_Argument
	defer if err != .None && err != .Busy do d.failed = true
	nal, ok := hevc.parse_nal_into(data, &d.syntax)
	if !ok || nal.layer_id != 0 do return .Invalid_Argument
	#partial switch nal.type {
	case .VPS_NUT, .SPS_NUT, .PPS_NUT:
		if err = h265_finish_picture(d, receiver, user); err != .None do return
		#partial switch nal.type {
		case .VPS_NUT:
			value, good := hevc.parse_vps(nal.rbsp)
			if !good do return .Invalid_Argument
			d.vps[value.id], d.has_vps[value.id] = value, true
		case .SPS_NUT:
			value, good := hevc.parse_sps(nal.rbsp)
			if !good do return .Invalid_Argument
			if d.has_sps[value.id] do hevc.destroy_sps(&d.sps[value.id])
			d.sps[value.id], d.has_sps[value.id] = value, true
		case .PPS_NUT:
			value, good := hevc.parse_pps(nal.rbsp)
			if !good do return .Invalid_Argument
			if d.has_pps[value.id] do hevc.destroy_pps(&d.pps[value.id])
			d.pps[value.id], d.has_pps[value.id] = value, true
		}
		d.parameters_dirty = true
		return .None
	case .EOS_NUT, .EOB_NUT:
		// The next picture starts afresh (8.1.3): a random access point with
		// NoRaslOutputFlag, whose C.5.2.2 rules decide what still waiting is shown.
		if err = h265_finish_picture(d, receiver, user); err != .None do return
		d.seen_picture = false
		return .None
	case .AUD_NUT:
		return h265_finish_picture(d, receiver, user)
	case:
	}
	if !hevc.nal_type_is_vcl(nal.type) do return .None
	pps_id, good := hevc.peek_pps_id(nal)
	if !good || pps_id >= len(d.pps) || !d.has_pps[pps_id] do return .Invalid_Argument
	p := &d.pps[pps_id]
	if !d.has_sps[p.sps_id] do return .Invalid_Argument
	s := &d.sps[p.sps_id]
	if !d.has_vps[s.vps_id] do return .Invalid_Argument
	if !hevc.pps_resolve_tile_geometry(p, s) do return .Invalid_Argument
	header, good_header := hevc.parse_slice_header(nal.rbsp, nal.type, s, p)
	if !good_header do return .Invalid_Argument
	if header.first_slice_segment_in_pic {
		if err = h265_finish_picture(d, receiver, user);
		   err != .None {hevc.destroy_slice_header(&header); return}
		if !d.seen_picture &&
		   !hevc.nal_type_is_irap(
				   nal.type,
			   ) {hevc.destroy_slice_header(&header); return .Unsupported}
		if hevc.nal_type_is_irap(nal.type) do d.skip_rasl = !d.seen_picture || hevc.nal_type_is_idr(nal.type) || (nal.type >= .BLA_W_LP && nal.type <= .BLA_N_LP)
		d.seen_picture = true
		if d.skip_rasl &&
		   (nal.type == .RASL_N ||
				   nal.type == .RASL_R) {hevc.destroy_slice_header(&header); return .None}
		d.pending, d.pending_type, d.pending_temporal_id, d.has_pending =
			header, nal.type, nal.temporal_id, true
	} else {
		same_picture :=
			d.has_pending &&
			header.pps_id == d.pending.pps_id &&
			(header.dependent_slice_segment ||
					header.pic_order_cnt_lsb == d.pending.pic_order_cnt_lsb)
		hevc.destroy_slice_header(&header)
		if !same_picture do return .Invalid_Argument
	}
	limit := d.config.max_packet_bytes
	if limit == 0 do limit = 128 * 1024 * 1024
	if len(data) + 3 > limit - len(d.packet) do return .Output_Overflow
	append(&d.slice_offsets, u32(len(d.packet)))
	append(&d.packet, u8(0), u8(0), u8(1))
	append(&d.packet, ..data)
	return .None
}

flush_h265_decoder :: proc(
	d: ^H265_Decoder,
	receiver: H265_Receiver,
	user: rawptr,
) -> (
	err: Error,
) {
	if d == nil || !d.initialized || d.failed do return .Invalid_Argument
	defer if err != .None && err != .Busy do d.failed = true
	if err = h265_finish_picture(d, receiver, user); err != .None do return
	for h265_bump(d) {}
	if err = h265_drain_backend(d, receiver, user); err != .None do return
	h265_emit(d, receiver, user)
	return .None
}

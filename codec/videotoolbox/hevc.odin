package videotoolbox

import hevc "../h265/decoder"

// Syntax, POC and reference picture sets come from the native HEVC parser,
// and output follows the bumping process of H.265 C.5.2 over a DPB of
// picture descriptions; VideoToolbox decodes each assembled picture and
// keeps its own references. Main and Main 10, 4:2:0, base layer only.
// Do not move an initialized decoder: its session is VideoToolbox's
// callback context.
H265_Decoder :: struct {
	pictures:                             Pictures,
	syntax:                               hevc.Nal_Scratch,
	vps:                                  [16]hevc.VPS,
	sps:                                  [16]hevc.SPS,
	pps:                                  [64]hevc.PPS,
	has_vps:                              [16]bool,
	has_sps:                              [16]bool,
	has_pps:                              [64]bool,
	// Parameter set NAL units for the format description (SPSs uncropped).
	vps_nal:                              [16][dynamic]u8,
	sps_nal:                              [16][dynamic]u8,
	pps_nal:                              [64][dynamic]u8,
	format_sps:                           u32,
	format_dirty:                         bool,
	pending:                              hevc.Slice_Header, // the picture being assembled
	pending_type:                         hevc.Nal_Type,
	pending_temporal_id:                  u8,
	poc:                                  hevc.Poc_State,
	dpb:                                  [dynamic]H265_Entry,
	// The active SPS's limits: max_num_reorder_pics, max_latency_increase_plus1, max_dec_pic_buffering.
	max_reorder, max_latency, max_dpb:    int,
	// seen_picture is false at the start and after an end of sequence, when
	// the next picture must be a random access point.
	seen_picture, skip_rasl, has_pending: bool,
	initialized, failed:                  bool,
}
// A picture in the decoded picture buffer; its samples are held in
// `pictures` while it waits for output.
@(private)
H265_Entry :: struct {
	poc:               i32,
	reference, output: bool, // still referenced; waiting for output
	latency:           int, // pictures decoded since, while it waits
}

init_h265_decoder :: proc(d: ^H265_Decoder) -> Error {
	if d == nil || d.initialized do return .Invalid_Argument
	if !hardware_decode_supported(.HEVC) do return .Unavailable
	d^ = {
		initialized  = true,
		format_dirty = true,
	}
	return .None
}

destroy_h265_decoder :: proc(d: ^H265_Decoder) {
	if d == nil || !d.initialized do return
	destroy_pictures(&d.pictures)
	if d.has_pending do hevc.destroy_slice_header(&d.pending)
	for &s, i in d.sps do if d.has_sps[i] do hevc.destroy_sps(&s)
	for &p, i in d.pps do if d.has_pps[i] do hevc.destroy_pps(&p)
	for nal in d.vps_nal do delete(nal)
	for nal in d.sps_nal do delete(nal)
	for nal in d.pps_nal do delete(nal)
	delete(d.dpb)
	hevc.destroy_nal_scratch(&d.syntax)
	d^ = {}
}

decode_h265_nal :: proc(d: ^H265_Decoder, data: []u8, receiver: Receiver, user: rawptr) -> (err: Error) {
	if d == nil || !d.initialized || d.failed do return .Invalid_Argument
	defer if err != .None do d.failed = true
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
			replace(&d.vps_nal[value.id], data)
		case .SPS_NUT:
			value, good := hevc.parse_sps(nal.rbsp)
			if !good do return .Invalid_Argument
			if d.has_sps[value.id] do hevc.destroy_sps(&d.sps[value.id])
			d.sps[value.id], d.has_sps[value.id] = value, true
			if !uncropped_sps(data, .HEVC, &d.sps_nal[value.id]) do return .Invalid_Argument
		case .PPS_NUT:
			value, good := hevc.parse_pps(nal.rbsp)
			if !good do return .Invalid_Argument
			if d.has_pps[value.id] do hevc.destroy_pps(&d.pps[value.id])
			d.pps[value.id], d.has_pps[value.id] = value, true
			replace(&d.pps_nal[value.id], data)
		}
		d.format_dirty = true
		return .None
	case .EOS_NUT, .EOB_NUT:
		// What follows starts afresh at a random access point (8.1.3), whose
		// C.5.2.2 rules decide what still waiting is shown: after a CRA, nothing.
		if err = h265_finish_picture(d, receiver, user); err != .None do return
		d.seen_picture = false
		return .None
	case .AUD_NUT:
		return h265_finish_picture(d, receiver, user)
	}
	if !hevc.nal_type_is_vcl(nal.type) do return .None
	pps_id, good := hevc.peek_pps_id(nal)
	if !good || pps_id >= len(d.pps) || !d.has_pps[pps_id] do return .Invalid_Argument
	p := &d.pps[pps_id]
	if !d.has_sps[p.sps_id] do return .Invalid_Argument
	s := &d.sps[p.sps_id]
	if !d.has_vps[s.vps_id] do return .Invalid_Argument
	if s.chroma_format_idc != 1 || (s.bit_depth_luma != 8 && s.bit_depth_luma != 10) || s.bit_depth_chroma != s.bit_depth_luma do return .Unsupported
	if !hevc.pps_resolve_tile_geometry(p, s) do return .Invalid_Argument
	header, good_header := hevc.parse_slice_header(nal.rbsp, nal.type, s, p)
	if !good_header do return .Invalid_Argument
	if header.first_slice_segment_in_pic {
		if err = h265_finish_picture(d, receiver, user); err != .None {hevc.destroy_slice_header(&header); return}
		irap := hevc.nal_type_is_irap(nal.type)
		if !d.seen_picture && !irap {hevc.destroy_slice_header(&header); return .Unsupported}
		if irap do d.skip_rasl = !d.seen_picture || hevc.nal_type_is_idr(nal.type) || (nal.type >= .BLA_W_LP && nal.type <= .BLA_N_LP)
		d.seen_picture = true
		// Leading pictures that reference pictures before a random-access start.
		if d.skip_rasl && (nal.type == .RASL_N || nal.type == .RASL_R) {hevc.destroy_slice_header(&header); return .None}
		d.pending, d.pending_type, d.pending_temporal_id, d.has_pending = header, nal.type, nal.temporal_id, true
	} else {
		same_picture := d.has_pending && header.pps_id == d.pending.pps_id && (header.dependent_slice_segment || header.pic_order_cnt_lsb == d.pending.pic_order_cnt_lsb)
		hevc.destroy_slice_header(&header)
		if !d.has_pending do return .None // a slice of a skipped RASL picture
		if !same_picture do return .Invalid_Argument
	}
	return append_nal(&d.pictures, data)
}

// Shows every picture still waiting, at the end of the stream.
flush_h265_decoder :: proc(d: ^H265_Decoder, receiver: Receiver, user: rawptr) -> (err: Error) {
	if d == nil || !d.initialized || d.failed do return .Invalid_Argument
	defer if err != .None do d.failed = true
	if err = h265_finish_picture(d, receiver, user); err != .None do return
	h265_bump_all(d, receiver, user)
	return .None
}

// C.5.2.4: shows the waiting picture with the lowest POC.
@(private)
h265_bump :: proc(d: ^H265_Decoder, receiver: Receiver, user: rawptr) -> bool {
	best := -1
	for e, i in d.dpb do if e.output && (best < 0 || e.poc < d.dpb[best].poc) do best = i
	if best < 0 do return false
	d.dpb[best].output = false
	for h, i in d.pictures.held {
		if h.id == i64(d.dpb[best].poc) {show(&d.pictures, i, receiver, user); break}
	}
	h265_remove_unused(d)
	return true
}

@(private)
h265_bump_all :: proc(d: ^H265_Decoder, receiver: Receiver, user: rawptr) {
	for h265_bump(d, receiver, user) {}
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

// Points the session at the VPS and SPS in use and every PPS of that SPS.
@(private)
h265_update_format :: proc(d: ^H265_Decoder, s: ^hevc.SPS) -> Error {
	if !d.format_dirty && d.format_sps == s.id do return .None
	sets: [MAX_PARAMETER_SETS][]u8
	sets[0], sets[1] = d.vps_nal[s.vps_id][:], d.sps_nal[s.id][:]
	n := 2
	for has, id in d.has_pps {
		if !has || d.pps[id].sps_id != s.id do continue
		sets[n] = d.pps_nal[id][:]
		n += 1
	}
	if err := session_set_format(&d.pictures.session, .HEVC, sets[:n], int(s.bit_depth_luma), s.full_range); err != .None do return err
	d.format_sps, d.format_dirty = s.id, false
	return .None
}

@(private)
h265_finish_picture :: proc(d: ^H265_Decoder, receiver: Receiver, user: rawptr) -> Error {
	if !d.has_pending do return .None
	defer {
		hevc.destroy_slice_header(&d.pending)
		d.has_pending = false
	}
	header := &d.pending
	s := &d.sps[d.pps[header.pps_id].sps_id]
	d.max_reorder, d.max_latency, d.max_dpb = int(s.max_num_reorder_pics), int(s.max_latency_increase), int(s.max_dec_pic_buffering) + 1
	no_rasl := hevc.nal_type_is_irap(d.pending_type) && d.skip_rasl
	if no_rasl do d.poc = {}
	poc := hevc.derive_poc(&d.poc, d.pending_type, i32(header.pic_order_cnt_lsb), s.log2_max_poc_lsb, no_rasl)
	hevc.poc_state_update(&d.poc, d.pending_type, d.pending_temporal_id, poc, i32(header.pic_order_cnt_lsb), s.log2_max_poc_lsb)

	// C.5.2.2: a random access point that starts decoding either releases
	// the buffer or shows all of it (a CRA always releases); otherwise the
	// reference picture set decides what stays.
	if no_rasl {
		if !header.no_output_of_prior_pics && d.pending_type != .CRA_NUT do h265_bump_all(d, receiver, user)
		for len(d.pictures.held) > 0 do discard(&d.pictures, 0)
		clear(&d.dpb)
	} else {
		rps := hevc.derive_ref_pic_set(poc, s.log2_max_poc_lsb, &header.st_rps, &header.lt_rps, header.lt_rps.num_sps)
		defer hevc.destroy_ref_pic_set(&rps)
		// Long-term entries named by their low POC bits resolve among the
		// pictures still referenced, as the native decoder does; one that
		// resolves to nothing simply keeps nothing.
		available := make([dynamic]i32, 0, len(d.dpb))
		defer delete(available)
		for e in d.dpb do if e.reference do append(&available, e.poc)
		hevc.resolve_long_term_ref_pocs(&rps, available[:], s.log2_max_poc_lsb)
		groups := [5][]i32{rps.st_curr_before[:], rps.st_curr_after[:], rps.lt_curr[:], rps.st_foll[:], rps.lt_foll[:]}
		for &e in d.dpb {
			e.reference = false
			for group in groups do for ref in group do if ref == e.poc do e.reference = true
		}
		h265_remove_unused(d)
		for h265_full(d, true) do if !h265_bump(d, receiver, user) do break
	}

	if err := h265_update_format(d, s); err != .None do return err
	depth := int(s.bit_depth_luma)
	frame := Frame {
		width        = int(hevc.sps_cropped_width(s)),
		height       = int(hevc.sps_cropped_height(s)),
		bit_depth    = depth,
		storage_bits = depth > 8 ? 16 : 8,
		coded_width  = int(s.pic_width_in_luma_samples),
		coded_height = int(s.pic_height_in_luma_samples),
		crop_x       = int(s.conf_win_left) * 2,
		crop_y       = int(s.conf_win_top) * 2,
		poc          = int(poc),
	}
	if err := decode_picture(&d.pictures, frame, i64(poc)); err != .None do return err

	// C.5.2.3: store the picture, then show what the limits no longer allow to wait.
	output := header.pic_output_flag
	if output {
		for &e in d.dpb do if e.output do e.latency += 1
	} else {
		discard(&d.pictures, len(d.pictures.held) - 1)
	}
	append(&d.dpb, H265_Entry{poc = poc, reference = true, output = output})
	for h265_full(d, false) do if !h265_bump(d, receiver, user) do break
	return .None
}

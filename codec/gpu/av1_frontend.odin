package gpu

import av1 "../av1"
import vk "vendor:vulkan"

AV1_Decoder_Config :: struct {
	shared_context:   ^Context, // optional shared device, held until this frontend is destroyed
	device_index:     int,
	max_packet_bytes: int, // zero admits up to 128 MiB per temporal unit
	skip_film_grain:  bool, // output without the stream's film grain (also when the device cannot apply it)
}
AV1_Receiver :: proc(frame: AV1_Frame, user: rawptr)

// The eight reference frames and the frame being decoded each need a slot.
AV1_SLOTS :: av1.NUM_REF_FRAMES + 1

@(private)
AV1_Slot :: struct {
	info:          vk.VideoDecodeAV1ReferenceInfo,
	width, height: int,
	// A hidden frame's output, kept for show_existing_frame: the DPB image
	// holds it without film grain and cannot be read back.
	shown:         [3][dynamic]u8,
	shown_frame:   AV1_Frame, // its description, planes into `shown`
	has_shown:     bool,
}

// What becomes of each submitted frame, in order, and the hidden frames
// shown again between them.
@(private)
AV1_Pending :: struct {
	show:   bool, // a decoded frame to show
	keep:   i8, // DPB slot whose host copy the decoded frame becomes, or -1
	replay: i8, // not a decoded frame: show this slot's copy (show_existing_frame), or -1
}

// The std structures a picture points to, alive for its decode call.
@(private)
AV1_Std :: struct {
	sequence:     vk.VideoAV1SequenceHeader,
	color:        vk.VideoAV1ColorConfig,
	timing:       vk.VideoAV1TimingInfo,
	tile:         vk.VideoAV1TileInfo,
	quantization: vk.VideoAV1Quantization,
	segmentation: vk.VideoAV1Segmentation,
	loop_filter:  vk.VideoAV1LoopFilter,
	cdef:         vk.VideoAV1CDEF,
	restoration:  vk.VideoAV1LoopRestoration,
	motion:       vk.VideoAV1GlobalMotion,
	grain:        vk.VideoAV1FilmGrain,
}

// Syntax and reference state come from the av1 package. This frontend maps
// the eight reference frames to DPB slots and hands each frame's header and
// tiles to the hardware. Outputs borrow callback storage.
AV1_Decoder :: struct {
	config:              AV1_Decoder_Config,
	backend:             Decoder,
	parser:              av1.Parser,
	sequence:            av1.Sequence_Header, // what the session parameters hold
	has_parameters:      bool,
	film_grain:          bool, // film grain was asked of the backend (backend.config says whether it applies it)
	frames:              [dynamic]av1.Frame,
	tiles:               [dynamic]av1.Tile,
	offsets, sizes:      [dynamic]u32,
	refs:                [av1.NUM_REF_FRAMES]i8, // DPB slot of each reference frame, -1 for none
	slots:               [AV1_SLOTS]AV1_Slot,
	in_flight:           [dynamic]AV1_Pending,
	std:                 AV1_Std,
	initialized, failed: bool,
}

init_av1_decoder :: proc(d: ^AV1_Decoder, config: AV1_Decoder_Config) -> Error {
	if d == nil || d.initialized || config.max_packet_bytes < 0 do return .Invalid_Argument
	if config.shared_context != nil {
		if err := retain_context(config.shared_context); err != .None do return err
	}
	d^ = {
		config      = config,
		initialized = true,
	}
	for &r in d.refs do r = -1
	return .None
}

destroy_av1_decoder :: proc(d: ^AV1_Decoder) {
	if d == nil do return
	for &slot in d.slots do for plane in slot.shown do delete(plane)
	delete(d.frames)
	delete(d.tiles)
	delete(d.offsets)
	delete(d.sizes)
	delete(d.in_flight)
	destroy_decoder(&d.backend)
	if d.initialized && d.config.shared_context != nil do release_context(d.config.shared_context)
	d^ = {}
}

// Decodes one temporal unit (an MP4 sample, a Matroska block, or the OBUs
// between temporal delimiters), passing its shown frames to `receiver`.
decode_av1_temporal_unit :: proc(d: ^AV1_Decoder, data: []u8, receiver: AV1_Receiver, user: rawptr) -> (err: Error) {
	if d == nil || !d.initialized || d.failed do return .Invalid_Argument
	defer if err != .None && err != .Busy do d.failed = true
	limit := d.config.max_packet_bytes
	if limit == 0 do limit = 128 * 1024 * 1024
	if len(data) > limit do return .Output_Overflow
	switch av1.parse_temporal_unit(&d.parser, data, &d.frames, &d.tiles) {
	case .None:
	case .Unsupported:
		return .Unsupported
	case .Invalid_Data:
		return .Invalid_Argument
	}
	for &frame in d.frames {
		h := &frame.header
		if h.show_existing_frame {
			av1_show_existing(d, h, receiver, user) or_return
			continue
		}
		av1_ensure_backend(d, h, receiver, user) or_return
		av1_decode_frame(d, data, &frame, receiver, user) or_return
	}
	return .None
}

// Shows the frames still on the GPU. Frames come out in the order the
// stream shows them.
flush_av1_decoder :: proc(d: ^AV1_Decoder, receiver: AV1_Receiver, user: rawptr) -> (err: Error) {
	if d == nil || !d.initialized || d.failed do return .Invalid_Argument
	defer if err != .None do d.failed = true
	return av1_drain_backend(d, receiver, user)
}

// Receives every frame still in flight.
@(private)
av1_drain_backend :: proc(d: ^AV1_Decoder, receiver: AV1_Receiver, user: rawptr) -> Error {
	if !d.backend.initialized do return .None
	for {
		decoded, ready, err := finish_decoder(&d.backend)
		if err != .None do return err
		if !ready do return .None
		av1_receive(d, decoded, receiver, user)
	}
}

// A frame back from the hardware, the oldest submitted: kept for a later
// show_existing_frame and/or shown, then any replays queued behind it.
@(private)
av1_receive :: proc(d: ^AV1_Decoder, decoded: Decoder_Frame, receiver: AV1_Receiver, user: rawptr) {
	p := d.in_flight[0]
	ordered_remove(&d.in_flight, 0)
	if p.keep >= 0 {
		s := &d.slots[p.keep]
		s.shown_frame = decoded
		for plane, i in decoded.planes {
			resize(&s.shown[i], len(plane))
			copy(s.shown[i][:], plane)
			s.shown_frame.planes[i] = s.shown[i][:]
		}
	}
	if p.show && receiver != nil do receiver(decoded, user)
	for len(d.in_flight) > 0 && d.in_flight[0].replay >= 0 {
		av1_replay(d, int(d.in_flight[0].replay), receiver, user)
		ordered_remove(&d.in_flight, 0)
	}
}

@(private)
av1_replay :: proc(d: ^AV1_Decoder, slot: int, receiver: AV1_Receiver, user: rawptr) {
	if receiver != nil do receiver(d.slots[slot].shown_frame, user)
}

@(private)
av1_show_existing :: proc(d: ^AV1_Decoder, h: ^av1.Frame_Header, receiver: AV1_Receiver, user: rawptr) -> Error {
	slot := d.refs[h.frame_to_show_map_idx]
	if slot < 0 do return .Invalid_Argument
	s := &d.slots[slot]
	if !s.has_shown do return .Unsupported // a frame shown twice, which encoders do not do
	if h.frame_type == .Key do for &r in d.refs do r = slot
	// Shown after the frames still in flight, from the copy the hidden
	// frame leaves when it comes back.
	if len(d.in_flight) > 0 {
		append(&d.in_flight, AV1_Pending{keep = -1, replay = slot})
	} else {
		av1_replay(d, int(slot), receiver, user)
	}
	return .None
}


// The session follows the sequence header: its largest frame and depth, and
// new parameters whenever the header changes.
@(private)
av1_ensure_backend :: proc(d: ^AV1_Decoder, h: ^av1.Frame_Header, receiver: AV1_Receiver, user: rawptr) -> Error {
	s := &d.parser.sequence
	c := &s.color
	if c.mono_chrome || c.subsampling_x != 1 || c.subsampling_y != 1 || s.seq_profile != 0 do return .Unsupported // Main 4:2:0 only
	if c.bit_depth != 8 && c.bit_depth != 10 do return .Unsupported
	// Rounded to even for the 4:2:0 images; frames may be any size within.
	w := (int(s.max_frame_width_minus_1) + 2) &~ 1
	ht := (int(s.max_frame_height_minus_1) + 2) &~ 1
	grain := s.film_grain_params_present && !d.config.skip_film_grain
	b := &d.backend
	if b.initialized && (b.config.width != w || b.config.height != ht || b.config.bit_depth != int(c.bit_depth) || d.film_grain != grain) {
		// A new session: only at a key frame, which invalidates every reference.
		if h.frame_type != .Key || !h.show_frame do return .Unsupported
		if err := av1_drain_backend(d, receiver, user); err != .None do return err
		destroy_decoder(b)
		d.has_parameters = false
		for &r in d.refs do r = -1
	}
	if !b.initialized {
		limit := d.config.max_packet_bytes
		if limit == 0 do limit = 128 * 1024 * 1024
		config := Decoder_Config {
			codec            = .AV1,
			width            = w,
			height           = ht,
			bit_depth        = int(c.bit_depth),
			dpb_slots        = AV1_SLOTS,
			max_references   = av1.REFS_PER_FRAME,
			device_index     = d.config.device_index,
			max_packet_bytes = limit,
			output_storage   = .Host,
			shared_context   = d.config.shared_context,
			film_grain       = grain,
		}
		err := init_decoder(b, config)
		if err == .Unsupported && grain {
			// Without film grain support the frames are shown without grain.
			config.film_grain = false
			err = init_decoder(b, config)
		}
		if err != .None do return err
		d.film_grain = grain
	}
	if !d.has_parameters || d.sequence != s^ {
		av1_map_sequence(&d.std, s)
		params := Decode_Parameters {
			av1 = &d.std.sequence,
		}
		if err := set_decoder_parameters(b, &params); err != .None do return err
		d.sequence, d.has_parameters = s^, true
	}
	return .None
}

@(private)
flag_set :: proc(on: [$E]bool) -> (set: bit_set[E;u32]) {
	for value, flag in on do if value do set += {flag}
	return
}

@(private)
av1_map_sequence :: proc(std: ^AV1_Std, s: ^av1.Sequence_Header) {
	c := &s.color
	std.color = {
		flags                    = vk.VideoAV1ColorConfigFlags(flag_set([vk.VideoAV1ColorConfigFlag]bool {
				.mono_chrome = c.mono_chrome,
				.color_range = c.color_range,
				.separate_uv_delta_q = c.separate_uv_delta_q,
				.color_description_present_flag = c.color_description_present_flag,
			})),
		BitDepth                 = c.bit_depth,
		subsampling_x            = c.subsampling_x,
		subsampling_y            = c.subsampling_y,
		color_primaries          = vk.VideoAV1ColorPrimaries(c.color_primaries),
		transfer_characteristics = vk.VideoAV1TransferCharacteristics(c.transfer_characteristics),
		matrix_coefficients      = vk.VideoAV1MatrixCoefficients(c.matrix_coefficients),
		chroma_sample_position   = vk.VideoAV1ChromaSamplePosition(c.chroma_sample_position),
	}
	std.timing = {
		flags                         = s.equal_picture_interval ? {.equal_picture_interval} : {},
		num_units_in_display_tick     = s.num_units_in_display_tick,
		time_scale                    = s.time_scale,
		num_ticks_per_picture_minus_1 = s.num_ticks_per_picture_minus_1,
	}
	std.sequence = {
		flags                              = vk.VideoAV1SequenceHeaderFlags(flag_set([vk.VideoAV1SequenceHeaderFlag]bool {
				.still_picture = s.still_picture,
				.reduced_still_picture_header = s.reduced_still_picture_header,
				.use_128x128_superblock = s.use_128x128_superblock,
				.enable_filter_intra = s.enable_filter_intra,
				.enable_intra_edge_filter = s.enable_intra_edge_filter,
				.enable_interintra_compound = s.enable_interintra_compound,
				.enable_masked_compound = s.enable_masked_compound,
				.enable_warped_motion = s.enable_warped_motion,
				.enable_dual_filter = s.enable_dual_filter,
				.enable_order_hint = s.enable_order_hint,
				.enable_jnt_comp = s.enable_jnt_comp,
				.enable_ref_frame_mvs = s.enable_ref_frame_mvs,
				.frame_id_numbers_present_flag = s.frame_id_numbers_present_flag,
				.enable_superres = s.enable_superres,
				.enable_cdef = s.enable_cdef,
				.enable_restoration = s.enable_restoration,
				.film_grain_params_present = s.film_grain_params_present,
				.timing_info_present_flag = s.timing_info_present_flag,
				.initial_display_delay_present_flag = s.initial_display_delay_present_flag,
			})),
		seq_profile                        = vk.VideoAV1Profile(s.seq_profile),
		frame_width_bits_minus_1           = s.frame_width_bits_minus_1,
		frame_height_bits_minus_1          = s.frame_height_bits_minus_1,
		max_frame_width_minus_1            = s.max_frame_width_minus_1,
		max_frame_height_minus_1           = s.max_frame_height_minus_1,
		delta_frame_id_length_minus_2      = s.delta_frame_id_length_minus_2,
		additional_frame_id_length_minus_1 = s.additional_frame_id_length_minus_1,
		order_hint_bits_minus_1            = s.order_hint_bits_minus_1,
		seq_force_integer_mv               = s.seq_force_integer_mv,
		seq_force_screen_content_tools     = s.seq_force_screen_content_tools,
		pColorConfig                       = &std.color,
		pTimingInfo                        = s.timing_info_present_flag ? &std.timing : nil,
	}
}

// The frame's std picture information, pointing into `std` and the header.
@(private)
av1_map_picture :: proc(std: ^AV1_Std, h: ^av1.Frame_Header, grain: bool) -> (p: vk.VideoDecodeAV1PictureInfo) {
	t := &h.tile_info
	std.tile = {
		flags                   = t.uniform_tile_spacing_flag ? {.uniform_tile_spacing_flag} : {},
		TileCols                = u8(t.tile_cols),
		TileRows                = u8(t.tile_rows),
		context_update_tile_id  = t.context_update_tile_id,
		tile_size_bytes_minus_1 = u8(max(t.tile_size_bytes, 1) - 1),
		pMiColStarts            = raw_data(t.mi_col_starts[:]),
		pMiRowStarts            = raw_data(t.mi_row_starts[:]),
		pWidthInSbsMinus1       = &t.width_in_sbs_minus_1[0],
		pHeightInSbsMinus1      = &t.height_in_sbs_minus_1[0],
	}
	std.quantization = {
		flags      = vk.VideoAV1QuantizationFlags(flag_set([vk.VideoAV1QuantizationFlag]bool{.using_qmatrix = h.using_qmatrix, .diff_uv_delta = h.diff_uv_delta})),
		base_q_idx = h.base_q_idx,
		DeltaQYDc  = h.delta_q_y_dc,
		DeltaQUDc  = h.delta_q_u_dc,
		DeltaQUAc  = h.delta_q_u_ac,
		DeltaQVDc  = h.delta_q_v_dc,
		DeltaQVAc  = h.delta_q_v_ac,
		qm_y       = h.qm_y,
		qm_u       = h.qm_u,
		qm_v       = h.qm_v,
	}
	std.segmentation = {
		FeatureEnabled = h.feature_enabled,
		FeatureData    = h.feature_data,
	}
	std.loop_filter = {
		flags                   = vk.VideoAV1LoopFilterFlags(flag_set([vk.VideoAV1LoopFilterFlag]bool{.loop_filter_delta_enabled = h.loop_filter_delta_enabled, .loop_filter_delta_update = h.loop_filter_delta_update})),
		loop_filter_level       = h.loop_filter_level,
		loop_filter_sharpness   = h.loop_filter_sharpness,
		update_ref_delta        = h.update_ref_delta,
		loop_filter_ref_deltas  = h.loop_filter_ref_deltas,
		update_mode_delta       = h.update_mode_delta,
		loop_filter_mode_deltas = h.loop_filter_mode_deltas,
	}
	// Secondary strengths as coded: 4 was coded as 3.
	coded :: proc(s: [8]u8) -> (c: [8]u8) {
		for v, i in s do c[i] = v == 4 ? 3 : v
		return
	}
	std.cdef = {
		cdef_damping_minus_3 = h.cdef_damping_minus_3,
		cdef_bits            = h.cdef_bits,
		cdef_y_pri_strength  = h.cdef_y_pri_strength,
		cdef_y_sec_strength  = coded(h.cdef_y_sec_strength),
		cdef_uv_pri_strength = h.cdef_uv_pri_strength,
		cdef_uv_sec_strength = coded(h.cdef_uv_sec_strength),
	}
	std.restoration = {}
	for plane in 0 ..< 3 {
		std.restoration.FrameRestorationType[plane] = vk.VideoAV1FrameRestorationType(h.frame_restoration_type[plane])
		// Sizes as log2(size) - 5.
		if size := h.loop_restoration_size[plane]; size >= 32 do std.restoration.LoopRestorationSize[plane] = u16(av1_log2(int(size)) - 5)
	}
	std.motion = {
		GmType    = h.gm_type,
		gm_params = h.gm_params,
	}
	g := &h.film_grain
	std.grain = {
		flags                     = vk.VideoAV1FilmGrainFlags(flag_set([vk.VideoAV1FilmGrainFlag]bool {
				.chroma_scaling_from_luma = g.chroma_scaling_from_luma,
				.overlap_flag = g.overlap_flag,
				.clip_to_restricted_range = g.clip_to_restricted_range,
				.update_grain = g.update_grain,
			})),
		grain_scaling_minus_8     = g.grain_scaling_minus_8,
		ar_coeff_lag              = g.ar_coeff_lag,
		ar_coeff_shift_minus_6    = g.ar_coeff_shift_minus_6,
		grain_scale_shift         = g.grain_scale_shift,
		grain_seed                = g.grain_seed,
		film_grain_params_ref_idx = g.film_grain_params_ref_idx,
		num_y_points              = g.num_y_points,
		point_y_value             = g.point_y_value,
		point_y_scaling           = g.point_y_scaling,
		num_cb_points             = g.num_cb_points,
		point_cb_value            = g.point_cb_value,
		point_cb_scaling          = g.point_cb_scaling,
		num_cr_points             = g.num_cr_points,
		point_cr_value            = g.point_cr_value,
		point_cr_scaling          = g.point_cr_scaling,
		// The std declares these int8_t; the values are the coded bytes.
		ar_coeffs_y_plus_128      = transmute([24]i8)g.ar_coeffs_y_plus_128,
		ar_coeffs_cb_plus_128     = transmute([25]i8)g.ar_coeffs_cb_plus_128,
		ar_coeffs_cr_plus_128     = transmute([25]i8)g.ar_coeffs_cr_plus_128,
		cb_mult                   = g.cb_mult,
		cb_luma_mult              = g.cb_luma_mult,
		cb_offset                 = g.cb_offset,
		cr_mult                   = g.cr_mult,
		cr_luma_mult              = g.cr_luma_mult,
		cr_offset                 = g.cr_offset,
	}
	p = {
		flags                = vk.VideoDecodeAV1PictureInfoFlags(flag_set([vk.VideoDecodeAV1PictureInfoFlag]bool {
				.error_resilient_mode = h.error_resilient_mode,
				.disable_cdf_update = h.disable_cdf_update,
				.use_superres = h.use_superres,
				.render_and_frame_size_different = h.render_and_frame_size_different,
				.allow_screen_content_tools = h.allow_screen_content_tools,
				.is_filter_switchable = h.is_filter_switchable,
				.force_integer_mv = h.force_integer_mv,
				.frame_size_override_flag = h.frame_size_override_flag,
				.buffer_removal_time_present_flag = h.buffer_removal_time_present_flag,
				.allow_intrabc = h.allow_intrabc,
				.frame_refs_short_signaling = h.frame_refs_short_signaling,
				.allow_high_precision_mv = h.allow_high_precision_mv,
				.is_motion_mode_switchable = h.is_motion_mode_switchable,
				.use_ref_frame_mvs = h.use_ref_frame_mvs,
				.disable_frame_end_update_cdf = h.disable_frame_end_update_cdf,
				.allow_warped_motion = h.allow_warped_motion,
				.reduced_tx_set = h.reduced_tx_set,
				.reference_select = h.reference_select,
				.skip_mode_present = h.skip_mode_present,
				.delta_q_present = h.delta_q_present,
				.delta_lf_present = h.delta_lf_present,
				.delta_lf_multi = h.delta_lf_multi,
				.segmentation_enabled = h.segmentation_enabled,
				.segmentation_update_map = h.segmentation_update_map,
				.segmentation_temporal_update = h.segmentation_temporal_update,
				.segmentation_update_data = h.segmentation_update_data,
				.UsesLr = h.uses_lr,
				.usesChromaLr = h.uses_chroma_lr,
				.apply_grain = h.film_grain.apply_grain && grain,
			})),
		frame_type           = vk.VideoAV1FrameType(h.frame_type),
		current_frame_id     = h.current_frame_id,
		OrderHint            = h.order_hint,
		primary_ref_frame    = h.primary_ref_frame,
		refresh_frame_flags  = h.refresh_frame_flags,
		interpolation_filter = vk.VideoAV1InterpolationFilter(h.interpolation_filter),
		TxMode               = vk.VideoAV1TxMode(h.tx_mode),
		delta_q_res          = h.delta_q_res,
		delta_lf_res         = h.delta_lf_res,
		SkipModeFrame        = h.skip_mode_frame,
		coded_denom          = h.coded_denom,
		OrderHints           = h.order_hints,
		pTileInfo            = &std.tile,
		pQuantization        = &std.quantization,
		pSegmentation        = &std.segmentation,
		pLoopFilter          = &std.loop_filter,
		pCDEF                = &std.cdef,
		pLoopRestoration     = &std.restoration,
		pGlobalMotion        = &std.motion,
		pFilmGrain           = &std.grain,
	}
	copy(p.expectedFrameId[:], h.expected_frame_id[:])
	return
}

@(private)
av1_log2 :: proc(n: int) -> int {
	k := 0
	for 1 << uint(k + 1) <= n do k += 1
	return k
}

@(private)
av1_decode_frame :: proc(d: ^AV1_Decoder, data: []u8, frame: ^av1.Frame, receiver: AV1_Receiver, user: rawptr) -> Error {
	h := &frame.header
	if len(frame.tiles) == 0 do return .Invalid_Argument
	// The frame's bytes: its header OBU through its last tile.
	last := frame.tiles[len(frame.tiles) - 1]
	start := frame.header_offset
	packet := data[start:int(last.offset) + int(last.size)]
	clear(&d.offsets)
	clear(&d.sizes)
	for t in frame.tiles {
		append(&d.offsets, t.offset - u32(start))
		append(&d.sizes, t.size)
	}
	// The setup slot: one no reference frame holds.
	setup := -1
	for slot in 0 ..< AV1_SLOTS {
		used := false
		for r in d.refs do used ||= int(r) == slot
		if !used {setup = slot; break}
	}
	if setup < 0 do return .Unsupported
	reset := h.frame_type == .Key && h.show_frame
	picture := Decode_Picture {
		av1               = av1_map_picture(&d.std, h, d.backend.config.film_grain),
		av1_header_offset = 0,
		slice_offsets     = d.offsets[:],
		tile_sizes        = d.sizes[:],
		width             = h.upscaled_width,
		height            = h.frame_height,
		setup_slot        = setup,
		reset             = reset,
	}
	references: [av1.REFS_PER_FRAME]Decode_Reference
	count := 0
	for &s in picture.av1_slots do s = -1
	if !h.frame_is_intra {
		for i in 0 ..< av1.REFS_PER_FRAME {
			slot := d.refs[h.ref_frame_idx[i]]
			if slot < 0 do return .Invalid_Argument
			picture.av1_slots[i] = i32(slot)
			listed := false
			for r in references[:count] do listed ||= r.slot == int(slot)
			if listed do continue
			s := &d.slots[slot]
			references[count] = {
				slot   = int(slot),
				width  = s.width,
				height = s.height,
				av1    = s.info,
			}
			count += 1
		}
	}
	picture.references = references[:count]
	// RADV (Mesa 26.2, VCN 5) faults the GPU predicting a frame of odd height
	// from a reference of another size; FFmpeg's Vulkan decoding of the same
	// stream does not, for a reason not yet found. Refuse it rather than hang.
	if h.frame_height & 1 != 0 {
		for r in picture.references do if r.width != h.upscaled_width || r.height != h.frame_height do return .Unsupported
	}
	sign_bias: u8
	for b, i in h.ref_frame_sign_bias do if b do sign_bias |= 1 << uint(i)
	picture.av1_setup = {
		flags            = vk.VideoDecodeAV1ReferenceInfoFlags(flag_set([vk.VideoDecodeAV1ReferenceInfoFlag]bool{.disable_frame_end_update_cdf = h.disable_frame_end_update_cdf, .segmentation_enabled = h.segmentation_enabled})),
		frame_type       = u8(h.frame_type),
		RefFrameSignBias = sign_bias,
		OrderHint        = h.order_hint,
		SavedOrderHints  = h.order_hints,
	}
	decoded, ready, err := decode_picture(&d.backend, packet, picture)
	if err != .None do return err
	s := &d.slots[setup]
	s.info, s.width, s.height = picture.av1_setup, h.upscaled_width, h.frame_height
	s.has_shown = !h.show_frame && h.showable_frame
	append(&d.in_flight, AV1_Pending{show = h.show_frame, keep = s.has_shown ? i8(setup) : -1, replay = -1})
	if ready do av1_receive(d, decoded, receiver, user)
	if reset do for &r in d.refs do r = -1
	for i in 0 ..< av1.NUM_REF_FRAMES do if h.refresh_frame_flags >> uint(i) & 1 != 0 do d.refs[i] = i8(setup)
	return .None
}

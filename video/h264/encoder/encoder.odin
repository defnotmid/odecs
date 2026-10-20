package h264_encoder

import h264 ".."
import common "../../../common"

import "core:math"
import "core:mem"
import "core:slice"
import "core:thread"

// ---------------------------------------------------------------------------
// Encoder: Constrained Baseline, CAVLC, I and P pictures
// ---------------------------------------------------------------------------

init_encoder :: proc(
	state: ^Encoder_State,
	config: Encoder_Config,
	allocator := context.allocator,
) -> (
	err: Error,
) {
	if state.macroblocks != nil || state.pictures != nil do return .Busy
	if err = encoder_config_error(config); err != .None do return
	state.config = config
	state.allocator = allocator
	state.error_detail = ""
	defer if err != .None do destroy_encoder(state)
	if state.config.num_ref_frames <= 0 do state.config.num_ref_frames = 1
	state.config.num_ref_frames = min(state.config.num_ref_frames, 4)
	if state.config.search_range <= 0 do state.config.search_range = 16
	if state.config.fps <= 0 do state.config.fps = 30
	if state.config.slice_count <= 0 do state.config.slice_count = 4
	state.config.checkpoint_capacity = max(config.checkpoint_capacity, 0)
	state.macroblock_columns = (config.width + 15) / 16
	state.macroblock_rows = (config.height + 15) / 16
	state.macroblock_count = state.macroblock_columns * state.macroblock_rows
	coded_w, coded_h := state.macroblock_columns * 16, state.macroblock_rows * 16

	state.macroblocks = make(#soa[]h264.Macroblock, state.macroblock_count, allocator)
	if state.macroblocks.type == nil || len(state.macroblocks) != state.macroblock_count do return .Allocation_Failed
	state.source = h264.alloc_yuv_buffer(coded_w, coded_h, allocator)
	if raw_data(state.source.memory) == nil {state.source = {}; return .Allocation_Failed}
	// Active references, retained checkpoints, one canceled GPU slot and one writer.
	state.pictures = make(
		[]Encoder_Picture,
		state.config.num_ref_frames * (state.config.checkpoint_capacity + 1) + 2,
		allocator,
	)
	if raw_data(state.pictures) == nil {state.pictures = nil; return .Allocation_Failed}
	for &pic, i in state.pictures {
		pic.buf = h264.alloc_yuv_buffer(coded_w, coded_h, allocator)
		if raw_data(pic.buf.memory) == nil {pic.buf = {}; return .Allocation_Failed}
		if err = init_reference_interpolation(&pic, allocator); err != .None do return
		pic.slot = i
	}
	state.checkpoints = make([]Encoder_Checkpoint, state.config.checkpoint_capacity, allocator)
	if state.config.checkpoint_capacity > 0 &&
	   raw_data(state.checkpoints) == nil {state.checkpoints = nil; return .Allocation_Failed}
	h264.compute_level_scales(
		&state.scales,
		&h264.Sequence_Parameter_Set{},
		&h264.Picture_Parameter_Set{},
	) // flat scaling lists

	state.out_rbsp = make([dynamic]u8, 0, 4096, allocator)
	if raw_data(state.out_rbsp) == nil do return .Allocation_Failed
	for &nal in state.parameter_nals do nal = make([dynamic]u8, allocator)
	state.nal_lanes = make([][]u8, state.macroblock_rows + 2, allocator)
	if raw_data(state.nal_lanes) == nil {state.nal_lanes = nil; return .Allocation_Failed}
	state.slices = make([]Slice_Task, state.macroblock_rows, allocator)
	if raw_data(state.slices) == nil {state.slices = nil; return .Allocation_Failed}
	for &slice in state.slices {
		slice.rbsp = make([dynamic]u8, allocator)
		slice.nal = make([dynamic]u8, allocator)
	}
	state.rate.qp = {config.qp, max(config.qp - 3, 0)}
	if config.bitrate_kbps > 0 {
		state.rate.target_bits = f64(config.bitrate_kbps) * 1000 / f64(state.config.fps)
		// Start from the QP that typically spends this many bits per pixel; the model takes over after the first frame of each kind
		bits_per_pixel := state.rate.target_bits / f64(config.width * config.height)
		start_qp := clamp(i32(math.round(28 - 6 * math.log(bits_per_pixel / 0.07, 2))), 10, 51)
		state.rate.qp = {start_qp, max(start_qp - 3, 10)}
	}
	return .None
}

@(private)
encoder_config_error :: proc(config: Encoder_Config) -> Error {
	if config.width <= 0 || config.height <= 0 || (config.width | config.height) & 1 != 0 || config.qp < 0 || config.qp > 51 do return .Invalid_Config
	if math.is_nan(f64(config.fps)) || math.is_inf(f64(config.fps)) do return .Invalid_Config
	pad := h264.PADDING_LENGTH
	if config.width > max(int) - 15 - 2 * pad || config.height > max(int) - 15 - 2 * pad do return .Invalid_Config
	w, h := (config.width + 15) / 16 * 16, (config.height + 15) / 16 * 16
	// Prove the existing padded frame and three interpolation plane products
	// before allocating or forming their int-sized offsets.
	stride, rows := w + 2 * pad, h + 2 * pad
	if stride > max(int) / rows do return .Invalid_Config
	luma_bytes := stride * rows
	if luma_bytes > max(int) / 3 do return .Invalid_Config
	uv_stride, uv_rows := w / 2 + pad, h / 2 + pad
	if uv_stride > max(int) / uv_rows do return .Invalid_Config
	uv_bytes := uv_stride * uv_rows
	if uv_bytes > max(int) / 2 || luma_bytes > max(int) - 2 * uv_bytes do return .Invalid_Config
	refs := clamp(config.num_ref_frames, 1, 4)
	if max(config.checkpoint_capacity, 0) > (max(int) - 2) / refs - 1 do return .Invalid_Config
	if max(config.checkpoint_capacity, 0) > max(int) / size_of(Encoder_Checkpoint) do return .Invalid_Config
	if refs * (max(config.checkpoint_capacity, 0) + 1) + 2 > max(int) / size_of(Encoder_Picture) do return .Invalid_Config
	return .None
}

destroy_encoder :: proc(state: ^Encoder_State) {
	allocator := state.allocator
	if allocator.procedure == nil do allocator = context.allocator
	// The context override must be in this procedure's scope. An override in
	// the conditional scope ends before the owned plain slices are deleted.
	context.allocator = allocator
	if state.compute !=
	   nil {compute_allocator := state.compute.allocator; destroy_compute(state.compute); free(state.compute, compute_allocator)}
	delete(state.macroblocks)
	h264.free_yuv_buffer(&state.source)
	for &pic in state.pictures {
		h264.free_yuv_buffer(&pic.buf)
		delete(pic.interpolation.storage)
	}
	delete(state.pictures)
	delete(state.out_rbsp)
	for &nal in state.parameter_nals do delete(nal)
	delete(state.nal_lanes)
	for &slice in state.slices {
		delete(slice.rbsp)
		delete(slice.nal)
	}
	delete(state.slices)
	delete(state.checkpoints)
	state^ = {}
}

// Sequence level for the frame size and rate (Table A-1). Rates up to 30 keep
// the historical size-only choice; faster rates rise until MaxMBPS fits.
level_for_rate :: proc(macroblock_count: int, fps: f32) -> h264.Sequence_Level {
	level := level_for_size(macroblock_count)
	if fps <= 30 do return level
	Limit :: struct {
		level:      h264.Sequence_Level,
		frame_size: int,
		rate:       f64,
	}
	limits := [?]Limit {
		{.Level_1_1, 396, 3000},
		{.Level_1_2, 396, 6000},
		{.Level_1_3, 396, 11880},
		{.Level_2_1, 792, 19800},
		{.Level_2_2, 1620, 20250},
		{.Level_3, 1620, 40500},
		{.Level_3_1, 3600, 108000},
		{.Level_3_2, 5120, 216000},
		{.Level_4, 8192, 245760},
		{.Level_4_2, 8704, 522240},
		{.Level_5, 22080, 589824},
		{.Level_5_1, 36864, 983040},
		{.Level_5_2, 36864, 2073600},
	}
	rate := f64(macroblock_count) * f64(fps)
	for l in limits {
		if l.level < level || l.frame_size < macroblock_count || l.rate < rate do continue
		return l.level
	}
	return .Level_5_2
}

// Sequence level for the frame size (Table A-1, frame rates up to 30).
level_for_size :: proc(macroblock_count: int) -> h264.Sequence_Level {
	switch {
	case macroblock_count <= 99:
		return .Level_1_1
	case macroblock_count <= 396:
		return .Level_2_1
	case macroblock_count <= 792:
		return .Level_2_2
	case macroblock_count <= 1620:
		return .Level_3_1
	case macroblock_count <= 3600:
		return .Level_3_2
	case macroblock_count <= 8192:
		return .Level_4
	}
	return .Level_5_1
}

write_sequence_parameter_set :: proc(state: ^Encoder_State, out: ^[dynamic]u8) {
	writer := h264.init_bit_writer(&state.out_rbsp)
	h264.write_bits(&writer, u32(h264.Sequence_Profile.Baseline), 8)
	h264.write_bits(&writer, 0b1100_0000, 8) // constraint_set0 and set1: Constrained Baseline
	h264.write_bits(&writer, u32(level_for_rate(state.macroblock_count, state.config.fps)), 8)
	h264.write_unsigned_exp_golomb(&writer, 0) // seq_parameter_set_id
	h264.write_unsigned_exp_golomb(&writer, 4) // log2_max_frame_num_minus4: 8-bit frame_num
	h264.write_unsigned_exp_golomb(&writer, u32(h264.Picture_Order_Mode.Frame_Number))
	h264.write_unsigned_exp_golomb(&writer, u32(state.config.num_ref_frames))
	h264.write_bits(&writer, 0, 1) // gaps_in_frame_num_value_allowed_flag
	h264.write_unsigned_exp_golomb(&writer, u32(state.macroblock_columns - 1))
	h264.write_unsigned_exp_golomb(&writer, u32(state.macroblock_rows - 1))
	h264.write_bits(&writer, 1, 1) // frame_mbs_only_flag
	h264.write_bits(&writer, 1, 1) // direct_8x8_inference_flag
	crop_right := (state.macroblock_columns * 16 - state.config.width) / 2
	crop_bottom := (state.macroblock_rows * 16 - state.config.height) / 2
	if crop_right > 0 || crop_bottom > 0 {
		h264.write_bits(&writer, 1, 1)
		h264.write_unsigned_exp_golomb(&writer, 0)
		h264.write_unsigned_exp_golomb(&writer, u32(crop_right))
		h264.write_unsigned_exp_golomb(&writer, 0)
		h264.write_unsigned_exp_golomb(&writer, u32(crop_bottom))
	} else {
		h264.write_bits(&writer, 0, 1)
	}
	vui := state.config.colour_primaries != 0
	h264.write_bits(&writer, vui ? 1 : 0, 1) // vui_parameters_present_flag
	if vui {
		h264.write_bits(&writer, 0, 1) // aspect_ratio_info_present_flag
		h264.write_bits(&writer, 0, 1) // overscan_info_present_flag
		h264.write_bits(&writer, 1, 1) // video_signal_type_present_flag
		h264.write_bits(&writer, 5, 3) // video_format: unspecified
		h264.write_bits(&writer, state.config.full_range ? 1 : 0, 1)
		h264.write_bits(&writer, 1, 1) // colour_description_present_flag
		h264.write_bits(&writer, u32(state.config.colour_primaries), 8)
		h264.write_bits(&writer, u32(state.config.transfer), 8)
		h264.write_bits(&writer, u32(state.config.matrix_coefficients), 8)
		h264.write_bits(&writer, 0, 1) // chroma_loc_info_present_flag
		h264.write_bits(&writer, 0, 1) // timing_info_present_flag
		h264.write_bits(&writer, 0, 1) // nal_hrd_parameters_present_flag
		h264.write_bits(&writer, 0, 1) // vcl_hrd_parameters_present_flag
		h264.write_bits(&writer, 0, 1) // pic_struct_present_flag
		h264.write_bits(&writer, 1, 1) // bitstream_restriction_flag
		h264.write_bits(&writer, 1, 1) // motion_vectors_over_pic_boundaries_flag
		h264.write_unsigned_exp_golomb(&writer, 0) // max_bytes_per_pic_denom: unbounded
		h264.write_unsigned_exp_golomb(&writer, 0) // max_bits_per_mb_denom: unbounded
		h264.write_unsigned_exp_golomb(&writer, 16) // log2_max_mv_length_horizontal
		h264.write_unsigned_exp_golomb(&writer, 16) // log2_max_mv_length_vertical
		h264.write_unsigned_exp_golomb(&writer, 0) // max_num_reorder_frames: I/P only
		h264.write_unsigned_exp_golomb(&writer, u32(state.config.num_ref_frames)) // max_dec_frame_buffering
	}
	h264.flush_bits_rbsp(&writer)
	h264.write_nal_annex_b(out, 3, 7, state.out_rbsp[:])
}

write_picture_parameter_set :: proc(state: ^Encoder_State, out: ^[dynamic]u8) {
	writer := h264.init_bit_writer(&state.out_rbsp)
	h264.write_unsigned_exp_golomb(&writer, 0) // pic_parameter_set_id
	h264.write_unsigned_exp_golomb(&writer, 0) // seq_parameter_set_id
	h264.write_bits(&writer, 0, 1) // entropy_coding_mode_flag: CAVLC
	h264.write_bits(&writer, 0, 1) // bottom_field_pic_order_in_frame_present_flag
	h264.write_unsigned_exp_golomb(&writer, 0) // num_slice_groups_minus1
	h264.write_unsigned_exp_golomb(&writer, u32(state.config.num_ref_frames - 1)) // num_ref_idx_l0_default_active_minus1
	h264.write_unsigned_exp_golomb(&writer, 0) // num_ref_idx_l1_default_active_minus1
	h264.write_bits(&writer, 0, 1) // weighted_pred_flag
	h264.write_bits(&writer, 0, 2) // weighted_bipred_idc
	h264.write_signed_exp_golomb(&writer, 0) // pic_init_qp_minus26
	h264.write_signed_exp_golomb(&writer, 0) // pic_init_qs_minus26
	h264.write_signed_exp_golomb(&writer, 0) // chroma_qp_index_offset
	h264.write_bits(&writer, 1, 1) // deblocking_filter_control_present_flag
	h264.write_bits(&writer, 0, 1) // constrained_intra_pred_flag
	h264.write_bits(&writer, 0, 1) // redundant_pic_cnt_present_flag
	h264.flush_bits_rbsp(&writer)
	h264.write_nal_annex_b(out, 3, 8, state.out_rbsp[:])
}

write_slice_header :: proc(task: ^Slice_Task, writer: ^h264.Bit_Writer) {
	state := task.state
	h264.write_unsigned_exp_golomb(writer, u32(task.first_macroblock))
	h264.write_unsigned_exp_golomb(writer, task.is_idr ? 7 : 5) // all slices of the picture are I or P
	h264.write_unsigned_exp_golomb(writer, 0) // pic_parameter_set_id
	h264.write_bits(writer, state.frame.frame_num & 255, 8)
	if task.is_idr do h264.write_unsigned_exp_golomb(writer, state.frame.idr_pic_id)
	if !task.is_idr {
		h264.write_bits(writer, 1, 1) // num_ref_idx_active_override_flag
		h264.write_unsigned_exp_golomb(writer, u32(state.num_refs - 1))
		h264.write_bits(writer, 0, 1) // ref_pic_list_modification_flag_l0
	}
	if task.is_idr {
		h264.write_bits(writer, 0, 1) // no_output_of_prior_pics_flag
		h264.write_bits(writer, 0, 1) // long_term_reference_flag
	} else {
		h264.write_bits(writer, 0, 1) // adaptive_ref_pic_marking_mode_flag: sliding window
	}
	h264.write_signed_exp_golomb(writer, task.quantizer - 26) // slice_qp_delta
	h264.write_unsigned_exp_golomb(writer, state.config.disable_deblocking ? 1 : 0)
	if !state.config.disable_deblocking {
		h264.write_signed_exp_golomb(writer, 0)
		h264.write_signed_exp_golomb(writer, 0)
	}
}

// Copy a source frame into the macroblock-aligned source buffer, replicating edges
import_source :: proc(
	state: ^Encoder_State,
	src_y, src_u, src_v: [^]u8,
	y_stride, uv_stride: int,
) {
	copy_plane :: proc(
		dst: [^]u8,
		dst_stride: int,
		src: [^]u8,
		src_stride, width, height, coded_w, coded_h: int,
	) {
		for y in 0 ..< coded_h {
			row: [^]u8 = &dst[y * dst_stride]
			source_row: [^]u8 = &src[min(y, height - 1) * src_stride]
			if row != source_row do mem.copy(row, source_row, width)
			for x in width ..< coded_w do row[x] = row[width - 1]
		}
	}
	buf := &state.source
	w, h := state.config.width, state.config.height
	copy_plane(buf.y, buf.y_stride, src_y, y_stride, w, h, buf.coded_width, buf.coded_height)
	copy_plane(
		buf.u,
		buf.uv_stride,
		src_u,
		uv_stride,
		w / 2,
		h / 2,
		buf.coded_width / 2,
		buf.coded_height / 2,
	)
	copy_plane(
		buf.v,
		buf.uv_stride,
		src_v,
		uv_stride,
		w / 2,
		h / 2,
		buf.coded_width / 2,
		buf.coded_height / 2,
	)
}

// Frame-level bitrate control. Bits scale as 2^(-qp/6), so each frame kind
// keeps a complexity estimate (its bits normalised to QP 0) and the next QP is
// solved directly from the share of the GOP budget that kind deserves, nudged by
// the accumulated overshoot.
rate_control_qp :: proc(state: ^Encoder_State, is_idr: bool) -> i32 {
	rate := &state.rate
	kind := int(is_idr)
	if rate.target_bits <= 0 do return state.config.qp
	if rate.complexity[kind] == 0 do return rate.qp[kind]
	gop := f64(max(state.config.gop_size, 1))
	p_complexity := rate.complexity[0] > 0 ? rate.complexity[0] : rate.complexity[1] / 4
	idr_complexity := rate.complexity[1] > 0 ? rate.complexity[1] : rate.complexity[0] * 4
	frame_target :=
		rate.target_bits *
		gop *
		rate.complexity[kind] /
		(idr_complexity + (gop - 1) * p_complexity)
	qp :=
		6 * math.log(rate.complexity[kind] / frame_target, 2) +
		6 * clamp(rate.overshoot / (rate.target_bits * gop), -1, 1)
	// P frames move at most 4 QP per frame for smoothness; IDR frames are rare, so let them jump to the model's answer
	if !is_idr do qp = clamp(qp, f64(rate.qp[0] - 4), f64(rate.qp[0] + 4))
	return clamp(i32(math.round(qp)), 10, 51)
}

rate_control_update :: proc(state: ^Encoder_State, bits: int, qp: i32, is_idr: bool) {
	rate := &state.rate
	if rate.target_bits <= 0 do return
	kind := int(is_idr)
	gop := f64(max(state.config.gop_size, 1))
	rate.overshoot = clamp(
		rate.overshoot + f64(bits) - rate.target_bits,
		-2 * rate.target_bits * gop,
		2 * rate.target_bits * gop,
	)
	complexity := f64(bits) * math.pow(2, f64(qp) / 6)
	rate.complexity[kind] =
		rate.complexity[kind] == 0 ? complexity : 0.75 * rate.complexity[kind] + 0.25 * complexity
	rate.qp[kind] = qp
}

// Synchronous convenience entrypoint over the same begin/advance/commit path.
// The caller's Work_Pool runs each preallocated slice item once and joins all
// items before returning; nil runs the same items serially.
encode_frame :: proc(
	state: ^Encoder_State,
	src_y: [^]u8,
	src_u: [^]u8,
	src_v: [^]u8,
	src_y_stride: int,
	src_uv_stride: int,
	is_idr: bool,
	out_stream: ^[dynamic]u8,
	pool: ^common.Work_Pool = nil,
) -> Error {
	if out_stream == nil do return .Output_Required
	if state.borrowed_output do return .Output_Owner_Mismatch
	if state.output_stream != nil && state.output_stream != out_stream do return .Output_Owner_Mismatch
	if err := begin_encode_frame(state, src_y, src_u, src_v, src_y_stride, src_uv_stride, is_idr); err != .None do return err
	if err := complete_encode_frame_work(state, pool); err != .None do return err
	return commit_encode_frame(state, out_stream)
}

// Borrow one ordered Annex B lane per NAL without copying the slice outputs.
// The descriptors and bytes are valid until the next begin, cancel or destroy.
// This mode has no seekable stream and cannot retain frame checkpoints.
encode_frame_lanes :: proc(
	state: ^Encoder_State,
	src_y, src_u, src_v: [^]u8,
	src_y_stride, src_uv_stride: int,
	is_idr: bool,
	pool: ^common.Work_Pool = nil,
) -> (
	lanes: [][]u8,
	err: Error,
) {
	if err = frame_lanes_admission_error(state); err != .None do return
	if err = begin_encode_frame(state, src_y, src_u, src_v, src_y_stride, src_uv_stride, is_idr); err != .None do return
	if err = complete_encode_frame_work(state, pool); err != .None do return
	return commit_frame_lanes(state)
}

@(private)
complete_encode_frame_work :: proc(state: ^Encoder_State, pool: ^common.Work_Pool) -> Error {
	for {
		ready, err := advance_encode_frame(state, state.macroblock_count, pool)
		if err != .None {cancel_encode_frame(state); return err}
		if ready do break
		if state.compute != nil && state.frame.phase == .Filtering do thread.yield()
	}
	return .None
}

// Single-owner API. Between advances the caller may pause or cancel. A frame
// cannot change the committed reference list, rate controller or stream.
begin_encode_frame :: proc(
	state: ^Encoder_State,
	src_y, src_u, src_v: [^]u8,
	y_stride, uv_stride: int,
	is_idr: bool,
) -> Error {
	state.error_detail = ""
	if state.macroblocks == nil || state.pictures == nil do return .Invalid_State
	if state.frame.phase != .Idle do return .Busy
	if state.num_refs == 0 && !is_idr do return .First_Frame_Must_Be_IDR
	if src_y == nil || src_u == nil || src_v == nil || y_stride < state.config.width || uv_stride < state.config.width / 2 do return .Invalid_Input

	// A reconstruction buffer that is not a current reference
	candidate: ^Encoder_Picture
	for &pic in state.pictures {
		used := pic.pins > 0
		if c := state.compute; c != nil && c.active && c.slot == pic.slot do used = true
		for r in 0 ..< state.num_refs do if state.refs[r] == &pic do used = true
		if !used {
			candidate = &pic
			break
		}
	}
	if candidate == nil do return .Picture_Capacity_Exhausted
	state.curr = candidate
	import_source(state, src_y, src_u, src_v, y_stride, uv_stride)
	state.epoch += 1
	state.frame = Encoder_Frame {
		phase      = .Coding,
		generation = state.epoch,
		is_idr     = is_idr,
		frame_num  = is_idr ? 0 : state.frame_num,
		idr_pic_id = is_idr ? (state.idr_pic_id + 1) & 0xFFFF : state.idr_pic_id,
		qp         = rate_control_qp(state, is_idr),
		num_slices = clamp(state.config.slice_count, 1, state.macroblock_rows),
	}
	state.curr.generation += 1
	state.curr.frame_num = i32(state.frame.frame_num)
	state.curr.pic_id = state.next_pic_id
	for i in 0 ..< state.macroblock_count do state.macroblocks[i].slice_index = 0xFFFF

	num_slices := state.frame.num_slices
	qp := state.frame.qp
	chroma_qp := i32(h264.chroma_qp_table[qp])
	for plane in 0 ..< 2 do for kind in 0 ..< 2 {
		state.frame.quantizers[plane][kind] = prepare_quantizer_4x4(plane == 0 ? qp : chroma_qp, kind == 1)
	}
	rows_per_slice := state.macroblock_rows / num_slices
	extra_rows := state.macroblock_rows % num_slices
	first_row := 0
	for &task, s in state.slices[:num_slices] {
		rows := rows_per_slice + (s < extra_rows ? 1 : 0)
		task = Slice_Task {
			state = state,
			first_macroblock = first_row * state.macroblock_columns,
			macroblock_count = rows * state.macroblock_columns,
			is_idr = is_idr,
			quantizer = qp,
			grid = {
				macroblocks = state.macroblocks,
				macroblock_columns = state.macroblock_columns,
				slice_index = u16(s),
				first_macroblock = first_row * state.macroblock_columns,
				end_macroblock = (first_row + rows) * state.macroblock_columns,
			},
			motion_lambda = motion_lambda_for_qp(qp),
			distortion_lambda = distortion_lambda_for_qp(qp),
			rbsp = task.rbsp,
			nal = task.nal,
		}
		task.next_macroblock = task.first_macroblock
		task.writer = h264.init_bit_writer(&task.rbsp)
		write_slice_header(&task, &task.writer)
		clear(&task.nal)
		first_row += rows
	}
	return .None
}

advance_encode_frame :: proc(
	state: ^Encoder_State,
	macroblocks_per_slice: int = 32,
	pool: ^common.Work_Pool = nil,
) -> (
	ready: bool,
	err: Error,
) {
	if state.frame.phase == .Idle do return false, .Invalid_State
	if macroblocks_per_slice <= 0 do return false, .Invalid_Input
	if state.frame.phase == .Ready do return true, .None
	slices := state.slices[:state.frame.num_slices]
	if state.frame.phase == .Coding {
		for &task in slices do task.work_limit = min(task.next_macroblock + macroblocks_per_slice, task.first_macroblock + task.macroblock_count)
		if pool != nil {
			pool.run(pool, len(slices), slice_encode_range, raw_data(slices))
		} else {
			slice_encode_range(raw_data(slices), 0, len(slices))
		}
		for &task in slices do if task.next_macroblock < task.first_macroblock + task.macroblock_count do return false, .None
		state.frame.phase = .Filtering
		return false, .None
	}
	if !state.config.disable_deblocking {
		if c := state.compute; c != nil {
			if !state.frame.compute_started {
				if retired, e := advance_compute(c); e != .None || !retired {
					state.error_detail = c.error_detail
					return false, e
				}
				if e := begin_compute_deblock(
					c,
					state.macroblocks,
					state.curr.slot,
					state.curr.generation,
					{0, 0},
				); e != .None {
					state.error_detail = c.error_detail
					return false, e
				}
				state.frame.compute_started = true
			}
			if done, e := advance_compute(c); e != .None || !done {
				state.error_detail = c.error_detail
				return false, e
			}
		} else {
			h264.deblock_picture(
				state.macroblocks,
				&state.curr.buf,
				state.macroblock_columns,
				state.macroblock_rows,
				{0, 0},
			)
		}
	}
	h264.expand_picture(&state.curr.buf)
	if pool != nil {
		pool.run(pool, len(slices), prepare_reference_interpolation_range, raw_data(slices))
	} else {
		prepare_reference_interpolation_range(raw_data(slices), 0, len(slices))
	}
	state.frame.phase = .Ready
	return true, .None
}

commit_encode_frame :: proc(state: ^Encoder_State, out_stream: ^[dynamic]u8) -> Error {
	if state.frame.phase != .Ready do return .Invalid_State
	if out_stream == nil do return .Output_Required
	if state.borrowed_output do return .Output_Owner_Mismatch
	if state.output_stream != nil && state.output_stream != out_stream do return .Output_Owner_Mismatch
	state.output_stream = out_stream
	for nal in prepare_frame_lanes(state) do append(out_stream, ..nal)
	promote_committed_frame(state)
	return .None
}

// Commit the same completed frame as an ordered borrowed view. Refusal leaves
// the Ready frame intact, so the caller can still commit its contiguous stream.
commit_frame_lanes :: proc(state: ^Encoder_State) -> (lanes: [][]u8, err: Error) {
	if state.frame.phase != .Ready do return nil, .Invalid_State
	if err = frame_lanes_admission_error(state); err != .None do return
	lanes = prepare_frame_lanes(state)
	state.borrowed_output = true
	promote_committed_frame(state)
	return
}

@(private)
frame_lanes_admission_error :: proc(state: ^Encoder_State) -> Error {
	if state.config.checkpoint_capacity != 0 || len(state.checkpoints) != 0 do return .Borrowed_Output_Checkpoints
	if state.output_stream != nil do return .Output_Owner_Mismatch
	return .None
}

@(private)
prepare_frame_lanes :: proc(state: ^Encoder_State) -> [][]u8 {
	count := 0
	if state.frame.is_idr {
		clear(&state.parameter_nals[0])
		clear(&state.parameter_nals[1])
		write_sequence_parameter_set(state, &state.parameter_nals[0])
		write_picture_parameter_set(state, &state.parameter_nals[1])
		for nal in state.parameter_nals {
			state.nal_lanes[count] = nal[:]
			count += 1
		}
	}
	for &task in state.slices[:state.frame.num_slices] {
		state.nal_lanes[count] = task.nal[:]
		count += 1
	}
	return state.nal_lanes[:count]
}

@(private)
promote_committed_frame :: proc(state: ^Encoder_State) {
	if state.frame.is_idr do state.num_refs = 0
	// Preserve the original rate domain: slice NAL bytes, excluding IDR SPS/PPS.
	bytes := 0
	for &task in state.slices[:state.frame.num_slices] do bytes += len(task.nal)

	// The reconstruction becomes a reference: filter, pad, insert at the front of the list
	for i := min(state.num_refs, state.config.num_ref_frames - 1); i > 0; i -= 1 do state.refs[i] = state.refs[i - 1]
	state.refs[0] = state.curr
	state.num_refs = min(state.num_refs + 1, state.config.num_ref_frames)

	rate_control_update(state, bytes * 8, state.frame.qp, state.frame.is_idr)
	state.frame_num = (state.frame.frame_num + 1) & 255
	state.idr_pic_id = state.frame.idr_pic_id
	state.next_pic_id += 1
	state.frames_coded += 1
	state.frame.phase = .Idle
}

cancel_encode_frame :: proc(state: ^Encoder_State) -> Error {
	if state.compute != nil do cancel_compute(state.compute)
	if state.frame.phase == .Idle do return .None
	state.epoch += 1
	state.frame = {}
	state.curr = state.num_refs > 0 ? state.refs[0] : nil
	return .None
}

slice_encode_range :: proc(data: rawptr, first, end: int) {
	// The synchronous map keeps the preallocated task storage alive, and each
	// worker owns a contiguous range of independent bitstream slices.
	for &task in slice.from_ptr(cast([^]Slice_Task)data, end)[first:end] do encode_slice_task(&task)
}

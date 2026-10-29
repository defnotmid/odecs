package h264_decoder

import h264 ".."

import "core:mem"

// ---------------------------------------------------------------------------
// Decoded picture buffer: picture order count, reference marking, reference
// picture lists and output order (clauses 8.2.1, 8.2.4, 8.2.5, C.4).
// ---------------------------------------------------------------------------

// MaxDpbMbs per level (Table A-1)
max_buffered_macroblocks :: proc(level: h264.Sequence_Level, constraint_set_3: bool) -> int {
	#partial switch level {
	case .Level_1b, .Level_1:
		return 396
	case .Level_1_1:
		return constraint_set_3 ? 396 : 900
	case .Level_1_2, .Level_1_3, .Level_2:
		return 2376
	case .Level_2_1:
		return 4752
	case .Level_2_2, .Level_3:
		return 8100
	case .Level_3_1:
		return 18000
	case .Level_3_2:
		return 20480
	case .Level_4, .Level_4_1:
		return 32768
	case .Level_4_2:
		return 34816
	case .Level_5:
		return 110400
	}
	return 184320
}

// Activate native allocation geometry. Pixel/motion storage is retained by
// each stable slot and allocated only when that slot is first used.
activate_sequence_parameter_set :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
) -> Error {
	// SPS activation may occur in a different caller/worker context from init.
	context.allocator = state.allocator.procedure != nil ? state.allocator : context.allocator
	coded_w := sequence_parameters.macroblock_columns * 16
	coded_h := sequence_parameters.macroblock_rows * 16
	format := sequence_buffer_format(sequence_parameters)
	resize :=
		state.macroblocks == nil ||
		state.storage_width != coded_w ||
		state.storage_height != coded_h ||
		state.storage_format != format
	if resize {
		macroblocks := make(#soa[]h264.Macroblock, sequence_parameters.macroblock_count)
		if macroblocks.type == nil || len(macroblocks) != sequence_parameters.macroblock_count {
			if macroblocks.type != nil do delete(macroblocks)
			return .Allocation_Failed
		}
		release_pictures(state)
		state.macroblocks = macroblocks
		state.storage_width, state.storage_height = coded_w, coded_h
		state.storage_format = format
		state.curr = nil
		state.output_count = 0
		state.output = nil
		state.max_long_term_frame_idx = -1
		state.prev_ref_frame_num = 0
		state.have_prev_slice = false
	}
	activate_sequence_parameter_set_metadata(state, sequence_parameters)
	return .None
}

// Picture sample layout of a sequence: u16 above 8 bits, full-height chroma for 4:2:2, full-size for 4:4:4, luma-only for 4:0:0.
sequence_buffer_format :: proc(sequence_parameters: ^h264.Sequence_Parameter_Set) -> h264.Buffer_Format {
	return {
		chroma_422 = sequence_parameters.chroma_format == .YUV_422,
		high_depth = sequence_parameters.luma_bit_depth_minus_8 != 0,
		chroma_444 = sequence_parameters.chroma_format == .YUV_444,
		monochrome = sequence_parameters.chroma_format == .Monochrome,
	}
}

// The native caller runs this after shared descriptor selection. Include gap
// references: native motion compensation can read their retained planes too.
// The metadata-only GPU path never calls this allocation owner.
@(private)
prepare_picture_storage :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
) -> Error {
	context.allocator = state.allocator.procedure != nil ? state.allocator : context.allocator
	for &pic in state.pics {
		if !pic.in_use || raw_data(pic.buf.memory) != nil do continue
		memory, memory_error := make(
			[]u8,
			h264.yuv_buffer_size(state.storage_width, state.storage_height, state.storage_format),
		)
		if memory_error != nil || raw_data(memory) == nil {
			if raw_data(memory) != nil do delete(memory)
			return .Allocation_Failed
		}
		motion, motion_error := make([]Reference_Motion, sequence_parameters.macroblock_count)
		if motion_error != nil || raw_data(motion) == nil {
			delete(memory)
			if raw_data(motion) != nil do delete(motion)
			return .Allocation_Failed
		}
		pic.buf = h264.yuv_buffer_view(state.storage_width, state.storage_height, raw_data(memory), state.storage_format)
		pic.buf.memory, pic.motion = memory, motion
		set_picture_display(&pic, sequence_parameters)
	}
	return .None
}

// Shared SPS/DPB semantics for native reconstruction and hardware syntax
// frontends. This updates descriptors only; no pixel or motion allocation.
activate_sequence_parameter_set_metadata :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
) {
	// Allocation shape and active SPS semantics have different lifetimes.
	// Pictures still held for output retain the crop with which they were decoded.
	for &pic in state.pics {
		if !pic.in_use do set_picture_display(&pic, sequence_parameters)
	}

	state.dpb_size = clamp(
		max_buffered_macroblocks(sequence_parameters.level, sequence_parameters.constraint_set_3) /
		max(sequence_parameters.macroblock_count, 1),
		1,
		16,
	)
	if sequence_parameters.has_bitstream_restrictions {
		state.dpb_size = clamp(int(sequence_parameters.max_buffered_frames), 1, 16)
		state.max_reorder = min(int(sequence_parameters.max_reordered_frames), state.dpb_size)
	} else if sequence_parameters.profile == .Baseline ||
	   sequence_parameters.constraint_set_0 ||
	   sequence_parameters.constraint_set_1 ||
	   sequence_parameters.picture_order_mode == .Frame_Number {
		state.max_reorder = 0 // no B pictures in Baseline / Constrained Baseline / POC type 2
	} else {
		state.max_reorder = state.dpb_size
	}
	state.dpb_size = max(state.dpb_size, int(sequence_parameters.max_reference_frames))
	if state.no_reordering do state.max_reorder = 0
}

set_picture_display :: proc(pic: ^Picture, sequence_parameters: ^h264.Sequence_Parameter_Set) {
	pic.bit_depth = 8 + int(sequence_parameters.luma_bit_depth_minus_8)
	pic.buf.width = sequence_parameters.width
	pic.buf.height = sequence_parameters.height
	// CropUnitX is SubWidthC (1 for Monochrome/4:4:4, 2 for 4:2:0/4:2:2);
	// CropUnitY is SubHeightC (1 for Monochrome/4:2:2/4:4:4, 2 for 4:2:0), doubled for field coding (7-19, 7-20).
	sub_width := (sequence_parameters.chroma_format == .Monochrome || sequence_parameters.chroma_format == .YUV_444) ? 1 : 2
	sub_height := sequence_parameters.chroma_format == .YUV_420 ? 2 : 1
	pic.buf.crop_x = int(sequence_parameters.crop_left) * sub_width
	pic.buf.crop_y = int(sequence_parameters.crop_top) * (sequence_parameters.frames_only ? sub_height : 2 * sub_height)
}

release_pictures :: proc(state: ^Decoder_State) {
	context.allocator = state.allocator.procedure != nil ? state.allocator : context.allocator
	for &pic in state.pics {
		h264.free_yuv_buffer(&pic.buf)
		delete(pic.motion)
		pic = {}
	}
	if state.macroblocks != nil {
		delete(state.macroblocks)
		state.macroblocks = nil
	}
	state.storage_width, state.storage_height = 0, 0
	state.storage_format = {}
}

// Release pictures that are neither referenced nor waiting for output. Output
// handed to the caller is valid until the next decode_nal call, so this runs
// at the start of every slice.
release_unused_pictures :: proc(state: ^Decoder_State) {
	for i in 0 ..< state.output_count do state.output_queue[i].needed_for_output = false
	state.output_count = 0
	for &pic in state.pics {
		if pic.in_use && &pic != state.curr && !pic.needed_for_output && !pic.is_short_ref && !pic.is_long_ref do pic.in_use = false
	}
}

// Move the picture with the smallest POC that waits for output to the output queue.
bump_one :: proc(state: ^Decoder_State) -> bool {
	best: ^Picture
	for &pic in state.pics {
		if pic.in_use && pic.needed_for_output && (best == nil || pic.poc < best.poc) do best = &pic
	}
	if best == nil do return false
	best.needed_for_output = false
	if state.output_count < len(state.output_queue) {
		state.output_queue[state.output_count] = best
		state.output_count += 1
	} else if !best.is_short_ref && !best.is_long_ref {
		best.in_use = false
	}
	return true
}

// Output everything still waiting, in POC order.
flush_output :: proc(state: ^Decoder_State) {
	for bump_one(state) {}
}

waiting_for_output :: proc(state: ^Decoder_State) -> (n: int) {
	for &pic in state.pics do if pic.in_use && pic.needed_for_output do n += 1
	return
}

// DPB fullness (C.4.5.3): pictures held for reference or output
pictures_in_use :: proc(state: ^Decoder_State) -> (n: int) {
	for &pic in state.pics do if pic.in_use && &pic != state.curr && (pic.is_short_ref || pic.is_long_ref || pic.needed_for_output) do n += 1
	return
}

// A free slot for the next picture, making room by output or, failing that,
// by dropping the oldest reference (damaged streams only).
alloc_picture :: proc(state: ^Decoder_State) -> ^Picture {
	for {
		for &pic in state.pics {
			if !pic.in_use {
				pic.in_use = true
				pic.is_short_ref = false
				pic.is_long_ref = false
				pic.needed_for_output = false
				pic.non_existing = false
				pic.is_idr = false
				pic.pic_id = state.next_pic_id
				state.next_pic_id += 1
				return &pic
			}
		}
		if bump_one(state) do continue
		oldest: ^Picture
		for &pic in state.pics {
			if pic.in_use && (pic.is_short_ref || pic.is_long_ref) && (oldest == nil || pic.frame_num_wrap < oldest.frame_num_wrap) do oldest = &pic
		}
		if oldest == nil do return nil
		oldest.is_short_ref = false
		oldest.is_long_ref = false
		oldest.in_use = false
	}
}

// Picture order count of the current picture (8.2.1), frames only.
compute_poc :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	header: ^h264.Slice_Header,
) -> i32 {
	counts := compute_poc_counts(state, sequence_parameters, header)
	return min(counts[0], counts[1])
}

// Retain both field counts rather than reconstructing them from the minimum
// picture POC in a hardware frontend. All reference-history updates stay here.
compute_poc_counts :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	header: ^h264.Slice_Header,
) -> [2]i32 {
	max_frame_num := i32(1) << uint(sequence_parameters.frame_number_bits)
	frame_num := i32(header.frame_num)
	#partial switch sequence_parameters.picture_order_mode {
	case .Explicit_Low_Bits:
		max_lsb := i32(1) << uint(sequence_parameters.picture_order_low_bits)
		prev_msb, prev_lsb := state.prev_poc_msb, state.prev_poc_lsb
		if header.is_idr do prev_msb, prev_lsb = 0, 0
		lsb := i32(header.pic_order_cnt_lsb)
		msb := prev_msb
		if lsb < prev_lsb && prev_lsb - lsb >= max_lsb / 2 {
			msb = prev_msb + max_lsb
		} else if lsb > prev_lsb && lsb - prev_lsb > max_lsb / 2 {
			msb = prev_msb - max_lsb
		}
		top := msb + lsb
		bottom := top + header.delta_pic_order_cnt_bottom
		if header.nal_ref_idc != 0 {
			state.prev_poc_msb = msb
			state.prev_poc_lsb = lsb
		}
		return {top, bottom}
	case .Reference_Cycle:
		prev_offset := state.prev_ref_has_mmco5 ? 0 : state.prev_frame_num_offset
		offset: i32 = 0
		if !header.is_idr do offset = state.prev_frame_num > frame_num ? prev_offset + max_frame_num : prev_offset
		abs_frame_num: i32 = 0
		if sequence_parameters.reference_cycle_length != 0 do abs_frame_num = offset + frame_num
		if header.nal_ref_idc == 0 && abs_frame_num > 0 do abs_frame_num -= 1
		expected: i32 = 0
		if abs_frame_num > 0 {
			cycle := i32(sequence_parameters.reference_cycle_length)
			delta_per_cycle: i32 = 0
			for i in 0 ..< cycle do delta_per_cycle += sequence_parameters.reference_frame_order_offsets[i]
			cycle_cnt := (abs_frame_num - 1) / cycle
			in_cycle := (abs_frame_num - 1) % cycle
			expected = cycle_cnt * delta_per_cycle
			for i in 0 ..= in_cycle do expected += sequence_parameters.reference_frame_order_offsets[i]
		}
		if header.nal_ref_idc == 0 do expected += sequence_parameters.non_reference_picture_order_offset
		top := expected + header.delta_pic_order_cnt[0]
		bottom :=
			top +
			sequence_parameters.top_to_bottom_field_order_offset +
			header.delta_pic_order_cnt[1]
		state.prev_frame_num_offset = offset
		state.prev_frame_num = frame_num
		return {top, bottom}
	case:
		prev_offset := state.prev_ref_has_mmco5 ? 0 : state.prev_frame_num_offset
		offset: i32 = 0
		if !header.is_idr do offset = state.prev_frame_num > frame_num ? prev_offset + max_frame_num : prev_offset
		state.prev_frame_num_offset = offset
		state.prev_frame_num = frame_num
		count :=
			header.is_idr ? 0 : (header.nal_ref_idc == 0 ? 2 * (offset + frame_num) - 1 : 2 * (offset + frame_num))
		return {count, count}
	}
}

// Sliding window marking (8.2.5.3): drop the oldest short-term reference when
// the window is full.
sliding_window :: proc(state: ^Decoder_State, sequence_parameters: ^h264.Sequence_Parameter_Set) {
	num_short, num_long := 0, 0
	oldest: ^Picture
	for &pic in state.pics {
		if !pic.in_use || &pic == state.curr do continue
		if pic.is_long_ref do num_long += 1
		if pic.is_short_ref {
			num_short += 1
			if oldest == nil || pic.frame_num_wrap < oldest.frame_num_wrap do oldest = &pic
		}
	}
	if num_short + num_long >= int(max(sequence_parameters.max_reference_frames, 1)) &&
	   oldest != nil {
		oldest.is_short_ref = false
		if !oldest.needed_for_output do oldest.in_use = false
	}
}

// FrameNumWrap of every short-term reference relative to the current frame_num.
update_frame_num_wrap :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	curr_frame_num: i32,
) {
	max_frame_num := i32(1) << uint(sequence_parameters.frame_number_bits)
	for &pic in state.pics {
		if pic.in_use && pic.is_short_ref {
			pic.frame_num_wrap =
				pic.frame_num > curr_frame_num ? pic.frame_num - max_frame_num : pic.frame_num
		}
	}
}

// Frames missing from frame_num (8.2.5.2): insert "non-existing" short-term
// references so PicNum arithmetic and the sliding window stay right.
fill_frame_num_gap :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	header: ^h264.Slice_Header,
) {
	max_frame_num := i32(1) << uint(sequence_parameters.frame_number_bits)
	frame_num := i32(header.frame_num)
	if header.is_idr || frame_num == state.prev_ref_frame_num || frame_num == (state.prev_ref_frame_num + 1) % max_frame_num do return
	if !sequence_parameters.allow_frame_number_gaps do return // damaged stream: keep going with what we have
	missing := (state.prev_ref_frame_num + 1) % max_frame_num
	for missing != frame_num {
		update_frame_num_wrap(state, sequence_parameters, missing)
		sliding_window(state, sequence_parameters)
		pic := alloc_picture(state)
		if pic == nil do break
		pic.non_existing = true
		pic.is_short_ref = true
		pic.frame_num = missing
		pic.frame_num_wrap = missing
		pic.poc = 0
		missing = (missing + 1) % max_frame_num
	}
	state.prev_ref_frame_num = frame_num
}

// Adaptive reference marking (8.2.5.4).
apply_mmco :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	header: ^h264.Slice_Header,
) {
	curr := state.curr
	max_frame_num := i32(1) << uint(sequence_parameters.frame_number_bits)
	curr_pic_num := i32(header.frame_num)
	find_short :: proc(state: ^Decoder_State, pic_num: i32) -> ^Picture {
		for &pic in state.pics do if pic.in_use && pic.is_short_ref && &pic != state.curr && pic.frame_num_wrap == pic_num do return &pic
		return nil
	}
	find_long :: proc(state: ^Decoder_State, idx: i32) -> ^Picture {
		for &pic in state.pics do if pic.in_use && pic.is_long_ref && &pic != state.curr && pic.long_term_frame_idx == idx do return &pic
		return nil
	}
	unmark :: proc(pic: ^Picture) {
		if pic == nil do return
		pic.is_short_ref = false
		pic.is_long_ref = false
		if !pic.needed_for_output do pic.in_use = false
	}
	for cmd in header.mmco[:header.num_mmco] {
		switch cmd.op {
		case 1:
			unmark(find_short(state, curr_pic_num - i32(cmd.arg1) - 1))
		case 2:
			unmark(find_long(state, i32(cmd.arg1)))
		case 3:
			pic := find_short(state, curr_pic_num - i32(cmd.arg1) - 1)
			if pic == nil do continue
			unmark(find_long(state, i32(cmd.arg2)))
			pic.is_short_ref = false
			pic.is_long_ref = true
			pic.long_term_frame_idx = i32(cmd.arg2)
		case 4:
			state.max_long_term_frame_idx = i32(cmd.arg1) - 1
			for &pic in state.pics {
				if pic.in_use && pic.is_long_ref && pic.long_term_frame_idx > state.max_long_term_frame_idx do unmark(&pic)
			}
		case 5:
			for &pic in state.pics do if pic.in_use && &pic != curr do unmark(&pic)
			state.max_long_term_frame_idx = -1
		case 6:
			unmark(find_long(state, i32(cmd.arg2)))
			curr.is_long_ref = true
			curr.is_short_ref = false
			curr.long_term_frame_idx = i32(cmd.arg2)
		}
	}
	_ = max_frame_num
}

// Reference marking and output handling after the last slice of a picture (8.2.5, C.4.5).
finish_picture_marking :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	header: ^h264.Slice_Header,
) {
	curr := state.curr
	if header.is_idr {
		for &pic in state.pics {
			if !pic.in_use || &pic == curr do continue
			pic.is_short_ref = false
			pic.is_long_ref = false
			if header.no_output_of_prior_pics_flag {
				pic.needed_for_output = false
				pic.in_use = false
			}
		}
		flush_output(state)
		if header.long_term_reference_flag {
			curr.is_long_ref = true
			curr.long_term_frame_idx = 0
			state.max_long_term_frame_idx = 0
		} else {
			curr.is_short_ref = true
			state.max_long_term_frame_idx = -1
		}
	} else if header.nal_ref_idc != 0 {
		if header.adaptive_ref_pic_marking_flag {
			apply_mmco(state, sequence_parameters, header)
			if header.mmco5 {
				flush_output(state)
				curr.frame_num = 0
				curr.field_order_counts[0] -= curr.poc
				curr.field_order_counts[1] -= curr.poc
				curr.poc = 0
			}
		} else {
			sliding_window(state, sequence_parameters)
		}
		if !curr.is_long_ref do curr.is_short_ref = true
	}
	curr.needed_for_output = true
	curr.frame_num_wrap = curr.frame_num

	state.prev_ref_has_mmco5 = header.nal_ref_idc != 0 && header.mmco5
	if header.nal_ref_idc != 0 {
		state.prev_ref_frame_num = header.mmco5 ? 0 : i32(header.frame_num)
		if header.mmco5 {
			state.prev_poc_msb = 0
			state.prev_poc_lsb = 0
			state.prev_frame_num = 0
			state.prev_frame_num_offset = 0
		}
	}

	// C.4.5.3 bumping: output while more pictures wait than the reorder depth
	// allows, or the buffer is full.
	for waiting_for_output(state) > state.max_reorder do if !bump_one(state) do break
	for pictures_in_use(state) + 1 > state.dpb_size do if !bump_one(state) do break
}

// Copy the motion of the current picture for later direct prediction.
save_col_motion :: proc(state: ^Decoder_State, macroblock_count: int) {
	for i in 0 ..< macroblock_count {
		mb := &state.macroblocks[i]
		m := &state.curr.motion[i]
		m.motion_vectors = mb.motion_vectors
		m.reference_picture_ids = mb.reference_picture_ids
		m.reference_indices = mb.reference_indices
		m.prediction_directions = mb.prediction_directions
		m.is_intra = mb.is_intra
		for l in 0 ..< 2 do for k in 0 ..< 4 {
			m.reference_picture_order_counts[l][k] = 0
			if mb.reference_indices[l][k] >= 0 && int(mb.reference_indices[l][k]) < state.ref_count[l] {
				if ref := state.ref_list[l][mb.reference_indices[l][k]]; ref != nil do m.reference_picture_order_counts[l][k] = ref.poc
			}
		}
	}
}

// Initial reference picture lists (8.2.4.2) and their modification (8.2.4.3).
// Native decoding retains its damaged-stream substitution. Hardware callers
// use complete to refuse a list whose requested references were unavailable.
build_ref_lists :: proc(
	state: ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	header: ^h264.Slice_Header,
) -> (
	complete: bool = true,
) {
	state.ref_count = {0, 0}
	for l in 0 ..< 2 do for i in 0 ..< len(state.ref_list[l]) do state.ref_list[l][i] = nil
	if header.slice_type == .I || header.slice_type == .SI do return true

	max_frame_num := i32(1) << uint(sequence_parameters.frame_number_bits)
	curr_pic_num := i32(header.frame_num)
	update_frame_num_wrap(state, sequence_parameters, curr_pic_num)

	short_refs: [MAX_PICTURES]^Picture
	long_refs: [MAX_PICTURES]^Picture
	ns, nl := 0, 0
	for &pic in state.pics {
		if !pic.in_use || &pic == state.curr do continue
		if pic.is_short_ref {short_refs[ns] = &pic; ns += 1}
		if pic.is_long_ref {long_refs[nl] = &pic; nl += 1}
	}
	sort_by :: proc(list: []^Picture, less: proc(a, b: ^Picture) -> bool) {
		for i in 1 ..< len(list) {
			for j := i; j > 0 && less(list[j], list[j - 1]); j -= 1 do list[j], list[j - 1] = list[j - 1], list[j]
		}
	}
	sort_by(
		long_refs[:nl],
		proc(a, b: ^Picture) -> bool {return a.long_term_frame_idx < b.long_term_frame_idx},
	)

	initial: [2][MAX_PICTURES * 2]^Picture
	count: [2]int
	if header.slice_type == .B {
		poc := state.curr.poc
		before, after: [MAX_PICTURES]^Picture
		nb, na := 0, 0
		for pic in short_refs[:ns] {
			if pic.poc <= poc {before[nb] = pic; nb += 1} else {after[na] = pic; na += 1}
		}
		sort_by(before[:nb], proc(a, b: ^Picture) -> bool {return a.poc > b.poc})
		sort_by(after[:na], proc(a, b: ^Picture) -> bool {return a.poc < b.poc})
		for pic in before[:nb] {initial[0][count[0]] = pic; count[0] += 1}
		for pic in after[:na] {initial[0][count[0]] = pic; count[0] += 1}
		for pic in after[:na] {initial[1][count[1]] = pic; count[1] += 1}
		for pic in before[:nb] {initial[1][count[1]] = pic; count[1] += 1}
		for l in 0 ..< 2 do for pic in long_refs[:nl] {initial[l][count[l]] = pic; count[l] += 1}
		if count[1] > 1 && count[0] == count[1] {
			same := true
			for i in 0 ..< count[0] do if initial[0][i] != initial[1][i] {same = false; break}
			if same do initial[1][0], initial[1][1] = initial[1][1], initial[1][0]
		}
	} else {
		sort_by(
			short_refs[:ns],
			proc(a, b: ^Picture) -> bool {return a.frame_num_wrap > b.frame_num_wrap},
		)
		for pic in short_refs[:ns] {initial[0][count[0]] = pic; count[0] += 1}
		for pic in long_refs[:nl] {initial[0][count[0]] = pic; count[0] += 1}
	}

	lists := header.slice_type == .B ? 2 : 1
	for l in 0 ..< lists {
		active := int(l == 0 ? header.num_ref_idx_l0_active : header.num_ref_idx_l1_active)
		state.ref_count[l] = active
		// One entry longer than the final list while modifying (8.2.4.3)
		list: [33]^Picture
		for i in 0 ..< active do list[i] = i < count[l] ? initial[l][i] : nil

		pic_num_pred := curr_pic_num
		for cmd, pos in header.reorder[l][:header.num_reorder[l]] {
			if pos >= active do break
			picture: ^Picture
			if cmd.idc < 2 {
				diff := i32(cmd.value) + 1
				no_wrap := cmd.idc == 0 ? pic_num_pred - diff : pic_num_pred + diff
				if no_wrap < 0 do no_wrap += max_frame_num
				if no_wrap >= max_frame_num do no_wrap -= max_frame_num
				pic_num_pred = no_wrap
				wanted := no_wrap > curr_pic_num ? no_wrap - max_frame_num : no_wrap
				for pic in short_refs[:ns] do if pic.frame_num_wrap == wanted {picture = pic; break}
			} else {
				for pic in long_refs[:nl] do if pic.long_term_frame_idx == i32(cmd.value) {picture = pic; break}
			}
			if picture == nil {complete = false; continue}
			for i := active; i > pos; i -= 1 do list[i] = list[i - 1]
			list[pos] = picture
			n := pos + 1
			for i in pos + 1 ..= active {
				if list[i] != picture {
					list[n] = list[i]
					n += 1
				}
			}
		}

		// Missing references (damaged streams): substitute the nearest available one.
		fallback: ^Picture
		for i in 0 ..< active do if list[i] != nil {fallback = list[i]; break}
		if fallback == nil do fallback = count[l] > 0 ? initial[l][0] : nil
		for i in 0 ..< active {
			if list[i] == nil do complete = false
			state.ref_list[l][i] = list[i] != nil ? list[i] : fallback
		}
	}
	return complete
}

// Fill a picture with mid-grey; used when a reference is missing entirely.
clear_picture :: proc(pic: ^Picture) {
	mem.set(raw_data(pic.buf.memory), 128, len(pic.buf.memory))
}

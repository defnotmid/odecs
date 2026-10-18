package h264_decoder

import h264 ".."


// ---------------------------------------------------------------------------
// Slice data decoding (7.3.4, 7.3.5): macroblock parsing shared by CAVLC and
// CABAC, prediction, and reconstruction of the current picture.
// ---------------------------------------------------------------------------

Slice_Decoder :: struct {
	state:               ^Decoder_State,
	sequence_parameters: ^h264.Sequence_Parameter_Set,
	picture_parameters:  ^h264.Picture_Parameter_Set,
	header:              ^h264.Slice_Header,
	reader:              ^h264.Bit_Reader,
	cabac:               bool,
	engine:              ^Cabac_Engine,
	using grid:          h264.Macroblock_Grid,
	picture:             ^Picture,
	macroblock_count:    int,
	// Sample format: bit depth with QpBdOffset = 6 * (bit_depth - 8), and
	// 4:2:2 chroma (8 chroma 4x4 blocks per plane instead of 4).
	bit_depth:           int,
	qp_bd_offset:        i32,
	chroma_422:          bool,
	qp:                  i32, // running QP_Y (from -qp_bd_offset to 51)
	prev_qp_delta_nz:    bool, // CABAC context for mb_qp_delta
	chroma_qp:           [2]i32, // QP'_C of Cb and Cr for the current macroblock
	skip_run:            int, // CAVLC: skipped macroblocks still owed, -1 when a run must be read
	// The current macroblock's available left and top neighbours (-1 when
	// unavailable), fixed while it decodes.
	left_index:          int,
	top_index:           int,
	last_skipped_direct: bool, // CABAC B_Skip inference is not needed; kept for symmetry
}

// Levels of every residual block of one macroblock in scan order: i16, or
// i32 above 8 bits (the levels of 10-bit residuals exceed 16 bits). Chroma
// has 4 DC levels and 4 AC blocks per plane, 8 of each in 4:2:2.
Residual :: struct($L: typeid) {
	luma_dc_coefficients:   [16]L,
	luma:                   [16][16]L, // per 4x4 block in decoding order (AC-only for I_16x16: index 0 unused)
	luma8x8:                [4][64]L,
	chroma_dc_coefficients: [2][8]L,
	chroma_ac_coefficients: [2][8][16]L, // raster order, two per row; index 0 unused (DC)
	luma_nz:                [16]bool,
	luma8x8_nz:             [4]bool,
}

// Residual block categories (ctxBlockCat, Table 9-42)
Block_Cat :: enum u8 {
	Luma_DC   = 0,
	Luma_AC   = 1,
	Luma_4x4  = 2,
	Chroma_DC = 3,
	Chroma_AC = 4,
	Luma_8x8  = 5,
}

// Decode all macroblocks of the slice. Returns an error for malformed data.
decode_slice_data :: proc(decoder: ^Slice_Decoder) -> Error {
	if decoder.bit_depth > 8 do return decode_slice_macroblocks(decoder, u16)
	return decode_slice_macroblocks(decoder, u8)
}

// The slice's macroblocks, reconstructed into a picture of T samples.
decode_slice_macroblocks :: proc(decoder: ^Slice_Decoder, $T: typeid) -> Error {
	header := decoder.header
	state := decoder.state
	decoder.qp = header.slice_qp
	decoder.skip_run = -1
	if decoder.cabac {
		h264.byte_align(decoder.reader) // cabac_alignment_one_bit
		cabac_init_contexts(
			decoder.engine,
			header.slice_type,
			header.cabac_init_idc,
			header.slice_qp,
		)
		cabac_init_engine(decoder.engine, decoder.reader)
	}

	macroblock_index := header.first_mb_in_slice
	for macroblock_index < decoder.macroblock_count {
		if !decoder.cabac && decoder.skip_run <= 0 && !h264.has_more_rbsp_data(decoder.reader) do break

		macroblock := &decoder.macroblocks[macroblock_index]
		if macroblock.slice_index == decoder.slice_index do return .Duplicate_Macroblock
		macroblock^ = {}
		macroblock.slice_index = decoder.slice_index
		decoder.left_index = h264.left_macroblock(&decoder.grid, macroblock_index)
		decoder.top_index = h264.top_macroblock(&decoder.grid, macroblock_index)
		macroblock.deblocking_mode = header.deblocking_mode
		macroblock.alpha_offset = i8(header.slice_alpha_c0_offset_div2)
		macroblock.beta_offset = i8(header.slice_beta_offset_div2)
		for l in 0 ..< 2 do for k in 0 ..< 4 {
			macroblock.reference_indices[l][k] = -1
			macroblock.reference_picture_ids[l][k] = -1
		}

		skip := false
		if header.slice_type != .I {
			if decoder.cabac {
				skip = cabac_read_mb_skip(decoder, macroblock_index)
			} else {
				if decoder.skip_run < 0 {
					decoder.skip_run = int(h264.read_ue(decoder.reader))
					if decoder.skip_run > decoder.macroblock_count - macroblock_index do return .Skip_Run_Out_Of_Range
				}
				if decoder.skip_run > 0 {
					skip = true
					decoder.skip_run -= 1
				} else {
					decoder.skip_run = -1
				}
			}
		}

		err: Error
		if skip {
			decode_skip_macroblock(decoder, macroblock_index, T)
		} else {
			err = decode_macroblock(decoder, macroblock_index, T)
		}
		if err != .None do return err
		state.mbs_decoded += 1
		macroblock_index += 1

		if decoder.cabac && cabac_decode_terminate(decoder.engine, decoder.reader) == 1 do break
	}
	return .None
}

// P_Skip and B_Skip: prediction only, no residual (7.4.5, 8.4.1.1, 8.4.1.2).
decode_skip_macroblock :: proc(decoder: ^Slice_Decoder, macroblock_index: int, $T: typeid) {
	macroblock := &decoder.macroblocks[macroblock_index]
	macroblock.is_skip = true
	macroblock.quantizer = i8(decoder.qp)
	decoder.prev_qp_delta_nz = false
	if decoder.header.slice_type == .B {
		macroblock.type = .B_Skip
		derive_direct(decoder, macroblock_index, 0xF)
	} else {
		macroblock.type = .P_Skip
		mv := h264.predict_skip_motion_vector(&decoder.grid, macroblock_index)
		for k in 0 ..< 16 do macroblock.motion_vectors[0][k] = mv
		for k in 0 ..< 4 {
			macroblock.reference_indices[0][k] = 0
			macroblock.prediction_directions[k] = h264.Prediction_Direction.List_0
		}
	}
	set_ref_pics(decoder, macroblock_index)
	predict_inter_macroblock(decoder, macroblock_index, T)
}

// Raw macroblock type value to the macroblock kind of the slice type (Tables 7-11, 7-13, 7-14).
// B partition prediction directions are stored in prediction_directions.
classify_mb_type :: proc(
	decoder: ^Slice_Decoder,
	macroblock: #soa^#soa[]h264.Macroblock,
	raw: u32,
) -> (
	intra_raw: i32,
	ok: bool,
) {
	raw := raw
	switch decoder.header.slice_type {
	case .P, .SP:
		switch raw {
		case 0:
			macroblock.type = .P_L0_16x16
		case 1:
			macroblock.type = .P_L0_L0_16x8
		case 2:
			macroblock.type = .P_L0_L0_8x16
		case 3:
			macroblock.type = .P_8x8
		case 4:
			macroblock.type = .P_8x8ref0
		case:
			return i32(raw) - 5, raw - 5 <= 25
		}
		for k in 0 ..< 4 do macroblock.prediction_directions[k] = h264.Prediction_Direction.List_0
		return -1, true
	case .B:
		if raw >= 23 do return i32(raw) - 23, raw - 23 <= 25
		// Table 7-14: directions of the two partitions for macroblock type 1..21
		dirs := [22][2]h264.Prediction_Direction {
			{.None, .None},
			{h264.Prediction_Direction.List_0, h264.Prediction_Direction.List_0},
			{h264.Prediction_Direction.List_1, h264.Prediction_Direction.List_1},
			{h264.Prediction_Direction.Bidirectional, h264.Prediction_Direction.Bidirectional},
			{h264.Prediction_Direction.List_0, h264.Prediction_Direction.List_0},
			{h264.Prediction_Direction.List_0, h264.Prediction_Direction.List_0},
			{h264.Prediction_Direction.List_1, h264.Prediction_Direction.List_1},
			{h264.Prediction_Direction.List_1, h264.Prediction_Direction.List_1},
			{h264.Prediction_Direction.List_0, h264.Prediction_Direction.List_1},
			{h264.Prediction_Direction.List_0, h264.Prediction_Direction.List_1},
			{h264.Prediction_Direction.List_1, h264.Prediction_Direction.List_0},
			{h264.Prediction_Direction.List_1, h264.Prediction_Direction.List_0},
			{h264.Prediction_Direction.List_0, h264.Prediction_Direction.Bidirectional},
			{h264.Prediction_Direction.List_0, h264.Prediction_Direction.Bidirectional},
			{h264.Prediction_Direction.List_1, h264.Prediction_Direction.Bidirectional},
			{h264.Prediction_Direction.List_1, h264.Prediction_Direction.Bidirectional},
			{h264.Prediction_Direction.Bidirectional, h264.Prediction_Direction.List_0},
			{h264.Prediction_Direction.Bidirectional, h264.Prediction_Direction.List_0},
			{h264.Prediction_Direction.Bidirectional, h264.Prediction_Direction.List_1},
			{h264.Prediction_Direction.Bidirectional, h264.Prediction_Direction.List_1},
			{h264.Prediction_Direction.Bidirectional, h264.Prediction_Direction.Bidirectional},
			{h264.Prediction_Direction.Bidirectional, h264.Prediction_Direction.Bidirectional},
		}
		switch {
		case raw == 0:
			macroblock.type = .B_Direct_16x16
		case raw <= 3:
			macroblock.type = .B_16x16
			for k in 0 ..< 4 do macroblock.prediction_directions[k] = dirs[raw][0]
		case raw == 22:
			macroblock.type = .B_8x8
		case raw & 1 == 0:
			// 4, 6, ..., 20: 16x8
			macroblock.type = .B_16x8
			macroblock.prediction_directions = {
				dirs[raw][0],
				dirs[raw][0],
				dirs[raw][1],
				dirs[raw][1],
			}
		case:
			// 5, 7, ..., 21: 8x16
			macroblock.type = .B_8x16
			macroblock.prediction_directions = {
				dirs[raw][0],
				dirs[raw][1],
				dirs[raw][0],
				dirs[raw][1],
			}
		}
		return -1, true
	case .I, .SI:
		return i32(raw), raw <= 25
	}
	return -1, false
}

decode_macroblock :: proc(decoder: ^Slice_Decoder, macroblock_index: int, $T: typeid) -> Error {
	macroblock := &decoder.macroblocks[macroblock_index]
	picture_parameters := decoder.picture_parameters

	raw := cabac_or_cavlc_mb_type(decoder, macroblock_index)
	intra_raw, ok := classify_mb_type(decoder, macroblock, raw)
	if !ok do return .Invalid_Macroblock_Type

	if intra_raw >= 0 {
		macroblock.is_intra = true
		switch {
		case intra_raw == 0:
			macroblock.type = .I_4x4
			if picture_parameters.transform_8x8_mode_flag &&
			   read_transform_8x8_flag(decoder, macroblock_index) {
				macroblock.type = .I_8x8
				macroblock.uses_8x8_transform = true
			}
		case intra_raw <= 24:
			macroblock.type = .I_16x16
			mode := intra_raw - 1
			macroblock.intra_16x16_mode = h264.Intra_16x16_Mode(mode % 4)
			macroblock.chroma_residual_mode = h264.Chroma_Residual_Mode((mode / 4) % 3)
			macroblock.luma_coded_block_mask = mode >= 12 ? 15 : 0
		case:
			macroblock.type = .I_PCM
			return decode_pcm(decoder, macroblock_index, T)
		}
	}

	// mb_pred / sub_mb_pred (7.3.5.1, 7.3.5.2)
	switch macroblock.type {
	case .I_4x4, .I_8x8:
		read_intra_modes(decoder, macroblock_index)
		macroblock.chroma_prediction_mode = h264.Intra_Chroma_Mode(
			read_intra_chroma_mode(decoder, macroblock_index),
		)
		if macroblock.chroma_prediction_mode > .Plane do return .Invalid_Chroma_Prediction_Mode
	case .I_16x16:
		macroblock.chroma_prediction_mode = h264.Intra_Chroma_Mode(
			read_intra_chroma_mode(decoder, macroblock_index),
		)
		if macroblock.chroma_prediction_mode > .Plane do return .Invalid_Chroma_Prediction_Mode
	case .B_Direct_16x16:
		derive_direct(decoder, macroblock_index, 0xF)
	case .P_8x8, .P_8x8ref0, .B_8x8:
		if err := read_sub_macroblock_prediction(decoder, macroblock_index); err != .None do return err
	case .P_L0_16x16, .P_L0_L0_16x8, .P_L0_L0_8x16, .B_16x16, .B_16x8, .B_8x16:
		if err := read_macroblock_prediction(decoder, macroblock_index); err != .None do return err
	case .I_PCM, .P_Skip, .B_Skip:
	}

	// coded_block_pattern and transform_size_8x8_flag for inter macroblocks
	if macroblock.type != .I_16x16 {
		cbp := read_coded_block_pattern(decoder, macroblock_index)
		macroblock.luma_coded_block_mask = u8(cbp & 0xF)
		macroblock.chroma_residual_mode = h264.Chroma_Residual_Mode(cbp >> 4)
		if macroblock.chroma_residual_mode > .DC_And_AC do return .Invalid_Coded_Block_Pattern
		if macroblock.luma_coded_block_mask != 0 &&
		   picture_parameters.transform_8x8_mode_flag &&
		   !macroblock.is_intra &&
		   inter_allows_8x8(decoder, macroblock) {
			macroblock.uses_8x8_transform = read_transform_8x8_flag(decoder, macroblock_index)
		}
	}

	// mb_qp_delta; its first bin's context depends on the previous macroblock's delta
	prev_delta_nz := decoder.prev_qp_delta_nz
	decoder.prev_qp_delta_nz = false
	if macroblock.luma_coded_block_mask != 0 ||
	   macroblock.chroma_residual_mode != .None ||
	   macroblock.type == .I_16x16 {
		delta := read_qp_delta(decoder, prev_delta_nz)
		offset := decoder.qp_bd_offset
		if delta < -(26 + offset / 2) || delta > 25 + offset / 2 do return .Invalid_QP_Delta
		// QPY wraps within -QpBdOffsetY..51 (7-39).
		decoder.qp = (decoder.qp + delta + 52 + 2 * offset) % (52 + offset) - offset
		decoder.prev_qp_delta_nz = delta != 0
	}
	macroblock.quantizer = i8(decoder.qp)
	macroblock.has_quantizer_delta = decoder.prev_qp_delta_nz
	for offset, plane in ([2]i32{picture_parameters.chroma_qp_index_offset, picture_parameters.second_chroma_qp_index_offset}) {
		decoder.chroma_qp[plane] = h264.chroma_qp(decoder.qp, offset, decoder.qp_bd_offset) + decoder.qp_bd_offset
	}

	// residual( )
	when T == u8 {L :: i16} else {L :: i32}
	residual: Residual(L) = ---
	residual.luma_nz = {}
	residual.luma8x8_nz = {}
	if macroblock.luma_coded_block_mask != 0 ||
	   macroblock.chroma_residual_mode != .None ||
	   macroblock.type == .I_16x16 {
		if err := read_residual(decoder, macroblock_index, &residual); err != .None do return err
	}

	// Prediction and reconstruction
	if macroblock.is_intra {
		reconstruct_intra(decoder, macroblock_index, &residual, T)
	} else {
		set_ref_pics(decoder, macroblock_index)
		predict_inter_macroblock(decoder, macroblock_index, T)
		reconstruct_inter_luma(decoder, macroblock_index, &residual, T)
	}
	reconstruct_chroma(decoder, macroblock_index, &residual, T)
	return .None
}

// transform_size_8x8_flag may follow the cbp only when no partition is smaller than 8x8
// and, for direct prediction, direct_8x8_inference_flag is set (7.3.5).
inter_allows_8x8 :: proc(decoder: ^Slice_Decoder, macroblock: #soa^#soa[]h264.Macroblock) -> bool {
	switch macroblock.type {
	case .B_Direct_16x16:
		return decoder.sequence_parameters.infer_direct_8x8_motion
	case .P_8x8, .P_8x8ref0:
		for type in macroblock.subpartition_types do if type != .List_0_8x8 do return false
		return true
	case .B_8x8:
		for k in 0 ..< 4 {
			sub := macroblock.subpartition_types[k]
			if sub == .Direct_8x8 && !decoder.sequence_parameters.infer_direct_8x8_motion do return false
			if subpartition_shape(sub) != .Block_8x8 do return false
		}
		return true
	case .I_4x4,
	     .I_8x8,
	     .I_16x16,
	     .I_PCM,
	     .P_L0_16x16,
	     .P_L0_L0_16x8,
	     .P_L0_L0_8x16,
	     .P_Skip,
	     .B_16x16,
	     .B_16x8,
	     .B_8x16,
	     .B_Skip:
		return true
	}
	return true
}

// I_PCM: raw samples of bit_depth bits replace prediction and residual (7.3.5, 8.3.5).
decode_pcm :: proc(decoder: ^Slice_Decoder, macroblock_index: int, $T: typeid) -> Error {
	macroblock := &decoder.macroblocks[macroblock_index]
	macroblock.quantizer = i8(decoder.qp)
	macroblock.luma_coded_block_mask = 15
	macroblock.chroma_residual_mode = .DC_And_AC
	for &count in macroblock.nonzero_coefficient_counts do count = 16
	macroblock.has_dc_coefficients = {true, true, true}
	decoder.prev_qp_delta_nz = false
	h264.byte_align(decoder.reader)
	chroma_rows := decoder.chroma_422 ? 16 : 8
	bits := uint(decoder.bit_depth)
	if decoder.reader.bit_pos + (256 + 16 * chroma_rows) * int(bits) > 8 * len(decoder.reader.data) do return .Truncated_PCM
	buf := &decoder.picture.buf
	luma, cb, cr := h264.buffer_planes(T, buf)
	mb_x, mb_y :=
		macroblock_index %
		decoder.macroblock_columns,
		macroblock_index /
		decoder.macroblock_columns
	for y in 0 ..< 16 {
		row := luma[(mb_y * 16 + y) * buf.y_stride + mb_x * 16:]
		for x in 0 ..< 16 do row[x] = T(h264.read_bits(decoder.reader, bits))
	}
	for plane in ([2][^]T{cb, cr}) {
		for y in 0 ..< chroma_rows {
			row := plane[(mb_y * chroma_rows + y) * buf.uv_stride + mb_x * 8:]
			for x in 0 ..< 8 do row[x] = T(h264.read_bits(decoder.reader, bits))
		}
	}
	if decoder.cabac do cabac_init_engine(decoder.engine, decoder.reader)
	return .None
}

// ---------------------------------------------------------------------------
// Intra prediction modes (8.3.1.1, 8.3.2.1)
// ---------------------------------------------------------------------------

// The intra NxN mode of a neighbouring 4x4 block, DC when it lies outside an
// I_4x4/I_8x8 macroblock, or -1 when the neighbouring macroblock is unusable.
neighbour_intra_mode :: proc(decoder: ^Slice_Decoder, macroblock_index: int, block: int) -> int {
	if macroblock_index < 0 do return -1
	neighbour := &decoder.macroblocks[macroblock_index]
	if decoder.picture_parameters.constrained_intra_pred_flag && !neighbour.is_intra do return -1
	if neighbour.type != .I_4x4 && neighbour.type != .I_8x8 do return int(h264.Intra_4x4_Mode.DC)
	return int(neighbour.intra_4x4_modes[block])
}

read_intra_modes :: proc(decoder: ^Slice_Decoder, macroblock_index: int) {
	macroblock := &decoder.macroblocks[macroblock_index]
	left, top := decoder.left_index, decoder.top_index
	if macroblock.type == .I_8x8 {
		for block8 in 0 ..< 4 {
			bx, by := block8 & 1, block8 >> 1
			// 8.3.2.1: an I_4x4 neighbour contributes its 4x4 block adjacent to this 8x8 block
			mode_a :=
				bx > 0 ? int(macroblock.intra_4x4_modes[(block8 - 1) * 4]) : neighbour_intra_mode(decoder, left, (block8 + 1) * 4 + 1)
			mode_b :=
				by > 0 ? int(macroblock.intra_4x4_modes[(block8 - 2) * 4]) : neighbour_intra_mode(decoder, top, (block8 + 2) * 4 + 2)
			predicted :=
				mode_a < 0 || mode_b < 0 ? int(h264.Intra_4x4_Mode.DC) : min(mode_a, mode_b)
			mode := read_intra_pred_mode(decoder, predicted)
			for k in 0 ..< 4 do macroblock.intra_4x4_modes[block8 * 4 + k] = h264.Intra_4x4_Mode(mode)
		}
		return
	}
	for block in 0 ..< 16 {
		bx, by := h264.subblock_to_xy(block)
		mode_a :=
			bx > 0 ? int(macroblock.intra_4x4_modes[h264.xy_to_subblock(bx - 1, by)]) : neighbour_intra_mode(decoder, left, h264.xy_to_subblock(3, by))
		mode_b :=
			by > 0 ? int(macroblock.intra_4x4_modes[h264.xy_to_subblock(bx, by - 1)]) : neighbour_intra_mode(decoder, top, h264.xy_to_subblock(bx, 3))
		predicted := mode_a < 0 || mode_b < 0 ? int(h264.Intra_4x4_Mode.DC) : min(mode_a, mode_b)
		macroblock.intra_4x4_modes[block] = h264.Intra_4x4_Mode(
			read_intra_pred_mode(decoder, predicted),
		)
	}
}

// prev_intra_pred_mode_flag / rem_intra_pred_mode to a mode (8.3.1.1 step 3)
read_intra_pred_mode :: proc(decoder: ^Slice_Decoder, predicted: int) -> int {
	prev, rem := read_intra_pred_mode_syntax(decoder)
	if prev do return predicted
	return rem < predicted ? rem : rem + 1
}

// ---------------------------------------------------------------------------
// Inter prediction syntax: reference indices and motion vector differences
// ---------------------------------------------------------------------------

// Fill motion vectors of a partition (blocks are in decoding order)
fill_partition_mv :: proc(
	macroblock: #soa^#soa[]h264.Macroblock,
	list: int,
	part: h264.Partition,
	mv: [2]i16,
) {
	bx, by := h264.subblock_to_xy(part.block)
	for y in 0 ..< part.height do for x in 0 ..< part.width {
		macroblock.motion_vectors[list][h264.xy_to_subblock(bx + x, by + y)] = mv
	}
}

read_macroblock_prediction :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> Error {
	macroblock := &decoder.macroblocks[macroblock_index]
	header := decoder.header
	parts := h264.macroblock_partitions(macroblock.type)
	for list in 0 ..< 2 {
		active := int(list == 0 ? header.num_ref_idx_l0_active : header.num_ref_idx_l1_active)
		for part in parts {
			if macroblock.prediction_directions[part.block / 4] & (list == 0 ? h264.Prediction_Direction.List_0 : .List_1) == .None do continue
			ref: i32 = 0
			if active > 1 do ref = read_ref_idx(decoder, macroblock_index, list, part.block, active)
			if ref < 0 || int(ref) >= active do return .Invalid_Reference_Index
			for y in 0 ..< part.height / 2 do for x in 0 ..< part.width / 2 {
				bx, by := h264.subblock_to_xy(part.block)
				macroblock.reference_indices[list][(by / 2 + y) * 2 + bx / 2 + x] = i8(ref)
			}
		}
	}
	for list in 0 ..< 2 {
		for part in parts {
			if macroblock.prediction_directions[part.block / 4] & (list == 0 ? h264.Prediction_Direction.List_0 : .List_1) == .None do continue
			predicted := h264.predict_motion_vector(
				&decoder.grid,
				macroblock_index,
				list,
				part.block,
				part.width,
				part.height,
				macroblock.reference_indices[list][part.block / 4],
			)
			motion_differences := read_mvd_pair(decoder, macroblock_index, list, part.block)
			fill_partition_mv(macroblock, list, part, predicted + motion_differences)
			if decoder.cabac do store_mvd(macroblock, list, part, motion_differences)
		}
	}
	return .None
}

read_sub_macroblock_prediction :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> Error {
	macroblock := &decoder.macroblocks[macroblock_index]
	header := decoder.header
	is_b := header.slice_type == .B
	for k in 0 ..< 4 {
		sub := read_sub_mb_type(decoder)
		if sub > (is_b ? 12 : 3) do return .Invalid_Sub_Macroblock_Type
		p_types := [4]h264.Subpartition_Type{.List_0_8x8, .List_0_8x4, .List_0_4x8, .List_0_4x4}
		macroblock.subpartition_types[k] = is_b ? h264.Subpartition_Type(sub) : p_types[sub]
		if is_b {
			// Table 7-18: direction and shape of B sub-macroblock types
			dirs := [13]h264.Prediction_Direction {
				.None,
				h264.Prediction_Direction.List_0,
				h264.Prediction_Direction.List_1,
				h264.Prediction_Direction.Bidirectional,
				h264.Prediction_Direction.List_0,
				h264.Prediction_Direction.List_0,
				h264.Prediction_Direction.List_1,
				h264.Prediction_Direction.List_1,
				h264.Prediction_Direction.Bidirectional,
				h264.Prediction_Direction.Bidirectional,
				h264.Prediction_Direction.List_0,
				h264.Prediction_Direction.List_1,
				h264.Prediction_Direction.Bidirectional,
			}
			macroblock.prediction_directions[k] = dirs[sub]
		} else {
			macroblock.prediction_directions[k] = h264.Prediction_Direction.List_0
		}
	}
	for list in 0 ..< 2 {
		active := int(list == 0 ? header.num_ref_idx_l0_active : header.num_ref_idx_l1_active)
		for k in 0 ..< 4 {
			if macroblock.prediction_directions[k] & (list == 0 ? h264.Prediction_Direction.List_0 : .List_1) == .None do continue
			ref: i32 = 0
			if active > 1 && macroblock.type != .P_8x8ref0 do ref = read_ref_idx(decoder, macroblock_index, list, k * 4, active)
			if ref < 0 || int(ref) >= active do return .Invalid_Reference_Index
			macroblock.reference_indices[list][k] = i8(ref)
		}
	}
	// Direct sub-macroblocks take their motion before the others are parsed (8.4.1.2 uses only neighbours)
	direct_mask: u8
	for k in 0 ..< 4 do if is_b && macroblock.subpartition_types[k] == .Direct_8x8 do direct_mask |= 1 << uint(k)
	if direct_mask != 0 do derive_direct(decoder, macroblock_index, direct_mask)

	for list in 0 ..< 2 {
		for k in 0 ..< 4 {
			if macroblock.prediction_directions[k] & (list == 0 ? h264.Prediction_Direction.List_0 : .List_1) == .None || (is_b && macroblock.subpartition_types[k] == .Direct_8x8) do continue
			shape := subpartition_shape(macroblock.subpartition_types[k])
			for sub in h264.sub_partitions(shape) {
				part := h264.Partition{k * 4 + sub.block, sub.width, sub.height}
				predicted := h264.predict_motion_vector(
					&decoder.grid,
					macroblock_index,
					list,
					part.block,
					part.width,
					part.height,
					macroblock.reference_indices[list][k],
				)
				motion_differences := read_mvd_pair(decoder, macroblock_index, list, part.block)
				fill_partition_mv(macroblock, list, part, predicted + motion_differences)
				if decoder.cabac do store_mvd(macroblock, list, part, motion_differences)
			}
		}
	}
	return .None
}

// Shape of a normalized P/B subpartition type.
subpartition_shape :: proc(type: h264.Subpartition_Type) -> h264.Subpartition_Shape {
	switch type {
	case .Direct_8x8, .List_0_8x8, .List_1_8x8, .Bidirectional_8x8:
		return .Block_8x8
	case .List_0_8x4, .List_1_8x4, .Bidirectional_8x4:
		return .Block_8x4
	case .List_0_4x8, .List_1_4x8, .Bidirectional_4x8:
		return .Block_4x8
	case .List_0_4x4, .List_1_4x4, .Bidirectional_4x4:
		return .Block_4x4
	}
	unreachable()
}

read_mvd_pair :: proc(decoder: ^Slice_Decoder, macroblock_index, list, block: int) -> [2]i16 {
	mvd: [2]i32
	if decoder.cabac {
		mvd = cabac_read_mvd_pair(decoder, macroblock_index, list, block)
	} else {
		mvd = {h264.read_se(decoder.reader), h264.read_se(decoder.reader)}
	}
	return {i16(clamp(mvd[0], -32768, 32767)), i16(clamp(mvd[1], -32768, 32767))}
}

// |mvd| per 4x4 block, read only by the CABAC contexts of later macroblocks
// in the same slice.
store_mvd :: proc(
	macroblock: #soa^#soa[]h264.Macroblock,
	list: int,
	part: h264.Partition,
	motion_differences: [2]i16,
) {
	bx, by := h264.subblock_to_xy(part.block)
	value := [2]u8 {
		u8(min(abs(int(motion_differences[0])), 255)),
		u8(min(abs(int(motion_differences[1])), 255)),
	}
	for y in 0 ..< part.height do for x in 0 ..< part.width {
		macroblock.motion_differences[list][h264.xy_to_subblock(bx + x, by + y)] = value
	}
}

// Resolve reference indices to picture ids for deblocking and direct prediction
set_ref_pics :: proc(decoder: ^Slice_Decoder, macroblock_index: int) {
	macroblock := &decoder.macroblocks[macroblock_index]
	for list in 0 ..< 2 do for k in 0 ..< 4 {
		macroblock.reference_picture_ids[list][k] = -1
		ref := int(macroblock.reference_indices[list][k])
		if ref >= 0 && ref < decoder.state.ref_count[list] {
			if pic := decoder.state.ref_list[list][ref]; pic != nil do macroblock.reference_picture_ids[list][k] = pic.pic_id
		}
	}
}

// ---------------------------------------------------------------------------
// Reconstruction
// ---------------------------------------------------------------------------

// Neighbour availability for intra prediction (8.3.1.2 with constrained_intra_pred)
intra_neighbours :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index: int,
) -> (
	top, left, top_right, top_left: bool,
) {
	usable :: proc(decoder: ^Slice_Decoder, idx: int) -> bool {
		return(
			h264.macroblock_is_available(&decoder.grid, idx) &&
			(!decoder.picture_parameters.constrained_intra_pred_flag ||
					decoder.macroblocks[idx].is_intra) \
		)
	}
	mb_x := macroblock_index % decoder.macroblock_columns
	top = usable(decoder, macroblock_index - decoder.macroblock_columns)
	left = mb_x > 0 && usable(decoder, macroblock_index - 1)
	top_right =
		mb_x < decoder.macroblock_columns - 1 &&
		usable(decoder, macroblock_index - decoder.macroblock_columns + 1)
	top_left = mb_x > 0 && usable(decoder, macroblock_index - decoder.macroblock_columns - 1)
	return
}

// The macroblock's top-left samples in each plane of the picture.
macroblock_samples :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index: int,
	$T: typeid,
) -> (
	luma: [^]T,
	chroma: [2][^]T,
) {
	buf := &decoder.picture.buf
	y, u, v := h264.buffer_planes(T, buf)
	mb_x, mb_y := macroblock_index % decoder.macroblock_columns, macroblock_index / decoder.macroblock_columns
	chroma_offset := (mb_y * (decoder.chroma_422 ? 16 : 8)) * buf.uv_stride + mb_x * 8
	return &y[(mb_y * 16) * buf.y_stride + mb_x * 16], {&u[chroma_offset], &v[chroma_offset]}
}

reconstruct_intra :: proc(decoder: ^Slice_Decoder, macroblock_index: int, residual: ^Residual($L), $T: typeid) {
	macroblock := &decoder.macroblocks[macroblock_index]
	buf := &decoder.picture.buf
	stride := buf.y_stride
	pixels, chroma_pixels := macroblock_samples(decoder, macroblock_index, T)
	top, left, top_right, top_left := intra_neighbours(decoder, macroblock_index)
	qp := i32(macroblock.quantizer) + decoder.qp_bd_offset
	bit_depth := decoder.bit_depth
	pixel_max := i32(1) << uint(bit_depth) - 1

	switch macroblock.type {
	case .I_16x16:
		h264.predict_intra_16x16(pixels, stride, macroblock.intra_16x16_mode, top, left, bit_depth)
		dc := residual.luma_dc_coefficients
		h264.luma_dc_dequant_idct(&decoder.state.scales, &dc, qp)
		for block in 0 ..< 16 {
			bx, by := h264.subblock_to_xy(block)
			h264.reconstruct_4x4(
				&decoder.state.scales,
				&pixels[by * 4 * stride + bx * 4],
				stride,
				&residual.luma[block],
				residual.luma_nz[block],
				qp,
				0,
				true,
				i32(dc[by * 4 + bx]),
				pixel_max,
			)
		}
	case .I_8x8:
		for block8 in 0 ..< 4 {
			bx, by := block8 & 1, block8 >> 1
			block_pixels: [^]T = &pixels[by * 8 * stride + bx * 8]
			avail_top := by > 0 || top
			avail_left := bx > 0 || left
			avail_top_right := block8 == 0 ? top : block8 == 1 ? top_right : block8 == 2
			avail_top_left :=
				block8 == 0 ? top_left : block8 == 1 ? top : block8 == 2 ? left : true
			h264.predict_intra_8x8(
				block_pixels,
				stride,
				macroblock.intra_4x4_modes[block8 * 4],
				avail_top,
				avail_left,
				avail_top_right,
				avail_top_left,
				bit_depth,
			)
			if residual.luma8x8_nz[block8] do h264.reconstruct_8x8(&decoder.state.scales, block_pixels, stride, &residual.luma8x8[block8], qp, 0, pixel_max)
		}
	case .I_4x4:
		for block in 0 ..< 16 {
			bx, by := h264.subblock_to_xy(block)
			block_pixels: [^]T = &pixels[by * 4 * stride + bx * 4]
			avail_top := by > 0 || top
			avail_left := bx > 0 || left
			avail_top_right: bool
			switch {
			case by == 0 && bx < 3:
				avail_top_right = top
			case by == 0:
				avail_top_right = top_right
			case bx < 3:
				avail_top_right = block != 3 && block != 11
			}
			h264.predict_intra_4x4(
				block_pixels,
				stride,
				macroblock.intra_4x4_modes[block],
				avail_top,
				avail_left,
				avail_top_right,
				bit_depth,
			)
			if residual.luma_nz[block] do h264.reconstruct_4x4(&decoder.state.scales, block_pixels, stride, &residual.luma[block], true, qp, 0, false, 0, pixel_max)
		}
	case .I_PCM,
	     .P_L0_16x16,
	     .P_L0_L0_16x8,
	     .P_L0_L0_8x16,
	     .P_8x8,
	     .P_8x8ref0,
	     .P_Skip,
	     .B_Direct_16x16,
	     .B_16x16,
	     .B_16x8,
	     .B_8x16,
	     .B_8x8,
	     .B_Skip:
	}

	for plane in 0 ..< 2 do h264.predict_intra_chroma(chroma_pixels[plane], buf.uv_stride, macroblock.chroma_prediction_mode, top, left, decoder.chroma_422, bit_depth)
}

reconstruct_inter_luma :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index: int,
	residual: ^Residual($L),
	$T: typeid,
) {
	macroblock := &decoder.macroblocks[macroblock_index]
	stride := decoder.picture.buf.y_stride
	pixels, _ := macroblock_samples(decoder, macroblock_index, T)
	qp := i32(macroblock.quantizer) + decoder.qp_bd_offset
	pixel_max := i32(1) << uint(decoder.bit_depth) - 1
	if macroblock.uses_8x8_transform {
		for block8 in 0 ..< 4 {
			if !residual.luma8x8_nz[block8] do continue
			h264.reconstruct_8x8(
				&decoder.state.scales,
				&pixels[(block8 >> 1) * 8 * stride + (block8 & 1) * 8],
				stride,
				&residual.luma8x8[block8],
				qp,
				1,
				pixel_max,
			)
		}
		return
	}
	for block in 0 ..< 16 {
		if !residual.luma_nz[block] do continue
		bx, by := h264.subblock_to_xy(block)
		h264.reconstruct_4x4(
			&decoder.state.scales,
			&pixels[by * 4 * stride + bx * 4],
			stride,
			&residual.luma[block],
			true,
			qp,
			3,
			false,
			0,
			pixel_max,
		)
	}
}

// Chroma residual (8.5.11): the DC levels of each plane through the 2x2 (or
// 4:2:2's 2x4) transform, then each 4x4 block with its DC.
reconstruct_chroma :: proc(decoder: ^Slice_Decoder, macroblock_index: int, residual: ^Residual($L), $T: typeid) {
	macroblock := &decoder.macroblocks[macroblock_index]
	if macroblock.chroma_residual_mode == .None do return
	stride := decoder.picture.buf.uv_stride
	_, planes := macroblock_samples(decoder, macroblock_index, T)
	pixel_max := i32(1) << uint(decoder.bit_depth) - 1
	blocks := decoder.chroma_422 ? 8 : 4
	for plane in 0 ..< 2 {
		list_idx := (macroblock.is_intra ? 1 : 4) + plane
		qp := decoder.chroma_qp[plane]
		dc := residual.chroma_dc_coefficients[plane]
		if decoder.chroma_422 {
			h264.chroma_dc_dequant_idct_422(&decoder.state.scales, &dc, qp, list_idx)
		} else {
			h264.chroma_dc_dequant_idct(&decoder.state.scales, (^[4]L)(&dc), qp, list_idx)
		}
		for block in 0 ..< blocks {
			h264.reconstruct_4x4(
				&decoder.state.scales,
				&planes[plane][(block >> 1) * 4 * stride + (block & 1) * 4],
				stride,
				&residual.chroma_ac_coefficients[plane][block],
				macroblock.chroma_residual_mode == .DC_And_AC,
				qp,
				list_idx,
				true,
				i32(dc[block]),
				pixel_max,
			)
		}
	}
}

// ---------------------------------------------------------------------------
// Residual parsing shared by both entropy coders: which blocks exist and in
// which order (7.3.5.3), coefficient reading is per entropy coder.
// ---------------------------------------------------------------------------

read_residual :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index: int,
	residual: ^Residual($L),
) -> Error {
	macroblock := &decoder.macroblocks[macroblock_index]
	if macroblock.type == .I_16x16 {
		dc_total := read_residual_block(
			decoder,
			macroblock_index,
			.Luma_DC,
			0,
			residual.luma_dc_coefficients[:],
			16,
		)
		macroblock.has_dc_coefficients[0] = dc_total > 0
		for block in 0 ..< 16 {
			if macroblock.luma_coded_block_mask & (1 << uint(block / 4)) == 0 do continue
			total := read_residual_block(
				decoder,
				macroblock_index,
				.Luma_AC,
				block,
				residual.luma[block][1:],
				15,
			)
			macroblock.nonzero_coefficient_counts[block] = u8(total)
			residual.luma_nz[block] = total > 0
		}
	} else if macroblock.uses_8x8_transform {
		for block8 in 0 ..< 4 {
			if macroblock.luma_coded_block_mask & (1 << uint(block8)) == 0 do continue
			if decoder.cabac {
				total := read_residual_block(
					decoder,
					macroblock_index,
					.Luma_8x8,
					block8,
					residual.luma8x8[block8][:],
					64,
				)
				residual.luma8x8_nz[block8] = total > 0
				macroblock.has_8x8_coefficients[block8] = total > 0
				for k in 0 ..< 4 do macroblock.nonzero_coefficient_counts[block8 * 4 + k] = u8(min(total, 16))
			} else {
				// CAVLC: four interleaved 4x4 blocks (7.3.5.3.2)
				for k in 0 ..< 4 {
					levels: [16]L
					count := read_residual_block(
						decoder,
						macroblock_index,
						.Luma_4x4,
						block8 * 4 + k,
						levels[:],
						16,
					)
					macroblock.nonzero_coefficient_counts[block8 * 4 + k] = u8(count)
					if count > 0 {
						residual.luma8x8_nz[block8] = true
						macroblock.has_8x8_coefficients[block8] = true
					}
					for i in 0 ..< 16 do residual.luma8x8[block8][4 * i + k] = levels[i]
				}
			}
		}
	} else {
		for block in 0 ..< 16 {
			if macroblock.luma_coded_block_mask & (1 << uint(block / 4)) == 0 do continue
			total := read_residual_block(
				decoder,
				macroblock_index,
				.Luma_4x4,
				block,
				residual.luma[block][:],
				16,
			)
			macroblock.nonzero_coefficient_counts[block] = u8(total)
			residual.luma_nz[block] = total > 0
		}
	}
	// Chroma blocks: 4 per plane, 8 in 4:2:2. A chroma AC block is passed as
	// plane * blocks + its raster index.
	blocks := decoder.chroma_422 ? 8 : 4
	if macroblock.chroma_residual_mode != .None {
		for plane in 0 ..< 2 {
			total := read_residual_block(
				decoder,
				macroblock_index,
				.Chroma_DC,
				plane,
				residual.chroma_dc_coefficients[plane][:blocks],
				blocks,
			)
			macroblock.has_dc_coefficients[1 + plane] = total > 0
		}
	}
	if macroblock.chroma_residual_mode == .DC_And_AC {
		for plane in 0 ..< 2 do for block in 0 ..< blocks {
			total := read_residual_block(decoder, macroblock_index, .Chroma_AC, plane * blocks + block, residual.chroma_ac_coefficients[plane][block][1:], 15)
			macroblock.nonzero_coefficient_counts[h264.chroma_count_index(plane, block)] = u8(total)
		}
	}
	return .None
}

// ---------------------------------------------------------------------------
// Entropy coder dispatch
// ---------------------------------------------------------------------------

cabac_or_cavlc_mb_type :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> u32 {
	return(
		decoder.cabac ? cabac_read_mb_type(decoder, macroblock_index) : h264.read_ue(decoder.reader) \
	)
}

read_transform_8x8_flag :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> bool {
	return(
		decoder.cabac ? cabac_read_transform_8x8_flag(decoder, macroblock_index) : h264.read_bit(decoder.reader) == 1 \
	)
}

read_sub_mb_type :: proc(decoder: ^Slice_Decoder) -> u32 {
	return decoder.cabac ? cabac_read_sub_mb_type(decoder) : h264.read_ue(decoder.reader)
}

read_ref_idx :: proc(decoder: ^Slice_Decoder, macroblock_index, list, block, active: int) -> i32 {
	if decoder.cabac do return cabac_read_ref_idx(decoder, macroblock_index, list, block)
	return i32(h264.read_te(decoder.reader, u32(active - 1)))
}

read_intra_pred_mode_syntax :: proc(decoder: ^Slice_Decoder) -> (prev: bool, rem: int) {
	if decoder.cabac do return cabac_read_intra_pred_mode(decoder)
	prev = h264.read_bit(decoder.reader) == 1
	if !prev do rem = int(h264.read_bits(decoder.reader, 3))
	return
}

read_intra_chroma_mode :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> u32 {
	return(
		decoder.cabac ? cabac_read_intra_chroma_mode(decoder, macroblock_index) : h264.read_ue(decoder.reader) \
	)
}

read_coded_block_pattern :: proc(decoder: ^Slice_Decoder, macroblock_index: int) -> u32 {
	if decoder.cabac do return cabac_read_coded_block_pattern(decoder, macroblock_index)
	code := h264.read_ue(decoder.reader)
	if code >= 48 do return 0xFF
	return u32(
		decoder.macroblocks[macroblock_index].is_intra ? h264.intra4x4_cbp_table[code] : h264.inter_cbp_table[code],
	)
}

read_qp_delta :: proc(decoder: ^Slice_Decoder, prev_delta_nz: bool) -> i32 {
	return(
		decoder.cabac ? cabac_read_qp_delta(decoder, prev_delta_nz) : h264.read_se(decoder.reader) \
	)
}

// Levels of one block in scan order; returns the number of non-zero levels.
read_residual_block :: proc(
	decoder: ^Slice_Decoder,
	macroblock_index: int,
	$cat: Block_Cat,
	block: int,
	levels: []$L,
	max_coeffs: int,
) -> int {
	for &level in levels do level = 0
	if decoder.cabac do return cabac_read_residual_block(decoder, macroblock_index, cat, block, levels, max_coeffs)
	return cavlc_read_residual_block(decoder, macroblock_index, cat, block, levels, max_coeffs)
}

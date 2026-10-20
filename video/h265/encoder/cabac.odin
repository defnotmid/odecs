package h265_encoder

import common "../../../common"

// ---------------------------------------------------------------------------
// HEVC CABAC encoder, ported from kvazaar's cabac.c. The engine writes bins
// into a caller-owned bit writer; the context models are plain value types so
// that search can copy and roll back the complete coder state.
// ---------------------------------------------------------------------------

NEXT_STATE_MPS := [128]u8 {
	2,
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	12,
	13,
	14,
	15,
	16,
	17,
	18,
	19,
	20,
	21,
	22,
	23,
	24,
	25,
	26,
	27,
	28,
	29,
	30,
	31,
	32,
	33,
	34,
	35,
	36,
	37,
	38,
	39,
	40,
	41,
	42,
	43,
	44,
	45,
	46,
	47,
	48,
	49,
	50,
	51,
	52,
	53,
	54,
	55,
	56,
	57,
	58,
	59,
	60,
	61,
	62,
	63,
	64,
	65,
	66,
	67,
	68,
	69,
	70,
	71,
	72,
	73,
	74,
	75,
	76,
	77,
	78,
	79,
	80,
	81,
	82,
	83,
	84,
	85,
	86,
	87,
	88,
	89,
	90,
	91,
	92,
	93,
	94,
	95,
	96,
	97,
	98,
	99,
	100,
	101,
	102,
	103,
	104,
	105,
	106,
	107,
	108,
	109,
	110,
	111,
	112,
	113,
	114,
	115,
	116,
	117,
	118,
	119,
	120,
	121,
	122,
	123,
	124,
	125,
	124,
	125,
	126,
	127,
}

NEXT_STATE_LPS := [128]u8 {
	1,
	0,
	0,
	1,
	2,
	3,
	4,
	5,
	4,
	5,
	8,
	9,
	8,
	9,
	10,
	11,
	12,
	13,
	14,
	15,
	16,
	17,
	18,
	19,
	18,
	19,
	22,
	23,
	22,
	23,
	24,
	25,
	26,
	27,
	26,
	27,
	30,
	31,
	30,
	31,
	32,
	33,
	32,
	33,
	36,
	37,
	36,
	37,
	38,
	39,
	38,
	39,
	42,
	43,
	42,
	43,
	44,
	45,
	44,
	45,
	46,
	47,
	48,
	49,
	48,
	49,
	50,
	51,
	52,
	53,
	52,
	53,
	54,
	55,
	54,
	55,
	56,
	57,
	58,
	59,
	58,
	59,
	60,
	61,
	60,
	61,
	60,
	61,
	62,
	63,
	64,
	65,
	64,
	65,
	66,
	67,
	66,
	67,
	66,
	67,
	68,
	69,
	68,
	69,
	70,
	71,
	70,
	71,
	70,
	71,
	72,
	73,
	72,
	73,
	72,
	73,
	74,
	75,
	74,
	75,
	74,
	75,
	76,
	77,
	76,
	77,
	126,
	127,
}

LPST_TABLE := [64][4]u8 {
	{128, 176, 208, 240},
	{128, 167, 197, 227},
	{128, 158, 187, 216},
	{123, 150, 178, 205},
	{116, 142, 169, 195},
	{111, 135, 160, 185},
	{105, 128, 152, 175},
	{100, 122, 144, 166},
	{95, 116, 137, 158},
	{90, 110, 130, 150},
	{85, 104, 123, 142},
	{81, 99, 117, 135},
	{77, 94, 111, 128},
	{73, 89, 105, 122},
	{69, 85, 100, 116},
	{66, 80, 95, 110},
	{62, 76, 90, 104},
	{59, 72, 86, 99},
	{56, 69, 81, 94},
	{53, 65, 77, 89},
	{51, 62, 73, 85},
	{48, 59, 69, 80},
	{46, 56, 66, 76},
	{43, 53, 63, 72},
	{41, 50, 59, 69},
	{39, 48, 56, 65},
	{37, 45, 54, 62},
	{35, 43, 51, 59},
	{33, 41, 48, 56},
	{32, 39, 46, 53},
	{30, 37, 43, 50},
	{29, 35, 41, 48},
	{27, 33, 39, 45},
	{26, 31, 37, 43},
	{24, 30, 35, 41},
	{23, 28, 33, 39},
	{22, 27, 32, 37},
	{21, 26, 30, 35},
	{20, 24, 29, 33},
	{19, 23, 27, 31},
	{18, 22, 26, 30},
	{17, 21, 25, 28},
	{16, 20, 23, 27},
	{15, 19, 22, 25},
	{14, 18, 21, 24},
	{14, 17, 20, 23},
	{13, 16, 19, 22},
	{12, 15, 18, 21},
	{12, 14, 17, 20},
	{11, 14, 16, 19},
	{11, 13, 15, 18},
	{10, 12, 15, 17},
	{10, 12, 14, 16},
	{9, 11, 13, 15},
	{9, 11, 12, 14},
	{8, 10, 12, 14},
	{8, 9, 11, 13},
	{7, 9, 11, 12},
	{7, 9, 10, 12},
	{7, 8, 10, 11},
	{6, 8, 9, 11},
	{6, 7, 9, 10},
	{6, 7, 8, 9},
	{2, 2, 2, 2},
}

RENORM_TABLE := [32]u8 {
	6,
	5,
	4,
	4,
	3,
	3,
	3,
	3,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	2,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
	1,
}

Cabac_Context :: struct {
	state: u8,
}

Cabac_Contexts :: struct {
	sao_merge_flag_model:        Cabac_Context,
	sao_type_idx_model:          Cabac_Context,
	split_flag_model:            [3]Cabac_Context,
	intra_mode_model:            Cabac_Context,
	chroma_pred_model:           [2]Cabac_Context,
	inter_dir:                   [5]Cabac_Context,
	trans_subdiv_model:          [3]Cabac_Context,
	qt_cbf_model_luma:           [4]Cabac_Context,
	qt_cbf_model_chroma:         [4]Cabac_Context,
	cu_qp_delta_abs:             [4]Cabac_Context,
	part_size_model:             [4]Cabac_Context,
	cu_sig_coeff_group_model:    [4]Cabac_Context,
	cu_sig_model_luma:           [27]Cabac_Context,
	cu_sig_model_chroma:         [15]Cabac_Context,
	cu_ctx_last_y_luma:          [15]Cabac_Context,
	cu_ctx_last_y_chroma:        [15]Cabac_Context,
	cu_ctx_last_x_luma:          [15]Cabac_Context,
	cu_ctx_last_x_chroma:        [15]Cabac_Context,
	cu_one_model_luma:           [16]Cabac_Context,
	cu_one_model_chroma:         [8]Cabac_Context,
	cu_abs_model_luma:           [4]Cabac_Context,
	cu_abs_model_chroma:         [2]Cabac_Context,
	cu_pred_mode_model:          Cabac_Context,
	cu_skip_flag_model:          [3]Cabac_Context,
	cu_merge_idx_ext_model:      Cabac_Context,
	cu_merge_flag_ext_model:     Cabac_Context,
	cu_transquant_bypass:        Cabac_Context,
	cu_mvd_model:                [2]Cabac_Context,
	cu_ref_pic_model:            [2]Cabac_Context,
	mvp_idx_model:               [2]Cabac_Context,
	cu_qt_root_cbf_model:        Cabac_Context,
	transform_skip_model_luma:   Cabac_Context,
	transform_skip_model_chroma: Cabac_Context,
	cross_component_prediction:  [10]Cabac_Context,
}

Cabac :: struct {
	stream:                 ^common.Bit_Writer,
	low:                    u32,
	range:                  u32,
	buffered_byte:          u32,
	num_buffered_bytes:     i32,
	bits_left:              i32,
	ctx:                    Cabac_Contexts,
	// The PPS transform_skip_enabled_flag: when set, every 4x4 transform block
	// carries a transform_skip_flag bin.
	transform_skip_enabled: bool,
}

// kvz_ctx_init: Table 9-5 initialization with QP and the per-slice init value.
ctx_init :: proc(ctx: ^Cabac_Context, qp: u32, init_value: u8) {
	slope := i32(init_value >> 4) * 5 - 45
	offset := i32(init_value & 15) << 3 - 16
	init_state := min(max(1, ((slope * i32(qp)) >> 4) + offset), 126)
	if init_state >= 64 {
		ctx.state = u8((init_state - 64) << 1 + 1)
	} else {
		ctx.state = u8((63 - init_state) << 1)
	}
}

init_contexts :: proc(cabac: ^Cabac, qp: u32, slice: Slice_Type) {
	s := u8(slice)
	c := &cabac.ctx
	ctx_init(&c.transform_skip_model_luma, qp, INIT_TRANSFORMSKIP_FLAG[s][0])
	ctx_init(&c.transform_skip_model_chroma, qp, INIT_TRANSFORMSKIP_FLAG[s][1])
	ctx_init(&c.sao_merge_flag_model, qp, INIT_SAO_MERGE_FLAG[s])
	ctx_init(&c.sao_type_idx_model, qp, INIT_SAO_TYPE_IDX[s])
	ctx_init(&c.cu_merge_flag_ext_model, qp, INIT_MERGE_FLAG_EXT[s][0])
	ctx_init(&c.cu_merge_idx_ext_model, qp, INIT_MERGE_IDX_EXT[s][0])
	ctx_init(&c.cu_pred_mode_model, qp, INIT_PRED_MODE[s][0])
	ctx_init(&c.cu_transquant_bypass, qp, INIT_CU_TRANSQUANT_BYPASS[s][0])
	for i in 0 ..< 3 {
		ctx_init(&c.cu_skip_flag_model[i], qp, INIT_SKIP_FLAG[s][i])
		ctx_init(&c.split_flag_model[i], qp, INIT_SPLIT_FLAG[s][i])
	}
	ctx_init(&c.intra_mode_model, qp, INIT_INTRA_PRED_MODE[s])
	ctx_init(&c.chroma_pred_model[0], qp, INIT_CHROMA_PRED_MODE[s][0])
	ctx_init(&c.chroma_pred_model[1], qp, INIT_CHROMA_PRED_MODE[s][1])
	ctx_init(&c.cu_abs_model_chroma[0], qp, INIT_ABS_FLAG[s][4])
	ctx_init(&c.cu_abs_model_chroma[1], qp, INIT_ABS_FLAG[s][5])
	ctx_init(&c.cu_qt_root_cbf_model, qp, INIT_QT_ROOT_CBF[s][0])
	ctx_init(&c.cu_mvd_model[0], qp, INIT_MVD[s][0])
	ctx_init(&c.cu_mvd_model[1], qp, INIT_MVD[s][1])
	ctx_init(&c.cu_ref_pic_model[0], qp, INIT_REF_PIC[s][0])
	ctx_init(&c.cu_ref_pic_model[1], qp, INIT_REF_PIC[s][1])
	ctx_init(&c.mvp_idx_model[0], qp, INIT_MVP_IDX[s][0])
	ctx_init(&c.mvp_idx_model[1], qp, INIT_MVP_IDX[s][1])
	ctx_init(&c.cu_qp_delta_abs[0], qp, INIT_CU_QP_DELTA_ABS[s][0])
	ctx_init(&c.cu_qp_delta_abs[1], qp, INIT_CU_QP_DELTA_ABS[s][1])
	for i in 0 ..< 4 {
		ctx_init(&c.cu_sig_coeff_group_model[i], qp, INIT_SIG_CG_FLAG[s][i])
		ctx_init(&c.cu_abs_model_luma[i], qp, INIT_ABS_FLAG[s][i])
		ctx_init(&c.part_size_model[i], qp, INIT_PART_SIZE[s][i])
		ctx_init(&c.qt_cbf_model_luma[i], qp, INIT_QT_CBF[s][i])
		ctx_init(&c.qt_cbf_model_chroma[i], qp, INIT_QT_CBF[s][i + 4])
	}
	for i in 0 ..< 3 do ctx_init(&c.trans_subdiv_model[i], qp, INIT_TRANS_SUBDIV_FLAG[s][i])
	for i in 0 ..< 5 do ctx_init(&c.inter_dir[i], qp, INIT_INTER_DIR[s][i])
	for i in 0 ..< 8 do ctx_init(&c.cu_one_model_chroma[i], qp, INIT_ONE_FLAG[s][i + 16])
	for i in 0 ..< 10 do ctx_init(&c.cross_component_prediction[i], qp, INIT_CROSS_COMPONENT_PREDICTION[s][i])
	for i in 0 ..< 15 {
		ctx_init(&c.cu_ctx_last_y_luma[i], qp, INIT_LAST[s][i])
		ctx_init(&c.cu_ctx_last_x_luma[i], qp, INIT_LAST[s][i])
		ctx_init(&c.cu_ctx_last_y_chroma[i], qp, INIT_LAST[s][i + 15])
		ctx_init(&c.cu_ctx_last_x_chroma[i], qp, INIT_LAST[s][i + 15])
		ctx_init(&c.cu_one_model_luma[i], qp, INIT_ONE_FLAG[s][i])
	}
	ctx_init(&c.cu_one_model_luma[15], qp, INIT_ONE_FLAG[s][15])
	for i in 0 ..< 27 {
		ctx_init(&c.cu_sig_model_luma[i], qp, INIT_SIG_FLAG[s][i])
		if i < 15 do ctx_init(&c.cu_sig_model_chroma[i], qp, INIT_SIG_FLAG[s][i + 27])
	}
}

cabac_start :: proc(data: ^Cabac) {
	data.low = 0
	data.range = 510
	data.bits_left = 23
	data.num_buffered_bytes = 0
	data.buffered_byte = 0xff
}

// cabac_rate is the coder's total output size in bits, including the bits held
// in the buffered bytes and the low register. `bits_written` alone misses those
// pending bits, which understates the cost of a candidate whose bins do not
// force a flush; the transform tree compares multi-node candidates, so it needs
// the complete count. Differences of cabac_rate are monotone.
cabac_rate :: #force_inline proc(data: ^Cabac) -> int {
	return(
		common.bits_written(data.stream) +
		int(data.num_buffered_bytes) * 8 +
		(32 - int(data.bits_left)) \
	)
}

// kvz_cabac_write
cabac_write :: proc(data: ^Cabac) {
	lead_byte := data.low >> uint(24 - data.bits_left)
	data.bits_left += 8
	data.low &= 0xffff_ffff >> uint(data.bits_left)

	if lead_byte == 0xff {
		data.num_buffered_bytes += 1
	} else {
		if data.num_buffered_bytes > 0 {
			carry := lead_byte >> 8
			byte := data.buffered_byte + carry
			data.buffered_byte = lead_byte & 0xff
			append(data.stream.buf, u8(byte))

			byte = (0xff + carry) & 0xff
			for data.num_buffered_bytes > 1 {
				append(data.stream.buf, u8(byte))
				data.num_buffered_bytes -= 1
			}
		} else {
			data.num_buffered_bytes = 1
			data.buffered_byte = lead_byte
		}
	}
}

// kvz_cabac_encode_bin
cabac_bin :: proc(data: ^Cabac, ctx: ^Cabac_Context, bin_value: u32) {
	lps := u32(LPST_TABLE[ctx.state >> 1][(data.range >> 6) & 3])
	data.range -= lps

	if (bin_value != 0 ? 1 : 0) != u32(ctx.state & 1) {
		num_bits := i32(RENORM_TABLE[lps >> 3])
		data.low = (data.low + data.range) << uint(num_bits)
		data.range = lps << uint(num_bits)
		ctx.state = NEXT_STATE_LPS[ctx.state]
		data.bits_left -= num_bits
	} else {
		ctx.state = NEXT_STATE_MPS[ctx.state]
		if data.range >= 256 do return
		data.low <<= 1
		data.range <<= 1
		data.bits_left -= 1
	}

	if data.bits_left < 12 do cabac_write(data)
}

cabac_bin_ep :: proc(data: ^Cabac, bin_value: u32) {
	data.low <<= 1
	if bin_value != 0 do data.low += data.range
	data.bits_left -= 1
	if data.bits_left < 12 do cabac_write(data)
}

cabac_bins_ep :: proc(data: ^Cabac, bin_values: u32, num_bins: int) {
	pattern: u32
	n := num_bins
	v := bin_values
	for n > 8 {
		n -= 8
		pattern = v >> uint(n)
		data.low = (data.low << 8) + data.range * pattern
		v -= pattern << uint(n)
		data.bits_left -= 8
		if data.bits_left < 12 do cabac_write(data)
	}
	data.low = (data.low << uint(n)) + data.range * v
	data.bits_left -= i32(n)
	if data.bits_left < 12 do cabac_write(data)
}

cabac_bin_trm :: proc(data: ^Cabac, bin_value: u8) {
	data.range -= 2
	if bin_value != 0 {
		data.low += data.range
		data.low <<= 7
		data.range = 2 << 7
		data.bits_left -= 7
	} else if data.range >= 256 {
		return
	} else {
		data.low <<= 1
		data.range <<= 1
		data.bits_left -= 1
	}
	if data.bits_left < 12 do cabac_write(data)
}

// kvz_cabac_finish: flush the arithmetic coder into the bit writer.
cabac_finish :: proc(data: ^Cabac) {
	if data.low >> uint(32 - data.bits_left) != 0 {
		append(data.stream.buf, u8(data.buffered_byte + 1))
		for data.num_buffered_bytes > 1 {
			append(data.stream.buf, 0)
			data.num_buffered_bytes -= 1
		}
		data.low -= 1 << uint(32 - data.bits_left)
	} else {
		if data.num_buffered_bytes > 0 {
			append(data.stream.buf, u8(data.buffered_byte))
		}
		for data.num_buffered_bytes > 1 {
			append(data.stream.buf, 0xff)
			data.num_buffered_bytes -= 1
		}
	}

	bits := u8(24 - data.bits_left)
	common.write_bits(data.stream, data.low >> 8, int(bits))
}

// kvz_cabac_write_unary_max_symbol
cabac_unary_max_symbol :: proc(
	data: ^Cabac,
	ctx: []Cabac_Context,
	symbol: u32,
	offset: int,
	max_symbol: u32,
) {
	if max_symbol == 0 do return
	code_last := max_symbol > symbol

	cabac_bin(data, &ctx[0], symbol != 0 ? 1 : 0)
	if symbol == 0 do return
	s := symbol
	for {
		s -= 1
		if s == 0 do break
		cabac_bin(data, &ctx[offset], 1)
	}
	if code_last do cabac_bin(data, &ctx[offset], 0)
}

// kvz_cabac_write_coeff_remain: coeff_abs_level_remaining, Rice code.
cabac_coeff_remain :: proc(data: ^Cabac, symbol: u32, r_param: u32) -> int {
	code_number := symbol
	length: u32
	bits := 0

	if code_number < (3 << r_param) {
		length = code_number >> r_param
		cabac_bins_ep(data, (1 << (length + 1)) - 2, int(length + 1))
		bits += int(length + 1)
		cabac_bins_ep(data, code_number % (1 << r_param), int(r_param))
		bits += int(r_param)
	} else {
		length = r_param
		code_number -= 3 << r_param
		for code_number >= (1 << length) {
			code_number -= 1 << length
			length += 1
		}
		cabac_bins_ep(data, (1 << (3 + length + 1 - r_param)) - 2, int(3 + length + 1 - r_param))
		bits += int(3 + length + 1 - r_param)
		cabac_bins_ep(data, code_number, int(length))
		bits += int(length)
	}
	return bits
}

// kvz_cabac_write_ep_ex_golomb
cabac_ep_ex_golomb :: proc(data: ^Cabac, symbol: u32, count: u32) -> u32 {
	bins: u32
	num_bins: i32
	c := count
	s := symbol
	for s >= (1 << c) {
		bins = 2 * bins + 1
		num_bins += 1
		s -= 1 << c
		c += 1
	}
	bins = 2 * bins
	num_bins += 1
	bins = bins << uint(c) | s
	num_bins += i32(c)
	cabac_bins_ep(data, bins, int(num_bins))
	return u32(num_bins)
}

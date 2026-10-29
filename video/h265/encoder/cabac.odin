package h265_encoder

import common "../../../common"

// ---------------------------------------------------------------------------
// HEVC CABAC encoder: context models and HEVC-specific syntax helpers built
// on common.Cabac_Enc. Context models are plain value types so search can
// copy and roll back the complete coder state.
// ---------------------------------------------------------------------------

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
	using enc:              common.Cabac_Enc,
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

cabac_start :: #force_inline proc(data: ^Cabac) {
	common.cabac_enc_start(&data.enc, data.stream)
}

cabac_rate :: #force_inline proc(data: ^Cabac) -> int {
	return common.cabac_enc_rate(&data.enc)
}

cabac_write :: #force_inline proc(data: ^Cabac) {
	common.cabac_enc_write(&data.enc)
}

cabac_bin :: #force_inline proc(data: ^Cabac, ctx: ^Cabac_Context, bin_value: u32) {
	common.cabac_enc_decision(&data.enc, &ctx.state, bin_value != 0 ? 1 : 0)
}

cabac_bin_ep :: #force_inline proc(data: ^Cabac, bin_value: u32) {
	common.cabac_enc_bypass(&data.enc, bin_value)
}

cabac_bins_ep :: #force_inline proc(data: ^Cabac, bin_values: u32, num_bins: int) {
	common.cabac_enc_bypass_bins(&data.enc, bin_values, num_bins)
}

cabac_bin_trm :: #force_inline proc(data: ^Cabac, bin_value: u8) {
	common.cabac_enc_terminate(&data.enc, u32(bin_value))
}

cabac_finish :: #force_inline proc(data: ^Cabac) {
	common.cabac_enc_finish(&data.enc, false)
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

cabac_ep_ex_golomb :: #force_inline proc(data: ^Cabac, symbol: u32, count: u32) -> u32 {
	return common.cabac_enc_exp_golomb(&data.enc, symbol, uint(count))
}

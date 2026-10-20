package h265_encoder

import hevc ".."
import common "../../common"

// ---------------------------------------------------------------------------
// Scaling lists (7.4.5) on the encoder side: the mode is fixed per encode, the
// matrices live on the Encoder, and every quantization and reconstruction
// picks the one the decoder will read out of the SPS. With scaling off the
// wrappers are the flat shared functions, so the default path is untouched.
// ---------------------------------------------------------------------------

// Sl_Kind names the component whose matrix a block uses; matrixId is the
// component plus 3 for an inter block.
Sl_Kind :: enum u8 {
	Y  = 0,
	Cb = 1,
	Cr = 2,
}

init_scaling :: proc(enc: ^Encoder, mode: Scaling_Mode) {
	switch mode {
	case .Off:
		return
	case .Default:
		enc.scaling = hevc.default_scaling_list()
	case .Flat:
		for s in 0 ..< hevc.MAX_SCALING_LIST_SIZES {
			for m in 0 ..< hevc.MAX_SCALING_LIST_MATS {
				for i in 0 ..< 64 do enc.scaling.sl[s][m][i] = 16
			}
		}
		for s in 0 ..< 2 {
			for m in 0 ..< hevc.MAX_SCALING_LIST_MATS do enc.scaling.dc[s][m] = 16
		}
	}
	enc.scaling_on = true
}

@(private)
scaling_matrix :: #force_inline proc(
	enc: ^Encoder,
	size: int,
	kind: Sl_Kind,
	intra: bool,
) -> (
	m: []u8,
	dc: u8,
) {
	matrix_id := int(kind) + (intra ? 0 : 3)
	log2 := log2_size(size)
	m = enc.scaling.sl[log2 - 2][matrix_id][:]
	dc = 16
	if log2 >= 4 do dc = enc.scaling.dc[log2 - 4][matrix_id]
	return
}

enc_quantize :: proc(
	enc: ^Encoder,
	coeff, qcoeff: []i16,
	size: int,
	kind: Sl_Kind,
	intra: bool,
	qp_scaled: int,
) -> bool {
	if !enc.scaling_on do return quantize(coeff, qcoeff, size, enc.bit_depth, qp_scaled, intra)
	m, dc := scaling_matrix(enc, size, kind, intra)
	return hevc.quantize_scaled(coeff, qcoeff, size, enc.bit_depth, qp_scaled, intra, m, dc)
}

enc_dequantize :: proc(
	enc: ^Encoder,
	qcoeff, coeff: []i16,
	size: int,
	kind: Sl_Kind,
	intra: bool,
	qp_scaled: int,
) {
	if !enc.scaling_on {
		dequantize(qcoeff, coeff, size, enc.bit_depth, qp_scaled)
		return
	}
	m, dc := scaling_matrix(enc, size, kind, intra)
	hevc.dequantize_scaled(qcoeff, coeff, size, enc.bit_depth, qp_scaled, m, dc)
}

// write_scaling_list_data is 7.3.4 with the shorthand 7.4.5 allows: a matrix
// equal to the default list (and, for 16x16/32x32, the default DC) is coded as
// a prediction with delta 0. Flat matrices therefore take the explicit path,
// which also exercises the delta decode in our own streams.
write_scaling_list_data :: proc(w: ^common.Bit_Writer, sl: ^hevc.Scaling_List) {
	def := hevc.default_scaling_list()

	for size_id in 0 ..< hevc.MAX_SCALING_LIST_SIZES {
		step := 1
		if size_id == 3 do step = 3

		matrix_id := 0
		for matrix_id < hevc.MAX_SCALING_LIST_MATS {
			same := true
			count := size_id == 0 ? 16 : 64
			for i in 0 ..< count {
				if sl.sl[size_id][matrix_id][i] != def.sl[size_id][matrix_id][i] {
					same = false
					break
				}
			}
			if same && size_id > 1 {
				if sl.dc[size_id - 2][matrix_id] != def.dc[size_id - 2][matrix_id] do same = false
			}

			if same {
				common.write_bits(w, 0, 1) // scaling_list_pred_mode_flag
				common.write_ue(w, 0) // scaling_list_pred_matrix_id_delta
			} else {
				common.write_bits(w, 1, 1) // scaling_list_pred_mode_flag

				next := i32(8)
				if size_id > 1 {
					common.write_se(w, i32(sl.dc[size_id - 2][matrix_id]) - 8)
					next = i32(sl.dc[size_id - 2][matrix_id])
				}

				scan := hevc.SCALING_SCAN_8X8[:]
				if size_id == 0 do scan = hevc.SCALING_SCAN_4X4[:]
				for idx in scan {
					v := i32(sl.sl[size_id][matrix_id][idx])
					d := v - next
					next = v
					if d > 127 do d -= 256
					if d < -128 do d += 256
					common.write_se(w, d)
				}
			}

			matrix_id += step
		}
	}
}

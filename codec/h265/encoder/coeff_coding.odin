package h265_encoder

import hevc ".."

// ---------------------------------------------------------------------------
// Residual syntax: last significant position and coefficient coding
// (kvz_encode_last_significant_xy and kvz_encode_coeff_nxn_generic).
// Sign data hiding is disabled, so every coefficient sign is coded.
// ---------------------------------------------------------------------------

encode_last_significant_xy :: proc(
	cabac: ^Cabac,
	last_x, last_y: u8,
	width: int,
	ctype: int,
	scan: Scan_Order,
) {
	index := log2_size(width) - 2
	ctx_offset := ctype != 0 ? 0 : index * 3 + (index + 1) / 4
	shift := ctype != 0 ? uint(index) : uint((index + 3) / 4)

	base_x := ctype != 0 ? cabac.ctx.cu_ctx_last_x_chroma[:] : cabac.ctx.cu_ctx_last_x_luma[:]
	base_y := ctype != 0 ? cabac.ctx.cu_ctx_last_y_chroma[:] : cabac.ctx.cu_ctx_last_y_luma[:]

	x, y := last_x, last_y
	if scan == .Vertical {
		x, y = y, x
	}
	group_x := int(GROUP_IDX[x])
	group_y := int(GROUP_IDX[y])

	for i in 0 ..< group_x {
		cabac_bin(cabac, &base_x[ctx_offset + (i >> shift)], 1)
	}
	if group_x < int(GROUP_IDX[width - 1]) {
		cabac_bin(cabac, &base_x[ctx_offset + (group_x >> shift)], 0)
	}
	for i in 0 ..< group_y {
		cabac_bin(cabac, &base_y[ctx_offset + (i >> shift)], 1)
	}
	if group_y < int(GROUP_IDX[width - 1]) {
		cabac_bin(cabac, &base_y[ctx_offset + (group_y >> shift)], 0)
	}

	if group_x > 3 {
		suffix := int(x) - int(MIN_IN_GROUP[group_x])
		n := (group_x - 2) / 2
		cabac_bins_ep(cabac, u32(suffix), n)
	}
	if group_y > 3 {
		suffix := int(y) - int(MIN_IN_GROUP[group_y])
		n := (group_y - 2) / 2
		cabac_bins_ep(cabac, u32(suffix), n)
	}
}

// kvz_encode_coeff_nxn_generic. `coeff` holds width*width quantized
// coefficients in raster order; `type` is 0 luma, 1 Cb, 2 Cr. With transform
// skip enabled a 4x4 block codes its transform_skip_flag before the residual.
encode_coeff_nxn :: proc(
	cabac: ^Cabac,
	coeff: []i16,
	width: int,
	ctype: int,
	scan_mode: Scan_Order,
	transform_skip := false,
) {
	if cabac.transform_skip_enabled && width == 4 {
		model :=
			ctype == 0 ? &cabac.ctx.transform_skip_model_luma : &cabac.ctx.transform_skip_model_chroma
		cabac_bin(cabac, model, transform_skip ? 1 : 0)
	}

	log2 := log2_size(width)
	num_blk_side := width >> 2
	scan := scan_table(scan_mode, log2)

	// Coefficient group scan.
	scan_cg: []u32
	switch log2 {
	case 2, 3:
		scan_cg = hevc.SCAN_CG_8X8[int(scan_mode)][:]
	case 4:
		scan_cg = hevc.SCAN_CG_16X16[:]
	case 5:
		scan_cg = hevc.SCAN_CG_32X32[:]
	}

	base_coeff_group_ctx :=
		ctype != 0 ? cabac.ctx.cu_sig_coeff_group_model[2:4] : cabac.ctx.cu_sig_coeff_group_model[0:2]
	base_ctx := ctype == 0 ? cabac.ctx.cu_sig_model_luma[:] : cabac.ctx.cu_sig_model_chroma[:]

	sig_coeffgroup_flag: [8 * 8]u32
	sig_cg_cnt := 0
	for cg_y in 0 ..< width / 4 {
		for cg_x in 0 ..< width / 4 {
			cg_pos := cg_y * width * 4 + cg_x * 4
			for coeff_row in 0 ..< 4 {
				coeff_pos := cg_pos + coeff_row * width
				any := false
				for i in 0 ..< 4 {
					if coeff[coeff_pos + i] != 0 {
						any = true
						break
					}
				}
				if any {
					sig_cg_cnt += 1
					cg_pos_y := (cg_pos >> uint(log2)) >> 2
					cg_pos_x := (cg_pos & (width - 1)) >> 2
					sig_coeffgroup_flag[cg_pos_x + cg_pos_y * num_blk_side] = 1
					break
				}
			}
		}
	}
	// Rest of the code assumes at least one non-zero coefficient.
	if sig_cg_cnt == 0 do return

	scan_cg_last := num_blk_side * num_blk_side - 1
	for sig_coeffgroup_flag[int(scan_cg[scan_cg_last])] == 0 {
		scan_cg_last -= 1
	}
	scan_pos_last := scan_cg_last * 16 + 15
	for coeff[int(scan[scan_pos_last])] == 0 {
		scan_pos_last -= 1
	}
	pos_last := int(scan[scan_pos_last])

	last_coeff_x := u8(pos_last & (width - 1))
	last_coeff_y := u8(pos_last >> uint(log2))

	encode_last_significant_xy(cabac, last_coeff_x, last_coeff_y, width, ctype, scan_mode)

	scan_pos_sig := scan_pos_last
	c1 := 1

	cg := int(scan_cg_last)
	for {
		cg_i := cg
		sub_pos := cg_i << 4
		abs_coeff: [16]i32
		cg_blk_pos := int(scan_cg[cg_i])
		cg_pos_y := cg_blk_pos / num_blk_side
		cg_pos_x := cg_blk_pos - cg_pos_y * num_blk_side

		coeff_signs: u32
		last_nz_pos_in_cg := -1
		first_nz_pos_in_cg := 16
		num_non_zero := 0
		go_rice_param: u32 = 0

		if scan_pos_sig == scan_pos_last {
			abs_coeff[0] = abs(i32(coeff[pos_last]))
			coeff_signs = coeff[pos_last] < 0 ? 1 : 0
			num_non_zero = 1
			last_nz_pos_in_cg = scan_pos_sig
			first_nz_pos_in_cg = scan_pos_sig
			scan_pos_sig -= 1
		}

		if cg_i == int(scan_cg_last) || cg_i == 0 {
			sig_coeffgroup_flag[cg_blk_pos] = 1
		} else {
			sig := sig_coeffgroup_flag[cg_blk_pos] != 0 ? u32(1) : u32(0)
			ctx_sig := context_get_sig_coeff_group(
				sig_coeffgroup_flag[:],
				cg_pos_x,
				cg_pos_y,
				width,
			)
			cabac_bin(cabac, &base_coeff_group_ctx[int(ctx_sig)], sig)
		}

		if sig_coeffgroup_flag[cg_blk_pos] != 0 {
			pattern_sig_ctx := context_calc_pattern_sig_ctx(
				sig_coeffgroup_flag[:],
				cg_pos_x,
				cg_pos_y,
				width,
			)

			for scan_pos_sig >= sub_pos {
				blk_pos := int(scan[scan_pos_sig])
				pos_y := blk_pos >> uint(log2)
				pos_x := blk_pos - (pos_y << uint(log2))
				sig := coeff[blk_pos] != 0 ? u32(1) : u32(0)

				if scan_pos_sig > sub_pos || cg_i == 0 || num_non_zero != 0 {
					ctx_sig := context_get_sig_ctx_inc(
						pattern_sig_ctx,
						i32(scan_mode),
						i32(pos_x),
						i32(pos_y),
						i32(log2),
						i32(ctype != 0 ? 1 : 0),
					)
					cabac_bin(cabac, &base_ctx[int(ctx_sig)], sig)
				}

				if sig != 0 {
					abs_coeff[num_non_zero] = abs(i32(coeff[blk_pos]))
					coeff_signs = 2 * coeff_signs + (coeff[blk_pos] < 0 ? 1 : 0)
					num_non_zero += 1
					if last_nz_pos_in_cg == -1 do last_nz_pos_in_cg = scan_pos_sig
					first_nz_pos_in_cg = scan_pos_sig
				}
				scan_pos_sig -= 1
			}
		} else {
			scan_pos_sig = sub_pos - 1
		}

		if num_non_zero > 0 {
			ctx_set := cg_i > 0 && ctype == 0 ? 2 : 0
			if c1 == 0 do ctx_set += 1
			c1 = 1

			base_ctx_mod :=
				ctype == 0 ? cabac.ctx.cu_one_model_luma[4 * ctx_set:] : cabac.ctx.cu_one_model_chroma[4 * ctx_set:]
			num_c1_flag := min(num_non_zero, C1FLAG_NUMBER)
			first_c2_flag_idx := -1

			for idx in 0 ..< num_c1_flag {
				symbol := abs_coeff[idx] > 1 ? u32(1) : u32(0)
				cabac_bin(cabac, &base_ctx_mod[c1], symbol)
				if symbol != 0 {
					c1 = 0
					if first_c2_flag_idx == -1 do first_c2_flag_idx = idx
				} else if c1 < 3 && c1 > 0 {
					c1 += 1
				}
			}

			if c1 == 0 {
				abs_mod :=
					ctype == 0 ? cabac.ctx.cu_abs_model_luma[:] : cabac.ctx.cu_abs_model_chroma[:]
				if first_c2_flag_idx != -1 {
					symbol := abs_coeff[first_c2_flag_idx] > 2 ? u32(1) : u32(0)
					cabac_bin(cabac, &abs_mod[ctx_set], symbol)
				}
			}

			cabac_bins_ep(cabac, coeff_signs, num_non_zero)

			if c1 == 0 || num_non_zero > C1FLAG_NUMBER {
				first_coeff2 := 1
				for idx in 0 ..< num_non_zero {
					base_level := i32(idx < C1FLAG_NUMBER ? 2 + first_coeff2 : 1)
					if abs_coeff[idx] >= base_level {
						cabac_coeff_remain(cabac, u32(abs_coeff[idx] - base_level), go_rice_param)
						if abs_coeff[idx] > 3 * (1 << go_rice_param) {
							go_rice_param = min(go_rice_param + 1, 4)
						}
					}
					if abs_coeff[idx] >= 2 do first_coeff2 = 0
				}
			}
		}

		if cg_i == 0 do break
		cg -= 1
	}
}

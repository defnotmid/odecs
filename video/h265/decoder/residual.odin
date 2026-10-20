package h265_decoder

import hevc ".."

// ---------------------------------------------------------------------------
// Residual coding (7.3.8.11), ported from gen2brain/h265 hevc/residual.go
// (MIT); oxideav-h265 src/residual.rs is the per-file cross-reference.
// ---------------------------------------------------------------------------

NUM_SB_COEFF :: 16

// 8.6.3, log2TransformRange.
transform_range :: proc(bit_depth: int, extended: bool) -> int {
	if !extended do return 15
	return max(15, bit_depth + 6)
}

sps_coeff_range :: proc(s: ^SPS, c_idx: int) -> int {
	if !s.extended_precision do return 0

	bit_depth := int(s.bit_depth_luma)
	if c_idx > 0 do bit_depth = int(s.bit_depth_chroma)

	return transform_range(bit_depth, true)
}

// Table 9-43, the sig_coeff_flag context map for 4x4 blocks.
SIG_CTX_MAP4X4 := [16]u8{0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8}

// sig_ctx_by_csbf is the position part of 9.3.4.2.5, derived from the
// derivation (xP + yP and the neighbouring sub-block flags).
SIG_CTX_BY_CSBF := [4][16]u8 {
	{2, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0},
	{2, 2, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0},
	{2, 1, 0, 0, 2, 1, 0, 0, 2, 1, 0, 0, 2, 1, 0, 0},
	{2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2},
}

SCAN_1X1 := [1]u32{0}
SCAN_DIAG_2X2 := [4]u32{0, 2, 1, 3}
SCAN_HOR_2X2 := [4]u32{0, 1, 2, 3}
SCAN_VER_2X2 := [4]u32{0, 2, 1, 3}

// scan_table_ext adds the 1x1 and 2x2 sizes the shared scan table does not
// carry (it starts at 4x4).
scan_table_ext :: proc "contextless" (scan: hevc.Scan_Order, log2: int) -> []u32 {
	switch log2 {
	case 0:
		return SCAN_1X1[:]
	case 1:
		if scan == .Horizontal do return SCAN_HOR_2X2[:]
		if scan == .Vertical do return SCAN_VER_2X2[:]
		return SCAN_DIAG_2X2[:]
	case:
		return hevc.scan_table(scan, log2)
	}
}

// group_scan orders the 4x4 coefficient groups of a transform block. It is not
// the coefficient scan of the same size: the 8x8 sub-blocks of a 32x32 block
// follow the plain up-right diagonal, which only equals the 8x8 coefficient
// scan for 4x4 group grids.
group_scan :: proc "contextless" (scan: hevc.Scan_Order, log2_size: int) -> []u32 {
	switch log2_size {
	case 2:
		return SCAN_1X1[:]
	case 3:
		return hevc.SCAN_CG_8X8[int(scan)][:]
	case 4:
		return hevc.SCAN_CG_16X16[:]
	case:
		return hevc.SCAN_CG_32X32[:]
	}
}

// Build inverse positions from the authoritative forward scans once, rather
// than searching up to 1024 coefficient positions for every residual block.
@(private)
Residual_Scan_Positions :: struct {
	group: [4][3][64]u8,
	coeff: [3][16]u8,
}

@(private)
residual_scan_positions :: proc "contextless" () -> (out: Residual_Scan_Positions) {
	for order in 0 ..< 3 {
		for raster, pos in scan_table_ext(hevc.Scan_Order(order), 2) do out.coeff[order][raster] = u8(pos)
		for log2 in 2 ..= 5 {
			for raster, pos in group_scan(hevc.Scan_Order(order), log2) do out.group[log2 - 2][order][raster] = u8(pos)
		}
	}
	return
}

@(private)
RESIDUAL_SCAN_POSITIONS := residual_scan_positions()

// scan_index is the derivation in 7.4.9.11: only small intra blocks depart from
// the diagonal scan, and then only for near-horizontal or near-vertical modes.
scan_index :: proc(
	log2_size, c_idx, pred_mode_intra: int,
	intra: bool,
	chroma_array_type: u32,
) -> hevc.Scan_Order {
	if !intra do return .Diag

	if log2_size != 2 && !(log2_size == 3 && (c_idx == 0 || chroma_array_type == 3)) {
		return .Diag
	}

	switch {
	case pred_mode_intra >= 6 && pred_mode_intra <= 14:
		return .Vertical
	case pred_mode_intra >= 22 && pred_mode_intra <= 30:
		return .Horizontal
	case:
		return .Diag
	}
}

// last_sig_coeff_ctx is the context derivation of 9.3.4.2.3.
last_sig_coeff_ctx :: proc(log2_size, c_idx, bin_idx: int) -> int {
	if c_idx == 0 {
		return bin_idx >> uint((log2_size + 1) >> 2) + 3 * (log2_size - 2) + (log2_size - 1) >> 2
	}

	return bin_idx >> uint(log2_size - 2) + 15
}

last_sig_coeff_prefix :: proc(c: ^Cabac_Bins, base, log2_size, c_idx: int) -> int {
	c_max := log2_size << 1 - 1

	v := 0
	for v < c_max && cabac_decode_bin(c, base + last_sig_coeff_ctx(log2_size, c_idx, v)) != 0 {
		v += 1
	}

	return v
}

last_sig_coeff_suffix :: proc(c: ^Cabac_Bins, prefix: int) -> int {
	if prefix <= 3 do return prefix

	n := prefix >> 1 - 1
	suffix := int(cabac_decode_bypass_bits(c, n))

	return (1 << uint(n)) * (2 + (prefix & 1)) + suffix
}

// coeff_abs_level_remaining is the binarization of 9.3.3.11. rng selects the
// limited form of 9.3.3.4 and is zero otherwise.
coeff_abs_level_remaining :: proc(c: ^Cabac_Bins, rice, rng: int) -> i32 {
	limit := 32
	if rng > 0 do limit = 32 - rng

	prefix := 0
	for prefix < limit && cabac_decode_bypass(c) != 0 {
		prefix += 1
	}

	if prefix < 3 {
		return i32(prefix << uint(rice)) + i32(cabac_decode_bypass_bits(c, rice))
	}

	k := prefix - 3

	if rng > 0 && prefix == limit {
		return i32(((1 << uint(k)) + 2) << uint(rice)) + i32(cabac_decode_bypass_bits(c, rng))
	}

	return i32(((1 << uint(k)) + 2) << uint(rice)) + i32(cabac_decode_bypass_bits(c, k + rice))
}

// Sig_Ctx_Set is 9.3.4.2.5 with everything that is fixed for a sub-block
// already resolved.
Sig_Ctx_Set :: struct {
	base:      int,
	dc:        int,
	small:     int,
	prev_csbf: int,
	is4x4:     bool,
	sb_dc:     bool,
	flat:      bool,
}

new_sig_ctx_set :: proc "contextless" (
	x_s, y_s, log2_size, c_idx, scan_idx, prev_csbf: int,
	flat: bool,
) -> Sig_Ctx_Set {
	c := Sig_Ctx_Set {
		prev_csbf = prev_csbf,
		is4x4     = log2_size == 2,
		sb_dc     = (x_s | y_s) == 0,
		flat      = flat,
	}

	if flat {
		c.base = 42
		if c_idx != 0 do c.base = 27 + 16
		return c
	}

	if c_idx != 0 {
		c.dc, c.small = 27, 27
		c.base = 27 + 12

		if log2_size == 3 do c.base = 27 + 9

		return c
	}

	if x_s + y_s > 0 do c.base = 3

	switch {
	case log2_size == 3 && scan_idx == int(hevc.Scan_Order.Diag):
		c.base += 9
	case log2_size == 3:
		c.base += 15
	case:
		c.base += 21
	}

	return c
}

sig_ctx_set_at :: proc "contextless" (c: Sig_Ctx_Set, x, y: int) -> int {
	switch {
	case c.flat:
		return c.base
	case c.is4x4:
		return c.small + int(SIG_CTX_MAP4X4[y << 2 + x])
	case c.sb_dc && (x | y) == 0:
		return c.dc
	}

	return c.base + int(SIG_CTX_BY_CSBF[c.prev_csbf][((y & 3) << 2) | (x & 3)])
}

// Resolve the scan and all group-fixed significance context decisions once.
// The hot significance loop then needs one indexed byte per coefficient.
@(private)
Sig_Scan_Contexts :: [4][3][2][4][2][2][16]u8

@(private, init)
sig_scan_contexts :: proc "contextless" () {
	table := &SIG_SCAN_CONTEXTS
	for size in 0 ..< 4 {
		for scan in 0 ..< 3 {
			for chroma in 0 ..< 2 {
				for prev in 0 ..< 4 {
					for non_dc in 0 ..< 2 {
						for flat in 0 ..< 2 {
							set := new_sig_ctx_set(
								non_dc,
								0,
								size + 2,
								chroma,
								scan,
								prev,
								flat != 0,
							)
							for raster, k in scan_table_ext(hevc.Scan_Order(scan), 2) {
								table[size][scan][chroma][prev][non_dc][flat][k] = u8(
									ctxSignificantCoeffFlag +
									sig_ctx_set_at(set, int(raster & 3), int(raster >> 2)),
								)
							}
						}
					}
				}
			}
		}
	}
	return
}

@(private)
SIG_SCAN_CONTEXTS: Sig_Scan_Contexts

Residual_Block :: struct {
	log2_size:         int,
	c_idx:             int,
	pred_mode_intra:   int,
	intra:             bool,
	transquant_bypass: bool,
	// 7.3.8.11's transform_skip_flag, parsed ahead of the residual syntax and
	// used for 9.3.3.5's adaptation statistics index.
	transform_skip:    bool,
	// Residual DPCM applies to this block (implicit for an intra mode 10/26,
	// explicit for the flagged inter case): sign data hiding is off.
	rdpcm:             bool,
}

// decode_residual is the residual_coding syntax of 7.3.8.11. `coef` receives
// the transform coefficient levels in raster order and must be zeroed first.
decode_residual :: proc(
	engine: ^Cabac,
	s: ^SPS,
	p: ^PPS,
	sh: ^Slice_Header,
	coef: []i32,
	b: Residual_Block,
	stat_coeff: ^[4]u8,
) -> (
	transform_skip: bool,
	explicit_rdpcm: bool,
	rdpcm_dir: bool,
	ok: bool,
) #no_bounds_check {
	// The scan tables below cover 4..32 square blocks and three components.
	// Scan positions are table-derived; last_x/last_y are checked before use.
	if b.log2_size < 2 || b.log2_size > 5 || b.c_idx < 0 || b.c_idx > 2 do return
	if len(coef) < 1 << uint(2 * b.log2_size) do return
	bins := Cabac_Bins{engine.cursor, &engine.state}
	defer engine.cursor = bins.cursor
	c := &bins
	n := 1 << uint(b.log2_size)

	if p.transform_skip_enabled &&
	   !b.transquant_bypass &&
	   b.log2_size <= int(p.log2_max_transform_skip_size) {
		transform_skip = cabac_decode_bin(c, ctxTransformSkipFlag + min(b.c_idx, 1)) != 0
	}

	// 7.3.8.11: an inter transform-skip (or transquant-bypass) block signals
	// its residual DPCM explicitly, direction included.
	if !b.intra && s.explicit_rdpcm && (transform_skip || b.transquant_bypass) {
		explicit_rdpcm = cabac_decode_bin(c, ctxExplicitRDPCMFlag + min(b.c_idx, 1)) != 0
		if explicit_rdpcm {
			rdpcm_dir = cabac_decode_bin(c, ctxExplicitRDPCMDirFlag + min(b.c_idx, 1)) != 0
		}
	}

	// The intra form is inferred from the prediction mode, so it produces no
	// bins; the direction is horizontal for mode 10 and vertical for mode 26.
	// The implicit form covers transform-skip and transquant-bypass blocks.
	rb := b
	rb.transform_skip = transform_skip
	rb.rdpcm =
		explicit_rdpcm ||
		(s.implicit_rdpcm &&
				b.intra &&
				(transform_skip || b.transquant_bypass) &&
				(b.pred_mode_intra == INTRA_HOR || b.pred_mode_intra == INTRA_VER))

	// 9.3.4.2.5 gives a block that skips the transform one significance
	// context throughout.
	flat_ctx := s.transform_skip_context && (transform_skip || b.transquant_bypass)

	scan_idx := scan_index(
		b.log2_size,
		b.c_idx,
		b.pred_mode_intra,
		b.intra,
		sps_chroma_array_type(s),
	)

	x_prefix := last_sig_coeff_prefix(c, ctxLastSignificantCoeffXPrefix, b.log2_size, b.c_idx)
	y_prefix := last_sig_coeff_prefix(c, ctxLastSignificantCoeffYPrefix, b.log2_size, b.c_idx)

	last_x := last_sig_coeff_suffix(c, x_prefix)
	last_y := last_sig_coeff_suffix(c, y_prefix)

	if scan_idx == .Vertical do last_x, last_y = last_y, last_x

	if last_x >= n || last_y >= n do return

	sb_log2 := b.log2_size - 2
	sb_scan := group_scan(scan_idx, b.log2_size)
	coeff_scan := scan_table_ext(scan_idx, 2)

	sb_width := 1 << uint(sb_log2)

	last_group_raster := (last_y >> 2) * sb_width + (last_x >> 2)
	last_coeff_raster := (last_y & 3) * 4 + (last_x & 3)
	last_sub_block := int(
		RESIDUAL_SCAN_POSITIONS.group[b.log2_size - 2][int(scan_idx)][last_group_raster],
	)
	last_scan_pos := int(RESIDUAL_SCAN_POSITIONS.coeff[int(scan_idx)][last_coeff_raster])

	csbf: [8 * 8]bool
	st: Residual_State

	sig: [NUM_SB_COEFF]bool

	for i := last_sub_block; i >= 0; i -= 1 {
		sb_r := sb_scan[i]
		x_s := int(sb_r) % sb_width
		y_s := int(sb_r) / sb_width

		infer_sb_dc_sig := false

		if i < last_sub_block && i > 0 {
			ctx := 0
			if x_s + 1 < sb_width && csbf[y_s * sb_width + x_s + 1] do ctx += 1
			if y_s + 1 < sb_width && csbf[(y_s + 1) * sb_width + x_s] do ctx += 1

			base := ctxSignificantCoeffGroupFlag
			if b.c_idx > 0 do base += 2

			csbf[y_s * sb_width + x_s] = cabac_decode_bin(c, base + min(ctx, 1)) != 0
			infer_sb_dc_sig = true
		} else {
			csbf[y_s * sb_width + x_s] = true
		}

		if !csbf[y_s * sb_width + x_s] do continue

		prev_csbf := 0
		if x_s + 1 < sb_width && csbf[y_s * sb_width + x_s + 1] do prev_csbf += 1
		if y_s + 1 < sb_width && csbf[(y_s + 1) * sb_width + x_s] do prev_csbf += 2

		start := NUM_SB_COEFF - 1
		if i == last_sub_block do start = last_scan_pos - 1

		for k in 0 ..< NUM_SB_COEFF do sig[k] = false

		if i == last_sub_block do sig[last_scan_pos] = true

		sig_ctx := &SIG_SCAN_CONTEXTS[b.log2_size - 2][int(scan_idx)][min(b.c_idx, 1)][prev_csbf][(x_s | y_s) == 0 ? 0 : 1][flat_ctx ? 1 : 0]

		for k := start; k >= 0; k -= 1 {
			if k == 0 && infer_sb_dc_sig && !any_true(sig[1:]) {
				sig[0] = true
				continue
			}

			sig[k] = cabac_decode_bin(c, int(sig_ctx[k])) != 0
		}

		decode_sub_block_levels(
			c,
			s,
			p,
			coef,
			rb,
			sb_scan[i],
			coeff_scan,
			&sig,
			i,
			n,
			stat_coeff,
			&st,
		)
	}

	return transform_skip, explicit_rdpcm, rdpcm_dir, true
}

any_true :: proc(v: []bool) -> bool {
	for b in v {
		if b do return true
	}
	return false
}

// Residual_State carries the greater1 context across the sub-blocks of one
// transform block, as 9.3.4.2.6 requires.
Residual_State :: struct {
	started:       bool,
	greater1_ctx:  int,
	last_greater1: bool,
}

decode_sub_block_levels :: proc(
	c: ^Cabac_Bins,
	s: ^SPS,
	p: ^PPS,
	coef: []i32,
	b: Residual_Block,
	sb: u32,
	coeff_scan: []u32,
	sig: ^[NUM_SB_COEFF]bool,
	sub_block, n: int,
	stat_coeff: ^[4]u8,
	st: ^Residual_State,
) #no_bounds_check {
	// Called only by decode_residual after the block/scan bounds are checked.
	// pos_buf holds at most 16 indices in 0..15; group and coefficient scans
	// map each of those indices into the validated n*n output square.
	sb_width := 1 << uint(b.log2_size - 2)
	x_s := int(sb) % sb_width
	y_s := int(sb) / sb_width

	ctx_set := 0
	if sub_block > 0 && b.c_idx == 0 do ctx_set = 2

	last_ctx := 1

	if st.started {
		last_ctx = st.greater1_ctx
		if last_ctx > 0 {
			if st.last_greater1 {
				last_ctx = 0
			} else {
				last_ctx += 1
			}
		}
	}

	if last_ctx == 0 do ctx_set += 1

	st.started = true

	pos_buf: [NUM_SB_COEFF]i8 = ---
	npos := 0

	for k := NUM_SB_COEFF - 1; k >= 0; k -= 1 {
		if sig[k] {
			pos_buf[npos] = i8(k)
			npos += 1
		}
	}

	if npos == 0 do return

	pos := pos_buf[:npos]

	first_sig := int(pos[len(pos) - 1])
	last_sig := int(pos[0])
	last_greater1 := -1

	greater1: [NUM_SB_COEFF]bool

	greater1_ctx := 1

	for p8 in pos[:min(len(pos), 8)] {
		k := int(p8)
		ctx := ctx_set * 4 + min(3, greater1_ctx)
		if b.c_idx > 0 do ctx += 16
		greater1[k] = cabac_decode_bin(c, ctxCoeffAbsLevelGreater1Flag + ctx) != 0
		st.greater1_ctx = greater1_ctx
		st.last_greater1 = greater1[k]
		if greater1[k] {
			greater1_ctx = 0
			if last_greater1 < 0 do last_greater1 = k
		} else if greater1_ctx > 0 {
			greater1_ctx += 1
		}
	}

	greater2 := false

	if last_greater1 >= 0 {
		ctx := ctx_set
		if b.c_idx > 0 do ctx += 4

		greater2 = cabac_decode_bin(c, ctxCoeffAbsLevelGreater2Flag + ctx) != 0
	}

	sign_hidden := last_sig - first_sig > 3 && !b.transquant_bypass && !b.rdpcm

	signs: [NUM_SB_COEFF]bool

	for p8 in pos {
		k := int(p8)

		if p.sign_data_hiding_enabled && sign_hidden && k == first_sig do continue

		signs[k] = cabac_decode_bypass(c) != 0
	}

	rice := 0
	if s.persistent_rice_adaptation do rice = int(stat_coeff[rice_stat_index(b)] / 4)

	rng := sps_coeff_range(s, b.c_idx)

	num_sig := 0
	sum_abs: i32
	first_remaining := true

	for p8 in pos {
		k := int(p8)

		base := i32(1)
		if greater1[k] do base += 1
		if k == last_greater1 && greater2 do base += 1

		want := i32(1)

		if num_sig < 8 {
			want = 2
			if k == last_greater1 do want = 3
		}

		level := base

		if base == want {
			rem := coeff_abs_level_remaining(c, rice, rng)
			level = base + rem

			if s.persistent_rice_adaptation && first_remaining {
				update_stat_coeff(stat_coeff, rice_stat_index(b), rem)
				first_remaining = false
			}

			// 9.3.3.11: under persistent Rice adaptation the parameter
			// grows uncapped; without the adaptation it stops at 4.
			if level > 3 << uint(rice) {
				rice = s.persistent_rice_adaptation ? rice + 1 : min(rice + 1, 4)
			}
		}

		sum_abs += level

		if signs[k] do level = -level

		if p.sign_data_hiding_enabled && sign_hidden && k == first_sig && sum_abs % 2 == 1 {
			level = -level
		}

		pos_r := coeff_scan[k]
		x_c := x_s << 2 + int(pos_r & 3)
		y_c := y_s << 2 + int(pos_r >> 2)
		coef[y_c * n + x_c] = level

		num_sig += 1
	}
}

rice_stat_index :: proc(b: Residual_Block) -> int {
	// 9.3.3.5's riceStatIdx: the adaptation statistics split by channel type
	// and by non-transformed (transform-skip or transquant-bypass) form.
	idx := 0
	if b.c_idx > 0 do idx += 2
	if b.transform_skip || b.transquant_bypass do idx += 1
	return idx
}

update_stat_coeff :: proc(stat: ^[4]u8, i: int, rem: i32) {
	switch {
	case rem >= 3 << uint(stat[i] / 4):
		stat[i] += 1
	case 2 * rem < 1 << uint(stat[i] / 4) && stat[i] > 0:
		stat[i] -= 1
	}
}

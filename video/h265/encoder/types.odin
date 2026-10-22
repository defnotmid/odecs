package h265_encoder

import common "../../../common"

import "core:math"

MIN_CU_LOG2 :: 3
MAX_CU_LOG2 :: 6
MAX_CU_DEPTH :: 3
MIN_PU_LOG2 :: 3
MAX_TU_LOG2 :: 5

// PCM coding block sizes signalled in the SPS: 8..32 (the CTU is always split,
// so no CU larger than 32 is coded).
PCM_LOG2_MIN :: 3
PCM_LOG2_MAX :: 5
CTU_WIDTH :: 1 << MAX_CU_LOG2
CTU_CELLS :: CTU_WIDTH / 4

MAX_REF_PICS :: 16
MAX_QP_DELTA_DEPTH :: 0

// Scaling list mode: off signals neither list and quantizes flat, default
// signals the spec's default matrices (7.4.5) and quantizes with them, and flat
// signals an all-16 list explicitly (quantization is then identical to off).
Scaling_Mode :: enum u8 {
	Off,
	Default,
	Flat,
}

C1FLAG_NUMBER :: 8

Cu_Type :: enum u8 {
	Unset = 0,
	Intra = 1,
	Inter = 2,
	PCM   = 3,
}

Part_Mode :: enum u8 {
	P_2Nx2N = 0,
	P_2NxN  = 1,
	P_Nx2N  = 2,
	P_NxN   = 3,
	P_2NxnU = 4,
	P_2NxnD = 5,
	P_nLx2N = 6,
	P_nRx2N = 7,
}

// Per-CU information, replicated into every 4x4 cell it covers.
Cu_Info :: struct {
	type:        Cu_Type,
	depth:       u8,
	part:        Part_Mode,
	tr_depth:    u8, // inter transform tree leaf size (log2), 0 when RQT is off
	mode:        u8, // luma intra mode 0..34
	chroma_mode: u8, // chroma intra mode 0..34, 36 = derived from luma
	cbf_y:       bool,
	cbf_u:       bool,
	cbf_v:       bool,
	// Transform skip of a 4x4 luma intra leaf, replayed by the bitstream pass.
	tskip:       bool,
	// PCM coding unit: raw samples instead of prediction and residual, replayed
	// by the bitstream pass. The type stays .Intra so deblocking treats it like
	// any intra block, exactly as the decoder does.
	pcm:         bool,
	skipped:     bool,
	// A partitioned CU whose rqt_root_cbf the search forced to zero: the
	// bitstream pass must replay that instead of coding the residual.
	part_skip:   bool,
	merge:       bool,
	merge_idx:   u8,
	// 8.7.2 transform block edges for the inter transform tree, per 4x4 cell:
	// only the first column and first row of a transform block carry them.
	tu_v:        bool,
	tu_h:        bool,
	// 8.7.2 prediction block edges of a partitioned CU, same convention.
	pu_v:        bool,
	pu_h:        bool,
	pred:        [2]bool, // which reference lists this CU predicts from
	mv:          [2][2]i16, // motion vector per list
	ref_idx:     [2]i8, // per-list reference index, -1 when the list is unused
	mv_cand:     u8,
	idc:         u8, // inter_pred_idc for B non-merge (0 L0, 1 L1, 2 BI)
	mvp_flag:    [2]u8, // mvp_lX_flag chosen per list
	qp:          i32,
	cost:        f64,
}

Cu_Grid :: struct {
	cells: []Cu_Info,
	cols:  int, // cells per row (coded_width / 4)
}

cu_at :: #force_inline proc(g: Cu_Grid, x, y: int) -> ^Cu_Info #no_bounds_check {
	return &g.cells[(y >> 2) * g.cols + (x >> 2)]
}

// Encoder configuration.
Config :: struct {
	width:               int,
	height:              int,
	qp:                  i32,
	// Luma/chroma sample bit depth: 8 or 10 (Main / Main 10).
	bit_depth:           int,
	profile:             u8,
	// level_idc 0 selects the lowest level that fits the resolution, frame
	// rate and DPB (Annex A); a positive value is signalled as is.
	level_idc:           u8,
	// Chroma format (chroma_format_idc). The default YUV_420 is the
	// historical encoder; Monochrome codes no chroma planes at all.
	chroma_format:       Chroma_Layout,
	// Frames per second for the VUI timing information (0 leaves it
	// unmarked); also the sample rate for level selection.
	fps_num:             int,
	fps_den:             int,
	// VUI (E.2): aspect-free timing info and the bitstream restriction
	// block, signalled opt-in.
	vui:                 bool,
	// VUI video signal type (E.2.1) in ITU-T H.273 code points. A nonzero
	// colour_primaries writes the VUI with this colour description even
	// when `vui` is off; zero leaves it unsignalled.
	colour_primaries:    u8,
	transfer:            u8,
	matrix_coeffs:       u8,
	full_range:          bool,
	// SEI: a recovery point (D.2.7) on every IRAP picture and a
	// decoded-picture-hash suffix (D.2, checksum) per picture, opt-in.
	sei_recovery:        bool,
	sei_hash:            bool,
	// Mastering display colour volume SEI (D.2.28): the display primaries,
	// white point and luminance range as the spec's 10.7 fixed-point values
	// (primaries/white point in 0.00002 units, max/min luminance in
	// 0.0001 cd/m^2).
	sei_mastering:       bool,
	mastering:           Mastering_Display,
	// HRD parameters (E.2.2) in the VUI: the formal CBR signalling of the
	// rate-control buffer (needs vui and a bit rate).
	hrd:                 bool,
	// Rate control (needs fps_num/fps_den): Constant_QP keeps the historical
	// fixed-QP behaviour; ABR feeds the picture QP back toward `bitrate`
	// bits per second; CBR adds the leaky-bucket buffer model; CRF is
	// constant quality at the `crf` anchor with frame-type offsets.
	rc:                  Rc_Mode,
	bitrate:             int,
	crf:                 f32,
	// CBR buffer size in bits (0 = one second of the target rate).
	rc_buffer:           int,
	intra_only:          bool,
	intra_only_i_slices: bool,
	forced_mode:         i32,
	deblock:             bool,
	sao:                 bool,
	b_frames:            bool,
	rqt:                 bool,
	intra_rqt:           bool,
	// Transform skip for 4x4 intra luma blocks (Main profile size limit).
	tskip:               bool,
	// Implicit residual DPCM for transform-skip blocks (SPS range extension).
	// Only meaningful together with tskip, which it implies.
	rdpcm:               bool,
	// PCM coding units (SPS pcm_enabled_flag): an intra CU may be coded as raw
	// samples when that is cheaper than prediction plus residual.
	pcm:                 bool,
	amp:                 bool,
	weighted:            bool,
	// Temporal motion vector prediction (SPS temporal_mvp_enabled_flag): the
	// collocated-reference candidate of 8.5.3.2.8/8.5.3.2.9 joins the merge and
	// AMVP lists, and the slice header signals collocated_from_l0 (always true)
	// and collocated_ref_idx (always 0).
	tmvp:                bool,
	// Wavefront parallel processing (PPS entropy_coding_sync_enabled_flag):
	// each CTU row is its own CABAC substream with 9.3.1 context handoff, and
	// the slice header carries the entry point offsets.
	wpp:                 bool,
	// Tiles (PPS tiles_enabled_flag): the CTB grid splits into tiles coded in
	// 6.5.1 tile-scan order, each tile its own CABAC substream with the
	// contexts re-initialized at the tile start (9.3.2.2). The counts spell
	// out the PPS tile widths (uniform_spacing_flag = 0); 0 keeps the
	// historical single-tile bitstream. Mutually exclusive with wpp for
	// 4:2:0.
	tiles_cols:          int,
	tiles_rows:          int,
	// Parallel tile search pool, passed in by the caller (nil keeps the
	// search serial): the codecs never create or own threads, so scheduling
	// and contention stay the caller's business. The tile decisions are
	// independent, so the output is identical for every pool.
	pool:                ^common.Work_Pool,
	// Quantization scaling lists: signalled in the SPS and applied on both
	// sides (7.4.5). Off leaves the flat list and the historical bitstream.
	scaling:             Scaling_Mode,
	// Closed hierarchical GOP: buffer display-order input and code a dyadic
	// B pyramid in coding order (see hierarchical.odin).
	hierarchical:        bool,
	gop_size:            int,
	// Periodic closed IDRs for the low-delay P path. Zero preserves the
	// original initial-IDR-only stream. B/hierarchical paths do not use it.
	idr_period:          int,
	// Active past references of a P slice (1 = the historical single ref).
	refs:                int,
	capture_rec:         bool,
	// Auxiliary alpha layer (Annex F, AuxId 1); see alpha.odin. Encode the
	// colour with Base_With_Alpha and the alpha plane with Alpha, both with
	// the same geometry and GOP settings, and join each pair of access units
	// with interleave_alpha.
	layer:               Layer_Role,
	// The alpha channel information SEI's alpha_channel_use_idc: true (1)
	// marks colour premultiplied by alpha, false (0) straight colour.
	alpha_premultiplied: bool,
	// Prefer speed over size: a top-down CU tree, four intra modes, a
	// diamond integer search refined to half-pel, earlier merge decisions.
	ultrafast:           bool,
}

Layer_Role :: enum u8 {
	Single,
	// Layer 0 of a stream with alpha: a VPS that declares the alpha layer
	// and the alpha channel information SEI on every IRAP picture.
	Base_With_Alpha,
	// The alpha layer: nuh_layer_id 1, SPS and PPS id 1, no VPS.
	Alpha,
}

// Reference pictures the encoder keeps per list. The default configuration
// uses one (P) and two (low-delay B); multi-reference P searches this history.
MAX_ENC_REFS :: 4

// Largest supported hierarchical GOP. The input queue holds one group plus its
// left anchor, and the DPB the group's coded pictures.
MAX_GOP :: 8
MAX_HIER_FRAMES :: MAX_GOP + 2

// Pictures whose collocated motion fields the temporal predictor can still
// name. The live set is the reference history plus the hierarchical DPB
// (MAX_HIER_FRAMES) and the picture being coded.
MAX_COL_PICS :: 16

// Wavefront substreams in one slice: one per CTU row boundary, so the largest
// supported picture (8192 luma samples, 64-sample CTUs) needs 127.
MAX_WPP_SUBSTREAMS :: 128

// Col_Motion_Enc is the encoder's copy of the decoder's per-picture
// collocated motion field: 16x16 subsampled (8.5.3.2.9) with reference
// pictures already resolved to POCs. The encoder keeps one of these per coded
// picture so a later picture can derive the temporal candidate exactly as the
// decoder reads its DPB picture's field.
Col_Motion_Enc :: struct {
	info:     Mv_Info,
	ref_poc:  [2]i32,
	ref_long: [2]bool,
	intra:    bool,
}

// Maximum inter transform hierarchy depth signalled in the SPS when RQT is on.
// The tree in this encoder never splits below 8x8 luma TUs; the extra depth is
// left available to the decoder and costs nothing.
RQT_MAX_HIER :: 3

// The inter transform tree in this encoder stops at 8x8 luma TUs. A 4x4 luma TU
// would move chroma to the blk_idx == 3 special case of 7.3.8.9 (and off the
// 8x8 deblocking grid), which is not worth its RD.
MIN_RQT_TU_LOG2 :: 3

// Lambda for HEVC quantizer QP: 0.57 * 2^((QP-12)/3).
// rc_type_offset is the picture-type part of the frame QP.
rc_type_offset :: #force_inline proc(slice_type: Slice_Type) -> f64 {
	return slice_type == .I ? -2 : (slice_type == .B ? 1 : 0)
}

// Chroma_Layout is the encoder's chroma format choice. YUV_420 is zero so a
// zero-initialized Config keeps its historical meaning; the bitstream idc
// comes from layout_idc.
Chroma_Layout :: enum u8 {
	YUV_420,
	Monochrome,
	YUV_422,
	YUV_444,
}

// has_chroma is the ChromaArrayType != 0 gate every chroma syntax write and
// reconstruction path takes.
has_chroma :: #force_inline proc(enc: ^Encoder) -> bool {
	return enc.config.chroma_format != .Monochrome
}

// chroma_blocks is the number of stacked square transform blocks one chroma
// component takes per luma block (7.3.8.10: 4:2:2 stacks two).
chroma_blocks :: #force_inline proc(l: Chroma_Layout) -> int {
	return l == .Monochrome ? 0 : (l == .YUV_422 ? 2 : 1)
}

// chroma_pred_mode maps the intra chroma mode through Table 8-3 for 4:2:2
// (8.4.2); every other format predicts with the derived mode as is.
chroma_pred_mode :: #force_inline proc(l: Chroma_Layout, mode: u8) -> u8 {
	if l == .YUV_422 {
		table := CHROMA_422_MAP
		return table[mode]
	}
	return mode
}

// Table 8-3 (the decoder carries the same table for its side).
CHROMA_422_MAP :: [35]u8 {
	0,
	1,
	2,
	2,
	2,
	2,
	3,
	5,
	7,
	8,
	10,
	12,
	13,
	15,
	17,
	18,
	19,
	20,
	21,
	22,
	23,
	23,
	24,
	24,
	25,
	25,
	26,
	27,
	27,
	28,
	28,
	29,
	29,
	30,
	31,
}

// intra_scan mirrors the decoder's scan_index derivation (6.5.x): the
// mode-driven scan applies to 4x4 blocks and to 8x8 luma (and 8x8 chroma at
// ChromaArrayType 3); everything else is diagonal. `pred_mode` is the
// component's own prediction mode — the Table 8-3-mapped one for 4:2:2
// chroma.
intra_scan :: proc(log2_size, c_idx, pred_mode: int, chroma_array_type: u32) -> Scan_Order {
	if log2_size != 2 && !(log2_size == 3 && (c_idx == 0 || chroma_array_type == 3)) {
		return .Diag
	}
	if pred_mode >= 6 && pred_mode <= 14 do return .Vertical
	if pred_mode >= 22 && pred_mode <= 30 do return .Horizontal
	return .Diag
}

// chroma_sub is the format's subsampling (Table 6-1).
chroma_sub :: proc(l: Chroma_Layout) -> (int, int) {
	if l == .YUV_420 do return 2, 2
	if l == .YUV_422 do return 2, 1
	if l == .YUV_444 do return 1, 1
	return 1, 1 // monochrome has no chroma, and its gates skip these values
}

// chroma_mv scales a quarter-luma-sample motion vector to the 1/8-chroma
// units mc_chroma consumes (8.5.3.3.3).
chroma_mv :: proc(l: Chroma_Layout, mv: [2]i16) -> [2]i16 {
	sw, sh := chroma_sub(l)
	return {i16(i32(mv[0]) * 2 / i32(sw)), i16(i32(mv[1]) * 2 / i32(sh))}
}

layout_format :: proc(l: Chroma_Layout) -> Chroma_Format {
	return Chroma_Format(layout_idc(l))
}

layout_idc :: proc(l: Chroma_Layout) -> u32 {
	switch l {
	case .YUV_420:
		return 1
	case .Monochrome:
		return 0
	case .YUV_422:
		return 2
	case .YUV_444:
		return 3
	}

	return 1
}

Mastering_Display :: struct {
	primaries_x: [3]u16,
	primaries_y: [3]u16,
	white_x:     u16,
	white_y:     u16,
	max_luma:    u32,
	min_luma:    u32,
}

Rc_Mode :: enum u8 {
	Constant_QP,
	ABR,
	CBR,
	CRF,
}

// Rc_State is the whole rate-control record: one preallocated struct per
// encode, updated once per picture (the codecs never allocate in the hot
// path and the caller's configuration is the only input).
Rc_State :: struct {
	mode:        Rc_Mode,
	base_qp:     i32,
	target_bits: f64, // bits per picture
	qp_adjust:   f64,
	// The picture QP offset actually used last (the feedback anchors its
	// Newton step at the operating point, not at the base QP).
	last_offset: f64,
	total_bits:  i64,
	coded:       int,
	buffer:      f64, // CBR buffer fullness in bits
	buffer_size: f64,
}

qd_lambda :: proc(qp: i32) -> f64 {
	return 0.57 * math.pow(2.0, f64(qp - 12) / 3.0)
}

// The luma Qp' the quantizer and dequantizer expect. 8.6.3 carries the
// 6 * (bit_depth - 8) bit-depth offset above 8-bit.
luma_qp_scaled :: #force_inline proc(enc: ^Encoder) -> i32 {
	return enc.qp + 6 * i32(enc.bit_depth - 8)
}

// Chroma Qp'C of 8.6.3: qPi runs from -QpBdOffsetC to 57, maps through the
// Table 8-10 curve (the identity below zero) and then carries the offset.
chroma_qp_scaled :: #force_inline proc(enc: ^Encoder) -> i32 {
	off_c := 6 * i32(enc.bit_depth - 8)
	q := clamp(enc.qp, -off_c, 57)
	if q < 0 do return q + off_c
	return chroma_qp(q, int(layout_idc(enc.config.chroma_format))) + off_c
}

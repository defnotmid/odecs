// VP9 syntax and reconstruction shared by the decoder and encoder:
// constants, probability contexts with their defaults and backward
// adaptation, transforms, intra/inter prediction and the loop filter.
// Written from the VP9 Bitstream & Decoding Process Specification v0.7;
// tables.odin is generated from that document by tools/tables.
package vp9

// Block sizes (width x height in samples).
BLOCK_4X4 :: 0
BLOCK_4X8 :: 1
BLOCK_8X4 :: 2
BLOCK_8X8 :: 3
BLOCK_8X16 :: 4
BLOCK_16X8 :: 5
BLOCK_16X16 :: 6
BLOCK_16X32 :: 7
BLOCK_32X16 :: 8
BLOCK_32X32 :: 9
BLOCK_32X64 :: 10
BLOCK_64X32 :: 11
BLOCK_64X64 :: 12
BLOCK_INVALID :: 14

PARTITION_NONE :: 0
PARTITION_HORZ :: 1
PARTITION_VERT :: 2
PARTITION_SPLIT :: 3

// Intra modes, then the inter modes that follow them in y_mode.
DC_PRED :: 0
V_PRED :: 1
H_PRED :: 2
D45_PRED :: 3
D135_PRED :: 4
D117_PRED :: 5
D153_PRED :: 6
D207_PRED :: 7
D63_PRED :: 8
TM_PRED :: 9
NEARESTMV :: 10
NEARMV :: 11
ZEROMV :: 12
NEWMV :: 13

TX_4X4 :: 0
TX_8X8 :: 1
TX_16X16 :: 2
TX_32X32 :: 3

ONLY_4X4 :: 0
ALLOW_8X8 :: 1
ALLOW_16X16 :: 2
ALLOW_32X32 :: 3
TX_MODE_SELECT :: 4

DCT_DCT :: 0
ADST_DCT :: 1 // ADST columns (vertical), DCT rows
DCT_ADST :: 2 // DCT columns, ADST rows
ADST_ADST :: 3

INTRA_FRAME :: 0
LAST_FRAME :: 1
GOLDEN_FRAME :: 2
ALTREF_FRAME :: 3
NONE :: -1 // as stored in ref_frame[1] (the spec's NONE <= INTRA_FRAME)

EIGHTTAP :: 0
EIGHTTAP_SMOOTH :: 1
EIGHTTAP_SHARP :: 2
BILINEAR :: 3
SWITCHABLE :: 4

SINGLE_REFERENCE :: 0
COMPOUND_REFERENCE :: 1
REFERENCE_MODE_SELECT :: 2

MV_JOINT_ZERO :: 0
MV_JOINT_HNZVZ :: 1
MV_JOINT_HZVNZ :: 2
MV_JOINT_HNZVNZ :: 3

SEG_LVL_ALT_Q :: 0
SEG_LVL_ALT_L :: 1
SEG_LVL_REF_FRAME :: 2
SEG_LVL_SKIP :: 3

ZERO_TOKEN :: 0
ONE_TOKEN :: 1
TWO_TOKEN :: 2
DCT_VAL_CAT6 :: 10

CS_RGB :: 7

NUM_REF_FRAMES :: 8
MAX_SEGMENTS :: 8
TX_SIZES :: 4
TX_SIZE_CONTEXTS :: 2
SKIP_CONTEXTS :: 3
INTER_MODE_CONTEXTS :: 7
INTER_MODES :: 4
INTERP_FILTER_CONTEXTS :: 4
SWITCHABLE_FILTERS :: 3
IS_INTER_CONTEXTS :: 4
COMP_MODE_CONTEXTS :: 5
REF_CONTEXTS :: 5
BLOCK_SIZE_GROUPS :: 4
INTRA_MODES :: 10
PARTITION_CONTEXTS :: 16
PARTITION_TYPES :: 4
MV_JOINTS :: 4
MV_CLASSES :: 11
CLASS0_SIZE :: 2
MV_OFFSET_BITS :: 10
MV_FR_SIZE :: 4
COEF_BANDS :: 6
PREV_COEF_CONTEXTS :: 6
UNCONSTRAINED_NODES :: 3
MAX_LOOP_FILTER :: 63
COMPANDED_MVREF_THRESH :: 8
MV_BORDER :: 128
INTERP_EXTEND :: 4
BORDERINPIXELS :: 160
MAX_TILE_WIDTH_B64 :: 64
MIN_TILE_WIDTH_B64 :: 4
COUNT_SAT :: 20
MAX_UPDATE_FACTOR :: 128

Mv :: [2]i16 // row, column in 1/8 samples

// Every adaptive probability, indexed as the specification indexes them
// (tx[TX_8X8..TX_32X32][ctx][node], index 0 unused).
Probabilities :: struct {
	tx:            [TX_SIZES][TX_SIZE_CONTEXTS][3]u8,
	skip:          [SKIP_CONTEXTS]u8,
	coef:          [TX_SIZES][2][2][COEF_BANDS][PREV_COEF_CONTEXTS][UNCONSTRAINED_NODES]u8,
	inter_mode:    [INTER_MODE_CONTEXTS][INTER_MODES - 1]u8,
	interp_filter: [INTERP_FILTER_CONTEXTS][SWITCHABLE_FILTERS - 1]u8,
	is_inter:      [IS_INTER_CONTEXTS]u8,
	comp_mode:     [COMP_MODE_CONTEXTS]u8,
	single_ref:    [REF_CONTEXTS][2]u8,
	comp_ref:      [REF_CONTEXTS]u8,
	y_mode:        [BLOCK_SIZE_GROUPS][INTRA_MODES - 1]u8,
	uv_mode:       [INTRA_MODES][INTRA_MODES - 1]u8,
	partition:     [PARTITION_CONTEXTS][PARTITION_TYPES - 1]u8,
	mv_joint:      [MV_JOINTS - 1]u8,
	mv_sign:       [2]u8,
	mv_class:      [2][MV_CLASSES - 1]u8,
	mv_class0_bit: [2]u8,
	mv_bits:       [2][MV_OFFSET_BITS]u8,
	mv_class0_fr:  [2][CLASS0_SIZE][MV_FR_SIZE - 1]u8,
	mv_fr:         [2][MV_FR_SIZE - 1]u8,
	mv_class0_hp:  [2]u8,
	mv_hp:         [2]u8,
}

// Symbol counts for backward adaptation (section 8.3); summed across tiles.
Counts :: struct {
	intra_mode:    [BLOCK_SIZE_GROUPS][INTRA_MODES]u32,
	uv_mode:       [INTRA_MODES][INTRA_MODES]u32,
	partition:     [PARTITION_CONTEXTS][PARTITION_TYPES]u32,
	interp_filter: [INTERP_FILTER_CONTEXTS][SWITCHABLE_FILTERS]u32,
	inter_mode:    [INTER_MODE_CONTEXTS][INTER_MODES]u32,
	tx_size:       [TX_SIZES][TX_SIZE_CONTEXTS][TX_SIZES]u32,
	is_inter:      [IS_INTER_CONTEXTS][2]u32,
	comp_mode:     [COMP_MODE_CONTEXTS][2]u32,
	single_ref:    [REF_CONTEXTS][2][2]u32,
	comp_ref:      [REF_CONTEXTS][2]u32,
	skip:          [SKIP_CONTEXTS][2]u32,
	mv_joint:      [MV_JOINTS]u32,
	mv_sign:       [2][2]u32,
	mv_class:      [2][MV_CLASSES]u32,
	mv_class0_bit: [2][CLASS0_SIZE]u32,
	mv_class0_fr:  [2][CLASS0_SIZE][MV_FR_SIZE]u32,
	mv_class0_hp:  [2][2]u32,
	mv_bits:       [2][MV_OFFSET_BITS][2]u32,
	mv_fr:         [2][MV_FR_SIZE]u32,
	mv_hp:         [2][2]u32,
	token:         [TX_SIZES][2][2][COEF_BANDS][PREV_COEF_CONTEXTS][UNCONSTRAINED_NODES]u32,
	more_coefs:    [TX_SIZES][2][2][COEF_BANDS][PREV_COEF_CONTEXTS][2]u32,
}

default_probabilities :: proc(p: ^Probabilities) {
	p.tx = DEFAULT_TX_PROBS
	p.skip = DEFAULT_SKIP_PROB
	p.coef = DEFAULT_COEF_PROBS
	p.inter_mode = DEFAULT_INTER_MODE_PROBS
	p.interp_filter = DEFAULT_INTERP_FILTER_PROBS
	p.is_inter = DEFAULT_IS_INTER_PROB
	p.comp_mode = DEFAULT_COMP_MODE_PROB
	p.single_ref = DEFAULT_SINGLE_REF_PROB
	p.comp_ref = DEFAULT_COMP_REF_PROB
	p.y_mode = DEFAULT_Y_MODE_PROBS
	p.uv_mode = DEFAULT_UV_MODE_PROBS
	p.partition = DEFAULT_PARTITION_PROBS
	p.mv_joint = DEFAULT_MV_JOINT_PROBS
	p.mv_sign = DEFAULT_MV_SIGN_PROB
	p.mv_class = DEFAULT_MV_CLASS_PROBS
	p.mv_class0_bit = DEFAULT_MV_CLASS0_BIT_PROB
	p.mv_bits = DEFAULT_MV_BITS_PROB
	p.mv_class0_fr = DEFAULT_MV_CLASS0_FR_PROBS
	p.mv_fr = DEFAULT_MV_FR_PROBS
	p.mv_class0_hp = DEFAULT_MV_CLASS0_HP_PROB
	p.mv_hp = DEFAULT_MV_HP_PROB
}

// load_probs: every table except tx and skip, which load_probs2 restores.
load_probs :: proc(p: ^Probabilities, saved: ^Probabilities) {
	tx, skip := p.tx, p.skip
	p^ = saved^
	p.tx, p.skip = tx, skip
}

load_probs2 :: proc(p: ^Probabilities, saved: ^Probabilities) {
	p.tx, p.skip = saved.tx, saved.skip
}

// Segmentation feature data, loop filter deltas and the frame size persist
// between frames until setup_past_independence resets them.
Segmentation :: struct {
	enabled, update_map, temporal_update, abs_or_delta_update: bool,
	tree_probs:      [7]u8,
	pred_probs:      [3]u8,
	feature_enabled: [MAX_SEGMENTS][4]bool,
	feature_data:    [MAX_SEGMENTS][4]i16,
}

Loop_Filter :: struct {
	level, sharpness: int,
	delta_enabled:    bool,
	ref_deltas:       [4]i8,
	mode_deltas:      [2]i8,
}

seg_feature_active :: #force_inline proc(s: ^Segmentation, segment, feature: int) -> bool {
	return s.enabled && s.feature_enabled[segment][feature]
}

// The quantizer index of a segment (section 8.6.1).
segment_qindex :: proc(s: ^Segmentation, base_q_idx, segment: int) -> int {
	if !seg_feature_active(s, segment, SEG_LVL_ALT_Q) do return base_q_idx
	data := int(s.feature_data[segment][SEG_LVL_ALT_Q])
	if !s.abs_or_delta_update do data += base_q_idx
	return clamp(data, 0, 255)
}

dc_q :: #force_inline proc(bit_depth, q: int) -> i32 {return i32(DC_QLOOKUP[(bit_depth - 8) >> 1][clamp(q, 0, 255)])}
ac_q :: #force_inline proc(bit_depth, q: int) -> i32 {return i32(AC_QLOOKUP[(bit_depth - 8) >> 1][clamp(q, 0, 255)])}

// Mode info of one 8x8 cell; a block writes every cell it covers. sub_mvs[l][3]
// is the block's motion vector for reference list l.
Mode_Info :: struct {
	sub_mvs:       [2][4]Mv,
	ref_frame:     [2]i8, // INTRA_FRAME (0) or LAST..ALTREF; ref_frame[1] is NONE (-1) unless compound
	sub_modes:     [4]u8,
	mi_size:       u8,
	tx_size:       u8,
	y_mode:        u8,
	interp_filter: u8,
	segment_id:    u8,
	skip:          bool,
}

// Transform size of the chroma planes for a block (get_uv_tx_size).
uv_tx_size :: #force_inline proc "contextless" (mi_size, tx_size, ss_x, ss_y: int) -> int {
	if mi_size < BLOCK_8X8 do return TX_4X4
	return min(tx_size, int(MAX_TXSIZE_LOOKUP[SS_SIZE_LOOKUP[mi_size][ss_x][ss_y]]))
}

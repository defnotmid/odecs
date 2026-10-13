package h264

// NAL unit byte range within bitstream
Nal_Location :: struct {
	offset: int,
	length: int,
}

// NAL unit types
Nal_Unit_Type :: enum u8 {
	Unspecified            = 0,
	Slice_Non_IDR          = 1,
	Slice_DPA              = 2,
	Slice_DPB              = 3,
	Slice_DPC              = 4,
	Slice_IDR              = 5,
	SEI                    = 6,
	Sequence_Parameter_Set = 7,
	Picture_Parameter_Set  = 8,
	AUD                    = 9,
	End_Of_Seq             = 10,
	End_Of_Stream          = 11,
	Filter_Data            = 12,
	SPS_Ext                = 13,
	Prefix                 = 14,
	Subset_SPS             = 15,
}

// Slice types (modulo 5)
Slice_Type :: enum u8 {
	P  = 0,
	B  = 1,
	I  = 2,
	SP = 3,
	SI = 4,
}

// Macroblock types. B partitions carry their prediction direction per 8x8 in
// Macroblock.prediction_directions; B_8x8 stores its subpartition types separately.
Macroblock_Type :: enum u8 {
	I_4x4,
	I_8x8,
	I_16x16,
	I_PCM,
	P_L0_16x16,
	P_L0_L0_16x8,
	P_L0_L0_8x16,
	P_8x8,
	P_8x8ref0,
	P_Skip,
	B_Direct_16x16,
	B_16x16,
	B_16x8,
	B_8x16,
	B_8x8,
	B_Skip,
}

// Numeric values are the H.264 syntax codes, not internal ordinal positions.
// Profile constraints remain separate from the base profile identifier.
Sequence_Profile :: enum u8 {
	Unspecified                                 = 0,
	CAVLC_444_Intra                             = 44,
	Baseline                                    = 66,
	Main                                        = 77,
	Scalable_Baseline                           = 83,
	Scalable_High                               = 86,
	Extended                                    = 88,
	High                                        = 100,
	High_10                                     = 110,
	Multiview_High                              = 118,
	High_422                                    = 122,
	Stereo_High                                 = 128,
	Multiresolution_Frame_Compatible_High       = 134,
	Multiresolution_Frame_Compatible_Depth_High = 135,
	Multiview_Depth_High                        = 138,
	Enhanced_Multiview_Depth_High               = 139,
	High_444_Legacy                             = 144,
	High_444_Predictive                         = 244,
}

Sequence_Level :: enum u8 {
	Unspecified = 0,
	Level_1b    = 9,
	Level_1     = 10,
	Level_1_1   = 11,
	Level_1_2   = 12,
	Level_1_3   = 13,
	Level_2     = 20,
	Level_2_1   = 21,
	Level_2_2   = 22,
	Level_3     = 30,
	Level_3_1   = 31,
	Level_3_2   = 32,
	Level_4     = 40,
	Level_4_1   = 41,
	Level_4_2   = 42,
	Level_5     = 50,
	Level_5_1   = 51,
	Level_5_2   = 52,
	Level_6     = 60,
	Level_6_1   = 61,
	Level_6_2   = 62,
}

Chroma_Format :: enum u32 {
	Monochrome = 0,
	YUV_420    = 1,
	YUV_422    = 2,
	YUV_444    = 3,
}
Picture_Order_Mode :: enum u32 {
	Explicit_Low_Bits = 0,
	Reference_Cycle   = 1,
	Frame_Number      = 2,
}
Prediction_Direction :: enum u8 {
	None          = 0,
	List_0        = 1,
	List_1        = 2,
	Bidirectional = 3,
}
Chroma_Residual_Mode :: enum u8 {
	None      = 0,
	DC_Only   = 1,
	DC_And_AC = 2,
}
Deblocking_Mode :: enum u8 {
	All_Edges    = 0,
	Disabled     = 1,
	Within_Slice = 2,
}

// Normalized prediction/shape values. B syntax maps directly; P syntax is
// translated when parsed so a stored type has one meaning in either slice.
Subpartition_Type :: enum u8 {
	Direct_8x8        = 0,
	List_0_8x8        = 1,
	List_1_8x8        = 2,
	Bidirectional_8x8 = 3,
	List_0_8x4        = 4,
	List_0_4x8        = 5,
	List_1_8x4        = 6,
	List_1_4x8        = 7,
	Bidirectional_8x4 = 8,
	Bidirectional_4x8 = 9,
	List_0_4x4        = 10,
	List_1_4x4        = 11,
	Bidirectional_4x4 = 12,
}

Subpartition_Shape :: enum u8 {
	Block_8x8,
	Block_8x4,
	Block_4x8,
	Block_4x4,
}

// Sequence Parameter Set (H.264 specifies at most 32 SPS, max ID 31)
Sequence_Parameter_Set :: struct {
	profile:                            Sequence_Profile,
	constraint_set_0:                   bool,
	constraint_set_1:                   bool,
	constraint_set_2:                   bool,
	constraint_set_3:                   bool,
	level:                              Sequence_Level,
	sequence_parameter_set_id:          u32,
	chroma_format:                      Chroma_Format,
	luma_bit_depth_minus_8:             u32,
	chroma_bit_depth_minus_8:           u32,
	bypass_transform_at_zero_quantizer: bool,
	has_scaling_matrices:               bool,
	scaling_list_4x4:                   [6][16]u8,
	scaling_list_8x8:                   [2][64]u8,
	frame_number_bits:                  u32,
	picture_order_mode:                 Picture_Order_Mode,
	picture_order_low_bits:             u32,
	picture_order_delta_always_zero:    bool,
	non_reference_picture_order_offset: i32,
	top_to_bottom_field_order_offset:   i32,
	reference_cycle_length:             u32,
	reference_frame_order_offsets:      [256]i32,
	max_reference_frames:               u32,
	allow_frame_number_gaps:            bool,
	frames_only:                        bool,
	adaptive_frame_field_coding:        bool,
	infer_direct_8x8_motion:            bool,
	has_cropping:                       bool,
	crop_left:                          u32,
	crop_right:                         u32,
	crop_top:                           u32,
	crop_bottom:                        u32,
	has_video_usability_information:    bool,
	// VUI colour description (E.2.1): ITU-T H.273 code points, 2
	// (unspecified) unless the sequence signals them.
	colour_primaries:                   u8,
	transfer_characteristics:           u8,
	matrix_coefficients:                u8,
	video_full_range:                   bool,
	has_scaling_list:                   [8]bool, // per list: explicitly sent (else fallback rules apply)
	use_default_scaling_list:           [8]bool, // sent as "use default" (useDefaultScalingMatrixFlag)
	// VUI bitstream_restriction
	has_bitstream_restrictions:         bool,
	max_reordered_frames:               u32,
	max_buffered_frames:                u32,
	// Precomputed flat dimensions
	width:                              int,
	height:                             int,
	macroblock_columns:                 int,
	macroblock_rows:                    int,
	macroblock_count:                   int,
}

// Picture Parameter Set (H.264 specifies at most 256 PPS, max ID 255)
Picture_Parameter_Set :: struct {
	pic_parameter_set_id:                         u32,
	sequence_parameter_set_id:                    u32,
	entropy_coding_mode_flag:                     bool, // false = CAVLC, true = CABAC
	bottom_field_pic_order_in_frame_present_flag: bool,
	num_slice_groups_minus1:                      u32,
	num_ref_idx_l0_default_active:                u32,
	num_ref_idx_l1_default_active:                u32,
	weighted_pred_flag:                           bool,
	weighted_bipred_idc:                          u8,
	pic_init_qp:                                  i32,
	pic_init_qs:                                  i32,
	chroma_qp_index_offset:                       i32,
	deblocking_filter_control_present_flag:       bool,
	constrained_intra_pred_flag:                  bool,
	redundant_pic_cnt_present_flag:               bool,
	transform_8x8_mode_flag:                      bool,
	pic_scaling_matrix_present_flag:              bool,
	scaling_list_4x4:                             [6][16]u8,
	scaling_list_8x8:                             [2][64]u8,
	has_scaling_list:                             [8]bool,
	use_default_scaling_list:                     [8]bool,
	second_chroma_qp_index_offset:                i32,
	redundant_pic_cnt:                            u32, // unused, slices with redundant_pic_cnt > 0 are dropped
}

// Slice Header
// ref_pic_list_modification and memory_management_control_operation commands
// as parsed; only the first MAX_REF_COMMANDS of each are kept.
MAX_REF_COMMANDS :: 16

Ref_Reorder_Command :: struct {
	idc:   u32, // 0: subtract, 1: add abs_diff_pic_num, 2: long_term_pic_num
	value: u32,
}

MMCO_Command :: struct {
	op:   u32,
	arg1: u32, // difference_of_pic_nums_minus1 / long_term_pic_num / max_long_term_frame_idx_plus1
	arg2: u32, // long_term_frame_idx for ops 3 and 6
}

// Explicit weighted prediction table (7.3.3.2), defaults filled in when a
// flag is 0: weight = 1 << log2_denom, offset = 0.
Pred_Weight_Table :: struct {
	luma_log2_denom:   u32,
	chroma_log2_denom: u32,
	luma_weight:       [2][32]i32,
	luma_offset:       [2][32]i32,
	chroma_weight:     [2][32][2]i32,
	chroma_offset:     [2][32][2]i32,
}

Slice_Header :: struct {
	first_mb_in_slice:             int,
	slice_type:                    Slice_Type,
	pps_id:                        u32,
	frame_num:                     u32,
	idr_pic_id:                    u32,
	pic_order_cnt_lsb:             u32,
	delta_pic_order_cnt_bottom:    i32,
	delta_pic_order_cnt:           [2]i32,
	redundant_pic_cnt:             u32,
	direct_spatial_mv_pred_flag:   bool,
	num_ref_idx_l0_active:         u32,
	num_ref_idx_l1_active:         u32,
	reorder:                       [2][MAX_REF_COMMANDS]Ref_Reorder_Command,
	num_reorder:                   [2]int,
	weights:                       Pred_Weight_Table,
	no_output_of_prior_pics_flag:  bool,
	long_term_reference_flag:      bool,
	adaptive_ref_pic_marking_flag: bool,
	mmco:                          [MAX_REF_COMMANDS]MMCO_Command,
	num_mmco:                      int,
	cabac_init_idc:                u32,
	slice_qp_delta:                i32,
	slice_qp:                      i32,
	deblocking_mode:               Deblocking_Mode,
	slice_alpha_c0_offset_div2:    i32,
	slice_beta_offset_div2:        i32,
	// Derived
	nal_ref_idc:                   u8,
	is_idr:                        bool,
	poc:                           i32,
	mmco5:                         bool,
}


// Contiguous Planar YUV420 Image Buffer
YUV_Buffer :: struct {
	width:        int, // displayed (cropped) size
	height:       int,
	coded_width:  int, // macroblock-aligned decoded size; padding starts here
	coded_height: int,
	crop_x:       int, // origin of the displayed picture inside the coded one
	crop_y:       int,
	y_stride:     int,
	uv_stride:    int,
	y:            [^]u8,
	u:            [^]u8,
	v:            [^]u8,
	memory:       []u8, // Underlying single contiguous buffer
}

// Encoder reference / reconstruction frame
Frame :: struct {
	buf:          YUV_Buffer,
	poc:          int,
	frame_num:    int,
	is_reference: bool,
	is_idr:       bool,
	is_valid:     bool,
}

// Explicit sized prediction mode enums
Intra_4x4_Mode :: enum u8 {
	Vertical            = 0,
	Horizontal          = 1,
	DC                  = 2,
	Diagonal_Down_Left  = 3,
	Diagonal_Down_Right = 4,
	Vertical_Right      = 5,
	Horizontal_Down     = 6,
	Vertical_Left       = 7,
	Horizontal_Up       = 8,
}

Intra_16x16_Mode :: enum u8 {
	Vertical   = 0,
	Horizontal = 1,
	DC         = 2,
	Plane      = 3,
}

Intra_Chroma_Mode :: enum u8 {
	DC         = 0,
	Horizontal = 1,
	Vertical   = 2,
	Plane      = 3,
}

Deblock_Edge_Direction :: enum u8 {
	Vertical   = 0,
	Horizontal = 1,
}

// Per-macroblock decoding state of the current picture, stored as #soa.
// Block-indexed arrays use the 4x4 decoding order (subblock_to_xy).
Macroblock :: struct {
	type:                       Macroblock_Type,
	is_intra:                   bool,
	is_skip:                    bool, // P_Skip or B_Skip
	uses_8x8_transform:         bool,
	quantizer:                  i8, // luma quantization parameter (QP_Y)
	has_quantizer_delta:        bool, // mb_qp_delta != 0 (CABAC context of the next macroblock)
	luma_coded_block_mask:      u8,
	chroma_residual_mode:       Chroma_Residual_Mode,
	intra_16x16_mode:           Intra_16x16_Mode,
	intra_4x4_modes:            [16]Intra_4x4_Mode, // I_8x8 uses entries 0, 4, 8, 12
	chroma_prediction_mode:     Intra_Chroma_Mode,
	prediction_directions:      [4]Prediction_Direction,
	has_uniform_motion:         bool, // one direction, reference and vector for the whole macroblock
	subpartition_types:         [4]Subpartition_Type,
	reference_indices:          [2][4]i8,
	reference_picture_ids:      [2][4]i32, // pic_id of the referenced picture, -1 if none
	motion_vectors:             [2][16][2]i16,
	motion_differences:         [2][16][2]u8, // |mvd| clipped, CABAC context of neighbours
	nonzero_coefficient_counts: [24]u8, // non-zero coefficients per 4x4: 16 luma, 4 cb, 4 cr
	has_8x8_coefficients:       [4]bool, // 8x8 transform block has coefficients (deblocking)
	has_dc_coefficients:        [3]bool, // coded_block_flag of the luma DC, Cb DC and Cr DC blocks
	slice_index:                u16,
	deblocking_mode:            Deblocking_Mode,
	alpha_offset:               i8,
	beta_offset:                i8,
}

// The macroblock records of a picture and the slice being coded; neighbour
// lookups treat macroblocks of other slices as unavailable. Parallel encoder
// slices set an immutable [first_macroblock, end_macroblock) band before work
// starts, so availability never reads another slice's mutable records.
Macroblock_Grid :: struct {
	macroblocks:        #soa[]Macroblock,
	macroblock_columns: int,
	slice_index:        u16,
	first_macroblock:   int,
	end_macroblock:     int, // 0 leaves the full picture grid available to the decoder's tag checks
}

// LevelScale tables (8.5.9): [list][qp % 6][raster position]
Level_Scales :: struct {
	scale_4x4: [6][6][16]i32,
	scale_8x8: [2][6][64]i32,
}

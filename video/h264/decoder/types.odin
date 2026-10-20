package h264_decoder

import h264 ".."
import common "../../../common"
import "core:mem"

// Motion of a reference picture kept for temporal/spatial direct prediction
Reference_Motion :: struct {
	motion_vectors:                 [2][16][2]i16,
	reference_indices:              [2][4]i8,
	reference_picture_ids:          [2][4]i32,
	reference_picture_order_counts: [2][4]i32,
	prediction_directions:          [4]h264.Prediction_Direction,
	is_intra:                       bool,
}

// A decoded picture in the DPB
Picture :: struct {
	buf:                 h264.YUV_Buffer,
	bit_depth:           int, // of the samples in buf
	pic_id:              i32,
	poc:                 i32,
	field_order_counts:  [2]i32, // progressive top/bottom POC, shared with hardware descriptors
	frame_num:           i32,
	frame_num_wrap:      i32,
	long_term_frame_idx: i32,
	is_short_ref:        bool,
	is_long_ref:         bool,
	needed_for_output:   bool,
	non_existing:        bool,
	is_idr:              bool,
	in_use:              bool,
	motion:              []Reference_Motion,
}


// The moving state of the CABAC arithmetic decoder (9.3.1.2, 9.3.3.2). It is
// a small value: hot syntax loops copy it into a local, where range, window
// and byte cursor stay in registers, and store it back once.
// CABAC arithmetic decoding engine: the cursor and every context variable.
Cabac_Engine :: struct {
	cursor: common.Cabac_Cursor,
	ctx:    [CABAC_CONTEXT_COUNT]u8, // pStateIdx << 1 | valMPS
}

MAX_PICTURES :: 18

Decoder_State :: struct {
	allocator:                         mem.Allocator, // owns SPS-activated pixel/motion storage
	sequence_parameters:               [32]h264.Sequence_Parameter_Set,
	sequence_parameter_set_valid:      [32]bool,
	active_sequence_parameter_set_id:  int, // -1 if none
	picture_parameters:                [256]h264.Picture_Parameter_Set,
	picture_parameter_set_valid:       [256]bool,
	active_picture_parameter_set_id:   int, // -1 if none
	slice:                             h264.Slice_Header,
	slice_index:                       u16, // index of the current slice within the picture
	prev_slice:                        h264.Slice_Header, // header of the previous slice, for new-picture detection
	have_prev_slice:                   bool,
	macroblocks:                       #soa[]h264.Macroblock,
	// Native allocation geometry is independent of the stable picture slots;
	// a slot may have metadata before it first needs pixel/motion backing.
	storage_width, storage_height:     int,
	storage_format:                    h264.Buffer_Format,
	mbs_decoded:                       int,

	// Picture store: current picture, references and pictures waiting for output
	pics:                              [MAX_PICTURES]Picture,
	curr:                              ^Picture,
	current_sequence_parameter_set_id: int, // parameter sets of the picture in progress
	current_picture_parameter_set_id:  int,
	next_pic_id:                       i32,
	dpb_size:                          int, // reference + waiting-for-output capacity
	max_reorder:                       int,
	no_reordering:                     bool, // caller asserts the stream has no B slices
	max_long_term_frame_idx:           i32, // -1: no long-term frame indices
	output_queue:                      [MAX_PICTURES]^Picture,
	output_count:                      int,
	output:                            ^Picture, // last frame handed to the caller

	// Reference picture lists of the current slice
	ref_list:                          [2][32]^Picture,
	ref_count:                         [2]int,

	// POC and frame_num state (8.2.1)
	prev_poc_msb:                      i32,
	prev_poc_lsb:                      i32,
	prev_frame_num_offset:             i32,
	prev_frame_num:                    i32,
	prev_ref_frame_num:                i32,
	prev_ref_has_mmco5:                bool,
	scales:                            h264.Level_Scales, // of the active parameter sets
	cabac:                             Cabac_Engine,
	rbsp_buffer:                       [dynamic]u8,
}

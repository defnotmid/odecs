package h264_encoder

import h264 ".."
import "core:mem"

// ---------------------------------------------------------------------------
// Encoder configuration and state
// ---------------------------------------------------------------------------

Encoder_Config :: struct {
	width:               int,
	height:              int,
	qp:                  i32, // 0..51; the frame QP when bitrate is 0, the starting QP otherwise
	gop_size:            int, // IDR every gop_size frames
	num_ref_frames:      int, // 1..4 reference frames for P pictures (0 means 1)
	search_range:        int, // integer motion search radius in pixels (0 means 16)
	disable_deblocking:  bool,
	bitrate_kbps:        int, // 0: constant QP, else a frame-level controller steers QP
	fps:                 f32, // for the bitrate controller (0 means 30)
	slice_count:         int, // fixed bitstream layout, independent of workers/cache (0 means 4)
	checkpoint_capacity: int, // bounded retained frame checkpoints (0 disables retention)
	exhaustive_intra:    bool, // evaluate intra even after a low-distortion skip probe
	// VUI video signal type (E.1.1) in ITU-T H.273 code points. A zero
	// colour_primaries leaves the VUI absent, the historical SPS. When
	// present, the VUI also states that no pictures are reordered.
	colour_primaries:    u8,
	transfer:            u8,
	matrix_coefficients: u8,
	full_range:          bool,
}

// A reconstructed picture used as reference
Encoder_Picture :: struct {
	buf:           h264.YUV_Buffer,
	interpolation: Reference_Interpolation,
	frame_num:     i32,
	pic_id:        i32,
	slot:          int,
	pins:          int,
	generation:    u64,
}

Rate_Control :: struct {
	target_bits: f64, // per frame
	overshoot:   f64, // accumulated bits above target (buffer fullness)
	complexity:  [2]f64, // bits a P frame (0) or IDR frame (1) would take at QP 0
	qp:          [2]i32, // QP used for the last frame of each kind
}

Encoder_State :: struct {
	config:             Encoder_Config,
	allocator:          mem.Allocator, // owns persistent CPU buffers across caller/worker contexts
	error_detail:       string, // diagnostic only; the operation returns a typed Error
	macroblock_columns: int,
	macroblock_rows:    int,
	macroblock_count:   int,
	frame_num:          u32,
	idr_pic_id:         u32,
	frames_coded:       int,
	source:             h264.YUV_Buffer, // frame being coded, macroblock aligned with replicated edges
	macroblocks:        #soa[]h264.Macroblock,
	pictures:           []Encoder_Picture, // references + retained checkpoint slots + two writable/in-flight slots
	curr:               ^Encoder_Picture,
	refs:               [4]^Encoder_Picture, // most recent first
	num_refs:           int,
	next_pic_id:        i32,
	scales:             h264.Level_Scales,
	rate:               Rate_Control,
	out_rbsp:           [dynamic]u8, // SPS/PPS scratch
	parameter_nals:     [2][dynamic]u8, // persistent IDR lanes, independent of slice writers
	nal_lanes:          [][]u8, // borrowed ordered frame view; descriptors are preallocated
	borrowed_output:    bool, // published lanes cannot acquire a seekable stream history
	slices:             []Slice_Task, // one per macroblock row at most, with persistent scratch
	frame:              Encoder_Frame,
	checkpoints:        []Encoder_Checkpoint,
	checkpoint_serial:  u64,
	epoch:              u64,
	output_stream:      ^[dynamic]u8, // caller-owned stream; checkpoints belong to this history
	compute:            ^Compute_State,
}

Encoder_Phase :: enum {
	Idle,
	Coding,
	Filtering,
	Ready,
}

Encoder_Frame :: struct {
	quantizers:      [2][2]Quantizer_4x4, // luma/chroma, inter/intra; immutable during slice coding
	phase:           Encoder_Phase,
	generation:      u64,
	is_idr:          bool,
	frame_num:       u32,
	idr_pic_id:      u32,
	qp:              i32,
	num_slices:      int,
	compute_started: bool,
}

Encoder_Checkpoint :: struct {
	active:          bool,
	generation:      u64,
	config:          Encoder_Config,
	frame_num:       u32,
	idr_pic_id:      u32,
	frames_coded:    int,
	next_pic_id:     i32,
	rate:            Rate_Control,
	num_refs:        int,
	refs:            [4]int,
	ref_generations: [4]u64,
	output_length:   int,
}

Encoder_Checkpoint_Handle :: struct {
	owner:      ^Encoder_State,
	index:      int,
	generation: u64,
}

// One slice of the current picture, coded independently by a thread
Slice_Task :: struct {
	state:             ^Encoder_State,
	first_macroblock:  int,
	macroblock_count:  int,
	is_idr:            bool,
	quantizer:         i32,
	motion_lambda:     i32,
	distortion_lambda: f64,
	grid:              h264.Macroblock_Grid,
	rbsp:              [dynamic]u8,
	nal:               [dynamic]u8, // Annex B NAL of this slice
	writer:            h264.Bit_Writer,
	next_macroblock:   int,
	work_limit:        int,
	skip_run:          int,
}

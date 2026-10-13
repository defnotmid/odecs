// AV1 bitstream syntax for hardware decoding (AV1 Bitstream & Decoding
// Process Specification, sections 5 and 6): OBUs, the sequence header and
// the uncompressed frame header with the reference state it depends on
// (7.20/7.21), and tile group layout. Pixels are decoded elsewhere (Vulkan
// Video); this package says what each frame is and where its tiles are.
// Depends only on Odin core.
package av1

Error :: enum {
	None,
	Invalid_Data, // malformed or out of spec
	Unsupported,  // valid, outside the implemented scope (tile lists, large scale tile)
}

NUM_REF_FRAMES :: 8
REFS_PER_FRAME :: 7
PRIMARY_REF_NONE :: 7
MAX_TILE_COLS :: 64
MAX_TILE_ROWS :: 64
MAX_SEGMENTS :: 8
SEG_LVL_MAX :: 8

// Reference frame names (ref frame index 0 is INTRA_FRAME).
LAST_FRAME :: 1
LAST2_FRAME :: 2
LAST3_FRAME :: 3
GOLDEN_FRAME :: 4
BWDREF_FRAME :: 5
ALTREF2_FRAME :: 6
ALTREF_FRAME :: 7

Obu_Type :: enum u8 {
	Reserved_0,
	Sequence_Header,
	Temporal_Delimiter,
	Frame_Header,
	Tile_Group,
	Metadata,
	Frame,
	Redundant_Frame_Header,
	Tile_List,
	Padding = 15,
}

Obu :: struct {
	type:                    Obu_Type,
	temporal_id, spatial_id: u8,
	offset:                  int, // of the OBU header in the data
	payload:                 []u8,
	payload_offset:          int,
}

// The OBU starting at data[at:] (low overhead format: every OBU sized).
next_obu :: proc(data: []u8, at: int) -> (o: Obu, next: int, err: Error) {
	if at >= len(data) do return o, at, .Invalid_Data
	h := data[at]
	if h & 0x80 != 0 do return o, at, .Invalid_Data // forbidden bit
	o.type = Obu_Type(h >> 3 & 15)
	o.offset = at
	p := at + 1
	if h & 4 != 0 {
		if p >= len(data) do return o, at, .Invalid_Data
		o.temporal_id, o.spatial_id = data[p] >> 5, data[p] >> 3 & 3
		p += 1
	}
	size := len(data) - p
	if h & 2 != 0 {
		v, n, ok := leb128(data[p:])
		if !ok || v > u64(len(data) - p - n) do return o, at, .Invalid_Data
		p += n
		size = int(v)
	}
	o.payload_offset = p
	o.payload = data[p:][:size]
	return o, p + size, .None
}

@(private)
leb128 :: proc(b: []u8) -> (value: u64, n: int, ok: bool) {
	for i in 0 ..< 8 {
		if i >= len(b) do return
		value |= u64(b[i] & 0x7F) << uint(7 * i)
		if b[i] & 0x80 == 0 do return value, i + 1, true
	}
	return
}

// ---- Bit reader (4.10, 8.1) -------------------------------------------------

@(private)
Bits :: struct {
	data: []u8,
	pos:  int, // bits read; reads past the end give zeros and set overrun
	overrun: bool,
}

@(private)
f :: proc(b: ^Bits, n: int) -> u32 {
	v: u32
	for _ in 0 ..< n {
		bit: u32
		if b.pos >> 3 < len(b.data) {
			bit = u32(b.data[b.pos >> 3] >> uint(7 - b.pos & 7) & 1)
		} else {
			b.overrun = true
		}
		v = v << 1 | bit
		b.pos += 1
	}
	return v
}

@(private)
flag :: proc(b: ^Bits) -> bool {return f(b, 1) == 1}

@(private)
su :: proc(b: ^Bits, n: int) -> i32 {
	v := i32(f(b, n))
	sign := i32(1) << uint(n - 1)
	return v & sign != 0 ? v - 2 * sign : v
}

@(private)
ns :: proc(b: ^Bits, n: u32) -> u32 {
	w := 0
	for x := n; x != 0; x >>= 1 do w += 1 // FloorLog2(n) + 1
	m := (u32(1) << uint(w)) - n
	v := f(b, w - 1)
	if v < m do return v
	return (v << 1) - m + f(b, 1)
}

@(private)
uvlc :: proc(b: ^Bits) -> u32 {
	zeros := 0
	for !flag(b) {
		zeros += 1
		if b.overrun do return 0
	}
	if zeros >= 32 do return max(u32)
	return f(b, zeros) + (u32(1) << uint(zeros)) - 1
}

// ---- Sequence header (5.5) --------------------------------------------------

Color_Config :: struct {
	bit_depth:                      u8,
	mono_chrome:                    bool,
	color_description_present_flag: bool,
	color_primaries:                u8,
	transfer_characteristics:       u8,
	matrix_coefficients:            u8,
	color_range:                    bool,
	subsampling_x, subsampling_y:   u8,
	chroma_sample_position:         u8,
	separate_uv_delta_q:            bool,
}

Sequence_Header :: struct {
	seq_profile:                        u8,
	still_picture:                      bool,
	reduced_still_picture_header:       bool,
	timing_info_present_flag:           bool,
	num_units_in_display_tick:          u32,
	time_scale:                         u32,
	equal_picture_interval:             bool,
	num_ticks_per_picture_minus_1:      u32,
	decoder_model_info_present_flag:    bool,
	buffer_removal_time_length_minus_1: u8,
	frame_presentation_time_length_minus_1: u8,
	initial_display_delay_present_flag: bool,
	operating_points_cnt_minus_1:       u8,
	operating_point_idc:                [32]u16,
	decoder_model_present_for_this_op:  [32]bool,
	seq_level_idx:                      u8, // of operating point 0
	frame_width_bits_minus_1:           u8,
	frame_height_bits_minus_1:          u8,
	max_frame_width_minus_1:            u16,
	max_frame_height_minus_1:           u16,
	frame_id_numbers_present_flag:      bool,
	delta_frame_id_length_minus_2:      u8,
	additional_frame_id_length_minus_1: u8,
	use_128x128_superblock:             bool,
	enable_filter_intra:                bool,
	enable_intra_edge_filter:           bool,
	enable_interintra_compound:         bool,
	enable_masked_compound:             bool,
	enable_warped_motion:               bool,
	enable_dual_filter:                 bool,
	enable_order_hint:                  bool,
	enable_jnt_comp:                    bool,
	enable_ref_frame_mvs:               bool,
	seq_force_screen_content_tools:     u8, // 2: SELECT_SCREEN_CONTENT_TOOLS
	seq_force_integer_mv:               u8, // 2: SELECT_INTEGER_MV
	order_hint_bits_minus_1:            u8,
	order_hint_bits:                    int,
	enable_superres:                    bool,
	enable_cdef:                        bool,
	enable_restoration:                 bool,
	color:                              Color_Config,
	film_grain_params_present:          bool,
}

SELECT_SCREEN_CONTENT_TOOLS :: 2
SELECT_INTEGER_MV :: 2

parse_sequence_header :: proc(payload: []u8) -> (s: Sequence_Header, err: Error) {
	b := Bits{data = payload}
	s.seq_profile = u8(f(&b, 3))
	if s.seq_profile > 2 do return s, .Unsupported
	s.still_picture = flag(&b)
	s.reduced_still_picture_header = flag(&b)
	if s.reduced_still_picture_header {
		s.seq_level_idx = u8(f(&b, 5))
		return s, parse_sequence_rest(&b, &s)
	}
	buffer_delay_length := 0
	s.timing_info_present_flag = flag(&b)
	if s.timing_info_present_flag {
		s.num_units_in_display_tick = f(&b, 32)
		s.time_scale = f(&b, 32)
		s.equal_picture_interval = flag(&b)
		if s.equal_picture_interval do s.num_ticks_per_picture_minus_1 = uvlc(&b)
		s.decoder_model_info_present_flag = flag(&b)
		if s.decoder_model_info_present_flag {
			buffer_delay_length = int(f(&b, 5)) + 1
			f(&b, 32) // num_units_in_decoding_tick
			s.buffer_removal_time_length_minus_1 = u8(f(&b, 5))
			s.frame_presentation_time_length_minus_1 = u8(f(&b, 5))
		}
	}
	return s, parse_operating_points(&b, &s, buffer_delay_length)
}

@(private)
parse_operating_points :: proc(b: ^Bits, s: ^Sequence_Header, buffer_delay_length: int) -> Error {
	s.initial_display_delay_present_flag = flag(b)
	s.operating_points_cnt_minus_1 = u8(f(b, 5))
	for i in 0 ..= int(s.operating_points_cnt_minus_1) {
		s.operating_point_idc[i] = u16(f(b, 12))
		level := u8(f(b, 5))
		if i == 0 do s.seq_level_idx = level
		if level > 7 do f(b, 1) // seq_tier
		if s.decoder_model_info_present_flag {
			s.decoder_model_present_for_this_op[i] = flag(b)
			if s.decoder_model_present_for_this_op[i] {
				f(b, buffer_delay_length) // decoder_buffer_delay
				f(b, buffer_delay_length) // encoder_buffer_delay
				f(b, 1) // low_delay_mode_flag
			}
		}
		if s.initial_display_delay_present_flag {
			if flag(b) do f(b, 4) // initial_display_delay_minus_1
		}
	}
	return parse_sequence_rest(b, s)
}

@(private)
parse_sequence_rest :: proc(b: ^Bits, s: ^Sequence_Header) -> Error {
	s.frame_width_bits_minus_1 = u8(f(b, 4))
	s.frame_height_bits_minus_1 = u8(f(b, 4))
	s.max_frame_width_minus_1 = u16(f(b, int(s.frame_width_bits_minus_1) + 1))
	s.max_frame_height_minus_1 = u16(f(b, int(s.frame_height_bits_minus_1) + 1))
	if !s.reduced_still_picture_header do s.frame_id_numbers_present_flag = flag(b)
	if s.frame_id_numbers_present_flag {
		s.delta_frame_id_length_minus_2 = u8(f(b, 4))
		s.additional_frame_id_length_minus_1 = u8(f(b, 3))
	}
	s.use_128x128_superblock = flag(b)
	s.enable_filter_intra = flag(b)
	s.enable_intra_edge_filter = flag(b)
	s.seq_force_screen_content_tools = SELECT_SCREEN_CONTENT_TOOLS
	s.seq_force_integer_mv = SELECT_INTEGER_MV
	if !s.reduced_still_picture_header {
		s.enable_interintra_compound = flag(b)
		s.enable_masked_compound = flag(b)
		s.enable_warped_motion = flag(b)
		s.enable_dual_filter = flag(b)
		s.enable_order_hint = flag(b)
		if s.enable_order_hint {
			s.enable_jnt_comp = flag(b)
			s.enable_ref_frame_mvs = flag(b)
		}
		if !flag(b) do s.seq_force_screen_content_tools = u8(f(b, 1)) // seq_choose_screen_content_tools
		if s.seq_force_screen_content_tools > 0 {
			if !flag(b) do s.seq_force_integer_mv = u8(f(b, 1)) // seq_choose_integer_mv
		}
		if s.enable_order_hint {
			s.order_hint_bits_minus_1 = u8(f(b, 3))
			s.order_hint_bits = int(s.order_hint_bits_minus_1) + 1
		}
	}
	s.enable_superres = flag(b)
	s.enable_cdef = flag(b)
	s.enable_restoration = flag(b)
	// color_config (5.5.2)
	c := &s.color
	high := flag(b)
	if s.seq_profile == 2 && high {
		c.bit_depth = flag(b) ? 12 : 10
	} else {
		c.bit_depth = high ? 10 : 8
	}
	if s.seq_profile != 1 do c.mono_chrome = flag(b)
	c.color_description_present_flag = flag(b)
	c.color_primaries, c.transfer_characteristics, c.matrix_coefficients = 2, 2, 2
	if c.color_description_present_flag {
		c.color_primaries = u8(f(b, 8))
		c.transfer_characteristics = u8(f(b, 8))
		c.matrix_coefficients = u8(f(b, 8))
	}
	switch {
	case c.mono_chrome:
		c.color_range = flag(b)
		c.subsampling_x, c.subsampling_y = 1, 1
	case c.color_primaries == 1 && c.transfer_characteristics == 13 && c.matrix_coefficients == 0:
		c.color_range = true
	case:
		c.color_range = flag(b)
		switch s.seq_profile {
		case 0:
			c.subsampling_x, c.subsampling_y = 1, 1
		case 1:
		case:
			if c.bit_depth == 12 {
				c.subsampling_x = u8(f(b, 1))
				if c.subsampling_x == 1 do c.subsampling_y = u8(f(b, 1))
			} else {
				c.subsampling_x = 1
			}
		}
		if c.subsampling_x == 1 && c.subsampling_y == 1 do c.chroma_sample_position = u8(f(b, 2))
	}
	if !c.mono_chrome do c.separate_uv_delta_q = flag(b)
	s.film_grain_params_present = flag(b)
	return b.overrun ? .Invalid_Data : .None
}

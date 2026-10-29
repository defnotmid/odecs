package media_videotoolbox

// VideoToolbox sizes its output to an SPS's cropping but takes it from the
// picture's top-left corner, ignoring left and top offsets. So it is given
// sequence parameter sets with cropping removed (H.264 frame_cropping_flag,
// HEVC conformance_window_flag cleared and their offsets dropped), returns
// whole coded pictures, and the frontends crop.

// The SPS NAL unit (header included, no start code) without cropping,
// appended to out; the unit unchanged when it has none. False when it is
// malformed.
uncropped_sps :: proc(nal: []u8, codec: Codec, out: ^[dynamic]u8) -> bool {
	header := codec == .H264 ? 1 : 2
	clear(out)
	if len(nal) <= header do return false
	rbsp := make([dynamic]u8, 0, len(nal))
	defer delete(rbsp)
	zeros := 0
	for b in nal[header:] {
		// Emulation prevention: 00 00 03 carries 00 00.
		if zeros >= 2 && b == 3 {zeros = 0; continue}
		append(&rbsp, b)
		zeros = b == 0 ? zeros + 1 : 0
	}
	r := Bit_Reader{data = rbsp[:]}
	if codec == .H264 {skip_h264_sps_to_cropping(&r)} else {skip_hevc_sps_to_cropping(&r)}
	flag := r.pos
	if read_bits(&r, 1) == 0 {
		if r.failed do return false
		append(out, ..nal)
		return true
	}
	for _ in 0 ..< 4 do read_ue(&r)
	after := r.pos
	// The RBSP stop bit: the last set bit.
	stop := len(rbsp) * 8 - 1
	for stop >= 0 && rbsp[stop / 8] & (0x80 >> uint(stop % 8)) == 0 do stop -= 1
	if r.failed || stop < after do return false

	w: Bit_Writer
	w.data = make([dynamic]u8, 0, len(rbsp))
	defer delete(w.data)
	for i in 0 ..< flag do write_bit(&w, bit_at(rbsp[:], i))
	write_bit(&w, 0)
	for i in after ..< stop do write_bit(&w, bit_at(rbsp[:], i))
	write_bit(&w, 1)
	for w.count % 8 != 0 do write_bit(&w, 0)

	append(out, ..nal[:header])
	zeros = 0
	for b in w.data {
		if zeros >= 2 && b <= 3 {
			append(out, 3)
			zeros = 0
		}
		append(out, b)
		zeros = b == 0 ? zeros + 1 : 0
	}
	return true
}

// H.264 7.3.2.1.1 up to frame_cropping_flag.
@(private)
skip_h264_sps_to_cropping :: proc(r: ^Bit_Reader) {
	profile := read_bits(r, 8)
	read_bits(r, 16) // constraint flags, level_idc
	read_ue(r) // seq_parameter_set_id
	switch profile {
	case 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135:
		chroma_format := read_ue(r)
		if chroma_format == 3 do read_bits(r, 1) // separate_colour_plane_flag
		read_ue(r) // bit_depth_luma_minus8
		read_ue(r) // bit_depth_chroma_minus8
		read_bits(r, 1) // qpprime_y_zero_transform_bypass_flag
		if read_bits(r, 1) != 0 { 	// seq_scaling_matrix_present_flag
			for i in 0 ..< (chroma_format != 3 ? 8 : 12) {
				if read_bits(r, 1) == 0 do continue
				last, next := 8, 8
				for _ in 0 ..< (i < 6 ? 16 : 64) {
					if next != 0 do next = (last + read_se(r) + 256) % 256
					if next != 0 do last = next
				}
			}
		}
	}
	read_ue(r) // log2_max_frame_num_minus4
	switch read_ue(r) { 	// pic_order_cnt_type
	case 0:
		read_ue(r) // log2_max_pic_order_cnt_lsb_minus4
	case 1:
		read_bits(r, 1) // delta_pic_order_always_zero_flag
		read_se(r) // offset_for_non_ref_pic
		read_se(r) // offset_for_top_to_bottom_field
		cycle := read_ue(r) // num_ref_frames_in_pic_order_cnt_cycle (a range bound would be re-read every pass)
		for _ in 0 ..< cycle do read_se(r) // offset_for_ref_frame
	}
	read_ue(r) // max_num_ref_frames
	read_bits(r, 1) // gaps_in_frame_num_value_allowed_flag
	read_ue(r) // pic_width_in_mbs_minus1
	read_ue(r) // pic_height_in_map_units_minus1
	if read_bits(r, 1) == 0 do read_bits(r, 1) // frame_mbs_only_flag, mb_adaptive_frame_field_flag
	read_bits(r, 1) // direct_8x8_inference_flag
}

// HEVC 7.3.2.2.1 up to conformance_window_flag.
@(private)
skip_hevc_sps_to_cropping :: proc(r: ^Bit_Reader) {
	read_bits(r, 4) // sps_video_parameter_set_id
	sub_layers := read_bits(r, 3) // sps_max_sub_layers_minus1
	read_bits(r, 1) // sps_temporal_id_nesting_flag
	skip_hevc_ptl(r, sub_layers)
	read_ue(r) // sps_seq_parameter_set_id
	if read_ue(r) == 3 do read_bits(r, 1) // chroma_format_idc, separate_colour_plane_flag
	read_ue(r) // pic_width_in_luma_samples
	read_ue(r) // pic_height_in_luma_samples
}

// profile_tier_level(1, sub_layers): the general profile and level, then
// what each sub-layer says it carries.
@(private)
skip_hevc_ptl :: proc(r: ^Bit_Reader, sub_layers: int) {
	read_bits(r, 32)
	read_bits(r, 32)
	read_bits(r, 32)
	profile_present, level_present: [8]bool
	for i in 0 ..< sub_layers {
		profile_present[i] = read_bits(r, 1) != 0
		level_present[i] = read_bits(r, 1) != 0
	}
	if sub_layers > 0 do for _ in sub_layers ..< 8 do read_bits(r, 2)
	for i in 0 ..< sub_layers {
		if profile_present[i] {read_bits(r, 32); read_bits(r, 32); read_bits(r, 24)}
		if level_present[i] do read_bits(r, 8)
	}
}

// The VPS NAL unit (header included, no start code) for the base layer
// alone: VideoToolbox's single-layer decompression session refuses a format
// description whose VPS declares an auxiliary alpha layer (OSStatus -12713).
base_layer_vps :: proc(nal: []u8, out: ^[dynamic]u8) -> bool {
	clear(out)
	if len(nal) <= 2 do return false
	rbsp := make([dynamic]u8, 0, len(nal))
	defer delete(rbsp)
	zeros := 0
	for b in nal[2:] {
		if zeros >= 2 && b == 3 {zeros = 0; continue}
		append(&rbsp, b)
		zeros = b == 0 ? zeros + 1 : 0
	}
	r := Bit_Reader{data = rbsp[:]}
	read_bits(&r, 6) // vps_video_parameter_set_id, base_layer_internal, base_layer_available
	if read_bits(&r, 6) == 0 {
		if r.failed do return false
		append(out, ..nal)
		return true
	}
	sub_layers := read_bits(&r, 3) // vps_max_sub_layers_minus1
	read_bits(&r, 1) // vps_temporal_id_nesting_flag
	if read_bits(&r, 16) != 0xffff do return false
	skip_hevc_ptl(&r, sub_layers)
	ordering := read_bits(&r, 1) != 0 // vps_sub_layer_ordering_info_present_flag
	for _ in (ordering ? 0 : sub_layers) ..= sub_layers {
		read_ue(&r) // vps_max_dec_pic_buffering_minus1
		read_ue(&r) // vps_max_num_reorder_pics
		read_ue(&r) // vps_max_latency_increase_plus1
	}
	if r.failed do return false
	dpb_end := r.pos

	w: Bit_Writer
	w.data = make([dynamic]u8, 0, len(rbsp))
	defer delete(w.data)
	for i in 0 ..< 6 do write_bit(&w, bit_at(rbsp[:], i))
	for _ in 0 ..< 6 do write_bit(&w, 0) // vps_max_layers_minus1 = 0
	for i in 12 ..< dpb_end do write_bit(&w, bit_at(rbsp[:], i))
	for _ in 0 ..< 6 do write_bit(&w, 0) // vps_max_layer_id = 0
	write_bit(&w, 1) // vps_num_layer_sets_minus1 = ue(0)
	write_bit(&w, 0) // vps_timing_info_present_flag = 0
	write_bit(&w, 0) // vps_extension_flag = 0
	write_bit(&w, 1) // rbsp_stop_one_bit
	for w.count % 8 != 0 do write_bit(&w, 0)

	append(out, ..nal[:2])
	zeros = 0
	for b in w.data {
		if zeros >= 2 && b <= 3 {
			append(out, 3)
			zeros = 0
		}
		append(out, b)
		zeros = b == 0 ? zeros + 1 : 0
	}
	return true
}

@(private)
Bit_Reader :: struct {
	data:   []u8,
	pos:    int, // in bits
	failed: bool, // read past the end
}

@(private)
bit_at :: #force_inline proc(data: []u8, i: int) -> u8 {
	return (data[i / 8] >> uint(7 - i % 8)) & 1
}

@(private)
read_bits :: proc(r: ^Bit_Reader, n: int) -> int {
	if r.pos + n > len(r.data) * 8 {
		r.failed = true
		r.pos = len(r.data) * 8
		return 0
	}
	v := 0
	for _ in 0 ..< n {
		v = v << 1 | int(bit_at(r.data, r.pos))
		r.pos += 1
	}
	return v
}

@(private)
read_ue :: proc(r: ^Bit_Reader) -> int {
	zeros := 0
	for read_bits(r, 1) == 0 {
		if r.failed || zeros == 31 {r.failed = true; return 0}
		zeros += 1
	}
	return (1 << uint(zeros)) - 1 + read_bits(r, zeros)
}

@(private)
read_se :: proc(r: ^Bit_Reader) -> int {
	k := read_ue(r)
	return k & 1 != 0 ? (k + 1) / 2 : -k / 2
}

@(private)
Bit_Writer :: struct {
	data:  [dynamic]u8,
	count: int, // bits written
}

@(private)
write_bit :: proc(w: ^Bit_Writer, bit: u8) {
	if w.count % 8 == 0 do append(&w.data, 0)
	w.data[len(w.data) - 1] |= bit << uint(7 - w.count % 8)
	w.count += 1
}

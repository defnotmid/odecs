package main

import h264 "../h264"
import avc_dec "../h264/decoder"
import "core:fmt"

main :: proc() {
	test_deblocking_modes()
	st: avc_dec.Decoder_State
	avc_dec.init_decoder(&st)
	defer avc_dec.destroy_decoder(&st)
	a := h264.Sequence_Parameter_Set {
		profile                    = .Baseline,
		level                      = .Level_3,
		width                      = 28,
		height                     = 32,
		macroblock_columns         = 2,
		macroblock_rows            = 2,
		macroblock_count           = 4,
		frames_only                = true,
		crop_right                 = 2,
		max_reference_frames       = 1,
		has_bitstream_restrictions = true,
		max_buffered_frames        = 1,
		max_reordered_frames       = 0,
	}
	avc_dec.activate_sequence_parameter_set(&st, &a)
	memory := raw_data(st.pics[0].buf.memory)
	st.prev_ref_frame_num = 7
	st.prev_frame_num = 7
	st.max_long_term_frame_idx = 3
	st.pics[1].in_use = true
	st.pics[1].needed_for_output = true
	b := a
	b.profile = .Main
	b.crop_left = 2
	b.crop_right = 0
	b.max_reference_frames = 4
	b.max_buffered_frames = 4
	b.max_reordered_frames = 2
	avc_dec.activate_sequence_parameter_set(&st, &b)
	assert(st.pics[0].buf.crop_x == 4 && st.dpb_size == 4 && st.max_reorder == 2)
	assert(raw_data(st.pics[0].buf.memory) == memory)
	assert(st.prev_ref_frame_num == 7 && st.prev_frame_num == 7 && st.max_long_term_frame_idx == 3)
	assert(st.pics[1].buf.crop_x == 0 && st.pics[1].needed_for_output)
	fmt.println(
		"[SUCCESS] SPS metadata refresh preserves allocation, reference history and queued crops",
	)
}

// Check numeric-to-enum validation before a byte-sized mode is stored.
test_deblocking_modes :: proc() {
	decoder: avc_dec.Decoder_State
	avc_dec.init_decoder(&decoder)
	defer avc_dec.destroy_decoder(&decoder)
	decoder.sequence_parameter_set_valid[0] = true
	decoder.picture_parameter_set_valid[0] = true
	decoder.sequence_parameters[0] = {
		frame_number_bits  = 4,
		picture_order_mode = .Frame_Number,
		macroblock_count   = 1,
		frames_only        = true,
	}
	decoder.picture_parameters[0] = {
		pic_init_qp                            = 26,
		deblocking_filter_control_present_flag = true,
	}
	for code in ([5]u32{0, 1, 2, 3, 256}) {
		payload := make([dynamic]u8)
		writer := h264.init_bit_writer(&payload)
		h264.write_unsigned_exp_golomb(&writer, 0) // first macroblock
		h264.write_unsigned_exp_golomb(&writer, u32(h264.Slice_Type.I))
		h264.write_unsigned_exp_golomb(&writer, 0) // picture parameter set
		h264.write_bits(&writer, 0, 4) // frame number
		h264.write_signed_exp_golomb(&writer, 0) // quantizer delta
		h264.write_unsigned_exp_golomb(&writer, code)
		if code != u32(h264.Deblocking_Mode.Disabled) {
			h264.write_signed_exp_golomb(&writer, 0)
			h264.write_signed_exp_golomb(&writer, 0)
		}
		h264.flush_bits_rbsp(&writer)
		reader := h264.init_bit_reader(payload[:])
		header, valid := avc_dec.parse_slice_header(&reader, .Slice_Non_IDR, 0, &decoder)
		assert(valid == (code <= u32(h264.Deblocking_Mode.Within_Slice)))
		if valid do assert(header.deblocking_mode == h264.Deblocking_Mode(code))
		delete(payload)
	}
	fmt.println(
		"[SUCCESS] named deblocking modes round-trip; invalid and overflowing codes are refused",
	)
}

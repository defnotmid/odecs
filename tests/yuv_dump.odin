package main
import h264 "../codec/h264"
import avc_dec "../codec/h264/decoder"
import "core:fmt"
import "core:os"
import "core:strconv"
emit :: proc(
	st: ^avc_dec.Decoder_State,
	pic: ^avc_dec.Picture,
	out: ^[dynamic]u8,
	frame_index: ^int,
) {
	// Planar output in the stream's format: I420 or I422, 16-bit little-endian above 8 bits.
	b := &pic.buf
	size := b.high_depth ? 2 : 1
	sub_y := b.chroma_422 ? 1 : 2
	plane :: proc(out: ^[dynamic]u8, p: [^]u8, stride, x, y, w, h, size: int) {
		for row in 0 ..< h do append(out, ..p[((y + row) * stride + x) * size:][:w * size])
	}
	plane(out, b.y, b.y_stride, b.crop_x, b.crop_y, b.width, b.height, size)
	plane(out, b.u, b.uv_stride, b.crop_x / 2, b.crop_y / sub_y, b.width / 2, b.height / sub_y, size)
	plane(out, b.v, b.uv_stride, b.crop_x / 2, b.crop_y / sub_y, b.width / 2, b.height / sub_y, size)
	if len(os.args) > 3 do fmt.printfln("out frame %d: poc %d frame_num %d", frame_index^, pic.poc, pic.frame_num)
	if len(os.args) > 4 && frame_index^ == 0 {
		mbw := st.sequence_parameters[st.active_sequence_parameter_set_id].macroblock_columns
		for m in 0 ..< len(st.macroblocks) {
			mb := st.macroblocks[m]
			fmt.printfln(
				"mb %d (%d,%d): %v t8x8=%v cbp=%d/%d quantizer=%d modes=%v chroma=%v nonzero=%v",
				m,
				m % mbw,
				m / mbw,
				mb.type,
				mb.uses_8x8_transform,
				mb.luma_coded_block_mask,
				mb.chroma_residual_mode,
				mb.quantizer,
				mb.intra_4x4_modes,
				mb.chroma_prediction_mode,
				mb.nonzero_coefficient_counts,
			)
		}
	}
	frame_index^ += 1
}

// yuv_dump <stream.264> <out.yuv> [verbose] [mbs] [nal-limit]
// Decodes an Annex B stream and writes the displayed frames as raw planar YUV:
// I420 or I422, 16-bit little-endian samples above 8 bits.
main :: proc() {
	if len(os.args) < 3 {
		fmt.println("usage: yuv_dump <stream.264> <out.yuv> [verbose] [mbs] [nal-limit]")
		os.exit(2)
	}
	data, read_err := os.read_entire_file(os.args[1], context.allocator)
	if read_err != nil {fmt.eprintln(read_err); os.exit(1)}
	defer delete(data)
	st: avc_dec.Decoder_State
	avc_dec.init_decoder(&st)
	defer avc_dec.destroy_decoder(&st)
	out := make([dynamic]u8)
	defer delete(out)
	nals := h264.find_nal_units(data)
	defer delete(nals)
	frame_index := 0
	limit := len(nals)
	if len(os.args) >
	   5 {value, ok := strconv.parse_int(os.args[5]); if !ok || value <= 0 do os.exit(2); limit = min(value, limit)}
	for nal, i in nals {
		if i >= limit do break
		ready, err := avc_dec.decode_nal(&st, data[nal.offset:nal.offset + nal.length])
		if err != .None {
			fmt.eprintfln("nal %d: %s", i, avc_dec.error_description(err))
			os.exit(avc_dec.is_unsupported(err) ? 3 : 1)
		}
		if len(os.args) > 3 && (data[nal.offset] & 0x1f == 1 || data[nal.offset] & 0x1f == 5) {
			sh := st.slice
			if sh.first_mb_in_slice == 0 {
				sequence_parameters :=
					st.sequence_parameters[st.active_sequence_parameter_set_id]; picture_parameters := st.picture_parameters[st.active_picture_parameter_set_id]
				fmt.printfln(
					"  [sps profile %d level %d log2fn %d poctype %d refs %d d8x8inf %v reorder %d/%d] [pps cabac %v wp %v bipred %d t8x8 %v cip %v refs %d/%d] scaling sps=%v pps=%v sps4=%v pps8=%v",
					sequence_parameters.profile,
					sequence_parameters.level,
					sequence_parameters.frame_number_bits,
					sequence_parameters.picture_order_mode,
					sequence_parameters.max_reference_frames,
					sequence_parameters.infer_direct_8x8_motion,
					st.max_reorder,
					st.dpb_size,
					picture_parameters.entropy_coding_mode_flag,
					picture_parameters.weighted_pred_flag,
					picture_parameters.weighted_bipred_idc,
					picture_parameters.transform_8x8_mode_flag,
					picture_parameters.constrained_intra_pred_flag,
					picture_parameters.num_ref_idx_l0_default_active,
					picture_parameters.num_ref_idx_l1_default_active,
					sequence_parameters.has_scaling_matrices,
					picture_parameters.pic_scaling_matrix_present_flag,
					sequence_parameters.has_scaling_list,
					picture_parameters.has_scaling_list,
				)
			}
			fmt.printf(
				"nal %d %v ref%d fn=%d poc=%d mb0=%d nref=%d/%d spatial=%v reorder0=%v reorder1=%v mmco=%v",
				i,
				sh.slice_type,
				sh.nal_ref_idc,
				sh.frame_num,
				st.curr != nil ? st.curr.poc : -1,
				sh.first_mb_in_slice,
				sh.num_ref_idx_l0_active,
				sh.num_ref_idx_l1_active,
				sh.direct_spatial_mv_pred_flag,
				sh.reorder[0][:sh.num_reorder[0]],
				sh.reorder[1][:sh.num_reorder[1]],
				sh.mmco[:sh.num_mmco],
			)
			for l in 0 ..< 2 {
				if st.ref_count[l] == 0 do continue
				fmt.printf(" L%d=[", l)
				for r in 0 ..< st.ref_count[l] {
					pic := st.ref_list[l][r]
					if pic ==
					   nil {fmt.printf("nil ")} else {fmt.printf("fn%d/poc%d%s ", pic.frame_num, pic.poc, pic.is_long_ref ? "L" : "")}
				}
				fmt.printf("]")
			}
			fmt.println()
		}
		if !ready do continue
		for pic := st.output; pic != nil; pic = avc_dec.next_output_frame(&st) do emit(&st, pic, &out, &frame_index)
	}
	if avc_dec.flush_decoder(&st) {
		for pic := st.output; pic != nil; pic = avc_dec.next_output_frame(&st) do emit(&st, pic, &out, &frame_index)
	}
	if frame_index == 0 {fmt.eprintln("no decoded output"); os.exit(1)}
	if err := os.write_entire_file(os.args[2], out[:]); err != nil {fmt.eprintln(err); os.exit(1)}
	fmt.println(len(out))
}

package videotoolbox

import avc "../h264"
import avcd "../h264/decoder"
import hevc "../h265/decoder"
import "core:slice"
import "core:testing"

// SPSs of 1918x1078 streams (x264 High; x265 Main and Main 10), whose
// cropping trims 2 columns and 10 rows from the 1920x1088 / 1920x1080 coded
// pictures.
@(private = "file", rodata)
X264_SPS := [?]u8{0x67, 0x64, 0x00, 0x28, 0xac, 0xd9, 0x40, 0x78, 0x02, 0x27, 0xa9, 0xb0, 0x11, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x3c, 0x0f, 0x18, 0x31, 0x96}
@(private = "file", rodata)
X265_SPS := [?]u8{0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0xa0, 0x03, 0xc0, 0x80, 0x10, 0xe7, 0x55, 0x96, 0x56, 0x69, 0x24, 0xca, 0xf0, 0x16, 0x80, 0x80, 0x00, 0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x0f, 0x04}
@(private = "file", rodata)
X265_MAIN10_SPS := [?]u8{0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0xa0, 0x03, 0xc0, 0x80, 0x10, 0xe7, 0x54, 0xd9, 0x65, 0x66, 0x92, 0x4c, 0xaf, 0x01, 0x68, 0x08, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03, 0x00, 0xf0, 0x40}

@(private = "file")
parse_avc :: proc(nal: []u8) -> (avc.Sequence_Parameter_Set, bool) {
	buffer: [dynamic]u8
	defer delete(buffer)
	reader := avc.init_bit_reader(avc.unescape_rbsp_into_buffer(nal[1:], &buffer))
	return avcd.parse_sequence_parameter_set(&reader)
}

@(test)
test_h264_sps_loses_only_its_cropping :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	testing.expect(t, uncropped_sps(X264_SPS[:], .H264, &out))
	before, ok_before := parse_avc(X264_SPS[:])
	after, ok_after := parse_avc(out[:])
	testing.expect(t, ok_before && ok_after)
	testing.expect(t, before.has_cropping && before.crop_right == 1 && before.crop_bottom == 5)
	testing.expect(t, !after.has_cropping && after.width == 1920 && after.height == 1088)
	before.has_cropping, before.crop_right, before.crop_bottom = false, 0, 0
	before.width, before.height = after.width, after.height
	testing.expect(t, before == after, "every other field, VUI included, survives")

	again: [dynamic]u8
	defer delete(again)
	testing.expect(t, uncropped_sps(out[:], .H264, &again))
	testing.expect(t, string(again[:]) == string(out[:]), "an SPS without cropping is unchanged")
}

@(test)
test_hevc_sps_loses_only_its_conformance_window :: proc(t: ^testing.T) {
	for sps in ([][]u8{X265_SPS[:], X265_MAIN10_SPS[:]}) {
		out: [dynamic]u8
		defer delete(out)
		testing.expect(t, uncropped_sps(sps, .HEVC, &out))
		scratch: hevc.Nal_Scratch
		defer hevc.destroy_nal_scratch(&scratch)
		nal, ok := hevc.parse_nal_into(sps, &scratch)
		before, ok_before := hevc.parse_sps(nal.rbsp)
		defer hevc.destroy_sps(&before)
		nal, ok = hevc.parse_nal_into(out[:], &scratch)
		after, ok_after := hevc.parse_sps(nal.rbsp)
		defer hevc.destroy_sps(&after)
		testing.expect(t, ok && ok_before && ok_after)
		testing.expect(t, before.conf_win_right == 1 && before.conf_win_bottom == 1)
		testing.expect(t, after.conf_win_left == 0 && after.conf_win_right == 0 && after.conf_win_top == 0 && after.conf_win_bottom == 0)
		testing.expect(t, hevc.sps_cropped_width(&after) == 1920 && hevc.sps_cropped_height(&after) == 1080)
		testing.expect(t, after.pic_width_in_luma_samples == before.pic_width_in_luma_samples && after.bit_depth_luma == before.bit_depth_luma)
		testing.expect(t, after.log2_max_poc_lsb == before.log2_max_poc_lsb && after.max_num_reorder_pics == before.max_num_reorder_pics)
		testing.expect(t, after.full_range == before.full_range && after.pic_width_in_ctbs == before.pic_width_in_ctbs)

		again: [dynamic]u8
		defer delete(again)
		testing.expect(t, uncropped_sps(out[:], .HEVC, &again))
		testing.expect(t, string(again[:]) == string(out[:]), "an SPS without cropping is unchanged")
	}
}

@(test)
test_semi_planar_copy_crops_and_splits_chroma :: proc(t: ^testing.T) {
	// A 6x4 coded NV12 picture whose visible 4x2 area starts at (2, 2).
	y: [6 * 4]u8
	uv: [6 * 2]u8
	for &v, i in y do v = u8(i)
	for &v, i in uv do v = u8(100 + i)
	data: [4 * 2 + 2 * 2]u8
	f := Frame {
		width        = 4,
		height       = 2,
		bit_depth    = 8,
		storage_bits = 8,
		strides      = {4, 2, 2},
	}
	f.planes = {data[:8], data[8:10], data[10:12]}
	copy_semi_planar(&f, y[:], 6, uv[:], 6, 2, 2)
	testing.expect(t, slice.equal(data[:8], []u8{14, 15, 16, 17, 20, 21, 22, 23}))
	testing.expect(t, slice.equal(data[8:], []u8{108, 110, 109, 111}), "Cb then Cr of chroma row 1 from column 1")
}

// LS_SVA_D's SPS: picture order type 1, whose cycle length bounds a loop.
@(private = "file", rodata)
POC_TYPE_1_SPS := [?]u8{0x67, 0x42, 0xe0, 0x0d, 0x88, 0x4d, 0x10, 0x20, 0x16, 0x27, 0x20}

@(test)
test_sps_without_cropping_passes_through :: proc(t: ^testing.T) {
	out: [dynamic]u8
	defer delete(out)
	testing.expect(t, uncropped_sps(POC_TYPE_1_SPS[:], .H264, &out))
	testing.expect(t, slice.equal(out[:], POC_TYPE_1_SPS[:]))
}

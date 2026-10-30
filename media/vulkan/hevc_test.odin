package media_vulkan

@(require) import avc "../../video/h264"
@(require) import "core:os"
@(require) import "core:testing"

when #config(OICUT_GPU_HEVC_TEST, false) {
	HEVC_Test_Output :: struct {
		bytes:  [dynamic]u8,
		frames: int,
	}

	hevc_test_receive :: proc(frame: H265_Frame, user: rawptr) {
		out := cast(^HEVC_Test_Output)user
		append_frame_samples(&out.bytes, frame)
		out.frames += 1
	}

	// An Annex-B stream against its full planar output in display order
	// (bytes at 8 bits, u16le above). Use an open-GOP stream (x265's
	// default): the leading pictures of a mid-stream CRA reference pictures
	// the CRA itself does not.
	@(test)
	h265_hardware_decode :: proc(t: ^testing.T) {
		fixture :: #config(OICUT_GPU_HEVC_FIXTURE, "")
		reference :: #config(OICUT_GPU_HEVC_REFERENCE, "")
		testing.expect(t, fixture != "" && reference != "")
		if fixture == "" || reference == "" do return
		data, e := os.read_entire_file(fixture, context.allocator)
		testing.expect(t, e == nil)
		if e != nil do return
		defer delete(data)
		ref, ref_e := os.read_entire_file(reference, context.allocator)
		testing.expect(t, ref_e == nil)
		if ref_e != nil do return
		defer delete(ref)
		d: H265_Decoder
		testing.expect_value(t, init_h265_decoder(&d, {device_index = -1}), Error.None)
		defer destroy_h265_decoder(&d)
		out: HEVC_Test_Output
		defer delete(out.bytes)
		nals := avc.find_nal_units(data)
		defer delete(nals)
		for nal in nals {
			err := decode_h265_nal(&d, data[nal.offset:][:nal.length], hevc_test_receive, &out)
			testing.expect_value(t, err, Error.None)
			if err != .None do return
		}
		testing.expect_value(t, flush_h265_decoder(&d, hevc_test_receive, &out), Error.None)
		testing.expect(t, out.frames > 0)
		testing.expect_value(t, len(out.bytes), len(ref))
		if len(out.bytes) != len(ref) do return
		for byte, i in ref do if byte != out.bytes[i] {
			frame_bytes := len(ref) / out.frames
			testing.expectf(t, false, "differs at byte %d (frame %d)", i, i / frame_bytes)
			return
		}
	}
}

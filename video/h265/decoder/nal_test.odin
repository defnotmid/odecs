package h265_decoder

import "core:mem"
import "core:slice"
import "core:testing"

@(test)
test_split_annex_b :: proc(t: ^testing.T) {
	data := []u8{0, 0, 1, 0x40, 0x01, 0xAA, 0xBB, 0, 0, 0, 1, 0x42, 0x01, 0xCC}
	nals := split_annex_b(data)
	defer {
		for i in 0 ..< len(nals) do destroy_nal(&nals[i])
		delete(nals)
	}

	testing.expect_value(t, len(nals), 2)
	testing.expect_value(t, nals[0].type, Nal_Type.VPS_NUT)
	testing.expect_value(t, nals[0].temporal_id, u8(0))
	testing.expect_value(t, len(nals[0].rbsp), 2)
	testing.expect_value(t, nals[1].type, Nal_Type.SPS_NUT)
	testing.expect_value(t, len(nals[1].rbsp), 1)
	testing.expect_value(t, nals[1].rbsp[0], u8(0xCC))
}

@(test)
test_parse_nal_removes_emulation_prevention :: proc(t: ^testing.T) {
	// 00 00 03 01 becomes 00 00 01, recording one prevention byte.
	data := []u8{0x40, 0x01, 0x00, 0x00, 0x03, 0x01}
	nal, ok := parse_nal(data)
	defer destroy_nal(&nal)
	testing.expect(t, ok)
	testing.expect_value(t, nal.type, Nal_Type.VPS_NUT)
	testing.expect_value(t, len(nal.rbsp), 3)
	testing.expect_value(t, nal.rbsp[0], u8(0))
	testing.expect_value(t, nal.rbsp[1], u8(0))
	testing.expect_value(t, nal.rbsp[2], u8(1))
	testing.expect_value(t, len(nal.epb), 1)
}

@(test)
test_borrowed_nal_scratch_reuse :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		scratch: Nal_Scratch
		data := []u8{0x43, 0xF9, 0, 0, 3, 0, 0, 3, 1, 0, 0, 3, 2, 0, 0, 3}
		want_rbsp := []u8{0, 0, 0, 0, 1, 0, 0, 2, 0, 0}
		want_epb := []u32{2, 5, 9, 13}
		n, good := parse_nal_into(data, &scratch)
		testing.expect(t, good && n.borrowed)
		testing.expect_value(t, n.type, Nal_Type.SPS_NUT)
		testing.expect_value(t, n.layer_id, u8(63))
		testing.expect(t, slice.equal(n.rbsp, want_rbsp))
		testing.expect(t, slice.equal(n.epb, want_epb))
		warm_allocations := track.total_allocation_count
		for _ in 0 ..< 100 {
			n, good = parse_nal_into(data, &scratch)
			testing.expect(
				t,
				good && slice.equal(n.rbsp, want_rbsp) && slice.equal(n.epb, want_epb),
			)
			destroy_nal(&n)
			testing.expect(t, slice.equal(scratch.rbsp[:], want_rbsp))
		}
		testing.expect_value(t, track.total_allocation_count, warm_allocations)

		// A shorter NAL reuses capacity and clears previous EPB positions.
		n, good = parse_nal_into([]u8{0x40, 1, 0xAA, 0xBB}, &scratch)
		testing.expect(t, good && slice.equal(n.rbsp, []u8{0xAA, 0xBB}))
		testing.expect_value(t, len(n.epb), 0)
		for invalid in ([][]u8{nil, {0x40}, {0xC0, 1}, {0x40, 0}}) {
			_, good = parse_nal_into(invalid, &scratch)
			testing.expect(t, !good)
			testing.expect(t, slice.equal(scratch.rbsp[:], []u8{0xAA, 0xBB}))
		}
		destroy_nal_scratch(&scratch)
	}
	testing.expect_value(t, track.current_memory_allocated, i64(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

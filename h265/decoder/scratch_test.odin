package h265_decoder

import "core:mem"
import "core:slice"
import "core:testing"

// The former construction explicitly repeats each group into a temporary
// list. Keep that independent index oracle instead of using modular lookup.
@(private)
scratch_test_ref_list :: proc(
	rps: ^Ref_Pic_Set,
	output: []i32,
	modify: bool,
	entries: []u32,
	l1: bool,
) -> bool {
	total := len(rps.st_curr_before) + len(rps.st_curr_after) + len(rps.lt_curr)
	if total == 0 do return false
	n := max(len(output), total)
	temporary: [32]i32
	count := 0
	first, second := rps.st_curr_before[:], rps.st_curr_after[:]
	if l1 do first, second = second, first
	for count < n {
		for group in ([3][]i32{first, second, rps.lt_curr[:]}) {
			for poc in group {
				if count == n do break
				temporary[count] = poc
				count += 1
			}
		}
	}
	for i in 0 ..< len(output) {
		index := i
		if modify && i < len(entries) {
			if int(entries[i]) >= n do return false
			index = int(entries[i])
		}
		output[i] = temporary[index]
	}
	return true
}

@(test)
test_ref_list_destination_exact_repetition_modification_and_no_allocations :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	for mask in 0 ..< 8 {
		rps: Ref_Pic_Set
		if mask & 1 != 0 do append(&rps.st_curr_before, -17, -1)
		if mask & 2 != 0 do append(&rps.st_curr_after, 1, 0x7fff_ffff)
		if mask & 4 != 0 do append(&rps.lt_curr, -0x8000_0000, 65536)
		for active in 0 ..= MAX_REFS {
			for list in 0 ..< 2 {
				for mode in 0 ..< 4 {
					actual, expected: [MAX_REFS + 4]i32
					for i in 0 ..< len(actual) do actual[i], expected[i] = i32(313 + i), i32(313 + i)
					entries: [MAX_REFS]u32
					n := max(active, ref_pic_set_num_poc_total_curr(&rps))
					for i in 0 ..< active do entries[i] = n > 0 ? u32((i * 5 + 1) % n) : 0
					entry_count := mode == 1 ? active / 2 : active
					if mode == 3 && active > 0 do entries[active - 1] = u32(n)
					wanted := scratch_test_ref_list(
						&rps,
						expected[2:2 + active],
						mode != 0,
						entries[:entry_count],
						list == 1,
					)
					actual_ok: bool
					before := track.total_allocation_count
					{
						context.allocator = mem.tracking_allocator(&track)
						actual_ok = build_ref_pic_list_into(
							&rps,
							actual[2:2 + active],
							mode != 0,
							entries[:entry_count],
							list == 1,
						)
					}
					testing.expect_value(t, track.total_allocation_count, before)
					testing.expect_value(t, actual_ok, wanted)
					testing.expectf(
						t,
						slice.equal(actual[:], expected[:]),
						"mask=%d active=%d list=%d mode=%d",
						mask,
						active,
						list,
						mode,
					)
				}
			}
		}
		destroy_ref_pic_set(&rps)
	}
	testing.expect_value(t, track.current_memory_allocated, i64(0))
}

@(test)
test_ref_list_owned_convenience_allocates_only_returned_list :: proc(t: ^testing.T) {
	rps: Ref_Pic_Set
	append(&rps.st_curr_before, -1, -17)
	append(&rps.st_curr_after, 1)
	defer destroy_ref_pic_set(&rps)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		list := build_ref_pic_list(&rps, MAX_REFS, false, nil, false)
		testing.expect_value(t, track.total_allocation_count, i64(1))
		testing.expect_value(t, len(list), MAX_REFS)
		list[0] = 1024
		testing.expect_value(t, rps.st_curr_before[0], i32(-1))
		delete(list)
		before := track.total_allocation_count
		bad := build_ref_pic_list(&rps, 2, true, []u32{0, 3}, false)
		testing.expect(t, bad == nil)
		testing.expect_value(t, track.total_allocation_count, before + 1)
	}
	testing.expect_value(t, track.current_memory_allocated, i64(0))
}

@(test)
test_continuation_reference_views_reuse_ctu_storage :: proc(t: ^testing.T) {
	d: Decoder
	ctu: Ctu_Decoder(u8)
	pictures: [MAX_REFS]Picture
	d.ctu = &ctu
	ctu.poc = 32
	for i in 0 ..< MAX_REFS {
		poc := i32((i - 8) * 65536 + 1)
		pictures[i].poc = int(poc)
		append(&d.dpb, Dpb_Picture{pic = &pictures[i], ref = true, long_term = i % 2 == 0})
		append(&d.cur_rps.st_curr_before, poc)
	}
	defer delete(d.dpb)
	defer destroy_ref_pic_set(&d.cur_rps)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	for segment in 0 ..< 48 {
		sh := Slice_Header {
			slice_type              = .B,
			num_ref_idx_l0_active   = MAX_REFS,
			num_ref_idx_l1_active   = 3,
			dependent_slice_segment = segment % 2 != 0,
			temporal_mvp            = true,
			collocated_from_l0      = true,
		}
		modifications: [MAX_REFS]u32
		for i in 0 ..< MAX_REFS do modifications[i] = u32((i + segment) % MAX_REFS)
		sh.list_modification.flag_l0 = true
		sh.list_modification.list_entry_l0 = modifications[:]
		if segment % 4 == 0 do sh.slice_type = .I
		before := track.total_allocation_count
		{
			context.allocator = mem.tracking_allocator(&track)
			build_ref_lists(&d, &ctu, &sh)
		}
		testing.expect_value(t, track.total_allocation_count, before)
		if sh.slice_type == .I {
			testing.expect(
				t,
				len(ctu.ref_poc[0]) == 0 && len(ctu.ref_poc[1]) == 0 && ctu.col_pic == nil,
			)
			continue
		}
		testing.expect_value(t, raw_data(ctu.ref_poc[0]), raw_data(ctu.ref_poc_storage[0][:]))
		testing.expect_value(t, raw_data(ctu.ref_pics[0]), raw_data(ctu.ref_pic_storage[0][:]))
		testing.expect_value(t, raw_data(ctu.ref_long[0]), raw_data(ctu.ref_long_storage[0][:]))
		for i in 0 ..< MAX_REFS {
			index := int(modifications[i])
			testing.expect_value(t, ctu.ref_poc[0][i], i32(pictures[index].poc))
			testing.expect_value(t, ctu.ref_pics[0][i], &pictures[index])
			testing.expect_value(t, ctu.ref_long[0][i], index % 2 == 0)
		}
		testing.expect_value(t, ctu.col_pic, &pictures[int(modifications[0])])
		testing.expect(t, !ctu.no_backward_pred)
	}
	// A refused modified index must publish an empty list, and a subsequent
	// valid segment must replace it using the same embedded destination.
	bad := Slice_Header {
		slice_type            = .P,
		num_ref_idx_l0_active = 2,
	}
	bad.list_modification.flag_l0 = true
	bad.list_modification.list_entry_l0 = []u32{0, MAX_REFS}
	build_ref_lists(&d, &ctu, &bad)
	testing.expect(
		t,
		len(ctu.ref_poc[0]) == 0 && len(ctu.ref_pics[0]) == 0 && len(ctu.ref_long[0]) == 0,
	)
	bad.list_modification.flag_l0 = false
	build_ref_lists(&d, &ctu, &bad)
	testing.expect_value(t, len(ctu.ref_poc[0]), 2)
	testing.expect_value(t, ctu.ref_pics[0][0], &pictures[0])
	testing.expect_value(t, ctu.ref_pics[0][1], &pictures[1])
	testing.expect_value(t, track.current_memory_allocated, i64(0))
}

@(test)
test_substream_start_borrows_syntax_preserves_epb_boundaries_and_error_order :: proc(
	t: ^testing.T,
) {
	rbsp: [32]u8
	epb := [4]u32{3, 7, 12, 18}
	nal := Nal_Unit {
		rbsp = rbsp[:],
		epb  = epb[:],
	}
	entries := [7]u32{0, 1, 2, 5, 10, 16, 0xffff_ffff}
	sh := Slice_Header {
		data_offset         = 2,
		entry_point_offsets = entries[:],
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	for i in 0 ..= len(entries) {
		// Independent byte-count oracle for this fixture's data_offset=2,
		// before its first removed byte. EPBs at the start itself are excluded.
		want := sh.data_offset
		if i > 0 {
			raw_offset := sh.data_offset + int(entries[i - 1])
			want = raw_offset
			for p in epb do if int(p) < raw_offset do want -= 1
		}
		start: int
		ok: bool
		{
			context.allocator = mem.tracking_allocator(&track)
			start, ok = substream_start(nal, &sh, i)
		}
		testing.expect(t, ok)
		testing.expect_value(t, start, want)
	}
	ctu: Ctu_Decoder(u8)
	ctu.c = Cabac {
		cursor = {value = 1234, range = 99, data = rbsp[:], pos = 7},
	}
	ctu.c.state[0] = 51
	ctu.qp_y_cur, ctu.qp_y_prev = 23, 19
	testing.expect(t, !start_substream(&ctu, nal, &sh, len(entries) + 1, false))
	testing.expect_value(t, ctu.c.cursor.value, u64(1234))
	testing.expect_value(t, ctu.c.cursor.range, u32(99))
	testing.expect_value(t, ctu.c.cursor.pos, 7)
	testing.expect_value(t, ctu.c.state[0], u8(51))
	testing.expect_value(t, ctu.qp_y_cur, i32(23))
	testing.expect_value(t, ctu.qp_y_prev, i32(19))
	testing.expect_value(t, track.total_allocation_count, i64(0))
}

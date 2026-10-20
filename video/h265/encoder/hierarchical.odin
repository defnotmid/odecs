package h265_encoder

import common "../../../common"

// ---------------------------------------------------------------------------
// Closed hierarchical GOP. Input arrives in display order; the encoder buffers
// a group plus its left anchor, codes the right anchor as a P picture, then
// the intermediate B pictures in dyadic order. Each B picture predicts from
// the nearest already-coded picture on each side: list 0 takes the negative
// (past) reference, list 1 the positive (future) one, exactly the order the
// decoder's 8.3.4 list construction produces from the inline short-term RPS.
//
// For a group of size G based at b the coded order is
//   b (already coded), b+G, b+G/2, b+G/4, b+3G/4, ...
// which is the recursion code_between(b, b+G): code the midpoint, then the two
// halves. The tail of a stream shorter than a full group uses the same
// recursion from the base to the last buffered picture.
// ---------------------------------------------------------------------------

// dpb_sizes returns max_dec_pic_buffering_minus1 and max_num_reorder_pics.
// The current reconstruction occupies a DPB picture in addition to retained
// references, including when output has no reordering delay.
dpb_sizes :: #force_inline proc(enc: ^Encoder) -> (buf, reorder: int) {
	if enc.config.hierarchical do return enc.gop_size, enc.gop_size - 1
	if enc.config.b_frames do return 2, 1
	// intra_only limits CU search but still emits P slices and their RPS.
	return enc.config.refs, 0
}

@(private)
hier_dpb_find :: proc(enc: ^Encoder, poc: i32) -> int {
	for i in 0 ..< MAX_HIER_FRAMES {
		if enc.hier_dpb_valid[i] && enc.hier_dpb_poc[i] == poc do return i
	}
	return -1
}

@(private)
hier_dpb_store :: proc(enc: ^Encoder, poc: i32) {
	slot := -1
	for i in 0 ..< MAX_HIER_FRAMES {
		if !enc.hier_dpb_valid[i] {
			slot = i
			break
		}
	}
	if slot < 0 do slot = 0
	copy_frame(&enc.hier_dpb[slot], &enc.rec)
	enc.hier_dpb_poc[slot] = poc
	enc.hier_dpb_valid[slot] = true
}

// hier_dpb_evict drops every reference older than `poc`, which is the left
// anchor of the next group.
@(private)
hier_dpb_evict :: proc(enc: ^Encoder, poc: i32) {
	for i in 0 ..< MAX_HIER_FRAMES {
		if enc.hier_dpb_valid[i] && enc.hier_dpb_poc[i] < poc do enc.hier_dpb_valid[i] = false
	}
}

// An RPS retains every live anchor even when the current picture does not
// use it. Omitting the outer right anchor in the left recursion would mark
// it unused in the decoder before the right half (or next group) needs it.
@(private)
write_hier_rps :: proc(enc: ^Encoder, w: ^common.Bit_Writer, poc: int, slice_type: Slice_Type) {
	refs: [2][MAX_HIER_FRAMES]int
	counts: [2]int
	for p, i in enc.hier_dpb_poc {
		if !enc.hier_dpb_valid[i] do continue
		side := int(p) < poc ? 0 : 1
		distance := abs(int(p) - poc)
		j := counts[side]
		for j > 0 && refs[side][j - 1] > distance {
			refs[side][j] = refs[side][j - 1]
			j -= 1
		}
		refs[side][j] = distance
		counts[side] += 1
	}
	common.write_ue(w, u32(counts[0]))
	common.write_ue(w, u32(counts[1]))
	for side in 0 ..< 2 {
		prev := 0
		for distance in refs[side][:counts[side]] {
			p := poc + (side == 0 ? -distance : distance)
			used :=
				p == int(enc.ref_poc[0][0]) || (slice_type == .B && p == int(enc.ref_poc[1][0]))
			common.write_ue(w, u32(distance - prev - 1))
			common.write_bits(w, used ? 1 : 0, 1)
			prev = distance
		}
	}
}

// code_hier_picture assembles the reference lists, codes one picture and files
// the reconstruction in the DPB. `ref_left`/`ref_right` are display POCs of
// already-coded pictures; a B picture uses both lists.
@(private)
code_hier_picture :: proc(
	enc: ^Encoder,
	poc: int,
	slice_type: Slice_Type,
	ref_left, ref_right: int,
	out: ^[dynamic]u8,
) {
	idx := poc - int(enc.queue_poc0)
	slot := (enc.queue_head + idx) % MAX_HIER_FRAMES
	copy_frame(&enc.source, &enc.hier_queue[slot])

	switch slice_type {
	case .I:
		enc.refs_active = {0, 0}
	case .B:
		sl := hier_dpb_find(enc, i32(ref_left))
		sr := hier_dpb_find(enc, i32(ref_right))
		copy_frame(&enc.refs[0][0], &enc.hier_dpb[sl])
		copy_frame(&enc.refs[1][0], &enc.hier_dpb[sr])
		enc.ref_poc[0][0] = i32(ref_left)
		enc.ref_poc[1][0] = i32(ref_right)
		enc.refs_active = {1, 1}
	case .P:
		sl := hier_dpb_find(enc, i32(ref_left))
		copy_frame(&enc.refs[0][0], &enc.hier_dpb[sl])
		enc.ref_poc[0][0] = i32(ref_left)
		enc.refs_active = {1, 0}
	}
	// One reference per list: the search runs both lists at index 0.
	enc.search_ref = {0, 0}

	encode_picture(enc, poc, slice_type, out)
	hier_dpb_store(enc, i32(poc))
}

// code_between codes every display position strictly between two coded
// pictures, midpoint first, so each B picture references its two nearest
// coded neighbours.
@(private)
code_between :: proc(enc: ^Encoder, left, right: int, out: ^[dynamic]u8) {
	if right - left <= 1 do return
	mid := (left + right) / 2
	code_hier_picture(enc, mid, .B, left, right, out)
	code_between(enc, left, mid, out)
	code_between(enc, mid, right, out)
}

// hier_code_group codes the buffered group once its right anchor has arrived.
@(private)
hier_code_group :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	left := int(enc.queue_poc0)
	right := left + enc.gop_size
	code_hier_picture(enc, right, .P, left, 0, out)
	code_between(enc, left, right, out)

	// Drop the group; the right anchor is the next group's left anchor. The
	// queue is a ring so no frame struct is copied (and none ends up owned by
	// two slots).
	enc.queue_head = (enc.queue_head + enc.gop_size) % MAX_HIER_FRAMES
	enc.queue_count -= enc.gop_size
	enc.queue_poc0 = i32(right)
	hier_dpb_evict(enc, i32(right))
}

// encode_frame_hier buffers one input frame and codes whatever the schedule
// can now emit.
encode_frame_hier :: proc(
	enc: ^Encoder,
	y, u, v: [^]Sample,
	y_stride, c_stride: int,
	out: ^[dynamic]u8,
) {
	if enc.frame_index == 0 do write_parameter_sets(enc, out)

	if enc.queue_count == 0 do enc.queue_poc0 = i32(enc.frame_index)
	slot := (enc.queue_head + enc.queue_count) % MAX_HIER_FRAMES
	set_source_into(enc, &enc.hier_queue[slot], y, u, v, y_stride, c_stride)
	enc.queue_count += 1
	enc.frame_index += 1

	// The leading I picture is codeable as soon as it is buffered.
	if !enc.hier_started {
		enc.hier_started = true
		code_hier_picture(enc, int(enc.queue_poc0), .I, 0, 0, out)
	}

	if enc.queue_count == enc.gop_size + 1 do hier_code_group(enc, out)
}

// flush_hier codes the buffered tail: the last picture as a P anchor of the
// remaining interval, then the B pictures between it and the left anchor.
flush_hier :: proc(enc: ^Encoder, out: ^[dynamic]u8) {
	if enc.queue_count == 0 do return

	if !enc.hier_started {
		enc.hier_started = true
		code_hier_picture(enc, int(enc.queue_poc0), .I, 0, 0, out)
	}

	left := int(enc.queue_poc0)
	right := left + enc.queue_count - 1
	if right > left {
		code_hier_picture(enc, right, .P, left, 0, out)
		code_between(enc, left, right, out)
	}
	enc.queue_count = 0
	enc.queue_head = 0
}

// set_source_into is set_source writing into an arbitrary frame, so the
// hierarchical queue can buffer the padded input without a second copy.
set_source_into :: proc(enc: ^Encoder, dst: ^Frame, y, u, v: [^]Sample, y_stride, c_stride: int) {
	for row in 0 ..< enc.height {
		for col in 0 ..< enc.width {
			set_at(dst.y, col, row, y[row * y_stride + col])
		}
		last := y[row * y_stride + enc.width - 1]
		for col in enc.width ..< enc.coded_width {
			set_at(dst.y, col, row, last)
		}
	}
	for row in enc.height ..< enc.coded_height {
		for col in 0 ..< enc.coded_width {
			set_at(dst.y, col, row, at(dst.y, col, enc.height - 1))
		}
	}
	if has_chroma(enc) {
		sub_w, sub_h := chroma_sub(enc.config.chroma_format)
		cw, ch := enc.width / sub_w, enc.height / sub_h
		for row in 0 ..< ch {
			for col in 0 ..< cw {
				set_at(dst.u, col, row, u[row * c_stride + col])
				set_at(dst.v, col, row, v[row * c_stride + col])
			}
			lu := u[row * c_stride + cw - 1]
			lv := v[row * c_stride + cw - 1]
			for col in cw ..< enc.coded_width / sub_w {
				set_at(dst.u, col, row, lu)
				set_at(dst.v, col, row, lv)
			}
		}
		for row in ch ..< enc.coded_height / sub_h {
			for col in 0 ..< enc.coded_width / sub_w {
				set_at(dst.u, col, row, at(dst.u, col, ch - 1))
				set_at(dst.v, col, row, at(dst.v, col, ch - 1))
			}
		}
	}
}

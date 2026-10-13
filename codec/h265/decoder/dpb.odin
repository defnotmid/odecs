package h265_decoder

import "core:slice"

// ---------------------------------------------------------------------------
// Picture order count, reference picture sets and the decoded picture buffer
// (8.3), ported from gen2brain/h265 hevc/dpb.go (MIT); oxideav-h265
// src/dpb.rs and src/poc.rs are the per-file cross-references.
//
// Output and decoder holds have separate lifetimes. Streaming callers may
// release output as soon as they finish reading it; prediction keeps the
// allocation alive until the DPB retires its own hold.
// ---------------------------------------------------------------------------

// Poc_State carries what 8.3.1 needs from the previous picture with TemporalId
// zero that was neither RASL, RADL nor a sub-layer non-reference picture.
Poc_State :: struct {
	prev_lsb: i32,
	prev_msb: i32,
}

// derive_poc is the picture order count derivation of 8.3.1.
derive_poc :: proc(
	st: ^Poc_State,
	nal_type: Nal_Type,
	lsb: i32,
	log2_max_lsb: u8,
	no_rasl_output: bool,
) -> i32 {
	max_lsb := i32(1) << uint(log2_max_lsb)

	msb: i32

	switch {
	case nal_type_is_irap(nal_type) && no_rasl_output:
		msb = 0
	case lsb < st.prev_lsb && st.prev_lsb - lsb >= max_lsb / 2:
		msb = st.prev_msb + max_lsb
	case lsb > st.prev_lsb && lsb - st.prev_lsb > max_lsb / 2:
		msb = st.prev_msb - max_lsb
	case:
		msb = st.prev_msb
	}

	return msb + lsb
}

// is_sub_layer_non_ref reports the sub-layer non-reference types, which 8.3.1
// excludes from the previous-picture search along with RASL and RADL.
is_sub_layer_non_ref :: proc(t: Nal_Type) -> bool {
	return u8(t) < 16 && u8(t) % 2 == 0
}

// poc_state_update advances the state 8.3.1 reads, which only pictures at
// temporal layer zero that are not RASL, RADL or sub-layer non-reference do.
poc_state_update :: proc(
	st: ^Poc_State,
	nal_type: Nal_Type,
	temporal_id: u8,
	poc, lsb: i32,
	log2_max_lsb: u8,
) {
	if temporal_id != 0 ||
	   nal_type == .RASL_N ||
	   nal_type == .RASL_R ||
	   nal_type == .RADL_N ||
	   nal_type == .RADL_R ||
	   is_sub_layer_non_ref(nal_type) {
		return
	}

	st.prev_lsb = lsb
	st.prev_msb = poc - lsb
}

// Ref_Pic_Set is the result of 8.3.2: the reference pictures the current
// picture may use, by POC, split the way list construction consumes them.
Ref_Pic_Set :: struct {
	st_curr_before:   [dynamic]i32,
	st_curr_after:    [dynamic]i32,
	lt_curr:          [dynamic]i32,
	st_foll:          [dynamic]i32,
	lt_foll:          [dynamic]i32,

	// A long-term entry whose delta_poc_msb_present_flag is zero names its
	// picture by the least significant bits alone, so it can only be resolved
	// against what the buffer holds.
	lt_curr_lsb_only: [dynamic]bool,
	lt_foll_lsb_only: [dynamic]bool,
}

destroy_ref_pic_set :: proc(r: ^Ref_Pic_Set) {
	delete(r.st_curr_before)
	delete(r.st_curr_after)
	delete(r.lt_curr)
	delete(r.st_foll)
	delete(r.lt_foll)
	delete(r.lt_curr_lsb_only)
	delete(r.lt_foll_lsb_only)
	r^ = {}
}

// derive_ref_pic_set is 8.3.2. The long-term entries need the current POC to
// rebuild their most significant bits, so it is passed rather than stored.
derive_ref_pic_set :: proc(
	poc: i32,
	log2_max_lsb: u8,
	st: ^Short_Term_RPS,
	lt: ^Long_Term_RPS,
	num_lt_sps: int,
) -> Ref_Pic_Set {
	r: Ref_Pic_Set

	for i in 0 ..< len(st.delta_poc_s0) {
		if st.used_s0[i] {
			append(&r.st_curr_before, poc + st.delta_poc_s0[i])
		} else {
			append(&r.st_foll, poc + st.delta_poc_s0[i])
		}
	}

	for i in 0 ..< len(st.delta_poc_s1) {
		if st.used_s1[i] {
			append(&r.st_curr_after, poc + st.delta_poc_s1[i])
		} else {
			append(&r.st_foll, poc + st.delta_poc_s1[i])
		}
	}

	max_lsb := i32(1) << uint(log2_max_lsb)

	cycle: i32

	for i in 0 ..< len(lt.poc_lsb_lt) {
		// DeltaPocMsbCycleLt accumulates within each of the two groups the
		// syntax splits long-term references into.
		if i == 0 || i == num_lt_sps {
			cycle = i32(lt.delta_poc_msb_cycle[i])
		} else {
			cycle += i32(lt.delta_poc_msb_cycle[i])
		}

		v := i32(lt.poc_lsb_lt[i])
		if lt.delta_poc_msb_present[i] {
			v = poc - cycle * max_lsb - poc & (max_lsb - 1) + v
		}

		if lt.used_by_curr_pic_lt[i] {
			append(&r.lt_curr, v)
			append(&r.lt_curr_lsb_only, !lt.delta_poc_msb_present[i])
		} else {
			append(&r.lt_foll, v)
			append(&r.lt_foll_lsb_only, !lt.delta_poc_msb_present[i])
		}
	}

	return r
}

ref_pic_set_num_poc_total_curr :: proc(r: ^Ref_Pic_Set) -> int {
	return len(r.st_curr_before) + len(r.st_curr_after) + len(r.lt_curr)
}

// build_ref_pic_list_into is 8.3.4. An index names the repeated concatenation
// of the three reference groups, so the repetition needs no temporary plane.
// The caller owns output; only its active entries are written.
build_ref_pic_list_into :: proc(
	rps: ^Ref_Pic_Set,
	output: []i32,
	modify: bool,
	entries: []u32,
	l1: bool,
) -> bool {
	total := ref_pic_set_num_poc_total_curr(rps)
	if total == 0 do return false
	n := max(len(output), total)
	first, second := rps.st_curr_before, rps.st_curr_after
	if l1 do first, second = rps.st_curr_after, rps.st_curr_before
	for i in 0 ..< len(output) {
		index := i
		if modify && i < len(entries) {
			if int(entries[i]) >= n do return false
			index = int(entries[i])
		}
		index %= total
		if index < len(first) {
			output[i] = first[index]
		} else if index < len(first) + len(second) {
			output[i] = second[index - len(first)]
		} else {
			output[i] = rps.lt_curr[index - len(first) - len(second)]
		}
	}
	return true
}

// The convenience API returns an owned list, as required by hardware callers
// that keep reference syntax outside one native slice decoder's scratch.
build_ref_pic_list :: proc(
	rps: ^Ref_Pic_Set,
	num_active: int,
	modify: bool,
	entries: []u32,
	l1: bool,
) -> []i32 {
	total := ref_pic_set_num_poc_total_curr(rps)
	if total == 0 do return nil
	list := make([]i32, num_active)
	if !build_ref_pic_list_into(rps, list, modify, entries, l1) {
		delete(list)
		return nil
	}
	return list
}

// Dpb_Picture is one decoded picture buffer entry, C.3.
Dpb_Picture :: struct {
	pic:       ^Picture,
	ref:       bool,
	long_term: bool,
	output:    bool,
	latency:   int,
}

dpb_find :: proc(d: ^Decoder, poc: i32) -> ^Picture {
	for i in 0 ..< len(d.dpb) {
		if i32(d.dpb[i].pic.poc) == poc do return d.dpb[i].pic
	}

	return nil
}

// dpb_mark is 8.3.2: everything the current picture's reference picture set
// leaves out stops being a reference.
dpb_mark :: proc(d: ^Decoder, rps: ^Ref_Pic_Set) {
	keep := make(map[i32]bool, ref_pic_set_num_poc_total_curr(rps))
	defer delete(keep)

	long := make(map[i32]bool, len(rps.lt_curr) + len(rps.lt_foll))
	defer delete(long)

	for p in rps.st_curr_before do keep[p] = true
	for p in rps.st_curr_after do keep[p] = true
	for p in rps.st_foll do keep[p] = true

	for p in rps.lt_curr {
		keep[p] = true
		long[p] = true
	}

	for p in rps.lt_foll {
		keep[p] = true
		long[p] = true
	}

	for i in 0 ..< len(d.dpb) {
		poc := i32(d.dpb[i].pic.poc)
		d.dpb[i].ref = keep[poc]
		d.dpb[i].long_term = long[poc]
	}
}

// dpb_long_term reports whether a reference picture is marked long term, which
// suppresses the motion vector scaling of 8.5.3.2.8.
dpb_long_term :: proc(d: ^Decoder, poc: i32) -> bool {
	for i in 0 ..< len(d.dpb) {
		if i32(d.dpb[i].pic.poc) == poc do return d.dpb[i].long_term
	}

	return false
}

// dpb_remove_unused drops the entries C.5.2.2 empties, those neither held for
// reference nor waiting to be output.
dpb_remove_unused :: proc(d: ^Decoder) {
	kept := 0

	for i in 0 ..< len(d.dpb) {
		e := d.dpb[i]

		if e.ref || e.output {
			d.dpb[kept] = e
			kept += 1
			continue
		}

		release_decoder_picture(e.pic)
	}

	resize(&d.dpb, kept)
}

dpb_need_output :: proc(d: ^Decoder) -> int {
	n := 0

	for e in d.dpb {
		if e.output do n += 1
	}

	return n
}

// dpb_bump is C.5.2.4, releasing the picture with the smallest picture order
// count of those still waiting.
dpb_bump :: proc(d: ^Decoder) -> ^Picture {
	best := -1

	for i in 0 ..< len(d.dpb) {
		if d.dpb[i].output && (best < 0 || d.dpb[i].pic.poc < d.dpb[best].pic.poc) {
			best = i
		}
	}

	if best < 0 do return nil

	p := d.dpb[best].pic
	d.dpb[best].output = false

	p.handed_out = true

	dpb_remove_unused(d)

	return p
}

// dpb_full is the bumping condition shared by C.5.2.2 and C.5.2.3.
dpb_full :: proc(d: ^Decoder, include_buffering: bool) -> bool {
	if dpb_need_output(d) > d.max_reorder do return true

	if d.max_latency != 0 {
		for e in d.dpb {
			if e.output && e.latency >= d.max_reorder + d.max_latency - 1 do return true
		}
	}

	return include_buffering && len(d.dpb) >= d.max_dec_pic_buf
}

dpb_drain :: proc(d: ^Decoder, include_buffering: bool) -> [dynamic]^Picture {
	out: [dynamic]^Picture

	for dpb_full(d, include_buffering) {
		p := dpb_bump(d)
		if p == nil do break

		append(&out, p)
	}

	return out
}

// dpb_store is C.5.2.3, which also ages every picture already waiting.
dpb_store :: proc(d: ^Decoder, p: ^Picture, output: bool) {
	p.decoder = d
	if output {
		for i in 0 ..< len(d.dpb) {
			if d.dpb[i].output do d.dpb[i].latency += 1
		}
	}

	append(&d.dpb, Dpb_Picture{pic = p, ref = true, output = output})
}

// resolve_long_term completes the long-term entries of 8.3.2 that carry only
// the least significant bits of their picture order count.
@(private)
resolve_long_term_fix :: proc(
	pocs: []i32,
	lsb_only: []bool,
	available: []i32,
	mask: i32,
	taken: ^map[i32]bool,
) -> bool {
	unique := true
	for i in 0 ..< len(pocs) {
		if i >= len(lsb_only) || !lsb_only[i] {
			matches := 0
			for poc in available do if poc == pocs[i] do matches += 1
			if matches != 1 || taken^[pocs[i]] do unique = false
			taken^[pocs[i]] = true
			continue
		}

		matches := 0
		first: i32
		for poc in available {
			if taken^[poc] || poc & mask != pocs[i] & mask do continue
			if matches == 0 do first = poc
			matches += 1
		}
		if matches != 1 do unique = false
		if matches > 0 {
			pocs[i] = first
			taken^[first] = true
		}
	}
	return unique
}

// Resolve long-term POC names against the available reference POCs in their
// existing DPB order. The result is true only when every name has one unique
// match; hardware callers can refuse missing/ambiguous references. On false,
// first matches and unresolved names retain the native decoder's historical
// behavior so its damaged-stream unavailable-picture policy remains intact.
resolve_long_term_ref_pocs :: proc(rps: ^Ref_Pic_Set, available: []i32, log2_max_lsb: u8) -> bool {
	if rps == nil do return false
	if len(rps.lt_curr) == 0 && len(rps.lt_foll) == 0 do return true
	if log2_max_lsb < 4 || log2_max_lsb > 16 do return false
	mask := i32(1) << uint(log2_max_lsb) - 1

	taken := make(map[i32]bool)
	defer delete(taken)

	current := resolve_long_term_fix(
		rps.lt_curr[:],
		rps.lt_curr_lsb_only[:],
		available,
		mask,
		&taken,
	)
	following := resolve_long_term_fix(
		rps.lt_foll[:],
		rps.lt_foll_lsb_only[:],
		available,
		mask,
		&taken,
	)
	return current && following
}

resolve_long_term :: proc(d: ^Decoder, rps: ^Ref_Pic_Set, log2_max_lsb: u8) {
	if len(rps.lt_curr) == 0 && len(rps.lt_foll) == 0 do return
	// Ordinary HEVC DPBs fit in sixteen pictures. Keep the collection on the
	// stack, with an explicit overflow allocation for broader legacy callers.
	local: [16]i32
	available := local[:]
	allocated := false
	if len(d.dpb) > len(available) {
		available = make([]i32, len(d.dpb))
		allocated = true
	}
	defer if allocated do delete(available)
	count := 0
	for e in d.dpb {
		if e.ref {
			available[count] = i32(e.pic.poc)
			count += 1
		}
	}
	resolve_long_term_ref_pocs(rps, available[:count], log2_max_lsb)
}

// generate_unavailable is 8.3.3. A reference the buffer never received is
// replaced by a mid-grey picture so a stream joined at a random access point,
// or one with a broken link, still decodes.
generate_unavailable :: proc(d: ^Decoder, rps: ^Ref_Pic_Set, s: ^SPS) {
	grey :: proc(d: ^Decoder, s: ^SPS, poc: i32) {
		if dpb_find(d, poc) != nil do return

		p := acquire_picture(d, s)
		p.decoder = d
		slice.zero(p.col_motion)
		p.poc = int(poc)

		fill_plane(p, 0, 1 << uint(p.bit_depth_y - 1))
		fill_plane(p, 1, 1 << uint(p.bit_depth_c - 1))
		fill_plane(p, 2, 1 << uint(p.bit_depth_c - 1))

		append(&d.dpb, Dpb_Picture{pic = p, ref = true})
	}

	for poc in rps.st_curr_before do grey(d, s, poc)
	for poc in rps.st_curr_after do grey(d, s, poc)
	for poc in rps.lt_curr do grey(d, s, poc)
	for poc in rps.st_foll do grey(d, s, poc)
	for poc in rps.lt_foll do grey(d, s, poc)
}

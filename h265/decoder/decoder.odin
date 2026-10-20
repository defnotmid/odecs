package h265_decoder


// ---------------------------------------------------------------------------
// Decoder top level. Parameter sets are kept by id; each first slice starts a
// picture, which is filed in the display buffer when the next one starts (or
// on flush) and surfaces in output order.
// ---------------------------------------------------------------------------

Decoder :: struct {
	// The nuh_layer_id this decoder decodes: 0, or an auxiliary (alpha)
	// layer decoded by a second decoder. NAL units of other layers are
	// skipped; VPSs, which belong to layer 0, are shared.
	layer:           u8,
	vps:             map[u8]^VPS,
	sps:             map[u32]^SPS,
	pps:             map[u32]^PPS,
	cur:             ^Picture,
	// The last independent slice header, for a dependent segment's 7.4.7.1
	// inheritance.
	prev_slice:      ^Slice_Header,
	cur_out:         bool,
	// The CTU decoder of the picture in progress, nil between pictures: the
	// retained one specialized for the picture's sample storage.
	ctu:             Active_Ctu,
	ctu8:            ^Ctu_Decoder(u8),
	ctu16:           ^Ctu_Decoder(u16),
	// Every picture this decoder allocated and still owns, and the subset no
	// caller or prediction holds, whose backing the next picture reuses.
	pictures:        [dynamic]^Picture,
	spare:           [dynamic]^Picture,
	dpb:             [dynamic]Dpb_Picture,
	poc:             Poc_State,
	cur_rps:         Ref_Pic_Set,

	// 8.1.3: leading pictures associated with an intra random access point
	// that starts decoding reference pictures that were never decoded, and
	// are discarded rather than decoded.
	seen_picture:    bool,
	skip_rasl:       bool,
	max_reorder:     int,
	max_latency:     int,
	max_dec_pic_buf: int,}

Active_Ctu :: union {
	^Ctu_Decoder(u8),
	^Ctu_Decoder(u16),
}

init_decoder :: proc(d: ^Decoder) {
	d.vps = make(map[u8]^VPS)
	d.sps = make(map[u32]^SPS)
	d.pps = make(map[u32]^PPS)
	d.dpb = make([dynamic]Dpb_Picture)
}

destroy_decoder :: proc(d: ^Decoder) {
	if d.prev_slice != nil {
		destroy_slice_header(d.prev_slice)
		free(d.prev_slice)
	}
	for _, v in d.vps do free(v)

	for _, s in d.sps {
		destroy_sps(s)
		free(s)
	}

	for _, p in d.pps {
		destroy_pps(p)
		free(p)
	}

	delete(d.vps)
	delete(d.sps)
	delete(d.pps)

	if d.ctu8 != nil do destroy_ctu_decoder(d.ctu8)
	if d.ctu16 != nil do destroy_ctu_decoder(d.ctu16)
	free(d.ctu8)
	free(d.ctu16)
	d.ctu, d.ctu8, d.ctu16 = nil, nil, nil

	// Detach every owned picture first, so a hold that outlives the decoder
	// frees its picture on release rather than returning it here.
	for p in d.pictures do p.owner = nil

	release_decoder_picture(d.cur)
	d.cur = nil

	for e in d.dpb do release_decoder_picture(e.pic)

	for p in d.spare {
		destroy_picture(p)
		free(p)
	}

	delete(d.spare)
	delete(d.pictures)
	delete(d.dpb)
	destroy_ref_pic_set(&d.cur_rps)

	d^ = {}
}

@(private)
store_sps :: proc(d: ^Decoder, s: SPS) -> bool {
	if old, ok := d.sps[s.id]; ok {
		destroy_sps(old)
		free(old)
	}

	p := new(SPS)
	p^ = s
	d.sps[s.id] = p

	return true
}

@(private)
store_pps :: proc(d: ^Decoder, p: PPS) -> bool {
	if old, ok := d.pps[p.id]; ok {
		destroy_pps(old)
		free(old)
	}

	q := new(PPS)
	q^ = p
	d.pps[q.id] = q

	return true
}

@(private)
store_vps :: proc(d: ^Decoder, v: VPS) -> bool {
	if old, ok := d.vps[v.id]; ok do free(old)

	p := new(VPS)
	p^ = v
	d.vps[p.id] = p

	return true
}

// DecodeANNEXB decodes a start-code delimited stream. The returned pictures
// are owned by the caller and must be freed with destroy_picture+free.
decode_annex_b :: proc(data: []u8) -> (pics: [dynamic]^Picture, ok: bool) {
	d: Decoder
	init_decoder(&d)
	defer destroy_decoder(&d)

	nals := split_annex_b(data)
	defer {
		for i in 0 ..< len(nals) do destroy_nal(&nals[i])
		delete(nals)
	}

	for i in 0 ..< len(nals) {
		if !decode_nal(&d, nals[i], &pics) {
			for p in pics do release_picture(&d, p)
			delete(pics)
			return nil, false
		}
	}

	if !flush_decoder(&d, &pics) {
		for p in pics do release_picture(&d, p)
		delete(pics)
		return nil, false
	}

	return pics, true
}

// finish_picture runs the loop filters over the picture the decoder has been
// filling, files it in the buffer and applies the additional bumping of
// C.5.2.3.
flush_decoder :: proc(d: ^Decoder, out: ^[dynamic]^Picture) -> bool {
	finish_picture(d, out)

	for {
		p := dpb_bump(d)
		if p == nil do break
		append(out, p)
	}

	d.cur, d.ctu = nil, nil

	return true
}

// finish_ctu runs the in-loop filters of a decoded picture and keeps the
// CTU decoder's grids for the next one.
finish_ctu :: proc(c: ^Ctu_Decoder($Sample)) {
	store_col_motion(c)
	deblock(c)
	apply_sao(c)
	end_ctu_picture(c)
}

finish_picture :: proc(d: ^Decoder, out: ^[dynamic]^Picture) {
	if d.cur == nil do return

	switch c in d.ctu {
	case ^Ctu_Decoder(u8):
		finish_ctu(c)
	case ^Ctu_Decoder(u16):
		finish_ctu(c)
	}

	dpb_store(d, d.cur, d.cur_out)

	d.cur, d.ctu = nil, nil

	drained := dpb_drain(d, false)
	for p in drained do append(out, p)
	delete(drained)
}

// decode_nal consumes one NAL unit and appends whatever pictures it completes.
// Output pictures stay valid until release_picture(d, p). Releasing output
// before the next decode is safe even when the DPB still needs its samples.
decode_nal :: proc(d: ^Decoder, nal: Nal_Unit, out: ^[dynamic]^Picture) -> bool {
	if nal.layer_id != d.layer && nal.type != .VPS_NUT do return true
	// The current CTU decoder borrows its active parameter sets. Complete it
	// before replacement so repeated headers at a closed GOP cannot free SPS
	// or PPS storage still used by the pending picture's in-loop filters.
	if nal.type == .VPS_NUT || nal.type == .SPS_NUT || nal.type == .PPS_NUT do finish_picture(d, out)
	#partial switch nal.type {
	case .VPS_NUT:
		v, good := parse_vps(nal.rbsp)
		if !good do return false
		return store_vps(d, v)

	case .SPS_NUT:
		s, good := parse_sps(nal.rbsp)
		if !good do return false
		if s.bit_depth_luma < 8 ||
		   s.bit_depth_luma > 12 ||
		   s.bit_depth_chroma < 8 ||
		   s.bit_depth_chroma > 12 {
			destroy_sps(&s)
			return false
		}
		return store_sps(d, s)

	case .PPS_NUT:
		p, good := parse_pps(nal.rbsp)
		if !good do return false
		return store_pps(d, p)

	case .EOS_NUT, .EOB_NUT:
		// The next picture starts afresh (8.1.3): a random access point with
		// NoRaslOutputFlag, whose C.5.2.2 rules decide what still waiting is shown.
		d.seen_picture = false
		return true
	case .AUD_NUT, .FD_NUT, .PREFIX_SEI_NUT, .SUFFIX_SEI_NUT:
		return true
	case:
	}

	if !nal_type_is_vcl(nal.type) do return true

	if nal_type_is_irap(nal.type) {
		d.skip_rasl =
			!d.seen_picture ||
			nal_type_is_idr(nal.type) ||
			(nal.type >= .BLA_W_LP && nal.type <= .BLA_N_LP)
		d.seen_picture = true
	}

	if d.skip_rasl && (nal.type == .RASL_N || nal.type == .RASL_R) do return true

	d.seen_picture = true

	return decode_slice(d, nal, out)
}

// decode_slice locates the parameter sets and decodes one slice segment.
decode_slice :: proc(d: ^Decoder, nal: Nal_Unit, out: ^[dynamic]^Picture) -> bool {
	// Locate the PPS without parsing the whole header twice.
	pps_id, good := peek_pps_id(nal)
	if !good do return false

	p, has_p := d.pps[pps_id]
	if !has_p do return false

	s, has_s := d.sps[p.sps_id]
	if !has_s do return false

	if !pps_resolve_tile_geometry(p, s) do return false

	if !sao_offset_scales_valid(p, s) do return false

	sh, good_h := parse_slice_header(nal.rbsp, nal.type, s, p)
	if !good_h do return false

	if !sh.first_slice_segment_in_pic {
		// 7.3.6.1: a continuation slice segment keeps the picture in
		// progress. A dependent one inherits the rest of its header from the
		// last independent segment (7.4.7.1); an independent one replaces
		// that retained header.
		if d.ctu == nil {
			destroy_slice_header(&sh)
			return false
		}

		shp: ^Slice_Header
		owned := false

		if sh.dependent_slice_segment {
			if d.prev_slice == nil {
				destroy_slice_header(&sh)
				return false
			}

			slice_header_inherit(&sh, d.prev_slice)
			shp = new(Slice_Header)
			shp^ = sh
			owned = true
		} else {
			own := new(Slice_Header)
			own^ = sh
			if d.prev_slice != nil {
				destroy_slice_header(d.prev_slice)
				free(d.prev_slice)
			}
			d.prev_slice = own
			shp = own
		}

		// 7.4.7.1 signals the active reference counts and the list
		// modification in every slice header, so the lists belong to the
		// slice segment.
		ok := decode_segment(d, nal, shp)

		// An Odin defer is scoped to its block, so the dependent copy is
		// released here rather than deferred.
		if owned {
			destroy_slice_header(shp)
			free(shp)
		}

		return ok
	}

	finish_picture(d, out)

	d.max_reorder = int(s.max_num_reorder_pics)
	d.max_latency = int(s.max_latency_increase)
	d.max_dec_pic_buf = int(s.max_dec_pic_buffering) + 1

	// 8.1.3 and 8.3.1: only a random access point that starts decoding
	// restarts the count; one in mid-stream keeps it.
	no_rasl_output := nal_type_is_irap(nal.type) && d.skip_rasl

	if no_rasl_output do d.poc = {}

	poc := derive_poc(
		&d.poc,
		nal.type,
		i32(sh.pic_order_cnt_lsb),
		s.log2_max_poc_lsb,
		no_rasl_output,
	)
	poc_state_update(
		&d.poc,
		nal.type,
		nal.temporal_id,
		poc,
		i32(sh.pic_order_cnt_lsb),
		s.log2_max_poc_lsb,
	)

	rps := derive_ref_pic_set(poc, s.log2_max_poc_lsb, &sh.st_rps, &sh.lt_rps, sh.lt_rps.num_sps)
	resolve_long_term(d, &rps, s.log2_max_poc_lsb)

	// C.5.2.2: a random access point that starts decoding either discards the
	// buffer or releases all of it, and a clean one always discards. Otherwise
	// the reference picture set decides what stays.
	if no_rasl_output {
		if !sh.no_output_of_prior_pics && nal.type != .CRA_NUT {
			for {
				q := dpb_bump(d)
				if q == nil do break
				append(out, q)
			}
		}

		for e in d.dpb do release_decoder_picture(e.pic)
		clear(&d.dpb)
	} else {
		dpb_mark(d, &rps)
		dpb_remove_unused(d)

		drained := dpb_drain(d, true)
		for q in drained do append(out, q)
		delete(drained)
	}

	if sh.slice_type != .I do generate_unavailable(d, &rps, s)

	destroy_ref_pic_set(&d.cur_rps)
	d.cur_rps = rps

	cur := acquire_picture(d, s)
	cur.decoder = d
	cur.poc = int(poc)
	d.cur = cur
	d.cur_out = sh.pic_output_flag

	if d.prev_slice != nil {
		destroy_slice_header(d.prev_slice)
		free(d.prev_slice)
	}
	prev := new(Slice_Header)
	slice_header_clone(prev, &sh)
	d.prev_slice = prev

	shp := new(Slice_Header)
	shp^ = sh

	if cur.sample_size == 1 {
		d.ctu = begin_ctu(&d.ctu8, s, p, shp, cur, poc)
	} else {
		d.ctu = begin_ctu(&d.ctu16, s, p, shp, cur, poc)
	}

	return decode_segment(d, nal, shp)
}

// sao_offset_scales_valid is the 7.4.3.3.2 bound: each SAO offset scale is at
// most Max(0, BitDepth - 10), which keeps scaled offsets within the decoder's
// 16-bit sample arithmetic.
sao_offset_scales_valid :: proc(p: ^PPS, s: ^SPS) -> bool {
	return(
		p.log2_sao_offset_scale_luma <= u32(max(0, int(s.bit_depth_luma) - 10)) &&
		p.log2_sao_offset_scale_chroma <= u32(max(0, int(s.bit_depth_chroma) - 10)) \
	)
}

// begin_ctu starts a picture in the retained CTU decoder of its storage type.
begin_ctu :: proc(
	store: ^^Ctu_Decoder($Sample),
	s: ^SPS,
	p: ^PPS,
	sh: ^Slice_Header,
	pic: ^Picture,
	poc: i32,
) -> ^Ctu_Decoder(Sample) {
	if store^ == nil do store^ = new(Ctu_Decoder(Sample))
	reset_ctu_decoder(store^, s, p, sh, pic)
	store^.poc = poc
	return store^
}

// decode_segment decodes one slice segment of the picture in progress. 7.4.7.1
// signals the active reference counts and the list modification in every
// slice segment header, so the lists belong to the segment.
decode_segment :: proc(d: ^Decoder, nal: Nal_Unit, sh: ^Slice_Header) -> bool {
	decode :: proc(
		d: ^Decoder,
		c: ^Ctu_Decoder($Sample),
		nal: Nal_Unit,
		sh: ^Slice_Header,
	) -> bool {
		build_ref_lists(d, c, sh)
		return decode_slice_data(c, nal, sh)
	}
	switch c in d.ctu {
	case ^Ctu_Decoder(u8):
		return decode(d, c, nal, sh)
	case ^Ctu_Decoder(u16):
		return decode(d, c, nal, sh)
	}
	return false
}

// build_ref_lists is 8.3.4 and the collocated picture selection of 8.5.3.2.8.
build_ref_lists :: proc(d: ^Decoder, c: ^Ctu_Decoder($Sample), sh: ^Slice_Header) {
	for l in 0 ..< 2 {
		c.ref_poc[l], c.ref_pics[l], c.ref_long[l] = nil, nil, nil

		if sh.slice_type == .I || (l == 1 && sh.slice_type != .B) do continue

		active := int(sh.num_ref_idx_l0_active)
		entries := sh.list_modification.list_entry_l0
		modify := sh.list_modification.flag_l0

		if l == 1 {
			active = int(sh.num_ref_idx_l1_active)
			entries = sh.list_modification.list_entry_l1
			modify = sh.list_modification.flag_l1
		}

		// The parser bounds both default and overridden active counts. These
		// views live in the current CTU decoder, not in per-segment heap lists.
		assert(active <= MAX_REFS)
		pocs := c.ref_poc_storage[l][:active]
		if !build_ref_pic_list_into(&d.cur_rps, pocs, modify, entries, l == 1) do continue
		c.ref_poc[l] = pocs
		c.ref_pics[l] = c.ref_pic_storage[l][:len(pocs)]
		c.ref_long[l] = c.ref_long_storage[l][:len(pocs)]

		for i in 0 ..< len(pocs) {
			c.ref_pics[l][i] = dpb_find(d, pocs[i])
			c.ref_long[l][i] = dpb_long_term(d, pocs[i])
		}
	}

	c.no_backward_pred = true

	for l in 0 ..< 2 {
		for p in c.ref_poc[l] {
			if p > c.poc do c.no_backward_pred = false
		}
	}

	c.col_pic = nil

	if sh.temporal_mvp {
		l := 1
		if sh.collocated_from_l0 do l = 0

		if int(sh.collocated_ref_idx) < len(c.ref_pics[l]) {
			c.col_pic = c.ref_pics[l][sh.collocated_ref_idx]
		}
	}
}

// peek_pps_id reads only the leading fields of a slice header.
peek_pps_id :: proc(nal: Nal_Unit) -> (u32, bool) {
	c: Get_Bits
	get_bits_init(&c, nal.rbsp)

	_ = get_bits_bit(&c) // first_slice_segment_in_pic_flag
	if nal.type >= .BLA_W_LP && nal.type <= .RSV_IRAP_VCL23 {
		_ = get_bits_bit(&c) // no_output_of_prior_pics_flag
	}

	id := get_bits_ue(&c)
	if c.err do return 0, false

	return id, true
}

// Entry point offsets count bytes of the NAL payload. Decode consumes one
// start at a time, so derive that RBSP offset directly from the borrowed
// header rather than materializing another per-segment list.
substream_start :: proc(nal: Nal_Unit, sh: ^Slice_Header, i: int) -> (start: int, ok: bool) {
	if i == 0 do return sh.data_offset, true
	if i < 0 || i - 1 >= len(sh.entry_point_offsets) do return 0, false
	base := nal_offset(nal, sh.data_offset)
	return nal_rbsp_offset(nal, base + int(sh.entry_point_offsets[i - 1])), true
}

// start_substream is 9.3.1. Every substream restarts the arithmetic decoder at
// its entry point; the first one also initializes the contexts, unless a
// dependent slice segment carries on with the contexts the previous segment
// ended with (a tile start always initializes).
start_substream :: proc(
	d: ^Ctu_Decoder($Sample),
	nal: Nal_Unit,
	sh: ^Slice_Header,
	i: int,
	tile_start: bool,
) -> bool {
	start, ok := substream_start(nal, sh, i)
	if !ok do return false
	if !cabac_init(&d.c, nal.rbsp, start) do return false

	// 8.6.1 restarts qPY_PREV at a slice or a tile, so a dependent segment
	// carrying on inside a tile keeps the quantisation parameter it
	// inherited.
	carry := i == 0 && sh.dependent_slice_segment && d.has_dep_saved && !tile_start

	if i == 0 && !carry {
		cabac_init_contexts(&d.c, sh.qp_y, sh.slice_type, sh.cabac_init)
	}

	if carry {
		d.c.state = d.dep_saved
		return true
	}

	d.qp_y_cur = sh.qp_y
	d.qp_y_prev = sh.qp_y

	return true
}

// decode_slice_data is 7.3.8.1. Tiles and wavefronts split the slice segment
// into substreams; the coding tree blocks are decoded in 6.5.1 tile-scan order
// and every substream boundary restarts the arithmetic decoder at an entry
// point. Wavefront rows hand the context state of 9.3.1 down to the next row.
decode_slice_data :: proc(d: ^Ctu_Decoder($Sample), nal: Nal_Unit, sh: ^Slice_Header) -> bool {
	// CTU syntax and reconstruction belong to this segment's header. The
	// picture retains its first owned header for the in-loop filter lifetime;
	// a dependent segment's temporary copy must not escape this call.
	picture_header := d.sh
	d.sh = sh
	defer d.sh = picture_header

	w := int(d.s.pic_width_in_ctbs)
	total := w * int(d.s.pic_height_in_ctbs)

	// 7.4.7.1: the header address is a raster-scan address. A dependent
	// segment keeps the slice group's start address (6.4.1 groups the
	// dependent segments with their independent one).
	d.slice_addr_rs = int(sh.slice_segment_address)
	if sh.dependent_slice_segment {
		d.slice_addr_rs = d.dep_slice_addr_rs
	} else {
		d.dep_slice_addr_rs = int(sh.slice_segment_address)
	}
	d.simple_avail = d.slice_addr_rs == 0 && !d.p.tiles_enabled

	start := int(d.grids.rs_to_ts[sh.slice_segment_address])
	tile_start := start == 0 || d.grids.tile_id[start] != d.grids.tile_id[start - 1]

	if !start_substream(d, nal, sh, 0, tile_start) do return false

	// The filters run after the whole picture, each with its own slice's controls.
	d.grids.slice_filters[d.slice_addr_rs] = {
		beta_offset_div2    = sh.beta_offset_div2,
		tc_offset_div2      = sh.tc_offset_div2,
		deblocking_disabled = sh.deblocking_disabled,
		loop_filter_across  = sh.loop_filter_across,
		sao_luma            = sh.sao_luma,
		sao_chroma          = sh.sao_chroma,
	}

	wpp := d.p.entropy_coding_sync
	sub := 0

	for ts := start; ts < total; ts += 1 {
		rs := int(d.grids.ts_to_rs[ts])
		d.grids.ctb_slice_addr[rs] = i32(d.slice_addr_rs)
		x := (rs % w) << uint(d.s.ctb_log2_size_y)
		y := (rs / w) << uint(d.s.ctb_log2_size_y)

		if wpp && rs % w == 0 {
			// 9.3.1 hands the new row the state stored after the second coding
			// tree block of the row above, but only when 6.4.1 makes the
			// above-right block available (same slice and tile, at least two
			// blocks wide); every other row of the segment initializes.
			top := rs - w + 1
			avail_top :=
				w >= 2 &&
				rs >= w &&
				top >= d.slice_addr_rs &&
				d.grids.tile_id[d.grids.rs_to_ts[rs]] == d.grids.tile_id[d.grids.rs_to_ts[top]]

			switch {
			case avail_top && d.has_saved:
				d.c.state = d.saved
			case ts > start || (w < 2 && rs > 0):
				cabac_init_contexts(&d.c, sh.qp_y, sh.slice_type, sh.cabac_init)
			}

			d.qp_y_prev = sh.qp_y
		}

		if !coding_tree_unit(d, x, y) do return false

		if wpp && rs % w == 1 {
			d.saved = d.c.state
			d.has_saved = true
		}

		if cabac_decode_terminate(&d.c) != 0 {
			// The dependent slice segment that follows carries on with the
			// state this segment ended with (9.3.1).
			if d.p.dependent_slice_segments_enabled {
				d.dep_saved = d.c.state
				d.has_dep_saved = true
			}

			return true
		}

		// A wavefront substream covers one tile row, and a tile ends where the
		// next coding tree block leaves it; both continue on a new entry point.
		end_of_tile := ts + 1 < total && d.grids.tile_id[ts + 1] != d.grids.tile_id[ts]
		end_of_row := wpp && ts + 1 < total && int(d.grids.ts_to_rs[ts + 1]) / w != rs / w

		if end_of_tile || end_of_row {
			if cabac_decode_terminate(&d.c) == 0 do return false

			sub += 1
			if !start_substream(d, nal, sh, sub, false) do return false

			if end_of_tile {
				cabac_init_contexts(&d.c, sh.qp_y, sh.slice_type, sh.cabac_init)
				d.has_saved = false
			}

			d.qp_y_prev = sh.qp_y
		}
	}

	return true
}

package h265_decoder

import "core:slice"

// ---------------------------------------------------------------------------
// One decoded picture. Planes hold samples in storage sized to the picture:
// one byte per sample when both bit depths are 8, two bytes otherwise.
// plane_at views a plane as samples of that storage type.
// ---------------------------------------------------------------------------

Picture :: struct {
	y:           []u8,
	u:           []u8,
	v:           []u8,
	sample_size: int,
	stride_y:    int,
	stride_c:    int,

	// The coded size in luma samples (the SPS picture size).
	width:       int,
	height:      int,
	bit_depth_y: u8,
	bit_depth_c: u8,

	// The conformance window.
	crop_x:      int,
	crop_y:      int,
	crop_w:      int,
	crop_h:      int,
	poc:         int,

	// The collocated motion field, subsampled to 16x16 as 8.5.3.2.9 allows.
	// Reference pictures are held by POC so a later picture need not read the
	// collocated picture's own reference lists.
	col_motion:  []Col_Motion,
	col_w:       int,

	// Chroma subsampling per axis (1 or 2); stride_c 0 marks monochrome.
	sub_w_c:     int,
	sub_h_c:     int,

	// Output and prediction have independent holds. A handed-out picture stays
	// valid until release_picture, even after its decoder has been destroyed.
	// The decoder retains it until it stops being current/reference/output.
	handed_out:  bool,
	decoder:     ^Decoder,
	// The decoder whose spare set takes this backing back once neither hold
	// remains. Nil for a caller-built picture or after decoder destruction.
	owner:       ^Decoder,
}

Col_Motion :: struct {
	info:     Mv_Info,
	ref_poc:  [2]i32,
	ref_long: [2]bool,
	intra:    bool,
}

col_index :: proc(p: ^Picture, x, y: int) -> int {
	return (y >> 4) * p.col_w + x >> 4
}

alloc_picture :: proc(s: ^SPS) -> Picture {
	p := picture_shape(s)
	height_c := p.height / p.sub_h_c

	p.y = make([]u8, p.stride_y * p.height * p.sample_size)
	p.u = make([]u8, p.stride_c * height_c * p.sample_size)
	p.v = make([]u8, p.stride_c * height_c * p.sample_size)
	p.col_motion = make([]Col_Motion, p.col_w * ((p.height + 15) / 16))

	return p
}

// picture_shape is a picture's geometry and format without its backing.
@(private)
picture_shape :: proc(s: ^SPS) -> Picture {
	p: Picture

	p.width = int(s.pic_width_in_luma_samples)
	p.height = int(s.pic_height_in_luma_samples)
	p.stride_y = p.width
	p.sub_w_c = s.sub_width_c
	p.sub_h_c = s.sub_height_c
	// A monochrome picture has no chroma planes (stride_c 0 marks it).
	has_chroma := sps_chroma_array_type(s) != 0
	p.stride_c = has_chroma ? p.width / s.sub_width_c : 0

	p.bit_depth_y = s.bit_depth_luma
	p.bit_depth_c = s.bit_depth_chroma
	p.sample_size = s.bit_depth_luma > 8 || s.bit_depth_chroma > 8 ? 2 : 1

	p.crop_x = int(s.conf_win_left) * s.sub_width_c
	p.crop_y = int(s.conf_win_top) * s.sub_height_c
	p.crop_w = int(sps_cropped_width(s))
	p.crop_h = int(sps_cropped_height(s))

	p.col_w = (p.width + 15) / 16

	return p
}

// acquire_picture returns a picture of the SPS geometry for the decoder to
// fill, reusing a spare picture's backing when one matches. Reused samples and
// collocated records keep their previous values until decoding writes them;
// a complete picture writes every one before it is read.
@(private)
acquire_picture :: proc(d: ^Decoder, s: ^SPS) -> ^Picture {
	want := picture_shape(s)
	height_c := want.height / want.sub_h_c
	col_h := (want.height + 15) / 16

	// A spare of another geometry is never reused after a change.
	for i := len(d.spare) - 1; i >= 0; i -= 1 {
		p := d.spare[i]
		if p.sample_size == want.sample_size &&
		   len(p.y) == want.stride_y * want.height * want.sample_size &&
		   len(p.u) == want.stride_c * height_c * want.sample_size &&
		   len(p.col_motion) == want.col_w * col_h {
			continue
		}
		unordered_remove(&d.spare, i)
		forget_picture(d, p)
	}

	if len(d.spare) > 0 {
		p := pop(&d.spare)
		y, u, v, col := p.y, p.u, p.v, p.col_motion
		p^ = want
		p.y, p.u, p.v, p.col_motion = y, u, v, col
		p.owner = d
		return p
	}

	p := new(Picture)
	p^ = alloc_picture(s)
	p.owner = d
	append(&d.pictures, p)
	return p
}

@(private)
forget_picture :: proc(d: ^Decoder, p: ^Picture) {
	for q, i in d.pictures {
		if q == p {
			unordered_remove(&d.pictures, i)
			break
		}
	}
	destroy_picture(p)
	free(p)
}

// retire_picture runs when neither the caller nor prediction holds a
// picture. A live owner keeps the backing; otherwise it is freed.
@(private)
retire_picture :: proc(p: ^Picture) {
	if p.owner != nil {
		append(&p.owner.spare, p)
		return
	}
	destroy_picture(p)
	free(p)
}

destroy_picture :: proc(p: ^Picture) {
	delete(p.y)
	delete(p.u)
	delete(p.v)
	delete(p.col_motion)
	p^ = {}
}

// Drop the caller's output hold. The DPB may still read this picture, so its
// allocation is reclaimed only after both caller and decoder release it.
// Call exactly once per output picture, on the decoder's owning thread. The
// decoder argument can be nil after decoder destruction; a live decoder must
// match the one that produced the picture. A successful call invalidates the
// caller's picture pointer, even if prediction still retains the allocation.
release_picture :: proc(d: ^Decoder, p: ^Picture) -> bool {
	if p == nil || !p.handed_out do return false
	if p.decoder != nil && p.decoder != d do return false
	p.handed_out = false
	if p.decoder == nil do retire_picture(p)
	return true
}

@(private)
release_decoder_picture :: proc(p: ^Picture) {
	if p == nil do return
	p.decoder = nil
	if !p.handed_out do retire_picture(p)
}

// plane_at views a plane as samples of the picture's storage type, with its
// stride in samples.
plane_at :: proc($Sample: typeid, p: ^Picture, c_idx: int) -> ([]Sample, int) {
	assert(size_of(Sample) == p.sample_size)
	bytes, stride := plane_bytes(p, c_idx)
	return slice.reinterpret([]Sample, bytes), stride
}

// plane_bytes is a plane's storage, with its stride in samples.
plane_bytes :: proc(p: ^Picture, c_idx: int) -> ([]u8, int) {
	switch c_idx {
	case 0:
		return p.y, p.stride_y
	case 1:
		return p.u, p.stride_c
	case:
		return p.v, p.stride_c
	}
}

// fill_plane sets every sample of a plane to v.
fill_plane :: proc(p: ^Picture, c_idx, v: int) {
	bytes, _ := plane_bytes(p, c_idx)
	if p.sample_size == 1 do slice.fill(bytes, u8(v))
	else do slice.fill(slice.reinterpret([]u16, bytes), u16(v))
}

sample_at :: proc(p: ^Picture, c_idx, x, y: int) -> int {
	plane, stride := plane_bytes(p, c_idx)
	at := (y * stride + x) * p.sample_size
	if p.sample_size == 1 do return int(plane[at])
	return int(plane[at]) | int(plane[at + 1]) << 8
}

// Append the visible region of every component in planar display order (no
// chroma planes for monochrome): one byte per sample for an 8-bit picture,
// 16-bit little-endian samples otherwise, the layout ffmpeg's raw video
// output uses. Storage rows are already in that layout.
append_picture_display :: proc(p: ^Picture, out: ^[dynamic]u8) {
	for c_idx in 0 ..= 2 {
		if c_idx > 0 && p.stride_c == 0 do break // monochrome

		plane, stride := plane_bytes(p, c_idx)
		sw, sh := 1, 1
		if c_idx > 0 do sw, sh = p.sub_w_c, p.sub_h_c
		x0, y0, w, h := p.crop_x / sw, p.crop_y / sh, p.crop_w / sw, p.crop_h / sh

		for y in y0 ..< y0 + h {
			row := (y * stride + x0) * p.sample_size
			append(out, ..plane[row:row + w * p.sample_size])
		}
	}
}

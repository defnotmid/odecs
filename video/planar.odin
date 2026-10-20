package video

import common "../common"
import media "../media"

// What a Frame carries.
Frame_Format :: enum u8 {
	RGBA,   // converted RGBA8 in Frame.rgba (the default)
	Planar, // the decoded planes in Frame.planar, for the caller to convert (in a shader, say)
}

// A frame's decoded samples with what is needed to convert them. Rows are
// tight. Samples are bytes at 8 bits and little-endian u16 above, LSB-
// aligned (0 .. 2^bit_depth - 1; P010 would be MSB-aligned). Colour planes
// are never premultiplied. planar_to_rgba is the reader's own conversion,
// a reference for a shader.
Planar :: struct {
	planes:          [3][]u8, // Y', Cb, Cr; G, B, R when color.matrix_coeffs is 0 (identity). Cb, Cr empty for monochrome
	strides:         [3]int, // bytes
	alpha:           []u8, // luma-sized and -deep; empty without alpha
	alpha_stride:    int,
	width, height:   int,
	chroma:          media.Chroma, // subsampling of planes 1 and 2
	bit_depth:       int, // 8, 10 or 12
	storage_bits:    int, // 8 or 16
	color:           media.Color, // as resolved for conversion (see the colour notes in the README)
	chroma_location: u8, // H.273 ChromaSampleLocType: the reader does not read siting, so 0, the H.264/H.265 default
	// The colour planes are premultiplied by alpha (HEVC alpha_channel_use_idc
	// 1, as Apple writes); otherwise colour is straight.
	alpha_premultiplied: bool,
}

// The reader's conversion of a planar frame to RGBA8 (width x height x 4
// bytes), including tone mapping for HDR. On `pool` it runs in bands.
planar_to_rgba :: proc(p: Planar, dst: []u8, premultiplied := false, pool: ^common.Work_Pool = nil) {
	job := Convert_Job {
		frame = {
			width = p.width,
			height = p.height,
			bit_depth = p.bit_depth,
			storage_bits = p.storage_bits,
			chroma = p.chroma,
			planes = {{p.planes[0], p.strides[0]}, {p.planes[1], p.strides[1]}, {p.planes[2], p.strides[2]}},
		},
		dst = dst,
	}
	set_alpha(&job, {p.alpha, p.alpha_stride, premultiplied}, p.alpha_premultiplied)
	cache: Conversion_Cache
	defer free(cache.tone)
	prepare_conversion(&cache, &job, p.color)
	run_bands(&job, pool)
}

// Coefficients or a tone map, rebuilt when the colour or depth changes.
@(private)
Conversion_Cache :: struct {
	coefficients: Yuv_To_Rgb,
	key:          Conversion_Key,
	tone:         ^Tone_Map,
	tone_key:     Conversion_Key,
}

@(private)
Conversion_Key :: struct {
	matrix_coeffs: u8,
	full_range:    bool,
	bit_depth:     int,
	transfer:      u8,
	primaries:     u8,
}

// Chooses the job's conversion for `color`: G, B, R planes (matrix 0 at
// 4:4:4), the HDR/wide-gamut path, or the integer SDR matrix.
@(private)
prepare_conversion :: proc(c: ^Conversion_Cache, job: ^Convert_Job, color: media.Color) {
	f := &job.frame
	job.gbr = color.matrix_coeffs == 0 && f.chroma == .YUV444
	if job.gbr do return
	key := Conversion_Key{color.matrix_coeffs, color.full_range, f.bit_depth, color.transfer, color.primaries}
	if needs_tone_map(color) {
		if c.tone == nil do c.tone = new(Tone_Map)
		if key != c.tone_key {
			init_tone_map(c.tone, color, f.bit_depth)
			c.tone_key = key
		}
		job.tone = c.tone
		return
	}
	if key != c.key {
		m: Matrix = .BT709
		switch color.matrix_coeffs {
		case 5, 6:
			m = .BT601
		case 9, 10:
			m = .BT2020
		}
		c.coefficients = yuv_to_rgb_coefficients(m, color.full_range, f.bit_depth)
		c.key = key
	}
	job.coefficients = &c.coefficients
}

@(private)
run_bands :: proc(job: ^Convert_Job, pool: ^common.Work_Pool) {
	bands := (job.frame.height + CONVERT_BAND - 1) / CONVERT_BAND
	if pool != nil && bands > 1 {
		pool.run(pool, bands, convert_bands, job)
	} else {
		convert_bands(job, 0, bands)
	}
}

// Bytes a frame's planes take in planar output.
@(private)
planar_bytes :: proc(f: media.Video_Frame) -> int {
	cw, ch := chroma_size(f)
	bytes := f.bit_depth > 8 ? 2 : 1
	return (f.width * f.height * (len(f.alpha.data) > 0 ? 2 : 1) + 2 * cw * ch) * bytes
}

@(private)
chroma_size :: proc(f: media.Video_Frame) -> (w, h: int) {
	if f.chroma == .Monochrome do return 0, 0
	sx, sy := media.chroma_subsampling(f.chroma)
	return (f.width + sx - 1) / sx, (f.height + sy - 1) / sy
}

// The planar layout of a frame in `buffer` (planar_bytes long).
@(private)
planar_layout :: proc(f: media.Video_Frame, color: media.Color, buffer: []u8) -> (p: Planar) {
	bytes := f.bit_depth > 8 ? 2 : 1
	cw, ch := chroma_size(f)
	p = {
		width        = f.width,
		height       = f.height,
		chroma       = f.chroma,
		bit_depth    = f.bit_depth,
		storage_bits = 8 * bytes,
		color        = color,
		strides      = {f.width * bytes, cw * bytes, cw * bytes},
	}
	at := 0
	take :: proc(buffer: []u8, at: ^int, n: int) -> []u8 {
		s := buffer[at^:][:n]
		at^ += n
		return s
	}
	p.planes[0] = take(buffer, &at, p.strides[0] * f.height)
	if cw > 0 {
		p.planes[1] = take(buffer, &at, p.strides[1] * ch)
		p.planes[2] = take(buffer, &at, p.strides[2] * ch)
	}
	if len(f.alpha.data) > 0 {
		p.alpha_stride = p.strides[0]
		p.alpha = take(buffer, &at, p.alpha_stride * f.height)
		p.alpha_premultiplied = f.alpha_premultiplied
	}
	return
}

// Copies one band of rows of every plane into the planar layout. 16-bit
// storage of 8-bit samples (Vulkan Video's output) narrows to bytes.
@(private)
copy_planar_band :: proc(f: ^media.Video_Frame, p: ^Planar, y0, rows: int) {
	copy_rows :: proc(src: media.Plane, dst: []u8, dst_stride, first, count, samples, src_bits, dst_bits: int) {
		for y in first ..< first + count {
			from := src.data[y * src.stride:]
			to := dst[y * dst_stride:][:samples * dst_bits / 8]
			if src_bits == dst_bits {
				copy(to, from[:len(to)])
			} else {
				wide := ([^]u16)(raw_data(from))
				for i in 0 ..< samples do to[i] = u8(wide[i])
			}
		}
	}
	copy_rows(f.planes[0], p.planes[0], p.strides[0], y0, rows, f.width, f.storage_bits, p.storage_bits)
	if len(f.alpha.data) > 0 do copy_rows(f.alpha, p.alpha, p.alpha_stride, y0, rows, f.width, f.storage_bits, p.storage_bits)
	cw, ch := chroma_size(f^)
	if cw == 0 do return
	_, sy := media.chroma_subsampling(f.chroma)
	first, end := y0 / sy, min((y0 + rows + sy - 1) / sy, ch)
	for i in 1 ..= 2 do copy_rows(f.planes[i], p.planes[i], p.strides[i], first, end - first, cw, f.storage_bits, p.storage_bits)
}

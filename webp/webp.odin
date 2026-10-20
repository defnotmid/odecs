// WebP decoding (RFC 9649) to RGBA8 with straight alpha: lossy (VP8 key
// frames) and lossless (VP8L) images, alpha (ALPH), the extended format
// (VP8X), and animation (ANIM/ANMF, see animation.odin).
//
// Written from RFC 9649, RFC 6386 and libwebp 1.6.0 (BSD-3-Clause; its
// notice in LICENSE-libwebp.txt), whose tables tables.odin copies.
package webp

import "../common"
import "base:intrinsics"
import "core:simd"

Error :: enum {
	None,
	Invalid,
	Unsupported,
	Out_Of_Memory,
}

// A decoded picture: width * height RGBA8 pixels, straight alpha, rows top
// to bottom.
Image :: struct {
	width, height: int,
	pixels:        []u8,
}

Features :: struct {
	width, height: int, // the canvas
	has_alpha:     bool,
	animated:      bool,
	lossless:      bool, // the first frame's coding
	frame_count:   int,
	loop_count:    int, // 0: forever
	background:    [4]u8, // RGBA, a hint for animations
}

// A frame's chunks: the bitstream and its optional alpha, and where it lies
// on the canvas (an animation frame).
@(private)
Frame_Chunks :: struct {
	bitstream:     []u8,
	alpha:         []u8, // ALPH payload, lossy frames only
	lossless:      bool,
	x, y:          int,
	width, height: int,
	duration:      int, // milliseconds
	blend:         bool, // alpha-blend onto the canvas (else overwrite)
	dispose:       bool, // clear the frame's rectangle afterwards
}

@(private)
Chunk :: struct {
	fourcc:  string,
	payload: []u8,
}

// The RIFF chunks after the header, padded to even sizes; a truncated last
// chunk keeps what is there.
@(private)
next_chunk :: proc(data: ^[]u8) -> (c: Chunk, ok: bool) {
	if len(data) < 8 do return
	c.fourcc = string(data[:4])
	size := int(le32(data[4:]))
	rest := data[8:]
	size = min(size, len(rest))
	c.payload = rest[:size]
	data^ = rest[min(size + (size & 1), len(rest)):]
	return c, true
}

@(private)
le32 :: #force_inline proc(b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private)
le24 :: #force_inline proc(b: []u8) -> int {
	return int(b[0]) | int(b[1]) << 8 | int(b[2]) << 16
}

@(private)
riff_body :: proc(data: []u8) -> (body: []u8, err: Error) {
	if len(data) < 12 || string(data[:4]) != "RIFF" || string(data[8:12]) != "WEBP" do return nil, .Invalid
	size := int(le32(data[4:]))
	if size < 4 do return nil, .Invalid
	return data[12:min(len(data), 8 + size)], .None
}

// A still image's frame (or a frame's ANMF payload): optional ALPH, then
// VP8 or VP8L, other chunks skipped.
@(private)
find_frame :: proc(chunks: []u8) -> (f: Frame_Chunks, ok: bool) {
	rest := chunks
	for c in next_chunk(&rest) {
		switch c.fourcc {
		case "ALPH":
			f.alpha = c.payload
		case "VP8 ":
			f.bitstream = c.payload
			return f, true
		case "VP8L":
			f.bitstream, f.lossless = c.payload, true
			f.alpha = nil
			return f, true
		case "ANMF", "ANIM":
			return f, false
		}
	}
	return f, false
}

// The frame's own size, from its bitstream header.
@(private)
bitstream_size :: proc(f: ^Frame_Chunks) -> bool {
	b := f.bitstream
	if f.lossless {
		if len(b) < 5 || b[0] != 0x2f do return false
		bits := le32(b[1:])
		f.width, f.height = int(bits & 0x3fff) + 1, int((bits >> 14) & 0x3fff) + 1
		return true
	}
	if len(b) < 10 || b[3] != 0x9d || b[4] != 0x01 || b[5] != 0x2a do return false
	f.width = int(u16(b[6]) | u16(b[7]) << 8) & 0x3fff
	f.height = int(u16(b[8]) | u16(b[9]) << 8) & 0x3fff
	return f.width > 0 && f.height > 0
}

get_features :: proc(data: []u8) -> (ft: Features, err: Error) {
	body := riff_body(data) or_return
	rest := body
	first, ok := next_chunk(&rest)
	if !ok do return ft, .Invalid
	if first.fourcc != "VP8X" {
		f, found := find_frame(body)
		if !found || !bitstream_size(&f) do return ft, .Invalid
		ft.width, ft.height, ft.lossless, ft.frame_count = f.width, f.height, f.lossless, 1
		ft.has_alpha = f.lossless // VP8L may carry alpha
		return ft, .None
	}
	x := first.payload
	if len(x) < 10 do return ft, .Invalid
	flags := x[0]
	ft.has_alpha = flags & 0x10 != 0
	ft.animated = flags & 0x02 != 0
	ft.width, ft.height = le24(x[4:]) + 1, le24(x[7:]) + 1
	if !ft.animated {
		f, found := find_frame(rest)
		if !found do return ft, .Invalid
		ft.lossless, ft.frame_count = f.lossless, 1
		return ft, .None
	}
	for c in next_chunk(&rest) {
		switch c.fourcc {
		case "ANIM":
			if len(c.payload) >= 6 {
				bg := c.payload[:4] // blue, green, red, alpha
				ft.background = {bg[2], bg[1], bg[0], bg[3]}
				ft.loop_count = int(u16(c.payload[4]) | u16(c.payload[5]) << 8)
			}
		case "ANMF":
			if len(c.payload) >= 16 {
				if ft.frame_count == 0 {
					f, _ := find_frame(c.payload[16:])
					ft.lossless = f.lossless
				}
				ft.frame_count += 1
			}
		}
	}
	if ft.frame_count == 0 do return ft, .Invalid
	return ft, .None
}

// Decodes a still image, or an animation's first frame on its canvas.
// `pool` (optional) converts rows in parallel.
decode :: proc(data: []u8, pool: ^common.Work_Pool = nil, allocator := context.allocator) -> (img: Image, err: Error) {
	ft := get_features(data) or_return
	pixels, perr := make([]u8, ft.width * ft.height * 4, allocator)
	if perr != nil do return {}, .Out_Of_Memory
	if err = decode_into(data, pixels, pool, allocator); err != .None {
		delete(pixels, allocator)
		return {}, err
	}
	return {ft.width, ft.height, pixels}, .None
}

// Decodes into `pixels`, width * height * 4 bytes (from get_features).
// Scratch comes from `allocator` and is freed before returning.
decode_into :: proc(data: []u8, pixels: []u8, pool: ^common.Work_Pool = nil, allocator := context.allocator) -> Error {
	ft := get_features(data) or_return
	if len(pixels) < ft.width * ft.height * 4 do return .Invalid
	if ft.animated {
		a: Animation
		init_animation(&a, data, pool, allocator) or_return
		defer destroy_animation(&a)
		frame := next_frame(&a) or_return
		copy(pixels, frame.pixels)
		return .None
	}
	body := riff_body(data) or_return
	rest := body
	if first, _ := next_chunk(&rest); first.fourcc == "VP8X" do body = rest
	f, found := find_frame(body)
	if !found || !bitstream_size(&f) do return .Invalid
	if f.width != ft.width || f.height != ft.height do return .Invalid
	return frame_into(&f, pixels, pool, allocator)
}

// A lossy still image's planes as decoded, before conversion to RGB: Y, U
// and V (4:2:0, the size rounded up to whole 16x16 macroblocks), and the
// alpha plane (width * height) if the image has one. Lossless and animated
// images return .Unsupported.
decode_yuva :: proc(data: []u8, allocator := context.allocator) -> (yuv: Yuv, alpha: []u8, err: Error) {
	ft := get_features(data) or_return
	if ft.animated do return {}, nil, .Unsupported
	body := riff_body(data) or_return
	rest := body
	if first, _ := next_chunk(&rest); first.fourcc == "VP8X" do body = rest
	f, found := find_frame(body)
	if !found do return {}, nil, .Invalid
	if f.lossless do return {}, nil, .Unsupported
	yuv = decode_vp8(f.bitstream, allocator) or_return
	if f.alpha != nil {
		alpha, err = decode_alpha(f.alpha, yuv.width, yuv.height, allocator)
		if err != .None do destroy_yuv(&yuv, allocator)
	}
	return
}

destroy_image :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.pixels, allocator)
	img^ = {}
}

@(private)
decode_frame :: proc(f: ^Frame_Chunks, pool: ^common.Work_Pool, allocator: Allocator) -> (img: Image, err: Error) {
	pixels, perr := make([]u8, f.width * f.height * 4, allocator)
	if perr != nil do return {}, .Out_Of_Memory
	if err = frame_into(f, pixels, pool, allocator); err != .None {
		delete(pixels, allocator)
		return {}, err
	}
	return {f.width, f.height, pixels}, .None
}

// A frame's RGBA into `pixels` (f.width * f.height * 4 bytes).
@(private)
frame_into :: proc(f: ^Frame_Chunks, pixels: []u8, pool: ^common.Work_Pool, allocator: Allocator) -> Error {
	if f.lossless {
		// Decoded into `pixels` as ARGB words, then made RGBA bytes in place.
		out := ([^]u32)(raw_data(pixels))[:len(pixels) / 4]
		argb, w, h := decode_vp8l(f.bitstream, allocator, out) or_return
		if raw_data(argb) != raw_data(out) do delete(argb, allocator) // a size the header did not promise
		if w * h > len(out) || raw_data(argb) != raw_data(out) do return .Invalid
		for &p in out[:w * h] do p = p & 0xff00ff00 | (p >> 16) & 0xff | (p & 0xff) << 16
		return .None
	}
	yuv := decode_vp8(f.bitstream, allocator) or_return
	defer destroy_yuv(&yuv, allocator)
	alpha: []u8
	if f.alpha != nil {
		alpha = decode_alpha(f.alpha, yuv.width, yuv.height, allocator) or_return
	}
	defer delete(alpha, allocator)
	if yuv.width * yuv.height * 4 > len(pixels) do return .Invalid
	yuv_to_rgba(&yuv, alpha, pixels, pool)
	return .None
}

// An ALPH chunk's plane (RFC 9649, "Alpha"): raw or lossless-compressed,
// then unfiltered.
@(private)
decode_alpha :: proc(chunk: []u8, width, height: int, allocator: Allocator) -> (plane: []u8, err: Error) {
	if len(chunk) < 1 do return nil, .Invalid
	header := chunk[0]
	method, filter, preprocessing := header & 3, (header >> 2) & 3, (header >> 4) & 3
	if method > 1 || preprocessing > 1 || header >> 6 != 0 do return nil, .Invalid
	plane, _ = make([]u8, width * height, allocator)
	if plane == nil do return nil, .Out_Of_Memory
	if method == 0 {
		if len(chunk) - 1 < width * height {
			delete(plane, allocator)
			return nil, .Invalid
		}
		copy(plane, chunk[1:])
	} else {
		argb, e := decode_vp8l_image(chunk[1:], width, height, allocator)
		if e != .None {
			delete(plane, allocator)
			return nil, e
		}
		for p, i in argb do plane[i] = u8(p >> 8) // green
		delete(argb, allocator)
	}
	unfilter_alpha(plane, width, height, filter)
	return plane, .None
}

// Each value is a residual from a prediction: the left, above or gradient
// neighbour; the first row predicts from the left, the first column from
// above, the first pixel from 0.
@(private)
unfilter_alpha :: proc(a: []u8, width, height: int, filter: u8) {
	if filter == 0 do return
	for x in 1 ..< width do a[x] += a[x - 1]
	for y in 1 ..< height {
		row := a[y * width:][:width]
		prev := a[(y - 1) * width:][:width]
		switch filter {
		case 1:
			row[0] += prev[0]
			for x in 1 ..< width do row[x] += row[x - 1]
		case 2:
			for x in 0 ..< width do row[x] += prev[x]
		case 3:
			row[0] += prev[0]
			for x in 1 ..< width do row[x] += u8(clamp(int(row[x - 1]) + int(prev[x]) - int(prev[x - 1]), 0, 255))
		}
	}
}

// YUV 4:2:0 to RGBA, BT.601 studio range as libwebp computes it, chroma
// upsampled by 9-3-3-1 weights (each output pixel from its four nearest
// chroma samples). A row's chroma is upsampled first, then the pixels are
// converted in one flat loop the compiler vectorizes. Rows are independent:
// they run on the pool.
@(private)
yuv_to_rgba :: proc(f: ^Yuv, alpha: []u8, out: []u8, pool: ^common.Work_Pool) {
	Job :: struct {
		f:     ^Yuv,
		alpha: []u8,
		out:   []u8,
	}
	job := Job{f, alpha, out}
	rows :: proc(data: rawptr, first, end: int) {
		job := (^Job)(data)
		f := job.f
		cw := (f.width + 1) >> 1
		ch := (f.height + 1) >> 1
		u_row, v_row: [16384]u8 // the widest image
		for y in first ..< end {
			near := y >> 1
			far := y & 1 == 0 ? max(near - 1, 0) : min(near + 1, ch - 1)
			upsample_row(f.u[near * f.uv_stride:][:cw], f.u[far * f.uv_stride:][:cw], u_row[:f.width])
			upsample_row(f.v[near * f.uv_stride:][:cw], f.v[far * f.uv_stride:][:cw], v_row[:f.width])
			a := job.alpha != nil ? job.alpha[y * f.width:][:f.width] : nil
			dst := ([^]u32)(raw_data(job.out[y * f.width * 4:]))[:f.width]
			convert_row(f.y[y * f.y_stride:][:f.width], u_row[:f.width], v_row[:f.width], a, dst)
		}
	}
	if pool != nil && f.height >= 64 {
		pool.run(pool, f.height, rows, &job)
	} else {
		rows(&job, 0, f.height)
	}
}

// One plane's chroma for an output row: between the near and far chroma
// rows (3/4, 1/4) and horizontally between neighbouring samples (3/4,
// 1/4), libwebp's "fancy" upsampling with its rounding. Output pixels
// 2k - 1 and 2k come from samples k - 1 and k: eight k at a time, the two
// outputs interleaved.
@(private)
upsample_row :: proc(near, far: []u8, out: []u8) #no_bounds_check {
	U :: #simd[8]u16
	load :: #force_inline proc(s: []u8, at: int) -> U {return cast(U)intrinsics.unaligned_load((^#simd[8]u8)(&s[at]))}
	width := len(out)
	out[0] = u8((3 * u32(near[0]) + u32(far[0]) + 2) >> 2)
	pairs := (width - 1) >> 1 // k = 1 ..= pairs
	k := 1
	for ; k + 8 <= pairs + 1 && k + 8 <= len(near); k += 8 {
		n0, n1, f0, f1 := load(near, k - 1), load(near, k), load(far, k - 1), load(far, k)
		avg := n0 + n1 + f0 + f1 + 8
		d12 := simd.shr(avg + 2 * (n1 + f0), 3)
		d03 := simd.shr(avg + 2 * (n0 + f1), 3)
		odd := cast(#simd[8]u8)simd.shr(d12 + n0, 1) // 2k - 1
		even := cast(#simd[8]u8)simd.shr(d03 + n1, 1) // 2k
		both := simd.shuffle(odd, even, 0, 8, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15)
		intrinsics.unaligned_store((^#simd[16]u8)(&out[2 * k - 1]), both)
	}
	for ; k <= pairs; k += 1 {
		n0, n1, f0, f1 := u32(near[k - 1]), u32(near[k]), u32(far[k - 1]), u32(far[k])
		avg := n0 + n1 + f0 + f1 + 8
		d12 := (avg + 2 * (n1 + f0)) >> 3
		d03 := (avg + 2 * (n0 + f1)) >> 3
		out[2 * k - 1] = u8((d12 + n0) >> 1)
		out[2 * k] = u8((d03 + n1) >> 1)
	}
	if width & 1 == 0 {
		last := width >> 1 - 1
		out[width - 1] = u8((3 * u32(near[last]) + u32(far[last]) + 2) >> 2)
	}
}

// BT.601 studio range to RGB with libwebp's constants (multiplications
// keeping the high bits, 6 fractional bits), sixteen pixels at a time in
// 16-bit lanes: high-half multiplies, saturating at 0 where the result
// would be negative, then clamped to 255.
@(private)
convert_row :: proc(y, u, v, a: []u8, dst: []u32) #no_bounds_check {
	W :: #simd[16]u16
	load :: #force_inline proc(s: []u8, at: int) -> W {
		return simd.shl(cast(W)intrinsics.unaligned_load((^#simd[16]u8)(&s[at])), 8)
	}
	// (value * c) >> 8 of the value in the lane's top byte.
	mul_hi :: #force_inline proc(v: W, c: u32) -> W {
		return cast(W)simd.shr(cast(#simd[16]u32)v * c, 16)
	}
	channel :: #force_inline proc(v: W) -> #simd[16]u32 {
		return cast(#simd[16]u32)simd.min(simd.shr(v, 6), 255)
	}
	n := len(dst)
	x := 0
	for ; x + 16 <= n; x += 16 {
		yy := mul_hi(load(y, x), 19077)
		uu, vv := load(u, x), load(v, x)
		r := simd.saturating_sub(yy + mul_hi(vv, 26149), 14234)
		g := simd.saturating_sub(yy + 8708, mul_hi(uu, 6419) + mul_hi(vv, 13320))
		b := simd.saturating_sub(yy + mul_hi(uu, 33050), 17685)
		alpha: #simd[16]u32 = 255
		if a != nil do alpha = cast(#simd[16]u32)intrinsics.unaligned_load((^#simd[16]u8)(&a[x]))
		px := channel(r) | simd.shl(channel(g), 8) | simd.shl(channel(b), 16) | simd.shl(alpha, 24)
		intrinsics.unaligned_store((^#simd[16]u32)(&dst[x]), px)
	}
	for ; x < n; x += 1 {
		yy := (i32(y[x]) * 19077) >> 8
		uu, vv := i32(u[x]), i32(v[x])
		r := clamp((yy + ((vv * 26149) >> 8) - 14234) >> 6, 0, 255)
		g := clamp((yy - ((uu * 6419) >> 8) - ((vv * 13320) >> 8) + 8708) >> 6, 0, 255)
		b := clamp((yy + ((uu * 33050) >> 8) - 17685) >> 6, 0, 255)
		alpha := a != nil ? u32(a[x]) : 255
		dst[x] = u32(r) | u32(g) << 8 | u32(b) << 16 | alpha << 24
	}
}

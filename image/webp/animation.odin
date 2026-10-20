package webp

import "../../common"

// Animated WebP (RFC 9649, "Animation"): frames decoded in order onto a
// canvas, each a rectangle that overwrites or alpha-blends what the previous
// frame left, after that frame's disposal (kept, or cleared to transparent).
// The ANIM background colour is only reported (Features.background), as
// libwebp treats it.
//
//	a: webp.Animation
//	webp.init_animation(&a, data) or_return
//	defer webp.destroy_animation(&a)
//	for _ in 0 ..< a.features.frame_count {
//		frame := webp.next_frame(&a) or_return // frame.pixels: the canvas, until the next call
//	}

Animation :: struct {
	features:  Features,
	frames:    [dynamic]Frame_Chunks,
	next:      int,
	time:      int, // milliseconds, the next frame's start
	canvas:    []u8, // RGBA, the current frame
	disposed:  []u8, // the previous canvas after its frame's disposal
	pool:      ^common.Work_Pool,
	allocator: Allocator,
}

Frame :: struct {
	pixels:   []u8, // the whole canvas, RGBA; owned by the Animation
	start:    int, // milliseconds from the start
	duration: int,
}

init_animation :: proc(a: ^Animation, data: []u8, pool: ^common.Work_Pool = nil, allocator := context.allocator) -> (err: Error) {
	a^ = {pool = pool, allocator = allocator}
	defer if err != .None do destroy_animation(a)
	a.features = get_features(data) or_return
	a.frames.allocator = allocator
	ft := &a.features
	body := riff_body(data) or_return
	if ft.animated {
		rest := body
		for c in next_chunk(&rest) {
			if c.fourcc != "ANMF" || len(c.payload) < 16 do continue
			h := c.payload
			f, found := find_frame(h[16:])
			if !found || !bitstream_size(&f) do return .Invalid
			// The rectangle is the ANMF's; the bitstream must agree.
			f.x, f.y = 2 * le24(h[0:]), 2 * le24(h[3:])
			if le24(h[6:]) + 1 != f.width || le24(h[9:]) + 1 != f.height do return .Invalid
			if f.x + f.width > ft.width || f.y + f.height > ft.height do return .Invalid
			f.duration = le24(h[12:])
			f.blend = h[15] & 2 == 0
			f.dispose = h[15] & 1 != 0
			append(&a.frames, f)
		}
	} else {
		rest := body
		if first, _ := next_chunk(&rest); first.fourcc == "VP8X" do body = rest
		f, found := find_frame(body)
		if !found || !bitstream_size(&f) do return .Invalid
		append(&a.frames, f)
	}
	ft.frame_count = len(a.frames)
	if ft.frame_count == 0 do return .Invalid
	size := ft.width * ft.height * 4
	a.canvas, _ = make([]u8, size, allocator)
	a.disposed, _ = make([]u8, size, allocator)
	if a.canvas == nil || a.disposed == nil do return .Out_Of_Memory
	return .None
}

destroy_animation :: proc(a: ^Animation) {
	delete(a.frames)
	delete(a.canvas, a.allocator)
	delete(a.disposed, a.allocator)
	a^ = {}
}

// Decodes the next frame onto the canvas; past the last it starts over.
next_frame :: proc(a: ^Animation) -> (frame: Frame, err: Error) {
	if a.next == len(a.frames) {
		a.next, a.time = 0, 0
	}
	if a.next == 0 do for &v in a.disposed do v = 0 // the canvas starts transparent
	f := &a.frames[a.next]
	img := decode_frame(f, a.pool, a.allocator) or_return
	defer destroy_image(&img, a.allocator)
	if img.width != f.width || img.height != f.height do return {}, .Invalid
	copy(a.canvas, a.disposed)
	stride := a.features.width * 4
	prev := a.next > 0 ? &a.frames[a.next - 1] : nil
	for y in 0 ..< f.height {
		src := img.pixels[y * f.width * 4:][:f.width * 4]
		dst := a.canvas[(f.y + y) * stride + f.x * 4:][:f.width * 4]
		if !f.blend || a.next == 0 {
			copy(dst, src)
			continue
		}
		cy := f.y + y
		for x in 0 ..< f.width {
			s, d := src[x * 4:][:4], dst[x * 4:][:4]
			cx := f.x + x
			// Where the previous frame was cleared, the canvas is transparent
			// and blending onto it is skipped.
			cleared := prev.dispose && cx >= prev.x && cx < prev.x + prev.width && cy >= prev.y && cy < prev.y + prev.height
			if s[3] == 255 || cleared {
				copy(d, s)
			} else {
				blend_pixel(s, d)
			}
		}
	}
	frame = {a.canvas, a.time, f.duration}
	a.time += f.duration
	copy(a.disposed, a.canvas)
	if f.dispose {
		for y in 0 ..< f.height do for &v in a.disposed[(f.y + y) * stride + f.x * 4:][:f.width * 4] do v = 0
	}
	a.next += 1
	return frame, .None
}

// src over dst, not premultiplied, in libwebp's integer arithmetic; the
// result into dst.
@(private)
blend_pixel :: proc(src, dst: []u8) {
	src_a := u32(src[3])
	if src_a == 0 do return
	dst_factor := (u32(dst[3]) * (256 - src_a)) >> 8
	blend_a := src_a + dst_factor
	scale := (u32(1) << 24) / blend_a
	for c in 0 ..< 3 do dst[c] = u8(((u32(src[c]) * src_a + u32(dst[c]) * dst_factor) * scale) >> 24)
	dst[3] = u8(blend_a)
}

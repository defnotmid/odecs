package gif

import "core:mem"

// An animated GIF frame by frame, on one canvas, composited as browsers do:
// the canvas starts transparent, and each frame is drawn over what the
// previous frame left after its disposal (kept, its rectangle cleared to
// transparent, or restored to what it covered). Browsers ignore the
// background colour, so the animation does too; decode's still keeps
// stb_image's first frame instead (see decode).
//
//	a: gif.Animation
//	gif.init_animation(&a, data) or_return
//	defer gif.destroy_animation(&a)
//	for _ in 0 ..< a.features.frame_count {
//		frame := gif.next_frame(&a) or_return // frame.pixels: the canvas, until the next call
//	}
Animation :: struct {
	using parse: Parse,
	data:        []u8,
	next:        int,
	time:        int, // milliseconds, the next frame's start
	canvas:      []u8, // RGBA, the current frame
	saved:       []u8, // the canvas under the last frame, for a Previous disposal
	indices:     []u8,
	allocator:   mem.Allocator,
}

Frame :: struct {
	pixels:   []u8, // the whole canvas, RGBA; owned by the Animation
	start:    int, // milliseconds from the start
	duration: int,
}

init_animation :: proc(a: ^Animation, data: []u8, allocator := context.allocator) -> (err: Error) {
	a^ = {data = data, allocator = allocator}
	defer if err != .None do destroy_animation(a)
	a.parse = parse(data, allocator) or_return
	n := a.width * a.height
	largest := 0
	for f in a.frames do largest = max(largest, f.width * f.height)
	e1, e2, e3: mem.Allocator_Error
	a.canvas, e1 = make([]u8, n * 4, allocator)
	a.saved, e2 = make([]u8, n * 4, allocator)
	a.indices, e3 = make([]u8, largest, allocator)
	if e1 != nil || e2 != nil || e3 != nil do return .Out_Of_Memory
	return .None
}

destroy_animation :: proc(a: ^Animation) {
	delete(a.frames)
	delete(a.canvas, a.allocator)
	delete(a.saved, a.allocator)
	delete(a.indices, a.allocator)
	a^ = {}
}

// Decodes the next frame onto the canvas; past the last it starts over.
next_frame :: proc(a: ^Animation) -> (frame: Frame, err: Error) {
	if a.next == len(a.frames) {
		a.next, a.time = 0, 0
	}
	if a.next == 0 {
		mem.zero_slice(a.canvas)
	} else {
		dispose(a, &a.frames[a.next - 1])
	}
	f := &a.frames[a.next]
	if f.disposal == .Previous do copy(a.saved, a.canvas)
	indices := a.indices[:f.width * f.height]
	decode_raster(a.data, f, indices) or_return
	draw(a.canvas, a.width, f, indices)
	frame = {a.canvas, a.time, f.delay}
	a.time += f.delay
	a.next += 1
	return frame, .None
}

// The previous frame's disposal, on its rectangle.
@(private)
dispose :: proc(a: ^Animation, f: ^Frame_Record) {
	if f.disposal == .Keep do return
	stride := a.width * 4
	for y in f.y ..< f.y + f.height {
		at := y * stride + f.x * 4
		row := a.canvas[at:][:f.width * 4]
		switch f.disposal {
		case .Keep:
		case .Background:
			mem.zero_slice(row)
		case .Previous:
			copy(row, a.saved[at:][:f.width * 4])
		}
	}
}

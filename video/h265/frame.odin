package h265

// A picture sample. Planes always store 16-bit samples; the picture's bit
// depth bounds the values that can be present.
Sample :: u16

// A pixel or coefficient plane. `offset` is the index of sample (0, 0) and
// `stride` the distance between rows, so negative coordinates address the
// one-sample border when present.
Plane :: struct($T: typeid) {
	data:   []T,
	stride: int,
	offset: int,
}

at :: #force_inline proc(p: Plane($T), x, y: int) -> T #no_bounds_check {
	return p.data[p.offset + y * p.stride + x]
}

set_at :: #force_inline proc(p: Plane($T), x, y: int, v: T) #no_bounds_check {
	p.data[p.offset + y * p.stride + x] = v
}

// A decoded/encoded picture. The coded size is rounded up to the minimum CU
// size; the conformance window in the SPS hides the padding.
Frame :: struct {
	y:            Plane(Sample),
	u:            Plane(Sample),
	v:            Plane(Sample),
	width:        int,
	height:       int,
	coded_width:  int,
	coded_height: int,
}

alloc_plane :: proc(
	$T: typeid,
	width, height, border: int,
	allocator := context.allocator,
) -> Plane(T) {
	stride := width + 2 * border
	data := make([]T, stride * (height + 2 * border), allocator)
	return Plane(T){data = data, stride = stride, offset = border * stride + border}
}

free_plane :: proc(p: ^Plane($T)) {
	delete(p.data)
	p^ = {}
}

alloc_frame :: proc(
	width, height: int,
	luma_border := 1,
	allocator := context.allocator,
	chroma: Chroma_Format = .YUV_420,
) -> Frame {
	frame: Frame
	frame.width = width
	frame.height = height
	frame.coded_width = (width + 7) / 8 * 8
	frame.coded_height = (height + 7) / 8 * 8
	frame.y = alloc_plane(Sample, frame.coded_width, frame.coded_height, luma_border, allocator)

	// Monochrome has no chroma planes; the other formats size theirs by the
	// subsampling.
	if chroma != .Monochrome {
		sub_w := chroma == .YUV_444 ? 1 : 2
		sub_h := chroma == .YUV_420 ? 2 : 1
		frame.u = alloc_plane(
			Sample,
			frame.coded_width / sub_w,
			frame.coded_height / sub_h,
			luma_border,
			allocator,
		)
		frame.v = alloc_plane(
			Sample,
			frame.coded_width / sub_w,
			frame.coded_height / sub_h,
			luma_border,
			allocator,
		)
	}

	return frame
}

free_frame :: proc(frame: ^Frame) {
	free_plane(&frame.y)
	free_plane(&frame.u)
	free_plane(&frame.v)
	frame^ = {}
}

fill_frame :: proc(frame: ^Frame, value: Sample) #no_bounds_check {
	for i in 0 ..< len(frame.y.data) do frame.y.data[i] = value
	for i in 0 ..< len(frame.u.data) do frame.u.data[i] = value
	for i in 0 ..< len(frame.v.data) do frame.v.data[i] = value
}

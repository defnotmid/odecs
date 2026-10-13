package h264

// Allocate a contiguous padded YUV420 frame buffer
alloc_yuv_buffer :: proc(width, height: int, allocator := context.allocator) -> YUV_Buffer {
	memory := make([]u8, yuv_buffer_size(width, height), allocator)
	buf := yuv_buffer_view(width, height, raw_data(memory))
	buf.memory = memory
	return buf
}

yuv_buffer_size :: proc(width, height: int) -> int {
	pad := PADDING_LENGTH
	return (height + pad * 2) * (width + pad * 2) + 2 * (height / 2 + pad) * (width / 2 + pad)
}

// A borrowed view; the allocation owner controls its lifetime.
yuv_buffer_view :: proc(width, height: int, mem_buf: [^]u8) -> YUV_Buffer {
	pad := PADDING_LENGTH
	y_stride := width + pad * 2
	y_size := (height + pad * 2) * y_stride
	uv_stride := (width / 2) + pad
	uv_size := (height / 2 + pad) * uv_stride
	return YUV_Buffer {
		width = width,
		height = height,
		coded_width = width,
		coded_height = height,
		y_stride = y_stride,
		uv_stride = uv_stride,
		y = &mem_buf[pad * y_stride + pad],
		u = &mem_buf[y_size + (pad / 2) * uv_stride + pad / 2],
		v = &mem_buf[y_size + uv_size + (pad / 2) * uv_stride + pad / 2],
	}
}

free_yuv_buffer :: proc(buf: ^YUV_Buffer) {
	if buf.memory != nil do delete(buf.memory)
	buf^ = {}
}

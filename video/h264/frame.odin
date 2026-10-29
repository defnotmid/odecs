package h264

// Sample layout of a frame buffer; the zero value is 8-bit 4:2:0.
Buffer_Format :: struct {
	chroma_422: bool,
	high_depth: bool, // u16 samples
	chroma_444: bool,
	monochrome: bool,
}

// Allocate a contiguous padded frame buffer
alloc_yuv_buffer :: proc(width, height: int, allocator := context.allocator, format := Buffer_Format{}) -> YUV_Buffer {
	memory := make([]u8, yuv_buffer_size(width, height, format), allocator)
	buf := yuv_buffer_view(width, height, raw_data(memory), format)
	buf.memory = memory
	return buf
}

yuv_buffer_size :: proc(width, height: int, format := Buffer_Format{}) -> int {
	pad := PADDING_LENGTH
	y_samples := (height + pad * 2) * (width + pad * 2)
	if format.monochrome {
		return format.high_depth ? 2 * y_samples : y_samples
	}
	cpad := format.chroma_444 ? pad * 2 : pad
	chroma_width := format.chroma_444 ? width : width / 2
	chroma_height := (format.chroma_422 || format.chroma_444) ? height : height / 2
	samples := y_samples + 2 * (chroma_height + cpad) * (chroma_width + cpad)
	return format.high_depth ? 2 * samples : samples
}

// A borrowed view; the allocation owner controls its lifetime.
yuv_buffer_view :: proc(width, height: int, mem_buf: [^]u8, format := Buffer_Format{}) -> YUV_Buffer {
	pad := PADDING_LENGTH
	size := format.high_depth ? 2 : 1
	y_stride := width + pad * 2
	y_size := (height + pad * 2) * y_stride
	if format.monochrome {
		return YUV_Buffer {
			width = width,
			height = height,
			coded_width = width,
			coded_height = height,
			y_stride = y_stride,
			uv_stride = 0,
			high_depth = format.high_depth,
			monochrome = true,
			y = &mem_buf[(pad * y_stride + pad) * size],
			u = nil,
			v = nil,
		}
	}
	cpad := format.chroma_444 ? pad : pad / 2
	chroma_width := format.chroma_444 ? width : width / 2
	chroma_height := (format.chroma_422 || format.chroma_444) ? height : height / 2
	uv_stride := chroma_width + cpad * 2
	uv_size := (chroma_height + cpad * 2) * uv_stride
	return YUV_Buffer {
		width = width,
		height = height,
		coded_width = width,
		coded_height = height,
		y_stride = y_stride,
		uv_stride = uv_stride,
		chroma_422 = format.chroma_422,
		high_depth = format.high_depth,
		chroma_444 = format.chroma_444,
		monochrome = false,
		y = &mem_buf[(pad * y_stride + pad) * size],
		u = &mem_buf[(y_size + cpad * uv_stride + cpad) * size],
		v = &mem_buf[(y_size + uv_size + cpad * uv_stride + cpad) * size],
	}
}

free_yuv_buffer :: proc(buf: ^YUV_Buffer) {
	if buf.memory != nil do delete(buf.memory)
	buf^ = {}
}

// The planes of a buffer as samples of type T (u8, or u16 when high_depth).
buffer_planes :: #force_inline proc "contextless" ($T: typeid, buf: ^YUV_Buffer) -> (y, u, v: [^]T) {
	return ([^]T)(buf.y), ([^]T)(buf.u), ([^]T)(buf.v)
}

// Chroma rows of the coded picture.
chroma_rows :: #force_inline proc "contextless" (buf: ^YUV_Buffer) -> int {
	if buf.monochrome do return 0
	return (buf.chroma_422 || buf.chroma_444) ? buf.coded_height : buf.coded_height / 2
}

// Chroma columns of the coded picture.
chroma_cols :: #force_inline proc "contextless" (buf: ^YUV_Buffer) -> int {
	if buf.monochrome do return 0
	return buf.chroma_444 ? buf.coded_width : buf.coded_width / 2
}

// Index in Macroblock.nonzero_coefficient_counts of chroma 4x4 block `block`
// (raster order, two per row) of plane 0 (Cb) or 1 (Cr): 4:2:0 uses the
// first 4 Cb and 4 Cr entries, and 4:2:2's lower 8x8 follows them.
chroma_count_index :: #force_inline proc "contextless" (plane, block: int) -> int {
	return 16 + (block >> 2) * 8 + plane * 4 + (block & 3)
}

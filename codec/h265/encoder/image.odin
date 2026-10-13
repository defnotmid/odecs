package h265_encoder

// ---------------------------------------------------------------------------
// CTU region save/restore for search rollback.
// ---------------------------------------------------------------------------

MAX_CTU_PIXELS :: CTU_WIDTH * CTU_WIDTH
// A chroma plane reaches a full CTU at 4:4:4 and half of one at 4:2:2, so
// the region buffers cover the full CTU area.
MAX_CTU_CHROMA_PIXELS :: MAX_CTU_PIXELS

Region :: struct {
	y: [MAX_CTU_PIXELS]Sample,
	u: [MAX_CTU_CHROMA_PIXELS]Sample,
	v: [MAX_CTU_CHROMA_PIXELS]Sample,
}

save_region :: proc(frame: ^Frame, x, y, width: int, out: ^Region, layout: Chroma_Layout) {
	sw, sh := chroma_sub(layout)
	cw := width / sw
	ch := width / sh
	for row in 0 ..< width {
		copy(
			out.y[row * width:row * width + width],
			frame.y.data[frame.y.offset + (y + row) * frame.y.stride + x:],
		)
	}
	// A monochrome frame has no chroma planes to save. The chroma region is
	// the luma one scaled by the subsampling: half the rows at 4:2:0, full
	// rows at 4:2:2, full rows and columns at 4:4:4.
	if len(frame.u.data) > 0 {
		for row in 0 ..< ch {
			copy(
				out.u[row * cw:row * cw + cw],
				frame.u.data[frame.u.offset + (y / sh + row) * frame.u.stride + x / sw:],
			)
			copy(
				out.v[row * cw:row * cw + cw],
				frame.v.data[frame.v.offset + (y / sh + row) * frame.v.stride + x / sw:],
			)
		}
	}
}

restore_region :: proc(frame: ^Frame, x, y, width: int, saved: ^Region, layout: Chroma_Layout) {
	sw, sh := chroma_sub(layout)
	cw := width / sw
	ch := width / sh
	for row in 0 ..< width {
		copy(
			frame.y.data[frame.y.offset + (y + row) * frame.y.stride + x:],
			saved.y[row * width:row * width + width],
		)
	}
	if len(frame.u.data) > 0 {
		for row in 0 ..< ch {
			copy(
				frame.u.data[frame.u.offset + (y / sh + row) * frame.u.stride + x / sw:],
				saved.u[row * cw:row * cw + cw],
			)
			copy(
				frame.v.data[frame.v.offset + (y / sh + row) * frame.v.stride + x / sw:],
				saved.v[row * cw:row * cw + cw],
			)
		}
	}
}

// Hardware H.264 and HEVC decoding through Apple's VideoToolbox.
//
// The native parsers (codec/h264/decoder, codec/h265/decoder) find picture
// boundaries, derive picture order and decide when each picture is shown;
// VideoToolbox only decodes whole pictures, handed over one at a time as
// length-prefixed NAL units. Its output (NV12, or P010 at 10 bits) is copied
// into planar 4:2:0 frames. Only the session (session_darwin.odin) is
// Apple-specific: elsewhere it reports .Unavailable.
package videotoolbox

Error :: enum {
	None,
	Invalid_Argument,
	Unsupported,
	Unavailable,
	Decoder_Error, // VideoToolbox refused or failed; the session's status says why
	Encoder_Error, // likewise for encoding
}

Codec :: enum {
	H264,
	HEVC,
}

// A decoded picture, planar 4:2:0: 8-bit samples in bytes, or 10-bit
// samples in the low bits of little-endian u16 (storage_bits 16). Planes
// start at the visible origin; crop_x/crop_y say where that is in the coded
// picture.
Frame :: struct {
	width, height, bit_depth, storage_bits: int,
	coded_width, coded_height:              int,
	crop_x, crop_y:                         int,
	poc:                                    int,
	planes:                                 [3][]u8,
	strides:                                [3]int,
}
// Receives each picture in display order. The frame is borrowed until it returns.
Receiver :: #type proc(frame: Frame, user: rawptr)

// Whole pictures are at most this large (128 MiB).
MAX_PICTURE_BYTES :: 128 << 20
// A format description holds at most an SPS and 256 PPSs (H.264), or a VPS,
// an SPS and 64 PPSs (HEVC).
MAX_PARAMETER_SETS :: 1 + 256

// What both decoders share: the session, the picture being assembled, and
// decoded pictures waiting for their turn to be shown, in decode order.
@(private)
Pictures :: struct {
	session: Session,
	sample:  [dynamic]u8, // the picture being assembled: 4-byte big-endian lengths, then NAL units
	held:    [dynamic]Held,
	spare:   [dynamic][]u8, // buffers of shown pictures, reused while the size stays the same
}
@(private)
Held :: struct {
	frame: Frame,
	data:  []u8,
	id:    i64, // what the parser knows the picture by: H.264 pic_id, HEVC POC
}

@(private)
append_nal :: proc(p: ^Pictures, nal: []u8) -> Error {
	if len(nal) > MAX_PICTURE_BYTES - 4 - len(p.sample) do return .Unsupported
	n := u32(len(nal))
	append(&p.sample, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
	append(&p.sample, ..nal)
	return .None
}

// Decodes the assembled picture into a held frame of the given shape.
@(private)
decode_picture :: proc(p: ^Pictures, frame: Frame, id: i64) -> Error {
	defer clear(&p.sample)
	f := frame
	b := f.storage_bits / 8
	cw, ch := (f.width + 1) / 2, (f.height + 1) / 2
	f.strides = {f.width * b, cw * b, cw * b}
	luma, chroma := f.strides[0] * f.height, f.strides[1] * ch
	data: []u8
	for len(p.spare) > 0 && data == nil {
		buffer := pop(&p.spare)
		if len(buffer) == luma + 2 * chroma {data = buffer} else {delete(buffer)}
	}
	if data == nil do data = make([]u8, luma + 2 * chroma)
	f.planes = {data[:luma], data[luma:][:chroma], data[luma + chroma:][:chroma]}
	if err := session_decode(&p.session, p.sample[:], &f); err != .None {
		append(&p.spare, data)
		return err
	}
	append(&p.held, Held{f, data, id})
	return .None
}

@(private)
show :: proc(p: ^Pictures, index: int, receiver: Receiver, user: rawptr) {
	h := p.held[index]
	ordered_remove(&p.held, index)
	if receiver != nil do receiver(h.frame, user)
	append(&p.spare, h.data)
}

@(private)
discard :: proc(p: ^Pictures, index: int) {
	append(&p.spare, p.held[index].data)
	ordered_remove(&p.held, index)
}

@(private)
destroy_pictures :: proc(p: ^Pictures) {
	session_destroy(&p.session)
	for h in p.held do delete(h.data)
	for buffer in p.spare do delete(buffer)
	delete(p.held)
	delete(p.spare)
	delete(p.sample)
	p^ = {}
}

// Copies the visible area of a semi-planar picture (NV12, or P010 with
// samples in the high bits of each u16) into f's planar buffers. (crop_x,
// crop_y) is the visible origin in the source, even as 4:2:0 requires.
copy_semi_planar :: proc(f: ^Frame, y_plane: []u8, y_stride: int, uv_plane: []u8, uv_stride: int, crop_x, crop_y: int) {
	w, h := f.width, f.height
	cw, ch := (w + 1) / 2, (h + 1) / 2
	cx, cy := crop_x / 2, crop_y / 2
	if f.storage_bits == 8 {
		for row in 0 ..< h {
			copy(f.planes[0][row * f.strides[0]:][:w], y_plane[(crop_y + row) * y_stride + crop_x:][:w])
		}
		for row in 0 ..< ch {
			src := uv_plane[(cy + row) * uv_stride + 2 * cx:][:2 * cw]
			u := f.planes[1][row * f.strides[1]:][:cw]
			v := f.planes[2][row * f.strides[2]:][:cw]
			for x in 0 ..< cw {
				u[x], v[x] = src[2 * x], src[2 * x + 1]
			}
		}
		return
	}
	shift := u16(16 - f.bit_depth)
	for row in 0 ..< h {
		src := samples16(y_plane[(crop_y + row) * y_stride + 2 * crop_x:][:2 * w])
		dst := samples16(f.planes[0][row * f.strides[0]:][:2 * w])
		for x in 0 ..< w do dst[x] = src[x] >> shift
	}
	for row in 0 ..< ch {
		src := samples16(uv_plane[(cy + row) * uv_stride + 4 * cx:][:4 * cw])
		u := samples16(f.planes[1][row * f.strides[1]:][:2 * cw])
		v := samples16(f.planes[2][row * f.strides[2]:][:2 * cw])
		for x in 0 ..< cw {
			u[x], v[x] = src[2 * x] >> shift, src[2 * x + 1] >> shift
		}
	}
}

// Little-endian u16 samples in an even-aligned byte slice (both Apple
// silicon and the copies' destinations are little-endian and aligned).
@(private)
samples16 :: #force_inline proc(bytes: []u8) -> []u16 {
	return ([^]u16)(raw_data(bytes))[:len(bytes) / 2]
}

// Hardware encoding: progressive 8-bit 4:2:0 in BT.709 limited range, I and P
// pictures only (no reordering), so each frame in gives its packet out.
Encoder_Config :: struct {
	codec:             Codec,
	width, height:     int,
	qp:                int, // 1..51, held constant through the frame QP limits
	keyframe_interval: int, // frames from one keyframe to the next
}

// The chroma of a picture to encode: U and V planes, or interleaved UV
// (NV12, VideoToolbox's own layout) in planes[0].
Encoder_Chroma :: struct {
	planes:      [2][]u8,
	strides:     [2]int,
	interleaved: bool,
}

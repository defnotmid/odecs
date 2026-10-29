#+build !darwin
package media_videotoolbox

// VideoToolbox exists only on Apple platforms.
Session :: struct {
	status:           i32,
	pixel_format:     u32,
	require_hardware: bool,
}

hardware_decode_supported :: proc(codec: Codec) -> bool {
	return false
}

session_set_format :: proc(s: ^Session, codec: Codec, parameter_sets: [][]u8, bit_depth: int, full_range: bool) -> Error {
	return .Unavailable
}

session_decode :: proc(s: ^Session, sample: []u8, f: ^Frame) -> Error {
	return .Unavailable
}

session_destroy :: proc(s: ^Session) {
	s^ = {}
}

Encoder :: struct {
	status:  i32,
	qp_held: bool,
}

encoder_create :: proc(e: ^Encoder, config: Encoder_Config) -> Error {
	return .Unavailable
}

encoder_encode :: proc(e: ^Encoder, y: []u8, y_stride: int, chroma: Encoder_Chroma) -> (packet: []u8, keyframe: bool, err: Error) {
	return nil, false, .Unavailable
}

encoder_destroy :: proc(e: ^Encoder) {
	e^ = {}
}

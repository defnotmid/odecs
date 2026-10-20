package media

import "core:testing"

@(private)
Bound_Provider_State :: struct {
	probes, opens, closes: int,
	return_busy:           bool,
}

@(test)
test_provider_binding_and_busy_retry :: proc(t: ^testing.T) {
	probe_bound :: proc(config: Config, user: rawptr) -> Error {
		if user == nil do return .Invalid_Config
		(^Bound_Provider_State)(user).probes += 1
		return .None
	}
	decode_bound :: proc(session: ^Session, packet: Packet, receiver: Receiver) -> Error {
		return (^Bound_Provider_State)(session.state).return_busy ? .Busy : .None
	}
	drain_bound :: proc(session: ^Session, receiver: Receiver) -> Error {
		return (^Bound_Provider_State)(session.state).return_busy ? .Busy : .None
	}
	close_bound :: proc(session: ^Session) {(^Bound_Provider_State)(session.state).closes += 1}
	open_bound :: proc(session: ^Session, config: Config, user: rawptr) -> Error {
		(^Bound_Provider_State)(user).opens += 1
		session.state = user
		session.decode_impl, session.drain_impl, session.close_impl =
			decode_bound, drain_bound, close_bound
		return .None
	}
	bound: Bound_Provider_State
	providers := []Provider {
		{backend = .Vulkan, user = &bound, probe = probe_bound, open = open_bound},
	}
	cfg := default_config(.H264, .Decode)
	cfg.preference = .Require_Hardware
	session: Session
	testing.expect_value(t, open(&session, cfg, providers), Error.None)
	testing.expect(t, bound.probes == 1 && bound.opens == 1 && session.state == &bound)
	byte := [1]u8{1}
	bound.return_busy = true
	testing.expect_value(t, decode(&session, {data = byte[:], framing = .NAL}, {}), Error.Busy)
	testing.expect(t, !session.failed && !session.busy)
	testing.expect_value(t, drain(&session, {}), Error.Busy)
	testing.expect(t, !session.failed && !session.ended && !session.busy)
	bound.return_busy = false
	testing.expect_value(t, decode(&session, {data = byte[:], framing = .NAL}, {}), Error.None)
	testing.expect_value(t, drain(&session, {}), Error.None)
	testing.expect_value(t, close(&session), Error.None)
	testing.expect(t, bound.closes == 1)
}

@(test)
test_provider_cannot_admit_an_unimplemented_operation :: proc(t: ^testing.T) {
	probe_ok :: proc(config: Config, user: rawptr) -> Error {return .None}
	close_dummy :: proc(session: ^Session) {free((^u8)(session.state))}
	drain_dummy :: proc(session: ^Session, receiver: Receiver) -> Error {return .None}
	open_incomplete :: proc(session: ^Session, config: Config, user: rawptr) -> Error {
		session.state = new(u8)
		session.close_impl = close_dummy
		session.drain_impl = drain_dummy
		return .None
	}
	providers := []Provider {
		{backend = .Vulkan, name = "incomplete", probe = probe_ok, open = open_incomplete},
	}
	session: Session
	config := default_config(.H265, .Decode)
	config.preference = .Require_Hardware
	testing.expect_value(t, open(&session, config, providers), Error.Invalid_Config)
	testing.expect_value(t, session.state, rawptr(nil))
	testing.expect_value(t, close(&session), Error.None)
}

@(test)
test_plane_geometry_rejects_overflow_and_short_buffers :: proc(t: ^testing.T) {
	bytes: [16]u8
	frame := Video_Frame {
		width        = 4,
		height       = 4,
		bit_depth    = 8,
		storage_bits = 8,
		chroma       = .Monochrome,
		planes       = {{bytes[:], 4}, {}, {}},
	}
	testing.expect_value(t, validate_frame(frame), Error.None)
	frame.planes[0].data = bytes[:15]
	testing.expect_value(t, validate_frame(frame), Error.Invalid_Input)
	frame.planes[0] = {bytes[:], max(int)}
	testing.expect_value(t, validate_frame(frame), Error.Invalid_Input)
	frame.width, frame.height, frame.storage_bits = max(int), 1, 16
	testing.expect_value(t, validate_frame(frame), Error.Invalid_Input)
	frame.width, frame.height, frame.chroma, frame.storage_bits = max(int), max(int), .YUV420, 8
	testing.expect_value(t, validate_frame(frame), Error.Invalid_Input)
}

@(test)
test_no_reordering_is_a_decode_assertion :: proc(t: ^testing.T) {
	decode := default_config(.H264, .Decode)
	decode.no_reordering = true
	testing.expect_value(t, validate_config(decode), Error.None)
	encode := default_config(.H264, .Encode)
	encode.width, encode.height = 64, 64
	encode.no_reordering = true
	testing.expect_value(t, validate_config(encode), Error.Invalid_Config)
}

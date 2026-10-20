package media_vulkan

import "core:mem"
import "core:slice"
import "core:testing"

// These test the host publication owner, without Vulkan handles or fabricated
// driver results. Hardware tests separately cover the encoded body producer.
@(test)
packet_publication_preserves_exact_spans_and_owned_independence :: proc(t: ^testing.T) {
	headers := [6]u8{0xC1, 0, 0, 1, 0x67, 0xC2}
	body := [7]u8{0xD1, 0, 0, 1, 0x65, 0xA7, 0xD2}
	want_headers, want_body := headers, body
	e: Encoder
	defer destroy_encoder(&e)
	owned, error := publish_encoded_packet(headers[1:5], body[1:6], nil)
	testing.expect_value(t, error, Error.None)
	defer delete(owned)
	testing.expect(t, slice.equal(owned, []u8{0, 0, 1, 0x67, 0, 0, 1, 0x65, 0xA7}))
	borrowed, borrowed_error := publish_encoded_packet(headers[1:5], body[1:6], &e.packet_buffer)
	testing.expect_value(t, borrowed_error, Error.None)
	testing.expect(t, slice.equal(borrowed, owned))
	testing.expect(t, raw_data(borrowed) == raw_data(e.packet_buffer))
	testing.expect(t, raw_data(owned) != raw_data(borrowed))
	// Only the requested source spans are consumed; neither source nor its
	// preceding/following guards is written during either publication mode.
	testing.expect(t, headers == want_headers && body == want_body)
	borrowed[0] = 0x99
	testing.expect_value(t, owned[0], u8(0))
	packet, packet_error := publish_encoded_packet(nil, []u8{0x31, 0x32}, &e.packet_buffer)
	testing.expect_value(t, packet_error, Error.None)
	testing.expect(t, slice.equal(packet, []u8{0x31, 0x32}))
	testing.expect(t, slice.equal(owned, []u8{0, 0, 1, 0x67, 0, 0, 1, 0x65, 0xA7}))
}

@(test)
packet_publication_retains_capacity_and_releases_encoder_storage :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		e: Encoder
		headers := [4]u8{0, 0, 1, 0x67}
		body: [64]u8
		for &b, i in body do b = u8(i + 1)
		packet, error := publish_encoded_packet(headers[:], body[:], &e.packet_buffer)
		testing.expect_value(t, error, Error.None)
		testing.expect_value(t, len(packet), 68)
		warm_allocations := track.total_allocation_count
		buffer, capacity := raw_data(e.packet_buffer), cap(e.packet_buffer)
		for frame in 0 ..< 37 {
			span := 1 + frame % len(body)
			body[0] = u8(frame + 10)
			prefix: []u8
			if frame % 15 == 0 do prefix = headers[:]
			packet, error = publish_encoded_packet(prefix, body[:span], &e.packet_buffer)
			testing.expect_value(t, error, Error.None)
			testing.expect_value(t, len(packet), len(prefix) + span)
			testing.expect(t, slice.equal(packet[:len(prefix)], prefix))
			testing.expect(t, slice.equal(packet[len(prefix):], body[:span]))
			testing.expect(
				t,
				raw_data(e.packet_buffer) == buffer && cap(e.packet_buffer) == capacity,
			)
		}
		testing.expect_value(t, track.total_allocation_count, warm_allocations)
		// Owned publication allocates independently and does not overwrite or
		// resize a borrowed packet from the same encoder.
		last := [2]u8{packet[0], packet[len(packet) - 1]}
		owned, owned_error := publish_encoded_packet(headers[:], body[:], nil)
		testing.expect_value(t, owned_error, Error.None)
		testing.expect_value(t, track.total_allocation_count, warm_allocations + 1)
		testing.expect(t, raw_data(owned) != buffer && raw_data(e.packet_buffer) == buffer)
		testing.expect(t, packet[0] == last[0] && packet[len(packet) - 1] == last[1])
		delete(owned)
		destroy_encoder(&e)
		testing.expect(
			t,
			raw_data(e.packet_buffer) == nil &&
			len(e.packet_buffer) == 0 &&
			cap(e.packet_buffer) == 0,
		)
		testing.expect_value(t, track.current_memory_allocated, i64(0))
		testing.expect_value(t, len(track.allocation_map), 0)
	}
}

@(test)
borrowed_encode_invalid_inputs_return_no_packet_without_loading :: proc(t: ^testing.T) {
	e: Encoder
	packet, error := encode_frame_borrowed(&e, {}, {}, {})
	testing.expect_value(t, error, Error.Invalid_Argument)
	testing.expect(t, packet == nil)
	packet, error = encode_frame16_borrowed(&e, {}, {}, {})
	testing.expect_value(t, error, Error.Invalid_Argument)
	testing.expect(t, packet == nil)
	packet, error = encode_surface_borrowed(&e, {}, 0, 0)
	testing.expect_value(t, error, Error.Invalid_Argument)
	testing.expect(
		t,
		packet == nil && raw_data(e.packet_buffer) == nil && !e.initialized && !e.failed,
	)
}

@(test)
packet_publication_reports_allocation_failure_in_both_modes :: proc(t: ^testing.T) {
	body := [4]u8{0, 0, 1, 0x65}
	{
		context.allocator = mem.nil_allocator()
		owned, owned_error := publish_encoded_packet(nil, body[:], nil)
		testing.expect_value(t, owned_error, Error.Out_Of_Memory)
		testing.expect(t, owned == nil)
		retained := make([dynamic]u8, mem.nil_allocator())
		borrowed, borrowed_error := publish_encoded_packet(nil, body[:], &retained)
		testing.expect_value(t, borrowed_error, Error.Out_Of_Memory)
		testing.expect(t, borrowed == nil && len(retained) == 0)
		delete(retained)
	}
}

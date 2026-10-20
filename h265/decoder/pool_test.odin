package h265_decoder

import enc "../encoder"
import "core:mem"
import "core:slice"
import "core:testing"

@(private = "file")
pool_stream :: proc(w, h, frames: int, b_frames: bool) -> [dynamic]u8 {
	e: enc.Encoder
	enc.init_encoder(
		&e,
		{
			width = w,
			height = h,
			qp = 30,
			forced_mode = -1,
			deblock = true,
			sao = true,
			refs = 2,
			tmvp = true,
			b_frames = b_frames,
			gop_size = 4,
		},
	)
	defer enc.destroy_encoder(&e)
	stream := make([dynamic]u8)
	y := make([]enc.Sample, w * h)
	c := make([]enc.Sample, w * h / 4)
	defer delete(y)
	defer delete(c)
	for f in 0 ..< frames {
		for i in 0 ..< len(y) do y[i] = enc.Sample((i * 7 + (i / w) * 3 + f * 5) & 255)
		for i in 0 ..< len(c) do c[i] = enc.Sample((i * 3 + f * 9) & 255)
		enc.encode_frame(&e, raw_data(y), raw_data(c), raw_data(c), w, w / 2, &stream)
	}
	enc.flush_encoder(&e, &stream)
	return stream
}

// Decodes every NAL into one decoder, releasing output immediately, and
// checks it against an independent whole-stream reference.
@(private = "file")
pool_decode :: proc(t: ^testing.T, d: ^Decoder, stream: []u8, seen: ^map[^Picture]bool) -> int {
	reference, good := decode_annex_b(stream)
	testing.expect(t, good)
	defer {
		for p in reference {
			destroy_picture(p)
			free(p)
		}
		delete(reference)
	}
	nals := split_annex_b(stream)
	defer {
		for &n in nals do destroy_nal(&n)
		delete(nals)
	}
	out: [dynamic]^Picture
	defer delete(out)
	count := 0
	check :: proc(t: ^testing.T, p: ^Picture, reference: [dynamic]^Picture, count: int) {
		if !testing.expect(t, count < len(reference)) do return
		want := reference[count]
		testing.expect_value(t, p.poc, want.poc)
		testing.expect(t, slice.equal(p.y, want.y))
		testing.expect(t, slice.equal(p.u, want.u))
		testing.expect(t, slice.equal(p.v, want.v))
	}
	for n in nals {
		testing.expect(t, decode_nal(d, n, &out))
		for p in out {
			check(t, p, reference, count)
			seen[p] = true
			testing.expect(t, release_picture(d, p))
			count += 1
		}
		clear(&out)
	}
	testing.expect(t, flush_decoder(d, &out))
	for p in out {
		check(t, p, reference, count)
		seen[p] = true
		testing.expect(t, release_picture(d, p))
		count += 1
	}
	testing.expect_value(t, count, len(reference))
	return count
}

@(test)
test_picture_backing_is_reused_across_pictures :: proc(t: ^testing.T) {
	stream := pool_stream(32, 32, 48, true)
	defer delete(stream)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		d: Decoder
		init_decoder(&d)
		seen := make(map[^Picture]bool)
		count := pool_decode(t, &d, stream[:], &seen)
		// Forty-eight outputs come from a handful of retained slots.
		testing.expect_value(t, count, 48)
		testing.expectf(t, len(seen) <= 8, "%d distinct pictures", len(seen))
		testing.expect_value(t, len(d.pictures), len(seen))
		delete(seen)
		destroy_decoder(&d)
	}
	testing.expect_value(t, track.current_memory_allocated, i64(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_geometry_change_replaces_spare_backing :: proc(t: ^testing.T) {
	small := pool_stream(16, 16, 9, false)
	large := pool_stream(32, 16, 9, true)
	defer delete(small)
	defer delete(large)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		d: Decoder
		init_decoder(&d)
		seen := make(map[^Picture]bool)
		pool_decode(t, &d, small[:], &seen)
		pool_decode(t, &d, large[:], &seen)
		pool_decode(t, &d, small[:], &seen)
		// Spares of a previous geometry are freed rather than accumulated.
		for p in d.pictures do testing.expect_value(t, len(p.y), 16 * 16)
		delete(seen)
		destroy_decoder(&d)
	}
	testing.expect_value(t, track.current_memory_allocated, i64(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_pooled_output_outlives_decoder :: proc(t: ^testing.T) {
	stream := pool_stream(16, 16, 6, false)
	defer delete(stream)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		d: Decoder
		init_decoder(&d)
		nals := split_annex_b(stream[:])
		held: [dynamic]^Picture
		for n in nals do testing.expect(t, decode_nal(&d, n, &held))
		testing.expect(t, flush_decoder(&d, &held))
		testing.expect_value(t, len(held), 6)
		// Releasing one first sends its backing to the spare set.
		testing.expect(t, release_picture(&d, held[0]))
		destroy_decoder(&d)
		for p in held[1:] {
			testing.expect_value(t, p.owner, (^Decoder)(nil))
			testing.expect_value(t, p.decoder, (^Decoder)(nil))
			testing.expect(t, release_picture(nil, p))
		}
		delete(held)
		for &n in nals do destroy_nal(&n)
		delete(nals)
	}
	testing.expect_value(t, track.current_memory_allocated, i64(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

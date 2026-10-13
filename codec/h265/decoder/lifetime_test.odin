package h265_decoder

import enc "../encoder"
import "core:mem"
import "core:slice"
import "core:testing"

@(test)
test_streaming_release_preserves_references_and_bounds_memory :: proc(t: ^testing.T) {
	frames :: 96
	for mode in 0 ..< 3 {
		e: enc.Encoder
		enc.init_encoder(
			&e,
			{
				width = 16,
				height = 16,
				qp = 26,
				forced_mode = -1,
				deblock = true,
				sao = true,
				refs = 2,
				tmvp = true,
				b_frames = mode == 1,
				hierarchical = mode == 2,
				gop_size = 4,
			},
		)
		stream := make([dynamic]u8)
		for f in 0 ..< frames {
			y: [16 * 16]enc.Sample
			c: [8 * 8]enc.Sample
			for i in 0 ..< len(y) do y[i] = enc.Sample((i * 13 + f * 7) & 255)
			for i in 0 ..< len(c) do c[i] = enc.Sample((i * 5 + f * 11) & 255)
			enc.encode_frame(&e, raw_data(y[:]), raw_data(c[:]), raw_data(c[:]), 16, 8, &stream)
		}
		enc.flush_encoder(&e, &stream)
		enc.destroy_encoder(&e)
		defer delete(stream)

		// Keep a whole-stream reference while streaming releases each frame as
		// soon as it is displayed, including pictures still needed by prediction.
		reference, good := decode_annex_b(stream[:])
		testing.expect(t, good && len(reference) == frames)
		defer {
			for p in reference {
				destroy_picture(p)
				free(p)
			}
			delete(reference)
		}
		if !good || len(reference) != frames do continue
		nals := split_annex_b(stream[:])
		defer {
			for &n in nals do destroy_nal(&n)
			delete(nals)
		}

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		{
			context.allocator = mem.tracking_allocator(&track)
			d: Decoder
			init_decoder(&d)
			out: [dynamic]^Picture
			count, released_references := 0, 0
			warm_peak: i64
			for n in nals {
				testing.expect(t, decode_nal(&d, n, &out))
				for p in out {
					testing.expect(t, count < frames)
					if count < frames {
						want := reference[count]
						testing.expect_value(t, p.poc, want.poc)
						testing.expect(t, slice.equal(p.y, want.y))
						testing.expect(t, slice.equal(p.u, want.u))
						testing.expect(t, slice.equal(p.v, want.v))
					}
					if p.decoder != nil do released_references += 1
					testing.expect(t, release_picture(&d, p))
					count += 1
				}
				clear(&out)
				if count <= 32 {
					warm_peak = max(warm_peak, track.current_memory_allocated)
				} else {
					// Permit one additional picture/scratch set, but no growth
					// proportional to the length of the clip.
					testing.expectf(
						t,
						track.current_memory_allocated <= warm_peak + 32 * 1024,
						"mode %d frame %d: live bytes %d exceeded warm bound %d",
						mode,
						count,
						track.current_memory_allocated,
						warm_peak,
					)
				}
			}
			testing.expect(t, flush_decoder(&d, &out))
			for p in out {
				if count < frames {
					testing.expect_value(t, p.poc, reference[count].poc)
					testing.expect(t, slice.equal(p.y, reference[count].y))
					testing.expect(t, slice.equal(p.u, reference[count].u))
					testing.expect(t, slice.equal(p.v, reference[count].v))
				}
				testing.expect(t, release_picture(&d, p))
				count += 1
			}
			testing.expect_value(t, count, frames)
			testing.expect(t, released_references > 0)
			delete(out)
			destroy_decoder(&d)
		}
		testing.expect_value(t, track.current_memory_allocated, i64(0))
		testing.expect_value(t, len(track.allocation_map), 0)
	}
}

@(test)
test_output_survives_decoder_destruction :: proc(t: ^testing.T) {
	d: Decoder
	other: Decoder
	init_decoder(&d)
	init_decoder(&other)
	defer destroy_decoder(&other)
	s := SPS {
		pic_width_in_luma_samples  = 16,
		pic_height_in_luma_samples = 16,
		sub_width_c                = 2,
		sub_height_c               = 2,
		chroma_format_idc          = 1,
		bit_depth_luma             = 8,
		bit_depth_chroma           = 8,
	}
	p := new(Picture)
	p^ = alloc_picture(&s)
	p.y[0] = 173
	dpb_store(&d, p, true)
	testing.expect_value(t, dpb_bump(&d), p)
	testing.expect(t, !release_picture(&other, p))
	testing.expect(t, p.handed_out)
	destroy_decoder(&d)
	testing.expect_value(t, p.decoder, (^Decoder)(nil))
	testing.expect_value(t, p.y[0], u8(173))
	testing.expect(t, release_picture(nil, p))
}

@(test)
test_annex_b_failure_releases_shared_outputs :: proc(t: ^testing.T) {
	e: enc.Encoder
	enc.init_encoder(&e, {width = 16, height = 16, qp = 26, forced_mode = -1})
	stream := encode_test_frames(&e, 8, 16, 16)
	enc.destroy_encoder(&e)
	defer delete(stream)
	// A valid NAL header followed by an incomplete first slice. Earlier
	// pictures have already been handed out and may still be in the DPB.
	append(&stream, 0, 0, 1, 2, 1, 0x80)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		pics, good := decode_annex_b(stream[:])
		testing.expect(t, !good)
		testing.expect_value(t, len(pics), 0)
	}
	testing.expect_value(t, track.current_memory_allocated, i64(0))
	testing.expect_value(t, len(track.allocation_map), 0)
}

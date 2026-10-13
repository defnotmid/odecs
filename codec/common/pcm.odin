package common

import "base:intrinsics"
import "core:simd"

PCM_Error :: enum {
	None,
	Non_Finite,
	Output_Too_Small,
}

@(private)
pcm_s16 :: #force_inline proc(value: f32) -> i16 {
	// Widen before scaling or adding the half: f32 addition can round the
	// representable value just below a half tie onto the next integer.
	scaled := clamp(f64(value) * 32768, -32768, 32767)
	return i16(i32(scaled + (scaled < 0 ? -0.5 : 0.5)))
}

// Pack normalized interleaved PCM into signed 16-bit little-endian bytes.
// Finite samples outside [-1,1] saturate; half ties round away from zero.
// Input and output storage must not overlap. No allocation or codec state is
// involved. A short output refuses before any writes. A nonfinite input returns
// its index, leaving that sample and the remaining output bytes untouched;
// all preceding samples have already been packed. Extra output bytes are kept.
pack_s16le :: proc(input: []f32, output: []u8) -> (samples: int, err: PCM_Error) #no_bounds_check {
	if len(input) > len(output) / 2 do return 0, .Output_Too_Small
	// This admission bounds 2*samples without overflow. Samples stays in
	// 0..len(input); each full batch has eight input/final output lanes, and
	// the scalar tail has both output bytes before either unchecked access.
	for len(input) - samples >= 8 {
		values := intrinsics.unaligned_load((^simd.f32x8)(&input[samples]))
		bits := transmute(simd.u32x8)values
		exponent := simd.bit_and(bits, simd.u32x8(0x7f800000))
		nonfinite := simd.lanes_eq(exponent, simd.u32x8(0x7f800000))
		// Never convert a NaN/Inf lane to an integer. Scalar fallback below
		// preserves the exact finite prefix, including inside this batch.
		if simd.reduce_or(nonfinite) != 0 do break
		scaled := simd.clamp(
			simd.mul(simd.f64x8(values), simd.f64x8(32768)),
			simd.f64x8(-32768),
			simd.f64x8(32767),
		)
		bias := simd.select(
			simd.lanes_lt(scaled, simd.f64x8(0)),
			simd.f64x8(-0.5),
			simd.f64x8(0.5),
		)
		packed := simd.i16x8(simd.i32x8(simd.add(scaled, bias)))
		when ODIN_ENDIAN == .Little {
			intrinsics.unaligned_store((^simd.i16x8)(&output[2 * samples]), packed)
		} else {
			unsigned := transmute(simd.u16x8)packed
			little := simd.bit_or(
				simd.shl(unsigned, simd.u16x8(8)),
				simd.shr(unsigned, simd.u16x8(8)),
			)
			intrinsics.unaligned_store((^simd.u16x8)(&output[2 * samples]), little)
		}
		samples += 8
	}
	for samples < len(input) {
		value := input[samples]
		if (transmute(u32)value) & 0x7f800000 == 0x7f800000 do return samples, .Non_Finite
		packed := u16(pcm_s16(value))
		output[2 * samples], output[2 * samples + 1] = u8(packed & 255), u8(packed >> 8)
		samples += 1
	}
	return samples, .None
}

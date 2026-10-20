package common

import "base:intrinsics"
import "core:simd"

PCM_Error :: enum {
	None,
	Non_Finite,
	Output_Too_Small,
}

// Stored sample types beyond Odin's own (u8, i8, i16, i16be, i32, i32be,
// f32, f32be, f64, f64be): 24-bit integers in three bytes, and G.711 bytes.
I24 :: distinct [3]u8
I24be :: distinct [3]u8
A_Law :: distinct u8
Mu_Law :: distinct u8

// How interleaved PCM is stored: one per stored sample type.
Sample_Format :: enum u8 {
	U8, // 8-bit unsigned: 128 is zero
	I8,
	I16,
	I16be,
	I24,
	I24be,
	I32,
	I32be,
	F32,
	F32be,
	F64,
	F64be,
	A_Law, // ITU-T G.711
	Mu_Law,
}

@(rodata)
SAMPLE_BYTES := [Sample_Format]int {
	.U8     = 1,
	.I8     = 1,
	.I16    = 2,
	.I16be  = 2,
	.I24    = 3,
	.I24be  = 3,
	.I32    = 4,
	.I32be  = 4,
	.F32    = 4,
	.F32be  = 4,
	.F64    = 8,
	.F64be  = 8,
	.A_Law  = 1,
	.Mu_Law = 1,
}

// The format of linear PCM `bits` wide; not ok outside 8, 16, 24 and 32-bit
// integers and 32 and 64-bit floats. `unsigned` applies to 8-bit integers.
sample_format :: proc(bits: int, float, unsigned, big_endian: bool) -> (f: Sample_Format, ok: bool) {
	switch {
	case float && bits == 32:
		f = big_endian ? .F32be : .F32
	case float && bits == 64:
		f = big_endian ? .F64be : .F64
	case float:
		return
	case bits == 8:
		f = unsigned ? .U8 : .I8
	case bits == 16:
		f = big_endian ? .I16be : .I16
	case bits == 24:
		f = big_endian ? .I24be : .I24
	case bits == 32:
		f = big_endian ? .I32be : .I32
	case:
		return
	}
	return f, true
}

// One stored sample as 16-bit PCM. Narrower integers scale up exactly;
// wider integers, and floats scaled by 32768, round half away from zero and
// saturate. NaN is silence. G.711 expands to its 16-bit linear values.
to_i16 :: proc {
	int_to_i16,
	float_to_i16,
	i24_to_i16,
	i24be_to_i16,
	a_law_to_i16,
	mu_law_to_i16,
}

// One stored sample as f32 in [-1, 1]. Integers divide by 2^(bits-1), which
// is exact; floats clamp, with NaN as silence; G.711 divides its 16-bit
// linear value by 32768.
to_f32 :: proc {
	int_to_f32,
	float_to_f32,
	i24_to_f32,
	i24be_to_f32,
	a_law_to_f32,
	mu_law_to_f32,
}

// A signed integer sample `bits` wide as 16-bit: narrower ones shift up
// exactly; wider ones drop their low bits, rounding half away from zero,
// and saturate.
scale_i16 :: #force_inline proc(v: i64, bits: uint) -> i16 {
	if bits <= 16 do return i16(v << (16 - bits))
	drop := bits - 16
	m := (abs(v) + (1 << (drop - 1))) >> drop
	return v < 0 ? i16(-m) : i16(min(m, 32767))
}

int_to_i16 :: #force_inline proc(v: $T) -> i16 where intrinsics.type_is_integer(T) {
	when intrinsics.type_is_unsigned(T) {
		#assert(size_of(T) == 1)
		return (i16(v) - 128) << 8
	} else {
		return scale_i16(i64(v), 8 * size_of(T))
	}
}

float_to_i16 :: #force_inline proc(v: $T) -> i16 where intrinsics.type_is_float(T) {
	x := f64(v)
	if x != x do return 0
	scaled := clamp(x * 32768, -32768, 32767)
	// Rounding by the exact fraction: adding a half can round up a value
	// just below the tie.
	whole := i32(scaled)
	fraction := scaled - f64(whole)
	return i16(whole + i32(fraction >= 0.5) - i32(fraction <= -0.5))
}

int_to_f32 :: #force_inline proc(v: $T) -> f32 where intrinsics.type_is_integer(T) {
	when intrinsics.type_is_unsigned(T) {
		#assert(size_of(T) == 1)
		return (f32(v) - 128) / 128
	} else {
		return f32(v) / (1 << (8 * size_of(T) - 1))
	}
}

float_to_f32 :: #force_inline proc(v: $T) -> f32 where intrinsics.type_is_float(T) {
	x := f32(v)
	return x != x ? 0 : clamp(x, -1, 1)
}

i24_to_i16 :: #force_inline proc(v: I24) -> i16 {return scale_i16(i64(i24(v)), 24)}
i24be_to_i16 :: #force_inline proc(v: I24be) -> i16 {return scale_i16(i64(i24({v[2], v[1], v[0]})), 24)}
i24_to_f32 :: #force_inline proc(v: I24) -> f32 {return f32(i24(v)) / (1 << 23)}
i24be_to_f32 :: #force_inline proc(v: I24be) -> f32 {return f32(i24({v[2], v[1], v[0]})) / (1 << 23)}

@(private)
i24 :: #force_inline proc(v: I24) -> i32 {
	return i32(v[0]) | i32(v[1]) << 8 | i32(i8(v[2])) << 16
}

// ITU-T G.711 A-law tables 1a/1b.
a_law_to_i16 :: proc(v: A_Law) -> i16 {
	a := i32(v ~ 0x55)
	segment := (a >> 4) & 7
	m := (a & 15) << 1 | 1
	x := segment == 0 ? m << 3 : (m + 32) << uint(segment + 2)
	return i16(a & 0x80 == 0 ? -x : x)
}

// ITU-T G.711 mu-law tables 2a/2b.
mu_law_to_i16 :: proc(v: Mu_Law) -> i16 {
	u := i32(~v)
	t := ((u & 15) << 3 + 0x84) << uint((u >> 4) & 7)
	return i16(u & 0x80 != 0 ? 0x84 - t : t - 0x84)
}

a_law_to_f32 :: #force_inline proc(v: A_Law) -> f32 {return f32(a_law_to_i16(v)) / 32768}
mu_law_to_f32 :: #force_inline proc(v: Mu_Law) -> f32 {return f32(mu_law_to_i16(v)) / 32768}

// How many leading channels of `stored` to keep: `wanted`, at most all of
// them, or all of them for 0.
kept_channels :: proc(stored, wanted: int) -> int {
	return wanted <= 0 ? stored : min(wanted, stored)
}

// Converts interleaved PCM in `format`, `channels` per frame, into `out` as
// i16 or f32 (see to_i16 and to_f32), keeping the first `keep` channels of
// each frame. Returns the frames converted: as many as both data and out hold.
convert_pcm :: proc(data: []u8, format: Sample_Format, channels: int, out: []$D, keep: int) -> (frames: int) where D == i16 || D == f32 {
	if channels < 1 || keep < 1 || keep > channels do return 0
	switch format {
	case .U8:     return convert_frames(data, u8, channels, out, keep)
	case .I8:     return convert_frames(data, i8, channels, out, keep)
	case .I16:    return convert_frames(data, i16le, channels, out, keep)
	case .I16be:  return convert_frames(data, i16be, channels, out, keep)
	case .I24:    return convert_frames(data, I24, channels, out, keep)
	case .I24be:  return convert_frames(data, I24be, channels, out, keep)
	case .I32:    return convert_frames(data, i32le, channels, out, keep)
	case .I32be:  return convert_frames(data, i32be, channels, out, keep)
	case .F32:    return convert_frames(data, f32le, channels, out, keep)
	case .F32be:  return convert_frames(data, f32be, channels, out, keep)
	case .F64:    return convert_frames(data, f64le, channels, out, keep)
	case .F64be:  return convert_frames(data, f64be, channels, out, keep)
	case .A_Law:  return convert_frames(data, A_Law, channels, out, keep)
	case .Mu_Law: return convert_frames(data, Mu_Law, channels, out, keep)
	}
	return 0
}

@(private)
convert_frames :: proc(data: []u8, $S: typeid, channels: int, out: []$D, keep: int) -> (frames: int) #no_bounds_check {
	stride := size_of(S) * channels
	frames = min(len(data) / stride, len(out) / keep)
	for f in 0 ..< frames {
		src := data[f * stride:]
		for &d, c in out[f * keep:][:keep] {
			s := intrinsics.unaligned_load((^S)(&src[c * size_of(S)]))
			when D == i16 {d = to_i16(s)} else {d = to_f32(s)}
		}
	}
	return
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
		packed := u16(to_i16(value))
		output[2 * samples], output[2 * samples + 1] = u8(packed & 255), u8(packed >> 8)
		samples += 1
	}
	return samples, .None
}

// Interleaves planar i32 channel buffers into `out` (at least samples * len(planes)
// values) as normalized f32 in [-1, 1): sample / 2^(bit_depth - 1).
interleave_i32_f32 :: proc(planes: [][]i32, samples, bit_depth: int, out: []f32) #no_bounds_check {
	n, ch := samples, len(planes)
	scale := f32(1.0 / f64(u64(1) << uint(bit_depth - 1)))
	if ch == 1 {
		p := planes[0][:n]
		sv := simd.f32x8(scale)
		i := 0
		for ; i + 8 <= n; i += 8 {
			iv := intrinsics.unaligned_load((^simd.i32x8)(&p[i]))
			intrinsics.unaligned_store((^simd.f32x8)(&out[i]), simd.f32x8(iv) * sv)
		}
		for ; i < n; i += 1 do out[i] = f32(p[i]) * scale
		return
	}
	if ch == 2 {
		l, r := planes[0][:n], planes[1][:n]
		sv := simd.f32x8(scale)
		i := 0
		for ; i + 8 <= n; i += 8 {
			lv := simd.to_array(simd.f32x8(intrinsics.unaligned_load((^simd.i32x8)(&l[i]))) * sv)
			rv := simd.to_array(simd.f32x8(intrinsics.unaligned_load((^simd.i32x8)(&r[i]))) * sv)
			#unroll for k in 0 ..< 8 {
				out[(i + k) * 2 + 0] = lv[k]
				out[(i + k) * 2 + 1] = rv[k]
			}
		}
		for ; i < n; i += 1 {
			out[i * 2 + 0] = f32(l[i]) * scale
			out[i * 2 + 1] = f32(r[i]) * scale
		}
		return
	}
	for c in 0 ..< ch {
		for x, i in planes[c][:n] do out[i * ch + c] = f32(x) * scale
	}
}

// Interleaves planar i32 channel buffers into `out` (at least samples * len(planes)
// values) as 16-bit PCM by scale_i16.
interleave_i32_i16 :: proc(planes: [][]i32, samples, bit_depth: int, out: []i16) #no_bounds_check {
	ch := len(planes)
	for p, c in planes {
		for x, i in p[:samples] do out[i * ch + c] = scale_i16(i64(x), uint(bit_depth))
	}
}

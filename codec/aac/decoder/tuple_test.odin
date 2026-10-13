package aac_decoder

import aac ".."
import common "../../common"
import "core:math"
import "core:testing"

// Retain the original runtime tuple arithmetic as an independent oracle.
// The writer uses the public Huffman codewords and explicit sign/escape bits;
// neither oracle reads the production tuple dictionary or numeric caches.
@(private)
tuple_test_original_unpack :: proc(book, symbol: int) -> (values: [4]i32, count: int) {
	count = book <= 4 ? 4 : 2
	radix := book <= 4 ? 3 : (book <= 6 ? 9 : (book <= 8 ? 8 : (book <= 10 ? 13 : 17)))
	signed := book <= 2 || book == 5 || book == 6
	bias := signed ? radix / 2 : 0
	index := symbol
	for i := count - 1; i >= 0; i -= 1 {
		values[i] = i32(index % radix - bias)
		index /= radix
	}
	return
}

@(private)
tuple_test_write :: proc(w: ^common.Bit_Writer, book, symbol: int, values: [4]i32, count: int) {
	code := aac.CODEBOOKS[book][symbol]
	common.write_bits(w, code.bits, int(code.length))
	signed := book <= 2 || book == 5 || book == 6
	if !signed {
		for i in 0 ..< count {
			value := values[i]
			if value != 0 do common.write_bits(w, value < 0 ? 1 : 0, 1)
		}
	}
	// All signs precede either escape payload, including a tuple with two escapes.
	if book == 11 {
		for i in 0 ..< count {
			value := values[i]
			magnitude := abs(value)
			if magnitude < 16 do continue
			n := 4
			for magnitude >= i32(1) << uint(n + 1) {
				common.write_bits(w, 1, 1)
				n += 1
			}
			common.write_bits(w, 0, 1)
			common.write_bits(w, u32(magnitude - (i32(1) << uint(n))), n)
		}
	}
}

@(private)
tuple_test_verify :: proc(
	t: ^testing.T,
	d: ^Decoder,
	buf: ^[dynamic]u8,
	book, symbol: int,
	want: [4]i32,
	count: int,
) {
	w := common.init_bit_writer(buf)
	tuple_test_write(&w, book, symbol, want, count)
	end := common.bits_written(&w)
	common.write_bits(&w, 0x15, 5)
	common.write_align_zero(&w)
	// Exact capacity and larger caller slices must publish only the tuple's
	// owned prefix. In particular a pair must leave slots two and three alone.
	for capacity in ([3]int{count, 4, 6}) {
		storage: [10]i32
		for &v, i in storage do v = i32(-1000 - i * 17)
		r := aac.Bit_Reader {
			data = buf[:],
		}
		got_count := read_tuple_into(&r, &d.huffman, &d.tuples, book, storage[2:2 + capacity])
		testing.expect_value(t, r.err, Error.None)
		testing.expect_value(t, got_count, count)
		testing.expect_value(t, r.pos, end)
		for value, i in storage {
			if i >= 2 && i < 2 + count {
				testing.expectf(
					t,
					value == want[i - 2],
					"book=%d symbol=%d capacity=%d coefficient=%d got=%d expected=%d",
					book,
					symbol,
					capacity,
					i - 2,
					value,
					want[i - 2],
				)
			} else {
				testing.expect_value(t, value, i32(-1000 - i * 17))
			}
		}
		testing.expect_value(t, aac.read_bits(&r, 5), u32(0x15))
	}
}

@(test)
test_tuple_dictionary_all_symbols_and_signs :: proc(t: ^testing.T) {
	d := new(Decoder)
	defer free(d)
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 1}), Error.None)
	buf: [dynamic]u8
	defer delete(buf)
	for book in 1 ..= 11 {
		signed := book <= 2 || book == 5 || book == 6
		for _, symbol in aac.CODEBOOKS[book] {
			raw, count := tuple_test_original_unpack(book, symbol)
			variants := signed ? 1 : 1 << uint(count)
			for mask in 0 ..< variants {
				want := raw
				if !signed do for &value, i in want[:count] {
					if mask & (1 << uint(i)) != 0 do value = -value
				}
				tuple_test_verify(t, d, &buf, book, symbol, want, count)
			}
		}
	}
}

@(test)
test_tuple_escape_ranges_and_sign_order :: proc(t: ^testing.T) {
	d := new(Decoder)
	defer free(d)
	testing.expect_value(t, init_decoder(d, {sample_rate = 44100, channels = 1}), Error.None)
	buf: [dynamic]u8
	defer delete(buf)
	for n in 4 ..= 12 {
		for suffix in ([3]int{0, 1 << uint(n - 1), (1 << uint(n)) - 1}) {
			magnitude := (i32(1) << uint(n)) + i32(suffix)
			for mask in 0 ..< 4 {
				a := mask & 1 != 0 ? -magnitude : magnitude
				b := mask & 2 != 0 ? i32(-17) : i32(17)
				// Escapes in either position and both positions discriminate sign ordering.
				tuple_test_verify(t, d, &buf, 11, 16 * 17 + 1, {a, b < 0 ? -1 : 1, 0, 0}, 2)
				tuple_test_verify(t, d, &buf, 11, 1 * 17 + 16, {b < 0 ? -1 : 1, a, 0, 0}, 2)
				tuple_test_verify(t, d, &buf, 11, 16 * 17 + 16, {a, b, 0, 0}, 2)
			}
		}
	}
}

@(test)
test_tuple_escape_truncation_and_invalid_unary :: proc(t: ^testing.T) {
	d := new(Decoder)
	defer free(d)
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 1}), Error.None)
	buf: [dynamic]u8
	defer delete(buf)
	// Shift the tuple through every bit alignment so byte truncations cover
	// every Huffman, sign, unary, terminator, and escape-suffix position.
	for prefix in 0 ..< 8 {
		w := common.init_bit_writer(&buf)
		common.write_bits(&w, 0, prefix)
		tuple_test_write(&w, 11, 16 * 17 + 16, {8191, -17, 0, 0}, 2)
		end := common.bits_written(&w)
		common.write_align_zero(&w)
		for cut in prefix ..< end {
			if cut % 8 != 0 do continue
			r := aac.Bit_Reader {
				data = buf[:cut / 8],
				pos  = prefix,
			}
			storage := [6]i32{-71, -72, -73, -74, -75, -76}
			count := read_tuple_into(&r, &d.huffman, &d.tuples, 11, storage[1:5])
			testing.expect_value(t, count, 2)
			testing.expectf(
				t,
				r.err == .Truncated && r.pos <= cut,
				"prefix=%d cut=%d error=%v position=%d",
				prefix,
				cut,
				r.err,
				r.pos,
			)
			for value, i in storage do if i != 1 && i != 2 do testing.expect_value(t, value, i32(-71 - i))
		}
	}
	w := common.init_bit_writer(&buf)
	code := aac.CODEBOOKS[11][16 * 17]
	common.write_bits(&w, code.bits, int(code.length))
	common.write_bits(&w, 0, 1) // Positive escape; the zero second value has no sign.
	common.write_bits(&w, 0x1ff, 9) // The ninth unary one would require n=13.
	end := common.bits_written(&w)
	common.write_align_zero(&w)
	r := aac.Bit_Reader {
		data = buf[:],
	}
	storage := [6]i32{-71, -72, -73, -74, -75, -76}
	count := read_tuple_into(&r, &d.huffman, &d.tuples, 11, storage[1:5])
	testing.expect_value(t, count, 2)
	testing.expect_value(t, r.err, Error.Invalid_Data)
	testing.expect_value(t, r.pos, end)
	for value, i in storage do if i != 1 && i != 2 do testing.expect_value(t, value, i32(-71 - i))
}

@(private)
tuple_test_exact_f64 :: proc(t: ^testing.T, got, want: f64) {
	testing.expect_value(t, transmute(u64)got, transmute(u64)want)
}

@(test)
test_dequant_caches_exact_original_math :: proc(t: ^testing.T) {
	d := new(Decoder)
	defer free(d)
	testing.expect_value(t, init_decoder(d, {sample_rate = 32000, channels = 1}), Error.None)
	for value, magnitude in d.dequant {
		tuple_test_exact_f64(t, value, math.pow(f64(magnitude), 4.0 / 3))
	}
	for value, sf in d.scale {
		tuple_test_exact_f64(t, value, math.pow(2.0, f64(sf - 100) / 4))
	}
	// Exhaust the admitted raw-escape-plus-pulse magnitude domain, including
	// the first fallback value, both signs, and zero's positive sign rule.
	for magnitude in 0 ..= 8251 {
		for sign in ([2]i32{-1, 1}) {
			q := i32(magnitude) * sign
			want := math.pow(f64(abs(q)), 4.0 / 3) * 1 * (q < 0 ? -1 : 1)
			tuple_test_exact_f64(t, dequantize(d, q, 1), want)
		}
	}
	for sf in 0 ..< 256 {
		for q in ([9]i32{-8251, -128, -127, -1, 0, 1, 127, 128, 8251}) {
			want :=
				math.pow(f64(abs(q)), 4.0 / 3) *
				math.pow(2.0, f64(sf - 100) / 4) *
				(q < 0 ? -1 : 1)
			tuple_test_exact_f64(t, dequantize(d, q, d.scale[sf]), want)
		}
	}
}

@(private)
tuple_test_pulse_frame :: proc(buf: ^[dynamic]u8, q: i32) {
	w := common.init_bit_writer(buf)
	common.write_bits(&w, 0, 3) // Single-channel element.
	common.write_bits(&w, 0, 4) // Element tag.
	common.write_bits(&w, 100, 8) // Global gain: scale 1.
	common.write_bits(&w, 0, 1) // ICS reserved bit.
	common.write_bits(&w, 0, 2) // Long sequence.
	common.write_bits(&w, 0, 1) // Sine shape.
	common.write_bits(&w, 1, 6) // One four-coefficient band.
	common.write_bits(&w, 0, 1) // Predictor absent.
	common.write_bits(&w, 11, 4)
	common.write_bits(&w, 1, 5) // One section covering that band.
	scale_code := aac.CODEBOOKS[0][60]
	common.write_bits(&w, scale_code.bits, int(scale_code.length)) // Scale-factor delta zero.
	common.write_bits(&w, 1, 1) // Pulse data present.
	common.write_bits(&w, 3, 2) // Four pulses.
	common.write_bits(&w, 0, 6) // Start at the first band.
	for _ in 0 ..< 4 {
		common.write_bits(&w, 0, 5) // All pulses name the same coefficient.
		common.write_bits(&w, 15, 4)
	}
	common.write_bits(&w, 0, 1) // TNS absent.
	common.write_bits(&w, 0, 1) // Gain control absent.
	tuple_test_write(&w, 11, min(int(abs(q)), 16) * 17, {q, 0, 0, 0}, 2)
	tuple_test_write(&w, 11, 0, {}, 2)
	common.write_bits(&w, 7, 3) // End element.
	common.write_align_zero(&w)
}

@(test)
test_dequant_repeated_pulses_cover_cache_and_extended_bound :: proc(t: ^testing.T) {
	d := new(Decoder)
	defer free(d)
	testing.expect_value(t, init_decoder(d, {sample_rate = 48000, channels = 1}), Error.None)
	buf: [dynamic]u8
	defer delete(buf)
	output: [1024]f32
	for q in ([7]i32{-8191, -68, -67, 0, 67, 68, 8191}) {
		tuple_test_pulse_frame(&buf, q)
		reset_decoder(d)
		samples, err := decode_frame(d, buf[:], output[:])
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, samples, 1024)
		want_q := q + (q > 0 ? i32(60) : i32(-60))
		testing.expect_value(t, d.channel[0].quant[0], want_q)
		want := math.pow(f64(abs(want_q)), 4.0 / 3) * 1 * (want_q < 0 ? -1 : 1)
		tuple_test_exact_f64(t, d.channel[0].spectrum[0], want)
		for value in d.channel[0].quant[1:] do testing.expect_value(t, value, i32(0))
	}
}

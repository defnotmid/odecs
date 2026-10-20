package vorbis

import "core:math"
import "core:math/rand"
import "core:testing"

// The specification's example (section 3.2.1): lengths 2 4 4 4 4 2 3 3 get
// the codewords 00 0100 0101 0110 0111 10 110 111.
@(test)
codewords_as_the_specification_assigns_them :: proc(t: ^testing.T) {
	s: Setup
	defer destroy_setup(&s, context.allocator)
	lengths := [8]u8{2, 4, 4, 4, 4, 2, 3, 3}
	c := Codebook{entries = 8, dimensions = 1}
	testing.expect_value(t, build_codes(&s, &c, lengths[:]), Error.None)
	codes := [8]string{"00", "0100", "0101", "0110", "0111", "10", "110", "111"}
	// Each codeword, written bit by bit as the stream carries it, decodes to
	// its entry.
	for code, e in codes {
		packet: [4]u8
		for ch, k in transmute([]u8)code do if ch == '1' do packet[k / 8] |= 1 << uint(k % 8)
		b := Bits{data = packet[:]}
		testing.expectf(t, decode_entry(&s, &c, &b) == e && b.count == 32 - len(code), "codeword %s", code)
	}
	// One more length-2 code than the tree holds is refused.
	over := [9]u8{2, 4, 4, 4, 4, 2, 3, 3, 2}
	c2 := Codebook{entries = 9, dimensions = 1}
	testing.expect_value(t, build_codes(&s, &c2, over[:]), Error.Invalid)
}

@(test)
helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, ilog(0), 0)
	testing.expect_value(t, ilog(1), 1)
	testing.expect_value(t, ilog(7), 3)
	testing.expect_value(t, ilog(8), 4)
	testing.expect_value(t, lookup1_values(6561, 8), 3)
	testing.expect_value(t, lookup1_values(6560, 8), 2)
	testing.expect_value(t, lookup1_values(289, 2), 17)
	// 1.0: mantissa 1 << 20, exponent 768 (2^-20 with the 788 bias).
	testing.expect_value(t, unpack_float(768 << 21 | 1 << 20), 1)
	testing.expect_value(t, unpack_float(0x8000_0000 | 768 << 21 | 1 << 20), -1)
}

@(test)
imdct_matches_its_definition :: proc(t: ^testing.T) {
	for n in ([3]int{64, 256, 2048}) {
		tr: Transform
		testing.expect_value(t, init_transform(&tr, n, context.allocator), Error.None)
		defer destroy_transform(&tr, context.allocator)
		spectrum := make([]f32, n / 2)
		defer delete(spectrum)
		for &v in spectrum do v = rand.float32() * 2 - 1
		out := make([]f32, n)
		defer delete(out)
		imdct(&tr, spectrum, out)
		m := f64(n / 2)
		worst := 0.0
		for j in 0 ..< n {
			sum: f64
			for x, k in spectrum do sum += f64(x) * math.cos(math.PI / m * (f64(j) + 0.5 + m / 2) * (f64(k) + 0.5))
			worst = max(worst, abs(sum - f64(out[j])))
		}
		testing.expectf(t, worst < 1e-3 * math.sqrt(m), "n = %d: worst difference %v", n, worst)
	}
}

// The identification header, and every truncation of it refused.
@(test)
identification_header :: proc(t: ^testing.T) {
	identification := [30]u8{1, 'v', 'o', 'r', 'b', 'i', 's', 0, 0, 0, 0, 2, 0x44, 0xAC, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xB8, 1}
	info, err := read_identification(identification[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, info.channels, 2)
	testing.expect_value(t, info.rate, 44100)
	testing.expect_value(t, info.blocksize, [2]int{256, 2048})
	for n in 0 ..< len(identification) - 1 {
		_, e := read_identification(identification[:n])
		testing.expect(t, e != .None)
	}
}

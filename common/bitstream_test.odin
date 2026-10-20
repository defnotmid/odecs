package common

import "core:testing"

// A unary run whose one bit lands just past the cache's valid bits (the
// wide refill holds it, but count doesn't cover it): it is read on the next
// refill, and the reader stays in step.
@(test)
read_unary_past_valid_bits :: proc(t: ^testing.T) {
	data: [32]u8
	// 7 bits of 1111111, then 58 zeros, then a one, then 101.
	data[0] = 0xfe
	// bits 7..64 are zero; bit 65 is one; bits 66..68 are 101
	data[8] = 0b0110_1000
	r := Bit_Reader{data = data[:], left = len(data) * 8}
	testing.expect_value(t, read_bits(&r, 7), 0x7f)
	refill_bits(&r)
	testing.expect_value(t, read_unary(&r), 58)
	testing.expect_value(t, read_bits(&r, 3), 0b101)
	testing.expect(t, r.count >= 0 && r.left == len(data) * 8 - 7 - 59 - 3)
}

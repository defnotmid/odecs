package h265_decoder

import "core:testing"

@(test)
test_get_bits_fixed_width :: proc(t: ^testing.T) {
	data := [3]u8{0b1011_0100, 0b0100_1100, 0b1000_0000}
	c: Get_Bits
	get_bits_init(&c, data[:])

	testing.expect_value(t, get_bits_bits(&c, 3), u32(0b101))
	testing.expect_value(t, get_bits_bits(&c, 5), u32(0b10100))
	testing.expect_value(t, get_bits_bits(&c, 4), u32(0b0100))
	testing.expect_value(t, get_bits_bits(&c, 4), u32(0b1100))
	testing.expect_value(t, get_bits_bits(&c, 2), u32(0b10))
	testing.expect_value(t, get_bits_bits(&c, 6), u32(0))
}

@(test)
test_get_bits_exp_golomb :: proc(t: ^testing.T) {
	// ue(v): 0 = "1", 1 = "010", 2 = "011", 3 = "00100".
	data := [2]u8{0b1010_0110, 0b0100_0000}
	c: Get_Bits
	get_bits_init(&c, data[:])

	testing.expect_value(t, get_bits_ue(&c), u32(0))
	testing.expect_value(t, get_bits_ue(&c), u32(1))
	testing.expect_value(t, get_bits_ue(&c), u32(2))
	testing.expect_value(t, get_bits_ue(&c), u32(3))
}

@(test)
test_get_bits_signed_exp_golomb :: proc(t: ^testing.T) {
	// se(v): 0, 1, -1, 2 map to ue 0, 1, 2, 3.
	data := [2]u8{0b1010_0110, 0b0100_0000}
	c: Get_Bits
	get_bits_init(&c, data[:])

	testing.expect_value(t, get_bits_se(&c), i32(0))
	testing.expect_value(t, get_bits_se(&c), i32(1))
	testing.expect_value(t, get_bits_se(&c), i32(-1))
	testing.expect_value(t, get_bits_se(&c), i32(2))
}

@(test)
test_get_bits_align_and_more :: proc(t: ^testing.T) {
	data := [2]u8{0b1000_0000, 0b0000_0000}
	c: Get_Bits
	get_bits_init(&c, data[:])

	testing.expect_value(t, get_bits_bit(&c), u32(1))
	get_bits_byte_align(&c)
	testing.expect_value(t, get_bits_pos(&c), 8)
	testing.expect_value(t, get_bits_more_rbsp_data(&c), false)

	data2 := [3]u8{0b1000_0000, 0b0000_0000, 0b1010_1011}
	get_bits_init(&c, data2[:])
	_ = get_bits_bit(&c)
	testing.expect(t, get_bits_more_rbsp_data(&c))
}

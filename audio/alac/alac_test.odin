package alac

import "core:math"
import "core:testing"

@(private = "file")
COOKIE_16 := [?]u8{0, 0, 16, 0, 0, 16, 40, 10, 14, 2, 0, 0, 0, 0, 64, 4, 0, 23, 112, 0, 0, 0, 187, 128}
@(private = "file")
PACKET_16 := [?]u8{
	32, 0, 16, 0, 0, 0, 128, 0, 0, 13, 8, 1, 143, 254, 58, 0, 223, 255, 218, 13,
	12, 1, 117, 254, 76, 1, 61, 255, 58, 0, 93, 255, 238, 15, 248, 62, 95, 254, 15, 114,
	254, 149, 127, 45, 2, 72, 240, 28, 130, 65, 8, 60, 4, 134, 66, 40, 140, 25, 16, 1,
	197, 66, 226, 208, 120, 32, 69, 3, 129, 17, 129, 144, 6, 144, 9, 141, 13, 141, 39, 48,
	180, 163, 49, 204, 195, 49, 143, 94, 217, 89, 65, 37, 162, 251, 67, 144, 73, 198, 164, 139,
	75, 199, 255, 157, 76, 3, 248, 189, 19, 114, 172, 112, 213, 159, 225, 192, 10, 131, 40, 101,
	8, 32, 56, 32, 132, 33, 14, 5, 132, 145, 128, 113, 12, 2, 80, 20, 20, 12, 66, 33,
	8, 188, 58, 63, 72, 155, 201, 227, 96, 56, 193, 21, 89, 29, 192, 245, 248, 188, 64, 140,
	112, 84, 144, 58, 231, 44, 6, 152, 64, 200, 17, 149, 15, 218, 79, 54, 180, 224, 0, 0,
	2, 170,
}

@(private = "file")
COOKIE_24 := [?]u8{0, 0, 16, 0, 0, 24, 40, 10, 14, 1, 0, 0, 0, 0, 48, 4, 0, 16, 38, 96, 0, 0, 172, 68}
@(private = "file")
PACKET_24 := [?]u8{
	0, 0, 20, 0, 0, 0, 96, 0, 0, 13, 12, 1, 107, 254, 84, 1, 67, 255, 46, 0,
	103, 255, 234, 0, 167, 234, 190, 64, 158, 147, 14, 232, 30, 195, 90, 222, 127, 84, 127, 228,
	48, 113, 212, 16, 222, 249, 0, 131, 89, 131, 122, 223, 87, 82, 112, 245, 247, 208, 47, 110,
	178, 104, 198, 30, 186, 89, 24, 42, 90, 190, 8, 15, 248, 242, 127, 252, 116, 107, 245, 139,
	246, 169, 235, 214, 186, 130, 174, 27, 65, 184, 36, 16, 67, 12, 153, 24, 241, 232, 9, 161,
	4, 47, 17, 208, 164, 20, 41, 201, 36, 12, 8, 38, 192, 177, 36, 141, 136, 13, 160, 129,
	72, 200, 66, 90, 12, 156, 128, 231, 73, 83, 34, 122, 48, 211, 129, 31, 0, 0, 2, 170,
}

@(private = "file")
COOKIE_51 := [?]u8{0, 0, 16, 0, 0, 16, 40, 10, 14, 6, 0, 0, 0, 0, 192, 4, 0, 70, 80, 0, 0, 0, 187, 128}
@(private = "file")
PACKET_51 := [?]u8{
	0, 0, 16, 0, 0, 0, 64, 0, 0, 13, 12, 1, 89, 254, 122, 1, 35, 255, 66, 0,
	93, 255, 237, 255, 42, 158, 172, 184, 145, 162, 91, 121, 196, 190, 87, 150, 98, 88, 0, 28,
	130, 97, 24, 20, 25, 128, 96, 88, 92, 74, 11, 23, 140, 74, 103, 212, 250, 92, 194, 27,
	44, 22, 27, 64, 32, 0, 16, 0, 0, 0, 64, 0, 2, 13, 12, 1, 91, 254, 122, 1,
	29, 255, 74, 0, 87, 255, 238, 13, 12, 1, 93, 254, 118, 1, 29, 255, 78, 0, 85, 255,
	238, 15, 248, 9, 79, 254, 2, 74, 255, 107, 225, 189, 99, 141, 29, 131, 7, 2, 138, 8,
	8, 24, 77, 7, 31, 6, 96, 72, 144, 195, 195, 13, 40, 49, 68, 60, 111, 248, 105, 36,
	25, 90, 200, 214, 150, 85, 216, 169, 178, 104, 72, 60, 40, 13, 4, 130, 35, 64, 96, 128,
	80, 80, 32, 96, 64, 128, 96, 98, 136, 121, 184, 11, 10, 145, 0, 8, 0, 0, 0, 32,
	1, 1, 6, 134, 0, 175, 255, 59, 0, 139, 255, 170, 0, 40, 255, 248, 6, 134, 0, 172,
	255, 62, 0, 143, 255, 163, 0, 45, 255, 246, 255, 146, 160, 199, 224, 181, 76, 112, 9, 49,
	213, 240, 90, 69, 8, 46, 12, 193, 32, 0, 36, 10, 198, 224, 24, 9, 14, 2, 243, 32,
	8, 14, 56, 0, 22, 8, 137, 73, 131, 178, 192, 223, 252, 61, 141, 247, 223, 241, 155, 242,
	51, 134, 61, 253, 109, 48, 237, 7, 32, 194, 5, 193, 24, 63, 3, 195, 48, 236, 79, 41,
	207, 116, 76, 167, 2, 69, 129, 8, 48, 10, 3, 143, 8, 38, 96, 248, 136, 8, 0, 64,
	0, 0, 1, 0, 0, 0, 52, 48, 5, 103, 249, 240, 4, 127, 253, 24, 1, 111, 255, 183,
	252, 35, 67, 254, 18, 171, 255, 9, 83, 255, 132, 142, 249, 105, 224, 167, 81, 209, 128, 40,
	79, 6, 194, 240, 68, 59, 17, 70, 148, 219, 44, 250, 49, 36, 17, 133, 1, 112, 192, 8,
	42, 48, 6, 92, 110, 117, 192, 0, 0, 2, 170,
}

@(test)
test_decode_16bit_stereo_lossless :: proc(t: ^testing.T) {
	c := COOKIE_16
	cfg, err := parse_config(c[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, cfg.bit_depth, 16)
	testing.expect_value(t, cfg.channels, 2)
	testing.expect_value(t, cfg.sample_rate, 48000)

	d: Decoder
	testing.expect_value(t, init_decoder(&d, cfg), Error.None)
	defer destroy_decoder(&d)

	p := PACKET_16
	f, de := decode_frame(&d, p[:])
	testing.expect_value(t, de, Error.None)
	testing.expect_value(t, f.samples, 64)
	testing.expect_value(t, f.channels, 2)
	for i in 0 ..< 64 {
		want_l := i32(f64(20000) * math.sin(f64(i) * 0.1))
		want_r := i32(f64(15000) * math.cos(f64(i) * 0.13))
		testing.expect_value(t, f.planes[0][i], want_l)
		testing.expect_value(t, f.planes[1][i], want_r)
	}
	pcm: [128]f32
	interleave_f32(f, pcm[:])
	testing.expect(t, abs(pcm[0] - 0) < 1e-6)
	testing.expect(t, abs(pcm[1] - f32(15000.0 / 32768.0)) < 1e-6)
}

@(test)
test_decode_24bit_shifted_lossless :: proc(t: ^testing.T) {
	c := COOKIE_24
	cfg, err := parse_config(c[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, cfg.bit_depth, 24)
	testing.expect_value(t, cfg.channels, 1)

	d: Decoder
	testing.expect_value(t, init_decoder(&d, cfg), Error.None)
	defer destroy_decoder(&d)

	p := PACKET_24
	f, de := decode_frame(&d, p[:])
	testing.expect_value(t, de, Error.None)
	testing.expect_value(t, f.samples, 48)
	for i in 0 ..< 48 {
		want := i32(f64(5000000) * math.sin(f64(i) * 0.2)) + i32(i * 17)
		testing.expect_value(t, f.planes[0][i], want)
	}
}

@(test)
test_decode_5_1_channel_mapping :: proc(t: ^testing.T) {
	c := COOKIE_51
	cfg, err := parse_config(c[:])
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, cfg.channels, 6)

	d: Decoder
	testing.expect_value(t, init_decoder(&d, cfg), Error.None)
	defer destroy_decoder(&d)

	p := PACKET_51
	f, de := decode_frame(&d, p[:])
	testing.expect_value(t, de, Error.None)
	testing.expect_value(t, f.samples, 32)
	for i in 0 ..< 32 {
		for ch in 0 ..< 6 {
			want := i32(f64(2000 * (ch + 1)) * math.sin(f64(i) * 0.15 + f64(ch)))
			testing.expect_value(t, f.planes[ch][i], want)
		}
	}
}

@(test)
test_damaged_packets_and_cookies_never_read_out_of_bounds :: proc(t: ^testing.T) {
	c := COOKIE_16
	cfg, _ := parse_config(c[:])
	d: Decoder
	init_decoder(&d, cfg)
	defer destroy_decoder(&d)

	p := PACKET_16
	for n in 0 ..< len(p) {
		_, _ = decode_frame(&d, p[:n])
	}
	buf := p
	for i in 0 ..< len(buf) {
		orig := buf[i]
		for v in ([3]u8{0, 0xFF, 0xAA}) {
			buf[i] = v
			_, _ = decode_frame(&d, buf[:])
		}
		buf[i] = orig
	}
}

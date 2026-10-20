package aac

import common "../../common"
import "core:math"
import "core:testing"

@(test)
test_huffman_symbols :: proc(t: ^testing.T) {
	tables: Huffman_Tables
	init_huffman(&tables)
	buf: [dynamic]u8
	defer delete(buf)
	for codes, book in CODEBOOKS {
		writer := common.init_bit_writer(&buf)
		for code in codes do common.write_bits(&writer, code.bits, int(code.length))
		common.write_align_zero(&writer)
		r := Bit_Reader {
			data = buf[:],
		}
		for _, symbol in codes do testing.expect_value(t, read_huffman(&r, &tables, book), symbol)
		testing.expect_value(t, r.err, Error.None)
	}
}

@(test)
test_transport :: proc(t: ^testing.T) {
	buf: [dynamic]u8
	defer delete(buf)
	for rate in SAMPLE_RATES[:12] do for channels in 1 ..= 2 {
		clear(&buf)
		config := Config {
			sample_rate = rate,
			channels    = channels,
		}
		payload := [3]u8{0x21, 0x10, 0x07}
		testing.expect_value(t, append_adts(&buf, config, payload[:]), Error.None)
		h, raw, err := parse_adts(buf[:])
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, h.config, config)
		testing.expect(t, len(raw) == 3 && raw[0] == 0x21 && raw[2] == 7)
		for n in 0 ..< len(buf) {
			_, _, e := parse_adts(buf[:n])
			testing.expect(t, e != .None)
		}
		asc, e := audio_specific_config(config)
		testing.expect_value(t, e, Error.None)
		c, ae := parse_audio_specific_config(asc[:])
		testing.expect_value(t, ae, Error.None)
		testing.expect_value(t, c, config)
	}
}

@(test)
test_transform_definition :: proc(t: ^testing.T) {
	plan: Transform
	init_transform(&plan)
	x: [256]f64
	for &v, i in x do v = math.sin(f64(i) * 0.137) + f64(i % 11) / 13
	spectrum: [128]f64
	mdct(&plan, x[:], spectrum[:])
	for k in ([]int{0, 1, 17, 63, 127}) {
		want: f64
		for v, n in x do want += 2 * v * math.cos(math.PI / 128 * (f64(n) + 64.5) * (f64(k) + 0.5))
		testing.expectf(
			t,
			abs(want - spectrum[k]) < 1e-8,
			"MDCT bin %d: %g != %g",
			k,
			spectrum[k],
			want,
		)
	}
	z: [256]f64
	imdct(&plan, spectrum[:], z[:])
	for n in ([]int{0, 47, 128, 255}) {
		want: f64
		for v, k in spectrum do want += v * math.cos(math.PI / 128 * (f64(n) + 64.5) * (f64(k) + 0.5)) / 128
		testing.expectf(t, abs(want - z[n]) < 1e-8, "IMDCT sample %d", n)
	}
	for shape in 0 ..< 2 do for i in 0 ..< 1024 {
		a, b := plan.long_window[shape][i], plan.long_window[shape][1023 - i]
		testing.expect(t, abs(a * a + b * b - 1) < 1e-12)
	}
}

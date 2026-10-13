package flac

import "core:encoding/hex"
import "core:testing"

// The example files of RFC 9639 appendix D, byte for byte.
@(private = "file")
EXAMPLE_1 ::
	"664c6143800000221000100000000f00000f0ac442f0000000013e84b41807dc690307586a3dad1a2e0ffff869180000" +
	"bf0358fd03128baa9a"
@(private = "file")
EXAMPLE_2 ::
	"664c614300000022001000100000170000440ac442f000000013d5b0564975e98b8d8b930422757b8103030000120000" +
	"000000000000000000000000000000100400003a200000007265666572656e6365206c6962464c414320312e332e3320" +
	"3230313930383034010000000e0000005449544c453dd7a9d79cd795d79d81000006000000000000fff86998000f9912" +
	"086701623d1442998f5df70d6fe00c17caeb21000ee7a77a24a1590c1217b603097b784faa9a33d285e070ad5b1b4851" +
	"b4010d99d2cd1a68f1e6b810fff869180102a402c382c40bc14a03ee48dd03b67c1330"
@(private = "file")
EXAMPLE_3 ::
	"664c6143800000221000100000001f00001f07d0007000000018f8f9e396f5cbcfc6dc807f9977906b32fff868020017" +
	"e944004f6f313d1047d227cb6d090831452bdc2822228057a3"

@(private = "file")
decode_file :: proc(t: ^testing.T, text: string) -> (info: Stream_Info, samples: [MAX_CHANNELS][dynamic]i32) {
	data, ok := hex.decode(transmute([]u8)text)
	defer delete(data)
	testing.expect(t, ok)
	seeks: #soa[dynamic]Seek_Point
	defer delete(seeks)
	audio: int
	err: Error
	info, audio, err = parse_metadata(data, &seeks)
	testing.expect_value(t, err, Error.None)
	d: Decoder
	init_decoder(&d, info)
	defer destroy_decoder(&d)
	for at := audio; at < len(data); {
		f, used, e := decode_frame(&d, data[at:])
		testing.expect_value(t, e, Error.None)
		if e != .None do return
		testing.expect_value(t, first_sample(f.header, info), i64(len(samples[0])))
		for c in 0 ..< f.header.channels do append(&samples[c], ..f.planes[c])
		at += used
	}
	return
}

@(test)
example_1_verbatim_and_wasted_bits :: proc(t: ^testing.T) {
	info, s := decode_file(t, EXAMPLE_1)
	defer for p in s do delete(p)
	testing.expect(t, info.sample_rate == 44100 && info.channels == 2 && info.bits == 16 && info.total_samples == 1)
	testing.expect_value(t, s[0][0], 25588)
	testing.expect_value(t, s[1][0], 10416)
}

@(test)
example_2_fixed_predictor_side_right :: proc(t: ^testing.T) {
	info, s := decode_file(t, EXAMPLE_2)
	defer for p in s do delete(p)
	testing.expect_value(t, info.total_samples, 19)
	left := [?]i32{10372, 18041, 14942, 17876, 15627, 17899, 16242, 18077, 16824, 18263, 17295, -14418, -15201, -14508, -15195, -14818}
	right := [?]i32{6070, 10545, 8743, 10449, 9143, 10463, 9502, 10569, 9840, 10680, 10113, -8428, -8895, -8476, -8896, -8653}
	testing.expect_value(t, len(s[0]), 19)
	for v, i in left do testing.expect_value(t, s[0][i], v)
	for v, i in right do testing.expect_value(t, s[1][i], v)
	// The second frame: verbatim left, right with one wasted bit.
	testing.expect_value(t, s[0][16], i32(i16(-0x3c7e)))
	testing.expect_value(t, s[1][16], -9072)
}

@(test)
example_3_lpc_with_escaped_partition :: proc(t: ^testing.T) {
	info, s := decode_file(t, EXAMPLE_3)
	defer for p in s do delete(p)
	testing.expect(t, info.channels == 1 && info.bits == 8 && info.sample_rate == 32000)
	want := [?]i32{0, 79, 111, 78, 8, -61, -90, -68, -13, 42, 67, 53, 13, -27, -46, -38, -12, 14, 24, 19, 6, -4, -5, 0}
	testing.expect_value(t, len(s[0]), len(want))
	for v, i in want do testing.expect_value(t, s[0][i], v)
}

// Every corruption of a frame is refused by a CRC or the syntax checks, and
// every truncation fails cleanly.
@(test)
corruption_is_refused :: proc(t: ^testing.T) {
	data, _ := hex.decode(transmute([]u8)string(EXAMPLE_3))
	defer delete(data)
	info, audio, _ := parse_metadata(data)
	d: Decoder
	init_decoder(&d, info)
	defer destroy_decoder(&d)
	frame := data[audio:]
	for n in 0 ..< len(frame) {
		_, _, e := decode_frame(&d, frame[:n])
		testing.expect(t, e != .None)
	}
	for i in 0 ..< len(frame) * 8 {
		frame[i / 8] ~= 1 << uint(i % 8)
		_, _, e := decode_frame(&d, frame)
		testing.expect(t, e != .None)
		frame[i / 8] ~= 1 << uint(i % 8)
	}
}

@(test)
coded_numbers :: proc(t: ^testing.T) {
	// RFC 9639 9.1.5: 51 billion as a 7-byte coded sample number.
	header := [?]u8{0xFF, 0xF9, 0xC9, 0x08, 0xFE, 0xAF, 0x9F, 0xB5, 0xA3, 0xB8, 0x80, 0}
	header[len(header) - 1] = crc8(header[:len(header) - 1])
	h, e := parse_frame_header(header[:], {})
	testing.expect_value(t, e, Error.None)
	testing.expect(t, h.variable && h.number == 51_000_000_000 && h.block_size == 4096 && h.sample_rate == 44100)
}

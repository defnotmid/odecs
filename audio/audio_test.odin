package audio

import flac "./flac"
import wav "./wav"
import "core:bytes"
import "core:encoding/hex"
import "core:slice"
import "core:testing"

// A WAV file: fmt (format tag, channels, rate, bits), data, and an optional
// smpl chunk with one loop.
@(private = "file")
wav_file :: proc(tag, channels, bits, frames: int, loop: Maybe([2]u32) = nil) -> [dynamic]u8 {
	out: [dynamic]u8
	put :: proc(out: ^[dynamic]u8, v: u64, n: int) {for i in 0 ..< n do append(out, u8(v >> uint(8 * i)))}
	align := channels * bits / 8
	data := frames * align
	smpl := loop != nil ? 8 + 60 : 0
	append(&out, "RIFF")
	put(&out, u64(4 + 8 + 16 + 8 + data + smpl), 4)
	append(&out, "WAVEfmt ")
	put(&out, 16, 4)
	put(&out, u64(tag), 2)
	put(&out, u64(channels), 2)
	put(&out, 44100, 4)
	put(&out, u64(44100 * align), 4)
	put(&out, u64(align), 2)
	put(&out, u64(bits), 2)
	append(&out, "data")
	put(&out, u64(data), 4)
	// Every byte pattern, floats' NaNs and infinities among them.
	x := u32(12345)
	for _ in 0 ..< data {
		x = x * 1664525 + 1013904223
		append(&out, u8(x >> 24))
	}
	if l, ok := loop.?; ok {
		append(&out, "smpl")
		put(&out, 60, 4)
		for _ in 0 ..< 7 do put(&out, 0, 4)
		put(&out, 1, 4) // one loop
		put(&out, 0, 4)
		put(&out, 0, 4) // cue point id
		put(&out, 0, 4) // type
		put(&out, u64(l[0]), 4)
		put(&out, u64(l[1]), 4)
		put(&out, 0, 4)
		put(&out, 0, 4)
	}
	return out
}

// What wav.read gives, the reference odawg's samples come from today.
@(private = "file")
wav_reference :: proc(t: ^testing.T, data: []u8, out: []$T, channels: int) -> int {
	r: wav.Reader
	testing.expect_value(t, wav.open_bytes(&r, data), wav.Error.None)
	defer wav.close(&r)
	frames, e := wav.read(&r, 0, out, channels)
	testing.expect_value(t, e, wav.Error.None)
	return frames
}

@(test)
wav_reads_match_wav_read :: proc(t: ^testing.T) {
	FRAMES :: 10000 // several of the reader's 4096-frame runs
	formats := [][2]int{{1, 8}, {1, 16}, {1, 24}, {1, 32}, {3, 32}, {3, 64}, {6, 8}, {7, 8}}
	for f in formats {
		file := wav_file(f[0], 3, f[1], FRAMES)
		defer delete(file)
		for channels in ([]int{0, 2, 1}) {
			kept := channels == 0 ? 3 : channels
			want16 := make([]i16, FRAMES * kept)
			got16 := make([]i16, FRAMES * kept)
			want32 := make([]f32, FRAMES * kept)
			got32 := make([]f32, FRAMES * kept)
			defer {delete(want16); delete(got16); delete(want32); delete(got32)}
			testing.expect_value(t, wav_reference(t, file[:], want16, channels), FRAMES)
			testing.expect_value(t, wav_reference(t, file[:], want32, channels), FRAMES)
			n, e := decode_into(file[:], got16, channels)
			testing.expect_value(t, e, Error.None)
			testing.expect_value(t, n, FRAMES)
			testing.expect(t, slice.equal(got16, want16), "i16 differs from wav.read")
			n, e = decode_into(file[:], got32, channels)
			testing.expect_value(t, n, FRAMES)
			testing.expect(t, slice.equal(slice.reinterpret([]u32, got32), slice.reinterpret([]u32, want32)), "f32 differs from wav.read")
		}
	}
}

// Reads of either type may follow each other; each converts from the
// decoded source.
@(test)
mixed_reads_and_the_loop :: proc(t: ^testing.T) {
	FRAMES :: 9000
	file := wav_file(1, 2, 24, FRAMES, [2]u32{100, 8191})
	defer delete(file)
	i, e := info(file[:])
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, i.loop, Maybe(Loop)(Loop{100, 8192}))
	want16 := make([]i16, FRAMES * 2)
	want32 := make([]f32, FRAMES * 2)
	defer {delete(want16); delete(want32)}
	wav_reference(t, file[:], want16, 0)
	wav_reference(t, file[:], want32, 0)
	reader: bytes.Reader
	bytes.reader_init(&reader, file[:])
	r: Reader
	testing.expect_value(t, open_stream(&r, bytes.reader_to_stream(&reader)), Error.None)
	defer close(&r)
	a: [5000 * 2]f32
	b: [3000 * 2]i16
	c: [2000 * 2]f32
	n, _ := read(&r, a[:])
	testing.expect_value(t, n, 5000)
	n, _ = read(&r, b[:])
	testing.expect_value(t, n, 3000)
	n, _ = read(&r, c[:])
	testing.expect_value(t, n, 1000)
	testing.expect(t, slice.equal(a[:], want32[:5000 * 2]))
	testing.expect(t, slice.equal(b[:], want16[5000 * 2:][:3000 * 2]))
	testing.expect(t, slice.equal(c[:1000 * 2], want32[8000 * 2:]))
}

// RFC 9639 appendix D example 2: 16-bit stereo, two frames, a VORBIS_COMMENT.
@(private = "file")
FLAC_EXAMPLE ::
	"664c614300000022001000100000170000440ac442f000000013d5b0564975e98b8d8b930422757b8103030000120000" +
	"000000000000000000000000000000100400003a200000007265666572656e6365206c6962464c414320312e332e3320" +
	"3230313930383034010000000e0000005449544c453dd7a9d79cd795d79d81000006000000000000fff86998000f9912" +
	"086701623d1442998f5df70d6fe00c17caeb21000ee7a77a24a1590c1217b603097b784faa9a33d285e070ad5b1b4851" +
	"b4010d99d2cd1a68f1e6b810fff869180102a402c382c40bc14a03ee48dd03b67c1330"

@(test)
flac_reads_match_interleave :: proc(t: ^testing.T) {
	data, ok := hex.decode(transmute([]u8)string(FLAC_EXAMPLE))
	defer delete(data)
	testing.expect(t, ok)
	info, audio_at, me := flac.parse_metadata(data)
	testing.expect_value(t, me, flac.Error.None)
	d: flac.Decoder
	flac.init_decoder(&d, info)
	defer flac.destroy_decoder(&d)
	want16: [dynamic]i16
	want32: [dynamic]f32
	defer {delete(want16); delete(want32)}
	for at := audio_at; at < len(data); {
		f, used, e := flac.decode_frame(&d, data[at:])
		testing.expect_value(t, e, flac.Error.None)
		if e != .None do return
		n := f.header.block_size
		base16, base32 := len(want16), len(want32)
		resize(&want16, base16 + n)
		resize(&want32, base32 + n)
		flac.interleave(f, want16[base16:], 1)
		flac.interleave(f, want32[base32:], 1)
		at += used
	}
	got16 := make([]i16, len(want16))
	got32 := make([]f32, len(want32))
	defer {delete(got16); delete(got32)}
	n, e := decode_into(data, got16, 1)
	testing.expect_value(t, e, Error.None)
	testing.expect_value(t, n, len(want16))
	testing.expect(t, slice.equal(got16, want16[:]))
	n, e = decode_into(data, got32, 1)
	testing.expect_value(t, n, len(want32))
	testing.expect(t, slice.equal(got32, want32[:]))
	a, ae := decode(data, context.allocator, 1)
	defer destroy_audio(&a)
	testing.expect_value(t, ae, Error.None)
	testing.expect_value(t, a.channels, 1)
	testing.expect(t, slice.equal(a.samples, want32[:]))
}

// A Vorbis comment block holding the given fields.
@(private = "file")
comments :: proc(fields: ..string) -> [dynamic]u8 {
	out: [dynamic]u8
	put :: proc(out: ^[dynamic]u8, n: int) {for i in 0 ..< 4 do append(out, u8(n >> uint(8 * i)))}
	put(&out, 3)
	append(&out, "odc")
	put(&out, len(fields))
	for f in fields {put(&out, len(f)); append(&out, f)}
	return out
}

@(test)
comment_loops :: proc(t: ^testing.T) {
	cases := []struct {
		fields: []string,
		loop:   Maybe(Loop),
	} {
		{{"TITLE=x", "LOOPSTART=441", "LOOPLENGTH=1000"}, Loop{441, 1441}},
		{{"looplength=5", "LoopStart=0"}, Loop{0, 5}},
		{{"LOOPSTART=10"}, nil},
		{{"LOOPSTART=10", "LOOPLENGTH=0"}, nil},
		{{"LOOPSTART=-1", "LOOPLENGTH=4"}, nil},
		{{"LOOPSTART=1x", "LOOPLENGTH=4"}, nil},
	}
	for c in cases {
		block := comments(..c.fields)
		defer delete(block)
		testing.expect_value(t, comment_loop(block[:]), c.loop)
	}
	// A field running past the block ends the list.
	block := comments("LOOPSTART=441", "LOOPLENGTH=1000")
	defer delete(block)
	testing.expect_value(t, comment_loop(block[:len(block) - 1]), nil)
	testing.expect_value(t, vorbis_comment_loop(block[:]), nil)
}

// Native FLAC: a smpl chunk kept in an APPLICATION "riff" block, else
// LOOPSTART and LOOPLENGTH comments.
@(test)
flac_loops :: proc(t: ^testing.T) {
	// RFC 9639 example 1 (one frame) with blocks inserted after streaminfo.
	EXAMPLE_1 ::
		"664c6143800000221000100000000f00000f0ac442f0000000013e84b41807dc690307586a3dad1a2e0ffff869180000" +
		"bf0358fd03128baa9a"
	original, ok := hex.decode(transmute([]u8)string(EXAMPLE_1))
	defer delete(original)
	testing.expect(t, ok)
	with :: proc(original: []u8, blocks: ..[]u8) -> [dynamic]u8 {
		out: [dynamic]u8
		if len(blocks) == 0 {append(&out, ..original); return out}
		append(&out, ..original[:8 + 34])
		out[4] = 0 // streaminfo is no longer the last block
		for b, i in blocks {
			n := len(b) - 1
			append(&out, b[0] | (i == len(blocks) - 1 ? 0x80 : 0), u8(n >> 16), u8(n >> 8), u8(n))
			append(&out, ..b[1:])
		}
		append(&out, ..original[8 + 34:])
		return out
	}
	text := comments("LOOPSTART=1", "LOOPLENGTH=2")
	defer delete(text)
	comment_block := make([]u8, 1 + len(text))
	defer delete(comment_block)
	comment_block[0] = 4
	copy(comment_block[1:], text[:])
	smpl := wav_file(1, 1, 16, 0, [2]u32{0, 0})
	defer delete(smpl)
	riff: [dynamic]u8
	defer delete(riff)
	append(&riff, 2)
	append(&riff, "riff")
	append(&riff, ..smpl[len(smpl) - 68:]) // the smpl chunk, header and body
	cases := []struct {
		blocks: [][]u8,
		loop:   Maybe(Loop),
	} {
		{{comment_block}, Loop{1, 3}},
		{{riff[:], comment_block}, Loop{0, 1}},
		{{}, nil},
	}
	for c in cases {
		file := with(original, ..c.blocks)
		defer delete(file)
		i, e := info(file[:])
		testing.expect_value(t, e, Error.None)
		testing.expect_value(t, i.samples, 1)
		testing.expect_value(t, i.loop, c.loop)
	}
}

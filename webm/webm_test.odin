package webm

import "core:io"
import "core:testing"

// An in-memory io.Stream over a byte slice (Read_At and Size).
@(private = "file")
bytes_stream :: proc(b: ^[]u8) -> io.Stream {
	proc_ :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
		b := (^[]u8)(data)^
		#partial switch mode {
		case .Read_At:
			if offset >= i64(len(b)) do return 0, .EOF
			return i64(copy(p, b[offset:])), .None
		case .Size:
			return i64(len(b)), .None
		case .Query:
			return io.query_utility({.Read_At, .Size, .Query})
		}
		return 0, .Unsupported
	}
	return {proc_, b}
}

// EBML writing: IDs keep their marker bytes, sizes use 8-byte vints.
@(private = "file")
element :: proc(out: ^[dynamic]u8, id: u32, payload: []u8) {
	for shift := 24; shift >= 0; shift -= 8 do if id >> uint(shift) != 0 || shift == 0 do append(out, u8(id >> uint(shift)))
	n := u64(len(payload))
	append(out, 0x01)
	for k := 6; k >= 0; k -= 1 do append(out, u8(n >> uint(8 * k)))
	append(out, ..payload)
}

@(private = "file")
uint_element :: proc(out: ^[dynamic]u8, id: u32, v: u64) {
	b: [8]u8
	for k in 0 ..< 8 do b[k] = u8(v >> uint(56 - 8 * k))
	element(out, id, b[:])
}

@(private = "file")
build :: proc() -> [dynamic]u8 {
	doc: [dynamic]u8
	header: [dynamic]u8
	defer delete(header)
	element(&header, u32(ID.Doc_Type), transmute([]u8)string("webm"))
	element(&doc, u32(ID.EBML), header[:])

	segment: [dynamic]u8
	defer delete(segment)
	info: [dynamic]u8
	defer delete(info)
	uint_element(&info, u32(ID.Timecode_Scale), 1_000_000)
	element(&segment, u32(ID.Info), info[:])

	tracks, video_track, video, audio_track, audio: [dynamic]u8
	defer {delete(tracks); delete(video_track); delete(video); delete(audio_track); delete(audio)}
	uint_element(&video, u32(ID.Pixel_Width), 64)
	uint_element(&video, u32(ID.Pixel_Height), 48)
	uint_element(&video, u32(ID.Alpha_Mode), 1)
	uint_element(&video_track, u32(ID.Track_Number), 1)
	uint_element(&video_track, u32(ID.Track_Type), 1)
	element(&video_track, u32(ID.Codec_ID), transmute([]u8)string("V_VP9"))
	element(&video_track, u32(ID.Video), video[:])
	uint_element(&audio, u32(ID.Channels), 2)
	uint_element(&audio_track, u32(ID.Track_Number), 2)
	uint_element(&audio_track, u32(ID.Track_Type), 2)
	uint_element(&audio_track, u32(ID.Default_Duration), 20_000_000)
	element(&audio_track, u32(ID.Codec_ID), transmute([]u8)string("A_OPUS"))
	element(&audio_track, u32(ID.Audio), audio[:])
	element(&tracks, u32(ID.Track_Entry), video_track[:])
	element(&tracks, u32(ID.Track_Entry), audio_track[:])
	element(&segment, u32(ID.Tracks), tracks[:])

	cluster: [dynamic]u8
	defer delete(cluster)
	uint_element(&cluster, u32(ID.Timecode), 1000)
	// A keyframe SimpleBlock: track 1 (vint 0x81), +0 ms, key flag.
	element(&cluster, u32(ID.Simple_Block), {0x81, 0, 0, 0x80, 'K', 'E', 'Y'})
	// A BlockGroup: inter frame at +33 ms with an alpha BlockAdditional.
	group, more, additions: [dynamic]u8
	defer {delete(group); delete(more); delete(additions)}
	element(&group, u32(ID.Block), {0x81, 0, 33, 0, 'I', 'N'})
	element(&group, u32(ID.Reference_Block), {0xDF})
	uint_element(&more, u32(ID.Block_Add_ID), 1)
	element(&more, u32(ID.Block_Additional), transmute([]u8)string("alpha"))
	element(&additions, u32(ID.Block_More), more[:])
	element(&group, u32(ID.Block_Additions), additions[:])
	element(&cluster, u32(ID.Block_Group), group[:])
	// Audio: Xiph lacing (sizes 2 and 3, last 1), EBML lacing (3, then
	// +1 as a 1-byte signed difference 0xC0 = 64 - 63, last 2), fixed
	// lacing (2 x 2).
	element(&cluster, u32(ID.Simple_Block), {0x82, 0, 0, 0x80 | 2, 2, 2, 3, 'a', 'a', 'b', 'b', 'b', 'c'})
	element(&cluster, u32(ID.Simple_Block), {0x82, 0, 60, 0x80 | 6, 2, 0x83, 0xC0, 'd', 'd', 'd', 'e', 'e', 'e', 'e', 'f', 'f'})
	element(&cluster, u32(ID.Simple_Block), {0x82, 0, 120, 0x80 | 4, 1, 'g', 'g', 'h', 'h'})
	element(&segment, u32(ID.Cluster), cluster[:])
	element(&doc, u32(ID.Segment), segment[:])
	return doc
}

@(test)
blocks_lacing_and_additions :: proc(t: ^testing.T) {
	doc := build()
	defer delete(doc)
	data := doc[:]
	r: Reader
	err := open_stream(&r, bytes_stream(&data))
	testing.expect_value(t, err, Error.None)
	if err != .None do return
	defer close(&r)
	testing.expect_value(t, len(r.tracks), 2)
	v := &r.tracks[0]
	testing.expect_value(t, v.codec, Codec.VP9)
	testing.expect(t, v.alpha && v.width == 64 && v.height == 48)
	testing.expect_value(t, len(v.samples), 2)
	testing.expect(t, v.samples[0].sync && !v.samples[1].sync)
	testing.expect_value(t, v.samples[1].pts, 1033 * 1_000_000)
	p, pe := read_sample(&r, 0, 1)
	testing.expect_value(t, pe, Error.None)
	testing.expect_value(t, string(p.data), "IN")
	testing.expect_value(t, string(p.additional), "alpha")
	a := &r.tracks[1]
	testing.expect_value(t, a.codec, Codec.Opus)
	sizes := [?]u32{2, 3, 1, 3, 4, 2, 2, 2}
	testing.expect_value(t, len(a.samples), len(sizes))
	for size, i in sizes do testing.expect_value(t, a.samples[i].size, size)
	// Laced frames follow the default duration.
	testing.expect_value(t, a.samples[1].pts, 1000 * 1_000_000 + 20_000_000)
	want := [?]string{"aa", "bbb", "c", "ddd", "eeee", "ff", "gg", "hh"}
	for w, i in want {
		q, _ := read_sample(&r, 1, i)
		testing.expect_value(t, string(q.data), w)
	}
}

// Every truncation opens with what it has, or fails with an error.
@(test)
truncated_documents_fail_cleanly :: proc(t: ^testing.T) {
	doc := build()
	defer delete(doc)
	for n in 0 ..< len(doc) {
		data := doc[:n]
		r: Reader
		if open_stream(&r, bytes_stream(&data)) == .None {
			for &track, ti in r.tracks do for i in 0 ..< len(track.samples) do read_sample(&r, ti, i)
			close(&r)
		}
	}
}

// Matroska codec IDs beyond WebM's, header stripping, a legacy AAC ID
// without CodecPrivate, and a recording cut off inside its last cluster.
@(private = "file")
build_matroska :: proc() -> [dynamic]u8 {
	doc: [dynamic]u8
	header: [dynamic]u8
	defer delete(header)
	element(&header, u32(ID.Doc_Type), transmute([]u8)string("matroska"))
	element(&doc, u32(ID.EBML), header[:])

	segment, tracks: [dynamic]u8
	defer {delete(segment); delete(tracks)}
	// Track 1: H.264 whose frames lost a 2-byte header to header stripping.
	video, video_track, encodings, encoding, compression: [dynamic]u8
	defer {delete(video); delete(video_track); delete(encodings); delete(encoding); delete(compression)}
	uint_element(&video, u32(ID.Pixel_Width), 320)
	uint_element(&video, u32(ID.Pixel_Height), 240)
	uint_element(&compression, u32(ID.Content_Comp_Algo), 3)
	element(&compression, u32(ID.Content_Comp_Settings), {0x00, 0x00})
	element(&encoding, u32(ID.Content_Compression), compression[:])
	element(&encodings, u32(ID.Content_Encoding), encoding[:])
	uint_element(&video_track, u32(ID.Track_Number), 1)
	uint_element(&video_track, u32(ID.Track_Type), 1)
	element(&video_track, u32(ID.Codec_ID), transmute([]u8)string("V_MPEG4/ISO/AVC"))
	element(&video_track, u32(ID.Codec_Private), {1, 100, 0, 30, 0xFF, 0xE0, 0})
	element(&video_track, u32(ID.Content_Encodings), encodings[:])
	element(&video_track, u32(ID.Video), video[:])
	element(&tracks, u32(ID.Track_Entry), video_track[:])
	// Track 2: legacy AAC-LC ID, 44.1 kHz stereo, no CodecPrivate.
	audio, audio_track: [dynamic]u8
	defer {delete(audio); delete(audio_track)}
	rate := transmute(u64)f64(44100)
	uint_element(&audio, u32(ID.Sampling_Frequency), rate)
	uint_element(&audio, u32(ID.Channels), 2)
	uint_element(&audio_track, u32(ID.Track_Number), 2)
	uint_element(&audio_track, u32(ID.Track_Type), 2)
	element(&audio_track, u32(ID.Codec_ID), transmute([]u8)string("A_AAC/MPEG4/LC"))
	element(&audio_track, u32(ID.Audio), audio[:])
	element(&tracks, u32(ID.Track_Entry), audio_track[:])
	// Track 3: big-endian 24-bit PCM.
	pcm, pcm_track: [dynamic]u8
	defer {delete(pcm); delete(pcm_track)}
	uint_element(&pcm, u32(ID.Channels), 1)
	uint_element(&pcm, u32(ID.Bit_Depth), 24)
	uint_element(&pcm_track, u32(ID.Track_Number), 3)
	uint_element(&pcm_track, u32(ID.Track_Type), 2)
	element(&pcm_track, u32(ID.Codec_ID), transmute([]u8)string("A_PCM/INT/BIG"))
	element(&pcm_track, u32(ID.Audio), pcm[:])
	element(&tracks, u32(ID.Track_Entry), pcm_track[:])
	element(&segment, u32(ID.Tracks), tracks[:])

	cluster: [dynamic]u8
	defer delete(cluster)
	uint_element(&cluster, u32(ID.Timecode), 0)
	element(&cluster, u32(ID.Simple_Block), {0x81, 0, 0, 0x80, 0x00, 0x05, 0x65, 0x88, 0x84, 0x00, 0x10})
	element(&cluster, u32(ID.Simple_Block), {0x81, 0, 33, 0x00, 0x00, 0x03, 0x41, 0x9A, 0x02})
	element(&cluster, u32(ID.Simple_Block), {0x82, 0, 0, 0x80, 0x21, 0x10})
	element(&cluster, u32(ID.Simple_Block), {0x83, 0, 0, 0x80, 1, 2, 3})
	element(&segment, u32(ID.Cluster), cluster[:])
	element(&doc, u32(ID.Segment), segment[:])
	return doc
}

@(test)
matroska_codecs_and_header_stripping :: proc(t: ^testing.T) {
	doc := build_matroska()
	defer delete(doc)
	data := doc[:]
	r: Reader
	err := open_stream(&r, bytes_stream(&data))
	testing.expect_value(t, err, Error.None)
	if err != .None do return
	defer close(&r)
	testing.expect_value(t, len(r.tracks), 3)
	v := &r.tracks[0]
	testing.expect_value(t, v.codec, Codec.H264)
	testing.expect_value(t, len(v.samples), 2)
	p, _ := read_sample(&r, 0, 0)
	// The stripped bytes come back: a 4-byte length then the NAL unit.
	testing.expect_value(t, string(p.data), "\x00\x00\x00\x05\x65\x88\x84\x00\x10")
	q, _ := read_sample(&r, 0, 1)
	testing.expect_value(t, string(q.data), "\x00\x00\x00\x03\x41\x9A\x02")
	a := &r.tracks[1]
	testing.expect_value(t, a.codec, Codec.AAC)
	testing.expect_value(t, a.sample_rate, 44100)
	// Object type 2, rate index 4, two channels, 1024-sample frames.
	testing.expect_value(t, string(a.codec_private), "\x12\x10")
	c := &r.tracks[2]
	testing.expect_value(t, c.codec, Codec.PCM)
	testing.expect_value(t, c.pcm_format, Pcm_Format{bits = 24})

	// Cut inside the cluster: the Segment and Cluster sizes now run past the
	// end, and the blocks before the cut are kept.
	cut := doc[:len(doc) - 5]
	r2: Reader
	err = open_stream(&r2, bytes_stream(&cut))
	testing.expect_value(t, err, Error.None)
	if err != .None do return
	defer close(&r2)
	testing.expect_value(t, len(r2.tracks[0].samples), 2)
	testing.expect_value(t, len(r2.tracks[1].samples), 1)
	testing.expect_value(t, len(r2.tracks[2].samples), 0)
}

@(test)
lc_config_with_explicit_rate :: proc(t: ^testing.T) {
	asc := lc_audio_specific_config(37800, 1)
	defer delete(asc)
	// 5 + 4 + 24 + 4 + 3 bits: type 2, index 15, rate, one channel.
	testing.expect_value(t, len(asc), 5)
	bits: u64
	for b in asc do bits = bits << 8 | u64(b)
	testing.expect_value(t, bits >> 35, 2)
	testing.expect_value(t, bits >> 31 & 15, 15)
	testing.expect_value(t, bits >> 7 & 0xFFFFFF, 37800)
	testing.expect_value(t, bits >> 3 & 15, 1)
}

package mp4

import common "../common"
import "core:testing"

@(private = "file")
avc_sps :: proc(out: ^[dynamic]u8, profile: u32, width_mbs: u32) {
	rbsp: [dynamic]u8
	defer delete(rbsp)
	w := common.init_bit_writer(&rbsp)
	common.write_bits(&w, profile, 8)
	common.write_bits(&w, 0, 8)
	common.write_bits(&w, 30, 8)
	common.write_ue(&w, 0) // seq_parameter_set_id
	if profile == 100 {
		common.write_ue(&w, 1) // chroma_format_idc
		common.write_ue(&w, 0)
		common.write_ue(&w, 0)
		common.write_bits(&w, 0, 1)
		common.write_bits(&w, 0, 1)
	}
	common.write_ue(&w, 0)
	common.write_ue(&w, 2)
	common.write_ue(&w, 1)
	common.write_bits(&w, 0, 1)
	common.write_ue(&w, width_mbs - 1)
	common.write_ue(&w, 3)
	common.write_bits(&w, 3, 2)
	common.write_bits(&w, 0, 2)
	common.write_rbsp_trailing_bits(&w)
	header := [1]u8{0x67}
	common.append_nal_annex_b(out, header[:], rbsp[:])
}

@(private = "file")
avc_pps :: proc(out: ^[dynamic]u8) {
	rbsp: [dynamic]u8
	defer delete(rbsp)
	w := common.init_bit_writer(&rbsp)
	common.write_ue(&w, 0)
	common.write_ue(&w, 0)
	common.write_bits(&w, 0, 3)
	common.write_rbsp_trailing_bits(&w)
	header := [1]u8{0x68}
	common.append_nal_annex_b(out, header[:], rbsp[:], false)
}

@(private = "file")
hevc_sps :: proc(out: ^[dynamic]u8) {
	rbsp: [dynamic]u8
	defer delete(rbsp)
	w := common.init_bit_writer(&rbsp)
	common.write_bits(&w, 0x02, 8) // vps 0, max_sub_layers_minus1 1, no nesting
	ptl := [12]u8{0x01, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 93}
	for b in ptl do common.write_bits(&w, u32(b), 8)
	common.write_bits(&w, 0, 16) // sub-layer flags and reserved bits
	common.write_ue(&w, 0)
	common.write_ue(&w, 1)
	common.write_ue(&w, 64)
	common.write_ue(&w, 48)
	common.write_bits(&w, 0, 1)
	common.write_ue(&w, 2) // 10-bit luma
	common.write_ue(&w, 2)
	common.write_ue(&w, 4)
	common.write_rbsp_trailing_bits(&w)
	header := [2]u8{33 << 1, 1}
	common.append_nal_annex_b(out, header[:], rbsp[:])
}

@(private = "file")
slice_nal :: proc(out: ^[dynamic]u8, type: u8, seed: int, length: int) {
	append(out, 0, 0, 1, 0x60 | type)
	for i in 0 ..< length do append(out, u8(1 + (seed * 31 + i * 7) % 250))
}

@(private = "file")
Frame :: struct {
	pts, dts: i64,
	idr:      bool,
}

// I0 P3 B1 B2 P6 B4 B5 I7 ... with dts shifted so presentation starts at 0.
@(private = "file")
REORDERED := [9]Frame {
	{pts = 0, dts = -2, idr = true},
	{pts = 3, dts = -1},
	{pts = 1, dts = 0},
	{pts = 2, dts = 1},
	{pts = 6, dts = 2},
	{pts = 4, dts = 3},
	{pts = 5, dts = 4},
	{pts = 7, dts = 5, idr = true},
	{pts = 8, dts = 6},
}

@(private = "file")
write_test_movie :: proc(t: ^testing.T, m: ^Memory_Stream, options: Options) {
	frame := i64(512)
	tracks := []Track_Config {
		{codec = .H264, timescale = 15360, width = 64, height = 64, color = BT709_LIMITED, default_duration = u32(frame)},
		{codec = .AAC, timescale = 48000, sample_rate = 48000, channels = 2, audio_specific_config = {0x11, 0x90}, default_duration = 1024},
	}
	w: Writer
	testing.expect_value(t, create_stream(&w, memory_stream(m), tracks, options), Error.None)
	defer destroy(&w)
	audio_next := i64(-1024)
	for f, i in REORDERED {
		// Audio is written ahead of the video that presents at the same time.
		for audio_next * 15360 <= f.dts * frame * 48000 {
			packet: [24]u8
			for &b, j in packet do b = u8(i + j + 1)
			testing.expect_value(t, write_audio_packet(&w, 1, packet[:], audio_next), Error.None)
			audio_next += 1024
		}
		au: [dynamic]u8
		defer delete(au)
		if f.idr {
			append(&au, 0, 0, 0, 1, 0x09, 0xF0) // AUD, dropped
			avc_sps(&au, 100, 4)
			avc_pps(&au)
		}
		slice_nal(&au, f.idr ? 5 : 1, i, 40 + i)
		slice_nal(&au, f.idr ? 5 : 1, i + 100, 10)
		append(&au, 0, 0) // trailing_zero_8bits
		testing.expect_value(t, write_video_packet(&w, 0, au[:], f.pts * frame, f.dts * frame, false), Error.None)
	}
	testing.expect_value(t, set_track_end(&w, 1, 9 * frame * 48000 / 15360 - 100), Error.None)
	testing.expect_value(t, finish(&w), Error.None)
}

@(test)
test_round_trip_reordered_video_and_primed_audio :: proc(t: ^testing.T) {
	for faststart in ([2]bool{false, true}) {
		m: Memory_Stream
		defer delete(m.data)
		write_test_movie(t, &m, {faststart = faststart})
		moov_at, mdat_at := -1, -1
		for pos := 0; pos + 8 <= len(m.data); {
			size := int(get_u32(m.data[pos:]))
			switch get_u32(m.data[pos + 4:]) {
			case fourcc("moov"):
				moov_at = pos
			case fourcc("mdat"):
				mdat_at = pos
			}
			if size < 8 do break
			pos += size
		}
		testing.expect(t, moov_at > 0 && mdat_at > 0)
		testing.expect_value(t, moov_at < mdat_at, faststart)

		r: Reader
		testing.expect_value(t, open_stream(&r, memory_stream(&m)), Error.None)
		defer close(&r)
		testing.expect_value(t, len(r.tracks), 2)
		v := &r.tracks[0]
		testing.expect_value(t, v.codec, Codec.H264)
		testing.expect_value(t, v.kind, Track_Kind.Video)
		testing.expect_value(t, v.width, 64)
		testing.expect_value(t, v.color, BT709_LIMITED)
		testing.expect_value(t, v.nal_length_size, 4)
		testing.expect_value(t, v.config[1], 100) // profile
		testing.expect_value(t, len(v.samples), len(REORDERED))
		testing.expect(t, !v.no_reordering)
		testing.expect_value(t, v.edit.media_time, i64(2 * 512))
		for f, i in REORDERED {
			s := v.samples[i]
			testing.expect_value(t, s.pts, f.pts * 512)
			testing.expect_value(t, s.dts, f.dts * 512)
			testing.expect_value(t, s.sync, f.idr)
			p, err := read_sample(&r, 0, i)
			testing.expect_value(t, err, Error.None)
			// Two length-prefixed slices; parameter sets and the AUD are gone.
			testing.expect_value(t, len(p.data), 4 + 1 + 40 + i + 4 + 1 + 10)
			testing.expect_value(t, int(get_u32(p.data)), 41 + i)
			testing.expect_value(t, p.data[4] & 0x1F, f.idr ? 5 : 1)
			testing.expect_value(t, p.data[5], u8(1 + (i * 31) % 250))
		}
		testing.expect_value(t, sample_at(v, 4 * 512 + 3), 5)
		testing.expect_value(t, sample_at(v, -1), -1)
		testing.expect_value(t, keyframe_at(v, 6 * 512), 0)
		testing.expect_value(t, keyframe_at(v, 8 * 512 + 1), 7)
		testing.expect_value(t, track_end(v), i64(9 * 512))

		a := &r.tracks[1]
		testing.expect_value(t, a.codec, Codec.AAC)
		testing.expect_value(t, a.sample_rate, 48000)
		testing.expect_value(t, a.channels, 2)
		testing.expect_value(t, a.edit.media_time, i64(1024))
		testing.expect_value(t, a.samples[0].pts, i64(-1024))
		testing.expect_value(t, a.samples[1].pts, i64(0))
		testing.expect(t, a.no_reordering)
		// The movie timescale follows the audio rate: trimming is exact.
		testing.expect_value(t, r.movie_timescale, 48000)
		testing.expect_value(t, track_end(a), i64(9 * 512 * 48000 / 15360 - 100))
		p, err := read_sample(&r, 1, 2)
		testing.expect_value(t, err, Error.None)
		testing.expect_value(t, len(p.data), 24)

		// Merged decode order alternates tracks by time.
		previous := f64(-1e9)
		count := 0
		for {
			pkt, e := next_packet(&r)
			if e == .End_Of_Stream do break
			testing.expect_value(t, e, Error.None)
			time := f64(pkt.dts) / f64(r.tracks[pkt.track].timescale)
			testing.expect(t, time >= previous)
			previous = time
			count += 1
		}
		testing.expect_value(t, count, len(v.samples) + len(a.samples))
	}
}

@(test)
test_co64_reads_back :: proc(t: ^testing.T) {
	m: Memory_Stream
	defer delete(m.data)
	write_test_movie(t, &m, {force_co64 = true, faststart = true})
	r: Reader
	testing.expect_value(t, open_stream(&r, memory_stream(&m)), Error.None)
	defer close(&r)
	testing.expect_value(t, len(r.tracks[0].samples), len(REORDERED))
	p, err := read_sample(&r, 0, 3)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, int(get_u32(p.data)), 44)
}

@(test)
test_hevc_configuration_record :: proc(t: ^testing.T) {
	m: Memory_Stream
	defer delete(m.data)
	w: Writer
	testing.expect_value(t, create_stream(&w, memory_stream(&m), {{codec = .H265, timescale = 30, width = 64, height = 48}}), Error.None)
	au: [dynamic]u8
	defer delete(au)
	append(&au, 0, 0, 0, 1, 32 << 1, 1, 0x0C, 0x01, 0xFF) // VPS id 0
	hevc_sps(&au)
	append(&au, 0, 0, 1, 34 << 1, 1, 0xC1, 0x80) // PPS id 0
	append(&au, 0, 0, 1, 19 << 1, 1, 0xAF, 0x11, 0x22) // IDR_W_RADL
	testing.expect_value(t, write_video_packet(&w, 0, au[:], 0, 0, false), Error.None)
	clear(&au)
	append(&au, 0, 0, 1, 1 << 1, 1, 0x80, 0x33)
	testing.expect_value(t, write_video_packet(&w, 0, au[:], 1, 1, false), Error.None)
	testing.expect_value(t, finish(&w), Error.None)
	destroy(&w)

	r: Reader
	testing.expect_value(t, open_stream(&r, memory_stream(&m)), Error.None)
	defer close(&r)
	v := &r.tracks[0]
	testing.expect_value(t, v.codec, Codec.H265)
	testing.expect_value(t, string(v.sample_entry[:]), "hvc1")
	c := v.config
	testing.expect_value(t, c[1], 0x01) // general profile
	testing.expect_value(t, c[12], 93) // general level
	testing.expect_value(t, c[16] & 3, 1) // 4:2:0
	testing.expect_value(t, c[17] & 7, 2) // 10-bit luma
	testing.expect_value(t, (c[21] >> 3) & 7, 2) // temporal layers
	testing.expect_value(t, c[22], 3) // VPS, SPS and PPS arrays
	testing.expect(t, v.samples[0].sync && !v.samples[1].sync)
	testing.expect(t, v.no_reordering)
}

@(test)
test_parameter_sets :: proc(t: ^testing.T) {
	scratch: [dynamic]u8
	defer delete(scratch)
	au: [dynamic]u8
	defer delete(au)
	avc_sps(&au, 100, 4)
	pos := 0
	nal, ok := next_annex_b_nal(au[:], &pos)
	testing.expect(t, ok)
	info, parsed := parse_avc_sps(nal, &scratch)
	testing.expect(t, parsed)
	testing.expect_value(t, info.profile_idc, 100)
	testing.expect_value(t, info.chroma_format_idc, 1)
	testing.expect_value(t, info.bit_depth_luma, 8)

	clear(&au)
	hevc_sps(&au)
	pos = 0
	nal, ok = next_annex_b_nal(au[:], &pos)
	testing.expect(t, ok)
	hinfo, hparsed := parse_hevc_sps(nal, &scratch)
	testing.expect(t, hparsed)
	testing.expect_value(t, hinfo.width, 64)
	testing.expect_value(t, hinfo.height, 48)
	testing.expect_value(t, hinfo.bit_depth_luma, 10)
	testing.expect_value(t, hinfo.max_sub_layers, 2)

	// A different SPS under the same identifier cannot share one sample entry.
	m: Memory_Stream
	defer delete(m.data)
	w: Writer
	testing.expect_value(t, create_stream(&w, memory_stream(&m), {{codec = .H264, timescale = 30, width = 64, height = 64}}), Error.None)
	defer destroy(&w)
	clear(&au)
	avc_sps(&au, 66, 4)
	testing.expect_value(t, write_video_packet(&w, 0, au[:], 0, 0, true), Error.None) // only parameter sets: dropped
	slice_nal(&au, 5, 0, 8)
	testing.expect_value(t, write_video_packet(&w, 0, au[:], 0, 0, true), Error.None)
	clear(&au)
	avc_sps(&au, 66, 5)
	slice_nal(&au, 5, 0, 8)
	testing.expect_value(t, write_video_packet(&w, 0, au[:], 1, 1, true), Error.Unsupported)
}

@(test)
test_annex_b_splitting :: proc(t: ^testing.T) {
	data := []u8{0, 0, 0, 1, 0x65, 1, 2, 0, 0, 1, 0x41, 3, 0, 0, 0, 0, 1, 0x41, 4, 0}
	pos := 0
	lengths: [dynamic]int
	defer delete(lengths)
	for {
		nal, ok := next_annex_b_nal(data, &pos)
		if !ok do break
		append(&lengths, len(nal))
	}
	testing.expect_value(t, len(lengths), 3)
	testing.expect_value(t, lengths[0], 3)
	testing.expect_value(t, lengths[1], 2)
	testing.expect_value(t, lengths[2], 2)
	pos = 0
	_, ok := next_annex_b_nal([]u8{7, 0, 0, 1, 0x65}, &pos)
	testing.expect(t, !ok)
}

@(test)
test_adts_input_supplies_the_audio_config :: proc(t: ^testing.T) {
	m: Memory_Stream
	defer delete(m.data)
	w: Writer
	testing.expect_value(t, create_stream(&w, memory_stream(&m), {{codec = .AAC, timescale = 44100, sample_rate = 44100, channels = 2}}), Error.None)
	// LC, 44.1 kHz (index 4), two channels, 7-byte header + 5 payload bytes.
	frame := []u8{0xFF, 0xF1, 0x50, 0x80, 0x01, 0x9F, 0xFC, 1, 2, 3, 4, 5}
	testing.expect_value(t, write_audio_packet(&w, 0, frame, 0), Error.None)
	testing.expect_value(t, write_audio_packet(&w, 0, frame, 1024), Error.None)
	testing.expect_value(t, finish(&w), Error.None)
	destroy(&w)
	r: Reader
	testing.expect_value(t, open_stream(&r, memory_stream(&m)), Error.None)
	defer close(&r)
	testing.expect_value(t, string(r.major_brand[:]), "M4A ")
	a := &r.tracks[0]
	testing.expect_value(t, len(a.audio_specific_config), 2)
	testing.expect_value(t, a.audio_specific_config[0], 0x12)
	testing.expect_value(t, a.audio_specific_config[1], 0x10)
	testing.expect_value(t, a.sample_rate, 44100)
	p, err := read_sample(&r, 0, 1)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(p.data), 5)
	testing.expect_value(t, a.edit, Edit{})
}

@(test)
test_writer_rejects_non_increasing_dts :: proc(t: ^testing.T) {
	m: Memory_Stream
	defer delete(m.data)
	w: Writer
	testing.expect_value(t, create_stream(&w, memory_stream(&m), {{codec = .AAC, timescale = 48000, sample_rate = 48000, channels = 1, audio_specific_config = {0x11, 0x88}}}), Error.None)
	defer destroy(&w)
	testing.expect_value(t, write_audio_packet(&w, 0, {1, 2}, 0), Error.None)
	testing.expect_value(t, write_audio_packet(&w, 0, {1, 2}, 0), Error.Invalid_Argument)
	testing.expect_value(t, write_audio_packet(&w, 0, {1, 2}, 1024), Error.None)
}

// Every truncation and a sweep of single-byte corruptions must return an
// error or a consistent file, never read out of bounds.
@(test)
test_damaged_files_are_refused_safely :: proc(t: ^testing.T) {
	m: Memory_Stream
	defer delete(m.data)
	write_test_movie(t, &m, {faststart = true})
	original := make([]u8, len(m.data))
	defer delete(original)
	copy(original, m.data[:])
	for n in 0 ..< len(original) {
		cut := Memory_Stream {
			data = make([dynamic]u8, n),
		}
		copy(cut.data[:], original[:n])
		r: Reader
		if open_stream(&r, memory_stream(&cut)) == .None {
			for _, i in r.tracks do for j in 0 ..< len(r.tracks[i].samples) do _, _ = read_sample(&r, i, j)
			close(&r)
		}
		delete(cut.data)
	}
	for i in 0 ..< len(original) {
		for value in ([3]u8{0, 0xFF, 0x80}) {
			copy(m.data[:], original)
			m.data[i] = value
			r: Reader
			if open_stream(&r, memory_stream(&m)) == .None {
				for _, k in r.tracks {
					for j in 0 ..< len(r.tracks[k].samples) do _, _ = read_sample(&r, k, j)
					_ = keyframe_at(&r.tracks[k], 100)
				}
				close(&r)
			}
		}
	}
}

@(test)
test_fragmented_opus_and_alac_entries :: proc(t: ^testing.T) {
	b: [dynamic]u8
	defer delete(b)
	ftyp := begin_box(&b, "ftyp")
	put_type(&b, "M4A ")
	put_u32(&b, 0)
	end_box(&b, ftyp)

	moov := begin_box(&b, "moov")
	mvhd := begin_full_box(&b, "mvhd", 0, 0)
	put_u32(&b, 0)
	put_u32(&b, 0)
	put_u32(&b, 48000)
	put_u32(&b, 0)
	put_zeros(&b, 80)
	end_box(&b, mvhd)

	// Track 1: Opus with dOps (pre_skip = 312, stereo).
	trak1 := begin_box(&b, "trak")
	tkhd1 := begin_full_box(&b, "tkhd", 0, 3)
	put_zeros(&b, 8)
	put_u32(&b, 1) // track_ID = 1
	put_zeros(&b, 68)
	end_box(&b, tkhd1)
	mdia1 := begin_box(&b, "mdia")
	mdhd1 := begin_full_box(&b, "mdhd", 0, 0)
	put_zeros(&b, 8)
	put_u32(&b, 48000)
	put_zeros(&b, 8)
	end_box(&b, mdhd1)
	hdlr1 := begin_full_box(&b, "hdlr", 0, 0)
	put_u32(&b, 0)
	put_type(&b, "soun")
	put_zeros(&b, 13)
	end_box(&b, hdlr1)
	minf1 := begin_box(&b, "minf")
	stbl1 := begin_box(&b, "stbl")
	stsd1 := begin_full_box(&b, "stsd", 0, 0)
	put_u32(&b, 1)
	opus_entry := begin_box(&b, "Opus")
	put_zeros(&b, 16)
	put_u16(&b, 2)
	put_u16(&b, 16)
	put_zeros(&b, 4)
	put_u32(&b, 48000 << 16)
	dops := begin_box(&b, "dOps")
	put_u8(&b, 0)      // Version
	put_u8(&b, 2)      // OutputChannelCount
	put_u16(&b, 312)   // PreSkip
	put_u32(&b, 48000) // InputSampleRate
	put_u16(&b, 0)     // OutputGain
	put_u8(&b, 0)      // ChannelMappingFamily
	end_box(&b, dops)
	end_box(&b, opus_entry)
	end_box(&b, stsd1)
	stsz1 := begin_full_box(&b, "stsz", 0, 0)
	put_u32(&b, 0)
	put_u32(&b, 0) // empty moov sample tables
	end_box(&b, stsz1)
	end_box(&b, stbl1)
	end_box(&b, minf1)
	end_box(&b, mdia1)
	end_box(&b, trak1)

	// Track 2: ALAC (96 kHz stereo, 4096 frame length).
	trak2 := begin_box(&b, "trak")
	tkhd2 := begin_full_box(&b, "tkhd", 0, 3)
	put_zeros(&b, 8)
	put_u32(&b, 2) // track_ID = 2
	put_zeros(&b, 68)
	end_box(&b, tkhd2)
	mdia2 := begin_box(&b, "mdia")
	mdhd2 := begin_full_box(&b, "mdhd", 0, 0)
	put_zeros(&b, 8)
	put_u32(&b, 96000)
	put_zeros(&b, 8)
	end_box(&b, mdhd2)
	hdlr2 := begin_full_box(&b, "hdlr", 0, 0)
	put_u32(&b, 0)
	put_type(&b, "soun")
	put_zeros(&b, 13)
	end_box(&b, hdlr2)
	minf2 := begin_box(&b, "minf")
	stbl2 := begin_box(&b, "stbl")
	stsd2 := begin_full_box(&b, "stsd", 0, 0)
	put_u32(&b, 1)
	alac_entry := begin_box(&b, "alac")
	put_zeros(&b, 16)
	put_u16(&b, 2)
	put_u16(&b, 16)
	put_zeros(&b, 4)
	put_u32(&b, 30464 << 16) // wrapped 16-bit rate, overridden by ALACSpecificConfig
	alac_box := begin_full_box(&b, "alac", 0, 0)
	put_u32(&b, 4096) // frameLength
	put_u8(&b, 0)     // compatibleVersion
	put_u8(&b, 24)    // bitDepth
	put_u8(&b, 40)    // pb
	put_u8(&b, 10)    // mb
	put_u8(&b, 14)    // kb
	put_u8(&b, 2)     // numChannels
	put_u16(&b, 255)  // maxRun
	put_u32(&b, 0)    // maxFrameBytes
	put_u32(&b, 0)    // avgBitRate
	put_u32(&b, 96000) // sampleRate
	end_box(&b, alac_box)
	end_box(&b, alac_entry)
	end_box(&b, stsd2)
	stsz2 := begin_full_box(&b, "stsz", 0, 0)
	put_u32(&b, 0)
	put_u32(&b, 0)
	end_box(&b, stsz2)
	end_box(&b, stbl2)
	end_box(&b, minf2)
	end_box(&b, mdia2)
	end_box(&b, trak2)

	mvex := begin_box(&b, "mvex")
	trex1 := begin_full_box(&b, "trex", 0, 0)
	put_u32(&b, 1)   // track_ID
	put_u32(&b, 1)   // default_sample_description_index
	put_u32(&b, 960) // default_sample_duration
	put_u32(&b, 3)   // default_sample_size
	put_u32(&b, 0)   // default_sample_flags
	end_box(&b, trex1)
	end_box(&b, mvex)
	end_box(&b, moov)

	// Fragment 1: Track 1 with 2 samples of 3 bytes each in mdat.
	moof1_at := len(b)
	moof1 := begin_box(&b, "moof")
	traf1 := begin_box(&b, "traf")
	tfhd1 := begin_full_box(&b, "tfhd", 0, 0x020000) // default-base-is-moof
	put_u32(&b, 1) // track_ID = 1
	end_box(&b, tfhd1)
	tfdt1 := begin_full_box(&b, "tfdt", 0, 0)
	put_u32(&b, 0) // baseMediaDecodeTime = 0
	end_box(&b, tfdt1)
	trun1 := begin_full_box(&b, "trun", 0, 0x000001) // data-offset-present, sizes/durations from trex
	put_u32(&b, 2) // sample_count = 2
	data_off_patch := len(b)
	put_u32(&b, 0)
	end_box(&b, trun1)
	end_box(&b, traf1)
	end_box(&b, moof1)
	mdat1 := begin_box(&b, "mdat")
	patch_u32(&b, data_off_patch, u32(len(b) - moof1_at))
	append(&b, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF)
	end_box(&b, mdat1)

	m := Memory_Stream {
		data = b,
	}
	r: Reader
	testing.expect_value(t, open_stream(&r, memory_stream(&m)), Error.None)
	defer close(&r)
	testing.expect_value(t, len(r.tracks), 2)

	t1 := &r.tracks[0]
	testing.expect_value(t, t1.codec, Codec.Opus)
	testing.expect_value(t, t1.sample_rate, 48000)
	testing.expect_value(t, t1.channels, 2)
	testing.expect_value(t, string(t1.audio_specific_config[:8]), "OpusHead")
	testing.expect_value(t, t1.edit.media_time, i64(312))
	testing.expect_value(t, len(t1.samples), 2)
	testing.expect_value(t, t1.samples[0].pts, i64(-312))
	testing.expect_value(t, t1.samples[1].pts, i64(960 - 312))
	p0, e0 := read_sample(&r, 0, 0)
	testing.expect_value(t, e0, Error.None)
	testing.expect_value(t, p0.data[0], 0xAA)
	p1, e1 := read_sample(&r, 0, 1)
	testing.expect_value(t, e1, Error.None)
	testing.expect_value(t, p1.data[0], 0xDD)

	t2 := &r.tracks[1]
	testing.expect_value(t, t2.codec, Codec.ALAC)
	testing.expect_value(t, t2.sample_rate, 96000)
	testing.expect_value(t, t2.channels, 2)
	testing.expect_value(t, len(t2.audio_specific_config), 24)
	b = m.data
}

@(private = "file")
find_type :: proc(data: []u8, type: string, from := 0) -> int {
	for i in from ..< len(data) - 3 do if string(data[i:i + 4]) == type do return i
	return -1
}

@(test)
test_mvhd_after_trak_keeps_edits :: proc(t: ^testing.T) {
	m: Memory_Stream
	defer delete(m.data)
	write_test_movie(t, &m, {}) // moov last: reordering it moves no chunk
	moov := find_type(m.data[:], "moov") - 4
	size := int(get_u32(m.data[moov:]))
	children: [dynamic]u8
	defer delete(children)
	mvhd: []u8
	for pos := moov + 8; pos < moov + size; {
		n := int(get_u32(m.data[pos:]))
		box := m.data[pos:pos + n]
		if string(box[4:8]) == "mvhd" {mvhd = box} else {append(&children, ..box)}
		pos += n
	}
	append(&children, ..mvhd)
	copy(m.data[moov + 8:], children[:])
	r: Reader
	testing.expect_value(t, open_stream(&r, memory_stream(&m)), Error.None)
	defer close(&r)
	testing.expect_value(t, r.tracks[0].edit.media_time, i64(2 * 512))
	testing.expect_value(t, track_end(&r.tracks[1]), i64(9 * 512 * 48000 / 15360 - 100))
}

@(test)
test_iso_audio_sample_entry_v1 :: proc(t: ^testing.T) {
	m: Memory_Stream
	defer delete(m.data)
	write_test_movie(t, &m, {})
	at := find_type(m.data[:], "mp4a")
	testing.expect(t, at > 12)
	m.data[at - 12] = 1 // stsd version 1
	m.data[at + 12], m.data[at + 13] = 0, 1 // AudioSampleEntryV1: same field layout
	r: Reader
	testing.expect_value(t, open_stream(&r, memory_stream(&m)), Error.None)
	defer close(&r)
	testing.expect_value(t, r.tracks[1].codec, Codec.AAC)
	testing.expect_value(t, len(r.tracks[1].audio_specific_config), 2)
}

@(test)
test_reversed_composition_order_sorts :: proc(t: ^testing.T) {
	N :: 50000
	m: Memory_Stream
	defer delete(m.data)
	w: Writer
	testing.expect_value(t, create_stream(&w, memory_stream(&m), {{codec = .H264, timescale = 1000, width = 64, height = 64}}), Error.None)
	au: [dynamic]u8
	defer delete(au)
	avc_sps(&au, 66, 4)
	avc_pps(&au)
	slice_nal(&au, 5, 0, 4)
	testing.expect_value(t, write_video_packet(&w, 0, au[:], N - 1, 0, true), Error.None)
	clear(&au)
	slice_nal(&au, 1, 1, 4)
	for i in 1 ..< N do testing.expect_value(t, write_video_packet(&w, 0, au[:], i64(N - 1 - i), i64(i), false), Error.None)
	testing.expect_value(t, finish(&w), Error.None)
	destroy(&w)
	r: Reader
	testing.expect_value(t, open_stream(&r, memory_stream(&m)), Error.None)
	defer close(&r)
	v := &r.tracks[0]
	ok := true
	for k in 0 ..< N do if int(v.presentation[k]) != N - 1 - k do ok = false
	testing.expect(t, ok)
}

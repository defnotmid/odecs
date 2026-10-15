package mp4

import "core:io"
import "core:os"

// One output track. Timestamps passed to the writer are in `timescale` units
// on the movie timeline: zero is the start of presentation. Samples before
// zero (AAC priming, B-frame pre-roll) are hidden by an edit list.
Track_Config :: struct {
	codec:                 Codec,
	timescale:             u32, // media ticks per second; audio normally uses the sample rate
	// Video: display size (the cropped size the SPS describes).
	width, height:         int,
	color:                 Color, // `colr` nclx; zero primaries omits the box
	// Audio.
	sample_rate, channels: int,
	audio_specific_config: []u8, // AAC ASC (copied); empty derives it from ADTS input
	// H.265: a prefix SEI NAL unit (header included, no start code; copied)
	// declared in hvcC beside the parameter sets, such as the alpha channel
	// information of a stream with an alpha layer.
	hevc_sei:              []u8,
	// Duration of the final sample when its write call gives none: the frame
	// duration for video, the frame samples for AAC. Zero repeats the
	// preceding sample delta.
	default_duration:      u32,
}

Options :: struct {
	// Write `moov` before `mdat` so progressive download can start playback
	// before the whole file arrives. Finish then moves the media data once.
	faststart:       bool,
	// 0 selects the first audio track's timescale (sample-exact edits for
	// AAC priming and trimming), else the first track's.
	movie_timescale: u32,
	force_co64:      bool, // 64-bit chunk offsets even when 32 bits suffice
}

Writer :: struct {
	stream:         io.Stream,
	file:           ^os.File, // owned when created from a path
	options:        Options,
	tracks:         [dynamic]Track_Writer,
	staging:        [dynamic]u8, // sample bytes not yet written, starting at staging_offset
	staging_offset: i64,
	mdat_start:     i64,
	last_track:     int, // track of the previous sample, for chunking
	sample:         Open_Sample,
	scratch:        [dynamic]u8,
	failed:         bool,
	finished:       bool,
}

@(private)
Open_Sample :: struct {
	track:     int,
	pts, dts:  i64,
	size:      u32,
	duration:  u32,
	irap:      bool,
	active:    bool,
	new_chunk: bool, // begin_sample opened a chunk for this sample
	previous:  int, // last_track before begin_sample
}

@(private)
Sample_Record :: struct {
	size: u32,
	dts:  i64,
	pts:  i64,
}

@(private)
Parameter_Set :: struct {
	type: u8,
	id:   u32,
	data: []u8,
}

@(private)
Track_Writer :: struct {
	config:         Track_Config,
	samples:        #soa[dynamic]Sample_Record,
	sync:           [dynamic]u32, // 1-based sample numbers
	chunk_offsets:  [dynamic]i64,
	chunk_first:    [dynamic]u32, // first sample index of each chunk
	parameter_sets: [dynamic]Parameter_Set,
	last_duration:  u32,
	end_pts:        i64,
	has_end:        bool,
	max_size:       u32,
	bytes:          u64,
}

STAGING_FLUSH :: 4 << 20

// Creates (truncating) the file at path.
create :: proc(w: ^Writer, path: string, tracks: []Track_Config, options := Options{}) -> Error {
	f, err := os.open(path, {.Read, .Write, .Create, .Trunc}, os.Permissions_Default_File)
	if err != nil do return .IO_Error
	if e := create_stream(w, os.to_stream(f), tracks, options); e != .None {
		os.close(f)
		return e
	}
	w.file = f
	return .None
}

// Writes to a stream at offsets from zero. The stream needs Write_At, and
// Read_At as well for faststart. The writer borrows it until finish/destroy.
create_stream :: proc(w: ^Writer, stream: io.Stream, tracks: []Track_Config, options := Options{}) -> Error {
	if w == nil || len(tracks) == 0 || len(tracks) > 255 do return .Invalid_Argument
	modes := io.query(stream)
	if .Write_At not_in modes || (options.faststart && .Read_At not_in modes) do return .Invalid_Argument
	for t in tracks {
		if t.timescale == 0 do return .Invalid_Argument
		switch t.codec {
		case .H264, .H265:
			if t.width <= 0 || t.height <= 0 || t.width > 65535 || t.height > 65535 do return .Invalid_Argument
		case .AAC:
			if t.sample_rate <= 0 || t.channels <= 0 || t.channels > 255 do return .Invalid_Argument
		case .ProRes, .PCM, .FLAC, .MP3, .AV1, .ALAC, .Opus:
			return .Unsupported // sample entries that are read, not yet written
		case .Unknown:
			return .Invalid_Argument
		}
	}
	w^ = {
		stream     = stream,
		options    = options,
		last_track = -1,
	}
	if w.options.movie_timescale == 0 {
		w.options.movie_timescale = tracks[0].timescale
		for t in tracks do if t.codec == .AAC {w.options.movie_timescale = t.timescale; break}
	}
	for t in tracks {
		tw := Track_Writer {
			config = t,
		}
		tw.config.audio_specific_config = nil
		if len(t.audio_specific_config) > 0 {
			asc, err := make([]u8, len(t.audio_specific_config))
			if err != nil {destroy(w); return .Out_Of_Memory}
			copy(asc, t.audio_specific_config)
			tw.config.audio_specific_config = asc
		}
		tw.config.hevc_sei = nil
		if len(t.hevc_sei) > 0 {
			sei, err := make([]u8, len(t.hevc_sei))
			if err != nil {destroy(w); return .Out_Of_Memory}
			copy(sei, t.hevc_sei)
			tw.config.hevc_sei = sei
		}
		append(&w.tracks, tw)
	}
	head: [dynamic]u8
	defer delete(head)
	write_ftyp(w, &head)
	// `wide` reserves room to widen the mdat header to 64 bits at finish.
	put_u32(&head, 8)
	put_type(&head, "wide")
	w.mdat_start = i64(len(head))
	put_u32(&head, 0)
	put_type(&head, "mdat")
	if err := write_all_at(w.stream, head[:], 0); err != .None {destroy(w); return err}
	w.staging_offset = i64(len(head))
	reserve(&w.staging, 1 << 20)
	return .None
}

@(private)
write_ftyp :: proc(w: ^Writer, b: ^[dynamic]u8) {
	all_audio := true
	for t in w.tracks do if t.config.codec != .AAC do all_audio = false
	start := begin_box(b, "ftyp")
	if all_audio {
		put_type(b, "M4A ")
		put_u32(b, 0x200)
		put_type(b, "M4A ")
		put_type(b, "isom")
		put_type(b, "iso2")
		put_type(b, "mp41")
	} else {
		put_type(b, "isom")
		put_u32(b, 0x200)
		put_type(b, "isom")
		put_type(b, "iso2")
		for t in w.tracks do if t.config.codec == .H264 {put_type(b, "avc1"); break}
		put_type(b, "mp41")
	}
	end_box(b, start)
}

// Releases writer memory and closes an owned file without finishing it.
destroy :: proc(w: ^Writer) {
	if w == nil do return
	for &t in w.tracks {
		delete(t.config.audio_specific_config)
		delete(t.config.hevc_sei)
		delete(t.samples)
		delete(t.sync)
		delete(t.chunk_offsets)
		delete(t.chunk_first)
		for p in t.parameter_sets do delete(p.data)
		delete(t.parameter_sets)
	}
	delete(w.tracks)
	delete(w.staging)
	delete(w.scratch)
	if w.file != nil do os.close(w.file)
	w^ = {}
}

@(private)
flush_staging :: proc(w: ^Writer) -> Error {
	if len(w.staging) == 0 do return .None
	if err := write_all_at(w.stream, w.staging[:], w.staging_offset); err != .None do return err
	w.staging_offset += i64(len(w.staging))
	clear(&w.staging)
	return .None
}

@(private)
append_payload :: proc(w: ^Writer, data: []u8) -> Error {
	if _, err := append(&w.staging, ..data); err != nil do return .Out_Of_Memory
	if len(w.staging) >= STAGING_FLUSH do return flush_staging(w)
	return .None
}

// Opens a sample (one access unit). Its bytes follow through add_nal,
// add_annex_b or add_bytes, then end_sample. dts must increase strictly per
// track. duration is used only if this turns out to be the track's last sample.
begin_sample :: proc(w: ^Writer, track: int, pts, dts: i64, duration: u32 = 0) -> Error {
	if w == nil || w.stream.procedure == nil do return .Closed
	if w.failed || w.finished do return .Closed
	if w.sample.active || track < 0 || track >= len(w.tracks) do return .Invalid_Argument
	t := &w.tracks[track]
	n := len(t.samples)
	if n >= MAX_SAMPLES do return .Unsupported
	if n > 0 && dts <= t.samples[n - 1].dts do return .Invalid_Argument
	if n > 0 && dts - t.samples[n - 1].dts > i64(max(u32)) do return .Invalid_Argument
	if pts - dts > i64(max(i32)) || dts - pts > i64(max(i32)) do return .Invalid_Argument
	w.sample = {
		track    = track,
		pts      = pts,
		dts      = dts,
		duration = duration,
		active   = true,
		previous = w.last_track,
	}
	if w.last_track != track {
		append(&t.chunk_offsets, w.staging_offset + i64(len(w.staging)))
		append(&t.chunk_first, u32(n))
		w.last_track = track
		w.sample.new_chunk = true
	}
	return .None
}

// Reports whether begin_sample has opened a sample that end_sample has not
// yet closed.
sample_open :: proc(w: ^Writer) -> bool {return w.sample.active}

// Adds one NAL unit (header included, no start code or length prefix) to the
// open video sample. Parameter sets move into the codec configuration record
// and access unit delimiters are dropped; other units are length-prefixed.
add_nal :: proc(w: ^Writer, nal: []u8) -> Error {
	if !w.sample.active do return .Invalid_Argument
	t := &w.tracks[w.sample.track]
	if len(nal) == 0 do return .Invalid_Argument
	type: u8
	switch t.config.codec {
	case .H264:
		type = nal[0] & 0x1F
		switch type {
		case 7, 8:
			return capture_parameter_set(w, t, type, nal)
		case 9:
			return .None
		case 5:
			w.sample.irap = true
		}
	case .H265:
		if len(nal) < 2 do return .Invalid_Argument
		type = (nal[0] >> 1) & 0x3F
		switch type {
		case 32, 33, 34:
			return capture_parameter_set(w, t, type, nal)
		case 35:
			return .None
		case 16 ..= 21:
			w.sample.irap = true
		}
	case .AAC, .Unknown, .ProRes, .PCM, .FLAC, .MP3, .AV1, .ALAC, .Opus:
		return .Invalid_Argument
	}
	if len(nal) > int(max(u32)) - 4 - int(w.sample.size) do return .Unsupported
	prefix := [4]u8{u8(len(nal) >> 24), u8(len(nal) >> 16), u8(len(nal) >> 8), u8(len(nal))}
	append_payload(w, prefix[:]) or_return
	append_payload(w, nal) or_return
	w.sample.size += u32(4 + len(nal))
	return .None
}

// Adds the NAL units of complete Annex-B data to the open video sample.
add_annex_b :: proc(w: ^Writer, data: []u8) -> Error {
	pos := 0
	count := 0
	for {
		nal, ok := next_annex_b_nal(data, &pos)
		if !ok do break
		add_nal(w, nal) or_return
		count += 1
	}
	return count == 0 ? .Invalid_Data : .None
}

// Adds raw bytes to the open audio sample.
add_bytes :: proc(w: ^Writer, data: []u8) -> Error {
	if !w.sample.active || w.tracks[w.sample.track].config.codec != .AAC do return .Invalid_Argument
	if len(data) > int(max(u32)) - int(w.sample.size) do return .Unsupported
	append_payload(w, data) or_return
	w.sample.size += u32(len(data))
	return .None
}

// Closes the open sample. A video sample containing an IDR/IRAP picture is a
// sync sample even when keyframe is false. A sample that carried only
// parameter sets or delimiters is dropped: its sets are kept for the sample
// entry and its timestamps are discarded.
end_sample :: proc(w: ^Writer, keyframe: bool) -> Error {
	if !w.sample.active do return .Invalid_Argument
	s := w.sample
	w.sample = {}
	t := &w.tracks[s.track]
	if s.size == 0 {
		if s.new_chunk {
			pop(&t.chunk_offsets)
			pop(&t.chunk_first)
			w.last_track = s.previous
		}
		return .None
	}
	append(&t.samples, Sample_Record{size = s.size, dts = s.dts, pts = s.pts})
	if keyframe || s.irap || t.config.codec == .AAC do append(&t.sync, u32(len(t.samples)))
	t.last_duration = s.duration
	t.max_size = max(t.max_size, s.size)
	t.bytes += u64(s.size)
	return .None
}

@(private)
capture_parameter_set :: proc(w: ^Writer, t: ^Track_Writer, type: u8, nal: []u8) -> Error {
	id, ok := parameter_set_id(t.config.codec, nal, &w.scratch)
	if !ok do return .Invalid_Data
	for p in t.parameter_sets {
		if p.type != type || p.id != id do continue
		if string(p.data) == string(nal) do return .None
		// avc1/hvc1 carry one fixed set per identifier in the sample entry.
		return .Unsupported
	}
	if len(t.parameter_sets) >= 64 || len(nal) > 65535 do return .Unsupported
	data, err := make([]u8, len(nal))
	if err != nil do return .Out_Of_Memory
	copy(data, nal)
	append(&t.parameter_sets, Parameter_Set{type = type, id = id, data = data})
	return .None
}

Video_Framing :: enum {
	Annex_B,         // start-code delimited
	Length_Prefixed, // 4-byte big-endian lengths, as stored in MP4
}

// Writes one complete video access unit.
write_video_packet :: proc(
	w: ^Writer,
	track: int,
	data: []u8,
	pts, dts: i64,
	keyframe: bool,
	framing := Video_Framing.Annex_B,
	duration: u32 = 0,
) -> Error {
	begin_sample(w, track, pts, dts, duration) or_return
	err: Error
	if framing == .Annex_B {
		err = add_annex_b(w, data)
	} else {
		for pos := 0; err == .None && pos < len(data); {
			if pos + 4 > len(data) {err = .Invalid_Data; break}
			size := int(get_u32(data[pos:]))
			if size == 0 || size > len(data) - pos - 4 {err = .Invalid_Data; break}
			err = add_nal(w, data[pos + 4:][:size])
			pos += 4 + size
		}
	}
	if err != .None {
		w.failed = true // bytes of a partial sample may already be staged
		return err
	}
	return end_sample(w, keyframe)
}

// Writes one access unit given as separate NAL units.
write_video_nals :: proc(w: ^Writer, track: int, nals: [][]u8, pts, dts: i64, keyframe: bool, duration: u32 = 0) -> Error {
	begin_sample(w, track, pts, dts, duration) or_return
	for nal in nals {
		if err := add_nal(w, nal); err != .None {w.failed = true; return err}
	}
	return end_sample(w, keyframe)
}

// Writes one AAC access unit. An ADTS header is stripped; when the track has
// no AudioSpecificConfig the first header supplies it.
write_audio_packet :: proc(w: ^Writer, track: int, data: []u8, pts: i64, duration: u32 = 0) -> Error {
	if w == nil || track < 0 || track >= len(w.tracks) || w.tracks[track].config.codec != .AAC do return .Invalid_Argument
	payload := data
	if len(data) >= 7 && data[0] == 0xFF && data[1] & 0xF6 == 0xF0 {
		header := 7 if data[1] & 1 == 1 else 9
		frame := int(data[3] & 3) << 11 | int(data[4]) << 3 | int(data[5] >> 5)
		if data[6] & 3 != 0 || frame < header || frame > len(data) do return .Unsupported
		t := &w.tracks[track]
		if len(t.config.audio_specific_config) == 0 {
			object := int(data[2] >> 6) + 1
			index := int(data[2] >> 2) & 15
			channels := int(data[2] & 1) << 2 | int(data[3] >> 6)
			if channels == 0 do return .Unsupported
			asc, err := make([]u8, 2)
			if err != nil do return .Out_Of_Memory
			asc[0] = u8(object << 3 | index >> 1)
			asc[1] = u8((index & 1) << 7 | channels << 3)
			t.config.audio_specific_config = asc
		}
		payload = data[header:frame]
	}
	if len(payload) == 0 do return .Invalid_Argument
	begin_sample(w, track, pts, pts, duration) or_return
	if err := add_bytes(w, payload); err != .None {w.failed = true; return err}
	return end_sample(w, true)
}

// Ends the track's presentation at end_pts (in its timescale), for example to
// trim AAC padding to the original input length.
set_track_end :: proc(w: ^Writer, track: int, end_pts: i64) -> Error {
	if w == nil || track < 0 || track >= len(w.tracks) do return .Invalid_Argument
	w.tracks[track].end_pts = end_pts
	w.tracks[track].has_end = true
	return .None
}

// Writes the sample tables and closes an owned file. The writer must still
// be destroyed afterwards to release memory.
finish :: proc(w: ^Writer) -> Error {
	if w == nil || w.stream.procedure == nil || w.finished do return .Closed
	if w.failed do return .Closed
	if w.sample.active do return .Invalid_Argument
	w.finished = true
	for t in w.tracks {
		if len(t.samples) == 0 do continue
		if t.config.codec == .AAC && len(t.config.audio_specific_config) == 0 do return .Invalid_Data
		if t.config.codec == .H264 || t.config.codec == .H265 {
			has_sps := false
			for p in t.parameter_sets do if p.type == 7 || p.type == 33 do has_sps = true
			if !has_sps do return .Invalid_Data
		}
	}
	flush_staging(w) or_return
	end := w.staging_offset
	mdat_size := end - w.mdat_start
	if mdat_size <= i64(max(u32)) {
		size: [4]u8 = {u8(mdat_size >> 24), u8(mdat_size >> 16), u8(mdat_size >> 8), u8(mdat_size)}
		write_all_at(w.stream, size[:], w.mdat_start) or_return
	} else {
		// Widen over the `wide` box: the payload offset stays the same.
		header: [dynamic]u8
		defer delete(header)
		put_u32(&header, 1)
		put_type(&header, "mdat")
		put_u64(&header, u64(mdat_size + 8))
		write_all_at(w.stream, header[:], w.mdat_start - 8) or_return
	}
	moov: [dynamic]u8
	defer delete(moov)
	if !w.options.faststart {
		build_moov(w, &moov, 0) or_return
		write_all_at(w.stream, moov[:], end) or_return
	} else {
		// Chunk offsets grow by the moov size, which itself grows when a
		// track's offsets cross 32 bits (co64). Each rebuild can only switch
		// more tracks, so the fixed point arrives within tracks + 1 rebuilds.
		shift := 0
		stable := false
		for _ in 0 ..< len(w.tracks) + 2 {
			clear(&moov)
			build_moov(w, &moov, i64(shift)) or_return
			if len(moov) == shift {stable = true; break}
			shift = len(moov)
		}
		if !stable do return .Invalid_Data
		ftyp_end := w.mdat_start - 8
		// Move [ftyp_end, end) forward by the moov size, last block first.
		block, alloc_err := make([]u8, STAGING_FLUSH)
		if alloc_err != nil do return .Out_Of_Memory
		defer delete(block)
		for pos := end; pos > ftyp_end; {
			n := min(i64(len(block)), pos - ftyp_end)
			pos -= n
			read_all_at(w.stream, block[:n], pos) or_return
			write_all_at(w.stream, block[:n], pos + i64(shift)) or_return
		}
		write_all_at(w.stream, moov[:], ftyp_end) or_return
	}
	if w.file != nil {
		err := os.close(w.file)
		w.file = nil
		w.stream = {}
		if err != nil do return .IO_Error
	}
	return .None
}

@(private)
rescale :: proc(v: i64, from, to: u32) -> i64 {
	return i64((i128(v) * i128(to) + i128(from / 2)) / i128(from))
}

@(private)
Track_Timing :: struct {
	media_duration:   i64, // media timescale
	media_time:       i64, // first presented media time
	empty_edit:       i64, // movie timescale
	segment_duration: i64, // movie timescale
	edit:             bool,
}

@(private)
track_timing :: proc(w: ^Writer, t: ^Track_Writer) -> (timing: Track_Timing) {
	n := len(t.samples)
	if n == 0 do return
	last := t.last_duration
	if last == 0 do last = t.config.default_duration
	if last == 0 do last = n > 1 ? u32(t.samples[n - 1].dts - t.samples[n - 2].dts) : 1
	d0 := t.samples[0].dts
	timing.media_duration = t.samples[n - 1].dts - d0 + i64(last)
	first, end := t.samples[0].pts, t.samples[0].pts + i64(last)
	for s in t.samples {
		first = min(first, s.pts)
		end = max(end, s.pts + i64(last))
	}
	if t.has_end do end = t.end_pts
	start := max(first, 0)
	end = max(end, start)
	timing.media_time = start - d0
	timing.empty_edit = rescale(start, t.config.timescale, w.options.movie_timescale)
	timing.segment_duration = rescale(end - start, t.config.timescale, w.options.movie_timescale)
	timing.edit = timing.media_time != 0 || timing.empty_edit != 0 || end - start != timing.media_duration
	return
}

@(private)
build_moov :: proc(w: ^Writer, b: ^[dynamic]u8, shift: i64) -> Error {
	movie_duration: i64
	timings, alloc_err := make([]Track_Timing, len(w.tracks))
	if alloc_err != nil do return .Out_Of_Memory
	defer delete(timings)
	for &t, i in w.tracks {
		timings[i] = track_timing(w, &t)
		movie_duration = max(movie_duration, timings[i].empty_edit + timings[i].segment_duration)
	}
	moov := begin_box(b, "moov")
	wide := movie_duration > i64(max(u32))
	mvhd := begin_full_box(b, "mvhd", wide ? 1 : 0, 0)
	if wide {
		put_u64(b, 0)
		put_u64(b, 0)
		put_u32(b, w.options.movie_timescale)
		put_u64(b, u64(movie_duration))
	} else {
		put_u32(b, 0)
		put_u32(b, 0)
		put_u32(b, w.options.movie_timescale)
		put_u32(b, u32(movie_duration))
	}
	put_u32(b, 0x00010000) // rate
	put_u16(b, 0x0100) // volume
	put_zeros(b, 10)
	put_matrix(b)
	put_zeros(b, 24)
	put_u32(b, u32(len(w.tracks) + 1)) // next_track_ID
	end_box(b, mvhd)
	for &t, i in w.tracks {
		if len(t.samples) == 0 do continue
		build_trak(w, b, &t, u32(i + 1), timings[i], shift) or_return
	}
	end_box(b, moov)
	return .None
}

@(private)
put_matrix :: proc(b: ^[dynamic]u8) {
	put_u32(b, 0x00010000)
	put_u32(b, 0)
	put_u32(b, 0)
	put_u32(b, 0)
	put_u32(b, 0x00010000)
	put_u32(b, 0)
	put_u32(b, 0)
	put_u32(b, 0)
	put_u32(b, 0x40000000)
}

@(private)
build_trak :: proc(w: ^Writer, b: ^[dynamic]u8, t: ^Track_Writer, id: u32, timing: Track_Timing, shift: i64) -> Error {
	video := t.config.codec != .AAC
	trak := begin_box(b, "trak")
	duration := timing.empty_edit + timing.segment_duration
	wide := duration > i64(max(u32)) || timing.media_duration > i64(max(u32))
	tkhd := begin_full_box(b, "tkhd", wide ? 1 : 0, 3) // enabled, in movie
	if wide {
		put_u64(b, 0)
		put_u64(b, 0)
		put_u32(b, id)
		put_u32(b, 0)
		put_u64(b, u64(duration))
	} else {
		put_u32(b, 0)
		put_u32(b, 0)
		put_u32(b, id)
		put_u32(b, 0)
		put_u32(b, u32(duration))
	}
	put_zeros(b, 8)
	put_u16(b, 0) // layer
	put_u16(b, 0) // alternate_group
	put_u16(b, video ? 0 : 0x0100)
	put_u16(b, 0)
	put_matrix(b)
	put_u32(b, video ? u32(t.config.width) << 16 : 0)
	put_u32(b, video ? u32(t.config.height) << 16 : 0)
	end_box(b, tkhd)
	if timing.edit {
		edts := begin_box(b, "edts")
		entries := timing.empty_edit > 0 ? 2 : 1
		elst_wide := wide || timing.media_time > i64(max(i32))
		elst := begin_full_box(b, "elst", elst_wide ? 1 : 0, 0)
		put_u32(b, u32(entries))
		if timing.empty_edit > 0 {
			if elst_wide {put_u64(b, u64(timing.empty_edit)); put_u64(b, max(u64))} else {put_u32(b, u32(timing.empty_edit)); put_u32(b, max(u32))}
			put_u32(b, 0x00010000)
		}
		if elst_wide {put_u64(b, u64(timing.segment_duration)); put_u64(b, u64(timing.media_time))} else {put_u32(b, u32(timing.segment_duration)); put_u32(b, u32(timing.media_time))}
		put_u32(b, 0x00010000) // media_rate 1.0
		end_box(b, elst)
		end_box(b, edts)
	}
	mdia := begin_box(b, "mdia")
	mdhd := begin_full_box(b, "mdhd", wide ? 1 : 0, 0)
	if wide {
		put_u64(b, 0)
		put_u64(b, 0)
		put_u32(b, t.config.timescale)
		put_u64(b, u64(timing.media_duration))
	} else {
		put_u32(b, 0)
		put_u32(b, 0)
		put_u32(b, t.config.timescale)
		put_u32(b, u32(timing.media_duration))
	}
	put_u16(b, 0x55C4) // 'und'
	put_u16(b, 0)
	end_box(b, mdhd)
	hdlr := begin_full_box(b, "hdlr", 0, 0)
	put_u32(b, 0)
	put_type(b, video ? "vide" : "soun")
	put_zeros(b, 12)
	name := video ? "VideoHandler" : "SoundHandler"
	append(b, ..transmute([]u8)name)
	put_u8(b, 0)
	end_box(b, hdlr)
	minf := begin_box(b, "minf")
	if video {
		vmhd := begin_full_box(b, "vmhd", 0, 1)
		put_zeros(b, 8)
		end_box(b, vmhd)
	} else {
		smhd := begin_full_box(b, "smhd", 0, 0)
		put_zeros(b, 4)
		end_box(b, smhd)
	}
	dinf := begin_box(b, "dinf")
	dref := begin_full_box(b, "dref", 0, 0)
	put_u32(b, 1)
	url := begin_full_box(b, "url ", 0, 1) // media in this file
	end_box(b, url)
	end_box(b, dref)
	end_box(b, dinf)
	build_stbl(w, b, t, id, timing, shift) or_return
	end_box(b, minf)
	end_box(b, mdia)
	end_box(b, trak)
	return .None
}

@(private)
build_stbl :: proc(w: ^Writer, b: ^[dynamic]u8, t: ^Track_Writer, id: u32, timing: Track_Timing, shift: i64) -> Error {
	n := len(t.samples)
	stbl := begin_box(b, "stbl")
	stsd := begin_full_box(b, "stsd", 0, 0)
	put_u32(b, 1)
	switch t.config.codec {
	case .H264, .H265:
		build_visual_entry(w, b, t) or_return
	case .AAC:
		build_audio_entry(b, t, id, timing)
	case .Unknown, .ProRes, .PCM, .FLAC, .MP3, .AV1, .ALAC, .Opus:
		return .Invalid_Argument
	}
	end_box(b, stsd)

	// stts: run-length decode deltas; the last sample uses the duration that
	// completes media_duration.
	stts := begin_full_box(b, "stts", 0, 0)
	count_at := len(b)
	put_u32(b, 0)
	entries: u32
	run_delta, run_count: u32
	for i in 0 ..< n {
		delta := u32(i + 1 < n ? t.samples[i + 1].dts - t.samples[i].dts : timing.media_duration - (t.samples[n - 1].dts - t.samples[0].dts))
		if run_count > 0 && delta == run_delta {run_count += 1; continue}
		if run_count > 0 {put_u32(b, run_count); put_u32(b, run_delta); entries += 1}
		run_delta, run_count = delta, 1
	}
	put_u32(b, run_count)
	put_u32(b, run_delta)
	entries += 1
	patch_u32(b, count_at, entries)
	end_box(b, stts)

	has_cts, negative := false, false
	for s in t.samples {
		if s.pts != s.dts do has_cts = true
		if s.pts < s.dts do negative = true
	}
	if has_cts {
		ctts := begin_full_box(b, "ctts", negative ? 1 : 0, 0)
		count_at = len(b)
		put_u32(b, 0)
		entries = 0
		run_offset: i64
		run_count = 0
		for s in t.samples {
			offset := s.pts - s.dts
			if run_count > 0 && offset == run_offset {run_count += 1; continue}
			if run_count > 0 {put_u32(b, run_count); put_u32(b, u32(i32(run_offset))); entries += 1}
			run_offset, run_count = offset, 1
		}
		put_u32(b, run_count)
		put_u32(b, u32(i32(run_offset)))
		entries += 1
		patch_u32(b, count_at, entries)
		end_box(b, ctts)
	}

	if len(t.sync) != n {
		stss := begin_full_box(b, "stss", 0, 0)
		put_u32(b, u32(len(t.sync)))
		for s in t.sync do put_u32(b, s)
		end_box(b, stss)
	}

	chunks := len(t.chunk_offsets)
	stsc := begin_full_box(b, "stsc", 0, 0)
	count_at = len(b)
	put_u32(b, 0)
	entries = 0
	previous: u32 = 0
	for c in 0 ..< chunks {
		next := c + 1 < chunks ? t.chunk_first[c + 1] : u32(n)
		per_chunk := next - t.chunk_first[c]
		if per_chunk == previous do continue
		put_u32(b, u32(c + 1))
		put_u32(b, per_chunk)
		put_u32(b, 1)
		entries += 1
		previous = per_chunk
	}
	patch_u32(b, count_at, entries)
	end_box(b, stsc)

	stsz := begin_full_box(b, "stsz", 0, 0)
	put_u32(b, 0)
	put_u32(b, u32(n))
	for s in t.samples do put_u32(b, s.size)
	end_box(b, stsz)

	co64 := w.options.force_co64
	for o in t.chunk_offsets do if o + shift > i64(max(u32)) do co64 = true
	stco := begin_full_box(b, co64 ? "co64" : "stco", 0, 0)
	put_u32(b, u32(chunks))
	for o in t.chunk_offsets {
		if co64 {put_u64(b, u64(o + shift))} else {put_u32(b, u32(o + shift))}
	}
	end_box(b, stco)
	end_box(b, stbl)
	return .None
}

@(private)
patch_u32 :: proc(b: ^[dynamic]u8, at: int, v: u32) {
	b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

@(private)
build_visual_entry :: proc(w: ^Writer, b: ^[dynamic]u8, t: ^Track_Writer) -> Error {
	h264 := t.config.codec == .H264
	entry := begin_box(b, h264 ? "avc1" : "hvc1")
	put_zeros(b, 6)
	put_u16(b, 1) // data_reference_index
	put_zeros(b, 16)
	put_u16(b, u16(t.config.width))
	put_u16(b, u16(t.config.height))
	put_u32(b, 0x00480000) // 72 dpi
	put_u32(b, 0x00480000)
	put_u32(b, 0)
	put_u16(b, 1) // frame_count
	put_zeros(b, 32) // compressorname
	put_u16(b, 0x0018)
	put_u16(b, 0xFFFF)
	if h264 {build_avcc(w, b, t) or_return} else {build_hvcc(w, b, t) or_return}
	if t.config.color.primaries != 0 {
		colr := begin_box(b, "colr")
		put_type(b, "nclx")
		put_u16(b, u16(t.config.color.primaries))
		put_u16(b, u16(t.config.color.transfer))
		put_u16(b, u16(t.config.color.matrix_coeffs))
		put_u8(b, t.config.color.full_range ? 0x80 : 0)
		end_box(b, colr)
	}
	pasp := begin_box(b, "pasp")
	put_u32(b, 1)
	put_u32(b, 1)
	end_box(b, pasp)
	end_box(b, entry)
	return .None
}

@(private)
build_avcc :: proc(w: ^Writer, b: ^[dynamic]u8, t: ^Track_Writer) -> Error {
	sps: Avc_Sps_Info
	found := false
	sps_count, pps_count := 0, 0
	for p in t.parameter_sets {
		if p.type == 7 {
			if !found {
				ok: bool
				sps, ok = parse_avc_sps(p.data, &w.scratch)
				if !ok do return .Invalid_Data
				found = true
			}
			sps_count += 1
		} else {
			pps_count += 1
		}
	}
	if !found || sps_count > 31 || pps_count > 255 do return .Invalid_Data
	avcc := begin_box(b, "avcC")
	put_u8(b, 1)
	put_u8(b, sps.profile_idc)
	put_u8(b, sps.constraint_flags)
	put_u8(b, sps.level_idc)
	put_u8(b, 0xFC | 3) // four-byte NAL lengths
	put_u8(b, 0xE0 | u8(sps_count))
	for p in t.parameter_sets do if p.type == 7 {put_u16(b, u16(len(p.data))); append(b, ..p.data)}
	put_u8(b, u8(pps_count))
	for p in t.parameter_sets do if p.type == 8 {put_u16(b, u16(len(p.data))); append(b, ..p.data)}
	switch sps.profile_idc {
	case 66, 77, 88:
	case:
		put_u8(b, 0xFC | sps.chroma_format_idc)
		put_u8(b, 0xF8 | (sps.bit_depth_luma - 8))
		put_u8(b, 0xF8 | (sps.bit_depth_chroma - 8))
		put_u8(b, 0)
	}
	end_box(b, avcc)
	return .None
}

@(private)
build_hvcc :: proc(w: ^Writer, b: ^[dynamic]u8, t: ^Track_Writer) -> Error {
	sps: Hevc_Sps_Info
	found := false
	for p in t.parameter_sets {
		if p.type != 33 || hevc_layer_id(p.data) != 0 do continue
		ok: bool
		sps, ok = parse_hevc_sps(p.data, &w.scratch)
		if !ok do return .Invalid_Data
		found = true
		break
	}
	if !found do return .Invalid_Data
	hvcc := begin_box(b, "hvcC")
	put_u8(b, 1)
	append(b, ..sps.general_ptl[:])
	put_u16(b, 0xF000) // min_spatial_segmentation_idc unknown
	put_u8(b, 0xFC) // parallelismType unknown
	put_u8(b, 0xFC | sps.chroma_format_idc)
	put_u8(b, 0xF8 | (sps.bit_depth_luma - 8))
	put_u8(b, 0xF8 | (sps.bit_depth_chroma - 8))
	put_u16(b, 0) // avgFrameRate unspecified
	put_u8(b, (sps.max_sub_layers & 7) << 3 | (sps.temporal_id_nesting ? 4 : 0) | 3)
	arrays := len(t.config.hevc_sei) > 0 ? 1 : 0
	for type in ([3]u8{32, 33, 34}) {
		for p in t.parameter_sets do if p.type == type {arrays += 1; break}
	}
	put_u8(b, u8(arrays))
	for type in ([3]u8{32, 33, 34}) {
		count := 0
		for p in t.parameter_sets do if p.type == type do count += 1
		if count == 0 do continue
		put_u8(b, 0x80 | type) // array_completeness: no in-band sets (hvc1)
		put_u16(b, u16(count))
		for p in t.parameter_sets do if p.type == type {put_u16(b, u16(len(p.data))); append(b, ..p.data)}
	}
	if len(t.config.hevc_sei) > 0 {
		// The SEI may repeat in the samples, so the array is not complete.
		put_u8(b, 39)
		put_u16(b, 1)
		put_u16(b, u16(len(t.config.hevc_sei)))
		append(b, ..t.config.hevc_sei)
	}
	end_box(b, hvcc)
	return .None
}

@(private)
put_descriptor :: proc(b: ^[dynamic]u8, tag: u8, size: int) {
	put_u8(b, tag)
	put_u8(b, u8(size >> 21) | 0x80)
	put_u8(b, u8(size >> 14) | 0x80)
	put_u8(b, u8(size >> 7) | 0x80)
	put_u8(b, u8(size & 0x7F))
}

@(private)
build_audio_entry :: proc(b: ^[dynamic]u8, t: ^Track_Writer, id: u32, timing: Track_Timing) {
	entry := begin_box(b, "mp4a")
	put_zeros(b, 6)
	put_u16(b, 1)
	put_zeros(b, 8)
	put_u16(b, u16(t.config.channels))
	put_u16(b, 16)
	put_u32(b, 0)
	put_u32(b, t.config.sample_rate <= 65535 ? u32(t.config.sample_rate) << 16 : 0)
	asc := t.config.audio_specific_config
	esds := begin_full_box(b, "esds", 0, 0)
	put_descriptor(b, 3, 3 + 5 + 13 + 5 + len(asc) + 5 + 1)
	put_u16(b, u16(id))
	put_u8(b, 0)
	put_descriptor(b, 4, 13 + 5 + len(asc))
	put_u8(b, 0x40) // MPEG-4 audio
	put_u8(b, 0x15) // audio stream
	put_u24(b, t.max_size)
	// Peak over any one-second decode window, and the whole-track average.
	peak, window: u64
	first := 0
	for s, i in t.samples {
		window += u64(s.size)
		for s.dts - t.samples[first].dts >= i64(t.config.timescale) {
			window -= u64(t.samples[first].size)
			first += 1
		}
		peak = max(peak, window)
		_ = i
	}
	seconds := f64(timing.media_duration) / f64(t.config.timescale)
	average := seconds > 0 ? u32(min(f64(t.bytes) * 8 / seconds, f64(max(u32)))) : 0
	put_u32(b, u32(min(peak * 8, u64(max(u32)))))
	put_u32(b, average)
	put_descriptor(b, 5, len(asc))
	append(b, ..asc)
	put_descriptor(b, 6, 1)
	put_u8(b, 2)
	end_box(b, esds)
	end_box(b, entry)
}

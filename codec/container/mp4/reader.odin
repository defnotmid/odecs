package mp4

import "core:io"
import "core:os"
import "core:slice"

// One sample in decode order. pts/dts are track-timescale ticks on the movie
// timeline: the edit list is applied, so zero is the first presented instant
// and samples hidden by the edit (AAC priming, pre-roll) have negative pts.
Sample :: struct {
	offset:   i64,
	dts, pts: i64,
	size:     u32,
	duration: u32,
	sync:     bool,
}

// Basic edit-list interpretation: an optional leading empty edit followed by
// one normal edit at rate 1. Longer lists keep their first normal edit and
// set `complex`; their later segments are not applied.
Edit :: struct {
	media_time: i64, // first presented media time (track ticks)
	delay:      i64, // empty edit before it, in track ticks
	duration:   i64, // presented duration in track ticks; 0 means all samples
	complex:    bool,
}

Track :: struct {
	id:                    u32,
	kind:                  Track_Kind,
	codec:                 Codec,
	sample_entry:          [4]u8, // avc1, avc3, hvc1, hev1, av01, mp4a, ...
	handler:               [4]u8,
	timescale:             u32,
	media_duration:        i64, // mdhd, track ticks
	edit:                  Edit,
	// Video.
	width, height:         int, // sample entry size
	rotation:              int, // clockwise degrees from the tkhd matrix: 0, 90, 180 or 270
	color:                 Color, // `colr`; zero primaries when absent
	color_range_signalled: bool, // nclx carries the range; QuickTime nclc does not
	config:                []u8, // avcC/hvcC record body
	nal_length_size:       int,
	interlaced:            bool, // QuickTime `fiel` with two fields
	// Audio.
	sample_rate, channels: int,
	pcm:                   Pcm_Format, // codec PCM
	audio_specific_config: []u8, // AAC AudioSpecificConfig, or FLAC metadata blocks (dfLa)
	// Decode-order samples and presentation order (indices sorted by pts).
	samples:               #soa[]Sample,
	presentation:          []i32,
	no_reordering:         bool, // every pts equals its dts after the edit shift
	cursor:                int, // next sample for next_packet
}

Reader :: struct {
	stream:          io.Stream,
	file:            ^os.File, // owned when opened from a path
	size:            i64,
	movie_timescale: u32,
	movie_duration:  i64,
	major_brand:     [4]u8,
	tracks:          [dynamic]Track,
	buffer:          [dynamic]u8,
	moov:            []u8,
}

Packet :: struct {
	track:    int,
	index:    int, // sample index in decode order
	data:     []u8, // borrowed until the next read on this reader
	pts, dts: i64,
	duration: u32,
	sync:     bool,
}

open :: proc(r: ^Reader, path: string) -> Error {
	f, err := os.open(path)
	if err != nil do return .IO_Error
	if e := open_stream(r, os.to_stream(f)); e != .None {
		os.close(f)
		return e
	}
	r.file = f
	return .None
}

// Reads a stream with Read_At and Size. The reader borrows it until close.
open_stream :: proc(r: ^Reader, stream: io.Stream) -> Error {
	if r == nil do return .Invalid_Argument
	modes := io.query(stream)
	if .Read_At not_in modes || .Size not_in modes do return .Invalid_Argument
	size, size_err := io.size(stream)
	if size_err != .None || size < 8 do return .Invalid_Data
	r^ = {
		stream = stream,
		size   = size,
	}
	if err := scan_top_level(r); err != .None {close(r); return err}
	return .None
}

close :: proc(r: ^Reader) {
	if r == nil do return
	for &t in r.tracks {
		delete(t.config)
		delete(t.audio_specific_config)
		delete(t.samples)
		delete(t.presentation)
	}
	delete(r.tracks)
	delete(r.buffer)
	delete(r.moov)
	if r.file != nil do os.close(r.file)
	r^ = {}
}

@(private)
scan_top_level :: proc(r: ^Reader) -> Error {
	pos: i64
	found_moov, fragmented := false, false
	for pos + 8 <= r.size {
		header: [16]u8
		read_all_at(r.stream, header[:8], pos) or_return
		size := i64(get_u32(header[:]))
		type := get_u32(header[4:])
		head: i64 = 8
		if size == 1 {
			if pos + 16 > r.size do return .Invalid_Data
			read_all_at(r.stream, header[8:16], pos + 8) or_return
			size = i64(get_u64(header[8:]))
			head = 16
		} else if size == 0 {
			size = r.size - pos
		}
		if size < head || size > r.size - pos do return .Invalid_Data
		switch type {
		case fourcc("ftyp"):
			if size >= 12 {
				brand: [4]u8
				read_all_at(r.stream, brand[:], pos + 8) or_return
				r.major_brand = brand
			}
		case fourcc("moov"):
			if found_moov do return .Invalid_Data
			if size - head > 1 << 30 do return .Unsupported
			moov, err := make([]u8, int(size - head))
			if err != nil do return .Out_Of_Memory
			r.moov = moov
			read_all_at(r.stream, moov, pos + head) or_return
			found_moov = true
		case fourcc("moof"):
			fragmented = true
		}
		pos += size
	}
	if !found_moov do return .Invalid_Data
	parse_moov(r, r.moov) or_return
	if fragmented do return .Unsupported
	return .None
}

// A view of one box's payload inside a parent payload.
@(private)
Box :: struct {
	type: u32,
	body: []u8,
}

@(private)
next_box :: proc(data: []u8, pos: ^int) -> (box: Box, ok: bool, err: Error) {
	p := pos^
	if p + 8 > len(data) {
		if p != len(data) do err = .Invalid_Data
		return
	}
	size := u64(get_u32(data[p:]))
	head := 8
	if size == 1 {
		if p + 16 > len(data) {err = .Invalid_Data; return}
		size = get_u64(data[p + 8:])
		head = 16
	} else if size == 0 {
		size = u64(len(data) - p)
	}
	if size < u64(head) || size > u64(len(data) - p) {err = .Invalid_Data; return}
	box = {get_u32(data[p + 4:]), data[p + head:p + int(size)]}
	pos^ = p + int(size)
	return box, true, .None
}

@(private)
find_box :: proc(data: []u8, type: string) -> (body: []u8, found: bool, err: Error) {
	pos := 0
	want := fourcc(type)
	for {
		box, ok, e := next_box(data, &pos)
		if e != .None do return nil, false, e
		if !ok do return nil, false, .None
		if box.type == want do return box.body, true, .None
	}
}

@(private)
parse_moov :: proc(r: ^Reader, moov: []u8) -> Error {
	// Edit lists are in movie ticks, so read mvhd first wherever it sits.
	b, has_mvhd := find_box(moov, "mvhd") or_return
	if !has_mvhd || len(b) < 4 do return .Invalid_Data
	if b[0] == 1 {
		if len(b) < 32 do return .Invalid_Data
		r.movie_timescale = get_u32(b[20:])
		r.movie_duration = i64(get_u64(b[24:]))
	} else {
		if len(b) < 20 do return .Invalid_Data
		r.movie_timescale = get_u32(b[12:])
		r.movie_duration = i64(get_u32(b[16:]))
	}
	if r.movie_timescale == 0 do return .Invalid_Data
	pos := 0
	has_mvex := false
	for {
		box, ok, err := next_box(moov, &pos)
		if err != .None do return err
		if !ok do break
		switch box.type {
		case fourcc("trak"):
			t: Track
			if err = parse_trak(r, &t, box.body); err != .None {
				destroy_track(&t)
				return err
			}
			append(&r.tracks, t)
		case fourcc("mvex"):
			has_mvex = true
		}
	}
	if has_mvex {
		for t in r.tracks do if len(t.samples) > 0 do return .Unsupported
		return .Unsupported
	}
	return .None
}

@(private)
destroy_track :: proc(t: ^Track) {
	delete(t.config)
	delete(t.audio_specific_config)
	delete(t.samples)
	delete(t.presentation)
	t^ = {}
}

@(private)
parse_trak :: proc(r: ^Reader, t: ^Track, trak: []u8) -> Error {
	tkhd, has_tkhd := find_box(trak, "tkhd") or_return
	if !has_tkhd || len(tkhd) < 84 do return .Invalid_Data
	matrix_at := 40
	if tkhd[0] == 1 {
		if len(tkhd) < 96 do return .Invalid_Data
		t.id = get_u32(tkhd[20:])
		matrix_at = 52
	} else {
		t.id = get_u32(tkhd[12:])
	}
	a := i32(get_u32(tkhd[matrix_at:]))
	bm := i32(get_u32(tkhd[matrix_at + 4:]))
	switch {
	case a == 0 && bm > 0:
		t.rotation = 90
	case a < 0 && bm == 0:
		t.rotation = 180
	case a == 0 && bm < 0:
		t.rotation = 270
	}
	mdia, has_mdia := find_box(trak, "mdia") or_return
	if !has_mdia do return .Invalid_Data
	mdhd, has_mdhd := find_box(mdia, "mdhd") or_return
	if !has_mdhd || len(mdhd) < 24 do return .Invalid_Data
	if mdhd[0] == 1 {
		if len(mdhd) < 36 do return .Invalid_Data
		t.timescale = get_u32(mdhd[20:])
		t.media_duration = i64(get_u64(mdhd[24:]))
	} else {
		t.timescale = get_u32(mdhd[12:])
		t.media_duration = i64(get_u32(mdhd[16:]))
	}
	if t.timescale == 0 do return .Invalid_Data
	hdlr, has_hdlr := find_box(mdia, "hdlr") or_return
	if has_hdlr && len(hdlr) >= 12 {
		copy(t.handler[:], hdlr[8:12])
		switch string(t.handler[:]) {
		case "vide":
			t.kind = .Video
		case "soun":
			t.kind = .Audio
		}
	}
	minf, has_minf := find_box(mdia, "minf") or_return
	if !has_minf do return .Invalid_Data
	stbl, has_stbl := find_box(minf, "stbl") or_return
	if !has_stbl do return .Invalid_Data
	if edts, has_edts := find_box(trak, "edts") or_return; has_edts {
		if elst, has_elst := find_box(edts, "elst") or_return; has_elst do parse_elst(r, t, elst) or_return
	}
	parse_stsd(t, stbl) or_return
	if t.codec == .PCM do return parse_pcm_chunks(r, t, stbl)
	return parse_sample_tables(r, t, stbl)
}

@(private)
parse_elst :: proc(r: ^Reader, t: ^Track, elst: []u8) -> Error {
	if len(elst) < 8 do return .Invalid_Data
	version := elst[0]
	count := int(get_u32(elst[4:]))
	entry := version == 1 ? 20 : 12
	if count > (len(elst) - 8) / entry do return .Invalid_Data
	normal := 0
	for i in 0 ..< count {
		e := elst[8 + i * entry:]
		duration, media_time: i64
		if version == 1 {
			duration = i64(get_u64(e))
			media_time = i64(get_u64(e[8:]))
		} else {
			duration = i64(get_u32(e))
			media_time = i64(i32(get_u32(e[4:])))
		}
		rate := get_u32(e[entry - 4:])
		ticks := rescale_i64(duration, r.movie_timescale, t.timescale)
		if media_time == -1 {
			if normal == 0 {t.edit.delay += ticks} else {t.edit.complex = true}
			continue
		}
		if normal == 0 {
			t.edit.media_time = media_time
			t.edit.duration = ticks
			if rate != 0x00010000 do t.edit.complex = true
		} else {
			t.edit.complex = true
		}
		normal += 1
	}
	if normal == 0 do t.edit.delay = 0
	return .None
}

@(private)
rescale_i64 :: proc(v: i64, from, to: u32) -> i64 {
	if from == 0 do return 0
	return i64((i128(v) * i128(to) + i128(from / 2)) / i128(from))
}

@(private)
parse_stsd :: proc(t: ^Track, stbl: []u8) -> Error {
	stsd, ok := find_box(stbl, "stsd") or_return
	if !ok || len(stsd) < 8 do return .Invalid_Data
	if get_u32(stsd[4:]) != 1 do return .Unsupported // one sample description per track
	iso_v1 := stsd[0] == 1 // ISO AudioSampleEntryV1 keeps the version-0 field layout
	pos := 8
	entry, found_entry := next_box(stsd, &pos) or_return
	if !found_entry || len(entry.body) < 8 do return .Invalid_Data
	t.sample_entry = {u8(entry.type >> 24), u8(entry.type >> 16), u8(entry.type >> 8), u8(entry.type)}
	body := entry.body
	switch entry.type {
	case fourcc("apco"), fourcc("apcs"), fourcc("apcn"), fourcc("apch"), fourcc("ap4h"), fourcc("ap4x"):
		if len(body) < 78 do return .Invalid_Data
		t.width = int(get_u16(body[24:]))
		t.height = int(get_u16(body[26:]))
		t.codec = .ProRes
		children := body[78:]
		parse_colr(t, children) or_return
		if fiel, has_fiel := find_box(children, "fiel") or_return; has_fiel && len(fiel) >= 1 do t.interlaced = fiel[0] == 2
	case fourcc("avc1"), fourcc("avc3"), fourcc("hvc1"), fourcc("hev1"):
		if len(body) < 78 do return .Invalid_Data
		t.width = int(get_u16(body[24:]))
		t.height = int(get_u16(body[26:]))
		children := body[78:]
		h264 := entry.type == fourcc("avc1") || entry.type == fourcc("avc3")
		record, found := find_box(children, h264 ? "avcC" : "hvcC") or_return
		if !found do return .Invalid_Data
		if h264 {
			if len(record) < 7 do return .Invalid_Data
			t.nal_length_size = int(record[4] & 3) + 1
		} else {
			if len(record) < 23 do return .Invalid_Data
			t.nal_length_size = int(record[21] & 3) + 1
		}
		if t.nal_length_size == 3 do return .Invalid_Data
		config, err := make([]u8, len(record))
		if err != nil do return .Out_Of_Memory
		copy(config, record)
		t.config = config
		t.codec = h264 ? .H264 : .H265
		parse_colr(t, children) or_return
	case fourcc("av01"):
		// A VisualSampleEntry whose av1C holds a 4-byte header and the
		// configuration OBUs (the sequence header).
		if len(body) < 78 do return .Invalid_Data
		t.width = int(get_u16(body[24:]))
		t.height = int(get_u16(body[26:]))
		children := body[78:]
		record, found := find_box(children, "av1C") or_return
		if !found || len(record) < 4 || record[0] != 0x81 do return .Invalid_Data
		config, err := make([]u8, len(record))
		if err != nil do return .Out_Of_Memory
		copy(config, record)
		t.config = config
		t.codec = .AV1
		parse_colr(t, children) or_return
	case fourcc("raw "), fourcc("twos"), fourcc("sowt"), fourcc("in24"), fourcc("in32"), fourcc("fl32"), fourcc("fl64"), fourcc("lpcm"):
		parse_pcm_entry(t, entry.type, body, iso_v1) or_return
	case fourcc(".mp3"):
		// QuickTime's MP3 sound description: version 0/1 fields only.
		if len(body) < 28 do return .Invalid_Data
		t.channels = int(get_u16(body[16:]))
		t.sample_rate = int(get_u32(body[24:]) >> 16)
		t.codec = .MP3
	case fourcc("fLaC"):
		// FLAC in ISO BMFF: an AudioSampleEntry whose dfLa (a full box)
		// holds the metadata blocks, streaminfo first. Rate and channels
		// come from streaminfo, as the entry's 16-bit rate cannot hold
		// rates above 65535 Hz.
		if len(body) < 28 do return .Invalid_Data
		dfla, found := find_box(body[28:], "dfLa") or_return
		if !found || len(dfla) < 4 + 4 + 34 || dfla[4] & 0x7F != 0 do return .Invalid_Data
		blocks := dfla[4:]
		info := blocks[4:]
		t.sample_rate = int(get_u32(info[10:]) >> 12)
		t.channels = int(info[12] >> 1 & 7) + 1
		config, err := make([]u8, len(blocks))
		if err != nil do return .Out_Of_Memory
		copy(config, blocks)
		t.audio_specific_config = config
		t.codec = .FLAC
	case fourcc("mp4a"):
		if len(body) < 28 do return .Invalid_Data
		version := get_u16(body[8:])
		t.channels = int(get_u16(body[16:]))
		t.sample_rate = int(get_u32(body[24:]) >> 16)
		children_at := 28
		// QuickTime sound description versions 1 and 2 (in a version-0 stsd)
		// extend the entry; ISO AudioSampleEntryV1 does not.
		if version == 1 && !iso_v1 do children_at = 44
		if version == 2 && !iso_v1 {
			children_at = 64
			if len(body) < 64 do return .Invalid_Data
			rate := transmute(f64)get_u64(body[32:])
			t.sample_rate = int(rate)
			t.channels = int(get_u32(body[40:]))
		}
		if len(body) < children_at do return .Invalid_Data
		children := body[children_at:]
		esds, found := find_box(children, "esds") or_return
		if !found {
			wave, has_wave := find_box(children, "wave") or_return
			if has_wave do esds, found = find_box(wave, "esds") or_return
		}
		if !found do return .Unsupported
		asc, object := parse_esds(esds) or_return
		if object == 0x69 || object == 0x6B {
			t.codec = .MP3 // rate and channels from the sample entry
			return .None
		}
		info, parsed := parse_asc(asc)
		if !parsed do return .Invalid_Data
		config, err := make([]u8, len(asc))
		if err != nil do return .Out_Of_Memory
		copy(config, asc)
		t.audio_specific_config = config
		t.sample_rate = info.sample_rate
		if info.channel_config > 0 && info.channel_config <= 7 {
			channels_for_config := [8]u8{0, 1, 2, 3, 4, 5, 6, 8}
			t.channels = int(channels_for_config[info.channel_config])
		}
		// Only AAC object types decode as AAC; others keep codec Unknown.
		if info.object_type == 2 || info.object_type == 5 || info.object_type == 29 do t.codec = .AAC
	}
	return .None
}

@(private)
parse_colr :: proc(t: ^Track, children: []u8) -> Error {
	colr, has_colr := find_box(children, "colr") or_return
	if !has_colr || len(colr) < 10 do return .None
	kind := get_u32(colr)
	if kind != fourcc("nclx") && kind != fourcc("nclc") do return .None
	t.color = {
		primaries     = u8(get_u16(colr[4:])),
		transfer      = u8(get_u16(colr[6:])),
		matrix_coeffs = u8(get_u16(colr[8:])),
	}
	if kind == fourcc("nclx") && len(colr) >= 11 {
		t.color.full_range = colr[10] & 0x80 != 0
		t.color_range_signalled = true
	}
	return .None
}

// QuickTime sound descriptions for uncompressed audio. Version 0 and 1 carry
// the sample size in bits (twos/sowt) or imply it by the format (in24, fl32,
// ...), with an `enda` box (possibly inside `wave`) for little-endian data;
// version 2 (lpcm) states rate, channels, bits and flags explicitly.
@(private)
parse_pcm_entry :: proc(t: ^Track, type: u32, body: []u8, iso_v1: bool) -> Error {
	if len(body) < 28 do return .Invalid_Data
	version := iso_v1 ? 0 : get_u16(body[8:])
	t.channels = int(get_u16(body[16:]))
	bits := int(get_u16(body[18:]))
	t.sample_rate = int(get_u32(body[24:]) >> 16)
	children_at := 28
	f := &t.pcm
	switch version {
	case 1:
		children_at = 44
	case 2:
		children_at = 64
		if len(body) < 64 do return .Invalid_Data
		t.sample_rate = int(transmute(f64)get_u64(body[32:]))
		t.channels = int(get_u32(body[40:]))
		bits = int(get_u32(body[48:]))
		flags := get_u32(body[52:])
		f.float, f.little_endian = flags & 1 != 0, flags & 2 == 0
		f.unsigned = flags & 5 == 0 && bits == 8
	}
	if len(body) < children_at do return .Invalid_Data
	switch type {
	case fourcc("raw "):
		bits, f.unsigned = 8, true
	case fourcc("sowt"):
		f.little_endian = true
	case fourcc("in24"):
		bits = 24
	case fourcc("in32"):
		bits = 32
	case fourcc("fl32"):
		bits, f.float = 32, true
	case fourcc("fl64"):
		bits, f.float = 64, true
	}
	if type != fourcc("lpcm") && type != fourcc("sowt") {
		children := body[children_at:]
		enda, has_enda := find_box(children, "enda") or_return
		if !has_enda {
			if wave, has_wave := find_box(children, "wave") or_return; has_wave do enda, has_enda = find_box(wave, "enda") or_return
		}
		f.little_endian = has_enda && len(enda) >= 2 && get_u16(enda) != 0
	}
	// Other layouts keep codec Unknown, so the rest of the file still opens.
	valid := f.float ? bits == 32 || bits == 64 : bits == 8 || bits == 16 || bits == 24 || bits == 32
	if !valid || t.channels < 1 || t.channels > 64 || t.sample_rate < 1 || t.sample_rate > 768000 do return .None
	f.bits = u8(bits)
	t.codec = .PCM
	return .None
}

// Returns the DecoderSpecificInfo (the AudioSpecificConfig) of an esds body.
@(private)
// Returns the DecoderConfigDescriptor's object type and, for AAC, its
// DecoderSpecificInfo (the AudioSpecificConfig). MPEG-1/2 audio (MP3)
// has no specific info.
parse_esds :: proc(esds: []u8) -> (asc: []u8, object: u8, err: Error) {
	if len(esds) < 4 do return nil, 0, .Invalid_Data
	data := esds[4:]
	pos := 0
	read_descriptor :: proc(data: []u8, pos: ^int) -> (tag: u8, body: []u8, ok: bool) {
		p := pos^
		if p >= len(data) do return
		tag = data[p]
		p += 1
		size := 0
		for _ in 0 ..< 4 {
			if p >= len(data) do return
			b := data[p]
			p += 1
			size = size << 7 | int(b & 0x7F)
			if b & 0x80 == 0 do break
		}
		if size > len(data) - p do return
		pos^ = p + size
		return tag, data[p:p + size], true
	}
	tag, es, ok := read_descriptor(data, &pos)
	if !ok || tag != 3 || len(es) < 3 do return nil, 0, .Invalid_Data
	flags := es[2]
	at := 3
	if flags & 0x80 != 0 do at += 2
	if flags & 0x40 != 0 {
		if at >= len(es) do return nil, 0, .Invalid_Data
		at += 1 + int(es[at])
	}
	if flags & 0x20 != 0 do at += 2
	if at > len(es) do return nil, 0, .Invalid_Data
	inner := es[at:]
	pos = 0
	for {
		dtag, dcd, dok := read_descriptor(inner, &pos)
		if !dok do return nil, 0, .Invalid_Data
		if dtag != 4 do continue
		if len(dcd) < 13 do return nil, 0, .Invalid_Data
		object = dcd[0]
		if object == 0x69 || object == 0x6B do return nil, object, .None // MPEG-2 / MPEG-1 audio
		if object != 0x40 && object != 0x66 && object != 0x67 && object != 0x68 do return nil, object, .Unsupported
		p := 13
		for {
			itag, info, iok := read_descriptor(dcd, &p)
			if !iok do return nil, object, .Invalid_Data
			if itag == 5 do return info, object, .None
		}
	}
}

@(private)
parse_sample_tables :: proc(r: ^Reader, t: ^Track, stbl: []u8) -> Error {
	// Sample sizes fix the count; stts/stsc/stco must agree with it.
	count: int
	constant_size: u32
	sizes: []u8
	size_bits := 32
	if stsz, ok := find_box(stbl, "stsz") or_return; ok {
		if len(stsz) < 12 do return .Invalid_Data
		constant_size = get_u32(stsz[4:])
		count = int(get_u32(stsz[8:]))
		if constant_size == 0 {
			if count > (len(stsz) - 12) / 4 do return .Invalid_Data
			sizes = stsz[12:]
		}
	} else if stz2, ok2 := find_box(stbl, "stz2") or_return; ok2 {
		if len(stz2) < 12 do return .Invalid_Data
		size_bits = int(stz2[7])
		count = int(get_u32(stz2[8:]))
		if size_bits != 4 && size_bits != 8 && size_bits != 16 do return .Invalid_Data
		if count > (len(stz2) - 12) * 8 / size_bits do return .Invalid_Data
		sizes = stz2[12:]
	} else {
		return .Invalid_Data
	}
	if count > MAX_SAMPLES do return .Unsupported
	if count == 0 do return .None
	samples, alloc_err := make(#soa[]Sample, count)
	if alloc_err != nil do return .Out_Of_Memory
	t.samples = samples
	for i in 0 ..< count {
		size := constant_size
		if constant_size == 0 {
			switch size_bits {
			case 32:
				size = get_u32(sizes[i * 4:])
			case 16:
				size = u32(get_u16(sizes[i * 2:]))
			case 8:
				size = u32(sizes[i])
			case 4:
				size = u32(sizes[i / 2] >> (i & 1 == 0 ? 4 : 0) & 15)
			}
		}
		samples[i].size = size
	}

	// Decode times.
	stts, has_stts := find_box(stbl, "stts") or_return
	if !has_stts || len(stts) < 8 do return .Invalid_Data
	entries := int(get_u32(stts[4:]))
	if entries > (len(stts) - 8) / 8 do return .Invalid_Data
	n := 0
	dts: i64
	for e in 0 ..< entries {
		run := int(get_u32(stts[8 + e * 8:]))
		delta := get_u32(stts[12 + e * 8:])
		for _ in 0 ..< run {
			if n >= count do break
			samples[n].dts = dts
			samples[n].duration = delta
			dts += i64(delta)
			n += 1
		}
	}
	if n < count do return .Invalid_Data

	// Composition offsets (version 0 values are read signed, as written by
	// common muxers that emit negative offsets in version 0 boxes).
	for i in 0 ..< count do samples[i].pts = samples[i].dts
	if ctts, ok := find_box(stbl, "ctts") or_return; ok {
		if len(ctts) < 8 do return .Invalid_Data
		entries = int(get_u32(ctts[4:]))
		if entries > (len(ctts) - 8) / 8 do return .Invalid_Data
		n = 0
		for e in 0 ..< entries {
			run := int(get_u32(ctts[8 + e * 8:]))
			offset := i64(i32(get_u32(ctts[12 + e * 8:])))
			for _ in 0 ..< run {
				if n >= count do break
				samples[n].pts = samples[n].dts + offset
				n += 1
			}
		}
	}

	// Sync samples; without stss every sample is a sync sample.
	if stss, ok := find_box(stbl, "stss") or_return; ok {
		if len(stss) < 8 do return .Invalid_Data
		entries = int(get_u32(stss[4:]))
		if entries > (len(stss) - 8) / 4 do return .Invalid_Data
		for e in 0 ..< entries {
			number := int(get_u32(stss[8 + e * 4:]))
			if number >= 1 && number <= count do samples[number - 1].sync = true
		}
	} else {
		for i in 0 ..< count do samples[i].sync = true
	}

	// Chunk offsets and sample-to-chunk runs give each sample's offset.
	chunk_data, has_stco := find_box(stbl, "stco") or_return
	wide := false
	if !has_stco {
		co64, has_co64 := find_box(stbl, "co64") or_return
		if !has_co64 do return .Invalid_Data
		chunk_data, wide = co64, true
	}
	if len(chunk_data) < 8 do return .Invalid_Data
	chunks := int(get_u32(chunk_data[4:]))
	entry_size := wide ? 8 : 4
	if chunks > (len(chunk_data) - 8) / entry_size do return .Invalid_Data
	stsc, has_stsc := find_box(stbl, "stsc") or_return
	if !has_stsc || len(stsc) < 8 do return .Invalid_Data
	runs := int(get_u32(stsc[4:]))
	if runs == 0 || runs > (len(stsc) - 8) / 12 do return .Invalid_Data
	n = 0
	for run in 0 ..< runs {
		first := int(get_u32(stsc[8 + run * 12:])) - 1
		per_chunk := int(get_u32(stsc[12 + run * 12:]))
		last := run + 1 < runs ? int(get_u32(stsc[8 + (run + 1) * 12:])) - 1 : chunks
		if first < 0 || last > chunks || last < first do return .Invalid_Data
		for c in first ..< last {
			offset := wide ? i64(get_u64(chunk_data[8 + c * 8:])) : i64(get_u32(chunk_data[8 + c * 4:]))
			for _ in 0 ..< per_chunk {
				if n >= count do break
				if offset < 0 || i64(samples[n].size) > r.size - offset do return .Invalid_Data
				samples[n].offset = offset
				offset += i64(samples[n].size)
				n += 1
			}
		}
	}
	if n < count do return .Invalid_Data

	// Move onto the movie timeline: presented time = media time - media_time + delay.
	shift := t.edit.delay - t.edit.media_time
	t.no_reordering = true
	for i in 0 ..< count {
		samples[i].dts += shift
		samples[i].pts += shift
		if samples[i].pts != samples[i].dts do t.no_reordering = false
	}
	presentation, err := make([]i32, count)
	if err != nil do return .Out_Of_Memory
	t.presentation = presentation
	for i in 0 ..< count do presentation[i] = i32(i)
	if !t.no_reordering do sort_presentation(presentation, samples.pts[:count]) or_return
	return .None
}

// PCM tracks index chunks, not frames. QuickTime keeps one table sample per
// audio frame, so a frame-level index would outgrow the audio it describes;
// each Sample here is one chunk of whole frames.
@(private)
parse_pcm_chunks :: proc(r: ^Reader, t: ^Track, stbl: []u8) -> Error {
	frame_bytes := i64(t.channels) * i64(t.pcm.bits) / 8
	frames_left := i64(max(i64))
	if stsz, ok := find_box(stbl, "stsz") or_return; ok && len(stsz) >= 12 do frames_left = i64(get_u32(stsz[8:]))
	stts, has_stts := find_box(stbl, "stts") or_return
	if !has_stts || len(stts) < 16 do return .Invalid_Data
	delta := get_u32(stts[12:])
	for e in 1 ..< min(int(get_u32(stts[4:])), (len(stts) - 8) / 8) {
		if get_u32(stts[12 + e * 8:]) != delta do return .Unsupported // variable-rate PCM
	}
	if delta == 0 do return .Invalid_Data
	chunk_data, has_stco := find_box(stbl, "stco") or_return
	wide := false
	if !has_stco {
		co64, has_co64 := find_box(stbl, "co64") or_return
		if !has_co64 do return .Invalid_Data
		chunk_data, wide = co64, true
	}
	if len(chunk_data) < 8 do return .Invalid_Data
	chunks := int(get_u32(chunk_data[4:]))
	entry_size := wide ? 8 : 4
	if chunks > (len(chunk_data) - 8) / entry_size do return .Invalid_Data
	if chunks > MAX_SAMPLES do return .Unsupported
	stsc, has_stsc := find_box(stbl, "stsc") or_return
	if !has_stsc || len(stsc) < 8 do return .Invalid_Data
	runs := int(get_u32(stsc[4:]))
	if runs == 0 || runs > (len(stsc) - 8) / 12 do return .Invalid_Data
	samples, alloc_err := make(#soa[]Sample, chunks)
	if alloc_err != nil do return .Out_Of_Memory
	t.samples = samples
	n := 0
	ticks := t.edit.delay - t.edit.media_time
	for run in 0 ..< runs {
		first := int(get_u32(stsc[8 + run * 12:])) - 1
		per_chunk := i64(get_u32(stsc[12 + run * 12:]))
		last := run + 1 < runs ? int(get_u32(stsc[8 + (run + 1) * 12:])) - 1 : chunks
		if first != n || last > chunks || last < first do return .Invalid_Data
		for c in first ..< last {
			frames := min(per_chunk, frames_left)
			if frames <= 0 do break
			offset := wide ? i64(get_u64(chunk_data[8 + c * 8:])) : i64(get_u32(chunk_data[8 + c * 4:]))
			if frames > (r.size - offset) / frame_bytes || offset < 0 do return .Invalid_Data
			samples[n] = {offset = offset, dts = ticks, pts = ticks, size = u32(frames * frame_bytes), duration = u32(frames) * delta, sync = true}
			ticks += frames * i64(delta)
			frames_left -= frames
			n += 1
		}
	}
	t.samples = samples[:n]
	t.no_reordering = true
	presentation, err := make([]i32, n)
	if err != nil do return .Out_Of_Memory
	t.presentation = presentation
	for i in 0 ..< n do presentation[i] = i32(i)
	return .None
}

// Orders sample indices by pts (ties in decode order). O(n log n) even for
// adversarial composition offsets.
@(private)
sort_presentation :: proc(order: []i32, pts: []i64) -> Error {
	Key :: struct {
		pts:   i64,
		index: i32,
	}
	keys, err := make([]Key, len(order))
	if err != nil do return .Out_Of_Memory
	defer delete(keys)
	for i in 0 ..< len(order) do keys[i] = {pts[i], i32(i)}
	slice.sort_by(keys, proc(a, b: Key) -> bool {return a.pts < b.pts || a.pts == b.pts && a.index < b.index})
	for k, i in keys do order[i] = k.index
	return .None
}

// Presented end of the track in track ticks.
track_end :: proc(t: ^Track) -> i64 {
	if t.edit.duration > 0 do return t.edit.delay + t.edit.duration
	end: i64
	for i in 0 ..< len(t.samples) do end = max(end, t.samples[i].pts + i64(t.samples[i].duration))
	return end
}

// Reads a sample by decode-order index.
read_sample :: proc(r: ^Reader, track, index: int) -> (p: Packet, err: Error) {
	if r == nil || r.stream.procedure == nil do return {}, .Closed
	if track < 0 || track >= len(r.tracks) do return {}, .Invalid_Argument
	t := &r.tracks[track]
	if index < 0 || index >= len(t.samples) do return {}, .End_Of_Stream
	s := t.samples[index]
	if int(s.size) > len(r.buffer) {
		if resize(&r.buffer, int(s.size)) != nil do return {}, .Out_Of_Memory
	}
	data := r.buffer[:s.size]
	read_all_at(r.stream, data, s.offset) or_return
	return {track = track, index = index, data = data, pts = s.pts, dts = s.dts, duration = s.duration, sync = s.sync}, .None
}

// Reads the next sample across all tracks in decode-time order.
next_packet :: proc(r: ^Reader) -> (p: Packet, err: Error) {
	if r == nil || r.stream.procedure == nil do return {}, .Closed
	best := -1
	best_dts: i64
	best_scale: u32
	for &t, i in r.tracks {
		if t.cursor >= len(t.samples) do continue
		dts := t.samples[t.cursor].dts
		if best < 0 || i128(dts) * i128(best_scale) < i128(best_dts) * i128(t.timescale) {
			best, best_dts, best_scale = i, dts, t.timescale
		}
	}
	if best < 0 do return {}, .End_Of_Stream
	p = read_sample(r, best, r.tracks[best].cursor) or_return
	r.tracks[best].cursor += 1
	return p, .None
}

// Index of the sample presented at pts: the greatest pts <= the argument.
// Returns -1 before the first presented sample.
sample_at :: proc(t: ^Track, pts: i64) -> int {
	order := t.presentation
	lo, hi := 0, len(order)
	for lo < hi {
		mid := (lo + hi) / 2
		if t.samples[order[mid]].pts <= pts {lo = mid + 1} else {hi = mid}
	}
	return lo == 0 ? -1 : int(order[lo - 1])
}

// Decode-order index of the sync sample to start decoding from to present
// pts: the last sync sample whose pts is at or before it (the first sync
// sample when pts precedes the stream). Decode forward from it. Returns -1
// for an empty track.
keyframe_at :: proc(t: ^Track, pts: i64) -> int {
	if len(t.samples) == 0 do return -1
	target := sample_at(t, pts)
	if target < 0 do target = 0
	for i := target; i >= 0; i -= 1 {
		if t.samples[i].sync && t.samples[i].pts <= pts do return i
	}
	for i in 0 ..< len(t.samples) do if t.samples[i].sync do return i
	return 0
}

// Positions every track's next_packet cursor at its keyframe for seconds.
seek :: proc(r: ^Reader, seconds: f64) {
	for &t in r.tracks {
		if len(t.samples) == 0 do continue
		t.cursor = keyframe_at(&t, i64(seconds * f64(t.timescale)))
	}
}

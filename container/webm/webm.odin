// WebM / Matroska demuxing: EBML header, Segment Info and Tracks, and every
// Cluster's SimpleBlocks and BlockGroups (with Xiph, EBML or fixed lacing),
// indexed once at open into a flat per-track sample table. A BlockGroup's
// BlockAdditional with BlockAddID 1 is kept per sample: for VP9 with
// AlphaMode it is the alpha plane's own VP9 frame. Header stripping (the
// only content encoding read) is undone in read_sample. Depends only on
// Odin core.
package webm

import "core:io"
import "core:os"
import "core:slice"

Codec :: enum u8 {
	Unknown, // see Track.codec_id
	VP8,
	VP9,
	AV1,
	H264, // V_MPEG4/ISO/AVC: length-prefixed NAL units, avcC in codec_private
	H265, // V_MPEGH/ISO/HEVC: likewise with hvcC
	Opus,
	Vorbis,
	AAC, // A_AAC (AudioSpecificConfig in codec_private) and the legacy A_AAC/MPEG*/LC IDs
	PCM, // A_PCM/INT/LIT, A_PCM/INT/BIG, A_PCM/FLOAT/IEEE; see pcm_format
	FLAC, // A_FLAC: the fLaC marker and metadata blocks in codec_private
	MP3,  // A_MPEG/L3: one frame per block
}

// Interleaved PCM layout of an A_PCM track.
Pcm_Format :: struct {
	bits:          u8, // 8, 16, 24, 32, or 64 for float
	float:         bool,
	little_endian: bool,
	unsigned:      bool, // 8-bit integer PCM is unsigned
}

Track_Kind :: enum u8 {
	Other,
	Video,
	Audio,
}

Error :: enum {
	None,
	Invalid_Argument,
	Invalid_Data, // malformed or truncated
	Unsupported,  // valid, outside the implemented scope
	IO_Error,
	Out_Of_Memory,
	End_Of_Stream,
	Closed,
}

// Matroska Colour, ITU-T H.273 code points (2 = unspecified). Siting is
// Matroska's: 0 unspecified, 1 left/top collocated, 2 half.
Color :: struct {
	primaries, transfer, matrix_coeffs: u8,
	range:                              u8, // 0 unspecified, 1 limited, 2 full, 3 derived
	bits_per_channel:                   u8,
	chroma_siting_horz, chroma_siting_vert: u8,
}

// One frame in decode order. Timestamps are nanoseconds from the segment
// start. `additional` is the BlockAdditional with BlockAddID 1, if any.
Sample :: struct {
	offset:            i64,
	pts:               i64,
	duration:          i64, // 0 when the block states none
	additional_offset: i64,
	size:              u32,
	additional_size:   u32,
	sync:              bool,
}

Track :: struct {
	number:         u64,
	kind:           Track_Kind,
	codec:          Codec,
	codec_id:       string, // owned, e.g. "V_VP9"
	codec_private:  []u8, // owned
	default_duration: i64, // ns per frame; 0 when absent
	codec_delay:    i64, // ns of decoded output to discard at the start (Opus pre-skip, AAC priming)
	end_discard:    i64, // ns the last block's DiscardPadding drops from the end
	// Bytes removed from the front of every frame (ContentCompAlgo 3,
	// header stripping); read_sample puts them back. Owned.
	stripped:       []u8,
	// Video.
	width, height:  int,
	display_width, display_height: int,
	alpha:          bool, // AlphaMode 1: BlockAdditions carry an alpha stream
	interlaced:     bool,
	color:          Color,
	// Audio.
	sample_rate:    int,
	channels:       int,
	bit_depth:      int,
	pcm_format:     Pcm_Format, // codec .PCM only
	// Decode-order samples and their presentation order (sorted by pts).
	samples:        #soa[]Sample,
	presentation:   []i32,
}

Reader :: struct {
	stream:         io.Stream,
	file:           ^os.File, // owned when opened from a path
	size:           i64,
	doc_type:       [8]u8,
	timecode_scale: i64, // ns per Matroska timestamp tick
	duration:       f64, // seconds; 0 when Info has none
	tracks:         [dynamic]Track,
	buffer:         [dynamic]u8, // read_sample storage
	window:         [4096]u8, // small read-ahead for element headers
	window_at:      i64,
	window_len:     int,
}

Packet :: struct {
	track:      int,
	index:      int,
	data:       []u8, // borrowed until the next read on this reader
	additional: []u8, // BlockAdditional (alpha), borrowed likewise; nil when absent
	pts:        i64, // ns
	duration:   i64,
	sync:       bool,
}

// Upper bound on indexed frames per track, as in the MP4 demuxer.
MAX_SAMPLES :: 1 << 26

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

// Reads a stream with Read_At and Size; the reader borrows it until close.
open_stream :: proc(r: ^Reader, stream: io.Stream) -> Error {
	if r == nil do return .Invalid_Argument
	modes := io.query(stream)
	if .Read_At not_in modes || .Size not_in modes do return .Invalid_Argument
	size, size_err := io.size(stream)
	if size_err != .None || size < 8 do return .Invalid_Data
	r^ = {
		stream         = stream,
		size           = size,
		timecode_scale = 1_000_000,
		window_at      = -1,
	}
	if e := parse_file(r); e != .None {close(r); return e}
	return .None
}

close :: proc(r: ^Reader) {
	if r == nil do return
	for &t in r.tracks do destroy_track(&t)
	delete(r.tracks)
	delete(r.buffer)
	if r.file != nil do os.close(r.file)
	r^ = {}
}

@(private)
destroy_track :: proc(t: ^Track) {
	delete(t.codec_id)
	delete(t.codec_private)
	delete(t.stripped)
	delete(t.samples)
	delete(t.presentation)
	t^ = {}
}

// Reads a frame by decode-order index, with its BlockAdditional.
read_sample :: proc(r: ^Reader, track, index: int) -> (p: Packet, err: Error) {
	if r == nil || r.stream.procedure == nil do return {}, .Closed
	if track < 0 || track >= len(r.tracks) do return {}, .Invalid_Argument
	t := &r.tracks[track]
	if index < 0 || index >= len(t.samples) do return {}, .End_Of_Stream
	s := t.samples[index]
	prefix := len(t.stripped)
	size := prefix + int(s.size)
	total := size + int(s.additional_size)
	if total > len(r.buffer) {
		if resize(&r.buffer, total) != nil do return {}, .Out_Of_Memory
	}
	data := r.buffer[:size]
	copy(data, t.stripped)
	read_all_at(r.stream, data[prefix:], s.offset) or_return
	p = {track = track, index = index, data = data, pts = s.pts, duration = s.duration, sync = s.sync}
	if s.additional_size > 0 {
		p.additional = r.buffer[size:total]
		read_all_at(r.stream, p.additional, s.additional_offset) or_return
	}
	return p, .None
}

// Index of the sample presented at pts (ns): the greatest pts <= the
// argument, or -1 before the first.
sample_at :: proc(t: ^Track, pts: i64) -> int {
	order := t.presentation
	lo, hi := 0, len(order)
	for lo < hi {
		mid := (lo + hi) / 2
		if t.samples[order[mid]].pts <= pts {lo = mid + 1} else {hi = mid}
	}
	return lo == 0 ? -1 : int(order[lo - 1])
}

// Decode-order index of the keyframe to start from to present pts.
keyframe_at :: proc(t: ^Track, pts: i64) -> int {
	if len(t.samples) == 0 do return -1
	target := max(sample_at(t, pts), 0)
	for i := target; i >= 0; i -= 1 do if t.samples[i].sync && t.samples[i].pts <= pts do return i
	for i in 0 ..< len(t.samples) do if t.samples[i].sync do return i
	return 0
}

// Presented end of the track in ns: the last frame's end.
track_end :: proc(t: ^Track) -> i64 {
	end: i64
	for i in 0 ..< len(t.samples) {
		s := t.samples[i]
		d := s.duration > 0 ? s.duration : t.default_duration
		end = max(end, s.pts + d)
	}
	return end
}

// ---- EBML -----------------------------------------------------------------

// Element IDs keep their length marker, as the specification writes them.
@(private)
ID :: enum u32 {
	EBML               = 0x1A45DFA3,
	Doc_Type           = 0x4282,
	Segment            = 0x18538067,
	Info               = 0x1549A966,
	Timecode_Scale     = 0x2AD7B1,
	Duration           = 0x4489,
	Tracks             = 0x1654AE6B,
	Track_Entry        = 0xAE,
	Track_Number       = 0xD7,
	Track_Type         = 0x83,
	Codec_ID           = 0x86,
	Codec_Private      = 0x63A2,
	Default_Duration   = 0x23E383,
	Codec_Delay        = 0x56AA,
	Content_Encodings  = 0x6D80,
	Content_Encoding   = 0x6240,
	Content_Encoding_Scope = 0x5032,
	Content_Encoding_Type = 0x5033,
	Content_Compression = 0x5034,
	Content_Comp_Algo  = 0x4254,
	Content_Comp_Settings = 0x4255,
	Video              = 0xE0,
	Pixel_Width        = 0xB0,
	Pixel_Height       = 0xBA,
	Display_Width      = 0x54B0,
	Display_Height     = 0x54BA,
	Flag_Interlaced    = 0x9A,
	Alpha_Mode         = 0x53C0,
	Colour             = 0x55B0,
	Matrix_Coefficients = 0x55B1,
	Bits_Per_Channel   = 0x55B2,
	Chroma_Siting_Horz = 0x55B7,
	Chroma_Siting_Vert = 0x55B8,
	Range              = 0x55B9,
	Transfer           = 0x55BA,
	Primaries          = 0x55BB,
	Audio              = 0xE1,
	Sampling_Frequency = 0xB5,
	Channels           = 0x9F,
	Bit_Depth          = 0x6264,
	Cluster            = 0x1F43B675,
	Timecode           = 0xE7,
	Simple_Block       = 0xA3,
	Block_Group        = 0xA0,
	Block              = 0xA1,
	Block_Additions    = 0x75A1,
	Block_More         = 0xA6,
	Block_Add_ID       = 0xEE,
	Block_Additional   = 0xA5,
	Block_Duration     = 0x9B,
	Discard_Padding    = 0x75A2,
	Reference_Block    = 0xFB,
	Position           = 0xA7,
	Prev_Size          = 0xAB,
	Void               = 0xEC,
	CRC32              = 0xBF,
}

@(private)
UNKNOWN_SIZE :: max(i64)

@(private)
Element :: struct {
	id:   u32,
	at:   i64, // payload offset
	size: i64, // payload bytes; UNKNOWN_SIZE when unstated
	end:  i64, // payload end, clamped to its parent for unknown sizes
	cut:  bool, // stated size ran past the parent (read_element with truncated_ok)
}

// Reads `n` bytes at `at` through the read-ahead window; the slice is valid
// until the next window read.
@(private)
peek :: proc(r: ^Reader, at: i64, n: int) -> (data: []u8, err: Error) {
	if at < 0 || n > len(r.window) || at > r.size - i64(n) do return nil, .Invalid_Data
	if r.window_at < 0 || at < r.window_at || at + i64(n) > r.window_at + i64(r.window_len) {
		count := int(min(i64(len(r.window)), r.size - at))
		read_all_at(r.stream, r.window[:count], at) or_return
		r.window_at, r.window_len = at, count
	}
	start := int(at - r.window_at)
	return r.window[start:][:n], .None
}

// Variable-length integer: the leading zeros of the first byte give its
// length (1..8). IDs keep the marker; sizes drop it, all ones meaning
// unknown.
@(private)
read_vint :: proc(r: ^Reader, at: i64, keep_marker: bool) -> (value: u64, length: int, unknown: bool, err: Error) {
	first := peek(r, at, 1) or_return
	b := first[0]
	if b == 0 do return 0, 0, false, .Invalid_Data
	length = 1
	for b & (0x80 >> uint(length - 1)) == 0 do length += 1
	bytes := peek(r, at, length) or_return
	value = u64(b)
	if !keep_marker do value &= u64(0xFF >> uint(length))
	all_ones := value == u64(0xFF >> uint(length))
	for i in 1 ..< length {
		value = value << 8 | u64(bytes[i])
		all_ones &&= bytes[i] == 0xFF
	}
	return value, length, all_ones && !keep_marker, .None
}

// The element header at `at`, its payload bounded by the parent's end. With
// truncated_ok a payload stated past that end (an interrupted recording)
// ends there instead of failing.
@(private)
read_element :: proc(r: ^Reader, at, parent_end: i64, truncated_ok := false) -> (e: Element, err: Error) {
	id, id_len, _ := read_vint(r, at, true) or_return
	if id_len > 4 do return e, .Invalid_Data
	size, size_len, unknown := read_vint(r, at + i64(id_len), false) or_return
	e.id = u32(id)
	e.at = at + i64(id_len + size_len)
	if e.at > parent_end do return e, .Invalid_Data
	if unknown {
		e.size, e.end = UNKNOWN_SIZE, parent_end
	} else if size > u64(parent_end - e.at) {
		if !truncated_ok do return e, .Invalid_Data
		e.size, e.end, e.cut = parent_end - e.at, parent_end, true
	} else {
		e.size = i64(size)
		e.end = e.at + e.size
	}
	return e, .None
}

@(private)
read_uint :: proc(r: ^Reader, e: Element) -> (v: u64, err: Error) {
	if e.size > 8 do return 0, .Invalid_Data
	bytes := peek(r, e.at, int(e.size)) or_return
	for b in bytes do v = v << 8 | u64(b)
	return v, .None
}

@(private)
read_float :: proc(r: ^Reader, e: Element) -> (v: f64, err: Error) {
	bits := read_uint(r, e) or_return
	switch e.size {
	case 4:
		return f64(transmute(f32)u32(bits)), .None
	case 8:
		return transmute(f64)bits, .None
	case 0:
		return 0, .None
	}
	return 0, .Invalid_Data
}

@(private)
read_bytes :: proc(r: ^Reader, e: Element) -> (data: []u8, err: Error) {
	if e.size > 1 << 24 do return nil, .Unsupported
	data = make([]u8, int(e.size)) or_else nil
	if data == nil && e.size > 0 do return nil, .Out_Of_Memory
	if err = read_all_at(r.stream, data, e.at); err != .None {delete(data); return nil, err}
	return data, .None
}

// ---- Structure --------------------------------------------------------------

@(private)
parse_file :: proc(r: ^Reader) -> Error {
	header := read_element(r, 0, r.size) or_return
	if header.id != u32(ID.EBML) || header.size == UNKNOWN_SIZE do return .Invalid_Data
	for at := header.at; at < header.end; {
		e := read_element(r, at, header.end) or_return
		if e.id == u32(ID.Doc_Type) {
			doc := peek(r, e.at, int(min(e.size, 8))) or_return
			copy(r.doc_type[:], doc)
		}
		at = e.end
	}
	doc := string(r.doc_type[:])
	if doc[:4] != "webm" && doc != "matroska" do return .Unsupported
	// The first Segment holds the presentation; later ones are ignored.
	at := header.end
	for at < r.size {
		e := read_element(r, at, r.size, true) or_return
		if e.id == u32(ID.Segment) do return parse_segment(r, e)
		if e.cut do break
		if e.size == UNKNOWN_SIZE do break
		at = e.end
	}
	return .Invalid_Data
}

@(private)
Index :: struct {
	samples: [dynamic]Sample, // per track, in file (decode) order
}

@(private)
parse_segment :: proc(r: ^Reader, segment: Element) -> Error {
	indices: [dynamic]Index
	defer {
		for &x in indices do delete(x.samples)
		delete(indices)
	}
	have_tracks := false
	for at := segment.at; at < segment.end; {
		e, err := read_element(r, at, segment.end, have_tracks)
		if err != .None {
			// A truncated tail (an interrupted recording) keeps the clusters
			// read so far.
			if have_tracks do break
			return err
		}
		#partial switch ID(e.id) {
		case .Info:
			parse_info(r, e) or_return
		case .Tracks:
			if have_tracks do break
			parse_tracks(r, e) or_return
			have_tracks = true
			resize(&indices, len(r.tracks))
		case .Cluster:
			if !have_tracks do return .Invalid_Data
			next, cluster_err := parse_cluster(r, e, indices[:])
			if cluster_err != .None {
				// The cut-off last cluster of an interrupted recording keeps
				// the blocks that were indexed before the cut.
				if e.cut do break
				return cluster_err
			}
			at = next
			continue
		case:
		}
		if e.size == UNKNOWN_SIZE do break
		at = e.end
	}
	if !have_tracks do return .Invalid_Data
	for &t, i in r.tracks {
		samples := indices[i].samples[:]
		if len(samples) == 0 do continue
		t.samples = make(#soa[]Sample, len(samples)) or_else nil
		t.presentation = make([]i32, len(samples)) or_else nil
		if t.samples == nil || t.presentation == nil do return .Out_Of_Memory
		in_order := true
		for s, k in samples {
			t.samples[k] = s
			t.presentation[k] = i32(k)
			if k > 0 && s.pts < samples[k - 1].pts do in_order = false
		}
		if !in_order {
			sort_by_pts(t.presentation, t.samples.pts[:len(samples)])
		}
		// Frames without a stated duration last until the next presented one.
		for k in 0 ..< len(samples) {
			cur := t.presentation[k]
			if t.samples[cur].duration > 0 do continue
			if k + 1 < len(samples) {
				t.samples[cur].duration = t.samples[t.presentation[k + 1]].pts - t.samples[cur].pts
			} else {
				t.samples[cur].duration = t.default_duration
			}
		}
	}
	return .None
}

@(private)
sort_by_pts :: proc(order: []i32, pts: []i64) {
	Key :: struct {
		pts:   i64,
		index: i32,
	}
	keys := make([]Key, len(order))
	defer delete(keys)
	for i in 0 ..< len(order) do keys[i] = {pts[i], i32(i)}
	slice.sort_by(keys, proc(a, b: Key) -> bool {return a.pts < b.pts || a.pts == b.pts && a.index < b.index})
	for k, i in keys do order[i] = k.index
}

@(private)
parse_info :: proc(r: ^Reader, info: Element) -> Error {
	duration: f64
	for at := info.at; at < info.end; {
		e := read_element(r, at, info.end) or_return
		#partial switch ID(e.id) {
		case .Timecode_Scale:
			scale := read_uint(r, e) or_return
			if scale == 0 || scale > 1_000_000_000 do return .Invalid_Data
			r.timecode_scale = i64(scale)
		case .Duration:
			duration = read_float(r, e) or_return
		}
		at = e.end
	}
	if duration > 0 && duration < 1e15 do r.duration = duration * f64(r.timecode_scale) / 1e9
	return .None
}

@(private)
parse_tracks :: proc(r: ^Reader, tracks: Element) -> Error {
	for at := tracks.at; at < tracks.end; {
		e := read_element(r, at, tracks.end) or_return
		if e.id == u32(ID.Track_Entry) {
			t: Track
			if err := parse_track(r, &t, e); err != .None {destroy_track(&t); return err}
			if t.number == 0 {destroy_track(&t)} else {append(&r.tracks, t)}
		}
		at = e.end
	}
	return .None
}

@(private)
parse_track :: proc(r: ^Reader, t: ^Track, entry: Element) -> Error {
	t.color = {primaries = 2, transfer = 2, matrix_coeffs = 2}
	encoded := false
	for at := entry.at; at < entry.end; {
		e := read_element(r, at, entry.end) or_return
		#partial switch ID(e.id) {
		case .Track_Number:
			t.number = read_uint(r, e) or_return
		case .Track_Type:
			switch read_uint(r, e) or_return {
			case 1:
				t.kind = .Video
			case 2:
				t.kind = .Audio
			}
		case .Codec_ID:
			id := read_bytes(r, e) or_return
			t.codec_id = string(id)
		case .Codec_Private:
			t.codec_private = read_bytes(r, e) or_return
		case .Default_Duration:
			t.default_duration = i64(read_uint(r, e) or_return)
		case .Codec_Delay:
			t.codec_delay = i64(read_uint(r, e) or_return)
		case .Content_Encodings:
			if !(parse_content_encodings(r, t, e) or_return) do encoded = true
		case .Video:
			parse_video(r, t, e) or_return
		case .Audio:
			for a := e.at; a < e.end; {
				c := read_element(r, a, e.end) or_return
				#partial switch ID(c.id) {
				case .Sampling_Frequency:
					t.sample_rate = int(read_float(r, c) or_return)
				case .Channels:
					t.channels = int(read_uint(r, c) or_return)
				case .Bit_Depth:
					t.bit_depth = int(read_uint(r, c) or_return)
				}
				a = c.end
			}
		}
		at = e.end
	}
	switch t.codec_id {
	case "V_VP8":
		t.codec = .VP8
	case "V_VP9":
		t.codec = .VP9
	case "V_AV1":
		t.codec = .AV1
	case "V_MPEG4/ISO/AVC":
		t.codec = .H264
	case "V_MPEGH/ISO/HEVC":
		t.codec = .H265
	case "A_OPUS":
		t.codec = .Opus
	case "A_VORBIS":
		t.codec = .Vorbis
	case "A_AAC":
		t.codec = .AAC
	case "A_AAC/MPEG2/LC", "A_AAC/MPEG4/LC":
		// Legacy IDs carry no AudioSpecificConfig; LC's follows from the
		// track's rate and channels.
		t.codec = .AAC
		if len(t.codec_private) == 0 do t.codec_private = lc_audio_specific_config(t.sample_rate, t.channels)
	case "A_MPEG/L3":
		t.codec = .MP3
	case "A_FLAC":
		t.codec = .FLAC
	case "A_PCM/INT/LIT":
		t.codec = .PCM
		t.pcm_format = {bits = u8(t.bit_depth), little_endian = true, unsigned = t.bit_depth == 8}
	case "A_PCM/INT/BIG":
		t.codec = .PCM
		t.pcm_format = {bits = u8(t.bit_depth), unsigned = t.bit_depth == 8}
	case "A_PCM/FLOAT/IEEE":
		t.codec = .PCM
		t.pcm_format = {bits = u8(t.bit_depth), float = true, little_endian = true}
	}
	if t.codec == .PCM {
		f := t.pcm_format
		valid := f.float ? f.bits == 32 || f.bits == 64 : f.bits == 8 || f.bits == 16 || f.bits == 24 || f.bits == 32
		if !valid do t.codec = .Unknown
	}
	// Compressed or encrypted frames are outside this demuxer.
	if encoded do t.codec = .Unknown
	return .None
}

// ContentEncodings: true when every frame is readable, which is the case
// without encodings or with one header-stripping encoding on frames.
@(private)
parse_content_encodings :: proc(r: ^Reader, t: ^Track, encodings: Element) -> (readable: bool, err: Error) {
	count := 0
	readable = true
	for at := encodings.at; at < encodings.end; {
		e := read_element(r, at, encodings.end) or_return
		at = e.end
		if e.id != u32(ID.Content_Encoding) do continue
		count += 1
		scope, kind, algo: u64 = 1, 0, 0 // the specification's defaults: frames, compression, zlib
		settings: Element
		for c := e.at; c < e.end; {
			f := read_element(r, c, e.end) or_return
			#partial switch ID(f.id) {
			case .Content_Encoding_Scope:
				scope = read_uint(r, f) or_return
			case .Content_Encoding_Type:
				kind = read_uint(r, f) or_return
			case .Content_Compression:
				for g := f.at; g < f.end; {
					h := read_element(r, g, f.end) or_return
					#partial switch ID(h.id) {
					case .Content_Comp_Algo:
						algo = read_uint(r, h) or_return
					case .Content_Comp_Settings:
						settings = h
					}
					g = h.end
				}
			}
			c = f.end
		}
		if kind != 0 || algo != 3 || scope != 1 || settings.size > 4096 {
			readable = false
			continue
		}
		delete(t.stripped)
		t.stripped = read_bytes(r, settings) or_return
	}
	return readable && count <= 1, .None
}

// A two- or five-byte AudioSpecificConfig for AAC-LC (ISO/IEC 14496-3
// 1.6.2.1), with the explicit 24-bit rate when it is not a table rate.
@(private)
lc_audio_specific_config :: proc(rate, channels: int) -> []u8 {
	RATES :: [13]int{96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350}
	if rate <= 0 || rate >= 1 << 24 || channels < 1 || channels > 7 do return nil
	index := 15
	rates := RATES
	for v, i in rates do if v == rate {index = i; break}
	bits, n: u64 = 2, 5 // object type 2 (LC)
	bits, n = bits << 4 | u64(index), n + 4
	if index == 15 do bits, n = bits << 24 | u64(rate), n + 24
	bits, n = bits << 4 | u64(channels), n + 4
	bits, n = bits << 3, n + 3 // 1024 samples, no core coder dependency, no extension
	out := make([]u8, (n + 7) / 8)
	bits <<= u64(len(out) * 8) - n
	for i in 0 ..< len(out) do out[i] = u8(bits >> u64(8 * (len(out) - 1 - i)))
	return out
}

@(private)
parse_video :: proc(r: ^Reader, t: ^Track, video: Element) -> Error {
	for at := video.at; at < video.end; {
		e := read_element(r, at, video.end) or_return
		#partial switch ID(e.id) {
		case .Pixel_Width:
			t.width = int(min(read_uint(r, e) or_return, 1 << 20))
		case .Pixel_Height:
			t.height = int(min(read_uint(r, e) or_return, 1 << 20))
		case .Display_Width:
			t.display_width = int(min(read_uint(r, e) or_return, 1 << 20))
		case .Display_Height:
			t.display_height = int(min(read_uint(r, e) or_return, 1 << 20))
		case .Flag_Interlaced:
			t.interlaced = (read_uint(r, e) or_return) == 1
		case .Alpha_Mode:
			t.alpha = (read_uint(r, e) or_return) == 1
		case .Colour:
			for c := e.at; c < e.end; {
				f := read_element(r, c, e.end) or_return
				v := u8(min(read_uint(r, f) or_return, 255)) if f.size <= 8 else 0
				#partial switch ID(f.id) {
				case .Matrix_Coefficients:
					t.color.matrix_coeffs = v
				case .Primaries:
					t.color.primaries = v
				case .Transfer:
					t.color.transfer = v
				case .Range:
					t.color.range = v
				case .Bits_Per_Channel:
					t.color.bits_per_channel = v
				case .Chroma_Siting_Horz:
					t.color.chroma_siting_horz = v
				case .Chroma_Siting_Vert:
					t.color.chroma_siting_vert = v
				}
				c = f.end
			}
		}
		at = e.end
	}
	return .None
}

// Indexes one cluster's blocks and returns where the next element starts.
// An unknown-size cluster ends at the first element that cannot be its child.
@(private)
parse_cluster :: proc(r: ^Reader, cluster: Element, indices: []Index) -> (next: i64, err: Error) {
	base: i64
	at := cluster.at
	for at < cluster.end {
		e, e_err := read_element(r, at, cluster.end)
		if e_err != .None {
			if cluster.size == UNKNOWN_SIZE do return cluster.end, .None
			return 0, e_err
		}
		#partial switch ID(e.id) {
		case .Timecode:
			base = i64(read_uint(r, e) or_return)
		case .Simple_Block:
			parse_block(r, e, base, indices, {}) or_return
		case .Block_Group:
			parse_block_group(r, e, base, indices) or_return
		case .Position, .Prev_Size, .Void, .CRC32:
		case:
			if cluster.size == UNKNOWN_SIZE do return at, .None
		}
		if e.size == UNKNOWN_SIZE do return 0, .Invalid_Data
		at = e.end
	}
	return cluster.end, .None
}

@(private)
Group :: struct {
	duration:          i64, // ticks; -1 when absent
	discard:           i64, // ns of trailing samples to drop
	reference:         bool,
	additional_offset: i64,
	additional_size:   u32,
}

@(private)
parse_block_group :: proc(r: ^Reader, group: Element, base: i64, indices: []Index) -> Error {
	g := Group {
		duration = -1,
	}
	block: Element
	have_block := false
	for at := group.at; at < group.end; {
		e := read_element(r, at, group.end) or_return
		#partial switch ID(e.id) {
		case .Block:
			block, have_block = e, true
		case .Block_Duration:
			g.duration = i64(min(read_uint(r, e) or_return, 1 << 40))
		case .Reference_Block:
			g.reference = true
		case .Discard_Padding:
			if e.size >= 1 && e.size <= 8 {
				v := read_uint(r, e) or_return
				shift := uint(64 - 8 * e.size)
				g.discard = max(i64(v << shift) >> shift, 0)
			}
		case .Block_Additions:
			for m := e.at; m < e.end; {
				more := read_element(r, m, e.end) or_return
				if more.id == u32(ID.Block_More) {
					add_id: u64 = 1
					payload: Element
					have_payload := false
					for c := more.at; c < more.end; {
						f := read_element(r, c, more.end) or_return
						#partial switch ID(f.id) {
						case .Block_Add_ID:
							add_id = read_uint(r, f) or_return
						case .Block_Additional:
							payload, have_payload = f, true
						}
						c = f.end
					}
					if add_id == 1 && have_payload && payload.size <= i64(max(u32)) {
						g.additional_offset, g.additional_size = payload.at, u32(payload.size)
					}
				}
				m = more.end
			}
		}
		at = e.end
	}
	if !have_block do return .None
	return parse_block(r, block, base, indices, g, true)
}

// A Block or SimpleBlock: track number, signed 16-bit timestamp relative to
// the cluster, flags, then one frame or a lace of several.
@(private)
parse_block :: proc(r: ^Reader, e: Element, base: i64, indices: []Index, g: Group, in_group := false) -> Error {
	number, number_len, _ := read_vint(r, e.at, false) or_return
	head := e.at + i64(number_len)
	if head + 3 > e.end do return .Invalid_Data
	bytes := peek(r, head, 3) or_return
	relative := i64(i16(u16(bytes[0]) << 8 | u16(bytes[1])))
	flags := bytes[2]
	track := -1
	for t, i in r.tracks do if t.number == number {track = i; break}
	if track < 0 do return .None // a block of an undeclared track is skipped
	t := &r.tracks[track]
	keyframe := in_group ? !g.reference : flags & 0x80 != 0
	pts := (base + relative) * r.timecode_scale
	duration := g.duration >= 0 ? g.duration * r.timecode_scale : 0
	data := head + 3
	// Frame sizes of a lace.
	frames: [256]i64
	count := 1
	lacing := (flags >> 1) & 3
	if lacing != 0 {
		n := peek(r, data, 1) or_return
		count = int(n[0]) + 1
		data += 1
		switch lacing {
		case 1: // Xiph: sizes as runs of 255 plus a final byte
			for i in 0 ..< count - 1 {
				size: i64
				for {
					b := peek(r, data, 1) or_return
					data += 1
					size += i64(b[0])
					if b[0] != 255 do break
				}
				frames[i] = size
			}
		case 3: // EBML: first size, then signed differences
			first, first_len, _ := read_vint(r, data, false) or_return
			data += i64(first_len)
			frames[0] = i64(first)
			for i in 1 ..< count - 1 {
				raw, raw_len, _ := read_vint(r, data, false) or_return
				data += i64(raw_len)
				bias := i64(1) << uint(7 * raw_len - 1) - 1
				frames[i] = frames[i - 1] + i64(raw) - bias
			}
		case 2: // fixed
		}
	}
	remaining := e.end - data
	if lacing == 2 {
		if remaining % i64(count) != 0 do return .Invalid_Data
		for i in 0 ..< count do frames[i] = remaining / i64(count)
	} else {
		used: i64
		for i in 0 ..< count - 1 {
			if frames[i] < 0 do return .Invalid_Data
			used += frames[i]
		}
		frames[count - 1] = remaining - used
	}
	if len(indices[track].samples) + count > MAX_SAMPLES do return .Unsupported
	step := t.default_duration
	if count > 1 && duration > 0 do step = duration / i64(count)
	for i in 0 ..< count {
		size := frames[i]
		if size < 0 || size > i64(max(u32)) || data + size > e.end do return .Invalid_Data
		s := Sample {
			offset   = data,
			size     = u32(size),
			pts      = pts + i64(i) * step,
			duration = count == 1 ? duration : step,
			sync     = keyframe && i == 0 || keyframe && t.kind == .Audio,
		}
		if i == 0 do s.additional_offset, s.additional_size = g.additional_offset, g.additional_size
		append(&indices[track].samples, s)
		t.end_discard = g.discard // in file order, so the last block's stays
		data += size
	}
	return .None
}

@(private)
read_all_at :: proc(s: io.Stream, data: []u8, offset: i64) -> Error {
	done := 0
	for done < len(data) {
		n, err := io.read_at(s, data[done:], offset + i64(done))
		if n <= 0 do return err == .EOF ? .Invalid_Data : .IO_Error
		done += n
	}
	return .None
}

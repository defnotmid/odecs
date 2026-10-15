// ISO base media file format (MP4) muxing and demuxing for H.264, H.265 and
// AAC. The package depends only on Odin core: codec configuration records
// are built from the parameter sets carried in the stream, and sample bytes
// pass through unchanged apart from Annex-B/length-prefix framing.
package mp4

import "base:runtime"
import "core:io"

Codec :: enum u8 {
	Unknown,
	H264,
	H265,
	AAC,
	ProRes, // QuickTime apco/apcs/apcn/apch/ap4h/ap4x; one frame per sample
	PCM,    // QuickTime uncompressed audio; one chunk per sample, see Pcm_Format
	FLAC,   // fLaC sample entry; dfLa metadata blocks in audio_specific_config
	MP3,    // mp4a with object type 0x6B/0x69, or QuickTime .mp3; one frame per sample
	AV1,    // av01 sample entry; av1C record in config; one temporal unit per sample (reading only)
	ALAC,   // alac sample entry; 24-byte ALACSpecificConfig in audio_specific_config (reading only)
	Opus,   // Opus sample entry; dOps converted to OpusHead in audio_specific_config (reading only)
}

// Uncompressed QuickTime audio: interleaved frames of `channels` samples.
Pcm_Format :: struct {
	bits:          u8, // 8, 16, 24, 32 or 64 (float only)
	float:         bool,
	little_endian: bool,
	unsigned:      bool, // 8-bit 'raw '
}

Track_Kind :: enum u8 {
	Other,
	Video,
	Audio,
}

Error :: enum {
	None,
	Invalid_Argument, // a caller value is outside the documented contract
	Invalid_Data,     // the file or packet is malformed
	Unsupported,      // valid, but outside the implemented scope
	IO_Error,
	Out_Of_Memory,
	End_Of_Stream,
	Closed,
}

// ISO/IEC 23091-2 (ITU-T H.273) code points, as carried by a `colr` nclx box
// and the H.264/H.265 VUI. Primaries 0 is reserved there; here it means the
// description is absent.
Color :: struct {
	primaries, transfer, matrix_coeffs: u8,
	full_range:                  bool,
}
BT709_LIMITED :: Color{1, 1, 1, false}

// Upper bound on samples per track. It bounds the tables a malformed file can
// make the demuxer expand (stts/stsc are run-length coded) to 64M samples.
MAX_SAMPLES :: 1 << 26

fourcc :: proc "contextless" (s: string) -> u32 {
	return u32(s[0]) << 24 | u32(s[1]) << 16 | u32(s[2]) << 8 | u32(s[3])
}

// A growable in-memory io.Stream with Read_At/Write_At/Size, for muxing to
// memory (for example independently encoded segments) and for tests.
// Writing past the end zero-fills the gap.
Memory_Stream :: struct {
	data: [dynamic]u8,
}

memory_stream :: proc(m: ^Memory_Stream) -> io.Stream {
	return {memory_stream_proc, m}
}

@(private)
memory_stream_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	m := (^Memory_Stream)(stream_data)
	#partial switch mode {
	case .Read_At:
		if offset < 0 do return 0, .Invalid_Offset
		if offset >= i64(len(m.data)) do return 0, .EOF
		return i64(copy(p, m.data[offset:])), .None
	case .Write_At:
		if offset < 0 do return 0, .Invalid_Offset
		end := int(offset) + len(p)
		if end > len(m.data) {
			if resize(&m.data, end) != nil do return 0, .Short_Write
		}
		return i64(copy(m.data[offset:], p)), .None
	case .Size:
		return i64(len(m.data)), .None
	case .Destroy:
		delete(m.data)
		m.data = nil
		return 0, .None
	case .Query:
		return io.query_utility({.Read_At, .Write_At, .Size, .Destroy, .Query})
	}
	return 0, .Unsupported
}

@(private)
write_all_at :: proc(s: io.Stream, data: []u8, offset: i64) -> Error {
	done := 0
	for done < len(data) {
		n, err := io.write_at(s, data[done:], offset + i64(done))
		if n <= 0 || err != .None do return .IO_Error
		done += n
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

@(private)
alloc_error :: proc(err: runtime.Allocator_Error) -> Error {
	return err == .None ? .None : .Out_Of_Memory
}

// ---------------------------------------------------------------------------
// Big-endian box building into a byte array.

@(private)
put_u8 :: proc(b: ^[dynamic]u8, v: u8) {append(b, v)}

@(private)
put_u16 :: proc(b: ^[dynamic]u8, v: u16) {append(b, u8(v >> 8), u8(v))}

@(private)
put_u24 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v >> 16), u8(v >> 8), u8(v))}

@(private)
put_u32 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}

@(private)
put_u64 :: proc(b: ^[dynamic]u8, v: u64) {
	put_u32(b, u32(v >> 32))
	put_u32(b, u32(v))
}

@(private)
put_zeros :: proc(b: ^[dynamic]u8, n: int) {for _ in 0 ..< n do append(b, 0)}

@(private)
put_type :: proc(b: ^[dynamic]u8, type: string) {append(b, type[0], type[1], type[2], type[3])}

@(private)
begin_box :: proc(b: ^[dynamic]u8, type: string) -> int {
	start := len(b)
	put_u32(b, 0)
	put_type(b, type)
	return start
}

@(private)
begin_full_box :: proc(b: ^[dynamic]u8, type: string, version: u8, flags: u32) -> int {
	start := begin_box(b, type)
	put_u32(b, u32(version) << 24 | flags & 0xFFFFFF)
	return start
}

@(private)
end_box :: proc(b: ^[dynamic]u8, start: int) {
	size := u32(len(b) - start)
	b[start], b[start + 1], b[start + 2], b[start + 3] = u8(size >> 24), u8(size >> 16), u8(size >> 8), u8(size)
}

@(private)
get_u16 :: proc "contextless" (b: []u8) -> u16 {return u16(b[0]) << 8 | u16(b[1])}

@(private)
get_u24 :: proc "contextless" (b: []u8) -> u32 {return u32(b[0]) << 16 | u32(b[1]) << 8 | u32(b[2])}

@(private)
get_u32 :: proc "contextless" (b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

@(private)
get_u64 :: proc "contextless" (b: []u8) -> u64 {return u64(get_u32(b)) << 32 | u64(get_u32(b[4:]))}

// ---------------------------------------------------------------------------
// NAL units. Parameter-set parsing reads only the fields the configuration
// records need; decoding remains the codecs' business.

// Splits complete Annex-B data at 3- or 4-byte start codes. Leading bytes
// before the first start code must be zero; trailing zero bytes of each unit
// are trailing_zero_8bits and are dropped.
next_annex_b_nal :: proc(data: []u8, pos: ^int) -> (nal: []u8, ok: bool) {
	i := pos^
	if i == 0 {
		for i + 2 < len(data) && !(data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
			if data[i] != 0 do return nil, false
			i += 1
		}
		if i + 2 >= len(data) do return nil, false
		i += 3
	}
	if i >= len(data) do return nil, false
	start := i
	end := len(data)
	next := len(data)
	for j := start; j + 2 < len(data); j += 1 {
		if data[j + 2] > 1 {j += 2; continue}
		if data[j] == 0 && data[j + 1] == 0 && data[j + 2] == 1 {
			end, next = j, j + 3
			break
		}
	}
	for end > start && data[end - 1] == 0 do end -= 1
	pos^ = next
	if end <= start do return nil, false
	return data[start:end], true
}

// Removes emulation prevention bytes (00 00 03) into scratch.
@(private)
unescape_rbsp :: proc(src: []u8, dst: ^[dynamic]u8) -> []u8 {
	clear(dst)
	zeros := 0
	for b in src {
		if zeros >= 2 && b == 3 {zeros = 0; continue}
		append(dst, b)
		zeros = b == 0 ? zeros + 1 : 0
	}
	return dst[:]
}

@(private)
Bits :: struct {
	data:    []u8,
	pos:     int, // bit position
	overrun: bool,
}

@(private)
read_bits :: proc(b: ^Bits, n: int) -> u32 {
	v: u32
	for _ in 0 ..< n {
		i := b.pos >> 3
		if i >= len(b.data) {b.overrun = true; return v}
		v = v << 1 | u32(b.data[i] >> (7 - uint(b.pos & 7)) & 1)
		b.pos += 1
	}
	return v
}

@(private)
read_ue :: proc(b: ^Bits) -> u32 {
	zeros := 0
	for read_bits(b, 1) == 0 {
		zeros += 1
		if zeros > 31 || b.overrun {b.overrun = true; return 0}
	}
	if zeros == 0 do return 0
	return (u32(1) << uint(zeros)) - 1 + read_bits(b, zeros)
}

Avc_Sps_Info :: struct {
	id:                                 u32,
	profile_idc, constraint_flags:      u8,
	level_idc, chroma_format_idc:       u8,
	bit_depth_luma, bit_depth_chroma:   u8,
}

// Reads the avcC fields of an H.264 SPS NAL (header byte included).
parse_avc_sps :: proc(nal: []u8, scratch: ^[dynamic]u8) -> (info: Avc_Sps_Info, ok: bool) {
	if len(nal) < 5 || nal[0] & 0x1F != 7 do return {}, false
	rbsp := unescape_rbsp(nal[1:], scratch)
	if len(rbsp) < 4 do return {}, false
	info = {
		profile_idc       = rbsp[0],
		constraint_flags  = rbsp[1],
		level_idc         = rbsp[2],
		chroma_format_idc = 1,
		bit_depth_luma    = 8,
		bit_depth_chroma  = 8,
	}
	b := Bits {
		data = rbsp,
		pos  = 24,
	}
	info.id = read_ue(&b)
	switch info.profile_idc {
	case 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135:
		info.chroma_format_idc = u8(read_ue(&b))
		if info.chroma_format_idc == 3 do read_bits(&b, 1)
		info.bit_depth_luma = u8(8 + read_ue(&b))
		info.bit_depth_chroma = u8(8 + read_ue(&b))
	}
	return info, !b.overrun && info.id < 32 && info.chroma_format_idc <= 3
}

Hevc_Sps_Info :: struct {
	id:                               u32,
	max_sub_layers:                   u8,
	temporal_id_nesting:              bool,
	general_ptl:                      [12]u8, // profile space/tier/idc, compatibility, constraints, level
	chroma_format_idc:                u8,
	bit_depth_luma, bit_depth_chroma: u8,
	width, height:                    u32, // coded luma size
}

// Reads the hvcC fields of an H.265 SPS NAL (two header bytes included).
parse_hevc_sps :: proc(nal: []u8, scratch: ^[dynamic]u8) -> (info: Hevc_Sps_Info, ok: bool) {
	if len(nal) < 16 || (nal[0] >> 1) & 0x3F != 33 do return {}, false
	rbsp := unescape_rbsp(nal[2:], scratch)
	if len(rbsp) < 14 do return {}, false
	b := Bits {
		data = rbsp,
	}
	read_bits(&b, 4) // sps_video_parameter_set_id
	max_sub_layers_minus1 := int(read_bits(&b, 3))
	info.max_sub_layers = u8(max_sub_layers_minus1 + 1)
	info.temporal_id_nesting = read_bits(&b, 1) == 1
	copy(info.general_ptl[:], rbsp[1:13])
	b.pos = 8 + 96
	profile_present, level_present: [8]bool
	for i in 0 ..< max_sub_layers_minus1 {
		profile_present[i] = read_bits(&b, 1) == 1
		level_present[i] = read_bits(&b, 1) == 1
	}
	if max_sub_layers_minus1 > 0 do for _ in max_sub_layers_minus1 ..< 8 do read_bits(&b, 2)
	for i in 0 ..< max_sub_layers_minus1 {
		if profile_present[i] do b.pos += 88
		if level_present[i] do b.pos += 8
	}
	info.id = read_ue(&b)
	info.chroma_format_idc = u8(read_ue(&b))
	if info.chroma_format_idc == 3 do read_bits(&b, 1)
	info.width = read_ue(&b)
	info.height = read_ue(&b)
	if read_bits(&b, 1) == 1 do for _ in 0 ..< 4 do read_ue(&b)
	info.bit_depth_luma = u8(8 + read_ue(&b))
	info.bit_depth_chroma = u8(8 + read_ue(&b))
	return info, !b.overrun && info.id < 16 && info.chroma_format_idc <= 3
}

// The parameter-set identifier a configuration record is keyed by.
@(private)
parameter_set_id :: proc(codec: Codec, nal: []u8, scratch: ^[dynamic]u8) -> (id: u32, ok: bool) {
	if codec == .H264 {
		switch nal[0] & 0x1F {
		case 7:
			info := parse_avc_sps(nal, scratch) or_return
			return info.id, true
		case 8:
			b := Bits {
				data = unescape_rbsp(nal[1:], scratch),
			}
			id = read_ue(&b)
			return id, !b.overrun && id < 256
		}
		return 0, false
	}
	if len(nal) < 3 do return 0, false
	switch (nal[0] >> 1) & 0x3F {
	case 32:
		return u32(nal[2] >> 4), true
	case 33:
		info := parse_hevc_sps(nal, scratch) or_return
		return info.id, true
	case 34:
		b := Bits {
			data = unescape_rbsp(nal[2:], scratch),
		}
		id = read_ue(&b)
		return id, !b.overrun && id < 64
	}
	return 0, false
}

// Minimal AudioSpecificConfig fields (ISO/IEC 14496-3 1.6.2.1).
Asc_Info :: struct {
	object_type, channel_config: int,
	sample_rate:                 int,
	frame_samples:               int, // 1024, or 960 with frameLengthFlag (object types 1-4, 6, 7)
}

AAC_SAMPLE_RATES := [13]int{96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350}

parse_asc :: proc(asc: []u8) -> (info: Asc_Info, ok: bool) {
	b := Bits {
		data = asc,
	}
	info.object_type = int(read_bits(&b, 5))
	if info.object_type == 31 do info.object_type = 32 + int(read_bits(&b, 6))
	index := int(read_bits(&b, 4))
	if index == 15 {
		info.sample_rate = int(read_bits(&b, 24))
	} else if index < len(AAC_SAMPLE_RATES) {
		info.sample_rate = AAC_SAMPLE_RATES[index]
	}
	info.channel_config = int(read_bits(&b, 4))
	info.frame_samples = 1024
	switch info.object_type {
	case 1 ..= 4, 6, 7:
		if read_bits(&b, 1) == 1 do info.frame_samples = 960
	}
	return info, !b.overrun && info.sample_rate > 0
}

// Reports whether nal starts a new access unit when the current one already
// holds a picture: a first slice of a picture, or a unit that may only
// precede the first slice (H.264 7.4.1.2.3, H.265 7.4.2.4.4). Use it to group
// an encoder's NAL stream into samples.
starts_access_unit :: proc(codec: Codec, nal: []u8, have_picture: bool) -> bool {
	if !have_picture || len(nal) == 0 do return false
	if codec == .H264 {
		switch nal[0] & 0x1F {
		case 1, 5:
			return len(nal) > 1 && nal[1] & 0x80 != 0 // first_mb_in_slice == 0
		case 6, 7, 8, 9, 13 ..= 18:
			return true
		}
		return false
	}
	if len(nal) < 3 do return false
	// Units of layers above 0 (an alpha layer) belong to the access unit
	// their base-layer picture opened (F.7.4.2.4.4).
	if hevc_layer_id(nal) != 0 do return false
	switch (nal[0] >> 1) & 0x3F {
	case 0 ..= 31:
		return nal[2] & 0x80 != 0 // first_slice_segment_in_pic_flag
	case 32 ..= 35, 39, 41 ..= 44, 48 ..= 55:
		return true
	}
	return false
}

// The nuh_layer_id of an H.265 NAL unit (header included).
hevc_layer_id :: proc(nal: []u8) -> u8 {
	if len(nal) < 2 do return 0
	return (nal[0] & 1) << 5 | nal[1] >> 3
}

// Reports whether a NAL unit carries a picture (a VCL unit).
is_picture_nal :: proc(codec: Codec, nal: []u8) -> bool {
	if len(nal) == 0 do return false
	if codec == .H264 {
		type := nal[0] & 0x1F
		return type >= 1 && type <= 5
	}
	return (nal[0] >> 1) & 0x3F < 32
}

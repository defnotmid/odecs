package webm

import "core:io"
import "core:os"
import "base:intrinsics"

// Video-only VP9. Timestamps and durations at the API boundary are nanoseconds.
Writer_Config :: struct {
	width, height: int,
	alpha: bool,
	default_duration: i64,
}

Writer :: struct {
	stream: io.Stream,
	file: ^os.File,
	config: Writer_Config,
	scratch: [dynamic]u8,
	cues: [dynamic]Writer_Cue,
	position, segment_start, segment_payload: i64,
	cluster_start, cluster_payload, cluster_time: i64,
	cue_seek_at, duration_at: i64,
	last_pts, end_pts: i64,
	have_sample, failed, finished, initialized: bool,
}

@(private)
Writer_Cue :: struct {time, position: u64}

create :: proc(w: ^Writer, path: string, config: Writer_Config) -> Error {
	if w == nil do return .Invalid_Argument
	f, err := os.open(path, {.Read, .Write, .Create, .Trunc}, os.Permissions_Default_File)
	if err != nil do return .IO_Error
	if e := create_stream(w, os.to_stream(f), config); e != .None {os.close(f); return e}
	w.file = f
	return .None
}

// Borrows a seekable Write_At stream. Destroy never finishes an incomplete file.
create_stream :: proc(w: ^Writer, stream: io.Stream, config: Writer_Config) -> Error {
	if w == nil || config.width <= 0 || config.height <= 0 || config.width > 65536 || config.height > 65536 || config.default_duration < 0 do return .Invalid_Argument
	if .Write_At not_in io.query(stream) do return .Invalid_Argument
	w^ = {stream = stream, config = config, cluster_start = -1, initialized = true}
	if reserve(&w.scratch, 512) != nil {destroy(w); return .Out_Of_Memory}
	b := &w.scratch
	ebml := writer_begin(b, 0x1A45DFA3)
	writer_uint(b, 0x4286, 1); writer_uint(b, 0x42F7, 1)
	writer_uint(b, 0x42F2, 4); writer_uint(b, 0x42F3, 8)
	writer_bytes(b, 0x4282, transmute([]u8)string("webm"))
	writer_uint(b, 0x4287, 4); writer_uint(b, 0x4285, 2)
	writer_end(b, ebml)
	w.segment_start = i64(writer_begin(b, 0x18538067))
	w.segment_payload = i64(len(b^))
	seek := writer_begin(b, 0x114D9B74)
	info_seek := writer_seek(b, 0x1549A966)
	tracks_seek := writer_seek(b, 0x1654AE6B)
	w.cue_seek_at = i64(writer_seek(b, 0x1C53BB6B))
	writer_end(b, seek)
	info_pos := len(b^)
	info := writer_begin(b, 0x1549A966)
	writer_uint(b, 0x2AD7B1, 1_000_000)
	writer_bytes(b, 0x4D80, transmute([]u8)string("odecs"))
	writer_bytes(b, 0x5741, transmute([]u8)string("odecs"))
	writer_id(b, 0x4489); writer_size(b, 8)
	w.duration_at = i64(len(b^)); writer_be(b, 0, 8)
	writer_end(b, info)
	tracks_pos := len(b^)
	tracks := writer_begin(b, 0x1654AE6B)
	track := writer_begin(b, 0xAE)
	writer_uint(b, 0xD7, 1); writer_uint(b, 0x73C5, 1); writer_uint(b, 0x83, 1)
	writer_uint(b, 0x9C, 0)
	writer_bytes(b, 0x86, transmute([]u8)string("V_VP9"))
	if config.default_duration > 0 do writer_uint(b, 0x23E383, u64(config.default_duration))
	if config.alpha do writer_uint(b, 0x55EE, 1) // MaxBlockAdditionID
	video := writer_begin(b, 0xE0)
	writer_uint(b, 0xB0, u64(config.width)); writer_uint(b, 0xBA, u64(config.height))
	if config.alpha do writer_uint(b, 0x53C0, 1)
	colour := writer_begin(b, 0x55B0)
	writer_uint(b, 0x55B1, 1); writer_uint(b, 0x55B2, 8)
	writer_uint(b, 0x55B9, 1); writer_uint(b, 0x55BA, 1); writer_uint(b, 0x55BB, 1)
	writer_end(b, colour); writer_end(b, video); writer_end(b, track); writer_end(b, tracks)
	writer_patch_be(b^[:], info_seek, u64(i64(info_pos) - w.segment_payload), 8)
	writer_patch_be(b^[:], tracks_seek, u64(i64(tracks_pos) - w.segment_payload), 8)
	if e := writer_flush(w); e != .None {destroy(w); return e}
	return .None
}

// A colour packet and, when configured, a separately encoded alpha packet.
// Each stream must use the same frame types; the writer does not inspect VP9.
write_sample :: proc(w: ^Writer, packet: []u8, pts: i64, keyframe: bool, alpha: []u8 = nil, duration: i64 = 0) -> Error {
	if w == nil || !w.initialized || w.finished do return .Closed
	if w.failed do return .IO_Error
	if len(packet) == 0 || pts < 0 || duration < 0 || (len(alpha) > 0) != w.config.alpha || (w.have_sample && pts <= w.last_pts) || (!w.have_sample && !keyframe) do return .Invalid_Argument
	frame_duration := duration > 0 ? duration : w.config.default_duration > 0 ? w.config.default_duration : w.have_sample ? pts - w.last_pts : 0
	if pts > max(i64) - frame_duration do return .Invalid_Argument
	tick := pts / 1_000_000
	if w.have_sample && tick <= w.last_pts / 1_000_000 do return .Invalid_Argument
	// Every append below then stays within capacity; failure changes nothing.
	if reserve(&w.scratch, len(packet) + len(alpha) + 128) != nil do return .Out_Of_Memory
	if keyframe && reserve(&w.cues, len(w.cues) + 1) != nil do return .Out_Of_Memory
	if w.cluster_start < 0 || keyframe || tick - w.cluster_time > 32767 {
		writer_close_cluster(w) or_return
		w.cluster_start = w.position
		w.cluster_time = tick
		b := &w.scratch
		writer_begin(b, 0x1F43B675)
		w.cluster_payload = w.position + i64(len(b^))
		writer_uint(b, 0xE7, u64(tick))
		writer_flush(w) or_return
	}
	if keyframe do append(&w.cues, Writer_Cue{u64(tick), u64(w.cluster_start - w.segment_payload)})
	b := &w.scratch
	group := -1
	if w.config.alpha do group = writer_begin(b, 0xA0)
	writer_id(b, w.config.alpha ? 0xA1 : 0xA3)
	writer_size(b, u64(len(packet) + 4))
	append(b, 0x81)
	writer_be(b, u64(tick - w.cluster_time), 2)
	append(b, !w.config.alpha && keyframe ? u8(0x80) : 0)
	append(b, ..packet)
	if w.config.alpha {
		if !keyframe {
			// Negative signed reference to the preceding frame, in ticks.
			writer_id(b, 0xFB); writer_size(b, 8)
			writer_be(b, u64(w.last_pts / 1_000_000 - tick), 8)
		}
		if duration > 0 do writer_uint(b, 0x9B, u64(max(i64(1), duration / 1_000_000)))
		adds := writer_begin(b, 0x75A1)
		more := writer_begin(b, 0xA6)
		writer_uint(b, 0xEE, 1)
		writer_bytes(b, 0xA5, alpha)
		writer_end(b, more); writer_end(b, adds); writer_end(b, group)
	}
	writer_flush(w) or_return
	w.have_sample = true
	w.last_pts = pts
	w.end_pts = pts + frame_duration
	return .None
}

finish :: proc(w: ^Writer) -> Error {
	if w == nil || !w.initialized do return .Closed
	if w.failed do return .IO_Error
	if w.finished do return .None
	if reserve(&w.scratch, 64 + len(w.cues) * 48) != nil do return .Out_Of_Memory
	writer_close_cluster(w) or_return
	cue_pos := w.position - w.segment_payload
	b := &w.scratch
	cues := writer_begin(b, 0x1C53BB6B)
	for c in w.cues {
		point := writer_begin(b, 0xBB)
		writer_uint(b, 0xB3, c.time)
		pos := writer_begin(b, 0xB7)
		writer_uint(b, 0xF7, 1); writer_uint(b, 0xF1, c.position)
		writer_end(b, pos); writer_end(b, point)
	}
	writer_end(b, cues)
	writer_flush(w) or_return
	patch: [8]u8
	writer_patch_be(patch[:], 0, u64(cue_pos), 8)
	writer_write_at(w, patch[:], w.cue_seek_at) or_return
	if w.end_pts > 0 {
		writer_patch_be(patch[:], 0, transmute(u64)(f64(w.end_pts) / 1e6), 8)
		writer_write_at(w, patch[:], w.duration_at) or_return
	} else {
		// Duration must be positive: replace its 11 bytes with a Void element.
		writer_write_at(w, {0xEC, 0x89}, w.duration_at - 3) or_return
	}
	writer_patch_be(patch[:], 0, u64(w.position - w.segment_payload) | 1 << 56, 8)
	writer_write_at(w, patch[:], w.segment_start) or_return
	w.finished = true
	return .None
}

destroy :: proc(w: ^Writer) {
	if w == nil do return
	if w.file != nil do os.close(w.file)
	delete(w.scratch); delete(w.cues)
	w^ = {}
}

@(private)
writer_close_cluster :: proc(w: ^Writer) -> Error {
	if w.cluster_start < 0 do return .None
	patch: [8]u8
	writer_patch_be(patch[:], 0, u64(w.position - w.cluster_payload) | 1 << 56, 8)
	writer_write_at(w, patch[:], w.cluster_start + 4) or_return
	w.cluster_start = -1
	return .None
}

@(private)
writer_write_at :: proc(w: ^Writer, data: []u8, offset: i64) -> Error {
	at := 0
	for at < len(data) {
		n, e := io.write_at(w.stream, data[at:], offset + i64(at))
		if e != .None || n <= 0 {w.failed = true; return .IO_Error}
		at += n
	}
	return .None
}

@(private)
writer_flush :: proc(w: ^Writer) -> Error {
	writer_write_at(w, w.scratch[:], w.position) or_return
	w.position += i64(len(w.scratch))
	clear(&w.scratch)
	return .None
}

@(private)
writer_be :: proc(b: ^[dynamic]u8, value: u64, bytes: int) {
	for i := bytes - 1; i >= 0; i -= 1 do append(b, u8(value >> uint(i * 8)))
}

@(private)
writer_patch_be :: proc(b: []u8, at: int, value: u64, bytes: int) {
	for i in 0 ..< bytes do b[at + i] = u8(value >> uint((bytes - 1 - i) * 8))
}

@(private)
writer_id :: proc(b: ^[dynamic]u8, id: u32) {
	bytes := (32 - intrinsics.count_leading_zeros(id) + 7) / 8
	writer_be(b, u64(id), int(bytes))
}

@(private)
writer_size :: proc(b: ^[dynamic]u8, size: u64) {
	bytes := 1
	for bytes < 8 && size >= (u64(1) << uint(7 * bytes)) - 1 do bytes += 1
	writer_be(b, size | u64(1) << uint(7 * bytes), bytes)
}

@(private)
writer_begin :: proc(b: ^[dynamic]u8, id: u32) -> int {
	writer_id(b, id)
	at := len(b^)
	writer_be(b, 0x01FFFFFFFFFFFFFF, 8)
	return at
}

@(private)
writer_end :: proc(b: ^[dynamic]u8, at: int) {
	writer_patch_be(b^[:], at, u64(len(b^) - at - 8) | 1 << 56, 8)
}

@(private)
writer_uint :: proc(b: ^[dynamic]u8, id: u32, value: u64) {
	bytes := max(1, int((64 - intrinsics.count_leading_zeros(value) + 7) / 8))
	writer_id(b, id); writer_size(b, u64(bytes)); writer_be(b, value, bytes)
}

@(private)
writer_bytes :: proc(b: ^[dynamic]u8, id: u32, value: []u8) {
	writer_id(b, id); writer_size(b, u64(len(value))); append(b, ..value)
}

@(private)
writer_seek :: proc(b: ^[dynamic]u8, id: u32) -> int {
	entry := writer_begin(b, 0x4DBB)
	writer_id(b, 0x53AB); writer_size(b, 4); writer_be(b, u64(id), 4)
	writer_id(b, 0x53AC); writer_size(b, 8)
	at := len(b^); writer_be(b, 0, 8)
	writer_end(b, entry)
	return at
}

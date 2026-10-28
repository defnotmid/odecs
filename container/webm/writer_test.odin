package webm

import "core:io"
import "core:testing"

@(private = "file")
Writer_Memory :: struct {data: [dynamic]u8, fail: bool}

@(private = "file")
writer_memory_stream :: proc(m: ^Writer_Memory) -> io.Stream {
	callback :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
		m := cast(^Writer_Memory)data
		#partial switch mode {
		case .Write_At:
			if m.fail do return 0, .Unsupported
			if offset < 0 || offset > i64(max(int) - len(p)) do return 0, .Unsupported
			end := int(offset) + len(p)
			if end > len(m.data) do resize(&m.data, end)
			return i64(copy(m.data[offset:], p)), .None
		case .Read_At:
			if offset < 0 do return 0, .Unsupported
			if offset >= i64(len(m.data)) do return 0, .EOF
			return i64(copy(p, m.data[offset:])), .None
		case .Size: return i64(len(m.data)), .None
		case .Query: return io.query_utility({.Read_At, .Write_At, .Size, .Query})
		}
		return 0, .Unsupported
	}
	return {callback, m}
}

@(test)
writer_roundtrip :: proc(t: ^testing.T) {
	for alpha in ([2]bool{false,true}) {
		m: Writer_Memory
		w: Writer
		testing.expect_value(t, create_stream(&w, writer_memory_stream(&m), {width = 65, height = 67, alpha = alpha, default_duration = 33_333_333}), .None)
		for i in 0 ..< 12 {
			pts := i64(i) * 33_333_333 + (i >= 6 ? i64(40_000_000_000) : 0)
			testing.expect_value(t, write_sample(&w, {u8(i),23}, pts, i % 3 == 0, alpha ? []u8{128,u8(i)} : nil), .None)
		}
		testing.expect_value(t, finish(&w), .None)
		testing.expect_value(t, finish(&w), .None)
		testing.expect_value(t, write_sample(&w, {1}, 100_000_000_000, true), .Closed)
		r: Reader
		testing.expect_value(t, open_stream(&r, writer_memory_stream(&m)), .None)
		testing.expect_value(t, len(r.tracks), 1)
		testing.expect_value(t, len(r.tracks[0].samples), 12)
		testing.expect_value(t, r.tracks[0].alpha, alpha)
		testing.expect_value(t, r.tracks[0].width, 65)
		testing.expect_value(t, r.tracks[0].height, 67)
		testing.expect_value(t, r.tracks[0].color, Color{primaries = 1, transfer = 1, matrix_coeffs = 1, range = 1, bits_per_channel = 8})
		for i in 0 ..< 12 {
			p, e := read_sample(&r, 0, i)
			testing.expect_value(t, e, .None)
			testing.expect_value(t, p.data[0], u8(i))
			testing.expect_value(t, p.sync, i % 3 == 0)
			testing.expect_value(t, p.pts, (i64(i) * 33_333_333 / 1_000_000 + (i >= 6 ? i64(40_000) : 0)) * 1_000_000)
			if alpha do testing.expect_value(t, p.additional[1], u8(i))
		}
		close(&r); destroy(&w); delete(m.data)
	}
}

@(test)
writer_errors :: proc(t: ^testing.T) {
	m: Writer_Memory
	defer delete(m.data)
	w: Writer
	testing.expect_value(t, create_stream(&w, writer_memory_stream(&m), {width = 0, height = 1}), .Invalid_Argument)
	testing.expect_value(t, create_stream(&w, writer_memory_stream(&m), {width = 64, height = 64, alpha = true}), .None)
	defer destroy(&w)
	testing.expect_value(t, write_sample(&w, {1}, 0, false, {2}), .Invalid_Argument)
	testing.expect_value(t, write_sample(&w, {1}, 0, true), .Invalid_Argument)
	testing.expect_value(t, write_sample(&w, {1}, 0, true, {2}), .None)
	testing.expect_value(t, write_sample(&w, {1}, 0, false, {2}), .Invalid_Argument)
	m.fail = true
	testing.expect_value(t, write_sample(&w, {1}, 33_333_333, false, {2}), .IO_Error)
	testing.expect_value(t, finish(&w), .IO_Error)
}

// Final duration: explicit, else DefaultDuration, else the preceding PTS delta.
// A lone frame at zero with none of these has no positive Duration to state.
@(test)
writer_final_duration :: proc(t: ^testing.T) {
	Case :: struct {default_duration, last_duration: i64, pts: []i64, seconds: f64}
	for c in ([]Case{
		{0, 0, {0, 40_000_000}, 0.08},
		{0, 10_000_000, {0, 40_000_000}, 0.05},
		{20_000_000, 0, {0, 40_000_000}, 0.06},
		{0, 0, {7_000_000}, 0.007},
		{0, 0, {0}, 0},
	}) {
		m: Writer_Memory
		w: Writer
		testing.expect_value(t, create_stream(&w, writer_memory_stream(&m), {width = 16, height = 16, default_duration = c.default_duration}), .None)
		for pts, i in c.pts {
			duration := i + 1 == len(c.pts) ? c.last_duration : 0
			testing.expect_value(t, write_sample(&w, {1}, pts, i == 0, nil, duration), .None)
		}
		testing.expect_value(t, finish(&w), .None)
		r: Reader
		testing.expect_value(t, open_stream(&r, writer_memory_stream(&m)), .None)
		testing.expect_value(t, len(r.tracks), 1)
		testing.expect(t, abs(r.duration - c.seconds) < 1e-9)
		close(&r); destroy(&w); delete(m.data)
	}
	m: Writer_Memory
	defer delete(m.data)
	w: Writer
	testing.expect_value(t, create_stream(&w, writer_memory_stream(&m), {width = 16, height = 16}), .None)
	defer destroy(&w)
	testing.expect_value(t, write_sample(&w, {1}, max(i64) / 2 + 1, true), .None)
	// The previous-delta fallback would overflow the end timestamp.
	testing.expect_value(t, write_sample(&w, {1}, max(i64) - 1_000_000, false), .Invalid_Argument)
	// Submillisecond spacing floors to the same tick.
	testing.expect_value(t, write_sample(&w, {1}, max(i64) / 2 + 2, false, nil, 1), .Invalid_Argument)
}

@(test)
writer_seekhead_and_sizes :: proc(t: ^testing.T) {
	m: Writer_Memory
	defer delete(m.data)
	w: Writer
	testing.expect_value(t, create_stream(&w, writer_memory_stream(&m), {width = 16, height = 16, default_duration = 33_333_333}), .None)
	defer destroy(&w)
	testing.expect_value(t, write_sample(&w, {1}, 0, true), .None)
	testing.expect_value(t, write_sample(&w, {2}, 33_333_333, false), .None)
	testing.expect_value(t, write_sample(&w, {3}, 100_000_000, true), .None)
	testing.expect_value(t, finish(&w), .None)
	r := Reader{stream = writer_memory_stream(&m), size = i64(len(m.data)), window_at = -1}
	header, err := read_element(&r, 0, r.size)
	testing.expect_value(t, err, .None)
	segment, se := read_element(&r, header.end, r.size)
	testing.expect_value(t, se, .None)
	testing.expect_value(t, segment.end, r.size)
	testing.expect(t, segment.size != UNKNOWN_SIZE)
	seek, he := read_element(&r, segment.at, segment.end)
	testing.expect_value(t, he, .None)
	testing.expect_value(t, seek.id, u32(0x114D9B74))
	count := 0
	for at := seek.at; at < seek.end; {
		entry, ee := read_element(&r, at, seek.end)
		testing.expect_value(t, ee, .None)
		id, ie := read_element(&r, entry.at, entry.end)
		testing.expect_value(t, ie, .None)
		target_id, tie := read_uint(&r, id)
		testing.expect_value(t, tie, .None)
		position, pe := read_element(&r, id.end, entry.end)
		testing.expect_value(t, pe, .None)
		target_position, tpe := read_uint(&r, position)
		testing.expect_value(t, tpe, .None)
		target, te := read_element(&r, segment.at + i64(target_position), segment.end)
		testing.expect_value(t, te, .None)
		testing.expect_value(t, target.id, u32(target_id))
		at = entry.end
		count += 1
	}
	testing.expect_value(t, count, 3)
	clusters := 0
	for at := segment.at; at < segment.end; {
		e, ee := read_element(&r, at, segment.end)
		testing.expect_value(t, ee, .None)
		testing.expect(t, e.size != UNKNOWN_SIZE)
		if e.id == u32(ID.Cluster) do clusters += 1
		at = e.end
	}
	testing.expect_value(t, clusters, 2)
}

@(test)
writer_chapters_roundtrip_and_validation :: proc(t: ^testing.T) {
	chapters := []Chapter{
		{0, "Intro"},
		{0.033333333, "Scène 2: Café & 🎬"},
		{0.066666666, "Finale"},
	}
	m: Writer_Memory
	defer delete(m.data)
	w: Writer
	testing.expect_value(t, create_stream(&w, writer_memory_stream(&m), {width = 32, height = 32, default_duration = 33_333_333, chapters = chapters}), .None)
	for i in 0 ..< 3 {
		testing.expect_value(t, write_sample(&w, {u8(i + 1)}, i64(i) * 33_333_333, i == 0), .None)
	}
	testing.expect_value(t, finish(&w), .None)
	destroy(&w)

	r: Reader
	testing.expect_value(t, open_stream(&r, writer_memory_stream(&m)), .None)
	defer close(&r)
	testing.expect_value(t, len(r.chapters), len(chapters))
	for c, i in r.chapters {
		testing.expect_value(t, c, chapters[i])
	}

	// SeekHead includes Chapters (4 entries total: Info, Tracks, Chapters, Cues).
	header, _ := read_element(&r, 0, r.size)
	segment, _ := read_element(&r, header.end, r.size)
	seek, _ := read_element(&r, segment.at, segment.end)
	seek_count := 0
	found_chapters := false
	for at := seek.at; at < seek.end; {
		entry, _ := read_element(&r, at, seek.end)
		id, _ := read_element(&r, entry.at, entry.end)
		target_id, _ := read_uint(&r, id)
		position, _ := read_element(&r, id.end, entry.end)
		target_pos, _ := read_uint(&r, position)
		target, te := read_element(&r, segment.at + i64(target_pos), segment.end)
		testing.expect_value(t, te, .None)
		testing.expect_value(t, target.id, u32(target_id))
		if target.id == u32(ID.Chapters) do found_chapters = true
		at = entry.end
		seek_count += 1
	}
	testing.expect_value(t, seek_count, 4)
	testing.expect(t, found_chapters)

	// Invalid chapter configurations must be refused with .Invalid_Argument.
	for bad in ([][]Chapter{
		{{0.1, "Not zero"}},
		{{-0.1, "Negative"}},
		{{0, ""}},
		{{0, "A"}, {0.5, ""}},
		{{0, "A"}, {0, "Duplicate"}},
		{{0, "A"}, {0.5, "B"}, {0.2, "Unsorted"}},
		{{0, "A"}, {0.5, "B"}, {0.5, "Equal"}},
	}) {
		bm: Writer_Memory
		defer delete(bm.data)
		bw: Writer
		testing.expect_value(t, create_stream(&bw, writer_memory_stream(&bm), {width = 16, height = 16, chapters = bad}), .Invalid_Argument)
		destroy(&bw)
	}

	// A chapter starting at or past the media's end is refused at finish.
	for last_start in ([2]f64{0.06, 0.1}) {
		bm: Writer_Memory
		defer delete(bm.data)
		bw: Writer
		testing.expect_value(t, create_stream(&bw, writer_memory_stream(&bm), {width = 16, height = 16, default_duration = 30_000_000, chapters = {{0, "Start"}, {last_start, "Past end"}}}), .None)
		testing.expect_value(t, write_sample(&bw, {1}, 0, true), .None)
		testing.expect_value(t, write_sample(&bw, {2}, 30_000_000, false), .None)
		testing.expect_value(t, finish(&bw), .Invalid_Argument)
		destroy(&bw)
	}
}


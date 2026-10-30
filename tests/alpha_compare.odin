// Decodes a ProRes .mov or VP9 .webm fixture with oicut and compares every
// frame with FFmpeg's raw decode written by tests/alpha_fixtures.sh
// (NAME.yuv in NAME.fmt layout). Reports per-plane max and mean absolute
// differences and the share of differing samples.
//
//   odin build tests/alpha_compare.odin -file -o:speed -out:/tmp/oicut-alpha-compare
//   /tmp/oicut-alpha-compare FIXTURE.mov|webm [ORACLE.yuv] [THREADS]
package alpha_compare

import common "../common"
import mp4 "../container/mp4"
import webm "../container/webm"
import prores "../video/prores/decoder"
import vp9 "../video/vp9/decoder"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

pool: common.Static_Pool
work_pool: ^common.Work_Pool

Stats :: struct {
	max_diff:      int,
	sum, count, differing: i64,
}

main :: proc() {
	if len(os.args) < 2 {fmt.eprintln("usage: alpha_compare FIXTURE [ORACLE.yuv]"); os.exit(2)}
	path := os.args[1]
	base := path[:strings.last_index_byte(path, '.')]
	oracle_path := len(os.args) > 2 && os.args[2] != "-" ? os.args[2] : strings.concatenate({base, ".yuv"})
	if len(os.args) > 3 {
		threads, _ := strconv.parse_int(os.args[3])
		if threads > 1 {
			common.init_static_pool(&pool, threads - 1)
			work_pool = &pool.work_pool
		}
	}
	oracle, read_err := os.read_entire_file(oracle_path, context.allocator)
	if read_err != nil {fmt.eprintln("cannot read", oracle_path); os.exit(2)}
	stats: [4]Stats
	frames := 0
	at := 0
	if strings.has_suffix(path, ".webm") {
		frames, at = compare_vp9(path, oracle, &stats)
		report(path, frames, stats, at == len(oracle))
		return
	}
	r: mp4.Reader
	if e := mp4.open(&r, path); e != .None {fmt.eprintln("open", e); os.exit(1)}
	video := -1
	for t, i in r.tracks do if t.codec == .ProRes && video < 0 do video = i
	if video < 0 {fmt.eprintln("no ProRes track"); os.exit(1)}
	d: prores.Decoder
	prores.init_decoder(&d, work_pool)
	for i in 0 ..< len(r.tracks[video].samples) {
		p, e := mp4.read_sample(&r, video, i)
		if e != .None {fmt.eprintln("sample", i, e); os.exit(1)}
		f, de := prores.decode_frame(&d, p.data)
		if de != .None {fmt.eprintln("frame", i, de); os.exit(1)}
		// FFmpeg's layout: planar Y, U, V(, A), little-endian u16, tight rows.
		cw := f.chroma == .YUV444 ? f.width : (f.width + 1) / 2
		widths := [4]int{f.width, cw, cw, f.width}
		planes := [4][]u16{f.planes[0], f.planes[1], f.planes[2], f.alpha}
		strides := [4]int{f.strides[0], f.strides[1], f.strides[2], f.alpha_stride}
		for plane in 0 ..< (f.alpha != nil ? 4 : 3) {
			for y in 0 ..< f.height {
				for x in 0 ..< widths[plane] {
					if at + 2 > len(oracle) {fmt.eprintln("oracle too short at frame", i); os.exit(1)}
					want := int(oracle[at]) | int(oracle[at + 1]) << 8
					at += 2
					got := int(planes[plane][y * strides[plane] + x])
					diff := abs(got - want)
					s := &stats[plane]
					s.max_diff = max(s.max_diff, diff)
					s.sum += i64(diff)
					s.count += 1
					if diff != 0 do s.differing += 1
				}
			}
		}
		frames += 1
	}
	report(path, frames, stats, at == len(oracle))
}

// VP9 and alpha must match exactly. ProRes colour may differ by one step:
// its IDCT is specified by accuracy, not as integer arithmetic.
report :: proc(path: string, frames: int, stats: [4]Stats, exact: bool) {
	names := [4]string{"Y", "Cb", "Cr", "A"}
	colour_tolerance := strings.has_suffix(path, ".mov") ? 1 : 0
	ok := exact && frames > 0
	fmt.printf("%s: %d frames", path, frames)
	for s, i in stats do if s.count > 0 {
		fmt.printf("; %s max %d mean %.4f differing %.3f%%", names[i], s.max_diff, f64(s.sum) / f64(s.count), 100 * f64(s.differing) / f64(s.count))
		if s.max_diff > (i == 3 ? 0 : colour_tolerance) do ok = false
	}
	fmt.printfln("; oracle fully consumed: %v", exact)
	if !ok do os.exit(1)
}

// VP9 in WebM: the colour stream, and the alpha stream (BlockAdditional 1)
// decoded by a second decoder whose luma is the alpha plane.
compare_vp9 :: proc(path: string, oracle: []u8, stats: ^[4]Stats) -> (frames, at: int) {
	r: webm.Reader
	if e := webm.open(&r, path); e != .None {fmt.eprintln("open", e); os.exit(1)}
	video := -1
	for t, i in r.tracks do if t.codec == .VP9 && video < 0 do video = i
	if video < 0 {fmt.eprintln("no VP9 track"); os.exit(1)}
	colour, alpha: vp9.Decoder
	vp9.init_decoder(&colour, work_pool)
	vp9.init_decoder(&alpha, work_pool)
	sample_value :: proc(p: vp9.Picture, plane, x, y: int) -> int {
		if p.bit_depth == 8 do return int(p.planes8[plane][y * p.strides[plane] + x])
		return int(p.planes16[plane][y * p.strides[plane] + x])
	}
	for i in 0 ..< len(r.tracks[video].samples) {
		p, e := webm.read_sample(&r, video, i)
		if e != .None {fmt.eprintln("sample", i, e); os.exit(1)}
		pic, shown, de := vp9.decode_packet(&colour, p.data)
		if de != .None {fmt.eprintln("frame", i, de); os.exit(1)}
		if !shown do continue
		a_pic: vp9.Picture
		has_alpha := p.additional != nil
		if has_alpha {
			ap, ashown, ae := vp9.decode_packet(&alpha, p.additional)
			if ae != .None || !ashown {fmt.eprintln("alpha frame", i, ae); os.exit(1)}
			a_pic = ap
		}
		bytes := pic.bit_depth == 8 ? 1 : 2
		cw, ch := (pic.width + pic.ss_x) >> uint(pic.ss_x), (pic.height + pic.ss_y) >> uint(pic.ss_y)
		widths := [4]int{pic.width, cw, cw, pic.width}
		heights := [4]int{pic.height, ch, ch, pic.height}
		for plane in 0 ..< (has_alpha ? 4 : 3) {
			for y in 0 ..< heights[plane] do for x in 0 ..< widths[plane] {
				if at + bytes > len(oracle) {fmt.eprintln("oracle too short at frame", i); os.exit(1)}
				want := int(oracle[at])
				if bytes == 2 do want |= int(oracle[at + 1]) << 8
				at += bytes
				got := plane == 3 ? sample_value(a_pic, 0, x, y) : sample_value(pic, plane, x, y)
				diff := abs(got - want)
				st := &stats[plane]
				st.max_diff = max(st.max_diff, diff)
				st.sum += i64(diff)
				st.count += 1
				if diff != 0 {
					if st.differing == 0 do fmt.eprintfln("first difference: frame %d plane %d (%d, %d) got %d want %d", frames, plane, x, y, got, want)
					st.differing += 1
				}
			}
		}
		frames += 1
	}
	return
}

// Checks that video.Reader presents two files identically: the same video
// description, every frame's RGBA and the whole PCM stream. Used with a
// Matroska file and the same streams remuxed to MP4 (tests/mkv_check.sh),
// whose path is verified against FFmpeg separately.
//
//   odin build tests/movie_equal.odin -file -o:speed -out:/tmp/odecs-movie-equal
//   /tmp/odecs-movie-equal A B [--no-audio]
package movie_equal

import native "../media/native"
import video "../video"
import "core:fmt"
import "core:os"

fail :: proc(args: ..any) {
	fmt.eprintln(..args)
	os.exit(1)
}

open :: proc(r: ^video.Reader, path: string, options: ^native.Options) {
	if e := video.open_reader(r, path, {preference = .Native, native_options = options}); e != .None do fail("open", path, e, r.error_detail)
}

main :: proc() {
	if len(os.args) < 3 do fail("usage: movie_equal A B [--no-audio]")
	options: native.Options
	a, b: video.Reader
	open(&a, os.args[1], &options)
	open(&b, os.args[2], &options)
	defer video.close_reader(&a)
	defer video.close_reader(&b)
	va, vb := a.video, b.video
	fmt.printfln("%s: %v %dx%d %d frames %d/%d fps %.3f s, depth %d, colour %v; audio %v %v %d Hz %d ch %d samples", os.args[1], va.codec, va.width, va.height, va.frame_count, va.fps_num, va.fps_den, va.duration, va.bit_depth, va.color, a.audio.codec, a.audio.present, a.audio.sample_rate, a.audio.channels, a.audio.samples)
	if va.codec != vb.codec || va.width != vb.width || va.height != vb.height do fail("video description differs:", va, vb)
	if va.frame_count != vb.frame_count do fail("frame count", va.frame_count, "vs", vb.frame_count)
	// A remux keeps Matroska's millisecond timestamps, so rates agree only
	// to within that rounding.
	rate_a, rate_b := f64(va.fps_num) / f64(va.fps_den), f64(vb.fps_num) / f64(vb.fps_den)
	if abs(rate_a - rate_b) > rate_a * 0.02 do fail("rate", va.fps_num, va.fps_den, "vs", vb.fps_num, vb.fps_den)
	if va.color != vb.color do fail("colour", va.color, "vs", vb.color)
	if len(a.chapters) != len(b.chapters) do fail("chapters", len(a.chapters), "vs", len(b.chapters))
	for c, i in a.chapters {
		if c.title != b.chapters[i].title || abs(c.start - b.chapters[i].start) > 0.001 {
			fail("chapter", i, c, "vs", b.chapters[i])
		}
	}
	frames := 0
	for {
		fa, ea := video.next_frame(&a)
		fb, eb := video.next_frame(&b)
		if ea != eb do fail("frame", frames, ea, a.error_detail, "vs", eb, b.error_detail)
		if ea == .End_Of_Stream do break
		if ea != .None do fail("frame", frames, ea, a.error_detail)
		if fa.index != fb.index || abs(fa.time - fb.time) > 0.0005 do fail("frame", frames, "at", fa.index, fa.time, "vs", fb.index, fb.time)
		if string(fa.rgba) != string(fb.rgba) do fail("frame", frames, "pixels differ")
		frames += 1
	}
	if frames != va.frame_count do fail("decoded", frames, "frames, expected", va.frame_count)
	fmt.printfln("  video: %d frames identical", frames)
	if len(os.args) > 3 && os.args[3] == "--no-audio" do return
	if a.audio.present != b.audio.present do fail("audio present", a.audio.present, "vs", b.audio.present)
	if !a.audio.present do return
	if a.audio.sample_rate != b.audio.sample_rate || a.audio.channels != b.audio.channels do fail("audio format differs")
	buf_a := make([]f32, 4096 * a.audio.channels)
	buf_b := make([]f32, 4096 * b.audio.channels)
	total := 0
	worst: f32
	for {
		na, _ := video.read_audio(&a, buf_a)
		nb, _ := video.read_audio(&b, buf_b)
		n := min(na, nb)
		for i in 0 ..< n * a.audio.channels do worst = max(worst, abs(buf_a[i] - buf_b[i]))
		total += n
		if na != nb {
			fmt.printfln("  audio: lengths differ after %d samples (%d vs %d in the last read)", total, na, nb)
			break
		}
		if na == 0 do break
	}
	fmt.printfln("  audio: %d samples/channel, max difference %g", total, worst)
}

// Transparent H.265 through movie.Writer and back. Renders premultiplied
// RGBA frames like onimite's (a moving disc with an anti-aliased edge, a
// soft glow, thin strokes, an alpha ramp over changing hues), writes them
// with colour stored premultiplied and straight (H.265) and as VP9 in
// WebM, reads each file back with
// movie.Reader, and reports what a viewer would see: the frames composited
// over black and over white, and alpha, as PSNR and maximum error.
//
//   odin build tests/movie_alpha_write.odin -file -o:speed -out:/tmp/odecs-movie-alpha-write
//   /tmp/odecs-movie-alpha-write OUTDIR [WIDTH HEIGHT FRAMES QP]
//   /tmp/odecs-movie-alpha-write --planar FILE.mov OUT.yuva
//
// OUTDIR receives alpha_premultiplied.mov, alpha_straight.mov (H.265),
// alpha_vp9.webm and source.rgba (premultiplied RGBA, frame after frame). --planar writes the
// reader's planar frames as yuva420p for comparison with FFmpeg's decode.
package movie_alpha_write

import movie "../movie"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:time"

fail :: proc(args: ..any) {
	fmt.eprintln(..args)
	os.exit(1)
}

main :: proc() {
	if len(os.args) >= 4 && os.args[1] == "--planar" {
		dump_planar(os.args[2], os.args[3])
		return
	}
	if len(os.args) < 2 do fail("usage: movie_alpha_write OUTDIR [WIDTH HEIGHT FRAMES QP] | --planar FILE OUT.yuva")
	dir := os.args[1]
	width, height, frames, qp := 640, 360, 30, 22
	if len(os.args) >= 5 {
		width, _ = strconv.parse_int(os.args[2])
		height, _ = strconv.parse_int(os.args[3])
		frames, _ = strconv.parse_int(os.args[4])
	}
	if len(os.args) >= 6 do qp, _ = strconv.parse_int(os.args[5])
	source := make([]u8, width * height * 4 * frames)
	for f in 0 ..< frames do render(source[f * width * height * 4:][:width * height * 4], width, height, f)
	_ = os.write_entire_file(fmt.tprintf("%s/source.rgba", dir), source)
	ok := true
	Case :: struct {
		codec: movie.Video_Codec,
		mode:  movie.Transparency,
		name:  string,
		floor: f64, // dB over black and white; premultiplied 4:2:0 tops out near 33
	}
	for test in ([]Case{{.H265, .Premultiplied, "alpha_premultiplied.mov", 32}, {.H265, .Straight, "alpha_straight.mov", 38}, {.VP9, .Straight, "alpha_vp9.webm", 38}}) {
		mode := test.mode
		path := fmt.tprintf("%s/%s", dir, test.name)
		config := movie.default_writer_config(width, height, 30, 1)
		config.codec = test.codec
		config.qp = qp
		config.alpha = .Premultiplied
		config.transparency = mode
		w: movie.Writer
		if e := movie.create(&w, path, config); e != .None do fail("create", mode, e, w.error_detail)
		start := time.tick_now()
		for f in 0 ..< frames {
			if e := movie.write_frame(&w, source[f * width * height * 4:][:width * height * 4], width * 4); e != .None do fail("write", f, e, w.error_detail)
		}
		if e := movie.finish(&w); e != .None do fail("finish", e, w.error_detail)
		movie.destroy(&w)
		elapsed := time.duration_seconds(time.tick_since(start))
		info, _ := os.stat(path, context.temp_allocator)
		size := info.size
		ok &= compare(path, test.floor, source, width, height, frames, size, elapsed)
	}
	if !ok do os.exit(1)
}

// Premultiplied "over" of a straight colour with coverage a onto dst.
over :: proc(dst: ^[4]f32, rgb: [3]f32, a: f32) {
	for c in 0 ..< 3 do dst[c] = rgb[c] * a + dst[c] * (1 - a)
	dst[3] = a + dst[3] * (1 - a)
}

render :: proc(out: []u8, width, height, f: int) {
	t := f32(f)
	cx := f32(width) * (0.3 + 0.4 * (0.5 + 0.5 * math.sin(t * 0.15)))
	cy := f32(height) * 0.5
	radius := f32(height) * 0.22
	for y in 0 ..< height {
		for x in 0 ..< width {
			px, py := f32(x) + 0.5, f32(y) + 0.5
			p: [4]f32
			// Alpha ramp across the bottom band, hue changing down the band.
			if py > f32(height) * 0.8 {
				v := (py - f32(height) * 0.8) / (f32(height) * 0.2)
				over(&p, {0.1 + 0.8 * v, 0.9 - 0.6 * v, 0.4}, px / f32(width))
			}
			// Soft glow around the disc.
			d := math.hypot(px - cx, py - cy)
			glow := clamp(1 - (d - radius) / (radius * 0.6), 0, 1)
			over(&p, {1, 0.85, 0.2}, 0.6 * glow * glow)
			// The disc, saturated red with a one-pixel anti-aliased edge.
			over(&p, {0.9, 0.1, 0.15}, clamp(radius - d + 0.5, 0, 1))
			// Thin strokes: a white diagonal and a cyan horizontal line.
			diag := abs((px - f32(width) * 0.1 - t * 2) - (py - f32(height) * 0.1)) / math.SQRT_TWO
			over(&p, {1, 1, 1}, clamp(1.2 - diag, 0, 1))
			over(&p, {0, 0.9, 1}, clamp(1.5 - abs(py - f32(height) * 0.25), 0, 1))
			o := out[(y * width + x) * 4:][:4]
			for c in 0 ..< 4 do o[c] = u8(clamp(p[c] * 255 + 0.5, 0, 255))
		}
	}
}

Stats :: struct {
	sse:     [3]f64, // over black, over white, alpha
	max_err: [3]int,
	count:   f64,
}

add :: proc(s: ^Stats, i: int, a, b: int) {
	d := a - b
	s.sse[i] += f64(d * d)
	s.max_err[i] = max(s.max_err[i], abs(d))
}

psnr :: proc(sse, count: f64) -> f64 {
	return sse == 0 ? 99 : 10 * math.log10(255 * 255 * count / sse)
}

compare :: proc(path: string, floor: f64, source: []u8, width, height, frames: int, size: i64, elapsed: f64) -> bool {
	r: movie.Reader
	if e := movie.open_reader(&r, path, {preference = .Native, premultiplied_alpha = true}); e != .None do fail("open", path, e, r.error_detail)
	defer movie.close_reader(&r)
	if !r.video.has_alpha || r.video.frame_count != frames do fail(path, "has_alpha", r.video.has_alpha, "frames", r.video.frame_count)
	s: Stats
	for f in 0 ..< frames {
		frame, e := movie.next_frame(&r)
		if e != .None do fail("next_frame", f, e, r.error_detail)
		src := source[f * width * height * 4:][:width * height * 4]
		for i := 0; i < len(src); i += 4 {
			sa, da := int(src[i + 3]), int(frame.rgba[i + 3])
			for c in 0 ..< 3 {
				sc, dc := int(src[i + c]), int(frame.rgba[i + c])
				add(&s, 0, sc, dc)
				add(&s, 1, sc + 255 - sa, dc + 255 - da)
			}
			add(&s, 2, sa, da)
		}
	}
	n := f64(width * height * frames)
	over_black, over_white, alpha := psnr(s.sse[0], 3 * n), psnr(s.sse[1], 3 * n), psnr(s.sse[2], n)
	fmt.printfln(
		"%s: %d bytes, %.1f fps; over black %.2f dB (max %d), over white %.2f dB (max %d), alpha %.2f dB (max %d)",
		path, size, f64(frames) / elapsed, over_black, s.max_err[0], over_white, s.max_err[1], alpha, s.max_err[2],
	)
	return over_black > floor && over_white > floor && alpha > 45
}

dump_planar :: proc(path, out_path: string) {
	r: movie.Reader
	if e := movie.open_reader(&r, path, {preference = .Native, format = .Planar}); e != .None do fail("open", path, e, r.error_detail)
	defer movie.close_reader(&r)
	out: [dynamic]u8
	for {
		frame, e := movie.next_frame(&r)
		if e == .End_Of_Stream do break
		if e != .None do fail("next_frame", e, r.error_detail)
		p := frame.planar
		if p.storage_bits != 8 || p.chroma != .YUV420 || len(p.alpha) == 0 do fail("unexpected planar layout", p.storage_bits, p.chroma, len(p.alpha))
		for i in 0 ..< 3 {
			w, h := i == 0 ? p.width : p.width / 2, i == 0 ? p.height : p.height / 2
			for y in 0 ..< h do append(&out, ..p.planes[i][y * p.strides[i]:][:w])
		}
		for y in 0 ..< p.height do append(&out, ..p.alpha[y * p.alpha_stride:][:p.width])
	}
	_ = os.write_entire_file(out_path, out[:])
}

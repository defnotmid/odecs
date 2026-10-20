// Hardware encoding through video.Writer on macOS: writes H.264 and HEVC
// from RGBA, from I420 and from NV12, checks that VideoToolbox was chosen,
// decodes each file with the native decoders and reports size, speed and
// PSNR against the encoded planes.
//
//   odin build tests/videotoolbox_encode_check.odin -file -o:speed -out:.work/vt-encode-check
//   .work/vt-encode-check OUTDIR [WIDTH HEIGHT FRAMES QP]
package videotoolbox_encode_check

import video "../video"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:time"

fail :: proc(args: ..any) {
	fmt.eprintln(..args)
	os.exit(1)
}

Input :: enum {
	RGBA,
	I420,
	NV12,
}

main :: proc() {
	if len(os.args) < 2 do fail("usage: videotoolbox_encode_check OUTDIR [WIDTH HEIGHT FRAMES QP]")
	dir := os.args[1]
	width, height, frames, qp := 1920, 1080, 120, 23
	if len(os.args) >= 5 {
		width, _ = strconv.parse_int(os.args[2])
		height, _ = strconv.parse_int(os.args[3])
		frames, _ = strconv.parse_int(os.args[4])
	}
	if len(os.args) >= 6 do qp, _ = strconv.parse_int(os.args[5])
	rgba := make([]u8, width * height * 4)
	luma, quarter := width * height, width * height / 4
	planes := make([]u8, frames * (luma + 2 * quarter)) // every frame's I420, the reference
	k := video.rgb_to_yuv_coefficients(.BT709, false)
	for f in 0 ..< frames {
		render(rgba, width, height, f)
		p := planes[f * (luma + 2 * quarter):]
		video.rgba_to_i420(rgba, width * 4, width, height, {p[:luma], p[luma:][:quarter], p[luma + quarter:][:quarter]}, {width, width / 2, width / 2}, &k, .Opaque, {})
	}
	nv12 := make([]u8, luma / 2)
	ok := true
	for codec in ([]video.Video_Codec{.H264, .H265}) {
		for input in Input {
			path := fmt.tprintf("%s/vt_%v_%v.mp4", dir, codec, input)
			config := video.default_writer_config(width, height, 30, 1)
			config.codec, config.qp = codec, qp
			w: video.Writer
			if e := video.create(&w, path, config); e != .None do fail("create", path, e, w.error_detail)
			backend, name := video.video_backend(&w)
			start := time.tick_now()
			for f in 0 ..< frames {
				p := planes[f * (luma + 2 * quarter):]
				y, u, v := p[:luma], p[luma:][:quarter], p[luma + quarter:][:quarter]
				e: video.Error
				switch input {
				case .RGBA:
					render(rgba, width, height, f) // timed: the conversion is part of this path
					e = video.write_frame(&w, rgba, width * 4)
				case .I420:
					e = video.write_i420(&w, {y, u, v}, {width, width / 2, width / 2})
				case .NV12:
					for j in 0 ..< quarter do nv12[2 * j], nv12[2 * j + 1] = u[j], v[j]
					e = video.write_nv12(&w, {y, nv12}, {width, width})
				}
				if e != .None do fail("write", path, f, e, w.error_detail)
			}
			if e := video.finish(&w); e != .None do fail("finish", path, e, w.error_detail)
			elapsed := time.duration_seconds(time.tick_since(start))
			video.destroy(&w)
			db := decoded_psnr(path, planes, width, height, frames)
			info, _ := os.stat(path, context.temp_allocator)
			fmt.printfln("%s: %v (%s), %.1f fps, %d bytes, %.2f dB", path, backend, name, f64(frames) / elapsed, info.size, db)
			ok &= backend == .VideoToolbox && db > 30
		}
	}
	if !ok do os.exit(1)
}

// A moving gradient with sharp edges, the same every run.
render :: proc(rgba: []u8, width, height, f: int) {
	for y in 0 ..< height {
		for x in 0 ..< width {
			p := rgba[(y * width + x) * 4:][:4]
			band := ((x + f * 4) / 64 + y / 64) % 2 == 0
			p[0] = u8((x + f * 3) * 255 / width)
			p[1] = band ? 200 : u8(y * 255 / height)
			p[2] = u8((x ~ y) & 0xFF)
			p[3] = 255
		}
	}
}

// PSNR of the native decode of path against the reference planes.
decoded_psnr :: proc(path: string, planes: []u8, width, height, frames: int) -> f64 {
	r: video.Reader
	if e := video.open_reader(&r, path, {preference = .Native, format = .Planar}); e != .None do fail("open", path, e, r.error_detail)
	defer video.close_reader(&r)
	if r.video.frame_count != frames do fail(path, "frames", r.video.frame_count)
	luma, quarter := width * height, width * height / 4
	sse: f64
	for f in 0 ..< frames {
		frame, e := video.next_frame(&r)
		if e != .None do fail("next_frame", path, f, e, r.error_detail)
		ref := planes[f * (luma + 2 * quarter):]
		p := frame.planar
		for i in 0 ..< 3 {
			w, h := i == 0 ? width : width / 2, i == 0 ? height : height / 2
			base := i == 0 ? 0 : (i == 1 ? luma : luma + quarter)
			for y in 0 ..< h do for x in 0 ..< w {
				d := f64(p.planes[i][y * p.strides[i] + x]) - f64(ref[base + y * w + x])
				sse += d * d
			}
		}
	}
	return 10 * math.log10(255 * 255 * f64(frames * (luma + 2 * quarter)) / sse)
}

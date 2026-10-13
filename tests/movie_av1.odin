// Reads an AV1 movie (MP4 or Matroska) through movie.Reader with planar
// output and writes every frame's planes as raw YUV (bytes at 8 bits,
// little-endian u16 above), for tests/av1_check.sh to compare with FFmpeg's
// libdav1d. Also reports the description and the time per frame.
//
//   movie_av1 FILE OUT.yuv [native]
package main

import movie "../codec/movie"
import "core:fmt"
import "core:os"
import "core:time"

main :: proc() {
	if len(os.args) < 3 {fmt.eprintln("usage: movie_av1 FILE OUT.yuv"); os.exit(2)}
	r: movie.Reader
	config := movie.Reader_Config {
		format = .Planar,
	}
	if len(os.args) > 3 && os.args[3] == "native" do config.preference = .Native
	start := time.now()
	if e := movie.open_reader(&r, os.args[1], config); e != .None {fmt.eprintln("open", e, r.error_detail); os.exit(1)}
	defer movie.close_reader(&r)
	out, oerr := os.create(os.args[2])
	if oerr != nil do os.exit(1)
	defer os.close(out)
	frames := 0
	p: movie.Planar
	for {
		f, e := movie.next_frame(&r)
		if e == .End_Of_Stream do break
		if e != .None {fmt.eprintln("frame", frames, e, r.error_detail); os.exit(1)}
		p = f.planar
		for plane, i in p.planes {
			if len(plane) == 0 do continue
			rows := i == 0 ? p.height : (p.height + 1) / 2
			for y in 0 ..< rows {
				row := plane[y * p.strides[i]:][:p.strides[i]]
				os.write(out, row)
			}
		}
		frames += 1
	}
	ms := time.duration_milliseconds(time.since(start))
	fmt.printfln("%d frames %dx%d %v %d-bit colour %v, %.2f ms/frame", frames, p.width, p.height, p.chroma, p.bit_depth, p.color, ms / f64(max(frames, 1)))
	if frames == 0 do os.exit(1)
}

// Checks Reader_Config.format = .Planar against the default RGBA output:
// every frame's planes, converted by planar_to_rgba (the reference for a
// shader), must equal the RGBA the reader produces itself, byte for byte.
// Also reports the planar layout and the bytes per pixel saved.
//
//   /tmp/movie_planar FILE [hardware]
package movie_planar

import video "../video"
import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) < 2 {fmt.eprintln("usage: movie_planar FILE [hardware]"); os.exit(2)}
	preference: video.Reader_Config
	preference.preference = len(os.args) > 2 && os.args[2] == "hardware" ? .Automatic : .Native
	rgba_reader, planar_reader: video.Reader
	planar_config := preference
	planar_config.format = .Planar
	if e := video.open_reader(&rgba_reader, os.args[1], preference); e != .None {fmt.eprintln("open", e, rgba_reader.error_detail); os.exit(1)}
	if e := video.open_reader(&planar_reader, os.args[1], planar_config); e != .None {fmt.eprintln("open", e); os.exit(1)}
	defer video.close_reader(&rgba_reader)
	defer video.close_reader(&planar_reader)
	scratch: [dynamic]u8
	frames, mismatched := 0, 0
	layout: video.Planar
	for {
		a, ea := video.next_frame(&rgba_reader)
		b, eb := video.next_frame(&planar_reader)
		if ea != eb {fmt.eprintln("frame", frames, ea, "vs", eb); os.exit(1)}
		if ea != .None {
			if ea != .End_Of_Stream {fmt.eprintln("frame", frames, ea, rgba_reader.error_detail, planar_reader.error_detail); os.exit(1)}
			break
		}
		if len(b.rgba) != 0 || len(b.planar.planes[0]) == 0 {fmt.eprintln("planar frame without planes"); os.exit(1)}
		resize(&scratch, a.width * a.height * 4)
		video.planar_to_rgba(b.planar, scratch[:])
		if string(scratch[:]) != string(a.rgba) do mismatched += 1
		layout = b.planar
		frames += 1
	}
	bytes := len(layout.planes[0]) + len(layout.planes[1]) + len(layout.planes[2]) + len(layout.alpha)
	fmt.printfln("%s: %d frames, %d differ; %dx%d %v %d-bit in %d-bit storage, alpha %v, colour %v; %.2f bytes/pixel planar vs 4 RGBA", os.args[1], frames, mismatched, layout.width, layout.height, layout.chroma, layout.bit_depth, layout.storage_bits, len(layout.alpha) > 0, layout.color, f64(bytes) / f64(layout.width * layout.height))
	if mismatched != 0 || frames == 0 do os.exit(1)
}

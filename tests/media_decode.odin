// Decode through the common API and optionally save visible raw YUV.
package main

import media "../media"
import native "../media/native"
import vulkan "../media/vulkan"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

Sink :: struct {
	frames:       int,
	write_pixels: bool,
	pixels:       [dynamic]u8,
}
receive :: proc(frame: media.Video_Frame, user: rawptr) {
	s := (^Sink)(user)
	if media.validate_frame(frame) != .None do os.exit(1)
	s.frames += 1
	if !s.write_pixels do return
	if frame.storage !=
	   .Host {fmt.eprintln("device frames cannot be saved as CPU YUV"); os.exit(1)}
	sw, sh := media.chroma_subsampling(frame.chroma)
	for i in 0 ..< 3 {
		if i > 0 && frame.chroma == .Monochrome do break
		w := i == 0 ? frame.width : frame.width / sw
		h := i == 0 ? frame.height : frame.height / sh
		p := frame.planes[i]
		for row in 0 ..< h {
			data := p.data[row * p.stride:]
			if frame.bit_depth > 8 || frame.storage_bits == 8 {
				append(&s.pixels, ..data[:w * (frame.storage_bits / 8)])
			} else {
				for col in 0 ..< w do append(&s.pixels, data[col * 2])
			}
		}
	}
}
integer :: proc(s: string) -> int {v, ok := strconv.parse_int(s); if !ok do os.exit(2); return v}
check :: proc(err: media.Error) {if err != .None {fmt.eprintln(err); os.exit(1)}}

main :: proc() {
	if len(os.args) < 7 {
		fmt.eprintln(
			"usage: media_decode input.264|265 h264|h265 width height bit_depth native|hardware|auto|device [output.yuv]",
		)
		os.exit(2)
	}
	config := media.default_config(.H265, .Decode)
	if os.args[2] == "h264" {config.codec = .H264} else if os.args[2] != "h265" do os.exit(2)
	config.width, config.height, config.bit_depth =
		integer(os.args[3]), integer(os.args[4]), integer(os.args[5])
	switch os.args[6] {
	case "native":
		config.preference = .Native
	case "hardware":
		config.preference = .Require_Hardware
	case "auto":
	case "device":
		config.preference = .Require_Hardware; config.output_storage = .Device
	case:
		os.exit(2)
	}
	data, err := os.read_entire_file(
		os.args[1],
		context.allocator,
	); if err != nil {fmt.eprintln(err); os.exit(1)}
	defer delete(data)
	session: media.Session
	check(media.open(&session, config, []media.Provider{native.provider(), vulkan.provider()}))
	defer media.close(&session)
	fmt.printfln(
		"selected=%s hardware_admission=%v",
		session.provider_name,
		session.hardware_error,
	)
	sink := Sink {
		write_pixels = len(os.args) > 7,
	}
	defer delete(sink.pixels)
	start := time.tick_now()
	check(
		media.decode(&session, {data = data, framing = .Annex_B}, {video = receive, user = &sink}),
	)
	check(media.drain(&session, {video = receive, user = &sink}))
	seconds := time.duration_seconds(time.tick_since(start))
	if sink.frames == 0 {fmt.eprintln("no output frames"); os.exit(1)}
	fmt.printfln(
		"frames=%d seconds=%.6f fps=%.3f output_bytes=%d",
		sink.frames,
		seconds,
		f64(sink.frames) / seconds,
		len(sink.pixels),
	)
	if sink.write_pixels && os.write_entire_file(os.args[7], sink.pixels[:]) != nil do os.exit(1)
}

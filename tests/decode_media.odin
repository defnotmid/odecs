package main

import media "../media"
import avcodec "../media/avcodec"
import mediafoundation "../media/mediafoundation"
import native "../media/native"
import videotoolbox "../media/videotoolbox"
import vulkan "../media/vulkan"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// decode_media h264|h265 <in.annexb> <out.yuv|-> [hardware|native|system] [WxH] [depth=N]
//
// Decodes an Annex B stream through media, one NAL unit per packet,
// with VideoToolbox or Vulkan Video (where available), the native decoder,
// or (system) the system codecs alone (Media Foundation, libavcodec), and
// writes the visible 4:2:0 frames in display order: yuv420p, or yuv420p10le
// above 8 bits ("-" only counts them, to time decoding alone).
// WxH and depth=N (8 by default) describe the stream as a container would;
// Vulkan Video admits a stream only with them.
main :: proc() {
	if len(os.args) < 4 {
		fmt.eprintln("usage: decode_media h264|h265 <in.annexb> <out.yuv|-> [hardware|native|system] [WxH] [depth=N]")
		os.exit(2)
	}
	config := media.default_config(os.args[1] == "h265" ? .H265 : .H264, .Decode)
	system := false
	for arg in os.args[4:] {
		switch {
		case arg == "native":
			config.preference = .Native
		case arg == "hardware":
			config.preference = .Require_Hardware
		case arg == "system":
			system = true
		case strings.has_prefix(arg, "depth="):
			config.bit_depth, _ = strconv.parse_int(arg[len("depth="):])
		case strings.contains(arg, "x"):
			w, _, h := strings.partition(arg, "x")
			config.width, _ = strconv.parse_int(w)
			config.height, _ = strconv.parse_int(h)
		}
	}
	data, err := os.read_entire_file(os.args[2], context.allocator)
	if err != nil {fmt.eprintln("cannot read", os.args[2]); os.exit(1)}

	Output :: struct {
		file:   ^os.File,
		row:    [dynamic]u8,
		frames: int,
	}
	out: Output
	if os.args[3] != "-" {
		file, open_err := os.create(os.args[3])
		if open_err != nil {fmt.eprintln("cannot write", os.args[3]); os.exit(1)}
		out.file = file
	}
	defer if out.file != nil do os.close(out.file)
	on_frame :: proc(frame: media.Video_Frame, user: rawptr) {
		out := (^Output)(user)
		out.frames += 1
		if out.file == nil do return
		b := frame.storage_bits / 8
		clear(&out.row)
		for i in 0 ..< 3 {
			w, h := frame.width, frame.height
			if i > 0 do w, h = (w + 1) / 2, (h + 1) / 2
			for row in 0 ..< h do append(&out.row, ..frame.planes[i].data[row * frame.planes[i].stride:][:w * b])
		}
		if _, e := os.write(out.file, out.row[:]); e != nil {fmt.eprintln("cannot write output"); os.exit(1)}
	}
	receiver := media.Receiver {
		video = on_frame,
		user  = &out,
	}

	session: media.Session
	providers := []media.Provider{videotoolbox.provider(), vulkan.provider(), native.provider()}
	if system do providers = []media.Provider{mediafoundation.provider(), avcodec.provider()}
	if e := media.open(&session, config, providers); e != .None {fmt.eprintln("open:", e); os.exit(1)}
	defer media.close(&session)
	start := time.tick_now()
	it := media.Nal_Iterator {
		packet = {data = data, framing = .Annex_B},
	}
	for {
		nal, done, e := media.next_nal(&it)
		if e != .None {fmt.eprintln("framing:", e); os.exit(1)}
		if done do break
		if de := media.decode(&session, {data = nal, framing = .NAL}, receiver); de != .None {
			fmt.eprintln("decode:", de, session.error_detail)
			os.exit(1)
		}
	}
	if e := media.drain(&session, receiver); e != .None {fmt.eprintln("drain:", e, session.error_detail); os.exit(1)}
	elapsed := time.duration_milliseconds(time.tick_since(start))
	fmt.printfln("%s: %d frames in %.1f ms (%.1f fps)", session.provider_name, out.frames, elapsed, f64(out.frames) / elapsed * 1000)
}

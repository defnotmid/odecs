package main

import common "../common"
import avc_enc "../h264/encoder"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

// encode_clip <in.yuv> <width> <height> <frames> <out.264> [--qp N] [--refs N] [--bitrate kbps] [--no-deblock] [--threads] [--gop N]
main :: proc() {
	if len(os.args) < 6 {
		fmt.println(
			"usage: encode_clip <in.yuv> <width> <height> <frames> <out.264> [--qp N] [--refs N] [--bitrate kbps] [--no-deblock] [--workers N|--threads] [--slices N] [--gop N] [--exhaustive]",
		)
		os.exit(2)
	}
	integer :: proc(value: string) -> int {n, ok := strconv.parse_int(value); if !ok {fmt.eprintln(
				"invalid integer:",
				value,
			)
			os.exit(2)}
		return n}
	width := integer(os.args[2])
	height := integer(os.args[3])
	frames := integer(os.args[4])
	if width <= 0 ||
	   height <= 0 ||
	   width > 16384 ||
	   height > 16384 ||
	   (width | height) & 1 != 0 ||
	   frames <=
		   0 {fmt.eprintln("positive even dimensions <= 16384 and a positive frame count required"); os.exit(2)}
	config := avc_enc.Encoder_Config {
		width          = width,
		height         = height,
		qp             = 26,
		gop_size       = 15,
		num_ref_frames = 1,
	}
	use_threads, verbose := false, false
	workers := clamp(os.get_processor_core_count(), 1, common.MAX_STATIC_POOL_THREADS + 1)
	for i := 6; i < len(os.args); i += 1 {
		next :: proc(i: ^int) -> int {i^ += 1; if i^ >= len(os.args) {fmt.eprintln(
					"missing option value",
				)
				os.exit(2)}
			return integer(os.args[i^])}
		switch os.args[i] {
		case "--qp":
			config.qp = i32(next(&i))
		case "--refs":
			config.num_ref_frames = next(&i)
		case "--bitrate":
			config.bitrate_kbps = next(&i)
		case "--gop":
			config.gop_size = next(&i)
		case "--no-deblock":
			config.disable_deblocking = true
		case "--threads":
			use_threads = true
		case "--workers":
			workers = next(&i); use_threads = workers > 1
		case "--slices":
			config.slice_count = next(&i)
		case "--exhaustive":
			config.exhaustive_intra = true
		case "--verbose":
			verbose = true
		case:
			fmt.eprintln("unknown option:", os.args[i]); os.exit(2)
		}
	}
	if config.qp < 0 ||
	   config.qp > 51 ||
	   config.gop_size <= 0 ||
	   config.num_ref_frames < 1 ||
	   config.num_ref_frames > 4 ||
	   config.bitrate_kbps < 0 ||
	   config.slice_count < 0 ||
	   workers < 1 ||
	   workers >
		   common.MAX_STATIC_POOL_THREADS +
			   1 {fmt.eprintln("invalid encoder configuration"); os.exit(2)}
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {
		fmt.println("cannot read", os.args[1])
		os.exit(1)
	}
	defer delete(data)
	frame_size := width * height * 3 / 2
	if len(data) % frame_size != 0 ||
	   frames >
		   len(data) /
			   frame_size {fmt.eprintln("input does not contain the requested complete frames"); os.exit(1)}
	pool: common.Static_Pool
	if use_threads do common.init_static_pool(&pool, workers - 1)
	defer if use_threads do common.destroy_static_pool(&pool)
	encoder: avc_enc.Encoder_State
	avc_enc.init_encoder(&encoder, config)
	defer avc_enc.destroy_encoder(&encoder)
	out := make([dynamic]u8, 0, 4 * 1024 * 1024)
	start := time.now()
	for f in 0 ..< frames {
		src := data[f * frame_size:]
		before := len(out)
		if err := avc_enc.encode_frame(
			&encoder,
			&src[0],
			&src[width * height],
			&src[width * height + width * height / 4],
			width,
			width / 2,
			f % config.gop_size == 0,
			&out,
			use_threads ? &pool.work_pool : nil,
		); err != .None {fmt.eprintln(err); os.exit(1)}
		if verbose do fmt.printfln("frame %d: %d bytes, next qp %v", f, len(out) - before, encoder.rate.qp)
	}
	elapsed := time.since(start)
	if write_err := os.write_entire_file(os.args[5], out[:]);
	   write_err != nil {fmt.eprintln("cannot write output:", write_err); os.exit(1)}
	fmt.printfln(
		"%d frames, %d bytes, %.1f ms (%.1f fps)",
		frames,
		len(out),
		time.duration_milliseconds(elapsed),
		f64(frames) / time.duration_seconds(elapsed),
	)
}

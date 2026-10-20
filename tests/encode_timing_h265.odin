package main

import common "../common"
import h265 "../video/h265/encoder"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"
import benchmark_support "support"

// Resident input, fresh encoder per round, initialization reported separately.
// Codec time includes output accumulation and flush, but no output-file I/O.
// Usage: encode_timing_h265 <in.yuv> <width> <height> <frames> [--qp N]
//        [--intra-only] [--i-slice] [--no-deblock] [--no-sao] [--out stream.265]
//        [--workers N] [--tiles CxR] [--wpp]
main :: proc() {
	if len(os.args) < 5 {
		fmt.eprintln(
			"usage: encode_timing_h265 <in.yuv> <width> <height> <frames> [--qp N] [--intra-only] [--i-slice] [--no-deblock] [--no-sao] [--workers N] [--tiles CxR] [--wpp]",
		)
		os.exit(2)
	}
	integer :: proc(value: string) -> int {
		n, ok := strconv.parse_int(value)
		if !ok {fmt.eprintln("invalid integer:", value); os.exit(2)}
		return n
	}
	next_value :: proc(index: ^int, option: string) -> string {
		index^ += 1
		if index^ >= len(os.args) {fmt.eprintln(option, "requires a value"); os.exit(2)}
		return os.args[index^]
	}
	width := integer(os.args[2])
	height := integer(os.args[3])
	frames := integer(os.args[4])
	if width <= 0 ||
	   height <= 0 ||
	   width > 8192 ||
	   height > 8192 ||
	   width % 2 != 0 ||
	   height % 2 != 0 ||
	   frames <= 0 {
		fmt.eprintln("positive even dimensions and a positive frame count required")
		os.exit(2)
	}

	output_path := ""
	workers := 1
	config := h265.Config {
		width       = width,
		height      = height,
		qp          = 26,
		level_idc   = 120,
		forced_mode = -1,
		deblock     = true,
		sao         = true,
	}
	for i := 5; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--out":
			output_path = next_value(&i, os.args[i])
		case "--qp":
			config.qp = i32(integer(next_value(&i, os.args[i])))
		case "--bitdepth":
			config.bit_depth = integer(next_value(&i, os.args[i]))
		case "--intra-only":
			config.intra_only = true
		case "--i-slice":
			config.intra_only_i_slices = true
		case "--no-deblock":
			config.deblock = false
		case "--no-sao":
			config.sao = false
		case "--b-frames":
			config.b_frames = true
		case "--rqt":
			config.rqt = true
		case "--intra-rqt":
			config.intra_rqt = true
		case "--tskip":
			config.tskip = true
		case "--rdpcm":
			config.rdpcm = true
		case "--pcm":
			config.pcm = true
		case "--amp":
			config.amp = true
		case "--wp":
			config.weighted = true
		case "--tmvp":
			config.tmvp = true
		case "--no-tmvp":
			config.tmvp = false
		case "--wpp":
			config.wpp = true
		case "--no-wpp":
			config.wpp = false
		case "--workers":
			workers = integer(next_value(&i, os.args[i]))
			if workers < 1 || workers > 33 {
				fmt.eprintln("--workers must be between 1 and 33 (including the caller)")
				os.exit(2)
			}
		case "--tiles":
			grid := next_value(&i, os.args[i])
			delim := -1
			for j in 0 ..< len(grid) {
				if grid[j] == 'x' {delim = j; break}
			}
			if delim <= 0 || delim + 1 >= len(grid) {
				fmt.eprintln("invalid tile grid:", grid)
				os.exit(2)
			}
			config.tiles_cols = integer(grid[:delim])
			config.tiles_rows = integer(grid[delim + 1:])
			if config.tiles_cols <= 0 || config.tiles_rows <= 0 {
				fmt.eprintln("tile columns and rows must be positive")
				os.exit(2)
			}
		case "--hierarchical":
			config.hierarchical = true
		case "--gop":
			config.gop_size = integer(next_value(&i, os.args[i]))
		case "--refs":
			config.refs = integer(next_value(&i, os.args[i]))
		case:
			fmt.eprintln("unknown option:", os.args[i])
			os.exit(2)
		}
	}
	if config.bit_depth != 0 && config.bit_depth != 8 && config.bit_depth != 10 {
		fmt.eprintln("--bitdepth must be 0 (default 8), 8, or 10")
		os.exit(2)
	}

	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {fmt.eprintln("cannot read", os.args[1]); os.exit(1)}
	defer delete(data)
	frame_size := width * height * 3 / 2
	bytes_per_sample := config.bit_depth > 8 ? 2 : 1
	if len(data) % (frame_size * bytes_per_sample) != 0 ||
	   frames > len(data) / (frame_size * bytes_per_sample) {
		fmt.eprintln("input does not contain the requested complete frames")
		os.exit(1)
	}

	// The codec core works on 16-bit sample planes; widen or unpack the whole
	// input once, outside the timer.
	pixels := make([]h265.Sample, frames * frame_size)
	defer delete(pixels)
	if bytes_per_sample == 2 {
		for i in 0 ..< frames * frame_size {
			pixels[i] = h265.Sample(data[2 * i]) | h265.Sample(data[2 * i + 1]) << 8
		}
	} else {
		for i in 0 ..< frames * frame_size do pixels[i] = h265.Sample(data[i])
	}

	out := make([dynamic]u8, 0, 4 * 1024 * 1024)
	defer delete(out)

	// Borrow one persistent caller-owned pool across all seven fresh encoders.
	// Pool construction and shutdown are outside both reported timers.
	pool: common.Static_Pool
	pool_on := workers > 1
	if pool_on {
		common.init_static_pool(&pool, workers - 1)
		config.pool = &pool.work_pool
	}
	defer if pool_on do common.destroy_static_pool(&pool)
	if err := benchmark_support.pin_video_cpus(config.pool, workers); err != .None {
		fmt.eprintln(benchmark_support.pin_error_description(err)); os.exit(2)
	}

	times, init_times: [7]f64
	baseline: []u8
	defer delete(baseline)
	actual_tile_cols, actual_tile_rows := 1, 1
	search_worker_capacity := 1
	actual_wpp := false

	for r in 0 ..< len(times) {
		clear(&out)
		t := time.tick_now()

		enc: h265.Encoder
		h265.init_encoder(&enc, config)
		init_times[r] = time.duration_milliseconds(time.tick_since(t))
		actual_tile_cols, actual_tile_rows = 1, 1
		search_worker_capacity = 1
		if enc.tiles_on {
			actual_tile_cols = enc.config.tiles_cols
			actual_tile_rows = enc.config.tiles_rows
			search_worker_capacity = min(actual_tile_cols * actual_tile_rows, workers)
		}
		// WPP changes CABAC row substreams; only tile search uses this pool.
		actual_wpp = enc.config.wpp
		t = time.tick_now()
		for f in 0 ..< frames {
			src := pixels[f * frame_size:]
			h265.encode_frame(
				&enc,
				&src[0],
				&src[width * height],
				&src[width * height + width * height / 4],
				width,
				width / 2,
				&out,
			)
		}
		h265.flush_encoder(&enc, &out)
		times[r] = time.duration_milliseconds(time.tick_since(t))

		h265.destroy_encoder(&enc)
		if r == 0 {
			baseline = slice.clone(out[:])
		} else if !slice.equal(baseline, out[:]) {
			fmt.eprintln("nondeterministic encoder output"); os.exit(1)
		}
		if len(out) == 0 {fmt.eprintln("encode produced no output"); os.exit(1)}
	}

	if output_path != "" && os.write_entire_file(output_path, out[:]) != nil do os.exit(1)
	slice.sort(times[:])
	slice.sort(init_times[:])
	fmt.printfln(
		"oicu h265 encode: frames=%d bytes=%d init_ms=%.3f codec_ms=%.3f fps=%.1f min_ms=%.3f max_ms=%.3f requested_workers=%d pool_threads=%d search_worker_capacity=%d tiles=%dx%d wpp=%v",
		frames,
		len(out),
		init_times[3],
		times[3],
		f64(frames) * 1000 / times[3],
		times[0],
		times[6],
		workers,
		pool.n_threads,
		search_worker_capacity,
		actual_tile_cols,
		actual_tile_rows,
		actual_wpp,
	)
}

package main

import common "../codec/common"
import h265 "../codec/h265/encoder"
import "core:fmt"
import "core:os"
import "core:strconv"

// encode_h265 <in.yuv> <width> <height> <frames> <out.265> [--qp N] [--rec out.yuv]
main :: proc() {
	if len(os.args) < 6 {
		fmt.println(
			"usage: encode_h265 <in.yuv> <width> <height> <frames> <out.265> [--qp N] [--bitdepth N] [--rec out.yuv] [--no-deblock] [--no-sao] [--b-frames] [--wp] [--tmvp] [--wpp] [--tiles CxR] [--threads N] [--vui] [--fps N] [--level N] [--sei-hash] [--sei-recovery] [--rc qp|abr|cbr|crf] [--bitrate N] [--crf F] [--rc-buffer N] [--hrd] [--sei-mastering] [--mono|--422|--444] [--hierarchical] [--gop N] [--idr-period N] [--intra-rqt] [--tskip] [--rdpcm] [--pcm] [--scaling-list off|default|flat]",
		)
		os.exit(2)
	}
	integer :: proc(value: string) -> int {
		n, ok := strconv.parse_int(value)
		if !ok {
			fmt.eprintln("invalid integer:", value)
			os.exit(2)
		}
		return n
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
	config := h265.Config {
		width       = width,
		height      = height,
		qp          = 26,
		forced_mode = -1,
		deblock     = true,
		sao         = true,
	}
	rec_path: string
	dump_cu := false
	threads := 0
	for i := 6; i < len(os.args); i += 1 {
		switch os.args[i] {
		case "--qp":
			i += 1
			config.qp = i32(integer(os.args[i]))
		case "--bitdepth":
			i += 1
			config.bit_depth = integer(os.args[i])
		case "--rec":
			i += 1
			rec_path = os.args[i]
		case "--intra-only":
			config.intra_only = true
		case "--mode":
			i += 1
			config.forced_mode = i32(integer(os.args[i]))
		case "--i-slice":
			config.intra_only_i_slices = true
		case "--no-deblock":
			config.deblock = false
		case "--no-sao":
			config.sao = false
		case "--b-frames":
			config.b_frames = true
		case "--no-b-frames":
			config.b_frames = false
		case "--rqt":
			config.rqt = true
		case "--no-rqt":
			config.rqt = false
		case "--intra-rqt":
			config.intra_rqt = true
		case "--no-intra-rqt":
			config.intra_rqt = false
		case "--tskip":
			config.tskip = true
		case "--no-tskip":
			config.tskip = false
		case "--rdpcm":
			config.rdpcm = true
		case "--no-rdpcm":
			config.rdpcm = false
		case "--pcm":
			config.pcm = true
		case "--tiles":
			i += 1
			// A CxR tile grid, e.g. --tiles 2x2. Tiles and wavefronts are
			// mutually exclusive for 4:2:0; tiles win.
			grid := os.args[i]
			delim := -1
			for j in 0 ..< len(grid) {
				if grid[j] == 'x' {
					delim = j
					break
				}
			}
			if delim <= 0 || delim + 1 >= len(grid) {
				fmt.eprintln("invalid tile grid:", grid)
				os.exit(2)
			}
			config.tiles_cols = integer(grid[:delim])
			config.tiles_rows = integer(grid[delim + 1:])
			config.wpp = false
		case "--threads":
			i += 1
			threads = integer(os.args[i])
		case "--vui":
			config.vui = true
		case "--fps":
			i += 1
			config.fps_num = integer(os.args[i])
			config.fps_den = 1
		case "--level":
			i += 1
			config.level_idc = u8(integer(os.args[i]))
		case "--sei-hash":
			config.sei_hash = true
		case "--sei-recovery":
			config.sei_recovery = true
		case "--rc":
			i += 1
			if os.args[i] == "abr" {
				config.rc = .ABR
			} else if os.args[i] == "cbr" {
				config.rc = .CBR
			} else if os.args[i] == "crf" {
				config.rc = .CRF
			} else if os.args[i] != "qp" {
				fmt.eprintln("unknown rate control mode:", os.args[i])
				os.exit(2)
			}
		case "--bitrate":
			i += 1
			config.bitrate = integer(os.args[i])
		case "--rc-buffer":
			i += 1
			config.rc_buffer = integer(os.args[i])
		case "--hrd":
			config.hrd = true
		case "--mono":
			config.chroma_format = .Monochrome
		case "--444":
			config.chroma_format = .YUV_444
		case "--422":
			config.chroma_format = .YUV_422
		case "--sei-mastering":
			config.sei_mastering = true
			// sRGB-ish display: Rec.709 primaries and D65 white at
			// 100/0.05 cd/m^2, in the SEI's fixed-point units.
			config.mastering = h265.Mastering_Display {
				primaries_x = {13250, 7500, 34000},
				primaries_y = {34500, 3000, 16000},
				white_x     = 15635,
				white_y     = 16450,
				max_luma    = 1000000,
				min_luma    = 50,
			}
		case "--crf":
			i += 1
			f, ok := strconv.parse_f64(os.args[i])
			if !ok {
				fmt.eprintln("invalid crf:", os.args[i])
				os.exit(2)
			}
			config.crf = f32(f)
		case "--no-pcm":
			config.pcm = false
		case "--amp":
			config.amp = true
		case "--no-amp":
			config.amp = false
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
		case "--hierarchical":
			config.hierarchical = true
		case "--gop":
			i += 1
			config.gop_size = integer(os.args[i])
		case "--idr-period":
			i += 1
			config.idr_period = integer(os.args[i])
		case "--refs":
			i += 1
			config.refs = integer(os.args[i])
		case "--scaling-list":
			i += 1
			switch os.args[i] {
			case "off":
				config.scaling = .Off
			case "default":
				config.scaling = .Default
			case "flat":
				config.scaling = .Flat
			case:
				fmt.eprintln("invalid scaling list mode:", os.args[i])
				os.exit(2)
			}
		case "--no-wp":
			config.weighted = false
		case "--dump-cu":
			dump_cu = true
		case:
			fmt.eprintln("unknown option:", os.args[i])
			os.exit(2)
		}
	}
	if config.idr_period < 0 ||
	   (config.idr_period > 0 && (config.b_frames || config.hierarchical)) {
		fmt.eprintln("--idr-period requires a non-negative period and the low-delay P path")
		os.exit(2)
	}
	config.capture_rec = rec_path != ""


	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", os.args[1])
		os.exit(1)
	}
	defer delete(data)
	mono := config.chroma_format == h265.Chroma_Layout.Monochrome
	sw, sh := h265.chroma_sub(config.chroma_format)
	cw, ch := width / sw, height / sh
	chroma_size := mono ? 0 : cw * ch
	frame_size := mono ? width * height : width * height + 2 * chroma_size
	bytes_per_sample := config.bit_depth > 8 ? 2 : 1
	if len(data) % (frame_size * bytes_per_sample) != 0 ||
	   frames > len(data) / (frame_size * bytes_per_sample) {
		fmt.eprintln("input does not contain the requested complete frames")
		os.exit(1)
	}

	// The codec core works on 16-bit sample planes. An 8-bit input is widened
	// once; a deeper one is read as 16-bit little-endian samples.
	pixels := make([]h265.Sample, frame_size)
	defer delete(pixels)
	if bytes_per_sample == 2 {
		for i in 0 ..< frame_size {
			pixels[i] = h265.Sample(data[2 * i]) | h265.Sample(data[2 * i + 1]) << 8
		}
	} else {
		src_frame := data[:frame_size]
		for i in 0 ..< frame_size do pixels[i] = h265.Sample(src_frame[i])
	}

	enc: h265.Encoder
	// The thread pool is the caller's: the encoder never owns threads, so
	// the application keeps control of scheduling and contention.
	pool: common.Static_Pool
	pool_on := threads > 0
	if pool_on {
		common.init_static_pool(&pool, threads)
		config.pool = &pool.work_pool
	}
	// The pool lives for the whole encode (an Odin defer is scoped to its
	// block, so this one must sit at main scope).
	defer if pool_on do common.destroy_static_pool(&pool)

	h265.init_encoder(&enc, config)
	defer h265.destroy_encoder(&enc)

	out := make([dynamic]u8, 0, 4 * 1024 * 1024)
	defer delete(out)

	for f in 0 ..< frames {
		if bytes_per_sample == 2 {
			src := data[f * frame_size * 2:]
			for i in 0 ..< frame_size {
				pixels[i] = h265.Sample(src[2 * i]) | h265.Sample(src[2 * i + 1]) << 8
			}
		} else {
			src := data[f * frame_size:]
			for i in 0 ..< frame_size do pixels[i] = h265.Sample(src[i])
		}
		if mono {
			h265.encode_frame(&enc, &pixels[0], nil, nil, width, 0, &out)
		} else {
			h265.encode_frame(
				&enc,
				&pixels[0],
				&pixels[width * height],
				&pixels[width * height + chroma_size],
				width,
				cw,
				&out,
			)
		}
		if dump_cu {
			fmt.printfln("frame %d:", f)
			for cy := 0; cy < enc.coded_height; cy += 8 {
				for cx := 0; cx < enc.coded_width; cx += 8 {
					cu := h265.cu_at(enc.cu, cx, cy)
					fmt.printf(
						"%d,%d:%v d%d m%d%s ",
						cx,
						cy,
						cu.type,
						cu.depth,
						cu.mode,
						cu.pcm ? " PCM" : "",
					)
				}
				fmt.println()
			}
		}
	}
	h265.flush_encoder(&enc, &out)

	if os.write_entire_file(os.args[5], out[:]) != nil {
		fmt.eprintln("cannot write output")
		os.exit(1)
	}
	if rec_path != "" {
		if os.write_entire_file(rec_path, enc.rec_display[:]) != nil {
			fmt.eprintln("cannot write reconstruction")
			os.exit(1)
		}
	}
	fmt.printfln("%d frames, %d bytes", frames, len(out))
}

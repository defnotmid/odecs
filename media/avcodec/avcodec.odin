// Runtime-loaded H.264 and H.265 decoding and encoding through libavcodec.
//
// Both libavutil and libavcodec are opened with core:dynlib on first use,
// trying known major sonames (.so.63..58, .dylib, avcodec-*.dll). Codec
// contexts are configured through AVOptions and pixel-format accessors rather
// than version-dependent AVCodecContext field layouts, and probe admits a
// configuration only if avcodec_open2 succeeds on the host's library build.
package media_avcodec

import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:slice"
import "core:sync"
import media ".."
import avc "../../video/h264"
import avcd "../../video/h264/decoder"
import hevcd "../../video/h265/decoder"

@(private)
AVRational :: struct {
	num: c.int,
	den: c.int,
}

// Prefix of AVPacket invariant across libavcodec 58..63. Always allocated
// and freed by libavcodec (av_packet_alloc / av_packet_free).
@(private)
AVPacket :: struct {
	buf:  rawptr,
	pts:  i64,
	dts:  i64,
	data: [^]u8,
	size: c.int,
}

// Prefix of AVFrame invariant across libavutil 56..61. Always allocated
// and freed by libavutil (av_frame_alloc / av_frame_free).
@(private)
AVFrame :: struct {
	data:          [8][^]u8,
	linesize:      [8]c.int,
	extended_data: rawptr,
	width, height: c.int,
	nb_samples:    c.int,
	format:        c.int,
}

@(private)
AV_OPT_SEARCH_CHILDREN :: c.int(1)
@(private)
AV_NOPTS_VALUE :: min(i64)
@(private)
AV_LOG_ERROR :: c.int(16)

@(private)
API :: struct {
	avutil_lib:                  dynlib.Library,
	avcodec_lib:                 dynlib.Library,
	loaded:                      bool,
	pts_offset:                  uintptr,
	av_frame_alloc:              proc "c" () -> ^AVFrame,
	av_frame_free:               proc "c" (frame: ^^AVFrame),
	av_frame_unref:              proc "c" (frame: ^AVFrame),
	av_frame_get_buffer:         proc "c" (frame: ^AVFrame, align: c.int) -> c.int,
	av_frame_make_writable:      proc "c" (frame: ^AVFrame) -> c.int,
	av_opt_set:                  proc "c" (obj: rawptr, name: cstring, val: cstring, search_flags: c.int) -> c.int,
	av_opt_set_int:              proc "c" (obj: rawptr, name: cstring, val: i64, search_flags: c.int) -> c.int,
	av_opt_set_image_size:       proc "c" (obj: rawptr, name: cstring, w, h, search_flags: c.int) -> c.int,
	av_opt_set_pixel_fmt:        proc "c" (obj: rawptr, name: cstring, fmt: c.int, search_flags: c.int) -> c.int,
	av_opt_set_q:                proc "c" (obj: rawptr, name: cstring, val: AVRational, search_flags: c.int) -> c.int,
	av_opt_set_video_rate:       proc "c" (obj: rawptr, name: cstring, val: AVRational, search_flags: c.int) -> c.int,
	av_get_pix_fmt:              proc "c" (name: cstring) -> c.int,
	av_get_pix_fmt_name:         proc "c" (pix_fmt: c.int) -> cstring,
	av_log_set_level:            proc "c" (level: c.int),
	avcodec_find_decoder_by_name: proc "c" (name: cstring) -> rawptr,
	avcodec_find_encoder_by_name: proc "c" (name: cstring) -> rawptr,
	avcodec_alloc_context3:      proc "c" (codec: rawptr) -> rawptr,
	avcodec_free_context:        proc "c" (avctx: ^rawptr),
	avcodec_open2:               proc "c" (avctx: rawptr, codec: rawptr, options: ^rawptr) -> c.int,
	avcodec_send_packet:         proc "c" (avctx: rawptr, avpkt: ^AVPacket) -> c.int,
	avcodec_receive_frame:       proc "c" (avctx: rawptr, frame: ^AVFrame) -> c.int,
	avcodec_send_frame:          proc "c" (avctx: rawptr, frame: ^AVFrame) -> c.int,
	avcodec_receive_packet:      proc "c" (avctx: rawptr, avpkt: ^AVPacket) -> c.int,
	av_packet_alloc:             proc "c" () -> ^AVPacket,
	av_packet_free:              proc "c" (pkt: ^^AVPacket),
	av_packet_unref:             proc "c" (pkt: ^AVPacket),
}

@(private)
global_api: API
@(private)
global_once: sync.Once

@(private, rodata)
AVUTIL_NAMES_UNIX := [?]string{
	"libavutil.so.61",
	"libavutil.so.60",
	"libavutil.so.59",
	"libavutil.so.58",
	"libavutil.so.57",
	"libavutil.so.56",
	"libavutil.so",
}

@(private, rodata)
AVCODEC_NAMES_UNIX := [?]string{
	"libavcodec.so.63",
	"libavcodec.so.62",
	"libavcodec.so.61",
	"libavcodec.so.60",
	"libavcodec.so.59",
	"libavcodec.so.58",
	"libavcodec.so",
}

@(private, rodata)
AVUTIL_NAMES_DARWIN := [?]string{
	"libavutil.61.dylib",
	"libavutil.60.dylib",
	"libavutil.59.dylib",
	"libavutil.58.dylib",
	"libavutil.57.dylib",
	"libavutil.56.dylib",
	"libavutil.dylib",
	"/opt/homebrew/lib/libavutil.dylib",
	"/usr/local/lib/libavutil.dylib",
}

@(private, rodata)
AVCODEC_NAMES_DARWIN := [?]string{
	"libavcodec.63.dylib",
	"libavcodec.62.dylib",
	"libavcodec.61.dylib",
	"libavcodec.60.dylib",
	"libavcodec.59.dylib",
	"libavcodec.58.dylib",
	"libavcodec.dylib",
	"/opt/homebrew/lib/libavcodec.dylib",
	"/usr/local/lib/libavcodec.dylib",
}

@(private, rodata)
AVUTIL_NAMES_WINDOWS := [?]string{
	"avutil-61.dll",
	"avutil-60.dll",
	"avutil-59.dll",
	"avutil-58.dll",
	"avutil-57.dll",
	"avutil-56.dll",
	"avutil.dll",
}

@(private, rodata)
AVCODEC_NAMES_WINDOWS := [?]string{
	"avcodec-63.dll",
	"avcodec-62.dll",
	"avcodec-61.dll",
	"avcodec-60.dll",
	"avcodec-59.dll",
	"avcodec-58.dll",
	"avcodec.dll",
}

@(private)
load_first :: proc(names: []string) -> (lib: dynlib.Library, ok: bool) {
	for name in names {
		if l, loaded := dynlib.load_library(name); loaded do return l, true
	}
	return nil, false
}

@(private)
sym :: proc(lib: dynlib.Library, name: string, $T: typeid) -> (fn: T, ok: bool) {
	ptr, found := dynlib.symbol_address(lib, name)
	if !found || ptr == nil do return nil, false
	return cast(T)ptr, true
}

@(private)
init_api :: proc() {
	context = runtime.default_context()
	avutil_names: []string
	avcodec_names: []string
	when ODIN_OS == .Darwin {
		avutil_names = AVUTIL_NAMES_DARWIN[:]
		avcodec_names = AVCODEC_NAMES_DARWIN[:]
	} else when ODIN_OS == .Windows {
		avutil_names = AVUTIL_NAMES_WINDOWS[:]
		avcodec_names = AVCODEC_NAMES_WINDOWS[:]
	} else {
		avutil_names = AVUTIL_NAMES_UNIX[:]
		avcodec_names = AVCODEC_NAMES_UNIX[:]
	}
	u, u_ok := load_first(avutil_names)
	if !u_ok do return
	c_lib, c_ok := load_first(avcodec_names)
	if !c_ok {
		dynlib.unload_library(u)
		return
	}
	a := API{avutil_lib = u, avcodec_lib = c_lib}
	defer if !a.loaded {
		dynlib.unload_library(c_lib)
		dynlib.unload_library(u)
	}
	ok := true
	a.av_frame_alloc, ok = sym(u, "av_frame_alloc", type_of(a.av_frame_alloc)); if !ok do return
	a.av_frame_free, ok = sym(u, "av_frame_free", type_of(a.av_frame_free)); if !ok do return
	a.av_frame_unref, ok = sym(u, "av_frame_unref", type_of(a.av_frame_unref)); if !ok do return
	a.av_frame_get_buffer, ok = sym(u, "av_frame_get_buffer", type_of(a.av_frame_get_buffer)); if !ok do return
	a.av_frame_make_writable, ok = sym(u, "av_frame_make_writable", type_of(a.av_frame_make_writable)); if !ok do return
	a.av_opt_set, ok = sym(u, "av_opt_set", type_of(a.av_opt_set)); if !ok do return
	a.av_opt_set_int, ok = sym(u, "av_opt_set_int", type_of(a.av_opt_set_int)); if !ok do return
	a.av_opt_set_image_size, ok = sym(u, "av_opt_set_image_size", type_of(a.av_opt_set_image_size)); if !ok do return
	a.av_opt_set_pixel_fmt, ok = sym(u, "av_opt_set_pixel_fmt", type_of(a.av_opt_set_pixel_fmt)); if !ok do return
	a.av_opt_set_q, ok = sym(u, "av_opt_set_q", type_of(a.av_opt_set_q)); if !ok do return
	a.av_opt_set_video_rate, ok = sym(u, "av_opt_set_video_rate", type_of(a.av_opt_set_video_rate)); if !ok do return
	a.av_get_pix_fmt, ok = sym(u, "av_get_pix_fmt", type_of(a.av_get_pix_fmt)); if !ok do return
	a.av_get_pix_fmt_name, ok = sym(u, "av_get_pix_fmt_name", type_of(a.av_get_pix_fmt_name)); if !ok do return
	a.av_log_set_level, _ = sym(u, "av_log_set_level", type_of(a.av_log_set_level))

	a.avcodec_find_decoder_by_name, ok = sym(c_lib, "avcodec_find_decoder_by_name", type_of(a.avcodec_find_decoder_by_name)); if !ok do return
	a.avcodec_find_encoder_by_name, ok = sym(c_lib, "avcodec_find_encoder_by_name", type_of(a.avcodec_find_encoder_by_name)); if !ok do return
	a.avcodec_alloc_context3, ok = sym(c_lib, "avcodec_alloc_context3", type_of(a.avcodec_alloc_context3)); if !ok do return
	a.avcodec_free_context, ok = sym(c_lib, "avcodec_free_context", type_of(a.avcodec_free_context)); if !ok do return
	a.avcodec_open2, ok = sym(c_lib, "avcodec_open2", type_of(a.avcodec_open2)); if !ok do return
	a.avcodec_send_packet, ok = sym(c_lib, "avcodec_send_packet", type_of(a.avcodec_send_packet)); if !ok do return
	a.avcodec_receive_frame, ok = sym(c_lib, "avcodec_receive_frame", type_of(a.avcodec_receive_frame)); if !ok do return
	a.avcodec_send_frame, ok = sym(c_lib, "avcodec_send_frame", type_of(a.avcodec_send_frame)); if !ok do return
	a.avcodec_receive_packet, ok = sym(c_lib, "avcodec_receive_packet", type_of(a.avcodec_receive_packet)); if !ok do return
	a.av_packet_alloc, ok = sym(c_lib, "av_packet_alloc", type_of(a.av_packet_alloc)); if !ok do return
	a.av_packet_free, ok = sym(c_lib, "av_packet_free", type_of(a.av_packet_free)); if !ok do return
	a.av_packet_unref, ok = sym(c_lib, "av_packet_unref", type_of(a.av_packet_unref)); if !ok do return

	if a.av_log_set_level != nil do a.av_log_set_level(AV_LOG_ERROR)

	// Discover AVFrame.pts offset dynamically: av_frame_alloc() initializes
	// pts and pkt_dts to AV_NOPTS_VALUE (min(i64)) immediately after the
	// header fields.
	if f := a.av_frame_alloc(); f != nil {
		for off := uintptr(size_of(AVFrame)); off <= 160; off += 8 {
			val := ((^i64)(uintptr(f) + off))^
			next := ((^i64)(uintptr(f) + off + 8))^
			if val == AV_NOPTS_VALUE && next == AV_NOPTS_VALUE {
				a.pts_offset = off
				break
			}
		}
		f_ptr := f
		a.av_frame_free(&f_ptr)
	}
	if a.pts_offset == 0 do return

	a.loaded = true
	global_api = a
}

@(private)
ensure_api :: proc() -> (^API, bool) {
	sync.once_do(&global_once, init_api)
	return &global_api, global_api.loaded
}

provider :: proc() -> media.Provider {
	return {backend = .AVCodec, name = "libavcodec", probe = probe, open = open_avcodec}
}

@(private)
pixel_format_name :: proc(chroma: media.Chroma, depth: int) -> cstring {
	switch chroma {
	case .YUV420:
		if depth == 8 do return "yuv420p"
		if depth == 10 do return "yuv420p10le"
		if depth == 12 do return "yuv420p12le"
	case .YUV422:
		if depth == 8 do return "yuv422p"
		if depth == 10 do return "yuv422p10le"
		if depth == 12 do return "yuv422p12le"
	case .YUV444:
		if depth == 8 do return "yuv444p"
		if depth == 10 do return "yuv444p10le"
		if depth == 12 do return "yuv444p12le"
	case .Monochrome:
		if depth == 8 do return "gray"
		if depth == 10 do return "gray10le"
		if depth == 12 do return "gray12le"
	}
	return ""
}

@(private)
parse_pixel_format :: proc(api: ^API, fmt_id: c.int) -> (chroma: media.Chroma, bit_depth, storage_bits: int, gbr: bool, ok: bool) {
	cname := api.av_get_pix_fmt_name(fmt_id)
	if cname == nil do return .YUV420, 0, 0, false, false
	switch string(cname) {
	case "yuv420p", "yuvj420p", "yuva420p":
		return .YUV420, 8, 8, false, true
	case "yuv420p10le", "yuva420p10le":
		return .YUV420, 10, 16, false, true
	case "yuv420p12le":
		return .YUV420, 12, 16, false, true
	case "yuv422p", "yuvj422p", "yuva422p":
		return .YUV422, 8, 8, false, true
	case "yuv422p10le", "yuva422p10le":
		return .YUV422, 10, 16, false, true
	case "yuv422p12le":
		return .YUV422, 12, 16, false, true
	case "yuv444p", "yuvj444p", "yuva444p":
		return .YUV444, 8, 8, false, true
	case "yuv444p10le", "yuva444p10le":
		return .YUV444, 10, 16, false, true
	case "yuv444p12le":
		return .YUV444, 12, 16, false, true
	case "gbrp", "gbrap":
		return .YUV444, 8, 8, true, true
	case "gbrp10le", "gbrap10le":
		return .YUV444, 10, 16, true, true
	case "gbrp12le", "gbrap12le":
		return .YUV444, 12, 16, true, true
	case "gray", "gray8", "ya8":
		return .Monochrome, 8, 8, false, true
	case "gray10le":
		return .Monochrome, 10, 16, false, true
	case "gray12le":
		return .Monochrome, 12, 16, false, true
	}
	return .YUV420, 0, 0, false, false
}

@(private)
open_codec_context :: proc(config: media.Config) -> (ctx: rawptr, pix_fmt: c.int, err: media.Error) {
	if err = media.validate_config(config); err != .None do return nil, -1, err
	if config.codec != .H264 && config.codec != .H265 do return nil, -1, .Unsupported
	depth := config.bit_depth == 0 ? 8 : config.bit_depth
	if config.codec == .H264 && depth != 8 && depth != 10 do return nil, -1, .Unsupported
	if config.codec == .H265 && depth != 8 && depth != 10 && depth != 12 do return nil, -1, .Unsupported
	if config.operation == .Decode && config.output_storage != .Host do return nil, -1, .Unsupported
	// Decoders take sides up to level 6 (16888); encoders up to 8192.
	limit := config.operation == .Encode ? 8192 : 16888
	if config.width > limit || config.height > limit do return nil, -1, .Unsupported
	if config.operation == .Encode {
		if config.alpha do return nil, -1, .Unsupported
		if config.width < 16 || config.height < 16 do return nil, -1, .Unsupported
	}
	api, ok := ensure_api()
	if !ok do return nil, -1, .Unavailable

	if config.operation == .Decode {
		names_h264 := [?]cstring{"h264", "libopenh264"}
		names_h265 := [?]cstring{"hevc"}
		names := config.codec == .H264 ? names_h264[:] : names_h265[:]
		for name in names {
			if name == "libopenh264" && (depth != 8 || config.chroma != .YUV420) do continue
			codec := api.avcodec_find_decoder_by_name(name)
			if codec == nil do continue
			c_ctx := api.avcodec_alloc_context3(codec)
			if c_ctx == nil do continue
			_ = api.av_opt_set_int(c_ctx, "threads", 1, 0)
			_ = api.av_opt_set_int(c_ctx, "apply_cropping", 0, 0)
			if config.no_reordering {
				_ = api.av_opt_set(c_ctx, "flags", "+low_delay", 0)
			}
			if api.avcodec_open2(c_ctx, codec, nil) == 0 {
				return c_ctx, -1, .None
			}
			api.avcodec_free_context(&c_ctx)
		}
		return nil, -1, .Unavailable
	}

	pf_name := pixel_format_name(config.chroma, depth)
	if pf_name == "" do return nil, -1, .Unsupported
	pf := api.av_get_pix_fmt(pf_name)
	if pf < 0 do return nil, -1, .Unsupported

	enc_h264 := [?]cstring{"libx264", "libopenh264"}
	enc_h265 := [?]cstring{"libx265", "libkvazaar"}
	names := config.codec == .H264 ? enc_h264[:] : enc_h265[:]
	found_any := false
	for name in names {
		codec := api.avcodec_find_encoder_by_name(name)
		if codec == nil do continue
		found_any = true
		c_ctx := api.avcodec_alloc_context3(codec)
		if c_ctx == nil do continue
		_ = api.av_opt_set_image_size(c_ctx, "video_size", c.int(config.width), c.int(config.height), 0)
		_ = api.av_opt_set_pixel_fmt(c_ctx, "pixel_format", pf, 0)
		fps_num := c.int(config.frame_rate_num > 0 ? config.frame_rate_num : 30)
		fps_den := c.int(config.frame_rate_den > 0 ? config.frame_rate_den : 1)
		_ = api.av_opt_set_q(c_ctx, "time_base", AVRational{num = fps_den, den = fps_num}, 0)
		_ = api.av_opt_set_q(c_ctx, "pkt_timebase", AVRational{num = fps_den, den = fps_num}, 0)
		_ = api.av_opt_set_video_rate(c_ctx, "framerate", AVRational{num = fps_num, den = fps_den}, 0)
		gop := config.gop_size == 0 ? 15 : config.gop_size
		_ = api.av_opt_set_int(c_ctx, "g", i64(gop), 0)
		_ = api.av_opt_set_int(c_ctx, "keyint_min", i64(gop), 0)
		_ = api.av_opt_set_int(c_ctx, "bf", 0, 0)
		_ = api.av_opt_set_int(c_ctx, "threads", 1, 0)
		qp := i64(clamp(config.qp, 0, 51))
		_ = api.av_opt_set_int(c_ctx, "qp", qp, AV_OPT_SEARCH_CHILDREN)
		_ = api.av_opt_set_int(c_ctx, "qmin", qp, 0)
		_ = api.av_opt_set_int(c_ctx, "qmax", qp, 0)
		if config.ultrafast {
			_ = api.av_opt_set(c_ctx, "preset", "ultrafast", AV_OPT_SEARCH_CHILDREN)
		} else {
			_ = api.av_opt_set(c_ctx, "preset", "veryfast", AV_OPT_SEARCH_CHILDREN)
		}
		_ = api.av_opt_set(c_ctx, "tune", "zerolatency", AV_OPT_SEARCH_CHILDREN)
		_ = api.av_opt_set_int(c_ctx, "forced-idr", 1, AV_OPT_SEARCH_CHILDREN)
		if name == "libx264" {
			_ = api.av_opt_set(c_ctx, "x264opts", "scenecut=0", AV_OPT_SEARCH_CHILDREN)
		} else if name == "libx265" {
			x265_params := fmt.ctprintf("keyint=%d:min-keyint=%d:scenecut=0:bframes=0:qp=%d:repeat-headers=1:info=0:log-level=error", gop, gop, qp)
			_ = api.av_opt_set(c_ctx, "x265-params", x265_params, AV_OPT_SEARCH_CHILDREN)
		}
		if config.color.primaries != 0 {
			_ = api.av_opt_set_int(c_ctx, "color_primaries", i64(config.color.primaries), 0)
			_ = api.av_opt_set_int(c_ctx, "color_trc", i64(config.color.transfer), 0)
			_ = api.av_opt_set_int(c_ctx, "colorspace", i64(config.color.matrix_coeffs), 0)
			_ = api.av_opt_set_int(c_ctx, "color_range", config.color.full_range ? 2 : 1, 0)
		}
		if api.avcodec_open2(c_ctx, codec, nil) == 0 {
			return c_ctx, pf, .None
		}
		api.avcodec_free_context(&c_ctx)
	}
	return nil, -1, found_any ? .Unsupported : .Unavailable
}

probe :: proc(config: media.Config, user: rawptr) -> media.Error {
	ctx, _, err := open_codec_context(config)
	if err != .None do return err
	api, _ := ensure_api()
	api.avcodec_free_context(&ctx)
	return .None
}

// A decoded picture held in host memory until its turn in display order.
@(private)
Held_Frame :: struct {
	frame:  media.Video_Frame,
	planes: [3][]u8,
	id:     i64,
}

@(private)
H264_Display :: struct {
	pic_id: i32,
	poc:    i32,
}

@(private)
H265_Entry :: struct {
	id:                i64,
	poc:               i32,
	reference, output: bool,
	latency:           int,
}

@(private)
State :: struct {
	ctx:                 rawptr,
	pkt:                 ^AVPacket,
	frame:               ^AVFrame,
	pix_fmt:             c.int,
	frame_index:         i64,
	au:                  [dynamic]u8,
	packet_buf:          [dynamic]u8,
	held:                [dynamic]Held_Frame,
	in_flight:           [dynamic]Held_Frame,
	has_vcl:             bool,
	seen_picture:        bool,
	// H.264 syntax and DPB ordering
	avc_syntax:          avcd.Decoder_State,
	avc_sps_nal:         [32][dynamic]u8,
	avc_pps_nal:         [256][dynamic]u8,
	avc_display:         [dynamic]H264_Display,
	// HEVC syntax and DPB ordering
	hevc_syntax:         hevcd.Nal_Scratch,
	hevc_vps:            [16]hevcd.VPS,
	hevc_sps:            [16]hevcd.SPS,
	hevc_pps:            [64]hevcd.PPS,
	has_hevc_vps:        [16]bool,
	has_hevc_sps:        [16]bool,
	has_hevc_pps:        [64]bool,
	hevc_vps_nal:        [16][dynamic]u8,
	hevc_sps_nal:        [16][dynamic]u8,
	hevc_pps_nal:        [64][dynamic]u8,
	hevc_pending:        hevcd.Slice_Header,
	hevc_pending_type:   hevcd.Nal_Type,
	hevc_pending_tid:    u8,
	has_hevc_pending:    bool,
	hevc_poc:            hevcd.Poc_State,
	hevc_dpb:            [dynamic]H265_Entry,
	hevc_display:        [dynamic]i64,
	hevc_next_id:        i64,
	hevc_max_reorder:    int,
	hevc_max_latency:    int,
	hevc_max_dpb:        int,
	skip_rasl:           bool,
}

@(private)
free_held :: proc(h: ^Held_Frame) {
	for plane in h.planes do delete(plane)
	h^ = {}
}

@(private)
open_avcodec :: proc(session: ^media.Session, config: media.Config, user: rawptr) -> media.Error {
	ctx, pf, err := open_codec_context(config)
	if err != .None do return err
	api, _ := ensure_api()
	s := new(State)
	if s == nil {
		api.avcodec_free_context(&ctx)
		return .Codec_Error
	}
	s.ctx = ctx
	s.pix_fmt = pf
	s.pkt = api.av_packet_alloc()
	s.frame = api.av_frame_alloc()
	if s.pkt == nil || s.frame == nil {
		if s.pkt != nil do api.av_packet_free(&s.pkt)
		if s.frame != nil do api.av_frame_free(&s.frame)
		api.avcodec_free_context(&s.ctx)
		free(s)
		return .Codec_Error
	}
	if config.operation == .Decode && config.codec == .H264 {
		avcd.init_decoder(&s.avc_syntax)
		s.avc_syntax.no_reordering = config.no_reordering
	}
	session.state = s
	session.close_impl = close_avcodec
	session.drain_impl = drain_avcodec
	if config.operation == .Decode {
		session.decode_impl = decode_avcodec
	} else {
		session.video_impl = encode_avcodec
	}
	return .None
}

@(private)
close_avcodec :: proc(session: ^media.Session) {
	s := (^State)(session.state)
	if s == nil do return
	api, ok := ensure_api()
	if ok {
		if s.frame != nil do api.av_frame_free(&s.frame)
		if s.pkt != nil do api.av_packet_free(&s.pkt)
		if s.ctx != nil do api.avcodec_free_context(&s.ctx)
	}
	if session.config.operation == .Decode && session.config.codec == .H264 {
		avcd.destroy_decoder(&s.avc_syntax)
	}
	if s.has_hevc_pending do hevcd.destroy_slice_header(&s.hevc_pending)
	for &sps, i in s.hevc_sps do if s.has_hevc_sps[i] do hevcd.destroy_sps(&sps)
	for &pps, i in s.hevc_pps do if s.has_hevc_pps[i] do hevcd.destroy_pps(&pps)
	for nal in s.avc_sps_nal do delete(nal)
	for nal in s.avc_pps_nal do delete(nal)
	for nal in s.hevc_vps_nal do delete(nal)
	for nal in s.hevc_sps_nal do delete(nal)
	for nal in s.hevc_pps_nal do delete(nal)
	for &h in s.held do free_held(&h)
	delete(s.held)
	delete(s.in_flight)
	delete(s.avc_display)
	delete(s.hevc_dpb)
	delete(s.hevc_display)
	hevcd.destroy_nal_scratch(&s.hevc_syntax)
	delete(s.au)
	delete(s.packet_buf)
	free(s)
}

@(private)
frame_pts :: proc(api: ^API, f: ^AVFrame) -> i64 {
	if api.pts_offset == 0 do return AV_NOPTS_VALUE
	return ((^i64)(uintptr(f) + api.pts_offset))^
}

@(private)
set_frame_pts :: proc(api: ^API, f: ^AVFrame, pts: i64) {
	if api.pts_offset != 0 {
		((^i64)(uintptr(f) + api.pts_offset))^ = pts
	}
}

@(private)
replace_nal :: proc(stored: ^[dynamic]u8, data: []u8) {
	clear(stored)
	append(stored, ..data)
}

@(private)
append_annex_b :: proc(buf: ^[dynamic]u8, nal: []u8) {
	append(buf, 0, 0, 0, 1)
	append(buf, ..nal)
}

@(private)
receive_decoded_frames :: proc(session: ^media.Session, s: ^State, receiver: media.Receiver) -> media.Error {
	api, _ := ensure_api()
	for {
		ret := api.avcodec_receive_frame(s.ctx, s.frame)
		if ret < 0 do break
		defer api.av_frame_unref(s.frame)
		chroma, bit_depth, storage_bits, gbr, ok := parse_pixel_format(api, s.frame.format)
		if !ok {
			session.error_detail = "libavcodec produced an unsupported pixel format"
			return .Unsupported
		}
		pts := frame_pts(api, s.frame)
		match := -1
		for f, i in s.in_flight {
			if f.id == pts {
				match = i
				break
			}
		}
		if match < 0 && len(s.in_flight) > 0 do match = 0
		if match < 0 do continue
		pending := s.in_flight[match]
		ordered_remove(&s.in_flight, match)

		out := pending.frame
		out.chroma = chroma
		out.bit_depth = bit_depth
		out.storage_bits = storage_bits
		if gbr {
			if out.color.primaries == 0 do out.color.primaries = 1
			out.color.matrix_coeffs = 0
		}
		sw, sh := media.chroma_subsampling(chroma)
		sample_bytes := storage_bits / 8
		planes := chroma == .Monochrome ? 1 : 3
		for i in 0 ..< planes {
			pw := i == 0 ? out.width : (out.width + sw - 1) / sw
			ph := i == 0 ? out.height : (out.height + sh - 1) / sh
			cx := i == 0 ? out.crop_x : out.crop_x / sw
			cy := i == 0 ? out.crop_y : out.crop_y / sh
			stride := int(s.frame.linesize[i])
			row := (cx + pw) * sample_bytes
			if s.frame.data[i] == nil || stride < row || int(s.frame.height) < (i == 0 ? out.crop_y + out.height : (out.crop_y + out.height + sh - 1) / sh) {
				return .Codec_Error
			}
			start := (cy * stride + cx * sample_bytes)
			total := (ph - 1) * stride + pw * sample_bytes
			src := s.frame.data[i][start : start + total]
			pending.planes[i] = slice.clone(src)
			out.planes[i] = {pending.planes[i], stride}
		}
		pending.frame = out
		append(&s.held, pending)
	}
	if session.config.codec == .H264 {
		h264_emit(s, receiver)
	} else {
		h265_emit(s, receiver)
	}
	return .None
}

@(private)
h264_take_display :: proc(s: ^State) {
	for {
		pic := avcd.next_output_frame(&s.avc_syntax)
		if pic == nil do return
		append(&s.avc_display, H264_Display{pic.pic_id, pic.poc})
	}
}

@(private)
h264_awaited :: proc(s: ^State, pic_id: i32) -> bool {
	for e in s.avc_display do if e.pic_id == pic_id do return true
	for &pic in s.avc_syntax.pics do if pic.in_use && pic.pic_id == pic_id && pic.needed_for_output do return true
	return false
}

@(private)
h264_emit :: proc(s: ^State, receiver: media.Receiver) {
	outer: for len(s.avc_display) > 0 {
		for &h, i in s.held {
			if h.id != i64(s.avc_display[0].pic_id) do continue
			h.frame.poc = int(s.avc_display[0].poc)
			ordered_remove(&s.avc_display, 0)
			if receiver.video != nil do receiver.video(h.frame, receiver.user)
			free_held(&h)
			ordered_remove(&s.held, i)
			continue outer
		}
		break
	}
	for i := 0; i < len(s.held); {
		if h264_awaited(s, i32(s.held[i].id)) {
			i += 1
			continue
		}
		free_held(&s.held[i])
		ordered_remove(&s.held, i)
	}
}

@(private)
h264_finish_picture :: proc(session: ^media.Session, s: ^State, receiver: media.Receiver) -> media.Error {
	state := &s.avc_syntax
	if state.curr == nil do return .None
	defer {
		clear(&s.au)
		s.has_vcl = false
	}
	sps_id := state.current_sequence_parameter_set_id
	sps := &state.sequence_parameters[sps_id]
	avcd.finish_picture_marking(state, sps, &state.prev_slice)
	pic_id := state.curr.pic_id
	state.curr = nil
	state.have_prev_slice = false
	h264_take_display(s)

	sub_x := sps.chroma_format == .YUV_444 || sps.chroma_format == .Monochrome ? 1 : 2
	sub_y := sps.chroma_format == .YUV_420 ? 2 : 1
	color: media.Color
	if !(sps.colour_primaries == 2 && sps.matrix_coefficients == 2 && !sps.video_full_range) {
		color = {sps.colour_primaries, sps.transfer_characteristics, sps.matrix_coefficients, sps.video_full_range}
	}
	append(&s.in_flight, Held_Frame {
		id = i64(pic_id),
		frame = {
			width        = sps.width,
			height       = sps.height,
			coded_width  = sps.macroblock_columns * 16,
			coded_height = sps.macroblock_rows * 16,
			crop_x       = int(sps.crop_left) * sub_x,
			crop_y       = int(sps.crop_top) * sub_y,
			storage      = .Host,
			color        = color,
		},
	})
	api, _ := ensure_api()
	api.av_opt_set_int(s.ctx, "has_b_frames", i64(state.max_reorder), 0)
	api.av_packet_unref(s.pkt)
	s.pkt.data = raw_data(s.au)
	s.pkt.size = c.int(len(s.au))
	s.pkt.pts = i64(pic_id)
	s.pkt.dts = AV_NOPTS_VALUE
	if api.avcodec_send_packet(s.ctx, s.pkt) < 0 {
		session.error_detail = "libavcodec rejected H.264 video packet"
		return .Codec_Error
	}
	return receive_decoded_frames(session, s, receiver)
}

@(private)
decode_h264_nal :: proc(session: ^media.Session, s: ^State, nal: []u8, receiver: media.Receiver) -> media.Error {
	if len(nal) < 1 || nal[0] & 0x80 != 0 do return .Invalid_Input
	nal_type := avc.Nal_Unit_Type(nal[0] & 0x1F)
	nal_ref := (nal[0] >> 5) & 3
	state := &s.avc_syntax
	rbsp := avc.unescape_rbsp_into_buffer(nal[1:], &state.rbsp_buffer)
	reader := avc.init_bit_reader(rbsp)
	#partial switch nal_type {
	case .Sequence_Parameter_Set:
		h264_finish_picture(session, s, receiver) or_return
		value, ok := avcd.parse_sequence_parameter_set(&reader)
		if !ok do return .Invalid_Input
		if err := avcd.sequence_parameter_set_error(&value, high_formats = true); err != .None {
			session.error_detail = avcd.error_description(err)
			return avcd.is_unsupported(err) ? .Unsupported : .Codec_Error
		}
		id := value.sequence_parameter_set_id
		state.sequence_parameters[id], state.sequence_parameter_set_valid[id] = value, true
		replace_nal(&s.avc_sps_nal[id], nal)
		return .None
	case .Picture_Parameter_Set:
		h264_finish_picture(session, s, receiver) or_return
		value, ok := avcd.parse_picture_parameter_set(&reader, state)
		if !ok do return .Invalid_Input
		if err := avcd.picture_parameter_set_error(&value); err != .None {
			session.error_detail = avcd.error_description(err)
			return avcd.is_unsupported(err) ? .Unsupported : .Codec_Error
		}
		id := value.pic_parameter_set_id
		state.picture_parameters[id], state.picture_parameter_set_valid[id] = value, true
		replace_nal(&s.avc_pps_nal[id], nal)
		return .None
	case .End_Of_Seq, .End_Of_Stream:
		h264_finish_picture(session, s, receiver) or_return
		avcd.flush_output(&s.avc_syntax)
		h264_take_display(s)
		h264_emit(s, receiver)
		return .None
	case .Slice_DPA, .Slice_DPB, .Slice_DPC:
		return .Unsupported
	case .Slice_IDR, .Slice_Non_IDR:
	case:
		return .None
	}
	header, ok := avcd.parse_slice_header(&reader, nal_type, nal_ref, state)
	if !ok do return .Codec_Error
	sps := &state.sequence_parameters[state.active_sequence_parameter_set_id]
	pps := &state.picture_parameters[state.active_picture_parameter_set_id]
	if avcd.sequence_parameter_set_error(sps, high_formats = true) != .None || avcd.picture_parameter_set_error(pps) != .None || header.slice_type == .SP || header.slice_type == .SI do return .Unsupported
	if header.redundant_pic_cnt > 0 do return .None
	if s.has_vcl && avcd.starts_new_picture(state, &header, sps) {
		h264_finish_picture(session, s, receiver) or_return
	}
	if !s.has_vcl {
		if !s.seen_picture && !header.is_idr do return .Codec_Error
		s.seen_picture = true
		avcd.release_unused_pictures(state)
		avcd.activate_sequence_parameter_set_metadata(state, sps)
		if header.slice_type == .B && state.max_reorder == 0 && !state.no_reordering do state.max_reorder = state.dpb_size
		if _, reason := avcd.start_picture_metadata(state, sps, &header); reason != .None do return .Codec_Error
		state.current_sequence_parameter_set_id = state.active_sequence_parameter_set_id
		state.current_picture_parameter_set_id = state.active_picture_parameter_set_id
		append_annex_b(&s.au, s.avc_sps_nal[state.current_sequence_parameter_set_id][:])
		for valid, id in state.picture_parameter_set_valid {
			if valid && int(state.picture_parameters[id].sequence_parameter_set_id) == state.current_sequence_parameter_set_id {
				append_annex_b(&s.au, s.avc_pps_nal[id][:])
			}
		}
		s.has_vcl = true
	}
	state.slice, state.prev_slice, state.have_prev_slice = header, header, true
	avcd.build_ref_lists(state, sps, &header)
	append_annex_b(&s.au, nal)
	return .None
}

@(private)
h265_bump :: proc(s: ^State) -> bool {
	best := -1
	for e, i in s.hevc_dpb do if e.output && (best < 0 || e.poc < s.hevc_dpb[best].poc) do best = i
	if best < 0 do return false
	s.hevc_dpb[best].output = false
	append(&s.hevc_display, s.hevc_dpb[best].id)
	h265_remove_unused(s)
	return true
}

@(private)
h265_remove_unused :: proc(s: ^State) {
	kept := 0
	for e in s.hevc_dpb {
		if !e.reference && !e.output do continue
		s.hevc_dpb[kept] = e
		kept += 1
	}
	resize(&s.hevc_dpb, kept)
}

@(private)
h265_full :: proc(s: ^State, include_buffering: bool) -> bool {
	waiting := 0
	for e in s.hevc_dpb {
		if !e.output do continue
		waiting += 1
		if s.hevc_max_latency != 0 && e.latency >= s.hevc_max_reorder + s.hevc_max_latency - 1 do return true
	}
	return waiting > s.hevc_max_reorder || include_buffering && len(s.hevc_dpb) >= s.hevc_max_dpb
}

@(private)
h265_awaited :: proc(s: ^State, id: i64) -> bool {
	for e in s.hevc_display do if e == id do return true
	for e in s.hevc_dpb do if e.id == id && e.output do return true
	return false
}

@(private)
h265_emit :: proc(s: ^State, receiver: media.Receiver) {
	outer: for len(s.hevc_display) > 0 {
		for &h, i in s.held {
			if h.id != s.hevc_display[0] do continue
			ordered_remove(&s.hevc_display, 0)
			if receiver.video != nil do receiver.video(h.frame, receiver.user)
			free_held(&h)
			ordered_remove(&s.held, i)
			continue outer
		}
		break
	}
	for i := 0; i < len(s.held); {
		if h265_awaited(s, s.held[i].id) {
			i += 1
			continue
		}
		free_held(&s.held[i])
		ordered_remove(&s.held, i)
	}
}

@(private)
h265_finish_picture :: proc(session: ^media.Session, s: ^State, receiver: media.Receiver) -> media.Error {
	if !s.has_hevc_pending do return .None
	defer {
		hevcd.destroy_slice_header(&s.hevc_pending)
		s.has_hevc_pending = false
		clear(&s.au)
		s.has_vcl = false
	}
	header := &s.hevc_pending
	sps := &s.hevc_sps[s.hevc_pps[header.pps_id].sps_id]
	s.hevc_max_reorder = int(sps.max_num_reorder_pics)
	s.hevc_max_latency = int(sps.max_latency_increase)
	s.hevc_max_dpb = int(sps.max_dec_pic_buffering) + 1
	no_rasl := hevcd.nal_type_is_irap(s.hevc_pending_type) && s.skip_rasl
	if no_rasl do s.hevc_poc = {}
	poc := hevcd.derive_poc(&s.hevc_poc, s.hevc_pending_type, i32(header.pic_order_cnt_lsb), sps.log2_max_poc_lsb, no_rasl)
	hevcd.poc_state_update(&s.hevc_poc, s.hevc_pending_type, s.hevc_pending_tid, poc, i32(header.pic_order_cnt_lsb), sps.log2_max_poc_lsb)

	if no_rasl {
		if !header.no_output_of_prior_pics && s.hevc_pending_type != .CRA_NUT {
			for h265_bump(s) {}
		}
		clear(&s.hevc_dpb)
		h265_emit(s, receiver)
	} else {
		rps := hevcd.derive_ref_pic_set(poc, sps.log2_max_poc_lsb, &header.st_rps, &header.lt_rps, header.lt_rps.num_sps)
		defer hevcd.destroy_ref_pic_set(&rps)
		available := make([dynamic]i32, 0, len(s.hevc_dpb))
		defer delete(available)
		for e in s.hevc_dpb do if e.reference do append(&available, e.poc)
		hevcd.resolve_long_term_ref_pocs(&rps, available[:], sps.log2_max_poc_lsb)
		groups := [5][]i32{rps.st_curr_before[:], rps.st_curr_after[:], rps.lt_curr[:], rps.st_foll[:], rps.lt_foll[:]}
		for &e in s.hevc_dpb {
			e.reference = false
			for group in groups do for ref in group do if ref == e.poc do e.reference = true
		}
		h265_remove_unused(s)
		for h265_full(s, true) do if !h265_bump(s) do break
		h265_emit(s, receiver)
	}

	id := s.hevc_next_id
	s.hevc_next_id += 1
	sub_x := sps.chroma_format_idc == 1 || sps.chroma_format_idc == 2 ? 2 : 1
	sub_y := sps.chroma_format_idc == 1 ? 2 : 1
	color: media.Color
	if !(sps.colour_primaries == 2 && sps.matrix_coeffs == 2 && !sps.full_range) {
		color = {u8(sps.colour_primaries), u8(sps.transfer_char), u8(sps.matrix_coeffs), sps.full_range}
	}
	append(&s.in_flight, Held_Frame {
		id = id,
		frame = {
			width        = int(hevcd.sps_cropped_width(sps)),
			height       = int(hevcd.sps_cropped_height(sps)),
			coded_width  = int(sps.pic_width_in_luma_samples),
			coded_height = int(sps.pic_height_in_luma_samples),
			crop_x       = int(sps.conf_win_left) * sub_x,
			crop_y       = int(sps.conf_win_top) * sub_y,
			poc          = int(poc),
			storage      = .Host,
			color        = color,
		},
	})

	output := header.pic_output_flag
	if output do for &e in s.hevc_dpb do if e.output do e.latency += 1
	append(&s.hevc_dpb, H265_Entry{id = id, poc = poc, reference = true, output = output})
	for h265_full(s, false) do if !h265_bump(s) do break

	api, _ := ensure_api()
	api.av_packet_unref(s.pkt)
	s.pkt.data = raw_data(s.au)
	s.pkt.size = c.int(len(s.au))
	s.pkt.pts = id
	s.pkt.dts = AV_NOPTS_VALUE
	if api.avcodec_send_packet(s.ctx, s.pkt) < 0 {
		session.error_detail = "libavcodec rejected HEVC video packet"
		return .Codec_Error
	}
	return receive_decoded_frames(session, s, receiver)
}

@(private)
decode_h265_nal :: proc(session: ^media.Session, s: ^State, nal_bytes: []u8, receiver: media.Receiver) -> media.Error {
	nal, ok := hevcd.parse_nal_into(nal_bytes, &s.hevc_syntax)
	if !ok do return .Invalid_Input
	if nal.layer_id != 0 do return .None
	#partial switch nal.type {
	case .VPS_NUT, .SPS_NUT, .PPS_NUT:
		h265_finish_picture(session, s, receiver) or_return
		#partial switch nal.type {
		case .VPS_NUT:
			value, good := hevcd.parse_vps(nal.rbsp)
			if !good do return .Codec_Error
			if value.max_layers_minus1 != 0 && value.alpha_layer_id == 0 do return .Unsupported
			s.hevc_vps[value.id], s.has_hevc_vps[value.id] = value, true
			replace_nal(&s.hevc_vps_nal[value.id], nal_bytes)
		case .SPS_NUT:
			value, good := hevcd.parse_sps(nal.rbsp)
			if !good do return .Codec_Error
			if value.bit_depth_luma != value.bit_depth_chroma || (value.bit_depth_luma != 8 && value.bit_depth_luma != 10 && value.bit_depth_luma != 12) do return .Unsupported
			if s.has_hevc_sps[value.id] do hevcd.destroy_sps(&s.hevc_sps[value.id])
			s.hevc_sps[value.id], s.has_hevc_sps[value.id] = value, true
			replace_nal(&s.hevc_sps_nal[value.id], nal_bytes)
		case .PPS_NUT:
			value, good := hevcd.parse_pps(nal.rbsp)
			if !good do return .Codec_Error
			if s.has_hevc_pps[value.id] do hevcd.destroy_pps(&s.hevc_pps[value.id])
			s.hevc_pps[value.id], s.has_hevc_pps[value.id] = value, true
			replace_nal(&s.hevc_pps_nal[value.id], nal_bytes)
		}
		return .None
	case .AUD_NUT:
		return h265_finish_picture(session, s, receiver)
	case .EOS_NUT, .EOB_NUT:
		h265_finish_picture(session, s, receiver) or_return
		s.seen_picture = false
		return .None
	}
	if !hevcd.nal_type_is_vcl(nal.type) do return .None
	pps_id, good := hevcd.peek_pps_id(nal)
	if !good || pps_id >= len(s.hevc_pps) || !s.has_hevc_pps[pps_id] do return .Codec_Error
	p := &s.hevc_pps[pps_id]
	if !s.has_hevc_sps[p.sps_id] do return .Codec_Error
	sps := &s.hevc_sps[p.sps_id]
	if !s.has_hevc_vps[sps.vps_id] do return .Codec_Error
	if !hevcd.pps_resolve_tile_geometry(p, sps) || !hevcd.sao_offset_scales_valid(p, sps) do return .Codec_Error
	header, good_header := hevcd.parse_slice_header(nal.rbsp, nal.type, sps, p)
	if !good_header do return .Codec_Error
	if header.first_slice_segment_in_pic {
		if err := h265_finish_picture(session, s, receiver); err != .None {
			hevcd.destroy_slice_header(&header)
			return err
		}
		irap := hevcd.nal_type_is_irap(nal.type)
		if !s.seen_picture && !irap {
			hevcd.destroy_slice_header(&header)
			return .Codec_Error
		}
		if irap do s.skip_rasl = !s.seen_picture || hevcd.nal_type_is_idr(nal.type) || (nal.type >= .BLA_W_LP && nal.type <= .BLA_N_LP)
		s.seen_picture = true
		if s.skip_rasl && (nal.type == .RASL_N || nal.type == .RASL_R) {
			hevcd.destroy_slice_header(&header)
			return .None
		}
		s.hevc_pending, s.hevc_pending_type, s.hevc_pending_tid, s.has_hevc_pending = header, nal.type, nal.temporal_id, true
		append_annex_b(&s.au, s.hevc_vps_nal[sps.vps_id][:])
		append_annex_b(&s.au, s.hevc_sps_nal[sps.id][:])
		for has, id in s.has_hevc_pps {
			if has && s.hevc_pps[id].sps_id == sps.id {
				append_annex_b(&s.au, s.hevc_pps_nal[id][:])
			}
		}
		s.has_vcl = true
	} else {
		same_picture := s.has_hevc_pending && header.pps_id == s.hevc_pending.pps_id && (header.dependent_slice_segment || header.pic_order_cnt_lsb == s.hevc_pending.pic_order_cnt_lsb)
		hevcd.destroy_slice_header(&header)
		if !s.has_hevc_pending do return .None
		if !same_picture do return .Codec_Error
		if sps.ctb_log2_size_y == 4 && sps.sao_enabled && p.loop_filter_across_slices && !p.entropy_coding_sync {
			session.error_detail = "libavcodec HEVC loop filter across 16x16 CTB slices is non-conformant"
			return .Unsupported
		}
	}
	append_annex_b(&s.au, nal_bytes)
	return .None
}

@(private)
decode_avcodec :: proc(session: ^media.Session, packet: media.Packet, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	it := media.Nal_Iterator{packet = packet}
	for {
		nal, done, err := media.next_nal(&it)
		if err != .None do return err
		if done do return .None
		if session.config.codec == .H264 {
			decode_h264_nal(session, s, nal, receiver) or_return
		} else {
			decode_h265_nal(session, s, nal, receiver) or_return
		}
	}
}

@(private)
emit_encoded_packets :: proc(session: ^media.Session, s: ^State, receiver: media.Receiver) -> media.Error {
	api, _ := ensure_api()
	for {
		ret := api.avcodec_receive_packet(s.ctx, s.pkt)
		if ret < 0 do break
		defer api.av_packet_unref(s.pkt)
		if s.pkt.size <= 0 || s.pkt.data == nil do continue
		raw := s.pkt.data[:s.pkt.size]
		clear(&s.packet_buf)
		keyframe := false
		it := media.Nal_Iterator{packet = {data = raw, framing = .Annex_B}}
		for {
			nal, done, err := media.next_nal(&it)
			if err != .None || done do break
			append_annex_b(&s.packet_buf, nal)
			if session.config.codec == .H264 && len(nal) > 0 && (nal[0] & 0x1F) == 5 {
				keyframe = true
			} else if session.config.codec == .H265 && len(nal) >= 2 {
				t := (nal[0] >> 1) & 0x3F
				if t >= 16 && t <= 21 do keyframe = true
			}
		}
		if len(s.packet_buf) == 0 do return .Codec_Error
		if receiver.packet != nil {
			receiver.packet({data = s.packet_buf[:], framing = .Annex_B, keyframe = keyframe}, receiver.user)
		}
	}
	return .None
}

@(private)
encode_avcodec :: proc(session: ^media.Session, frame: media.Video_Frame, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	if frame.storage != .Host do return .Unsupported
	expected_storage := frame.bit_depth > 8 ? 16 : 8
	if frame.storage_bits != expected_storage do return .Unsupported
	api, _ := ensure_api()
	s.frame.format = s.pix_fmt
	s.frame.width = c.int(frame.width)
	s.frame.height = c.int(frame.height)
	if s.frame.data[0] == nil {
		if api.av_frame_get_buffer(s.frame, 0) < 0 do return .Codec_Error
	}
	if api.av_frame_make_writable(s.frame) < 0 do return .Codec_Error

	sw, sh := media.chroma_subsampling(frame.chroma)
	cw, ch := (frame.width + sw - 1) / sw, (frame.height + sh - 1) / sh
	sample_bytes := frame.storage_bits / 8
	limit := u16(1) << uint(frame.bit_depth)

	// Copy luma plane (and validate 16-bit samples).
	for y in 0 ..< frame.height {
		src := frame.planes[0].data[y * frame.planes[0].stride:][:frame.width * sample_bytes]
		if sample_bytes == 2 {
			for x in 0 ..< frame.width {
				val := u16(src[2 * x]) | u16(src[2 * x + 1]) << 8
				if val >= limit do return .Invalid_Input
			}
		}
		dst := s.frame.data[0][y * int(s.frame.linesize[0]):][:frame.width * sample_bytes]
		copy(dst, src)
	}

	if frame.chroma != .Monochrome {
		if frame.chroma_interleaved {
			if sample_bytes != 1 || frame.chroma != .YUV420 do return .Unsupported
			for y in 0 ..< ch {
				src := frame.planes[1].data[y * frame.planes[1].stride:][:2 * cw]
				dst_u := s.frame.data[1][y * int(s.frame.linesize[1]):][:cw]
				dst_v := s.frame.data[2][y * int(s.frame.linesize[2]):][:cw]
				for x in 0 ..< cw {
					dst_u[x], dst_v[x] = src[2 * x], src[2 * x + 1]
				}
			}
		} else {
			for p in 1 ..= 2 {
				for y in 0 ..< ch {
					src := frame.planes[p].data[y * frame.planes[p].stride:][:cw * sample_bytes]
					if sample_bytes == 2 {
						for x in 0 ..< cw {
							val := u16(src[2 * x]) | u16(src[2 * x + 1]) << 8
							if val >= limit do return .Invalid_Input
						}
					}
					dst := s.frame.data[p][y * int(s.frame.linesize[p]):][:cw * sample_bytes]
					copy(dst, src)
				}
			}
		}
	}

	set_frame_pts(api, s.frame, s.frame_index)
	s.frame_index += 1
	if api.avcodec_send_frame(s.ctx, s.frame) < 0 {
		session.error_detail = "libavcodec failed to encode video frame"
		return .Codec_Error
	}
	return emit_encoded_packets(session, s, receiver)
}

@(private)
drain_avcodec :: proc(session: ^media.Session, receiver: media.Receiver) -> media.Error {
	s := (^State)(session.state)
	api, _ := ensure_api()
	if session.config.operation == .Decode {
		if session.config.codec == .H264 {
			h264_finish_picture(session, s, receiver) or_return
			avcd.flush_output(&s.avc_syntax)
			h264_take_display(s)
		} else {
			h265_finish_picture(session, s, receiver) or_return
			for h265_bump(s) {}
		}
		_ = api.avcodec_send_packet(s.ctx, nil)
		return receive_decoded_frames(session, s, receiver)
	}
	_ = api.avcodec_send_frame(s.ctx, nil)
	return emit_encoded_packets(session, s, receiver)
}

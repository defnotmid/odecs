// Decodes a WebP file with webp and compares it with libwebp's dwebp
// output: RGBA against `dwebp -pam` (identical, or the PSNR), and for lossy
// images the planes against `dwebp -pgm` (Y, then U and V side by side, then
// alpha).
//
//   webp_decode in.webp [ref.pam|-] [ref.pgm|-] [repeat] [threads]
package main

import "../common"
import webp "../image/webp"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

fail :: proc(args: ..any) {
	fmt.eprintln(..args)
	os.exit(1)
}

// The raster after a PAM/PGM header (its last line: ENDHDR, or maxval).
raster :: proc(data: []u8) -> []u8 {
	if len(data) > 2 && string(data[:2]) == "P7" {
		at := strings.index(string(data), "ENDHDR\n")
		return data[at + 7:]
	}
	lines := 0
	for b, i in data {
		if b == '\n' {
			lines += 1
			if lines == 3 do return data[i + 1:]
		}
	}
	return nil
}

main :: proc() {
	if len(os.args) < 2 do fail("usage: webp_decode in.webp [ref.pam|-] [ref.pgm|-] [repeat] [threads]")
	data, rerr := os.read_entire_file(os.args[1], context.allocator)
	if rerr != nil do fail("cannot read", os.args[1])
	repeat := 1
	if len(os.args) > 4 do repeat, _ = strconv.parse_int(os.args[4])
	threads := 1
	if len(os.args) > 5 do threads, _ = strconv.parse_int(os.args[5])
	pool: common.Static_Pool
	work_pool: ^common.Work_Pool
	if threads > 1 {
		common.init_static_pool(&pool, threads - 1)
		work_pool = &pool.work_pool
	}
	defer if threads > 1 do common.destroy_static_pool(&pool)
	ft, ferr := webp.get_features(data)
	if ferr != .None do fail("features:", ferr)
	img: webp.Image
	err: webp.Error
	best := max(f64)
	for _ in 0 ..< max(repeat, 1) {
		if img.pixels != nil do webp.destroy_image(&img)
		start := time.now()
		img, err = webp.decode(data, work_pool)
		best = min(best, time.duration_milliseconds(time.since(start)))
		if err != .None do fail("decode:", err)
	}
	fmt.printf("%dx%d %s%s%s, %.3f ms%s", img.width, img.height, ft.lossless ? "lossless" : "lossy", ft.has_alpha ? " alpha" : "", ft.animated ? " animated" : "", best, threads > 1 ? fmt.tprintf(" (%d threads)", threads) : "")
	if len(os.args) > 2 && os.args[2] != "-" {
		ref_file, e := os.read_entire_file(os.args[2], context.allocator)
		if e != nil do fail("cannot read", os.args[2])
		ref := raster(ref_file)
		if len(ref) != len(img.pixels) do fail("; reference size", len(ref), "ours", len(img.pixels))
		max_diff := 0
		sse: f64
		for i in 0 ..< len(ref) {
			d := int(ref[i]) - int(img.pixels[i])
			max_diff = max(max_diff, abs(d))
			sse += f64(d * d)
		}
		if max_diff == 0 {
			fmt.print("; RGBA identical to dwebp")
		} else {
			fmt.printf("; RGBA vs dwebp max %d, PSNR %.2f dB", max_diff, 10 * math.log10(255 * 255 * f64(len(ref)) / sse))
		}
	}
	if len(os.args) > 3 && os.args[3] != "-" && !ft.lossless {
		ref_file, e := os.read_entire_file(os.args[3], context.allocator)
		if e != nil do fail("cannot read", os.args[3])
		ref := raster(ref_file)
		yuv, alpha, yerr := webp.decode_yuva(data)
		if yerr != .None do fail("; yuva:", yerr)
		// dwebp's layout: even-width rows of Y, then U and V side by side.
		w, h := yuv.width, yuv.height
		cw, ch := (w + 1) / 2, (h + 1) / 2
		pw := (w + 1) & ~int(1)
		ours := make([]u8, pw * (h + ch + (alpha != nil ? h : 0)))
		for y in 0 ..< h do copy(ours[y * pw:][:w], yuv.y[y * yuv.y_stride:][:w])
		for y in 0 ..< ch {
			copy(ours[(h + y) * pw:][:cw], yuv.u[y * yuv.uv_stride:][:cw])
			copy(ours[(h + y) * pw + cw:][:cw], yuv.v[y * yuv.uv_stride:][:cw])
		}
		if alpha != nil do for y in 0 ..< h do copy(ours[(h + ch + y) * pw:][:w], alpha[y * w:][:w])
		diffs := 0
		for i in 0 ..< min(len(ref), len(ours)) do if ref[i] != ours[i] do diffs += 1
		if len(ref) == len(ours) && diffs == 0 {
			fmt.print("; YUVA identical to dwebp")
		} else {
			fmt.printf("; YUVA differs: %d bytes (sizes %d, %d)", diffs, len(ref), len(ours))
		}
	}
	fmt.println()
}

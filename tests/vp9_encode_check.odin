// Native encoder + muxer oracle harness. No reference library is linked.
package vp9_encode_check

import encoder "../video/vp9/encoder"
import decoder "../video/vp9/decoder"
import webm "../container/webm"
import common "../common"
import video "../video"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import "core:math"

require :: proc(ok: bool, detail: string) {if !ok {fmt.eprintln(detail); os.exit(1)}}
number :: proc(s: string) -> int {v, ok := strconv.parse_int(s); require(ok, "invalid integer"); return v}

main :: proc() {
	if len(os.args) < 9 || len(os.args) > 11 {fmt.eprintln("usage: vp9_encode_check PREFIX WIDTH HEIGHT Q WORKERS FRAMES ALPHA animation|noise|flat [BLOCK_LOG2 [GOP]]"); os.exit(2)}
	prefix := os.args[1]
	w, h, q, workers, frames, alpha := number(os.args[2]), number(os.args[3]), number(os.args[4]), number(os.args[5]), number(os.args[6]), number(os.args[7]) != 0
	content := os.args[8]
	raw_source: []u8
	if content != "animation" && content != "noise" && content != "flat" {
		err: os.Error
		raw_source, err = os.read_entire_file(content, context.allocator)
		require(err == nil, "read raw camera source")
	}
	defer delete(raw_source)
	block_log2 := len(os.args) > 9 ? number(os.args[9]) : 3
	gop := len(os.args) > 10 ? number(os.args[10]) : 3
	require(frames > 0 && workers > 0, "positive frames and workers required")
	pool: common.Static_Pool
	common.init_static_pool(&pool, workers - 1)
	defer common.destroy_static_pool(&pool)
	e, ae: encoder.Encoder
	config := encoder.Encoder_Config{width = w, height = h, base_q_idx = q, keyframe_interval = gop, block_log2 = block_log2, tile_cols_log2 = 2, pool = &pool.work_pool}
	require(encoder.init_encoder(&e, config) == .None, "init colour")
	defer encoder.destroy_encoder(&e)
	if alpha do require(encoder.init_encoder(&ae, config) == .None, "init alpha")
	defer if alpha do encoder.destroy_encoder(&ae)
	input, ai: [3][]u8
	strides := [3]int{w, (w + 1) / 2, (w + 1) / 2}
	for p in 0 ..< 3 {
		ph := p == 0 ? h : (h + 1) / 2
		input[p] = make([]u8, strides[p] * ph)
		ai[p] = make([]u8, strides[p] * ph)
		if p > 0 do for &v in ai[p] do v = 128
	}
	defer for p in 0 ..< 3 {delete(input[p]); delete(ai[p])}
	cw, aw: webm.Writer
	save := prefix != "-"
	if save {
		require(webm.create(&cw, fmt.tprintf("%s.webm", prefix), {width = w, height = h, alpha = alpha, default_duration = 33_333_333}) == .None, "create WebM")
		if alpha {
			require(webm.create(&aw, fmt.tprintf("%s.alpha.webm", prefix), {width = w, height = h, default_duration = 33_333_333}) == .None, "create alpha oracle WebM")
		}
	}
	defer if save {webm.destroy(&cw); if alpha do webm.destroy(&aw)}
	source, rec, ar: [dynamic]u8
	defer {delete(source); delete(rec); delete(ar)}
	milliseconds: f64
	bytes: int
	sse: u64
	for f in 0 ..< frames {
		if len(raw_source) == 0 {
			generate(input, ai, strides, w, h, f, content)
		} else {
			frame_bytes := w * h + 2 * strides[1] * ((h + 1) / 2)
			require(len(raw_source) >= frame_bytes * frames, "short raw camera source")
			at := f * frame_bytes
			for p in 0 ..< 3 {copy(input[p], raw_source[at:][:len(input[p])]); at += len(input[p])}
			for &v in ai[0] do v = 255
		}
		if save do for plane in input do append(&source, ..plane)
		tick := time.tick_now()
		packet, key, err := encoder.encode_frame(&e, input, strides)
		milliseconds += time.duration_milliseconds(time.tick_since(tick))
		require(err == .None, "encode colour")
		bytes += len(packet)
		ap: []u8
		if alpha {
			tick = time.tick_now()
			ak: bool
			ap, ak, err = encoder.encode_frame(&ae, ai, strides)
			milliseconds += time.duration_milliseconds(time.tick_since(tick))
			require(err == .None && ak == key, "encode alpha/frame type")
			if save do require(webm.write_sample(&aw, ap, i64(f) * 33_333_333, key) == .None, "write alpha oracle")
		}
		if save do require(webm.write_sample(&cw, packet, i64(f) * 33_333_333, key, ap) == .None, "write colour + alpha")
		planes, rs := encoder.reconstruction(&e)
		for p in 0 ..< 3 {
			ph := p == 0 ? h : (h + 1) / 2
			for y in 0 ..< ph {
				row := planes[p][y * rs[p]:][:strides[p]]
				if save do append(&rec, ..row)
				for v, x in row {
					d := i64(v) - i64(input[p][y * strides[p] + x])
					sse += u64(d * d)
				}
			}
		}
		if alpha && save {
			planes, rs = encoder.reconstruction(&ae)
			for p in 0 ..< 3 {
				ph := p == 0 ? h : (h + 1) / 2
				for y in 0 ..< ph do append(&ar, ..planes[p][y * rs[p]:][:strides[p]])
			}
		}
	}
	pixels := (w * h + 2 * strides[1] * ((h + 1) / 2)) * frames
	psnr := sse == 0 ? math.inf_f64(1) : 10 * math.log10(255.0 * 255.0 * f64(pixels) / f64(sse))
	fmt.printfln("%dx%d q=%d workers=%d frames=%d alpha=%v content=%s bytes=%d PSNR=%.4f encode_ms=%.3f fps=%.3f", w, h, q, workers, frames, alpha, content, bytes, psnr, milliseconds, f64(frames) * 1000 / milliseconds)
	if save {
		require(webm.finish(&cw) == .None, "finish WebM")
		if alpha do require(webm.finish(&aw) == .None, "finish alpha WebM")
		require(os.write_entire_file(fmt.tprintf("%s.source.yuv", prefix), source[:]) == nil, "write source")
		require(os.write_entire_file(fmt.tprintf("%s.rec.yuv", prefix), rec[:]) == nil, "write reconstruction")
		if alpha {
			require(os.write_entire_file(fmt.tprintf("%s.alpha.rec.yuv", prefix), ar[:]) == nil, "write alpha reconstruction")
			luma: [dynamic]u8
			defer delete(luma)
			frame_bytes := w * h + 2 * strides[1] * ((h + 1) / 2)
			for f in 0 ..< frames do append(&luma, ..ar[f * frame_bytes:][:w * h])
			require(os.write_entire_file(fmt.tprintf("%s.alpha.luma", prefix), luma[:]) == nil, "write alpha luma")
		}
		verify(fmt.tprintf("%s.webm", prefix), rec[:], ar[:], w, h, frames, gop, alpha)
	}
}

generate :: proc(input, ai: [3][]u8, strides: [3]int, w, h, f: int, content: string) {
	for p in 0 ..< 3 {
		pw, ph := strides[p], p == 0 ? h : (h + 1) / 2
		for y in 0 ..< ph do for x in 0 ..< pw {
			v := p > 0 ? 128 : 16 + x * 180 / max(1, pw - 1)
			if content == "noise" {
				seed := u32(x * 137 + y * 977 + f * 113 + p * 859 + 1)
				seed ~= seed << 13; seed ~= seed >> 17; seed ~= seed << 5
				v = int(seed & 255)
			} else if content == "flat" {v = p > 0 ? 128 : 100} else if p == 0 {
				// Moving flat vector shape, one-pixel AA border, text-like strokes.
				dx, dy := abs(x - (w / 2 + f * 2)), abs(y - h / 2)
				if dx < w / 5 && dy < h / 4 do v = 210
				if y % 13 < 2 && x % 17 < 9 do v = 24
				ai[0][y * pw + x] = u8(clamp((min(w / 3 - dx, h / 3 - dy) + 2) * 64, 0, 255))
			}
			input[p][y * pw + x] = u8(v)
		}
	}
	if content != "animation" do for &v, i in ai[0] do v = u8((i + f * 13) & 255)
}

verify :: proc(path: string, expected, expected_alpha: []u8, w, h, frames, gop: int, alpha: bool) {
	r: webm.Reader
	require(webm.open(&r, path) == .None, "open own WebM")
	defer webm.close(&r)
	require(len(r.tracks) == 1 && len(r.tracks[0].samples) == frames && r.tracks[0].alpha == alpha, "WebM tracks/sample count/alpha")
	require(r.tracks[0].color.matrix_coeffs == 1 && r.tracks[0].color.range == 1, "WebM BT.709 limited")
	d, ad: decoder.Decoder
	decoder.init_decoder(&d); decoder.init_decoder(&ad)
	defer {decoder.destroy_decoder(&d); decoder.destroy_decoder(&ad)}
	mr: video.Reader
	require(video.open_reader(&mr, path, {preference = .Native, format = .Planar}) == .None, "movie open")
	defer video.close_reader(&mr)
	require(mr.video.has_alpha == alpha, "movie alpha metadata")
	at := 0
	for f in 0 ..< frames {
		packet, err := webm.read_sample(&r, 0, f)
		require(err == .None && packet.sync == (f % gop == 0), "read packet/keyframe")
		pic, shown, de := decoder.decode_packet(&d, packet.data)
		require(de == .None && shown, "native decode colour")
		frame, me := video.next_frame(&mr)
		require(me == .None, "movie decode")
		ap: decoder.Picture
		if alpha {
			ap, shown, de = decoder.decode_packet(&ad, packet.additional)
			require(de == .None && shown, "native decode alpha")
		}
		for p in 0 ..< 3 {
			pw, ph := p == 0 ? w : (w + 1) / 2, p == 0 ? h : (h + 1) / 2
			for y in 0 ..< ph {
				require(string(pic.planes8[p][y * pic.strides[p]:][:pw]) == string(expected[at:][:pw]), "decoder != encoder reconstruction")
				require(string(frame.planar.planes[p][y * pw:][:pw]) == string(expected[at:][:pw]), "movie != encoder reconstruction")
				if alpha {
					require(string(ap.planes8[p][y * ap.strides[p]:][:pw]) == string(expected_alpha[at:][:pw]), "alpha decoder != encoder reconstruction")
					if p == 0 do require(string(frame.planar.alpha[y * pw:][:pw]) == string(expected_alpha[at:][:pw]), "movie alpha != encoder reconstruction")
				}
				at += pw
			}
		}
	}
	_, end := video.next_frame(&mr)
	require(end == .End_Of_Stream, "movie frame count")
}

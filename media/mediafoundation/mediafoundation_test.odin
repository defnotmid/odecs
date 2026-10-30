package media_mediafoundation

import media ".."
import "core:log"
import "core:math"
import "core:testing"

@(private = "file")
Capture :: struct {
	stream: [dynamic]u8,
	luma:   [dynamic][]u8,
	sizes:  [dynamic][2]int,
}

@(private = "file")
on_packet :: proc(p: media.Packet, user: rawptr) {
	append(&(^Capture)(user).stream, ..p.data)
}

@(private = "file")
on_frame :: proc(f: media.Video_Frame, user: rawptr) {
	c := (^Capture)(user)
	y := make([]u8, f.width * f.height)
	for row in 0 ..< f.height do copy(y[row * f.width:][:f.width], f.planes[0].data[row * f.planes[0].stride:][:f.width])
	append(&c.luma, y)
	append(&c.sizes, [2]int{f.width, f.height})
}

// Off Windows the provider reports itself unavailable. On Windows with Media
// Foundation, H.264 through Microsoft's encoder and back through its decoder
// keeps every frame, its size, and the picture.
@(test)
test_h264_round_trip :: proc(t: ^testing.T) {
	W, H, FRAMES :: 320, 240, 30
	encode := media.default_config(.H264, .Encode)
	encode.width, encode.height, encode.qp = W, H, 20
	encode.frame_rate_num, encode.frame_rate_den = 30, 1
	available := probe(encode, nil)
	when ODIN_OS != .Windows {
		testing.expect_value(t, available, media.Error.Unavailable)
		return
	}
	if available != .None {
		log.infof("Media Foundation H.264 encoding unavailable here (%v)", available)
		return
	}
	log.info("Media Foundation H.264 encoding available")
	providers := []media.Provider{provider()}
	c: Capture
	defer {
		delete(c.stream)
		for y in c.luma do delete(y)
		delete(c.luma)
		delete(c.sizes)
	}
	source := make([]u8, W * H * 3 / 2)
	defer delete(source)
	sources: [FRAMES][]u8
	defer for s in sources do delete(s)

	session: media.Session
	testing.expect_value(t, media.open(&session, encode, providers), media.Error.None)
	for i in 0 ..< FRAMES {
		for y in 0 ..< H do for x in 0 ..< W do source[y * W + x] = u8((x + 2 * y + 3 * i) & 0xff)
		for j in W * H ..< len(source) do source[j] = 128
		sources[i] = make([]u8, W * H)
		copy(sources[i], source[:W * H])
		frame := media.Video_Frame {
			width        = W,
			height       = H,
			bit_depth    = 8,
			storage_bits = 8,
			chroma       = .YUV420,
			storage      = .Host,
			planes       = {{source[:W * H], W}, {source[W * H:][:W * H / 4], W / 2}, {source[W * H * 5 / 4:], W / 2}},
		}
		testing.expect_value(t, media.encode_video(&session, frame, {packet = on_packet, user = &c}), media.Error.None)
	}
	testing.expect_value(t, media.drain(&session, {packet = on_packet, user = &c}), media.Error.None)
	media.close(&session)
	testing.expect(t, len(c.stream) > 0)

	decode := media.default_config(.H264, .Decode)
	decode.width, decode.height = W, H
	testing.expect_value(t, probe(decode, nil), media.Error.None)
	testing.expect_value(t, media.open(&session, decode, providers), media.Error.None)
	receiver := media.Receiver{video = on_frame, user = &c}
	if e := media.decode(&session, {data = c.stream[:], framing = .Annex_B}, receiver); e != .None do log.errorf("decode: %v %s", e, session.error_detail)
	testing.expect_value(t, media.drain(&session, receiver), media.Error.None)
	media.close(&session)

	testing.expect_value(t, len(c.luma), FRAMES)
	for y, i in c.luma {
		if i >= FRAMES do break
		testing.expect_value(t, c.sizes[i], [2]int{W, H})
		error: f64
		for v, j in y {d := f64(v) - f64(sources[i][j]); error += d * d}
		psnr := 10 * math.log10(255 * 255 / max(error / f64(len(y)), 1e-9))
		testing.expectf(t, psnr > 30, "frame %d: luma PSNR %.2f dB", i, psnr)
	}
}

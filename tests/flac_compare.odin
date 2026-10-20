// Decodes a native .flac file with flac and checks it three ways: the
// MD5 of the decoded samples against the one in streaminfo (the encoder's
// own checksum, RFC 9639 section 8.2), the samples as f32 against FFmpeg's
// decode, and random seeks against the sequential decode. Reports decode
// speed.
//
//   odin build tests/flac_compare.odin -file -o:speed -out:/tmp/odecs-flac-compare
//   /tmp/odecs-flac-compare FILE.flac [ORACLE.f32|-]
package flac_compare

import flac "../audio/flac"
import "core:crypto/legacy/md5"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:time"

fail :: proc(args: ..any) {
	fmt.eprintln(..args)
	os.exit(1)
}

main :: proc() {
	if len(os.args) < 2 do fail("usage: flac_compare FILE.flac [ORACLE.f32|-]")
	r: flac.Reader
	if e := flac.open(&r, os.args[1]); e != .None do fail("open", e)
	defer flac.close(&r)
	info := r.info
	d: flac.Decoder
	flac.init_decoder(&d, info)
	defer flac.destroy_decoder(&d)

	// Decode everything once, timed, keeping f32 and the MD5 input.
	pcm: [dynamic]f32
	hash: md5.Context
	md5.init(&hash)
	bytes := (info.bits + 7) / 8
	frames, samples := 0, i64(0)
	scratch: [dynamic]f32
	le: [dynamic]u8
	start := time.tick_now()
	decode_time: time.Duration
	for {
		p, e := flac.read_frame(&r)
		if e == .End_Of_Stream do break
		if e != .None do fail("read_frame", frames, e)
		t0 := time.tick_now()
		f, _, de := flac.decode_frame(&d, p.data)
		decode_time += time.tick_since(t0)
		if de != .None do fail("decode_frame", frames, "at", p.offset, de)
		if p.first_sample != samples do fail("frame", frames, "starts at sample", p.first_sample, "expected", samples)
		n, ch := f.header.block_size, f.header.channels
		resize(&scratch, n * ch)
		flac.interleave_f32(f, scratch[:])
		append(&pcm, ..scratch[:])
		clear(&le)
		for i in 0 ..< n do for c in 0 ..< ch {
			v := f.planes[c][i]
			for k in 0 ..< bytes do append(&le, u8(v >> uint(8 * k)))
		}
		md5.update(&hash, le[:])
		frames += 1
		samples += i64(n)
	}
	elapsed := time.duration_seconds(time.tick_since(start))
	digest: [16]u8
	md5.final(&hash, digest[:])
	seconds := f64(samples) / f64(info.sample_rate)
	fmt.printfln("%s: %d Hz %d ch %d bits, %d frames, %d samples (streaminfo %d)", os.args[1], info.sample_rate, info.channels, info.bits, frames, samples, info.total_samples)
	fmt.printfln("  decode: %.0fx real time (%.1f ms for %.1f s), read+decode %.0fx", seconds / time.duration_seconds(decode_time), time.duration_milliseconds(decode_time), seconds, seconds / elapsed)
	if info.total_samples != 0 && samples != info.total_samples do fail("sample count differs from streaminfo")
	zero: [16]u8
	if info.md5 == zero {
		fmt.println("  md5: not stored")
	} else if digest == info.md5 {
		fmt.println("  md5: matches streaminfo")
	} else {
		fail("  md5: MISMATCH")
	}

	if len(os.args) > 2 && os.args[2] != "-" {
		data, err := os.read_entire_file(os.args[2], context.allocator)
		if err != nil do fail("cannot read", os.args[2])
		want := ([^]f32)(raw_data(data))[:len(data) / 4]
		worst: f32
		for i in 0 ..< min(len(want), len(pcm)) do worst = max(worst, abs(want[i] - pcm[i]))
		fmt.printfln("  vs FFmpeg: %d values (FFmpeg %d), max difference %g", len(pcm), len(want), worst)
		if len(want) != len(pcm) || worst != 0 do fail("  differs from FFmpeg")
	}

	// Seeks: the frame found for a random sample must hold it and decode to
	// the same values as the sequential pass.
	ch := info.channels
	worst_ms: f64
	for k in 0 ..< 50 {
		target := k == 0 ? samples - 1 : i64(rand.int63_max(max(samples, 1)))
		t0 := time.tick_now()
		if e := flac.seek(&r, target); e != .None do fail("seek", target, e)
		p, e := flac.read_frame(&r)
		worst_ms = max(worst_ms, time.duration_milliseconds(time.tick_since(t0)))
		if e != .None do fail("read after seek", target, e)
		if target < p.first_sample || target >= p.first_sample + i64(p.block_size) do fail("seek", target, "landed on", p.first_sample, p.block_size)
		f, _, de := flac.decode_frame(&d, p.data)
		if de != .None do fail("decode after seek", de)
		resize(&scratch, f.header.block_size * ch)
		flac.interleave_f32(f, scratch[:])
		base := int(p.first_sample) * ch
		for v, i in scratch do if v != pcm[base + i] do fail("seek", target, "decoded differently")
	}
	fmt.printfln("  seeks: 50 random, all exact, worst %.2f ms", worst_ms)
}

// The audio package's sample types on real files: i16 against common.to_i16
// of the f32 decode (equal where f32 holds the source exactly), the channel
// limit against the first channels of the full decode, and Reader reads
// mixing the two types against both.
//   odin run tests/audio_types_check.odin -file -o:speed -- file...
package audio_types_check

import audio "../audio"
import common "../common"
import "core:bytes"
import "core:fmt"
import "core:os"
import "core:slice"

main :: proc() {
	failed := 0
	for path in os.args[1:] {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil do continue
		defer delete(data)
		full, e := audio.decode(data)
		defer audio.destroy_audio(&full)
		if e != .None {fmt.println(path, "decode", e); continue}
		ch := full.channels
		frames := len(full.samples) / ch
		i, _ := audio.info(data)
		s16 := make([]i16, len(full.samples))
		defer delete(s16)
		n, e16 := audio.decode_into(data, s16)
		mismatch := 0
		for x, k in full.samples do if common.to_i16(x) != s16[k] do mismatch += 1
		// Kept channels: the first two (or one) of the full decode.
		keep := ch > 2 ? 2 : 1
		k32 := make([]f32, frames * keep)
		k16 := make([]i16, frames * keep)
		defer {delete(k32); delete(k16)}
		n32, _ := audio.decode_into(data, k32, keep)
		n16, _ := audio.decode_into(data, k16, keep)
		kept_ok := n32 == frames && n16 == frames
		for f in 0 ..< frames do for c in 0 ..< keep {
			if k32[f * keep + c] != full.samples[f * ch + c] || k16[f * keep + c] != s16[f * ch + c] do kept_ok = false
		}
		// Mixed reads through one Reader.
		reader: bytes.Reader
		bytes.reader_init(&reader, data)
		r: audio.Reader
		audio.open_stream(&r, bytes.reader_to_stream(&reader))
		mixed_ok := true
		at := 0
		a32: [3001 * 8]f32
		a16: [1777 * 8]i16
		for step := 0; at < frames; step += 1 {
			got: int
			if step % 2 == 0 {
				got, _ = audio.read(&r, a32[:3001 * ch])
				if !slice.equal(a32[:got * ch], full.samples[at * ch:][:got * ch]) do mixed_ok = false
			} else {
				got, _ = audio.read(&r, a16[:1777 * ch])
				if !slice.equal(a16[:got * ch], s16[at * ch:][:got * ch]) do mixed_ok = false
			}
			if got == 0 {mixed_ok = false; break}
			at += got
		}
		audio.close(&r)
		ok := e16 == .None && n == frames && kept_ok && mixed_ok
		if !ok do failed += 1
		fmt.printfln("%-52s %-6v %dch %8d frames  i16!=to_i16(f32): %-6d kept: %v mixed: %v loop: %v %s", path, i.codec, ch, frames, mismatch, kept_ok, mixed_ok, i.loop, ok ? "ok" : "FAILED")
	}
	fmt.println(failed == 0 ? "all ok" : "FAILED")
	if failed != 0 do os.exit(1)
}

package main

import h265 "../codec/h265/decoder"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

// Resident input, complete decode/flush/drain. No output-file I/O in the timer.
// Usage: decode_timing_h265 <in.265> <expected_frames>
main :: proc() {
	if len(os.args) !=
	   3 {fmt.eprintln("usage: decode_timing_h265 stream.265 expected_frames"); os.exit(2)}

	expected, ok := strconv.parse_int(os.args[2])
	if !ok || expected <= 0 do os.exit(2)

	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {fmt.eprintln("cannot read stream:", err); os.exit(1)}
	defer delete(data)

	times: [7]f64

	for r in 0 ..< len(times) {
		t := time.tick_now()
		pics, good := h265.decode_annex_b(data)
		times[r] = time.duration_milliseconds(time.tick_since(t))

		if !good {fmt.eprintln("decode failed"); os.exit(1)}
		if len(pics) != expected {
			fmt.eprintfln("decoded %d frames, expected %d", len(pics), expected)
			os.exit(1)
		}

		for p in pics {
			h265.destroy_picture(p)
			free(p)
		}

		delete(pics)
	}

	slice.sort(times[:])
	fmt.printfln(
		"oicu h265 decode: frames=%d codec_ms=%.3f fps=%.1f min_ms=%.3f max_ms=%.3f",
		expected,
		times[3],
		f64(expected) * 1000 / times[3],
		times[0],
		times[6],
	)
}

package main
import h264 "../h264"
import avc_dec "../h264/decoder"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

// Resident input, complete decode/flush/drain. No output-file I/O in the timer.
main :: proc() {
	if len(os.args) !=
	   3 {fmt.eprintln("usage: decode_timing stream.264 expected_frames"); os.exit(2)}
	expected, ok := strconv.parse_int(os.args[2])
	if !ok || expected <= 0 do os.exit(2)
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {fmt.eprintln("cannot read stream:", err); os.exit(1)}
	defer delete(data)
	nals := h264.find_nal_units(data)
	defer delete(nals)
	times, init_times: [7]f64
	for r in 0 ..< len(times) {
		st: avc_dec.Decoder_State
		t := time.tick_now()
		avc_dec.init_decoder(&st)
		init_times[r] = time.duration_milliseconds(time.tick_since(t))
		count := 0
		t = time.tick_now()
		for loc in nals {
			ready, err := avc_dec.decode_nal(&st, data[loc.offset:loc.offset + loc.length])
			if err != .None {fmt.eprintln("decode failed:", err); os.exit(1)}
			if ready do for p := st.output; p != nil; p = avc_dec.next_output_frame(&st) do count += 1
		}
		if avc_dec.flush_decoder(&st) do for p := st.output; p != nil; p = avc_dec.next_output_frame(&st) do count += 1
		times[r] = time.duration_milliseconds(time.tick_since(t))
		avc_dec.destroy_decoder(&st)
		if count !=
		   expected {fmt.eprintfln("decoded %d frames, expected %d", count, expected); os.exit(1)}
	}
	slice.sort(times[:])
	slice.sort(init_times[:])
	fmt.printfln(
		"oicu decode: frames=%d workers=1 init_ms=%.3f codec_ms=%.3f fps=%.1f min_ms=%.3f max_ms=%.3f (includes EOS drain and lazy picture allocation)",
		expected,
		init_times[3],
		times[3],
		f64(expected) * 1000 / times[3],
		times[0],
		times[6],
	)
}

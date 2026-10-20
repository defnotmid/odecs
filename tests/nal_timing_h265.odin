package main

import h265 "../video/h265/decoder"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

HAS_SCRATCH :: #config(HAS_SCRATCH, false)
Nal_Range :: struct {
	start, end: int,
}

start_code :: proc(data: []u8, off: int) -> (payload, start: int, good: bool) {
	for i := off; i + 2 < len(data); i += 1 {
		if data[i] != 0 || data[i + 1] != 0 do continue
		if data[i + 2] == 1 do return i + 3, i, true
		if i + 3 < len(data) && data[i + 2] == 0 && data[i + 3] == 1 do return i + 4, i, true
	}
	return 0, 0, false
}

// Resident NAL parsing only: file reads and start-code indexing are outside
// the timer. Both modes include parser allocations/destruction; scratch mode
// retains capacity across repetitions within a round. Each round parses the
// complete indexed stream the requested number of times and checks its count.
main :: proc() {
	if len(os.args) !=
	   4 {fmt.eprintln("usage: nal_timing_h265 stream.265 repeats owned|scratch"); os.exit(2)}
	repeats, good := strconv.parse_int(os.args[2])
	if !good || repeats <= 0 do os.exit(2)
	scratch_mode := os.args[3] == "scratch"
	if os.args[3] != "owned" && !scratch_mode do os.exit(2)
	when !HAS_SCRATCH {
		if scratch_mode {fmt.eprintln("build with -define:HAS_SCRATCH=true"); os.exit(2)}
	}
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {fmt.eprintln(err); os.exit(1)}
	defer delete(data)
	ranges: [dynamic]Nal_Range
	defer delete(ranges)
	pos, _, found := start_code(data, 0)
	if !found do os.exit(1)
	for pos < len(data) {
		next, end, more := start_code(data, pos)
		if !more do end = len(data)
		for end > pos && data[end - 1] == 0 do end -= 1
		if end > pos do append(&ranges, Nal_Range{pos, end})
		if !more do break
		pos = next
	}
	times: [7]f64
	checksum: u64
	for round in 0 ..< len(times) {
		count: int
		start := time.tick_now()
		when HAS_SCRATCH {
			if scratch_mode {
				scratch: h265.Nal_Scratch
				for _ in 0 ..< repeats do for r in ranges {
					n, ok := h265.parse_nal_into(data[r.start:r.end], &scratch)
					if !ok do os.exit(1)
					checksum += u64(len(n.rbsp)) + u64(len(n.epb)) + u64(n.type)
					count += 1
				}
				h265.destroy_nal_scratch(&scratch)
			} else {
				for _ in 0 ..< repeats do for r in ranges {
					n, ok := h265.parse_nal(data[r.start:r.end])
					if !ok do os.exit(1)
					checksum += u64(len(n.rbsp)) + u64(len(n.epb)) + u64(n.type)
					count += 1
					h265.destroy_nal(&n)
				}
			}
		} else {
			for _ in 0 ..< repeats do for r in ranges {
				n, ok := h265.parse_nal(data[r.start:r.end])
				if !ok do os.exit(1)
				checksum += u64(len(n.rbsp)) + u64(len(n.epb)) + u64(n.type)
				count += 1
				h265.destroy_nal(&n)
			}
		}
		times[round] = time.duration_milliseconds(time.tick_since(start))
		if count != repeats * len(ranges) do os.exit(1)
	}
	slice.sort(times[:])
	fmt.printfln(
		"h265 NAL parse: mode=%s bytes=%d nals=%d repeats=%d median_ms=%.3f min_ms=%.3f max_ms=%.3f checksum=%d",
		os.args[3],
		len(data),
		len(ranges),
		repeats,
		times[3],
		times[0],
		times[6],
		checksum,
	)
}

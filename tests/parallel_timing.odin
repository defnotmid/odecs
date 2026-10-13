package main

import common "../codec/common"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

// Cheap native data traversal isolates range dispatch from codec arithmetic.
// Usage: parallel_timing elements workers maps [output.u64]
// Persistent pool, input/output allocation and checks are outside the timer.
// Each map overwrites disjoint output ranges without an assembly/merge pass.
Batch :: struct {
	input, output: []u64,
}

value_for :: #force_inline proc(value: u64) -> u64 {
	return (value * 0x9e3779b97f4a7c15) ~ (value >> 13)
}

process_range :: proc(data: rawptr, first, end: int) {
	b := cast(^Batch)data
	input, output := b.input[first:end], b.output[first:end]
	for value, i in input do output[i] = value_for(value)
}

integer :: proc(text: string) -> int {
	value, ok := strconv.parse_int(text)
	if !ok do os.exit(2)
	return value
}

main :: proc() {
	if len(os.args) != 4 && len(os.args) != 5 {
		fmt.eprintln("usage: parallel_timing elements workers maps [output.u64]")
		os.exit(2)
	}
	count, workers, maps := integer(os.args[1]), integer(os.args[2]), integer(os.args[3])
	if count <= 0 || count > 1 << 26 || workers < 1 || workers > common.MAX_STATIC_POOL_THREADS + 1 || maps <= 0 do os.exit(2)
	b := Batch {
		input  = make([]u64, count),
		output = make([]u64, count),
	}
	defer delete(b.input)
	defer delete(b.output)
	for &value, i in b.input do value = u64(i + 1) * 0x1000193
	p: common.Static_Pool
	common.init_static_pool(&p, workers - 1)
	defer common.destroy_static_pool(&p)
	times: [7]f64
	for &elapsed in times {
		start := time.tick_now()
		for _ in 0 ..< maps do p.work_pool.run(&p.work_pool, count, process_range, &b)
		elapsed = time.duration_milliseconds(time.tick_since(start))
		for value, i in b.input do assert(b.output[i] == value_for(value))
	}
	if len(os.args) == 5 {
		if err := os.write_entire_file(os.args[4], transmute([]u8)b.output); err != nil do os.exit(1)
	}
	slice.sort(times[:])
	fmt.printfln(
		"range traversal: elements=%d workers=%d maps=%d codec_ms=%.3f ns_per_element=%.3f min_ms=%.3f max_ms=%.3f bytes=%d",
		count,
		workers,
		maps,
		times[3],
		times[3] * 1e6 / f64(count) / f64(maps),
		times[0],
		times[6],
		count * size_of(u64),
	)
}

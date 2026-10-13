#+build linux
package benchmark_support

import common "../../codec/common"
import "core:fmt"
import "core:os"
import "core:sys/linux"

@(private)
CPU_LIMIT :: 1024
@(private)
CPU_Mask :: [CPU_LIMIT / 64]u64
@(private)
Pin_Slot :: struct {
	cpu:     int,
	err:     Pin_Error,
	visited: bool,
}
@(private)
Pin_Request :: struct {
	allowed: CPU_Mask,
	slots:   [common.MAX_STATIC_POOL_THREADS + 1]Pin_Slot,
}

// Call once after constructing a persistent Static_Pool(workers-1), before
// encoder initialization or timing. A nil pool is the one-worker serial case.
// All slots start with the caller's original permitted mask; this synchronous
// one-item-per-slot map pins caller slot zero and each persistent worker once.
// It allocates no task storage and performs no work when VIDEO_CPUS is unset.
pin_video_cpus :: proc(pool: ^common.Work_Pool, workers: int) -> Pin_Error {
	if workers < 1 || workers > common.MAX_STATIC_POOL_THREADS + 1 do return .Invalid_Worker_Count
	cpus, present := os.lookup_env("VIDEO_CPUS", context.allocator)
	defer delete(cpus)
	if !present do return .None
	if pool == nil && workers != 1 || pool != nil && pool.run == nil do return .Slot_Mapping

	request: Pin_Request
	bytes, affinity_error := linux.sched_getaffinity(0, size_of(request.allowed), &request.allowed)
	if affinity_error != nil || bytes <= 0 || bytes > size_of(request.allowed) do return .Affinity_Unavailable

	// Validate the complete list against the original mask before any slot is
	// pinned. Decimal accumulation is bounded before multiplication/addition.
	start, slot := 0, 0
	for end in 0 ..= len(cpus) {
		if end < len(cpus) && cpus[end] != ',' do continue
		if start == end || slot >= workers do return .Invalid_CPU_List
		cpu := 0
		for digit in cpus[start:end] {
			if digit < '0' || digit > '9' || cpu > (CPU_LIMIT - 1 - int(digit - '0')) / 10 do return .Invalid_CPU_List
			cpu = cpu * 10 + int(digit - '0')
		}
		if request.allowed[cpu / 64] & (u64(1) << uint(cpu % 64)) == 0 do return .CPU_Not_Allowed
		for previous in 0 ..< slot do if request.slots[previous].cpu == cpu do return .Duplicate_CPU
		request.slots[slot].cpu = cpu
		slot += 1
		start = end + 1
	}
	if slot != workers do return .Invalid_CPU_List

	if pool == nil {
		pin_slot_range(&request, 0, workers)
	} else {
		pool.run(pool, workers, pin_slot_range, &request)
	}
	for selected in request.slots[:workers] {
		if selected.err != .None do return selected.err
		if !selected.visited do return .Slot_Mapping
	}
	fmt.printfln("VIDEO_CPUS: placement=pinned_slots cpus=%s", cpus)
	return .None
}

@(private)
pin_slot_range :: proc(data: rawptr, first, end: int) {
	p := (^Pin_Request)(data)
	if end - first != 1 {
		for &slot in p.slots[first:end] do slot.err = .Slot_Mapping
		return
	}
	slot := &p.slots[first]
	if slot.visited {slot.err = .Slot_Mapping; return}
	slot.visited = true
	before: CPU_Mask
	bytes, err := linux.sched_getaffinity(0, size_of(before), &before)
	if err != nil ||
	   bytes <= 0 ||
	   bytes > size_of(before) {slot.err = .Affinity_Unavailable; return}
	if before != p.allowed {slot.err = .Affinity_Changed; return}
	mask: CPU_Mask
	mask[slot.cpu / 64] = u64(1) << uint(slot.cpu % 64)
	_, err = linux.sched_setaffinity(0, size_of(mask), &mask)
	if err != nil {slot.err = .Affinity_Unavailable; return}
	actual: CPU_Mask
	bytes, err = linux.sched_getaffinity(0, size_of(actual), &actual)
	if err != nil ||
	   bytes <= 0 ||
	   bytes > size_of(actual) {slot.err = .Affinity_Unavailable; return}
	if actual != mask do slot.err = .Affinity_Changed
}

package common

import "base:intrinsics"
import "core:sync"
import "core:testing"

@(private)
Parallel_Probe_Item :: struct {
	visits: int,
	owner:  int,
	value:  u64,
	calls:  int,
	end:    int,
}

@(private)
Parallel_Probe :: struct {
	items: []Parallel_Probe_Item,
	salt:  u64,
}

@(private)
parallel_probe_range :: proc(data: rawptr, first, end: int) {
	p := cast(^Parallel_Probe)data
	if first < 0 || first >= end || end > len(p.items) do panic("invalid pool range")
	intrinsics.atomic_add(&p.items[first].calls, 1)
	intrinsics.atomic_store(&p.items[first].end, end)
	for &item, offset in p.items[first:end] {
		i := first + offset
		// Duplicate execution is a counted failure rather than a test race.
		// Production range traversal needs no per-element atomics.
		intrinsics.atomic_add(&item.visits, 1)
		intrinsics.atomic_store(&item.owner, sync.current_thread_id())
		intrinsics.atomic_store(&item.value, (u64(i) * 0x1000193) ~ p.salt)
	}
}

// Independent quotient/remainder expression for the required balanced range
// owner. It does not read the pool's boundary array or worker descriptors.
@(private)
parallel_expected_slot :: proc(index, count, slots: int) -> int {
	active := min(count, slots)
	width, wide := count / active, count % active
	wide_items := wide * (width + 1)
	if index < wide_items do return index / (width + 1)
	return wide + (index - wide_items) / width
}

@(private)
parallel_probe_map :: proc(
	t: ^testing.T,
	p: ^Static_Pool,
	count: int,
	salt: u64,
	owners: ^[MAX_STATIC_POOL_THREADS + 1]int,
	establish: bool = false,
) {
	GUARD :: u64(0xf18d3e047ac962b5)
	storage: [134]Parallel_Probe_Item
	for &item in storage do item.value = GUARD
	probe := Parallel_Probe {
		items = storage[3:131],
		salt  = salt,
	}
	p.work_pool.run(&p.work_pool, count, parallel_probe_range, &probe)
	slots := p.started ? p.n_threads + 1 : 1
	for item, physical in storage {
		index := physical - 3
		active := index >= 0 && index < count
		if !active {
			testing.expectf(
				t,
				item.visits == 0 &&
				item.owner == 0 &&
				item.value == GUARD &&
				item.calls == 0 &&
				item.end == 0,
				"parallel write outside active range: count=%d physical=%d",
				count,
				physical,
			)
			continue
		}
		testing.expectf(
			t,
			item.visits == 1,
			"parallel item count: count=%d index=%d visits=%d",
			count,
			index,
			item.visits,
		)
		testing.expectf(
			t,
			item.value == ((u64(index) * 0x1000193) ~ salt),
			"parallel result/publication: count=%d index=%d",
			count,
			index,
		)
		slot := parallel_expected_slot(index, count, slots)
		active_slots := min(count, slots)
		width, wide := count / active_slots, count % active_slots
		first := slot * width + min(slot, wide)
		end := first + width + (slot < wide ? 1 : 0)
		testing.expectf(
			t,
			item.calls == (index == first ? 1 : 0) && item.end == (index == first ? end : 0),
			"parallel callback must own one complete range: count=%d index=%d calls=%d end=%d expected=%d..<%d",
			count,
			index,
			item.calls,
			item.end,
			first,
			end,
		)
		if establish && owners[slot] == 0 do owners[slot] = item.owner
		testing.expectf(
			t,
			item.owner == owners[slot],
			"parallel unstable/wrong thread owner: count=%d index=%d slot=%d got=%d want=%d",
			count,
			index,
			slot,
			item.owner,
			owners[slot],
		)
	}
}

@(test)
test_static_pool_fixed_range_ownership :: proc(t: ^testing.T) {
	p: Static_Pool
	init_static_pool(&p, 3)
	defer destroy_static_pool(&p)
	owners: [MAX_STATIC_POOL_THREADS + 1]int
	owners[0] = sync.current_thread_id()
	parallel_probe_map(t, &p, 127, 0x4281, &owners, establish = true)
	for slot in 0 ..< 4 {
		testing.expect(t, owners[slot] != 0)
		for other in 0 ..< slot do testing.expectf(t, owners[slot] != owners[other], "parallel slots share one thread: slot=%d other=%d", slot, other)
	}
	// Same full map recurs among smaller/larger counts; dormant slots must keep
	// their identity and must not leave a stale hand-off or completion behind.
	for round in 0 ..< 6 {
		for count in ([13]int{127, 0, 1, 2, 3, 4, 5, 7, 13, 31, 64, 97, 127}) {
			parallel_probe_map(t, &p, count, u64(round * 257 + count), &owners)
		}
	}
}

@(test)
test_static_pool_serial_and_inactive_maps :: proc(t: ^testing.T) {
	p: Static_Pool
	// Preserve the existing map's serial fallback before initialization and
	// after shutdown. The caller-owned Work_Pool is still at a stable address.
	p.work_pool = {
		run  = static_pool_map,
		user = &p,
	}
	owners: [MAX_STATIC_POOL_THREADS + 1]int
	owners[0] = sync.current_thread_id()
	for count in ([5]int{0, 1, 2, 31, 127}) do parallel_probe_map(t, &p, count, 17, &owners)
	init_static_pool(&p, 0)
	testing.expect(t, p.started && p.n_threads == 0)
	for count in ([5]int{127, 1, 0, 17, 127}) do parallel_probe_map(t, &p, count, 29, &owners)
	destroy_static_pool(&p)
	destroy_static_pool(&p)
	for count in ([4]int{0, 1, 7, 127}) do parallel_probe_map(t, &p, count, 41, &owners)
}

@(test)
test_static_pool_shutdown_and_reinitialize :: proc(t: ^testing.T) {
	p: Static_Pool
	for threads in ([6]int{3, 0, 1, 4, 2, 0}) {
		init_static_pool(&p, threads)
		owners: [MAX_STATIC_POOL_THREADS + 1]int
		owners[0] = sync.current_thread_id()
		parallel_probe_map(t, &p, 127, u64(threads + 51), &owners, establish = true)
		for count in ([5]int{0, 1, 2, 19, 127}) do parallel_probe_map(t, &p, count, 73, &owners)
		destroy_static_pool(&p)
		testing.expect(t, !p.started && !p.running)
	}
}

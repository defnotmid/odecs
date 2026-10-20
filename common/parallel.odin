package common

import "core:sync"
import "core:thread"

// ---------------------------------------------------------------------------
// Work_Pool is the codec's view of the caller's parallelism. The pool is
// always passed in by the caller — the codecs never create, own or join
// threads on their own, so scheduling and contention with the rest of the
// application stay the caller's business.
//
// `run` partitions 0 ..< count into nonempty, disjoint contiguous ranges and
// calls `task(data, first, end)` once per range. It returns only after all
// ranges finish. The callback forms a typed slice over its range and traverses
// it locally: no scheduler callback, allocation or atomic per element.
// Elements are independent and write only their preallocated owned state.
// The descriptor and backing storage stay alive until `run` returns; it is
// not called reentrantly on the same pool. Zero count performs no callback.
// ---------------------------------------------------------------------------

Range_Proc :: #type proc(data: rawptr, first, end: int)

Map_Proc :: #type proc(p: ^Work_Pool, count: int, task: Range_Proc, data: rawptr)

Work_Pool :: struct {
	run:  Map_Proc,
	user: rawptr,
}

MAX_STATIC_POOL_THREADS :: 32

// Static_Pool is the reference Work_Pool: a fixed set of persistent worker
// threads the application creates once and hands to the codecs per call. The
// range 0 ..< count is split into contiguous chunks at `run` time and the
// caller owns chunk zero and persistent worker slot i owns chunk i+1. For a
// fixed count, each item's thread owner stays the same across calls. The item
// loops themselves are allocation-free and atomic-free; CPU placement remains
// the caller/OS scheduler's responsibility.
//
//	pool: common.Static_Pool
//	common.init_static_pool(&pool, threads)
//	defer common.destroy_static_pool(&pool)
//	...
//	config.pool = &pool.work_pool
//
// The pool must not move after init (the workers hold pointers into it).
Static_Pool :: struct {
	work_pool: Work_Pool,
	threads:   [MAX_STATIC_POOL_THREADS]^thread.Thread,
	n_threads: int,
	started:   bool,
	// map state: written by the caller thread before the workers are woken
	// and read-only while they run.
	task:      Range_Proc,
	data:      rawptr,
	chunks:    [MAX_STATIC_POOL_THREADS + 2]int,
	running:   bool,
	// per-worker state (stable addresses for the thread entry points)
	workers:   [MAX_STATIC_POOL_THREADS]Static_Pool_Worker,
}

@(private)
Static_Pool_Worker :: struct {
	pool:  ^Static_Pool,
	chunk: int,
	// One hand-off per selected slot. These semaphore edges publish the map
	// descriptor to this worker and its completed item writes to the caller.
	go:    sync.Sema,
	ack:   sync.Sema,
}

init_static_pool :: proc(p: ^Static_Pool, threads: int) {
	// Initialization and shutdown belong to the same controller, between maps.
	assert(!p.started)
	p^ = {}
	p.work_pool = {
		run  = static_pool_map,
		user = p,
	}
	p.n_threads = clamp(threads, 0, MAX_STATIC_POOL_THREADS)
	p.running = true
	p.started = true

	for i in 0 ..< p.n_threads {
		p.workers[i].pool = p
		p.workers[i].chunk = i + 1
		p.threads[i] = thread.create_and_start_with_data(
			&p.workers[i],
			static_pool_runner,
			self_cleanup = false,
		)
	}
}

destroy_static_pool :: proc(p: ^Static_Pool) {
	if !p.started do return
	p.started = false
	p.running = false

	for i in 0 ..< p.n_threads do sync.post(&p.workers[i].go)
	for i in 0 ..< p.n_threads {
		thread.join(p.threads[i])
		thread.destroy(p.threads[i])
	}
}

@(private)
static_pool_runner :: proc(data: rawptr) {
	w := cast(^Static_Pool_Worker)data
	p := w.pool

	for {
		sync.wait(&w.go)
		if !p.running do return

		chunk := w.chunk
		p.task(p.data, p.chunks[chunk], p.chunks[chunk + 1])

		sync.post(&w.ack)
	}
}

static_pool_map :: proc(wp: ^Work_Pool, count: int, task: Range_Proc, data: rawptr) {
	p := cast(^Static_Pool)wp.user

	if count <= 0 do return

	// A serial range uses the same local traversal owner as a worker range.
	if !p.started || p.n_threads == 0 || count <= 1 {
		task(data, 0, count)
		return
	}

	// Contiguous chunks over 0 ..< count: at most one per worker plus one for
	// the caller thread.
	n_chunks := min(count, p.n_threads + 1)
	base := count / n_chunks
	extra := count % n_chunks

	p.task = task
	p.data = data

	off := 0
	for c in 0 ..< n_chunks {
		p.chunks[c] = off
		off += base + (c < extra ? 1 : 0)
	}
	p.chunks[n_chunks] = off

	// The descriptor is complete before any selected slot is released. Each
	// selected worker runs its own chunk once; unused slots stay asleep.
	used := n_chunks - 1
	for i in 0 ..< used do sync.post(&p.workers[i].go)

	p.task(p.data, p.chunks[0], p.chunks[1])

	// Completion precedes descriptor reuse, payload release and pool shutdown.
	for i in 0 ..< used do sync.wait(&p.workers[i].ack)
}

package main

import common "../codec/common"
import avc "../codec/h264"
import media "../codec/media"
import native "../codec/media/native"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:sys/linux"
import "core:time"

// Resident NAL input, fresh states, bounded streaming picture release.
// Seven codec-only rounds count borrowed frames without touching pixel planes.
// A separate verification pass hashes every visible 8-bit YUV420 pixel in
// display order for every independent stream. It is outside all codec timers.
// VIDEO_CPUS optionally pins fixed caller/worker slots; codecs set no affinity.
Job :: struct {
	session:                    media.Session,
	packets:                    []media.Packet,
	err:                        media.Error,
	frames, width, height, cpu: int,
	hash:                       u64,
	verify, pinned:             bool,
}
CPU_Mask :: [16]u64
SEED :: u64(14695981039346656037)

integer :: proc(s: string) -> int {
	v, ok := strconv.parse_int(s)
	if !ok do os.exit(2)
	return v
}

receive :: proc(frame: media.Video_Frame, user: rawptr) {
	j := (^Job)(user)
	j.frames += 1
	if frame.width != j.width ||
	   frame.height != j.height ||
	   frame.bit_depth != 8 ||
	   frame.chroma != .YUV420 ||
	   frame.storage != .Host {
		j.err = .Invalid_Input; return
	}
	if !j.verify do return
	for plane, c in frame.planes {
		w, h := c == 0 ? j.width : j.width / 2, c == 0 ? j.height : j.height / 2
		bytes := frame.storage_bits / 8
		if bytes != 1 && bytes != 2 {j.err = .Invalid_Input; return}
		for y in 0 ..< h do for x in 0 ..< w {
			offset := y * plane.stride + x * bytes
			value := u16(plane.data[offset])
			if bytes == 2 do value |= u16(plane.data[offset + 1]) << 8
			if value > 255 {j.err = .Invalid_Input; return}
			j.hash = (j.hash ~ u64(value)) * 1099511628211
		}
	}
}

run_range :: proc(data: rawptr, first, end: int) {
	jobs := (^[]Job)(data)
	for &j in jobs^[first:end] {
		receiver := media.Receiver {
			video = receive,
			user  = &j,
		}
		for packet in j.packets {
			e := media.decode(&j.session, packet, receiver)
			if e != .None {j.err = e; break}
			if j.err != .None do break
		}
		if j.err == .None {
			drain_error := media.drain(&j.session, receiver)
			if drain_error != .None && j.err == .None do j.err = drain_error
		}
	}
}

pin_range :: proc(data: rawptr, first, end: int) {
	jobs := (^[]Job)(data)
	for &j in jobs^[first:end] {
		if !j.pinned do continue
		mask: CPU_Mask
		mask[j.cpu / 64] = u64(1) << uint(j.cpu % 64)
		_, pin_error := linux.sched_setaffinity(0, size_of(mask), &mask)
		if pin_error != nil {j.err = .Unavailable; continue}
		actual: CPU_Mask
		n, e := linux.sched_getaffinity(0, size_of(actual), &actual)
		if e != nil || n <= 0 || actual != mask do j.err = .Unavailable
	}
}

main :: proc() {
	if len(os.args) != 7 {
		fmt.eprintln("usage: video_decode_timing input.264|265 h264|h265 width height frames independent_streams")
		os.exit(2)
	}
	w, h, expected, workers :=
		integer(os.args[3]), integer(os.args[4]), integer(os.args[5]), integer(os.args[6])
	if w <= 0 || h <= 0 || (w | h) & 1 != 0 || expected <= 0 || workers < 1 || workers > 16 do os.exit(2)
	codec: media.Codec
	switch os.args[2] {
	case "h264":
		codec = .H264
	case "h265":
		codec = .H265
	case:
		os.exit(2)
	}
	input, e := os.read_entire_file(os.args[1], context.allocator); if e != nil do os.exit(1)
	defer delete(input)
	nals := avc.find_nal_units(input); defer delete(nals)
	if len(nals) == 0 do os.exit(2)
	packets := make([]media.Packet, len(nals)); defer delete(packets)
	for nal, i in nals do packets[i] = {
		data    = input[nal.offset:nal.offset + nal.length],
		framing = .NAL,
	}
	jobs := make([]Job, workers); defer delete(jobs)
	cpus, pinned := os.lookup_env("VIDEO_CPUS", context.allocator); defer delete(cpus)
	allowed: CPU_Mask
	n, ae := linux.sched_getaffinity(0, size_of(allowed), &allowed)
	if ae != nil || n <= 0 do os.exit(2)
	for &j in jobs do j.width, j.height, j.packets, j.pinned = w, h, packets, pinned
	if pinned {
		start, slot := 0, 0
		for end in 0 ..= len(cpus) {
			if end < len(cpus) && cpus[end] != ',' do continue
			if slot >= workers || start == end do os.exit(2)
			cpu := integer(cpus[start:end])
			if cpu < 0 || cpu >= 1024 || allowed[cpu / 64] & (u64(1) << uint(cpu % 64)) == 0 do os.exit(2)
			for old in jobs[:slot] do if old.cpu == cpu do os.exit(2)
			jobs[slot].cpu = cpu; slot += 1; start = end + 1
		}
		if slot != workers do os.exit(2)
	}
	pool: common.Static_Pool
	common.init_static_pool(&pool, workers - 1); defer common.destroy_static_pool(&pool)
	pool.work_pool.run(&pool.work_pool, workers, pin_range, &jobs)
	for j in jobs do if j.err != .None do os.exit(2)
	config := media.Config {
		codec      = codec,
		operation  = .Decode,
		preference = .Native,
		width      = w,
		height     = h,
		bit_depth  = 8,
		chroma     = .YUV420,
	}
	times, init_times: [7]f64
	for round in 0 ..< 8 {
		t := time.tick_now()
		for &j in jobs {
			j.err, j.frames, j.hash, j.verify = .None, 0, SEED, round == 7
			if media.open(&j.session, config, []media.Provider{native.provider()}) != .None do os.exit(1)
		}
		if round < 7 do init_times[round] = time.duration_milliseconds(time.tick_since(t))
		t = time.tick_now()
		pool.work_pool.run(&pool.work_pool, workers, run_range, &jobs)
		if round < 7 do times[round] = time.duration_milliseconds(time.tick_since(t))
		for &j in jobs {
			if j.err != .None ||
			   j.frames != expected {fmt.eprintln("decode failure:", j.err, j.frames); os.exit(1)}
			if media.close(&j.session) != .None do os.exit(1)
		}
	}
	for j in jobs do if j.hash != jobs[0].hash do os.exit(1)
	slice.sort(times[:]); slice.sort(init_times[:])
	fmt.printfln(
		"native video decode: codec=%s frames=%d independent_streams=%d context_threads=1 init_ms=%.3f codec_ms=%.3f min_ms=%.3f max_ms=%.3f aggregate_fps=%.1f verification_hash=%016x verification=separate_full_pixel_pass cpus=%s",
		os.args[2],
		expected,
		workers,
		init_times[3],
		times[3],
		times[0],
		times[6],
		f64(expected * workers) * 1000 / times[3],
		jobs[0].hash,
		pinned ? cpus : "initial_mask",
	)
}

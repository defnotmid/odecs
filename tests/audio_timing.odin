package main

import aac "../audio/aac"
import decoder "../audio/aac/decoder"
import encoder "../audio/aac/encoder"
import common "../common"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:sys/linux"
import "core:time"

// Resident-input AAC-LC benchmark; this file is a standalone program.
// odin build tests/audio_timing.odin -file -o:speed -microarch:native -out:/tmp/audio-timing
// /tmp/audio-timing encode input.s16le rate channels bitrate workers output.aac
// /tmp/audio-timing decode input.aac workers output.s16le
// workers is 1..16 independent copies of the same stream, including the caller.
// Optional AUDIO_CPUS=cpu0,cpu1,... binds permanent caller/worker slots once.
// Require exactly workers distinct decimal IDs from the initial allowed mask;
// placement validation and the pin/verification map are outside both timers.
// Each of seven rounds initializes fresh codec state on the caller. The shared
// common.Static_Pool maps this fixed stream count to persistent worker slots;
// the caller processes stream zero and one AAC stream remains serial.
// Input loading, s16->f32 conversion, partial-frame padding, heap state/output
// allocation, initialization, comparison and file writes are outside codec_ms.
// Encode includes ADTS/output accumulation and one flush. Decode includes ADTS
// parsing, interleaving and s16 rounding/clipping/output accumulation. It retains
// all priming/padding samples: ADTS contains no original sample-count metadata.

Mode :: enum {
	Encode,
	Decode,
}
Job :: struct {
	mode:          Mode,
	config:        aac.Config,
	pcm:           []f32,
	input:         []u8,
	enc:           ^encoder.Encoder,
	dec:           ^decoder.Decoder,
	output:        [dynamic]u8,
	err:           aac.Error,
	frames:        int,
	failed_offset: int,
}

CPU_LIMIT :: 1024 // Same bounded Linux cpu_set_t envelope as the reference oracle.
CPU_Mask :: [CPU_LIMIT / 64]u64
CPU_Placement :: struct {
	allowed:   CPU_Mask,
	selected:  [16]int,
	errors:    [16]linux.Errno,
	verified:  [16]bool,
	pinned:    bool,
	label:     [5 * CPU_LIMIT]u8,
	label_len: int,
}

cpu_in_mask :: proc(mask: ^CPU_Mask, cpu: int) -> bool {
	return mask[cpu / 64] & (u64(1) << uint(cpu % 64)) != 0
}

append_cpu_label :: proc(p: ^CPU_Placement, cpu: int) {
	separator := p.label_len == 0 ? "" : ","
	value := fmt.bprintf(p.label[p.label_len:], "%s%d", separator, cpu)
	p.label_len += len(value)
}

prepare_placement :: proc(p: ^CPU_Placement, workers: int) {
	// Capture before any caller pin or worker creation, so every slot is checked
	// against the same original permitted CPU set rather than a singleton mask.
	bytes, err := linux.sched_getaffinity(0, size_of(p.allowed), &p.allowed)
	if err != nil || bytes <= 0 || bytes > size_of(p.allowed) {
		fmt.eprintln(
			"cannot capture initial CPU affinity within 1024-CPU envelope:",
			err,
		); os.exit(2)
	}
	text, found := os.lookup_env("AUDIO_CPUS", context.allocator)
	defer delete(text)
	p.pinned = found
	if !found {
		for cpu in 0 ..< CPU_LIMIT do if cpu_in_mask(&p.allowed, cpu) do append_cpu_label(p, cpu)
		if p.label_len == 0 {fmt.eprintln("initial CPU affinity is empty"); os.exit(2)}
		return
	}
	start, slot := 0, 0
	for end in 0 ..= len(text) {
		if end < len(text) && text[end] != ',' do continue
		if end == start || slot >= workers {
			fmt.eprintln(
				"AUDIO_CPUS requires exactly workers nonempty decimal CPU IDs",
			); os.exit(2)
		}
		cpu := 0
		for digit in text[start:end] {
			if digit < '0' || digit > '9' || cpu > (CPU_LIMIT - 1 - int(digit - '0')) / 10 {
				fmt.eprintln(
					"AUDIO_CPUS requires decimal CPU IDs below 1024, without whitespace or signs",
				); os.exit(2)
			}
			cpu = cpu * 10 + int(digit - '0')
		}
		if !cpu_in_mask(&p.allowed, cpu) {
			fmt.eprintln("AUDIO_CPUS CPU is outside the initial permitted mask:", cpu); os.exit(2)
		}
		for previous in 0 ..< slot do if p.selected[previous] == cpu {
			fmt.eprintln("AUDIO_CPUS CPU IDs must be distinct:", cpu); os.exit(2)
		}
		p.selected[slot] = cpu
		append_cpu_label(p, cpu)
		slot += 1
		start = end + 1
	}
	if slot != workers {
		fmt.eprintln("AUDIO_CPUS requires exactly workers CPU IDs"); os.exit(2)
	}
}

pin_slot_range :: proc(data: rawptr, first, end: int) {
	for index in first ..< end do pin_slot(data, index)
}

pin_slot :: proc(data: rawptr, index: int) {
	p := cast(^CPU_Placement)data
	mask: CPU_Mask
	cpu := p.selected[index]
	mask[cpu / 64] = u64(1) << uint(cpu % 64)
	_, err := linux.sched_setaffinity(0, size_of(mask), &mask)
	p.errors[index] = err
	if err != nil do return
	actual: CPU_Mask
	bytes, get_err := linux.sched_getaffinity(0, size_of(actual), &actual)
	p.errors[index] = get_err
	if get_err != nil || bytes <= 0 || bytes > size_of(actual) do return
	p.verified[index] = actual == mask
}

integer :: proc(value: string) -> int {
	v, ok := strconv.parse_int(value)
	if !ok {fmt.eprintln("invalid integer:", value); os.exit(2)}
	return v
}

product :: proc(count, factor: int) -> int {
	if count < 0 || factor <= 0 || count > max(int) / factor {
		fmt.eprintln("input/output size overflow"); os.exit(2)
	}
	return count * factor
}

run_job :: proc(j: ^Job) {
	if j.mode == .Encode {
		stride := aac.FRAME_SAMPLES * j.config.channels
		for pos := 0; pos < len(j.pcm); pos += stride {
			j.failed_offset = pos
			j.err = encoder.encode_frame(j.enc, j.pcm[pos:pos + stride], &j.output)
			if j.err != .None do return
			j.frames += 1
		}
		j.err = encoder.flush_encoder(j.enc, &j.output)
		if j.err == .None do j.frames = j.enc.frames
		return
	}
	pcm: [2 * aac.FRAME_SAMPLES]f32
	for pos := 0; pos < len(j.input); {
		j.failed_offset = pos
		consumed, samples, err := decoder.decode_adts_frame(j.dec, j.input[pos:], pcm[:])
		j.err = err
		if err != .None do return
		if consumed <= 0 || samples != aac.FRAME_SAMPLES {
			j.err = .Invalid_Data
			return
		}
		pos += consumed
		j.frames += 1
		count := samples * j.config.channels
		first := len(j.output)
		// Capacity is already reserved for the complete resident stream. Every
		// added byte is written below, so no zero fill or per-sample append is needed.
		if err := non_zero_resize(&j.output, first + count * 2); err != nil {
			j.err = .Output_Too_Small
			return
		}
		packed, packing_err := common.pack_s16le(pcm[:count], j.output[first:])
		switch packing_err {
		case .None:
		case .Non_Finite:
			// Match the old append loop's finite-sample prefix on failure.
			_ = non_zero_resize(&j.output, first + packed * 2)
			j.err = .Invalid_Data
			return
		case .Output_Too_Small:
			_ = non_zero_resize(&j.output, first)
			j.err = .Output_Too_Small
			return
		}
	}
}

run_job_range :: proc(data: rawptr, first, end: int) {
	jobs := (cast(^[]Job)data)^
	for &job in jobs[first:end] do run_job(&job)
}

run_jobs :: proc(pool: ^common.Work_Pool, jobs: []Job) {
	batch := jobs // Local descriptor stays alive until the synchronous join.
	if pool == nil {
		run_job_range(&batch, 0, len(batch))
		return
	}
	// One independent stream per item. With count == threads+1, the common
	// fixed-range owner maps caller/worker slot i to jobs[i] for every round.
	pool.run(pool, len(batch), run_job_range, &batch)
}

main :: proc() {
	if len(os.args) < 2 ||
	   (os.args[1] != "encode" && os.args[1] != "decode") ||
	   (os.args[1] == "encode" && len(os.args) != 8) ||
	   (os.args[1] == "decode" && len(os.args) != 5) {
		fmt.eprintln(
			"usage: audio_timing encode input.s16le rate channels bitrate workers output.aac",
		)
		fmt.eprintln("       audio_timing decode input.aac workers output.s16le")
		os.exit(2)
	}
	mode := os.args[1] == "encode" ? Mode.Encode : Mode.Decode
	config: aac.Config
	workers: int
	output_path: string
	if mode == .Encode {
		config = {
			sample_rate = integer(os.args[3]),
			channels    = integer(os.args[4]),
			bit_rate    = integer(os.args[5]),
		}
		workers = integer(os.args[6])
		output_path = os.args[7]
		if aac.validate_config(config) != .None {
			fmt.eprintln(
				"AAC-LC requires a supported 8000..96000-Hz rate and one or two channels",
			); os.exit(2)
		}
		if config.bit_rate == 0 do config.bit_rate = 64000 * config.channels
		if config.bit_rate < 8000 * config.channels ||
		   config.bit_rate >
			   min(512000 * config.channels, config.sample_rate * 6 * config.channels) {
			fmt.eprintln("invalid AAC target bit rate"); os.exit(2)
		}
	} else {
		workers = integer(os.args[3])
		output_path = os.args[4]
	}
	if workers < 1 || workers > 16 {
		fmt.eprintln(
			"workers must be 1..16 independent streams (including the caller)",
		); os.exit(2)
	}
	placement: CPU_Placement
	prepare_placement(&placement, workers)
	data, read_err := os.read_entire_file(os.args[2], context.allocator)
	if read_err != nil {fmt.eprintln("cannot read input:", read_err); os.exit(1)}
	defer delete(data)
	if len(data) == 0 {fmt.eprintln("input is empty"); os.exit(2)}

	pcm: []f32
	defer delete(pcm)
	input_samples, input_frames, expected_frames, output_capacity: int
	if mode == .Encode {
		if len(data) % (2 * config.channels) != 0 {
			fmt.eprintln("s16le input must contain complete channel frames"); os.exit(2)
		}
		input_samples = len(data) / (2 * config.channels)
		input_frames = (input_samples - 1) / aac.FRAME_SAMPLES + 1
		if input_frames == max(int) {fmt.eprintln("input frame count overflow"); os.exit(2)}
		expected_frames = input_frames + 1 // One final overlap frame, including padded input.
		output_capacity = product(expected_frames, 8191) // Maximum admitted ADTS frame size.
		pcm_count := product(product(input_frames, aac.FRAME_SAMPLES), config.channels)
		_ = product(pcm_count, size_of(f32))
		pcm = make([]f32, pcm_count)
		for i in 0 ..< len(data) / 2 {
			sample := i16(u16(data[2 * i]) | u16(data[2 * i + 1]) << 8)
			pcm[i] = f32(sample) / 32768
		}
	} else {
		// Count and validate framing/config outside setup/timing. The actual
		// per-frame API repeats ADTS parsing inside every timed decode job.
		for pos := 0; pos < len(data); {
			h, _, err := aac.parse_adts(data[pos:])
			if err !=
			   .None {fmt.eprintfln("invalid ADTS frame at byte %d: %v", pos, err); os.exit(2)}
			if pos == 0 do config = h.config
			if h.config.sample_rate != config.sample_rate || h.config.channels != config.channels {
				fmt.eprintln("ADTS configuration changes are not admitted"); os.exit(2)
			}
			pos += h.frame_bytes
			input_frames += 1
		}
		expected_frames = input_frames
		input_samples = product(input_frames, aac.FRAME_SAMPLES)
		output_capacity = product(product(input_samples, config.channels), 2)
	}

	// Large states and each stream's complete output live on the heap. Their
	// addresses remain stable until the shared persistent pool has joined.
	jobs := make([]Job, workers)
	defer {
		for &job in jobs {
			if job.enc != nil {encoder.destroy_encoder(job.enc); free(job.enc)}
			if job.dec != nil do free(job.dec)
			delete(job.output)
		}
		delete(jobs)
	}
	for &job in jobs {
		job.mode, job.config, job.pcm, job.input = mode, config, pcm, data
		job.output = make([dynamic]u8, 0, output_capacity)
		if mode == .Encode {job.enc = new(encoder.Encoder)} else {job.dec = new(decoder.Decoder)}
	}
	pool: common.Static_Pool
	if workers > 1 do common.init_static_pool(&pool, workers - 1)
	defer if workers > 1 do common.destroy_static_pool(&pool)
	if placement.pinned {
		// The shared pool owns the same fixed slot ranges for this map and each
		// codec round. All workers exist before slot zero narrows the caller mask.
		if workers >
		   1 {pool.work_pool.run(&pool.work_pool, workers, pin_slot_range, &placement)} else {pin_slot(&placement, 0)}
		for index in 0 ..< workers do if !placement.verified[index] {
			fmt.eprintfln("cannot pin/verify slot %d on CPU %d: %v", index, placement.selected[index], placement.errors[index]); os.exit(2)
		}
	}

	times, init_times: [7]f64
	baseline: []u8
	defer delete(baseline)
	for round in 0 ..< len(times) {
		for &job in jobs {
			clear(&job.output)
			job.err, job.frames, job.failed_offset = .None, 0, 0
		}
		t := time.tick_now()
		for &job in jobs {
			if mode ==
			   .Encode {job.err = encoder.init_encoder(job.enc, config)} else {job.err = decoder.init_decoder(job.dec, config)}
		}
		init_times[round] = time.duration_milliseconds(time.tick_since(t))
		for job, index in jobs do if job.err != .None {
			fmt.eprintfln("AAC initialization failed, stream %d: %v", index, job.err); os.exit(1)
		}
		t = time.tick_now()
		run_jobs(workers > 1 ? &pool.work_pool : nil, jobs)
		times[round] = time.duration_milliseconds(time.tick_since(t))
		for &job, index in jobs {
			if job.err != .None {
				fmt.eprintfln(
					"AAC %s failed, round %d stream %d frame %d input offset %d: %v",
					os.args[1],
					round,
					index,
					job.frames,
					job.failed_offset,
					job.err,
				); os.exit(1)
			}
			if job.frames != expected_frames ||
			   len(job.output) == 0 ||
			   (mode == .Decode && len(job.output) != output_capacity) {
				fmt.eprintln("AAC frame/output accounting mismatch"); os.exit(1)
			}
			if round == 0 &&
			   index ==
				   0 {baseline = slice.clone(job.output[:])} else if !slice.equal(baseline, job.output[:]) {
				fmt.eprintfln(
					"nondeterministic AAC output, round %d stream %d",
					round,
					index,
				); os.exit(1)
			}
			if job.enc != nil do encoder.destroy_encoder(job.enc)
		}
	}
	if write_err := os.write_entire_file(output_path, baseline); write_err != nil {
		fmt.eprintln("cannot write output:", write_err); os.exit(1)
	}
	slice.sort(times[:])
	slice.sort(init_times[:])
	input_seconds := f64(input_samples) / f64(config.sample_rate)
	total_stream_seconds := input_seconds * f64(workers)
	fmt.printfln("Odin target: %s, microarchitecture: %s", ODIN_ARCH_STRING, ODIN_MICROARCH_STRING)
	fmt.printfln(
		"native AAC-LC %s: rate=%d channels=%d bit_rate=%d independent_streams=%d pool_threads=%d rounds=7 frames_per_stream=%d input_samples_per_channel=%d input_bytes=%d bytes_per_stream=%d input_seconds=%.6f total_stream_seconds=%.6f init_ms=%.3f codec_ms=%.3f min_ms=%.3f max_ms=%.3f realtime_x=%.3f rtf=%.6f scheduler=common_fixed_ranges initialization_owner=caller placement=%s cpus=%s",
		os.args[1],
		config.sample_rate,
		config.channels,
		config.bit_rate,
		workers,
		pool.n_threads,
		expected_frames,
		input_samples,
		len(data),
		len(baseline),
		input_seconds,
		total_stream_seconds,
		init_times[3],
		times[3],
		times[0],
		times[6],
		total_stream_seconds * 1000 / times[3],
		times[3] / (total_stream_seconds * 1000),
		placement.pinned ? "pinned_slots" : "allowed_set",
		string(placement.label[:placement.label_len]),
	)
}

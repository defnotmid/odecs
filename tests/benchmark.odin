package main
import common "../common"
import avc_enc "../video/h264/encoder"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"
import benchmark_support "support"

integer :: proc(s: string) -> int {v, ok := strconv.parse_int(s); if !ok do os.exit(2); return v}

// Resident input and codec calls, including output accumulation.
// Setup and disk writes are outside the codec timer.
main :: proc() {
	fmt.printfln("Odin target: %s, microarchitecture: %s", ODIN_ARCH_STRING, ODIN_MICROARCH_STRING)
	if len(os.args) < 9 {
		fmt.eprintln(
			"usage: benchmark input.yuv width height frames workers slices qp output.264 [exhaustive] [gpu|gpu-local]",
		)
		os.exit(2)
	}
	w, h, frames := integer(os.args[2]), integer(os.args[3]), integer(os.args[4])
	workers, slices, qp := integer(os.args[5]), integer(os.args[6]), integer(os.args[7])
	exhaustive, use_gpu := false, false
	placement: avc_enc.Compute_Memory = .Host_Cached
	for arg in os.args[9:] {
		switch arg {
		case "exhaustive":
			exhaustive = true
		case "gpu":
			use_gpu = true
		case "gpu-local":
			use_gpu = true; placement = .Device_Local
		case:
			fmt.eprintln("unknown option:", arg); os.exit(2)
		}
	}
	if w <= 0 || h <= 0 || w > 16384 || h > 16384 || (w | h) & 1 != 0 || frames < 2 || frames > 100000 || workers < 1 || workers > common.MAX_STATIC_POOL_THREADS + 1 || slices < 1 || qp < 0 || qp > 51 do os.exit(2)
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {fmt.eprintln(err); os.exit(1)}
	defer delete(data)
	frame_bytes := w * h * 3 / 2
	if len(data) % frame_bytes != 0 ||
	   frames > len(data) / frame_bytes {fmt.eprintln("incomplete input frames"); os.exit(1)}
	device: avc_enc.Compute_Device
	if use_gpu {
		t := time.tick_now()
		if err := avc_enc.init_compute_device(&device);
		   err != .None {fmt.eprintln(err); os.exit(1)}
		fmt.printfln(
			"GPU=%s device_init_ms=%.3f placement=%v",
			cstring(raw_data(device.properties.deviceName[:])),
			time.duration_milliseconds(time.tick_since(t)),
			placement,
		)
	}
	defer if use_gpu do avc_enc.destroy_compute_device(&device)
	pool: common.Static_Pool
	if workers > 1 do common.init_static_pool(&pool, workers - 1)
	defer if workers > 1 do common.destroy_static_pool(&pool)
	if err := benchmark_support.pin_video_cpus(workers > 1 ? &pool.work_pool : nil, workers);
	   err != .None {
		fmt.eprintln(benchmark_support.pin_error_description(err)); os.exit(2)
	}
	out := make([dynamic]u8, 0, 4 * 1024 * 1024)
	defer delete(out)
	frame_times := make([]f64, frames * 7)
	defer delete(frame_times)
	totals, initializations, first_frames, steady: [7]f64
	gpu_times: [7]f64
	baseline: []u8
	defer delete(baseline)
	for rep in 0 ..< 7 {
		st: avc_enc.Encoder_State
		t := time.tick_now()
		avc_enc.init_encoder(
			&st,
			{
				width = w,
				height = h,
				qp = i32(qp),
				gop_size = 15,
				num_ref_frames = 1,
				slice_count = slices,
				exhaustive_intra = exhaustive,
			},
		)
		if use_gpu do if err := avc_enc.attach_encoder_compute(&st, &device, placement); err != .None {fmt.eprintln(err); os.exit(1)}
		initializations[rep] = time.duration_milliseconds(time.tick_since(t))
		clear(&out)
		t = time.tick_now()
		for frame in 0 ..< frames {
			src := data[frame * frame_bytes:]
			start := time.tick_now()
			err := avc_enc.encode_frame(
				&st,
				raw_data(src),
				&src[w * h],
				&src[w * h * 5 / 4],
				w,
				w / 2,
				frame % 15 == 0,
				&out,
				workers > 1 ? &pool.work_pool : nil,
			)
			frame_times[rep * frames + frame] = time.duration_milliseconds(time.tick_since(start))
			if err != .None {fmt.eprintln(err); os.exit(1)}
		}
		totals[rep] = time.duration_milliseconds(time.tick_since(t))
		first_frames[rep] = frame_times[rep * frames]
		steady[rep] = totals[rep] - first_frames[rep]
		assert(st.frames_coded == frames)
		if use_gpu do gpu_times[rep] = st.compute.gpu_ms
		avc_enc.destroy_encoder(&st)
		if rep ==
		   0 {baseline = make([]u8, len(out)); copy(baseline, out[:])} else if len(baseline) != len(out) || mem.compare(baseline, out[:]) != 0 {fmt.eprintln("nondeterministic encoded output"); os.exit(1)}
	}
	if write_err := os.write_entire_file(os.args[8], out[:]); write_err != nil {fmt.eprintln(write_err); os.exit(1)}
	slice.sort(totals[:])
	slice.sort(initializations[:])
	slice.sort(first_frames[:])
	slice.sort(steady[:])
	slice.sort(frame_times)
	slice.sort(gpu_times[:])
	fmt.printfln(
		"oicu encode: frames=%d workers=%d slices=%d qp=%d bytes=%d init_ms=%.3f codec_ms=%.3f fps=%.1f first_frame_ms=%.3f steady_fps=%.1f frame_p50_ms=%.3f frame_p95_ms=%.3f",
		frames,
		workers,
		min(slices, (h + 15) / 16),
		qp,
		len(out),
		initializations[3],
		totals[3],
		f64(frames) * 1000 / totals[3],
		first_frames[3],
		f64(frames - 1) * 1000 / steady[3],
		frame_times[len(frame_times) / 2],
		frame_times[len(frame_times) * 95 / 100],
	)
	if use_gpu do fmt.printfln("GPU deblock device_ms=%.3f (codec_ms includes host access, packing, dispatch, fences; frame transfers=0)", gpu_times[3])
}

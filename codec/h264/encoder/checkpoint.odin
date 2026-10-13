package h264_encoder

// Frame checkpoints retain immutable picture slots. They never copy YUV planes.
// Only this encoder may append to the bound output stream while checkpoints live.
// Pass the stream to capture the initial state before frame zero. Restoring that
// checkpoint restarts the whole encode while retaining all CPU/GPU allocations.
capture_encoder_checkpoint :: proc(
	state: ^Encoder_State,
	out_stream: ^[dynamic]u8 = nil,
) -> (
	handle: Encoder_Checkpoint_Handle,
	err: Error,
) {
	if state.frame.phase != .Idle do return handle, .Invalid_State
	if state.borrowed_output do return handle, .Borrowed_Output_Checkpoints
	stream := state.output_stream
	if stream == nil do stream = out_stream
	if stream == nil do return handle, .Output_Required
	if out_stream != nil && out_stream != stream do return handle, .Output_Owner_Mismatch
	for &point, index in state.checkpoints {
		if point.active do continue
		state.output_stream = stream
		state.checkpoint_serial += 1
		point = Encoder_Checkpoint {
			active        = true,
			generation    = state.checkpoint_serial,
			config        = state.config,
			frame_num     = state.frame_num,
			idr_pic_id    = state.idr_pic_id,
			frames_coded  = state.frames_coded,
			next_pic_id   = state.next_pic_id,
			rate          = state.rate,
			num_refs      = state.num_refs,
			output_length = len(state.output_stream),
		}
		for r in 0 ..< state.num_refs {
			pic := state.refs[r]
			point.refs[r] = pic.slot
			point.ref_generations[r] = pic.generation
			pic.pins += 1
		}
		return {state, index, point.generation}, .None
	}
	return handle, .Checkpoint_Capacity_Exhausted
}

encoder_checkpoint_valid :: proc(
	state: ^Encoder_State,
	handle: Encoder_Checkpoint_Handle,
) -> bool {
	return(
		handle.owner == state &&
		handle.index >= 0 &&
		handle.index < len(state.checkpoints) &&
		state.checkpoints[handle.index].active &&
		state.checkpoints[handle.index].generation == handle.generation \
	)
}

release_encoder_checkpoint :: proc(
	state: ^Encoder_State,
	handle: Encoder_Checkpoint_Handle,
) -> Error {
	if !encoder_checkpoint_valid(state, handle) do return .Invalid_Checkpoint
	point := &state.checkpoints[handle.index]
	for r in 0 ..< point.num_refs do state.pictures[point.refs[r]].pins -= 1
	point.active = false
	return .None
}

restore_encoder_checkpoint :: proc(
	state: ^Encoder_State,
	handle: Encoder_Checkpoint_Handle,
) -> Error {
	if !encoder_checkpoint_valid(state, handle) do return .Invalid_Checkpoint
	point := state.checkpoints[handle.index]
	if point.config != state.config do return .Checkpoint_Config_Mismatch
	if state.output_stream == nil || len(state.output_stream) < point.output_length do return .Checkpoint_Output_Unavailable
	for r in 0 ..< point.num_refs {
		if state.pictures[point.refs[r]].generation != point.ref_generations[r] do return .Checkpoint_Reference_Overwritten
	}
	cancel_encode_frame(state)
	// A rewind invalidates the discarded suffix and checkpoints within it.
	for &later, index in state.checkpoints {
		if later.active && later.frames_coded > point.frames_coded do release_encoder_checkpoint(state, {state, index, later.generation})
	}
	resize(state.output_stream, point.output_length)
	state.frame_num = point.frame_num
	state.idr_pic_id = point.idr_pic_id
	state.frames_coded = point.frames_coded
	state.next_pic_id = point.next_pic_id
	state.rate = point.rate
	state.num_refs = point.num_refs
	state.refs = {}
	for r in 0 ..< point.num_refs do state.refs[r] = &state.pictures[point.refs[r]]
	state.curr = state.num_refs > 0 ? state.refs[0] : nil
	state.epoch += 1
	return .None
}

// first_changed_frame is zero-based. Return the first frame the caller must
// replay, including any unchanged gap between a retained point and the edit.
// The caller owns the source frames; no old encoded suffix is reused.
rewind_encoder_to_edit :: proc(
	state: ^Encoder_State,
	first_changed_frame: int,
) -> (
	restart_frame: int,
	err: Error,
) {
	if first_changed_frame < 0 do return 0, .Invalid_Input
	best := -1
	for point, i in state.checkpoints {
		if !point.active || point.frames_coded > first_changed_frame do continue
		if best < 0 || point.frames_coded > state.checkpoints[best].frames_coded do best = i
	}
	if best < 0 do return 0, .Checkpoint_Unavailable
	point := state.checkpoints[best]
	if e := restore_encoder_checkpoint(state, {state, best, point.generation}); e != .None do return 0, e
	return point.frames_coded, .None
}

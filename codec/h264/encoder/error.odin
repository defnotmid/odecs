package h264_encoder

// Refusals and resource failures are values; diagnostics are separate text.
Error :: enum {
	None,
	Invalid_Config,
	Invalid_Input,
	Invalid_State,
	Busy,
	First_Frame_Must_Be_IDR,
	Output_Required,
	Output_Owner_Mismatch,
	Borrowed_Output_Checkpoints,
	Picture_Capacity_Exhausted,
	Checkpoint_Capacity_Exhausted,
	Invalid_Checkpoint,
	Checkpoint_Config_Mismatch,
	Checkpoint_Output_Unavailable,
	Checkpoint_Reference_Overwritten,
	Checkpoint_Unavailable,
	Unsupported_Platform,
	Unsupported_Device,
	Vulkan_Unavailable,
	Memory_Placement_Unavailable,
	Allocation_Failed,
	Driver_Error,
}

error_description :: proc(err: Error) -> string {
	switch err {
	case .None:
		return ""
	case .Invalid_Config:
		return "invalid encoder configuration"
	case .Invalid_Input:
		return "invalid input, source planes, work budget or edited frame index"
	case .Invalid_State:
		return "operation is invalid in the current encoder state"
	case .Busy:
		return "encoder or compute work is already active"
	case .First_Frame_Must_Be_IDR:
		return "the first frame must be IDR"
	case .Output_Required:
		return "an output stream is required"
	case .Output_Owner_Mismatch:
		return "encoder output belongs to another stream or publication mode"
	case .Borrowed_Output_Checkpoints:
		return "borrowed lane output cannot retain or seek checkpoints"
	case .Picture_Capacity_Exhausted:
		return "all picture slots are retained"
	case .Checkpoint_Capacity_Exhausted:
		return "checkpoint capacity exhausted"
	case .Invalid_Checkpoint:
		return "invalid or released checkpoint"
	case .Checkpoint_Config_Mismatch:
		return "checkpoint configuration differs"
	case .Checkpoint_Output_Unavailable:
		return "checkpoint output prefix is unavailable"
	case .Checkpoint_Reference_Overwritten:
		return "checkpoint reference was overwritten"
	case .Checkpoint_Unavailable:
		return "no retained checkpoint precedes the edited frame"
	case .Unsupported_Platform:
		return "Vulkan compute is unsupported on this platform"
	case .Unsupported_Device:
		return "GPU lacks the required compute features"
	case .Vulkan_Unavailable:
		return "Vulkan loader or physical device is unavailable"
	case .Memory_Placement_Unavailable:
		return "requested coherent mapped memory placement is unavailable"
	case .Allocation_Failed:
		return "encoder resource allocation failed"
	case .Driver_Error:
		return "Vulkan compute driver operation failed"
	}
	return "unknown encoder error"
}

package benchmark_support

// Benchmark placement is optional and never changes codec scheduling policy.
// Unset VIDEO_CPUS leaves every thread's inherited affinity unchanged.
Pin_Error :: enum {
	None,
	Invalid_Worker_Count,
	Invalid_CPU_List,
	Duplicate_CPU,
	CPU_Not_Allowed,
	Affinity_Unavailable,
	Affinity_Changed,
	Slot_Mapping,
}

pin_error_description :: proc(err: Pin_Error) -> string {
	switch err {
	case .None:
		return ""
	case .Invalid_Worker_Count:
		return "worker count must be between 1 and 33"
	case .Invalid_CPU_List:
		return(
			"VIDEO_CPUS requires exactly workers decimal CPU IDs below 1024, without whitespace or signs" \
		)
	case .Duplicate_CPU:
		return "VIDEO_CPUS CPU IDs must be distinct"
	case .CPU_Not_Allowed:
		return "VIDEO_CPUS CPU is outside the initial permitted mask"
	case .Affinity_Unavailable:
		return "cannot set or read CPU affinity within the 1024-CPU envelope"
	case .Affinity_Changed:
		return "thread CPU affinity did not match the expected mask"
	case .Slot_Mapping:
		return "pinning requires one fixed caller/worker slot per item"
	}
	return "unknown benchmark pin error"
}

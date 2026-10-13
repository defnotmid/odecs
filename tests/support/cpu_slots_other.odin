#+build !linux
package benchmark_support

import common "../../codec/common"
import "core:os"

// Preserve portable default benchmark behavior; explicit placement is currently
// implemented only with Linux's current-thread affinity API.
pin_video_cpus :: proc(pool: ^common.Work_Pool, workers: int) -> Pin_Error {
	if workers < 1 || workers > common.MAX_STATIC_POOL_THREADS + 1 do return .Invalid_Worker_Count
	cpus, present := os.lookup_env("VIDEO_CPUS", context.allocator)
	defer delete(cpus)
	if present do return .Affinity_Unavailable
	return .None
}

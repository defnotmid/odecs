// H.264 Macroblock Motion Estimation Compute Shader (Slang -> SPIR-V for Vulkan)
// Dispatches 1 workgroup [16, 16] per macroblock to evaluate 256 candidate motion vectors in parallel.

[[vk::binding(0, 0)]] ByteAddressBuffer curr_frame_y : register(t0, space0);
[[vk::binding(1, 0)]] ByteAddressBuffer ref_frame_y  : register(t1, space0);

struct MotionParams {
    uint width;
    uint height;
    uint mb_width;
    uint mb_height;
    uint y_stride;
    int  search_range; // e.g. 8 -> [-8, 7] search window
};

[[vk::binding(0, 1)]] ConstantBuffer<MotionParams> u : register(b0, space1);

struct MotionVectorResult {
    int  mv_x;
    int  mv_y;
    uint sad;
    uint pad;
};

[[vk::binding(0, 2)]] RWStructuredBuffer<MotionVectorResult> out_mvs : register(u0, space2);

// Shared memory for 256 candidate reduction
groupshared uint s_sad[256];
groupshared int2 s_mv[256];

uint load_byte(ByteAddressBuffer buf, uint offset) {
    uint word = buf.Load(offset & ~3u);
    return (word >> ((offset & 3u) * 8u)) & 0xFFu;
}

[shader("compute")]
[numthreads(16, 16, 1)]
void cs_main(
    uint3 group_id   : SV_GroupID,
    uint3 thread_id  : SV_GroupThreadID,
    uint  flat_idx   : SV_GroupIndex
) {
    uint mb_x = group_id.x;
    uint mb_y = group_id.y;
    if (mb_x >= u.mb_width || mb_y >= u.mb_height) return;

    int cand_dx = int(thread_id.x) - u.search_range;
    int cand_dy = int(thread_id.y) - u.search_range;

    int cur_origin_x = int(mb_x * 16u);
    int cur_origin_y = int(mb_y * 16u);

    int ref_origin_x = cur_origin_x + cand_dx;
    int ref_origin_y = cur_origin_y + cand_dy;

    uint sad = 0;
    bool valid = (ref_origin_x >= 0 && ref_origin_x + 16 <= int(u.width) &&
                  ref_origin_y >= 0 && ref_origin_y + 16 <= int(u.height));

    if (valid) {
        // Accumulate 16x16 SAD
        for (uint y = 0; y < 16u; y++) {
            uint cur_row = uint(cur_origin_y + int(y)) * u.y_stride + uint(cur_origin_x);
            uint ref_row = uint(ref_origin_y + int(y)) * u.y_stride + uint(ref_origin_x);
            for (uint x = 0; x < 16u; x++) {
                uint cur_val = load_byte(curr_frame_y, cur_row + x);
                uint ref_val = load_byte(ref_frame_y, ref_row + x);
                sad += (cur_val > ref_val) ? (cur_val - ref_val) : (ref_val - cur_val);
            }
        }
    } else {
        sad = 0x7FFFFFFFu; // Out of bounds penalty
    }

    s_sad[flat_idx] = sad;
    s_mv[flat_idx] = int2(cand_dx, cand_dy);
    GroupMemoryBarrierWithGroupSync();

    // Parallel reduction in shared memory to find minimum SAD (256 -> 128 -> ... -> 1)
    [unroll]
    for (uint s = 128u; s > 0u; s >>= 1u) {
        if (flat_idx < s) {
            if (s_sad[flat_idx + s] < s_sad[flat_idx]) {
                s_sad[flat_idx] = s_sad[flat_idx + s];
                s_mv[flat_idx] = s_mv[flat_idx + s];
            }
        }
        GroupMemoryBarrierWithGroupSync();
    }

    // Thread 0 writes the optimal motion vector for this macroblock
    if (flat_idx == 0u) {
        uint mb_index = mb_y * u.mb_width + mb_x;
        MotionVectorResult res;
        res.mv_x = s_mv[0].x;
        res.mv_y = s_mv[0].y;
        res.sad = s_sad[0];
        res.pad = 0;
        out_mvs[mb_index] = res;
    }
}

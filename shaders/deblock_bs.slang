#include "deblock_common.slang"
[[vk::push_constant]] ConstantBuffer<DeblockParams> u;

// One invocation owns one complete word: four strengths per macroblock edge.
// No byte read/modify/write, including the zero-valued frame/slice boundaries.
[shader("compute")]
[numthreads(64, 1, 1)]
void cs_main(uint3 id : SV_DispatchThreadID) {
    uint idx = id.x, mb = idx / 8, orientation = (idx / 4) & 1, edge = idx & 3;
    if (mb >= u.mb_width * u.mb_height) return;
    DeblockMB* q = &u.mbs[mb];
    DeblockMB* p = q;
    uint packed = 0;
    bool enabled = q.filter_idc != 1;
    if (edge == 0) {
        enabled = enabled && (orientation == 0 ? mb % u.mb_width > 0 : mb >= u.mb_width);
        if (enabled) {
            p = &u.mbs[mb - (orientation == 0 ? 1 : u.mb_width)];
            enabled = q.filter_idc != 2 || p.slice_num == q.slice_num;
        }
    } else if ((q.flags & 2) != 0 && (edge & 1) != 0) enabled = false;
    if (enabled) for (uint k = 0; k < 4; ++k) {
        uint ps = orientation == 0 ? subblock(edge == 0 ? 3 : edge - 1, k) : subblock(k, edge == 0 ? 3 : edge - 1);
        uint qs = orientation == 0 ? subblock(edge, k) : subblock(k, edge);
        uint bs = ((p.flags | q.flags) & 1) != 0 ? (edge == 0 ? 4 : 3) :
            (((p.coded_mask >> ps) | (q.coded_mask >> qs)) & 1) != 0 ? 2 : inter_strength(p, q, ps, qs);
        packed |= bs << (k * 8);
    }
    u.strengths[idx] = packed;
}

// Shared wire layout with Compute_MB / Compute_Params in codec/h264/compute.odin.
struct DeblockMB {
    uint flags; // intra=1, transform8=2
    uint filter_idc, slice_num;
    int qp, alpha_offset, beta_offset; // offsets already multiplied by two
    uint coded_mask, reserved;
    uint pred_dir[4];
    int ref_pic[2][4]; // physical reference identity, not list index
    int2 mvs[2][16];
};
struct DeblockParams {
    DeblockMB* mbs;
    uint* strengths;
    int* tables;
    uint8_t* y;
    uint8_t* cb;
    uint8_t* cr;
    uint mb_width, mb_height, wave, y_stride;
    uint uv_stride;
    int chroma0, chroma1;
    uint reserved;
};
uint subblock(uint x, uint y) {
    return ((y / 2) * 2 + x / 2) * 4 + (y & 1) * 2 + (x & 1);
}
bool differs(int2 a, int2 b) { return any(abs(a - b) >= 4); }
uint inter_strength(DeblockMB* p, DeblockMB* q, uint ps, uint qs) {
    uint pd = p.pred_dir[ps / 4], qd = q.pred_dir[qs / 4];
    if (pd != 3 && qd != 3) {
        uint pl = pd == 1 ? 0 : 1, ql = qd == 1 ? 0 : 1;
        return p.ref_pic[pl][ps / 4] != q.ref_pic[ql][qs / 4] || differs(p.mvs[pl][ps], q.mvs[ql][qs]) ? 1 : 0;
    }
    if (pd != qd) return 1;
    int2 pp = int2(p.ref_pic[0][ps / 4], p.ref_pic[1][ps / 4]);
    int2 qp = int2(q.ref_pic[0][qs / 4], q.ref_pic[1][qs / 4]);
    bool same = all(pp == qp), swapped = all(pp == qp.yx);
    if (!same && !swapped) return 1;
    bool direct = !differs(p.mvs[0][ps], q.mvs[0][qs]) && !differs(p.mvs[1][ps], q.mvs[1][qs]);
    bool crossed = !differs(p.mvs[0][ps], q.mvs[1][qs]) && !differs(p.mvs[1][ps], q.mvs[0][qs]);
    return (pp.x == pp.y ? direct || crossed : (same ? direct : crossed)) ? 0 : 1;
}

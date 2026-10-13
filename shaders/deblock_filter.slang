#include "deblock_common.slang"
[[vk::push_constant]] ConstantBuffer<DeblockParams> u;

int read_pixel(uint plane, int2 pos) {
    uint8_t* pixels = plane == 0 ? u.y : (plane == 1 ? u.cb : u.cr);
    int stride = int(plane == 0 ? u.y_stride : u.uv_stride);
    return int(pixels[pos.y*stride+pos.x]);
}
void write_pixel(uint plane, int2 pos, int value) {
    uint8_t* pixels = plane == 0 ? u.y : (plane == 1 ? u.cb : u.cr);
    int stride = int(plane == 0 ? u.y_stride : u.uv_stride);
    pixels[pos.y*stride+pos.x] = uint8_t(value);
}
void filter_sample(uint plane, int2 pos, int2 step, int alpha, int beta, uint bs, int tc0) {
    int p1 = read_pixel(plane, pos - 2 * step), p0 = read_pixel(plane, pos - step);
    int q0 = read_pixel(plane, pos), q1 = read_pixel(plane, pos + step);
    if (abs(p0-q0) >= alpha || abs(p1-p0) >= beta || abs(q1-q0) >= beta) return;
    if (plane != 0) {
        int delta = clamp(((q0-p0)*4 + p1-q1+4) >> 3, -tc0-1, tc0+1);
        write_pixel(plane, pos-step, bs == 4 ? (2*p1+p0+q1+2)>>2 : clamp(p0+delta,0,255));
        write_pixel(plane, pos, bs == 4 ? (2*q1+q0+p1+2)>>2 : clamp(q0-delta,0,255));
        return;
    }
    int p2 = read_pixel(plane,pos-3*step), q2 = read_pixel(plane,pos+2*step);
    bool ap = abs(p2-p0)<beta, aq = abs(q2-q0)<beta;
    if (bs < 4) {
        int tc = tc0+int(ap)+int(aq), mid = (p0+q0+1)>>1;
        int delta = clamp(((q0-p0)*4+p1-q1+4)>>3,-tc,tc);
        write_pixel(plane,pos-step,clamp(p0+delta,0,255));
        write_pixel(plane,pos,clamp(q0-delta,0,255));
        if(ap) write_pixel(plane,pos-2*step,p1+clamp((p2+mid-2*p1)>>1,-tc0,tc0));
        if(aq) write_pixel(plane,pos+step,q1+clamp((q2+mid-2*q1)>>1,-tc0,tc0));
    } else {
        bool near = abs(p0-q0)<((alpha>>2)+2);
        if(ap && near) {
            int p3=read_pixel(plane,pos-4*step);
            write_pixel(plane,pos-step,(p2+2*p1+2*p0+2*q0+q1+4)>>3);
            write_pixel(plane,pos-2*step,(p2+p1+p0+q0+2)>>2);
            write_pixel(plane,pos-3*step,(2*p3+3*p2+p1+p0+q0+4)>>3);
        } else write_pixel(plane,pos-step,(2*p1+p0+q1+2)>>2);
        if(aq && near) {
            int q3=read_pixel(plane,pos+3*step);
            write_pixel(plane,pos,(q2+2*q1+2*q0+2*p0+p1+4)>>3);
            write_pixel(plane,pos+step,(q2+q1+p0+q0+2)>>2);
            write_pixel(plane,pos+2*step,(2*q3+3*q2+q1+q0+p0+4)>>3);
        } else write_pixel(plane,pos,(2*q1+q0+p1+2)>>2);
    }
}

// Macroblocks on wave x+2*y have disjoint pixel footprints. Left, top and
// top-right dependencies have completed in earlier dispatches. The host inserts
// a compute memory barrier between waves. Byte stores have disjoint ownership.
[shader("compute")]
[numthreads(32, 1, 1)]
void cs_main(uint3 group : SV_GroupID, uint lane : SV_GroupIndex) {
    int y = int(group.x), x = int(u.wave)-2*y;
    if(y >= int(u.mb_height) || x<0 || x>=int(u.mb_width)) return;
    uint mb = uint(y)*u.mb_width+uint(x);
    DeblockMB* q=&u.mbs[mb];
    uint plane = lane<16 ? 0 : (lane<24 ? 1 : 2), sample = plane == 0 ? lane : (lane-16)&7;
    for(uint orientation=0; orientation<2; ++orientation) for(uint edge=0; edge<4; ++edge) {
        uint bs=(u.strengths[mb*8+orientation*4+edge] >> ((sample/(plane==0?4:2))*8))&255;
        if(bs!=0 && (plane==0 || (edge&1)==0)) {
            int pp=edge==0 ? u.mbs[mb-(orientation==0?1:u.mb_width)].qp : q.qp;
            int qp=(pp+q.qp+1)>>1;
            // H.264 8.7.2.2 derives admission from each plane's mapped QP.
            if(plane!=0) {
                int offset=plane==1?u.chroma0:u.chroma1;
                qp=(u.tables[312+clamp(pp+offset,0,51)]+u.tables[312+clamp(q.qp+offset,0,51)]+1)>>1;
            }
            int ia=clamp(qp+q.alpha_offset,0,51), ib=clamp(qp+q.beta_offset,0,51);
            int alpha=u.tables[ia], beta=u.tables[52+ib];
            if(alpha!=0 && beta!=0) {
                int size=plane==0?16:8, offset=int(edge)*(plane==0?4:2);
                int2 pos=int2(x*size,y*size)+(orientation==0?int2(offset,sample):int2(sample,offset));
                int tc0=bs<4?u.tables[104+ia*4+bs]:0;
                filter_sample(plane,pos,orientation==0?int2(1,0):int2(0,1),alpha,beta,bs,tc0);
            }
        }
        DeviceMemoryBarrierWithGroupSync();
    }
}

#include <cstdint>
#include <x264.h>
#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <vector>

using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point t) { return std::chrono::duration<double,std::milli>(Clock::now()-t).count(); }
static int integer(const char *s) {
    int value; const char *end=s+std::strlen(s);
    auto result=std::from_chars(s,end,value);
    if(result.ec!=std::errc{} || result.ptr!=end) std::exit(2);
    return value;
}
static double median(std::vector<double> v) { std::sort(v.begin(),v.end()); return v[v.size()/2]; }

// Same resident-input/codec/output-accumulation boundary as benchmark.odin.
int main(int argc,char **argv) {
    if(argc!=9 && argc!=10) { std::fprintf(stderr,"usage: x264_benchmark input.yuv width height frames workers slices qp output.264 [crf]\n"); return 2; }
    int w=integer(argv[2]),h=integer(argv[3]),frames=integer(argv[4]);
    int workers=integer(argv[5]),slices=integer(argv[6]),qp=integer(argv[7]);
    double crf=-1;
    if(argc==10) { char *end; crf=std::strtod(argv[9],&end); if(end==argv[9] || *end || !std::isfinite(crf) || crf<0 || crf>51) return 2; }
    if(w<=0 || h<=0 || w>16384 || h>16384 || (w|h)&1 || frames<2 || workers<1 || slices<1 || qp<0 || qp>51) return 2;
    FILE *file=std::fopen(argv[1],"rb"); if(!file) return 1;
    if(std::fseek(file,0,SEEK_END)) return 1;
    long size=std::ftell(file); if(size<0 || std::fseek(file,0,SEEK_SET)) return 1;
    size_t frame_bytes=size_t(w)*h*3/2;
    if(size_t(size)%frame_bytes || size_t(frames)>size_t(size)/frame_bytes) return 1;
    std::vector<uint8_t> input(size),output,baseline;
    if(std::fread(input.data(),1,input.size(),file)!=input.size() || std::fclose(file)) return 1;
    output.reserve(4*1024*1024);
    std::vector<double> times,init,first,steady,frame_times;
    int effective_workers=0,effective_slices=0;
    // ROUNDS (1 to 7, default 7): one round when only the stream matters.
    int rounds=std::getenv("ROUNDS")?std::clamp(std::atoi(std::getenv("ROUNDS")),1,7):7;
    for(int rep=0;rep<rounds;++rep) {
        auto t=Clock::now();
        x264_param_t p;
        if(x264_param_default_preset(&p,"medium",nullptr)) return 1;
        p.i_width=w; p.i_height=h; p.i_csp=X264_CSP_I420;
        p.i_fps_num=30; p.i_fps_den=1; p.b_vfr_input=0;
        p.i_keyint_max=15; p.i_keyint_min=1; p.i_scenecut_threshold=0;
        p.i_frame_reference=1; p.rc.i_rc_method=X264_RC_CQP; p.rc.i_qp_constant=qp;
        if(crf>=0) { p.rc.i_rc_method=X264_RC_CRF; p.rc.f_rf_constant=float(crf); }
        p.rc.f_ip_factor=1; p.rc.f_pb_factor=1;
        p.i_threads=workers; p.b_sliced_threads=1; p.i_slice_count=slices;
        p.i_sync_lookahead=0; p.rc.i_lookahead=0; p.i_log_level=X264_LOG_ERROR;
        if(x264_param_apply_profile(&p,"baseline")) return 1;
        x264_t *enc=x264_encoder_open(&p); if(!enc) return 1;
        init.push_back(ms(t));
        x264_encoder_parameters(enc,&p);
        effective_workers=p.i_threads; effective_slices=p.i_slice_count;
        output.clear();
        x264_picture_t pic,out; x264_picture_init(&pic);
        pic.img.i_csp=X264_CSP_I420; pic.img.i_plane=3;
        pic.img.i_stride[0]=w; pic.img.i_stride[1]=pic.img.i_stride[2]=w/2;
        int count=0;
        auto consume=[&](x264_picture_t *in) {
            x264_nal_t *nal; int n;
            int bytes=x264_encoder_encode(enc,&nal,&n,in,&out);
            if(bytes<0) std::exit(1);
            if(bytes) { ++count; output.insert(output.end(),nal[0].p_payload,nal[0].p_payload+bytes); }
        };
        double first_ms=0;
        t=Clock::now();
        for(int f=0;f<frames;++f) {
            auto start=Clock::now();
            auto src=input.data()+f*frame_bytes;
            pic.img.plane[0]=src; pic.img.plane[1]=src+size_t(w)*h; pic.img.plane[2]=src+size_t(w)*h*5/4;
            pic.i_pts=f; pic.i_type=f%15==0?X264_TYPE_IDR:X264_TYPE_P;
            consume(&pic);
            double elapsed=ms(start); frame_times.push_back(elapsed);
            if(f==0) { if(count!=1) { std::fprintf(stderr,"benchmark requires immediate frame output\n"); return 1; } first_ms=elapsed; }
        }
        while(x264_encoder_delayed_frames(enc)) consume(nullptr);
        times.push_back(ms(t)); first.push_back(first_ms); steady.push_back(times.back()-first_ms);
        if(count!=frames) return 1;
        x264_encoder_close(enc);
        if(rep==0) baseline=output;
        else if(baseline!=output) { std::fprintf(stderr,"nondeterministic x264 output\n"); return 1; }
    }
    file=std::fopen(argv[8],"wb"); if(!file) return 1;
    if(std::fwrite(output.data(),1,output.size(),file)!=output.size() || std::fclose(file)) return 1;
    std::sort(frame_times.begin(),frame_times.end());
    std::printf("x264 encode: frames=%d requested_workers=%d requested_slices=%d workers=%d slices=%d qp=%d bytes=%zu init_ms=%.3f codec_ms=%.3f fps=%.1f first_frame_ms=%.3f steady_fps=%.1f frame_p50_ms=%.3f frame_p95_ms=%.3f\n",
        frames,workers,slices,effective_workers,effective_slices,qp,output.size(),median(init),median(times),frames*1000/median(times),median(first),(frames-1)*1000/median(steady),frame_times[frame_times.size()/2],frame_times[frame_times.size()*95/100]);
    if(crf>=0) std::printf("rate_control=CRF crf=%.3f (qp argument unused)\n",crf);
}

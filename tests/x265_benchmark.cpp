#include <x265.h>
#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

using Clock = std::chrono::steady_clock;
static double ms(Clock::time_point t) { return std::chrono::duration<double,std::milli>(Clock::now()-t).count(); }
static int integer(const char *s) {
    int value;
    auto r = std::from_chars(s, s + std::strlen(s), value);
    if (r.ec != std::errc{} || *r.ptr) std::exit(2);
    return value;
}
static double median(std::vector<double> v) { std::sort(v.begin(),v.end()); return v[v.size()/2]; }

// Resident planar 8-bit 4:2:0 input; setup and output I/O are outside the timer.
// Low-delay, one reference, fixed QP, matching OICU's default tool envelope.
// Serial by default. Optional pool threads and WPP are reference controls;
// they are not native total-worker counts or native tile partitioning.
// Search decisions and psycho-visual tuning remain x265's.
int main(int argc, char **argv) {
    if (argc < 7) {
        std::fprintf(stderr,"usage: x265_benchmark input.yuv width height frames qp output.265 [--pool-threads N] [--wpp | --no-wpp]\n");
        return 2;
    }
    int w=integer(argv[2]), h=integer(argv[3]), frames=integer(argv[4]), qp=integer(argv[5]);
    if(w<=0 || h<=0 || w>8192 || h>8192 || ((w|h)&1) || frames<=0 || qp<0 || qp>51) return 2;
    int pool_threads=0, wpp=0;
    for(int i=7;i<argc;++i) {
        if(!std::strcmp(argv[i],"--pool-threads")) {
            if(++i>=argc) { std::fprintf(stderr,"--pool-threads requires a nonnegative integer\n"); return 2; }
            pool_threads=integer(argv[i]);
            if(pool_threads<0) { std::fprintf(stderr,"--pool-threads requires a nonnegative integer\n"); return 2; }
        } else if(!std::strcmp(argv[i],"--wpp")) wpp=1;
        else if(!std::strcmp(argv[i],"--no-wpp")) wpp=0;
        else { std::fprintf(stderr,"unknown option: %s\n",argv[i]); return 2; }
    }
    char pool_spec[32];
    if(pool_threads) std::snprintf(pool_spec,sizeof(pool_spec),"%d",pool_threads);
    else std::strcpy(pool_spec,"none");
    // The public API returns normalized parameters, not actual worker counts.
    // A numeric pool specification is an upper limit for NUMA node zero.
    x265_param resolved{};
    size_t frame_bytes=size_t(w)*h*3/2;
    std::vector<uint8_t> input(frame_bytes*frames), output, baseline;
    FILE *file=std::fopen(argv[1],"rb"); if(!file) return 1;
    if(std::fread(input.data(),1,input.size(),file)!=input.size() || std::fclose(file)) return 1;
    output.reserve(4*1024*1024);
    std::vector<double> times,init;
    // ROUNDS (1 to 7, default 7): one round when only the stream matters.
    int rounds=std::getenv("ROUNDS")?std::clamp(std::atoi(std::getenv("ROUNDS")),1,7):7;
    for(int rep=0;rep<rounds;++rep) {
        auto t=Clock::now();
        x265_param *p=x265_param_alloc(); if(!p) return 1;
        if(x265_param_default_preset(p,"medium",nullptr)) return 1;
        p->sourceWidth=w; p->sourceHeight=h;
        p->internalCsp=X265_CSP_I420; p->internalBitDepth=8;
        p->fpsNum=30; p->fpsDenom=1; p->totalFrames=frames;
        p->frameNumThreads=1;
        if(x265_param_parse(p,"pools",pool_spec)) return 1;
        p->bEnableWavefront=wpp; p->lookaheadDepth=0; p->bframes=0;
        p->keyframeMax=1000000; p->keyframeMin=1; p->scenecutThreshold=0;
        p->maxNumReferences=1; p->rc.rateControlMode=X265_RC_CQP; p->rc.qp=qp;
        p->rc.ipFactor=1; p->rc.pbFactor=1;
        p->maxCUSize=64; p->minCUSize=8; p->maxTUSize=32;
        p->tuQTMaxInterDepth=1; p->tuQTMaxIntraDepth=1;
        p->bEnableRectInter=0; p->bEnableAMP=0;
        p->bEnableTemporalMvp=0; p->bEnableStrongIntraSmoothing=0;
        p->bEnableWeightedPred=0; p->bEnableWeightedBiPred=0;
        p->logLevel=X265_LOG_ERROR;
        x265_encoder *enc=x265_encoder_open(p); if(!enc) return 1;
        x265_picture pic,out;
        x265_picture_init(p,&pic); x265_picture_init(p,&out);
        pic.bitDepth=8; pic.colorSpace=X265_CSP_I420;
        pic.stride[0]=w; pic.stride[1]=pic.stride[2]=w/2;
        init.push_back(ms(t)); output.clear();
        x265_encoder_parameters(enc,&resolved);
        int count=0;
        auto consume=[&](x265_picture *in) {
            x265_nal *nals; uint32_t n;
            int r=x265_encoder_encode(enc,&nals,&n,in,&out);
            if(r<0) std::exit(1);
            count+=r;
            for(uint32_t i=0;i<n;++i) output.insert(output.end(),nals[i].payload,nals[i].payload+nals[i].sizeBytes);
            return r;
        };
        t=Clock::now();
        x265_nal *headers; uint32_t n;
        if(x265_encoder_headers(enc,&headers,&n)<0) return 1;
        for(uint32_t i=0;i<n;++i) output.insert(output.end(),headers[i].payload,headers[i].payload+headers[i].sizeBytes);
        for(int f=0;f<frames;++f) {
            auto src=input.data()+size_t(f)*frame_bytes;
            pic.planes[0]=src; pic.planes[1]=src+size_t(w)*h; pic.planes[2]=src+size_t(w)*h*5/4;
            pic.pts=f; pic.sliceType=f==0?X265_TYPE_IDR:X265_TYPE_P;
            consume(&pic);
        }
        while(consume(nullptr)) {}
        times.push_back(ms(t));
        if(count!=frames) return 1;
        x265_encoder_close(enc); x265_param_free(p);
        if(rep==0) baseline=output;
        else if(baseline!=output) { std::fprintf(stderr,"nondeterministic x265 output\n"); return 1; }
    }
    file=std::fopen(argv[6],"wb"); if(!file) return 1;
    if(std::fwrite(output.data(),1,output.size(),file)!=output.size() || std::fclose(file)) return 1;
    std::printf("x265 encode: frames=%d qp=%d bytes=%zu init_ms=%.3f codec_ms=%.3f fps=%.1f requested_pool_threads=%d requested_wpp=%d resolved_pool_spec=%s resolved_frame_threads=%d resolved_wpp=%d\n",
        frames,qp,output.size(),median(init),median(times),frames*1000/median(times),
        pool_threads,wpp,resolved.numaPools,resolved.frameNumThreads,resolved.bEnableWavefront);
    x265_cleanup();
}

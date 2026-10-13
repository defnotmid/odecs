// Development-only public FFmpeg API oracle. Independent resident streams,
// persistent caller/worker slots, fresh contexts, seven codec-only medians.
// Setup, demux and a separate full-pixel verification pass are outside timers.
#include <algorithm>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <pthread.h>
#include <sched.h>
#include <semaphore.h>
#include <vector>
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
}
using Clock = std::chrono::steady_clock;
static void fail(const char *s) { std::fprintf(stderr,"reference video: %s\n",s); std::exit(1); }
static int integer(const char *s) {
    int n; auto e=s+std::strlen(s); auto r=std::from_chars(s,e,n);
    if(r.ec!=std::errc{} || r.ptr!=e) fail("invalid integer");
    return n;
}
static double ms(Clock::time_point t) { return std::chrono::duration<double,std::milli>(Clock::now()-t).count(); }
static void wait(sem_t *s) { while(sem_wait(s)) if(errno!=EINTR) fail("semaphore wait"); }
struct Job {
    AVCodecContext *ctx=nullptr;
    AVFrame *frame=nullptr;
    const std::vector<AVPacket*> *packets=nullptr;
    int frames=0, cpu=-1;
    uint64_t hash=14695981039346656037ull;
    bool verify=false, stop=false;
    sem_t go, ack;
    pthread_t thread;
};
static void pin(int cpu) {
    if(cpu<0) return;
    cpu_set_t mask, actual; CPU_ZERO(&mask); CPU_SET(cpu,&mask);
    if(sched_setaffinity(0,sizeof(mask),&mask) || sched_getaffinity(0,sizeof(actual),&actual) || !CPU_EQUAL(&mask,&actual)) fail("slot pin/verification");
}
static void digest(Job &j) {
    auto f=j.frame;
    if(f->format!=AV_PIX_FMT_YUV420P || (f->width|f->height)&1) fail("verification requires even 8-bit YUV420");
    for(int c=0;c<3;++c) {
        int w=c?f->width/2:f->width, h=c?f->height/2:f->height;
        for(int y=0;y<h;++y) for(int x=0;x<w;++x)
            j.hash=(j.hash^f->data[c][y*f->linesize[c]+x])*1099511628211ull;
    }
}
static void run(Job &j) {
    auto drain=[&]() {
        int r;
        while((r=avcodec_receive_frame(j.ctx,j.frame))>=0) {
            ++j.frames; if(j.verify) digest(j); av_frame_unref(j.frame);
        }
        if(r!=AVERROR(EAGAIN) && r!=AVERROR_EOF) fail("receive frame");
    };
    for(auto p:*j.packets) { if(avcodec_send_packet(j.ctx,p)<0) fail("send packet"); drain(); }
    if(avcodec_send_packet(j.ctx,nullptr)<0) fail("flush");
    drain();
}
static void *worker(void *ptr) {
    auto &j=*static_cast<Job*>(ptr); pin(j.cpu); sem_post(&j.ack);
    for(;;) { wait(&j.go); if(j.stop) return nullptr; run(j); sem_post(&j.ack); }
}
int main(int argc,char **argv) {
    if(argc!=4) { std::fprintf(stderr,"usage: reference_video_decode stream expected_frames independent_streams\n"); return 2; }
    int expected=integer(argv[2]), streams=integer(argv[3]);
    if(expected<=0 || streams<1 || streams>16) return 2;
    av_log_set_level(AV_LOG_ERROR);
    AVFormatContext *format=nullptr;
    if(avformat_open_input(&format,argv[1],nullptr,nullptr)<0 || avformat_find_stream_info(format,nullptr)<0) fail("input demux");
    int index=av_find_best_stream(format,AVMEDIA_TYPE_VIDEO,-1,-1,nullptr,0); if(index<0) fail("video stream");
    std::vector<AVPacket*> packets;
    for(;;) {
        AVPacket *p=av_packet_alloc(); if(!p) fail("packet allocation");
        int r=av_read_frame(format,p);
        if(r<0) { av_packet_free(&p); if(r!=AVERROR_EOF) fail("packet read"); break; }
        if(p->stream_index==index) packets.push_back(p); else av_packet_free(&p);
    }
    auto codec=avcodec_find_decoder(format->streams[index]->codecpar->codec_id); if(!codec) fail("decoder unavailable");
    std::vector<Job> jobs(streams);
    const char *cpus=std::getenv("VIDEO_CPUS");
    if(cpus) {
        cpu_set_t allowed; if(sched_getaffinity(0,sizeof(allowed),&allowed)) fail("initial CPU mask");
        const char *start=cpus; int slot=0;
        for(auto p=cpus;;++p) {
            if(*p && *p!=',') continue;
            if(slot>=streams || p==start) fail("CPU slot count");
            int cpu; auto r=std::from_chars(start,p,cpu);
            if(r.ec!=std::errc{} || r.ptr!=p || cpu<0 || cpu>=CPU_SETSIZE || !CPU_ISSET(cpu,&allowed)) fail("invalid CPU slot");
            for(int i=0;i<slot;++i) if(jobs[i].cpu==cpu) fail("duplicate CPU slot");
            jobs[slot++].cpu=cpu;
            if(!*p) break;
            start=p+1;
        }
        if(slot!=streams) fail("CPU slot count");
    }
    for(int i=1;i<streams;++i) {
        if(sem_init(&jobs[i].go,0,0) || sem_init(&jobs[i].ack,0,0) || pthread_create(&jobs[i].thread,nullptr,worker,&jobs[i])) fail("worker creation");
    }
    for(int i=1;i<streams;++i) wait(&jobs[i].ack);
    pin(jobs[0].cpu);
    std::vector<double> times,init_times;
    for(int round=0;round<8;++round) {
        auto t=Clock::now();
        for(auto &j:jobs) {
            j.frames=0; j.hash=14695981039346656037ull; j.verify=round==7; j.packets=&packets;
            j.ctx=avcodec_alloc_context3(codec); if(!j.ctx) fail("context allocation");
            if(avcodec_parameters_to_context(j.ctx,format->streams[index]->codecpar)<0) fail("parameters");
            j.ctx->thread_count=1; j.ctx->err_recognition=AV_EF_EXPLODE;
            if(avcodec_open2(j.ctx,codec,nullptr)<0) fail("decoder open");
            j.frame=av_frame_alloc(); if(!j.frame) fail("frame allocation");
        }
        if(round<7) init_times.push_back(ms(t));
        t=Clock::now();
        for(int i=1;i<streams;++i) sem_post(&jobs[i].go);
        run(jobs[0]);
        for(int i=1;i<streams;++i) wait(&jobs[i].ack);
        if(round<7) times.push_back(ms(t));
        for(auto &j:jobs) {
            if(j.frames!=expected) fail("frame count");
            av_frame_free(&j.frame); avcodec_free_context(&j.ctx);
        }
    }
    for(auto &j:jobs) if(j.hash!=jobs[0].hash) fail("stream verification differs");
    std::sort(times.begin(),times.end()); std::sort(init_times.begin(),init_times.end());
    std::printf("reference video decode: codec=%s frames=%d independent_streams=%d context_threads=1 init_ms=%.3f codec_ms=%.3f min_ms=%.3f max_ms=%.3f aggregate_fps=%.1f verification_hash=%016llx verification=separate_full_pixel_pass cpus=%s ffmpeg_version=%s\n",codec->name,expected,streams,init_times[3],times[3],times[0],times[6],expected*streams*1000/times[3],static_cast<unsigned long long>(jobs[0].hash),cpus?cpus:"initial_mask",av_version_info());
    for(int i=1;i<streams;++i) { jobs[i].stop=true; sem_post(&jobs[i].go); pthread_join(jobs[i].thread,nullptr); sem_destroy(&jobs[i].go); sem_destroy(&jobs[i].ack); }
    for(auto p:packets) av_packet_free(&p);
    avformat_close_input(&format);
}

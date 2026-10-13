#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
}
static int integer(const char *s) { int v; auto end=s+std::strlen(s); auto r=std::from_chars(s,end,v); if(r.ec!=std::errc{} || r.ptr!=end) std::exit(2); return v; }
using Clock=std::chrono::steady_clock;
static double ms(Clock::time_point t) { return std::chrono::duration<double,std::milli>(Clock::now()-t).count(); }

// Demux and input reads are outside the codec timer; EOS and frame counting are inside.
int main(int argc,char **argv) {
    if(argc!=4) { std::fprintf(stderr,"usage: ffmpeg_benchmark stream expected_frames workers\n"); return 2; }
    int expected=integer(argv[2]),workers=integer(argv[3]); if(expected<=0 || workers<=0) return 2;
    av_log_set_level(AV_LOG_ERROR);
    AVFormatContext *format=nullptr;
    if(avformat_open_input(&format,argv[1],nullptr,nullptr)<0 || avformat_find_stream_info(format,nullptr)<0) return 1;
    int stream=av_find_best_stream(format,AVMEDIA_TYPE_VIDEO,-1,-1,nullptr,0); if(stream<0) return 1;
    std::vector<AVPacket*> packets;
    for(;;) {
        AVPacket *packet=av_packet_alloc(); if(!packet) return 1;
        int r=av_read_frame(format,packet);
        if(r<0) { av_packet_free(&packet); if(r!=AVERROR_EOF) return 1; break; }
        if(packet->stream_index==stream) packets.push_back(packet); else av_packet_free(&packet);
    }
    std::vector<double> times,initializations;
    for(int rep=0;rep<7;++rep) {
        auto t=Clock::now();
        const AVCodec *codec=avcodec_find_decoder(format->streams[stream]->codecpar->codec_id); if(!codec) return 1;
        AVCodecContext *ctx=avcodec_alloc_context3(codec); if(!ctx) return 1;
        if(avcodec_parameters_to_context(ctx,format->streams[stream]->codecpar)<0) return 1;
        ctx->thread_count=workers; ctx->err_recognition=AV_EF_EXPLODE;
        if(avcodec_open2(ctx,codec,nullptr)<0) return 1;
        AVFrame *frame=av_frame_alloc(); if(!frame) return 1;
        initializations.push_back(ms(t));
        int count=0;
        auto drain=[&]() { int r; while((r=avcodec_receive_frame(ctx,frame))>=0) { ++count; av_frame_unref(frame); } if(r!=AVERROR(EAGAIN) && r!=AVERROR_EOF) std::exit(1); };
        t=Clock::now();
        for(auto packet:packets) { if(avcodec_send_packet(ctx,packet)<0) return 1; drain(); }
        if(avcodec_send_packet(ctx,nullptr)<0) return 1;
        drain(); times.push_back(ms(t));
        if(count!=expected) { std::fprintf(stderr,"expected %d frames, decoded %d\n",expected,count); return 1; }
        av_frame_free(&frame); avcodec_free_context(&ctx);
    }
    std::sort(times.begin(),times.end()); std::sort(initializations.begin(),initializations.end());
    std::printf("ffmpeg decode: frames=%d workers=%d init_ms=%.3f min_ms=%.3f codec_ms=%.3f max_ms=%.3f fps=%.1f\n",expected,workers,initializations[3],times[0],times[3],times[6],expected*1000/times[3]);
    for(auto packet:packets) av_packet_free(&packet);
    avformat_close_input(&format);
}

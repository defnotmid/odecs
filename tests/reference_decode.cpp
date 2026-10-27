// Development-only FFmpeg oracle for tests/compare.sh: one stream of
// any container, its packets resident, a fresh decoder per round (one
// thread, or THREADS slice and frame threads), decode and flush timed
// (opening the decoder is not), median of seven after a warmup. Frames or
// samples are counted, never touched. HWACCEL=vulkan decodes video through
// FFmpeg's Vulkan Video and downloads each frame to host memory, timed.
//   [THREADS=n] [HWACCEL=vulkan] reference_decode FILE video|audio [decoder]   (decoder: e.g. libvpx-vp9)
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
}
using Clock = std::chrono::steady_clock;
static void fail(const char *s) { std::fprintf(stderr, "reference decode: %s\n", s); std::exit(1); }

static AVPixelFormat vulkan_format(AVCodecContext *, const AVPixelFormat *formats) {
    for (; *formats != AV_PIX_FMT_NONE; ++formats) if (*formats == AV_PIX_FMT_VULKAN) return *formats;
    fail("no Vulkan decoding for this stream");
    return AV_PIX_FMT_NONE;
}

int main(int argc, char **argv) {
    if (argc < 3 || argc > 4) { std::fprintf(stderr, "usage: reference_decode FILE video|audio [decoder]\n"); return 2; }
    bool video = std::strcmp(argv[2], "video") == 0;
    if (!video && std::strcmp(argv[2], "audio") != 0) return 2;
    av_log_set_level(AV_LOG_ERROR);
    AVFormatContext *format = nullptr;
    if (avformat_open_input(&format, argv[1], nullptr, nullptr) < 0 || avformat_find_stream_info(format, nullptr) < 0) fail("demux");
    int index = av_find_best_stream(format, video ? AVMEDIA_TYPE_VIDEO : AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    if (index < 0) fail("no such stream");
    std::vector<AVPacket *> packets;
    for (;;) {
        AVPacket *p = av_packet_alloc();
        int r = av_read_frame(format, p);
        if (r < 0) { av_packet_free(&p); if (r != AVERROR_EOF) fail("packet read"); break; }
        if (p->stream_index == index) packets.push_back(p); else av_packet_free(&p);
    }
    const AVCodec *codec = argc == 4 ? avcodec_find_decoder_by_name(argv[3])
                                     : avcodec_find_decoder(format->streams[index]->codecpar->codec_id);
    if (!codec) fail("decoder unavailable");
    AVFrame *frame = av_frame_alloc();
    std::vector<double> times;
    int threads = std::getenv("THREADS") ? std::atoi(std::getenv("THREADS")) : 1;
    if (threads < 1) fail("THREADS");
    const char *hwaccel = std::getenv("HWACCEL");
    AVBufferRef *device = nullptr;
    if (hwaccel && (std::strcmp(hwaccel, "vulkan") || av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VULKAN, nullptr, nullptr, 0) < 0))
        fail("HWACCEL: no Vulkan device");
    AVFrame *host = av_frame_alloc();
    long long units = 0;
    for (int round = 0; round < 8; ++round) {
        AVCodecContext *ctx = avcodec_alloc_context3(codec);
        if (!ctx || avcodec_parameters_to_context(ctx, format->streams[index]->codecpar) < 0) fail("context");
        ctx->thread_count = threads;
        ctx->thread_type = threads > 1 ? FF_THREAD_SLICE | FF_THREAD_FRAME : 0;
        if (device) {
            ctx->hw_device_ctx = av_buffer_ref(device);
            ctx->get_format = vulkan_format;
        }
        if (avcodec_open2(ctx, codec, nullptr) < 0) fail("decoder open");
        units = 0;
        auto drain = [&] {
            int r;
            while ((r = avcodec_receive_frame(ctx, frame)) >= 0) {
                units += video ? 1 : frame->nb_samples;
                if (device) {
                    if (av_hwframe_transfer_data(host, frame, 0) < 0) fail("download");
                    av_frame_unref(host);
                }
                av_frame_unref(frame);
            }
            if (r != AVERROR(EAGAIN) && r != AVERROR_EOF) fail("receive frame");
        };
        auto t = Clock::now();
        for (auto p : packets) { if (avcodec_send_packet(ctx, p) < 0) fail("send packet"); drain(); }
        if (avcodec_send_packet(ctx, nullptr) < 0) fail("flush");
        drain();
        double ms = std::chrono::duration<double, std::milli>(Clock::now() - t).count();
        if (round > 0) times.push_back(ms);
        avcodec_free_context(&ctx);
    }
    std::sort(times.begin(), times.end());
    std::printf("reference decode: decoder=%s %s=%lld packets=%zu codec_ms=%.3f min_ms=%.3f max_ms=%.3f ffmpeg=%s\n",
                codec->name, video ? "frames" : "samples", units, packets.size(), times[3], times[0], times[6], av_version_info());
    for (auto p : packets) av_packet_free(&p);
    av_frame_free(&frame);
    av_frame_free(&host);
    av_buffer_unref(&device);
    avformat_close_input(&format);
}

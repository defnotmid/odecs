// Development-only FFmpeg Vulkan Video encoder for tests/compare.sh, set up
// as video.Writer sets up odecs' (tests/movie_encode_timing.odin): the same
// 30 synthetic I420 pictures cycled, constant QP 23, a keyframe every 15,
// IDR and P pictures with one reference. Each picture is converted to NV12
// and uploaded inside the timer, as odecs uploads its I420 planes. Five fresh
// encoders, whose outputs must be identical; the median, init not timed.
//   reference_vulkan_encode h264|h265 [W H FRAMES]
#define _POSIX_C_SOURCE 200809L
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define ROUNDS 5
#define SOURCES 30

static double now_ms(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int by_value(const void *a, const void *b) {
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static void fail(const char *s) {
	fprintf(stderr, "reference vulkan encode: %s\n", s);
	exit(1);
}

int main(int argc, char **argv) {
	if (argc != 2 && argc != 5) {
		fprintf(stderr, "usage: reference_vulkan_encode h264|h265 [W H FRAMES]\n");
		return 2;
	}
	int h265 = !strcmp(argv[1], "h265");
	int W = 1920, H = 1080, frames = 900;
	if (argc == 5) W = atoi(argv[2]), H = atoi(argv[3]), frames = atoi(argv[4]);
	if (W <= 0 || H <= 0 || (W | H) & 1 || frames < 1) return 2;

	// tests/movie_encode_timing.odin's pictures: a gradient drifting right and
	// a square moving down, so P pictures carry real motion.
	size_t luma = (size_t)W * H, chroma = luma / 4;
	unsigned char *pictures = malloc(SOURCES * (luma + 2 * chroma));
	if (!pictures) fail("memory");
	for (int s = 0; s < SOURCES; s++) {
		unsigned char *p = pictures + s * (luma + 2 * chroma);
		for (int y = 0; y < H; y++)
			for (int x = 0; x < W; x++) {
				int inside = abs(x - W / 2) < H / 6 && abs(y - s * H / SOURCES) < H / 6;
				p[y * W + x] = inside ? 235 : (unsigned char)(16 + (x + y + s * 8) % 200);
			}
		for (int y = 0; y < H / 2; y++)
			for (int x = 0; x < W / 2; x++) {
				p[luma + y * W / 2 + x] = (unsigned char)(128 + (x - y + s) % 64 - 32);
				p[luma + chroma + y * W / 2 + x] = (unsigned char)(96 + (x * 2 + s * 3) % 64);
			}
	}

	AVBufferRef *device = NULL;
	if (av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VULKAN, NULL, NULL, 0) < 0) fail("no Vulkan device");
	const AVCodec *codec = avcodec_find_encoder_by_name(h265 ? "hevc_vulkan" : "h264_vulkan");
	if (!codec) fail("no Vulkan encoder");
	AVFrame *host = av_frame_alloc(), *hw = av_frame_alloc();
	AVPacket *packet = av_packet_alloc();
	host->format = AV_PIX_FMT_NV12, host->width = W, host->height = H;
	if (!host || !hw || !packet || av_frame_get_buffer(host, 0) < 0) fail("frames");

	double times[ROUNDS];
	size_t bytes = 0;
	unsigned long long hashes[ROUNDS];
	for (int round = 0; round < ROUNDS; round++) {
		AVBufferRef *pool = av_hwframe_ctx_alloc(device);
		if (!pool) fail("frames context");
		AVHWFramesContext *fc = (AVHWFramesContext *)pool->data;
		fc->format = AV_PIX_FMT_VULKAN, fc->sw_format = AV_PIX_FMT_NV12, fc->width = W, fc->height = H;
		if (av_hwframe_ctx_init(pool) < 0) fail("frames context init");
		AVCodecContext *ctx = avcodec_alloc_context3(codec);
		ctx->width = W, ctx->height = H, ctx->pix_fmt = AV_PIX_FMT_VULKAN;
		ctx->time_base = (AVRational){1, 30}, ctx->framerate = (AVRational){30, 1};
		ctx->gop_size = 15, ctx->max_b_frames = 0, ctx->refs = 1;
		ctx->hw_frames_ctx = av_buffer_ref(pool);
		av_opt_set(ctx->priv_data, "rc_mode", "cqp", 0);
		av_opt_set_int(ctx->priv_data, "qp", 23, 0);
		if (avcodec_open2(ctx, codec, NULL) < 0) fail("encoder open");
		unsigned long long hash = 14695981039346656037ull;
		bytes = 0;
		int out = 0;
		double t = now_ms();
		for (int f = 0; f <= frames; f++) {
			if (f < frames) {
				const unsigned char *p = pictures + (f % SOURCES) * (luma + 2 * chroma);
				if (av_frame_make_writable(host) < 0) fail("host frame");
				for (int y = 0; y < H; y++) memcpy(host->data[0] + y * host->linesize[0], p + y * W, W);
				for (int y = 0; y < H / 2; y++) {
					unsigned char *uv = host->data[1] + y * host->linesize[1];
					const unsigned char *u = p + luma + y * W / 2, *v = p + luma + chroma + y * W / 2;
					for (int x = 0; x < W / 2; x++) uv[2 * x] = u[x], uv[2 * x + 1] = v[x];
				}
				if (av_hwframe_get_buffer(pool, hw, 0) < 0 || av_hwframe_transfer_data(hw, host, 0) < 0) fail("upload");
				hw->pts = f;
				if (avcodec_send_frame(ctx, hw) < 0) fail("send frame");
				av_frame_unref(hw);
			} else if (avcodec_send_frame(ctx, NULL) < 0) fail("flush");
			int r;
			while ((r = avcodec_receive_packet(ctx, packet)) >= 0) {
				for (int i = 0; i < packet->size; i++) hash = (hash ^ packet->data[i]) * 1099511628211ull;
				bytes += packet->size;
				out++;
				av_packet_unref(packet);
			}
			if (r != AVERROR(EAGAIN) && r != AVERROR_EOF) fail("receive packet");
		}
		times[round] = now_ms() - t;
		if (out != frames) fail("packet count");
		hashes[round] = hash;
		avcodec_free_context(&ctx);
		av_buffer_unref(&pool);
	}
	for (int round = 1; round < ROUNDS; round++)
		if (hashes[round] != hashes[0]) fail("rounds wrote different bytes");
	qsort(times, ROUNDS, sizeof times[0], by_value);
	printf("ffmpeg vulkan encode: codec=%s frames=%d bytes=%zu codec_ms=%.1f ms_per_frame=%.3f\n", codec->name, frames, bytes,
	       times[ROUNDS / 2], times[ROUNDS / 2] / frames);
	av_packet_free(&packet);
	av_frame_free(&host);
	av_frame_free(&hw);
	av_buffer_unref(&device);
	free(pictures);
	return 0;
}

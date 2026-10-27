// Development-only libvpx VP9 encoder for tests/compare.sh: resident I420
// input, one thread, good deadline at cpu-used 4, constant quality
// (end-usage q at the given cq-level), no lag and so no alt-ref, four tile
// columns, a keyframe every GOP frames; cq-level "lossless" codes losslessly.
// Seven fresh encoders (or ROUNDS), whose outputs must be identical; times
// the encode calls and the flush, not init.
//   reference_vp9_encode input.yuv width height frames cq-level|lossless gop output.ivf
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vpx/vp8cx.h>
#include <vpx/vpx_encoder.h>

static double now_ms(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int by_value(const void *a, const void *b) {
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

static void put32(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

typedef struct {
	unsigned char *data;
	size_t len, cap;
} Bytes;

static void append(Bytes *b, const void *p, size_t n) {
	if (b->len + n > b->cap) {
		b->cap = (b->len + n) * 2;
		b->data = realloc(b->data, b->cap);
		if (!b->data) exit(1);
	}
	memcpy(b->data + b->len, p, n);
	b->len += n;
}

// IVF frame records (12-byte header, then the frame) for every packet out.
static int drain(vpx_codec_ctx_t *codec, Bytes *out, int *count) {
	const vpx_codec_cx_pkt_t *pkt;
	vpx_codec_iter_t iter = NULL;
	int got = 0;
	while ((pkt = vpx_codec_get_cx_data(codec, &iter))) {
		if (pkt->kind != VPX_CODEC_CX_FRAME_PKT) continue;
		unsigned char h[12];
		put32(h, (unsigned)pkt->data.frame.sz);
		put32(h + 4, (unsigned)pkt->data.frame.pts);
		put32(h + 8, (unsigned)(pkt->data.frame.pts >> 32));
		append(out, h, 12);
		append(out, pkt->data.frame.buf, pkt->data.frame.sz);
		*count += 1;
		got = 1;
	}
	return got;
}

int main(int argc, char **argv) {
	if (argc != 8) {
		fprintf(stderr, "usage: reference_vp9_encode input.yuv width height frames cq-level|lossless gop output.ivf\n");
		return 2;
	}
	int lossless = !strcmp(argv[5], "lossless");
	int w = atoi(argv[2]), h = atoi(argv[3]), frames = atoi(argv[4]), cq = lossless ? 0 : atoi(argv[5]), gop = atoi(argv[6]);
	if (w <= 0 || h <= 0 || (w | h) & 1 || frames < 1 || cq < 0 || cq > 63 || gop < 1) return 2;
	size_t frame_bytes = (size_t)w * h * 3 / 2;
	FILE *f = fopen(argv[1], "rb");
	if (!f) return 1;
	unsigned char *input = malloc(frame_bytes * frames);
	if (!input || fread(input, 1, frame_bytes * frames, f) != frame_bytes * frames) return 1;
	fclose(f);

	// ROUNDS (1 to 7, default 7): one round when only the stream matters.
	int rounds = getenv("ROUNDS") ? atoi(getenv("ROUNDS")) : 7;
	if (rounds < 1 || rounds > 7) return 2;
	double times[7], init[7];
	Bytes out = {0}, first = {0};
	for (int round = 0; round < rounds; round++) {
		double t = now_ms();
		vpx_codec_enc_cfg_t cfg;
		if (vpx_codec_enc_config_default(vpx_codec_vp9_cx(), &cfg, 0)) return 1;
		cfg.g_w = w;
		cfg.g_h = h;
		cfg.g_timebase.num = 1;
		cfg.g_timebase.den = 30;
		cfg.g_threads = 1;
		cfg.g_lag_in_frames = 0;
		cfg.g_pass = VPX_RC_ONE_PASS;
		cfg.rc_end_usage = VPX_Q;
		cfg.kf_mode = VPX_KF_AUTO;
		cfg.kf_min_dist = gop;
		cfg.kf_max_dist = gop;
		vpx_codec_ctx_t codec;
		if (vpx_codec_enc_init(&codec, vpx_codec_vp9_cx(), &cfg, 0)) return 1;
		if (vpx_codec_control(&codec, VP8E_SET_CPUUSED, 4) || vpx_codec_control(&codec, VP8E_SET_CQ_LEVEL, cq) ||
		    vpx_codec_control(&codec, VP9E_SET_TILE_COLUMNS, 2) || vpx_codec_control(&codec, VP8E_SET_ENABLEAUTOALTREF, 0) ||
		    vpx_codec_control(&codec, VP9E_SET_ROW_MT, 0) || vpx_codec_control(&codec, VP9E_SET_LOSSLESS, lossless))
			return 1;
		init[round] = now_ms() - t;
		out.len = 0;
		unsigned char header[32] = "DKIF";
		header[4] = 0, header[5] = 0, header[6] = 32, header[7] = 0;
		memcpy(header + 8, "VP90", 4);
		header[12] = w, header[13] = w >> 8, header[14] = h, header[15] = h >> 8;
		put32(header + 16, 30);
		put32(header + 20, 1);
		put32(header + 24, frames);
		append(&out, header, 32);
		int count = 0;
		t = now_ms();
		for (int i = 0; i < frames; i++) {
			vpx_image_t img;
			vpx_img_wrap(&img, VPX_IMG_FMT_I420, w, h, 1, input + frame_bytes * i);
			if (vpx_codec_encode(&codec, &img, i, 1, 0, VPX_DL_GOOD_QUALITY)) return 1;
			drain(&codec, &out, &count);
		}
		do {
			if (vpx_codec_encode(&codec, NULL, -1, 1, 0, VPX_DL_GOOD_QUALITY)) return 1;
		} while (drain(&codec, &out, &count));
		times[round] = now_ms() - t;
		vpx_codec_destroy(&codec);
		if (count != frames) return 1;
		if (round == 0) append(&first, out.data, out.len);
		else if (out.len != first.len || memcmp(out.data, first.data, out.len)) {
			fprintf(stderr, "nondeterministic libvpx output\n");
			return 1;
		}
	}
	f = fopen(argv[7], "wb");
	if (!f || fwrite(out.data, 1, out.len, f) != out.len || fclose(f)) return 1;
	qsort(times, rounds, sizeof times[0], by_value);
	qsort(init, rounds, sizeof init[0], by_value);
	printf("libvpx vp9 encode: frames=%d cq=%d bytes=%zu init_ms=%.3f codec_ms=%.3f fps=%.1f\n", frames, cq,
	       out.len - 32 - (size_t)12 * frames, init[rounds / 2], times[rounds / 2], frames * 1000 / times[rounds / 2]);
	return 0;
}

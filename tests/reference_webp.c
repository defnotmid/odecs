// Development-only libwebp oracle for tests/decode_benchmark.sh: one WebP
// file resident, WebPDecodeRGBA timed, median of seven after a warmup.
//   reference_webp FILE
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <webp/decode.h>

static double now_ms(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int by_value(const void *a, const void *b) {
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

int main(int argc, char **argv) {
	if (argc != 2) { fprintf(stderr, "usage: reference_webp FILE\n"); return 2; }
	FILE *f = fopen(argv[1], "rb");
	if (!f) { fprintf(stderr, "reference webp: cannot open\n"); return 1; }
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *data = malloc(size);
	if (!data || fread(data, 1, size, f) != (size_t)size) { fprintf(stderr, "reference webp: cannot read\n"); return 1; }
	fclose(f);
	double times[7];
	int width = 0, height = 0;
	for (int round = 0; round < 8; ++round) {
		double t = now_ms();
		uint8_t *rgba = WebPDecodeRGBA(data, size, &width, &height);
		double ms = now_ms() - t;
		if (!rgba) { fprintf(stderr, "reference webp: decode failed\n"); return 1; }
		WebPFree(rgba);
		if (round > 0) times[round - 1] = ms;
	}
	qsort(times, 7, sizeof times[0], by_value);
	int version = WebPGetDecoderVersion();
	printf("reference decode: decoder=libwebp pixels=%d codec_ms=%.3f min_ms=%.3f max_ms=%.3f libwebp=%d.%d.%d\n", width * height,
	       times[3], times[0], times[6], version >> 16, version >> 8 & 0xff, version & 0xff);
	free(data);
	return 0;
}

/* The libopus side of tests/opus_check.sh's loss tests: decodes an
 * opus_demo bitstream (.bit) to 16-bit PCM like tests/opus_decode.odin,
 * concealing each packet the loss file marks (one 0 or 1 per packet) with
 * opus_decode(NULL) for the last packet's duration. With "fec", the last
 * packet of each loss is recovered from the next packet's in-band FEC
 * instead, as opus_demo does.
 *   opus_loss_ref in.bit loss.txt out.pcm channels [fec]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "opus.h"

static unsigned be32(const unsigned char *b) {
	return (unsigned)b[0] << 24 | (unsigned)b[1] << 16 | (unsigned)b[2] << 8 | b[3];
}

int main(int argc, char **argv) {
	if (argc < 5) {
		fprintf(stderr, "usage: opus_loss_ref in.bit loss.txt out.pcm channels [fec]\n");
		return 2;
	}
	FILE *in = fopen(argv[1], "rb"), *loss = fopen(argv[2], "r"), *out = fopen(argv[3], "wb");
	int channels = atoi(argv[4]), fec = argc > 5 && strcmp(argv[5], "fec") == 0, err;
	if (!in || !loss || !out) return 1;
	OpusDecoder *dec = opus_decoder_create(48000, channels, &err);
	if (err != OPUS_OK) return 1;
	/* All packets first: error correction reads the one after a loss. */
	static unsigned char *packet[100000];
	static int size[100000], lost[100000];
	int count = 0;
	unsigned char head[8];
	while (count < 100000 && fread(head, 1, 8, in) == 8) {
		size[count] = (int)be32(head);
		packet[count] = malloc(size[count] + 1);
		if (fread(packet[count], 1, size[count], in) != (size_t)size[count]) break;
		if (fscanf(loss, "%d", &lost[count]) != 1) lost[count] = 0;
		count++;
	}
	static opus_int16 pcm[5760 * 2];
	for (int i = 0; i < count; i++) {
		int n;
		if (lost[i]) {
			opus_int32 last = 0;
			opus_decoder_ctl(dec, OPUS_GET_LAST_PACKET_DURATION(&last));
			if (fec && i + 1 < count && !lost[i + 1])
				n = opus_decode(dec, packet[i + 1], size[i + 1], pcm, last, 1);
			else
				n = opus_decode(dec, NULL, 0, pcm, last, 0);
		} else {
			n = opus_decode(dec, packet[i], size[i], pcm, 5760, 0);
		}
		if (n < 0) {
			fprintf(stderr, "decode: %s\n", opus_strerror(n));
			return 1;
		}
		fwrite(pcm, 2 * channels, n, out);
	}
	opus_decoder_destroy(dec);
	fclose(out);
	return 0;
}

// Resident AAC reference oracle. Only public installed libavcodec/libavutil APIs.
// No production codec dependency: build/run this optional benchmark separately.
// Pool workers process independent full streams; AAC contexts remain serial.
// PCM conversion, padded raw-packet preparation, persistent pool creation,
// fresh context initialization and output reservation are outside the timer.
// The timer includes
// dispatch/join, codec calls, ADTS parsing/framing, output copies and s16 packing.
// Optional AUDIO_CPUS=cpu0,cpu1,... assigns one initially permitted CPU per
// fixed stream slot, including the caller; pin/verification is outside timers.
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/log.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#ifdef __linux__
#include <sched.h>
#endif
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { FRAME_SAMPLES = 1024, ROUNDS = 7, MAX_WORKERS = 16 };
static const int rates[] = {96000, 88200, 64000, 48000, 44100, 32000,
                           24000, 22050, 16000, 12000, 11025, 8000};
typedef struct { uint8_t *data; size_t len, cap; } Buffer;
typedef struct {
    int pinned;
    int cpus[MAX_WORKERS];
#ifdef __linux__
    cpu_set_t permitted;
#endif
} Placement;
typedef struct {
    int encode, rate, channels, bitrate, rate_index, workers;
    Buffer input;
    size_t sample_frames, frames, output_capacity;
    AVFrame **pcm;
    AVPacket **packets;
} Input;
typedef struct {
    const Input *input;
    AVCodecContext *codec;
    AVPacket *packet;
    AVFrame *frame;
    Buffer output;
    size_t frames, sample_frames;
    int error;
    char message[256];
} Job;
typedef struct Pool Pool;
typedef struct { Pool *pool; int index; } Worker;
struct Pool {
    pthread_mutex_t mutex;
    pthread_cond_t start, finish;
    pthread_t threads[MAX_WORKERS - 1];
    Worker workers[MAX_WORKERS - 1];
    const Placement *placement;
    Job *jobs;
    int count, stop, generation, completed, ready;
};

static void fail(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
    fputc('\n', stderr); exit(1);
}
static int number(const char *text) {
    char *end; errno = 0; long n = strtol(text, &end, 10);
    if (errno || end == text || *end || n < 0 || n > INT_MAX)
        fail("invalid nonnegative integer: %s", text);
    return (int)n;
}
static void prepare_placement(Placement *p, int workers) {
    const char *list = getenv("AUDIO_CPUS");
#ifdef __linux__
    if (sched_getaffinity(0, sizeof(p->permitted), &p->permitted))
        fail("cannot query initial permitted CPU mask: %s", strerror(errno));
    if (!list) return;
    p->pinned = 1;
    cpu_set_t selected; CPU_ZERO(&selected);
    int count = 0;
    const char *cursor = list;
    for (;;) {
        if (*cursor < '0' || *cursor > '9')
            fail("AUDIO_CPUS requires nonempty comma-separated decimal CPU IDs");
        int cpu = 0;
        do {
            int digit = *cursor++ - '0';
            if (cpu > (CPU_SETSIZE - 1 - digit) / 10)
                fail("AUDIO_CPUS CPU ID exceeds supported mask bound %d", CPU_SETSIZE - 1);
            cpu = cpu * 10 + digit;
        } while (*cursor >= '0' && *cursor <= '9');
        if (count >= workers) fail("AUDIO_CPUS must have exactly %d entries", workers);
        if (!CPU_ISSET(cpu, &p->permitted))
            fail("AUDIO_CPUS CPU %d is outside the initial permitted mask", cpu);
        if (CPU_ISSET(cpu, &selected)) fail("AUDIO_CPUS CPUs must be distinct: %d", cpu);
        CPU_SET(cpu, &selected); p->cpus[count++] = cpu;
        if (!*cursor) break;
        if (*cursor++ != ',') fail("AUDIO_CPUS requires comma-separated decimal CPU IDs");
    }
    if (count != workers) fail("AUDIO_CPUS must have exactly %d entries", workers);
#else
    (void)p; (void)workers;
    if (list) fail("AUDIO_CPUS is supported only on Linux");
#endif
}
static void pin_current_slot(const Placement *p, int slot) {
    if (!p->pinned) return;
#ifdef __linux__
    cpu_set_t current, wanted; int cpu = p->cpus[slot];
    CPU_ZERO(&current);
    int error = pthread_getaffinity_np(pthread_self(), sizeof(current), &current);
    if (error) fail("cannot query CPU affinity for slot %d: %s", slot, strerror(error));
    if (!CPU_ISSET(cpu, &current))
        fail("CPU %d is no longer permitted for slot %d", cpu, slot);
    CPU_ZERO(&wanted); CPU_SET(cpu, &wanted);
    error = pthread_setaffinity_np(pthread_self(), sizeof(wanted), &wanted);
    if (error) fail("cannot pin slot %d to CPU %d: %s", slot, cpu, strerror(error));
    CPU_ZERO(&current);
    error = pthread_getaffinity_np(pthread_self(), sizeof(current), &current);
    if (error || !CPU_EQUAL(&current, &wanted))
        fail("CPU placement verification failed for slot %d CPU %d", slot, cpu);
#else
    (void)slot;
    fail("AUDIO_CPUS is supported only on Linux");
#endif
}
static void report_placement(const Placement *p, int workers) {
    printf(" placement=%s cpus=", p->pinned ? "pinned_slots" : "allowed_set");
    if (p->pinned) {
        for (int n = 0; n < workers; ++n) printf("%s%d", n ? "," : "", p->cpus[n]);
    } else {
#ifdef __linux__
        int count = 0;
        for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu)
            if (CPU_ISSET(cpu, &p->permitted)) printf("%s%d", count++ ? "," : "", cpu);
#else
        printf("unqueried");
#endif
    }
    putchar('\n');
}
static double now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) fail("clock_gettime failed");
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}
static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
static double median(const double values[ROUNDS]) {
    double copy[ROUNDS]; memcpy(copy, values, sizeof(copy));
    qsort(copy, ROUNDS, sizeof(copy[0]), cmp_double); return copy[ROUNDS / 2];
}
static size_t multiply(size_t a, size_t b) {
    if (a && b > SIZE_MAX / a) fail("size overflow");
    return a * b;
}
static Buffer read_file(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) fail("cannot open input: %s", path);
    if (fseeko(f, 0, SEEK_END)) fail("cannot seek input");
    off_t size = ftello(f);
    if (size <= 0 || (uintmax_t)size > SIZE_MAX - AV_INPUT_BUFFER_PADDING_SIZE)
        fail("empty or oversized input");
    if (fseeko(f, 0, SEEK_SET)) fail("cannot rewind input");
    Buffer b = { .len = (size_t)size, .cap = (size_t)size };
    b.data = calloc(1, b.len + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!b.data || fread(b.data, 1, b.len, f) != b.len || fclose(f))
        fail("cannot read input");
    return b;
}
static void write_file(const char *path, Buffer b) {
    FILE *f = fopen(path, "wb"); if (!f) fail("cannot open output: %s", path);
    if (fwrite(b.data, 1, b.len, f) != b.len || fclose(f)) fail("cannot write output");
}
static int job_error(Job *j, const char *fmt, ...) {
    j->error = 1;
    va_list ap; va_start(ap, fmt); vsnprintf(j->message, sizeof(j->message), fmt, ap);
    va_end(ap); return -1;
}
static int codec_error(Job *j, int code, const char *operation) {
    char text[AV_ERROR_MAX_STRING_SIZE]; av_strerror(code, text, sizeof(text));
    return job_error(j, "%s: %s", operation, text);
}
static int append(Job *j, const uint8_t *data, size_t n) {
    if (n > j->output.cap - j->output.len) return job_error(j, "output bound exceeded");
    memcpy(j->output.data + j->output.len, data, n); j->output.len += n; return 0;
}

// Matches the native admitted transport: AAC-LC, seven-byte unprotected ADTS,
// one raw access unit, fixed mono/stereo configuration and a supported rate.
static int adts(const uint8_t *p, size_t remaining, int *rate_index,
                int *channels, size_t *bytes) {
    if (remaining < 7 || p[0] != 255 || (p[1] & 0xf6) != 0xf0 ||
        !(p[1] & 1) || (p[6] & 3) || (p[2] >> 6) != 1) return -1;
    *rate_index = (p[2] >> 2) & 15;
    *channels = (p[2] & 1) * 4 + (p[3] >> 6);
    *bytes = ((size_t)(p[3] & 3) << 11) | ((size_t)p[4] << 3) | (p[5] >> 5);
    return *rate_index < 12 && (*channels == 1 || *channels == 2) &&
           *bytes >= 8 && *bytes <= remaining ? 0 : -1;
}
static void prepare_input(Input *in) {
    if (in->encode) {
        if (in->input.len % (2 * (size_t)in->channels)) fail("incomplete PCM sample frame");
        in->sample_frames = in->input.len / (2 * (size_t)in->channels);
        in->frames = in->sample_frames / FRAME_SAMPLES + !!(in->sample_frames % FRAME_SAMPLES);
        if (in->frames >= SIZE_MAX / sizeof(*in->pcm)) fail("too many frames");
        in->pcm = calloc(in->frames, sizeof(*in->pcm)); if (!in->pcm) fail("allocation failed");
        // Refcounted, read-only resident FLTP frames shared by independent jobs.
        // avcodec_send_frame explicitly preserves caller ownership and data.
        for (size_t f = 0; f < in->frames; ++f) {
            AVFrame *frame = av_frame_alloc(); if (!frame) fail("frame allocation failed");
            in->pcm[f] = frame;
            frame->format = AV_SAMPLE_FMT_FLTP; frame->sample_rate = in->rate;
            frame->nb_samples = FRAME_SAMPLES; frame->pts = (int64_t)(f * FRAME_SAMPLES);
            av_channel_layout_default(&frame->ch_layout, in->channels);
            if (av_frame_get_buffer(frame, 0) < 0) fail("PCM frame allocation failed");
            for (int c = 0; c < in->channels; ++c) {
                float *dst = (float *)frame->extended_data[c];
                for (size_t n = 0; n < FRAME_SAMPLES; ++n) {
                    size_t sample = f * FRAME_SAMPLES + n;
                    if (sample >= in->sample_frames) { dst[n] = 0; continue; }
                    size_t offset = 2 * (sample * in->channels + c);
                    uint16_t bits = (uint16_t)in->input.data[offset] |
                                    (uint16_t)in->input.data[offset + 1] << 8;
                    int value = bits < 32768 ? bits : (int)bits - 65536;
                    dst[n] = (float)value / 32768.0f;
                }
            }
        }
        in->output_capacity = multiply(in->frames + 1, 8191);
    } else {
        size_t offset = 0;
        while (offset < in->input.len) {
            int ri, ch; size_t bytes;
            if (adts(in->input.data + offset, in->input.len - offset, &ri, &ch, &bytes))
                fail("unsupported or malformed ADTS at byte %zu", offset);
            if (!offset) { in->rate_index = ri; in->rate = rates[ri]; in->channels = ch; }
            if (ri != in->rate_index || ch != in->channels) fail("ADTS configuration changes");
            offset += bytes; ++in->frames;
        }
        in->sample_frames = multiply(in->frames, FRAME_SAMPLES);
        in->output_capacity = multiply(multiply(in->sample_frames, in->channels), 2);
        in->packets = calloc(in->frames, sizeof(*in->packets));
        if (!in->packets) fail("packet index allocation failed");
        // Public avcodec_send_packet preserves caller ownership, never writes
        // packet data, and may retain its refcounted buffer. Prepare padded,
        // immutable raw access units once, exactly as resident PCM above.
        offset = 0;
        for (size_t n = 0; n < in->frames; ++n) {
            int ri, ch; size_t bytes;
            if (adts(in->input.data + offset, in->input.len - offset, &ri, &ch, &bytes) ||
                ri != in->rate_index || ch != in->channels)
                fail("ADTS framing/configuration changed during preparation");
            AVPacket *packet = av_packet_alloc(); if (!packet) fail("packet allocation failed");
            in->packets[n] = packet;
            if (av_new_packet(packet, (int)bytes - 7) < 0) fail("payload allocation failed");
            memcpy(packet->data, in->input.data + offset + 7, bytes - 7);
            packet->pts = packet->dts = (int64_t)(n * FRAME_SAMPLES);
            packet->pos = (int64_t)offset;
            offset += bytes;
        }
    }
}

static void init_job(Job *j, const Input *in) {
    j->input = in; j->error = 0; j->message[0] = 0;
    j->output.len = 0; j->frames = 0; j->sample_frames = 0;
    const AVCodec *codec = in->encode ? avcodec_find_encoder_by_name("aac") :
                                       avcodec_find_decoder_by_name("aac");
    if (!codec) fail("native FFmpeg AAC codec unavailable");
    if (codec->capabilities & (AV_CODEC_CAP_FRAME_THREADS | AV_CODEC_CAP_SLICE_THREADS))
        fail("AAC threading capabilities changed; review serial-context contract");
    j->codec = avcodec_alloc_context3(codec);
    if (in->encode) j->packet = av_packet_alloc();
    if (!j->codec || (in->encode && !j->packet)) fail("codec allocation failed");
    AVCodecContext *c = j->codec;
    c->sample_rate = in->rate; c->profile = AV_PROFILE_AAC_LOW;
    c->thread_count = 1; c->thread_type = 0;
    av_channel_layout_default(&c->ch_layout, in->channels);
    if (in->encode) {
        c->sample_fmt = AV_SAMPLE_FMT_FLTP; c->bit_rate = in->bitrate;
        c->time_base = (AVRational){1, in->rate};
        if (av_opt_set(c->priv_data, "aac_coder", "twoloop", 0) < 0 ||
            av_opt_set_int(c->priv_data, "aac_pns", 0, 0) < 0)
            fail("cannot select AAC coder/PNS controls");
    } else {
        c->request_sample_fmt = AV_SAMPLE_FMT_FLTP;
        c->extradata = av_mallocz(2 + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!c->extradata) fail("ASC allocation failed");
        c->extradata_size = 2;
        c->extradata[0] = (uint8_t)((2 << 3) | (in->rate_index >> 1));
        c->extradata[1] = (uint8_t)(((in->rate_index & 1) << 7) | (in->channels << 3));
        j->frame = av_frame_alloc(); if (!j->frame) fail("decode frame allocation failed");
    }
    int error = avcodec_open2(c, codec, NULL);
    if (error < 0) { codec_error(j, error, "avcodec_open2"); fail("%s", j->message); }
    if (c->thread_count != 1 || c->active_thread_type != 0 ||
        c->sample_rate != in->rate || c->ch_layout.nb_channels != in->channels ||
        (in->encode && (c->frame_size != FRAME_SAMPLES || c->initial_padding != FRAME_SAMPLES ||
                        c->sample_fmt != AV_SAMPLE_FMT_FLTP || c->profile != AV_PROFILE_AAC_LOW)))
        fail("resolved codec layout, priming or serial-context contract changed");
}
static void destroy_job(Job *j) {
    av_frame_free(&j->frame); av_packet_free(&j->packet); avcodec_free_context(&j->codec);
}
static int encoded_packets(Job *j) {
    int code;
    while ((code = avcodec_receive_packet(j->codec, j->packet)) >= 0) {
        int payload = j->packet->size;
        if (payload <= 0 || payload > 8191 - 7) return job_error(j, "AAC packet exceeds ADTS bound");
        int bytes = payload + 7, ri = j->input->rate_index, ch = j->input->channels;
        const uint8_t header[7] = {255, 0xf1, (uint8_t)((1 << 6) | (ri << 2) | (ch >> 2)),
            (uint8_t)(((ch & 3) << 6) | (bytes >> 11)), (uint8_t)(bytes >> 3),
            (uint8_t)(((bytes & 7) << 5) | 0x1f), 0xfc};
        if (append(j, header, sizeof(header)) || append(j, j->packet->data, payload)) return -1;
        ++j->frames; j->sample_frames += FRAME_SAMPLES;
        av_packet_unref(j->packet);
    }
    if (code != AVERROR(EAGAIN) && code != AVERROR_EOF) return codec_error(j, code, "receive packet");
    return code;
}
static int decoded_frames(Job *j) {
    int code;
    while ((code = avcodec_receive_frame(j->codec, j->frame)) >= 0) {
        AVFrame *f = j->frame;
        if (f->format != AV_SAMPLE_FMT_FLTP || f->nb_samples != FRAME_SAMPLES ||
            f->ch_layout.nb_channels != j->input->channels || f->sample_rate != j->input->rate)
            return job_error(j, "decoded frame layout changed");
        size_t bytes = FRAME_SAMPLES * (size_t)j->input->channels * 2;
        if (bytes > j->output.cap - j->output.len) return job_error(j, "decoded output bound exceeded");
        uint8_t *out = j->output.data + j->output.len;
        for (int n = 0; n < FRAME_SAMPLES; ++n) {
            for (int ch = 0; ch < j->input->channels; ++ch) {
                double value = ((const float *)f->extended_data[ch])[n];
                if (!isfinite(value)) return job_error(j, "nonfinite decoded sample");
                // Native math.round rounds halfway away from zero. Clamp before
                // llround to keep even unusual finite decoder outputs in range.
                int sample = value <= -1.0 ? -32768 : value >= 32767.0 / 32768.0 ? 32767 :
                             (int)llround(value * 32768.0);
                uint16_t bits = (uint16_t)sample;
                *out++ = (uint8_t)bits; *out++ = (uint8_t)(bits >> 8);
            }
        }
        j->output.len += bytes; ++j->frames; j->sample_frames += FRAME_SAMPLES;
        av_frame_unref(f);
    }
    if (code != AVERROR(EAGAIN) && code != AVERROR_EOF) return codec_error(j, code, "receive frame");
    return code;
}
static void run_job(Job *j) {
    const Input *in = j->input;
    if (in->encode) {
        for (size_t n = 0; n < in->frames; ++n) {
            int code = avcodec_send_frame(j->codec, in->pcm[n]);
            if (code < 0) { codec_error(j, code, "send frame"); return; }
            code = encoded_packets(j);
            if (code != AVERROR(EAGAIN)) {
                if (!j->error) job_error(j, "unexpected encoder drain before flush");
                return;
            }
        }
        int code = avcodec_send_frame(j->codec, NULL);
        if (code < 0) { codec_error(j, code, "flush encoder"); return; }
        if (encoded_packets(j) != AVERROR_EOF || j->frames != in->frames + 1)
            if (!j->error) job_error(j, "encoder flush or packet count differs from native envelope");
    } else {
        size_t offset = 0, index = 0;
        while (offset < in->input.len) {
            int ri, ch; size_t bytes;
            if (adts(in->input.data + offset, in->input.len - offset, &ri, &ch, &bytes) ||
                ri != in->rate_index || ch != in->channels) {
                job_error(j, "ADTS framing/configuration changed"); return;
            }
            if (index >= in->frames || in->packets[index]->pos != (int64_t)offset ||
                in->packets[index]->size != (int)bytes - 7) {
                job_error(j, "resident packet/framing index mismatch"); return;
            }
            int code = avcodec_send_packet(j->codec, in->packets[index]);
            if (code < 0) { codec_error(j, code, "send packet"); return; }
            code = decoded_frames(j);
            if (code != AVERROR(EAGAIN)) {
                if (!j->error) job_error(j, "unexpected decoder drain before flush");
                return;
            }
            offset += bytes; ++index;
        }
        int code = avcodec_send_packet(j->codec, NULL);
        if (code < 0) { codec_error(j, code, "flush decoder"); return; }
        if (decoded_frames(j) != AVERROR_EOF || j->frames != in->frames)
            if (!j->error) job_error(j, "decoder flush or frame count differs from native envelope");
    }
}

static void *worker_main(void *opaque) {
    Worker *worker = opaque; Pool *p = worker->pool; int seen = 0;
    pin_current_slot(p->placement, worker->index);
    pthread_mutex_lock(&p->mutex);
    if (++p->ready == p->count - 1) pthread_cond_signal(&p->finish);
    for (;;) {
        while (!p->stop && seen == p->generation) pthread_cond_wait(&p->start, &p->mutex);
        if (p->stop) break;
        seen = p->generation; Job *job = &p->jobs[worker->index];
        pthread_mutex_unlock(&p->mutex); run_job(job); pthread_mutex_lock(&p->mutex);
        if (++p->completed == p->count - 1) pthread_cond_signal(&p->finish);
    }
    pthread_mutex_unlock(&p->mutex); return NULL;
}
static void init_pool(Pool *p, int workers, const Placement *placement) {
    memset(p, 0, sizeof(*p)); p->count = workers; p->placement = placement;
    if (pthread_mutex_init(&p->mutex, NULL) || pthread_cond_init(&p->start, NULL) ||
        pthread_cond_init(&p->finish, NULL)) fail("pool synchronization allocation failed");
    for (int n = 1; n < workers; ++n) {
        p->workers[n - 1] = (Worker){p, n};
        if (pthread_create(&p->threads[n - 1], NULL, worker_main, &p->workers[n - 1]))
            fail("cannot create pool thread");
    }
    // Workers inherit the original allowed mask. Confirm their one-time pin
    // before narrowing the caller's mask or starting any codec/setup timer.
    pthread_mutex_lock(&p->mutex);
    while (p->ready != workers - 1) pthread_cond_wait(&p->finish, &p->mutex);
    pthread_mutex_unlock(&p->mutex);
}
static void run_pool(Pool *p, Job *jobs) {
    if (p->count == 1) { run_job(&jobs[0]); return; }
    pthread_mutex_lock(&p->mutex);
    p->jobs = jobs; p->completed = 0; ++p->generation;
    pthread_cond_broadcast(&p->start); pthread_mutex_unlock(&p->mutex);
    run_job(&jobs[0]); // One complete independent stream on the caller.
    pthread_mutex_lock(&p->mutex);
    while (p->completed != p->count - 1) pthread_cond_wait(&p->finish, &p->mutex);
    pthread_mutex_unlock(&p->mutex);
}
static void destroy_pool(Pool *p) {
    pthread_mutex_lock(&p->mutex); p->stop = 1;
    pthread_cond_broadcast(&p->start); pthread_mutex_unlock(&p->mutex);
    for (int n = 1; n < p->count; ++n) pthread_join(p->threads[n - 1], NULL);
    pthread_cond_destroy(&p->start); pthread_cond_destroy(&p->finish); pthread_mutex_destroy(&p->mutex);
}

int main(int argc, char **argv) {
    Input in = {0}; const char *output_path;
    if (argc == 8 && !strcmp(argv[1], "encode")) {
        in.encode = 1; in.rate = number(argv[3]); in.channels = number(argv[4]);
        in.bitrate = number(argv[5]); in.workers = number(argv[6]); output_path = argv[7];
        if (in.channels != 1 && in.channels != 2) fail("mono/stereo only");
        in.rate_index = -1;
        for (int n = 0; n < 12; ++n) if (rates[n] == in.rate) in.rate_index = n;
        if (in.rate_index < 0) fail("unsupported sample rate");
        if (!in.bitrate) in.bitrate = 64000 * in.channels;
        int maximum = 512000 * in.channels;
        if (in.rate * 6 * in.channels < maximum) maximum = in.rate * 6 * in.channels;
        if (in.bitrate < 8000 * in.channels || in.bitrate > maximum) fail("native-envelope bitrate out of range");
    } else if (argc == 5 && !strcmp(argv[1], "decode")) {
        in.workers = number(argv[3]); output_path = argv[4];
    } else {
        fprintf(stderr, "usage: reference encode source.s16le rate channels bitrate workers output.aac\n"
                        "       reference decode input.aac workers output.s16le\n");
        return 2;
    }
    if (in.workers < 1 || in.workers > MAX_WORKERS)
        fail("workers must be between 1 and 16 independent streams");
    Placement placement = {0}; prepare_placement(&placement, in.workers);
    av_log_set_level(AV_LOG_ERROR);
    in.input = read_file(argv[2]); prepare_input(&in);
    Pool pool; init_pool(&pool, in.workers, &placement);
    pin_current_slot(&placement, 0);
    Job jobs[MAX_WORKERS] = {0};
    for (int n = 0; n < in.workers; ++n) {
        jobs[n].output.cap = in.output_capacity;
        jobs[n].output.data = malloc(in.output_capacity);
        if (!jobs[n].output.data) fail("output allocation failed");
    }
    Buffer baseline = {0}; double init[ROUNDS], codec[ROUNDS];
    int resolved_threads = 0, active_threads = 0, initial_padding = 0;
    int64_t resolved_bitrate = 0;
    int64_t coder = -2, pns = -2, tns = -2, ms = -2, intensity = -2;
    for (int rep = 0; rep < ROUNDS; ++rep) {
        double start = now_ms();
        for (int n = 0; n < in.workers; ++n) init_job(&jobs[n], &in);
        init[rep] = now_ms() - start;
        resolved_threads = jobs[0].codec->thread_count;
        active_threads = jobs[0].codec->active_thread_type;
        initial_padding = jobs[0].codec->initial_padding;
        resolved_bitrate = jobs[0].codec->bit_rate;
        if (in.encode) {
            if (av_opt_get_int(jobs[0].codec->priv_data, "aac_coder", 0, &coder) < 0 ||
                av_opt_get_int(jobs[0].codec->priv_data, "aac_pns", 0, &pns) < 0 ||
                av_opt_get_int(jobs[0].codec->priv_data, "aac_tns", 0, &tns) < 0 ||
                av_opt_get_int(jobs[0].codec->priv_data, "aac_ms", 0, &ms) < 0 ||
                av_opt_get_int(jobs[0].codec->priv_data, "aac_is", 0, &intensity) < 0)
                fail("cannot report resolved AAC controls");
        }
        start = now_ms(); run_pool(&pool, jobs); codec[rep] = now_ms() - start;
        for (int n = 0; n < in.workers; ++n) {
            if (jobs[n].error) fail("round %d stream %d: %s", rep, n, jobs[n].message);
            if (n && (jobs[n].output.len != jobs[0].output.len ||
                      memcmp(jobs[n].output.data, jobs[0].output.data, jobs[0].output.len)))
                fail("concurrent stream output differs in round %d stream %d", rep, n);
            destroy_job(&jobs[n]);
        }
        if (!rep) {
            baseline.len = jobs[0].output.len; baseline.data = malloc(baseline.len);
            if (!baseline.data) fail("baseline allocation failed");
            memcpy(baseline.data, jobs[0].output.data, baseline.len);
        } else if (baseline.len != jobs[0].output.len || memcmp(baseline.data, jobs[0].output.data, baseline.len))
            fail("nondeterministic output in round %d", rep);
        printf("round=%d init_ms=%.3f codec_ms=%.3f bytes_first_stream=%zu frames_first_stream=%zu\n",
               rep, init[rep], codec[rep], jobs[0].output.len, jobs[0].frames);
    }
    write_file(output_path, jobs[0].output);
    double elapsed = median(codec), seconds = (double)in.sample_frames / in.rate * in.workers;
    printf("FFmpeg AAC %s: rate=%d channels=%d bitrate=%d input_sample_frames=%zu output_sample_frames=%zu "
           "frames_first_stream=%zu bytes_first_stream=%zu rounds=%d independent_streams=%d "
           "requested_workers=%d pool_threads=%d caller_streams=1 context_threads=%d active_thread_type=%d "
           "initial_padding=%d init_ms=%.3f codec_ms=%.3f aggregate_audio_seconds=%.6f "
           "aggregate_sample_frames_per_second=%.3f aggregate_x_realtime=%.3f "
           "resolved_bitrate=%lld ffmpeg_version=%s libavcodec_version=%u",
           in.encode ? "encode" : "decode", in.rate, in.channels, in.bitrate, in.sample_frames,
           jobs[0].sample_frames, jobs[0].frames, jobs[0].output.len, ROUNDS, in.workers,
           in.workers, in.workers - 1, resolved_threads, active_threads, initial_padding,
           median(init), elapsed, seconds, (double)in.sample_frames * in.workers * 1000 / elapsed,
           seconds * 1000 / elapsed, (long long)resolved_bitrate, av_version_info(), avcodec_version());
    report_placement(&placement, in.workers);
    if (in.encode) printf("reference_tools: AAC-LC sample_fmt=fltp aac_coder=%lld(twoloop=0) "
                         "aac_pns=%lld aac_tns=%lld aac_ms=%lld(auto=-1) aac_is=%lld "
                         "short_windows=encoder_default native_feature_quality_parity=not_claimed\n",
                         (long long)coder, (long long)pns, (long long)tns, (long long)ms, (long long)intensity);
    else printf("decode_envelope: ADTS_parse+resident_raw_packet+codec+interleave+s16_round_clip; "
                "priming_and_padding_retained=1\n");
    destroy_pool(&pool);
    for (int n = 0; n < in.workers; ++n) free(jobs[n].output.data);
    for (size_t n = 0; n < in.frames && in.encode; ++n) av_frame_free(&in.pcm[n]);
    for (size_t n = 0; n < in.frames && !in.encode; ++n) av_packet_free(&in.packets[n]);
    free(in.pcm); free(in.packets); free(in.input.data); free(baseline.data); return 0;
}

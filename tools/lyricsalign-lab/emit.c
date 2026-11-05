/*
 * emit: run the lyricsalign GGUF model on a 16 kHz mono 16-bit WAV without
 * ffmpeg, writing the emissions (T x vocab log-probs, raw little-endian f32)
 * for tools/lyricsalign-lab/gate_a.py, the JFK emission-fidelity gate of
 * nomercy-ffmpeg #126.
 *
 *   emit <model.gguf> <clip.wav> <out.f32> [threads]
 *   emit --self-test <model.gguf>       the short-input cases (0, 300, 8000 samples)
 *
 * Built in the lab:
 *   gcc -O2 -I scripts/includes -I /opt/nm/include tools/lyricsalign-lab/emit.c \
 *       -L/opt/nm/lib $(pkg-config --libs whisper) -lstdc++ -lm -lpthread -o /tmp/emit
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "nm_lyricsalign_w2v2.h"

static uint32_t le32(const unsigned char *p)
{
    return p[0] | (p[1] << 8) | ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

static float *load_wav16(const char *path, int *n)
{
    FILE *f = fopen(path, "rb");
    unsigned char hdr[12], ch[8], fmt[16];
    int16_t *pcm;
    float *out;
    uint32_t size;

    if (!f)
        return NULL;
    if (fread(hdr, 1, 12, f) != 12 || memcmp(hdr, "RIFF", 4) || memcmp(hdr + 8, "WAVE", 4))
        goto bad;
    for (;;) {
        if (fread(ch, 1, 8, f) != 8)
            goto bad;
        size = le32(ch + 4);
        if (!memcmp(ch, "fmt ", 4)) {
            if (size < 16 || fread(fmt, 1, 16, f) != 16 || (fmt[0] | (fmt[1] << 8)) != 1 ||
                (fmt[2] | (fmt[3] << 8)) != 1 || le32(fmt + 4) != 16000 || (fmt[14] | (fmt[15] << 8)) != 16) {
                fprintf(stderr, "%s: need PCM, mono, 16 kHz, 16-bit\n", path);
                goto bad;
            }
            if (size > 16 && fseek(f, (long) (size - 16 + (size & 1)), SEEK_CUR))
                goto bad;
        } else if (!memcmp(ch, "data", 4)) {
            break;
        } else if (fseek(f, (long) (size + (size & 1)), SEEK_CUR)) {
            goto bad;
        }
    }
    *n = (int) (size / 2);
    pcm = malloc(size);
    out = malloc(sizeof(*out) * *n);
    if (fread(pcm, 2, *n, f) != (size_t) *n)
        goto bad;
    fclose(f);
    for (int i = 0; i < *n; i++)
        out[i] = pcm[i] / 32768.0f;
    free(pcm);
    return out;
bad:
    fclose(f);
    return NULL;
}

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int self_test(NMW2V2 *m)
{
    const int cases[3] = { 0, 300, 8000 };
    const int want[3] = { 0, 0, 25 };
    float *samples = calloc(8000, sizeof(*samples)), *logp = NULL;
    int frames = -1, bad = 0;

    for (int i = 0; i < 8000; i++)
        samples[i] = 0.1f * (float) ((i % 160) - 80) / 80.0f;
    for (int c = 0; c < 3; c++) {
        int rc = nm_w2v2_emissions(m, samples, cases[c], &logp, &frames);
        if (rc != 0 || frames != want[c] || (want[c] == 0) != (logp == NULL)) {
            fprintf(stderr, "self-test: %d samples -> rc %d, frames %d (want %d), logp %s\n", cases[c], rc, frames,
                    want[c], logp ? "set" : "NULL");
            bad++;
        } else if (logp) {
            /* every row is a distribution */
            for (int t = 0; t < frames; t++) {
                double sum = 0;
                for (int v = 0; v < nm_w2v2_vocab_n(m); v++)
                    sum += exp(logp[(size_t) t * nm_w2v2_vocab_n(m) + v]);
                if (sum < 0.999 || sum > 1.001) {
                    fprintf(stderr, "self-test: frame %d sums to %g\n", t, sum);
                    bad++;
                    break;
                }
            }
        }
        free(logp);
        logp = NULL;
    }
    free(samples);
    printf(bad ? "self-test FAILED\n" : "self-test ok\n");
    return bad ? 1 : 0;
}

int main(int argc, char **argv)
{
    ggml_backend_t cpu;
    NMW2V2 *m = NULL;
    char err[256];
    int threads = 4, n, frames, rc;
    float *samples, *logp;
    double t0;
    FILE *out;

    if (argc < 3) {
        fprintf(stderr, "usage: emit <model.gguf> <clip.wav> <out.f32> [threads] | emit --self-test <model.gguf>\n");
        return 2;
    }
    cpu = ggml_backend_cpu_init();
    if (!cpu) {
        fprintf(stderr, "no CPU backend\n");
        return 1;
    }
    if (argc > 4)
        threads = atoi(argv[4]);
    ggml_backend_cpu_set_n_threads(cpu, threads);

    t0 = now();
    if (nm_w2v2_load(!strcmp(argv[1], "--self-test") ? argv[2] : argv[1], NULL, cpu, &m, err, sizeof(err))) {
        fprintf(stderr, "load failed: %s\n", err);
        return 1;
    }
    fprintf(stderr, "loaded %s: vocab %d, blank %d, %d conv layers (field %d), %d transformer layers, in %.1f s\n",
            nm_w2v2_name(m), nm_w2v2_vocab_n(m), nm_w2v2_blank(m), m->n_conv, m->receptive, m->n_layers, now() - t0);

    if (!strcmp(argv[1], "--self-test")) {
        rc = self_test(m);
        nm_w2v2_free(m);
        ggml_backend_free(cpu);
        return rc;
    }
    if (argc < 4) {
        fprintf(stderr, "usage: emit <model.gguf> <clip.wav> <out.f32> [threads]\n");
        return 2;
    }
    samples = load_wav16(argv[2], &n);
    if (!samples) {
        fprintf(stderr, "cannot read %s\n", argv[2]);
        return 1;
    }
    t0 = now();
    rc = nm_w2v2_emissions(m, samples, n, &logp, &frames);
    if (rc) {
        fprintf(stderr, "emissions failed\n");
        return 1;
    }
    fprintf(stderr, "%d samples -> %d frames in %.2f s (%d threads)\n", n, frames, now() - t0, threads);
    out = fopen(argv[3], "wb");
    if (!out || fwrite(logp, sizeof(*logp), (size_t) frames * nm_w2v2_vocab_n(m), out) != (size_t) frames * nm_w2v2_vocab_n(m)) {
        fprintf(stderr, "cannot write %s\n", argv[3]);
        return 1;
    }
    fclose(out);
    printf("frames %d\n", frames);
    free(logp);
    free(samples);
    nm_w2v2_free(m);
    ggml_backend_free(cpu);
    return 0;
}

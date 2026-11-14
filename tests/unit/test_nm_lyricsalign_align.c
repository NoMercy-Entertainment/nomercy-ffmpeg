/*
 * Unit tests for scripts/includes/nm_lyricsalign_align.h: log-softmax, the
 * star column, the blank-interleaved star Viterbi, the agreement verdict, the
 * RMS envelope and the onset walk-back (nomercy-ffmpeg #126, processing
 * steps 3, 5, 6 and 7), pinned to the prototype's JFK fixture; and the two
 * refinements of step 7 (#130): the soft-onset walk-back (7b) and the island
 * before an unheard first word (7c).
 *
 * Plain C, no FFmpeg and no ggml:
 *
 *   cc -std=c11 -Wall -Wextra -Werror -I scripts/includes \
 *      tests/unit/test_nm_lyricsalign_align.c -lm -o test_nm_lyricsalign_align
 *   NM_UNIT_FIXTURES=tests/unit/fixtures ./test_nm_lyricsalign_align
 *
 * tests/unit/run.sh does exactly that. JFK_WAV=<path to jfk.wav> enables the
 * walk-back check on the real clip; without it that one check is reported
 * as skipped. Exit code 0 means every check passed.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nm_lyricsalign_align.h"
#include "nm_lyricsalign_phones.h"      /* nm_lp_soft_onset: the first phone's class, for step 7b */
#include "fixtures/jfk/jfk_fixture.h"

static int failures;
static int checks;

#define CHECK(cond) do {                                                    \
        checks++;                                                           \
        if (!(cond)) {                                                      \
            failures++;                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        }                                                                   \
    } while (0)

#define CHECK_EQ_INT(got, want) do {                                               \
        int g_ = (got), w_ = (want);                                               \
        checks++;                                                                  \
        if (g_ != w_) {                                                            \
            failures++;                                                            \
            fprintf(stderr, "FAIL %s:%d: %s = %d, want %d\n", __FILE__, __LINE__, \
                    #got, g_, w_);                                                 \
        }                                                                          \
    } while (0)

#define CHECK_NEAR(got, want, tol) do {                                                 \
        double g_ = (got), w_ = (want);                                                 \
        checks++;                                                                       \
        if (fabs(g_ - w_) > (tol)) {                                                    \
            failures++;                                                                 \
            fprintf(stderr, "FAIL %s:%d: %s = %g, want %g (tol %g)\n", __FILE__,        \
                    __LINE__, #got, g_, w_, (double) (tol));                            \
        }                                                                               \
    } while (0)

/* --------------------------------------------------------------------------
 * Helpers: emissions built by hand, the .npy fixture, a WAV reader.
 * ------------------------------------------------------------------------ */

/* A frames x cols log-prob matrix where every entry is log(p_low) except the
 * cells set afterwards. */
static float *emissions(int frames, int cols, float p_low)
{
    float *m = malloc(sizeof(*m) * frames * cols);
    for (int i = 0; i < frames * cols; i++)
        m[i] = logf(p_low);
    return m;
}

static void set(float *m, int cols, int frame, int col, float p)
{
    m[frame * cols + col] = logf(p);
}

static float f16_to_f32(uint16_t h)
{
    uint32_t sign = (uint32_t) (h & 0x8000) << 16;
    uint32_t exp = (h >> 10) & 0x1F;
    uint32_t mant = h & 0x3FF;
    uint32_t bits;
    float out;

    if (exp == 0) {
        if (mant == 0) {
            bits = sign;
        } else {
            /* subnormal: normalise */
            int e = -1;
            do {
                e++;
                mant <<= 1;
            } while (!(mant & 0x400));
            mant &= 0x3FF;
            bits = sign | ((uint32_t) (127 - 15 - e) << 23) | (mant << 13);
        }
    } else if (exp == 31) {
        bits = sign | 0x7F800000 | (mant << 13);
    } else {
        bits = sign | ((exp + 127 - 15) << 23) | (mant << 13);
    }
    memcpy(&out, &bits, sizeof(out));
    return out;
}

/* The fixture's [550 x 392] float16 log-probs as float32, or NULL. */
static float *load_jfk_logp(void)
{
    const char *dir = getenv("NM_UNIT_FIXTURES");
    char path[1024];
    unsigned char head[10];
    uint16_t *raw;
    float *out;
    FILE *f;
    size_t n = (size_t) JFK_FRAMES * JFK_VOCAB;
    unsigned hlen;

    if (!dir)
        dir = "tests/unit/fixtures";
    snprintf(path, sizeof(path), "%s/jfk/%s", dir, JFK_LOGP_NPY);
    f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        return NULL;
    }
    if (fread(head, 1, sizeof(head), f) != sizeof(head) || memcmp(head, "\x93NUMPY\x01\x00", 8)) {
        fprintf(stderr, "%s: not a v1.0 .npy\n", path);
        fclose(f);
        return NULL;
    }
    hlen = head[8] | (head[9] << 8);
    if (fseek(f, 10 + (long) hlen, SEEK_SET)) {
        fclose(f);
        return NULL;
    }
    raw = malloc(n * sizeof(*raw));
    out = malloc(n * sizeof(*out));
    if (fread(raw, sizeof(*raw), n, f) != n) {
        fprintf(stderr, "%s: short read\n", path);
        free(raw);
        free(out);
        fclose(f);
        return NULL;
    }
    fclose(f);
    for (size_t i = 0; i < n; i++)
        out[i] = f16_to_f32(raw[i]);
    free(raw);
    return out;
}

/* 16-bit PCM mono WAV -> float samples in [-1, 1); walks the RIFF chunks to
 * "data" (jfk.wav carries a LIST chunk before it). The fixture clip only. */
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
                (fmt[2] | (fmt[3] << 8)) != 1 || (fmt[14] | (fmt[15] << 8)) != 16)
                goto bad;                                   /* PCM, mono, 16-bit only */
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
    if (fread(pcm, 2, *n, f) != (size_t) *n) {
        free(pcm);
        free(out);
        goto bad;
    }
    fclose(f);
    for (int i = 0; i < *n; i++)
        out[i] = pcm[i] / 32768.0f;
    free(pcm);
    return out;
bad:
    fclose(f);
    return NULL;
}

/* One accepted line as the onset steps see it. The first phone gives its
 * class (soft or hard) through the filter's own classifier. */
static NMLaLineOnset onset_of(int spike_frame, int prev_end_frame, const char *first_phone, int words,
                              double first_word_score)
{
    NMLaLineOnset line;

    line.spike_frame = spike_frame;
    line.prev_end_frame = prev_end_frame;
    line.soft_onset = nm_lp_soft_onset(first_phone);
    line.words = words;
    line.first_word_score = first_word_score;
    return line;
}

static void fill_db(float *db, int n, float level)
{
    for (int k = 0; k < n; k++)
        db[k] = level;
}

static void set_db(float *db, int from, int to, float level)
{
    for (int k = from; k < to; k++)
        db[k] = level;
}

/* The 10 ms envelope that goes with a level per 20 ms frame. */
static void hops_of(const float *frames, int n_frames, float *env)
{
    for (int f = 0; f < n_frames; f++)
        env[2 * f] = env[2 * f + 1] = frames[f];
}

/* --------------------------------------------------------------------------
 * Tests
 * ------------------------------------------------------------------------ */

static void test_log_softmax_rows_sum_to_one(void)
{
    const float logits[3 * 4] = { 1, 2, 3, 4,  0, 0, 0, 0,  -1, 5, 2, 0 };
    float logp[3 * 4];

    nm_la_log_softmax(logits, 3, 4, logp);
    for (int t = 0; t < 3; t++) {
        double sum = 0;
        for (int v = 0; v < 4; v++)
            sum += exp(logp[t * 4 + v]);
        CHECK_NEAR(sum, 1.0, 1e-6);
    }
    for (int v = 0; v < 4; v++)
        CHECK_NEAR(logp[1 * 4 + v], -log(4.0), 1e-6);
    /* argmax is kept */
    CHECK(logp[0 * 4 + 3] > logp[0 * 4 + 2] && logp[2 * 4 + 1] > logp[2 * 4 + 2]);
}

static void test_star_column(void)
{
    /* 2 frames x 2 symbols, blank = 0 */
    float logp[2 * 2] = { 0.0f, -30.0f, logf(0.5f), logf(0.5f) };
    float *out = nm_la_add_star(logp, 2, 2);

    CHECK(out != NULL);
    if (!out)
        return;
    CHECK(out[0 * 3 + 2] <= NM_LA_NEG / 2);                   /* p_blank = 1: nothing left for the star */
    CHECK_NEAR(out[1 * 3 + 2], log(0.5) + log(NM_LA_STAR_WEIGHT), 1e-6);
    CHECK_NEAR(out[1 * 3 + 0], log(0.5), 1e-7);                /* the original columns are copied */
    NM_LA_FREE(out);
}

static void test_viterbi_three_tokens_known_path(void)
{
    enum { F = 10, C = 4 };
    float *m = emissions(F, C, 0.0333f);
    const int tokens[3] = { 1, 2, 3 };
    NMLaPlace out[3];
    int rc;

    for (int t = 0; t < F; t++)
        set(m, C, t, 0, 0.9f);          /* blank loud everywhere ... */
    set(m, C, 2, 0, 0.0333f); set(m, C, 2, 1, 0.9f);   /* ... except a at 2-3 */
    set(m, C, 3, 0, 0.0333f); set(m, C, 3, 1, 0.9f);
    set(m, C, 5, 0, 0.0333f); set(m, C, 5, 2, 0.9f);   /* b at 5-6 */
    set(m, C, 6, 0, 0.0333f); set(m, C, 6, 2, 0.9f);
    set(m, C, 8, 0, 0.0333f); set(m, C, 8, 3, 0.9f);   /* c at 8 */

    rc = nm_la_viterbi(m, F, C, tokens, 3, 0, -1, 0.0f, out);
    CHECK_EQ_INT(rc, 1);
    CHECK_EQ_INT(out[0].first, 2); CHECK_EQ_INT(out[0].last, 3);
    CHECK_EQ_INT(out[1].first, 5); CHECK_EQ_INT(out[1].last, 6);
    CHECK_EQ_INT(out[2].first, 8); CHECK_EQ_INT(out[2].last, 8);
    CHECK_NEAR(out[0].post, 0.9, 1e-5);
    free(m);
}

static void test_viterbi_repeat_rule(void)
{
    enum { F = 6, C = 2 };
    float *m = emissions(F, C, 0.05f);
    const int tokens[2] = { 1, 1 };
    NMLaPlace out[2];

    for (int t = 0; t < F; t++)
        set(m, C, t, 1, 0.9f);           /* a loud at every frame */
    CHECK_EQ_INT(nm_la_viterbi(m, F, C, tokens, 2, 0, -1, 0.0f, out), 1);
    /* a a needs a blank between the two runs */
    CHECK(out[1].first > out[0].last + 1);
    CHECK(out[0].first >= 0 && out[1].last <= F - 1);
    free(m);
}

static void test_viterbi_star_skip(void)
{
    enum { F = 5, C = 3 };               /* blank, a, star */
    float *m = emissions(F, C, 0.05f);
    const int tokens[2] = { 2, 1 };      /* star, a */
    NMLaPlace out[2];

    for (int t = 0; t < F; t++) {
        set(m, C, t, 0, 0.9f);
        m[t * C + 2] = NM_LA_NEG;        /* the star is impossible everywhere */
    }
    set(m, C, 2, 0, 0.05f); set(m, C, 2, 1, 0.9f);
    set(m, C, 3, 0, 0.05f); set(m, C, 3, 1, 0.9f);
    CHECK_EQ_INT(nm_la_viterbi(m, F, C, tokens, 2, 0, 2, 0.0f, out), 1);
    CHECK_EQ_INT(out[0].first, -1);      /* never visited */
    CHECK_EQ_INT(out[0].last, -1);
    CHECK_EQ_INT(out[1].first, 2);
    CHECK_EQ_INT(out[1].last, 3);
    free(m);
}

static void test_viterbi_penalty_changes_path(void)
{
    enum { F = 6, C = 3 };               /* blank, a, b */
    float *m = emissions(F, C, 0.01f);
    const int tokens[2] = { 1, 2 };
    NMLaPlace out[2];

    set(m, C, 0, 1, 0.9f); set(m, C, 1, 1, 0.9f);               /* a at 0-1 */
    set(m, C, 2, 0, 0.5f); set(m, C, 2, 2, 0.48f);              /* blank beats b by 0.041 nats ... */
    set(m, C, 3, 0, 0.5f); set(m, C, 3, 2, 0.48f);
    set(m, C, 4, 2, 0.9f); set(m, C, 5, 2, 0.9f);               /* b at 4-5 */

    CHECK_EQ_INT(nm_la_viterbi(m, F, C, tokens, 2, 0, -1, 0.0f, out), 1);
    CHECK_EQ_INT(out[1].first, 4);                              /* ... so b starts at 4 without the penalty */
    CHECK_EQ_INT(nm_la_viterbi(m, F, C, tokens, 2, 0, -1, NM_LA_LINE_BLANK_PENALTY, out), 1);
    CHECK_EQ_INT(out[1].first, 2);                              /* ... and at 2 with 0.05 nats on the internal blank */
    free(m);
}

static void test_viterbi_ties_prefer_staying(void)
{
    /* At frame 0 the blank and `a` score the same, so at frame 1 state `a`
     * can come from itself or from the blank with equal scores. numpy's
     * argmax took the first candidate (stay), so `a` runs from frame 0. */
    enum { F = 2, C = 2 };
    float *m = emissions(F, C, 0.5f);
    const int tokens[1] = { 1 };
    NMLaPlace out[1];

    set(m, C, 1, 0, 0.05f); set(m, C, 1, 1, 0.9f);
    CHECK_EQ_INT(nm_la_viterbi(m, F, C, tokens, 1, 0, -1, 0.0f, out), 1);
    CHECK_EQ_INT(out[0].first, 0);
    CHECK_EQ_INT(out[0].last, 1);
    free(m);
}

static void test_viterbi_no_path(void)
{
    enum { F = 3, C = 3 };
    float *m = emissions(F, C, 0.3f);
    const int tokens[5] = { 1, 2, 1, 2, 1 };
    NMLaPlace out[5];

    CHECK_EQ_INT(nm_la_viterbi(m, F, C, tokens, 5, 0, -1, 0.0f, out), 0);
    free(m);
}

static void test_viterbi_jfk_exact(void)
{
    float *logp = load_jfk_logp();
    float *star;
    int tokens[JFK_N_TOKENS + 2];
    NMLaPlace out[JFK_N_TOKENS + 2];
    int stars = 0, mismatches = 0;

    CHECK(logp != NULL);
    if (!logp)
        return;
    star = nm_la_add_star(logp, JFK_FRAMES, JFK_VOCAB);
    CHECK(star != NULL);
    if (!star) {
        free(logp);
        return;
    }
    tokens[0] = JFK_VOCAB;
    for (int i = 0; i < JFK_N_TOKENS; i++)
        tokens[1 + i] = JFK_TOKENS[i];
    tokens[JFK_N_TOKENS + 1] = JFK_VOCAB;

    CHECK_EQ_INT(nm_la_viterbi(star, JFK_FRAMES, JFK_VOCAB + 1, tokens, JFK_N_TOKENS + 2, JFK_BLANK,
                               JFK_VOCAB, JFK_LINE_BLANK_PENALTY, out), 1);
    for (int i = 0; i < JFK_N_TOKENS; i++) {
        if (out[1 + i].first != JFK_FIRST_FRAMES[i]) {
            mismatches++;
            fprintf(stderr, "  phone %d: frame %d, fixture %d\n", i, out[1 + i].first, JFK_FIRST_FRAMES[i]);
        }
        CHECK_NEAR(out[1 + i].post, JFK_POSTERIORS[i], 2e-3);
        CHECK(out[1 + i].last >= out[1 + i].first);
    }
    CHECK_EQ_INT(mismatches, 0);
    if (out[0].first >= 0)
        stars++;
    if (out[JFK_N_TOKENS + 1].first >= 0)
        stars++;
    CHECK_EQ_INT(stars, JFK_STAR_FRAMES);
    /* the line's spike start and the prototype's end (first frame of the last phone) */
    CHECK_NEAR(out[1].first * NM_LA_HOP / (double) NM_LA_RATE, JFK_START_SPIKE, 1e-9);
    CHECK_NEAR(out[JFK_N_TOKENS].first * NM_LA_HOP / (double) NM_LA_RATE, JFK_END, 1e-9);
    NM_LA_FREE(star);
    free(logp);
}

static void fill(NMLaPlace *p, int n, int first0, int step, float post)
{
    for (int i = 0; i < n; i++) {
        p[i].first = first0 + i * step;
        p[i].last = p[i].first;
        p[i].post = post;
    }
}

static void test_verdict_each_reason(void)
{
    NMLaPlace line[8], check[8];

    fill(line, 8, 100, 2, 0.9f);
    fill(check, 8, 100, 2, 0.9f);
    CHECK_EQ_INT(nm_la_verdict(line, 8, NULL), NM_LA_CHECK_FAILED);
    CHECK_EQ_INT(nm_la_verdict(line, 8, check), NM_LA_OK);

    check[0].first = 116;                                   /* 0.32 s away */
    CHECK_EQ_INT(nm_la_verdict(line, 8, check), NM_LA_DISAGREE);
    check[0].first = 115;                                   /* 0.30 s: not more than 0.3 */
    CHECK_EQ_INT(nm_la_verdict(line, 8, check), NM_LA_OK);
    check[0].first = 84;                                    /* 16 frames early */
    CHECK_EQ_INT(nm_la_verdict(line, 8, check), NM_LA_DISAGREE);
    check[0].first = 100;

    fill(line, 8, 100, 2, 0.9f);
    line[0].first = line[0].last = line[1].first - 26;      /* gap 0.52 s before phone 2 */
    check[0].first = line[0].first;
    CHECK_EQ_INT(nm_la_verdict(line, 8, check), NM_LA_FIRST_GAP);
    line[0].first = line[0].last = line[1].first - 25;      /* 0.50 s: not more than 0.5 */
    check[0].first = line[0].first;
    CHECK_EQ_INT(nm_la_verdict(line, 8, check), NM_LA_OK);

    /* stray prefix: three quiet phones, then a 0.82 s gap */
    fill(line, 8, 100, 1, 0.9f);
    line[0].post = line[1].post = line[2].post = 0.1f;
    for (int i = 3; i < 8; i++)
        line[i].first = line[i].last = 102 + 41 + (i - 3);
    check[0].first = 100;
    CHECK_EQ_INT(nm_la_verdict(line, 8, check), NM_LA_STRAY_PREFIX);
    line[0].post = line[1].post = line[2].post = 0.3f;      /* heard: mean 0.3 is not under 0.2 */
    CHECK_EQ_INT(nm_la_verdict(line, 8, check), NM_LA_OK);
    line[0].post = line[1].post = line[2].post = 0.1f;
    for (int i = 3; i < 8; i++)
        line[i].first = line[i].last = 102 + 40 + (i - 3);  /* 0.80 s: not more than 0.8 */
    CHECK_EQ_INT(nm_la_verdict(line, 8, check), NM_LA_OK);
    /* the same gap after phone 7 is past the 6-phone prefix */
    fill(line, 8, 100, 1, 0.1f);
    line[7].first = line[7].last = 106 + 41;
    CHECK_EQ_INT(nm_la_verdict(line, 8, check), NM_LA_OK);

    /* one-phone lines cannot have a gap */
    fill(line, 1, 100, 1, 0.1f);
    CHECK_EQ_INT(nm_la_verdict(line, 1, check), NM_LA_OK);

    CHECK(!strcmp(nm_la_reason_name(NM_LA_EMPTY), "empty"));
    CHECK(!strcmp(nm_la_reason_name(NM_LA_NO_PHONES), "no_phones"));
    CHECK(!strcmp(nm_la_reason_name(NM_LA_DISAGREE), "disagree"));
    CHECK(!strcmp(nm_la_reason_name(NM_LA_FIRST_GAP), "first_gap"));
    CHECK(!strcmp(nm_la_reason_name(NM_LA_STRAY_PREFIX), "stray_prefix"));
    CHECK(!strcmp(nm_la_reason_name(NM_LA_CHECK_FAILED), "check_failed"));
    CHECK(!strcmp(nm_la_reason_name(NM_LA_NO_ALIGNMENT), "no_alignment"));
}

static void test_envelope_db(void)
{
    float square[1600], silence[320];
    float *env;
    int n;

    for (int i = 0; i < 1600; i++)
        square[i] = (i & 1) ? 0.5f : -0.5f;
    memset(silence, 0, sizeof(silence));

    env = nm_la_envelope_db(square, 1600, &n);
    CHECK_EQ_INT(n, 10);
    for (int k = 0; k < n; k++)
        CHECK_NEAR(env[k], 20 * log10(0.5), 0.01);
    NM_LA_FREE(env);

    env = nm_la_envelope_db(square, 1599, &n);
    CHECK_EQ_INT(n, 9);
    NM_LA_FREE(env);

    env = nm_la_envelope_db(silence, 320, &n);
    CHECK_EQ_INT(n, 2);
    CHECK_NEAR(env[0], -180.0, 0.01);
    NM_LA_FREE(env);

    env = nm_la_envelope_db(silence, 100, &n);
    CHECK_EQ_INT(n, 0);
    NM_LA_FREE(env);
}

static void test_walk_back_stops_at_each_limit(void)
{
    float env[200];

    /* A: the voice begins at hop 50 (-60 dB before it): spike at frame 30 (hop 60) walks to 50 */
    for (int k = 0; k < 200; k++)
        env[k] = k < 50 ? -60.0f : -20.0f;
    CHECK_EQ_INT(nm_la_walk_back(env, 200, 30, -1), 50);

    /* B: flat -25 dB: at most 0.8 s (80 hops), clamped at 0 */
    for (int k = 0; k < 200; k++)
        env[k] = -25.0f;
    CHECK_EQ_INT(nm_la_walk_back(env, 200, 50, -1), 20);
    CHECK_EQ_INT(nm_la_walk_back(env, 200, 30, -1), 0);

    /* C: never before the previous line's end + 0.05 s (frame 20 = hop 40, + 5) */
    CHECK_EQ_INT(nm_la_walk_back(env, 200, 50, 20), 45);

    /* D: a step of 11 dB stops the walk (within 10 dB of the level at the spike) */
    for (int k = 0; k < 200; k++)
        env[k] = k < 55 ? -36.0f : -25.0f;
    CHECK_EQ_INT(nm_la_walk_back(env, 200, 30, -1), 55);
    for (int k = 0; k < 200; k++)
        env[k] = k < 55 ? -34.0f : -25.0f;                  /* 9 dB: keeps walking */
    CHECK_EQ_INT(nm_la_walk_back(env, 200, 30, -1), 0);

    /* E: the -45 dBFS floor, on its own (level -40, so -46 is within 10 dB but under the floor) */
    for (int k = 0; k < 200; k++)
        env[k] = k < 50 ? -46.0f : -40.0f;
    CHECK_EQ_INT(nm_la_walk_back(env, 200, 30, -1), 50);
    for (int k = 0; k < 200; k++)
        env[k] = k < 50 ? -44.0f : -40.0f;                  /* above the floor: keeps walking */
    CHECK_EQ_INT(nm_la_walk_back(env, 200, 30, -1), 0);

    /* F: the level is the loudest of the five hops from the spike */
    for (int k = 0; k < 200; k++)
        env[k] = -25.0f;
    env[63] = -10.0f;                                       /* level -10: -25 is 15 dB under it */
    CHECK_EQ_INT(nm_la_walk_back(env, 200, 30, -1), 60);

    /* G: a spike past the end of the envelope is clamped, not read out of bounds */
    for (int k = 0; k < 200; k++)
        env[k] = -25.0f;
    CHECK_EQ_INT(nm_la_walk_back(env, 200, 150, -1), 199 - 80);
}

static void test_walk_back_jfk(void)
{
    const char *wav = getenv("JFK_WAV");
    float *samples, *env;
    int n, n_env, k;

    if (!wav || !*wav) {
        fprintf(stderr, "  (JFK_WAV unset: walk-back on the real clip skipped)\n");
        return;
    }
    samples = load_wav16(wav, &n);
    CHECK(samples != NULL);
    if (!samples)
        return;
    CHECK_EQ_INT(n, 176000);
    env = nm_la_envelope_db(samples, n, &n_env);
    CHECK_EQ_INT(n_env, 1100);
    k = nm_la_walk_back(env, n_env, (int) lround(JFK_START_SPIKE * NM_LA_RATE / NM_LA_HOP), -1);
    CHECK_NEAR(k * 0.01, JFK_START_WRITTEN, 1e-9);
    CHECK_NEAR(JFK_START_SPIKE - k * 0.01, JFK_LEAD_IN, 1e-9);

    /* #130 keeps these numbers. The line is the first line: step 7 walks it
     * back, 7b leaves a line that was walked back alone (and this one begins
     * on a vowel, so it is 7b's kind), 7c needs a previous line's end. */
    {
        int n_rms20;
        float *rms20 = nm_la_rms_db(samples, n, NM_LA_HOP, &n_rms20);
        NMLaLineOnset line = onset_of((int) lround(JFK_START_SPIKE * NM_LA_RATE / NM_LA_HOP), -1,
                                      JFK_PHONE_STRINGS[0], JFK_N_WORDS, JFK_WORD_SCORES[0]);

        CHECK(rms20 != NULL);
        CHECK_EQ_INT(n_rms20, 550);
        CHECK_EQ_INT(line.soft_onset, 1);
        CHECK_EQ_INT(nm_la_written_start(env, n_env, rms20, n_rms20, &line, NM_LA_SOFT_WALK_HOPS, 1), k);
        CHECK_EQ_INT(nm_la_written_start(env, n_env, NULL, 0, &line, 0, 0), k);
        line.first_word_score = 0.0;                        /* even with a first word nobody heard */
        CHECK_EQ_INT(nm_la_written_start(env, n_env, rms20, n_rms20, &line, NM_LA_SOFT_WALK_HOPS, 1), k);
        NM_LA_FREE(rms20);
    }
    NM_LA_FREE(env);
    free(samples);
}

/* --------------------------------------------------------------------------
 * Step 7 with its refinements 7b and 7c (#130)
 * ------------------------------------------------------------------------ */

static void test_written_start_is_step_7_when_both_are_off(void)
{
    enum { N = 400 };
    float env[N];
    NMLaLineOnset line;

    fill_db(env, N, -60.0f);
    set_db(env, 150, N, -20.0f);                            /* the voice begins at hop 150 */

    /* after a pause, or on the first line: the walk-back, as nm_la_walk_back gives it */
    line = onset_of(100, -1, "p", 3, 0.9);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, 0, 0), nm_la_walk_back(env, N, 100, -1));
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, 0, 0), 150);
    line = onset_of(100, 50, "p", 3, 0.9);                  /* exactly 1.0 s after the previous line */
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, 0, 0), 150);
    /* step 7 walked 0.5 s here; 7b, which stops at 0.1 s, must not take that back on a soft onset */
    line = onset_of(100, -1, "a", 3, 0.9);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 150);
    /* no pause: the spike itself, whatever the envelope, the first phone and the score are */
    line = onset_of(100, 51, "a", 3, 0.0);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, 0, 0), 200);
    /* a spike past the envelope's end stays the spike when nothing walks */
    CHECK_EQ_INT(nm_la_written_start(env, 100, NULL, 0, &line, 0, 0), 200);
    CHECK_EQ_INT(nm_la_written_start(env, 100, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 200);
}

static void test_soft_walk_back(void)
{
    enum { N = 400, SPIKE = 100, PREV = 80 };               /* the spike is hop 200; no pause before it */
    const char *vowel = "a\xC9\xAA", *sonorant = "l", *plosive = "p", *fricative = "s";     /* the vowel is aɪ */
    float env[N];
    NMLaLineOnset line;

    /* the voice sits at -20 dB from the spike on, after a 60 ms rise at -28 dB out of silence */
    fill_db(env, N, -60.0f);
    set_db(env, 194, 200, -28.0f);
    set_db(env, 200, N, -20.0f);
    line = onset_of(SPIKE, PREV, vowel, 3, 0.9);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 194);    /* 60 ms earlier */
    line = onset_of(SPIKE, PREV, sonorant, 3, 0.9);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 194);
    /* a hard onset with the same envelope does not move */
    line = onset_of(SPIKE, PREV, plosive, 3, 0.9);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 200);
    line = onset_of(SPIKE, PREV, fricative, 3, 0.9);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 200);
    /* soft_walkback=0 turns it off */
    line = onset_of(SPIKE, PREV, vowel, 3, 0.9);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, 0, 1), 200);

    /* a 200 ms rise: the walk stops at its maximum, 100 ms by default */
    set_db(env, 180, 200, -28.0f);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 190);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, 5, 1), 195);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, 20, 1), 180);

    /* never before the previous line's end + 0.05 s (frame 97 is hop 194, + 5) */
    line = onset_of(SPIKE, 97, vowel, 3, 0.9);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 199);
    line = onset_of(SPIKE, 99, vowel, 3, 0.9);              /* the floor is past the spike: it stays */
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 200);

    /* A line step 7 walked back does not move again. Step 7 stops at hop 194:
     * -36 dB is more than 10 dB under the -20 at the spike. A second walk from
     * 194 would measure its level there (-28) and go on to 188. */
    fill_db(env, N, -60.0f);
    set_db(env, 188, 194, -36.0f);
    set_db(env, 194, 200, -28.0f);
    set_db(env, 200, N, -20.0f);
    line = onset_of(SPIKE, -1, vowel, 3, 0.9);              /* the first line */
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 194);
    line = onset_of(SPIKE, SPIKE - 50, vowel, 3, 0.9);      /* after a pause of 1.0 s */
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 194);
    CHECK_EQ_INT(nm_la_written_start(env, N, NULL, 0, &line, 80, 1), 194);
}

static void test_unheard_island(void)
{
    /* The line's first phone is at frame 200 (4.00 s, hop 400) and is a
     * plosive, so 7b stays out of it. The previous line ends at frame 60 and
     * its last note is held until frame 90 (1.8 s). */
    enum { F = 400, SPIKE = 200, PREV = 60 };
    float frames[F], env[2 * F];
    NMLaLineOnset line;

#define ISLAND_SCENE() do {                                                     \
        fill_db(frames, F, -70.0f);                                             \
        set_db(frames, 0, 90, -20.0f);                                          \
        set_db(frames, SPIKE, F, -20.0f);                                       \
    } while (0)
#define START(soft_hops, island) (hops_of(frames, F, env),                      \
                                  nm_la_written_start(env, 2 * F, frames, F, &line, soft_hops, island))

    /* a 0.7 s shout at -17 dB after 1 s of silence, 1.2 s before the start */
    ISLAND_SCENE();
    set_db(frames, 140, 175, -17.0f);
    line = onset_of(SPIKE, PREV, "p", 3, 0.005);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 280);      /* the island's onset, 2.80 s */
    CHECK_EQ_INT(START(0, 1), 280);
    /* unheard_island=0 turns it off */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 0), 400);
    /* without the 20 ms frames there is nothing to look at */
    CHECK_EQ_INT(nm_la_written_start(env, 2 * F, NULL, 0, &line, NM_LA_SOFT_WALK_HOPS, 1), 400);
    /* a first word the model heard: 0.05; and 0.01 is not below 0.01 */
    line = onset_of(SPIKE, PREV, "p", 3, 0.05);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    line = onset_of(SPIKE, PREV, "p", 3, 0.01);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    line = onset_of(SPIKE, PREV, "p", 3, 0.0099);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 280);
    /* a line of one word has no second word to be late for */
    line = onset_of(SPIKE, PREV, "p", 1, 0.005);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    /* the first line has no previous end */
    line = onset_of(SPIKE, -1, "p", 3, 0.005);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);

    /* a breath: 0.2 s of sound is not an island; 0.3 s is */
    line = onset_of(SPIKE, PREV, "p", 3, 0.005);
    ISLAND_SCENE();
    set_db(frames, 140, 150, -17.0f);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    set_db(frames, 140, 154, -17.0f);                       /* 0.28 s */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    set_db(frames, 140, 155, -17.0f);                       /* 0.30 s */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 280);

    /* the island needs 0.3 s of quiet before it */
    ISLAND_SCENE();
    set_db(frames, 90, 126, -20.0f);                        /* the held note goes on until 0.28 s before */
    set_db(frames, 140, 175, -17.0f);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    set_db(frames, 125, 126, -70.0f);                       /* 0.30 s of quiet */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 280);
    /* a frame between -45 and -35 dB is neither quiet nor sound: it does not
     * count, and it does not start the count over */
    set_db(frames, 125, 140, -40.0f);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);      /* nothing quiet is left before the island */
    ISLAND_SCENE();
    set_db(frames, 110, 125, -40.0f);
    set_db(frames, 140, 175, -17.0f);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 280);      /* 0.2 s + 0.3 s of quiet around them */
    /* a frame of sound starts the count over */
    ISLAND_SCENE();
    set_db(frames, 128, 130, -17.0f);                       /* a click 0.2 s before the island */
    set_db(frames, 140, 175, -17.0f);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    /* the thresholds themselves: -35 dB is sound, -45 dB is not quiet */
    ISLAND_SCENE();
    set_db(frames, 140, 175, -35.0f);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 280);
    set_db(frames, 140, 175, -35.5f);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    ISLAND_SCENE();
    set_db(frames, 90, 140, -45.0f);
    set_db(frames, 140, 175, -17.0f);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);

    /* an island closer than 0.2 s to the start does not move the line ...
     * (the previous line ends 0.8 s before this one, so step 7 does not walk
     * into the sound itself) */
    line = onset_of(SPIKE, 160, "p", 3, 0.005);
    ISLAND_SCENE();
    set_db(frames, 192, SPIKE, -20.0f);                     /* 0.16 s before, running into the line */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    set_db(frames, 190, SPIKE, -20.0f);                     /* 0.20 s: not more than 0.2 s */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    /* ... one that begins 0.22 s before does, and it may run past the window's end */
    set_db(frames, 189, SPIKE, -20.0f);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 378);

    /* an island before the previous line's end is not seen */
    ISLAND_SCENE();
    set_db(frames, 140, 175, -17.0f);
    line = onset_of(SPIKE, 180, "p", 3, 0.005);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    line = onset_of(SPIKE, 150, "p", 3, 0.005);             /* the previous line ends inside it */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    line = onset_of(SPIKE, 125, "p", 3, 0.005);             /* 0.3 s of quiet after the previous end */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 280);
    line = onset_of(SPIKE, 126, "p", 3, 0.005);             /* 0.28 s */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);

    /* the window opens 2.0 s before the start: sound from before it is not an onset */
    ISLAND_SCENE();
    set_db(frames, 0, 90, -70.0f);
    set_db(frames, 80, 115, -17.0f);                        /* begins 2.4 s before the start */
    line = onset_of(SPIKE, 10, "p", 3, 0.005);
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    set_db(frames, 80, 115, -70.0f);
    set_db(frames, 114, 150, -17.0f);                       /* quiet for 0.28 s inside the window, then sound */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
    set_db(frames, 114, 115, -70.0f);                       /* 0.30 s */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 230);

    /* 7b first, then 7c from where 7b put the start. No pause before the
     * line (the previous one ends 0.96 s earlier), so step 7 is not in it. */
    ISLAND_SCENE();
    set_db(frames, 170, 186, -17.0f);                       /* a 0.32 s island, 0.6 s before the line */
    set_db(frames, 197, SPIKE, -28.0f);                     /* a 60 ms rise into the line */
    line = onset_of(SPIKE, 152, "a", 3, 0.9);               /* soft and heard: 7b only */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 394);
    line = onset_of(SPIKE, 152, "a", 3, 0.005);             /* soft and unheard: 7b, then the island */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 340);
    line = onset_of(SPIKE, 152, "p", 3, 0.005);             /* hard and unheard: the island */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 340);
    line = onset_of(SPIKE, 152, "p", 3, 0.9);               /* hard and heard: the spike */
    CHECK_EQ_INT(START(NM_LA_SOFT_WALK_HOPS, 1), 400);
#undef ISLAND_SCENE
#undef START
}

static void test_rms_db_per_frame(void)
{
    float square[1600];
    float *rms;
    int n;

    for (int i = 0; i < 1600; i++)
        square[i] = i < 320 ? 0.0f : ((i & 1) ? 0.5f : -0.5f);
    rms = nm_la_rms_db(square, 1600, NM_LA_HOP, &n);
    CHECK_EQ_INT(n, 5);                                     /* 20 ms frames */
    CHECK_NEAR(rms[0], -180.0, 0.01);
    for (int k = 1; k < n; k++)
        CHECK_NEAR(rms[k], 20 * log10(0.5), 0.01);
    NM_LA_FREE(rms);
    rms = nm_la_rms_db(square, 319, NM_LA_HOP, &n);
    CHECK_EQ_INT(n, 0);
    NM_LA_FREE(rms);
}

/* v1.0.46 printed the start of a line that was not walked back from its
 * 20 ms frame, and the lead-in as a difference of two times. A start is a
 * 10 ms hop now and the lead-in a number of hops. Both give the same text,
 * so a line the refinements leave alone is written as it was. */
static void test_times_print_as_before(void)
{
    char was[32], is[32];
    int differ = 0;

    for (int f = 0; f < 720000; f++) {                      /* four hours of frames */
        snprintf(was, sizeof(was), "%.3f", f * (double) NM_LA_HOP / NM_LA_RATE);
        snprintf(is, sizeof(is), "%.3f", (f * 2) * 0.01);
        differ += strcmp(was, is) != 0;
    }
    CHECK_EQ_INT(differ, 0);
    for (int f = 0; f < 720000; f += 97) {
        for (int lead = 0; lead <= NM_LA_WALK_MAX_HOPS && lead <= 2 * f; lead++) {
            double old_lead = f * (double) NM_LA_HOP / NM_LA_RATE - (2 * f - lead) * 0.01;

            if (old_lead < 0)
                old_lead = 0;
            snprintf(was, sizeof(was), "%.3f", old_lead);
            snprintf(is, sizeof(is), "%.3f", lead * 0.01);
            differ += strcmp(was, is) != 0;
        }
    }
    CHECK_EQ_INT(differ, 0);
}

static void test_pause_before(void)
{
    CHECK_EQ_INT(nm_la_pause_before(50, 0), 1);
    CHECK_EQ_INT(nm_la_pause_before(49, 0), 0);
    CHECK_EQ_INT(nm_la_pause_before(10, -1), 1);
    CHECK_EQ_INT(nm_la_pause_before(560, 510), 1);
}

int main(void)
{
    test_log_softmax_rows_sum_to_one();
    test_star_column();
    test_viterbi_three_tokens_known_path();
    test_viterbi_repeat_rule();
    test_viterbi_star_skip();
    test_viterbi_penalty_changes_path();
    test_viterbi_ties_prefer_staying();
    test_viterbi_no_path();
    test_viterbi_jfk_exact();
    test_verdict_each_reason();
    test_envelope_db();
    test_walk_back_stops_at_each_limit();
    test_walk_back_jfk();
    test_written_start_is_step_7_when_both_are_off();
    test_soft_walk_back();
    test_unheard_island();
    test_rms_db_per_frame();
    test_times_print_as_before();
    test_pause_before();
    fprintf(stderr, "%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}

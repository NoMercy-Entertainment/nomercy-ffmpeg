/*
 * nm_lyricsalign_align.h - the alignment arithmetic of the lyricsalign filter
 * (nomercy-ffmpeg #126): log-softmax, the star column, the blank-interleaved
 * star Viterbi, the agreement verdict, the RMS envelope and the onset
 * walk-back. Processing steps 3, 5, 6 and 7 of the spec, ported number for
 * number from the Python prototype (lyrics_eval.ctc_align, ctc_pipeline,
 * onset, audio) so that the C filter places a line where the prototype did.
 *
 * Step 7 has two refinements (#130), both measured on the reference set and
 * both only ever moving a written start earlier: 7b, a short walk-back for a
 * line that begins on a vowel or a sonorant, and 7c, the start of a line
 * whose first word the model did not hear moved onto sound no word claims.
 * nm_la_written_start() runs the three in order.
 *
 * Header-only and free of FFmpeg and ggml on purpose: the same code the
 * filter runs is compiled by tests/unit/test_nm_lyricsalign_align.c with a
 * plain C compiler and checked against the prototype's JFK fixture.
 *
 * Times are integers here. Emission frames are 20 ms (320 samples at 16 kHz),
 * envelope hops are 10 ms (160 samples); the spec's second thresholds become
 * frame counts that decide exactly what the prototype's float comparisons
 * decided (its starts are multiples of 0.02 rounded to 3 decimals).
 *
 * Memory comes from NM_LA_MALLOC / NM_LA_FREE, defaulting to the C library;
 * af_lyricsalign.c points them at av_malloc and av_free first.
 */
#ifndef NM_LYRICSALIGN_ALIGN_H
#define NM_LYRICSALIGN_ALIGN_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifndef NM_LA_MALLOC
#include <stdlib.h>
#define NM_LA_MALLOC(n) malloc(n)
#define NM_LA_FREE(p)   free(p)
#endif

#define NM_LA_RATE 16000
#define NM_LA_HOP 320                      /* samples per emission frame: 20 ms */
#define NM_LA_ENV_HOP 160                  /* samples per envelope hop: 10 ms */
#define NM_LA_STAR_WEIGHT 0.3              /* the star's share of the non-blank mass */
#define NM_LA_LINE_BLANK_PENALTY 0.05f     /* nats per frame on a blank between two phones of one line */
#define NM_LA_NEG (-1e9f)

/* Agreement check and skip reasons, in frames of 20 ms (spec: seconds). */
#define NM_LA_DISAGREE_FRAMES 15           /* |check - vocals| > 0.3 s  ->  >= 16 frames */
#define NM_LA_FIRST_GAP_FRAMES 25          /* gap phone 1 -> 2 > 0.5 s  ->  >= 26 */
#define NM_LA_STRAY_PREFIX_PHONES 6
#define NM_LA_STRAY_PREFIX_GAP_FRAMES 40   /* > 0.8 s  ->  >= 41 */
#define NM_LA_STRAY_PREFIX_POSTERIOR 0.2
#define NM_LA_LEAD_IN_GAP_FRAMES 50        /* a pause of >= 1.0 s before the line */

/* Onset walk-back, in envelope hops of 10 ms. */
#define NM_LA_WALK_WITHIN_DB 10.0f
#define NM_LA_WALK_FLOOR_DB (-45.0f)
#define NM_LA_WALK_MAX_HOPS 80             /* 0.8 s */
#define NM_LA_WALK_MARGIN_HOPS 5           /* 0.05 s after the previous line */

/* 7b, the soft-onset walk-back: the same walk, shorter. */
#define NM_LA_SOFT_WALK_HOPS 10            /* at most 0.1 s (the default of soft_walkback) */

/* 7c, the island before an unheard first word. The window is counted in
 * envelope hops of 10 ms, the island itself in RMS frames of 20 ms. */
#define NM_LA_ISLAND_SCORE 0.01            /* a first word scoring below this was not heard */
#define NM_LA_ISLAND_LOOK_HOPS 200         /* the window opens 2.0 s before the start ... */
#define NM_LA_ISLAND_NEAR_HOPS 10          /* ... and closes 0.1 s before it */
#define NM_LA_ISLAND_QUIET_DB (-45.0f)     /* a frame under this is quiet */
#define NM_LA_ISLAND_LOUD_DB (-35.0f)      /* a frame at or over this is sound */
#define NM_LA_ISLAND_QUIET_FRAMES 15       /* 0.3 s of quiet before the island */
#define NM_LA_ISLAND_MIN_FRAMES 15         /* the island lasts at least 0.3 s */
#define NM_LA_ISLAND_MOVE_HOPS 20          /* its onset is more than 0.2 s before the start */

enum NMLaReason {
    NM_LA_OK = 0,
    NM_LA_EMPTY,          /* the text line is empty */
    NM_LA_NO_PHONES,      /* nothing mapped onto the vocabulary */
    NM_LA_DISAGREE,       /* the vocals and the check placed the line apart */
    NM_LA_FIRST_GAP,      /* the first phone sits away from the second */
    NM_LA_STRAY_PREFIX,   /* a few unheard first phones dumped early */
    NM_LA_CHECK_FAILED,   /* the check alignment had no placement */
    NM_LA_NO_ALIGNMENT    /* the whole track has no path */
};

static inline const char *nm_la_reason_name(enum NMLaReason r)
{
    switch (r) {
    case NM_LA_OK:           return "ok";
    case NM_LA_EMPTY:        return "empty";
    case NM_LA_NO_PHONES:    return "no_phones";
    case NM_LA_DISAGREE:     return "disagree";
    case NM_LA_FIRST_GAP:    return "first_gap";
    case NM_LA_STRAY_PREFIX: return "stray_prefix";
    case NM_LA_CHECK_FAILED: return "check_failed";
    case NM_LA_NO_ALIGNMENT: return "no_alignment";
    }
    return "?";
}

/* Where the Viterbi put one token: its run's first and last frame (inclusive),
 * -1 for a token the path never visited (a skipped star), and the model's
 * posterior for the token at its first frame. */
typedef struct NMLaPlace {
    int first;
    int last;
    float post;
} NMLaPlace;

/* ---------------------------------------------------------------------------
 * Step 2 tail: log-softmax over a frame's logits, in double.
 * ------------------------------------------------------------------------- */
static inline void nm_la_log_softmax(const float *logits, int frames, int vocab, float *logp)
{
    for (int t = 0; t < frames; t++) {
        const float *x = logits + (size_t) t * vocab;
        float *y = logp + (size_t) t * vocab;
        double m = x[0], sum = 0.0, lse;

        for (int v = 1; v < vocab; v++)
            if (x[v] > m)
                m = x[v];
        for (int v = 0; v < vocab; v++)
            sum += exp((double) x[v] - m);
        lse = m + log(sum);
        for (int v = 0; v < vocab; v++)
            y[v] = (float) ((double) x[v] - lse);
    }
}

/* ---------------------------------------------------------------------------
 * Step 3: the star column. Returns frames x (vocab + 1), column vocab being
 * star = log(1 - p_blank) + log(0.3), or NM_LA_NEG where nothing is left.
 * ------------------------------------------------------------------------- */
static inline float *nm_la_add_star(const float *logp, int frames, int vocab)
{
    const int cols = vocab + 1;
    float *out = (float *) NM_LA_MALLOC(sizeof(*out) * (size_t) frames * cols + 1);
    const double logw = log(NM_LA_STAR_WEIGHT);

    if (!out)
        return NULL;
    for (int t = 0; t < frames; t++) {
        const float *src = logp + (size_t) t * vocab;
        float *dst = out + (size_t) t * cols;
        double rest = -expm1((double) src[0]);   /* 1 - p_blank; the blank is column 0 */

        memcpy(dst, src, sizeof(*dst) * vocab);
        dst[vocab] = rest > 0 ? (float) (log(rest > 1e-300 ? rest : 1e-300) + logw) : NM_LA_NEG;
    }
    return out;
}

/* ---------------------------------------------------------------------------
 * Step 5: Viterbi over the chain blank, t1, blank, t2, ..., tn, blank.
 *
 * logp is frames x cols (cols = vocab + 1 when a star column was appended);
 * tokens are column indices, star is the star's column or -1. Transitions
 * into state s at frame t come from s (stay) and s-1 always; from s-2 when s
 * is a token other than the first and its token differs from the one at s-2;
 * from s-3 when s is a token and the token at s-2 is a star; from s-4 when,
 * additionally, the token at s-4 differs from s's. Candidates are compared in
 * that order with a strict greater-than, so a tie goes to the earliest one,
 * exactly as numpy's argmax did in the prototype; scores are float32 and
 * accumulate in float32 for the same reason.
 *
 * A blank between two phones of one line (neither neighbour a star) costs
 * line_penalty per frame. Start in state 0 or 1, end in 2n or 2n-1.
 *
 * Returns 1 and fills out[n_tokens] when a path exists, 0 when none does,
 * -1 when memory ran out.
 * ------------------------------------------------------------------------- */
static inline int nm_la_viterbi(const float *logp, int frames, int cols, const int *tokens, int n_tokens,
                                int blank, int star, float line_penalty, NMLaPlace *out)
{
    const int n = 2 * n_tokens + 1;
    int *col = NULL;          /* column each state reads */
    float *pen = NULL;        /* penalty subtracted from that state's emission */
    unsigned char *from2 = NULL, *from3 = NULL, *from4 = NULL;
    float *score = NULL, *next = NULL;
    int8_t *back = NULL;      /* frames x n: how far back the best predecessor sat */
    int last, state, rc = -1;

    for (int i = 0; i < n_tokens; i++)
        out[i].first = out[i].last = -1, out[i].post = 0.0f;
    if (frames <= 0 || n_tokens < 0)
        return 0;

    col = (int *) NM_LA_MALLOC(sizeof(*col) * n);
    pen = (float *) NM_LA_MALLOC(sizeof(*pen) * n);
    from2 = (unsigned char *) NM_LA_MALLOC((size_t) n * 3);
    score = (float *) NM_LA_MALLOC(sizeof(*score) * n);
    next = (float *) NM_LA_MALLOC(sizeof(*next) * n);
    back = (int8_t *) NM_LA_MALLOC((size_t) frames * n);
    if (!col || !pen || !from2 || !score || !next || !back)
        goto done;
    from3 = from2 + n;
    from4 = from3 + n;

#define NM_LA_TOK(s)     tokens[((s) - 1) / 2]
#define NM_LA_IS_TOK(s)  ((s) & 1)
#define NM_LA_IS_STAR(s) (NM_LA_IS_TOK(s) && star >= 0 && NM_LA_TOK(s) == star)
    for (int s = 0; s < n; s++) {
        col[s] = NM_LA_IS_TOK(s) ? NM_LA_TOK(s) : blank;
        pen[s] = 0.0f;
        if (!NM_LA_IS_TOK(s) && s >= 2 && s <= n - 2 && !NM_LA_IS_STAR(s - 1) && !NM_LA_IS_STAR(s + 1))
            pen[s] = line_penalty;
        from2[s] = NM_LA_IS_TOK(s) && s >= 3 && NM_LA_TOK(s) != NM_LA_TOK(s - 2);
        from3[s] = NM_LA_IS_TOK(s) && s >= 3 && NM_LA_IS_STAR(s - 2);
        from4[s] = from3[s] && s >= 5 && NM_LA_TOK(s) != NM_LA_TOK(s - 4);
    }

    for (int s = 0; s < n; s++)
        score[s] = NM_LA_NEG;
    score[0] = logp[col[0]] - pen[0];
    if (n > 1)
        score[1] = logp[col[1]] - pen[1];
    memset(back, 0, n);

    for (int t = 1; t < frames; t++) {
        const float *row = logp + (size_t) t * cols;
        int8_t *bt = back + (size_t) t * n;

        for (int s = 0; s < n; s++) {
            float best = score[s];
            int8_t by = 0;
            float c;

            if (s >= 1 && (c = score[s - 1]) > best)
                best = c, by = 1;
            if (from2[s] && (c = score[s - 2]) > best)
                best = c, by = 2;
            if (from3[s] && (c = score[s - 3]) > best)
                best = c, by = 3;
            if (from4[s] && (c = score[s - 4]) > best)
                best = c, by = 4;
            bt[s] = by;
            next[s] = best + (row[col[s]] - pen[s]);
        }
        memcpy(score, next, sizeof(*score) * n);
    }

    last = (n == 1 || score[n - 1] >= score[n - 2]) ? n - 1 : n - 2;
    if (score[last] <= NM_LA_NEG / 2) {
        rc = 0;
        goto done;
    }
    state = last;
    for (int t = frames - 1; t >= 0; t--) {
        if (NM_LA_IS_TOK(state)) {
            NMLaPlace *p = &out[(state - 1) / 2];
            p->first = t;                 /* overwritten on the way back: ends at the run's first frame */
            if (p->last < 0)
                p->last = t;              /* the first time the state is seen is the run's last frame */
        }
        if (t > 0)
            state -= back[(size_t) t * n + state];
    }
    for (int i = 0; i < n_tokens; i++)
        if (out[i].first >= 0)
            out[i].post = (float) exp((double) logp[(size_t) out[i].first * cols + tokens[i]]);
    rc = 1;
#undef NM_LA_TOK
#undef NM_LA_IS_TOK
#undef NM_LA_IS_STAR
done:
    NM_LA_FREE(col);
    NM_LA_FREE(pen);
    NM_LA_FREE(from2);
    NM_LA_FREE(score);
    NM_LA_FREE(next);
    NM_LA_FREE(back);
    return rc;
}

/* ---------------------------------------------------------------------------
 * Step 6: the agreement check for one placed line. line[n] is the vocals
 * placement of its n phones, check the check signal's placement of the same
 * phones or NULL when the check had none. Tests in the spec's order.
 * ------------------------------------------------------------------------- */
static inline enum NMLaReason nm_la_verdict(const NMLaPlace *line, int n, const NMLaPlace *check)
{
    int limit, apart;
    double sum = 0.0;

    if (!check)
        return NM_LA_CHECK_FAILED;
    if (n <= 0)
        return NM_LA_OK;
    apart = check[0].first - line[0].first;
    if (apart > NM_LA_DISAGREE_FRAMES || apart < -NM_LA_DISAGREE_FRAMES)
        return NM_LA_DISAGREE;
    if (n > 1 && line[1].first - line[0].first > NM_LA_FIRST_GAP_FRAMES)
        return NM_LA_FIRST_GAP;
    limit = n - 1 < NM_LA_STRAY_PREFIX_PHONES ? n - 1 : NM_LA_STRAY_PREFIX_PHONES;
    for (int k = 1; k <= limit; k++) {
        sum += line[k - 1].post;
        if (line[k].first - line[k - 1].first > NM_LA_STRAY_PREFIX_GAP_FRAMES &&
            sum / k < NM_LA_STRAY_PREFIX_POSTERIOR)
            return NM_LA_STRAY_PREFIX;
    }
    return NM_LA_OK;
}

/* ---------------------------------------------------------------------------
 * Step 7: the vocals' RMS in dB, 20·log10(rms + 1e-9), over non-overlapping
 * windows of `hop` samples. *n_env = n / hop windows; the trailing partial
 * window is dropped. Never NULL unless memory ran out (an empty result is a
 * 0-window allocation).
 * ------------------------------------------------------------------------- */
static inline float *nm_la_rms_db(const float *samples, int n, int hop, int *n_env)
{
    const int hops = n > 0 ? n / hop : 0;
    float *env = (float *) NM_LA_MALLOC(sizeof(*env) * (size_t) (hops > 0 ? hops : 1));

    *n_env = 0;
    if (!env)
        return NULL;
    for (int k = 0; k < hops; k++) {
        const float *x = samples + (size_t) k * hop;
        double acc = 0.0;

        for (int i = 0; i < hop; i++)
            acc += (double) x[i] * x[i];
        env[k] = (float) (20.0 * log10(sqrt(acc / hop) + 1e-9));
    }
    *n_env = hops;
    return env;
}

/* The envelope the walk-backs read: one value per 10 ms hop. */
static inline float *nm_la_envelope_db(const float *samples, int n, int *n_env)
{
    return nm_la_rms_db(samples, n, NM_LA_ENV_HOP, n_env);
}

/* From the spike at emission frame spike_frame (20 ms), walk back through the
 * envelope while it stays within 10 dB of its level at the spike (the loudest
 * of the five hops from there) and above -45 dBFS, at most max_hops, never
 * before the previous line's end (an emission frame, -1 for none) plus
 * 0.05 s. Returns the 10 ms hop index of the written start. */
static inline int nm_la_walk_back_max(const float *env, int n_env, int spike_frame, int prev_end_frame, int max_hops)
{
    int k0 = spike_frame * (NM_LA_HOP / NM_LA_ENV_HOP);
    int low, k, top;
    float level;

    if (n_env <= 0)
        return k0;
    if (k0 > n_env - 1)
        k0 = n_env - 1;
    top = k0 + 5 < n_env ? k0 + 5 : n_env;
    level = env[k0];
    for (int i = k0 + 1; i < top; i++)
        if (env[i] > level)
            level = env[i];
    low = k0 - max_hops;
    if (low < 0)
        low = 0;
    if (prev_end_frame >= 0) {
        int floor_hop = prev_end_frame * (NM_LA_HOP / NM_LA_ENV_HOP) + NM_LA_WALK_MARGIN_HOPS;
        if (floor_hop > low)
            low = floor_hop;
    }
    k = k0;
    while (k > low && env[k - 1] >= level - NM_LA_WALK_WITHIN_DB && env[k - 1] > NM_LA_WALK_FLOOR_DB)
        k--;
    return k;
}

/* Step 7's own walk: at most 0.8 s. */
static inline int nm_la_walk_back(const float *env, int n_env, int spike_frame, int prev_end_frame)
{
    return nm_la_walk_back_max(env, n_env, spike_frame, prev_end_frame, NM_LA_WALK_MAX_HOPS);
}

/* Does a pause of at least 1.0 s precede a line that starts at start_frame,
 * given the previous placed line ended at prev_end_frame (-1: no previous)? */
static inline int nm_la_pause_before(int start_frame, int prev_end_frame)
{
    return prev_end_frame < 0 || start_frame - prev_end_frame >= NM_LA_LEAD_IN_GAP_FRAMES;
}

/* ---------------------------------------------------------------------------
 * Step 7c: the island. frames[n_frames] is the vocals' RMS per 20 ms frame
 * (nm_la_rms_db with NM_LA_HOP), start_hop the line's written start so far
 * (a 10 ms hop), prev_end_frame the previous placed line's end.
 *
 * The window runs from the previous line's end, or 2.0 s before the start
 * when that is later, to 0.1 s before the start. Walking forward through the
 * frames that lie inside it, quiet frames (under -45 dB) are counted and a
 * frame of sound (-35 dB or over) sets the count back to 0; a frame between
 * the two does neither. The first run of sound that begins after 0.3 s of
 * quiet and lasts 0.3 s is the island; the run may go on past the window.
 * A breath is shorter than that, a held note of the previous line has no
 * quiet before it.
 *
 * Returns the island's onset as a 10 ms hop, -1 when there is none.
 * ------------------------------------------------------------------------- */
static inline int nm_la_island_onset(const float *frames, int n_frames, int start_hop, int prev_end_frame)
{
    const int per_frame = NM_LA_HOP / NM_LA_ENV_HOP;        /* hops in one frame */
    int open_hop, close_hop, f, f_end, quiet = 0;

    if (prev_end_frame < 0 || n_frames <= 0)
        return -1;
    open_hop = start_hop - NM_LA_ISLAND_LOOK_HOPS;
    if (prev_end_frame * per_frame > open_hop)
        open_hop = prev_end_frame * per_frame;
    close_hop = start_hop - NM_LA_ISLAND_NEAR_HOPS;
    if (close_hop <= open_hop)
        return -1;
    f = (open_hop + per_frame - 1) / per_frame;             /* the first frame that begins inside the window */
    f_end = close_hop / per_frame;                          /* frames [f, f_end) lie inside it */
    if (f_end > n_frames)
        f_end = n_frames;
    while (f < f_end) {
        if (frames[f] < NM_LA_ISLAND_QUIET_DB) {
            quiet++;
            f++;
        } else if (frames[f] >= NM_LA_ISLAND_LOUD_DB) {
            int stop = f;

            while (stop < n_frames && frames[stop] >= NM_LA_ISLAND_LOUD_DB)
                stop++;
            if (quiet >= NM_LA_ISLAND_QUIET_FRAMES && stop - f >= NM_LA_ISLAND_MIN_FRAMES)
                return f * per_frame;
            quiet = 0;
            f = stop;
        } else {
            f++;
        }
    }
    return -1;
}

/* What the onset steps know about one accepted line. */
typedef struct NMLaLineOnset {
    int spike_frame;            /* the first phone's first emission frame */
    int prev_end_frame;         /* the previous placed line's end, -1 for the first placed line */
    int soft_onset;             /* the first phone is a vowel or a sonorant (nm_lp_soft_onset) */
    int words;                  /* the line's words that have phones ... */
    double first_word_score;    /* ... and the score of the first of them, as words[] reports it */
} NMLaLineOnset;

/* ---------------------------------------------------------------------------
 * The written start of an accepted line, as a 10 ms hop. lead_in is the
 * spike minus this.
 *
 *   7   after a pause of 1.0 s, or on the first placed line: the walk-back,
 *       at most 0.8 s. Otherwise the start is the spike.
 *   7b  when the start is still the spike and the first phone is soft: the
 *       same walk-back, at most soft_max_hops. The model fires on the steady
 *       part of a vowel or sonorant, a few hops after the voice came in; a
 *       plosive or fricative has no such rise. soft_max_hops 0 turns it off.
 *   7c  when the line has two words or more and the first scored below 0.01:
 *       the island in front of the start (nm_la_island_onset), if its onset
 *       is more than 0.2 s before the start. No word claims that sound, so
 *       it is the word the model did not hear. island 0 turns it off.
 *
 * env is the 10 ms envelope, frames the 20 ms RMS (NULL also turns 7c off).
 * With both refinements off this is step 7 as v1.0.46 ran it.
 * ------------------------------------------------------------------------- */
static inline int nm_la_written_start(const float *env, int n_env, const float *frames, int n_frames,
                                      const NMLaLineOnset *line, int soft_max_hops, int island)
{
    const int spike_hop = line->spike_frame * (NM_LA_HOP / NM_LA_ENV_HOP);
    int start = spike_hop;

    if (nm_la_pause_before(line->spike_frame, line->prev_end_frame))
        start = nm_la_walk_back(env, n_env, line->spike_frame, line->prev_end_frame);

    /* spike_hop < n_env: a spike past the envelope's end has nothing to walk through */
    if (start == spike_hop && line->soft_onset && soft_max_hops > 0 && spike_hop < n_env)
        start = nm_la_walk_back_max(env, n_env, line->spike_frame, line->prev_end_frame, soft_max_hops);

    if (island && frames && line->words >= 2 && line->first_word_score < NM_LA_ISLAND_SCORE) {
        int onset = nm_la_island_onset(frames, n_frames, start, line->prev_end_frame);

        if (onset >= 0 && start - onset > NM_LA_ISLAND_MOVE_HOPS)
            start = onset;
    }
    return start;
}

#endif /* NM_LYRICSALIGN_ALIGN_H */

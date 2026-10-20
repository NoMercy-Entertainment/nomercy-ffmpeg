/*
 * nm_whisper_words.h - JSON escaping and per-word timing for af_whisper.c.
 *
 * Header-only and free of FFmpeg and whisper.cpp on purpose: the same code
 * the filter runs is compiled by tests/unit/test_nm_whisper_words.c with a
 * plain C compiler, so escaping, UTF-8 repair and word building are tested
 * without building ffmpeg. scripts/48-whisper.sh copies this file next to
 * af_whisper.c.
 *
 * Memory comes from NM_WW_MALLOC / NM_WW_REALLOC / NM_WW_FREE, which default
 * to the C library. af_whisper.c points them at av_malloc and friends before
 * including this file, because FFmpeg's libavutil/internal.h poisons malloc.
 */
#ifndef NM_WHISPER_WORDS_H
#define NM_WHISPER_WORDS_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef NM_WW_MALLOC
#include <stdlib.h>
#define NM_WW_MALLOC(n)     malloc(n)
#define NM_WW_REALLOC(p, n) realloc(p, n)
#define NM_WW_FREE(p)       free(p)
#endif

/* ---------------------------------------------------------------------------
 * JSON escaping
 * ------------------------------------------------------------------------- */

/*
 * Length of the UTF-8 sequence at p, and whether it is well formed (Unicode
 * Table 3-7: no overlongs, no surrogates, nothing above U+10FFFF). For an
 * ill-formed sequence the length is its "maximal subpart" - the longest
 * prefix that could still have become a valid character - so that each one
 * is replaced by a single U+FFFD, as the Unicode standard recommends. A NUL
 * terminator is never in a continuation range, so this never reads past it.
 */
static inline int nm_utf8_seq(const unsigned char *p, int *valid)
{
    const unsigned c = p[0];
    unsigned lo = 0x80, hi = 0xBF;
    int need;

    if (c < 0x80) {
        *valid = 1;
        return 1;
    }
    if (c >= 0xC2 && c <= 0xDF)
        need = 1;
    else if (c == 0xE0) {
        need = 2;
        lo = 0xA0;
    } else if ((c >= 0xE1 && c <= 0xEC) || c == 0xEE || c == 0xEF)
        need = 2;
    else if (c == 0xED) {
        need = 2;
        hi = 0x9F;
    } else if (c == 0xF0) {
        need = 3;
        lo = 0x90;
    } else if (c >= 0xF1 && c <= 0xF3)
        need = 3;
    else if (c == 0xF4) {
        need = 3;
        hi = 0x8F;
    } else {
        *valid = 0;
        return 1;
    }

    for (int i = 1; i <= need; i++) {
        if (p[i] < lo || p[i] > hi) {
            *valid = 0;
            return i;
        }
        lo = 0x80;
        hi = 0xBF;
    }
    *valid = 1;
    return need + 1;
}

/*
 * Escape a string as the contents of a JSON string literal (RFC 8259, 7).
 *
 * The json destination used to insert text with a plain %s. Whisper output
 * containing a double quote, a backslash or a control character therefore
 * produced a line no JSON parser accepts -- and a transcript quoting someone
 * is exactly where a double quote turns up. The language field had the same
 * hole and a worse source: it can be the user's own language= option, not
 * only one of whisper.cpp's fixed codes.
 *
 * Valid UTF-8 is copied as it is. Invalid UTF-8 is replaced with U+FFFD:
 * whisper's byte-level BPE can end a segment or a word halfway through a
 * character, and strict JSON parsers reject the whole line for one stray
 * byte. Valid input produces exactly the bytes it always did. Returns a newly
 * allocated string, or NULL when allocation fails; free it with NM_WW_FREE.
 */
static inline char *nm_json_escape(const char *s)
{
    static const char hex[] = "0123456789abcdef";
    const unsigned char *p;
    size_t n = 0;
    char *out, *o;
    int len, valid;

    for (p = (const unsigned char *) s; *p; p += len) {
        len = 1;
        switch (*p) {
        case '"': case '\\': case '\b': case '\f':
        case '\n': case '\r': case '\t':
            n += 2;
            break;
        default:
            if (*p < 0x20)
                n += 6;
            else {
                len = nm_utf8_seq(p, &valid);
                n += valid ? (size_t) len : 3;
            }
        }
    }

    out = NM_WW_MALLOC(n + 1);
    if (!out)
        return NULL;

    for (p = (const unsigned char *) s, o = out; *p; p += len) {
        len = 1;
        switch (*p) {
        case '"':  *o++ = '\\'; *o++ = '"';  break;
        case '\\': *o++ = '\\'; *o++ = '\\'; break;
        case '\b': *o++ = '\\'; *o++ = 'b';  break;
        case '\f': *o++ = '\\'; *o++ = 'f';  break;
        case '\n': *o++ = '\\'; *o++ = 'n';  break;
        case '\r': *o++ = '\\'; *o++ = 'r';  break;
        case '\t': *o++ = '\\'; *o++ = 't';  break;
        default:
            if (*p < 0x20) {
                *o++ = '\\';
                *o++ = 'u';
                *o++ = '0';
                *o++ = '0';
                *o++ = hex[*p >> 4];
                *o++ = hex[*p & 0xf];
            } else {
                len = nm_utf8_seq(p, &valid);
                if (valid) {
                    memcpy(o, p, len);
                    o += len;
                } else {
                    *o++ = (char) 0xEF;
                    *o++ = (char) 0xBF;
                    *o++ = (char) 0xBD;
                }
            }
        }
    }
    *o = '\0';
    return out;
}

/* ---------------------------------------------------------------------------
 * Words from tokens
 * ------------------------------------------------------------------------- */

/* One whisper token, copied out of whisper_full_get_token_data(). */
typedef struct NMWhisperToken {
    const char *text;
    int special;    /* id >= whisper_token_eot(): timestamps, [_BEG_], ... */
    int64_t t0;     /* centiseconds from the start of the whisper_full() window, -1 if unknown */
    int64_t t_dtw;  /* the same for DTW, -1 when DTW did not place the token */
    float p;
} NMWhisperToken;

typedef struct NMWhisperWord {
    char *text;     /* raw UTF-8, leading spaces removed; not yet JSON-escaped */
    int64_t start;  /* absolute milliseconds */
    int64_t end;
    float p;        /* mean probability of the word's tokens */
} NMWhisperWord;

static inline void nm_whisper_free_words(NMWhisperWord *w, int n)
{
    for (int i = 0; i < n; i++)
        NM_WW_FREE(w[i].text);
    NM_WW_FREE(w);
}

static inline int nm_ww_is_blank_audio(const char *s)
{
    static const char tag[] = "[BLANK_AUDIO]";
    for (size_t i = 0; i < sizeof(tag); i++) {
        char c = s[i];
        if (c >= 'a' && c <= 'z')
            c -= 'a' - 'A';
        if (c != tag[i])
            return 0;
    }
    return 1;
}

/*
 * Group a segment's tokens into words.
 *
 * - Special tokens are skipped.
 * - A token whose text starts with a space starts a new word, and so does the
 *   first text token. Every other token is appended to the current word,
 *   which also re-joins a UTF-8 character that BPE split across two tokens.
 * - A word's raw start is its first token's t_dtw when use_dtw is set and
 *   t_dtw >= 0, otherwise its t0 (offset_ms + centiseconds * 10).
 * - Words that are empty, or are the "[BLANK_AUDIO]" marker the filter also
 *   strips from the segment text, are dropped.
 * - Starts are clamped into [seg_start, seg_end] and never earlier than the
 *   previous word's start; DTW can place a token slightly outside its
 *   segment. A word with no timing at all takes the previous start.
 * - A word ends where the next one starts; the last ends at seg_end.
 *
 * On success *out holds *n_out words (free with nm_whisper_free_words) and 0
 * is returned. On allocation failure -1 is returned and nothing is leaked.
 */
static inline int nm_whisper_build_words(const NMWhisperToken *tok, int n_tok,
                                         int64_t offset_ms, int64_t seg_start, int64_t seg_end,
                                         int use_dtw, NMWhisperWord **out, int *n_out)
{
    NMWhisperWord *w = NULL;
    int *ntok = NULL;    /* tokens per word, for the mean probability */
    int n = 0, cap = 0, kept = 0;

    *out = NULL;
    *n_out = 0;
    if (seg_end < seg_start)
        seg_end = seg_start;

    for (int i = 0; i < n_tok; i++) {
        const char *text = tok[i].text ? tok[i].text : "";
        const int starts_word = n == 0 || text[0] == ' ';
        size_t old_len, add_len;
        char *grown;

        if (tok[i].special)
            continue;

        if (starts_word) {
            int64_t cs = -1;
            if (n == cap) {
                const int ncap = cap ? cap * 2 : 16;
                NMWhisperWord *nw = NM_WW_REALLOC(w, ncap * sizeof(*w));
                int *nt;
                if (!nw)
                    goto fail;
                w = nw;
                nt = NM_WW_REALLOC(ntok, ncap * sizeof(*ntok));
                if (!nt)
                    goto fail;
                ntok = nt;
                cap = ncap;
            }
            w[n].text = NM_WW_MALLOC(1);
            if (!w[n].text)
                goto fail;
            w[n].text[0] = '\0';
            if (use_dtw && tok[i].t_dtw >= 0)
                cs = tok[i].t_dtw;
            else if (tok[i].t0 >= 0)
                cs = tok[i].t0;
            /* INT64_MIN marks "no timing"; resolved below. */
            w[n].start = cs >= 0 ? offset_ms + cs * 10 : INT64_MIN;
            w[n].end = 0;
            w[n].p = 0.0f;
            ntok[n] = 0;
            n++;
            while (*text == ' ')
                text++;
        }

        old_len = strlen(w[n - 1].text);
        add_len = strlen(text);
        grown = NM_WW_REALLOC(w[n - 1].text, old_len + add_len + 1);
        if (!grown)
            goto fail;
        memcpy(grown + old_len, text, add_len + 1);
        w[n - 1].text = grown;
        w[n - 1].p += tok[i].p;
        ntok[n - 1]++;
    }

    for (int i = 0; i < n; i++) {
        if (!w[i].text[0] || nm_ww_is_blank_audio(w[i].text)) {
            NM_WW_FREE(w[i].text);
            continue;
        }
        w[i].p /= ntok[i];
        w[kept++] = w[i];
    }
    n = kept;

    for (int i = 0; i < n; i++) {
        const int64_t floor = i ? w[i - 1].start : seg_start;
        int64_t s = w[i].start == INT64_MIN ? floor : w[i].start;
        if (s < seg_start)
            s = seg_start;
        if (s > seg_end)
            s = seg_end;
        if (s < floor)
            s = floor;
        w[i].start = s;
    }
    for (int i = 0; i < n; i++)
        w[i].end = i + 1 < n ? w[i + 1].start : seg_end;

    NM_WW_FREE(ntok);
    if (!n) {
        NM_WW_FREE(w);
        w = NULL;
    }
    *out = w;
    *n_out = n;
    return 0;

fail:
    for (int i = 0; i < n; i++)
        NM_WW_FREE(w[i].text);
    NM_WW_FREE(w);
    NM_WW_FREE(ntok);
    return -1;
}

/*
 * The "words" array of a JSON segment line:
 *   [{"text":"hello","start":12340,"end":12710,"p":0.931},...]
 * Returns a newly allocated string, or NULL when allocation fails.
 */
static inline char *nm_whisper_words_json(const NMWhisperWord *w, int n)
{
    size_t cap = 64, len = 0;
    char *out = NM_WW_MALLOC(cap);

    if (!out)
        return NULL;
    out[len++] = '[';

    for (int i = 0; i < n; i++) {
        char *text = nm_json_escape(w[i].text);
        float p = w[i].p;
        size_t need;
        int k;

        if (!text) {
            NM_WW_FREE(out);
            return NULL;
        }
        if (!(p >= 0.0f))   /* also catches NaN */
            p = 0.0f;
        if (p > 1.0f)
            p = 1.0f;

        /* 120 covers the punctuation, two int64 and the probability. */
        need = len + strlen(text) + 120;
        if (need > cap) {
            char *grown = NM_WW_REALLOC(out, need * 2);
            if (!grown) {
                NM_WW_FREE(text);
                NM_WW_FREE(out);
                return NULL;
            }
            out = grown;
            cap = need * 2;
        }
        k = snprintf(out + len, cap - len,
                     "%s{\"text\":\"%s\",\"start\":%lld,\"end\":%lld,\"p\":%.3f}",
                     i ? "," : "", text, (long long) w[i].start, (long long) w[i].end, p);
        NM_WW_FREE(text);
        if (k < 0 || (size_t) k >= cap - len) {
            NM_WW_FREE(out);
            return NULL;
        }
        len += k;
    }

    out[len++] = ']';
    out[len] = '\0';
    return out;
}

/* ---------------------------------------------------------------------------
 * DTW alignment-head presets
 * ------------------------------------------------------------------------- */

/*
 * The names whisper-cli accepts for --dtw, in the order of whisper.cpp's
 * enum whisper_alignment_heads_preset from WHISPER_AHEADS_TINY_EN on - but
 * listed here by name, so af_whisper.c maps each index to its enum value
 * explicitly. With each, the decoder shape of the models the preset was made
 * for: whisper.cpp itself only rejects a preset that names a layer or head
 * the model does not have, so base on a base.en model, or tiny.en on base.en,
 * would load and produce wrong timings without a word. The filter checks the
 * model against this table instead.
 */
typedef struct NMWhisperDtwPreset {
    const char *name;
    int n_text_layer;
    int n_text_head;
    int multilingual;
    int n_mels;         /* 0: either 80 or 128 */
} NMWhisperDtwPreset;

static inline const NMWhisperDtwPreset *nm_whisper_dtw_presets(int *count)
{
    static const NMWhisperDtwPreset presets[] = {
        { "tiny.en",         4,  6, 0,  80 },
        { "tiny",            4,  6, 1,  80 },
        { "base.en",         6,  8, 0,  80 },
        { "base",            6,  8, 1,  80 },
        { "small.en",       12, 12, 0,  80 },
        { "small",          12, 12, 1,  80 },
        { "medium.en",      24, 16, 0,  80 },
        { "medium",         24, 16, 1,  80 },
        { "large.v1",       32, 20, 1,  80 },
        { "large.v2",       32, 20, 1,  80 },
        { "large.v3",       32, 20, 1, 128 },
        { "large.v3.turbo",  4, 20, 1, 128 },
    };
    *count = (int) (sizeof(presets) / sizeof(presets[0]));
    return presets;
}

static inline int nm_whisper_dtw_preset_count(void)
{
    int n;
    nm_whisper_dtw_presets(&n);
    return n;
}

/* Index of the preset with exactly this name, or -1. */
static inline int nm_whisper_dtw_preset_find(const char *name)
{
    int n;
    const NMWhisperDtwPreset *p = nm_whisper_dtw_presets(&n);
    for (int i = 0; name && i < n; i++)
        if (!strcmp(p[i].name, name))
            return i;
    return -1;
}

static inline const char *nm_whisper_dtw_preset_name(int idx)
{
    int n;
    const NMWhisperDtwPreset *p = nm_whisper_dtw_presets(&n);
    return idx >= 0 && idx < n ? p[idx].name : "";
}

/* "tiny, tiny.en, ..." for error messages. */
static inline const char *nm_whisper_dtw_preset_list(void)
{
    return "tiny, tiny.en, base, base.en, small, small.en, medium, medium.en, "
           "large.v1, large.v2, large.v3, large.v3.turbo";
}

/* Whether a model with this decoder shape is one the preset was made for. */
static inline int nm_whisper_dtw_preset_matches(int idx, int n_text_layer, int n_text_head,
                                                int multilingual, int n_mels)
{
    int n;
    const NMWhisperDtwPreset *p = nm_whisper_dtw_presets(&n);
    if (idx < 0 || idx >= n)
        return 0;
    p += idx;
    return p->n_text_layer == n_text_layer && p->n_text_head == n_text_head &&
           p->multilingual == !!multilingual && (!p->n_mels || p->n_mels == n_mels);
}

#endif /* NM_WHISPER_WORDS_H */

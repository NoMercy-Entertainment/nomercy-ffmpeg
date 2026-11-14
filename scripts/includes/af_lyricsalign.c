/*
 * lyricsalign audio filter: time-synced lyrics by CTC forced alignment.
 *
 * Copyright (c) 2026 NoMercy Entertainment
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/*
 * The filter takes known lyric text and places it on a vocal stem: espeak-ng
 * turns every line into IPA phones, a wav2vec2 phoneme model on ggml gives
 * per-frame phone probabilities, and a Viterbi over the blank-interleaved
 * token chain (with a "star" that absorbs non-lyric vocals between lines)
 * places every phone. A second alignment on vocals + blend * backing must
 * agree before a line is written; a line that fails any test is skipped
 * with its reason, never guessed. The method and every constant are the
 * prototype's, measured on a verified reference set (nomercy-ffmpeg #126).
 * Where a written line starts has two refinements measured on the same set
 * (#130, nm_lyricsalign_align.h), and the words of a line keep their text
 * when espeak-ng writes two lyric tokens as one word (#131,
 * nm_lyricsalign_phones.h).
 *
 * Two inputs (vocals, backing), one output: input 0, unchanged, streamed as
 * it arrives. The alignment runs once, when both inputs have ended, before
 * EOF is forwarded. The result is JSON Lines on `destination`.
 */

/* glibc declares sched_getaffinity (nm_ggml_threads.h) only under
 * _GNU_SOURCE, which must precede the first system header. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#elif defined(__FreeBSD__)
#include <sys/types.h>
#include <sys/sysctl.h>
#elif defined(__linux__)
#include <unistd.h>
#endif
#include <sys/stat.h>
#if defined(_WIN32)
#include "libavutil/wchar_filename.h"
#endif

#include <ggml.h>
#include <ggml-backend.h>
#include <ggml-cpu.h>
/* speak_lib.h declares its API __declspec(dllimport) on Windows unless the
 * library itself is being built. We link the static archive, so the
 * symbols are plain functions: tell the header so, or the link asks for
 * __imp_espeak_* thunks no archive provides. The exe gains a small export
 * table listing the espeak_* entries, which is harmless. */
#if defined(_WIN32) && !defined(LIBESPEAK_NG_EXPORT)
#define LIBESPEAK_NG_EXPORT 1
#endif
#include <espeak-ng/speak_lib.h>

#include "libavutil/avutil.h"
#include "libavutil/avstring.h"
#include "libavutil/bprint.h"
#include "libavutil/channel_layout.h"
#include "libavutil/cpu.h"
#include "libavutil/getenv_utf8.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/samplefmt.h"
#include "libavutil/thread.h"
#include "libavformat/avio.h"
#include "libswresample/swresample.h"
#include "libavfilter/avfilter.h"
#include "libavfilter/audio.h"
#include "libavfilter/filters.h"
#include "libavfilter/formats.h"

#include "nm_ggml_cpu.h"
#include "nm_ggml_threads.h"

/* The header-only pieces, with FFmpeg's allocator. libavutil/internal.h
 * (included by filters.h above) poisons the C library's names, so the
 * headers must not reach for stdlib.h themselves: the macros stop them. */
#define NM_WW_MALLOC(n)     av_malloc(n)
#define NM_WW_REALLOC(p, n) av_realloc(p, n)
#define NM_WW_FREE(p)       av_free(p)
#include "nm_whisper_words.h"
#define NM_LA_MALLOC(n)     av_malloc(n)
#define NM_LA_FREE(p)       av_free(p)
#include "nm_lyricsalign_align.h"
#define NM_LP_MALLOC(n)     av_malloc(n)
#define NM_LP_REALLOC(p, n) av_realloc(p, n)
#define NM_LP_FREE(p)       av_free(p)
#include "nm_lyricsalign_phones.h"
#define NM_W2V2_MALLOC(n)   av_malloc(n)
#define NM_W2V2_FREE(p)     av_free(p)
#include "nm_lyricsalign_w2v2.h"

#define LA_VERSION "1.1.0"

typedef struct LaLine {
    char *text;                 /* the text line, without its line ending */
    NMLpWord *words;            /* espeak's words of phones; NULL for an empty line */
    int n_words;
    NMLpSpan *spans;            /* the entries of words[]: the phones each one spans (nm_lp_tie) ... */
    char **labels;              /* ... and its text, NULL for an entry without one */
    int n_spans;
    int *ids;                   /* every mapped id of the line, in order */
    int n_ids;
    int *id_at;                 /* per phone of the line, and one past the last: the ids before it */
    int soft_onset;             /* the first phone that kept an id is a vowel or a sonorant */
} LaLine;

typedef struct LyricsAlignContext {
    const AVClass *class;

    /* options */
    char *model_path;
    char *text_file;
    char *language;
    char *espeak_data;
    float blend;
    char *destination;
    int threads;
    int use_gpu;
    int gpu_device;
    float soft_walkback;
    int unheard_island;

    /* text */
    LaLine *lines;
    int n_lines;
    int mapping_misses;
    int phonemized;

    /* audio: 16 kHz mono float copies of both inputs */
    SwrContext *swr[2];
    float *pcm[2];
    int n[2], cap[2];
    int eof[2];
    int status;
    int64_t eof_pts;
    int done;

    /* model */
    NMW2V2 *model;
    ggml_backend_t device, cpu;
    int gpu_active;
    int threads_used;

    AVIOContext *out;
} LyricsAlignContext;

/* ---------------------------------------------------------------------------
 * espeak-ng: one global instance per process, used under a lock.
 * ------------------------------------------------------------------------- */

static AVMutex la_espeak_lock = AV_MUTEX_INITIALIZER;
static int la_espeak_users;

/* The directory holding this ffmpeg binary, for the espeak_data default. */
static int la_exe_dir(char *buf, size_t size)
{
#if defined(_WIN32)
    wchar_t wpath[MAX_PATH];
    char *utf8;
    DWORD n = GetModuleFileNameW(NULL, wpath, MAX_PATH);
    if (!n || n >= MAX_PATH)
        return -1;
    if (WideCharToMultiByte(CP_UTF8, 0, wpath, -1, NULL, 0, NULL, NULL) > (int) size)
        return -1;
    utf8 = buf;
    if (!WideCharToMultiByte(CP_UTF8, 0, wpath, -1, utf8, (int) size, NULL, NULL))
        return -1;
#elif defined(__APPLE__)
    uint32_t n = (uint32_t) size;
    if (_NSGetExecutablePath(buf, &n))
        return -1;
#elif defined(__FreeBSD__)
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
    size_t n = size;
    if (sysctl(mib, 4, buf, &n, NULL, 0))
        return -1;
#elif defined(__linux__)
    ssize_t n = readlink("/proc/self/exe", buf, size - 1);
    if (n < 0)
        return -1;
    buf[n] = 0;
#else
    return -1;
#endif
    {
        char *slash = strrchr(buf, '/');
#if defined(_WIN32)
        char *bslash = strrchr(buf, '\\');
        if (!slash || (bslash && bslash > slash))
            slash = bslash;
#endif
        if (!slash)
            return -1;
        *slash = 0;
    }
    return 0;
}

/* Does the path exist? Through UTF-16 on Windows: the C library's narrow
 * stat() takes the ANSI code page, and these paths are UTF-8. */
static int la_path_exists(const char *path)
{
#if defined(_WIN32)
    wchar_t *w = NULL;
    struct _stati64 st;
    int ok;
    if (utf8towchar(path, &w) < 0 || !w)
        return 0;
    ok = _wstati64(w, &st) == 0;
    av_free(w);
    return ok;
#else
    struct stat st;
    return stat(path, &st) == 0;
#endif
}

static int la_is_dir_with(const char *dir, const char *file)
{
    char path[2048];
    snprintf(path, sizeof(path), "%s/%s", dir, file);
    return la_path_exists(path);
}

/* The data directory as espeak-ng gets it. espeak-ng opens its files with the
 * C library's narrow fopen, which takes the ANSI code page on Windows: a
 * directory name outside that code page is handed over as its 8.3 short
 * name, which is ASCII whenever the volume keeps short names. */
static char *la_espeak_data_arg(AVFilterContext *ctx, const char *dir)
{
#if defined(_WIN32)
    const unsigned char *p;
    for (p = (const unsigned char *) dir; *p && *p < 0x80; p++)
        ;
    if (*p) {
        wchar_t *w = NULL, shortw[MAX_PATH];
        char *s8 = NULL;
        DWORD n;
        if (utf8towchar(dir, &w) >= 0 && w && (n = GetShortPathNameW(w, shortw, MAX_PATH)) > 0 && n < MAX_PATH &&
            wchartoutf8(shortw, &s8) >= 0 && s8) {
            for (p = (const unsigned char *) s8; *p && *p < 0x80; p++)
                ;
            if (!*p) {
                av_free(w);
                av_log(ctx, AV_LOG_VERBOSE, "lyricsalign: espeak-ng data handed over as %s\n", s8);
                return s8;
            }
            av_free(s8);
        }
        av_free(w);
        av_log(ctx, AV_LOG_WARNING, "lyricsalign: the espeak-ng data directory name is outside the ANSI code page and has "
               "no short name, so espeak-ng may not open it (set espeak_data to an ASCII path)\n");
    }
#endif
    return av_strdup(dir);
}

/* Phonemize text with the already-initialised espeak (lock held): clause by
 * clause, joined by a space, then parsed into words of phones. */
static int la_ipa_words(const char *text, NMLpWord **words, int *n_words)
{
    AVBPrint ipa;
    const void *p = text;
    int ret;

    av_bprint_init(&ipa, 0, AV_BPRINT_SIZE_UNLIMITED);
    while (p) {
        const char *clause = espeak_TextToPhonemes(&p, espeakCHARS_UTF8, espeakPHONEMES_IPA | ('_' << 8));
        if (!clause)
            break;
        av_bprintf(&ipa, "%s ", clause);
    }
    if (!av_bprint_is_complete(&ipa)) {
        av_bprint_finalize(&ipa, NULL);
        return AVERROR(ENOMEM);
    }
    ret = nm_lp_parse_ipa(ipa.str, words, n_words);
    av_bprint_finalize(&ipa, NULL);
    return ret ? AVERROR(ENOMEM) : 0;
}

/* The text of one words[] entry: the tokens its label runs over, a space
 * between them, without the ones espeak does not speak. */
static char *la_span_label(const NMLpSpan *span, const NMLpToken *toks, char *const *tok_text)
{
    AVBPrint b;
    char *label = NULL;
    int any = 0;

    av_bprint_init(&b, 0, AV_BPRINT_SIZE_UNLIMITED);
    for (int t = span->tok; t < span->tok + span->n_tok; t++) {
        if (!toks[t].n)
            continue;
        av_bprintf(&b, "%s%s", any ? " " : "", tok_text[t]);
        any = 1;
    }
    if (av_bprint_is_complete(&b))
        av_bprint_finalize(&b, &label);
    else
        av_bprint_finalize(&b, NULL);
    return label;
}

/* The whole line for the alignment; then every whitespace token on its own,
 * to learn which of the line's phones are that token's ("-" has none,
 * "1999" has three words of them), so the JSON can give each lyric token
 * its own span. nm_lp_tie() does the tying, and says what happens when
 * espeak wrote two tokens as one word. */
static int la_phonemize_line(LaLine *line)
{
    const char *p = line->text;
    NMLpToken *toks = NULL;
    char **tok_text = NULL;
    int ret, n_tok = 0, cap = 0;

    ret = la_ipa_words(line->text, &line->words, &line->n_words);
    if (ret < 0)
        return ret;
    while (*p) {
        const char *tok;

        while (*p && nm_lp_is_space((unsigned char) *p))
            p++;
        if (!*p)
            break;
        tok = p;
        while (*p && !nm_lp_is_space((unsigned char) *p))
            p++;
        if (n_tok == cap) {
            NMLpToken *grown_toks;
            char **grown_text;

            cap = cap ? cap * 2 : 16;
            grown_toks = av_realloc_array(toks, cap, sizeof(*grown_toks));
            if (grown_toks)
                toks = grown_toks;
            grown_text = av_realloc_array(tok_text, cap, sizeof(*grown_text));
            if (grown_text)
                tok_text = grown_text;
            if (!grown_toks || !grown_text) {
                ret = AVERROR(ENOMEM);
                goto done;
            }
        }
        toks[n_tok].words = NULL;
        toks[n_tok].n = 0;
        tok_text[n_tok] = av_strndup(tok, p - tok);
        if (!tok_text[n_tok]) {
            ret = AVERROR(ENOMEM);
            goto done;
        }
        n_tok++;
        ret = la_ipa_words(tok_text[n_tok - 1], &toks[n_tok - 1].words, &toks[n_tok - 1].n);
        if (ret < 0)
            goto done;
    }

    if (nm_lp_tie(line->words, line->n_words, toks, n_tok, &line->spans, &line->n_spans)) {
        ret = AVERROR(ENOMEM);
        goto done;
    }
    line->labels = av_calloc(FFMAX(line->n_spans, 1), sizeof(*line->labels));
    if (!line->labels) {
        ret = AVERROR(ENOMEM);
        goto done;
    }
    for (int i = 0; i < line->n_spans; i++) {
        if (!line->spans[i].n_tok)
            continue;
        line->labels[i] = la_span_label(&line->spans[i], toks, tok_text);
        if (!line->labels[i]) {
            ret = AVERROR(ENOMEM);
            goto done;
        }
    }
    ret = 0;
done:
    for (int t = 0; t < n_tok; t++) {
        nm_lp_free_words(toks[t].words, toks[t].n);
        av_free(tok_text[t]);
    }
    av_free(toks);
    av_free(tok_text);
    return ret;
}

static int la_phonemize(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    int ret = 0;

    ff_mutex_lock(&la_espeak_lock);
    if (!la_espeak_users) {
        char *data = la_espeak_data_arg(ctx, s->espeak_data);
        int ok;
        if (!data) {
            ff_mutex_unlock(&la_espeak_lock);
            return AVERROR(ENOMEM);
        }
        ok = espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, data, 0) >= 0;
        av_free(data);
        if (!ok) {
            av_log(ctx, AV_LOG_ERROR, "lyricsalign: espeak-ng could not initialise with its data at %s\n", s->espeak_data);
            ff_mutex_unlock(&la_espeak_lock);
            return AVERROR(EINVAL);
        }
    }
    la_espeak_users++;
    /* The way the espeak-ng CLI's -v resolves a name (the prototype used the
     * CLI): a voice name or identifier first, then a language code such as
     * en-gb, which no voice is named after but which the selection by
     * properties resolves. */
    if (espeak_SetVoiceByName(s->language) != EE_OK) {
        espeak_VOICE by_language;
        memset(&by_language, 0, sizeof(by_language));
        by_language.languages = s->language;
        if (espeak_SetVoiceByProperties(&by_language) != EE_OK) {
            av_log(ctx, AV_LOG_ERROR, "lyricsalign: espeak-ng has no voice named '%s' (use an espeak-ng voice name or "
                   "language code such as en-us, en-gb, nl, de, fr, ja)\n", s->language);
            ret = AVERROR(EINVAL);
        }
    }
    if (!ret) {
        for (int i = 0; i < s->n_lines && !ret; i++)
            if (s->lines[i].text[0])
                ret = la_phonemize_line(&s->lines[i]);
    }
    ff_mutex_unlock(&la_espeak_lock);
    s->phonemized = 1;
    return ret;
}

/* ---------------------------------------------------------------------------
 * The text file: UTF-8, one lyric line per text line. A BOM and CR are not
 * part of any line, trailing blanks are dropped, blank lines are kept (they
 * are instrumental markers), a trailing newline ends the last line instead
 * of adding an empty one. A file with no non-blank line fails.
 * ------------------------------------------------------------------------- */
static int la_read_text(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    AVIOContext *pb = NULL;
    AVBPrint buf;
    char *p, *end;
    int ret, cap = 0, nonblank = 0;

    ret = avio_open(&pb, s->text_file, AVIO_FLAG_READ);
    if (ret < 0) {
        av_log(ctx, AV_LOG_ERROR, "lyricsalign: cannot read text_file %s: %s\n", s->text_file, av_err2str(ret));
        return ret;
    }
    av_bprint_init(&buf, 0, AV_BPRINT_SIZE_UNLIMITED);
    for (;;) {
        unsigned char chunk[4096];
        int n = avio_read(pb, chunk, sizeof(chunk));
        if (n <= 0)
            break;
        av_bprint_append_data(&buf, (const char *) chunk, n);
    }
    avio_closep(&pb);
    if (!av_bprint_is_complete(&buf)) {
        av_bprint_finalize(&buf, NULL);
        return AVERROR(ENOMEM);
    }
    p = buf.str;
    end = p + buf.len;
    if (buf.len >= 3 && !memcmp(p, "\xEF\xBB\xBF", 3))
        p += 3;
    while (p < end) {
        char *nl = memchr(p, '\n', end - p);
        char *stop = nl ? nl : end;
        char *line;
        size_t len;

        while (stop > p && (stop[-1] == '\r' || stop[-1] == ' ' || stop[-1] == '\t' || stop[-1] == '\f' || stop[-1] == '\v'))
            stop--;
        len = stop - p;
        if (s->n_lines == cap) {
            LaLine *grown;
            cap = cap ? cap * 2 : 64;
            grown = av_realloc_array(s->lines, cap, sizeof(*grown));
            if (!grown) {
                av_bprint_finalize(&buf, NULL);
                return AVERROR(ENOMEM);
            }
            s->lines = grown;
        }
        line = av_malloc(len + 1);
        if (!line) {
            av_bprint_finalize(&buf, NULL);
            return AVERROR(ENOMEM);
        }
        memcpy(line, p, len);
        line[len] = 0;
        memset(&s->lines[s->n_lines], 0, sizeof(s->lines[0]));
        s->lines[s->n_lines++].text = line;
        if (len)
            nonblank++;
        p = nl ? nl + 1 : end;
    }
    av_bprint_finalize(&buf, NULL);
    if (!nonblank) {
        av_log(ctx, AV_LOG_ERROR, "lyricsalign: text_file %s has no lyric line\n", s->text_file);
        return AVERROR(EINVAL);
    }
    return 0;
}

static void la_free_lines(LyricsAlignContext *s)
{
    for (int i = 0; i < s->n_lines; i++) {
        LaLine *l = &s->lines[i];
        av_free(l->text);
        nm_lp_free_words(l->words, l->n_words);
        if (l->labels)
            for (int w = 0; w < l->n_spans; w++)
                av_free(l->labels[w]);
        av_free(l->labels);
        av_free(l->spans);
        av_free(l->ids);
        av_free(l->id_at);
    }
    av_freep(&s->lines);
    s->n_lines = 0;
}

/* Map every phone of every line onto the model's vocabulary (needs the
 * loaded model); a phone that misses is dropped and counted. */
static int la_map_phones(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    const int n_vocab = nm_w2v2_vocab_n(s->model);
    const char **vocab = av_malloc_array(n_vocab, sizeof(*vocab));

    if (!vocab)
        return AVERROR(ENOMEM);
    for (int i = 0; i < n_vocab; i++)
        vocab[i] = nm_w2v2_vocab(s->model, i);
    s->mapping_misses = 0;
    for (int i = 0; i < s->n_lines; i++) {
        LaLine *l = &s->lines[i];
        int phones = 0, p = 0;

        if (!l->n_words)
            continue;
        for (int w = 0; w < l->n_words; w++)
            phones += l->words[w].n;
        av_freep(&l->ids);
        av_freep(&l->id_at);
        l->n_ids = 0;
        l->soft_onset = 0;
        l->ids = av_malloc_array(phones + 1, sizeof(*l->ids));
        l->id_at = av_malloc_array(phones + 1, sizeof(*l->id_at));
        if (!l->ids || !l->id_at)
            goto oom;
        for (int w = 0; w < l->n_words; w++) {
            for (int k = 0; k < l->words[w].n; k++) {
                const char *phone = l->words[w].phones[k];
                int id = nm_lp_map_phone(phone, vocab, n_vocab);

                l->id_at[p++] = l->n_ids;
                if (id < 0) {
                    s->mapping_misses++;
                    continue;
                }
                /* the line's spike is this phone's when it is the first to keep an id */
                if (!l->n_ids)
                    l->soft_onset = nm_lp_soft_onset(phone);
                l->ids[l->n_ids++] = id;
            }
        }
        l->id_at[p] = l->n_ids;
    }
    av_free(vocab);
    return 0;
oom:
    av_free(vocab);
    return AVERROR(ENOMEM);
}

/* ---------------------------------------------------------------------------
 * Output: JSON Lines to the destination, or the log.
 * ------------------------------------------------------------------------- */
static void la_emit(AVFilterContext *ctx, AVBPrint *line)
{
    LyricsAlignContext *s = ctx->priv;

    if (s->out) {
        av_bprint_chars(line, '\n', 1);
        avio_write(s->out, (const unsigned char *) line->str, line->len);
    } else {
        av_log(ctx, AV_LOG_INFO, "%s\n", line->str);
    }
}

static void la_json_str(AVBPrint *b, const char *s)
{
    char *esc = nm_json_escape(s);
    av_bprintf(b, "\"%s\"", esc ? esc : "");
    av_free(esc);
}

static void la_json_time(AVBPrint *b, int frame20, int written_hop10)
{
    /* -1: null; a 20 ms frame, or a 10 ms hop when written_hop10 >= 0 */
    if (written_hop10 >= 0)
        av_bprintf(b, "%.3f", written_hop10 * 0.01);
    else if (frame20 >= 0)
        av_bprintf(b, "%.3f", frame20 * (double) NM_LA_HOP / NM_LA_RATE);
    else
        av_bprintf(b, "null");
}

static void la_write_header(AVFilterContext *ctx, int written, const char *check)
{
    LyricsAlignContext *s = ctx->priv;
    AVBPrint b;

    av_bprint_init(&b, 0, AV_BPRINT_SIZE_UNLIMITED);
    av_bprintf(&b, "{\"model\":");
    la_json_str(&b, nm_w2v2_name(s->model));
    av_bprintf(&b, ",\"language\":");
    la_json_str(&b, s->language);
    av_bprintf(&b, ",\"lines\":%d,\"written\":%d,\"mapping_misses\":%d,\"check\":\"%s\"}",
               s->n_lines, written, s->mapping_misses, check);
    la_emit(ctx, &b);
    av_bprint_finalize(&b, NULL);
}

/* A line that is not written: start/end null, its reason, the two candidate
 * starts (frames, -1 = none), no words. Appended to b with its newline. */
static void la_write_skipped_to(AVFilterContext *ctx, AVBPrint *b, int index, enum NMLaReason reason,
                                int vocals_frame, int check_frame)
{
    LyricsAlignContext *s = ctx->priv;

    av_bprintf(b, "{\"index\":%d,\"text\":", index);
    la_json_str(b, s->lines[index].text);
    av_bprintf(b, ",\"start\":null,\"end\":null,\"score\":0,\"reason\":\"%s\",\"vocals_start\":", nm_la_reason_name(reason));
    la_json_time(b, vocals_frame, -1);
    av_bprintf(b, ",\"check_start\":");
    la_json_time(b, check_frame, -1);
    av_bprintf(b, ",\"words\":[]}\n");
}

static void la_write_skipped(AVFilterContext *ctx, int index, enum NMLaReason reason, int vocals_frame, int check_frame)
{
    AVBPrint b;

    av_bprint_init(&b, 0, AV_BPRINT_SIZE_UNLIMITED);
    la_write_skipped_to(ctx, &b, index, reason, vocals_frame, check_frame);
    if (b.len && b.str[b.len - 1] == '\n')
        b.str[--b.len] = 0;
    la_emit(ctx, &b);
    av_bprint_finalize(&b, NULL);
}

/* ---------------------------------------------------------------------------
 * The alignment (processing steps 2 to 7).
 * ------------------------------------------------------------------------- */

/* The undocumented debug hook of the lab and the CI gate: the vocals'
 * log-probs, raw little-endian f32, T x vocab, before the star column. */
static void la_dump_emissions(AVFilterContext *ctx, const float *logp, int frames, int vocab)
{
    char *path = getenv_utf8("NOMERCY_LYRICSALIGN_EMISSIONS");
    AVIOContext *pb = NULL;

    if (!path)
        return;
    if (*path && avio_open(&pb, path, AVIO_FLAG_WRITE) >= 0) {
        avio_write(pb, (const unsigned char *) logp, (int) (sizeof(*logp) * (size_t) frames * vocab));
        avio_closep(&pb);
        av_log(ctx, AV_LOG_INFO, "lyricsalign: emissions (%d x %d) written to %s\n", frames, vocab, path);
    }
    freeenv_utf8(path);
}

/* Place the token chain on one signal: emissions, star column, Viterbi.
 * Returns 1 placed (out filled), 0 no path, <0 error. */
static int la_place(AVFilterContext *ctx, const float *pcm, int n, const int *tokens, int n_tokens,
                    NMLaPlace *out, int dump)
{
    LyricsAlignContext *s = ctx->priv;
    const int V = nm_w2v2_vocab_n(s->model);
    float *logp = NULL, *star;
    int frames = 0, rc;

    if (nm_w2v2_emissions(s->model, pcm, n, &logp, &frames)) {
        av_log(ctx, AV_LOG_ERROR, "lyricsalign: the model failed on %d samples\n", n);
        return AVERROR(ENOMEM);
    }
    if (frames <= 0) {
        av_free(logp);
        return 0;
    }
    if (dump)
        la_dump_emissions(ctx, logp, frames, V);
    star = nm_la_add_star(logp, frames, V);
    av_free(logp);
    if (!star)
        return AVERROR(ENOMEM);
    rc = nm_la_viterbi(star, frames, V + 1, tokens, n_tokens, nm_w2v2_blank(s->model), V,
                       NM_LA_LINE_BLANK_PENALTY, out);
    av_free(star);
    return rc < 0 ? AVERROR(ENOMEM) : rc;
}

static double la_frame_s(int frame20)
{
    return frame20 * (double) NM_LA_HOP / NM_LA_RATE;
}

/* One written line: its JSON object into b. */
/* One word object: text (null when NULL), its span over n placed tokens from
 * k, or nulls when the word kept no vocabulary id. */
static void la_json_word(AVBPrint *b, int first, const char *text, const NMLaPlace *tok, int k, int n)
{
    av_bprintf(b, "%s{\"text\":", first ? "" : ",");
    if (text)
        la_json_str(b, text);
    else
        av_bprintf(b, "null");
    if (n > 0) {
        double ws = 0.0;
        for (int i = 0; i < n; i++)
            ws += tok[k + i].post;
        av_bprintf(b, ",\"start\":%.3f,\"end\":%.3f,\"score\":%.3f}", la_frame_s(tok[k].first),
                   la_frame_s(tok[k + n - 1].last + 1), ws / n);
    } else {
        av_bprintf(b, ",\"start\":null,\"end\":null,\"score\":0}");
    }
}

static void la_json_written(AVFilterContext *ctx, AVBPrint *b, int index, const NMLaPlace *tok_place, double start_s,
                            double lead_in_s)
{
    LyricsAlignContext *s = ctx->priv;
    const LaLine *l = &s->lines[index];
    double score = 0.0;

    for (int i = 0; i < l->n_ids; i++)
        score += tok_place[i].post;
    score /= l->n_ids;
    av_bprintf(b, "{\"index\":%d,\"text\":", index);
    la_json_str(b, l->text);
    av_bprintf(b, ",\"start\":%.3f,\"end\":%.3f,\"score\":%.3f,\"lead_in\":%.3f,\"words\":[",
               start_s, la_frame_s(tok_place[l->n_ids - 1].last + 1), score, lead_in_s);
    /* one entry per span: the placed tokens of the phones it kept */
    for (int w = 0; w < l->n_spans; w++) {
        const NMLpSpan *span = &l->spans[w];
        const int k = l->id_at[span->phone];

        la_json_word(b, !w, l->labels[w], tok_place, k, l->id_at[span->phone + span->n_phones] - k);
    }
    av_bprintf(b, "]}");
}

/* How many of the line's words[] entries have phones, and the score of the
 * first of them, as la_json_word() reports it. */
static int la_scored_words(const LaLine *l, const NMLaPlace *tok_place, double *first_score)
{
    int words = 0;

    *first_score = 0.0;
    for (int w = 0; w < l->n_spans; w++) {
        const NMLpSpan *span = &l->spans[w];
        const int k = l->id_at[span->phone];
        const int n = l->id_at[span->phone + span->n_phones] - k;

        if (n <= 0)
            continue;
        if (!words++) {
            double sum = 0.0;

            for (int i = 0; i < n; i++)
                sum += tok_place[k + i].post;
            *first_score = sum / n;
        }
    }
    return words;
}

static int la_align_and_write(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    const int V = nm_w2v2_vocab_n(s->model);
    int *tokens = NULL, *line_first = NULL;
    int n_tokens = 0, written = 0, rc_v, rc_c = 1, ret = 0;
    NMLaPlace *placed_v = NULL, *placed_c = NULL;
    float *check = NULL, *env = NULL, *rms20 = NULL;
    /* soft_walkback is seconds; the walk counts envelope hops of 10 ms */
    const int soft_hops = (int) lrint(s->soft_walkback * (double) NM_LA_RATE / NM_LA_ENV_HOP);
    int n_env = 0, n_rms20 = 0, common, backing_silent = 1, prev_end = -1;
    const char *check_name;
    AVBPrint body;

    av_bprint_init(&body, 0, AV_BPRINT_SIZE_UNLIMITED);

    /* step 4: the token sequence [star] (phones [star])* */
    for (int i = 0; i < s->n_lines; i++)
        n_tokens += s->lines[i].n_ids ? s->lines[i].n_ids + 1 : 0;
    n_tokens += 1;
    tokens = av_malloc_array(n_tokens, sizeof(*tokens));
    line_first = av_malloc_array(s->n_lines + 1, sizeof(*line_first));
    placed_v = av_malloc_array(n_tokens, sizeof(*placed_v));
    placed_c = av_malloc_array(n_tokens, sizeof(*placed_c));
    if (!tokens || !line_first || !placed_v || !placed_c) {
        ret = AVERROR(ENOMEM);
        goto done;
    }
    n_tokens = 0;
    tokens[n_tokens++] = V;
    for (int i = 0; i < s->n_lines; i++) {
        const LaLine *l = &s->lines[i];
        line_first[i] = l->n_ids ? n_tokens : -1;
        for (int k = 0; k < l->n_ids; k++)
            tokens[n_tokens++] = l->ids[k];
        if (l->n_ids)
            tokens[n_tokens++] = V;
    }

    /* steps 2, 3, 5 on the vocals */
    rc_v = la_place(ctx, s->pcm[0], s->n[0], tokens, n_tokens, placed_v, 1);
    if (rc_v < 0) {
        ret = rc_v;
        goto done;
    }
    if (rc_v == 0) {
        av_log(ctx, AV_LOG_WARNING, "lyricsalign: no alignment path (%d samples, %d tokens): nothing written\n",
               s->n[0], n_tokens);
        la_write_header(ctx, 0, s->blend == 0.0f ? "none" : "backing");
        for (int i = 0; i < s->n_lines; i++)
            la_write_skipped(ctx, i, NM_LA_NO_ALIGNMENT, -1, -1);
        goto done;
    }

    /* step 6: the check signal, vocals + blend * backing over the common length */
    common = FFMIN(s->n[0], s->n[1]);
    for (int i = 0; i < common && backing_silent; i++)
        if (s->pcm[1][i] != 0.0f)
            backing_silent = 0;
    if (s->blend == 0.0f) {
        check_name = "none";
    } else if (backing_silent) {
        /* identical signals place identically: the second pass would only cost time */
        check_name = "backing";
    } else {
        check = av_malloc_array(FFMAX(common, 1), sizeof(*check));
        if (!check) {
            ret = AVERROR(ENOMEM);
            goto done;
        }
        for (int i = 0; i < common; i++)
            check[i] = s->pcm[0][i] + s->blend * s->pcm[1][i];
        rc_c = la_place(ctx, check, common, tokens, n_tokens, placed_c, 0);
        if (rc_c < 0) {
            ret = rc_c;
            goto done;
        }
        check_name = rc_c ? "backing" : "failed";
        if (!rc_c)
            av_log(ctx, AV_LOG_WARNING, "lyricsalign: the check alignment has no path; every line is check_failed\n");
    }

    /* step 7 needs the vocals' envelope, 7c their level per 20 ms as well */
    env = nm_la_envelope_db(s->pcm[0], s->n[0], &n_env);
    if (env && s->unheard_island)
        rms20 = nm_la_rms_db(s->pcm[0], s->n[0], NM_LA_HOP, &n_rms20);
    if (!env || (s->unheard_island && !rms20)) {
        ret = AVERROR(ENOMEM);
        goto done;
    }

    for (int i = 0; i < s->n_lines; i++) {
        const LaLine *l = &s->lines[i];
        const NMLaPlace *line, *chk;
        enum NMLaReason reason;
        NMLaLineOnset onset;
        int spike, start_hop;
        double lead_in_s;

        if (line_first[i] < 0) {
            la_write_skipped_to(ctx, &body, i, l->text[0] ? NM_LA_NO_PHONES : NM_LA_EMPTY, -1, -1);
            continue;
        }
        line = placed_v + line_first[i];
        /* the check placement: the check's own, the line itself when there is
         * no check (blend=0, or a silent backing), none when the check failed */
        chk = !check ? line : (rc_c ? placed_c + line_first[i] : NULL);
        reason = nm_la_verdict(line, l->n_ids, chk);
        spike = line[0].first;
        if (reason != NM_LA_OK) {
            la_write_skipped_to(ctx, &body, i, reason, spike, chk ? chk[0].first : -1);
            prev_end = line[l->n_ids - 1].first;
            continue;
        }
        /* step 7 and its refinements 7b and 7c: the written start, a 10 ms hop */
        onset.spike_frame = spike;
        onset.prev_end_frame = prev_end;
        onset.soft_onset = l->soft_onset;
        onset.words = la_scored_words(l, line, &onset.first_word_score);
        start_hop = nm_la_written_start(env, n_env, rms20, n_rms20, &onset, soft_hops, s->unheard_island);
        lead_in_s = (spike * (NM_LA_HOP / NM_LA_ENV_HOP) - start_hop) * 0.01;
        if (lead_in_s < 0)
            lead_in_s = 0;
        la_json_written(ctx, &body, i, line, start_hop * 0.01, lead_in_s);
        av_bprint_chars(&body, '\n', 1);
        written++;
        prev_end = line[l->n_ids - 1].first;
    }
    if (!av_bprint_is_complete(&body)) {
        ret = AVERROR(ENOMEM);
        goto done;
    }
    la_write_header(ctx, written, check_name);
    {
        /* the per-line objects, one per line, already newline-terminated */
        char *p = body.str, *nl;
        AVBPrint one;
        while (p && *p) {
            nl = strchr(p, '\n');
            if (!nl)
                break;
            *nl = 0;
            av_bprint_init(&one, 0, AV_BPRINT_SIZE_UNLIMITED);
            av_bprintf(&one, "%s", p);
            la_emit(ctx, &one);
            av_bprint_finalize(&one, NULL);
            p = nl + 1;
        }
    }
    av_log(ctx, AV_LOG_INFO, "lyricsalign: %d of %d lines written (check: %s)\n", written, s->n_lines, check_name);
done:
    av_bprint_finalize(&body, NULL);
    av_free(tokens);
    av_free(line_first);
    av_free(placed_v);
    av_free(placed_c);
    av_free(check);
    av_free(env);
    av_free(rms20);
    if (s->out) {
        avio_flush(s->out);
        if (s->out->error < 0 && ret >= 0) {
            av_log(ctx, AV_LOG_ERROR, "lyricsalign: writing to %s failed: %s\n", s->destination,
                   av_err2str(s->out->error));
            ret = s->out->error;
        }
    }
    return ret;
}

/* ---------------------------------------------------------------------------
 * Filter plumbing
 * ------------------------------------------------------------------------- */

static int init(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    int ret;

    if (!s->model_path || !*s->model_path) {
        av_log(ctx, AV_LOG_ERROR, "lyricsalign: the model option is required (path to the GGUF)\n");
        return AVERROR(EINVAL);
    }
    if (!s->text_file || !*s->text_file) {
        av_log(ctx, AV_LOG_ERROR, "lyricsalign: the text_file option is required\n");
        return AVERROR(EINVAL);
    }
    if (!s->language || !*s->language) {
        av_log(ctx, AV_LOG_ERROR, "lyricsalign: the language option is required (an espeak-ng voice name)\n");
        return AVERROR(EINVAL);
    }
    if (!la_path_exists(s->model_path)) {
        av_log(ctx, AV_LOG_ERROR, "lyricsalign: model not found: %s\n", s->model_path);
        return AVERROR(ENOENT);
    }

    /* espeak-ng data: the option, or espeak-ng-data next to the binary. espeak
     * itself would fall back to its compiled-in path and the environment when
     * the directory is missing, so the check is ours. */
    if (!s->espeak_data || !*s->espeak_data) {
        char dir[2048];
        char *def;
        if (la_exe_dir(dir, sizeof(dir))) {
            av_log(ctx, AV_LOG_ERROR, "lyricsalign: cannot find this binary's directory for the espeak-ng data; set espeak_data\n");
            return AVERROR(EINVAL);
        }
        def = av_asprintf("%s/espeak-ng-data", dir);
        if (!def)
            return AVERROR(ENOMEM);
        av_free(s->espeak_data);
        s->espeak_data = def;
    }
    if (!la_is_dir_with(s->espeak_data, "phontab")) {
        av_log(ctx, AV_LOG_ERROR, "lyricsalign: espeak-ng data not found: %s/phontab is missing (set espeak_data to the "
               "espeak-ng-data directory)\n", s->espeak_data);
        return AVERROR(ENOENT);
    }

    ret = la_read_text(ctx);
    if (ret < 0)
        return ret;
    ret = la_phonemize(ctx);
    if (ret < 0)
        return ret;

    if (s->destination && *s->destination) {
        const char *dst = !strcmp(s->destination, "-") ? "pipe:1" : s->destination;
        ret = avio_open(&s->out, dst, AVIO_FLAG_WRITE);
        if (ret < 0) {
            av_log(ctx, AV_LOG_ERROR, "lyricsalign: could not open %s: %s\n", s->destination, av_err2str(ret));
            return ret;
        }
        s->out->direct = AVIO_FLAG_DIRECT;
    }
    return 0;
}

static int la_align_received(AVFilterContext *ctx, const char *why);

static void uninit(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;

    la_align_received(ctx, "the graph ended");    /* a failure is logged there */
    if (s->out)
        avio_closep(&s->out);
    for (int i = 0; i < 2; i++) {
        swr_free(&s->swr[i]);
        av_freep(&s->pcm[i]);
    }
    la_free_lines(s);
    nm_w2v2_free(s->model);
    s->model = NULL;
    if (s->device)
        ggml_backend_free(s->device);
    if (s->cpu)
        ggml_backend_free(s->cpu);
    s->device = s->cpu = NULL;
    if (s->phonemized) {
        ff_mutex_lock(&la_espeak_lock);
        if (--la_espeak_users == 0)
            espeak_Terminate();
        ff_mutex_unlock(&la_espeak_lock);
        s->phonemized = 0;
    }
}

static AVOnce init_static_once = AV_ONCE_INIT;

/* The model loads here, on input 0's configuration, not in init(): the
 * ffmpeg CLI builds every filtergraph twice and only configures one. */
static int config_vocals(AVFilterLink *inlink)
{
    AVFilterContext *ctx = inlink->dst;
    LyricsAlignContext *s = ctx->priv;
    char err[256];
    int gpu_usable, n_gpu, ret;

    if (s->model)
        return 0;

    /* Unconditionally and first: nm_ggml_gpu_usable()'s first call runs the
     * software-Vulkan guard, which must happen before anything touches
     * ggml's backend registry (see nm_ggml_cpu.h). */
    gpu_usable = nm_ggml_gpu_usable();
    ff_thread_once(&init_static_once, ggml_backend_load_all);
    if (nm_ggml_backend_notice())
        av_log(ctx, AV_LOG_INFO, "lyricsalign: %s.\n", nm_ggml_backend_notice());
    n_gpu = nm_ggml_gpu_count();
    s->gpu_active = s->use_gpu && gpu_usable && s->gpu_device < n_gpu;
    if (s->use_gpu && gpu_usable && !s->gpu_active)
        av_log(ctx, AV_LOG_WARNING, "lyricsalign: gpu_device=%d but this machine has %d GPU device(s); running on the CPU.\n",
               s->gpu_device, n_gpu);

    s->cpu = nm_ggml_backend_init(0, 0);
    if (!s->cpu) {
        av_log(ctx, AV_LOG_ERROR, "lyricsalign: no ggml CPU backend\n");
        return AVERROR(EINVAL);
    }
    if (s->gpu_active) {
        s->device = nm_ggml_backend_init(1, s->gpu_device);
        if (!s->device)
            s->gpu_active = 0;
    }
    s->threads_used = s->threads > 0 ? FFMAX(1, FFMIN(s->threads, av_cpu_count())) : nm_ggml_filter_threads(ctx);
    ggml_backend_cpu_set_n_threads(s->cpu, s->threads_used);
    av_log(ctx, AV_LOG_INFO, "lyricsalign: %d ggml threads.\n", s->threads_used);
    av_log(ctx, AV_LOG_INFO, "lyricsalign: ggml cpu variant '%s'.\n", nm_ggml_cpu_variant_name());
    av_log(ctx, AV_LOG_INFO, "lyricsalign: ggml backend '%s' (%s).\n",
           s->gpu_active ? nm_ggml_backend_name(s->gpu_device) : "cpu",
           s->gpu_active ? nm_ggml_backend_device(s->gpu_device) : nm_ggml_cpu_variant_name());

    if (nm_w2v2_load(s->model_path, s->device, s->cpu, &s->model, err, sizeof(err))) {
        av_log(ctx, AV_LOG_ERROR, "lyricsalign: cannot load %s: %s\n", s->model_path, err);
        return AVERROR(EINVAL);
    }
    av_log(ctx, AV_LOG_INFO, "lyricsalign: model '%s', %d phones in the vocabulary.\n",
           nm_w2v2_name(s->model), nm_w2v2_vocab_n(s->model));

    ret = la_map_phones(ctx);
    if (ret < 0)
        return ret;
    if (s->mapping_misses)
        av_log(ctx, AV_LOG_WARNING, "lyricsalign: %d phone(s) of the text have no entry in the model's vocabulary and were dropped.\n",
               s->mapping_misses);
    return 0;
}

static int config_output(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    LyricsAlignContext *s = ctx->priv;
    AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;

    outlink->sample_rate = ctx->inputs[0]->sample_rate;
    outlink->format = ctx->inputs[0]->format;
    outlink->time_base = ctx->inputs[0]->time_base;
    if (av_channel_layout_copy(&outlink->ch_layout, &ctx->inputs[0]->ch_layout) < 0)
        return AVERROR(ENOMEM);

    for (int i = 0; i < 2; i++) {
        AVFilterLink *in = ctx->inputs[i];
        int ret;

        swr_free(&s->swr[i]);
        ret = swr_alloc_set_opts2(&s->swr[i], &mono, AV_SAMPLE_FMT_FLT, NM_LA_RATE,
                                  &in->ch_layout, in->format, in->sample_rate, 0, ctx);
        if (ret < 0 || (ret = swr_init(s->swr[i])) < 0) {
            av_log(ctx, AV_LOG_ERROR, "lyricsalign: cannot set up resampling of input %d\n", i);
            return ret;
        }
    }
    return 0;
}

/* Append a frame of input i (or, with NULL, the resampler's tail) to the
 * 16 kHz mono buffer. */
static int la_append(AVFilterContext *ctx, int i, const AVFrame *frame)
{
    LyricsAlignContext *s = ctx->priv;
    int want, got;
    uint8_t *dst;

    want = (int) av_rescale_rnd(swr_get_delay(s->swr[i], ctx->inputs[i]->sample_rate) + (frame ? frame->nb_samples : 0),
                                NM_LA_RATE, ctx->inputs[i]->sample_rate, AV_ROUND_UP) + 32;
    if (s->n[i] + want > s->cap[i]) {
        int cap = FFMAX(s->cap[i] * 2, s->n[i] + want + NM_LA_RATE);
        float *grown = av_realloc_array(s->pcm[i], cap, sizeof(*grown));
        if (!grown)
            return AVERROR(ENOMEM);
        s->pcm[i] = grown;
        s->cap[i] = cap;
    }
    dst = (uint8_t *) (s->pcm[i] + s->n[i]);
    got = swr_convert(s->swr[i], &dst, want, frame ? (const uint8_t **) frame->extended_data : NULL,
                      frame ? frame->nb_samples : 0);
    if (got < 0)
        return got;
    s->n[i] += got;
    return 0;
}

/* Flush the resamplers, align and write, once. */
static int la_align_now(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    int ret;

    if (s->done)
        return 0;
    s->done = 1;
    for (int i = 0; i < 2; i++) {
        ret = la_append(ctx, i, NULL);
        if (ret < 0)
            return ret;
    }
    return la_align_and_write(ctx);
}

static int la_finish(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    int ret = la_align_now(ctx);

    if (ret < 0)
        return ret;
    ff_outlink_set_status(ctx->outputs[0], s->status, s->eof_pts);
    return 0;
}

/* The audio received when the graph ends before the vocals do (the output
 * was closed early, by -t after the graph for instance) is still aligned. */
static int la_align_received(AVFilterContext *ctx, const char *why)
{
    LyricsAlignContext *s = ctx->priv;

    if (s->done || !s->model || s->n[0] <= 0)
        return 0;
    av_log(ctx, AV_LOG_WARNING, "lyricsalign: %s after %.2f s of vocals; aligning what was received\n",
           why, s->n[0] / (double) NM_LA_RATE);
    return la_align_now(ctx);
}

static int activate(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    AVFilterLink *in0 = ctx->inputs[0], *in1 = ctx->inputs[1], *outlink = ctx->outputs[0];
    AVFrame *frame = NULL;
    int ret, status;
    int64_t pts;

    status = ff_outlink_get_status(outlink);
    if (status) {
        ret = la_align_received(ctx, "output closed");
        if (ret < 0)
            return ret;
        for (unsigned i = 0; i < ctx->nb_inputs; i++)
            ff_inlink_set_status(ctx->inputs[i], status);
        return 0;
    }

    /* vocals: copy, stamp, forward */
    if (!s->eof[0]) {
        ret = ff_inlink_consume_frame(in0, &frame);
        if (ret < 0)
            return ret;
        if (ret > 0) {
            ret = la_append(ctx, 0, frame);
            if (ret < 0) {
                av_frame_free(&frame);
                return ret;
            }
            av_dict_set(&frame->metadata, "lavfi.lyricsalign.backend",
                        s->gpu_active ? nm_ggml_backend_name(s->gpu_device) : "cpu", 0);
            av_dict_set(&frame->metadata, "lavfi.lyricsalign.cpu_variant", nm_ggml_cpu_variant_name(), 0);
            av_dict_set(&frame->metadata, "lavfi.lyricsalign.version", LA_VERSION, 0);
            return ff_filter_frame(outlink, frame);
        }
        if (ff_inlink_acknowledge_status(in0, &status, &pts)) {
            s->eof[0] = 1;
            s->status = status;
            s->eof_pts = pts;
        }
    }

    /* backing: copy while it is not ahead of the vocals. It is only ever
     * requested while it lags them (below), so an endless backing such as
     * anullsrc cannot run ahead and fill memory: measured, an unconditional
     * request let anullsrc deliver at CPU speed while the file decoder
     * delivered three frames, and the buffer died of ENOMEM in 4 s. */
    if (!s->eof[1]) {
        while ((ret = ff_inlink_consume_frame(in1, &frame)) > 0) {
            if (!s->eof[0] || s->n[1] < s->n[0]) {
                ret = la_append(ctx, 1, frame);
                if (ret < 0) {
                    av_frame_free(&frame);
                    return ret;
                }
            }
            av_frame_free(&frame);
        }
        if (ret < 0)
            return ret;
        if (ff_inlink_acknowledge_status(in1, &status, &pts))
            s->eof[1] = 1;
    }

    if (s->eof[0]) {
        /* the vocals ended: fetch backing up to their length, then finish */
        if (!s->eof[1] && s->n[1] < s->n[0]) {
            ff_inlink_request_frame(in1);
            return FFERROR_NOT_READY;
        }
        return la_finish(ctx);
    }

    if (ff_outlink_frame_wanted(outlink)) {
        ff_inlink_request_frame(in0);
        if (!s->eof[1] && s->n[1] < s->n[0] + NM_LA_RATE)
            ff_inlink_request_frame(in1);
    }
    return FFERROR_NOT_READY;
}

static int query_formats(const AVFilterContext *ctx, AVFilterFormatsConfig **cfg_in, AVFilterFormatsConfig **cfg_out)
{
    static const enum AVSampleFormat sample_fmts[] = { AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_NONE };
    int ret;

    if ((ret = ff_set_common_formats_from_list2(ctx, cfg_in, cfg_out, sample_fmts)) < 0)
        return ret;
    if ((ret = ff_set_common_all_channel_counts2(ctx, cfg_in, cfg_out)) < 0)
        return ret;
    return ff_set_common_all_samplerates2(ctx, cfg_in, cfg_out);
}

#define OFFSET(x) offsetof(LyricsAlignContext, x)
#define FLAGS AV_OPT_FLAG_AUDIO_PARAM | AV_OPT_FLAG_FILTERING_PARAM

static const AVOption lyricsalign_options[] = {
    { "model", "Path to the GGUF phoneme model (wav2vec2-xlsr-53-espeak-cv-ft-f16.gguf)", OFFSET(model_path), AV_OPT_TYPE_STRING, .flags = FLAGS },
    { "text_file", "UTF-8 lyric text, one lyric line per text line (an empty line is an instrumental marker)", OFFSET(text_file), AV_OPT_TYPE_STRING, .flags = FLAGS },
    { "language", "espeak-ng voice name of the lyrics (en-us, en-gb, nl, de, fr, ja, ...)", OFFSET(language), AV_OPT_TYPE_STRING, .flags = FLAGS },
    { "espeak_data", "Path to espeak-ng-data (default: next to the ffmpeg binary)", OFFSET(espeak_data), AV_OPT_TYPE_STRING, { .str = "" }, .flags = FLAGS },
    { "blend", "Share of the backing mixed into the check signal; 0 disables the agreement check", OFFSET(blend), AV_OPT_TYPE_FLOAT, { .dbl = 0.5 }, 0.0, 1.0, .flags = FLAGS },
    { "destination", "Where the JSON Lines go ('-' is stdout; empty: the log)", OFFSET(destination), AV_OPT_TYPE_STRING, { .str = "" }, .flags = FLAGS },
    { "threads", "ggml CPU threads (0: half the physical cores, capped by -filter_threads)", OFFSET(threads), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, .flags = FLAGS },
    { "use_gpu", "Allow the ggml GPU backend (Vulkan, Metal)", OFFSET(use_gpu), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, .flags = FLAGS },
    { "gpu_device", "GPU device to use", OFFSET(gpu_device), AV_OPT_TYPE_INT, { .i64 = 0 }, 0, INT_MAX, .flags = FLAGS },
    { "soft_walkback", "Seconds a line that begins on a vowel or sonorant may start before its first phone; 0 disables", OFFSET(soft_walkback), AV_OPT_TYPE_FLOAT, { .dbl = 0.1 }, 0.0, 0.8, .flags = FLAGS },
    { "unheard_island", "Start a line whose first word was not heard on the sound no word claims before it; 0 disables", OFFSET(unheard_island), AV_OPT_TYPE_INT, { .i64 = 1 }, 0, 1, .flags = FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(lyricsalign);

static const AVFilterPad lyricsalign_inputs[] = {
    {
        .name         = "vocals",
        .type         = AVMEDIA_TYPE_AUDIO,
        .config_props = config_vocals,
    },
    {
        .name         = "backing",
        .type         = AVMEDIA_TYPE_AUDIO,
    },
};

static const AVFilterPad lyricsalign_outputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_AUDIO,
        .config_props = config_output,
    },
};

const FFFilter ff_af_lyricsalign = {
    .p.name        = "lyricsalign",
    .p.description = NULL_IF_CONFIG_SMALL("Place known lyric text on a vocal stem by CTC forced alignment."),
    .p.priv_class  = &lyricsalign_class,
    .init          = init,
    .uninit        = uninit,
    .activate      = activate,
    .priv_size     = sizeof(LyricsAlignContext),
    FILTER_INPUTS(lyricsalign_inputs),
    FILTER_OUTPUTS(lyricsalign_outputs),
    FILTER_QUERY_FUNC2(query_formats),
};

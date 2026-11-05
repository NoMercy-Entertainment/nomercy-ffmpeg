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

#include <ggml.h>
#include <ggml-backend.h>
#include <ggml-cpu.h>
#include <espeak-ng/speak_lib.h>

#include "libavutil/avutil.h"
#include "libavutil/avstring.h"
#include "libavutil/bprint.h"
#include "libavutil/channel_layout.h"
#include "libavutil/cpu.h"
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

#define LA_VERSION "1.0.0"

typedef struct LaLine {
    char *text;                 /* the text line, without its line ending */
    NMLpWord *words;            /* espeak's words of phones; NULL for an empty line */
    int n_words;
    int **word_ids;             /* per word, the mapped vocabulary ids */
    int *word_n;
    int *ids;                   /* every mapped id of the line, in order */
    int n_ids;
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

static int la_is_dir_with(const char *dir, const char *file)
{
    char path[2048];
    struct stat st;
    snprintf(path, sizeof(path), "%s/%s", dir, file);
    return stat(path, &st) == 0;
}

/* Phonemize one line with the already-initialised espeak (lock held):
 * clause by clause, joined by a space, then parsed. */
static int la_phonemize_line(LaLine *line)
{
    AVBPrint ipa;
    const void *p = line->text;
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
    ret = nm_lp_parse_ipa(ipa.str, &line->words, &line->n_words);
    av_bprint_finalize(&ipa, NULL);
    return ret ? AVERROR(ENOMEM) : 0;
}

static int la_phonemize(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    int ret = 0;

    ff_mutex_lock(&la_espeak_lock);
    if (!la_espeak_users) {
        if (espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, s->espeak_data, 0) < 0) {
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
        if (l->word_ids)
            for (int w = 0; w < l->n_words; w++)
                av_free(l->word_ids[w]);
        av_free(l->word_ids);
        av_free(l->word_n);
        av_free(l->ids);
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
        int total = 0;

        if (!l->n_words)
            continue;
        l->word_ids = av_calloc(l->n_words, sizeof(*l->word_ids));
        l->word_n = av_calloc(l->n_words, sizeof(*l->word_n));
        if (!l->word_ids || !l->word_n)
            goto oom;
        for (int w = 0; w < l->n_words; w++) {
            l->word_ids[w] = av_malloc_array(l->words[w].n + 1, sizeof(int));
            if (!l->word_ids[w])
                goto oom;
            for (int k = 0; k < l->words[w].n; k++) {
                int id = nm_lp_map_phone(l->words[w].phones[k], vocab, n_vocab);
                if (id < 0)
                    s->mapping_misses++;
                else
                    l->word_ids[w][l->word_n[w]++] = id;
            }
            total += l->word_n[w];
        }
        l->ids = av_malloc_array(total + 1, sizeof(int));
        if (!l->ids)
            goto oom;
        for (int w = 0; w < l->n_words; w++)
            for (int k = 0; k < l->word_n[w]; k++)
                l->ids[l->n_ids++] = l->word_ids[w][k];
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
 * starts (frames, -1 = none), no words. */
static void la_write_skipped(AVFilterContext *ctx, int index, enum NMLaReason reason, int vocals_frame, int check_frame)
{
    LyricsAlignContext *s = ctx->priv;
    AVBPrint b;

    av_bprint_init(&b, 0, AV_BPRINT_SIZE_UNLIMITED);
    av_bprintf(&b, "{\"index\":%d,\"text\":", index);
    la_json_str(&b, s->lines[index].text);
    av_bprintf(&b, ",\"start\":null,\"end\":null,\"score\":0,\"reason\":\"%s\",\"vocals_start\":", nm_la_reason_name(reason));
    la_json_time(&b, vocals_frame, -1);
    av_bprintf(&b, ",\"check_start\":");
    la_json_time(&b, check_frame, -1);
    av_bprintf(&b, ",\"words\":[]}");
    la_emit(ctx, &b);
    av_bprint_finalize(&b, NULL);
}

/* ---------------------------------------------------------------------------
 * The alignment: skeleton (every line no_alignment) until the real one lands.
 * ------------------------------------------------------------------------- */
static int la_align_and_write(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    const char *check = s->blend == 0.0f ? "none" : "backing";

    la_write_header(ctx, 0, check);
    for (int i = 0; i < s->n_lines; i++)
        la_write_skipped(ctx, i, NM_LA_NO_ALIGNMENT, -1, -1);
    if (s->out)
        avio_flush(s->out);
    return 0;
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
    {
        struct stat st;
        if (stat(s->model_path, &st)) {
            av_log(ctx, AV_LOG_ERROR, "lyricsalign: model not found: %s\n", s->model_path);
            return AVERROR(ENOENT);
        }
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

static void uninit(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;

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

static int la_finish(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    AVFilterLink *outlink = ctx->outputs[0];
    int ret;

    if (!s->done) {
        s->done = 1;
        for (int i = 0; i < 2; i++) {
            ret = la_append(ctx, i, NULL);
            if (ret < 0)
                return ret;
        }
        ret = la_align_and_write(ctx);
        if (ret < 0)
            return ret;
    }
    ff_outlink_set_status(outlink, s->status, s->eof_pts);
    return 0;
}

static int activate(AVFilterContext *ctx)
{
    LyricsAlignContext *s = ctx->priv;
    AVFilterLink *in0 = ctx->inputs[0], *in1 = ctx->inputs[1], *outlink = ctx->outputs[0];
    AVFrame *frame = NULL;
    int ret, status;
    int64_t pts;

    FF_FILTER_FORWARD_STATUS_BACK_ALL(outlink, ctx);

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

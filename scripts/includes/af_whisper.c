/*
 * Copyright (c) 2025 Vittorio Palmisano
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with FFmpeg; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

// sched_getaffinity() and the CPU_SET macros, for counting physical cores.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>   // strstr, for reading whisper.cpp back-end report out of its log

#if defined(_WIN32)
#include <windows.h>
#elif defined(__APPLE__) || defined(__FreeBSD__)
#include <sys/param.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#elif defined(__linux__)
#include <sched.h>
#endif

#include <whisper.h>
#include "nm_ggml_cpu.h"

#include "libavutil/avutil.h"
#include "libavutil/opt.h"
#include "libavutil/channel_layout.h"
#include "libavutil/samplefmt.h"
#include "libavfilter/avfilter.h"
#include "libavfilter/audio.h"
#include "libavutil/mem.h"
#include "libavutil/avstring.h"
#include "libavutil/internal.h"
#include "libavformat/avio.h"
#include "libavutil/bprint.h"
#include "libavutil/cpu.h"
#include "libavutil/thread.h"

#include "formats.h"

// libavutil/internal.h poisons malloc and friends, so the shared header gets
// FFmpeg's allocator. See nm_whisper_words.h for why it is a separate file.
#define NM_WW_MALLOC(n)     av_malloc(n)
#define NM_WW_REALLOC(p, n) av_realloc(p, n)
#define NM_WW_FREE(p)       av_free(p)
#include "nm_whisper_words.h"

// whisper.cpp's enum values for the presets in nm_whisper_words.h, by index.
// Listed by name rather than computed from the enum's order, so a reordering
// upstream is a compile-visible change here, not a silent shift of presets.
static const enum whisper_alignment_heads_preset nm_whisper_dtw_aheads[] = {
    WHISPER_AHEADS_TINY_EN,
    WHISPER_AHEADS_TINY,
    WHISPER_AHEADS_BASE_EN,
    WHISPER_AHEADS_BASE,
    WHISPER_AHEADS_SMALL_EN,
    WHISPER_AHEADS_SMALL,
    WHISPER_AHEADS_MEDIUM_EN,
    WHISPER_AHEADS_MEDIUM,
    WHISPER_AHEADS_LARGE_V1,
    WHISPER_AHEADS_LARGE_V2,
    WHISPER_AHEADS_LARGE_V3,
    WHISPER_AHEADS_LARGE_V3_TURBO,
};

// whisper.cpp refuses more than this many decoders (WHISPER_MAX_DECODERS in
// whisper.cpp, not exported), and it refuses per window: whisper_full() fails
// and the window's audio is dropped. Capping the options catches it at init.
#define NM_WHISPER_MAX_DECODERS 8

// A prompt longer than this is a mistake rather than a prompt: whisper keeps
// only the last n_text_ctx/2 tokens (about 223) of it anyway.
#define NM_WHISPER_MAX_PROMPT_FILE (1 << 20)

typedef struct WhisperContext {
    const AVClass *class;
    char *model_path;
    const char *language;
    char *language_str;
    bool translate;
    bool use_gpu;
    int gpu_device;
    /* What we actually handed whisper.cpp: use_gpu AND'ed with our own
     * judgement of whether a GPU is usable at all. The log line and the
     * lavfi.whisper.backend metadata report this, never the request - a run
     * that asked for a GPU and quietly got the CPU must not claim otherwise. */
    int gpu_active;
    char *vad_model_path;
    float vad_threshold;
    int64_t vad_min_speech_duration;
    int64_t vad_min_silence_duration;

    int64_t queue;
    char *destination;
    char *format;
    int max_len;

    char *dtw;
    int word_timestamps;
    char *prompt;
    char *prompt_file;
    int beam_size;
    int best_of;
    /* Index into nm_whisper_dtw_presets(), -1 when DTW is off. */
    int dtw_preset;
    /* whisper.cpp threads, resolved once by config_input (nm_whisper_threads). */
    int n_threads;
    /* The prompt handed to whisper_full(): prompt_file's contents, else the
     * prompt option, else NULL. Owned when it came from the file. */
    const char *initial_prompt;
    char *prompt_file_text;

    struct whisper_context *ctx_wsp;
    struct whisper_vad_context *ctx_vad;
    struct whisper_vad_params vad_params;

    float *audio_buffer;
    int audio_buffer_queue_size;
    int audio_buffer_fill_size;
    int audio_buffer_vad_size;
    int64_t audio_buffer_start_ms;

    int eof;
    int64_t next_pts;

    AVIOContext *avio_context;
    int index;

    const char *detected_language;
    float language_confidence;
} WhisperContext;

// Whether whisper.cpp said it did not get a GPU. A FILE-STATIC flag, not a
// field of the filter context, and that is the whole point.
//
// whisper_log_set() stores ONE global callback and one user pointer, so with
// two whisper filters in a graph the last to initialise owns it - and a write
// through `ctx->priv` from this callback would then land in the other
// instance's state, telling a filter it had lost a GPU because its neighbour
// did. af_stemsplit.c's uninit already carries the hard-won version of this
// lesson (it restores ggml's default sink precisely so a stale ctx pointer
// cannot be written through); this is the same hazard reached through
// whisper_log_set instead of ggml_log_set.
//
// A process-wide flag cannot be attributed to the wrong instance because it is
// not attributed to any instance: init() clears it immediately before its own
// whisper_init_from_file_with_params() and reads it immediately after, so the
// window belongs to that call. The worst a concurrent init can do is make us
// report "cpu" for a run that did get a GPU - a conservative misreport, not a
// write into another filter's memory.
static int nm_whisper_saw_no_gpu;

// Which context currently owns the global log callback. Compared on teardown so
// that a filter being destroyed only resets the sink if it is still the owner:
// otherwise tearing down the FIRST of two whisper filters would unregister the
// SECOND one's callback, and that survivor's ggml messages would go straight to
// stderr, around FFmpeg's -loglevel. Read and written only from filter init and
// uninit, which FFmpeg runs on one thread per graph.
static const AVFilterContext *nm_whisper_log_owner;

static void cb_log(enum ggml_log_level level, const char *text, void *user_data)
{
    AVFilterContext *ctx = user_data;
    int av_log_level = AV_LOG_DEBUG;

    // whisper.cpp's own account of which backend it took. See the snapshot in
    // init() for why this is read out of a log line rather than an API, and
    // why only the negative direction is acted on.
    if (text && (strstr(text, "whisper_backend_init_gpu: no GPU found") ||
                 strstr(text, "whisper_backend_init_gpu: failed to initialize")))
        nm_whisper_saw_no_gpu = 1;

    switch (level) {
    case GGML_LOG_LEVEL_ERROR:
        av_log_level = AV_LOG_ERROR;
        break;
    case GGML_LOG_LEVEL_WARN:
        av_log_level = AV_LOG_WARNING;
        break;
    }
    av_log(ctx, av_log_level, "%s", text);
}

/**
 * Physical cores this process may run on, or 0 when the platform cannot say.
 *
 * Only cores with at least one logical CPU in the process affinity count, so
 * a pinned or cgroup-limited process is not told about cores it cannot use.
 * The same count af_stemsplit.c uses for its thread default.
 */
static int nm_whisper_physical_cores(void)
{
#if defined(_WIN32)
    SYSTEM_LOGICAL_PROCESSOR_INFORMATION *info;
    DWORD_PTR proc_mask, sys_mask;
    DWORD len = 0;
    int i, n, cores = 0;

    if (!GetProcessAffinityMask(GetCurrentProcess(), &proc_mask, &sys_mask))
        return 0;
    GetLogicalProcessorInformation(NULL, &len);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || !len)
        return 0;
    info = av_malloc(len);
    if (!info)
        return 0;
    if (GetLogicalProcessorInformation(info, &len)) {
        n = len / sizeof(*info);
        for (i = 0; i < n; i++)
            if (info[i].Relationship == RelationProcessorCore &&
                (info[i].ProcessorMask & proc_mask))
                cores++;
    }
    av_free(info);
    return cores;
#elif defined(__APPLE__) || defined(__FreeBSD__)
    int n = 0;
    size_t size = sizeof(n);
#if defined(__APPLE__)
    const char *name = "hw.physicalcpu";
#else
    const char *name = "kern.smp.cores";
#endif
    return sysctlbyname(name, &n, &size, NULL, 0) == 0 && n > 0 ? n : 0;
#elif defined(__linux__)
    cpu_set_t set;
    int cpu, cores = 0;

    if (sched_getaffinity(0, sizeof(set), &set))
        return 0;
    // A core counts once: at the lowest of its hyperthreads that the
    // affinity mask allows.
    for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
        char path[96], list[256], *p;
        int first = -1;
        FILE *f;

        if (!CPU_ISSET(cpu, &set))
            continue;
        snprintf(path, sizeof(path),
                 "/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list", cpu);
        f = fopen(path, "r");
        if (!f)
            return 0;
        p = fgets(list, sizeof(list), f);
        fclose(f);
        if (!p)
            return 0;
        // "0,28" or "0-1": walk every sibling, ranges included
        while (*p && first < 0) {
            long lo = strtol(p, &p, 10), hi = lo, c;
            if (*p == '-')
                hi = strtol(p + 1, &p, 10);
            for (c = lo; c <= hi && c < CPU_SETSIZE; c++)
                if (CPU_ISSET(c, &set)) {
                    first = c;
                    break;
                }
            if (*p != ',')
                break;
            p++;
        }
        if (first == cpu)
            cores++;
    }
    return cores;
#else
    return 0;
#endif
}

/**
 * Threads for whisper.cpp: half the physical cores, unless the graph's thread
 * count was set on purpose.
 *
 * ggml's thread pool (no OpenMP, #64) busy-waits at every barrier, so a worker
 * that has to share a core - with its hyperthread twin, with ffmpeg's own
 * threads, with anything else the machine runs - stalls all the others. With
 * ffmpeg's default (threads=auto, which libavfilter turns into
 * min(cpus + 1, 16)) every whisper run on the CPU fell off that cliff: jfk.wav
 * on base.en took 53.6 s with 7 threads on 6 cores against 3.3 s with 6, and
 * 16.0 s with 16 threads on an 8-core/16-thread i7 against 5.0 s with 4. It
 * is what made vad_model unusable at the default (#115).
 *
 * Half the physical cores is the rule af_stemsplit.c follows for the same
 * reason (owner decision D16): a media server transcribes while it also
 * serves and transcodes, so a filter never takes the whole machine. When the
 * platform cannot count physical cores, half the logical CPUs.
 *
 * A graph thread count other than ffmpeg's automatic one was chosen on
 * purpose (-filter_threads, or the filter's own threads option) and is
 * followed, never above the CPUs this process may use. The thread count does
 * not change the transcript.
 */
static int nm_whisper_threads(AVFilterContext *ctx)
{
    const int cpus = av_cpu_count();
    const int graph = FFMAX(1, ff_filter_get_nb_threads(ctx));
    const int automatic = cpus > 1 ? FFMIN(cpus + 1, 16) : 1;
    const int cores = nm_whisper_physical_cores();

    if (graph != automatic)
        return FFMAX(1, FFMIN(graph, cpus));
    return FFMAX(1, (cores > 0 ? cores : cpus) / 2);
}

/**
 * Read prompt_file into wctx->prompt_file_text.
 *
 * Through avio rather than fopen, so the path behaves like every other path
 * FFmpeg takes, UTF-8 on Windows included. A UTF-8 byte order mark and
 * trailing whitespace are dropped: an editor's final newline is not part of
 * the prompt. An empty file means no prompt.
 */
static int read_prompt_file(AVFilterContext *ctx)
{
    WhisperContext *wctx = ctx->priv;
    AVIOContext *pb = NULL;
    AVBPrint bp;
    char *text;
    size_t len;
    int ret;

    ret = avio_open(&pb, wctx->prompt_file, AVIO_FLAG_READ);
    if (ret < 0) {
        av_log(ctx, AV_LOG_ERROR, "Could not read prompt_file %s: %s\n",
               wctx->prompt_file, av_err2str(ret));
        return ret;
    }

    av_bprint_init(&bp, 0, AV_BPRINT_SIZE_UNLIMITED);
    ret = avio_read_to_bprint(pb, &bp, NM_WHISPER_MAX_PROMPT_FILE + 1);
    avio_closep(&pb);
    if (ret >= 0 && !av_bprint_is_complete(&bp))
        ret = AVERROR(ENOMEM);
    if (ret < 0) {
        av_log(ctx, AV_LOG_ERROR, "Could not read prompt_file %s: %s\n",
               wctx->prompt_file, av_err2str(ret));
        av_bprint_finalize(&bp, NULL);
        return ret;
    }
    if (bp.len > NM_WHISPER_MAX_PROMPT_FILE) {
        av_log(ctx, AV_LOG_ERROR, "prompt_file %s is larger than %d bytes.\n",
               wctx->prompt_file, NM_WHISPER_MAX_PROMPT_FILE);
        av_bprint_finalize(&bp, NULL);
        return AVERROR(EINVAL);
    }

    ret = av_bprint_finalize(&bp, &text);
    if (ret < 0)
        return ret;

    len = strlen(text);
    while (len && av_isspace(text[len - 1]))
        text[--len] = '\0';
    if (len >= 3 && !memcmp(text, "\xEF\xBB\xBF", 3))
        memmove(text, text + 3, len - 2);

    if (!text[0]) {
        av_free(text);
        return 0;
    }
    wctx->prompt_file_text = text;
    return 0;
}

/**
 * Whether a model of this shape is one the dtw preset was made for.
 *
 * whisper.cpp only rejects a preset whose alignment heads do not exist in
 * the model. A preset for a model of the same shape - base on base.en, or
 * tiny.en on a base.en file - loads without a word and produces wrong
 * timings, so the filter checks the decoder shape itself and refuses.
 */
static int dtw_preset_fits(AVFilterContext *ctx, int preset, int layers, int heads,
                           int multilingual, int mels)
{
    int n;
    const NMWhisperDtwPreset *want = nm_whisper_dtw_presets(&n) + preset;

    if (nm_whisper_dtw_preset_matches(preset, layers, heads, multilingual, mels))
        return 1;

    av_log(ctx, AV_LOG_ERROR,
           "dtw=%s does not match this model: it has %d text layers, %d heads, "
           "%s, %d mel bins, and %s was made for %d layers, %d heads, %s. "
           "Use the preset named after the model (ggml-base.en.bin is base.en).\n",
           want->name, layers, heads, multilingual ? "multilingual" : "English-only",
           mels, want->name, want->n_text_layer, want->n_text_head,
           want->multilingual ? "multilingual" : "English-only");
    return 0;
}

/**
 * Check the dtw preset against the model file's header, before any load.
 *
 * Returns 0 when it fits, or when the header cannot be read: a missing or
 * broken model is reported by the real load, with its own message. Returns
 * AVERROR(EINVAL) for a preset that does not fit.
 *
 * Done here, from 48 bytes of the file, rather than by letting whisper.cpp
 * load the model with the wrong preset: whisper.cpp then rejects it in
 * whisper_init_state(), and its cleanup frees a half-built state. That
 * crashed ffmpeg on Windows (exit 139) once the load moved off the main
 * thread (#114).
 */
static int check_dtw_preset_against_file(AVFilterContext *ctx)
{
    WhisperContext *wctx = ctx->priv;
    AVIOContext *pb = NULL;
    unsigned char head[48];
    NMWhisperModelShape shape;
    int got;

    if (avio_open(&pb, wctx->model_path, AVIO_FLAG_READ) < 0)
        return 0;
    got = avio_read(pb, head, sizeof(head));
    avio_closep(&pb);
    if (got != (int) sizeof(head) || nm_whisper_parse_model_header(head, sizeof(head), &shape) < 0)
        return 0;

    if (!dtw_preset_fits(ctx, wctx->dtw_preset, shape.n_text_layer, shape.n_text_head,
                         nm_whisper_model_multilingual(&shape), shape.n_mels))
        return AVERROR(EINVAL);
    return 0;
}

static int init(AVFilterContext *ctx)
{
    WhisperContext *wctx = ctx->priv;

    if (!wctx->model_path) {
        av_log(ctx, AV_LOG_ERROR, "No whisper model path specified. Use the 'model' option.\n");
        return AVERROR(EINVAL);
    }

    // The options that do not need the model are checked before loading it,
    // so a typo fails in milliseconds rather than after a model load.
    wctx->dtw_preset = -1;
    if (wctx->dtw && wctx->dtw[0]) {
        wctx->dtw_preset = nm_whisper_dtw_preset_find(wctx->dtw);
        if (wctx->dtw_preset < 0 || wctx->dtw_preset >= (int) FF_ARRAY_ELEMS(nm_whisper_dtw_aheads)) {
            av_log(ctx, AV_LOG_ERROR, "Unknown dtw preset '%s'. Valid presets: %s.\n",
                   wctx->dtw, nm_whisper_dtw_preset_list());
            return AVERROR(EINVAL);
        }
        int ret = check_dtw_preset_against_file(ctx);
        if (ret < 0)
            return ret;
    }

    if (wctx->word_timestamps && av_strcasecmp(wctx->format, "json")) {
        av_log(ctx, AV_LOG_WARNING,
               "word_timestamps only applies to format=json; ignored for format=%s.\n",
               wctx->format);
        wctx->word_timestamps = 0;
    }

    if (wctx->prompt_file && wctx->prompt_file[0]) {
        int ret = read_prompt_file(ctx);
        if (ret < 0)
            return ret;
        if (wctx->prompt && wctx->prompt[0])
            av_log(ctx, AV_LOG_WARNING, "Both prompt and prompt_file are set; using prompt_file.\n");
        wctx->initial_prompt = wctx->prompt_file_text;
    } else if (wctx->prompt && wctx->prompt[0])
        wctx->initial_prompt = wctx->prompt;

    wctx->next_pts = AV_NOPTS_VALUE;

    if (wctx->destination && strcmp("", wctx->destination)) {
        const char *dst = wctx->destination;
        if (!strcmp("-", dst))
            dst = "pipe:1";
        int ret = avio_open(&wctx->avio_context, dst, AVIO_FLAG_WRITE);

        if (ret < 0) {
            av_log(ctx, AV_LOG_ERROR, "Could not open %s: %s\n", wctx->destination, av_err2str(ret));
            return ret;
        }

        wctx->avio_context->direct = AVIO_FLAG_DIRECT;
    }

    return 0;
}

/**
 * Load the model, on the input link's configuration rather than in init().
 *
 * The ffmpeg CLI parses every filtergraph twice: fg_create() builds a
 * throwaway graph only to learn its inputs and outputs, and that runs each
 * filter's init() but is never configured. Loading here instead of in init()
 * means that graph never loads the model, which used to cost a whole second
 * load per run - about 2 s for large-v3 (#114). Everything that only checks
 * options stays in init(), so a typo still fails before any model I/O.
 *
 * The GPU decision, the log-callback registration and the backend report move
 * with the load: they belong to the whisper_init_*() call, not to init().
 */
static int config_input(AVFilterLink *inlink)
{
    AVFilterContext *ctx = inlink->dst;
    WhisperContext *wctx = ctx->priv;

    static AVOnce init_static_once = AV_ONCE_INIT;

    // A graph is configured once, but stay safe if a link is reconfigured.
    if (wctx->ctx_wsp)
        return 0;

    // Ask FIRST, before ggml_backend_load_all() or anything else can reach
    // ggml's backend registry. nm_ggml_gpu_usable()'s first call is what makes
    // this process safe to enumerate Vulkan in, and on a Linux box with Mesa
    // installed the loader segfaults inside its own driver probe - i.e. inside
    // the registry's constructor, which ggml_backend_load_all() triggers.
    //
    // On its OWN LINE, not as the right-hand side of `use_gpu && ...`. That is
    // what this was, and C short-circuits: with use_gpu=0 the guard never ran
    // and the very next line killed the process. Reproduced at exit 139 - on
    // the one option a user reaches for when a GPU is causing trouble.
    const int gpu_usable = nm_ggml_gpu_usable();

    wctx->gpu_active = wctx->use_gpu && gpu_usable;

    // An index past the last GPU is not an error: whisper.cpp counts GPU/IGPU
    // devices the same way and simply falls back to the CPU. Catching it here
    // means the log and the metadata say "cpu" instead of naming a device that
    // is not the one anything ran on.
    if (wctx->gpu_active && wctx->gpu_device >= nm_ggml_gpu_count()) {
        av_log(ctx, AV_LOG_WARNING,
               "whisper: gpu_device=%d but this machine has %d GPU device(s); "
               "running on the CPU.\n", wctx->gpu_device, nm_ggml_gpu_count());
        wctx->gpu_active = 0;
    }

    ff_thread_once(&init_static_once, ggml_backend_load_all);

    // Only ever non-NULL when the guard had to do something a user would want
    // to know about, such as disabling a driver.
    if (nm_ggml_backend_notice())
        av_log(ctx, AV_LOG_INFO, "whisper: %s.\n", nm_ggml_backend_notice());

    whisper_log_set(cb_log, ctx);
    nm_whisper_log_owner = ctx;


    struct whisper_context_params params = whisper_context_default_params();
    // whisper.cpp picks its own backend from this flag - it is never handed
    // one - so the decision has to be made here. nm_ggml_gpu_usable() refuses
    // software rasterisers, which whisper.cpp would otherwise happily select
    // (whisper_backend_init_gpu() takes the Nth GPU/IGPU device with no check
    // of its own) and which crash inside a static binary.
    params.use_gpu = wctx->gpu_active;
    params.gpu_device = wctx->gpu_device;

    // DTW token timestamps. flash_attn defaults to true in whisper.cpp, and
    // whisper_init_with_params_no_state() then switches DTW off again with
    // only a warning (whisper.cpp v1.9.1, src/whisper.cpp:3708). Turning DTW
    // on therefore has to turn flash attention off, or the option would be
    // accepted and do nothing.
    if (wctx->dtw_preset >= 0) {
        params.dtw_token_timestamps = true;
        params.dtw_aheads_preset = nm_whisper_dtw_aheads[wctx->dtw_preset];
        params.flash_attn = false;
    }

    // Cleared here, read immediately after the call below: that pair is what
    // makes the process-wide flag above safe to attribute to this filter.
    nm_whisper_saw_no_gpu = 0;
    wctx->ctx_wsp = whisper_init_from_file_with_params(wctx->model_path, params);
    if (wctx->ctx_wsp == NULL) {
        av_log(ctx, AV_LOG_ERROR, "Failed to initialize whisper context from model: %s\n", wctx->model_path);
        return AVERROR(EIO);
    }

    if (wctx->dtw_preset >= 0) {
        // init() already checked the file header; this is the same check on
        // what whisper.cpp actually loaded, for a header it could not read.
        if (!dtw_preset_fits(ctx, wctx->dtw_preset,
                             whisper_model_n_text_layer(wctx->ctx_wsp),
                             whisper_model_n_text_head(wctx->ctx_wsp),
                             whisper_is_multilingual(wctx->ctx_wsp),
                             whisper_model_n_mels(wctx->ctx_wsp)))
            return AVERROR(EINVAL);
        av_log(ctx, AV_LOG_INFO, "whisper: DTW on (preset %s); flash attention turned off.\n",
               nm_whisper_dtw_preset_name(wctx->dtw_preset));
    }

    // What whisper.cpp ACTUALLY got, which is not always what it was asked
    // for: whisper_backend_init_gpu() calls ggml_backend_dev_init() itself and
    // simply returns nullptr on failure, after which the whole context runs on
    // the CPU without telling its caller. There is no public accessor for the
    // chosen backend in whisper.h (checked, v1.9.1), so the only signal is the
    // log line it emits on that path, which cb_log above has already seen by
    // now - whisper_init_from_file_with_params() has returned.
    //
    // Deliberately one-directional: an observed failure clears the flag, and
    // the absence of any message leaves it alone. A string that upstream
    // renames therefore costs us a downgrade we failed to notice, never a
    // downgrade we invented. Snapshotted HERE, before the VAD context below
    // initialises, because whisper forces use_gpu=false for VAD and would emit
    // the same "no GPU found" line for a run that has nothing to do with this.
    if (wctx->gpu_active && nm_whisper_saw_no_gpu) {
        av_log(ctx, AV_LOG_WARNING,
               "whisper: whisper.cpp did not take the GPU after all; running on the CPU.\n");
        wctx->gpu_active = 0;
    }

    // ggml_backend_cpu_init() inside whisper.cpp resolves to the
    // instruction-set variant ggml_cpu_dispatch.c selected for this
    // machine; report it once so the media server can tell what actually
    // ran without scraping logs.
    av_log(ctx, AV_LOG_INFO, "whisper: ggml cpu variant '%s'.\n",
           nm_ggml_cpu_variant_name());
    av_log(ctx, AV_LOG_INFO, "whisper: ggml backend '%s' (%s).\n",
           wctx->gpu_active ? nm_ggml_backend_name(wctx->gpu_device) : "cpu",
           wctx->gpu_active ? nm_ggml_backend_device(wctx->gpu_device)
                            : nm_ggml_cpu_variant_name());

    wctx->n_threads = nm_whisper_threads(ctx);
    av_log(ctx, AV_LOG_INFO, "whisper: %d threads.\n", wctx->n_threads);

    // Init buffer
    wctx->audio_buffer_queue_size = av_rescale(wctx->queue, WHISPER_SAMPLE_RATE, AV_TIME_BASE);
    wctx->audio_buffer = av_malloc_array(wctx->audio_buffer_queue_size, sizeof(*wctx->audio_buffer));
    if (!wctx->audio_buffer)
        return AVERROR(ENOMEM);

    // Init VAD model context
    if (wctx->vad_model_path) {
        struct whisper_vad_context_params ctx_params = whisper_vad_default_context_params();
        // At most whisper.cpp's own VAD default (4 in v1.9.1), never every
        // logical core. Silero is a tiny LSTM evaluated as one small ggml graph
        // per 512-sample chunk; with 16 threads the synchronisation dwarfs the
        // work, and 15 s of audio took over five minutes instead of 7 s (#115).
        // Fewer threads only when the user asked for fewer with -filter_threads.
        // The VAD result does not depend on the thread count.
        ctx_params.n_threads = FFMIN(ctx_params.n_threads, wctx->n_threads);
        // ctx_params.use_gpu = wctx->use_gpu; TODO (see: whisper_vad_init_context)
        ctx_params.gpu_device = wctx->gpu_device;
        wctx->ctx_vad = whisper_vad_init_from_file_with_params(wctx->vad_model_path, ctx_params);

        wctx->vad_params = whisper_vad_default_params();
        wctx->vad_params.threshold = wctx->vad_threshold;
        wctx->vad_params.min_speech_duration_ms = av_rescale(wctx->vad_min_speech_duration, 1000, AV_TIME_BASE);
        wctx->vad_params.min_silence_duration_ms = av_rescale(wctx->vad_min_silence_duration, 1000, AV_TIME_BASE);
        wctx->vad_params.max_speech_duration_s = av_rescale(wctx->queue, 1, AV_TIME_BASE);
        wctx->vad_params.speech_pad_ms = 0;
        wctx->vad_params.samples_overlap = 0;
    }

    if (!whisper_is_multilingual(wctx->ctx_wsp)) {
        if (!wctx->translate && strcmp(wctx->language_str, "auto") == 0) {
            av_log(ctx, AV_LOG_WARNING,
                   "Multilingual model not provided. Non-English audio may not be correctly transcribed.\n");
        } else if (wctx->translate || (strcmp(wctx->language_str, "auto") != 0 && strcmp(wctx->language_str, "en") != 0)) {
            av_log(ctx, AV_LOG_ERROR,
                   "%s requested but multilingual model not provided.\n", wctx->translate ? "Translation" : "Transcription");
            return AVERROR(ENOSYS);
        }
        wctx->language = "en";
    } else
        wctx->language = wctx->language_str;

    av_log(ctx, AV_LOG_INFO,
           "Whisper filter initialized: model: %s lang: %s queue: %" PRId64 " ms\n",
           wctx->model_path, wctx->language, wctx->queue / 1000);

    return 0;
}

static void uninit(AVFilterContext *ctx)
{
    WhisperContext *wctx = ctx->priv;

    if (wctx->audio_buffer_fill_size > 0) {
        av_log(ctx, AV_LOG_WARNING,
               "Remaining audio buffer %d samples (%d seconds) after stopping\n",
               wctx->audio_buffer_fill_size, wctx->audio_buffer_fill_size / WHISPER_SAMPLE_RATE);
    }

    if (wctx->ctx_vad) {
        whisper_vad_free(wctx->ctx_vad);
        wctx->ctx_vad = NULL;
    }

    if (wctx->ctx_wsp) {
        whisper_free(wctx->ctx_wsp);
        wctx->ctx_wsp = NULL;
    }

    av_freep(&wctx->audio_buffer);
    av_freep(&wctx->prompt_file_text);
    wctx->initial_prompt = NULL;

    if (wctx->avio_context)
        avio_closep(&wctx->avio_context);

    // whisper_log_set() is process-global, not per-context: init() registered
    // cb_log with THIS ctx as its user_data. Leaving that registration in place
    // means any whisper call anywhere in the process after this AVFilterContext
    // is freed - including from another whisper or stemsplit instance still
    // running in the same filtergraph, which this media server routinely does -
    // invokes cb_log with a dangling AVFilterContext* and writes through it via
    // av_log(): a use-after-free. af_stemsplit.c's uninit does exactly this for
    // ggml_log_set and says why at length; this is the same hazard, and this
    // filter was missing the same guard. Restore whisper's default sink: if
    // another instance is still live its messages fall back to whisper's own
    // logging rather than being routed through freed memory, and degraded
    // logging beats a crash. Do not remove this.
    //
    // Only when we are still the owner, though: with two whisper filters in a
    // graph the second one's init took the registration over, and resetting it
    // from the first one's teardown would push that live filter's messages to
    // stderr, around -loglevel, for no benefit. The dangling pointer we are
    // avoiding is only ours to avoid while the callback still points at us.
    if (nm_whisper_log_owner == ctx) {
        whisper_log_set(NULL, NULL);
        nm_whisper_log_owner = NULL;
    }
}

// Resolve the spoken language once, on the first transcription window that
// produced actual speech. With an explicit 'language' option the configured
// value is reported with confidence 1.0; with 'auto' the detection reuses the
// mel spectrogram of the whisper_full() call that produced the current window,
// costing one extra encoder pass exactly once per filter instance.
static void resolve_language(AVFilterContext *ctx)
{
    WhisperContext *wctx = ctx->priv;

    if (wctx->detected_language)
        return;

    if (wctx->language && wctx->language[0] && strcmp(wctx->language, "auto")) {
        wctx->detected_language = wctx->language;
        wctx->language_confidence = 1.0f;
    } else if (!whisper_is_multilingual(wctx->ctx_wsp)) {
        // English-only models cannot auto-detect; whisper transcribes as English
        wctx->detected_language = "en";
        wctx->language_confidence = 1.0f;
    } else {
        const int max_id = whisper_lang_max_id();
        float *lang_probs = av_calloc(max_id + 1, sizeof(*lang_probs));
        int lang_id;

        if (!lang_probs)
            return;

        lang_id = whisper_lang_auto_detect(wctx->ctx_wsp, 0, wctx->n_threads, lang_probs);
        if (lang_id >= 0 && lang_id <= max_id) {
            wctx->detected_language = whisper_lang_str(lang_id);
            wctx->language_confidence = lang_probs[lang_id];
        }
        av_freep(&lang_probs);

        if (!wctx->detected_language)
            return;
    }

    av_log(ctx, AV_LOG_INFO, "detected language: %s (confidence: %.6f)\n",
           wctx->detected_language, wctx->language_confidence);

    if (wctx->avio_context && !av_strcasecmp(wctx->format, "json")) {
        char *lang_json = nm_json_escape(wctx->detected_language);
        char *buf = lang_json
            ? av_asprintf("{\"detected_language\":\"%s\",\"language_confidence\":%.6f}\n",
                          lang_json, wctx->language_confidence)
            : NULL;
        av_freep(&lang_json);
        if (buf) {
            avio_write(wctx->avio_context, buf, strlen(buf));
            av_freep(&buf);
        }
    }
}

/**
 * Drop the first `samples` from the audio buffer and move the rest to the
 * front.
 *
 * This used memcpy, and source and destination are the same buffer: they
 * overlap as soon as more than half of it is kept (fill > 2 * samples).
 * Overlapping memcpy is undefined behaviour. It mostly works because glibc
 * happens to copy forwards, and silently corrupts the buffer on any
 * implementation that copies in blocks or backwards. memmove is defined for
 * exactly this.
 */
static void consume_buffer(WhisperContext *wctx, int samples)
{
    const float duration = (float) samples / WHISPER_SAMPLE_RATE;

    if (wctx->audio_buffer_fill_size > samples) {
        memmove(wctx->audio_buffer, wctx->audio_buffer + samples,
                (wctx->audio_buffer_fill_size - samples) * sizeof(*wctx->audio_buffer));
        wctx->audio_buffer_start_ms += duration * 1000;
    }
    wctx->audio_buffer_fill_size -= samples;
    wctx->audio_buffer_vad_size = wctx->audio_buffer_fill_size;
}

/**
 * The "words" array for segment i of the last whisper_full() call, built by
 * nm_whisper_build_words() from the segment's tokens. offset_ms is where the
 * whisper_full() window started; seg_start/seg_end are the segment's absolute
 * times as written in its JSON line. Returns NULL when allocation fails.
 */
static char *segment_words_json(AVFilterContext *ctx, int i, int64_t offset_ms,
                                int64_t seg_start, int64_t seg_end)
{
    WhisperContext *wctx = ctx->priv;
    const whisper_token eot = whisper_token_eot(wctx->ctx_wsp);
    const int n_tok = whisper_full_n_tokens(wctx->ctx_wsp, i);
    NMWhisperToken *tok = NULL;
    NMWhisperWord *words = NULL;
    int n_words = 0;
    char *json = NULL;

    if (n_tok > 0) {
        tok = av_malloc_array(n_tok, sizeof(*tok));
        if (!tok)
            return NULL;
    }
    for (int j = 0; j < n_tok; j++) {
        const whisper_token_data data = whisper_full_get_token_data(wctx->ctx_wsp, i, j);
        tok[j].text = whisper_full_get_token_text(wctx->ctx_wsp, i, j);
        tok[j].special = data.id >= eot;
        tok[j].t0 = data.t0;
        tok[j].t_dtw = data.t_dtw;
        tok[j].p = data.p;
    }

    if (nm_whisper_build_words(tok, n_tok, offset_ms, seg_start, seg_end,
                               wctx->dtw_preset >= 0, &words, &n_words) >= 0) {
        json = nm_whisper_words_json(words, n_words);
        nm_whisper_free_words(words, n_words);
    }
    av_free(tok);
    return json;
}

static void run_transcription(AVFilterContext *ctx, AVFrame *frame, int samples)
{
    WhisperContext *wctx = ctx->priv;
    samples = FFMAX(0, FFMIN(samples, wctx->audio_buffer_fill_size));

    if (!wctx->ctx_wsp || samples == 0)
        return;

    const int64_t timestamp_ms = wctx->audio_buffer_start_ms;
    const float duration = (float) samples / WHISPER_SAMPLE_RATE;

    av_log(ctx, AV_LOG_INFO,
           "run transcription at %" PRId64 " ms, %d/%d samples (%.2f seconds)...\n",
           timestamp_ms, samples, wctx->audio_buffer_fill_size, duration);

    struct whisper_full_params params = whisper_full_default_params(
        wctx->beam_size > 0 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
    params.language = wctx->language;
    params.translate = wctx->translate;
    params.n_threads = wctx->n_threads;
    params.print_special = 0;
    params.print_progress = 0;
    params.print_realtime = 0;
    params.print_timestamps = 0;
    params.max_len = wctx->max_len;
    params.token_timestamps = (wctx->max_len > 0) || wctx->word_timestamps;
    params.split_on_word = (wctx->max_len > 0);
    params.initial_prompt = wctx->initial_prompt;
    if (wctx->beam_size > 0) {
        params.beam_search.beam_size = wctx->beam_size;
        // The beam-search defaults leave greedy.best_of at -1, which makes the
        // temperature fallback decode with a single candidate. whisper-cli
        // always passes the greedy default (5) along with a beam size; do the
        // same, so beam_size=N here means what --beam-size N means there.
        params.greedy.best_of = whisper_full_default_params(WHISPER_SAMPLING_GREEDY).greedy.best_of;
    }
    if (wctx->best_of > 0)
        params.greedy.best_of = wctx->best_of;

    if (whisper_full(wctx->ctx_wsp, params, wctx->audio_buffer, samples) != 0) {
        av_log(ctx, AV_LOG_ERROR, "Failed to process audio with whisper.cpp\n");
        /* Drain the failed window anyway. This used to return with the
         * buffer untouched, and filter_frame calls this function precisely to
         * make room: it then appended the next frame to a buffer that was
         * still full and wrote past the end of the allocation. Dropping the
         * audio is the only option that does not overflow, and it also stops
         * the same window being retried forever. */
        consume_buffer(wctx, samples);
        return;
    }

    const int n_segments = whisper_full_n_segments(wctx->ctx_wsp);
    char *segments_text = NULL;

    for (int i = 0; i < n_segments; ++i) {
        const char *text = whisper_full_get_segment_text(wctx->ctx_wsp, i);
        if (av_isspace(text[0]))
            text++;
        char *text_cleaned = av_strireplace(text, "[BLANK_AUDIO]", "");

        if (av_strnlen(text_cleaned, 1) == 0) {
            av_freep(&text_cleaned);
            continue;
        }

        // Skip segments that are parts of [BLANK_AUDIO] when max_len splits them
        if (wctx->max_len > 0 && (strcmp(text_cleaned, "[") == 0 || strcmp(text_cleaned, "]") == 0 ||
                                  strcmp(text_cleaned, "BLANK") == 0 || strcmp(text_cleaned, "_") == 0 ||
                                  strcmp(text_cleaned, "AUDIO") == 0)) {
            av_freep(&text_cleaned);
            continue;
        }

        // Real speech in this window: resolve the language before the first
        // segment is written so a JSON destination gets a leading detection
        // object. No-op once resolved; never reached for blank-only windows.
        resolve_language(ctx);

        const bool turn = whisper_full_get_segment_speaker_turn_next(wctx->ctx_wsp, i);
        const int64_t t0_ms = whisper_full_get_segment_t0(wctx->ctx_wsp, i) * 10;
        const int64_t t1_ms = whisper_full_get_segment_t1(wctx->ctx_wsp, i) * 10;

        av_log(ctx, AV_LOG_DEBUG, "  [%" PRId64 "-%" PRId64 "%s]: \"%s\"\n",
               timestamp_ms + t0_ms, timestamp_ms + t1_ms, turn ? " (turn)" : "", text_cleaned);

        if (segments_text) {
            char *new_text = av_asprintf("%s%s", segments_text, text_cleaned);
            av_freep(&segments_text);
            segments_text = new_text;
        } else
            segments_text = av_strdup(text_cleaned);

        if (wctx->avio_context) {
            const int64_t start_t = timestamp_ms + t0_ms;
            const int64_t end_t = timestamp_ms + t1_ms;
            char *buf = NULL;

            if (!av_strcasecmp(wctx->format, "srt")) {
                buf =
                    av_asprintf
                    ("%d\n%02" PRId64 ":%02" PRId64 ":%02" PRId64 ",%03" PRId64 " --> %02" PRId64 ":%02" PRId64 ":%02" PRId64 ",%03" PRId64 "\n%s\n\n",
                     wctx->index, start_t / 3600000,
                     (start_t / 60000) % 60, (start_t / 1000) % 60,
                     start_t % 1000, end_t / 3600000, (end_t / 60000) % 60,
                     (end_t / 1000) % 60, end_t % 1000, text_cleaned);

                wctx->index++;
            } else if (!av_strcasecmp(wctx->format, "json")) {
                char *text_json = nm_json_escape(text_cleaned);
                if (text_json && wctx->word_timestamps) {
                    char *words_json = segment_words_json(ctx, i, timestamp_ms, start_t, end_t);
                    if (words_json)
                        buf = av_asprintf("{\"start\":%" PRId64 ",\"end\":%" PRId64
                                          ",\"text\":\"%s\",\"words\":%s}\n",
                                          start_t, end_t, text_json, words_json);
                    av_freep(&words_json);
                } else if (text_json)
                    buf = av_asprintf("{\"start\":%" PRId64 ",\"end\":%" PRId64 ",\"text\":\"%s\"}\n",
                                      start_t, end_t, text_json);
                av_freep(&text_json);
            } else
                buf = av_asprintf("%s\n", text_cleaned);

            if (buf) {
                avio_write(wctx->avio_context, buf, strlen(buf));
                av_freep(&buf);
            }
        }

        av_freep(&text_cleaned);
    }

    AVDictionary **metadata = &frame->metadata;
    if (metadata && segments_text) {
        av_dict_set(metadata, "lavfi.whisper.text", segments_text, 0);
        char *duration_text = av_asprintf("%f", duration);
        av_dict_set(metadata, "lavfi.whisper.duration", duration_text, AV_DICT_DONT_STRDUP_VAL);
        av_dict_set(metadata, "lavfi.whisper.cpu_variant",
                    nm_ggml_cpu_variant_name(), 0);
        // Deliberately outside the language branch below, and keyed off
        // gpu_active rather than use_gpu: this reports what ran, not what was
        // asked for.
        av_dict_set(metadata, "lavfi.whisper.backend",
                    wctx->gpu_active ? nm_ggml_backend_name(wctx->gpu_device) : "cpu", 0);
        if (wctx->detected_language) {
            av_dict_set(metadata, "lavfi.whisper.language", wctx->detected_language, 0);
            char *confidence_text = av_asprintf("%f", wctx->language_confidence);
            av_dict_set(metadata, "lavfi.whisper.language_confidence", confidence_text, AV_DICT_DONT_STRDUP_VAL);
        }
    }
    av_freep(&segments_text);

    consume_buffer(wctx, samples);
}

static int filter_frame(AVFilterLink *inlink, AVFrame *frame)
{
    AVFilterContext *ctx = inlink->dst;
    WhisperContext *wctx = ctx->priv;
    AVFilterLink *outlink = ctx->outputs[0];

    const int samples = frame->nb_samples;
    const float *input_data = (const float *) frame->data[0];
    int copy = samples;
    int skipped = 0;

    if (wctx->audio_buffer_fill_size + samples > wctx->audio_buffer_queue_size) {
        run_transcription(ctx, frame, wctx->audio_buffer_fill_size);
    }

    /* The append below writes into an allocation of exactly
     * audio_buffer_queue_size floats, and nothing checked that it fit. Two
     * ways it did not, both of which wrote past the end of the heap buffer:
     *
     *  - run_transcription could not drain. Since it now drains even when
     *    whisper_full fails, that is down to a missing context; the buffered
     *    audio cannot be transcribed then, so it is dropped.
     *
     *  - this frame alone is bigger than the whole queue. queue= accepts
     *    values down to 20 ms, which is 320 samples at 16 kHz, and an
     *    ordinary audio frame is 1024 or more -- so queue=0.02 on a normal
     *    input was enough to overflow. The newest queue_size samples are
     *    kept, and the start time moves forward by what was skipped.
     *
     * After this, fill + copy <= audio_buffer_queue_size always holds. */
    if (wctx->audio_buffer_fill_size + copy > wctx->audio_buffer_queue_size) {
        if (wctx->audio_buffer_fill_size) {
            av_log(ctx, AV_LOG_WARNING,
                   "dropping %d buffered samples that could not be transcribed\n",
                   wctx->audio_buffer_fill_size);
            wctx->audio_buffer_fill_size = 0;
            wctx->audio_buffer_vad_size  = 0;
        }
        if (copy > wctx->audio_buffer_queue_size) {
            skipped = copy - wctx->audio_buffer_queue_size;
            copy    = wctx->audio_buffer_queue_size;
            av_log(ctx, AV_LOG_WARNING,
                   "frame of %d samples is larger than the %d-sample queue; "
                   "keeping the last %d. Raise queue= to avoid this.\n",
                   samples, wctx->audio_buffer_queue_size, copy);
        }
    }

    if (!wctx->audio_buffer_fill_size)
        wctx->audio_buffer_start_ms = av_rescale_q(frame->pts,
                                                   (AVRational) {1000, 1},
                                                   (AVRational) {inlink->time_base.den, inlink->time_base.num})
                                    + av_rescale(skipped, 1000, WHISPER_SAMPLE_RATE);
    memcpy(wctx->audio_buffer + wctx->audio_buffer_fill_size, input_data + skipped,
           copy * sizeof(*wctx->audio_buffer));
    wctx->audio_buffer_fill_size += copy;

    if (wctx->ctx_vad
        && (wctx->audio_buffer_fill_size - wctx->audio_buffer_vad_size) >=
        av_rescale(wctx->vad_min_speech_duration + wctx->vad_min_silence_duration, WHISPER_SAMPLE_RATE, AV_TIME_BASE)) {
        struct whisper_vad_segments *segments = whisper_vad_segments_from_samples(wctx->ctx_vad,
                                                                                  wctx->vad_params,
                                                                                  wctx->audio_buffer,
                                                                                  wctx->audio_buffer_fill_size);
        wctx->audio_buffer_vad_size = wctx->audio_buffer_fill_size;

        if (!segments) {
            av_log(ctx, AV_LOG_ERROR, "failed to detect VAD\n");
        } else {
            int n_segments = whisper_vad_segments_n_segments(segments);

            if (n_segments > 0) {
                const float start_ms = whisper_vad_segments_get_segment_t0(segments, 0) * 10.0;
                const float end_ms = whisper_vad_segments_get_segment_t1(segments, n_segments - 1) * 10.0;
                int end_pos = (int) (end_ms * WHISPER_SAMPLE_RATE / 1000);

                if (end_pos <= wctx->audio_buffer_fill_size -
                    av_rescale(wctx->vad_min_silence_duration, WHISPER_SAMPLE_RATE, AV_TIME_BASE)) {
                    av_log(ctx, AV_LOG_INFO,
                            "VAD detected %d segments, start: %.0f ms, end: %.0f ms (buffer: %d ms)\n",
                            n_segments, start_ms, end_ms, 1000 * wctx->audio_buffer_fill_size / WHISPER_SAMPLE_RATE);
                    run_transcription(ctx, frame, end_pos);
                }
            }

            whisper_vad_free_segments(segments);
        }
    } else if (wctx->audio_buffer_fill_size >= wctx->audio_buffer_queue_size)
        run_transcription(ctx, frame, wctx->audio_buffer_fill_size);

    wctx->next_pts = frame->pts + av_rescale_q(samples, (AVRational) {
                                               1, inlink->sample_rate}
                                               , inlink->time_base);
    return ff_filter_frame(outlink, frame);
}

static int push_last_frame(AVFilterLink *outlink)
{
    AVFilterContext *ctx = outlink->src;
    WhisperContext *wctx = ctx->priv;
    AVFrame *frame;
    int n_out = 1;

    if (ctx->is_disabled || wctx->audio_buffer_fill_size == 0)
        return 0;
    frame = ff_get_audio_buffer(outlink, n_out);
    if (!frame)
        return AVERROR(ENOMEM);

    av_samples_set_silence(frame->extended_data, 0, n_out, frame->ch_layout.nb_channels, frame->format);

    frame->pts = wctx->next_pts;
    if (wctx->next_pts != AV_NOPTS_VALUE)
        wctx->next_pts += av_rescale_q(n_out, (AVRational) {
                                       1, outlink->sample_rate}
                                       , outlink->time_base);

    run_transcription(ctx, frame, wctx->audio_buffer_fill_size);

    return ff_filter_frame(outlink, frame);
}

static int activate(AVFilterContext *ctx)
{
    AVFilterLink *inlink = ctx->inputs[0];
    AVFilterLink *outlink = ctx->outputs[0];
    WhisperContext *wctx = ctx->priv;
    int64_t pts;
    int status;

    FF_FILTER_FORWARD_STATUS_BACK(outlink, inlink);

    if (!wctx->eof && ff_inlink_queued_frames(inlink)) {
        AVFrame *frame = NULL;
        int ret;

        ret = ff_inlink_consume_frame(inlink, &frame);
        if (ret < 0)
            return ret;
        if (ret > 0)
            return filter_frame(inlink, frame);
    }

    if (!wctx->eof && ff_inlink_acknowledge_status(inlink, &status, &pts))
        wctx->eof = status == AVERROR_EOF;

    if (wctx->eof) {
        push_last_frame(outlink);

        ff_outlink_set_status(outlink, AVERROR_EOF, wctx->next_pts);
        return 0;
    }

    FF_FILTER_FORWARD_WANTED(outlink, inlink);

    return FFERROR_NOT_READY;
}

static int query_formats(const AVFilterContext *ctx,
                         AVFilterFormatsConfig **cfg_in,
                         AVFilterFormatsConfig **cfg_out)
{
    static const enum AVSampleFormat sample_fmts[] = { AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_NONE };
    AVChannelLayout chlayouts[] = { FF_COUNT2LAYOUT(1), { 0 } };
    int sample_rates[] = { WHISPER_SAMPLE_RATE, -1 };
    int ret;

    ret = ff_set_sample_formats_from_list2(ctx, cfg_in, cfg_out, sample_fmts);
    if (ret < 0)
        return ret;

    ret = ff_set_common_channel_layouts_from_list2(ctx, cfg_in, cfg_out, chlayouts);
    if (ret < 0)
        return ret;

    return ff_set_common_samplerates_from_list2(ctx, cfg_in, cfg_out, sample_rates);
}

#define OFFSET(x) offsetof(WhisperContext, x)
#define FLAGS AV_OPT_FLAG_AUDIO_PARAM | AV_OPT_FLAG_FILTERING_PARAM
#define HOURS 3600000000

static const AVOption whisper_options[] = {
    { "model", "Path to the whisper.cpp model file", OFFSET(model_path), AV_OPT_TYPE_STRING,.flags = FLAGS },
    { "language", "Language for transcription ('auto' for auto-detect)", OFFSET(language_str), AV_OPT_TYPE_STRING, {.str = "auto"}, .flags = FLAGS },
    { "translate", "Translate from source language to English", OFFSET(translate), AV_OPT_TYPE_BOOL, {.i64 = 0}, 0, 1, .flags = FLAGS },
    { "queue", "Audio queue size", OFFSET(queue), AV_OPT_TYPE_DURATION, {.i64 = 3000000}, 20000, HOURS, .flags = FLAGS },
    { "use_gpu", "Use GPU for processing", OFFSET(use_gpu), AV_OPT_TYPE_BOOL, {.i64 = 1}, 0, 1, .flags = FLAGS },
    { "gpu_device", "GPU device to use", OFFSET(gpu_device), AV_OPT_TYPE_INT, {.i64 = 0}, 0, INT_MAX, .flags = FLAGS },
    { "destination", "Output destination", OFFSET(destination), AV_OPT_TYPE_STRING, {.str = ""}, .flags = FLAGS },
    { "format", "Output format (text|srt|json)", OFFSET(format), AV_OPT_TYPE_STRING, {.str = "text"},.flags = FLAGS },
    { "max_len", "Max segment length in characters", OFFSET(max_len), AV_OPT_TYPE_INT, {.i64 = 0}, 0, INT_MAX, .flags = FLAGS },
    { "vad_model", "Path to the VAD model file", OFFSET(vad_model_path), AV_OPT_TYPE_STRING,.flags = FLAGS },
    { "vad_threshold", "VAD threshold", OFFSET(vad_threshold), AV_OPT_TYPE_FLOAT, {.dbl = 0.5}, 0.0, 1.0, .flags = FLAGS },
    { "vad_min_speech_duration", "Minimum speech duration for VAD", OFFSET(vad_min_speech_duration), AV_OPT_TYPE_DURATION, {.i64 = 100000}, 20000, HOURS, .flags = FLAGS },
    { "vad_min_silence_duration", "Minimum silence duration for VAD", OFFSET(vad_min_silence_duration), AV_OPT_TYPE_DURATION, {.i64 = 500000}, 0, HOURS, .flags = FLAGS },
    { "dtw", "DTW token timestamps with this alignment-heads preset (tiny, tiny.en, base, base.en, small, small.en, medium, medium.en, large.v1, large.v2, large.v3, large.v3.turbo); turns flash attention off", OFFSET(dtw), AV_OPT_TYPE_STRING, {.str = ""}, .flags = FLAGS },
    { "word_timestamps", "Add a per-word 'words' array to each format=json segment", OFFSET(word_timestamps), AV_OPT_TYPE_BOOL, {.i64 = 0}, 0, 1, .flags = FLAGS },
    { "prompt", "Initial prompt for whisper (only its last ~223 tokens are used)", OFFSET(prompt), AV_OPT_TYPE_STRING, {.str = ""}, .flags = FLAGS },
    { "prompt_file", "Read the initial prompt from this UTF-8 file; wins over prompt", OFFSET(prompt_file), AV_OPT_TYPE_STRING, {.str = ""}, .flags = FLAGS },
    { "beam_size", "Beam search with this beam size (0 = greedy decoding)", OFFSET(beam_size), AV_OPT_TYPE_INT, {.i64 = 0}, 0, NM_WHISPER_MAX_DECODERS, .flags = FLAGS },
    { "best_of", "Candidates for greedy decoding and the temperature fallback (0 = library default)", OFFSET(best_of), AV_OPT_TYPE_INT, {.i64 = 0}, 0, NM_WHISPER_MAX_DECODERS, .flags = FLAGS },
    { NULL }
};

static const AVClass whisper_class = {
    .class_name = "whisper",
    .item_name = av_default_item_name,
    .option = whisper_options,
    .version = LIBAVUTIL_VERSION_INT,
};

static const AVFilterPad whisper_inputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_AUDIO,
        .config_props = config_input,
    },
};

const FFFilter ff_af_whisper = {
    .p.name = "whisper",
    .p.description = NULL_IF_CONFIG_SMALL("Transcribe audio using whisper.cpp."),
    .p.priv_class = &whisper_class,
    .p.flags = AVFILTER_FLAG_METADATA_ONLY,
    .init = init,
    .uninit = uninit,
    .activate = activate,
    .priv_size = sizeof(WhisperContext),
    FILTER_INPUTS(whisper_inputs),
    FILTER_OUTPUTS(ff_audio_default_filterpad),
    FILTER_QUERY_FUNC2(query_formats),
};

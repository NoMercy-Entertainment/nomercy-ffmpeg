/*
 * Copyright (c) 2026
 *
 * Trailing-silence detection filter for FFmpeg.
 *
 * Reports where a stream's audible content ends, so a caller can store the
 * point and cut there later with -to. This filter never modifies audio and
 * never cuts anything itself.
 *
 * The answer only exists at end of stream, so the filter holds one frame
 * back and attaches the result to it once EOF arrives.
 */

#include <errno.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "libavformat/avio.h"
#include "libavutil/avstring.h"
#include "libavutil/channel_layout.h"
#include "libavutil/macros.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"

#include "audio.h"
#include "avfilter.h"
#include "filters.h"

typedef struct TrailingSilenceContext {
    const AVClass *class;

    /* options */
    double   noise;                 /* linear amplitude threshold */
    int64_t  duration;              /* AV_TIME_BASE */
    int64_t  min_stream_duration;   /* AV_TIME_BASE */
    int64_t  safety_margin;         /* AV_TIME_BASE */
    char    *destination;
    char    *format;

    /* state */
    AVIOContext *report;            /* open temp file, NULL when disabled/published */
    char    *tmp_path;              /* "<destination>.part" */
    AVFrame *held;                  /* the one delayed frame */
    int64_t  nb_samples;            /* samples seen, the fallback clock */
    int      sample_rate;
    int64_t  silent_run_start;      /* sample index, -1 when no run is open */
    int      reported;
} TrailingSilenceContext;

#define OFFSET(x) offsetof(TrailingSilenceContext, x)
#define FLAGS AV_OPT_FLAG_AUDIO_PARAM | AV_OPT_FLAG_FILTERING_PARAM

static const AVOption trailingsilence_options[] = {
    { "noise", "silence threshold, in dB or as a linear amplitude",
      OFFSET(noise), AV_OPT_TYPE_DOUBLE, {.dbl = 0.00316227766}, 0, DBL_MAX, FLAGS },
    { "n", "alias for noise",
      OFFSET(noise), AV_OPT_TYPE_DOUBLE, {.dbl = 0.00316227766}, 0, DBL_MAX, FLAGS },
    { "duration", "minimum length of the trailing silence",
      OFFSET(duration), AV_OPT_TYPE_DURATION, {.i64 = 2000000}, 0, INT64_MAX, FLAGS },
    { "d", "alias for duration",
      OFFSET(duration), AV_OPT_TYPE_DURATION, {.i64 = 2000000}, 0, INT64_MAX, FLAGS },
    { "min_stream_duration", "skip streams shorter than this",
      OFFSET(min_stream_duration), AV_OPT_TYPE_DURATION, {.i64 = 10000000}, 0, INT64_MAX, FLAGS },
    { "safety_margin", "how far after silence_start the advice sits",
      OFFSET(safety_margin), AV_OPT_TYPE_DURATION, {.i64 = 250000}, 0, INT64_MAX, FLAGS },
    { "destination", "path for the JSON report; empty disables it",
      OFFSET(destination), AV_OPT_TYPE_STRING, {.str = ""}, .flags = FLAGS },
    { "format", "report format",
      OFFSET(format), AV_OPT_TYPE_STRING, {.str = "json"}, .flags = FLAGS },
    { NULL }
};

AVFILTER_DEFINE_CLASS(trailingsilence);

/* Both the report format and the report path are caller configuration, and
 * both used to fail at end of stream: one log line, no file written, and
 * ffmpeg still exiting 0. A media server that asked for a report then could
 * not tell "scanned, found nothing" from "the filter never ran" -- the exact
 * ambiguity this filter exists to remove, and the same reason every metadata
 * key is emitted even when detected=0.
 *
 * Validating here moves both failures to filter-graph setup, before a single
 * frame is decoded. A bad report path therefore now refuses to start the run
 * rather than wasting it: failing before any work is done is a different
 * thing from throwing completed work away, and it is the loud failure the
 * caller needs.
 *
 * What is opened here is "<destination>.part", not destination itself, and
 * finalize_report renames it into place once the content is complete. Opening
 * destination directly cost the caller two things that only show up on a real
 * server:
 *
 *   - AVIO_FLAG_WRITE truncates on open, so starting a re-probe destroyed the
 *     previous good report immediately -- before knowing whether this run
 *     would produce a better one, or produce one at all. That is data loss,
 *     not untidiness.
 *   - The content is only known at end of stream, so destination sat at zero
 *     bytes for the whole transcode. A consumer polling it found an
 *     unparseable file rather than an absence it could reason about, which is
 *     the same ambiguity this filter exists to remove.
 *
 * With the temp path, destination appears exactly once, complete, and an
 * unfinished or fruitless run leaves whatever was there before untouched. */
static av_cold int init(AVFilterContext *ctx)
{
    TrailingSilenceContext *s = ctx->priv;
    int ret;

    if (av_strcasecmp(s->format, "json")) {
        av_log(ctx, AV_LOG_ERROR,
               "trailingsilence: unknown format '%s'; only 'json' is supported.\n",
               s->format);
        return AVERROR(EINVAL);
    }

    if (s->destination && *s->destination) {
        s->tmp_path = av_asprintf("%s.part", s->destination);
        if (!s->tmp_path)
            return AVERROR(ENOMEM);

        ret = avio_open(&s->report, s->tmp_path, AVIO_FLAG_WRITE);
        if (ret < 0) {
            av_log(ctx, AV_LOG_ERROR, "trailingsilence: could not open %s: %s\n",
                   s->tmp_path, av_err2str(ret));
            return ret;
        }
    }

    return 0;
}

static int config_input(AVFilterLink *inlink)
{
    TrailingSilenceContext *s = inlink->dst->priv;

    s->sample_rate      = inlink->sample_rate;
    s->silent_run_start = -1;
    return 0;
}

/* A sample position is silent when every channel is below the threshold, so
 * the per-position test is the max across channels. Scanning per sample
 * rather than per frame puts silence_start on the real sample instead of a
 * frame boundary -- at 1024 samples that is the difference between ~21 ms of
 * slop and none, and this value is what the caller will cut on. */
static void scan_frame(TrailingSilenceContext *s, const AVFrame *frame)
{
    const int nb_ch = frame->ch_layout.nb_channels;

    for (int i = 0; i < frame->nb_samples; i++) {
        float peak = 0.f;

        for (int c = 0; c < nb_ch; c++) {
            const float v = fabsf(((const float *)frame->extended_data[c])[i]);
            if (v > peak)
                peak = v;
        }

        if (peak > s->noise)
            s->silent_run_start = -1;                 /* audible: close any run */
        else if (s->silent_run_start < 0)
            s->silent_run_start = s->nb_samples + i;  /* a new run opens here */
    }

    s->nb_samples += frame->nb_samples;
}

static void write_report(AVFilterContext *ctx, int detected,
                         double silence_start, double silence_duration,
                         double stream_duration, double recommended_end,
                         double margin)
{
    TrailingSilenceContext *s = ctx->priv;
    char buf[512];

    /* init() already validated the format and opened the file, so the only
     * question left here is whether a report was asked for at all. */
    if (!s->report)
        return;

    snprintf(buf, sizeof(buf),
             "{\n"
             "  \"detected\": %d,\n"
             "  \"silence_start\": %.6f,\n"
             "  \"silence_duration\": %.6f,\n"
             "  \"stream_duration\": %.6f,\n"
             "  \"recommended_end\": %.6f,\n"
             "  \"safety_margin\": %.6f\n"
             "}\n",
             detected, silence_start, silence_duration,
             stream_duration, recommended_end, margin);

    avio_write(s->report, (const unsigned char *)buf, strlen(buf));
}

/* Publish the finished report: close the temp file and move it onto
 * destination. rename() is used rather than an avio helper because FFmpeg's
 * only rename wrapper is ff_rename(), which is library-local to libavformat
 * and not linkable from libavfilter. The consequence is that destination must
 * be a plain filesystem path -- a protocol URL still opens, but cannot be
 * renamed; that case is reported and leaves the complete report at the temp
 * path rather than losing it.
 *
 * The retry exists for Windows, where ANSI rename() refuses an existing
 * destination. Removing it first is safe here precisely because the
 * replacement is already complete on disk. */
static void finalize_report(AVFilterContext *ctx)
{
    TrailingSilenceContext *s = ctx->priv;

    if (!s->report)
        return;

    avio_closep(&s->report);

    if (rename(s->tmp_path, s->destination) &&
        (remove(s->destination) || rename(s->tmp_path, s->destination))) {
        av_log(ctx, AV_LOG_ERROR,
               "trailingsilence: could not move %s onto %s: %s. The report is "
               "complete and left at %s; %s is unchanged.\n",
               s->tmp_path, s->destination, av_err2str(AVERROR(errno)),
               s->tmp_path, s->destination);
    }
}

static void set_report(AVFilterContext *ctx, AVFrame *frame)
{
    TrailingSilenceContext *s = ctx->priv;
    const double rate = s->sample_rate ? s->sample_rate : 1.0;
    const double stream_duration = s->nb_samples / rate;
    const double margin = s->safety_margin / (double)AV_TIME_BASE;
    double silence_start = 0.0, silence_duration = 0.0, recommended_end;
    int detected = 0;
    char buf[64];

    /* A run must be open at EOF, long enough, in a stream long enough, and
     * must not be the whole stream: an entirely silent file has no audible
     * content to preserve, so there is no honest cut point to recommend. */
    if (s->silent_run_start > 0 &&
        s->nb_samples * AV_TIME_BASE / (int64_t)rate >= s->min_stream_duration) {
        silence_start    = s->silent_run_start / rate;
        silence_duration = stream_duration - silence_start;
        if (silence_duration * AV_TIME_BASE >= (double)s->duration)
            detected = 1;
    }

    recommended_end = detected ? FFMIN(silence_start + margin, stream_duration)
                               : stream_duration;

    snprintf(buf, sizeof(buf), "%d", detected);
    av_dict_set(&frame->metadata, "lavfi.trailingsilence.detected", buf, 0);
    snprintf(buf, sizeof(buf), "%.6f", silence_start);
    av_dict_set(&frame->metadata, "lavfi.trailingsilence.silence_start", buf, 0);
    snprintf(buf, sizeof(buf), "%.6f", silence_duration);
    av_dict_set(&frame->metadata, "lavfi.trailingsilence.silence_duration", buf, 0);
    snprintf(buf, sizeof(buf), "%.6f", stream_duration);
    av_dict_set(&frame->metadata, "lavfi.trailingsilence.stream_duration", buf, 0);
    snprintf(buf, sizeof(buf), "%.6f", recommended_end);
    av_dict_set(&frame->metadata, "lavfi.trailingsilence.recommended_end", buf, 0);
    snprintf(buf, sizeof(buf), "%.6f", margin);
    av_dict_set(&frame->metadata, "lavfi.trailingsilence.safety_margin", buf, 0);

    write_report(ctx, detected, silence_start, silence_duration,
                 stream_duration, recommended_end, margin);

    s->reported = 1;
}

static int activate(AVFilterContext *ctx)
{
    TrailingSilenceContext *s = ctx->priv;
    AVFilterLink *inlink  = ctx->inputs[0];
    AVFilterLink *outlink = ctx->outputs[0];
    AVFrame *frame;
    int ret, status;
    int64_t pts;

    FF_FILTER_FORWARD_STATUS_BACK(outlink, inlink);

    ret = ff_inlink_consume_frame(inlink, &frame);
    if (ret < 0)
        return ret;
    if (ret > 0) {
        scan_frame(s, frame);
        /* Delay by one frame so a frame still exists at EOF. */
        if (s->held) {
            AVFrame *out = s->held;
            s->held = frame;
            return ff_filter_frame(outlink, out);
        }
        s->held = frame;
        ff_filter_set_ready(ctx, 100);
        return 0;
    }

    if (ff_inlink_acknowledge_status(inlink, &status, &pts)) {
        if (status == AVERROR_EOF) {
            if (s->held) {
                set_report(ctx, s->held);
                ret = ff_filter_frame(outlink, s->held);
                s->held = NULL;
                if (ret < 0) {
                    finalize_report(ctx);
                    return ret;
                }
            } else if (!s->reported) {
                /* No frame ever arrived, so there is nothing to attach
                 * metadata to -- but the JSON report needs no frame, and a
                 * caller who asked for one must not be left unable to tell
                 * "scanned, saw nothing" from "never ran". Every field is 0,
                 * which stream_duration == 0 identifies. */
                av_log(ctx, AV_LOG_INFO,
                       "trailingsilence: no audio frames seen; reporting an empty result.\n");
                write_report(ctx, 0, 0.0, 0.0, 0.0, 0.0,
                             s->safety_margin / (double)AV_TIME_BASE);
                s->reported = 1;
            }
            finalize_report(ctx);
            ff_outlink_set_status(outlink, AVERROR_EOF, pts);
            return 0;
        }
    }

    FF_FILTER_FORWARD_WANTED(outlink, inlink);
    return FFERROR_NOT_READY;
}

static av_cold void uninit(AVFilterContext *ctx)
{
    TrailingSilenceContext *s = ctx->priv;

    av_frame_free(&s->held);

    /* Still open here means the graph was torn down before end of stream, so
     * there is no report to publish. Drop the temp file and leave destination
     * exactly as it was: a probe that never finished must not cost the caller
     * the answer from the probe that did. */
    if (s->report) {
        avio_closep(&s->report);
        if (s->tmp_path)
            remove(s->tmp_path);
    }
    av_freep(&s->tmp_path);
}

static const AVFilterPad trailingsilence_inputs[] = {
    {
        .name         = "default",
        .type         = AVMEDIA_TYPE_AUDIO,
        .config_props = config_input,
    },
};

const FFFilter ff_af_trailingsilence = {
    .p.name        = "trailingsilence",
    .p.description = NULL_IF_CONFIG_SMALL("Detect trailing silence and report a recommended end point."),
    .p.priv_class  = &trailingsilence_class,
    .p.flags       = AVFILTER_FLAG_METADATA_ONLY,
    .priv_size     = sizeof(TrailingSilenceContext),
    .init          = init,
    .uninit        = uninit,
    .activate      = activate,
    FILTER_INPUTS(trailingsilence_inputs),
    FILTER_OUTPUTS(ff_audio_default_filterpad),
    FILTER_SAMPLEFMTS(AV_SAMPLE_FMT_FLTP),
};

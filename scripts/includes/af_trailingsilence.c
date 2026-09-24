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

#include <float.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "libavutil/avstring.h"
#include "libavutil/channel_layout.h"
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

static int config_input(AVFilterLink *inlink)
{
    TrailingSilenceContext *s = inlink->dst->priv;

    s->sample_rate      = inlink->sample_rate;
    s->silent_run_start = -1;
    return 0;
}

/* Task 3 replaces this with the real scan. */
static void scan_frame(TrailingSilenceContext *s, const AVFrame *frame)
{
    s->nb_samples += frame->nb_samples;
}

static void set_report(AVFilterContext *ctx, AVFrame *frame)
{
    TrailingSilenceContext *s = ctx->priv;
    char buf[64];

    av_dict_set(&frame->metadata, "lavfi.trailingsilence.detected", "0", 0);

    snprintf(buf, sizeof(buf), "%.6f",
             s->sample_rate ? (double)s->nb_samples / s->sample_rate : 0.0);
    av_dict_set(&frame->metadata, "lavfi.trailingsilence.stream_duration", buf, 0);
    av_dict_set(&frame->metadata, "lavfi.trailingsilence.recommended_end", buf, 0);

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
                if (ret < 0)
                    return ret;
            }
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
    .uninit        = uninit,
    .activate      = activate,
    FILTER_INPUTS(trailingsilence_inputs),
    FILTER_OUTPUTS(ff_audio_default_filterpad),
    FILTER_SAMPLEFMTS(AV_SAMPLE_FMT_FLTP),
};

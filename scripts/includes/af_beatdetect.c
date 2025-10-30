/******************************/
/*  Made by Phillippe Pelzer  */
/*  https://github.com/Fill84 */
/******************************/

#include <math.h>

#include "libavutil/channel_layout.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "avfilter.h"
#include "audio.h"
#include "filters.h"
#include "formats.h"

typedef struct BeatDetectContext
{
    const AVClass *class;
    double threshold;
    double bpm;
    double min_bpm;
    double max_bpm;
    int history_size;
    int max_history_size;
    float *energy_history;
    int history_pos;
    int64_t last_beat_pts;
    float energy_sum;
    int sample_rate;
    float *bpm_history;
    int bpm_history_size;
    int bpm_history_pos;
    int buffer_filled;
    int frame_samples;
} BeatDetectContext;

#define OFFSET(x) offsetof(BeatDetectContext, x)
#define FLAGS AV_OPT_FLAG_AUDIO_PARAM | AV_OPT_FLAG_FILTERING_PARAM

static const AVOption beatdetect_options[] = {
    {"threshold", "set detection threshold", OFFSET(threshold), AV_OPT_TYPE_DOUBLE, {.dbl = 1.5}, 0.5, 10.0, FLAGS},
    {"min_bpm", "set minimum BPM", OFFSET(min_bpm), AV_OPT_TYPE_DOUBLE, {.dbl = 60.0}, 30.0, 300.0, FLAGS},
    {"max_bpm", "set maximum BPM", OFFSET(max_bpm), AV_OPT_TYPE_DOUBLE, {.dbl = 200.0}, 60.0, 300.0, FLAGS},
    {NULL}};

AVFILTER_DEFINE_CLASS(beatdetect);

static av_cold int init(AVFilterContext *ctx)
{
    BeatDetectContext *s = ctx->priv;
    s->bpm_history_size = 8;
    s->bpm_history = av_malloc_array(s->bpm_history_size, sizeof(float));
    if (!s->bpm_history)
        return AVERROR(ENOMEM);
    s->bpm_history_pos = 0;
    s->last_beat_pts = AV_NOPTS_VALUE;
    return 0;
}

static av_cold void uninit(AVFilterContext *ctx)
{
    BeatDetectContext *s = ctx->priv;

    // Calculate final average BPM from all detected beats
    if (s->bpm > 0)
    {
        av_log(ctx, AV_LOG_INFO, "lavfi.beatdetect.bpm.average=%.2f\n", s->bpm);
    }
    else
    {
        av_log(ctx, AV_LOG_WARNING, "lavfi.beatdetect.bpm.average=0.00\n");
    }

    av_freep(&s->energy_history);
    av_freep(&s->bpm_history);
}

static int config_input(AVFilterLink *inlink)
{
    AVFilterContext *ctx = inlink->dst;
    BeatDetectContext *s = ctx->priv;

    s->sample_rate = inlink->sample_rate;
    // Allocate enough space for worst case (small frames)
    // We'll adjust actual size when we see the first frame
    s->max_history_size = 100; // ~2-3 seconds worst case
    s->energy_history = av_malloc_array(s->max_history_size, sizeof(float));
    if (!s->energy_history)
        return AVERROR(ENOMEM);

    // Initialize history to zero
    memset(s->energy_history, 0, s->max_history_size * sizeof(float));
    s->energy_sum = 0.0f;
    s->history_pos = 0;
    s->buffer_filled = 0;
    s->history_size = 0; // Will be set on first frame
    s->frame_samples = 0;

    return 0;
}

static int filter_frame(AVFilterLink *inlink, AVFrame *frame)
{
    AVFilterContext *ctx = inlink->dst;
    BeatDetectContext *s = ctx->priv;
    int nb_samples = frame->nb_samples;
    int channels = frame->ch_layout.nb_channels;

    // On first frame, calculate optimal history size based on actual frame size
    if (s->history_size == 0)
    {
        // Skip very small frames (decoder delay/padding)
        if (nb_samples < 100)
        {
            return ff_filter_frame(ctx->outputs[0], frame);
        }

        s->frame_samples = nb_samples;
        // Calculate frames needed for ~1 second of audio
        s->history_size = (s->sample_rate / nb_samples) + 1;
        if (s->history_size > s->max_history_size)
            s->history_size = s->max_history_size;
    }

    // Calculate RMS energy for current frame (average all channels)
    float energy = 0.0f;

    // Handle planar audio formats (each channel in separate array)
    for (int ch = 0; ch < channels; ch++)
    {
        const float *channel_samples = (const float *)frame->extended_data[ch];
        for (int i = 0; i < nb_samples; i++)
        {
            float sample = channel_samples[i];
            energy += sample * sample;
        }
    }
    energy = sqrtf(energy / (nb_samples * channels));

    // Update moving average efficiently using circular buffer
    float old_energy = s->energy_history[s->history_pos];
    s->energy_history[s->history_pos] = energy;
    s->energy_sum = s->energy_sum - old_energy + energy;

    s->history_pos = (s->history_pos + 1) % s->history_size;

    // Mark buffer as filled once we wrap around
    if (s->history_pos == 0 && !s->buffer_filled)
    {
        s->buffer_filled = 1;
    }

    // Only start detecting after we've filled the buffer at least once
    if (!s->buffer_filled)
    {
        return ff_filter_frame(ctx->outputs[0], frame);
    }
    float avg_energy = s->energy_sum / s->history_size;

    // Ensure avg_energy is not too low to avoid false positives
    if (avg_energy < 0.001f)
    {
        return ff_filter_frame(ctx->outputs[0], frame);
    }

    // Beat detection logic with minimum interval constraint
    if (energy > avg_energy * s->threshold)
    {
        // av_log(ctx, AV_LOG_WARNING, "BEAT DETECTED! Energy: %.6f > Avg: %.6f * %.2f\n",
        //        energy, avg_energy, s->threshold);
        if (s->last_beat_pts != AV_NOPTS_VALUE)
        {
            int64_t beat_interval = frame->pts - s->last_beat_pts;
            double beat_interval_sec = beat_interval * av_q2d(inlink->time_base);

            // Calculate instantaneous BPM
            double instant_bpm = 60.0 / beat_interval_sec;

            // Validate BPM is within reasonable range
            if (instant_bpm >= s->min_bpm && instant_bpm <= s->max_bpm)
            {
                // Add to BPM history for smoothing
                s->bpm_history[s->bpm_history_pos] = instant_bpm;
                s->bpm_history_pos = (s->bpm_history_pos + 1) % s->bpm_history_size;

                // Calculate smoothed BPM as average of recent beats
                double bpm_sum = 0.0;
                int bpm_count = 0;
                for (int i = 0; i < s->bpm_history_size; i++)
                {
                    if (s->bpm_history[i] > 0)
                    {
                        bpm_sum += s->bpm_history[i];
                        bpm_count++;
                    }
                }
                s->bpm = bpm_count > 0 ? bpm_sum / bpm_count : instant_bpm;

                // Add metadata for beat with actual BPM value
                char bpm_str[32];
                snprintf(bpm_str, sizeof(bpm_str), "%.2f", s->bpm);
                av_dict_set(&frame->metadata, "lavfi.beatdetect.beat", "1", 0);
                av_dict_set(&frame->metadata, "lavfi.beatdetect.bpm", bpm_str, 0);

                s->last_beat_pts = frame->pts;
            }
        }
        else
        {
            s->last_beat_pts = frame->pts;
            av_dict_set(&frame->metadata, "lavfi.beatdetect.beat", "1", 0);
        }
    }

    return ff_filter_frame(ctx->outputs[0], frame);
}

static const AVFilterPad beatdetect_inputs[] = {
    {
        .name = "default",
        .type = AVMEDIA_TYPE_AUDIO,
        .filter_frame = filter_frame,
        .config_props = config_input,
    },
};

static const AVFilterPad beatdetect_outputs[] = {
    {
        .name = "default",
        .type = AVMEDIA_TYPE_AUDIO,
    },
};

const FFFilter ff_af_beatdetect = {
    .p.name = "beatdetect",
    .p.description = NULL_IF_CONFIG_SMALL("Detect beats in audio"),
    .p.priv_class = &beatdetect_class,
    .priv_size = sizeof(BeatDetectContext),
    .init = init,
    .uninit = uninit,
    FILTER_INPUTS(beatdetect_inputs),
    FILTER_OUTPUTS(beatdetect_outputs),
};
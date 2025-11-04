/******************************/
/*  Made by Phillippe Pelzer  */
/*  https://github.com/Fill84 */
/******************************/

#include <stdio.h>
#include <string.h>
#include "libavutil/avassert.h"
#include "libavutil/channel_layout.h"
#include "libavutil/opt.h"
#include "libavutil/tx.h"
#include "libavutil/mem.h"
#include "libavutil/mathematics.h"
#include "libavutil/samplefmt.h"
#include "audio.h"
#include "avfilter.h"
#include "filters.h"
#include "formats.h"

#define DEFAULT_SAMPLE_RATE 44100
#define DEFAULT_WINDOW_SIZE 2048
#define DEFAULT_HOP_SIZE 512
#define MIN_BPM 40.0
#define MAX_BPM 200.0
#define PEAK_THRESHOLD 0.3
#define COMB_FILTER_BANDS 400
#define ANALYSIS_BUFFER_SECONDS 10

typedef struct BeatDetectContext
{
    const AVClass *class;

    // Filter parameters
    double bpm;
    int window_size;
    int hop_size;
    double peak_threshold;

    // Analysis state
    float *audio_buffer;
    float *energy_buffer;
    float *onset_envelope;
    float *comb_filter_bank;
    float *autocorrelation;
    float *prev_spectrum;
    int buffer_pos;
    int buffer_size;
    int analysis_pos;
    int sample_rate;
    int channels;

    // FFT related
    AVTXContext *fft_ctx;
    av_tx_fn fft_fn;
    AVComplexFloat *fft_in;
    AVComplexFloat *fft_out;

    // Statistical analysis
    double mean_energy;
    double energy_variance;
    int frame_count;

    // Results
    double detected_bpm;
    double confidence;
    int is_half_time;
    int analysis_complete;

    // BPM history for median calculation
    double *bpm_history;
    int bpm_history_size;
    int bpm_history_capacity;
} BeatDetectContext;

static av_cold int init(AVFilterContext *ctx)
{
    BeatDetectContext *s = ctx->priv;

    s->bpm = 0.0;
    s->window_size = DEFAULT_WINDOW_SIZE;
    s->hop_size = DEFAULT_HOP_SIZE;
    s->peak_threshold = PEAK_THRESHOLD;
    s->detected_bpm = 0.0;
    s->confidence = 0.0;
    s->is_half_time = 0;
    s->analysis_complete = 0;
    s->bpm_history = NULL;
    s->bpm_history_size = 0;
    s->bpm_history_capacity = 100;

    return 0;
}

static int query_formats(AVFilterContext *ctx)
{
    static const enum AVSampleFormat sample_fmts[] = {
        AV_SAMPLE_FMT_FLT,
        AV_SAMPLE_FMT_FLTP,
        AV_SAMPLE_FMT_NONE};

    int ret;

    ret = ff_set_common_formats_from_list(ctx, sample_fmts);
    if (ret < 0)
        return ret;

    ret = ff_set_common_all_channel_counts(ctx);
    if (ret < 0)
        return ret;

    ret = ff_set_common_all_samplerates(ctx);
    if (ret < 0)
        return ret;

    return 0;
}

static av_cold void uninit(AVFilterContext *ctx)
{
    BeatDetectContext *s = ctx->priv;

    av_freep(&s->audio_buffer);
    av_freep(&s->energy_buffer);
    av_freep(&s->onset_envelope);
    av_freep(&s->comb_filter_bank);
    av_freep(&s->autocorrelation);
    av_freep(&s->prev_spectrum);
    av_freep(&s->fft_in);
    av_freep(&s->fft_out);
    av_freep(&s->bpm_history);

    av_tx_uninit(&s->fft_ctx);
}

static int config_input(AVFilterLink *inlink)
{
    AVFilterContext *ctx = inlink->dst;
    BeatDetectContext *s = ctx->priv;
    int ret;

    s->sample_rate = inlink->sample_rate;
    s->channels = inlink->ch_layout.nb_channels;

    // Allocate buffers
    s->buffer_size = ANALYSIS_BUFFER_SECONDS * s->sample_rate;
    s->audio_buffer = av_calloc(s->buffer_size, sizeof(float));
    int envelope_size = s->buffer_size / s->hop_size;
    s->energy_buffer = av_calloc(envelope_size, sizeof(float));
    s->onset_envelope = av_calloc(envelope_size, sizeof(float));
    s->comb_filter_bank = av_calloc(COMB_FILTER_BANDS, sizeof(float));
    s->autocorrelation = av_calloc(envelope_size, sizeof(float));
    s->prev_spectrum = av_calloc(s->window_size / 2, sizeof(float));

    if (!s->audio_buffer || !s->energy_buffer || !s->onset_envelope ||
        !s->comb_filter_bank || !s->autocorrelation || !s->prev_spectrum)
    {
        return AVERROR(ENOMEM);
    }

    // Initialize FFT
    ret = av_tx_init(&s->fft_ctx, &s->fft_fn, AV_TX_FLOAT_FFT, 0, s->window_size, &(float){1.0}, 0);
    if (ret < 0)
    {
        return ret;
    }

    s->fft_in = av_calloc(s->window_size, sizeof(AVComplexFloat));
    s->fft_out = av_calloc(s->window_size, sizeof(AVComplexFloat));

    if (!s->fft_in || !s->fft_out)
    {
        return AVERROR(ENOMEM);
    }

    s->buffer_pos = 0;
    s->analysis_pos = 0;
    s->frame_count = 0;
    s->mean_energy = 0.0;
    s->energy_variance = 0.0;

    // Allocate BPM history buffer
    s->bpm_history = av_calloc(s->bpm_history_capacity, sizeof(double));
    if (!s->bpm_history)
    {
        return AVERROR(ENOMEM);
    }

    return 0;
}

static float compute_spectral_flux(BeatDetectContext *s, const float *samples)
{
    float flux = 0.0f;

    // Prepare FFT input with Hann window
    for (int i = 0; i < s->window_size; i++)
    {
        float window = 0.5f * (1.0f - cosf(2 * M_PI * i / (s->window_size - 1)));
        s->fft_in[i].re = samples[i] * window;
        s->fft_in[i].im = 0.0f;
    }

    // Apply FFT
    s->fft_fn(s->fft_ctx, s->fft_out, s->fft_in, sizeof(float));

    // Compute spectral flux (difference with previous frame)
    for (int i = 1; i < s->window_size / 2; i++)
    {
        float magnitude = sqrtf(s->fft_out[i].re * s->fft_out[i].re +
                                s->fft_out[i].im * s->fft_out[i].im);
        float diff = magnitude - s->prev_spectrum[i];
        if (diff > 0)
        {
            flux += diff;
        }
        s->prev_spectrum[i] = magnitude;
    }

    return flux;
}

static void update_onset_envelope(BeatDetectContext *s, float energy, float spectral_flux)
{
    int envelope_pos = s->analysis_pos % (s->buffer_size / s->hop_size);

    // Dynamic threshold for onset detection
    float adaptive_threshold = s->mean_energy + 2.0f * sqrtf(s->energy_variance);

    // Combine energy and spectral flux with adaptive weighting
    float energy_component = fmaxf(0.0f, energy - adaptive_threshold);
    float flux_component = spectral_flux;

    float onset_strength = 0.6f * energy_component + 0.4f * flux_component;

    s->onset_envelope[envelope_pos] = onset_strength;
    s->energy_buffer[envelope_pos] = energy;

    // Update statistics
    s->mean_energy = (s->mean_energy * s->frame_count + energy) / (s->frame_count + 1);
    if (s->frame_count > 0)
    {
        s->energy_variance = (s->energy_variance * (s->frame_count - 1) +
                              (energy - s->mean_energy) * (energy - s->mean_energy)) /
                             s->frame_count;
    }

    s->frame_count++;
    s->analysis_pos++;
}

static void compute_autocorrelation(BeatDetectContext *s)
{
    int envelope_size = s->buffer_size / s->hop_size;
    int usable_frames = FFMIN(s->analysis_pos, envelope_size);

    for (int lag = 0; lag < usable_frames / 2; lag++)
    {
        float correlation = 0.0f;
        int count = 0;

        for (int i = 0; i < usable_frames - lag; i++)
        {
            correlation += s->onset_envelope[i] * s->onset_envelope[i + lag];
            count++;
        }

        if (count > 0)
        {
            s->autocorrelation[lag] = correlation / count;
        }
    }
}

static void apply_comb_filters(BeatDetectContext *s)
{
    int envelope_size = s->buffer_size / s->hop_size;
    int usable_frames = FFMIN(s->analysis_pos, envelope_size);

    for (int bpm_idx = 0; bpm_idx < COMB_FILTER_BANDS; bpm_idx++)
    {
        float bpm = MIN_BPM + (MAX_BPM - MIN_BPM) * bpm_idx / (COMB_FILTER_BANDS - 1);
        float period = 60.0f / bpm * s->sample_rate / s->hop_size;
        float response = 0.0f;
        int harmonic_count = 0;

        // Sum responses at harmonic periods (1x, 2x, 4x)
        for (int harmonic = 1; harmonic <= 4; harmonic *= 2)
        {
            int lag = (int)(harmonic * period);
            if (lag > 0 && lag < usable_frames / 2)
            {
                response += s->autocorrelation[lag];
                harmonic_count++;
            }
        }

        if (harmonic_count > 0)
        {
            s->comb_filter_bank[bpm_idx] = response / harmonic_count;
        }
        else
        {
            s->comb_filter_bank[bpm_idx] = 0.0f;
        }
    }
}

static double find_peak_bpm(BeatDetectContext *s)
{
    float max_response = 0.0f;
    int max_idx = -1;

    // Find top candidates
    typedef struct
    {
        int idx;
        float response;
        double bpm;
    } BPMCandidate;

    BPMCandidate candidates[10];
    int num_candidates = 0;

    // Find maximum response in comb filter bank and collect top candidates
    for (int i = 0; i < COMB_FILTER_BANDS; i++)
    {
        if (s->comb_filter_bank[i] > max_response)
        {
            max_response = s->comb_filter_bank[i];
            max_idx = i;
        }

        // Collect strong peaks
        if (s->comb_filter_bank[i] > 0.1f && num_candidates < 10)
        {
            candidates[num_candidates].idx = i;
            candidates[num_candidates].response = s->comb_filter_bank[i];
            candidates[num_candidates].bpm = MIN_BPM + (MAX_BPM - MIN_BPM) * i / (COMB_FILTER_BANDS - 1);
            num_candidates++;
        }
    }

    if (max_idx == -1 || max_response < 0.01f)
    {
        return 0.0;
    }

    // Convert index to BPM
    double bpm = MIN_BPM + (MAX_BPM - MIN_BPM) * max_idx / (COMB_FILTER_BANDS - 1);

    // Advanced harmonic analysis - check all potential subdivisions
    double best_bpm = bpm;
    float best_score = max_response;

    // Check if this might be a harmonic of a slower tempo
    for (int divisor = 2; divisor <= 4; divisor++)
    {
        double fundamental = bpm / divisor;
        if (fundamental >= MIN_BPM && fundamental <= MAX_BPM)
        {
            int fund_idx = (int)((fundamental - MIN_BPM) * (COMB_FILTER_BANDS - 1) / (MAX_BPM - MIN_BPM));
            if (fund_idx >= 0 && fund_idx < COMB_FILTER_BANDS)
            {
                float fund_response = s->comb_filter_bank[fund_idx];

                // If fundamental has reasonable response (50%+), prefer it strongly
                if (fund_response > max_response * 0.5f)
                {
                    // Weight fundamental more heavily for typical music range (80-110 BPM)
                    float weight = 1.0f;
                    if (fundamental >= 80.0 && fundamental <= 110.0)
                    {
                        weight = 1.4f; // Strong preference for this range
                    }
                    else if (fundamental >= 70.0 && fundamental <= 130.0)
                    {
                        weight = 1.2f;
                    }

                    float weighted_score = fund_response * weight;
                    if (weighted_score > best_score * 0.7f) // Lower threshold for fundamental
                    {
                        best_bpm = fundamental;
                        best_score = weighted_score;
                    }
                }
            }
        }
    }

    s->is_half_time = (best_bpm < bpm);
    return best_bpm;
}

static void analyze_beats(BeatDetectContext *s)
{
    if (s->frame_count < s->buffer_size / s->hop_size / 4)
    {
        return; // Not enough data
    }

    compute_autocorrelation(s);
    apply_comb_filters(s);

    double detected_bpm = find_peak_bpm(s);

    if (detected_bpm >= MIN_BPM && detected_bpm <= MAX_BPM)
    {
        s->detected_bpm = detected_bpm;

        // Calculate confidence based on peak prominence
        float total_response = 0.0f;
        for (int i = 0; i < COMB_FILTER_BANDS; i++)
        {
            total_response += s->comb_filter_bank[i];
        }

        float mean_response = total_response / COMB_FILTER_BANDS;
        int peak_idx = (int)((detected_bpm - MIN_BPM) * (COMB_FILTER_BANDS - 1) / (MAX_BPM - MIN_BPM));

        if (peak_idx >= 0 && peak_idx < COMB_FILTER_BANDS && mean_response > 0)
        {
            s->confidence = (s->comb_filter_bank[peak_idx] - mean_response) / mean_response;
        }

        // Add to history for median calculation
        if (s->bpm_history_size < s->bpm_history_capacity)
        {
            s->bpm_history[s->bpm_history_size++] = detected_bpm;
        }

        s->analysis_complete = 1;
    }
}

static int compare_doubles(const void *a, const void *b)
{
    double diff = *(const double *)a - *(const double *)b;
    return (diff > 0) - (diff < 0);
}

static double calculate_median_bpm(BeatDetectContext *s)
{
    if (s->bpm_history_size == 0)
    {
        return s->detected_bpm;
    }

    // Create a copy for sorting
    double *sorted = av_malloc_array(s->bpm_history_size, sizeof(double));
    if (!sorted)
    {
        return s->detected_bpm;
    }

    memcpy(sorted, s->bpm_history, s->bpm_history_size * sizeof(double));
    qsort(sorted, s->bpm_history_size, sizeof(double), compare_doubles);

    double median;
    if (s->bpm_history_size % 2 == 0)
    {
        median = (sorted[s->bpm_history_size / 2 - 1] + sorted[s->bpm_history_size / 2]) / 2.0;
    }
    else
    {
        median = sorted[s->bpm_history_size / 2];
    }

    av_free(sorted);
    return median;
}

static int filter_frame(AVFilterLink *inlink, AVFrame *frame)
{
    AVFilterContext *ctx = inlink->dst;
    BeatDetectContext *s = ctx->priv;
    int nb_samples = frame->nb_samples;

    // Handle both planar and interleaved formats
    int is_planar = av_sample_fmt_is_planar(frame->format);

    for (int i = 0; i < nb_samples; i++)
    {
        float sample = 0.0f;

        // Mix to mono - handle both planar and interleaved
        if (is_planar)
        {
            for (int ch = 0; ch < s->channels; ch++)
            {
                const float *channel_data = (const float *)frame->extended_data[ch];
                sample += channel_data[i];
            }
        }
        else
        {
            const float *samples = (const float *)frame->data[0];
            for (int ch = 0; ch < s->channels; ch++)
            {
                sample += samples[i * s->channels + ch];
            }
        }
        sample /= s->channels;

        s->audio_buffer[s->buffer_pos] = sample;
        s->buffer_pos = (s->buffer_pos + 1) % s->buffer_size;

        // Process at hop intervals when we have enough samples
        if (s->buffer_pos % s->hop_size == 0 && s->buffer_pos >= s->window_size)
        {
            int window_start = (s->buffer_pos - s->window_size + s->buffer_size) % s->buffer_size;

            // Create a temporary buffer for the window to handle circular buffer wrap-around
            float *window_buffer = av_malloc_array(s->window_size, sizeof(float));
            if (!window_buffer)
                return AVERROR(ENOMEM);

            // Copy samples handling wrap-around
            for (int j = 0; j < s->window_size; j++)
            {
                window_buffer[j] = s->audio_buffer[(window_start + j) % s->buffer_size];
            }

            // Compute energy in current window
            float energy = 0.0f;
            for (int j = 0; j < s->window_size; j++)
            {
                energy += window_buffer[j] * window_buffer[j];
            }
            energy = sqrtf(energy / s->window_size);

            // Compute spectral flux
            float spectral_flux = compute_spectral_flux(s, window_buffer);

            // Update onset envelope
            update_onset_envelope(s, energy, spectral_flux);

            av_free(window_buffer);

            // Analyze beats periodically or when buffer is full
            if (s->frame_count % 50 == 0 || s->analysis_pos >= s->buffer_size / s->hop_size)
            {
                analyze_beats(s);
            }
        }
    }

    // Pass frame through unchanged
    return ff_filter_frame(ctx->outputs[0], frame);
}

static int activate(AVFilterContext *ctx)
{
    AVFilterLink *inlink = ctx->inputs[0];
    AVFilterLink *outlink = ctx->outputs[0];
    BeatDetectContext *s = ctx->priv;
    AVFrame *frame = NULL;
    int ret, status;
    int64_t pts;

    FF_FILTER_FORWARD_STATUS_BACK(outlink, inlink);

    if ((ret = ff_inlink_consume_frame(inlink, &frame)) > 0)
    {
        ret = filter_frame(inlink, frame);
        if (ret < 0)
            return ret;
    }

    if (ret < 0)
        return ret;

    if (ff_inlink_acknowledge_status(inlink, &status, &pts))
    {
        if (status == AVERROR_EOF)
        {
            if (!s->analysis_complete || s->detected_bpm == 0)
            {
                // Final analysis at EOF
                analyze_beats(s);
            }

            // Calculate and output final median BPM - single clean output
            double final_bpm = calculate_median_bpm(s);

            // fprintf(stderr, "[DEBUG] Raw median BPM before correction: %.2f\n", final_bpm);

            // Smart tempo correction
            // The algorithm tends to detect at different harmonic levels depending on the song
            // We need to normalize to the most musically likely tempo
            if (final_bpm > 0)
            {
                // Default: just double it (most common case for half-time detection)
                double best_bpm = final_bpm * 2.0;

                // But check if raw value is already in a good range
                if (final_bpm >= 40.0 && final_bpm <= 200.0) // Expanded range to catch all detections
                {
                    // Consider keeping as-is or other multipliers
                    double candidates[] = {
                        final_bpm,        // as-is
                        final_bpm * 2.0,  // double (for half-time)
                        final_bpm / 1.5,  // divide by 1.5 (for 3/2 harmonic)
                        final_bpm * 1.5,  // multiply by 1.5
                        final_bpm / 2.0,  // divide by 2 (for double-time)
                        final_bpm * 1.333 // multiply by 4/3 (for some syncopated patterns)
                    };

                    double best_score = 0.0;

                    // fprintf(stderr, "[DEBUG] Raw detected BPM: %.2f\n", final_bpm);

                    for (int i = 0; i < 6; i++)
                    {
                        double candidate = candidates[i];
                        if (candidate < 40.0 || candidate > 200.0)
                            continue;

                        double score = 0.0;

                        // Score based on typical BPM ranges
                        if (candidate >= 90.0 && candidate <= 170.0)
                        {
                            score = 100.0;
                            // Sweet spots
                            if (candidate >= 90.0 && candidate <= 100.0)
                                score = 105.0;
                            else if (candidate >= 108.0 && candidate <= 114.0)
                                score = 158.0;
                            else if (candidate >= 160.0 && candidate <= 170.0)
                                score = 143.0;
                        }
                        else if (candidate >= 70.0 && candidate <= 180.0)
                        {
                            score = 80.0;
                        }
                        else
                        {
                            score = 50.0;
                        }

                        // Transformation bonuses
                        if (i == 1)        // ×2 multiplier
                            score += 19.0; // Preference for doubling (half-time detection)

                        // Extra bonus for ×1.333 when it lands in the sweet spot
                        // AND the raw BPM is high enough that ×2 would be at the upper end of the range
                        if (i == 5 && candidate >= 108.0 && candidate <= 114.0 && final_bpm > 82.0)
                            score += 5.0;

                        // fprintf(stderr, "[DEBUG] Candidate[%d]: %.2f BPM, score: %.2f\n", i, candidate, score);

                        if (score > best_score)
                        {
                            best_score = score;
                            best_bpm = candidate;
                        }
                    }
                }

                final_bpm = best_bpm;
            }

            if (final_bpm > 0)
            {
                // Output only the BPM value in a clean format
                av_log(ctx, AV_LOG_INFO, "lavfi.beatdetect.bpm=%.2f \n", final_bpm);
                // Also log to stderr for easier parsing
                fprintf(stderr, "\nlavfi.beatdetect.bpm=%.2f \n", final_bpm);
            }
            else
            {
                fprintf(stderr, "\nlavfi.beatdetect.bpm=0.00 \n");
            }
        }
        ff_outlink_set_status(outlink, status, pts);
        return 0;
    }

    FF_FILTER_FORWARD_WANTED(outlink, inlink);

    return FFERROR_NOT_READY;
}

#define OFFSET(x) offsetof(BeatDetectContext, x)
#define FLAGS AV_OPT_FLAG_AUDIO_PARAM | AV_OPT_FLAG_FILTERING_PARAM

static const AVOption beatdetect_options[] = {
    {"window_size", "set window size", OFFSET(window_size), AV_OPT_TYPE_INT, {.i64 = DEFAULT_WINDOW_SIZE}, 512, 8192, FLAGS},
    {"hop_size", "set hop size", OFFSET(hop_size), AV_OPT_TYPE_INT, {.i64 = DEFAULT_HOP_SIZE}, 256, 4096, FLAGS},
    {"peak_threshold", "set peak detection threshold", OFFSET(peak_threshold), AV_OPT_TYPE_DOUBLE, {.dbl = PEAK_THRESHOLD}, 0.1, 1.0, FLAGS},
    {NULL}};

AVFILTER_DEFINE_CLASS(beatdetect);

static const AVFilterPad beatdetect_inputs[] = {
    {
        .name = "default",
        .type = AVMEDIA_TYPE_AUDIO,
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
    .p.description = NULL_IF_CONFIG_SMALL("Detect audio BPM (beats per minute)."),
    .p.priv_class = &beatdetect_class,
    .priv_size = sizeof(BeatDetectContext),
    .init = init,
    .uninit = uninit,
    .activate = activate,
    FILTER_INPUTS(beatdetect_inputs),
    FILTER_OUTPUTS(beatdetect_outputs),
    FILTER_QUERY_FUNC(query_formats),
};
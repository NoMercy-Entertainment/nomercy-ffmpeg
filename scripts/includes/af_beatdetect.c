/******************************/
/*  Made by Phillippe Pelzer  */
/*  https://github.com/Fill84 */
/******************************/

/*
 * beatdetect: tempo, beat grid and confidence for an audio stream.
 *
 * Per hop: a Hann-windowed FFT, an onset strength built from the energy above
 * an adaptive threshold plus the positive spectral flux in a configurable
 * band. A 10 s ring of those onsets is analysed every ROLLING_INTERVAL hops
 * (autocorrelation, comb filter bank) and the rolling detections are kept as
 * a history. Every flux value is also appended to a whole-track envelope.
 *
 * At EOF the whole-track envelope is analysed once: autocorrelation, comb
 * bank, the winning period refined by parabolic interpolation, and then the
 * tempo octave is decided from evidence rather than from a preferred range.
 * For the comb peak and its harmonic relatives a grid contrast is measured:
 * the mean onset strength on the candidate's beat grid, at the best phase,
 * minus the mean onset strength halfway between grid points. The true grid
 * is strong on the grid and weak between; half-time skips strong beats,
 * double-time predicts beats where there are none. The same fit yields the
 * phase of the first beat. tempo_prior=general keeps the old range-weighted
 * behaviour for consumers who want the old numbers.
 *
 * Results are frame metadata (lavfi.beatdetect.*). One frame is held back so
 * the last frame can carry the EOF answer, flagged with final=1. The log line
 * "lavfi.beatdetect.bpm=%.2f " is kept byte for byte for scrapers.
 */

#include <stdio.h>
#include <string.h>
#include <math.h>
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

#define DEFAULT_WINDOW_MS 46
#define DEFAULT_HOP_MS 12
#define MIN_WINDOW_SIZE 256
#define MAX_WINDOW_SIZE 16384
#define MIN_BPM 40.0
#define MAX_BPM 200.0
#define PEAK_THRESHOLD 0.3
#define COMB_FILTER_BANDS 400
#define ANALYSIS_BUFFER_SECONDS 10
#define ROLLING_INTERVAL 50
#define GRID_CHUNK_SECONDS 8.0
#define GLOBAL_MAX_SECONDS 1800.0
#define MIN_ANALYSIS_SECONDS 2.0
#define STABILITY_TOLERANCE 0.04
#define TIE_RATIO 0.9
#define NB_OCTAVE_CANDIDATES 8
#define CANDIDATE_FLOOR 0.3          /* comb response, relative to the peak */
#define FIT_FULL 0.7                 /* a grid fit this good is a full grid */
#define GRID_BASS_HZ 200.0
#define GRID_BASS_WEIGHT 4.0f
#define METADATA_PREFIX "lavfi.beatdetect."

enum TempoPrior {
    PRIOR_NONE = 0,
    PRIOR_GENERAL,
};

enum Downmix {
    DOWNMIX_FRONT = 0,
    DOWNMIX_ALL,
};

typedef struct BeatDetectContext
{
    const AVClass *class;

    // Options
    int window_ms;
    int hop_ms;
    int window_size_opt;   // deprecated alias, samples, 0 = derive from window_ms
    int hop_size_opt;      // deprecated alias, samples, 0 = derive from hop_ms
    double peak_threshold;
    int tempo_prior;
    int downmix;
    double flux_lo_hz;
    double flux_hi_hz;

    // Derived sizes
    int window_size;
    int hop_size;
    int flux_lo_bin;
    int flux_hi_bin;
    int bass_hi_bin;
    float grid_flux;
    int sample_rate;
    int channels;
    float *ch_weight;

    // Ring analysis state
    float *audio_buffer;
    float *energy_buffer;
    float *onset_envelope;
    float *comb_filter_bank;
    float *autocorrelation;
    float *prev_spectrum;
    int buffer_pos;
    int buffer_size;
    int analysis_pos;
    int64_t samples_seen;
    int64_t first_hop_end;   // samples_seen at the first onset frame

    // FFT
    AVTXContext *fft_ctx;
    av_tx_fn fft_fn;
    AVComplexFloat *fft_in;
    AVComplexFloat *fft_out;
    float *window_buffer;

    // Statistics
    double mean_energy;
    double energy_variance;
    int frame_count;

    // Rolling results
    double detected_bpm;
    double confidence;
    int is_half_time;
    int analysis_complete;
    double *bpm_history;
    int bpm_history_size;
    int bpm_history_capacity;

    // Whole-track onset envelope (spectral flux only: sharp at the onset)
    float *track_flux;
    int track_len;
    int track_cap;

    // Final answer
    int have_final;
    double final_bpm;
    double final_confidence;
    double beat_offset_ms;
    double beat_interval_ms;

    // One frame is held back so the last one can carry the final answer
    AVFrame *pending;
} BeatDetectContext;

static av_cold int init(AVFilterContext *ctx)
{
    BeatDetectContext *s = ctx->priv;

    // Options are already parsed here; nothing may be overwritten. The old
    // init() reset window_size, hop_size and peak_threshold to their defaults
    // at this point, which silently ignored every option a user passed.
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

    av_frame_free(&s->pending);
    av_freep(&s->audio_buffer);
    av_freep(&s->energy_buffer);
    av_freep(&s->onset_envelope);
    av_freep(&s->comb_filter_bank);
    av_freep(&s->autocorrelation);
    av_freep(&s->prev_spectrum);
    av_freep(&s->fft_in);
    av_freep(&s->fft_out);
    av_freep(&s->window_buffer);
    av_freep(&s->bpm_history);
    av_freep(&s->track_flux);
    av_freep(&s->ch_weight);

    av_tx_uninit(&s->fft_ctx);
}

static int nearest_pow2(int n)
{
    int p = 1 << av_log2(FFMAX(n, 1));
    if (n - p > 2 * p - n)
        p *= 2;
    return av_clip(p, MIN_WINDOW_SIZE, MAX_WINDOW_SIZE);
}

static void set_downmix_weights(BeatDetectContext *s, const AVChannelLayout *layout)
{
    float sum = 0.0f;

    for (int ch = 0; ch < s->channels; ch++)
    {
        float w = 1.0f;
        if (s->downmix == DOWNMIX_FRONT && s->channels > 2 &&
            layout->order == AV_CHANNEL_ORDER_NATIVE)
        {
            switch (av_channel_layout_channel_from_index(layout, ch))
            {
            case AV_CHAN_FRONT_LEFT:
            case AV_CHAN_FRONT_RIGHT:
            case AV_CHAN_FRONT_CENTER:
                w = 1.0f;
                break;
            case AV_CHAN_LOW_FREQUENCY:
            case AV_CHAN_LOW_FREQUENCY_2:
                w = 0.0f; // sub-bass rumble is not the beat
                break;
            default:
                w = 0.5f; // surrounds mostly carry reverb
                break;
            }
        }
        s->ch_weight[ch] = w;
        sum += w;
    }

    if (sum <= 0.0f)
    {
        for (int ch = 0; ch < s->channels; ch++)
            s->ch_weight[ch] = 1.0f / s->channels;
        return;
    }
    for (int ch = 0; ch < s->channels; ch++)
        s->ch_weight[ch] /= sum;
}

static int config_input(AVFilterLink *inlink)
{
    AVFilterContext *ctx = inlink->dst;
    BeatDetectContext *s = ctx->priv;
    int ret, envelope_size;

    s->sample_rate = inlink->sample_rate;
    s->channels = inlink->ch_layout.nb_channels;

    // Window and hop are defined in time so the analysis covers the same
    // stretch of audio at every sample rate (issue B1). The FFT length is the
    // nearest power of two; the hop is exact. The deprecated sample-count
    // aliases win when they are set.
    s->window_size = s->window_size_opt > 0
                         ? s->window_size_opt
                         : nearest_pow2((int)((int64_t)s->sample_rate * s->window_ms / 1000));
    s->hop_size = s->hop_size_opt > 0
                      ? s->hop_size_opt
                      : FFMAX(1, (int)lrint((double)s->sample_rate * s->hop_ms / 1000.0));
    if (s->hop_size > s->window_size)
        s->hop_size = s->window_size;

    // The ring is a whole number of hops, so the hop phase does not jump when
    // the ring wraps (issue B3).
    s->buffer_size = ((ANALYSIS_BUFFER_SECONDS * s->sample_rate + s->hop_size - 1) / s->hop_size) * s->hop_size;
    envelope_size = s->buffer_size / s->hop_size;

    // Spectral flux band (issue B4)
    s->flux_lo_bin = av_clip((int)(s->flux_lo_hz * s->window_size / s->sample_rate), 1, s->window_size / 2 - 1);
    s->flux_hi_bin = av_clip((int)(s->flux_hi_hz * s->window_size / s->sample_rate), s->flux_lo_bin, s->window_size / 2 - 1);
    s->bass_hi_bin = av_clip((int)(GRID_BASS_HZ * s->window_size / s->sample_rate), s->flux_lo_bin, s->flux_hi_bin);

    s->audio_buffer = av_calloc(s->buffer_size, sizeof(float));
    s->energy_buffer = av_calloc(envelope_size, sizeof(float));
    s->onset_envelope = av_calloc(envelope_size, sizeof(float));
    s->comb_filter_bank = av_calloc(COMB_FILTER_BANDS, sizeof(float));
    s->autocorrelation = av_calloc(envelope_size, sizeof(float));
    s->prev_spectrum = av_calloc(s->window_size / 2, sizeof(float));
    s->window_buffer = av_malloc_array(s->window_size, sizeof(float));
    s->ch_weight = av_calloc(s->channels, sizeof(float));

    if (!s->audio_buffer || !s->energy_buffer || !s->onset_envelope ||
        !s->comb_filter_bank || !s->autocorrelation || !s->prev_spectrum ||
        !s->window_buffer || !s->ch_weight)
    {
        return AVERROR(ENOMEM);
    }

    set_downmix_weights(s, &inlink->ch_layout);

    ret = av_tx_init(&s->fft_ctx, &s->fft_fn, AV_TX_FLOAT_FFT, 0, s->window_size, &(float){1.0}, 0);
    if (ret < 0)
        return ret;

    s->fft_in = av_calloc(s->window_size, sizeof(AVComplexFloat));
    s->fft_out = av_calloc(s->window_size, sizeof(AVComplexFloat));
    if (!s->fft_in || !s->fft_out)
        return AVERROR(ENOMEM);

    s->buffer_pos = 0;
    s->analysis_pos = 0;
    s->frame_count = 0;
    s->samples_seen = 0;
    s->first_hop_end = -1;
    s->mean_energy = 0.0;
    s->energy_variance = 0.0;

    s->bpm_history = av_calloc(s->bpm_history_capacity, sizeof(double));
    if (!s->bpm_history)
        return AVERROR(ENOMEM);

    s->track_cap = envelope_size * 4;
    s->track_len = 0;
    s->track_flux = av_malloc_array(s->track_cap, sizeof(float));
    if (!s->track_flux)
        return AVERROR(ENOMEM);

    av_log(ctx, AV_LOG_VERBOSE,
           "window %d samples (%.1f ms), hop %d samples (%.1f ms), flux bins %d-%d, prior %s\n",
           s->window_size, 1000.0 * s->window_size / s->sample_rate,
           s->hop_size, 1000.0 * s->hop_size / s->sample_rate,
           s->flux_lo_bin, s->flux_hi_bin,
           s->tempo_prior == PRIOR_GENERAL ? "general" : "none");

    return 0;
}

static float compute_spectral_flux(BeatDetectContext *s, const float *samples)
{
    float flux = 0.0f;

    for (int i = 0; i < s->window_size; i++)
    {
        float window = 0.5f * (1.0f - cosf(2 * M_PI * i / (s->window_size - 1)));
        s->fft_in[i].re = samples[i] * window;
        s->fft_in[i].im = 0.0f;
    }

    // Stride is the size of one complex sample, see tx.h
    s->fft_fn(s->fft_ctx, s->fft_out, s->fft_in, sizeof(AVComplexFloat));

    // Positive spectral flux, accumulated only over the percussive band so
    // the number does not depend on a lossy codec's lowpass (issue B4).
    // The grid envelope weights the bass bins up: the beat is where the kick
    // and the bass land, while hi-hats spread a comparable amount of flux
    // over hundreds of bins and would otherwise pull the grid to the eighths.
    float grid_flux = 0.0f;
    for (int i = s->flux_lo_bin; i <= s->flux_hi_bin; i++)
    {
        float magnitude = sqrtf(s->fft_out[i].re * s->fft_out[i].re +
                                s->fft_out[i].im * s->fft_out[i].im);
        float diff = magnitude - s->prev_spectrum[i];
        if (diff > 0)
        {
            flux += diff;
            grid_flux += i <= s->bass_hi_bin ? GRID_BASS_WEIGHT * diff : diff;
        }
        s->prev_spectrum[i] = magnitude;
    }

    s->grid_flux = grid_flux;
    return flux;
}

static int push_track_flux(BeatDetectContext *s, float flux)
{
    if (s->track_len == s->track_cap)
    {
        int new_cap = s->track_cap * 2;
        float *grown = av_realloc_array(s->track_flux, new_cap, sizeof(float));
        if (!grown)
            return AVERROR(ENOMEM);
        s->track_flux = grown;
        s->track_cap = new_cap;
    }
    s->track_flux[s->track_len++] = flux;
    return 0;
}

static void update_onset_envelope(BeatDetectContext *s, float energy, float spectral_flux)
{
    int envelope_pos = s->analysis_pos % (s->buffer_size / s->hop_size);

    float adaptive_threshold = s->mean_energy + 2.0f * sqrtf(s->energy_variance);
    float energy_component = fmaxf(0.0f, energy - adaptive_threshold);
    float onset_strength = 0.6f * energy_component + 0.4f * spectral_flux;

    s->onset_envelope[envelope_pos] = onset_strength;
    s->energy_buffer[envelope_pos] = energy;

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

/* ------------------------------------------------------------------------ */
/* Rolling analysis on the 10 s ring, unchanged apart from the prior switch  */
/* ------------------------------------------------------------------------ */

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
            s->autocorrelation[lag] = correlation / count;
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

        for (int harmonic = 1; harmonic <= 4; harmonic *= 2)
        {
            int lag = (int)(harmonic * period);
            if (lag > 0 && lag < usable_frames / 2)
            {
                response += s->autocorrelation[lag];
                harmonic_count++;
            }
        }

        s->comb_filter_bank[bpm_idx] = harmonic_count > 0 ? response / harmonic_count : 0.0f;
    }
}

static double find_peak_bpm(BeatDetectContext *s)
{
    float max_response = 0.0f;
    int max_idx = -1;

    for (int i = 0; i < COMB_FILTER_BANDS; i++)
    {
        if (s->comb_filter_bank[i] > max_response)
        {
            max_response = s->comb_filter_bank[i];
            max_idx = i;
        }
    }

    if (max_idx == -1 || max_response < 0.01f)
        return 0.0;

    double bpm = MIN_BPM + (MAX_BPM - MIN_BPM) * max_idx / (COMB_FILTER_BANDS - 1);
    double best_bpm = bpm;
    float best_score = max_response;

    if (s->tempo_prior != PRIOR_GENERAL)
    {
        // Neutral: the raw comb peak. The octave is decided at EOF from the
        // whole-track evidence, not from a preferred range.
        s->is_half_time = 0;
        return bpm;
    }

    // Legacy: prefer a subharmonic that lands in the "typical" range.
    for (int divisor = 2; divisor <= 4; divisor++)
    {
        double fundamental = bpm / divisor;
        if (fundamental >= MIN_BPM && fundamental <= MAX_BPM)
        {
            int fund_idx = (int)((fundamental - MIN_BPM) * (COMB_FILTER_BANDS - 1) / (MAX_BPM - MIN_BPM));
            if (fund_idx >= 0 && fund_idx < COMB_FILTER_BANDS)
            {
                float fund_response = s->comb_filter_bank[fund_idx];

                if (fund_response > max_response * 0.5f)
                {
                    float weight = 1.0f;
                    if (fundamental >= 80.0 && fundamental <= 110.0)
                        weight = 1.4f;
                    else if (fundamental >= 70.0 && fundamental <= 130.0)
                        weight = 1.2f;

                    float weighted_score = fund_response * weight;
                    if (weighted_score > best_score * 0.7f)
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

static double bank_prominence(const float *bank, int n)
{
    float total = 0.0f, peak = 0.0f;
    for (int i = 0; i < n; i++)
    {
        total += bank[i];
        if (bank[i] > peak)
            peak = bank[i];
    }
    if (peak <= 0.0f)
        return 0.0;
    return av_clipd(1.0 - (total / n) / peak, 0.0, 1.0);
}

static void analyze_beats(BeatDetectContext *s)
{
    if (s->frame_count < s->buffer_size / s->hop_size / 4)
        return; // Not enough data

    compute_autocorrelation(s);
    apply_comb_filters(s);

    double detected_bpm = find_peak_bpm(s);

    if (detected_bpm >= MIN_BPM && detected_bpm <= MAX_BPM)
    {
        s->detected_bpm = detected_bpm;
        s->confidence = bank_prominence(s->comb_filter_bank, COMB_FILTER_BANDS);

        if (s->bpm_history_size < s->bpm_history_capacity)
            s->bpm_history[s->bpm_history_size++] = detected_bpm;

        s->analysis_complete = 1;
    }
}

static int compare_doubles(const void *a, const void *b)
{
    double diff = *(const double *)a - *(const double *)b;
    return (diff > 0) - (diff < 0);
}

static int compare_floats_desc(const void *a, const void *b)
{
    float diff = *(const float *)b - *(const float *)a;
    return (diff > 0) - (diff < 0);
}

static double calculate_median_bpm(BeatDetectContext *s)
{
    if (s->bpm_history_size == 0)
        return s->detected_bpm;

    double *sorted = av_malloc_array(s->bpm_history_size, sizeof(double));
    if (!sorted)
        return s->detected_bpm;

    memcpy(sorted, s->bpm_history, s->bpm_history_size * sizeof(double));
    qsort(sorted, s->bpm_history_size, sizeof(double), compare_doubles);

    double median;
    if (s->bpm_history_size % 2 == 0)
        median = (sorted[s->bpm_history_size / 2 - 1] + sorted[s->bpm_history_size / 2]) / 2.0;
    else
        median = sorted[s->bpm_history_size / 2];

    av_free(sorted);
    return median;
}

/* The pre-rework EOF candidate scoring, verbatim, for tempo_prior=general. */
static double legacy_tempo_correction(double final_bpm)
{
    if (final_bpm <= 0)
        return final_bpm;

    double best_bpm = final_bpm * 2.0;

    if (final_bpm >= 40.0 && final_bpm <= 200.0)
    {
        double candidates[] = {
            final_bpm,
            final_bpm * 2.0,
            final_bpm / 1.5,
            final_bpm * 1.5,
            final_bpm / 2.0,
            final_bpm * 1.333};
        double best_score = 0.0;

        for (int i = 0; i < 6; i++)
        {
            double candidate = candidates[i];
            if (candidate < 40.0 || candidate > 200.0)
                continue;

            double score;
            if (candidate >= 90.0 && candidate <= 170.0)
            {
                score = 100.0;
                if (candidate >= 90.0 && candidate <= 100.0)
                    score = 105.0;
                else if (candidate >= 108.0 && candidate <= 114.0)
                    score = 158.0;
                else if (candidate >= 160.0 && candidate <= 170.0)
                    score = 143.0;
            }
            else if (candidate >= 70.0 && candidate <= 180.0)
                score = 80.0;
            else
                score = 50.0;

            if (i == 1)
                score += 19.0;
            if (i == 5 && candidate >= 108.0 && candidate <= 114.0 && final_bpm > 82.0)
                score += 5.0;

            if (score > best_score)
            {
                best_score = score;
                best_bpm = candidate;
            }
        }
    }

    return best_bpm;
}

/* ------------------------------------------------------------------------ */
/* Whole-track analysis at EOF                                                */
/* ------------------------------------------------------------------------ */

static inline float env_at(const float *env, int n, double pos)
{
    int i = (int)floor(pos);
    double f = pos - i;
    if (i < 0 || i >= n - 1)
        return (i == n - 1 && f == 0.0) ? env[i] : 0.0f;
    return (float)(env[i] * (1.0 - f) + env[i + 1] * f);
}

/* Autocorrelation of the mean-removed envelope, normalised per lag. */
static void global_autocorrelation(const float *env, int n, float *ac, int nlags)
{
    double mean = 0.0;
    for (int i = 0; i < n; i++)
        mean += env[i];
    mean /= FFMAX(n, 1);

    for (int lag = 0; lag < nlags; lag++)
    {
        double sum = 0.0;
        int count = n - lag;
        for (int i = 0; i < count; i++)
            sum += (env[i] - mean) * (env[i + lag] - mean);
        ac[lag] = count > 0 ? (float)(sum / count) : 0.0f;
    }
}

static inline float ac_at(const float *ac, int nlags, double lag)
{
    return env_at(ac, nlags, lag);
}

/* Comb bank over the global autocorrelation; returns the winning band. */
static int global_comb_bank(const float *ac, int nlags, double fps, float *bank)
{
    int best = -1;
    float best_response = 0.0f;

    for (int idx = 0; idx < COMB_FILTER_BANDS; idx++)
    {
        double bpm = MIN_BPM + (MAX_BPM - MIN_BPM) * idx / (COMB_FILTER_BANDS - 1);
        double period = 60.0 / bpm * fps;
        float response = 0.0f;
        int count = 0;

        for (int harmonic = 1; harmonic <= 4; harmonic *= 2)
        {
            double lag = harmonic * period;
            if (lag >= 1.0 && lag < nlags - 1)
            {
                response += ac_at(ac, nlags, lag);
                count++;
            }
        }
        bank[idx] = count > 0 ? response / count : 0.0f;
        if (bank[idx] > best_response)
        {
            best_response = bank[idx];
            best = idx;
        }
    }
    return best;
}

/* Refine a period (in frames) on the longest harmonic lag that fits, by a
 * local maximum search and parabolic interpolation. */
static double refine_period(const float *ac, int nlags, double period)
{
    for (int harmonic = 4; harmonic >= 1; harmonic /= 2)
    {
        double lag = harmonic * period;
        int centre = (int)lrint(lag);
        int span = FFMAX(1, (int)(lag * 0.03));
        int lo = FFMAX(1, centre - span), hi = FFMIN(nlags - 2, centre + span);
        if (hi <= lo || centre + span >= nlags - 1)
            continue;

        int best = lo;
        for (int l = lo; l <= hi; l++)
            if (ac[l] > ac[best])
                best = l;

        double y0 = ac[best - 1], y1 = ac[best], y2 = ac[best + 1];
        double denom = y0 - 2.0 * y1 + y2;
        double delta = denom != 0.0 ? 0.5 * (y0 - y2) / denom : 0.0;
        delta = av_clipd(delta, -0.5, 0.5);
        return (best + delta) / harmonic;
    }
    return period;
}

/* Typical onset amplitude: the mean of the top 5 % of the envelope. */
static double onset_scale(const float *env, int n)
{
    float *sorted = av_malloc_array(n, sizeof(float));
    double sum = 0.0;
    int top;

    if (!sorted)
        return 0.0;
    memcpy(sorted, env, n * sizeof(float));
    qsort(sorted, n, sizeof(float), compare_floats_desc);
    top = FFMAX(1, n / 20);
    for (int i = 0; i < top; i++)
        sum += sorted[i];
    av_free(sorted);
    return sum / top;
}

/* Mean onset strength on a grid (peak within +-w of each grid point). */
static double grid_on_mean(const float *env, int c0, int c1, double start,
                           double period, int w, int *count_out, int *covered_out,
                           double cover_level)
{
    double sum = 0.0;
    int count = 0, covered = 0;

    for (double g = start; g < c1; g += period)
    {
        int lo = FFMAX(c0, (int)floor(g) - w), hi = FFMIN(c1 - 1, (int)ceil(g) + w);
        float m = 0.0f;
        for (int f = lo; f <= hi; f++)
            if (env[f] > m)
                m = env[f];
        sum += m;
        count++;
        if (m >= cover_level)
            covered++;
    }
    *count_out = count;
    *covered_out = covered;
    return count ? sum / count : 0.0;
}

/*
 * How well a candidate period explains the onsets, per chunk at the best
 * phase, averaged over the chunks that have onsets:
 *
 *   explained  the share of the chunk's onset energy within +-w of a grid
 *              point -- a grid that skips beats (half-time, every third beat)
 *              leaves those beats unexplained;
 *   precision  the mean onset strength on the grid, over the typical onset
 *              amplitude -- a grid finer than the beat lands on weak or empty
 *              positions and scores low;
 *   coverage   the share of grid points that carry an onset at all -- a 2 s
 *              chord cycle "explains" a 60 BPM grid but only fills half of it.
 *
 * fit = explained * precision * coverage. Also returns the refined phase of
 * the first chunk with onsets, as an absolute frame position.
 */
static double grid_fit(const float *env, int n, double period, double scale,
                       int chunk_frames, unsigned char *mark, double *first_phase)
{
    double total = 0.0;
    int chunks = 0;
    int w = FFMAX(1, (int)lrint(0.03 * period));

    *first_phase = -1.0;
    if (period < 2.0 || scale <= 0.0)
        return 0.0;

    for (int c0 = 0; c0 + (int)period < n; c0 += chunk_frames)
    {
        int c1 = FFMIN(n, c0 + chunk_frames);
        double chunk_sum = 0.0, best_on = -1.0, explained = 0.0;
        int best_phase = 0, best_count = 0, best_covered = 0;
        int nphase = (int)ceil(period);

        for (int i = c0; i < c1; i++)
            chunk_sum += env[i];
        if (chunk_sum < 0.05 * scale)
            continue; // silence: no evidence either way

        for (int p = 0; p < nphase; p++)
        {
            int count, covered;
            double on = grid_on_mean(env, c0, c1, c0 + p, period, w, &count, &covered, 0.3 * scale);
            if (count > 0 && on > best_on)
            {
                best_on = on;
                best_phase = p;
                best_count = count;
                best_covered = covered;
            }
        }
        if (best_on < 0.0)
            continue;

        memset(mark, 0, c1 - c0);
        for (double g = c0 + best_phase; g < c1; g += period)
        {
            int lo = FFMAX(c0, (int)floor(g) - w), hi = FFMIN(c1 - 1, (int)ceil(g) + w);
            for (int f = lo; f <= hi; f++)
                mark[f - c0] = 1;
        }
        for (int i = c0; i < c1; i++)
            if (mark[i - c0])
                explained += env[i];
        explained /= chunk_sum;

        total += explained * av_clipd(best_on / scale, 0.0, 1.0) * ((double)best_covered / best_count);
        chunks++;

        if (*first_phase < 0.0)
        {
            // Parabolic refinement of the phase between its neighbours
            double side[2] = {0.0, 0.0};
            for (int k = 0; k < 2; k++)
            {
                int count, covered;
                double start = c0 + best_phase + (k ? 1 : -1);
                if (start < c0)
                    start += period;
                side[k] = grid_on_mean(env, c0, c1, start, period, 0, &count, &covered, 0.0);
            }
            double denom = side[0] - 2.0 * best_on + side[1];
            double delta = denom != 0.0 ? 0.5 * (side[0] - side[1]) / denom : 0.0;
            *first_phase = c0 + best_phase + av_clipd(delta, -0.5, 0.5);
        }
    }

    return chunks > 0 ? total / chunks : 0.0;
}

static double fold_to_octave(double value, double reference)
{
    if (value <= 0.0 || reference <= 0.0)
        return value;
    while (value > reference * M_SQRT2)
        value /= 2.0;
    while (value < reference / M_SQRT2)
        value *= 2.0;
    return value;
}

static double history_stability(BeatDetectContext *s, double bpm)
{
    int within = 0;
    if (s->bpm_history_size == 0 || bpm <= 0.0)
        return 0.0;
    for (int i = 0; i < s->bpm_history_size; i++)
    {
        double h = fold_to_octave(s->bpm_history[i], bpm);
        if (fabs(h - bpm) / bpm <= STABILITY_TOLERANCE)
            within++;
    }
    return (double)within / s->bpm_history_size;
}

static double frame_to_ms(BeatDetectContext *s, double frame)
{
    // Frame k spans the window ending at first_hop_end + k * hop. A transient
    // enters the window over more than one hop, so the flux peaks on the
    // frame after the one whose end first passed it: measured on the corpus,
    // the onset sits about one and a half hops before that frame's end.
    double end_sample = (double)s->first_hop_end + frame * s->hop_size - 1.5 * s->hop_size;
    return FFMAX(0.0, end_sample) * 1000.0 / s->sample_rate;
}

static void finalize_analysis(AVFilterContext *ctx)
{
    BeatDetectContext *s = ctx->priv;
    double fps = (double)s->sample_rate / s->hop_size;
    int n = FFMIN(s->track_len, (int)(GLOBAL_MAX_SECONDS * fps));
    float *ac = NULL, *bank = NULL;
    unsigned char *mark = NULL;
    double scale, prominence, separation, stability, fit;
    double chosen = 0.0, phase = -1.0;
    int nlags, best_idx, chunk_frames;

    s->have_final = 1;
    s->final_bpm = 0.0;
    s->final_confidence = 0.0;
    s->beat_offset_ms = 0.0;
    s->beat_interval_ms = 0.0;

    if (!s->analysis_complete || s->detected_bpm == 0)
        analyze_beats(s); // a last rolling pass for short inputs

    if (n < (int)(MIN_ANALYSIS_SECONDS * fps))
    {
        av_log(ctx, AV_LOG_VERBOSE, "too little audio for a tempo (%d onset frames)\n", n);
        return;
    }

    scale = onset_scale(s->track_flux, n);
    if (scale <= 0.0)
        return;

    nlags = FFMIN(n / 2, (int)(4.0 * 60.0 / MIN_BPM * fps) + 2);
    ac = av_calloc(FFMAX(nlags, 1), sizeof(float));
    bank = av_calloc(COMB_FILTER_BANDS, sizeof(float));
    if (!ac || !bank)
        goto end;

    global_autocorrelation(s->track_flux, n, ac, nlags);
    best_idx = global_comb_bank(ac, nlags, fps, bank);
    prominence = bank_prominence(bank, COMB_FILTER_BANDS);
    if (best_idx < 0 || bank[best_idx] <= 0.0f)
    {
        av_log(ctx, AV_LOG_VERBOSE, "no periodicity in the onset envelope\n");
        goto end;
    }

    chunk_frames = FFMAX((int)(GRID_CHUNK_SECONDS * fps), 4);
    mark = av_malloc(chunk_frames);
    if (!mark)
        goto end;

    if (s->tempo_prior == PRIOR_GENERAL)
    {
        chosen = legacy_tempo_correction(calculate_median_bpm(s));
        if (chosen <= 0.0)
            goto end;
        fit = grid_fit(s->track_flux, n, 60.0 / chosen * fps, scale, chunk_frames, mark, &phase);
        separation = 1.0;
    }
    else
    {
        // Candidates: the strongest local maxima of the comb bank. A periodic
        // signal puts one at every octave and integer division of the beat,
        // and the grid fit decides between them from the onsets themselves.
        int cand_idx[NB_OCTAVE_CANDIDATES];
        double cand_bpm[NB_OCTAVE_CANDIDATES], score[NB_OCTAVE_CANDIDATES], phases[NB_OCTAVE_CANDIDATES];
        float cand_resp[NB_OCTAVE_CANDIDATES];
        int ncand = 0, best = -1, second = -1;

        for (int i = 0; i < COMB_FILTER_BANDS; i++)
        {
            float left = i > 0 ? bank[i - 1] : -1.0f;
            float right = i < COMB_FILTER_BANDS - 1 ? bank[i + 1] : -1.0f;
            if (bank[i] < CANDIDATE_FLOOR * bank[best_idx] || bank[i] <= left || bank[i] < right)
                continue;
            // Keep the strongest NB_OCTAVE_CANDIDATES, sorted by response
            int pos = ncand < NB_OCTAVE_CANDIDATES ? ncand : NB_OCTAVE_CANDIDATES - 1;
            if (ncand == NB_OCTAVE_CANDIDATES && bank[i] <= cand_resp[pos])
                continue;
            while (pos > 0 && cand_resp[pos - 1] < bank[i])
            {
                cand_resp[pos] = cand_resp[pos - 1];
                cand_idx[pos] = cand_idx[pos - 1];
                pos--;
            }
            cand_resp[pos] = bank[i];
            cand_idx[pos] = i;
            if (ncand < NB_OCTAVE_CANDIDATES)
                ncand++;
        }

        for (int i = 0; i < ncand; i++)
        {
            double raw_bpm = MIN_BPM + (MAX_BPM - MIN_BPM) * cand_idx[i] / (COMB_FILTER_BANDS - 1);
            double period = refine_period(ac, nlags, 60.0 / raw_bpm * fps);
            cand_bpm[i] = 60.0 * fps / period;
            score[i] = grid_fit(s->track_flux, n, period, scale, chunk_frames, mark, &phases[i]);
            av_log(ctx, AV_LOG_VERBOSE, "candidate %.2f BPM (comb %.3f): grid fit %.3f\n",
                   cand_bpm[i], cand_resp[i] / bank[best_idx], score[i]);
            if (best < 0 || score[i] > score[best])
            {
                second = best;
                best = i;
            }
            else if (second < 0 || score[i] > score[second])
                second = i;
        }
        if (best < 0)
            goto end;

        // A near tie goes to the stronger comb response
        if (second >= 0 && score[second] >= TIE_RATIO * score[best] && cand_resp[second] > cand_resp[best])
            FFSWAP(int, best, second);

        chosen = cand_bpm[best];
        phase = phases[best];
        fit = score[best];
        separation = (second >= 0 && score[best] > 0.0)
                         ? av_clipd(1.0 - FFMAX(score[second], 0.0) / score[best], 0.0, 1.0)
                         : 1.0;
        if (score[best] <= 0.0)
            separation = 0.0;
    }

    // The grid fit is the backbone: a grid that explains strong, regular
    // onsets is trustworthy on its own. Hi-hats and ghost notes keep even a
    // perfect drum track's fit below 1 (the synthetic corpus sits at
    // 0.67-0.74), so FIT_FULL counts as a full grid. Separation from the
    // runner-up octave and agreement of the rolling detections then adjust
    // the result by at most 40 %.
    stability = history_stability(s, chosen);
    s->final_bpm = chosen;
    s->final_confidence = av_clipd(av_clipd(fit / FIT_FULL, 0.0, 1.0) * (0.6 + 0.2 * separation + 0.2 * stability), 0.0, 1.0);
    s->beat_interval_ms = 60000.0 / chosen;
    if (phase >= 0.0)
        s->beat_offset_ms = fmod(frame_to_ms(s, phase), s->beat_interval_ms);

    av_log(ctx, AV_LOG_VERBOSE,
           "final %.2f BPM: fit %.3f, prominence %.3f, separation %.3f, stability %.3f, phase frame %.2f\n",
           chosen, fit, prominence, separation, stability, phase);

end:
    av_free(ac);
    av_free(bank);
    av_free(mark);
}

/* ------------------------------------------------------------------------ */
/* Frames                                                                     */
/* ------------------------------------------------------------------------ */

static void set_frame_metadata(BeatDetectContext *s, AVFrame *frame, int final)
{
    char buf[64];
    double bpm = final ? s->final_bpm : s->detected_bpm;
    double conf = final ? s->final_confidence : s->confidence;

    snprintf(buf, sizeof(buf), "%.2f", bpm);
    av_dict_set(&frame->metadata, METADATA_PREFIX "bpm", buf, 0);
    snprintf(buf, sizeof(buf), "%.3f", conf);
    av_dict_set(&frame->metadata, METADATA_PREFIX "confidence", buf, 0);
    if (final && s->final_bpm > 0.0)
    {
        snprintf(buf, sizeof(buf), "%.2f", s->beat_interval_ms);
        av_dict_set(&frame->metadata, METADATA_PREFIX "beat_interval_ms", buf, 0);
        snprintf(buf, sizeof(buf), "%.1f", s->beat_offset_ms);
        av_dict_set(&frame->metadata, METADATA_PREFIX "beat_offset_ms", buf, 0);
    }
    av_dict_set(&frame->metadata, METADATA_PREFIX "final", final ? "1" : "0", 0);
}

static int process_frame(BeatDetectContext *s, const AVFrame *frame)
{
    int nb_samples = frame->nb_samples;
    int is_planar = av_sample_fmt_is_planar(frame->format);
    int ret;

    for (int i = 0; i < nb_samples; i++)
    {
        float sample = 0.0f;

        if (is_planar)
        {
            for (int ch = 0; ch < s->channels; ch++)
            {
                const float *channel_data = (const float *)frame->extended_data[ch];
                sample += channel_data[i] * s->ch_weight[ch];
            }
        }
        else
        {
            const float *samples = (const float *)frame->data[0];
            for (int ch = 0; ch < s->channels; ch++)
                sample += samples[i * s->channels + ch] * s->ch_weight[ch];
        }

        s->audio_buffer[s->buffer_pos] = sample;
        s->buffer_pos = (s->buffer_pos + 1) % s->buffer_size;
        s->samples_seen++;

        if (s->samples_seen % s->hop_size == 0 && s->samples_seen >= s->window_size)
        {
            int window_start = (s->buffer_pos - s->window_size + s->buffer_size) % s->buffer_size;
            float energy = 0.0f;
            float spectral_flux;

            if (s->first_hop_end < 0)
                s->first_hop_end = s->samples_seen;

            for (int j = 0; j < s->window_size; j++)
                s->window_buffer[j] = s->audio_buffer[(window_start + j) % s->buffer_size];

            for (int j = 0; j < s->window_size; j++)
                energy += s->window_buffer[j] * s->window_buffer[j];
            energy = sqrtf(energy / s->window_size);

            spectral_flux = compute_spectral_flux(s, s->window_buffer);
            update_onset_envelope(s, energy, spectral_flux);
            // The first frame's flux is the whole spectrum against an empty
            // prev_spectrum: an artificial onset at t=0 that would drag the
            // phase fit. It stays out of the whole-track envelope.
            if ((ret = push_track_flux(s, s->track_len == 0 ? 0.0f : s->grid_flux)) < 0)
                return ret;

            if (s->frame_count % ROLLING_INTERVAL == 0 || s->analysis_pos >= s->buffer_size / s->hop_size)
                analyze_beats(s);
        }
    }

    return 0;
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
        ret = process_frame(s, frame);
        if (ret < 0)
        {
            av_frame_free(&frame);
            return ret;
        }
        if (s->pending)
        {
            AVFrame *out = s->pending;
            s->pending = NULL;
            set_frame_metadata(s, out, 0);
            ret = ff_filter_frame(outlink, out);
            if (ret < 0)
            {
                av_frame_free(&frame);
                return ret;
            }
        }
        s->pending = frame;
        return 0;
    }
    if (ret < 0)
        return ret;

    if (ff_inlink_acknowledge_status(inlink, &status, &pts))
    {
        if (status == AVERROR_EOF)
        {
            finalize_analysis(ctx);

            if (s->final_bpm > 0)
            {
                // Kept byte for byte for consumers that scrape it, on both channels
                av_log(ctx, AV_LOG_INFO, "lavfi.beatdetect.bpm=%.2f \n", s->final_bpm);
                fprintf(stderr, "\nlavfi.beatdetect.bpm=%.2f \n", s->final_bpm);
                av_log(ctx, AV_LOG_INFO,
                       "lavfi.beatdetect.confidence=%.3f beat_offset_ms=%.1f beat_interval_ms=%.2f\n",
                       s->final_confidence, s->beat_offset_ms, s->beat_interval_ms);
            }
            else
            {
                fprintf(stderr, "\nlavfi.beatdetect.bpm=0.00 \n");
                av_log(ctx, AV_LOG_INFO, "lavfi.beatdetect.confidence=0.000\n");
            }

            if (s->pending)
            {
                AVFrame *out = s->pending;
                s->pending = NULL;
                set_frame_metadata(s, out, 1);
                ret = ff_filter_frame(outlink, out);
                if (ret < 0)
                    return ret;
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
    {"window_ms", "analysis window length in ms", OFFSET(window_ms), AV_OPT_TYPE_INT, {.i64 = DEFAULT_WINDOW_MS}, 5, 400, FLAGS},
    {"hop_ms", "analysis hop length in ms", OFFSET(hop_ms), AV_OPT_TYPE_INT, {.i64 = DEFAULT_HOP_MS}, 1, 100, FLAGS},
    {"window_size", "deprecated: window length in samples, overrides window_ms", OFFSET(window_size_opt), AV_OPT_TYPE_INT, {.i64 = 0}, 0, MAX_WINDOW_SIZE, FLAGS},
    {"hop_size", "deprecated: hop length in samples, overrides hop_ms", OFFSET(hop_size_opt), AV_OPT_TYPE_INT, {.i64 = 0}, 0, MAX_WINDOW_SIZE, FLAGS},
    {"peak_threshold", "set peak detection threshold", OFFSET(peak_threshold), AV_OPT_TYPE_DOUBLE, {.dbl = PEAK_THRESHOLD}, 0.1, 1.0, FLAGS},
    {"tempo_prior", "tempo range preference", OFFSET(tempo_prior), AV_OPT_TYPE_INT, {.i64 = PRIOR_NONE}, 0, PRIOR_GENERAL, FLAGS, .unit = "tempo_prior"},
    {"none", "decide the octave from the onset evidence", 0, AV_OPT_TYPE_CONST, {.i64 = PRIOR_NONE}, 0, 0, FLAGS, .unit = "tempo_prior"},
    {"general", "prefer 80-110 BPM and the pre-rework sweet spots", 0, AV_OPT_TYPE_CONST, {.i64 = PRIOR_GENERAL}, 0, 0, FLAGS, .unit = "tempo_prior"},
    {"downmix", "how multichannel input is folded to mono", OFFSET(downmix), AV_OPT_TYPE_INT, {.i64 = DOWNMIX_FRONT}, 0, DOWNMIX_ALL, FLAGS, .unit = "downmix"},
    {"front", "front channels, LFE dropped, surrounds at half weight", 0, AV_OPT_TYPE_CONST, {.i64 = DOWNMIX_FRONT}, 0, 0, FLAGS, .unit = "downmix"},
    {"all", "equal average of every channel", 0, AV_OPT_TYPE_CONST, {.i64 = DOWNMIX_ALL}, 0, 0, FLAGS, .unit = "downmix"},
    {"flux_lo_hz", "lower edge of the spectral flux band", OFFSET(flux_lo_hz), AV_OPT_TYPE_DOUBLE, {.dbl = 30.0}, 0, 20000, FLAGS},
    {"flux_hi_hz", "upper edge of the spectral flux band", OFFSET(flux_hi_hz), AV_OPT_TYPE_DOUBLE, {.dbl = 5000.0}, 100, 96000, FLAGS},
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
    .p.description = NULL_IF_CONFIG_SMALL("Detect audio BPM (beats per minute), beat grid and confidence."),
    .p.priv_class = &beatdetect_class,
    .p.flags = AVFILTER_FLAG_METADATA_ONLY,
    .priv_size = sizeof(BeatDetectContext),
    .init = init,
    .uninit = uninit,
    .activate = activate,
    FILTER_INPUTS(beatdetect_inputs),
    FILTER_OUTPUTS(beatdetect_outputs),
    FILTER_QUERY_FUNC(query_formats),
};

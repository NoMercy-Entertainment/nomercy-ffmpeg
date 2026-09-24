# Trailing-silence filter implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an FFmpeg audio filter `trailingsilence` that reports where a stream's audible content ends, through `lavfi.*` metadata and an optional JSON file.

**Architecture:** A self-contained `af_trailingsilence.c` in the style of `af_keydetect.c`, registered into FFmpeg's build by a numbered script like the other custom filters. It scans samples against a threshold, tracks the open silent run, and answers at EOF. Because the answer only exists at EOF, the filter **delays output by exactly one frame** so there is still a frame to attach the result to.

**Tech Stack:** C (FFmpeg 9.0 libavfilter), bash build scripts, Docker for the cross-builds, the repo's existing `tools/` harness pattern for tests.

**Spec:** `docs/superpowers/specs/2026-09-24-trailing-silence-design.md`

## Global Constraints

- Sample format is `AV_SAMPLE_FMT_FLTP` (planar float), declared via `FILTER_SAMPLEFMTS`; FFmpeg inserts conversion for anything else.
- The filter **must not modify audio**. It is `AVFILTER_FLAG_METADATA_ONLY`; frames pass through unchanged.
- Every metadata key is emitted on every run, including `detected=0`.
- `recommended_end = min(silence_start + safety_margin, stream_duration)`.
- Defaults, exactly: `noise=-50dB`, `duration=2`, `min_stream_duration=10`, `safety_margin=0.25`, `destination=""`, `format=json`.
- Metadata key prefix is exactly `lavfi.trailingsilence.`.
- No upstream FFmpeg source file is patched. One new `af_*.c` plus one new numbered script only.
- Conventional Commits. **Never** add self-attribution, `Co-Authored-By`, or "Generated with" lines to any commit message — absolute rule of this repository's owner.

## Review Focus

Five input classes the spec implies but does not give tasks of their own. Each has its test assigned to the task that owns the code.

1. **A stream with no frames at all** (empty or fully-skipped input) — must report `detected=0` and must not divide by zero computing duration. → Task 3.
2. **Timestamps that do not start at zero**, e.g. a segment cut from the middle — `silence_start` and `stream_duration` must be relative to the stream's own start, not absolute pts. → Task 3.
3. **`AV_NOPTS_VALUE` on a frame** — must not produce a garbage timestamp. Handled by construction: the filter never reads `frame->pts` at all, deriving every reported time from an accumulated sample count instead. Task 3 adds a test that pins this, so a later change that reaches for `pts` as a shortcut is caught rather than silently reintroducing the bug.
4. **`noise` given as a linear value** (`noise=0.001`) rather than dB — must parse and behave identically to the equivalent dB value. → Task 3.
5. **`safety_margin` larger than the trailing silence** — `recommended_end` must clamp to `stream_duration` and never exceed it. → Task 3.

---

### Task 1: Test fixtures

**Files:**
- Create: `tools/trailing-silence/make-fixtures.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: eight WAV files in a directory given as `$1`, named exactly as below. Later tasks assert against these names.

The fixtures encode every case in the spec's test table. They are generated rather than committed so the repo carries no binary blobs.

- [ ] **Step 1: Write the fixture generator**

Create `tools/trailing-silence/make-fixtures.sh`:

```bash
#!/bin/bash
# Generates the trailing-silence test fixtures. $1 = output directory,
# $2 = path to an ffmpeg binary with lavfi, sine, apad and amerge.
set -euo pipefail
OUT="${1:?output directory required}"
FF="${2:-ffmpeg}"
mkdir -p "$OUT"

# 6 s tone, then 5 s of digital silence. The headline case.
"$FF" -hide_banner -v error -f lavfi -i "sine=frequency=440:duration=6" \
    -af "apad=pad_dur=5" -t 11 -c:a pcm_s16le -y "$OUT/tail_long.wav"

# 6 s tone, then 1 s of silence: shorter than the 2 s default minimum.
"$FF" -hide_banner -v error -f lavfi -i "sine=frequency=440:duration=6" \
    -af "apad=pad_dur=1" -t 7 -c:a pcm_s16le -y "$OUT/tail_short.wav"

# 11 s tone ending abruptly, no trailing silence at all.
"$FF" -hide_banner -v error -f lavfi -i "sine=frequency=440:duration=11" \
    -c:a pcm_s16le -y "$OUT/no_tail.wav"

# Silence in the MIDDLE, audio at the end: must not be reported.
"$FF" -hide_banner -v error \
    -f lavfi -i "sine=frequency=440:duration=3" \
    -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=44100:duration=4" \
    -f lavfi -i "sine=frequency=440:duration=4" \
    -filter_complex "[0:a][1:a][2:a]concat=n=3:v=0:a=1[a]" -map "[a]" \
    -c:a pcm_s16le -y "$OUT/mid_silence.wav"

# Entirely silent, 11 s. There is no audible content to preserve.
"$FF" -hide_banner -v error \
    -f lavfi -i "anullsrc=channel_layout=mono:sample_rate=44100:duration=11" \
    -c:a pcm_s16le -y "$OUT/all_silence.wav"

# Stereo, 6 s of both channels, then LEFT silent while RIGHT keeps playing.
# All channels must be silent to count, so this must NOT be detected.
"$FF" -hide_banner -v error \
    -f lavfi -i "sine=frequency=440:duration=6" \
    -f lavfi -i "sine=frequency=440:duration=11" \
    -filter_complex "[0:a]apad=pad_dur=5[l];[l][1:a]amerge=inputs=2[a]" -map "[a]" \
    -t 11 -c:a pcm_s16le -y "$OUT/stereo_one_loud.wav"

# Stereo, both channels go silent at 6 s. Must be detected.
"$FF" -hide_banner -v error \
    -f lavfi -i "sine=frequency=440:duration=6" \
    -af "apad=pad_dur=5,pan=stereo|c0=c0|c1=c0" -t 11 \
    -c:a pcm_s16le -y "$OUT/stereo_both_quiet.wav"

# 5 s total: below the 10 s min_stream_duration, so skipped.
"$FF" -hide_banner -v error -f lavfi -i "sine=frequency=440:duration=2" \
    -af "apad=pad_dur=3" -t 5 -c:a pcm_s16le -y "$OUT/too_short.wav"

echo "fixtures written to $OUT"
ls -1 "$OUT"
```

- [ ] **Step 2: Run it and verify every fixture exists with the right duration**

```bash
bash tools/trailing-silence/make-fixtures.sh /tmp/ts-fix \
  "F:/DevProjects/NoMercyEntertainment-Developement/nomercy-ffmpeg/output/ffmpeg-9.0-windows-x86_64/ffmpeg.exe"
for f in /tmp/ts-fix/*.wav; do
  printf '%s %s\n' "$(basename "$f")" \
    "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")"
done
```

Expected: eight files. `tail_long` 11 s, `tail_short` 7 s, `no_tail` 11 s, `mid_silence` 11 s, `all_silence` 11 s, `stereo_one_loud` 11 s, `stereo_both_quiet` 11 s, `too_short` 5 s.

- [ ] **Step 3: Verify the stereo fixtures really differ**

The `stereo_one_loud` fixture is the one most likely to be wrong in a way that quietly makes a later test vacuous. Prove the channels differ after 6 s:

```bash
ffprobe -v error -f lavfi -i "amovie=/tmp/ts-fix/stereo_one_loud.wav,channelsplit=channel_layout=stereo[l][r];[l]astats[a]" -show_entries frame_tags=lavfi.astats.Overall.RMS_level -of csv=p=0 2>/dev/null | tail -1
```

Expected: the left channel's RMS over the last seconds is far below the right channel's. If they match, the fixture is wrong — fix it before continuing, because `stereo_one_loud` is the only test that proves the all-channels rule.

- [ ] **Step 4: Commit**

```bash
git add tools/trailing-silence/make-fixtures.sh
git commit -m "test(trailingsilence): generator for the trailing-silence fixtures"
```

---

### Task 2: Filter skeleton, registration, and a build that loads it

**Files:**
- Create: `scripts/includes/af_trailingsilence.c`
- Create: `scripts/61-trailing-silence.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: a registered filter named `trailingsilence` with the full option set, which emits `lavfi.trailingsilence.detected=0` and nothing else. Task 3 replaces the body of the detection logic; the option names, the context field names and the metadata prefix defined here are what Task 3 and Task 4 build on.

This task deliberately ships a filter that always answers `detected=0`. That is a real, testable deliverable: it proves registration, option parsing, format negotiation and metadata emission work before any detection logic exists to confuse the diagnosis.

- [ ] **Step 1: Write the filter**

Create `scripts/includes/af_trailingsilence.c`:

```c
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
```

- [ ] **Step 2: Write the registration script**

Create `scripts/61-trailing-silence.sh`, following `scripts/57-keydetect.sh` exactly:

```bash
#!/bin/bash

#/******************************/#
#/*  Made by Phillippe Pelzer  */#
#/*  https://github.com/Fill84 */#
#/******************************/#

cp /scripts/includes/af_trailingsilence.c /build/ffmpeg/libavfilter/af_trailingsilence.c

log "Step 1: Adding extern declaration to allfilters.c"
if ! grep -q "ff_af_trailingsilence" /build/ffmpeg/libavfilter/allfilters.c; then
    sed -i '0,/^extern const FFFilter ff_af_volumedetect;$/s//&\nextern const FFFilter ff_af_trailingsilence;/' /build/ffmpeg/libavfilter/allfilters.c
    log "  ✓ Added extern declaration"
else
    log "  ✓ Extern declaration already exists"
fi

if grep -q "ff_af_trailingsilence" /build/ffmpeg/libavfilter/allfilters.c; then
    log "  ✓ Verified in allfilters.c"
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

log "Step 2: Adding to Makefile"
if ! grep -q "af_trailingsilence.o" /build/ffmpeg/libavfilter/Makefile; then
    sed -i '/^OBJS-\$(CONFIG_ABENCH_FILTER)/a\
OBJS-$(CONFIG_TRAILINGSILENCE_FILTER)    += af_trailingsilence.o' /build/ffmpeg/libavfilter/Makefile
    log "  ✓ Added to Makefile"
else
    log "  ✓ Makefile entry already exists"
fi

if grep -q "af_trailingsilence.o" /build/ffmpeg/libavfilter/Makefile; then
    log "  ✓ Verified in Makefile"
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

log "Step 3: Adding filter dependencies to configure script"
if ! grep -q "trailingsilence_filter_deps" /build/ffmpeg/configure; then
    sed -i '/^abench_filter_deps=/i trailingsilence_filter_deps="lm"' /build/ffmpeg/configure
    log "  ✓ Added filter dependencies"
else
    log "  ✓ Filter dependencies already exist"
fi

exit 0
```

- [ ] **Step 3: Build linux-x86_64 and verify the filter is registered**

The repo builds each platform through docker compose; the base image must exist
first, and `ffmpeg-base.dockerfile` is what downloads and prepares the FFmpeg
tree that `scripts/61-trailing-silence.sh` patches:

```bash
docker compose build ffmpeg-base
docker compose build ffmpeg-linux-x86_64
docker compose run --rm ffmpeg-linux-x86_64
```

The build artefact lands in `./output/`. Unpack it and work from that binary:

```bash
tar -xzf output/ffmpeg-9.0-linux-x86_64.tar.gz -C /tmp/ts-build
```

A full platform build is slow. While iterating on the C file, rebuilding only
the `ffmpeg-linux-x86_64` stage is enough — the base image carries the
dependencies and does not need rebuilding unless `ffmpeg-base.dockerfile`
changes. Then, on the resulting binary:

```bash
./ffmpeg -hide_banner -filters | grep trailingsilence
./ffmpeg -hide_banner -h filter=trailingsilence
```

Expected: the filter is listed, and `-h` prints all six options with the documented defaults (`noise`, `duration`, `min_stream_duration`, `safety_margin`, `destination`, `format`).

- [ ] **Step 4: Verify it emits keys and passes audio through untouched**

```bash
./ffmpeg -hide_banner -nostats -i /tmp/ts-fix/tail_long.wav \
    -af "trailingsilence,ametadata=mode=print" -f null - 2>&1 | grep trailingsilence
./ffmpeg -hide_banner -v error -i /tmp/ts-fix/tail_long.wav -af trailingsilence -f wav - | md5sum
./ffmpeg -hide_banner -v error -i /tmp/ts-fix/tail_long.wav -f wav - | md5sum
```

Expected: `detected=0`, `stream_duration` and `recommended_end` present; and the two md5s are **identical** — the filter must not alter a single sample. If they differ, stop: `AVFILTER_FLAG_METADATA_ONLY` is being violated.

- [ ] **Step 5: Commit**

```bash
git add scripts/includes/af_trailingsilence.c scripts/61-trailing-silence.sh
git commit -m "feat(trailingsilence): filter skeleton, options and registration"
```

---

### Task 3: Detection

**Files:**
- Modify: `scripts/includes/af_trailingsilence.c` (replace `scan_frame` and `set_report`)
- Create: `tools/trailing-silence/run-cases.sh`

**Interfaces:**
- Consumes: the context fields and option names from Task 2.
- Produces: the full metadata set — `detected`, `silence_start`, `silence_duration`, `stream_duration`, `recommended_end`, `safety_margin` — which Task 4 serialises to JSON.

- [ ] **Step 1: Write the failing test harness**

Create `tools/trailing-silence/run-cases.sh`. It asserts values, not merely that the filter ran:

```bash
#!/bin/bash
# $1 = fixture dir, $2 = ffmpeg binary. Exits 1 on any mismatch.
set -uo pipefail
FIX="${1:?fixture dir required}"; FF="${2:?ffmpeg required}"
fail=0

get() { # $1 file, $2 key, $3 extra filter args
    "$FF" -hide_banner -nostats -i "$FIX/$1" \
        -af "trailingsilence${3:+=$3},ametadata=mode=print" -f null - 2>&1 \
      | sed -n "s/^.*lavfi\.trailingsilence\.$2=//p" | tail -1
}

check() { # $1 label, $2 actual, $3 expected
    if [[ "$2" == "$3" ]]; then
        echo "  ok    $1: $2"
    else
        echo "  FAIL  $1: got '$2', expected '$3'"; fail=1
    fi
}

check "tail_long detected"        "$(get tail_long.wav detected)"          "1"
check "tail_short detected"       "$(get tail_short.wav detected)"         "0"
check "no_tail detected"          "$(get no_tail.wav detected)"            "0"
check "mid_silence detected"      "$(get mid_silence.wav detected)"        "0"
check "all_silence detected"      "$(get all_silence.wav detected)"        "0"
check "stereo_one_loud detected"  "$(get stereo_one_loud.wav detected)"    "0"
check "stereo_both_quiet detected" "$(get stereo_both_quiet.wav detected)" "1"
check "too_short detected"        "$(get too_short.wav detected)"          "0"

# The measurement itself, to 0.1 s.
start=$(get tail_long.wav silence_start)
printf -v rounded '%.1f' "$start"
check "tail_long silence_start"   "$rounded"                               "6.0"

# Advice = measurement + margin, and both are reported.
end=$(get tail_long.wav recommended_end)
printf -v rounded_end '%.2f' "$end"
check "tail_long recommended_end" "$rounded_end"                           "6.25"

# Review Focus 5: a margin larger than the silence clamps to the stream end.
end=$(get tail_long.wav recommended_end "safety_margin=30")
printf -v rounded_end '%.1f' "$end"
check "clamped recommended_end"   "$rounded_end"                           "11.0"

# Review Focus 4: linear noise behaves like the equivalent dB value.
check "linear noise"              "$(get tail_long.wav detected "noise=0.00316227766")" "1"

# Review Focus 3: timestamps must not come from pts. Strip them entirely with
# setpts and the answer must be unchanged -- if a later edit reaches for
# frame->pts as a shortcut, this is what catches it.
nopts=$("$FF" -hide_banner -nostats -i "$FIX/tail_long.wav" \
          -af "asetpts=NAN,trailingsilence,ametadata=mode=print" -f null - 2>&1 \
        | sed -n 's/^.*lavfi\.trailingsilence\.silence_start=//p' | tail -1)
printf -v rounded_nopts '%.1f' "${nopts:-0}"
check "silence_start without pts" "$rounded_nopts"                         "6.0"

# Review Focus 2: a stream that does not start at pts 0 still measures from
# its own start, not from absolute pts.
mid=$("$FF" -hide_banner -v error -ss 2 -i "$FIX/tail_long.wav" \
        -af "trailingsilence,ametadata=mode=print" -f null - 2>&1 \
      | sed -n 's/^.*lavfi\.trailingsilence\.silence_start=//p' | tail -1)
printf -v rounded_mid '%.1f' "$mid"
check "offset stream silence_start" "$rounded_mid"                         "4.0"

exit $fail
```

- [ ] **Step 2: Run it against the Task 2 build and watch it fail**

```bash
bash tools/trailing-silence/run-cases.sh /tmp/ts-fix ./ffmpeg
```

Expected: FAIL on every `detected=1` case, because Task 2 always answers `0`. This confirms the harness can actually fail before any detection exists — a check that cannot fail is worse than no check.

- [ ] **Step 3: Implement the scan**

Replace `scan_frame` in `scripts/includes/af_trailingsilence.c`:

```c
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
```

- [ ] **Step 4: Implement the report**

Replace `set_report`:

```c
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

    s->reported = 1;
}
```

Note `s->silent_run_start > 0` rather than `>= 0`: a run starting at sample 0 is an entirely silent stream, which the spec says must report `detected=0`.

- [ ] **Step 5: Handle the no-frames case (Review Focus 1)**

EOF can arrive with `s->held == NULL` — an empty input, or one where every frame was consumed elsewhere. The Task 2 `activate` already skips reporting then, which is correct behaviour but silent. Make it explicit by emitting the report through the log so the caller still learns the filter ran:

```c
        if (status == AVERROR_EOF) {
            if (s->held) {
                set_report(ctx, s->held);
                ret = ff_filter_frame(outlink, s->held);
                s->held = NULL;
                if (ret < 0)
                    return ret;
            } else if (!s->reported) {
                /* No frame ever arrived, so there is nothing to attach
                 * metadata to. Say so rather than exiting silently. */
                av_log(ctx, AV_LOG_INFO,
                       "trailingsilence: no audio frames seen; nothing to report.\n");
            }
            ff_outlink_set_status(outlink, AVERROR_EOF, pts);
            return 0;
        }
```

- [ ] **Step 6: Rebuild and run the cases**

```bash
bash tools/trailing-silence/run-cases.sh /tmp/ts-fix ./ffmpeg
```

Expected: every line `ok`, exit 0.

- [ ] **Step 7: Verify the empty-input case does not crash**

```bash
./ffmpeg -hide_banner -v info -f lavfi -i "anullsrc=d=0" -af trailingsilence -f null - 2>&1 | tail -3
echo "exit=$?"
```

Expected: exits 0, no crash, and either a report or the "no audio frames seen" line.

- [ ] **Step 8: Commit**

```bash
git add scripts/includes/af_trailingsilence.c tools/trailing-silence/run-cases.sh
git commit -m "feat(trailingsilence): detect the trailing run and report it"
```

---

### Task 4: The JSON report

**Files:**
- Modify: `scripts/includes/af_trailingsilence.c`
- Modify: `tools/trailing-silence/run-cases.sh`

**Interfaces:**
- Consumes: the six values computed in Task 3's `set_report`.
- Produces: a JSON file at `destination` carrying the same six fields under the same names, minus the `lavfi.trailingsilence.` prefix.

- [ ] **Step 1: Add the failing assertion**

Append to `tools/trailing-silence/run-cases.sh`, before `exit $fail`:

```bash
# The JSON report must agree with the metadata field for field -- they come
# from one computation and a test should hold them to that.
rm -f /tmp/ts-report.json
"$FF" -hide_banner -nostats -i "$FIX/tail_long.wav" \
    -af "trailingsilence=destination=/tmp/ts-report.json,ametadata=mode=print" \
    -f null - >/tmp/ts-meta.txt 2>&1
for k in detected silence_start silence_duration stream_duration recommended_end safety_margin; do
    meta=$(sed -n "s/^.*lavfi\.trailingsilence\.$k=//p" /tmp/ts-meta.txt | tail -1)
    json=$(sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^,\"}]*\).*/\1/p" /tmp/ts-report.json | head -1)
    check "json $k matches metadata" "$json" "$meta"
done
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — no file is written yet, so every `json ...` line reports an empty value.

- [ ] **Step 3: Write the report file**

Add to `af_trailingsilence.c`, and call `write_report(ctx, ...)` from the end of `set_report`:

```c
static void write_report(AVFilterContext *ctx, int detected,
                         double silence_start, double silence_duration,
                         double stream_duration, double recommended_end,
                         double margin)
{
    TrailingSilenceContext *s = ctx->priv;
    AVIOContext *out = NULL;
    char buf[512];
    int ret;

    if (!s->destination || !*s->destination)
        return;

    if (av_strcasecmp(s->format, "json")) {
        av_log(ctx, AV_LOG_ERROR,
               "trailingsilence: unknown format '%s'; only 'json' is supported.\n",
               s->format);
        return;
    }

    ret = avio_open(&out, s->destination, AVIO_FLAG_WRITE);
    if (ret < 0) {
        av_log(ctx, AV_LOG_ERROR, "trailingsilence: could not open %s: %s\n",
               s->destination, av_err2str(ret));
        return;
    }

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

    avio_write(out, (const unsigned char *)buf, strlen(buf));
    avio_closep(&out);
}
```

Add `#include "libavformat/avio.h"` to the includes.

- [ ] **Step 4: Rebuild, run the cases, and check the JSON parses**

```bash
bash tools/trailing-silence/run-cases.sh /tmp/ts-fix ./ffmpeg
cat /tmp/ts-report.json | python3 -m json.tool
```

Expected: all `ok`, and the JSON parses cleanly.

- [ ] **Step 5: Verify a bad destination fails loudly, not silently**

```bash
./ffmpeg -hide_banner -v error -i /tmp/ts-fix/tail_long.wav \
    -af "trailingsilence=destination=/nonexistent-dir/r.json" -f null - 2>&1 | tail -2
```

Expected: a clear error naming the path. The run may still succeed — the report is a side channel — but it must not fail silently.

- [ ] **Step 6: Commit**

```bash
git add scripts/includes/af_trailingsilence.c tools/trailing-silence/run-cases.sh
git commit -m "feat(trailingsilence): write the JSON report to destination"
```

---

### Task 5: Documentation and the smoke check

**Files:**
- Modify: `README.md`
- Modify: `tests/smoke.sh`, `tests/smoke.ps1`

**Interfaces:**
- Consumes: the finished filter.
- Produces: nothing other tasks use.

- [ ] **Step 1: Document the filter in README.md**

Add a section in the style of the other custom filters. It must state: what it reports and that it does **not** cut; the option table with defaults; the metadata keys, marking which are measurements and which are advice; that keys are emitted even when `detected=0`, with `recommended_end` at the stream duration; and the two-step usage.

```
ffmpeg -i in.mka -af trailingsilence=destination=report.json -f null -
ffmpeg -i in.mka -to <recommended_end> -c copy out.mka
```

- [ ] **Step 2: Add the smoke assertion**

In `tests/smoke.sh` and `tests/smoke.ps1`, assert the filter exists in the built binary and that it answers on a generated fixture. Assert a **value**, not that the command ran:

```bash
ts_out=$("$FFMPEG" -hide_banner -nostats -f lavfi -i "sine=frequency=440:duration=6" \
    -af "apad=pad_dur=5,atrim=end=11,trailingsilence,ametadata=mode=print" -f null - 2>&1 \
  | sed -n 's/^.*lavfi\.trailingsilence\.detected=//p' | tail -1)
if [[ "$ts_out" != "1" ]]; then
    echo "FAIL: trailingsilence did not detect the tail (got '$ts_out')"; fail=1
fi
```

- [ ] **Step 3: Prove the smoke assertion can fail**

Temporarily change `duration=2` to `duration=30` in the command and confirm the assertion reports FAIL. Revert.

Expected: FAIL is produced. An assertion that cannot fail is worse than none — three checks in this repository were silently broken for exactly this reason.

- [ ] **Step 4: Commit**

```bash
git add README.md tests/smoke.sh tests/smoke.ps1
git commit -m "docs(trailingsilence): document the filter and assert it in the smoke tests"
```

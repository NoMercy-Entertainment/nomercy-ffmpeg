# Trailing-silence detection — design

Issue: [#25](https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/issues/25).
Date: 2026-09-24. Status: approved by the owner, ready for an implementation plan.

## Purpose

Audio streams often end in dead air — padding, muxer artefacts, or a long tail
after the last real sound. Players have to run through it before the next track
or next-episode hint fires, which kills pacing. This adds a detector that reports
where a stream's audible content actually ends, so the server can store that
point and the player can respect it.

**The detector reports. It does not cut.** Trimming stays with the caller.

## What the owner decided

Five decisions, taken 2026-09-24, each of which shaped the design:

1. **It runs both ways** — riding along with an existing transcode, and as a
   standalone probe pass. That makes it a filter: only a filter can ride along
   without paying for a second decode, and a probe pass is then just the same
   filter with `-f null -`.
2. **Report through both channels** — `lavfi.*` metadata *and* an optional JSON
   file. The values are computed once, so the second delivery route is nearly
   free, and it spares the server from parsing ffmpeg's log output during a
   transcode.
3. **No trim mode.** The caller uses `-to <recommended_end>`, which ffmpeg
   already does well and can often do with `-c copy`. In-filter trimming would
   mean buffering the entire candidate tail in RAM — an input-dependent memory
   profile, which is exactly what made #70 painful.
4. **Its own filter, not a wrapper.** See "Why not wrap silencedetect" below.
5. **Report measurement and advice separately**, and **always report**, even when
   nothing is found.

## Why not wrap silencedetect

The issue proposed wrapping FFmpeg's `silencedetect`. That was written before
anyone measured what `silencedetect` actually does at end-of-stream. It was
measured (FFmpeg 9.0, 6 s tone followed by 5 s of silence):

```
[Parsed_silencedetect_0] silence_start: 6
[Parsed_silencedetect_0] silence_end: 11 | silence_duration: 5
```

It closes the final interval cleanly at EOF, so a wrapper would work. But the
measurement also showed how little of `silencedetect` this needs: one threshold
comparison across all channels. Three routes were weighed:

- **Consume `silencedetect`'s metadata** from a chained filter. No duplicated
  DSP, and all its options come free — but the contract becomes "you must put
  another filter in front of us", and we would depend on metadata keys owned by
  upstream.
- **Extend `silencedetect` itself.** This repo does patch upstream files
  (`hlsenc.c`), so it fits the house style — but every FFmpeg bump then carries
  merge work, for something that can live in its own file.
- **Its own filter** — chosen. The DSP being duplicated is a threshold
  comparison; the coupling avoided is worth more than the few lines saved. One
  new file, no upstream patch, no dependency on keys we do not own, and the
  server adds one filter rather than wiring a chain correctly.

## The filter

New file `scripts/includes/af_trailingsilence.c`, registered by
`scripts/61-trailing-silence.sh`, following the pattern established by
`af_keydetect.c` / `scripts/57-keydetect.sh`.

### Detection

A sample position is *silent* when the maximum absolute sample value across
**all channels** at that position is below the threshold. The issue's requirement
that multi-channel content only counts as silent when every channel is silent
falls out of taking the maximum across channels rather than a per-channel
decision.

**Resolution is per sample, not per frame.** The filter scans within each frame
rather than classifying whole frames, so `silence_start` lands on the actual
sample where the tail begins rather than on a frame boundary. At a typical 1024
sample frame this is the difference between ~21 ms of granularity and exact — and
since the reported value is what the server will cut on, it should be the real
one.

The filter tracks the timestamp at which the current silent run began, and resets
it the moment a non-silent sample arrives. At EOF the question is already
answered: if a run is open, it began at `silence_start` and reaches the end of
the stream.

A result qualifies when **both** hold:
- the open run is at least `duration` long, which is what protects a genuine
  fade-out from being reported as dead air; and
- the stream is at least `min_stream_duration` long.

### Options

| option | type | default | meaning |
|---|---|---|---|
| `noise` / `n` | string | `-50dB` | silence threshold, dB or linear, as `silencedetect` accepts |
| `duration` / `d` | duration | `2` | minimum length of the trailing silence |
| `min_stream_duration` | duration | `10` | streams shorter than this are skipped |
| `safety_margin` | duration | `0.25` | how far after `silence_start` the advice sits |
| `destination` | string | *(empty)* | path for the JSON report; empty disables it |
| `format` | string | `json` | report format; `json` is the only accepted value for now, and the option exists so a second format can be added without changing the interface |

`recommended_end` is **clamped to the stream duration**. It is
`min(silence_start + safety_margin, stream_duration)`, so a `safety_margin`
larger than the silence it sits in can never produce a cut point past the end of
the stream.

### What it reports

Measurement and advice are reported **separately**, because they are different
kinds of claim and the server should be able to tell them apart:

| key | meaning |
|---|---|
| `lavfi.trailingsilence.detected` | `1` or `0` |
| `lavfi.trailingsilence.silence_start` | **measured**: where the trailing silence begins |
| `lavfi.trailingsilence.silence_duration` | **measured**: how long it runs |
| `lavfi.trailingsilence.stream_duration` | **measured**: total duration seen |
| `lavfi.trailingsilence.recommended_end` | **advice**: `silence_start + safety_margin` |
| `lavfi.trailingsilence.safety_margin` | the margin used, so the advice can be undone |

`recommended_end` is advice, not a measurement: a very quiet outro can sit below
the threshold while still being audible on good speakers, so the advice sits a
little later than the measurement. Reporting both means the server can take
either, and can see which is which.

**The keys are always emitted, including when nothing is found.** When
`detected=0`, `recommended_end` equals the stream duration, so a caller may use
it unconditionally without special-casing. This is deliberate: if the filter
stayed silent on a negative result, the server could not distinguish "scanned,
found nothing" from "the filter never ran" — and this codebase produced three
separate instances of exactly that failure during the preceding week's work
(checks that were silently broken and read as passes).

Metadata lands on the final frame, since that is the first moment the answer
exists. The JSON report, when `destination` is set, carries the same fields.

### Skipped cases

- **Live or streaming input.** This needs no detection mechanism and the filter
  does not attempt one. The report is produced at EOF; a stream that never ends
  never reaches that point, so it simply never reports. The issue lists this as an
  edge case to handle, and the honest answer is that the design handles it by
  construction rather than by testing for it.
- **Streams shorter than `min_stream_duration`**: skipped, `detected=0`.
- **A fully silent stream**: `detected=0` — there is no audible content to
  preserve, so a recommended cut point would be meaningless and dangerous.
- **Silence in the middle** that does not reach the end: not reported. Only a run
  that is still open at EOF qualifies.

## Testing

Fixtures with known tails, each asserting the exact reported values:

| fixture | expectation |
|---|---|
| tone, then silence longer than `d` | `detected=1`, `silence_start` at the boundary |
| tone, then silence shorter than `d` | `detected=0` |
| tone ending abruptly, no silence | `detected=0` |
| silence in the middle, audio at the end | `detected=0` |
| fully silent stream | `detected=0` |
| multi-channel, one channel loud to the end | `detected=0` |
| multi-channel, all channels silent at the end | `detected=1` |
| stream shorter than `min_stream_duration` | `detected=0` |

Plus a real track through the existing Docker harness, and an assertion that the
JSON report and the metadata agree field for field — they come from one
computation, and a test should hold them to that.

Every test asserts a *value*, not merely that the filter ran. A check that cannot
fail is worse than no check.

## Out of scope

- **Trimming.** The caller uses `-to <recommended_end>`.
- **Leading silence.** Not asked for; the same filter could grow it later.
- **Video.** Audio filter only.

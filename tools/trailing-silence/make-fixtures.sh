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

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

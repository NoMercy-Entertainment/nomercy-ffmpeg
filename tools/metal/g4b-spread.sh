#!/bin/bash
# Gate 4b's measurement, repeated, to see whether its verdict means anything.
# Same shape as tools/metal/verify-on-mac.sh: warm the Metal path once, then
# time -t 30 per side. Alternates cpu/metal so thermal drift cannot favour
# whichever side runs last. bash 3.2 only -- macOS stock /bin/bash.
set -uo pipefail

WORKDIR="${1:?usage: g4b-spread.sh <workdir> [runs]}"
RUNS="${2:-7}"
FF="${WORKDIR%/}/ffmpeg"
MODEL="${WORKDIR%/}/spleeter-2stems-f16.gguf"
INPUT="${WORKDIR%/}/input.mp3"

for f in "$FF" "$MODEL" "$INPUT"; do
    [ -f "$f" ] || { echo "missing: $f"; exit 1; }
done

run_one() {  # run_one <use_gpu>
    TIMEFORMAT='%R'
    { time "$FF" -hide_banner -loglevel error -nostats -t 30 -i "$INPUT" -vn \
        -af "stemsplit=model=${MODEL}:stem=accompaniment:use_gpu=$1" \
        -f null - >/dev/null 2>&1; } 2>&1
}

echo "warming the Metal path (one-time shader compile, not timed)"
"$FF" -hide_banner -loglevel error -nostats -t 1 -i "$INPUT" -vn \
    -af "stemsplit=model=${MODEL}:stem=accompaniment:use_gpu=1" -f null - >/dev/null 2>&1

CPU_FILE="${WORKDIR%/}/.cpu_times"
MTL_FILE="${WORKDIR%/}/.mtl_times"
: > "$CPU_FILE"; : > "$MTL_FILE"

echo
printf "  %-5s %10s %10s %9s\n" "run" "cpu" "metal" "ratio"
i=1
while [ "$i" -le "$RUNS" ]; do
    c="$(run_one 0)"; m="$(run_one 1)"
    echo "$c" >> "$CPU_FILE"; echo "$m" >> "$MTL_FILE"
    r="$(awk -v c="$c" -v m="$m" 'BEGIN{ if (m>0) printf "%.3f", c/m; else print "n/a" }')"
    printf "  %-5s %10s %10s %9s\n" "$i" "$c" "$m" "$r"
    i=$((i + 1))
done

median() {  # median <file>
    sort -n "$1" | awk '{v[NR]=$1} END{ if (NR%2) print v[(NR+1)/2]; else printf "%.3f", (v[NR/2]+v[NR/2+1])/2 }'
}
spread() { # spread <file>  -> min..max
    printf "%s..%s" "$(sort -n "$1" | head -1)" "$(sort -n "$1" | tail -1)"
}

CPU_MED="$(median "$CPU_FILE")"; MTL_MED="$(median "$MTL_FILE")"
echo
echo "  cpu   median ${CPU_MED}s   spread $(spread "$CPU_FILE")"
echo "  metal median ${MTL_MED}s   spread $(spread "$MTL_FILE")"
awk -v c="$CPU_MED" -v m="$MTL_MED" 'BEGIN{
    printf "  metal/cpu on medians: %.3f  (%+.1f%% vs cpu)\n", m/c, (m/c-1)*100 }'

rm -f "$CPU_FILE" "$MTL_FILE"

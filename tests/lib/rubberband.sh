#!/bin/bash
# rubberband: tempo and pitch independently, on both engines, without delay.
# The input is 1 s of silence and then 3 s of a 440 Hz sine (48 kHz, 4 s).
# Each check measures three things on the output:
#  - length: exactly round(192000 / tempo) samples (astats' running count);
#  - start: the sine starts at 1/tempo s, within 10 ms. silencedetect with
#    n=0.5 reports the first sample above half amplitude. Measured with the
#    patched filter: at most 4.7 ms off; the unpatched one was 15 ms off at
#    tempo=2 and 32 ms at pitch=0.5;
#  - pitch: the spectral centroid of every window in the middle of the sine
#    is within 10 % of 440 Hz x pitch (aspectralstats).
# A filter that did nothing, swapped tempo and pitch, ignored the engine or
# shifted the output in time fails at least one of them.
_RB_SOURCE="aevalsrc='if(gte(t,1),sin(2*PI*440*t),0)':s=48000:d=4"

_rubberband_check() (
    local engine="$1" tempo="$2" pitch="$3"
    local option="tempo=${tempo}:pitch=${pitch}:engine=${engine}" work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "${work}"' EXIT
    local want_samples want_start want_hz from to
    want_samples=$(awk -v t="${tempo}" 'BEGIN { printf "%d", 192000 / t + 0.5 }')
    want_start=$(awk -v t="${tempo}" 'BEGIN { printf "%.6f", 1 / t }')
    want_hz=$(awk -v p="${pitch}" 'BEGIN { printf "%.1f", 440 * p }')
    from=$(awk -v t="${tempo}" 'BEGIN { printf "%.3f", 1.75 / t }')
    to=$(awk -v t="${tempo}" 'BEGIN { printf "%.3f", 3.25 / t }')

    "${FFMPEG}" -hide_banner -loglevel error -filter_complex \
        "${_RB_SOURCE},rubberband=${option},silencedetect=n=0.5:d=0.05,astats=metadata=1:reset=0,ametadata=mode=print:file=-" \
        -f null - >"${work}/run.txt" 2>"${work}/run.log" || {
            cat "${work}/run.log"
            return 1
        }
    local samples start
    samples=$(awk -F= '/^lavfi.astats.Overall.Number_of_samples=/ { sub(/\r$/, "", $2); last=$2 } END { print last }' "${work}/run.txt")
    start=$(awk -F= '/^lavfi.silence_end=/ { sub(/\r$/, "", $2); print $2; exit }' "${work}/run.txt")
    if [[ ! ${samples} =~ ^[0-9]+([.]0+)?$ || ${samples%%.*} -ne ${want_samples} ]]; then
        echo "rubberband ${option}: ${samples:-no} samples, expected exactly ${want_samples}"
        cat "${work}/run.log"
        return 1
    fi
    if [[ ! ${start} =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "rubberband ${option}: no start of the sine found"
        return 1
    fi
    if ! awk -v got="${start}" -v want="${want_start}" 'BEGIN { d = got - want; exit !(d <= 0.010 && d >= -0.010) }'; then
        echo "rubberband ${option}: the sine starts at ${start} s, expected ${want_start} s (10 ms tolerance)"
        return 1
    fi

    "${FFMPEG}" -hide_banner -loglevel error -filter_complex \
        "${_RB_SOURCE},rubberband=${option},atrim=start=${from}:end=${to},aspectralstats,ametadata=mode=print:key=lavfi.aspectralstats.1.centroid:file=-" \
        -f null - >"${work}/pitch.txt" 2>"${work}/pitch.log" || {
            cat "${work}/pitch.log"
            return 1
        }
    # The first and the last window are left out: atrim's hard cut and the
    # half-filled last window smear the spectrum even on the plain sine
    # without rubberband (measured: 3332 Hz and 691 Hz for 440 Hz).
    if ! awk -F= -v want="${want_hz}" '
        /^lavfi.aspectralstats.1.centroid=/ {
            sub(/\r$/, "", $2)
            v[++n]=$2
        }
        END {
            for (i = 2; i < n; i++) {
                if (v[i] !~ /^[0-9]+([.][0-9]+)?(e[+-]?[0-9]+)?$/) bad=1
                else if (v[i] + 0 < want * 0.9 || v[i] + 0 > want * 1.1) bad=1
            }
            exit (bad || n < 12)
        }
    ' "${work}/pitch.txt"; then
        echo "rubberband ${option}: spectral centroid not at ${want_hz} Hz in every window"
        cat "${work}/pitch.txt"
        return 1
    fi
    echo "rubberband ${option}: ${want_samples} samples, starts at ${start} s (expected ${want_start}), centroid at ${want_hz} Hz"
)

# The engine option must change the processing: the same input and ratios
# through faster (R2) and finer (R3) give different samples. A filter that
# accepted engine= and ignored it would pass every check above.
test_rubberband_engines_differ() {
    local faster finer
    faster=$("${FFMPEG}" -hide_banner -loglevel error -filter_complex \
        "${_RB_SOURCE},rubberband=tempo=1.5:engine=faster" -f hash -hash md5 - 2>&1) || { echo "${faster}"; return 1; }
    finer=$("${FFMPEG}" -hide_banner -loglevel error -filter_complex \
        "${_RB_SOURCE},rubberband=tempo=1.5:engine=finer" -f hash -hash md5 - 2>&1) || { echo "${finer}"; return 1; }
    if [[ ${faster} != MD5=* || ${finer} != MD5=* ]]; then
        echo "rubberband engines: no checksum (${faster} / ${finer})"
        return 1
    fi
    if [[ ${faster} == "${finer}" ]]; then
        echo "rubberband engines: faster and finer give identical output (${faster}); engine= has no effect"
        return 1
    fi
    echo "rubberband engines: faster ${faster#MD5=}, finer ${finer#MD5=}"
}

test_rubberband_tempo() { _rubberband_check faster 2 1; }
test_rubberband_pitch() { _rubberband_check faster 1 0.5; }
test_rubberband_finer_tempo() { _rubberband_check finer 1.05 1; }
test_rubberband_finer_pitch() { _rubberband_check finer 1 2; }

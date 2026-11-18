#!/bin/bash
# libsoxr: resample a 4 s, 440 Hz sine from 48 kHz to 44.1 kHz with
# resampler=soxr. Without libsoxr, aresample stops with "Requested
# resampling engine is unavailable", so a passing run used soxr. The output
# must be 176400 samples long and still at 440 Hz.
test_soxr() (
    local work
    work=$(mktemp -d) || return 1
    trap 'rm -rf "${work}"' EXIT
    local source="aevalsrc='sin(2*PI*440*t)':s=48000:d=4,aresample=44100:resampler=soxr"

    "${FFMPEG}" -hide_banner -loglevel error -filter_complex \
        "${source},astats=metadata=1:reset=0,ametadata=mode=print:key=lavfi.astats.Overall.Number_of_samples:file=-" \
        -f null - >"${work}/length.txt" 2>"${work}/length.log" || {
            cat "${work}/length.log"
            return 1
        }
    local samples
    samples=$(awk -F= '/^lavfi.astats.Overall.Number_of_samples=/ { sub(/\r$/, "", $2); last=$2 } END { print last }' "${work}/length.txt")
    if [[ ! ${samples} =~ ^[0-9]+([.]0+)?$ || ${samples%%.*} -ne 176400 ]]; then
        echo "soxr: ${samples:-no} samples at 44.1 kHz, expected 176400"
        return 1
    fi

    "${FFMPEG}" -hide_banner -loglevel error -filter_complex \
        "${source},atrim=start=1:end=3,aspectralstats,ametadata=mode=print:key=lavfi.aspectralstats.1.centroid:file=-" \
        -f null - >"${work}/pitch.txt" 2>"${work}/pitch.log" || {
            cat "${work}/pitch.log"
            return 1
        }
    # First and last window left out, as in rubberband.sh.
    if ! awk -F= '
        /^lavfi.aspectralstats.1.centroid=/ { sub(/\r$/, "", $2); v[++n]=$2 }
        END {
            for (i = 2; i < n; i++) {
                if (v[i] !~ /^[0-9]+([.][0-9]+)?(e[+-]?[0-9]+)?$/) bad=1
                else if (v[i] + 0 < 396 || v[i] + 0 > 484) bad=1
            }
            exit (bad || n < 12)
        }
    ' "${work}/pitch.txt"; then
        echo "soxr: spectral centroid not at 440 Hz in every window"
        cat "${work}/pitch.txt"
        return 1
    fi
    echo "soxr: 48 kHz to 44.1 kHz, 176400 samples, centroid at 440 Hz"
)

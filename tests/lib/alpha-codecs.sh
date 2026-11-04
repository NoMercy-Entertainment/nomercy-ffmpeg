#!/bin/bash
# Lossy alpha codecs need a range check, not a byte comparison. Require the
# gradient's dark end, light end and mean in every one of three decoded frames.
_alpha_codec_roundtrip() (
    local codec="$1" work decoder container scale
    work=$(mktemp -d) || return 1
    trap 'rm -rf "${work}"' EXIT
    case "${codec}" in
        hap) decoder=hap; container=mov; scale=1; set -- -format hap_alpha ;;
        liboapv) decoder=apv; container=mkv; scale=4; set -- -pix_fmt yuva444p10le ;;
        *) echo "Unknown alpha test codec: ${codec}"; return 1 ;;
    esac
    local source="testsrc2=size=128x64:rate=5,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*X/W'"
    "${FFMPEG}" -hide_banner -loglevel error -y -f lavfi -i "${source}" \
        -frames:v 3 -c:v "${codec}" "$@" "${work}/video.${container}" || return 1
    # Decode with FFmpeg's native decoder; no external decoding dependency.
    "${FFMPEG}" -hide_banner -loglevel error -c:v "${decoder}" -i "${work}/video.${container}" \
        -vf "alphaextract,signalstats,metadata=mode=print:file=-" \
        -frames:v 3 -f null - >"${work}/alpha.txt" 2>"${work}/decode.log" || {
            cat "${work}/decode.log"
            return 1
        }
    if ! awk -F= -v scale="${scale}" '
        /^lavfi.signalstats.Y(MIN|MAX|AVG)=/ {
            sub(/\r$/, "", $2)
            if ($2 !~ /^[0-9]+([.][0-9]+)?$/) bad=1
            # sub() makes fields strings on some awk implementations.
            value=$2+0
            if ($1 == "lavfi.signalstats.YMIN") { nmin++; if (value >= 40*scale) bad=1 }
            if ($1 == "lavfi.signalstats.YMAX") { nmax++; if (value <= 210*scale) bad=1 }
            if ($1 == "lavfi.signalstats.YAVG") { navg++; if (value < 100*scale || value > 150*scale) bad=1 }
        }
        END { exit (bad || nmin != 3 || nmax != 3 || navg != 3) }
    ' "${work}/alpha.txt"; then
        echo "${codec}: alpha gradient missing, opaque, flat or incomplete"
        cat "${work}/alpha.txt"
        return 1
    fi
    echo "${codec}: alpha gradient retained in all 3 frames (${scale}x 8-bit scale)"
)

test_hap_alpha() { _alpha_codec_roundtrip hap; }
test_apv_alpha() { _alpha_codec_roundtrip liboapv; }

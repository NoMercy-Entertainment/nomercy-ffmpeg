#!/bin/bash
# No external assets: compare every RGBA byte, including varying alpha, after
# lossless encoding at default effort (also exercises Win64 AVX2 alignment).
_jpegxl_roundtrip() (
    local codec="$1" frames="$2" mode="${3:-lossless}" work
    # macOS's Bash 3.2 treats an empty array as unset under `set -u`.
    # Positional arguments preserve an empty option list on that shell too.
    if [[ "${mode}" == lossless ]]; then
        set -- -distance 0
    else
        set --
    fi
    work=$(mktemp -d) || return 1
    trap 'rm -rf "${work}"' EXIT
    local source="testsrc=size=64x48:rate=5,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*X/W'"
    "${FFMPEG}" -hide_banner -loglevel error -y -f lavfi -i "${source}" \
        -frames:v "${frames}" -pix_fmt rgba -f rawvideo "${work}/source.rgba" || return 1
    "${FFMPEG}" -hide_banner -loglevel error -y -f rawvideo -pixel_format rgba \
        -video_size 64x48 -framerate 5 -i "${work}/source.rgba" \
        -frames:v "${frames}" -c:v "${codec}" "$@" -pix_fmt rgba \
        -f image2pipe "${work}/image.jxl" || return 1
    # Force the libjxl decoder, so another decoder cannot mask a missing one.
    "${FFMPEG}" -hide_banner -loglevel error -y -c:v "${codec}" -i "${work}/image.jxl" \
        -pix_fmt rgba -fps_mode passthrough -f rawvideo "${work}/decoded.rgba" || return 1
    if [[ $(wc -c <"${work}/source.rgba") -ne $((64 * 48 * 4 * frames)) ||
          $(wc -c <"${work}/decoded.rgba") -ne $((64 * 48 * 4 * frames)) ]]; then
        echo "${codec}: round-trip changed the frame size or count"
        return 1
    fi
    if [[ "${mode}" == lossless ]] && ! cmp -s "${work}/source.rgba" "${work}/decoded.rgba"; then
        echo "${codec}: lossless round-trip changed pixels, alpha or frame count"
        return 1
    fi
    if [[ "${mode}" == lossless ]]; then
        echo "${codec}: ${frames} frame(s), RGBA bytes identical"
    else
        echo "${codec}: default encoding settings encode and decode successfully"
    fi
)

test_jpegxl_still() { _jpegxl_roundtrip libjxl 1; }
test_jpegxl_animation() { _jpegxl_roundtrip libjxl_anim 3; }
test_jpegxl_defaults() { _jpegxl_roundtrip libjxl 1 default; }

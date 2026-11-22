#!/bin/bash

# Security fixes FFmpeg has on master that the release this build uses does
# not carry. FFmpeg 9.1 fixes 121 of the 125 CVEs that were open against
# 9.0.2; two of the remaining fixes exist upstream and were not picked into
# release/9.1 before the tag. They are applied here, unchanged.
#
#   60bc31fcf654  avcodec/jpeglsdec: decode line interleaved scans with more
#                 than 8 bits                                (CVE-2026-125243)
#   b8f159858e2f  libavcodec/v4l2_buffers: fixing buffer alignment issue
#                                       (CVE-2026-125208, CVE-2026-125270)
#
# Each fix has a marker line. A release that already carries the fix is left
# alone, and the patch file says when it can go. A fix that no longer applies
# stops the build: silently building without it is the one outcome this
# script exists to prevent.

FF="/build/ffmpeg"
PATCH_DIR="/scripts/includes"

# backport <patch file> <file it changes> <line only the fixed file has>
backport() {
    local patch="${PATCH_DIR}/$1" target="${FF}/$2" marker="$3"

    if [ ! -f "${patch}" ]; then
        log "  ERROR: ${patch} not found"
        exit 1
    fi
    if [ ! -f "${target}" ]; then
        log "  ERROR: ${target} not found"
        exit 1
    fi
    if grep -qF -- "${marker}" "${target}"; then
        log "  $1: FFmpeg ${ffmpeg_source_version:-${ffmpeg_version}} already carries this fix, skipping (the patch file can go)"
        return 0
    fi
    patch -d "${FF}" -p1 --fuzz=0 --forward <"${patch}" 2>&1 | log -a
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        log "  ERROR: $1 does not apply to FFmpeg ${ffmpeg_source_version:-${ffmpeg_version}}"
        exit 1
    fi
    if ! grep -qF -- "${marker}" "${target}"; then
        log "  ERROR: $1 applied, but $2 does not have the fix"
        exit 1
    fi
    log "  Applied $1"
}

backport ffmpeg-jpegls-16bit-line-interleaved.patch libavcodec/jpeglsdec.c \
    "only single component scans can have more than 8 bits"
backport ffmpeg-v4l2-buffer-alignment.patch libavcodec/v4l2_buffers.c \
    "v4l2_buffer_swframe_to_single_buffer"

exit 0

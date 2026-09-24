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
# Two things drifted from the brief since it was written, both symptoms of
# the same FFmpeg version bump scripts/60-stemsplit.sh already ran into:
#   1. The anchor (abench_filter_deps=) no longer exists; whisper_filter_deps=
#      does, and sits in the same audio-filter-deps block.
#   2. "check_lib libm math.h sin -lm" registers the component as "libm", not
#      "lm" -- configure's check_deps requires the exact component name, so
#      "lm" never resolves and the filter is silently disabled.
if ! grep -q "trailingsilence_filter_deps" /build/ffmpeg/configure; then
    sed -i '/^whisper_filter_deps=/a trailingsilence_filter_deps="libm"' /build/ffmpeg/configure
fi

if grep -q "trailingsilence_filter_deps" /build/ffmpeg/configure; then
    log "  ✓ Added filter dependencies"
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

exit 0

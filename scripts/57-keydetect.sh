#!/bin/bash

#/******************************/#
#/*  Made by Phillippe Pelzer  */#
#/*  https://github.com/Fill84 */#
#/******************************/#

# The filter source comes from its own repository, always at its newest
# RELEASE -- same arrangement as 49-beatdetect.sh and 60-stemsplit.sh, and the
# owner's decision of 2026-09-30: these repositories are theirs, and a release
# there is meant to ship here.
#
# The RELEASE is resolved, not the default branch. A branch carries whatever
# was half-written that afternoon; a release is something the author decided to
# publish.
#
# Two consequences, recorded rather than hidden:
#
#   * builds are not reproducible from this repository alone -- the same
#     nomercy-ffmpeg commit produces a different binary once a new keydetect
#     release exists;
#   * there is no digest to verify against, so the content check below carries
#     the weight a digest otherwise would. `curl -f` does not catch a proxy or
#     error page served with HTTP 200, and compiling one of those into ffmpeg
#     fails in a way that looks like anything except a bad download.
#
# What replaces reproducibility is traceability: the resolved tag, byte count
# and digest are logged here, and the filter reports its version at runtime as
# lavfi.keydetect.version.
#
# It used to be a copy under scripts/includes/, kept in step by hand. That copy
# predates keydetect 1.0.0 and carried no version macro at all, so a binary
# built from it could not say which keydetect it contained.
keydetect_api=https://forgejo.phillippepelzer.me/api/v1/repos/FiLL/ffmpeg-keydetect
keydetect_dst=/build/ffmpeg/libavfilter/af_keydetect.c

log "Step 0: Resolving the newest ffmpeg-keydetect release"
keydetect_tag=$(curl -fsSL --retry 3 --max-time 60 "${keydetect_api}/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p')
if [ -z "${keydetect_tag}" ]; then
    log "  ✗ ERROR: could not resolve the newest release from ${keydetect_api}/releases/latest"
    log "      (no tag_name in the response -- server unreachable, or no release published yet)"
    exit 1
fi
log "  ✓ newest release is ${keydetect_tag}"

keydetect_url="https://forgejo.phillippepelzer.me/FiLL/ffmpeg-keydetect/raw/tag/${keydetect_tag}/src/af_keydetect.c"
if ! curl -fsSL --retry 3 --max-time 120 -o "${keydetect_dst}" "${keydetect_url}"; then
    log "  ✗ ERROR: could not fetch ${keydetect_url}"
    exit 1
fi

# Without a digest to compare against, this is what stands between the build
# and a plausible-looking error page. Both markers must be present: the filter
# FFmpeg links by name, and the version macro the runtime metadata reports.
if ! grep -q "ff_af_keydetect" "${keydetect_dst}" || ! grep -q "define KD_VERSION" "${keydetect_dst}"; then
    log "  ✗ ERROR: what came back from ${keydetect_tag} is not af_keydetect.c"
    log "      ($(wc -c < "${keydetect_dst}") bytes, first line: $(head -1 "${keydetect_dst}" | cut -c1-70))"
    rm -f "${keydetect_dst}"
    exit 1
fi

keydetect_declared=$(sed -n 's/^#define KD_VERSION *"\([^"]*\)".*/\1/p' "${keydetect_dst}" | head -1)
log "  ✓ af_keydetect.c ${keydetect_tag} (declares ${keydetect_declared:-?}), $(wc -c < "${keydetect_dst}") bytes, sha256 $(sha256sum "${keydetect_dst}" | cut -d' ' -f1)"

# 1. Register the filter extern declaration in allfilters.c
echo "Step 1: Adding extern declaration to allfilters.c" > /ffmpeg_build.log

# Debug: Show what patterns exist
log "  Debug: Looking for existing patterns..."
grep "extern.*FFFilter ff_af_" /build/ffmpeg/libavfilter/allfilters.c | head -5 >> /ffmpeg_build.log

if ! grep -q "ff_af_keydetect" /build/ffmpeg/libavfilter/allfilters.c; then
    # Add after ONLY the LAST audio filter extern (ff_af_volumedetect)
    sed -i '0,/^extern const FFFilter ff_af_volumedetect;$/s//&\nextern const FFFilter ff_af_keydetect;/' /build/ffmpeg/libavfilter/allfilters.c
    log "  ✓ Added extern declaration"
else
    log "  ✓ Extern declaration already exists"
fi

# Debug: Show what was added
log "  Debug: Checking what's in the file now..."
grep "keydetect" /build/ffmpeg/libavfilter/allfilters.c | wc -l >> /ffmpeg_build.log

# Verify
if grep -q "ff_af_keydetect" /build/ffmpeg/libavfilter/allfilters.c; then
    log "  ✓ Verified in allfilters.c"
    grep "ff_af_keydetect" /build/ffmpeg/libavfilter/allfilters.c | head -1 >> /ffmpeg_build.log
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

# 2. Add the filter to the Makefile
log "Step 2: Adding to Makefile"
if ! grep -q "af_keydetect.o" /build/ffmpeg/libavfilter/Makefile; then
    sed -i '/^OBJS-\$(CONFIG_ABENCH_FILTER)/a\
OBJS-$(CONFIG_KEYDETECT_FILTER)          += af_keydetect.o' /build/ffmpeg/libavfilter/Makefile
    log "  ✓ Added to Makefile"
else
    log "  ✓ Makefile entry already exists"
fi

# Verify
if grep -q "af_keydetect.o" /build/ffmpeg/libavfilter/Makefile; then
    log "  ✓ Verified in Makefile"
    grep "af_keydetect.o" /build/ffmpeg/libavfilter/Makefile >> /ffmpeg_build.log
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

# 3. Add filter to the configure script
log "Step 3: Adding filter dependencies to configure script"

if ! grep -q "keydetect_filter_deps" /build/ffmpeg/configure; then
    sed -i '/^abench_filter_deps=/i keydetect_filter_deps="lm"' /build/ffmpeg/configure
    log "  ✓ Added filter dependencies"
else
    log "  ✓ Filter dependencies already exist"
fi

exit 0

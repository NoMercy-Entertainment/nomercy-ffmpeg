#!/bin/bash

#/******************************/#
#/*  Made by Phillippe Pelzer  */#
#/*  https://github.com/Fill84 */#
#/******************************/#

# The filter source comes from its own repository, always at its newest
# RELEASE, the same way every other component that is not in the base image is
# pulled from upstream.
#
# It used to be a copy under scripts/includes/, kept in step by hand. That
# stopped working exactly the way hand-copying always stops working: the copy
# picked up a second `#define SS_VERSION "1.0.0"` ninety-six lines above the
# real one. It compiled silently -- both replacement lists were identical, so
# no warning -- and would only have broken at the next version bump, in a
# place nobody would think to look.
#
# The owner's decision (2026-09-30): always take the newest release rather than
# a pinned version, because ffmpeg-stemsplit is theirs and a release there is
# meant to ship here. Two consequences, neither hidden:
#
#   * builds are not reproducible from this repository alone -- the same
#     nomercy-ffmpeg commit will produce a different binary once a new
#     stemsplit release exists;
#   * there is no digest to verify against, so the content check below carries
#     the weight the digest used to. `curl -f` does not catch a proxy or error
#     page served with HTTP 200, and compiling one of those into ffmpeg would
#     fail in a way that looks like anything but a bad download.
#
# What replaces the digest is traceability: the resolved tag, byte count and
# digest are logged here, and the filter reports the same version at runtime as
# lavfi.stemsplit.version, so any shipped binary can be traced back to the
# source it was built from.
#
# The RELEASE is used, not the default branch, deliberately. A branch carries
# whatever was half-written this afternoon; a release is something the author
# decided to publish.
stemsplit_api=https://forgejo.phillippepelzer.me/api/v1/repos/FiLL/ffmpeg-stemsplit
stemsplit_dst=/build/ffmpeg/libavfilter/af_stemsplit.c

# CI resolves the newest tag once per run and passes it in as STEMSPLIT_TAG, so
# all seven platforms build the same release, and the Dockerfile ARG of
# that name makes a new release rerun init.sh instead of replaying the
# previous download from the build cache. A local build passes nothing
# and resolves the newest release here, as it always did.
if [ -n "${STEMSPLIT_TAG}" ]; then
    log "Step 0: Using ffmpeg-stemsplit ${STEMSPLIT_TAG}, chosen once for this build run"
    stemsplit_tag=${STEMSPLIT_TAG}
else
    log "Step 0: Resolving the newest ffmpeg-stemsplit release"
    stemsplit_tag=$(curl -fsSL --retry 3 --max-time 60 "${stemsplit_api}/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p')
fi
if [ -z "${stemsplit_tag}" ]; then
    log "  ✗ ERROR: could not resolve the newest release from ${stemsplit_api}/releases/latest"
    log "      (no tag_name in the response -- server unreachable, or no release published yet)"
    exit 1
fi
log "  ✓ building release ${stemsplit_tag}"

stemsplit_url="https://forgejo.phillippepelzer.me/FiLL/ffmpeg-stemsplit/raw/tag/${stemsplit_tag}/src/af_stemsplit.c"
if ! curl -fsSL --retry 3 --max-time 120 -o "${stemsplit_dst}" "${stemsplit_url}"; then
    log "  ✗ ERROR: could not fetch ${stemsplit_url}"
    exit 1
fi

# Without a digest to compare against, this is what stands between the build
# and a plausible-looking error page. Both markers must be present: the filter
# FFmpeg links by name, and the version macro the runtime metadata reports.
if ! grep -q "ff_af_stemsplit" "${stemsplit_dst}" || ! grep -q "define SS_VERSION" "${stemsplit_dst}"; then
    log "  ✗ ERROR: what came back from ${stemsplit_tag} is not af_stemsplit.c"
    log "      ($(wc -c < "${stemsplit_dst}") bytes, first line: $(head -1 "${stemsplit_dst}" | cut -c1-70))"
    rm -f "${stemsplit_dst}"
    exit 1
fi

stemsplit_declared=$(sed -n 's/^#define SS_VERSION *"\([^"]*\)".*/\1/p' "${stemsplit_dst}" | head -1)
log "  ✓ af_stemsplit.c ${stemsplit_tag} (declares ${stemsplit_declared:-?}), $(wc -c < "${stemsplit_dst}") bytes, sha256 $(sha256sum "${stemsplit_dst}" | cut -d' ' -f1)"

# 1. Register the filter extern declaration in allfilters.c
echo "Step 1: Adding extern declaration to allfilters.c" > /ffmpeg_build.log

# Debug: Show what patterns exist
log "  Debug: Looking for existing patterns..."
grep "extern.*FFFilter ff_af_" /build/ffmpeg/libavfilter/allfilters.c | head -5 >> /ffmpeg_build.log

if ! grep -q "ff_af_stemsplit" /build/ffmpeg/libavfilter/allfilters.c; then
    # Add after ONLY the LAST audio filter extern (ff_af_volumedetect)
    sed -i '0,/^extern const FFFilter ff_af_volumedetect;$/s//&\nextern const FFFilter ff_af_stemsplit;/' /build/ffmpeg/libavfilter/allfilters.c
    log "  ✓ Added extern declaration"
else
    log "  ✓ Extern declaration already exists"
fi

# Debug: Show what was added
log "  Debug: Checking what's in the file now..."
grep "stemsplit" /build/ffmpeg/libavfilter/allfilters.c | wc -l >> /ffmpeg_build.log

# Verify
if grep -q "ff_af_stemsplit" /build/ffmpeg/libavfilter/allfilters.c; then
    log "  ✓ Verified in allfilters.c"
    grep "ff_af_stemsplit" /build/ffmpeg/libavfilter/allfilters.c | head -1 >> /ffmpeg_build.log
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

# 2. Add the filter to the Makefile
log "Step 2: Adding to Makefile"
if ! grep -q "af_stemsplit.o" /build/ffmpeg/libavfilter/Makefile; then
    sed -i '/^OBJS-\$(CONFIG_ABENCH_FILTER)/a\
OBJS-$(CONFIG_STEMSPLIT_FILTER)          += af_stemsplit.o' /build/ffmpeg/libavfilter/Makefile
    log "  ✓ Added to Makefile"
else
    log "  ✓ Makefile entry already exists"
fi

# Verify
if grep -q "af_stemsplit.o" /build/ffmpeg/libavfilter/Makefile; then
    log "  ✓ Verified in Makefile"
    grep "af_stemsplit.o" /build/ffmpeg/libavfilter/Makefile >> /ffmpeg_build.log
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

# 3. Add filter to the configure script
log "Step 3: Adding filter dependencies to configure script"

DEPS="whisper swresample"

if grep -q "^stemsplit_filter_deps=\"${DEPS}\"$" /build/ffmpeg/configure; then
    log "  ✓ Filter dependencies already correct"
elif grep -q "^stemsplit_filter_deps=" /build/ffmpeg/configure; then
    # An older run wrote a shorter list. swresample is what lets the filter
    # accept any sample rate and channel count and hand the stems back in the
    # input's own format; without it the line declares a filter that is
    # missing a dependency.
    sed -i "s|^stemsplit_filter_deps=.*|stemsplit_filter_deps=\"${DEPS}\"|" /build/ffmpeg/configure
    log "  ✓ Updated filter dependencies"
else
    # Anchored after whisper_filter_deps (the last audio-filter dep line
    # before the "# examples" section in FFmpeg 9.0's configure) rather than
    # the brief's abench_filter_deps anchor, which no longer exists in this
    # tree. whisper is also the filter stemsplit's own dep is borrowed from,
    # so the two lines sitting together is the more natural spot anyway.
    sed -i "/^whisper_filter_deps=/a stemsplit_filter_deps=\"${DEPS}\"" /build/ffmpeg/configure
    log "  ✓ Added filter dependencies"
fi

# Verify
if grep -q "stemsplit_filter_deps" /build/ffmpeg/configure; then
    log "  ✓ Verified in configure"
    grep "stemsplit_filter_deps" /build/ffmpeg/configure >> /ffmpeg_build.log
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

exit 0

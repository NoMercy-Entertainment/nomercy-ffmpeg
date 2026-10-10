#!/bin/bash

#/******************************/#
#/*  Made by Phillippe Pelzer  */#
#/*  https://github.com/Fill84 */#
#/******************************/#

# The filter source comes from its own repository, always at its newest
# RELEASE -- same arrangement as 60-stemsplit.sh, and the owner's decision of
# 2026-09-30: these repositories are theirs, and a release there is meant to
# ship here.
#
# The RELEASE is resolved, not the default branch. A branch carries whatever
# was half-written that afternoon; a release is something the author decided to
# publish.
#
# Two consequences, recorded rather than hidden:
#
#   * builds are not reproducible from this repository alone -- the same
#     nomercy-ffmpeg commit produces a different binary once a new beatdetect
#     release exists;
#   * there is no digest to verify against, so the content check below carries
#     the weight a digest otherwise would. `curl -f` does not catch a proxy or
#     error page served with HTTP 200, and compiling one of those into ffmpeg
#     fails in a way that looks like anything except a bad download.
#
# What replaces reproducibility is traceability: the resolved tag, byte count
# and digest are logged here, and the filter reports its version at runtime as
# lavfi.beatdetect.version.
beatdetect_api=https://forgejo.phillippepelzer.me/api/v1/repos/FiLL/ffmpeg-beatdetect
beatdetect_dst=/build/ffmpeg/libavfilter/af_beatdetect.c

# CI resolves the newest tag once per run and passes it in as BEATDETECT_TAG, so
# all seven platforms build the same release, and the Dockerfile ARG of
# that name makes a new release rerun init.sh instead of replaying the
# previous download from the build cache. A local build passes nothing
# and resolves the newest release here, as it always did.
if [ -n "${BEATDETECT_TAG}" ]; then
    log "Step 0: Using ffmpeg-beatdetect ${BEATDETECT_TAG}, chosen once for this build run"
    beatdetect_tag=${BEATDETECT_TAG}
else
    log "Step 0: Resolving the newest ffmpeg-beatdetect release"
    beatdetect_tag=$(curl -fsSL --retry 3 --max-time 60 "${beatdetect_api}/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p')
fi
if [ -z "${beatdetect_tag}" ]; then
    log "  ✗ ERROR: could not resolve the newest release from ${beatdetect_api}/releases/latest"
    log "      (no tag_name in the response -- server unreachable, or no release published yet)"
    exit 1
fi
log "  ✓ building release ${beatdetect_tag}"

beatdetect_url="https://forgejo.phillippepelzer.me/FiLL/ffmpeg-beatdetect/raw/tag/${beatdetect_tag}/src/af_beatdetect.c"
if ! curl -fsSL --retry 3 --max-time 120 -o "${beatdetect_dst}" "${beatdetect_url}"; then
    log "  ✗ ERROR: could not fetch ${beatdetect_url}"
    exit 1
fi

# Without a digest to compare against, this is what stands between the build
# and a plausible-looking error page. Both markers must be present: the filter
# FFmpeg links by name, and the version macro the runtime metadata reports.
if ! grep -q "ff_af_beatdetect" "${beatdetect_dst}" || ! grep -q "define BEATDETECT_VERSION" "${beatdetect_dst}"; then
    log "  ✗ ERROR: what came back from ${beatdetect_tag} is not af_beatdetect.c"
    log "      ($(wc -c < "${beatdetect_dst}") bytes, first line: $(head -1 "${beatdetect_dst}" | cut -c1-70))"
    rm -f "${beatdetect_dst}"
    exit 1
fi

beatdetect_declared=$(sed -n 's/^#define BEATDETECT_VERSION *"\([^"]*\)".*/\1/p' "${beatdetect_dst}" | head -1)
log "  ✓ af_beatdetect.c ${beatdetect_tag} (declares ${beatdetect_declared:-?}), $(wc -c < "${beatdetect_dst}") bytes, sha256 $(sha256sum "${beatdetect_dst}" | cut -d' ' -f1)"

# 1. Register the filter extern declaration in allfilters.c
echo "Step 1: Adding extern declaration to allfilters.c" > /ffmpeg_build.log

# Debug: Show what patterns exist
log "  Debug: Looking for existing patterns..."
grep "extern.*FFFilter ff_af_" /build/ffmpeg/libavfilter/allfilters.c | head -5 >> /ffmpeg_build.log

if ! grep -q "ff_af_beatdetect" /build/ffmpeg/libavfilter/allfilters.c; then
    # Add after ONLY the LAST audio filter extern (ff_af_volumedetect)
    sed -i '0,/^extern const FFFilter ff_af_volumedetect;$/s//&\nextern const FFFilter ff_af_beatdetect;/' /build/ffmpeg/libavfilter/allfilters.c
    log "  ✓ Added extern declaration"
else
    log "  ✓ Extern declaration already exists"
fi

# Debug: Show what was added
log "  Debug: Checking what's in the file now..."
grep "beatdetect" /build/ffmpeg/libavfilter/allfilters.c | wc -l >> /ffmpeg_build.log

# Verify
if grep -q "ff_af_beatdetect" /build/ffmpeg/libavfilter/allfilters.c; then
    log "  ✓ Verified in allfilters.c"
    grep "ff_af_beatdetect" /build/ffmpeg/libavfilter/allfilters.c | head -1 >> /ffmpeg_build.log
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

# 2. Add the filter to the Makefile
log "Step 2: Adding to Makefile"
if ! grep -q "af_beatdetect.o" /build/ffmpeg/libavfilter/Makefile; then
    sed -i '/^OBJS-\$(CONFIG_ABENCH_FILTER)/a\
OBJS-$(CONFIG_BEATDETECT_FILTER)         += af_beatdetect.o' /build/ffmpeg/libavfilter/Makefile
    log "  ✓ Added to Makefile"
else
    log "  ✓ Makefile entry already exists"
fi

# Verify
if grep -q "af_beatdetect.o" /build/ffmpeg/libavfilter/Makefile; then
    log "  ✓ Verified in Makefile"
    grep "af_beatdetect.o" /build/ffmpeg/libavfilter/Makefile >> /ffmpeg_build.log
else
    log "  ✗ ERROR: Verification failed!"
    exit 1
fi

# 3. Filter dependencies: none to declare.
#
# This step used to insert beatdetect_filter_deps="lm" before abench_filter_deps=
# and log "Added filter dependencies". abench_filter_deps does not exist in
# FFmpeg 9.0, so the sed matched nothing and the log claimed success anyway,
# on every build.
#
# Measured with FFmpeg 9.0's own configure, on a filter with no deps:
#   no _deps line        -> filter enabled
#   _deps="lm"           -> filter DISABLED
#   _deps="libm"         -> filter enabled (on linux-x86_64)
# So the dead edit is what kept this filter working: had its anchor matched,
# "lm" would have switched it off.
#
# The October 2026 audit (AUD-9128) proposed re-anchoring it with "libm".
# That keeps the filter on in linux configure, but libm is detected
# differently on mingw, darwin and freebsd, and where configure does not see
# it enabled the filter would quietly disappear from that platform while the
# build still succeeds. With no dependency declared, the filter has shipped
# working on all seven platforms, and it needs none: it is plain DSP with no
# external library, and libm is linked into every ffmpeg build regardless.
# Compare 60-stemsplit.sh, whose dependencies (whisper, swresample) are real
# features and are declared.
log "Step 3: no filter dependencies to declare (libm is always linked)"

exit 0
#!/bin/bash

#/******************************/#
#/*  Made by Phillippe Pelzer  */#
#/*  https://github.com/Fill84 */#
#/******************************/#

# The filter source comes from its own repository, pinned, the same way every
# other component that is not in the base image does.
#
# It used to be a copy under scripts/includes/, kept in step by hand. That
# stopped working exactly the way hand-copying always stops working: the copy
# picked up a second `#define SS_VERSION "1.0.0"` ninety-six lines above the
# real one. It compiled silently -- both replacement lists were identical, so
# no warning -- and would only have broken at the next version bump, in a
# place nobody would think to look.
#
# Two lines below are the whole contract. Bump them together to take a new
# stemsplit release; nothing else in this repository needs to change.
#
# The digest is what actually guarantees the source, not the tag: a tag can be
# moved, a digest cannot. A mismatch stops the build rather than quietly
# compiling something nobody reviewed.
stemsplit_version=1.0.0
stemsplit_sha256=b2e52dbcb48e7622a233c03d9a4357f92fb8b7080a4023d70717a8656148f173

stemsplit_url="https://forgejo.phillippepelzer.me/FiLL/ffmpeg-stemsplit/raw/tag/v${stemsplit_version}/src/af_stemsplit.c"
stemsplit_dst=/build/ffmpeg/libavfilter/af_stemsplit.c

log "Step 0: Fetching af_stemsplit.c from ffmpeg-stemsplit v${stemsplit_version}"
if ! curl -fsSL --retry 3 --max-time 120 -o "${stemsplit_dst}" "${stemsplit_url}"; then
    log "  ✗ ERROR: could not fetch ${stemsplit_url}"
    exit 1
fi

stemsplit_got=$(sha256sum "${stemsplit_dst}" | cut -d' ' -f1)
if [ "${stemsplit_got}" != "${stemsplit_sha256}" ]; then
    log "  ✗ ERROR: af_stemsplit.c digest mismatch"
    log "      expected ${stemsplit_sha256}"
    log "      got      ${stemsplit_got}"
    rm -f "${stemsplit_dst}"
    exit 1
fi
log "  ✓ af_stemsplit.c v${stemsplit_version} fetched and verified ($(wc -c < "${stemsplit_dst}") bytes)"

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

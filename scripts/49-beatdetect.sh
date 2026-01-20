#!/bin/bash

#/******************************/#
#/*  Made by Phillippe Pelzer  */#
#/*  https://github.com/Fill84 */#
#/******************************/#

# Copy the custom filter source
cp /scripts/includes/af_beatdetect.c /build/ffmpeg/libavfilter/af_beatdetect.c

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

# 3. Add filter to the configure script
log "Step 3: Adding filter dependencies to configure script"

if ! grep -q "beatdetect_filter_deps" /build/ffmpeg/configure; then
    sed -i '/^abench_filter_deps=/i beatdetect_filter_deps="lm"' /build/ffmpeg/configure
    log "  ✓ Added filter dependencies"
else
    log "  ✓ Filter dependencies already exist"
fi

exit 0
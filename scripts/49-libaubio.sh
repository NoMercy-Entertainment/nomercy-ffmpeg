#!/bin/bash

# Copy the custom filter source
cp /scripts/includes/af_beatdetect.c /build/ffmpeg/libavfilter/af_beatdetect.c

# 1. Register the filter extern declaration in allfilters.c
echo "Step 1: Adding extern declaration to allfilters.c" > /ffmpeg_build.log

# Debug: Show what patterns exist
echo "  Debug: Looking for existing patterns..." >> /ffmpeg_build.log
grep "extern.*FFFilter ff_af_" /build/ffmpeg/libavfilter/allfilters.c | head -5 >> /ffmpeg_build.log

if ! grep -q "ff_af_beatdetect" /build/ffmpeg/libavfilter/allfilters.c; then
    # Add after ONLY the LAST audio filter extern (ff_af_volumedetect)
    sed -i '0,/^extern const FFFilter ff_af_volumedetect;$/s//&\nextern const FFFilter ff_af_beatdetect;/' /build/ffmpeg/libavfilter/allfilters.c
    echo "  ✓ Added extern declaration" >> /ffmpeg_build.log
else
    echo "  ✓ Extern declaration already exists" >> /ffmpeg_build.log
fi

# Debug: Show what was added
echo "  Debug: Checking what's in the file now..." >> /ffmpeg_build.log
grep "beatdetect" /build/ffmpeg/libavfilter/allfilters.c | wc -l >> /ffmpeg_build.log

# Verify
if grep -q "ff_af_beatdetect" /build/ffmpeg/libavfilter/allfilters.c; then
    echo "  ✓ Verified in allfilters.c" >> /ffmpeg_build.log
    grep "ff_af_beatdetect" /build/ffmpeg/libavfilter/allfilters.c | head -1 >> /ffmpeg_build.log
else
    echo "  ✗ ERROR: Verification failed!" >> /ffmpeg_build.log
    exit 1
fi

# 2. Add the filter to the Makefile
echo "Step 2: Adding to Makefile" >> /ffmpeg_build.log
if ! grep -q "af_beatdetect.o" /build/ffmpeg/libavfilter/Makefile; then
    sed -i '/^OBJS-\$(CONFIG_ABENCH_FILTER)/a\
OBJS-$(CONFIG_BEATDETECT_FILTER)         += af_beatdetect.o' /build/ffmpeg/libavfilter/Makefile
    echo "  ✓ Added to Makefile" >> /ffmpeg_build.log
else
    echo "  ✓ Makefile entry already exists" >> /ffmpeg_build.log
fi

# Verify
if grep -q "af_beatdetect.o" /build/ffmpeg/libavfilter/Makefile; then
    echo "  ✓ Verified in Makefile" >> /ffmpeg_build.log
    grep "af_beatdetect.o" /build/ffmpeg/libavfilter/Makefile >> /ffmpeg_build.log
else
    echo "  ✗ ERROR: Verification failed!" >> /ffmpeg_build.log
    exit 1
fi

# 3. Add filter to the configure script
echo "Step 3: Adding filter dependencies to configure script" >> /ffmpeg_build.log

if ! grep -q "beatdetect_filter_deps" /build/ffmpeg/configure; then
    sed -i '/^abench_filter_deps=/i beatdetect_filter_deps="lm"' /build/ffmpeg/configure
    echo "  ✓ Added filter dependencies" >> /ffmpeg_build.log
else
    echo "  ✓ Filter dependencies already exist" >> /ffmpeg_build.log
fi

exit 0
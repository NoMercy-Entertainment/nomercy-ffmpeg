#!/bin/bash

#/************************************/#
#/*  NoMercy Entertainment - VOBsub  */#
#/*  Muxer for DVD subtitle output   */#
#/************************************/#

# Copy the custom muxer source into the FFmpeg source tree
cp /scripts/includes/vobsubenc.c /build/ffmpeg/libavformat/vobsubenc.c

# 1. Register the muxer extern declaration in allformats.c
log "Step 1: Adding extern declaration to allformats.c"

if ! grep -q "ff_vobsub_muxer" /build/ffmpeg/libavformat/allformats.c; then
    sed -i '/^extern const FFInputFormat  ff_vobsub_demuxer;$/a\extern const FFOutputFormat ff_vobsub_muxer;' /build/ffmpeg/libavformat/allformats.c
    log "  Added extern declaration"
else
    log "  Extern declaration already exists"
fi

# Verify
if grep -q "ff_vobsub_muxer" /build/ffmpeg/libavformat/allformats.c; then
    log "  Verified in allformats.c"
else
    log "  ERROR: Verification failed!"
    exit 1
fi

# 2. Add the muxer object to the Makefile
log "Step 2: Adding to Makefile"

if ! grep -q "vobsubenc.o" /build/ffmpeg/libavformat/Makefile; then
    sed -i '/^OBJS-\$(CONFIG_VOBSUB_DEMUXER)/a\OBJS-$(CONFIG_VOBSUB_MUXER)              += vobsubenc.o' /build/ffmpeg/libavformat/Makefile
    log "  Added to Makefile"
else
    log "  Makefile entry already exists"
fi

# Verify
if grep -q "vobsubenc.o" /build/ffmpeg/libavformat/Makefile; then
    log "  Verified in Makefile"
else
    log "  ERROR: Verification failed!"
    exit 1
fi

exit 0

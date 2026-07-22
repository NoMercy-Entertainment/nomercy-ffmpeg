#!/bin/bash

#/**************************************/#
#/*  NoMercy Entertainment — HLS       */#
#/*  master playlist spec compliance   */#
#/**************************************/#

# Replace the upstream HLS muxer sources with patched versions that complete
# the master playlist for Apple HLS spec compliance:
#   - FRAME-RATE and VIDEO-RANGE (SDR/PQ/HLG) on #EXT-X-STREAM-INF
#   - aname: var_stream_map key for a custom audio rendition NAME
#   - auto-set the hvc1 tag on HEVC streams instead of silently
#     dropping the CODECS attribute
#   - HEVC codec string from hvcC extradata (stream copies from MP4/MOV)
#   - loud warning when a CODECS attribute cannot be built
# See: https://github.com/NoMercy-Entertainment/nomercy-ffmpeg/issues/12

FFDIR="/build/ffmpeg/libavformat"

for f in hlsenc.c hlsplaylist.c hlsplaylist.h codecstring.c; do
    if [ ! -f "/scripts/includes/${f}" ]; then
        log "  ERROR: /scripts/includes/${f} not found"
        exit 1
    fi
    cp "/scripts/includes/${f}" "${FFDIR}/${f}"
    log "  Applied ${f}"
done

# ff_hls_write_audio_rendition() gained an aname parameter; update the single
# call site in the DASH muxer (NULL keeps the upstream audio_N naming there).
if ! grep -q "playlist_file, NULL, NULL, i, is_default," "${FFDIR}/dashenc.c"; then
    sed -i 's|playlist_file, NULL, i, is_default,|playlist_file, NULL, NULL, i, is_default,|' "${FFDIR}/dashenc.c"
fi

if grep -q "playlist_file, NULL, NULL, i, is_default," "${FFDIR}/dashenc.c"; then
    log "  Updated ff_hls_write_audio_rendition call site in dashenc.c"
else
    log "  ERROR: failed to update ff_hls_write_audio_rendition call site in dashenc.c"
    exit 1
fi

echo "HLS master playlist patch applied successfully" > /ffmpeg_build.log

exit 0

#!/bin/bash

# Skipped: this built a library and produced no decoder.
#
# FFmpeg has no AV2 support at all -- not in 9.0, and not on master as of
# 2026-10. There is no AV_CODEC_ID_AV2, no codec descriptor, no parser, no
# demuxer that maps AV2 (MP4, Matroska, IVF and OBU all lack it), no
# libavcodec/libdav2d.c and no entry in allcodecs.c. So --enable-libdav2d was
# accepted, because the library-list sed below works, and the library was
# built and found through pkg-config -- but CONFIG_LIBDAV2D_DECODER was never
# set, libdav2d.o was never compiled, and `ffmpeg -decoders` on v1.0.44 lists
# libdav1d alone. The flag in -buildconf claimed AV2 decoding that did not
# exist, on every release since this script was added.
#
# tools/dav2d.c in the dav2d repository is that project's own command-line
# decoder, the counterpart of tools/dav1d.c. FFmpeg uses neither: it decodes
# through its own wrapper around the library API, libavcodec/libdav1d.c for
# dav1d, and no such wrapper exists for dav2d.
#
# Skipped rather than deleted, so it is ready when AV2 reaches FFmpeg. Building
# it ourselves now would mean defining our own AV_CODEC_ID_AV2, which would
# collide with upstream's on every FFmpeg upgrade once upstream adds one --
# and AV2 is not final, dav2d is at 0.0.1, and there is no AV2 content to
# decode beyond reference test vectors.
#
# For whoever turns this back on, four things below are known to be wrong:
#   1. FFmpeg needs AV2 first: a codec id, a descriptor and a demuxer mapping.
#      A wrapper alone is unreachable -- nothing would ever hand it a packet.
#   2. The decoder_select sed has a dead anchor. FFmpeg 9.0 has no
#      `dav1d_decoder_select="libdav1d"`; it has libdav1d_decoder_deps and
#      libdav1d_decoder_select="itut_t35". The line it means to add is
#      `libdav2d_decoder_deps="libdav2d"`, by analogy with dav1d.
#   3. The clone is unpinned. v1.0.44 was built against dav2d commit
#      9aafa5bf1aec7b1e939640d0262948a81a7d2f53 (2026-10-01).
#   4. The cleanup removes /build/libdav2d; the clone is at /build/dav2d.
# None of the sed edits is verified afterwards, so add a grep check per edit;
# against FFmpeg 9.0 the other three anchors do match.
exit 255

cd /build

git clone https://code.videolan.org/videolan/dav2d.git

cd /build/dav2d

mkdir build && cd build

meson --prefix=${PREFIX} --buildtype=release -Ddefault_library=static \
	--cross-file="/build/cross_file.txt" .. 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	exit 1
fi

ninja -j$(nproc) && ninja install || exit 1
rm -rf /build/libdav2d

log "Bezig met patchen van configure..."

# 1. Voeg 'libdav2d' toe aan de EXTERNAL_LIBRARY_LIST in configure
# We zoeken naar 'libdav1d' en plakken 'libdav2d' er direct achter
sed -i '/EXTERNAL_LIBRARY_LIST="/,/\"/ s/libdav1d/libdav1d libdav2d/' /build/ffmpeg/configure

# 2. Voeg de decoder-selectie regel toe
# We zoeken naar de regel van dav1d en plaatsen de dav2d variant eronder
sed -i '/dav1d_decoder_select="libdav1d"/a dav2d_decoder_select="libdav2d"' /build/ffmpeg/configure

# 3. Voeg de pkg-config check toe zodat configure de library daadwerkelijk zoekt
# We plaatsen deze onder de bestaande libdav1d check
sed -i '/enabled libdav1d/a enabled libdav2d          && require_pkg_config libdav2d dav2d "dav2d/dav2d.h" dav2d_version' /build/ffmpeg/configure

log "Bezig met patchen van libavcodec/Makefile..."

# 4. Vertel de Makefile dat hij libdav2d.c moet compileren als de decoder aan staat
sed -i '/OBJS-$(CONFIG_LIBDAV1D_DECODER)/a OBJS-$(CONFIG_LIBDAV2D_DECODER)          += libdav2d.o' /build/ffmpeg/libavcodec/Makefile

log "Klaar! FFmpeg configure is nu aangepast."

add_enable "--enable-libdav2d"

exit 0

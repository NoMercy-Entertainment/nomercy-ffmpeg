#!/bin/bash

cd /build

git clone https://code.videolan.org/videolan/dav2d.git

cd /build/dav2d

mkdir build && cd build

meson --prefix=${PREFIX} --buildtype=release -Ddefault_library=static \
	--cross-file="/build/cross_file.txt" .. | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	exit 1
fi

ninja -j$(nproc) && ninja install
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

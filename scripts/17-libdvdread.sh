#!/bin/bash

EXTRA_FLAGS=""

if [[ ${TARGET_OS} == "darwin" ]]; then
    EXTRA_FLAGS="--without-iconv"
fi

#region libdvdcss
git clone --branch 1.4.3 https://code.videolan.org/videolan/libdvdcss.git /build/libdvdcss
cd /build/libdvdcss

autoreconf -i
./configure --prefix=${PREFIX} --prefix=${PREFIX} --enable-static --disable-shared ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libdvdcss.pc
rm -rf /build/libdvdcss && cd /build
#endregion

#region libdvdread
git clone --branch 6.1.3 https://code.videolan.org/videolan/libdvdread.git /build/libdvdread
cd /build/libdvdread

autoreconf -i
./configure --prefix=${PREFIX} --prefix=${PREFIX} --enable-static --disable-shared --with-libdvdcss ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
echo "Libs.private: -ldvdnav -ldvdcss -lstdc++" >>${PREFIX}/lib/pkgconfig/libdvdread.pc
rm -rf /build/libdvdread && cd /build
#endregion

#region libdvdnav
git clone --branch 6.1.1 https://code.videolan.org/videolan/libdvdnav.git /build/libdvdnav
cd /build/libdvdnav

autoreconf -i
./configure --prefix=${PREFIX} --prefix=${PREFIX} --enable-static --disable-shared --with-libdvdcss ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
echo "Libs.private: -ldvdread -ldvdcss -lstdc++" >>${PREFIX}/lib/pkgconfig/libdvdnav.pc
rm -rf /build/libdvdnav && cd /build
#endregion

add_enable "--enable-libdvdread --enable-libdvdnav"
add_extralib "-ldvdcss"

if [ -f /build/ffmpeg/libavformat/dvdvideodec.c ]; then
    # patch ffmpeg to use libdvdcss
    apply_sed "#include <dvdread\/nav_read.h>" "a #include <dvdcss\/dvdcss.h>" "/build/ffmpeg/libavformat/dvdvideodec.c"
fi

exit 0

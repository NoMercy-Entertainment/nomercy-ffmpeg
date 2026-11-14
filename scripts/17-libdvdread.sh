#!/bin/bash

# code.videolan.org intermittently drops clones under repeated CI-style load;
# retry with backoff instead of failing the whole build
clone_retry() {
    local branch=$1 url=$2 dest=$3 i
    for i in 1 2 3 4 5; do
        git clone --branch "${branch}" "${url}" "${dest}" && return 0
        rm -rf "${dest}"
        sleep $((i * 10))
    done
    return 1
}

EXTRA_FLAGS=""

if [[ ${TARGET_OS} == "darwin" ]]; then
    EXTRA_FLAGS="--without-iconv"
fi

#region libdvdcss
clone_retry 1.4.3 https://github.com/NoMercy-CI-Mirrors/libdvdcss.git /build/libdvdcss || exit 1
cd /build/libdvdcss

autoreconf -i
./configure --prefix=${PREFIX} --prefix=${PREFIX} --enable-static --disable-shared ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-} 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install || exit 1
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libdvdcss.pc
rm -rf /build/libdvdcss && cd /build
#endregion

#region libdvdread
clone_retry 6.1.3 https://github.com/NoMercy-CI-Mirrors/libdvdread.git /build/libdvdread || exit 1
cd /build/libdvdread

autoreconf -i
./configure --prefix=${PREFIX} --prefix=${PREFIX} --enable-static --disable-shared --with-libdvdcss ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-} 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install || exit 1
echo "Libs.private: -ldvdnav -ldvdcss -lstdc++" >>${PREFIX}/lib/pkgconfig/libdvdread.pc
rm -rf /build/libdvdread && cd /build
#endregion

#region libdvdnav
# 7.0.0 fixes CVE-2026-112057 (an out-of-bounds read in
# dvdnav_describe_title_chapters, which FFmpeg's dvdvideo demuxer calls). It
# builds with Meson only: 7.0.0 removed autotools. Its API is 6.1.1's plus
# additions, and it takes libdvdread from 6.0.0 on.
clone_retry 7.0.0 https://github.com/NoMercy-CI-Mirrors/libdvdnav.git /build/libdvdnav || exit 1
cd /build/libdvdnav

# --wrap-mode=nodownload: dvdread must be the one built above, never a
# subproject meson fetches on its own.
meson setup build --prefix=${PREFIX} --libdir=lib --buildtype=release \
    --default-library=static --wrap-mode=nodownload \
    -Denable_docs=false -Denable_examples=false \
    --cross-file="/build/cross_file.txt" 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

ninja -j$(nproc) -C build && ninja -C build install || exit 1
# Meson writes dvdnav.pc with dvdread under Requires.private. The static
# link also needs what dvdread's own .pc line above adds, and the threads
# library on platforms that have one: say so in the file pkg-config reads.
# (Up to 6.1.1 this line went to a libdvdnav.pc nobody reads; the autotools
# build installed dvdnav.pc too.)
dvdnav_pc=${PREFIX}/lib/pkgconfig/dvdnav.pc
if [ ! -f "${dvdnav_pc}" ]; then
    log "libdvdnav: ${dvdnav_pc} was not installed"
    exit 1
fi
# One Libs.private field: pkg-config rejects a file that has two.
if grep -q '^Libs.private:' "${dvdnav_pc}"; then
    sed -i 's|^Libs.private:.*|& -ldvdread -ldvdcss -lstdc++|' "${dvdnav_pc}"
else
    echo "Libs.private: -ldvdread -ldvdcss -lstdc++" >>"${dvdnav_pc}"
fi
if ! ${PKG_CONFIG:-pkg-config} --exists --static dvdnav; then
    log "libdvdnav: pkg-config cannot read ${dvdnav_pc}:"
    log "$(${PKG_CONFIG:-pkg-config} --static --libs dvdnav 2>&1)"
    exit 1
fi
rm -rf /build/libdvdnav && cd /build
#endregion

add_enable "--enable-libdvdread --enable-libdvdnav"
add_extralib "-ldvdcss"

if [ -f /build/ffmpeg/libavformat/dvdvideodec.c ]; then
    # patch ffmpeg to use libdvdcss
    apply_sed "#include <dvdread\/nav_read.h>" "a #include <dvdcss\/dvdcss.h>" "/build/ffmpeg/libavformat/dvdvideodec.c"
fi

exit 0

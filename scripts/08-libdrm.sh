#!/bin/bash

if [[ ${TARGET_OS} != "linux" ]]; then
    exit 255
fi

# libpciaccess
cd /build/libpciaccess
meson build --prefix=${PREFIX} --buildtype=release -Ddefault_library=static \
    --cross-file="/build/cross_file.txt" | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

ninja -j$(nproc) -C build && ninja -C build install
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libpciaccess.pc
rm -rf /build/libpciaccess

# xcbproto
cd /build/xcbproto
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
mv ${PREFIX}/share/pkgconfig/xcb-proto.pc ${PREFIX}/lib/pkgconfig/xcb-proto.pc
rm -rf /build/xcbproto

# xproto
cd /build/xproto
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
mv ${PREFIX}/share/pkgconfig/xproto.pc ${PREFIX}/lib/pkgconfig/xproto.pc
rm -rf /build/xproto

# xtrans
cd /build/libxtrans
./autogen.sh --prefix=${PREFIX} --without-xmlto --without-fop --without-xsltproc \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --without-xmlto --without-fop --without-xsltproc \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
cp -r ${PREFIX}/share/aclocal/. ${PREFIX}/lib/aclocal
rm -rf /build/libxtrans

# libxcb
cd /build/libxcb
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic --disable-devel-docs \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic --disable-devel-docs \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/libxcb

# libx11
cd /build/libx11
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --without-xmlto --without-fop --without-xsltproc --without-lint --disable-specs --enable-ipv6 \
    --host=${CROSS_PREFIX%-} \
    --disable-malloc0returnsnull
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --without-xmlto --without-fop --without-xsltproc --without-lint --disable-specs --enable-ipv6 \
    --host=${CROSS_PREFIX%-} \
    --disable-malloc0returnsnull | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/x11.pc
rm -rf /build/libx11

# libxfixes
cd /build/libxfixes
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/xfixes.pc
rm -rf /build/libxfixes

# libdrm
cd /build/libdrm
mkdir build && cd build
meson --prefix=${PREFIX} --buildtype=release \
    -Ddefault_library=static -Dudev=false -Dcairo-tests=disabled \
    -Dvalgrind=disabled -Dexynos=disabled -Dfreedreno=disabled \
    -Domap=disabled -Detnaviv=disabled -Dintel=enabled \
    -Dnouveau=enabled -Dradeon=enabled -Damdgpu=enabled \
    --cross-file="/build/cross_file.txt" .. | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

ninja -j$(nproc) && ninja install install
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libdrm.pc
rm -rf /build/libdrm

add_enable "--enable-libdrm"

exit 0

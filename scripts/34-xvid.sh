#!/bin/bash

OLD_CFLAGS=${CFLAGS}
CFLAGS="${CFLAGS} -fstrength-reduce -ffast-math"

CROSS_HOST=${CROSS_PREFIX%-}
EXTRA_FLAGS=""

cd /build/xvidcore/build/generic

if [[ ${TARGET_OS} == "windows" ]]; then
    sed -i 's/-mno-cygwin//g' Makefile
    sed -i 's/-mno-cygwin//g' configure
fi

if [[ ${TARGET_OS} == "darwin" ]]; then
    if [[ ${ARCH} == "arm64" ]]; then
        CROSS_HOST="aarch64-apple-darwin24.1"
    fi
    EXTRA_FLAGS="CC=${CC} \
                 CXX=${CXX}"
fi

./configure --enable-static --disable-shared \
    --prefix=${PREFIX} \
    --libdir=${PREFIX}/lib \
    --host=${CROSS_HOST} ${EXTRA_FLAGS} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
if [[ ${TARGET_OS} == "windows" ]]; then
    mv ${PREFIX}/lib/xvidcore.a ${PREFIX}/lib/libxvidcore.a
    mv ${PREFIX}/lib/xvidcore.dll.a ${PREFIX}/lib/libxvidcore.dll.a
fi

rm -rf /build/xvidcore
CFLAGS=${OLD_CFLAGS}

add_enable "--enable-libxvid"

exit 0

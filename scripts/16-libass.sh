#!/bin/bash

CONFIG="--host=${CROSS_PREFIX%-}"

if [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "linux" ]]; then
    CONFIG=""
fi

if [[ ${TARGET_OS} == "darwin" ]]; then
    CONFIG="--disable-iconv --host=${CROSS_PREFIX%-}"
fi

cd /build/libass
./autogen.sh --prefix="${PREFIX}" --enable-static --disable-shared --with-pic ${CONFIG}
./configure --prefix="${PREFIX}" --enable-static --disable-shared --with-pic ${CONFIG} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/libass

if [ ! -f "${PREFIX}/lib/pkgconfig/libass.pc" ]; then
    log "libass failed to build"
    exit 1
fi

add_enable "--enable-libass"

exit 0

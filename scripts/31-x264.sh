#!/bin/bash

export X264_TARGET=""
if [[ "${ARCH}" == "aarch64" && "${TARGET_OS}" == "linux" ]]; then
    export X264_TARGET="--target=${ARCH}-unknown-linux-gnu"
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "windows" ]]; then
    export X264_TARGET="--target=${ARCH}-win64-gcc"
fi

cd /build/x264
./configure \
    --prefix=${PREFIX} --disable-cli --enable-static --disable-lavf --disable-swscale \
    --cross-prefix=${CROSS_PREFIX} --host=${CROSS_PREFIX%-} ${X264_TARGET} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
make -j$(nproc) && make install
rm -rf /build/x264

add_enable "--enable-libx264"

exit 0

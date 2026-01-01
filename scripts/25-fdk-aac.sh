#!/bin/bash

export FDK_AAC_TARGET=""
if [[ "${ARCH}" == "aarch64" && "${TARGET_OS}" == "linux" ]]; then
    export FDK_AAC_TARGET="--target=${ARCH}-unknown-linux-gnu"
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "windows" ]]; then
    export FDK_AAC_TARGET="--target=${ARCH}-win64-gcc"
elif [[ "${TARGET_OS}" == "darwin" ]]; then
    export FDK_AAC_TARGET="--target=${ARCH}-apple-darwin"
fi

cd /build/fdk-aac
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared \
    --host=${CROSS_PREFIX%-} ${FDK_AAC_TARGET}
./configure --prefix=${PREFIX} --enable-static --disable-shared \
    --host=${CROSS_PREFIX%-} ${FDK_AAC_TARGET} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/fdk-aac

add_enable "--enable-libfdk-aac"

exit 0

#!/bin/bash

LIBRAV1E_TARGET=""
if [[ "${ARCH}" == "aarch64" && "${TARGET_OS}" == "linux" ]]; then
    LIBRAV1E_TARGET="--target=${ARCH}-unknown-linux-gnu"
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "windows" ]]; then
    LIBRAV1E_TARGET="--target=${ARCH}-pc-windows-gnu"
elif [[ "${ARCH}" == "aarch64" && "${TARGET_OS}" == "windows" ]]; then
    LIBRAV1E_TARGET="--target=${ARCH}-pc-windows-msvc"
elif [[ "${ARCH}" == "arm64" && "${TARGET_OS}" == "darwin" ]]; then
    LIBRAV1E_TARGET="--target=aarch64-apple-darwin"
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "darwin" ]]; then
    LIBRAV1E_TARGET="--target=${ARCH}-apple-darwin"
fi

cd /build/librav1e
cargo cinstall -j$(nproc) -v ${LIBRAV1E_TARGET} --prefix=${PREFIX} --library-type=staticlib --crt-static --release | tee /ffmpeg_build.log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

if [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "linux" ]]; then
    sed -i 's/-lgcc_s//' ${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/rav1e.pc
    cp ${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/rav1e.pc ${PREFIX}/lib/pkgconfig/rav1e.pc
else
    sed -i 's/-lgcc_s//' ${PREFIX}/lib/pkgconfig/rav1e.pc
fi

rm -rf /build/librav1e

add_enable "--enable-librav1e"

exit 0

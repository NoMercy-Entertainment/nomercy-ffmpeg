#!/bin/bash

cd /build/harfbuzz

if [[ "${TARGET_OS}" == "darwin" ]]; then
    mkdir -p /build/harfbuzz/src/unicode
    cp -r /usr/include/unicode/* /build/harfbuzz/src/unicode
fi

meson build --prefix=${PREFIX} --buildtype=release -Ddefault_library=static \
    --cross-file="/build/cross_file.txt" | tee /ffmpeg_build.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

ninja -j$(nproc) -C build && ninja -C build install
rm -rf /build/harfbuzz

add_enable "--enable-libharfbuzz"

exit 0

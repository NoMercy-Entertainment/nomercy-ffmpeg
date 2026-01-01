#!/bin/bash

cd /build/libdav1d
mkdir build && cd build
meson --prefix=${PREFIX} --buildtype=release -Ddefault_library=static \
    --cross-file="/build/cross_file.txt" .. | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

ninja -j$(nproc) && ninja install
rm -rf /build/libdav1d

add_enable "--enable-libdav1d"

exit 0

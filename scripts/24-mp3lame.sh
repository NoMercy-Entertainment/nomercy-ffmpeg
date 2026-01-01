#!/bin/bash

cd /build/lame
autoreconf -i

if [[ ${ARCH} == "arm64" && ${TARGET_OS} == "darwin" ]]; then
    CROSS_PREFIX=aarch64-apple-darwin-
fi

./configure --prefix=${PREFIX} --enable-static --disable-shared --enable-nasm --disable-gtktest --disable-cpml --disable-frontend --disable-decode \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/lame

add_enable "--enable-libmp3lame"

exit 0

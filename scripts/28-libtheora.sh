#!/bin/bash

cd /build/libtheora
./autogen.sh --prefix=${PREFIX} \
    --disable-shared \
    --enable-static \
    --with-pic \
    --disable-examples \
    --disable-oggtest \
    --disable-vorbistest \
    --disable-spec \
    --disable-doc \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} \
    --disable-shared \
    --enable-static \
    --with-pic \
    --disable-examples \
    --disable-oggtest \
    --disable-vorbistest \
    --disable-spec \
    --disable-doc \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/libtheora

add_enable "--enable-libtheora"

exit 0

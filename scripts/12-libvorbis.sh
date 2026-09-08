#!/bin/bash

cd /build/libvorbis
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --disable-oggtest \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --disable-oggtest \
    --host=${CROSS_PREFIX%-} 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/libvorbis

add_enable "--enable-libvorbis"

exit 0

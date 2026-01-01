#!/bin/bash

cd /build/freetype
./configure --prefix=${PREFIX} --enable-static --disable-shared \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/freetype

add_enable "--enable-libfreetype"

exit 0

#!/bin/bash

cd /build/zimg
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/zimg

add_enable "--enable-libzimg"

exit 0

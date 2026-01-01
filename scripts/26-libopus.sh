#!/bin/bash

cd /build/opus
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --disable-extra-programs \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --disable-extra-programs \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/opus

add_enable "--enable-libopus"

exit 0

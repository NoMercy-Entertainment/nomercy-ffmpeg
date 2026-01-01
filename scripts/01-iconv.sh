#!/bin/bash

if [[ ${TARGET_OS} == "darwin" ]]; then
    exit 255
fi

cd /build/iconv
./configure --prefix=${PREFIX} --enable-extra-encodings --enable-static --disable-shared --with-pic \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install

rm -rf /build/iconv

add_enable "--enable-iconv"

exit 0

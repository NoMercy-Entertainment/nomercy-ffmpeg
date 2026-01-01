#!/bin/bash

cd /build/libxml2
EXTRA_COMPILE_FLAGS=""
if [[ ${TARGET_OS} == "darwin" ]]; then
    EXTRA_COMPILE_FLAGS="--without-iconv --without-zlib --without-lzma"
fi
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --without-python --disable-maintainer-mode \
    --host=${CROSS_PREFIX%-} ${EXTRA_COMPILE_FLAGS}
./configure --prefix=${PREFIX} --enable-static --disable-shared --without-python --disable-maintainer-mode \
    --host=${CROSS_PREFIX%-} ${EXTRA_COMPILE_FLAGS} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/libxml2

add_enable "--enable-libxml2"

exit 0

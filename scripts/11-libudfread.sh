#!/bin/bash

cd /build/libudfread
./bootstrap --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install

if [ ! -f ${PREFIX}/lib/pkgconfig/libudfread.pc ]; then
    cp libudfread.pc ${PREFIX}/lib/pkgconfig/udfread.pc
    cp ${PREFIX}/lib/pkgconfig/udfread.pc ${PREFIX}/lib/pkgconfig/libudfread.pc
fi

rm -rf /build/libudfread

exit 0

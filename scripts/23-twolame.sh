#!/bin/bash

cd /build/twolame
export NOCONFIGURE=1
./autogen.sh
touch doc/twolame.1
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic --disable-sndfile \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
sed -i 's/Cflags:/Cflags: -DLIBTWOLAME_STATIC/' ${PREFIX}/lib/pkgconfig/twolame.pc
rm -rf /build/twolame
add_cflag "-DLIBTWOLAME_STATIC"
# export CFLAGS="${CFLAGS} -DLIBTWOLAME_STATIC"

add_enable "--enable-libtwolame"

exit 0

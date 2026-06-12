#!/bin/bash

cd /build/libudfread

mkdir -p build && cd build

meson --prefix=${PREFIX} --buildtype=release -Ddefault_library=static \
	--cross-file="/build/cross_file.txt" .. | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	exit 1
fi

ninja -j$(nproc) && ninja install

if [ ! -f ${PREFIX}/lib/pkgconfig/libudfread.pc ]; then
    cp libudfread.pc ${PREFIX}/lib/pkgconfig/udfread.pc
    cp ${PREFIX}/lib/pkgconfig/udfread.pc ${PREFIX}/lib/pkgconfig/libudfread.pc
fi

rm -rf /build/libudfread

exit 0

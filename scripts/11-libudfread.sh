#!/bin/bash

cd /build/libudfread

mkdir -p build && cd build

meson --prefix=${PREFIX} --buildtype=release -Ddefault_library=static \
	--cross-file="/build/cross_file.txt" .. | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log -a "Error: libudfread meson setup failed."
	exit 1
fi

ninja -j$(nproc) 2>&1 | log -a || { log -a "libudfread build failed"; exit 1; }
ninja install 2>&1 | log -a || { log -a "libudfread install failed"; exit 1; }

if [ ! -f ${PREFIX}/lib/pkgconfig/libudfread.pc ]; then
    cp libudfread.pc ${PREFIX}/lib/pkgconfig/udfread.pc
    cp ${PREFIX}/lib/pkgconfig/udfread.pc ${PREFIX}/lib/pkgconfig/libudfread.pc
fi

rm -rf /build/libudfread

exit 0

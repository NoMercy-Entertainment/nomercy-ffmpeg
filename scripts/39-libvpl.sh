#!/bin/bash

if [[ ${TARGET_OS} == "darwin" ]]; then
    exit 255
fi

cd /build/libvpl
mkdir -p build && cd build
cmake -GNinja -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DCMAKE_INSTALL_BINDIR=${PREFIX}/bin -DCMAKE_INSTALL_LIBDIR=${PREFIX}/lib \
    -DBUILD_DISPATCHER=ON -DBUILD_DEV=ON \
    -DBUILD_PREVIEW=OFF -DBUILD_TOOLS=OFF -DBUILD_TOOLS_ONEVPL_EXPERIMENTAL=OFF -DINSTALL_EXAMPLE_CODE=OFF \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

ninja -j$(nproc) && ninja install
rm -rf /build/libvpl ${PREFIX}/{etc,share}

add_enable "--enable-libvpl"

exit 0

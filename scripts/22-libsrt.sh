#!/bin/bash

cd /build/libsrt
mkdir -p build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_CXX_DEPS=ON -DUSE_STATIC_LIBSTDCXX=ON -DENABLE_ENCRYPTION=ON -DENABLE_APPS=OFF | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/srt.pc
rm -rf /build/libsrt

add_enable "--enable-libsrt"

exit 0

#!/bin/bash

cd /build/chromaprint
mkdir -p build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DBUILD_TOOLS=OFF \
    -DBUILD_TESTS=OFF \
    -DFFT_LIB=fftw3 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
echo "Libs.private: -lfftw3 -lstdc++" >>${PREFIX}/lib/pkgconfig/libchromaprint.pc
echo "Cflags.private: -DCHROMAPRINT_NODLL" >>${PREFIX}/lib/pkgconfig/libchromaprint.pc
rm -rf /build/chromaprint

add_enable "--enable-chromaprint"

exit 0

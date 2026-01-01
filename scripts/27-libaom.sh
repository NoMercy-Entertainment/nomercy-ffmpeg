#!/bin/bash

cd /build/libaom
mkdir -p build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DENABLE_EXAMPLES=NO -DENABLE_TESTS=NO -DENABLE_TOOLS=NO -DCONFIG_TUNE_VMAF=1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
echo "Requires.private: libvmaf" >>${PREFIX}/lib/pkgconfig/aom.pc
rm -rf /build/libaom

add_enable "--enable-libaom"

exit 0

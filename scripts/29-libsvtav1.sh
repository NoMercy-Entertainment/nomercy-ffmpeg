#!/bin/bash

EXTRA_CONFIGURE_ARGS=""
if [[ ${TARGET_OS} == "darwin" && ${ARCH} == "x86_64" ]]; then
    EXTRA_CONFIGURE_ARGS="-DCPUINFO_ARCHITECTURE=${ARCH} \
                          -DCMAKE_SYSTEM_PROCESSOR=${ARCH} -Wno-dev \
                          -DUSE_EXTERNAL_CPUINFO=OFF"
fi

cd /build/libsvtav1
mkdir -p build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DBUILD_APPS=OFF -DBUILD_EXAMPLES=OFF -DENABLE_AVX512=ON ${EXTRA_CONFIGURE_ARGS} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/libsvtav1

add_enable "--enable-libsvtav1"

exit 0

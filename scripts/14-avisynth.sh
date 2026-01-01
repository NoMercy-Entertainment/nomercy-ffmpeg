#!/bin/bash

if [[ "${TARGET_OS}" == "darwin" && ${ARCH} == "arm64" ]]; then
    CMAKE_COMMON_ARG="-DCMAKE_INSTALL_PREFIX=${PREFIX} \
    -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
    -DCMAKE_OSX_ARCHITECTURES=arm64"
fi

cd /build/avisynth
mkdir -p build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DHEADERS_ONLY=ON | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make VersionGen install
rm -rf /build/avisynth

add_enable "--enable-avisynth"

exit 0

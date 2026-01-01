#!/bin/bash
if [[ ${TARGET_OS} != "windows" ]]; then
    exit 255
fi

rm -f /ffmpeg_build.log
touch /ffmpeg_build.log

git clone --branch v0.3.30 https://github.com/OpenMathLib/OpenBLAS /build/OpenBLAS
cd /build/OpenBLAS

mkdir build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DBINARY=64 \
    -DBUILD_DEPRECATED=OFF \
    -DBUILD_LAPACK_DEPRECATED=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_WITHOUT_LAPACK=YES \
    -DCMAKE_MT=mt \
    -DCROSS=ON \
    -DDYNAMIC_ARCH=ON \
    -DHOSTCC=gcc \
    -DNUM_THREADS=64 \
    -DTARGET=NEHALEM \
    -DUTEST_CHECK=OFF \
    -DVERBOSE=ON | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "Error: OpenBLAS configure failed" >> /ffmpeg_build.log
    exit 1
fi

cmake --build . -j$(nproc) --config Release | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "Error: OpenBLAS build failed" >> /ffmpeg_build.log
    exit 1
fi

cmake --install . --config Release | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "Error: OpenBLAS install failed" >> /ffmpeg_build.log
    exit 1
else 
    echo "OpenBLAS installed successfully" > /ffmpeg_build.log
fi

cd /build
rm -rf /build/OpenBLAS

exit 0
#!/bin/bash

cd /build/frei0r
mkdir -p build && cd build

cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DWITHOUT_OPENCV=ON \
    -DWITHOUT_CAIRO=ON \
    -DWITHOUT_GAVL=ON \
    -DWITHOUT_FACERECOGNITION=ON \
    -DBUILD_TESTING=OFF | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log -a "Error: frei0r cmake setup failed."
    exit 1
fi

mkdir -p ${PREFIX}/include ${PREFIX}/lib/pkgconfig
cp ../include/frei0r.h ${PREFIX}/include/frei0r.h
cp frei0r.pc ${PREFIX}/lib/pkgconfig/frei0r.pc

echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/frei0r.pc

if [[ ! -f "${PREFIX}/include/frei0r.h" ]]; then
    log -a "Error: frei0r.h was not installed."
    exit 1
fi

if [[ ! -f "${PREFIX}/lib/pkgconfig/frei0r.pc" ]]; then
    log -a "Error: frei0r.pc was not installed."
    exit 1
fi

rm -rf /build/frei0r

add_enable "--enable-frei0r"

exit 0

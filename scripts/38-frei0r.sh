#!/bin/bash

cd /build/frei0r
mkdir -p build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

# && make -j$(nproc) && make install
cp frei0r.pc ${PREFIX}/lib/pkgconfig/frei0r.pc
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/frei0r.pc
cp ../include/frei0r.h ${PREFIX}/include
rm -rf /build/frei0r

add_enable "--enable-frei0r"

exit 0

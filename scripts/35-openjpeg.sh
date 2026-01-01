#!/bin/bash

#region libjpeg
cd /build/jpeg

# Configure and compile
./configure --disable-shared --enable-static \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "Failed to build libjpeg"
    exit 1
fi

make && make install

if [[ ${TARGET_OS} != "linux" ]]; then
    sed -i 's/^Libs: \(.*\)[\r|\n]/Libs: \1 -lz/' ${PREFIX}/lib/pkgconfig/libjpeg.pc
fi
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libjpeg.pc

rm -rf /build/jpeg-v9f
cd /build
#endregion

#region libjpeg-turbo
cd /build/libjpeg-turbo
mkdir build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG}
make -j$(nproc) && make install
if [[ ${TARGET_OS} != "linux" ]]; then
    sed -i 's/^Libs: \(.*\)[\r|\n]/Libs: \1 -lz/' ${PREFIX}/lib/pkgconfig/libjpeg.pc
fi
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libjpeg.pc
cd /build
rm -rf /build/libjpeg-turbo
#endregion

#region openjpeg
cd /build/openjpeg
mkdir build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DBUILD_PKGCONFIG_FILES=ON \
    -DBUILD_CODEC=OFF \
    -DWITH_ASTYLE=OFF \
    -DBUILD_TESTING=OFF | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "Failed to build openjpeg"
    exit 1
fi

make -j$(nproc) && make install

if [[ ${TARGET_OS} != "linux" ]]; then
    echo "Libs.private: -lstdc++ -lm -lpthread -lz" >>${PREFIX}/lib/pkgconfig/libopenjp2.pc
fi

rm -rf /build/openjpeg
#endregion

add_enable "--enable-libopenjpeg"

exit 0

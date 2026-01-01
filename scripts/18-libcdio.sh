#!/bin/bash

EXTRA_FLAGS=""

if [[ ${TARGET_OS} == "darwin" ]]; then
    EXTRA_FLAGS="--without-iconv"
fi

if [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "linux" ]]; then
    cd /build/libcddb
    ./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic ${EXTRA_FLAGS} \
        --host=${CROSS_PREFIX%-} | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi

    make -j$(nproc) && make install
    echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libcddb.pc
    rm -rf /build/libcddb
fi

cd /build/libcdio
touch src/cd-drive.1 src/cd-info.1 src/cd-read.1 src/iso-info.1 src/iso-read.1
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
if [[ ${TARGET_OS} == "darwin" ]]; then
    echo "Libs.private: -lstdc++ -framework DiskArbitration -framework IOKit" >>${PREFIX}/lib/pkgconfig/libcdio.pc
else
    echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libcdio.pc
fi
rm -rf /build/libcdio

# libcdio-paranoia
cd /build/libcdio-paranoia
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
if [[ ${TARGET_OS} == "darwin" ]]; then
    echo "Libs.private: -lstdc++ -framework DiskArbitration -framework IOKit" >>${PREFIX}/lib/pkgconfig/libcdio_paranoia.pc
else
    echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libcdio_paranoia.pc
fi
rm -rf /build/libcdio-paranoia

add_enable "--enable-libcdio"

exit 0

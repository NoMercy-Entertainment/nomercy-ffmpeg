#!/bin/bash

EXTRA_FLAGS=""

if [[ "${TARGET_OS}" == "windows" ]]; then
    if [[ "${ARCH}" == "aarch64" ]]; then
        EXTRA_FLAGS="--disable-asm"
    fi
    cp -r /build/libdavs2/build/linux /build/libdavs2/build/windows
    cd /build/libdavs2/build/windows
elif [[ "${TARGET_OS}" == "darwin" ]]; then
    if [[ "${ARCH}" == "arm64" ]]; then
        CROSS_PREFIX="aarch64-apple-darwin24.1-"
    fi
    cp -r /build/libdavs2/build/linux /build/libdavs2/build/darwin-${ARCH}
    cd /build/libdavs2/build/darwin-${ARCH}
elif [[ "${TARGET_OS}" == "linux" ]]; then
    cd /build/libdavs2/build/linux
    if [[ "${ARCH}" == "aarch64" ]]; then
        cp -r /build/libdavs2/build/linux /build/libdavs2/build/aarch64
        cd /build/libdavs2/build/aarch64
        EXTRA_FLAGS="--disable-asm"
    fi
fi

if [[ "${TARGET_OS}" != "darwin" ]]; then
    sed -i -e 's/EGIB/bss/g' -e 's/naidnePF/bss/g' configure
fi

./configure --prefix=${PREFIX} --disable-cli --enable-static --disable-shared --with-pic \
    --host=${CROSS_PREFIX%-} \
    --cross-prefix=${CROSS_PREFIX} ${EXTRA_FLAGS} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/libdavs2

add_enable "--enable-libdavs2"

exit 0

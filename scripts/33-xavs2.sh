#!/bin/bash

if [[ ${TARGET_OS} == "darwin" ]]; then
    cp -r /build/libxavs2/build/linux /build/libxavs2/build/darwin
    cd /build/libxavs2/build/darwin

    if [[ ${ARCH} == "arm64" ]]; then
        CROSS_PREFIX="aarch64-apple-darwin24.1-"
    fi

    ./configure --prefix=${PREFIX} \
        --disable-cli --enable-static --enable-pic --disable-avs --disable-swscale --disable-lavf --disable-ffms --disable-gpac --disable-lsmash --extra-asflags="-w-macro-params-legacy" \
        --extra-cflags="-Wno-dev -Wno-typedef-redefinition -Wno-unused-but-set-variable -Wno-tautological-compare -Wno-format -Wno-incompatible-function-pointer-types" \
        --host=${CROSS_PREFIX%-} | log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
else
    CONF_FLAGS=""

    if [[ ${TARGET_OS} == "windows" ]]; then
        cp -r /build/libxavs2/build/linux /build/libxavs2/build/windows
        cd /build/libxavs2/build/windows
        if [[ ${ARCH} == "aarch64" ]]; then
            CONF_FLAGS="--disable-asm"
        fi
    else
        if [[ ${ARCH} == "aarch64" ]]; then
            CONF_FLAGS="--disable-asm"
        fi
        cd /build/libxavs2/build/linux
    fi

    ./configure --prefix=${PREFIX} \
        --disable-cli --enable-static --enable-pic --disable-avs --disable-swscale --disable-lavf --disable-ffms --disable-gpac --disable-lsmash --extra-asflags="-w-macro-params-legacy" \
        ${CONF_FLAGS} --host=${CROSS_PREFIX%-} \
        --cross-prefix=${CROSS_PREFIX} | log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
fi

make -j$(nproc) && make install | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

rm -rf /build/libxavs2

add_enable "--enable-libxavs2"

exit 0

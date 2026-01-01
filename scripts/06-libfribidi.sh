#!/bin/bash
if [[ "${TARGET_OS}" == "windows" && "${ARCH}" == "aarch64" ]]; then
    # fribidi is not supported on Windows ARM64 it wants to use libdrm
    exit 255
fi

cd /build/fribidi
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --disable-bin --disable-docs --disable-tests \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --disable-bin --disable-docs --disable-tests \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install

rm -rf /build/fribidi

add_enable "--enable-libfribidi"

exit 0

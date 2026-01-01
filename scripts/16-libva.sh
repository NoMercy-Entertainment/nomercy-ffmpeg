#!/bin/bash

cd /build/libva

if [[ ${TARGET_OS} != "linux" ]]; then
    exit 255
fi

./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --enable-x11 --enable-drm --disable-docs --disable-glx --disable-wayland \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --enable-x11 --enable-drm --disable-docs --disable-glx --disable-wayland \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install

echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libva.pc
rm -rf /build/libva

add_enable "--enable-vaapi"

exit 0

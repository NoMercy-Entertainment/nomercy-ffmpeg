#!/bin/bash

cd /build/libvmaf
mkdir build && cd build
meson --prefix=${PREFIX} \
    --buildtype=release --default-library=static -Dbuilt_in_models=true -Denable_tests=false -Denable_docs=false -Denable_avx512=true -Denable_float=true \
    --cross-file="/build/cross_file.txt" ../libvmaf | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

ninja -j$(nproc) && ninja install
sed -i 's/Libs.private:/Libs.private: -lstdc++/; t; $ a Libs.private: -lstdc++' ${PREFIX}/lib/pkgconfig/libvmaf.pc
rm -rf /build/libvmaf

add_enable "--enable-libvmaf"

exit 0

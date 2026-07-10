#!/bin/bash

if [[ ${TARGET_OS} == "darwin" || ${TARGET_OS} == "freebsd" ]]; then
    # The FreeBSD NVIDIA driver ships no NVENC/CUVID userland
    exit 255
fi

cd /build/ffnvcodec
make PREFIX=${PREFIX} install
rm -rf /build/ffnvcodec

add_enable "--enable-ffnvcodec --enable-nvenc --enable-nvdec"

exit 0

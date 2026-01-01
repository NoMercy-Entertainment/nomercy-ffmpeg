#!/bin/bash

EXTRA_CONFIG=""
if [ ${TARGET_OS} == "darwin" ]; then
    EXTRA_CONFIG="--archs="-arch ${ARCH}""
fi

cd /build/zlib
./configure --prefix=${PREFIX} --static ${EXTRA_CONFIG} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/zlib

exit 0

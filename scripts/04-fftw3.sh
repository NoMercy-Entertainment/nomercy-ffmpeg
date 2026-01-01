#!/bin/bash

EXTRA_FLAGS=""
if [ "${ARCH}" == "x86_64" && ${TARGET_OS} == "linux" ]; then
    EXTRA_FLAGS="--enable-sse2 --enable-avx --enable-avx2"
fi

cd /build/fftw3
./bootstrap.sh --prefix=${PREFIX} --enable-static --disable-shared --enable-maintainer-mode --disable-fortran \
    --disable-doc --with-our-malloc --enable-threads --with-combined-threads --with-incoming-stack-boundary=2 \
    --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install
rm -rf /build/fftw3

exit 0

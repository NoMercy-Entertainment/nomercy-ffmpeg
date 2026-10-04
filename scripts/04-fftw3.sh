#!/bin/bash

EXTRA_FLAGS=""
# [[ ]], not [ ]. Inside single brackets "&&" is a command separator, so this
# read as `[ "${ARCH}" == "x86_64"` -- which fails with "missing ]" -- followed
# by a second, nonsensical command. The test was therefore always false, and
# fftw3 has shipped without SSE2, AVX or AVX2 in every release.
#
# fftw3 is linked by chromaprint alone (FFT_LIB=fftw3 in 15-chromaprint.sh),
# so this speeds up audio fingerprinting on linux-x86_64. It also means that
# platform now computes its FFTs with SIMD while the others stay scalar; the
# results can differ in the last bits. AcoustID matching is tolerant of that,
# but anything comparing fingerprints bit-for-bit across platforms is not.
# fftw selects its SIMD codelets by cpuid at run time, so a CPU without AVX2
# still runs the plain path.
if [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "linux" ]]; then
    EXTRA_FLAGS="--enable-sse2 --enable-avx --enable-avx2"
fi

cd /build/fftw3
./bootstrap.sh --prefix=${PREFIX} --enable-static --disable-shared --enable-maintainer-mode --disable-fortran \
    --disable-doc --with-our-malloc --enable-threads --with-combined-threads --with-incoming-stack-boundary=2 \
    --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS} 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install || exit 1
rm -rf /build/fftw3

exit 0

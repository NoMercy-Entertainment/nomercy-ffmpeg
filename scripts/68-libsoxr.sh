#!/bin/bash

# SoX Resampler (libsoxr), LGPL-2.1: a higher-quality resampler for
# libswresample, chosen per filter with aresample=resampler=soxr.
# 0.1.3 is the last release; GitHub mirrors the SourceForge repository, and
# the commit below is the same in both.
SOXR_VERSION=0.1.3
SOXR_COMMIT=945b592b70470e29f917f4de89b4281fbbd540c0

cd /build || exit 1
retry git clone --depth 1 --branch "${SOXR_VERSION}" https://github.com/chirlu/soxr.git soxr 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
cd /build/soxr || exit 1
if [[ "$(git rev-parse HEAD)" != "${SOXR_COMMIT}" ]]; then
    log "soxr: tag ${SOXR_VERSION} is $(git rev-parse HEAD), expected ${SOXR_COMMIT}"
    exit 1
fi

# soxr's SIMD engines are x86 only in 0.1.3: on ARM its run-time check
# returns false unless soxr is built on libavcodec's FFT, and its NEON code
# is for 32-bit ARM. So on aarch64 they would never run; leave them out
# rather than let its compiler-flag probe try 32-bit ARM flags on clang.
# On x86_64 the AVX engine is compiled in and chosen at run time by cpuid.
SIMD_FLAGS=""
if [[ ${ARCH} != x86_64 ]]; then
    SIMD_FLAGS="-DWITH_CR32S=OFF -DWITH_CR64S=OFF"
fi

# No OpenMP: the binary would need libgomp, and FFmpeg calls soxr per
# filter instance anyway. No tests, examples or libsamplerate interface.
cmake -S . -B build ${CMAKE_COMMON_ARG} \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_SYSTEM_PROCESSOR="${ARCH}" \
    -DBUILD_SHARED_LIBS=OFF -DWITH_OPENMP=OFF -DBUILD_TESTS=OFF \
    -DBUILD_EXAMPLES=OFF -DWITH_LSR_BINDINGS=OFF -DWITH_DEV_TRACE=OFF \
    ${SIMD_FLAGS} 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
cmake --build build --parallel "$(nproc)" 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
cmake --install build 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
if [[ ! -f "${PREFIX}/lib/libsoxr.a" || ! -f "${PREFIX}/include/soxr.h" ]]; then
    log "soxr install incomplete: missing static archive or header"
    exit 1
fi

cd /build || exit 1
rm -rf /build/soxr
add_enable "--enable-libsoxr"

exit 0

#!/bin/bash

SNAPPY_VERSION=1.3.1

cd /build || exit 1
retry git clone --depth 1 --branch "${SNAPPY_VERSION}" https://github.com/google/snappy.git snappy 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
cd /build/snappy || exit 1
cmake -S . -B build ${CMAKE_COMMON_ARG} \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_SYSTEM_PROCESSOR="${ARCH}" \
    -DBUILD_SHARED_LIBS=OFF -DSNAPPY_INSTALL=ON \
    -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF \
    -DSNAPPY_REQUIRE_AVX=OFF -DSNAPPY_REQUIRE_AVX2=OFF 2>&1 | log -a
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
if [[ ! -f "${PREFIX}/lib/libsnappy.a" || ! -f "${PREFIX}/include/snappy-c.h" ]]; then
    log "snappy install incomplete: missing static archive or C header"
    exit 1
fi

# FFmpeg 9.0 probes the C API with a hard-coded -lstdc++. macOS uses
# libc++; change only that library's check, with a checked source anchor.
if [[ ${TARGET_OS} == darwin ]]; then
    if ! grep -q '^enabled libsnappy .*snappy_compress -lsnappy -lstdc++$' /build/ffmpeg/configure; then
        log "snappy: FFmpeg configure check changed; cannot select libc++ safely"
        exit 1
    fi
    sed -i '/^enabled libsnappy .*snappy_compress /s/ -lstdc++$/ -lc++/' /build/ffmpeg/configure || exit 1
fi

cd /build || exit 1
rm -rf /build/snappy
add_enable "--enable-libsnappy"

exit 0

#!/bin/bash

OPENAPV_VERSION=1.1.3.0

cd /build || exit 1
retry git clone --depth 1 --branch "v${OPENAPV_VERSION}" https://github.com/AcademySoftwareFoundation/openapv.git openapv 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
cd /build/openapv || exit 1
cmake -S . -B build ${CMAKE_COMMON_ARG} \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_SYSTEM_PROCESSOR="${ARCH}" \
    -DOAPV_BUILD_STATIC_LIB=ON -DOAPV_BUILD_SHARED_LIB=OFF \
    -DOAPV_BUILD_APPS=OFF 2>&1 | log -a
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

OAPV_PC="${PREFIX}/lib/pkgconfig/oapv.pc"
if [[ ! -f "${PREFIX}/lib/liboapv.a" || ! -f "${PREFIX}/include/oapv/oapv.h" || ! -f "${OAPV_PC}" ]]; then
    log "OpenAPV install incomplete: missing static archive, header or oapv.pc"
    exit 1
fi
# Static-only upstream builds publish this define in Cflags. Without it the
# header expects the shared build's export header, which we do not install.
if ! grep -q '^Cflags:.*-DOAPV_STATIC_DEFINE' "${OAPV_PC}"; then
    log "OpenAPV pkg-config is missing the public static-library define"
    exit 1
fi
if ! pkg-config --static --exists 'oapv >= 0.2.0.0'; then
    log "OpenAPV pkg-config dependency check failed"
    exit 1
fi

# Backport the release/9.0 wrapper's API-set 1 metadata descriptor support.
# OpenAPV copies this zero-initialized descriptor and uses its default allocator.
if ! grep -q 'oapvm_create(&mcdsc, &ret)' /build/ffmpeg/libavcodec/liboapvenc.c; then
    patch -d /build/ffmpeg -p1 --fuzz=0 < /scripts/includes/liboapv-api1.patch 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
fi

cd /build || exit 1
rm -rf /build/openapv
add_enable "--enable-liboapv"

exit 0

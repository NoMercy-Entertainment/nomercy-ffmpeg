#!/bin/bash

# Rubber Band: tempo and pitch changed independently of each other, with the
# formants kept (FFmpeg's rubberband filter). GPL-2.0-or-later, which the
# build already is (--enable-gpl).
RUBBERBAND_VERSION=4.0.0
# The commit the tag points at, so a moved tag stops the build instead of
# building something else under the same name.
RUBBERBAND_COMMIT=1d95888bec3ae0a17c0c4af791810d5a63f6bc35

cd /build || exit 1
retry git clone --depth 1 --branch "v${RUBBERBAND_VERSION}" https://github.com/breakfastquay/rubberband.git rubberband 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
cd /build/rubberband || exit 1
if [[ "$(git rev-parse HEAD)" != "${RUBBERBAND_COMMIT}" ]]; then
    log "rubberband: tag v${RUBBERBAND_VERSION} is $(git rev-parse HEAD), expected ${RUBBERBAND_COMMIT}"
    exit 1
fi

# The FFT the library uses. macOS gets Apple's vDSP (Accelerate, already in
# LDFLAGS there); everywhere else the built-in FFT, which needs nothing extra.
# These are upstream's own defaults, named here so they cannot change under us.
RUBBERBAND_FFT=builtin
if [[ ${TARGET_OS} == darwin ]]; then
    RUBBERBAND_FFT=vdsp
fi

# Rubber Band's meson.build accepts only aarch64 and x86_64 as the CPU on
# macOS and stops on anything else. The darwin-arm64 cross file says arm64
# (that is ARCH there), so give meson a copy that says aarch64. Every other
# script keeps the shared cross file as it is.
CROSS_FILE=/build/cross_file.txt
if [[ ${TARGET_OS} == darwin && ${ARCH} == arm64 ]]; then
    CROSS_FILE=/build/rubberband_cross_file.txt
    sed "s/^cpu_family = 'arm64'$/cpu_family = 'aarch64'/" /build/cross_file.txt >"${CROSS_FILE}" || exit 1
    if ! grep -q "^cpu_family = 'aarch64'$" "${CROSS_FILE}"; then
        log "rubberband: could not set cpu_family to aarch64 in the darwin-arm64 cross file"
        exit 1
    fi
fi

# Only the library: no command-line tool, plugins, Java binding or tests.
meson setup build --prefix="${PREFIX}" --libdir=lib --buildtype=release \
    -Ddefault_library=static --cross-file="${CROSS_FILE}" \
    -Dfft="${RUBBERBAND_FFT}" -Dresampler=builtin \
    -Dcmdline=disabled -Dladspa=disabled -Dlv2=disabled -Dvamp=disabled \
    -Djni=disabled -Dtests=disabled 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
ninja -C build -j"$(nproc)" 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
ninja -C build install 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

if [[ ! -f "${PREFIX}/lib/librubberband.a" || ! -f "${PREFIX}/include/rubberband/rubberband-c.h" \
    || ! -f "${PREFIX}/lib/pkgconfig/rubberband.pc" ]]; then
    log "rubberband install incomplete: missing static archive, C header or rubberband.pc"
    exit 1
fi
if ! pkg-config --static --exists 'rubberband >= 1.8.1'; then
    log "rubberband pkg-config check failed"
    exit 1
fi

# FFmpeg's rubberband filter, two changes (rubberband-engine-delay.patch):
# - an engine option: faster (R2, the default, as upstream) or finer (R3);
# - no delay: the filter runs Rubber Band in real-time mode, which leaves
#   the start delay to the caller, and upstream never compensated it
#   (measured: the output was up to 32 ms off). The filter now feeds the
#   preferred start pad, drops the start delay, flushes at the end, and
#   makes the output exactly input length / tempo samples long.
# The configure check moves to Rubber Band 3.0, the first with that API.
if ! grep -q 'RubberBandOptionEngineFiner' /build/ffmpeg/libavfilter/af_rubberband.c; then
    patch -d /build/ffmpeg -p1 --fuzz=0 < /scripts/includes/rubberband-engine-delay.patch 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
fi

# FFmpeg's configure check links the C API with a hard-coded -lstdc++ and
# adds the same flag to the final link. macOS has libc++ only, so change that
# one check there, as 63-libsnappy.sh does for snappy. The other platforms
# resolve -lstdc++ (FreeBSD and windows-aarch64 through their shims).
if [[ ${TARGET_OS} == darwin ]]; then
    if ! grep -q '^enabled librubberband .*rubberband_new -lstdc++ && append librubberband_extralibs "-lstdc++"$' /build/ffmpeg/configure; then
        log "rubberband: FFmpeg configure check changed; cannot select libc++ safely"
        exit 1
    fi
    sed -i '/^enabled librubberband /s/-lstdc++/-lc++/g' /build/ffmpeg/configure || exit 1
fi

cd /build || exit 1
rm -rf /build/rubberband /build/rubberband_cross_file.txt
add_enable "--enable-librubberband"

exit 0

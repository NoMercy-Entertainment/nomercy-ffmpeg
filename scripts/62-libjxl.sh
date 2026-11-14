#!/bin/bash

LIBJXL_VERSION=0.13.0

cd /build || exit 1
retry git clone --depth 1 --branch "v${LIBJXL_VERSION}" https://github.com/libjxl/libjxl.git libjxl 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
retry git -C libjxl submodule update --init --depth 1 \
    third_party/highway third_party/brotli third_party/skcms 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

# Keep each compiler flag string in ONE CMake argument. Splitting this as a
# shell string loses the assembler option when CFLAGS contains spaces.
JXL_EXTRA=()
if [[ ${TARGET_OS} == "windows" && ${ARCH} == "x86_64" ]]; then
    # MinGW GCC does not realign the Win64 stack for Highway's AVX2 loads
    # (GCC bug 54412). Do not raise the CPU baseline with -march/-mavx2.
    JXL_EXTRA+=("-DCMAKE_C_FLAGS=${CFLAGS} -Wa,-muse-unaligned-vector-move"
                "-DCMAKE_CXX_FLAGS=${CXXFLAGS} -Wa,-muse-unaligned-vector-move")
fi

cd /build/libjxl || exit 1
cmake -S . -B build ${CMAKE_COMMON_ARG} "${JXL_EXTRA[@]}" \
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_SYSTEM_PROCESSOR="${ARCH}" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DJPEGXL_STATIC=OFF \
    -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
    -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF \
    -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_PLUGINS=OFF \
    -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_FUZZERS=OFF \
    -DJPEGXL_ENABLE_TCMALLOC=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF \
    -DJPEGXL_ENABLE_SKCMS=ON 2>&1 | log -a
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

JXL_PC_DIR="${PREFIX}/lib/pkgconfig"
for component in jxl jxl_threads jxl_cms; do
    pc="${JXL_PC_DIR}/lib${component}.pc"
    if [[ ! -f "${pc}" || ! -f "${PREFIX}/lib/lib${component}.a" ]]; then
        log "libjxl install incomplete: missing ${component} archive or pkg-config file"
        exit 1
    fi
    case "${component}" in
        jxl) define=JXL_STATIC_DEFINE ;;
        jxl_threads) define=JXL_THREADS_STATIC_DEFINE ;;
        jxl_cms) define=JXL_CMS_STATIC_DEFINE ;;
    esac
    # pkg-config implementations differ on Cflags.private. Public defines
    # prevent __imp_Jxl* references when FFmpeg uses the static Windows libs.
    sed -i "/^Cflags:/ s/$/ -D${define}/" "${pc}" || exit 1
done

case "${TARGET_OS}" in
    darwin|freebsd) JXL_RUNTIME="-lc++" ;;
    windows) JXL_RUNTIME="-lstdc++ -ladvapi32" ;;
    *) JXL_RUNTIME="-lstdc++" ;;
esac
for component in jxl jxl_threads; do
    pc="${JXL_PC_DIR}/lib${component}.pc"
    if grep -q '^Libs.private:' "${pc}"; then
        sed -i "/^Libs.private:/ s/$/ ${JXL_RUNTIME}/" "${pc}" || exit 1
    else
        echo "Libs.private: ${JXL_RUNTIME}" >>"${pc}" || exit 1
    fi
done

JXL_LIBS=$(pkg-config --static --libs libjxl libjxl_threads 2>>/ffmpeg_build.log) || exit 1
log "libjxl static link flags: ${JXL_LIBS}"
for dependency in hwy brotlienc brotlidec brotlicommon jxl_cms; do
    if [[ " ${JXL_LIBS} " != *" -l${dependency} "* ]]; then
        log "libjxl static link is missing -l${dependency}"
        exit 1
    fi
done

cd /build || exit 1
rm -rf /build/libjxl
add_enable "--enable-libjxl"

exit 0

#!/bin/bash

if [ ! -d ${PREFIX}/lib/pkgconfig ]; then
    mkdir -p ${PREFIX}/lib/pkgconfig
fi

# #region libpng
cd /build/libpng

LIBPNG_EXTRA_FLAGS=""
if [[ ${TARGET_OS} == "freebsd" ]]; then
    # the pngvalid test program uses feenableexcept, which FreeBSD's fenv.h
    # hides under the _POSIX_SOURCE that pngpriv.h defines — skip the tests
    LIBPNG_EXTRA_FLAGS="--disable-tests --disable-tools"
fi

./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pkgconfigdir=${PREFIX}/lib/pkgconfig \
    ${LIBPNG_EXTRA_FLAGS} --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pkgconfigdir=${PREFIX}/lib/pkgconfig \
    CPPFLAGS="${CPPFLAGS} -I${PREFIX}/include" \
    LDFLAGS="${LDFLAGS} -L${PREFIX}/lib -lz" \
    ${LIBPNG_EXTRA_FLAGS} --host=${CROSS_PREFIX%-} 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "Failed to build libpng config"
    exit 1
fi

make clean
make -j$(nproc) || exit 1
make install || exit 1

if [ ! -f ${PREFIX}/lib/libpng.a ]; then
    log "Failed to build libpng a "
    exit 1
fi
if [ ! -f ${PREFIX}/include/png.h ]; then
    log "Failed to build libpng h "
    exit 1
fi
if [ ! -f ${PREFIX}/include/pngconf.h ]; then
    log "Failed to build libpng c"
    exit 1
fi
if [ ! -f ${PREFIX}/include/pnglibconf.h ]; then
    log "Failed to build libpng ch"
    exit 1
fi
if [ ! -f ${PREFIX}/lib/pkgconfig/libpng.pc ]; then
    log "Failed to build libpng p"
    exit 1
fi
if [[ ${TARGET_OS} != "linux" ]]; then
    echo "Libs.private: -lstdc++ -lz" >>${PREFIX}/lib/pkgconfig/libpng.pc
else
    echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libpng.pc
fi
cd /build
rm -rf /build/libpng
if pkg-config --modversion libpng >/dev/null 2>&1; then
    log "libpng is installed."
else
    log "libpng is missing!"
    exit 1 # Optional: Exit script if libpng is not found
fi
# #endregion

#region libgif
cd /build/giflib

# Only the static library and the header are consumed here (libwebp's GIF
# support), so every platform builds just the static target and installs
# those two files itself. A full `make` also builds the shared library, the
# libutil helper and the CLI tools, and that broke one platform after the
# other: windows-aarch64's lld rejects the ELF-only -soname on libgif.so,
# windows-x86_64 fails on libutil.so (a DLL must resolve every symbol), and
# giflib 6.1.3 stopped building on darwin. Before 6.1.3 the Linux and darwin
# builds also installed imagemagick into the build container for giflib's
# documentation, which nothing here uses.
#
# `|| { ...; exit 1; }`, never `|| ( ...; exit 1 )`: parentheses run the
# handler in a subshell, whose exit ends nothing but the subshell (found in
# the October 2026 audit, when a failed giflib make carried on silently).
make libgif.a 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ] || [ ! -f libgif.a ] || [ ! -f gif_lib.h ]; then
    log "Error: giflib make libgif.a failed."
    exit 1
fi
cp gif_lib.h ${PREFIX}/include/gif_lib.h || { log "Error: installing gif_lib.h failed."; exit 1; }
cp libgif.a ${PREFIX}/lib/libgif.a || { log "Error: installing libgif.a failed."; exit 1; }

# The version the header declares, so giflib.pc says what was built.
giflib_version=$(awk '/#define GIFLIB_(MAJOR|MINOR|RELEASE)/ { v = v (v ? "." : "") $3 } END { print v }' gif_lib.h)
{
    echo "prefix=${PREFIX}"
    echo "exec_prefix=\${prefix}"
    echo "libdir=\${exec_prefix}/lib"
    echo "includedir=\${prefix}/include"
    echo ""
    echo "Name: giflib"
    echo "Description: GIF library"
    echo "Version: ${giflib_version:-unknown}"
    echo "Libs: -L\${libdir} -lgif"
    echo "Cflags: -I\${includedir}"
    if [[ ${TARGET_OS} != "linux" ]]; then
        echo "Libs.private: -lstdc++ -lz"
    else
        echo "Libs.private: -lstdc++"
    fi
} >${PREFIX}/lib/pkgconfig/giflib.pc
log "giflib ${giflib_version} (static library and header)"
cd /build
rm -rf /build/giflib
#endregion

#region libtiff
cd /build/libtiff
# Settle libtiff's 8/12-bit JPEG decision instead of letting configure probe
# for it.
#
# libtiff decides whether to compile tif_jpeg_12.c by looking for ONE symbol:
#
#     AC_CHECK_LIB(jpeg, jpeg12_read_scanlines, HAVE_JPEGTURBO_DUAL_MODE_8_12=yes)
#
# Our libjpeg-turbo answers that probe, but does not provide the three
# functions the resulting object then needs -- jpeg12_write_raw_data,
# jpeg12_read_raw_data and jpeg12_write_scanlines. So the object compiles and
# the failure surfaces much later and somewhere else: as undefined references
# while gdk-pixbuf links, which aborts LIBRSVG seven minutes into the build
# with an error naming neither libtiff nor libjpeg.
#
# Measured: the probe falls that way on the mingw cross to windows-x86_64 and
# the other way on linux-x86_64 and darwin-x86_64, where librsvg builds fine.
# It is a build-time coin flip nobody chose, so it is settled here for every
# platform rather than only for the one that lost -- leaving the other two on a
# probe leaves them free to flip the same way tomorrow. Overriding the autoconf
# cache variable is enough: no patch to libtiff, and the probe never runs.
#
# Nothing is lost by it. 12-bit JPEG inside TIFF is not something this project
# reads or writes; libtiff is here for gdk-pixbuf, which is here for librsvg,
# which renders SVG.
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pkgconfigdir=${PREFIX}/lib/pkgconfig \
    --host=${CROSS_PREFIX%-}
ac_cv_lib_jpeg_jpeg12_read_scanlines=no \
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pkgconfigdir=${PREFIX}/lib/pkgconfig \
    --host=${CROSS_PREFIX%-} 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "Failed to build libtiff"
    exit 1
fi
make -j$(nproc) && make install || exit 1
if [ ! -f ${PREFIX}/lib/pkgconfig/libtiff-4.pc ]; then
    log "Failed to build libtiff"
    exit 1
fi
if [[ ${TARGET_OS} != "linux" ]]; then
    echo "Libs.private: -lstdc++ -lz" >>${PREFIX}/lib/pkgconfig/libtiff-4.pc
else
    echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libtiff-4.pc
fi
cd /build
rm -rf /build/libtiff
#endregion

#region libwebp
cd /build/libwebp
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --enable-libwebpmux --enable-libwebpextras --enable-libwebpdemux --enable-libwebpdecoder \
    --disable-sdl --disable-gl --enable-gif --enable-jpeg --enable-tiff \
    --with-pngincludedir=${PREFIX}/include --with-pnglibdir=${PREFIX}/lib --enable-png \
    LDFLAGS="${LDFLAGS} -L${PREFIX}/lib" \
    CPPFLAGS="${CPPFLAGS} -I${PREFIX}/include" \
    CFLAGS="${CFLAGS} -I${PREFIX}/include" \
    LIBS="-lpng16 -lz" \
    PNG_INCLUDES="I${PREFIX}/include" \
    PNG_LIBS="${PREFIX}/lib" \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
    --enable-libwebpmux --enable-libwebpextras --enable-libwebpdemux --enable-libwebpdecoder \
    --disable-sdl --disable-gl --enable-gif --enable-jpeg --enable-tiff \
    --with-pngincludedir=${PREFIX}/include --with-pnglibdir=${PREFIX}/lib --enable-png \
    LDFLAGS="${LDFLAGS} -L${PREFIX}/lib" \
    CPPFLAGS="${CPPFLAGS} -I${PREFIX}/include" \
    CFLAGS="${CFLAGS} -I${PREFIX}/include" \
    LIBS="-lpng16 -lz" \
    PNG_INCLUDES="${PREFIX}/include" \
    PNG_LIBS="${PREFIX}/lib" \
    --host=${CROSS_PREFIX%-} 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "Failed to build libwebp"
    exit 1
fi

make -j$(nproc) && make install || exit 1
rm -rf /build/libwebp

cp ${PREFIX}/lib/pkgconfig/libsharpyuv.pc ${PREFIX}/lib/pkgconfig/sharpyuv.pc
#endregion

add_enable "--enable-libwebp"

exit 0

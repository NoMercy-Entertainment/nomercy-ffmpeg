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

if [[ ${TARGET_OS} != "windows" ]]; then
    apt-get update
    apt-get install -y --no-install-recommends imagemagick

    if [[ ${TARGET_OS} == "darwin" ]]; then
        sed -i 's/-Wl,-soname/-Wl,-install_name/g' Makefile
    fi

    # `|| { ...; exit 1; }`, never `|| ( ...; exit 1 )`. Parentheses run the
    # block in a subshell, so its exit leaves the subshell and nothing else:
    # a failed giflib make logged its error and the build carried on as though
    # it had worked. All five handlers in this region had that shape.
    make PREFIX=${PREFIX} || {
        log "Error: giflib make failed."
        exit 1
    }

    make PREFIX=${PREFIX} install || {
        log "Error: giflib install failed."
        exit 1
    }
else
    # Only the static library and the header are consumed here, so build just
    # the static target and skip `make install`; the gif_lib.h / libgif.a
    # copies below install exactly what is needed. A full `make` fails on
    # both windows targets:
    #   windows-aarch64 links with lld, which rejects the ELF-only -soname
    #     flag on libgif.so ("lld: error: unknown argument: -soname"), and
    #     make dies there, before it has written libgif.a.
    #   windows-x86_64 gets past that (GNU ld only warns), writes libgif.a,
    #     then fails on libutil.so, the helper library for giflib's own CLI
    #     tools: a DLL must resolve every symbol, and it cannot find GifErrorString.
    # The x86_64 failure was invisible until the October 2026 audit: the
    # handler ran in a subshell, so the build carried on and the fallback
    # copies below picked up the libgif.a that make had already written.
    make libgif.a || {
        log "Error: giflib make failed."
        exit 1
    }
    if [ ! -f ${PREFIX}/include/gif_lib.h ]; then
        if [ -f gif_lib.h ]; then
            cp gif_lib.h ${PREFIX}/include/gif_lib.h
        else
            log "Failed to build giflib 1"
            exit 1
        fi
    fi
    if [ ! -f ${PREFIX}/lib/libgif.a ]; then
        if [ -f libgif.a ]; then
            cp libgif.a ${PREFIX}/lib/libgif.a
        else
            log "Failed to build giflib 2"
            exit 1
        fi
    fi
fi

if [ ! -f ${PREFIX}/lib/pkgconfig/giflib.pc ]; then
    if [ -f giflib.pc ]; then
        cp giflib.pc ${PREFIX}/lib/pkgconfig/giflib.pc
        sed -i "s|prefix=.*|prefix=${PREFIX}|g" ${PREFIX}/lib/pkgconfig/giflib.pc
    else
        {
            echo "prefix=${PREFIX}"
            echo "exec_prefix=\${prefix}"
            echo "libdir=\${exec_prefix}/lib"
            echo "includedir=\${prefix}/include"
            echo ""
            echo "Name: giflib"
            echo "Description: GIF library"
            echo "Version: 5.2.2"
            echo "Libs: -L\${libdir} -lgif"
            echo "Cflags: -I\${includedir}"
        } >${PREFIX}/lib/pkgconfig/giflib.pc
    fi
fi
if [ ! -f ${PREFIX}/lib/pkgconfig/giflib.pc ]; then
    log "Failed to build giflib 3"
    exit 1
fi
if [[ ${TARGET_OS} != "linux" ]]; then
    echo "Libs.private: -lstdc++ -lz" >>${PREFIX}/lib/pkgconfig/giflib.pc
else
    echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/giflib.pc
fi
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

#!/bin/bash

if [[ ${TARGET_OS} == "linux" || ${TARGET_OS} == "windows" || ${ARCH} == "arm64" || ${ARCH} == "aarch64" ]]; then
	exit 255;
fi

# Versions
LIBRSVG_VERSION=2.61.3
GLIB_VERSION=2.82.4
CAIRO_VERSION=1.18.2
PANGO_VERSION=1.54.0
GDK_PIXBUF_VERSION=2.42.12
PIXMAN_VERSION=0.44.2
LIBFFI_VERSION=3.4.6
PCRE2_VERSION=10.44

# Store original flags
ORIG_CFLAGS="${CFLAGS}"
ORIG_CXXFLAGS="${CXXFLAGS}"
ORIG_LDFLAGS="${LDFLAGS}"

clear_log() {
	rm -f /ffmpeg_build.log
	touch /ffmpeg_build.log
}

#---------------------------------------------------------------------------------------------------------#
# Build libffi (required by glib2)
#---------------------------------------------------------------------------------------------------------#
build_libffi() {
    clear_log
    log "Building libffi ${LIBFFI_VERSION}..."
    
    cd /build
    rm -rf libffi libffi-${LIBFFI_VERSION}
    
    # Use tarball release which includes pre-generated configure script
    wget -O libffi.tar.gz https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log "libffi download failed"
        return 1
    fi
    
    tar -xzf libffi.tar.gz >/dev/null 2>&1
    rm -f libffi.tar.gz
    mv libffi-${LIBFFI_VERSION} libffi
    cd libffi

    ./configure --prefix=${PREFIX} \
        --enable-static \
        --disable-shared \
        --disable-docs \
        --disable-exec-static-tramp \
        --host=${CROSS_PREFIX%-} | log -a

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "libffi configure failed"
        return 1
    fi

    make -j$(nproc) && make install
    if [ $? -ne 0 ]; then
        log "libffi build failed"
        return 1
    fi

    if [[ -f ${PREFIX}/lib/pkgconfig/libffi.pc ]]; then
        echo "Libs.private: -lstdc++" >> ${PREFIX}/lib/pkgconfig/libffi.pc
    fi
    rm -rf /build/libffi
    log "libffi built successfully"
    return 0
}

#---------------------------------------------------------------------------------------------------------#
# Build pcre2 (required by glib2)
#---------------------------------------------------------------------------------------------------------#
build_pcre2() {
    clear_log
    log "Building pcre2 ${PCRE2_VERSION}..."
    
    cd /build
    if [[ ! -d pcre2 ]]; then
        git clone --branch pcre2-${PCRE2_VERSION} --depth 1 https://github.com/PCRE2Project/pcre2.git pcre2 >/dev/null 2>&1
    fi
    cd pcre2
    
    mkdir -p build && cd build
    cmake -S .. -B . \
        ${CMAKE_COMMON_ARG} \
        -DPCRE2_BUILD_PCRE2GREP=OFF \
        -DPCRE2_BUILD_TESTS=OFF \
        -DPCRE2_SUPPORT_UNICODE=ON \
        -DPCRE2_SUPPORT_JIT=ON | log -a

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "pcre2 configure failed"
        return 1
    fi

    make -j$(nproc) && make install
    if [ $? -ne 0 ]; then
        log "pcre2 build failed"
        return 1
    fi

    # Ensure pkgconfig files exist
    for pc in libpcre2-8 libpcre2-16 libpcre2-32 libpcre2-posix; do
        if [[ -f ${PREFIX}/lib/pkgconfig/${pc}.pc ]]; then
            echo "Libs.private: -lstdc++" >> ${PREFIX}/lib/pkgconfig/${pc}.pc
        fi
    done

    rm -rf /build/pcre2
    log "pcre2 built successfully"
    return 0
}

#---------------------------------------------------------------------------------------------------------#
# Build glib2 (required by cairo, pango, gdk-pixbuf, librsvg)
#---------------------------------------------------------------------------------------------------------#
build_glib2() {
    clear_log
    log "Building glib2 ${GLIB_VERSION}..."
    
    cd /build
    if [[ ! -d glib ]]; then
        git clone --branch ${GLIB_VERSION} --depth 1 https://gitlab.gnome.org/GNOME/glib.git glib >/dev/null 2>&1
    fi
    cd glib

    # Create meson cross file additions for glib
    local glib_cross_file="/build/glib_cross_file.txt"
    cp /build/cross_file.txt "${glib_cross_file}"
    
    # For macOS, add objc and objcpp compilers to [binaries] section
    # Add objc compilers right after the [binaries] section header
    sed -i "s/^\[binaries\]$/[binaries]\nobjc = '${CROSS_PREFIX}clang'\nobjcpp = '${CROSS_PREFIX}clang++'/" "${glib_cross_file}"
    
    # Add glib-specific properties using built-in options (meson 1.0+ style)
    {
        echo ""
        echo "[built-in options]"
        echo "c_args = ['-I${PREFIX}/include']"
        echo "c_link_args = ['-L${PREFIX}/lib']"
    } >> "${glib_cross_file}"

    mkdir -p build && cd build
    meson setup --prefix=${PREFIX} \
        --buildtype=release \
        --default-library=static \
        -Dtests=false \
        -Dglib_debug=disabled \
        -Dintrospection=disabled \
        -Dnls=disabled \
        -Dlibmount=disabled \
        -Dman-pages=disabled \
        -Ddtrace=false \
        -Dsystemtap=false \
        -Dgtk_doc=false \
        -Dbsymbolic_functions=false \
        -Dforce_posix_threads=true \
        --cross-file="${glib_cross_file}" .. | log -a

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "glib2 configure failed"
        return 1
    fi

    ninja -j$(nproc) 2>&1 | log -a && ninja install 2>&1 | log -a
    if [ $? -ne 0 ]; then
        log "glib2 build failed"
        return 1
    fi

    # Add private libs to pkgconfig
    for pc in glib-2.0 gobject-2.0 gio-2.0 gmodule-2.0 gthread-2.0; do
        if [[ -f ${PREFIX}/lib/pkgconfig/${pc}.pc ]]; then
            echo "Libs.private: -lstdc++ -lm" >> ${PREFIX}/lib/pkgconfig/${pc}.pc
        fi
    done

    rm -rf /build/glib "${glib_cross_file}"
    log "glib2 built successfully"
    return 0
}

#---------------------------------------------------------------------------------------------------------#
# Build pixman (required by cairo)
#---------------------------------------------------------------------------------------------------------#
build_pixman() {
    clear_log
    log "Building pixman ${PIXMAN_VERSION}..."
    
    cd /build
    if [[ ! -d pixman ]]; then
        git clone --branch pixman-${PIXMAN_VERSION} --depth 1 https://gitlab.freedesktop.org/pixman/pixman.git pixman >/dev/null 2>&1
    fi
    cd pixman

    mkdir -p build && cd build
    meson setup --prefix=${PREFIX} \
        --buildtype=release \
        --default-library=static \
        -Dgtk=disabled \
        -Dlibpng=enabled \
        -Dtests=disabled \
        -Ddemos=disabled \
        --cross-file="/build/cross_file.txt" .. | log -a

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "pixman configure failed"
        return 1
    fi

    ninja -j$(nproc) 2>&1 | log -a && ninja install 2>&1 | log -a
    if [ $? -ne 0 ]; then
        log "pixman build failed"
        return 1
    fi

    if [[ -f ${PREFIX}/lib/pkgconfig/pixman-1.pc ]]; then
        echo "Libs.private: -lstdc++ -lm -lpng16" >> ${PREFIX}/lib/pkgconfig/pixman-1.pc
    fi

    rm -rf /build/pixman
    log "pixman built successfully"
    return 0
}

#---------------------------------------------------------------------------------------------------------#
# Build cairo
#---------------------------------------------------------------------------------------------------------#
build_cairo() {
    clear_log
    log "Building cairo ${CAIRO_VERSION}..."
    
    cd /build
    if [[ ! -d cairo ]]; then
        git clone --branch ${CAIRO_VERSION} --depth 1 https://gitlab.freedesktop.org/cairo/cairo.git cairo >/dev/null 2>&1
    fi
    cd cairo

    local cairo_options="-Dtests=disabled \
        -Dgtk_doc=false \
        -Dspectre=disabled \
        -Dsymbol-lookup=disabled \
        -Dfontconfig=enabled \
        -Dfreetype=enabled \
        -Dpng=enabled \
        -Dzlib=enabled \
        -Dglib=enabled"

    cairo_options="${cairo_options} -Dxlib=disabled -Dxcb=disabled -Dquartz=enabled"

    # Create cairo-specific cross file with libxml2 in link args
    local cairo_cross_file="/build/cairo_cross_file.txt"
    cp /build/cross_file.txt "${cairo_cross_file}"
    
    # For macOS, add objc and objcpp compilers to [binaries] section
    # Add objc compilers right after the [binaries] section header
    sed -i "s/^\[binaries\]$/[binaries]\nobjc = '${CROSS_PREFIX}clang'\nobjcpp = '${CROSS_PREFIX}clang++'/" "${cairo_cross_file}"
    
    # Add libxml2 to link args for fontconfig dependency
    {
        echo ""
        echo "[built-in options]"
        echo "c_args = ['-I${PREFIX}/include', '-I${PREFIX}/include/libxml2']"
        echo "c_link_args = ['-L${PREFIX}/lib', '-lxml2']"
    } >> "${cairo_cross_file}"

    mkdir -p build && cd build
    meson setup --prefix=${PREFIX} \
        --buildtype=release \
        --default-library=static \
        ${cairo_options} \
        --cross-file="${cairo_cross_file}" .. | log -a

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "cairo configure failed"
        return 1
    fi

    ninja -j$(nproc) 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "cairo build failed"
        return 1
    fi
    
    ninja install 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "cairo install failed"
        return 1
    fi

    # Fix pkg-config files - cairo-ft needs fontconfig which needs libxml2
    local cairo_private="-lstdc++ -lm -lpixman-1 -lpng16 -lz -lxml2"
    cairo_private="${cairo_private} -framework CoreGraphics -framework CoreFoundation -framework ApplicationServices"
    
    # Update all cairo pc files
    for pc in cairo cairo-fc cairo-ft cairo-png cairo-pdf cairo-ps cairo-svg cairo-script cairo-gobject cairo-quartz; do
        if [[ -f ${PREFIX}/lib/pkgconfig/${pc}.pc ]]; then
            # Remove any existing Libs.private line and add correct one
            sed -i '/^Libs\.private:/d' ${PREFIX}/lib/pkgconfig/${pc}.pc
            echo "Libs.private: ${cairo_private}" >> ${PREFIX}/lib/pkgconfig/${pc}.pc
        fi
    done
    
    # For static linking, cairo-ft.pc needs the actual libs on the Libs: line for link tests to work
    # Meson link tests don't use Libs.private
    if [[ -f ${PREFIX}/lib/pkgconfig/cairo-ft.pc ]]; then
        # Add fontconfig, freetype, and their deps directly to Libs line
        sed -i "s|^Libs: \(.*\)|Libs: \1 -L${PREFIX}/lib -lfontconfig -lfreetype -lxml2 -lexpat|" ${PREFIX}/lib/pkgconfig/cairo-ft.pc
    fi

    rm -rf /build/cairo "${cairo_cross_file}"
    log "cairo built successfully"
    return 0
}

#---------------------------------------------------------------------------------------------------------#
# Build pango
#---------------------------------------------------------------------------------------------------------#
build_pango() {
    clear_log
    log "Building pango ${PANGO_VERSION}..."
    
    cd /build
    if [[ ! -d pango ]]; then
        git clone --branch ${PANGO_VERSION} --depth 1 https://gitlab.gnome.org/GNOME/pango.git pango >/dev/null 2>&1
    fi
    cd pango

    # Create pango-specific cross file with additional link args for static deps
    local pango_cross_file="/build/pango_cross_file.txt"
    cp /build/cross_file.txt "${pango_cross_file}"
    
    # Add all required static library dependencies for link tests to pass
    {
        echo ""
        echo "[built-in options]"
        echo "c_args = ['-I${PREFIX}/include', '-I${PREFIX}/include/cairo', '-I${PREFIX}/include/freetype2', '-I${PREFIX}/include/fontconfig', '-I${PREFIX}/include/libxml2']"
        echo "c_link_args = ['-L${PREFIX}/lib', '-lfontconfig', '-lfreetype', '-lxml2', '-lexpat', '-lpng16', '-lz', '-lbz2', '-lharfbuzz']"
    } >> "${pango_cross_file}"

    mkdir -p build && cd build
    meson setup --prefix=${PREFIX} \
        --buildtype=release \
        --default-library=static \
        -Dintrospection=disabled \
        -Dgtk_doc=false \
        -Dfontconfig=enabled \
        -Dfreetype=enabled \
        -Dcairo=enabled \
        -Dlibthai=disabled \
        -Dsysprof=disabled \
        --cross-file="${pango_cross_file}" .. | log -a

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "pango configure failed"
        return 1
    fi

    ninja -j$(nproc) 2>&1 | log -a && ninja install 2>&1 | log -a
    if [ $? -ne 0 ]; then
        log "pango build failed"
        return 1
    fi

    for pc in pango pangocairo pangoft2; do
        if [[ -f ${PREFIX}/lib/pkgconfig/${pc}.pc ]]; then
            echo "Libs.private: -lstdc++ -lm" >> ${PREFIX}/lib/pkgconfig/${pc}.pc
        fi
    done

    rm -rf /build/pango "${pango_cross_file}"
    log "pango built successfully"
    return 0
}

#---------------------------------------------------------------------------------------------------------#
# Build gdk-pixbuf
#---------------------------------------------------------------------------------------------------------#
build_gdk_pixbuf() {
    clear_log
    log "Building gdk-pixbuf ${GDK_PIXBUF_VERSION}..."
    
    cd /build
    if [[ ! -d gdk-pixbuf ]]; then
        git clone --branch ${GDK_PIXBUF_VERSION} --depth 1 https://gitlab.gnome.org/GNOME/gdk-pixbuf.git gdk-pixbuf >/dev/null 2>&1
    fi
    cd gdk-pixbuf

    # Create gdk-pixbuf specific cross file
    local gdkpixbuf_cross_file="/build/gdkpixbuf_cross_file.txt"
    cp /build/cross_file.txt "${gdkpixbuf_cross_file}"
    
    # Add include paths but be careful with link args - they can break meson's function detection
    {
        echo ""
        echo "[built-in options]"
        echo "c_args = ['-I${PREFIX}/include', '-I${PREFIX}/include/glib-2.0', '-I${PREFIX}/lib/glib-2.0/include']"
    } >> "${gdkpixbuf_cross_file}"

    mkdir -p build && cd build
    meson setup --prefix=${PREFIX} \
        --buildtype=release \
        --default-library=static \
        -Dbuiltin_loaders=all \
        -Dgtk_doc=false \
        -Dintrospection=disabled \
        -Dman=false \
        -Dinstalled_tests=false \
        -Dtests=false \
        -Dpng=enabled \
        -Djpeg=disabled \
        -Dtiff=disabled \
        --cross-file="${gdkpixbuf_cross_file}" .. | log -a

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "gdk-pixbuf configure failed"
        return 1
    fi

    # Build only the static library target - utilities may fail due to static linking issues
    # but we only need the library for librsvg
    ninja -j$(nproc) gdk-pixbuf/libgdk_pixbuf-2.0.a 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "gdk-pixbuf library build failed"
        return 1
    fi
    
    # Try full install, but if it fails due to utilities, do manual install
    ninja install 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "Full install failed, doing manual library install..."
        # Manual install of just what we need
        cp gdk-pixbuf/libgdk_pixbuf-2.0.a ${PREFIX}/lib/
        mkdir -p ${PREFIX}/include/gdk-pixbuf-2.0/gdk-pixbuf
        cp ../gdk-pixbuf/*.h ${PREFIX}/include/gdk-pixbuf-2.0/gdk-pixbuf/
        cp gdk-pixbuf/*.h ${PREFIX}/include/gdk-pixbuf-2.0/gdk-pixbuf/
        
        # Create pkg-config file
        {
            echo "prefix=${PREFIX}"
            echo "exec_prefix=\${prefix}"
            echo "libdir=\${exec_prefix}/lib"
            echo "includedir=\${prefix}/include"
            echo ""
            echo "Name: GdkPixbuf"
            echo "Description: Image loading and scaling"
            echo "Version: ${GDK_PIXBUF_VERSION}"
            echo "Requires: glib-2.0 >= 2.56.0, gobject-2.0 >= 2.56.0, gio-2.0 >= 2.56.0"
            echo "Libs: -L\${libdir} -lgdk_pixbuf-2.0"
            echo "Libs.private: -lm -lpng16 -lz"
            echo "Cflags: -I\${includedir}/gdk-pixbuf-2.0"
        } > ${PREFIX}/lib/pkgconfig/gdk-pixbuf-2.0.pc
    fi

    if [[ -f ${PREFIX}/lib/pkgconfig/gdk-pixbuf-2.0.pc ]]; then
        # Ensure private libs are set
        if ! grep -q "Libs.private:" ${PREFIX}/lib/pkgconfig/gdk-pixbuf-2.0.pc; then
            echo "Libs.private: -lc++ -lm -lpng16 -lz" >> ${PREFIX}/lib/pkgconfig/gdk-pixbuf-2.0.pc
        fi
    fi

    rm -rf /build/gdk-pixbuf "${gdkpixbuf_cross_file}"
    log "gdk-pixbuf built successfully"
    return 0
}

#---------------------------------------------------------------------------------------------------------#
# Build librsvg
#---------------------------------------------------------------------------------------------------------#
build_librsvg() {
    clear_log
    log "Building librsvg ${LIBRSVG_VERSION}..."
    
    cd /build
    if [[ ! -d librsvg ]]; then
        git clone --branch ${LIBRSVG_VERSION} --depth 1 https://gitlab.gnome.org/GNOME/librsvg.git librsvg >/dev/null 2>&1
    fi
    cd librsvg

    # Set Rust target based on platform
    local RUST_TARGET=""
    local CARGO_TARGET_DIR=""
    
    if [[ "${ARCH}" == "arm64" && "${TARGET_OS}" == "darwin" ]]; then
        RUST_TARGET="aarch64-apple-darwin"
    elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "darwin" ]]; then
        RUST_TARGET="x86_64-apple-darwin"
    fi

    # Ensure the Rust target is installed
    rustup target add ${RUST_TARGET} >/dev/null 2>&1

    # Set up Cargo configuration for cross-compilation
    mkdir -p .cargo

    # For Darwin, we need to avoid duplicate Rust runtime symbols with librav1e
    # Use panic=abort to avoid the duplicate rust_eh_personality symbol
    local DARWIN_RUSTFLAGS=""
    DARWIN_RUSTFLAGS="[\"-C\", \"panic=abort\", \"-C\", \"lto=thin\"]"
    {
        echo "[target.${RUST_TARGET}]"
        echo "linker = \"${CC}\""
        echo "ar = \"${AR}\""
        echo "rustflags = ${DARWIN_RUSTFLAGS}"
        echo ""
        echo "[build]"
        echo "target = \"${RUST_TARGET}\""
        echo ""
        echo "[profile.release]"
        echo "lto = true"
        echo "codegen-units = 1"
        echo "opt-level = 3"
        echo "panic = \"abort\""
    } > .cargo/config.toml

    # Export necessary environment variables for Rust cross-compilation
    export CARGO_TARGET_DIR="/build/librsvg/target"
    export PKG_CONFIG_ALLOW_CROSS=1
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"

    # Set linker environment variable for the specific target
    local TARGET_UPPER=$(echo "${RUST_TARGET}" | tr '[:lower:]-' '[:upper:]_')
    export "CARGO_TARGET_${TARGET_UPPER}_LINKER"="${CC}"

    # For Darwin, set RUSTFLAGS to use panic=abort to avoid duplicate rust_eh_personality
    export RUSTFLAGS="-C panic=abort -C lto=thin -C opt-level=3"
    # Configure with meson
    mkdir -p build && cd build
    
    local rsvg_options="-Dintrospection=disabled \
        -Dpixbuf=enabled \
        -Dpixbuf-loader=disabled \
        -Ddocs=disabled \
        -Dvala=disabled \
        -Dtests=false \
        -Dtriplet=${RUST_TARGET}"

    meson setup --prefix=${PREFIX} \
        --buildtype=release \
        --default-library=static \
        ${rsvg_options} \
        --cross-file="/build/cross_file.txt" .. | log -a

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "librsvg configure failed"
        return 1
    fi

    # Build only the library target - rsvg-convert may fail due to -lstdc++ issue on macOS
    # We only need the library for FFmpeg
    ninja rsvg/librsvg-2.a 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "librsvg library build failed"
        return 1
    fi
    
    # Try full install, but if it fails do manual install of the library
    ninja install 2>&1 | log -a
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log "Full install failed, doing manual library install..."
        
        # Find and copy the static library
        local rsvg_lib=$(find /build/librsvg/build -name "librsvg*.a" -type f 2>/dev/null | head -1)
        if [[ -n "${rsvg_lib}" ]]; then
            cp "${rsvg_lib}" ${PREFIX}/lib/librsvg-2.a
            log "Copied library: ${rsvg_lib}"
        fi
    fi
    
    # Always ensure headers are installed - search multiple possible locations
    if [[ ! -f ${PREFIX}/include/librsvg-2.0/librsvg/rsvg.h ]]; then
        log "Headers missing, searching for them..."
        mkdir -p ${PREFIX}/include/librsvg-2.0/librsvg
        
        # Log what we find
        log "Searching for rsvg.h in source tree..."
        find /build/librsvg -name "rsvg.h" -type f 2>/dev/null | log -a
        
        # Try multiple possible source locations for librsvg 2.61
        local header_dirs=(
            "/build/librsvg/include"
            "/build/librsvg/include/librsvg"
            "/build/librsvg/librsvg"
            "/build/librsvg/rsvg"
            "/build/librsvg/build/include"
            "/build/librsvg/build/include/librsvg"
            "/build/librsvg/build/librsvg"
            "/build/librsvg/build/rsvg"
        )
        
        for dir in "${header_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                log "Checking $dir for headers..."
                cp "$dir"/*.h ${PREFIX}/include/librsvg-2.0/librsvg/ 2>/dev/null && \
                    log "Copied headers from $dir"
            fi
        done
        
        # If still no rsvg.h, do a broad search and copy
        if [[ ! -f ${PREFIX}/include/librsvg-2.0/librsvg/rsvg.h ]]; then
            log "Still no rsvg.h, doing broad search..."
            local found_rsvg=$(find /build/librsvg -name "rsvg.h" -type f 2>/dev/null | head -1)
            if [[ -n "${found_rsvg}" ]]; then
                local header_dir=$(dirname "${found_rsvg}")
                log "Found rsvg.h in: ${header_dir}"
                cp "${header_dir}"/*.h ${PREFIX}/include/librsvg-2.0/librsvg/ 2>/dev/null
            fi
        fi
        
        # Also look for generated headers (rsvg-version.h, librsvg-features.h, etc.)
        find /build/librsvg/build -name "*.h" -type f 2>/dev/null | while read hfile; do
            local hname=$(basename "$hfile")
            if [[ "$hname" == *rsvg* ]] || [[ "$hname" == *librsvg* ]]; then
                cp "$hfile" ${PREFIX}/include/librsvg-2.0/librsvg/ 2>/dev/null
                log "Copied generated header: $hfile"
            fi
        done
    fi
    
    # Create pkg-config file if not present
    if [[ ! -f ${PREFIX}/lib/pkgconfig/librsvg-2.0.pc ]]; then
        {
            echo "prefix=${PREFIX}"
            echo "exec_prefix=\${prefix}"
            echo "libdir=\${exec_prefix}/lib"
            echo "includedir=\${prefix}/include"
            echo ""
            echo "Name: librsvg"
            echo "Description: SVG rendering library"
            echo "Version: ${LIBRSVG_VERSION}"
            echo "Requires: glib-2.0 >= 2.50.0, gio-2.0, gdk-pixbuf-2.0, cairo, pangocairo, libxml-2.0"
            echo "Libs: -L\${libdir} -lrsvg-2"
            echo "Cflags: -I\${includedir} -I\${includedir}/librsvg-2.0"
        } > ${PREFIX}/lib/pkgconfig/librsvg-2.0.pc
    fi
    
    # Verify installation
    log "Verifying librsvg installation..."
    ls -la ${PREFIX}/include/librsvg-2.0/librsvg/ >> /ffmpeg_build.log 2>&1
    ls -la ${PREFIX}/lib/librsvg*.a >> /ffmpeg_build.log 2>&1

    # Handle Rust symbol conflicts with librav1e
    if [[ -f ${PREFIX}/lib/librsvg-2.a ]]; then        
        # Verify the library has the expected API symbols
        log "Verifying librsvg API symbols..."
        local NM_TOOL="${NM:-${CROSS_PREFIX}nm}"
        if ${NM_TOOL} ${PREFIX}/lib/librsvg-2.a 2>/dev/null | grep -q "rsvg_handle_new_from_data"; then
            log "librsvg API symbols verified OK"
        else
            log "WARNING: rsvg_handle_new_from_data not found in library!"
            log "Library contents:"
            ${NM_TOOL} ${PREFIX}/lib/librsvg-2.a 2>/dev/null | grep -i rsvg | head -20 >> /ffmpeg_build.log
        fi
    fi

    # Update pkgconfig file
    local rsvg_pc="${PREFIX}/lib/pkgconfig/librsvg-2.0.pc"
    if [[ -f "${rsvg_pc}" ]]; then
        # Ensure Cflags has both paths:
        # -I${includedir} for FFmpeg's <librsvg-2.0/librsvg/rsvg.h>
        # -I${includedir}/librsvg-2.0 for internal includes like <librsvg/rsvg-features.h>
        
        # First normalize to just -I${includedir}/librsvg-2.0 if that's what's there
        # Then add both paths
        if ! grep -q "\-I\${includedir} " "${rsvg_pc}" && ! grep -q "\-I${PREFIX}/include " "${rsvg_pc}"; then
            # Need to add the base includedir path
            sed -i.bak "s|Cflags:.*|Cflags: -I\${includedir} -I\${includedir}/librsvg-2.0|" "${rsvg_pc}"
            rm -f "${rsvg_pc}.bak"
        fi
        
        local rsvg_private="-lc++ -lm"
        rsvg_private="${rsvg_private} -framework Security -framework CoreFoundation"
        
        # Check if Libs.private already exists
        if ! grep -q "Libs.private:" "${rsvg_pc}"; then
            echo "Libs.private: ${rsvg_private}" >> "${rsvg_pc}"
        fi
    fi

    rm -rf /build/librsvg
    log "librsvg built successfully"
    return 0
}

#---------------------------------------------------------------------------------------------------------#
# Main build sequence
#---------------------------------------------------------------------------------------------------------#

# Build dependencies in order
clear_log
log "Starting librsvg dependency chain build..."

# 1. libffi (for glib)
build_libffi || {
    log "Failed to build libffi"
    exit 1
}

# 2. pcre2 (for glib)
build_pcre2 || {
    log "Failed to build pcre2"
    exit 1
}

# 3. glib2 (core dependency)
build_glib2 || {
    log "Failed to build glib2"
    exit 1
}

# 4. pixman (for cairo)
build_pixman || {
    log "Failed to build pixman"
    exit 1
}

# 5. cairo
build_cairo || {
    log "Failed to build cairo"
    exit 1
}

# 6. pango
build_pango || {
    log "Failed to build pango"
    exit 1
}

# 7. gdk-pixbuf
build_gdk_pixbuf || {
    log "Failed to build gdk-pixbuf"
    exit 1
}

# 8. librsvg
build_librsvg || {
    log "Failed to build librsvg"
    exit 1
}

# Restore original flags
CFLAGS="${ORIG_CFLAGS}"
CXXFLAGS="${ORIG_CXXFLAGS}"
LDFLAGS="${ORIG_LDFLAGS}"

# Add librsvg to FFmpeg enables
add_enable "--enable-librsvg"

# Add extra library flags for linking
add_extralib "-Wl,-dead_strip -Wl,-multiply_defined,suppress -lrsvg-2 -lcairo -lpango-1.0 -lpangocairo-1.0 -lgdk_pixbuf-2.0 -lgio-2.0 -lgobject-2.0 -lglib-2.0 -lpixman-1 -lffi -lpcre2-8 -framework Security -framework CoreFoundation -framework CoreGraphics"

log "librsvg build chain completed successfully"

exit 0
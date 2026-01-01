#!/bin/bash

if [[ ${TARGET_OS} == "darwin" || ${ARCH} == "arm64" || ${ARCH} == "aarch64" ]]; then
	exit 255;
fi

#region Set library versions
LIBPCRE2_VERSION="10.44"
LIBGLIB_VERSION="2.86.2"
LIBPIXMAN_VERSION="0.46.4"
LIBCAIRO_VERSION="1.18.4"
LIBPANGO_VERSION="1.57.0"
LIBGDKPIXBUF_VERSION="2.44.4"
LIBRSVG_VERSION="2.61.3"
#endregion

if [ ${TARGET_OS} == "windows" ]; then
	#region pcre2 (required by glib for regex support)
	cd /build

	# Download pcre2 source code
	if [ ! -d "/build/pcre2" ]; then
		echo "Downloading pcre2..."
		git clone --branch pcre2-${LIBPCRE2_VERSION} https://github.com/PCRE2Project/pcre2.git pcre2 >/dev/null 2>&1
	fi

	cd /build/pcre2

	# Configure and build pcre2
	./autogen.sh --prefix=${PREFIX} \
		--enable-static \
		--disable-shared \
		--host=${CROSS_PREFIX%-} \
		--enable-pcre2-16 \
		--enable-pcre2-32 \
		--disable-pcre2grep-libz \
		--disable-pcre2grep-libbz2 \
		--disable-pcre2test-libreadline >/dev/null 2>&1

	./configure --prefix=${PREFIX} \
		--enable-static \
		--disable-shared \
		--host=${CROSS_PREFIX%-} \
		--enable-pcre2-16 \
		--enable-pcre2-32 \
		--disable-pcre2grep-libz \
		--disable-pcre2grep-libbz2 \
		--disable-pcre2test-libreadline | log

	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		log "pcre2 configure failed"
		exit 1
	fi

	make -j$(nproc) 2>&1 | log -a
	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		log "pcre2 build failed"
		exit 1
	fi

	make install >/dev/null 2>&1

	if [ ! -f "${PREFIX}/lib/pkgconfig/libpcre2-8.pc" ]; then
		log "pcre2 install failed"
		exit 1
	fi

	rm -rf /build/pcre2
	#endregion

	#region gettext (required by glib for localization)
	cd /build
	wget https://ftp.gnu.org/pub/gnu/gettext/gettext-0.26.tar.gz
	tar -xzf gettext-0.26.tar.gz && rm gettext-0.26.tar.gz && mv gettext-0.26 gettext
	cd gettext

	./autogen.sh --prefix=${PREFIX} \
	--enable-static \
	--disable-shared \
	--with-libiconv-prefix=${PREFIX} \
	--host=${CROSS_PREFIX%-}
	
	./configure --prefix=${PREFIX} \
	--enable-static \
	--disable-shared \
	--with-libiconv-prefix=${PREFIX} \
	--host=${CROSS_PREFIX%-} | log
	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		log "gettext configure failed"
		exit 1
	fi

	make -j$(nproc) 2>&1 | log -a
	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		log "gettext build failed"
		exit 1
	fi
	
	make install 2>&1 | log -a
	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		log "gettext install failed"
		exit 1
	fi

	rm -rf /build/gettext
	#endregion
fi

#region pixman (required by cairo)
cd /build

# Download pixman source code
if [ ! -d "/build/pixman" ]; then
	echo "Downloading pixman..."
	git clone --branch pixman-${LIBPIXMAN_VERSION} https://gitlab.freedesktop.org/pixman/pixman.git pixman >/dev/null 2>&1
fi

cd /build/pixman

# Configure with meson
meson setup build --prefix=${PREFIX} \
	--buildtype=release \
	--default-library=static \
	--cross-file="/build/cross_file.txt" \
	-Dtests=disabled \
	-Ddemos=disabled \
	-Dgtk=disabled | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log "pixman configure failed"
	exit 1
fi

ninja -j$(nproc) -C build 2>&1 | log -a

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log "pixman build failed"
	exit 1
fi

ninja -C build install >/dev/null 2>&1

if [ ! -f "${PREFIX}/lib/pkgconfig/pixman-1.pc" ]; then
	log "pixman install failed"
	exit 1
fi

sed -i 's/-lgcc_s//g' ${PREFIX}/lib/pkgconfig/pixman-1.pc
sed -i 's/-lgcc//g' ${PREFIX}/lib/pkgconfig/pixman-1.pc

rm -rf /build/pixman
#endregion

#region glib (required by most GTK/GNOME libraries)
cd /build

# Download glib
if [ ! -d "/build/glib" ]; then
	echo "Downloading glib..."
	git clone --branch ${LIBGLIB_VERSION} https://gitlab.gnome.org/GNOME/glib.git glib >/dev/null 2>&1
fi

cd /build/glib

rm -rf build
# Configure with meson
cp /build/cross_file.txt /build/glib/cross_file.txt

if [[ ${TARGET_OS} == "windows" ]]; then
	{
		echo ""
		echo "[properties]"
		echo "c_args = ['-I${PREFIX}/include']"
		echo "cpp_args = ['-I${PREFIX}/include']"
		echo ""
		echo "[built-in options]"
		echo "c_args = ['-I${PREFIX}/include']"
		echo "cpp_args = ['-I${PREFIX}/include']"
		echo "c_link_args = ['-L${PREFIX}/lib', '-lpthread', '-lbcrypt', '-lws2_32', '-lintl', '-liconv']"
		echo "cpp_link_args = ['-L${PREFIX}/lib', '-lpthread', '-lbcrypt', '-lws2_32', '-lintl', '-liconv']"
	} >>/build/glib/cross_file.txt
	
	sed -i "2345s/^/# /" ./meson.build

	if [ ! -d "./subprojects" ]; then
		mkdir ./subprojects
	fi
	if [ ! -f "./subprojects/proxy-libintl.wrap" ]; then
		touch ./subprojects/proxy-libintl.wrap
		{
			echo "[wrap-git]"
			echo "url = https://github.com/frida/proxy-libintl.git"
			echo "revision = head"
			echo "depth = 1"
		}>./subprojects/proxy-libintl.wrap
	fi
fi

# Set PKG_CONFIG_PATH to ensure libintl is found
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"

meson setup build --prefix=${PREFIX} \
	--buildtype=release \
	--default-library=static \
	-Dtests=false \
	-Dintrospection=disabled \
	-Dlibmount=disabled \
	-Dselinux=disabled \
	-Dnls=enabled \
	--wrap-mode=forcefallback \
	--force-fallback-for=proxy-libintl \
	--cross-file="/build/glib/cross_file.txt" | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log "$(cat /build/glib/build/meson-logs/meson-log.txt | tail -50)"
	log "glib configure failed"
	exit 1
fi

ninja -j$(nproc) -C build 2>&1 | log -a

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log "glib build failed"
	exit 1
fi

ninja -C build install >/dev/null 2>&1

if [ ! -f "${PREFIX}/lib/pkgconfig/glib-2.0.pc" ]; then
	log "glib install failed"
	exit 1
fi

for pc in glib-2.0.pc gio-2.0.pc gobject-2.0.pc gmodule-2.0.pc; do
	if [ -f "${PREFIX}/lib/pkgconfig/${pc}" ]; then
		sed -i 's/-lgcc_s//g' ${PREFIX}/lib/pkgconfig/${pc}
		sed -i 's/-lgcc//g' ${PREFIX}/lib/pkgconfig/${pc}
	fi
done

rm -rf /build/glib
#endregion

#region cairo (required by pango and librsvg)
cd /build

if [ ! -d "/build/cairo" ]; then
	echo "Downloading cairo..." > /ffmpeg_build.log
	git clone --branch ${LIBCAIRO_VERSION} https://gitlab.freedesktop.org/cairo/cairo.git cairo >/dev/null 2>&1
fi

cd /build/cairo

CAIRO_EXTRA_FLAGS="-Dxlib=disabled -Dxcb=disabled -Dgtk_doc=false -Dglib=enabled"

cp /build/cross_file.txt /build/cairo/cross_file.txt
{
	echo ""
	echo "[built-in options]"
	if [[ ${TARGET_OS} == "windows" ]]; then
		echo "c_args = ['-DCAIRO_WIN32_STATIC_BUILD=1']"
		echo "cpp_args = ['-DCAIRO_WIN32_STATIC_BUILD=1']"
		echo "c_link_args = ['-L${PREFIX}/lib', '-lglib-2.0', '-lgobject-2.0', '-lfontconfig', '-lfreetype', '-lpixman-1', '-lxml2', '-liconv', '-lbcrypt']"
		echo "cpp_link_args = ['-L${PREFIX}/lib', '-lglib-2.0', '-lgobject-2.0', '-lfontconfig', '-lfreetype', '-lpixman-1', '-lxml2', '-liconv', '-lbcrypt']"
	elif [[ ${TARGET_OS} == "linux" ]]; then
		echo "c_link_args = ['-L${PREFIX}/lib', '-lglib-2.0', '-lgobject-2.0', '-lfontconfig', '-lfreetype', '-lpixman-1', '-lxml2', '-liconv']"
		echo "cpp_link_args = ['-L${PREFIX}/lib', '-lglib-2.0', '-lgobject-2.0', '-lfontconfig', '-lfreetype', '-lpixman-1', '-lxml2', '-liconv']"
	fi
} >>/build/cairo/cross_file.txt

echo "Configuring cairo..." > /ffmpeg_build.log

meson setup build --prefix=${PREFIX} \
	--buildtype=release \
	--default-library=static \
	-Dtests=disabled \
	-Dzlib=enabled \
	-Dpng=enabled \
	-Dfreetype=enabled \
	-Dfontconfig=enabled \
	${CAIRO_EXTRA_FLAGS} \
	--cross-file="/build/cairo/cross_file.txt" | log -a

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log "cairo configure failed"
	exit 1
fi

echo "Compiling cairo..." > /ffmpeg_build.log

ninja -j$(nproc) -C build 2>&1 | log -a

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log "cairo build failed"
	exit 1
fi

echo "Installing cairo..." > /ffmpeg_build.log

ninja -C build install 2>&1 | log -a

if [ ${PIPESTATUS[0]} -ne 0 ] ||  [ ! -f "${PREFIX}/lib/pkgconfig/cairo.pc"]; then
	log "cairo install failed"
	exit 1
fi

sed -i 's/-lgcc_s//g' ${PREFIX}/lib/pkgconfig/cairo.pc
sed -i 's/-lgcc//g' ${PREFIX}/lib/pkgconfig/cairo.pc

rm -rf /build/cairo
#endregion

#region gdk-pixbuf (required by librsvg for image handling)
if [[ ${TARGET_OS} != "darwin" ]]; then
	cd /build

	if [ ! -d "/build/gdk-pixbuf" ]; then
		echo "Downloading gdk-pixbuf..."
		git clone --branch ${LIBGDKPIXBUF_VERSION} https://gitlab.gnome.org/GNOME/gdk-pixbuf.git gdk-pixbuf >/dev/null 2>&1
	fi

	cd /build/gdk-pixbuf

	CROSS_FILE_PATH="/build/cross_file.txt"
	if [[ ${TARGET_OS} == "windows" ]]; then
		cp /build/cross_file.txt /build/gdk-pixbuf/cross_file.txt
		sed -i "/\[binaries\]/a glib-compile-resources = '${PREFIX}/bin/glib-compile-resources'" /build/gdk-pixbuf/cross_file.txt
		CROSS_FILE_PATH="/build/gdk-pixbuf/cross_file.txt"
	fi

	meson setup build --prefix=${PREFIX} \
		--buildtype=release \
		--default-library=static \
		--cross-file="${CROSS_FILE_PATH}" \
		-Dpng=enabled \
		-Djpeg=enabled \
		-Dtiff=enabled \
		-Dintrospection=disabled \
		-Dman=false \
		-Ddocumentation=false \
		-Dgio_sniffing=false \
		-Dglycin=disabled \
		-Dtests=false \
		-Dinstalled_tests=false | log

	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		log "gdk-pixbuf configure failed"
		exit 1
	fi

	ninja -j$(nproc) -C build 2>&1 | log -a

	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		log "gdk-pixbuf build failed"
		exit 1
	fi

	ninja -C build install >/dev/null 2>&1

	if [ ! -f "${PREFIX}/lib/pkgconfig/gdk-pixbuf-2.0.pc" ]; then
		log "gdk-pixbuf install failed"
		exit 1
	fi

	sed -i 's/-lgcc_s//g' ${PREFIX}/lib/pkgconfig/gdk-pixbuf-2.0.pc
	sed -i 's/-lgcc//g' ${PREFIX}/lib/pkgconfig/gdk-pixbuf-2.0.pc

	rm -rf /build/gdk-pixbuf
fi
#endregion

#region pango (required by librsvg for text rendering)
cd /build

if [ ! -d "/build/pango" ]; then
	echo "Downloading pango..."
	git clone --branch ${LIBPANGO_VERSION} https://gitlab.gnome.org/GNOME/pango.git pango >/dev/null 2>&1
fi

cd /build/pango
PANGO_EXTRA_FLAGS=""
cp /build/cross_file.txt /build/pango/cross_file.txt
{
	if [[ ${TARGET_OS} == "windows" ]]; then
		echo ""
		echo "[built-in options]"
		echo "c_args = ['-DCAIRO_WIN32_STATIC_BUILD=1']"
		echo "cpp_args = ['-DCAIRO_WIN32_STATIC_BUILD=1']"
		echo "c_link_args = ['-L${PREFIX}/lib', '-lcairo', '-lpixman-1', '-lfontconfig', '-lfreetype', '-lpng', '-lz', '-lharfbuzz', '-lfribidi', '-lglib-2.0', '-lgobject-2.0', '-lgio-2.0', '-lxml2', '-liconv', '-lbcrypt', '-lws2_32']"
		echo "cpp_link_args = ['-L${PREFIX}/lib', '-lcairo', '-lpixman-1', '-lfontconfig', '-lfreetype', '-lpng', '-lz', '-lharfbuzz', '-lfribidi', '-lglib-2.0', '-lgobject-2.0', '-lgio-2.0', '-lxml2', '-liconv', '-lbcrypt', '-lws2_32']"
	else
		echo ""
		echo "[built-in options]"
		echo "c_link_args = ['-L${PREFIX}/lib', '-lcairo', '-lfontconfig', '-lfreetype', '-lharfbuzz', '-lfribidi', '-lpixman-1', '-lglib-2.0', '-lgobject-2.0', '-lgio-2.0', '-lxml2', '-liconv']"
		echo "cpp_link_args = ['-L${PREFIX}/lib', '-lcairo', '-lfontconfig', '-lfreetype', '-lharfbuzz', '-lfribidi', '-lpixman-1', '-lglib-2.0', '-lgobject-2.0', '-lgio-2.0', '-lxml2', '-liconv']"
	fi
} >>/build/pango/cross_file.txt

meson setup build --prefix=${PREFIX} \
	--buildtype=release \
	--default-library=static \
	--cross-file="/build/pango/cross_file.txt" \
	-Dintrospection=disabled \
	-Ddocumentation=false \
	-Dbuild-testsuite=false \
	-Dbuild-examples=false \
	-Dman-pages=false \
	${PANGO_EXTRA_FLAGS} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log "pango configure failed"
	exit 1
fi

ninja -j$(nproc) -C build 2>&1 | log -a

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log "pango build failed"
	exit 1
fi

ninja -C build install >/dev/null 2>&1

if [ ! -f "${PREFIX}/lib/pkgconfig/pango.pc" ]; then
	log "pango install failed"
	exit 1
fi

for pc in pango.pc pangocairo.pc pangoft2.pc; do
	if [ -f "${PREFIX}/lib/pkgconfig/${pc}" ]; then
		sed -i 's/-lgcc_s//g' ${PREFIX}/lib/pkgconfig/${pc}
		sed -i 's/-lgcc//g' ${PREFIX}/lib/pkgconfig/${pc}
	fi
	if [ "${pc}" == "pango.pc" ] && [ ! -f "${PREFIX}/lib/pkgconfig/${pc}" ]; then
		echo "missing pango.pc">> /ffmpeg_build.log
		exit 1
	fi
	if [ "${pc}" == "pangocairo.pc" ] && [ ! -f "${PREFIX}/lib/pkgconfig/${pc}" ]; then
		echo "missing pangocairo.pc">> /ffmpeg_build.log
		exit 1
	fi
done

rm -rf /build/pango
#endregion

#region librsvg (main library for SVG rendering)
cd /build

if [ ! -d "/build/librsvg" ]; then
	echo "Downloading librsvg..."
	git clone --branch ${LIBRSVG_VERSION} https://gitlab.gnome.org/GNOME/librsvg.git librsvg >/dev/null 2>&1
fi

cd /build/librsvg

# Install Rust target for cross-compilation if needed
if [[ "${ARCH}" == "aarch64" && "${TARGET_OS}" == "linux" ]]; then
	rustup target add aarch64-unknown-linux-gnu >/dev/null 2>&1
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "windows" ]]; then
	rustup target add x86_64-pc-windows-gnu >/dev/null 2>&1
elif [[ "${ARCH}" == "arm64" && "${TARGET_OS}" == "darwin" ]]; then
	rustup target add aarch64-apple-darwin >/dev/null 2>&1
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "darwin" ]]; then
	rustup target add x86_64-apple-darwin >/dev/null 2>&1
fi

# Set up Rust environment for cross-compilation
LIBRSVG_RUST_TARGET="x86_64-unknown-linux-gnu"
if [[ "${ARCH}" == "aarch64" && "${TARGET_OS}" == "linux" ]]; then
	LIBRSVG_RUST_TARGET="aarch64-unknown-linux-gnu"
	export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=${CC}
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "windows" ]]; then
	LIBRSVG_RUST_TARGET="x86_64-pc-windows-gnu"
	export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=${CC}
elif [[ "${ARCH}" == "arm64" && "${TARGET_OS}" == "darwin" ]]; then
	LIBRSVG_RUST_TARGET="aarch64-apple-darwin"
	export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER=${CC}
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "darwin" ]]; then
	LIBRSVG_RUST_TARGET="x86_64-apple-darwin"
	export CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER=${CC}
fi

if [[ ${TARGET_OS} == "darwin" ]]; then
	export CARGO_BUILD_TARGET=${LIBRSVG_RUST_TARGET}
fi

# Update meson cross file with Rust information
cp /build/cross_file.txt /build/librsvg/cross_file.txt

LIBRSVG_EXTRA_FLAGS=""
OLD_LDFLAGS="${LDFLAGS}"
OLD_RUSTFLAGS="${RUSTFLAGS}"

{
	echo ""
	echo "[properties]"
	echo "rust_target = '${LIBRSVG_RUST_TARGET}'"
} >>/build/librsvg/cross_file.txt

meson setup build --prefix=${PREFIX} \
	--buildtype=release \
	--default-library=static \
	--cross-file="/build/librsvg/cross_file.txt" \
	-Dintrospection=disabled \
	-Dtests=false \
	-Dpixbuf=enabled \
	-Ddocs=disabled \
	-Dvala=disabled \
	${LIBRSVG_EXTRA_FLAGS} \
	-Dtests=false | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	LDFLAGS="${OLD_LDFLAGS}"
	RUSTFLAGS="${OLD_RUSTFLAGS}"
	log "librsvg configure failed"
	exit 1
fi

ninja -j$(nproc) -C build 2>&1 | log -a

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	LDFLAGS="${OLD_LDFLAGS}"
	RUSTFLAGS="${OLD_RUSTFLAGS}"
	log "librsvg build failed"
	exit 1
fi

ninja -C build install >/dev/null 2>&1

if [ ! -f "${PREFIX}/lib/pkgconfig/librsvg-2.0.pc" ]; then
	LDFLAGS="${OLD_LDFLAGS}"
	RUSTFLAGS="${OLD_RUSTFLAGS}"
	log "librsvg install failed"
	exit 1
fi

LDFLAGS="${OLD_LDFLAGS}"
RUSTFLAGS="${OLD_RUSTFLAGS}"

sed -i 's/-lgcc_s//g' ${PREFIX}/lib/pkgconfig/librsvg-2.0.pc
sed -i 's/-lgcc//g' ${PREFIX}/lib/pkgconfig/librsvg-2.0.pc

if [[ ${TARGET_OS} == "windows" ]]; then
	if ! grep -q "Libs.private:" ${PREFIX}/lib/pkgconfig/librsvg-2.0.pc; then
		echo "Libs.private: -lstdc++ -lws2_32 -lbcrypt -luserenv -lkernel32" >>${PREFIX}/lib/pkgconfig/librsvg-2.0.pc
	fi
else
	if ! grep -q "Libs.private:" ${PREFIX}/lib/pkgconfig/librsvg-2.0.pc; then
		echo "Libs.private: -lstdc++ -lm" >>${PREFIX}/lib/pkgconfig/librsvg-2.0.pc
	fi
fi

rm -rf /build/librsvg
#endregion

#region Add librsvg to FFmpeg configuration
add_enable "--enable-librsvg"
add_ldflag "-Wl,--allow-multiple-definition"
#endregion

log "librsvg build completed successfully"

exit 0

#!/bin/bash

ZVBI_VERSION="0.2.44"

cd /build

rm -rf zvbi
rm -f /ffmpeg_build.log
rm -r ${PREFIX}/lib/pkgconfig/zvbi-0.2.pc

touch /ffmpeg_build.log

git clone --depth 1 --branch v${ZVBI_VERSION} https://github.com/zapping-vbi/zvbi.git zvbi
cd zvbi

EXTRA_FLAGS=""
if [ "${TARGET_OS}" == "darwin" ]; then
	EXTRA_FLAGS="ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes"
fi

./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared \
	--disable-bktr \
	--disable-docs \
	--disable-dvb \
	--disable-examples \
	--disable-nls \
	--disable-proxy \
	--disable-tests \
	--with-pic \
	--without-doxygen \
	--without-x \
	${EXTRA_FLAGS} \
	--host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared \
	--disable-bktr \
	--disable-docs \
	--disable-dvb \
	--disable-examples \
	--disable-nls \
	--disable-proxy \
	--disable-tests \
	--with-pic \
	--without-doxygen \
	--without-x \
	${EXTRA_FLAGS} \
	--host=${CROSS_PREFIX%-} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log "libzvbi configure failed"
	exit 1
fi

if [ ${TARGET_OS} == "darwin" ]; then
	make -C src -j$(nproc) 2>&1 | log

	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		log "libzvbi build failed"
		exit 1
	fi

	make -C src install 2>&1 | log
else
	make -j$(nproc) 2>&1 | log

	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		log "libzvbi build failed"
		exit 1
	fi

	make install 2>&1 | log
fi

if [ ! -f "${PREFIX}/lib/pkgconfig/zvbi-0.2.pc" ]; then
	ZVBI_LIBS="-lzvbi -lm -lpthread -lm"
	if [ -f "${PREFIX}/lib/libiconv.a" ]; then
		ZVBI_LIBS+=" ${PREFIX}/lib/libiconv.a"
	fi
	ZVBI_LIBS+=" -lm -lpng -lz"

	ZVBI_LIBS_PRIVATE="-lstdc++"

	{
		echo "prefix=${PREFIX}"
		echo "exec_prefix=\${prefix}"
		echo "libdir=\${exec_prefix}/lib"
		echo "includedir=\${prefix}/include"
		echo ""
		echo "Name: ZVBI "
		echo "Description: VBI Capturing and Decoding Library"
		echo "Requires: "
		echo "Version: ${ZVBI_VERSION}"
		echo "Libs: -L\${libdir} ${ZVBI_LIBS}"
		echo "Cflags: -I\${includedir}"
	} >${PREFIX}/lib/pkgconfig/zvbi-0.2.pc
fi

rm -rf /build/zvbi

add_enable "--enable-libzvbi"

exit 0

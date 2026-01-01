#!/bin/bash

EXTRA_FONTCONFIG_FLAGS="--enable-iconv"

if [[ ${TARGET_OS} == "darwin" ]]; then
	EXTRA_FONTCONFIG_FLAGS="--disable-iconv"
fi

cd /build/fontconfig
./autogen.sh --prefix=${PREFIX} --disable-docs --enable-libxml2 --enable-static --disable-shared \
	--host=${CROSS_PREFIX%-} ${EXTRA_FONTCONFIG_FLAGS}
./configure --prefix=${PREFIX} --disable-docs --enable-libxml2 --enable-static --disable-shared \
	--host=${CROSS_PREFIX%-} ${EXTRA_FONTCONFIG_FLAGS} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	exit 1
fi

make -j$(nproc) && make install

# Fix fontconfig.pc to include libxml2 in Libs.private for static linking
if [ -f "${PREFIX}/lib/pkgconfig/fontconfig.pc" ]; then
	# Check if Libs.private line exists
	if grep -q "^Libs.private:" ${PREFIX}/lib/pkgconfig/fontconfig.pc; then
		if ! grep -q "Libs.private:.*-lxml2" ${PREFIX}/lib/pkgconfig/fontconfig.pc; then
			sed -i 's/Libs.private:/Libs.private: -lxml2/' ${PREFIX}/lib/pkgconfig/fontconfig.pc
		fi
	else
		# Add Libs.private line with -lxml2
		echo "Libs.private: -lxml2" >>${PREFIX}/lib/pkgconfig/fontconfig.pc
	fi
fi

rm -rf /build/fontconfig

add_enable "--enable-fontconfig"

exit 0

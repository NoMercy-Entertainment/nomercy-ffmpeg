#!/bin/bash

cd /build/fontconfig

EXTRA_FONTCONFIG_FLAGS="--enable-iconv"

if [[ ${TARGET_OS} == "darwin" ]]; then
	EXTRA_FONTCONFIG_FLAGS="--disable-iconv"
	export ac_cv_va_copy="C99"
elif [[ ${TARGET_OS} == "linux" && ${ARCH} == "aarch64" ]]; then
	export ac_cv_va_copy="C99"
elif [[ ${TARGET_OS} == "windows" ]]; then
	export ac_cv_va_copy="C99"
	python3 - <<'PYEOF'
p = "src/fccompat.c"
s = open(p, encoding="utf-8").read()
old = """#ifndef _WIN32
FcLocale
FcLocaleSetCurrent (FcLocale loc)
{
    return uselocale (loc);
}
#endif"""
new = """FcLocale
FcLocaleSetCurrent (FcLocale loc)
{
#ifdef _WIN32
    /* MSVCRT has no uselocale(); fontconfig only needs a neutral "C" numeric
       locale around vsnprintf and a fresh thread already uses "C", so return
       the handle unchanged for the symmetric restore call. */
    return loc;
#else
    return uselocale (loc);
#endif
}"""
assert old in s, "fccompat.c: FcLocaleSetCurrent block not found"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))

p = "src/fcint.h"
s = open(p, encoding="utf-8").read()
old = """#ifndef _WIN32
FcPrivate FcLocale
FcLocaleSetCurrent (FcLocale loc);
#endif"""
new = """FcPrivate FcLocale
FcLocaleSetCurrent (FcLocale loc);"""
assert old in s, "fcint.h: FcLocaleSetCurrent declaration not found"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PYEOF
	if [ $? -ne 0 ]; then
		log "fontconfig FcLocaleSetCurrent patch failed"
		exit 1
	fi
fi

./autogen.sh --prefix=${PREFIX} --disable-docs --enable-libxml2 --enable-static --disable-shared \
	--host=${CROSS_PREFIX%-} ${EXTRA_FONTCONFIG_FLAGS}
./configure --prefix=${PREFIX} --disable-docs --enable-libxml2 --enable-static --disable-shared \
	--host=${CROSS_PREFIX%-} ${EXTRA_FONTCONFIG_FLAGS} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	exit 1
fi

make -j$(nproc) 2>&1 | log -a || { log "fontconfig build failed"; exit 1; }
make install 2>&1 | log -a

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
else
	log "fontconfig install failed — no .pc"
	exit 1
	# {
    #     echo "prefix=${PREFIX}"
    #     echo "exec_prefix=\${prefix}"
    #     echo "libdir=\${exec_prefix}/lib"
    #     echo "includedir=\${prefix}/include"
	# 	echo "sysconfdir=\${exec_prefix}/etc"
	# 	echo "localstatedir=\${exec_prefix}/var"
	# 	echo "PACKAGE=fontconfig"
	# 	echo "confdir=\${sysconfdir}/fonts"
	# 	echo "cachedir=\${localstatedir}/cache/fontconfig"
	# 	echo ""
	# 	echo "Name: Fontconfig"
	# 	echo "Description: Font configuration and customization library"
	# 	echo "Version: ${fontconfig_version}"
	# 	echo "Requires: freetype2 >= 21.0.15"
	# 	echo "Requires.private: "
	# 	echo "Libs: -L\${libdir} -lfontconfig"
	# 	echo "Libs.private: -liconv -lxml2 -lexpat"
	# 	echo "Cflags: -I\${includedir}"
	# } > ${PREFIX}/lib/pkgconfig/fontconfig.pc
fi

rm -rf /build/fontconfig

add_enable "--enable-fontconfig"

log "✅ fontconfig build and installation completed successfully"

exit 0

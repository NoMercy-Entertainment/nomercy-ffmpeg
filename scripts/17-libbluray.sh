#!/bin/bash

#region libgpg-error
cd /build/libgpg-error
if [[ ${TARGET_OS} == "darwin" ]]; then
    if [[ ${ARCH} == "arm64" ]]; then
        cp src/syscfg/lock-obj-pub.${ARCH%64}-apple-darwin.h src/syscfg/lock-obj-pub.darwin24.1.h
    else
        cp src/syscfg/lock-obj-pub.${ARCH}-apple-darwin.h src/syscfg/lock-obj-pub.${CROSS_PREFIX%-}.h
    fi
fi

./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic --disable-doc \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic --disable-doc \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "libgpg-error configure failed"
    exit 1
fi

make -j$(nproc) &>make.log || {
    log "$(cat make.log)"
    log "Error: libgpg-error make failed."
    exit 1
}
make install &>install.log || {
    log "$(cat install.log)"
    log "Error: libgpg-error install failed."
    exit 1
}

if [ ! -f "${PREFIX}/lib/pkgconfig/libgpg-error.pc" ]; then
    {
        echo "prefix=${PREFIX}"
        echo "exec_prefix=\${prefix}"
        echo "libdir=\${exec_prefix}/lib"
        echo "includedir=\${prefix}/include"
        echo ""
        echo "Name: libgpg-error"
        echo "Description: GnuPG error reporting library"
        echo "Version: ${libgpg_error_version}"
        echo "Libs: -L\${libdir} -lgpg-error"
        echo "Cflags: -I\${includedir}"
    } >${PREFIX}/lib/pkgconfig/libgpg-error.pc
else
    sed -i "s/prefix=.*/prefix=${PREFIX}/" ${PREFIX}/lib/pkgconfig/libgpg-error.pc
fi

if [[ ${TARGET_OS} == "windows" ]]; then
    sed -i 's/^Libs: \(.*\)[\r|\n]/Libs: \1 -lws2_32/' ${PREFIX}/lib/pkgconfig/libgpg-error.pc
fi
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libgpg-error.pc

echo '#!/bin/sh' >/usr/local/bin/gpg-error-config
echo 'pkg-config libgpg-error "$@"' >>/usr/local/bin/gpg-error-config
chmod +x /usr/local/bin/gpg-error-config
#endregion

#region libgcrypt
EXTRA_FLAGS=""
cd /build/libgcrypt
if [[ ${TARGET_OS} == "darwin" ]]; then
    EXTRA_FLAGS="--disable-asm --disable-test"
fi
./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic --disable-doc ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic --disable-doc ${EXTRA_FLAGS} \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "libgcrypt configure failed"
    exit 1
fi

make -j$(nproc) &>make.log || {
    log "$(cat make.log)"
    log "Error: libgcrypt make failed."
    exit 1
}
make install &>install.log || {
    log "$(cat install.log)"
    log "Error: libgcrypt install failed."
    exit 1
}

if [ ! -f "${PREFIX}/lib/pkgconfig/libgcrypt.pc" ]; then
    {
        echo "prefix=${PREFIX}"
        echo "exec_prefix=\${prefix}"
        echo "libdir=\${exec_prefix}/lib"
        echo "includedir=\${prefix}/include"
        echo ""
        echo "Name: libgcrypt"
        echo "Description: GnuPG cryptographic library"
        echo "Version: ${libgcrypt_version}"
        echo "Libs: -L\${libdir} -lgcrypt"
        echo "Cflags: -I\${includedir}"
    } >${PREFIX}/lib/pkgconfig/libgcrypt.pc
else
    sed -i "s/prefix=.*/prefix=${PREFIX}/" ${PREFIX}/lib/pkgconfig/libgcrypt.pc
fi

if [[ ${TARGET_OS} == "windows" ]]; then
    sed -i 's/^Libs: \(.*\)[\r|\n]/Libs: \1 -lws2_32/' ${PREFIX}/lib/pkgconfig/libgcrypt.pc
fi
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libgcrypt.pc

echo '#!/bin/sh' >/usr/local/bin/libgcrypt-config
echo 'pkg-config libgcrypt "$@"' >>/usr/local/bin/libgcrypt-config
chmod +x /usr/local/bin/libgcrypt-config
#endregion

#region libbdplus
cd /build/libbdplus
./bootstrap --prefix=${PREFIX} --libdir=${PREFIX}/lib --enable-static --disable-shared --with-pic --disable-doc \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --libdir=${PREFIX}/lib --enable-static --disable-shared --with-pic --disable-doc \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "libbdplus configure failed"
    exit 1
fi

make -j$(nproc) &>make.log || {
    log "$(cat make.log)"
    log "Error: libbdplus make failed."
    exit 1
}
make install &>install.log || {
    log "$(cat install.log)"
    log "Error: libbdplus install failed."
    exit 1
}

if [[ ! -f "${PREFIX}/lib/pkgconfig/libbdplus.pc" ]]; then
    log "Error: ${PREFIX}/lib/pkgconfig/libbdplus.pc does not exist."
    exit 1
fi

if [[ ${TARGET_OS} == "windows" ]]; then
    sed -i 's/^Libs: \(.*\)[\r|\n]/Libs: \1 -lws2_32/' ${PREFIX}/lib/pkgconfig/libbdplus.pc
fi
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libbdplus.pc
#endregion

#region libaacs
cd /build/libaacs

if [[ -f "/scripts/patches/libaacs/keydb.cfg" ]]; then
    mv KEYDB.cfg KEYDB.cfg.orig
    cp /scripts/patches/libaacs/keydb.cfg KEYDB.cfg
fi

if [[ -f "/scripts/patches/libaacs/keydb_static.c" ]]; then
    mv Makefile.am Makefile.am.orig
    mv src/file/keydbcfg.c src/file/keydbcfg.c.orig

    cp /scripts/patches/libaacs/Makefile.am Makefile.am
    cp /scripts/patches/libaacs/keydb_static.c src/file/keydb.c

    if [[ -f "/scripts/patches/libaacs/keydb_static.h" ]]; then
        mv src/file/keydb.h src/file/keydb.h.orig
        cp /scripts/patches/libaacs/keydb_static.h src/file/keydb.h
    fi

    cp /scripts/patches/libaacs/keydbcfg.c src/file/keydbcfg.c
fi

./bootstrap --prefix=${PREFIX} --libdir=${PREFIX}/lib --enable-static --disable-shared --with-pic --disable-doc \
    --host=${CROSS_PREFIX%-}
./configure --prefix=${PREFIX} --libdir=${PREFIX}/lib --enable-static --disable-shared --with-pic --disable-doc \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "libaacs configure failed"
    exit 1
fi

if [[ -f "src/file/keydb.c" ]]; then
    apply_sed "AM_CFLAGS = -std=c99 \$(LIBGCRYPT_CFLAGS) \$(GPG_ERROR_CFLAGS)" "AM_CFLAGS = -std=c99 \$(LIBGCRYPT_CFLAGS) \$(GPG_ERROR_CFLAGS) -Wno-trigraphs" "Makefile.am" "s" "/g"
    apply_sed "	src/file/keydbcfg.h \\" "a	src/file/keydb.c \\" "src/Makefile.am"
fi

make -j$(nproc) &>make.log || {
    log "$(cat make.log)"
    log "Error: libaacs make failed."
    exit 1
}
make install &>install.log || {
    log "$(cat install.log)"
    log "Error: libaacs install failed."
    exit 1
}

if [[ ! -f "${PREFIX}/lib/pkgconfig/libaacs.pc" ]]; then
    log "Error: ${PREFIX}/lib/pkgconfig/libaacs.pc does not exist."
    exit 1
fi

if [[ ${TARGET_OS} == "windows" ]]; then
    sed -i 's/^Libs: \(.*\)[\r|\n]/Libs: \1 -lws2_32/' ${PREFIX}/lib/pkgconfig/libaacs.pc
fi
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libaacs.pc
#endregion

#region libbluray
cd /build/libbluray

if pkg-config --cflags libaacs >/dev/null 2>&1; then
    log "libaacs is installed and configured correctly."
else
    log "Error: libaacs not found or pkg-config is not configured properly."
    exit 1
fi

if [[ -f "/scripts/patches/libbluray/aacs_static.c" ]]; then
    mv configure.ac configure.ac.orig
    cp /scripts/patches/libbluray/configure.ac configure.ac

    mv Makefile.am Makefile.am.orig
    cp /scripts/patches/libbluray/Makefile.am Makefile.am

    mv src/libbluray/disc/aacs.c src/libbluray/disc/aacs.c.orig
    cp /scripts/patches/libbluray/aacs_static.c src/libbluray/disc/aacs.c
fi
# replace in all files "str_dup" with "bd_str_dup"
find . -type f -exec sed -i 's/str_dup/libbluray_str_dup/g' {} \;
find . -type f -exec sed -i 's/str_printf/libbluray_str_printf/g' {} \;
find . -type f -exec sed -i 's/str_print_hex/libbluray_str_print_hex/g' {} \;

sed -i 's/dec_init/libbluray_dec_init/g' src/libbluray/disc/dec.c
sed -i 's/dec_init/libbluray_dec_init/g' src/libbluray/disc/dec.h
sed -i 's/dec_init/libbluray_dec_init/g' src/libbluray/disc/disc.c

LIBS="-laacs -lbdplus -lgcrypt -lgpg-error"
EXTRA_LIBS="-L${PREFIX}/lib -laacs -lbdplus -lgcrypt -lgpg-error"
if [[ ${TARGET_OS} == "windows" ]]; then
    LIBS+=" -lws2_32"
    EXTRA_LIBS+=" -lws2_32"
fi

./bootstrap --prefix=${PREFIX} --enable-static --enable-bdjava --disable-shared \
    --with-pic --with-libxml2 --with-libaacs --with-libbdplus --with-aacs --with-bdplus \
    --disable-doxygen-doc --disable-doxygen-dot --disable-doxygen-html --disable-doxygen-ps --disable-doxygen-pdf --disable-examples \
    --host=${CROSS_PREFIX%-}

./configure --prefix=${PREFIX} --enable-static --enable-bdjava --disable-shared \
    --with-pic --with-libxml2 --with-libaacs --with-libbdplus --with-aacs --with-bdplus \
    --disable-doxygen-doc --disable-doxygen-dot --disable-doxygen-html --disable-doxygen-ps --disable-doxygen-pdf --disable-examples \
    --host=${CROSS_PREFIX%-} | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) &>make.log || {
    log "$(cat make.log)"
    log "Error: libbluray make failed."
    exit 1
}

make install &>install.log || {
    log "$(cat install.log)"
    log "Error: libbluray install failed."
    exit 1
}

if [[ ! -f "${PREFIX}/lib/libbluray.a" ]]; then
    log "Error: ${PREFIX}/lib/libbluray.a does not exist."
    exit 1
fi

if [[ ! -f "${PREFIX}/lib/pkgconfig/libbluray.pc" ]]; then
    log "Error: ${PREFIX}/lib/pkgconfig/libbluray.pc does not exist."
    exit 1
fi

find . -name '*.jar' -exec cp {} ${PREFIX}/lib \;

if [[ ${TARGET_OS} == "windows" ]]; then
    sed -i 's/^Libs: \(.*\)[\r|\n]/Libs: \1 -lws2_32/' ${PREFIX}/lib/pkgconfig/libbluray.pc
elif [[ ${TARGET_OS} == "darwin" ]]; then
    sed -i 's/^Libs: \(.*\)[\r|\n]/Libs: \1 -framework CoreFoundation -framework IOKit/' ${PREFIX}/lib/pkgconfig/libbluray.pc
fi
echo "Libs.private: -lstdc++ -laacs -lbdplus -lgcrypt -lgpg-error" >>${PREFIX}/lib/pkgconfig/libbluray.pc

LIBS=""
EXTRA_LIBS=""
#endregion

#region Clean up
rm -rf /build/libgpg-error
rm -rf /build/libgcrypt
rm -rf /build/libbdplus
rm -rf /build/libaacs
rm -rf /build/libbluray
#endregion

#region Add pkg-config files
add_enable "--enable-libbluray"
if [[ ${TARGET_OS} == "windows" ]]; then
    add_extralib "-laacs -lbdplus -lgcrypt -lgpg-error -lws2_32"
else
    add_extralib "-laacs -lbdplus -lgcrypt -lgpg-error"
fi
#endregion

exit 0

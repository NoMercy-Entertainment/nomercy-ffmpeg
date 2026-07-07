#!/bin/bash

#region libgpg-error
cd /build/libgpg-error
if [[ ${TARGET_OS} == "darwin" ]]; then
    if [[ ${ARCH} == "arm64" ]]; then
        # Two tools look up the lock object under different names:
        #   configure (full triplet):  lock-obj-pub.aarch64-apple-darwin24.1.h
        #   mkheader  (stripped arch): lock-obj-pub.darwin24.1.h
        # Source ships "aarch64-apple-darwin" (no version). Copy to both targets.
        cp src/syscfg/lock-obj-pub.aarch64-apple-darwin.h src/syscfg/lock-obj-pub.${CROSS_PREFIX%-}.h
        cp src/syscfg/lock-obj-pub.aarch64-apple-darwin.h src/syscfg/lock-obj-pub.aarch64-apple-darwin24.1.h
        cp src/syscfg/lock-obj-pub.aarch64-apple-darwin.h src/syscfg/lock-obj-pub.darwin24.1.h
    else
        cp src/syscfg/lock-obj-pub.${ARCH}-apple-darwin.h src/syscfg/lock-obj-pub.${CROSS_PREFIX%-}.h
    fi
elif [[ ${TARGET_OS} == "freebsd" ]]; then
    # Upstream ships no FreeBSD lock object and a cross build cannot run
    # gen-posix-lock-obj. On FreeBSD amd64 pthread_mutex_t is an 8-byte pointer
    # and PTHREAD_MUTEX_INITIALIZER is NULL, so the object is all zeroes.
    # mkheader looks up the stripped OS name, configure the full triplet.
    for f in lock-obj-pub.freebsd14.h lock-obj-pub.${CROSS_PREFIX%-}.h; do
        cat >src/syscfg/${f} <<'EOF'
## File created by gen-posix-lock-obj - DO NOT EDIT
## To be included by mkheader into gpg-error.h

typedef struct
{
  long _vers;
  union {
    volatile char _priv[8];
    long _x_align;
    long *_xp_align;
  } u;
} gpgrt_lock_t;

#define GPGRT_LOCK_INITIALIZER {1,{{0,0,0,0,0,0,0,0}}}
EOF
    done
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

if [[ ${TARGET_OS} == "freebsd" ]]; then
    # trap.c calls gettimeofday() without including <sys/time.h>; glibc leaks
    # the declaration through other headers, FreeBSD libc does not
    sed -i '0,/^#include/s//#include <sys\/time.h>\n&/' src/libbdplus/bdsvm/trap.c
    # -D_POSIX_C_SOURCE=200112L hides XSI declarations (gettimeofday) on
    # FreeBSD; _XOPEN_SOURCE=700 restores them
    sed -i 's/^SET_FEATURES="\(.*\)"/SET_FEATURES="\1 -D_XOPEN_SOURCE=700"/' configure.ac
    # convtab_dump.c declares a global "uint32_t index[]" that collides with
    # libc's legacy index() declaration, which FreeBSD's strings.h exposes
    # whenever __POSIX_VISIBLE <= 200112 — rename the variable
    sed -i 's/\bindex\b/conv_index/g' src/examples/convtab_dump.c
fi
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

if [[ ${TARGET_OS} == "freebsd" ]]; then
    # same -D_POSIX_C_SOURCE strictness as libbdplus; keep XSI declarations visible
    sed -i 's/^SET_FEATURES="\(.*\)"/SET_FEATURES="\1 -D_XOPEN_SOURCE=700"/' configure.ac
fi

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
    mv meson.build meson.build.orig
    cp /scripts/patches/libbluray/meson.build meson.build

    mv meson_options.txt meson_options.txt.orig
    cp /scripts/patches/libbluray/meson_options.txt meson_options.txt

    mv src/meson.build src/meson.build.orig
    cp /scripts/patches/libbluray/src.meson.build src/meson.build

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

meson setup build \
    --prefix=${PREFIX} \
    --libdir=lib \
    --buildtype=release \
    -Ddefault_library=static \
    -Dlibaacs=enabled \
    -Dlibbdplus=enabled \
    -Dlibxml2=enabled \
    -Dbdj_jar=auto \
    -Denable_tools=false \
    -Denable_examples=false \
    -Denable_devtools=false \
    -Denable_docs=false \
    --cross-file="/build/cross_file.txt" | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log -a "libbluray configure failed"
	exit 1
fi

ninja -j$(nproc) -C build 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log -a "libbluray build failed"
	exit 1
fi

ninja -C build install >/dev/null 2>&1

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
log -a "libbluray build and installation successful."
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

#!/bin/bash

export OPENSSL_TARGET="linux-x86_64"
if [[ "${ARCH}" == "aarch64" && "${TARGET_OS}" == "linux" ]]; then
    export OPENSSL_TARGET="linux-aarch64"
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "windows" ]]; then
    export OPENSSL_TARGET="mingw64"
elif [[ "${TARGET_OS}" == "darwin" ]]; then
    export OPENSSL_TARGET="darwin64-${ARCH}-cc"
fi

export OLD_CFLAGS=${CFLAGS}
export OLD_CXXFLAGS=${CXXFLAGS}
export CFLAGS="${CFLAGS} -fno-strict-aliasing"
export CXXFLAGS="${CXXFLAGS} -fno-strict-aliasing"
cd /build/openssl
./Configure threads zlib no-shared enable-camellia enable-ec enable-srp --prefix=${PREFIX} ${OPENSSL_TARGET} --libdir=${PREFIX}/lib \
    --cross-compile-prefix='' | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

sed -i -e "/^CFLAGS=/s|=.*|=${CFLAGS}|" -e "/^LDFLAGS=/s|=[[:space:]]*$|=${LDFLAGS}|" Makefile
make -j$(nproc) build_sw && make install_sw
rm -rf /build/openssl
export CFLAGS=${OLD_CFLAGS}
export CXXFLAGS=${OLD_CXXFLAGS}

add_enable "--enable-openssl"

exit 0

#!/bin/bash

LIBRAV1E_TARGET=""
if [[ "${ARCH}" == "aarch64" && "${TARGET_OS}" == "linux" ]]; then
    LIBRAV1E_TARGET="--target=${ARCH}-unknown-linux-gnu"
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "windows" ]]; then
    LIBRAV1E_TARGET="--target=${ARCH}-pc-windows-gnu"
elif [[ "${ARCH}" == "aarch64" && "${TARGET_OS}" == "windows" ]]; then
    LIBRAV1E_TARGET="--target=${ARCH}-pc-windows-msvc"
elif [[ "${ARCH}" == "arm64" && "${TARGET_OS}" == "darwin" ]]; then
    LIBRAV1E_TARGET="--target=aarch64-apple-darwin"
elif [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "darwin" ]]; then
    LIBRAV1E_TARGET="--target=${ARCH}-apple-darwin"
fi

OLD_LDFLAGS="${LDFLAGS}"
OLD_RUSTFLAGS="${RUSTFLAGS}"
# Set RUSTFLAGS for Darwin to suppress duplicate symbol warnings
if [[ "${TARGET_OS}" == "darwin" ]]; then
	export LDFLAGS="${LDFLAGS} -Wl,-dead_strip_dylibs -Wl,-multiply_defined,suppress"
    export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-Wl,-dead_strip_dylibs -C link-arg=-Wl,-multiply_defined,suppress -C panic=abort -C lto=thin -C opt-level=3"
fi

cd /build/librav1e
cargo cinstall -j$(nproc) -v ${LIBRAV1E_TARGET} --prefix=${PREFIX} --library-type=staticlib --crt-static --release | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
	LDFLAGS="${OLD_LDFLAGS}"
	RUSTFLAGS="${OLD_RUSTFLAGS}"
    exit 1
fi

if [[ "${ARCH}" == "x86_64" && "${TARGET_OS}" == "linux" ]]; then
    sed -i 's/-lgcc_s//' ${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/rav1e.pc
    cp ${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/rav1e.pc ${PREFIX}/lib/pkgconfig/rav1e.pc
else
    sed -i 's/-lgcc_s//' ${PREFIX}/lib/pkgconfig/rav1e.pc
fi
LDFLAGS="${OLD_LDFLAGS}"
RUSTFLAGS="${OLD_RUSTFLAGS}"

rm -rf /build/librav1e

add_enable "--enable-librav1e"

exit 0

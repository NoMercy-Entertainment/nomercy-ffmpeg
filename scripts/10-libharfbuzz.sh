#!/bin/bash

cd /build/harfbuzz

if [[ "${TARGET_OS}" == "darwin" ]]; then
	mkdir -p /build/harfbuzz/src/unicode
	cp -r /usr/include/unicode/* /build/harfbuzz/src/unicode
fi

# Configure HarfBuzz with CoreText support for Darwin
HARFBUZZ_EXTRA_FLAGS=""
if [[ "${TARGET_OS}" == "darwin" ]]; then
	HARFBUZZ_EXTRA_FLAGS="-Dcoretext=enabled"
fi

meson build --prefix=${PREFIX} --buildtype=release -Ddefault_library=static \
	${HARFBUZZ_EXTRA_FLAGS} \
	--cross-file="/build/cross_file.txt" | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	exit 1
fi

ninja -j$(nproc) -C build && ninja -C build install
rm -rf /build/harfbuzz

add_enable "--enable-libharfbuzz"

exit 0

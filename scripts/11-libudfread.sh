#!/bin/bash

cd /build/libudfread

mkdir -p build && cd build

meson --prefix=${PREFIX} --buildtype=release -Ddefault_library=static \
	--cross-file="/build/cross_file.txt" .. 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
	log -a "Error: libudfread meson setup failed."
	exit 1
fi

# Checked through PIPESTATUS, not `| log -a || exit`. Without pipefail -- and
# nothing here sets it -- a pipeline's status is its LAST command, which is
# log, which is tee, which succeeds. So `make | log -a || { ...; exit 1; }`
# looked guarded and could never fire: a failed build was logged and then
# carried on. PIPESTATUS[0] is the build's own status.
ninja -j$(nproc) 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log -a "libudfread build failed"
    exit 1
fi
ninja install 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log -a "libudfread install failed"
    exit 1
fi

if [ ! -f ${PREFIX}/lib/pkgconfig/libudfread.pc ]; then
    cp libudfread.pc ${PREFIX}/lib/pkgconfig/udfread.pc
    cp ${PREFIX}/lib/pkgconfig/udfread.pc ${PREFIX}/lib/pkgconfig/libudfread.pc
fi

rm -rf /build/libudfread

exit 0

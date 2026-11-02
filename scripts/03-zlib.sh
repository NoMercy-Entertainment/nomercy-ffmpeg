#!/bin/bash

# An array, so "--archs=-arch <arch>" reaches configure as ONE argument.
#
# This used to be EXTRA_CONFIG="--archs="-arch ${ARCH}"", whose quotes close
# and reopen: bash read it as an assignment prefix followed by the command
# "${ARCH}", ran x86_64 or arm64 as a program ("command not found"), and left
# EXTRA_CONFIG empty. zlib on darwin has always been configured without it.
#
# The obvious repair, EXTRA_CONFIG="--archs=\"-arch ${ARCH}\"", is wrong too:
# word splitting ignores embedded quotes, so configure receives the two
# arguments --archs="-arch and x86_64", quote characters included. An array
# is the only form that keeps the space inside one argument.
EXTRA_CONFIG=()
if [ ${TARGET_OS} == "darwin" ]; then
    EXTRA_CONFIG=(--archs="-arch ${ARCH}")
fi

cd /build/zlib
./configure --prefix=${PREFIX} --static "${EXTRA_CONFIG[@]}" 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi

make -j$(nproc) && make install || exit 1
rm -rf /build/zlib

exit 0

#!/bin/bash

#region libjpeg
cd /build/jpeg

# Configure and compile
./configure --disable-shared --enable-static \
    --host=${CROSS_PREFIX%-} 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "Failed to build libjpeg"
    exit 1
fi

make && make install || exit 1

if [[ ${TARGET_OS} != "linux" ]]; then
    sed -i 's/^Libs: \(.*\)[\r|\n]/Libs: \1 -lz/' ${PREFIX}/lib/pkgconfig/libjpeg.pc
fi
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libjpeg.pc

rm -rf /build/jpeg-v9f
cd /build
#endregion

#region libjpeg-turbo
cd /build/libjpeg-turbo
mkdir build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG}
make -j$(nproc) && make install || exit 1
if [[ ${TARGET_OS} != "linux" ]]; then
    sed -i 's/^Libs: \(.*\)[\r|\n]/Libs: \1 -lz/' ${PREFIX}/lib/pkgconfig/libjpeg.pc
fi
echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/libjpeg.pc
cd /build
rm -rf /build/libjpeg-turbo
#endregion

#region openjpeg
cd /build/openjpeg
mkdir build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DBUILD_PKGCONFIG_FILES=ON \
    -DBUILD_CODEC=OFF \
    -DWITH_ASTYLE=OFF \
    -DBUILD_TESTING=OFF 2>&1 | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "Failed to build openjpeg"
    exit 1
fi

# Checked through PIPESTATUS, not `| log -a || exit`. Without pipefail -- and
# nothing here sets it -- a pipeline's status is its LAST command, which is
# log, which is tee, which succeeds. So `make | log -a || { ...; exit 1; }`
# looked guarded and could never fire: a failed build was logged and then
# carried on. PIPESTATUS[0] is the build's own status.
make -j$(nproc) 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log -a "openjpeg build failed"
    exit 1
fi
make install 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log -a "openjpeg install failed"
    exit 1
fi

OPENJPEG_PC="${PREFIX}/lib/pkgconfig/libopenjp2.pc"

if [ ! -f "${OPENJPEG_PC}" ]; then
    log "openjpeg install failed — libopenjp2.pc not found under ${PREFIX}"
    exit 1
fi

if [[ ${TARGET_OS} != "linux" ]]; then
    if grep -q "^Libs.private:" "${OPENJPEG_PC}"; then
        sed -i 's/^Libs.private:.*/Libs.private: -lstdc++ -lm -lpthread -lz/' "${OPENJPEG_PC}"
    else
        echo "Libs.private: -lstdc++ -lm -lpthread -lz" >>"${OPENJPEG_PC}"
    fi
fi

rm -rf /build/openjpeg
#endregion

add_enable "--enable-libopenjpeg"

exit 0

#!/bin/bash

mkdir -p /build/OpenCL

# Both Khronos repositories are pinned to the commit each one was at when
# v1.0.44 was built. They used to be cloned at whatever the default branch
# held that day, so two builds of the same tree could link different OpenCL
# code. Both commits predate that release: headers 2026-09-30, loader
# 2026-09-22. Neither matches a tag -- each is ahead of the latest one -- so
# pinning a tag would have been a downgrade. Bump these deliberately.
OPENCL_HEADERS_COMMIT=30bc20a8e90468e231d7c639805ae61ad1fefa4f
OPENCL_LOADER_COMMIT=5192c84f8059e5f703e5452929b613f9487f6e4c

git clone https://github.com/KhronosGroup/OpenCL-Headers.git /build/OpenCL/headers || exit 1
git -C /build/OpenCL/headers checkout --quiet "${OPENCL_HEADERS_COMMIT}" || exit 1

mkdir -p ${PREFIX}/include/CL
cp /build/OpenCL/headers/CL/* ${PREFIX}/include/CL/.

git clone https://github.com/KhronosGroup/OpenCL-ICD-Loader.git /build/OpenCL/loader || exit 1
git -C /build/OpenCL/loader checkout --quiet "${OPENCL_LOADER_COMMIT}" || exit 1

cd /build/OpenCL/loader
mkdir -p build && cd build

cmake ${CMAKE_COMMON_ARG} \
    -DOPENCL_ICD_LOADER_HEADERS_DIR="${PREFIX}/include" -DOPENCL_ICD_LOADER_BUILD_SHARED_LIBS=OFF \
    -DOPENCL_ICD_LOADER_DISABLE_OPENCLON12=ON -DOPENCL_ICD_LOADER_PIC=ON \
    -DOPENCL_ICD_LOADER_BUILD_TESTING=OFF -DBUILD_TESTING=OFF ..

make -j$(nproc) && make install || exit 1

echo "prefix=${PREFIX}" >OpenCL.pc
echo "exec_prefix=\${prefix}" >>OpenCL.pc
echo "libdir=\${exec_prefix}/lib" >>OpenCL.pc
echo "includedir=\${prefix}/include" >>OpenCL.pc
echo "" >>OpenCL.pc
echo "Name: OpenCL" >>OpenCL.pc
echo "Description: OpenCL ICD Loader" >>OpenCL.pc
echo "Version: 9999" >>OpenCL.pc
echo "Cflags: -I\${includedir}" >>OpenCL.pc

if [[ ${TARGET_OS} == "windows" ]]; then
    echo "Libs: -L\${libdir} -l:OpenCL.a" >>OpenCL.pc
    echo "Libs.private: -lole32 -lshlwapi -lcfgmgr32" >>OpenCL.pc
else
    echo "Libs: -L\${libdir} -lOpenCL" >>OpenCL.pc
    echo "Libs.private: -ldl" >>OpenCL.pc
fi

mv OpenCL.pc ${PREFIX}/lib/pkgconfig/OpenCL.pc

add_enable "--enable-opencl"

exit 0
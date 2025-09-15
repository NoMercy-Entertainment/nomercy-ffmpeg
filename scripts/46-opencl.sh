#!/bin/bash

mkdir -p /build/OpenCL

git clone https://github.com/KhronosGroup/OpenCL-Headers.git /build/OpenCL/headers

mkdir -p ${PREFIX}/include/CL
cp /build/OpenCL/headers/CL/* ${PREFIX}/include/CL/.

git clone https://github.com/KhronosGroup/OpenCL-ICD-Loader.git /build/OpenCL/loader

cd /build/OpenCL/loader
mkdir -p build && cd build

cmake ${CMAKE_COMMON_ARG} \
    -DOPENCL_ICD_LOADER_HEADERS_DIR="${PREFIX}/include" -DOPENCL_ICD_LOADER_BUILD_SHARED_LIBS=OFF \
    -DOPENCL_ICD_LOADER_DISABLE_OPENCLON12=ON -DOPENCL_ICD_LOADER_PIC=ON \
    -DOPENCL_ICD_LOADER_BUILD_TESTING=OFF -DBUILD_TESTING=OFF ..

make -j$(nproc) && make install

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
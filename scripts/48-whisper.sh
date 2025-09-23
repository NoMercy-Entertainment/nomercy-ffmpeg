#!/bin/bash

whisper_version=1.7.6

rm -f /ffmpeg_build.log
touch /ffmpeg_build.log

mkdir -p /build/whisper
cd /build/whisper

git clone --branch v${whisper_version} https://github.com/ggml-org/whisper.cpp.git .

rm -rf build

chmod +x ./models/download-ggml-model.sh
./models/download-ggml-model.sh base

NPROC=$(nproc)

WHISPER_CMAKE_COMMON_ARG=${CMAKE_COMMON_ARG}

if check_enabled "sdl2"; then
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DWHISPER_SDL2=ON"
fi

if check_enabled "cuda"; then
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_CUDA=ON -DCUDA_TOOLKIT_ROOT_DIR=${PREFIX}/lib -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc"
fi

if check_enabled "vulkan"; then
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_VULKAN=ON -DVulkan_LIBRARY=${PREFIX}/lib/libvulkan.a -DVulkan_INCLUDE_DIR=${PREFIX}/include"
fi

if [[ ${TARGET_OS} == "windows" ]]; then
    OLD_CFLAGS=${CFLAGS}
    OLD_CXXFLAGS=${CXXFLAGS}

    CFLAGS="${CFLAGS} -lws2_32 -lwinpthread -lgomp -lkernel32"
    CXXFLAGS="${CXXFLAGS} -lws2_32 -lwinpthread -lgomp -lkernel32"

    find . -name '*.cpp' -exec sed -i 's|%ld|%llu|g' {} +
    find . -name '*.cpp' -exec sed -i 's|%lld|%llu|g' {} +

    # Disable the following functions that cause issues on Windows
    sed -i '2369,2380s/^/\/\//' ggml/src/ggml-cpu/ggml-cpu.c

    if [[ -f ${PREFIX}/lib/libopenblas.a ]]; then
        WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_BLAS=ON -DBLAS_VENDOR=OpenBLAS -DBLAS_LIBRARIES=${PREFIX}/lib/libopenblas.a -DBLAS_INCLUDE_DIRS=${PREFIX}/include/openblas"
    fi

    cmake -G Ninja -B build  \
        ${WHISPER_CMAKE_COMMON_ARG} \
        -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
        -DWHISPER_STATIC=ON \
        -DWHISPER_BUILD_TOOLS=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DVERBOSE=ON | tee /ffmpeg_build.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        CFLAGS=${OLD_CFLAGS}
        CXXFLAGS=${OLD_CXXFLAGS}
        echo "Error: Whisper configure failed" >> /ffmpeg_build.log
        exit 1
    fi

    ninja -j${NPROC} -C build 2>&1 | tee -a /ffmpeg_build.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        CFLAGS=${OLD_CFLAGS}
        CXXFLAGS=${OLD_CXXFLAGS}
        echo "Error: Whisper build failed" >> /ffmpeg_build.log
        exit 1
    fi

    ninja -C build install 2>&1 | tee -a /ffmpeg_build.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        CFLAGS=${OLD_CFLAGS}
        CXXFLAGS=${OLD_CXXFLAGS}
        echo "Error: Whisper install failed" >> /ffmpeg_build.log
        exit 1
    fi
    
    CFLAGS=${OLD_CFLAGS}
    CXXFLAGS=${OLD_CXXFLAGS}
else
    if [[ ${TARGET_OS} == "darwin" ]]; then
        WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_METAL=OFF -DGGML_ACCELERATE=OFF"
        if [[ ${ARCH} == "x86_64" ]]; then
            WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15.0"
        fi
    fi
    mkdir build && cd build

    cmake -S .. -B . \
        ${WHISPER_CMAKE_COMMON_ARG} \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_TOOLS=OFF \
        -DWHISPER_BUILD_SERVER=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_TESTS=OFF -DVERBOSE=ON | tee /ffmpeg_build.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "Error: Whisper configure failed" >> /ffmpeg_build.log
        exit 1
    fi

    cmake --build . -j${NPROC} --config Release --verbose | tee -a /ffmpeg_build.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "Error: Whisper build failed" >> /ffmpeg_build.log
        exit 1
    fi

    cmake --install . --config Release | tee -a /ffmpeg_build.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "Error: Whisper install failed" >> /ffmpeg_build.log
        exit 1
    fi
fi

if [[ ! -f "${PREFIX}/lib/pkgconfig/whisper.pc" ]]; then
    echo "Error: whisper.pc not found" >>/ffmpeg_build.log
    exit 1
fi

echo "Whisper installed successfully" > /ffmpeg_build.log

cd /build
rm -rf /build/whisper

rm -rf ${PREFIX}/lib/pkgconfig/whisper.pc
lib_flags="Libs: -L\${libdir} -lggml -lggml-base -lwhisper -lggml -lggml-base -lggml-cpu"
lib_private_flags="Libs.private: -lstdc++"
{
    echo "prefix=${PREFIX}"
    echo "exec_prefix=\${prefix}"
    echo "libdir=\${exec_prefix}/lib"
    echo "includedir=\${prefix}/include"
    echo ""
    echo "Name: whisper"
    echo "Description: Port of OpenAI's Whisper model in C/C++"
    echo "Version: ${whisper_version}"
    if [[ ${TARGET_OS} == "linux" ]]; then
        lib_private_flags+=" -lm -fopenmp"
    elif [[ ${TARGET_OS} == "darwin" ]]; then
        lib_flags+=" -lggml-blas"
        lib_private_flags+=" -lz"
    else
        lib_flags+=" -lggml-blas -lwinpthread -lgomp -lws2_32 -fopenmp"
        lib_private_flags+=" -lm -lopenblas -lwinpthread -lgomp -lws2_32 -fopenmp"
    fi
    echo "${lib_flags}"
    echo "${lib_private_flags}"
    if [[ ${TARGET_OS} == "windows" ]]; then
        echo "Cflags: -I\${includedir} -fopenmp"
    else
        echo "Cflags: -I\${includedir}"
    fi
    echo "Requires: "
    echo "Requires.private: "
} >${PREFIX}/lib/pkgconfig/whisper.pc

if [[ ${TARGET_OS} == "windows" ]]; then
    mv ${PREFIX}/lib/ggml.a ${PREFIX}/lib/libggml.a
    mv ${PREFIX}/lib/ggml-base.a ${PREFIX}/lib/libggml-base.a
    mv ${PREFIX}/lib/ggml-blas.a ${PREFIX}/lib/libggml-blas.a
    mv ${PREFIX}/lib/ggml-cpu.a ${PREFIX}/lib/libggml-cpu.a
fi

add_enable "--enable-whisper"

exit 0
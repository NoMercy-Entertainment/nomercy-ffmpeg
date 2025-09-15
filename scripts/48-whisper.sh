#!/bin/bash

whisper_version=1.7.6

touch /ffmpeg_build.log

mkdir -p /build/whisper
cd /build/whisper

git clone --branch v${whisper_version} https://github.com/ggml-org/whisper.cpp.git .

chmod +x ./models/download-ggml-model.sh
./models/download-ggml-model.sh base

rm -rf build
mkdir build && cd build

WHISPER_CMAKE_COMMON_ARG=${CMAKE_COMMON_ARG}

if check_enabled "sdl2"; then
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DWHISPER_SDL2=ON"
else
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DWHISPER_SDL2=OFF"
fi

if [[ ${TARGET_OS} == "darwin" && ${ARCH} == "x86_64" ]]; then
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_METAL=OFF -DGGML_ACCELERATE=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15.0"
elif [[ ${TARGET_OS} == "darwin" && ${ARCH} == "arm64" ]]; then
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_METAL=OFF -DGGML_ACCELERATE=OFF"
elif [[ ${TARGET_OS} == "windows" ]]; then
    WHISPER_CMAKE_COMMON_ARG="${WHISPER_CMAKE_COMMON_ARG} -DGGML_CPU=OFF"
fi

cmake -S .. -B . \
    ${WHISPER_CMAKE_COMMON_ARG} \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_TOOLS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DVERBOSE=ON | tee -a /ffmpeg_build.log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "Error: configure failed" >> /ffmpeg_build.log
    exit 1
fi

cmake --build . -j$(nproc) --config Release --verbose | tee -a /ffmpeg_build.log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "Error: build failed" >> /ffmpeg_build.log
    exit 1
fi

cmake --install . --config Release | tee -a /ffmpeg_build.log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "Error: install failed" >> /ffmpeg_build.log
    exit 1
fi

if [[ ! -f "${PREFIX}/lib/pkgconfig/whisper.pc" ]]; then
    echo "Error: whisper.pc not found" >>/ffmpeg_build.log
    exit 1
fi

if [[ ${TARGET_OS} == "linux" ]]; then
    rm -rf ${PREFIX}/lib/pkgconfig/whisper.pc
    {
        echo "prefix=${PREFIX}"
        echo "exec_prefix=\${prefix}"
        echo "libdir=\${exec_prefix}/lib"
        echo "includedir=\${prefix}/include"
        echo ""
        echo "Name: whisper"
        echo "Description: Port of OpenAI's Whisper model in C/C++"
        echo "Version: ${whisper_version}"
        echo "Libs: -L\${libdir} -lggml -lggml-base -lwhisper -lggml -lggml-base -lggml-cpu"
        echo "Libs.private: -lstdc++ -lm -fopenmp"
        echo "Cflags: -I\${includedir}"
    } >${PREFIX}/lib/pkgconfig/whisper.pc
elif [[ ${TARGET_OS} == "darwin" ]]; then
    rm -rf ${PREFIX}/lib/pkgconfig/whisper.pc
    {
        echo "prefix=${PREFIX}"
        echo "exec_prefix=\${prefix}"
        echo "libdir=\${exec_prefix}/lib"
        echo "includedir=\${prefix}/include"
        echo ""
        echo "Name: whisper"
        echo "Description: Port of OpenAI's Whisper model in C/C++"
        echo "Version: ${whisper_version}"
        echo "Libs: -L\${libdir} -lggml -lggml-base -lwhisper -lggml -lggml-base -lggml-cpu -lggml-blas"
        echo "Libs.private: -lstdc++ -lz"
        echo "Cflags: -I\${includedir}"
    } >${PREFIX}/lib/pkgconfig/whisper.pc
elif [[ ${TARGET_OS} == "windows" ]]; then
    rm -rf ${PREFIX}/lib/pkgconfig/whisper.pc
    {
        echo "prefix=${PREFIX}"
        echo "exec_prefix=\${prefix}"
        echo "libdir=\${exec_prefix}/lib"
        echo "includedir=\${prefix}/include"
        echo ""
        echo "Name: whisper"
        echo "Description: Port of OpenAI's Whisper model in C/C++"
        echo "Version: ${whisper_version}"
        echo "Libs: -L\${libdir} -lggml -lggml-base -lwhisper -lggml -lggml-base -lwinpthread -lws2_32"
        echo "Libs.private: -lstdc++"
        echo "Cflags: -I\${includedir}"
    } >${PREFIX}/lib/pkgconfig/whisper.pc
    cp ${PREFIX}/lib/ggml.a ${PREFIX}/lib/libggml.a
    cp ${PREFIX}/lib/ggml-base.a ${PREFIX}/lib/libggml-base.a
fi

add_enable "--enable-whisper"

exit 0
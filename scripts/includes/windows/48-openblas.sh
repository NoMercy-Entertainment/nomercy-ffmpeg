#!/bin/bash
if [[ ${TARGET_OS} != "windows" ]]; then
    exit 255
fi

if [[ ${ARCH} == "aarch64" ]]; then
    # OpenBLAS is skipped on Windows-on-ARM. With DYNAMIC_ARCH=ON its CMake
    # enumerates the x86 kernel family regardless of TARGET ("Targeting the
    # ATOM architecture", kernel_CORE2, cpuid.S, ...), which cannot assemble
    # for aarch64. Setting TARGET=ARMV8 does not change that list.
    #
    # This costs nothing but BLAS acceleration inside the whisper filter:
    # 48-whisper.sh enables BLAS only "if [[ -f ${PREFIX}/lib/libopenblas.a ]]",
    # and OpenBLAS is a windows-only extra to begin with -- linux, darwin and
    # freebsd already build whisper without it. Transcription still works, it
    # just uses ggml's built-in kernels.
    exit 255
fi

rm -f /ffmpeg_build.log
touch /ffmpeg_build.log

git clone --branch v0.3.34 https://github.com/OpenMathLib/OpenBLAS /build/OpenBLAS
cd /build/OpenBLAS

# NUM_THREADS and BUFFERSIZE are memory settings, not speed settings.
#
# OpenBLAS starts one worker thread per logical processor from a linker
# constructor, before main(), and every worker commits a BUFFER_SIZE block as
# its first statement -- before it is given any work, in every process that
# links this library, whether or not it ever calls BLAS. The defaults here
# were NUM_THREADS=64 with BUFFERSIZE unset, which is 128 MiB per thread: a
# plain transcode on a 56-thread server committed 7078 MiB it never touched,
# and ffmpeg died with "Memory allocation still failed after 10 retries" once
# the host's commit limit was reached (178 stemsplit runs, see issue #70).
#
# 16 threads x 32 MiB caps that at 487 MiB measured, on both a 16-thread
# desktop and the 56-thread server, and costs no measurable whisper time
# (60 s of speech through ggml-base.en: 18.7/18.9 s before, 18.5/16.7 s
# after). Nothing we run comes near the ~30000x30000 matrices where a 32 MiB
# buffer is documented as a constraint; whisper's own matmuls are far smaller.
mkdir build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    -DBINARY=64 \
    -DBUILD_DEPRECATED=OFF \
    -DBUILD_LAPACK_DEPRECATED=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DBUILD_WITHOUT_LAPACK=YES \
    -DCMAKE_MT=mt \
    -DCROSS=ON \
    -DDYNAMIC_ARCH=ON \
    -DHOSTCC=gcc \
    -DNUM_THREADS=16 \
    -DBUFFERSIZE=20 \
    -DTARGET=NEHALEM \
    -DUTEST_CHECK=OFF \
    -DVERBOSE=ON 2>&1 | log
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "Error: OpenBLAS configure failed"
    exit 1
fi

cmake --build . -j$(nproc) --config Release 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "Error: OpenBLAS build failed"
    exit 1
fi

cmake --install . --config Release 2>&1 | log -a
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log "Error: OpenBLAS install failed"
    exit 1
else 
    echo "OpenBLAS installed successfully" > /ffmpeg_build.log
fi

cd /build
rm -rf /build/OpenBLAS

exit 0
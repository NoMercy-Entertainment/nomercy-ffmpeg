# tools/lyricsalign-lab/Dockerfile
#
# A lab for the lyricsalign filter: FFmpeg 9.0 source, whisper.cpp v1.9.1's
# ggml built static for the CPU, and the toolchain, so build.sh can turn
# scripts/includes/af_lyricsalign.c into a runnable ffmpeg in minutes instead
# of the hours a platform build takes. Nothing here is shipped: the platform
# dockerfiles build the real binaries with scripts/48-whisper.sh and
# scripts/65-espeak-ng.sh; this image only lets those scripts and the filter
# be exercised quickly. See README.md.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PREFIX=/opt/nm \
    TARGET_OS=linux \
    ARCH=x86_64

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git nasm yasm pkg-config ca-certificates curl \
        wget bzip2 xz-utils file python3 python3-numpy \
    && rm -rf /var/lib/apt/lists/*

ARG ffmpeg_version=9.0
ARG whisper_version=1.9.1

# FFmpeg source, from the same mirror the base image uses.
RUN mkdir -p /build && cd /build \
    && wget -q -O ffmpeg.tar.bz2 https://github.com/NoMercy-CI-Mirrors/sources/releases/download/ffmpeg-${ffmpeg_version}/ffmpeg-${ffmpeg_version}.tar.bz2 \
    && tar -xjf ffmpeg.tar.bz2 && rm ffmpeg.tar.bz2 && mv ffmpeg-${ffmpeg_version} ffmpeg

# whisper.cpp with the DTW median-filter backport 48-whisper.sh applies, built
# static, CPU only, at the haswell level (AVX2/FMA/F16C): the fixed-level
# shape the darwin platforms use, so the lab links the stock libggml-cpu.a
# plus a fixed-mode ggml_cpu_dispatch.o (build.sh compiles that one from the
# repository every run, so a dispatcher change is picked up too).
COPY whisper-dtw-median-filter.patch whisper-security-backports.patch /tmp/
RUN mkdir -p /build/whisper && cd /build/whisper \
    && git clone --quiet --depth 1 --branch v${whisper_version} https://github.com/ggml-org/whisper.cpp.git . \
    && git apply /tmp/whisper-dtw-median-filter.patch \
    && git apply /tmp/whisper-security-backports.patch \
    && grep -q 'narrow the filter instead of aborting' src/whisper.cpp \
    && cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${PREFIX} \
         -DBUILD_SHARED_LIBS=OFF -DWHISPER_STATIC=ON \
         -DGGML_NATIVE=OFF -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON \
         -DGGML_OPENMP=OFF -DGGML_VULKAN=OFF -DGGML_BLAS=OFF \
         -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_TOOLS=OFF \
    && cmake --build build -j"$(nproc)" \
    && cmake --install build \
    && cd / && rm -rf /build/whisper \
    && ls ${PREFIX}/lib/libwhisper.a ${PREFIX}/lib/libggml.a ${PREFIX}/lib/libggml-base.a ${PREFIX}/lib/libggml-cpu.a \
    && rm -f ${PREFIX}/lib/pkgconfig/whisper.pc

# The volumes run.sh mounts: /opt/nm keeps espeak-ng and the lab's whisper.pc,
# /build keeps ffmpeg's object files between runs. Both are seeded from the
# image on first use.
VOLUME ["/opt/nm", "/build"]

COPY build.sh suite.sh /lab/
RUN chmod +x /lab/build.sh /lab/suite.sh
WORKDIR /repo
CMD ["/lab/build.sh"]

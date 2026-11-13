# Create a Linux ffmpeg build
# CI pins this to the base built in the same run (BASE_TAG=<commit sha>);
# local/compose builds use the default "latest". See .github/workflows.
ARG BASE_TAG=latest

# glibc 2.35 sysroot. The Linux x86_64 build links the host's glibc
# dynamically, the way every other platform uses its system runtime, so that
# GPU drivers load into the one C runtime the process already has. The glibc
# it is compiled and linked against is therefore the oldest one it can start
# on. The base image is Ubuntu 24.04 (glibc 2.39), which would shut out
# Ubuntu 22.04 and Debian 12; compiling and linking against Ubuntu 22.04's
# glibc instead gives a 2.35 floor. The sysroot holds
# glibc and the same X development packages ffmpeg-base.dockerfile installs
# from apt (libXau and libXdmcp, which the libxcb built by 08-libdrm.sh needs
# and which no script builds); every codec, xproto, libxcb and libX11 are built
# from source by the numbered scripts, as on every platform, and their copies
# in the build prefix win over the sysroot's. The image is pinned by digest;
# apt still fetches the current jammy point release of glibc, like every
# apt-get in ffmpeg-base.dockerfile. scripts/includes/glibc235_sysroot_setup.sh
# wires the sysroot into the build below.
FROM ubuntu:22.04@sha256:076e7bf82319619f28dd0aa9c02ab34b055ad37100395b4f49a2ffba04fb5e11 AS glibc235-sysroot
RUN apt-get update >/dev/null 2>&1 \
    && apt-get install -y --no-install-recommends libc6-dev linux-libc-dev libcrypt-dev \
       libxext-dev libxau-dev libxdmcp-dev xtrans-dev xutils-dev >/dev/null 2>&1 \
    && mkdir -p /sysroot/usr \
    && cp -a /usr/include /usr/lib /usr/lib64 /sysroot/usr/ \
    && ln -s usr/lib /sysroot/lib && ln -s usr/lib64 /sysroot/lib64 \
    && rm -rf /sysroot/usr/lib/apt /sysroot/usr/lib/dpkg /sysroot/usr/lib/systemd /sysroot/usr/lib/udev /sysroot/usr/lib/python3* \
    && test "$(sed -n 's/^#define[[:space:]]*__GLIBC_MINOR__[[:space:]]*//p' /sysroot/usr/include/features.h)" = 35

FROM nomercyentertainment/ffmpeg-base:${BASE_TAG} AS linux

LABEL maintainer="Phillippe Pelzer"
LABEL version="1.0.1"
LABEL description="FFmpeg for Linux x86_64"

ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

# Update and install dependencies
RUN echo "------------------------------------------------------" \
    && echo "        _   _       __  __                      " \
    && echo "       | \ | | ___ |  \/  | ___ _ __ ___ _   _  " \
    && echo "       |  \| |/ _ \| |\/| |/ _ \ '__/ __| | | | " \
    && echo "       | |\  | (_) | |  | |  __/ | | (__| |_| | " \
    && echo "       |_| \_|\___/|_|  |_|\___|_|  \___|\__, | " \
    && echo "         _____ _____ __  __ ____  _____ _|___/  " \
    && echo "        |  ___|  ___|  \/  |  _ \| ____/ ___|   " \
    && echo "        | |_  | |_  | |\/| | |_) |  _|| |  _    " \
    && echo "        |  _| |  _| | |  | |  __/| |__| |_| |   " \
    && echo "        |_|   |_|   |_|  |_|_|   |_____\____|   " \
    && echo "" \
    && echo "------------------------------------------------------" \
    && echo "📦 Start FFmpeg for Linux x86_64 build" \
    && echo "------------------------------------------------------" \
    && echo "🔧 Start downloading and installing dependencies" \
    && echo "------------------------------------------------------"\
    && echo "🔄 Checking for updates" \
    && apt-get update >/dev/null 2>&1 \
    && echo "✅ Updating completed successfully" \
    && echo "------------------------------------------------------" \
    && echo "🔧 Installing dependencies" \
    && apt-get install -y --no-install-recommends \
    g++ gcc openjdk-11-jdk ant >/dev/null 2>&1 \
    && apt-get autoremove -y >/dev/null 2>&1 && apt-get autoclean -y >/dev/null 2>&1 && apt-get clean -y >/dev/null 2>&1 \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && echo "✅ Installations completed successfully" \
    && echo "------------------------------------------------------"

# Set environment variables for building ffmpeg
ARG BUILD_JOBS=
ENV BUILD_JOBS=${BUILD_JOBS}
ENV TARGET_OS=linux
ENV PREFIX=/ffmpeg_build/linux
ENV ARCH=x86_64
ENV CROSS_PREFIX=${ARCH}-linux-gnu-
ENV CC=${CROSS_PREFIX}gcc
ENV CXX=${CROSS_PREFIX}g++
ENV LD=${CROSS_PREFIX}ld
ENV AR=${CROSS_PREFIX}gcc-ar
ENV RANLIB=${CROSS_PREFIX}gcc-ranlib
ENV STRIP=${CROSS_PREFIX}strip
ENV NM=${CROSS_PREFIX}gcc-nm
# ENV WINDRES=${CROSS_PREFIX}windres
# ENV DLLTOOL=${CROSS_PREFIX}dlltool
ENV STAGE_CFLAGS="-fvisibility=hidden -fno-semantic-interposition"
ENV STAGE_CXXFLAGS="-fvisibility=hidden -fno-semantic-interposition"
ENV PKG_CONFIG=pkg-config
ENV PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig
ENV PATH="${PREFIX}/bin:${PATH}"
ENV CFLAGS="-static-libgcc -static-libstdc++ -I${PREFIX}/include -O2 -pipe -fPIC -DPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection -pthread"
ENV CXXFLAGS="-static-libgcc -static-libstdc++ -I${PREFIX}/include -O2 -pipe -fPIC -DPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection -pthread" 
ENV LDFLAGS="-static-libgcc -static-libstdc++ -L${PREFIX}/lib -O2 -pipe -fstack-protector-strong -fstack-clash-protection -Wl,-z,relro,-z,now -pthread -lm"

# Create Meson cross file for Linux
RUN echo "[binaries]" > /build/cross_file.txt && \
    echo "c = '${CC}'" >> /build/cross_file.txt && \
    echo "cpp = '${CXX}'" >> /build/cross_file.txt && \
    echo "ld = '${LD}'" >> /build/cross_file.txt && \
    echo "ar = '${AR}'" >> /build/cross_file.txt && \
    echo "ranlib = '${RANLIB}'" >> /build/cross_file.txt && \
    echo "strip = '${STRIP}'" >> /build/cross_file.txt && \
    echo "pkgconfig = '${PKG_CONFIG}'" >> /build/cross_file.txt && \
    echo "pkg-config = '${PKG_CONFIG}'" >> /build/cross_file.txt && \
    echo "" >> /build/cross_file.txt && \
    echo "[host_machine]" >> /build/cross_file.txt && \
    echo "system = 'linux'" >> /build/cross_file.txt && \
    echo "cpu_family = '${ARCH}'" >> /build/cross_file.txt && \
    echo "cpu = '${ARCH}'" >> /build/cross_file.txt && \
    echo "endian = 'little'" >> /build/cross_file.txt

ENV CMAKE_COMMON_ARG="-DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=${ARCH} -DCMAKE_C_COMPILER=${CC} -DCMAKE_CXX_COMPILER=${CXX} -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release"

# Create the build directory
RUN mkdir -p ${PREFIX}

ENV FFMPEG_ENABLES="" \
    FFMPEG_CFLAGS="" \
    FFMPEG_LDFLAGS="" \
    FFMPEG_EXTRA_LIBFLAGS=""

# Copy the build scripts
COPY ./scripts /scripts

# Convert Windows line endings to Unix line endings
RUN find /scripts -type f -name "*.sh" -exec sed -i 's/\r$//' {} +

# Compile and link everything against the glibc 2.35 sysroot. The script
# writes compiler wrappers into /usr/local/bin, adds the four symbols gcc 13's
# static runtimes need to the sysroot's libc_nonshared.a, and proves with a
# C++/OpenMP probe that a program links, runs and imports nothing above
# GLIBC_2.35, before the first dependency builds.
COPY --from=glibc235-sysroot /sysroot /opt/glibc235
RUN chmod +x /scripts/includes/glibc235_sysroot_setup.sh \
    && /scripts/includes/glibc235_sysroot_setup.sh /opt/glibc235

# Which release of our own filters to build, and which omnidrive ref. CI
# resolves them once per run (detect-changes) and passes the same values to
# every platform. They sit right before init.sh on purpose: a changed value
# reruns it, an unchanged one keeps the cache. Before, a new filter release
# with nothing changed in scripts/ replayed the old download from the cache
# of the last published image. Empty, as in a local build, means the
# scripts resolve the newest themselves.
ARG BEATDETECT_TAG=
ARG KEYDETECT_TAG=
ARG STEMSPLIT_TAG=
ARG OMNIDRIVE_REF=

# Initialize the build
RUN touch /build/enable.txt /build/cflags.txt /build/ldflags.txt /build/extra_libflags.txt \
    && chmod +x /scripts/init/init.sh \
    && /scripts/init/init.sh \
    || (echo "❌ FFmpeg build failed" ; exit 1)

# Copy the dev scripts
COPY ./dev /test

# Convert Windows line endings to Unix line endings
RUN find /test -type f -name "*.sh" -exec sed -i 's/\r$//' {} +

# Run the dev scripts to build dependencies
RUN chmod +x /test/init/dev.sh \
    && /test/init/dev.sh \
    || (echo "❌ FFmpeg build failed" ; exit 1)

# ffmpeg
RUN FFMPEG_ENABLES=$(cat /build/enable.txt) export FFMPEG_ENABLES \
    && LINUX_LINK_CC="${CC}" export LINUX_LINK_CC \
    && CFLAGS="${CFLAGS} $(cat /build/cflags.txt)" export CFLAGS \
    && LDFLAGS="${LDFLAGS} $(cat /build/ldflags.txt)" export LDFLAGS \
    && FFMPEG_EXTRA_LIBFLAGS="-lpthread -lm $(cat /build/extra_libflags.txt)" export FFMPEG_EXTRA_LIBFLAGS \
    && echo "------------------------------------------------------" \
    && echo "🚧 Start building FFmpeg" \
    && echo "------------------------------------------------------" \
    && cd /build/ffmpeg \
    && chmod +x /scripts/includes/linux_link.sh \
    && set -- --ld=/scripts/includes/linux_link.sh --glslc=/usr/bin/glslangValidator \
         '--extra-cflags=-static-libgcc -static-libstdc++' \
         '--extra-ldflags=-static-libgcc -static-libstdc++' \
    && echo "⚙️ Configure FFmpeg                              [1/2]" \
    && ./configure --pkg-config-flags=--static \
    --arch=${ARCH} \
    --target-os=${TARGET_OS} \
    --cross-prefix=${CROSS_PREFIX} \
    --pkg-config=pkg-config \
    --prefix=${PREFIX} \
    --enable-cross-compile \
    --disable-shared \
    --enable-ffplay \
    --enable-static \
    --enable-gpl \
    --enable-version3 \
    --enable-nonfree \
    ${FFMPEG_ENABLES} \
    --enable-filter=all \
    --enable-runtime-cpudetect \
    --extra-version="NoMercy-MediaServer" \
    "$@" \
    --extra-libs="${FFMPEG_EXTRA_LIBFLAGS}" >/ffmpeg_build.log 2>&1 \
    || (cat "/ffmpeg_build.log" ; echo "--- last 200 lines of ffbuild/config.log (compiler and linker errors) ---" ; tail -200 "/build/ffmpeg/ffbuild/config.log" 2>/dev/null ; echo "❌ FFmpeg build failed" ; false) \
    && for feature in VULKAN LIBPLACEBO CUDA; do \
         grep -q "^#define CONFIG_${feature} 1$" config.h \
           || { echo "Required hardware feature is disabled: ${feature}"; exit 1; }; \
       done \
    && for feature in SCALE_VULKAN_FILTER LIBPLACEBO_FILTER H264_NVENC_ENCODER \
         HEVC_NVENC_ENCODER H264_NVDEC_HWACCEL; do \
         grep -q "^#define CONFIG_${feature} 1$" config_components.h \
           || { echo "Required hardware component is disabled: ${feature}"; exit 1; }; \
       done \
    && for feature in WHISPER_FILTER STEMSPLIT_FILTER; do \
         grep -q "^#define CONFIG_${feature} 1$" config_components.h \
           || { echo "Required filter is disabled: ${feature}"; exit 1; }; \
       done \
    && { grep -q '^#define CONFIG_VULKAN_1_4 1$' config.h \
           || { echo "Required Vulkan 1.4 support is disabled"; exit 1; }; } \
    && for feature in H264_VULKAN_HWACCEL HEVC_VULKAN_HWACCEL AV1_VULKAN_HWACCEL \
         VP9_VULKAN_HWACCEL AV1_VULKAN_ENCODER; do \
         grep -q "^#define CONFIG_${feature} 1$" config_components.h \
           || { echo "Required Vulkan component is disabled: ${feature}"; exit 1; }; \
       done \
    && echo "🛠️ Building FFmpeg                               [2/2]" \
    && make -j${BUILD_JOBS:-$(nproc)} >/ffmpeg_build.log 2>&1 || (cat "/ffmpeg_build.log" ; cat "/build/ffmpeg/ffbuild/config.log" ; echo "❌ FFmpeg build failed" ; exit 1) \
    && echo "🔎 Verifying ggml CPU variants survived the link" \
    && bash /scripts/includes/verify_ggml_cpu_link.sh \
    && bash /scripts/includes/verify_linux_runtime.sh hardware \
    && make install >/dev/null 2>&1 \
    && rm -rf /build/ffmpeg \
    && echo "------------------------------------------------------" \
    && echo "✅ FFmpeg was built successfully" \
    && echo "------------------------------------------------------" 

RUN chmod +x /scripts/init/package.sh && /scripts/init/package.sh \
    && tar -tzf /output/ffmpeg-*-linux-x86_64.tar.gz >/tmp/archive-files.txt \
    && ! grep -E '\.so($|[./])' /tmp/archive-files.txt

FROM alpine:latest AS final

# Take the Alpine branch's current package fixes. alpine:latest is only
# rebuilt now and then, so its zlib can lag behind a published fix (Trivy
# flagged CVE-2026-4738 on every v1.0.46 image: zlib 1.3.2-r1 while 3.24
# already shipped 1.4-r0). The upgrade keeps the image at what the branch
# has fixed on the day it is built.
RUN apk upgrade --no-cache

# The archive is named after ffmpeg_version in ffmpeg-base.dockerfile
# (scripts/init/package.sh builds the name). It used to be spelled out
# here as well, so a version bump that missed this line broke the build
# at the very last step. The glob takes whatever version the build
# produced. A wildcard COPY that matches nothing still succeeds, so the
# RUN below insists on exactly one archive: none, or a stale second one
# from another version, stops the build here.
COPY --from=linux /output/ffmpeg-*-linux-x86_64.tar.gz /build/
RUN set -- /build/ffmpeg-*-linux-x86_64.tar.gz && [ "$#" -eq 1 ] && [ -f "$1" ] \
    || { echo "expected exactly one ffmpeg archive, found: $*" >&2; exit 1; }

CMD ["sh", "-c", "cp /build/ffmpeg-*-linux-x86_64.tar.gz /output"]

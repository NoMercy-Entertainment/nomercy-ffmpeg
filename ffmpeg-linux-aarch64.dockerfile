# Create an Aarch64 ffmpeg build
FROM nomercyentertainment/ffmpeg-base AS linux

LABEL maintainer="Phillippe Pelzer"
LABEL version="1.0.1"
LABEL description="FFmpeg for Linux Aarch64"

ARG DEBUG=0
ENV DEBUG=${DEBUG}

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
    && echo "📦 Start FFmpeg for Linux aarch64 build" \
    && echo "------------------------------------------------------" \
    && echo "🔧 Start downloading and installing dependencies" \
    && echo "------------------------------------------------------"\
    && echo "🔄 Checking for updates" \
    && apt-get update >/dev/null 2>&1 \
    && echo "✅ Updating completed successfully" \
    && echo "------------------------------------------------------" \
    && echo "🔧 Installing dependencies" \
    && apt-get install -y --no-install-recommends \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu libgit2-dev openjdk-11-jdk ant >/dev/null 2>&1 \
    && apt-get upgrade -y >/dev/null 2>&1 && apt-get autoremove -y >/dev/null 2>&1 && apt-get autoclean -y >/dev/null 2>&1 && apt-get clean -y >/dev/null 2>&1 \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && echo "✅ Installations completed successfully" \
    && echo "------------------------------------------------------"

# Install Rust and Cargo
RUN echo "------------------------------------------------------" \
    && echo "🔄 Start installing Rust and Cargo" \
    && rustup target add aarch64-unknown-linux-gnu >/dev/null 2>&1 \
    && cargo install cargo-c >/dev/null 2>&1 \
    && echo "✅ Installations completed successfully" \
    && echo "------------------------------------------------------"

RUN cd /build

# Set environment variables for building ffmpeg
ENV TARGET_OS=linux
ENV PREFIX=/ffmpeg_build/aarch64
ENV ARCH=aarch64
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

# Create the build directory
RUN mkdir -p ${PREFIX}

# Create Meson cross file for aarch64
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


# ══════════════════════════════════════════════════════════════
# Per-dependency cached build layers
#
# Each script gets its own COPY+RUN so Docker can cache individual
# dependency builds. Changing one script only invalidates that
# layer and everything after it — earlier deps stay cached.
# ══════════════════════════════════════════════════════════════

# ── Build infrastructure (helpers, platform includes, C sources)
COPY ./scripts/init/ /scripts/init/
COPY ./scripts/includes/ /scripts/includes/
RUN find /scripts -type f -name "*.sh" -exec sed -i 's/\r$//' {} + \
    && chmod +x /scripts/init/*.sh \
    && mkdir -p ${PREFIX}/lib ${PREFIX}/lib/pkgconfig ${PREFIX}/include ${PREFIX}/bin \
    && touch /build/enable.txt /build/cflags.txt /build/ldflags.txt /build/extra_libflags.txt

# ── Dependency build steps ─────────────────────────────────

COPY ./scripts/01-iconv.sh /scripts/01-iconv.sh
RUN /scripts/init/run-step.sh 01-iconv.sh

COPY ./scripts/02-libxml2.sh /scripts/02-libxml2.sh
RUN /scripts/init/run-step.sh 02-libxml2.sh

COPY ./scripts/03-zlib.sh /scripts/03-zlib.sh
RUN /scripts/init/run-step.sh 03-zlib.sh

COPY ./scripts/04-fftw3.sh /scripts/04-fftw3.sh
RUN /scripts/init/run-step.sh 04-fftw3.sh

COPY ./scripts/05-libfreetype.sh /scripts/05-libfreetype.sh
RUN /scripts/init/run-step.sh 05-libfreetype.sh

COPY ./scripts/06-libfribidi.sh /scripts/06-libfribidi.sh
RUN /scripts/init/run-step.sh 06-libfribidi.sh

COPY ./scripts/07-libogg.sh /scripts/07-libogg.sh
RUN /scripts/init/run-step.sh 07-libogg.sh

COPY ./scripts/08-libdrm.sh /scripts/08-libdrm.sh
RUN /scripts/init/run-step.sh 08-libdrm.sh

COPY ./scripts/08-openssl.sh /scripts/08-openssl.sh
RUN /scripts/init/run-step.sh 08-openssl.sh

COPY ./scripts/09-fontconfig.sh /scripts/09-fontconfig.sh
RUN /scripts/init/run-step.sh 09-fontconfig.sh

COPY ./scripts/10-libharfbuzz.sh /scripts/10-libharfbuzz.sh
RUN /scripts/init/run-step.sh 10-libharfbuzz.sh

COPY ./scripts/11-libudfread.sh /scripts/11-libudfread.sh
RUN /scripts/init/run-step.sh 11-libudfread.sh

COPY ./scripts/12-libvorbis.sh /scripts/12-libvorbis.sh
RUN /scripts/init/run-step.sh 12-libvorbis.sh

COPY ./scripts/13-libvmaf.sh /scripts/13-libvmaf.sh
RUN /scripts/init/run-step.sh 13-libvmaf.sh

COPY ./scripts/14-avisynth.sh /scripts/14-avisynth.sh
RUN /scripts/init/run-step.sh 14-avisynth.sh

COPY ./scripts/15-chromaprint.sh /scripts/15-chromaprint.sh
RUN /scripts/init/run-step.sh 15-chromaprint.sh

COPY ./scripts/16-libass.sh /scripts/16-libass.sh
RUN /scripts/init/run-step.sh 16-libass.sh

COPY ./scripts/16-libva.sh /scripts/16-libva.sh
RUN /scripts/init/run-step.sh 16-libva.sh

COPY ./scripts/17-libbluray.sh /scripts/17-libbluray.sh
RUN /scripts/init/run-step.sh 17-libbluray.sh

COPY ./scripts/17-libdvdread.sh /scripts/17-libdvdread.sh
RUN /scripts/init/run-step.sh 17-libdvdread.sh

COPY ./scripts/18-libcdio.sh /scripts/18-libcdio.sh
RUN /scripts/init/run-step.sh 18-libcdio.sh

COPY ./scripts/19-libdav1d.sh /scripts/19-libdav1d.sh
RUN /scripts/init/run-step.sh 19-libdav1d.sh

COPY ./scripts/20-libdavs2.sh /scripts/20-libdavs2.sh
RUN /scripts/init/run-step.sh 20-libdavs2.sh

COPY ./scripts/21-librav1e.sh /scripts/21-librav1e.sh
RUN /scripts/init/run-step.sh 21-librav1e.sh

COPY ./scripts/22-libsrt.sh /scripts/22-libsrt.sh
RUN /scripts/init/run-step.sh 22-libsrt.sh

COPY ./scripts/23-twolame.sh /scripts/23-twolame.sh
RUN /scripts/init/run-step.sh 23-twolame.sh

COPY ./scripts/24-mp3lame.sh /scripts/24-mp3lame.sh
RUN /scripts/init/run-step.sh 24-mp3lame.sh

COPY ./scripts/25-fdk-aac.sh /scripts/25-fdk-aac.sh
RUN /scripts/init/run-step.sh 25-fdk-aac.sh

COPY ./scripts/26-libopus.sh /scripts/26-libopus.sh
RUN /scripts/init/run-step.sh 26-libopus.sh

COPY ./scripts/27-libaom.sh /scripts/27-libaom.sh
RUN /scripts/init/run-step.sh 27-libaom.sh

COPY ./scripts/28-libtheora.sh /scripts/28-libtheora.sh
RUN /scripts/init/run-step.sh 28-libtheora.sh

COPY ./scripts/29-libsvtav1.sh /scripts/29-libsvtav1.sh
RUN /scripts/init/run-step.sh 29-libsvtav1.sh

COPY ./scripts/30-libvpx.sh /scripts/30-libvpx.sh
RUN /scripts/init/run-step.sh 30-libvpx.sh

COPY ./scripts/31-x264.sh /scripts/31-x264.sh
RUN /scripts/init/run-step.sh 31-x264.sh

COPY ./scripts/32-x265.sh /scripts/32-x265.sh
RUN /scripts/init/run-step.sh 32-x265.sh

COPY ./scripts/33-xavs2.sh /scripts/33-xavs2.sh
RUN /scripts/init/run-step.sh 33-xavs2.sh

COPY ./scripts/34-xvid.sh /scripts/34-xvid.sh
RUN /scripts/init/run-step.sh 34-xvid.sh

COPY ./scripts/35-openjpeg.sh /scripts/35-openjpeg.sh
RUN /scripts/init/run-step.sh 35-openjpeg.sh

COPY ./scripts/36-libwebp.sh /scripts/36-libwebp.sh
RUN /scripts/init/run-step.sh 36-libwebp.sh

COPY ./scripts/37-zimg.sh /scripts/37-zimg.sh
RUN /scripts/init/run-step.sh 37-zimg.sh

COPY ./scripts/38-frei0r.sh /scripts/38-frei0r.sh
RUN /scripts/init/run-step.sh 38-frei0r.sh

COPY ./scripts/39-libvpl.sh /scripts/39-libvpl.sh
RUN /scripts/init/run-step.sh 39-libvpl.sh

COPY ./scripts/40-amf.sh /scripts/40-amf.sh
RUN /scripts/init/run-step.sh 40-amf.sh

COPY ./scripts/41-libtesseract.sh /scripts/41-libtesseract.sh
RUN /scripts/init/run-step.sh 41-libtesseract.sh

COPY ./scripts/42-sdl2.sh /scripts/42-sdl2.sh
RUN /scripts/init/run-step.sh 42-sdl2.sh

COPY ./scripts/43-ffnvcodec.sh /scripts/43-ffnvcodec.sh
RUN /scripts/init/run-step.sh 43-ffnvcodec.sh

COPY ./scripts/44-cuda.sh /scripts/44-cuda.sh
RUN /scripts/init/run-step.sh 44-cuda.sh

COPY ./scripts/45-vulkan.sh /scripts/45-vulkan.sh
RUN /scripts/init/run-step.sh 45-vulkan.sh

COPY ./scripts/46-opencl.sh /scripts/46-opencl.sh
RUN /scripts/init/run-step.sh 46-opencl.sh

COPY ./scripts/47-dxva.sh /scripts/47-dxva.sh
RUN /scripts/init/run-step.sh 47-dxva.sh

COPY ./scripts/48-whisper.sh /scripts/48-whisper.sh
RUN /scripts/init/run-step.sh 48-whisper.sh

COPY ./scripts/49-beatdetect.sh /scripts/49-beatdetect.sh
RUN /scripts/init/run-step.sh 49-beatdetect.sh

COPY ./scripts/49-libzvbi.sh /scripts/49-libzvbi.sh
RUN /scripts/init/run-step.sh 49-libzvbi.sh

COPY ./scripts/50-librsvg.sh /scripts/50-librsvg.sh
RUN /scripts/init/run-step.sh 50-librsvg.sh

COPY ./scripts/51-vobsub-muxer.sh /scripts/51-vobsub-muxer.sh
RUN /scripts/init/run-step.sh 51-vobsub-muxer.sh

COPY ./scripts/52-ocr-subtitle-encoder.sh /scripts/52-ocr-subtitle-encoder.sh
RUN /scripts/init/run-step.sh 52-ocr-subtitle-encoder.sh

COPY ./scripts/53-sprite-sheet-muxer.sh /scripts/53-sprite-sheet-muxer.sh
RUN /scripts/init/run-step.sh 53-sprite-sheet-muxer.sh

COPY ./scripts/54-chapter-vtt-muxer.sh /scripts/54-chapter-vtt-muxer.sh
RUN /scripts/init/run-step.sh 54-chapter-vtt-muxer.sh

COPY ./scripts/55-auto-create-dirs.sh /scripts/55-auto-create-dirs.sh
RUN /scripts/init/run-step.sh 55-auto-create-dirs.sh

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
    && CFLAGS="${CFLAGS} $(cat /build/cflags.txt)" export CFLAGS \
    && LDFLAGS="${LDFLAGS} $(cat /build/ldflags.txt)" export LDFLAGS \
    && FFMPEG_EXTRA_LIBFLAGS="-lpthread -lm $(cat /build/extra_libflags.txt)" export FFMPEG_EXTRA_LIBFLAGS \
    && echo "------------------------------------------------------" \
    && echo "🚧 Start building FFmpeg" \
    && echo "------------------------------------------------------" \
    && cd /build/ffmpeg \
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
    --extra-cflags="-static -static-libgcc -static-libstdc++" \
    --extra-ldflags="-static -static-libgcc -static-libstdc++" \
    --extra-libs="${FFMPEG_EXTRA_LIBFLAGS}" >/ffmpeg_build.log 2>&1 \
    || (cat "/ffmpeg_build.log" ; echo "❌ FFmpeg build failed" ; false) \
    && echo "🛠️ Building FFmpeg                               [2/2]" \
    && make -j$(nproc) >/ffmpeg_build.log 2>&1 || (cat "/ffmpeg_build.log" ; echo "❌ FFmpeg build failed" ; exit 1) && make install >/dev/null 2>&1 \
    && rm -rf /build/ffmpeg \
    && echo "------------------------------------------------------" \
    && echo "✅ FFmpeg was built successfully" \
    && echo "------------------------------------------------------"

RUN chmod +x /scripts/init/package.sh && /scripts/init/package.sh

FROM alpine:latest AS final

COPY --from=linux /build/ffmpeg-8.1-linux-aarch64.tar.gz /build/ffmpeg-8.1-linux-aarch64.tar.gz

CMD ["cp", "/build/ffmpeg-8.1-linux-aarch64.tar.gz", "/output"]

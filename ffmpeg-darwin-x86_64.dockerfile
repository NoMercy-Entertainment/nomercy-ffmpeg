# Create a macOS ffmpeg build
FROM nomercyentertainment/ffmpeg-base AS darwin

LABEL maintainer="Phillippe Pelzer"
LABEL version="1.0.1"
LABEL description="FFmpeg for Darwin x86_64"

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
    && echo "📦 Start FFmpeg for Darwin x86_64 build" \
    && echo "------------------------------------------------------" \
    && echo "🔧 Start downloading and installing dependencies" \
    && echo "------------------------------------------------------"\
    && echo "🔄 Checking for updates" \
    && apt-get update >/dev/null 2>&1 \
    && echo "✅ Updating completed successfully" \
    && echo "------------------------------------------------------" \
    && echo "🔧 Installing dependencies" \
    && apt-get install -y --no-install-recommends \
    clang patch liblzma-dev libxml2-dev xz-utils bzip2 cpio zlib1g-dev libgit2-dev openjdk-11-jdk ant >/dev/null 2>&1 \
    && apt-get upgrade -y >/dev/null 2>&1 && apt-get autoremove -y >/dev/null 2>&1 && apt-get autoclean -y >/dev/null 2>&1 && apt-get clean -y >/dev/null 2>&1 \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && echo "✅ Installations completed successfully" \
    && echo "------------------------------------------------------"

# Install Rust and Cargo
RUN echo "------------------------------------------------------" \
    && echo "🔄 Start installing Rust and Cargo" \
    && rustup target add x86_64-apple-darwin >/dev/null 2>&1 \
    && cargo install cargo-c >/dev/null 2>&1 \
    && echo "✅ Installations completed successfully" \
    && echo "------------------------------------------------------"

# Install rcodesign for ad-hoc code signing of cross-compiled Mach-O binaries
# Required because: ld64 signs during linking, but strip invalidates the signature.
# Future macOS versions may enforce signing for x86_64 too.
# rcodesign (apple-codesign) produces proper code directory signatures that
# satisfy macOS kernel enforcement, unlike ldid which produces invalid
# signatures for ARM64 binaries when run from Linux.
RUN echo "------------------------------------------------------" \
    && echo "🔏 Installing rcodesign for Mach-O code signing" \
    && cargo install apple-codesign >/dev/null 2>&1 \
    && echo "✅ rcodesign installed successfully" \
    && echo "------------------------------------------------------"

ENV PREFIX=/ffmpeg_build/darwin
ENV MACOSX_DEPLOYMENT_TARGET=10.13.0
ENV SDK_VERSION=15.1
ENV SDK_PATH=${PREFIX}/osxcross/SDK/MacOSX${SDK_VERSION}.sdk
ENV OSX_FRAMEWORKS=${SDK_PATH}/System/Library/Frameworks

RUN echo "------------------------------------------------------" \
    && echo "🔧 Start building macOS SDK" \
    && git clone https://github.com/tpoechtrager/osxcross.git /build/osxcross >/dev/null 2>&1 && cd /build/osxcross \
    && wget -nc https://github.com/joseluisq/macosx-sdks/releases/download/${SDK_VERSION}/MacOSX${SDK_VERSION}.sdk.tar.xz >/dev/null 2>&1 \
    && mv MacOSX${SDK_VERSION}.sdk.tar.xz tarballs/MacOSX${SDK_VERSION}.sdk.tar.xz \
    && UNATTENDED=1 SDK_VERSION=${SDK_VERSION} OSX_VERSION_MIN=${MACOSX_DEPLOYMENT_TARGET%.0} MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} TARGET_DIR=${PREFIX}/osxcross ./build.sh >/dev/null 2>&1 \
    && echo "✅ macOS SDK build completed successfully" \
    && echo "------------------------------------------------------" \
    && echo "MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}" > ${PREFIX}/osxcross/bin/cc_target \
    && cp ${PREFIX}/osxcross/bin/cc_target ${SDK_PATH}/usr/bin/cc_target

RUN cd /build

# Set environment variables for building ffmpeg
ENV TARGET_OS=darwin
ENV PREFIX=/ffmpeg_build/darwin
ENV ARCH=x86_64
ENV CROSS_PREFIX=${ARCH}-apple-darwin24.1-
ENV CC=${CROSS_PREFIX}clang
ENV CXX=${CROSS_PREFIX}clang++
ENV LD=${CROSS_PREFIX}ld
ENV AR=${CROSS_PREFIX}ar
ENV RANLIB=${CROSS_PREFIX}ranlib
ENV STRIP=${CROSS_PREFIX}strip
ENV NM=${CROSS_PREFIX}nm
# ENV WINDRES=${CROSS_PREFIX}windres
# ENV DLLTOOL=${CROSS_PREFIX}dlltool
ENV PKG_CONFIG=pkg-config
ENV PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig
ENV PATH="${PREFIX}/bin:${SDK_PATH}/usr/bin:${PREFIX}/osxcross/bin:${PATH}"
ENV CFLAGS="-arch ${ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot ${SDK_PATH} -F${OSX_FRAMEWORKS} -I${SDK_PATH}/usr/include -stdlib=libc++ -I${PREFIX}/include -O2 -pipe -fPIC -DPIC -pthread"
ENV CXXFLAGS="-arch ${ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot ${SDK_PATH} -F${OSX_FRAMEWORKS} -I${SDK_PATH}/usr/include -stdlib=libc++ -I${PREFIX}/include -O2 -pipe -fPIC -DPIC -pthread"
ENV LDFLAGS="-arch ${ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot ${SDK_PATH} -F${OSX_FRAMEWORKS} -framework CoreFoundation -framework CoreVideo -framework IOSurface -framework VideoToolbox -framework OpenCL -framework Accelerate -framework DiskArbitration -framework IOKit -L${SDK_PATH}/usr/lib -stdlib=libc++ -L${PREFIX}/lib -Wl,-dead_strip_dylibs -pthread"

ENV CARGO_TARGET_X86_64_APPLE_DARWIN_LINKER=${CC}

# Create Meson cross file for darwin
RUN echo "[constants]" > /build/cross_file.txt && \
    echo "osx_sdk_version = '${MACOSX_DEPLOYMENT_TARGET}'" >> /build/cross_file.txt && \
    echo "osx_arch = '${ARCH}'" >> /build/cross_file.txt && \
    echo "" >> /build/cross_file.txt && \
    echo "[binaries]" >> /build/cross_file.txt && \
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
    echo "system = 'darwin'" >> /build/cross_file.txt && \
    echo "cpu_family = '${ARCH}'" >> /build/cross_file.txt && \
    echo "cpu = '${ARCH}'" >> /build/cross_file.txt && \
    echo "endian = 'little'" >> /build/cross_file.txt && \
    echo "" >> /build/cross_file.txt && \
    echo "[properties]" >> /build/cross_file.txt && \
    echo "c_args = ['-arch', '${ARCH}', '-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}', '-isysroot', '${SDK_PATH}', '-F${OSX_FRAMEWORKS}', '-I${SDK_PATH}/usr/include', '-stdlib=libc++', '-I${PREFIX}/include', '-O2', '-pipe', '-fPIC', '-DPIC', '-pthread']" >> /build/cross_file.txt && \
    echo "cpp_args = ['-arch', '${ARCH}', '-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}', '-isysroot', '${SDK_PATH}', '-F${OSX_FRAMEWORKS}', '-I${SDK_PATH}/usr/include', '-stdlib=libc++', '-I${PREFIX}/include', '-O2', '-pipe', '-fPIC', '-DPIC', '-pthread']" >> /build/cross_file.txt && \
    echo "c_link_args = ['-arch', '${ARCH}', '-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}', '-isysroot', '${SDK_PATH}', '-F${OSX_FRAMEWORKS} -framework CoreFoundation -framework CoreVideo -framework IOSurface -framework VideoToolbox -framework OpenCL -framework Accelerate -framework DiskArbitration -framework IOKit', '-L${SDK_PATH}/usr/lib', '-stdlib=libc++', '-L${PREFIX}/lib', '-Wl,-dead_strip_dylibs', '-pthread']" >> /build/cross_file.txt && \
    echo "cpp_link_args = ['-arch', '${ARCH}', '-mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}', '-isysroot', '${SDK_PATH}', '-F${OSX_FRAMEWORKS} -framework CoreFoundation -framework CoreVideo -framework IOSurface -framework VideoToolbox -framework OpenCL -framework Accelerate -framework DiskArbitration -framework IOKit', '-L${SDK_PATH}/usr/lib', '-stdlib=libc++', '-L${PREFIX}/lib', '-Wl,-dead_strip_dylibs', '-pthread']" >> /build/cross_file.txt

# CMake common arguments for static build
ENV CMAKE_COMMON_ARG="-DCMAKE_INSTALL_PREFIX=${PREFIX} -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_OSX_ARCHITECTURES=${ARCH} -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} -DCMAKE_OSX_SYSROOT=${SDK_PATH} -DCMAKE_C_COMPILER=${CC} -DCMAKE_CXX_COMPILER=${CXX} -DENABLE_SHARED=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release"

RUN ln -s ${PREFIX}/osxcross/bin/${CROSS_PREFIX}install_name_tool ${SDK_PATH}/usr/bin/${CROSS_PREFIX}install_name_tool \
    && chmod +x ${SDK_PATH}/usr/bin/${CROSS_PREFIX}install_name_tool \
    && ln -s ${PREFIX}/osxcross/bin/${CROSS_PREFIX}otool ${SDK_PATH}/usr/bin/${CROSS_PREFIX}otool \
    && chmod +x ${SDK_PATH}/usr/bin/${CROSS_PREFIX}otool \
    && ln -s /build/osxcross/build/apple-libtapi/build/tools/llvm-objdump ${SDK_PATH}/usr/bin/${CROSS_PREFIX}objdump \
    && chmod +x ${SDK_PATH}/usr/bin/${CROSS_PREFIX}objdump \
    && ln -s /build/osxcross/build/apple-libtapi/build/tools/llvm-objcopy ${SDK_PATH}/usr/bin/${CROSS_PREFIX}objcopy \
    && chmod +x ${SDK_PATH}/usr/bin/${CROSS_PREFIX}objcopy \
    && ln -s ${CROSS_PREFIX}libtool /usr/bin/libtool \
    && mkdir -p /System/Library/Frameworks \
    && ln -s ${OSX_FRAMEWORKS}/System/Library/Frameworks /System/Library/Frameworks

ENV INSTALL_NAME_TOOL=${SDK_PATH}/usr/bin/${CROSS_PREFIX}install_name_tool
ENV OBJDUMP=${SDK_PATH}/usr/bin/${CROSS_PREFIX}objdump
ENV OBJCOPY=${SDK_PATH}/usr/bin/${CROSS_PREFIX}objcopy
ENV OTOOL=${SDK_PATH}/usr/bin/${CROSS_PREFIX}otool

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

# ── Darwin: platform version helper ──────────────────────────
COPY ./scripts/includes/darwin/00-platformversion.sh /scripts/00-platformversion.sh
RUN /scripts/init/run-step.sh 00-platformversion.sh

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

# Darwin: platform-specific librsvg (replaces default)
COPY ./scripts/includes/darwin/50-librsvg.sh /scripts/50-librsvg.sh
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
    && MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET%.0} export MACOSX_DEPLOYMENT_TARGET \
    && echo "------------------------------------------------------" \
    && echo "🚧 Start building FFmpeg" \
    && echo "------------------------------------------------------" \
    && cd /build/ffmpeg \
    && echo "⚙️ Configure FFmpeg                              [1/2]" \
    && ./configure --pkg-config-flags=--static \
    --arch=${ARCH} \
    --target-os=darwin \
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
    --cc=${CC} \
    --cxx=${CXX} \
    --extra-version="NoMercy-MediaServer" \
    --extra-cflags="-arch ${ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}" \
    --extra-ldflags="-arch ${ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}" \
    --extra-libs="${FFMPEG_EXTRA_LIBFLAGS}" >/ffmpeg_build.log 2>&1 \
    || (cat "/ffmpeg_build.log" ; cat "ffbuild/config.log" ; echo "❌ FFmpeg build failed" ; false) \
    && echo "🛠️ Building FFmpeg                               [2/2]" \
    && make -j$(nproc) >/ffmpeg_build.log 2>&1 || (cat "/ffmpeg_build.log" ; echo "❌ FFmpeg build failed" ; exit 1) && make install >/dev/null 2>&1 \
    && rm -rf /build/ffmpeg \
    && echo "------------------------------------------------------" \
    && echo "✅ FFmpeg was built successfully" \
    && echo "------------------------------------------------------" 

RUN chmod +x /scripts/init/package.sh && /scripts/init/package.sh

FROM alpine:latest AS final

COPY --from=darwin /output/ffmpeg-8.0-darwin-x86_64.tar.gz /build/ffmpeg-8.0-darwin-x86_64.tar.gz

CMD ["cp", "/build/ffmpeg-8.0-darwin-x86_64.tar.gz", "/output"]

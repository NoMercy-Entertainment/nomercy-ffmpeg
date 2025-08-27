FROM nvidia/cuda:12.6.3-devel-ubuntu24.04 AS ffmpeg-base

LABEL maintainer="Phillippe Pelzer"
LABEL version="1.0.0"
LABEL description="Cross-compile FFmpeg for Windows, Linux, Darwin"

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video

ENV ffmpeg_version=8.0 \
    iconv_version=1.18 \
    libxml2_version=2.13 \
    zlib_version=1.3.1 \
    fftw3_version=3.3.10 \
    freetype_version=2-13-3 \
    fribidi_version=1.0.16 \
    libogg_version=1.3.5 \
    openssl_version=3.4.0 \
    fontconfig_version=2.16.1 \
    libpciaccess_version=0.18.1 \
    xcbproto_version=1.17.0 \
    xorgproto_version=2024.1 \
    xtranx_version=1.5.2 \
    libxcb_version=1.17.0 \
    libx11_version=1.8.10 \
    libXfixed_version=6.0.1 \
    libdrm_version=2.4.124 \
    harfbuzz_version=10.1.0 \
    vulkan_headers_version=1.4.307 \
    libudfread_version=1.1.2 \
    libvorbis_version=1.3.7 \
    libvmaf_version=3.0.0 \
    avisynth_version=3.7.3 \
    chromaprint_version=1.5.1 \
    libass_version=0.17.3 \
    libva_version=2.22.0 \
    libgpg_error_version=1.51 \
    libgcrypt_version=1.11.0 \
    libbdplus_version=0.2.0 \
    libaacs_version=0.11.1 \
    libbluray_version=1.3.4 \
    libcddb_version=1.3.2 \
    libcdio_version=master \
    libcdio_paranoia_version=2.0.2 \
    dav1d_version=1.5.0 \
    davs2_version=1.7 \
    rav1e_version=0.7.1 \
    libsrt_version=1.5.4 \
    twolame_version=0.4.0 \
    mp3lame_version=3.100 \
    fdk_aac_version=2.0.3 \
    opus_version=1.5.2 \
    libaom_version=3.11.0 \
    libtheora_version=1.1.1 \
    libvpx_version=1.15.0 \
    x264_version=stable \
    x265_version=4.0 \
    xavs2_version=1.4 \
    xvid_version=1.3.7 \
    libwebp_version=1.4.0 \
    openjpeg_version=2.5.3 \
    jpegsrc_version=9f \
    zimg_version=3.0.5 \
    frei0r_version=2.3.3 \
    libvpl_version=2.14.0 \
    libsvtav1_version=2.3.0 \
    amf_version=1.4.36 \
    nvcodec_version=12.2.72.0 \
    leptonica_version=1.85.0 \
    libtesseract_version=5.5.0 \
    sdl2_version=2.30.10 \
    shaderc_version=2024.4 \
    spirv_cross_checkout=5e7db829a37787e096a7bfbdbdf317cd6cbe5897 \
    libplacebo_version=7.349.0

# Dependencies for building ffmpeg
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
    && echo "📦 Start base build" \
    && echo "------------------------------------------------------" \
    && echo "🔧 Start downloading and installing dependencies" \
    && echo "------------------------------------------------------"\
    && echo "🔄 Checking for updates" \
    && apt-get update >/dev/null 2>&1 \
    && echo "✅ Updating completed successfully" \
    && echo "------------------------------------------------------" \
    && echo "🔧 Installing dependencies" \
    && apt-get install -y --no-install-recommends \
    apt-utils \
    autoconf \
    automake \
    autopoint \
    autotools-dev \
    bison \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    doxygen \
    fig2dev \
    flex \
    gettext \
    git \
    gperf \
    groff \
    libc6 \
    libc6-dev \
    libssl-dev \
    libtool \
    libxext-dev \
    meson \
    nasm \
    nvidia-cuda-toolkit \
    pkg-config \
    python3 \
    python3-dev \
    python3-venv \
    subversion \
    texinfo \
    wget \
    xtrans-dev \
    xutils-dev \
    yasm >/dev/null 2>&1 \
    && apt-get upgrade -y >/dev/null 2>&1 && apt-get autoremove -y >/dev/null 2>&1 && apt-get autoclean -y >/dev/null 2>&1 && apt-get clean -y >/dev/null 2>&1 \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && echo "✅ Installations completed successfully" \
    && echo "------------------------------------------------------"

RUN git config --global user.email "builder@nomercy.tv" \
    && git config --global user.name "Builder" \
    && git config --global advice.detachedHead false

# Install rust and cargo-c
ENV CARGO_HOME="/opt/cargo" RUSTUP_HOME="/opt/rustup" PATH="/opt/cargo/bin:${PATH}"
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading and installing Rust and Cargo" \
    && curl https://sh.rustup.rs -sSf | bash -s -- -y --no-modify-path >/dev/null 2>&1 \
    && cargo install cargo-c >/dev/null 2>&1 && rm -rf "${CARGO_HOME}"/registry "${CARGO_HOME}"/git \
    && echo "✅ Installations completed successfully" \
    && echo "------------------------------------------------------"

WORKDIR /build

# Download iconv
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading iconv" \
    && wget -O libiconv.tar.gz http://ftp.gnu.org/gnu/libiconv/libiconv-${iconv_version}.tar.gz >/dev/null 2>&1 \
    && tar -xvf libiconv.tar.gz >/dev/null 2>&1 && rm libiconv.tar.gz && mv libiconv-* iconv \
    # && git clone --branch v${iconv_version} https://git.savannah.gnu.org/git/libiconv.git iconv >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libxml2
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libxml2" \
    && git clone --branch ${libxml2_version} https://github.com/GNOME/libxml2.git libxml2 >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download zlib
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading zlib" \
    && git clone --branch v${zlib_version} https://github.com/madler/zlib.git zlib >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download fftw3 
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading fftw3" \
    && wget -O fftw3.tar.gz http://www.fftw.org/fftw-${fftw3_version}.tar.gz >/dev/null 2>&1 \
    && tar -xvf fftw3.tar.gz >/dev/null 2>&1 && rm fftw3.tar.gz && mv fftw-${fftw3_version} fftw3 \
    # && git clone --branch fftw-${fftw3_version} https://github.com/FFTW/fftw3.git fftw3 >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download freetype
# replace - with . for ${freetype_version}

RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading freetype" \
    && wget -O freetype.tar.gz https://download.savannah.gnu.org/releases/freetype/freetype-$(echo ${freetype_version} | tr '-' '.').tar.gz >/dev/null 2>&1 \
    && tar -xzf freetype.tar.gz >/dev/null 2>&1 && rm freetype.tar.gz && mv freetype-$(echo ${freetype_version} | tr '-' '.') freetype \
    # && git clone --branch VER-${freetype_version} https://gitlab.freedesktop.org/freetype/freetype.git freetype >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download fribidi
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading fribidi" \
    && wget https://github.com/fribidi/fribidi/releases/download/v${fribidi_version}/fribidi-${fribidi_version}.tar.xz >/dev/null 2>&1 \
    && tar -xJf fribidi-${fribidi_version}.tar.xz >/dev/null 2>&1 && rm fribidi-${fribidi_version}.tar.xz && mv fribidi-${fribidi_version} fribidi \
    # && git clone --branch v${fribidi_version} https://github.com/fribidi/fribidi.git fribidi >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libogg
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libogg" \
    && git clone --branch v${libogg_version} https://github.com/xiph/ogg.git libogg >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download openssl
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading openssl" \
    && git clone --branch openssl-${openssl_version} https://github.com/openssl/openssl.git openssl >/dev/null 2>&1 \
    && cd openssl && git submodule update --init --recursive --depth=1 >/dev/null 2>&1 && cd ..

# Download fontconfig
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading fontconfig" \
    && git clone --branch ${fontconfig_version} https://gitlab.freedesktop.org/fontconfig/fontconfig.git fontconfig >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libpciaccess
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libpciaccess" \
    && git clone --branch libpciaccess-${libpciaccess_version} https://gitlab.freedesktop.org/xorg/lib/libpciaccess.git libpciaccess >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download xcbproto
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading xcbproto" \
    && git clone --branch xcb-proto-${xcbproto_version} https://gitlab.freedesktop.org/xorg/proto/xcbproto.git xcbproto >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download xproto
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading xproto" \
    && git clone --branch xorgproto-${xorgproto_version} https://gitlab.freedesktop.org/xorg/proto/xorgproto.git xproto >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download xtrans
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading xtrans" \
    && git clone --branch xtrans-${xtranx_version} https://gitlab.freedesktop.org/xorg/lib/libxtrans.git libxtrans >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libxcb
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libxcb" \
    && git clone --branch libxcb-${libxcb_version} https://gitlab.freedesktop.org/xorg/lib/libxcb.git libxcb >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libx11
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libx11" \
    && git clone --branch libX11-${libx11_version} https://gitlab.freedesktop.org/xorg/lib/libx11.git libx11 >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libxfixes
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libxfixes" \
    && git clone --branch libXfixes-${libXfixed_version} https://gitlab.freedesktop.org/xorg/lib/libxfixes.git /build/libxfixes >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libdrm
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libdrm" \
    && git clone --branch libdrm-${libdrm_version} https://gitlab.freedesktop.org/mesa/drm.git libdrm >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download harfbuzz
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading harfbuzz" \
    && git clone --branch ${harfbuzz_version} https://github.com/harfbuzz/harfbuzz.git harfbuzz >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download vulkan-headers
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading vulkan-headers" \
    && git clone --branch v${vulkan_headers_version} https://github.com/KhronosGroup/Vulkan-Headers.git vulkan-headers >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libudfread
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libudfread" \
    && git clone --branch ${libudfread_version} https://code.videolan.org/videolan/libudfread libudfread >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libvorbis
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libvorbis" \
    && git clone --branch v${libvorbis_version} https://github.com/xiph/vorbis.git libvorbis >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libvmaf
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libvmaf" \
    && git clone --branch v${libvmaf_version} https://github.com/Netflix/vmaf.git libvmaf >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download avisynth
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading avisynth" \
    && git clone --branch v${avisynth_version} https://github.com/AviSynth/AviSynthPlus.git avisynth >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download chromaprint
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading chromaprint" \
    && git clone --branch v${chromaprint_version} https://github.com/acoustid/chromaprint.git chromaprint >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download shaderc
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading shaderc" \
    && git clone --branch v${shaderc_version} https://github.com/google/shaderc.git shaderc >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libass
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libass" \
    && git clone --branch ${libass_version} https://github.com/libass/libass.git libass >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libva
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libva" \
    && git clone --branch ${libva_version} https://github.com/intel/libva.git libva >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libgpg-error
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libgpg-error" \
    && git clone --branch libgpg-error-${libgpg_error_version} https://github.com/gpg/libgpg-error.git libgpg-error >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libgcrypt
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libgcrypt" \
    && git clone --branch libgcrypt-${libgcrypt_version} https://github.com/gpg/libgcrypt.git libgcrypt >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libbdplus
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libbdplus" \
    && git clone --branch ${libbdplus_version} https://code.videolan.org/videolan/libbdplus.git libbdplus >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libaacs
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libaacs" \
    && git clone --branch ${libaacs_version} https://code.videolan.org/videolan/libaacs.git libaacs >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libbluray
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libbluray" \
    && git clone --branch ${libbluray_version} https://code.videolan.org/videolan/libbluray.git libbluray >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libcddb
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libcddb" \
    && wget -O libcddb.tar.gz https://sourceforge.net/projects/libcddb/files/libcddb/${libcddb_version}/libcddb-${libcddb_version}.tar.gz/download >/dev/null 2>&1 \
    && tar -xvf libcddb.tar.gz >/dev/null 2>&1 && rm libcddb.tar.gz \
    && mv libcddb-* libcddb \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libcdio
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libcdio" \
    && git clone --branch ${libcdio_version} https://github.com/libcdio/libcdio.git libcdio >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libcdio-paranoia
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libcdio-paranoia" \
    && git clone --branch release-10.2+${libcdio_paranoia_version} https://github.com/libcdio/libcdio-paranoia.git libcdio-paranoia >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download dav1d
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading dav1d" \
    && git clone --branch ${dav1d_version} https://code.videolan.org/videolan/dav1d.git libdav1d >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download dav2
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading davs2" \
    && git clone --branch ${davs2_version} https://github.com/pkuvcl/davs2.git libdavs2 >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download rav1e
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading rav1e" \
    && git clone --branch v${rav1e_version} https://github.com/xiph/rav1e.git librav1e >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libsrt
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libsrt" \
    && git clone --branch v${libsrt_version} https://github.com/Haivision/srt.git libsrt >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download twolame
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading twolame" \
    && git clone --branch ${twolame_version} https://github.com/njh/twolame.git twolame >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download mp3lame
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading mp3lame" \
    && wget -O mp3lame.tar.gz https://downloads.sourceforge.net/project/lame/lame/${mp3lame_version}/lame-${mp3lame_version}.tar.gz >/dev/null 2>&1 \
    && tar -xzf mp3lame.tar.gz >/dev/null 2>&1 && rm mp3lame.tar.gz && mv lame-${mp3lame_version} lame \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download fdk-aac
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading fdk-aac" \
    && wget -O fdk-aac.tar.gz https://github.com/mstorsjo/fdk-aac/archive/v${fdk_aac_version}.tar.gz >/dev/null 2>&1 \
    && tar -xzf fdk-aac.tar.gz >/dev/null 2>&1 && rm fdk-aac.tar.gz && mv fdk-aac-* fdk-aac \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download Opus
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading opus" \
    && git clone --branch v${opus_version} https://github.com/xiph/opus.git opus >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libaom
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libaom" \
    && git clone --branch v${libaom_version} https://aomedia.googlesource.com/aom libaom >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libtheora
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libtheora" \
    && git clone --branch v${libtheora_version} https://github.com/xiph/theora.git libtheora >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libsvtav1
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libsvtav1" \
    && git clone --branch v${libsvtav1_version} https://gitlab.com/AOMediaCodec/SVT-AV1.git libsvtav1 >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libvpx
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libvpx" \
    && git clone --branch v${libvpx_version} https://chromium.googlesource.com/webm/libvpx.git libvpx >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download x264
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading x264" \
    && git clone --branch ${x264_version} https://code.videolan.org/videolan/x264.git x264 >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download x265
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading x265" \
    && git clone --branch Release_${x265_version} https://bitbucket.org/multicoreware/x265_git.git x265 >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download xavs2
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading xavs2" \
    && git clone --branch ${xavs2_version} https://github.com/pkuvcl/xavs2.git libxavs2 >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download xvidcore
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading xvidcore" \
    && wget -O xvidcore.tar.gz https://downloads.xvid.com/downloads/xvidcore-${xvid_version}.tar.gz >/dev/null 2>&1 \
    && tar -xzf xvidcore.tar.gz >/dev/null 2>&1 && rm xvidcore.tar.gz \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libwebp
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libwebp" \
    && wget -O libwebp.tar.gz https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${libwebp_version}.tar.gz >/dev/null 2>&1 \
    && tar -xzf libwebp.tar.gz >/dev/null 2>&1 && rm libwebp.tar.gz && mv libwebp-${libwebp_version} libwebp \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download openjpeg
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading openjpeg" \
    && git clone --branch v${openjpeg_version} https://github.com/uclouvain/openjpeg.git openjpeg >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------" \
    && echo "------------------------------------------------------" \
    && echo "🔄 Start downloading jpeg" \
    && wget -O jpegsrc.v${jpegsrc_version}.tar.gz https://ijg.org/files/jpegsrc.v${jpegsrc_version}.tar.gz >/dev/null 2>&1 \
    && tar -xzf jpegsrc.v${jpegsrc_version}.tar.gz >/dev/null 2>&1 && mv jpeg-${jpegsrc_version} jpeg && rm jpegsrc.v${jpegsrc_version}.tar.gz \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download zimg
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading zimg" \
    && git clone --branch release-${zimg_version} https://github.com/sekrit-twc/zimg.git zimg >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download frei0r
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading frei0r" \
    && git clone --branch v${frei0r_version} https://github.com/dyne/frei0r.git frei0r >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libvpl
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libvpl" \
    && git clone --branch v${libvpl_version} https://github.com/intel/libvpl.git libvpl >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download amf
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading amf" \
    && git clone --branch v${amf_version} https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git amf >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download ffnvcodec
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading ffnvcodec" \
    && git clone --branch n${nvcodec_version} https://github.com/FFmpeg/nv-codec-headers.git ffnvcodec >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download giflib
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading giflib" \
    && wget -O giflib-5.2.2.tar.gz https://sourceforge.net/projects/giflib/files/giflib-5.2.2.tar.gz/download >/dev/null 2>&1 \
    && tar -xvzf giflib-5.2.2.tar.gz >/dev/null 2>&1 && mv giflib-5.2.2 giflib && rm giflib-5.2.2.tar.gz \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libpng
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libpng" \
    && wget https://download.sourceforge.net/libpng/libpng-1.6.47.tar.gz >/dev/null 2>&1 \
    && tar -xvf libpng-1.6.47.tar.gz >/dev/null 2>&1 && mv libpng-1.6.47 libpng && rm -f libpng-1.6.47.tar.gz \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libjpeg-turbo
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libjpeg-turbo" \
    && git clone --branch 3.1.0 https://github.com/libjpeg-turbo/libjpeg-turbo.git /build/libjpeg-turbo >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libtiff
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libtiff" \
    && git clone --branch v4.7.0 https://gitlab.com/libtiff/libtiff.git /build/libtiff >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download leptonica
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading leptonica" \
    && git clone --branch ${leptonica_version} https://github.com/DanBloomberg/leptonica.git leptonica >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libtesseract (for OCR)
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libtesseract" \
    && git clone --branch ${libtesseract_version} https://github.com/tesseract-ocr/tesseract.git libtesseract >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download SDL2
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading SDL2" \
    && git clone --branch release-${sdl2_version} https://github.com/libsdl-org/SDL.git sdl2 >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download spirv-cross
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading spirv-cross" \
    && git clone https://github.com/KhronosGroup/SPIRV-Cross.git spirv-cross >/dev/null 2>&1 \
    && cd spirv-cross && git checkout ${spirv_cross_checkout} >/dev/null 2>&1 && cd .. \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download libplacebo
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading libplacebo" \
    && git clone --branch release https://code.videolan.org/videolan/libplacebo.git libplacebo >/dev/null 2>&1 \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

# Download ffmpeg
RUN \
    echo "------------------------------------------------------" \
    && echo "🔄 Start downloading FFmpeg" \
    && wget -O ffmpeg.tar.bz2 https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.bz2 >/dev/null 2>&1 \
    && tar -xjf ffmpeg.tar.bz2 >/dev/null 2>&1 && rm ffmpeg.tar.bz2 && mv ffmpeg-${ffmpeg_version} ffmpeg \
    && echo "✅ Download completed successfully" \
    && echo "------------------------------------------------------"

RUN mkdir -p /output

WORKDIR /

RUN echo "------------------------------------------------------" \
    && echo "📦 Base build completed successfully" \
    && echo "------------------------------------------------------"


CMD ["rm", "-f", "/output/*.tar.gz"]

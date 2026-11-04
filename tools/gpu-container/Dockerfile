# A Linux/WSL2 GPU validation image, not a FreeBSD runtime.
ARG BUILDER_IMAGE=nomercyentertainment/ffmpeg-base:latest
ARG RUNTIME_IMAGE=ubuntu:24.04
FROM ${BUILDER_IMAGE} AS dozen
ARG DEBIAN_FRONTEND=noninteractive
ARG MESA_VERSION=25.0.7
# Published by Mesa: https://docs.mesa3d.org/relnotes/25.0.7.html
ARG MESA_SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
ARG DXHEADERS_REV=48a762973271c5a75869946bf1fdbc489a628a5c
RUN python3 -m pip install --no-cache-dir --break-system-packages \
    Mako==1.3.10 PyYAML==6.0.2 packaging==24.2 ply==3.11
WORKDIR /build
RUN git clone --depth 1 --branch v1.614.1 https://github.com/microsoft/DirectX-Headers.git \
    && test "$(git -C DirectX-Headers rev-parse HEAD)" = "${DXHEADERS_REV}" \
    && cmake -S DirectX-Headers -B dx-build -DCMAKE_BUILD_TYPE=Release \
       -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_TESTING=OFF \
       -DDXHEADERS_BUILD_TEST=OFF -DDXHEADERS_BUILD_GOOGLE_TEST=OFF \
    && cmake --build dx-build --parallel 2 && cmake --install dx-build
RUN apt-get update && apt-get install -y --no-install-recommends libdrm-dev libzstd-dev \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL --retry 3 "https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz" -o mesa.tar.xz \
    && echo "${MESA_SHA256}  mesa.tar.xz" | sha256sum -c - \
    && tar -xJf mesa.tar.xz && rm mesa.tar.xz
RUN meson setup mesa-build "mesa-${MESA_VERSION}" --prefix=/opt/dozen --libdir=lib \
       --buildtype=release -Dplatforms=[] -Dgallium-drivers=[] \
       -Dc_args=-I/usr/local/include/wsl/stubs -Dcpp_args=-I/usr/local/include/wsl/stubs \
       -Dvulkan-drivers=microsoft-experimental -Dllvm=disabled \
       -Dmicrosoft-clc=disabled -Dopengl=false -Dglx=disabled \
       -Degl=disabled -Dgbm=disabled -Dgles1=disabled -Dgles2=disabled \
       -Dbuild-tests=false -Dvalgrind=disabled -Dlibunwind=disabled \
    && meson compile -C mesa-build -j 2 && meson install -C mesa-build

FROM ${BUILDER_IMAGE} AS ffmpeg-control
RUN make -C /build/ffnvcodec PREFIX=/opt/control install
RUN cd /build/ffmpeg \
    && PKG_CONFIG_PATH=/opt/control/lib/pkgconfig ./configure \
       --disable-everything --disable-autodetect --disable-doc --disable-debug --disable-x86asm \
       --disable-ffplay --disable-ffprobe --enable-ffmpeg --enable-indev=lavfi \
       --enable-protocol=file,pipe --enable-muxer=h264,rawvideo \
       --enable-decoder=wrapped_avframe --enable-encoder=rawvideo,h264_nvenc \
       --enable-filter=testsrc2,format,scale,hwupload,hwdownload,scale_vulkan \
       --enable-vulkan --enable-ffnvcodec --enable-nvenc \
       --glslc=/usr/bin/glslangValidator \
       --extra-cflags=-I/build/vulkan-headers/include \
    && make -j2 ffmpeg && strip ffmpeg && mkdir -p /opt/control/bin \
    && cp ffmpeg /opt/control/bin/ffmpeg-control

FROM ${RUNTIME_IMAGE} AS runtime
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    libvulkan1 vulkan-tools libdrm2 libexpat1 libzstd1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
RUN if ! command -v python3 >/dev/null; then \
       apt-get update && apt-get install -y --no-install-recommends python3 \
       && rm -rf /var/lib/apt/lists/*; \
    fi
COPY --from=dozen /opt/dozen /opt/dozen
COPY --from=ffmpeg-control /opt/control/bin/ffmpeg-control /usr/local/bin/ffmpeg-control
COPY probe.py /tools/probe.py
ENV VK_DRIVER_FILES=/opt/dozen/share/vulkan/icd.d/dzn_icd.x86_64.json \
    VK_ICD_FILENAMES=/opt/dozen/share/vulkan/icd.d/dzn_icd.x86_64.json \
    LD_LIBRARY_PATH=/usr/lib/wsl/lib:/opt/dozen/lib \
    NVIDIA_DRIVER_CAPABILITIES=all \
    XDG_RUNTIME_DIR=/tmp/nm-gpu-runtime
ENTRYPOINT ["python3", "/tools/probe.py"]

#!/bin/bash

CONFIG_ARG="-DSDL_SHARED=OFF \
            -DSDL_STATIC=ON \
            -DSDL_STATIC_PIC=ON \
            -DSDL_PULSEAUDIO=OFF \
            -DSDL_PULSEAUDIO_SHARED=OFF"

if [[ ${TARGET_OS} == "linux" && ${ARCH} == "x86_64" ]]; then
    # xxf86vm
    git clone --branch libXxf86vm-1.1.6 https://gitlab.freedesktop.org/xorg/lib/libxxf86vm.git /build/libxxf86vm
    cd /build/libxxf86vm
    ./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS}
    ./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS} | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    make -j$(nproc) && make install
    rm -rf /build/libxxf86vm && cd /build

    # xrender
    git clone --branch libXrender-0.9.12 https://gitlab.freedesktop.org/xorg/lib/libxrender.git /build/libxrender
    cd /build/libxrender
    ./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS}
    ./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS} | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    make -j$(nproc) && make install
    rm -rf /build/libxrender && cd /build

    # xscrnsaver
    git clone --branch libXScrnSaver-1.2.4 https://gitlab.freedesktop.org/xorg/lib/libxscrnsaver.git /build/libxscrnsaver
    cd /build/libxscrnsaver
    ./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS}
    ./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS} | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    make -j$(nproc) && make install
    rm -rf /build/libxscrnsaver && cd /build

    # xrandr
    git clone --branch libXrandr-1.5.4 https://gitlab.freedesktop.org/xorg/lib/libxrandr.git /build/libxrandr
    cd /build/libxrandr
    ./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS}
    ./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS} | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    make -j$(nproc) && make install
    rm -rf /build/libxrandr && cd /build

    # xi
    git clone --branch libXi-1.8.2 https://gitlab.freedesktop.org/xorg/lib/libxi.git /build/libxi
    cd /build/libxi
    ./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS}
    ./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS} | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    make -j$(nproc) && make install
    rm -rf /build/libxi && cd /build

    # xinerama
    git clone --branch libXinerama-1.1.5 https://gitlab.freedesktop.org/xorg/lib/libxinerama.git /build/libxinerama
    cd /build/libxinerama
    ./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS}
    ./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS} | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    make -j$(nproc) && make install
    rm -rf /build/libxinerama && cd /build

    # xcursor
    git clone --branch libXcursor-1.2.3 https://gitlab.freedesktop.org/xorg/lib/libxcursor.git /build/libxcursor
    cd /build/libxcursor
    ./autogen.sh --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS}
    ./configure --prefix=${PREFIX} --enable-static --disable-shared --with-pic \
        --host=${CROSS_PREFIX%-} ${EXTRA_FLAGS} | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    make -j$(nproc) && make install
    rm -rf /build/libxcursor && cd /build

    # libsamplerate
    git clone --branch 0.2.2 https://github.com/libsndfile/libsamplerate.git /build/libsamplerate
    mkdir -p /build/libsamplerate/build && cd /build/libsamplerate/build
    cmake -S .. -B . \
        ${CMAKE_COMMON_ARG} \
        -DBUILD_TESTING=OFF -DLIBSAMPLERATE_EXAMPLES=OFF -DLIBSAMPLERATE_INSTALL=ON | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    make -j$(nproc) && make install
    rm -rf /build/libsamplerate && cd /build

    # libpulse
    git clone --branch stable-16.x https://gitlab.freedesktop.org/pulseaudio/pulseaudio.git /build/pulseaudio
    cd /build/pulseaudio
    echo >src/utils/meson.build
    echo >src/pulsecore/sndfile-util.c
    echo >src/pulsecore/sndfile-util.h
    sed -ri -e 's/(sndfile_dep = .*)\)/\1, required : false)/' meson.build
    sed -ri -e 's/shared_library/library/g' src/meson.build src/pulse/meson.build
    mkdir -p build && cd build
    meson --prefix=${PREFIX} \
        --buildtype=release \
        --default-library=static \
        -Ddaemon=false \
        -Dclient=true \
        -Ddoxygen=false \
        -Dgcov=false \
        -Dman=false \
        -Dtests=false \
        -Dipv6=true \
        -Dopenssl=enabled \
        --cross-file=/build/cross_file.txt .. | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    ninja -j$(nproc) && ninja install
    echo "Libs.private: -lstdc++ -ldl -lrt" >>${PREFIX}/lib/pkgconfig/libpulse.pc
    echo "Libs.private: -lstdc++ -ldl -lrt" >>${PREFIX}/lib/pkgconfig/libpulse-simple.pc
    rm -rf /build/pulseaudio && cd /build

    CONFIG_ARG="-DSDL_SHARED=OFF \
                -DSDL_STATIC=ON \
                -DSDL_STATIC_PIC=ON \
                -DSDL_TEST=OFF \
                -DSDL_X11=ON \
                -DSDL_X11_SHARED=OFF \
                -DHAVE_XGENERICEVENT=TRUE \
                -DSDL_VIDEO_DRIVER_X11_HAS_XKBKEYCODETOKEYSYM=1 \
                -DSDL_PULSEAUDIO=ON \
                -DSDL_PULSEAUDIO_SHARED=OFF"
else
    # libsamplerate
    git clone --branch 0.2.2 https://github.com/libsndfile/libsamplerate.git /build/libsamplerate
    mkdir -p /build/libsamplerate/build && cd /build/libsamplerate/build
    cmake -S .. -B . \
        ${CMAKE_COMMON_ARG} \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DLIBSAMPLERATE_EXAMPLES=OFF -DLIBSAMPLERATE_INSTALL=ON | log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        exit 1
    fi
    make -j$(nproc) && make install
    rm -rf /build/libsamplerate

    if [[ ${TARGET_OS} == "linux" ]]; then
        CONFIG_ARG="-DSDL_SHARED=OFF \
                    -DSDL_STATIC=ON \
                    -DSDL_STATIC_PIC=ON \
                    -DSDL_TEST=OFF \
                    -DSDL_X11=OFF \
                    -DSDL_X11_SHARED=OFF \
                    -DHAVE_XGENERICEVENT=FALSE \
                    -DSDL_VIDEO_DRIVER_X11_HAS_XKBKEYCODETOKEYSYM=0 \
                    -DSDL_PULSEAUDIO=OFF \
                    -DSDL_PULSEAUDIO_SHARED=OFF"
    elif [[ ${TARGET_OS} == "darwin" ]]; then
        CONFIG_ARG="-DSDL_SHARED=OFF \
                    -DSDL_STATIC=ON \
                    -DSDL_STATIC_PIC=ON \
                    -DSDL_X11=OFF \
                    -DSDL_PULSEAUDIO=OFF \
                    -DSDL_JOYSTICK=OFF \
                    -DSDL_HAPTIC=OFF \
                    -DWITH_SYSROOT=${SDK_PATH}"
    fi
fi

# sdl2
cd /build/sdl2
mkdir -p build && cd build
cmake -S .. -B . \
    ${CMAKE_COMMON_ARG} \
    ${CONFIG_ARG} | log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    exit 1
fi
make -j$(nproc) && make install

if [[ ${TARGET_OS} == "darwin" ]]; then
    sed -ri -e 's/\-Wl,\-\-no\-undefined.*//' -e 's/ \-l\/.+?\.a//g' ${PREFIX}/lib/pkgconfig/sdl2.pc
elif [[ ${TARGET_OS} == "linux" ]]; then
    sed -ri -e 's/\-Wl,\-\-no\-undefined.*//' -e 's/ \-l\/.+?\.a//g' ${PREFIX}/lib/pkgconfig/sdl2.pc
    echo "Libs.private: -lstdc++" >>${PREFIX}/lib/pkgconfig/sdl2.pc
    if [[ ${ARCH} == "x86_64" ]]; then
        echo 'Requires: libpulse-simple xxf86vm xscrnsaver xrandr xfixes xi xinerama xcursor' >>${PREFIX}/lib/pkgconfig/sdl2.pc
    fi
elif [[ ${TARGET_OS} == "windows" ]]; then
    sed -ri -e 's/\-Wl,\-\-no\-undefined.*//' -e 's/ \-mwindows//g' -e 's/ \-lSDL2main//g' -e 's/ \-Dmain=SDL_main//g' ${PREFIX}/lib/pkgconfig/sdl2.pc
fi

sed -ri -e 's/ -lSDL2//g' -e 's/Libs: /Libs: -lSDL2 /' ${PREFIX}/lib/pkgconfig/sdl2.pc
echo 'Requires: samplerate' >>${PREFIX}/lib/pkgconfig/sdl2.pc
rm -rf /build/sdl2 && cd /build

add_enable "--enable-sdl2"

exit 0

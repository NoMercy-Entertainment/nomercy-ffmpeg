#!/bin/bash
# Build ggml-vulkan + our shim into a static probe and check the three runtime
# conditions that matter. Usage: vulkan-shim-test.sh [elf|coff]
set -eu
FORMAT="${1:-elf}"
REPO="${REPO:-/repo}"
WORK="${WORK:-/tmp/nm-vkshim}"
WHISPER_VERSION=1.9.1

apt-get update -qq >/dev/null
PKGS="cmake ninja-build git gcc g++ binutils ca-certificates glslc libvulkan-dev spirv-headers file"
[[ ${FORMAT} == coff ]] && PKGS="${PKGS} mingw-w64"
apt-get install -y -qq --no-install-recommends ${PKGS} >/dev/null

mkdir -p "${WORK}" && cd "${WORK}"
[[ -d whisper.cpp ]] || git clone -q --depth 1 --branch "v${WHISPER_VERSION}" \
    https://github.com/ggml-org/whisper.cpp.git

# find_package(Vulkan) must be satisfiable without a real loader: ggml-vulkan is
# built as a static archive, so Vulkan_LIBRARY is never actually linked - it only
# has to exist as a path. Give it an empty archive and an isolated header dir.
mkdir -p "${WORK}/vkinc"
cp -r /usr/include/vulkan /usr/include/vk_video "${WORK}/vkinc/" 2>/dev/null || true
cp -r /usr/include/spirv "${WORK}/vkinc/" 2>/dev/null || true
: > "${WORK}/empty.c"
gcc -c "${WORK}/empty.c" -o "${WORK}/empty.o" && ar rcs "${WORK}/libvulkan-stub.a" "${WORK}/empty.o"

if [[ ${FORMAT} == coff ]]; then
    CC=x86_64-w64-mingw32-gcc; CXX=x86_64-w64-mingw32-g++
    CROSS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_C_COMPILER=${CC} -DCMAKE_CXX_COMPILER=${CXX}"
    # Ubuntu's mingw-w64 default (win32 thread model) still pulls libgomp.a's
    # OpenACC glue objects (oacc-init.o etc, needed for OpenMP support) which
    # reference plain pthread_* symbols unconditionally - verified: -static
    # linking otherwise fails with dozens of "undefined reference to
    # pthread_mutex_lock". winpthreads supplies those regardless of which
    # gthr backend the compiler itself uses internally, so link it explicitly
    # rather than switching compiler variant (which breaks ABI against the
    # __gthr_win32_* symbols the archives were already compiled to expect -
    # verified separately: using the posix-variant compiler for this final
    # link, while everything else was built with the win32-variant one,
    # fails with "undefined reference to __gthr_win32_mutex_lock" instead).
    EXTRA="-lstdc++ -lm -lpthread -lgomp -lwinpthread -lws2_32 -fstack-protector-strong"
    BIN="${WORK}/vulkan-probe.exe"
    sed -i 's|#if _WIN32_WINNT >= 0x0602|#if 0|' whisper.cpp/ggml/src/ggml-cpu/ggml-cpu.c
else
    CC=gcc; CXX=g++
    CROSS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_C_COMPILER=${CC} -DCMAKE_CXX_COMPILER=${CXX}"
    EXTRA="-lstdc++ -lm -lpthread -lgomp -ldl"
    BIN="${WORK}/vulkan-probe"
fi

cmake -S "${WORK}/whisper.cpp" -B "${WORK}/build" -G Ninja ${CROSS} \
    -DCMAKE_INSTALL_PREFIX="${WORK}/inst" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_VULKAN=ON \
    -DVulkan_INCLUDE_DIR="${WORK}/vkinc" -DVulkan_LIBRARY="${WORK}/libvulkan-stub.a" \
    -DVulkan_GLSLC_EXECUTABLE="$(command -v glslc)" \
    -DWHISPER_BUILD_TOOLS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF > "${WORK}/configure.log" 2>&1
ninja -j"$(nproc)" -C "${WORK}/build" > "${WORK}/build.log" 2>&1
ninja -C "${WORK}/build" install >> "${WORK}/build.log" 2>&1

# ggml's CMake install step names these archives with a "lib" prefix on the
# native (elf) build but without one when cross-compiling for Windows (coff) -
# verified against both actual builds, not assumed. Resolve whichever exists.
L="${WORK}/inst/lib"
libpath() { [[ -f "${L}/lib$1.a" ]] && echo "${L}/lib$1.a" || echo "${L}/$1.a"; }
LIBGGML="$(libpath ggml)"
LIBVULKAN="$(libpath ggml-vulkan)"
LIBCPU="$(libpath ggml-cpu)"
LIBBASE="$(libpath ggml-base)"

echo "== undefined vulkan symbols in the built archive (expect exactly 3):"
nm --undefined-only "${LIBVULKAN}" 2>/dev/null | grep -oE '\bvk[A-Za-z0-9]+' | sort -u

${CC} -O2 -I"${WORK}/inst/include" -I"${WORK}/vkinc" -static \
    "${REPO}/tools/ggml-variants/vulkan-probe.c" "${REPO}/scripts/includes/vk_loader_shim.c" \
    "${LIBGGML}" "${LIBVULKAN}" "${LIBCPU}" "${LIBBASE}" ${EXTRA} -o "${BIN}"
echo "built ${BIN}"

if [[ ${FORMAT} == elf ]]; then
    echo "== linkage (must say statically linked):"; file "${BIN}"
    echo "== case A: no loader present at all"; "${BIN}"; echo "exit=$?"
fi
exit 0

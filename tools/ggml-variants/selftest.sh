#!/bin/bash
# Build two ggml CPU variants, pack them, link both into one static binary and
# assert they coexist. Usage: selftest.sh elf|coff
set -eu
FORMAT="${1:-elf}"
REPO="${REPO:-/repo}"
WORK="${WORK:-/tmp/nm-selftest}"
WHISPER_VERSION=1.9.1

apt-get update -qq >/dev/null
PKGS="cmake ninja-build git gcc g++ binutils ca-certificates"
[[ ${FORMAT} == coff ]] && PKGS="${PKGS} mingw-w64"
apt-get install -y -qq --no-install-recommends ${PKGS} >/dev/null

mkdir -p "${WORK}" && cd "${WORK}"
[[ -d whisper.cpp ]] || git clone -q --depth 1 --branch "v${WHISPER_VERSION}" \
    https://github.com/ggml-org/whisper.cpp.git

if [[ ${FORMAT} == coff ]]; then
    export NM_NM=x86_64-w64-mingw32-nm NM_OBJCOPY=x86_64-w64-mingw32-objcopy NM_LD=x86_64-w64-mingw32-ld
    CC=x86_64-w64-mingw32-gcc
    CROSS="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++"
    EXTRA_LINK="-fstack-protector-strong -lws2_32"
    # mingw headers lack THREAD_POWER_THROTTLING_STATE, same guard the real build flips
    sed -i 's|#if _WIN32_WINNT >= 0x0602|#if 0|' whisper.cpp/ggml/src/ggml-cpu/ggml-cpu.c
else
    unset NM_NM NM_OBJCOPY NM_LD || true
    CC=gcc
    CROSS="-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++"
    EXTRA_LINK=""
fi

build() { # tag  instruction-flags...
    local tag="$1"; shift
    [[ -f ${WORK}/inst-${tag}/lib/libggml-cpu.a ]] && return 0
    cmake -S "${WORK}/whisper.cpp" -B "${WORK}/b-${tag}" -G Ninja \
        -DCMAKE_INSTALL_PREFIX="${WORK}/inst-${tag}" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
        -DWHISPER_BUILD_TOOLS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF ${CROSS} "$@" >"${WORK}/log-${tag}.txt" 2>&1
    ninja -j"$(nproc)" -C "${WORK}/b-${tag}" >>"${WORK}/log-${tag}.txt" 2>&1
    ninja -C "${WORK}/b-${tag}" install >>"${WORK}/log-${tag}.txt" 2>&1
    # the windows build installs unprefixed archive names
    [[ -f ${WORK}/inst-${tag}/lib/ggml-cpu.a ]] && \
        mv "${WORK}/inst-${tag}/lib/ggml-cpu.a" "${WORK}/inst-${tag}/lib/libggml-cpu.a"
    [[ -f ${WORK}/inst-${tag}/lib/ggml-base.a ]] && \
        mv "${WORK}/inst-${tag}/lib/ggml-base.a" "${WORK}/inst-${tag}/lib/libggml-base.a"
    return 0
}

build lo -DGGML_SSE42=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF
build hi -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON

source "${REPO}/scripts/includes/ggml_cpu_pack.sh"
nm_pack_variant "${FORMAT}" "${WORK}/inst-lo/lib/libggml-cpu.a" lo_ "${WORK}/lo.o"
nm_pack_variant "${FORMAT}" "${WORK}/inst-hi/lib/libggml-cpu.a" hi_ "${WORK}/hi.o"

BIN="${WORK}/selftest"
[[ ${FORMAT} == coff ]] && BIN="${BIN}.exe"

${CC} -O2 -I"${WORK}/inst-lo/include" "${REPO}/tools/ggml-variants/selftest.c" -static \
    "${WORK}/lo.o" "${WORK}/hi.o" "${WORK}/inst-lo/lib/libggml-base.a" \
    -lstdc++ -lm -lpthread ${EXTRA_LINK} -o "${BIN}"
echo "built ${BIN}"
[[ ${FORMAT} == elf ]] && "${BIN}"
exit 0

#!/bin/bash
# Usage: build-common.sh <target-os> <arch> <workdir>
#
# Runs the repo's real 48-whisper.sh (and 60-stemsplit.sh) in the base image
# with the platform's own environment, then builds a minimal ffmpeg against
# the result, plus a tiny statically-linked probe binary that reports which
# ggml CPU variant this process would select. One source of truth: the
# harness exercises the same 48-whisper.sh CI does, so it cannot drift.
#
# The probe exists because Task 4 (which makes the whisper/stemsplit filters
# themselves log the selected variant) has not landed on this branch yet --
# Task 3 comes first in the plan's own ordering. The probe calls
# nm_ggml_cpu_variant_name() directly against the produced
# libggml-cpu-variants.a, which proves the same thing (a variant really was
# selected, and which one) without depending on or duplicating Task 4's
# work. See task-3-report.md for the full reasoning.
set -eu
TARGET_OS="$1"; ARCH="$2"; WORK="$3"
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
DOCKERFILE="${REPO}/ffmpeg-${TARGET_OS}-${ARCH}.dockerfile"
IMAGE="${BASE_IMAGE:-nomercyentertainment/ffmpeg-base:latest}"

[[ -f ${DOCKERFILE} ]] || { echo "build-common.sh: no such dockerfile: ${DOCKERFILE}" >&2; exit 1; }

# Lift every ENV line out of the platform dockerfile so the container sees
# the same PREFIX, CC, CROSS_PREFIX, CMAKE_COMMON_ARG, CFLAGS... that CI
# uses.
#
# DEVIATION from the plan's version of this loop: it queued each computed
# value into the docker `-e` list via `eval echo` but never assigned it as a
# real shell variable in THIS process, so a later ENV line that referenced
# an earlier one (e.g. CC=${CROSS_PREFIX}gcc, two lines below where
# CROSS_PREFIX is set) evaluated against an empty variable -- every cross
# tool name would have come out unprefixed (CC=gcc instead of
# CC=x86_64-linux-gnu-gcc). Fixed by exporting each computed value into this
# shell as we go, the same way docker's own ENV processing resolves
# forward references.
#
# Two more things this loop must handle that a naive read misses:
#   - a multi-line "ENV FOO=bar \" continuation: only the first line matches
#     the grep pattern, and its trailing backslash must be stripped before
#     eval or bash waits forever for the (never-supplied) rest of the line.
#   - PATH: the dockerfile's own "ENV PATH=${PREFIX}/bin:${PATH}" means
#     "prepend to whatever PATH the image already has at that point", not
#     "prepend to this host script's PATH" (a Windows Git Bash PATH full of
#     C:\... entries that mean nothing inside the container and, worse,
#     could shadow the image's own /opt/cargo/bin or similar). PATH is
#     evaluated inside the container instead, right before running the
#     platform's own scripts.
env_args=()
while IFS= read -r raw; do
    line="${raw#ENV }"
    if [[ ${line} == *'\' ]]; then
        line="${line:0:${#line}-1}"
    fi
    [[ ${line} == *=* ]] || continue
    key="${line%%=*}"
    [[ ${key} == PATH ]] && continue
    set +u
    eval "${line}"
    env_args+=(-e "${key}=${!key}")
    set -u
done < <(grep -E '^ENV [A-Z_]+=' "${DOCKERFILE}")

# DEVIATION: the plan's ffmpeg configure invocation gated --cross-prefix /
# --arch / --target-os=mingw32 on "${CROSS_PREFIX:+...}" -- but CROSS_PREFIX
# is non-empty on every platform's dockerfile, linux-x86_64 included
# (CROSS_PREFIX=x86_64-linux-gnu-). Run verbatim, the very first platform
# would have been configured with --target-os=mingw32, breaking the build
# outright. The real platform dockerfiles (ffmpeg-linux-x86_64.dockerfile)
# pass --target-os=${TARGET_OS} unconditionally and only the windows
# dockerfiles hardcode mingw32 (ffmpeg's configure does not recognise
# "windows" as a target-os), so mirror that instead of gating on
# CROSS_PREFIX.
ffmpeg_target_os="${TARGET_OS}"
[[ ${TARGET_OS} == windows ]] && ffmpeg_target_os=mingw32

# CARRY FORWARD from Task 2: production ggml-cpu builds are OpenMP-enabled
# everywhere 48-whisper.sh does not explicitly turn it off (windows,
# freebsd), so the final ffmpeg link needs the OpenMP runtime wherever the
# dispatcher/variant objects land.
extra_libs="-lstdc++ -lm -lpthread"
if [[ ${TARGET_OS} != windows && ${TARGET_OS} != freebsd ]]; then
    extra_libs="${extra_libs} -fopenmp"
fi

# NM_SEED_PREFIX (optional): a host directory whose contents get copied into
# ${PREFIX} inside the container before 48-whisper.sh/60-stemsplit.sh run.
# The harness only ever runs those two numbered scripts, not the full
# init.sh pipeline, so anything an EARLIER numbered script would normally
# have installed into PREFIX (e.g. windows-x86_64's OpenBLAS, built by
# includes/windows/48-openblas.sh before 48-whisper.sh in a real init.sh
# run) has to be seeded in some other way for this harness to reach the
# same code path (48-whisper.sh's `-f ${PREFIX}/lib/libopenblas.a` gate for
# -DGGML_BLAS=ON). Not needed on platforms with nothing to seed.
seed_mount=()
if [[ -n "${NM_SEED_PREFIX:-}" ]]; then
    [[ -d ${NM_SEED_PREFIX} ]] || { echo "build-common.sh: no such NM_SEED_PREFIX dir: ${NM_SEED_PREFIX}" >&2; exit 1; }
    seed_mount=(-v "$(cygpath -w "${NM_SEED_PREFIX}")":/seed:ro)
fi

# windows-x86_64/aarch64: the base image (nomercyentertainment/ffmpeg-base)
# carries no mingw-w64 cross toolchain -- that gets installed by a RUN
# apt-get in the platform's own ffmpeg-windows-*.dockerfile, a layer this
# harness deliberately does not build (it only lifts ENV lines out of the
# dockerfile; see the loop above). Install just the packages 48-whisper.sh's
# CC/CXX/AR/NM/LD/etc. env vars point at, so this harness reaches the same
# compiler the real image would have. No-op on every other TARGET_OS.
windows_setup=""
if [[ ${TARGET_OS} == windows ]]; then
    windows_setup='
apt-get update >/tmp/apt.log 2>&1 || { cat /tmp/apt.log; exit 1; }
apt-get install -y --no-install-recommends mingw-w64 mingw-w64-tools mingw-w64-x86-64-dev mingw-w64-common >>/tmp/apt.log 2>&1 \
    || { cat /tmp/apt.log; exit 1; }
'
fi

mkdir -p "${WORK}"
MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$(cygpath -w "${REPO}/scripts")":/scripts:ro \
    -v "$(cygpath -w "${WORK}")":/out \
    "${seed_mount[@]}" \
    "${env_args[@]}" -e TARGET_OS="${TARGET_OS}" -e ARCH="${ARCH}" \
    -e NM_FFMPEG_TARGET_OS="${ffmpeg_target_os}" -e NM_EXTRA_LIBS="${extra_libs}" \
    -e NM_WINDOWS_SETUP="${windows_setup}" \
    "${IMAGE}" bash -c '
set -eu
eval "${NM_WINDOWS_SETUP}"
export PATH="${PREFIX}/bin:${PATH}"
mkdir -p /build "${PREFIX}/lib/pkgconfig" "${PREFIX}/include" "${PREFIX}/bin"
if [[ -d /seed ]]; then
    cp -a /seed/. "${PREFIX}/"
fi
cd /build

# init.sh normally sources these and exports them before running any
# numbered script; we run 48-whisper.sh / 60-stemsplit.sh directly, so do
# the same here.
. /scripts/init/helpers.sh
export -f hr text_with_padding add_enable add_cflag add_ldflag add_extralib join_lines split_lines clean_whitespace apply_sed check_enabled log

bash /scripts/48-whisper.sh
bash /scripts/60-stemsplit.sh

cd /build/ffmpeg
# DEVIATION: the plan had no -static anywhere in this configure invocation
# (LDFLAGS lifted from the dockerfile only carries -static-libgcc
# -static-libstdc++, which leaves libc/libm/libgomp dynamically linked). The
# real platform dockerfiles pass --extra-cflags="-static ..." and
# --extra-ldflags="-static ..." precisely to get a fully static binary; run
# as specified, the harness ffmpeg would have failed global constraint 2
# ("stay fully static") while still reporting PASS on every other check,
# since nothing else in the plan verifies static linking. Mirrored here from
# the production dockerfiles.
PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig ./configure --disable-everything --disable-autodetect \
    --disable-doc --disable-ffplay --disable-ffprobe --enable-whisper --enable-swresample \
    --enable-filter=stemsplit,whisper,aresample,aformat,anull,ametadata \
    --enable-demuxer=mp3,wav --enable-parser=mpegaudio --enable-decoder=mp3,mp3float,pcm_s16le \
    --enable-encoder=pcm_s16le --enable-muxer=wav,null --enable-protocol=file,pipe \
    --enable-runtime-cpudetect --pkg-config-flags=--static --enable-cross-compile \
    --cross-prefix=${CROSS_PREFIX:-} --arch=${ARCH} --target-os=${NM_FFMPEG_TARGET_OS} \
    --extra-cflags="-static -static-libgcc -static-libstdc++" \
    --extra-ldflags="-static -static-libgcc -static-libstdc++" \
    --extra-libs="${NM_EXTRA_LIBS}"
make -j"$(nproc)"
cp ffmpeg* /out/

# Verification-only probe (see file header): reports the selected ggml CPU
# variant directly, independent of Task 4 filter-level logging.
cat > /build/nm_probe.c <<"CEOF"
#include <stdio.h>
#include "nm_ggml_cpu.h"
int main(void) { printf("%s\n", nm_ggml_cpu_variant_name()); return 0; }
CEOF
if [[ -f ${PREFIX}/lib/libggml-cpu-variants.a ]]; then
    ${CC} -O2 -I${PREFIX}/include -static /build/nm_probe.c -o /out/nm-probe \
        -L${PREFIX}/lib -Wl,--start-group -lggml-cpu-variants -lggml-base -lggml -Wl,--end-group \
        ${NM_EXTRA_LIBS}
fi
cp /ffmpeg_build.log /out/ffmpeg_build.log 2>/dev/null || true
# Verification-only: expose the generated whisper.pc so a harness can grep
# it for real (e.g. -lggml-blas / -lggml-cpu-variants) instead of only
# reading the generator script that produced it.
cp ${PREFIX}/lib/pkgconfig/whisper.pc /out/whisper.pc 2>/dev/null || true
'
echo "built into ${WORK}"

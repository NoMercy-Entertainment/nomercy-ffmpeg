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

# freebsd-x86_64: same story as windows above, but the missing piece is a
# whole cross-toolchain-by-hand -- apt has no cross-gcc for FreeBSD, so
# ffmpeg-freebsd-x86_64.dockerfile builds ${CROSS_PREFIX}* as clang/lld
# wrapper scripts against a downloaded FreeBSD base.txz sysroot (its own RUN
# block, not an ENV line, so the lifting loop above cannot see it either).
# Mirrors that RUN block exactly, using the SYSROOT/CROSS_PREFIX/
# FREEBSD_VERSION values the loop already lifted. Static shim libs
# (libstdc++.a/libdl.a/libgcc_s.a/libatomic.a) are recreated too: FreeBSD has
# none of these as real archives, and the scripts' generated .pc files
# reference them unconditionally.
freebsd_setup=""
if [[ ${TARGET_OS} == freebsd ]]; then
    freebsd_setup='
apt-get update >/tmp/apt.log 2>&1 || { cat /tmp/apt.log; exit 1; }
apt-get install -y --no-install-recommends clang lld llvm >>/tmp/apt.log 2>&1 \
    || { cat /tmp/apt.log; exit 1; }
mkdir -p "${SYSROOT}"
(wget -O /tmp/base.txz "https://download.freebsd.org/releases/amd64/${FREEBSD_VERSION}-RELEASE/base.txz" >/tmp/wget.log 2>&1 \
    || wget -O /tmp/base.txz "https://archive.freebsd.org/old-releases/amd64/${FREEBSD_VERSION}-RELEASE/base.txz" >>/tmp/wget.log 2>&1) \
    || { cat /tmp/wget.log; exit 1; }
tar -xJf /tmp/base.txz -C "${SYSROOT}" ./lib ./usr/lib ./usr/include ./usr/libdata
rm -f /tmp/base.txz
printf "#!/bin/sh\nexec clang --target=%s --sysroot=%s -fuse-ld=lld -Qunused-arguments \"\$@\"\n" "${CROSS_PREFIX%-}" "${SYSROOT}" > /usr/local/bin/${CROSS_PREFIX}gcc
printf "#!/bin/sh\nexec clang++ --target=%s --sysroot=%s -stdlib=libc++ -fuse-ld=lld -Qunused-arguments \"\$@\"\n" "${CROSS_PREFIX%-}" "${SYSROOT}" > /usr/local/bin/${CROSS_PREFIX}g++
chmod +x /usr/local/bin/${CROSS_PREFIX}gcc /usr/local/bin/${CROSS_PREFIX}g++
ln -sf /usr/bin/ld.lld /usr/local/bin/${CROSS_PREFIX}ld
ln -sf /usr/bin/llvm-ar /usr/local/bin/${CROSS_PREFIX}ar
ln -sf /usr/bin/llvm-ar /usr/local/bin/${CROSS_PREFIX}gcc-ar
ln -sf /usr/bin/llvm-ranlib /usr/local/bin/${CROSS_PREFIX}ranlib
ln -sf /usr/bin/llvm-ranlib /usr/local/bin/${CROSS_PREFIX}gcc-ranlib
ln -sf /usr/bin/llvm-nm /usr/local/bin/${CROSS_PREFIX}nm
ln -sf /usr/bin/llvm-nm /usr/local/bin/${CROSS_PREFIX}gcc-nm
ln -sf /usr/bin/llvm-strip /usr/local/bin/${CROSS_PREFIX}strip
ln -sf /usr/bin/llvm-objdump /usr/local/bin/${CROSS_PREFIX}objdump
ln -sf /usr/bin/llvm-strings /usr/local/bin/${CROSS_PREFIX}strings
ln -sf /usr/bin/llvm-size /usr/local/bin/${CROSS_PREFIX}size
ln -sf /usr/bin/llvm-readelf /usr/local/bin/${CROSS_PREFIX}readelf
ln -sf /usr/bin/llvm-objcopy /usr/local/bin/${CROSS_PREFIX}objcopy
printf "INPUT(-lc++ -lcxxrt)\n" > "${SYSROOT}/usr/lib/libstdc++.a"
llvm-ar rc "${SYSROOT}/usr/lib/libdl.a"
printf "INPUT(-lgcc -lgcc_eh)\n" > "${SYSROOT}/usr/lib/libgcc_s.a"
llvm-ar rc "${SYSROOT}/usr/lib/libatomic.a"
${CROSS_PREFIX}gcc --version >/tmp/cc_version.log 2>&1 || { cat /tmp/cc_version.log; exit 1; }
'
fi

# darwin-x86_64/arm64: heaviest of the three, per the task brief -- there is
# no apt cross-toolchain for Darwin either, and unlike freebsd's clang+lld
# shim the real dockerfile builds a whole osxcross toolchain (cctools-port,
# ld64, libtapi) against a downloaded macOS SDK. Mirrors
# ffmpeg-darwin-*.dockerfile's RUN blocks that produce it, minus the Rust/
# cargo-c/apple-codesign install (those exist for OTHER dependencies' builds
# and for ad-hoc signing the final ffmpeg binary; nothing in
# 48-whisper.sh/60-stemsplit.sh needs Rust or a signed binary). Slow (SDK
# download + a real cctools-port compile) but this is the same tradeoff the
# task brief calls out: standing up osxcross is the only way to reach
# 48-whisper.sh here without going through the full, unrelated
# multi-dependency init.sh pipeline (see the freebsd note above -- the same
# pipeline was observed failing on an unrelated libbluray/meson bug before
# it ever reaches whisper).
darwin_setup=""
if [[ ${TARGET_OS} == darwin ]]; then
    darwin_setup='
apt-get update >/tmp/apt.log 2>&1 || { cat /tmp/apt.log; exit 1; }
apt-get install -y --no-install-recommends clang patch liblzma-dev libxml2-dev xz-utils bzip2 cpio zlib1g-dev libgit2-dev >>/tmp/apt.log 2>&1 \
    || { cat /tmp/apt.log; exit 1; }
git clone https://github.com/tpoechtrager/osxcross.git /build/osxcross >/tmp/osxcross_clone.log 2>&1 \
    || { cat /tmp/osxcross_clone.log; exit 1; }
cd /build/osxcross
wget -nc "https://github.com/joseluisq/macosx-sdks/releases/download/${SDK_VERSION}/MacOSX${SDK_VERSION}.sdk.tar.xz" >/tmp/sdk_wget.log 2>&1 \
    || { cat /tmp/sdk_wget.log; exit 1; }
mv "MacOSX${SDK_VERSION}.sdk.tar.xz" "tarballs/MacOSX${SDK_VERSION}.sdk.tar.xz"
UNATTENDED=1 SDK_VERSION="${SDK_VERSION}" OSX_VERSION_MIN="${MACOSX_DEPLOYMENT_TARGET%.0}" MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" TARGET_DIR="${PREFIX}/osxcross" ./build.sh >/tmp/osxcross_build.log 2>&1 \
    || { tail -c 20000 /tmp/osxcross_build.log; exit 1; }
echo "MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}" > "${PREFIX}/osxcross/bin/cc_target"
cp "${PREFIX}/osxcross/bin/cc_target" "${SDK_PATH}/usr/bin/cc_target"
cd /build
ln -sf "${PREFIX}/osxcross/bin/${CROSS_PREFIX}install_name_tool" "${SDK_PATH}/usr/bin/${CROSS_PREFIX}install_name_tool"
chmod +x "${SDK_PATH}/usr/bin/${CROSS_PREFIX}install_name_tool"
ln -sf "${PREFIX}/osxcross/bin/${CROSS_PREFIX}otool" "${SDK_PATH}/usr/bin/${CROSS_PREFIX}otool"
chmod +x "${SDK_PATH}/usr/bin/${CROSS_PREFIX}otool"
ln -sf /build/osxcross/build/apple-libtapi/build/tools/llvm-objdump "${SDK_PATH}/usr/bin/${CROSS_PREFIX}objdump"
chmod +x "${SDK_PATH}/usr/bin/${CROSS_PREFIX}objdump"
ln -sf /build/osxcross/build/apple-libtapi/build/tools/llvm-objcopy "${SDK_PATH}/usr/bin/${CROSS_PREFIX}objcopy"
chmod +x "${SDK_PATH}/usr/bin/${CROSS_PREFIX}objcopy"
mkdir -p /System/Library/Frameworks
ln -sf "${OSX_FRAMEWORKS}/System/Library/Frameworks" /System/Library/Frameworks
${CROSS_PREFIX}clang --version >/tmp/cc_version.log 2>&1 || { cat /tmp/cc_version.log; exit 1; }
'
fi

mkdir -p "${WORK}"
MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$(cygpath -w "${REPO}/scripts")":/scripts:ro \
    -v "$(cygpath -w "${WORK}")":/out \
    "${seed_mount[@]}" \
    "${env_args[@]}" -e TARGET_OS="${TARGET_OS}" -e ARCH="${ARCH}" \
    -e NM_FFMPEG_TARGET_OS="${ffmpeg_target_os}" -e NM_EXTRA_LIBS="${extra_libs}" \
    -e NM_WINDOWS_SETUP="${windows_setup}" -e NM_FREEBSD_SETUP="${freebsd_setup}" \
    -e NM_DARWIN_SETUP="${darwin_setup}" \
    "${IMAGE}" bash -c '
set -eu
eval "${NM_WINDOWS_SETUP}"
eval "${NM_FREEBSD_SETUP}"
eval "${NM_DARWIN_SETUP}"
if [[ ${TARGET_OS} == darwin ]]; then
    export PATH="${PREFIX}/bin:${SDK_PATH}/usr/bin:${PREFIX}/osxcross/bin:${PATH}"
else
    export PATH="${PREFIX}/bin:${PATH}"
fi
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
#
# DEVIATION found while verifying Task 6 (freebsd/darwin): every real
# ffmpeg-*.dockerfile passes --pkg-config=pkg-config explicitly; this
# harness invocation did not. Without it, ffmpeg configure defaults
# pkg_config to "${cross_prefix}pkg-config" (configure:5033) -- on
# linux-x86_64/windows that name happens to already exist as a real
# apt-installed wrapper (x86_64-linux-gnu-pkg-config,
# x86_64-w64-mingw32-pkg-config), so Task 3/5 never noticed the gap, but
# "x86_64-unknown-freebsd14-pkg-config" and the darwin CROSS_PREFIX are
# invented by this projects own toolchain setup and never going to
# exist. configure then silently sets pkg_config=false
# (configure:5075-5077) and every subsequent check_pkg_config call fails
# with "not found using pkg-config", including require_pkg_config whisper
# -- which is exactly the failure this surfaced. Matches production now.
#
# PITFALL hit while verifying Task 6, recorded so it does not recur: a
# stray apostrophe in a comment ANYWHERE inside this single-quoted
# bash -c argument (the big docker command above) silently closes the
# quoted string early. Everything from that apostrophe to the
# next literal single-quote character in the file then stops being the
# container script and instead gets parsed as code belonging to this
# HOST script -- so a dollar-brace variable reference further down that
# was meant to expand inside the container instead expands against the
# HOST shell environment, where it is usually unset. That surfaced here
# as a baffling
# "NM_FFMPEG_TARGET_OS: unbound variable" error attributed to this
# configure line, even though the variable was correctly set inside the
# container the whole time -- the expansion was simply happening in the
# wrong shell. `bash -n` on this file does not catch it by itself unless
# the quote count is actually unbalanced (it is not always). If this
# script ever misbehaves in a way that does not make sense given what is
# printed right before the failure, check for a new apostrophe first.
PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig ./configure --disable-everything --disable-autodetect \
    --disable-doc --disable-ffplay --disable-ffprobe --enable-whisper --enable-swresample \
    --enable-filter=stemsplit,whisper,aresample,aformat,anull,ametadata \
    --enable-demuxer=mp3,wav --enable-parser=mpegaudio --enable-decoder=mp3,mp3float,pcm_s16le \
    --enable-encoder=pcm_s16le --enable-muxer=wav,null --enable-protocol=file,pipe \
    --enable-runtime-cpudetect --pkg-config=pkg-config --pkg-config-flags=--static --enable-cross-compile \
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

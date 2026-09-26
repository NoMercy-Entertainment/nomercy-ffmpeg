#!/bin/bash
# Usage: seed-windows-openblas.sh <seed-dir>
#
# Builds (or reuses) a windows-x86_64 OpenBLAS into <seed-dir> for
# build-windows-x86_64.sh to feed into build-common.sh's NM_SEED_PREFIX.
#
# WHY THIS EXISTS: an earlier version of build-windows-x86_64.sh seeded
# OpenBLAS by copying a prebuilt tree out of the project's ffblas-vol docker
# volume without checking which flags it was built with. ffblas-vol turned
# out to hold BOTH a pre-fix build (NUM_THREADS=64, no BUFFERSIZE cap -- the
# one issue #70 / commit b52078d fixed) and a post-fix one
# (NUM_THREADS=16, BUFFERSIZE=20) under similarly-named directories
# (pfx-cur vs pfx-cap), and the harness picked the wrong one (pfx-cur, the
# unfixed 64-thread build) for the task-5 windows-x86_64 verification --
# undetected because stemsplit's own timing/accuracy checks never call BLAS,
# so nothing in that verification would have caught a bad OpenBLAS. See
# task-5-report.md's "Fix: OpenBLAS seed provenance" section.
#
# To make that class of mistake impossible instead of just fixed once, this
# script does not trust ANY prebuilt artifact's directory name: it always
# builds by literally running the repo's own
# scripts/includes/windows/48-openblas.sh (the single source of truth for
# NUM_THREADS/BUFFERSIZE), and stamps the result with a hash of that script.
# A cached seed is only reused when its stamp matches the CURRENT script; any
# mismatch (or a first run) triggers a full rebuild. There is no code path
# that can silently hand back a seed built from a stale script.
set -eu
SEED="$1"
REPO="${REPO:-$(cd "$(dirname "$0")/../.." && pwd)}"
DOCKERFILE="${REPO}/ffmpeg-windows-x86_64.dockerfile"
IMAGE="${BASE_IMAGE:-nomercyentertainment/ffmpeg-base:latest}"
SCRIPT="${REPO}/scripts/includes/windows/48-openblas.sh"

[[ -f ${SCRIPT} ]] || { echo "seed-windows-openblas.sh: missing ${SCRIPT}" >&2; exit 1; }
[[ -f ${DOCKERFILE} ]] || { echo "seed-windows-openblas.sh: missing ${DOCKERFILE}" >&2; exit 1; }

current_hash=$(sha256sum "${SCRIPT}" | awk '{print $1}')

if [[ -f "${SEED}/lib/libopenblas.a" && -f "${SEED}/.nm-openblas-stamp" ]] \
    && [[ "$(cat "${SEED}/.nm-openblas-stamp")" == "${current_hash}" ]]; then
    echo "seed-windows-openblas.sh: reusing ${SEED} (stamp matches current 48-openblas.sh: ${current_hash})"
    exit 0
fi
if [[ -d ${SEED} ]]; then
    echo "seed-windows-openblas.sh: stale or missing seed at ${SEED} (stamp did not match current 48-openblas.sh, or no stamp) -- rebuilding"
fi

rm -rf "${SEED}"
mkdir -p "${SEED}/lib/pkgconfig" "${SEED}/include"

# Same ENV-lift as build-common.sh's own loop (duplicated deliberately: this
# script runs standalone, independent of any build-common.sh invocation, so
# it needs its own PREFIX/CC/CXX/CMAKE_COMMON_ARG/... resolution before it
# can run 48-openblas.sh. See build-common.sh for the full reasoning on
# forward-reference resolution and the PATH special case; kept in sync by
# hand since this is the only other caller.)
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

MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$(cygpath -w "${REPO}/scripts")":/scripts:ro \
    -v "$(cygpath -w "${SEED}")":/out \
    "${env_args[@]}" -e TARGET_OS=windows -e ARCH=x86_64 \
    "${IMAGE}" bash -c '
set -eu
apt-get update >/tmp/apt.log 2>&1 || { cat /tmp/apt.log; exit 1; }
apt-get install -y --no-install-recommends mingw-w64 mingw-w64-tools mingw-w64-x86-64-dev mingw-w64-common >>/tmp/apt.log 2>&1 \
    || { cat /tmp/apt.log; exit 1; }
export PATH="${PREFIX}/bin:${PATH}"
mkdir -p /build "${PREFIX}/lib/pkgconfig" "${PREFIX}/include" "${PREFIX}/bin"
cd /build
. /scripts/init/helpers.sh
export -f hr text_with_padding add_enable add_cflag add_ldflag add_extralib join_lines split_lines clean_whitespace apply_sed check_enabled log

bash /scripts/includes/windows/48-openblas.sh

[[ -f ${PREFIX}/lib/libopenblas.a ]] || { echo "seed-windows-openblas.sh: 48-openblas.sh did not produce libopenblas.a" >&2; exit 1; }
cp ${PREFIX}/lib/libopenblas.a /out/lib/
cp -r ${PREFIX}/include/openblas /out/include/
cp ${PREFIX}/lib/pkgconfig/openblas.pc /out/lib/pkgconfig/ 2>/dev/null || true
'

echo "${current_hash}" > "${SEED}/.nm-openblas-stamp"
echo "seed-windows-openblas.sh: built ${SEED} (stamp ${current_hash})"

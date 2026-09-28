#!/usr/bin/env bash
# Builds nmcompat.o with the production flags, links the C and C++
# self-tests (selftest.c, selftest_cxx.cpp) against it, and runs both
# inside nomercyentertainment/ffmpeg-base:latest so the compiler and glibc
# match the real ffmpeg build. Task 1 needs no ffmpeg build at all: this is
# minutes, not hours.
#
# A successful link is not evidence (see the plan's Global Constraints and
# Review Focus 1/2) — this script always RUNS both self-tests under a
# timeout and treats a nonzero exit or a timeout as failure.
#
# Usage: bash tools/nvenc-wsl2/build-selftest.sh
#
# Env overrides, used to reproduce the plan's trap-proofs on scratch copies
# without duplicating this script:
#   NMCOMPAT_SRC   repo-relative path to the nmcompat.c to build.
#                  Default: scripts/includes/nmcompat.c
#   CHECK_HIDDEN   1 to additionally assert (Review Focus 2) that objdump -T
#                  exports none of the shim symbols. Default: 0.
#   RUN_TIMEOUT    seconds allowed for each self-test before it counts as a
#                  hang. Default: 10.
#
# Always on, not gated behind an env var: a "capture" check that objdump -T
# imports (UND) none of the shim symbols from the dynamic libc. This is the
# ffplay defect (Task 3b / task-4-report.md) in miniature -- a symbol the
# shim source forgets to define still links and still passes every
# functional CHECK above, because it's silently satisfied by the *build
# image's* glibc (2.39 here) instead of by nmcompat.o. That leak is invisible
# to a correctness test and only shows up in objdump -T as an imported
# `name@GLIBC_x.y` entry, exactly the shape the real dockerfile link guard
# checks on the shipped binaries. Verified both directions on wcslcpy/wcslcat:
# without the shim, `wcslcpy@GLIBC_2.38`/`wcslcat@GLIBC_2.38` show up as UND;
# with it, neither symbol appears in the dynamic table at all.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NMCOMPAT_SRC="${NMCOMPAT_SRC:-scripts/includes/nmcompat.c}"
CHECK_HIDDEN="${CHECK_HIDDEN:-0}"
RUN_TIMEOUT="${RUN_TIMEOUT:-10}"
IMAGE="nomercyentertainment/ffmpeg-base:latest"

# Bind mounts on Windows/Git Bash need this or the path is mangled into a
# literal directory named "<path>;C".
export MSYS_NO_PATHCONV=1

if [ ! -f "$REPO_ROOT/$NMCOMPAT_SRC" ]; then
    echo "build-selftest.sh: $NMCOMPAT_SRC not found under $REPO_ROOT" >&2
    exit 1
fi

docker run --rm \
    -v "$REPO_ROOT:/work" \
    -w /work \
    -e NMCOMPAT_SRC="$NMCOMPAT_SRC" \
    -e CHECK_HIDDEN="$CHECK_HIDDEN" \
    -e RUN_TIMEOUT="$RUN_TIMEOUT" \
    "$IMAGE" \
    bash -eu -o pipefail -c '
        OUT=$(mktemp -d)
        trap "rm -rf \"$OUT\"" EXIT

        echo "=== compiling $NMCOMPAT_SRC (gcc -O2 -fPIC -fvisibility=hidden -fno-builtin -c) ==="
        gcc -O2 -fPIC -fvisibility=hidden -fno-builtin -c "$NMCOMPAT_SRC" -o "$OUT/nmcompat.o"

        echo "=== linking C self-test (ordinary dynamic link) ==="
        gcc -O2 -o "$OUT/selftest" tools/nvenc-wsl2/selftest.c "$OUT/nmcompat.o" -lm

        echo "=== linking C++ self-test (-static-libgcc -static-libstdc++, matches ffmpeg link flags) ==="
        g++ -O2 -static-libgcc -static-libstdc++ -pthread \
            -o "$OUT/selftest_cxx" tools/nvenc-wsl2/selftest_cxx.cpp "$OUT/nmcompat.o" -lm

        echo "=== objdump -T selftest: asserting no shim symbol is imported (UND) from the dynamic libc ==="
        if objdump -T "$OUT/selftest" | grep "UND" \
            | grep -E "arc4random|_dl_find_object|\bstrlc(py|at)\b|\bwcslc(py|at)\b|__isoc23_|pidfd_spawnp|pidfd_getpid|_ZGVbN2"; then
            echo "NOT CAPTURED - FAIL (a shim symbol is being satisfied by the build images own glibc, not nmcompat.o -- this is the ffplay defect in miniature, see task-4-report.md)"
            exit 1
        fi
        echo "all shim symbols captured by nmcompat.o - ok"

        if [ "$CHECK_HIDDEN" = "1" ]; then
            echo "=== objdump -T selftest: asserting no shim symbol is a dynamic export ==="
            if objdump -T "$OUT/selftest" \
                | grep -E "arc4random|_dl_find_object|\bstrlc(py|at)\b|\bwcslc(py|at)\b|__isoc23_|pidfd_spawnp|pidfd_getpid|_ZGVbN2"; then
                echo "EXPORTED - FAIL (shim symbols visible in .dynsym)"
                exit 1
            fi
            echo "none exported - ok"
        fi

        echo "=== running C self-test (timeout ${RUN_TIMEOUT}s) ==="
        set +e
        timeout "$RUN_TIMEOUT" "$OUT/selftest"
        c_rc=$?
        set -e
        echo "selftest exit=$c_rc"

        echo "=== running C++ self-test (timeout ${RUN_TIMEOUT}s) ==="
        set +e
        timeout "$RUN_TIMEOUT" "$OUT/selftest_cxx"
        cxx_rc=$?
        set -e
        echo "selftest_cxx exit=$cxx_rc"

        if [ "$c_rc" -ne 0 ] || [ "$cxx_rc" -ne 0 ]; then
            echo "BUILD-SELFTEST FAILED (selftest=$c_rc selftest_cxx=$cxx_rc)"
            exit 1
        fi
        echo "BUILD-SELFTEST PASSED"
    '

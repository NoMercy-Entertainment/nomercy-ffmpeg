#!/usr/bin/env bash
# Manual Linux/glibc diagnostic; the shared plugin is a test fixture only.
set -euo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    echo 'This diagnostic requires native Linux x86_64 with glibc.' >&2
    exit 2
fi
CC=${CC:-gcc}
CXX=${CXX:-g++}
for tool in "$CC" "$CXX" readelf timeout getconf; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 2; }
done
getconf GNU_LIBC_VERSION
BUILD_DIR=${1:-"$ROOT/output/linux-runtime/dlopen"}
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
fixtures="$ROOT/tools/linux-runtime/fixtures"
"$CC" -std=c11 -O0 -g -Wall -Wextra -Werror -fPIC -shared \
    "$fixtures/probe-plugin.c" -pthread -o "$BUILD_DIR/plugin.so"
"$CXX" -std=c++17 -O0 -g -Wall -Wextra -Werror -pthread \
    -c "$fixtures/probe-main.cpp" -o "$BUILD_DIR/main.o"
LINUX_LINK_CC="$CC" bash "$ROOT/scripts/includes/linux_link.sh" \
    "$BUILD_DIR/main.o" -pthread -ldl -o "$BUILD_DIR/hardware"
"$CXX" -static "$BUILD_DIR/main.o" -pthread -ldl -o "$BUILD_DIR/static-control" \
    2>"$BUILD_DIR/static-link.log"

for variant in hardware static-control; do
    readelf --program-headers --dynamic --version-info "$BUILD_DIR/$variant" >"$BUILD_DIR/$variant.elf.txt"
done
# Check that these really are different startup runtime policies.
grep -Fq 'Requesting program interpreter: /lib64/ld-linux-x86-64.so.2]' "$BUILD_DIR/hardware.elf.txt"
grep -Fq 'Shared library: [libc.so.6]' "$BUILD_DIR/hardware.elf.txt"
if grep -Eq '\(NEEDED\).*(libstdc\+\+|libgcc_s)' "$BUILD_DIR/hardware.elf.txt"; then
    echo 'Hardware fixture accidentally uses a shared C++ runtime.' >&2
    exit 1
fi
if grep -Eq '\(NEEDED\)|Requesting program interpreter:' "$BUILD_DIR/static-control.elf.txt"; then
    echo 'Negative control is not fully static.' >&2
    exit 1
fi
for variant in hardware static-control; do
    expectation=isolated
    [[ $variant != static-control ]] || expectation=collision
    if timeout -k 2 15 "$BUILD_DIR/$variant" "$BUILD_DIR/plugin.so" "$expectation" \
        >"$BUILD_DIR/$variant.log" 2>&1; then
        result=0
    else
        result=$?
    fi
    printf '%s\n' "$result" >"$BUILD_DIR/$variant.status"
    cat "$BUILD_DIR/$variant.log"
    if [[ $result != 0 ]]; then
        echo "$variant did not demonstrate $expectation (exit=$result); inspect $BUILD_DIR" >&2
        exit 1
    fi
done
echo "PASS: hardware preserves pthread state; static control demonstrates the collision. Logs: $BUILD_DIR"

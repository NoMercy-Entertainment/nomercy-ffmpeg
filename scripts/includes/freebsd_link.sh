#!/bin/bash
# FFmpeg's target linker: static codec/C++ archives, dynamic FreeBSD base only.
# Use a per-library scope because pkg-config mixes codec and system libraries.
set -euo pipefail
# FFmpeg's makefiles decorate exported CC with their quiet command printer.
# Capture the real compiler before make rather than executing that make recipe.
compiler=${FREEBSD_LINK_CC:-${CC:-}}
: "${compiler:?FreeBSD target C compiler must be set}"

if [[ $# == 1 && ( $1 == --version || $1 == -v ) ]]; then
    exec "${compiler}" "$@"
fi

args=()
for arg in "$@"; do
    case "${arg}" in
        -static)
            echo 'FreeBSD Vulkan requires the dynamic base runtime; -static is not supported' >&2
            exit 1
            ;;
        -lc|-lm|-lpthread|-lthr)
            args+=("-Wl,--push-state,-Bdynamic" "${arg}" "-Wl,--pop-state")
            ;;
        -l*)
            args+=("-Wl,--push-state,-Bstatic" "${arg}" "-Wl,--pop-state")
            ;;
        *) args+=("${arg}") ;;
    esac
done

# Suppress driver-added shared C++/unwind libraries. crt startup objects are
# still supplied by the target compiler; only its default libraries are replaced.
exec "${compiler}" -nodefaultlibs "${args[@]}" \
    -Wl,--push-state,-Bstatic -lc++ -lcxxrt -lgcc_eh -lgcc -Wl,--pop-state \
    -Wl,--push-state,-Bdynamic -lpthread -lm -lc -Wl,--pop-state

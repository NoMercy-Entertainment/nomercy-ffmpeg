#!/bin/bash
# Linux x86_64 hardware build: static codecs/C++/OpenMP, dynamic glibc base.
set -euo pipefail
# FFmpeg make decorates exported CC with its quiet command printer.
compiler=${LINUX_LINK_CC:-${CC:-}}
: "${compiler:?Linux target C compiler must be set}"
if [[ $# == 1 && ( $1 == --version || $1 == -v ) ]]; then
    exec "${compiler}" "$@"
fi

args=()
openmp=0
for arg in "$@"; do
    case "${arg}" in
        -static|-static-pie)
            echo 'Linux hardware build requires the dynamic base runtime; fully static linking is not supported' >&2
            exit 1 ;;
        # Do not let the compiler driver append a shared libgomp dependency.
        -fopenmp) openmp=1 ;;
        -lc|-lm|-lmvec|-lpthread|-ldl|-lrt|-lutil)
            args+=("-Wl,--push-state,-Bdynamic" "${arg}" "-Wl,--pop-state") ;;
        -l*) args+=("-Wl,--push-state,-Bstatic" "${arg}" "-Wl,--pop-state") ;;
        *) args+=("${arg}") ;;
    esac
done
runtime=(-lstdc++)
if [[ ${openmp} == 1 ]]; then runtime+=(-lgomp); fi
runtime+=(-lgcc -lgcc_eh)

# Retain target crt startup objects, but replace compiler-added runtime DSOs.
exec "${compiler}" -no-pie -nodefaultlibs "${args[@]}" \
    -Wl,--push-state,-Bstatic "${runtime[@]}" -Wl,--pop-state \
    -Wl,--push-state,-Bdynamic -lpthread -ldl -lrt -lm -lc -Wl,--pop-state

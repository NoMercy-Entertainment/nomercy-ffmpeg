#!/bin/bash
# Fail the build if a codec/runtime DSO leaks into any shipped FreeBSD program.
set -euo pipefail
: "${CROSS_PREFIX:?FreeBSD cross-toolchain prefix must be set}"
readelf="${CROSS_PREFIX}readelf"
build_dir=${1:-/build/ffmpeg}
for program in ffmpeg_g ffprobe_g; do
    [[ -f "${build_dir}/${program}" ]] || { echo "Missing ${program}" >&2; exit 1; }
done
for binary in "${build_dir}/ffmpeg_g" "${build_dir}/ffprobe_g" "${build_dir}/ffplay_g"; do
    [[ -f "${binary}" ]] || continue
    info=$("${readelf}" --program-headers --dynamic "${binary}")
    if ! grep -Fq 'Requesting program interpreter: /libexec/ld-elf.so.1]' <<<"${info}"; then
        echo "${binary}: missing FreeBSD runtime linker" >&2
        exit 1
    fi
    needed=$(awk '/\(NEEDED\)/ { sub(/^.*\[/, ""); sub(/\].*$/, ""); print }' <<<"${info}")
    if ! grep -Fxq 'libc.so.7' <<<"${needed}"; then
        echo "${binary}: missing dynamic base libc" >&2
        exit 1
    fi
    while IFS= read -r library; do
        case "${library}" in
            libc.so.7|libm.so.5|libthr.so.3) ;;
            *) echo "${binary}: unexpected shared dependency ${library}" >&2; exit 1 ;;
        esac
    done <<<"${needed}"
    printf '%s: base runtime only: %s\n' "${binary}" "${needed//$'\n'/ }"
done
